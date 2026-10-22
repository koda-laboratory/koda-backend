-- Sync contract: apply_mutations (push) and pull_changes (pull).
-- See .agents/skills/sync-contract/SKILL.md for the client-facing contract.

-- Internal sync bookkeeping (single row).
create table private.sync_state (
  id boolean primary key default true check (id),
  purge_watermark bigint not null default 0,
  last_purge_at timestamptz,
  keepalive_at timestamptz
);
insert into private.sync_state default values;

-- Highest server_seq of any purged tombstone. A client whose cursor is below it may have
-- missed a deletion and must do a full resync.
create or replace function public.sync_purge_watermark()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select s.purge_watermark from private.sync_state s where s.id;
$$;

-- Synced tables in dependency order (parents first). Mutations are applied in this order so a
-- batch may contain children before their parents.
create or replace function public.synced_tables()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
    'stores', 'products', 'product_stores', 'recipes', 'recipe_ingredients', 'recipe_components',
    'meal_plan_drafts', 'meal_plan_entries', 'consumptions', 'shopping_entries', 'shopping_entry_items'
  ]::text[];
$$;

-- ---------------------------------------------------------------------------
-- apply_mutations
-- ---------------------------------------------------------------------------
-- p_mutations: [{ table, id, op: 'upsert' | 'delete', fields: {...}, client_ts }]
-- Returns { applied: [{table, id, server_seq, merged?}], rejected: [{table, id, reason, ...}], cursor }.
--
-- Conflict rules:
--   * Row LWW by client_ts against client_updated_at (ties apply).
--   * shopping_entries / shopping_entry_items: field-level LWW.
--       checked/checked_at        resolved by checked_at (defaults to client_ts)
--       text/quantity/unit        resolved by name_updated_at (shopping_entries only)
--       any other field           row LWW by client_ts
--   * A tombstone wins: deletes always apply and upserts on a deleted row are rejected.
--   * client_ts more than 5 minutes in the future is clamped to now() (clock skew guard).
-- Each mutation runs in its own subtransaction: a failing mutation is reported as rejected
-- and does not abort the batch.
create or replace function public.apply_mutations(p_device_id uuid, p_mutations jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_tables constant text[] := public.synced_tables();
  v_server_cols constant text[] := array[
    'id', 'household_id', 'created_at', 'updated_at', 'updated_by', 'deleted_at', 'client_updated_at', 'server_seq'
  ];
  v_check_cols constant text[] := array['checked', 'checked_at'];
  v_name_cols constant text[] := array['text', 'quantity', 'unit', 'name_updated_at'];
  v_m record;
  v_table text;
  v_id uuid;
  v_op text;
  v_fields jsonb;
  v_ts timestamptz;
  v_writable text[];
  v_clean jsonb;
  v_existing jsonb;
  v_existing_ts timestamptz;
  v_accept jsonb;
  v_part jsonb;
  v_part_ts timestamptz;
  v_rest jsonb;
  v_refused boolean;
  v_cols text;
  v_seq bigint;
  v_cursor bigint;
  v_applied jsonb := '[]'::jsonb;
  v_rejected jsonb := '[]'::jsonb;
  v_reason text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if p_mutations is null or jsonb_typeof(p_mutations) <> 'array' then
    raise exception 'mutations must be a JSON array' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_array_length(p_mutations) > 1000 then
    raise exception 'too many mutations (max 1000)' using errcode = 'invalid_parameter_value';
  end if;

  -- Read by the push enqueue trigger to exclude the actor device.
  perform set_config('koda.device_id', coalesce(p_device_id::text, ''), true);
  -- Same lock key as private.sync_lock() (inlined: authenticated has no access to schema private).
  perform pg_advisory_xact_lock(hashtextextended('koda.sync_seq', 0));

  for v_m in
    select e.value as m, e.ordinality as idx
    from jsonb_array_elements(p_mutations) with ordinality as e
    order by coalesce(array_position(v_tables, e.value ->> 'table'), 0), e.ordinality
  loop
    v_table := v_m.m ->> 'table';
    v_op := v_m.m ->> 'op';
    v_id := null;
    begin
      if v_table is null or not (v_table = any (v_tables)) then
        v_rejected := v_rejected || jsonb_build_object('table', v_table, 'id', v_m.m -> 'id', 'reason', 'unknown_table');
        continue;
      end if;
      if v_op is null or v_op not in ('upsert', 'delete') then
        v_rejected := v_rejected || jsonb_build_object('table', v_table, 'id', v_m.m -> 'id', 'reason', 'invalid_op');
        continue;
      end if;
      v_id := (v_m.m ->> 'id')::uuid;
      v_ts := (v_m.m ->> 'client_ts')::timestamptz;
      if v_id is null or v_ts is null then
        v_rejected := v_rejected || jsonb_build_object('table', v_table, 'id', v_m.m -> 'id', 'reason', 'invalid_mutation');
        continue;
      end if;
      v_ts := least(v_ts, now() + interval '5 minutes');
      v_fields := coalesce(v_m.m -> 'fields', '{}'::jsonb);
      if jsonb_typeof(v_fields) <> 'object' then
        v_rejected := v_rejected || jsonb_build_object('table', v_table, 'id', v_id, 'reason', 'invalid_mutation');
        continue;
      end if;

      execute format('select to_jsonb(t) from public.%I t where t.id = $1 for update', v_table)
        into v_existing using v_id;

      -- ----------------------------------------------------------------- delete
      if v_op = 'delete' then
        if v_existing is null then
          v_rejected := v_rejected || jsonb_build_object('table', v_table, 'id', v_id, 'reason', 'not_found');
          continue;
        end if;
        if v_existing ->> 'deleted_at' is null then
          execute format(
            'update public.%I t set deleted_at = now(), client_updated_at = greatest(t.client_updated_at, $2) where t.id = $1 returning t.server_seq',
            v_table
          ) into v_seq using v_id, v_ts;
        else
          v_seq := (v_existing ->> 'server_seq')::bigint;
        end if;
        v_applied := v_applied || jsonb_build_object('table', v_table, 'id', v_id, 'server_seq', v_seq);
        v_cursor := greatest(v_cursor, v_seq);
        continue;
      end if;

      -- ----------------------------------------------------------------- upsert
      select array_agg(a.attname::text) into v_writable
      from pg_catalog.pg_attribute a
      where a.attrelid = format('public.%I', v_table)::regclass
        and a.attnum > 0 and not a.attisdropped;

      select coalesce(jsonb_object_agg(f.key, f.value), '{}'::jsonb) into v_clean
      from jsonb_each(v_fields) f
      where f.key = any (v_writable)
        and (not (f.key = any (v_server_cols)) or (f.key = 'household_id' and v_existing is null));

      if v_existing is null then
        -- Insert. Fill server-side defaults for the field-level LWW timestamps.
        if v_table in ('shopping_entries', 'shopping_entry_items') then
          if v_clean ? 'checked' and not v_clean ? 'checked_at' and (v_clean ->> 'checked')::boolean then
            v_clean := v_clean || jsonb_build_object('checked_at', v_ts);
          end if;
          if v_table = 'shopping_entries' then
            if (v_clean ->> 'checked')::boolean then
              v_clean := v_clean || jsonb_build_object('checked_by', auth.uid());
            end if;
            if not v_clean ? 'name_updated_at' then
              v_clean := v_clean || jsonb_build_object('name_updated_at', v_ts);
            end if;
          end if;
        end if;
        v_clean := v_clean || jsonb_build_object('id', v_id, 'client_updated_at', v_ts);
        select string_agg(format('%I', k), ', ') into v_cols from jsonb_object_keys(v_clean) k;
        execute format(
          'insert into public.%1$I (%2$s) select %2$s from jsonb_populate_record(null::public.%1$I, $1) returning server_seq',
          v_table, v_cols
        ) into v_seq using v_clean;
        v_applied := v_applied || jsonb_build_object('table', v_table, 'id', v_id, 'server_seq', v_seq);
        v_cursor := greatest(v_cursor, v_seq);
        continue;
      end if;

      if v_existing ->> 'deleted_at' is not null then
        v_rejected := v_rejected || jsonb_build_object(
          'table', v_table, 'id', v_id, 'reason', 'deleted', 'server_seq', (v_existing ->> 'server_seq')::bigint);
        continue;
      end if;

      v_existing_ts := coalesce((v_existing ->> 'client_updated_at')::timestamptz, '-infinity'::timestamptz);
      v_accept := '{}'::jsonb;
      v_refused := false;

      if v_table in ('shopping_entries', 'shopping_entry_items') then
        -- checked group, resolved by checked_at
        select coalesce(jsonb_object_agg(f.key, f.value), '{}'::jsonb) into v_part
        from jsonb_each(v_clean) f where f.key = any (v_check_cols);
        if v_part <> '{}'::jsonb then
          v_part_ts := least(coalesce((v_part ->> 'checked_at')::timestamptz, v_ts), now() + interval '5 minutes');
          if v_part_ts >= coalesce((v_existing ->> 'checked_at')::timestamptz, '-infinity'::timestamptz) then
            v_accept := v_accept || v_part || jsonb_build_object('checked_at', v_part_ts);
            if v_table = 'shopping_entries' then
              v_accept := v_accept || jsonb_build_object('checked_by', auth.uid());
            end if;
          else
            v_refused := true;
          end if;
        end if;
        v_rest := v_clean - v_check_cols;

        -- name group, resolved by name_updated_at (shopping_entries only)
        if v_table = 'shopping_entries' then
          select coalesce(jsonb_object_agg(f.key, f.value), '{}'::jsonb) into v_part
          from jsonb_each(v_clean) f where f.key = any (v_name_cols);
          if (v_part - 'name_updated_at') <> '{}'::jsonb then
            v_part_ts := least(coalesce((v_part ->> 'name_updated_at')::timestamptz, v_ts), now() + interval '5 minutes');
            if v_part_ts >= coalesce((v_existing ->> 'name_updated_at')::timestamptz, '-infinity'::timestamptz) then
              v_accept := v_accept || v_part || jsonb_build_object('name_updated_at', v_part_ts);
            else
              v_refused := true;
            end if;
          end if;
          v_rest := v_rest - v_name_cols - 'checked_by';
        end if;
      else
        v_rest := v_clean;
      end if;

      -- everything else: row LWW
      if v_rest <> '{}'::jsonb then
        if v_ts >= v_existing_ts then
          v_accept := v_accept || v_rest;
        else
          v_refused := true;
        end if;
      end if;

      if v_accept = '{}'::jsonb then
        if v_refused then
          v_rejected := v_rejected || jsonb_build_object(
            'table', v_table, 'id', v_id, 'reason', 'stale', 'server_seq', (v_existing ->> 'server_seq')::bigint);
        else
          -- Nothing to change.
          v_seq := (v_existing ->> 'server_seq')::bigint;
          v_applied := v_applied || jsonb_build_object('table', v_table, 'id', v_id, 'server_seq', v_seq);
          v_cursor := greatest(v_cursor, v_seq);
        end if;
        continue;
      end if;

      v_accept := v_accept || jsonb_build_object('client_updated_at', greatest(v_existing_ts, v_ts));
      select string_agg(format('%I', k), ', ') into v_cols from jsonb_object_keys(v_accept) k;
      execute format(
        'update public.%1$I t set (%2$s) = (select %2$s from jsonb_populate_record(null::public.%1$I, $1)) where t.id = $2 returning t.server_seq',
        v_table, v_cols
      ) into v_seq using v_accept, v_id;
      v_applied := v_applied || jsonb_build_array(
        jsonb_build_object('table', v_table, 'id', v_id, 'server_seq', v_seq)
        || case when v_refused then jsonb_build_object('merged', true) else '{}'::jsonb end
      );
      v_cursor := greatest(v_cursor, v_seq);
    exception when others then
      v_reason := case sqlstate
        when '42501' then 'forbidden'
        when '23505' then 'conflict'
        when '23503' then 'missing_reference'
        when '23502' then 'invalid_value'
        when '23514' then 'constraint_violation'
        when '22P02' then 'invalid_value'
        when '22007' then 'invalid_value'
        when '22008' then 'invalid_value'
        when '22023' then 'invalid_value'
        when '22003' then 'invalid_value'
        else 'error'
      end;
      v_rejected := v_rejected || jsonb_build_object(
        'table', v_table, 'id', coalesce(to_jsonb(v_id), v_m.m -> 'id'), 'reason', v_reason,
        'code', sqlstate, 'message', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('applied', v_applied, 'rejected', v_rejected, 'cursor', v_cursor);
end;
$$;

-- ---------------------------------------------------------------------------
-- pull_changes
-- ---------------------------------------------------------------------------
-- Rows of every synced table with server_seq > p_cursor (tombstones included), ordered by
-- server_seq, at most p_limit (1..1000). Returns { rows: [{table, row}], has_more, cursor,
-- reset_required }. cursor is the server_seq of the last returned row (or p_cursor).
create or replace function public.pull_changes(p_cursor bigint default 0, p_limit integer default 500)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_cursor bigint := greatest(coalesce(p_cursor, 0), 0);
  v_limit integer := greatest(1, least(coalesce(p_limit, 500), 1000));
  v_rows jsonb;
  v_count integer;
  v_has_more boolean;
  v_watermark bigint := public.sync_purge_watermark();
begin
  with changes as (
    select 'stores' as t, x.server_seq, to_jsonb(x) as r from public.stores x where x.server_seq > v_cursor
    union all
    select 'products', x.server_seq, to_jsonb(x) from public.products x where x.server_seq > v_cursor
    union all
    select 'product_stores', x.server_seq, to_jsonb(x) from public.product_stores x where x.server_seq > v_cursor
    union all
    select 'recipes', x.server_seq, to_jsonb(x) from public.recipes x where x.server_seq > v_cursor
    union all
    select 'recipe_ingredients', x.server_seq, to_jsonb(x) from public.recipe_ingredients x where x.server_seq > v_cursor
    union all
    select 'recipe_components', x.server_seq, to_jsonb(x) from public.recipe_components x where x.server_seq > v_cursor
    union all
    select 'meal_plan_drafts', x.server_seq, to_jsonb(x) from public.meal_plan_drafts x where x.server_seq > v_cursor
    union all
    select 'meal_plan_entries', x.server_seq, to_jsonb(x) from public.meal_plan_entries x where x.server_seq > v_cursor
    union all
    select 'consumptions', x.server_seq, to_jsonb(x) from public.consumptions x where x.server_seq > v_cursor
    union all
    select 'shopping_entries', x.server_seq, to_jsonb(x) from public.shopping_entries x where x.server_seq > v_cursor
    union all
    select 'shopping_entry_items', x.server_seq, to_jsonb(x) from public.shopping_entry_items x where x.server_seq > v_cursor
  ),
  page as (
    select * from changes order by server_seq limit v_limit + 1
  )
  select coalesce(jsonb_agg(jsonb_build_object('table', page.t, 'row', page.r) order by page.server_seq), '[]'::jsonb),
         count(*)
  into v_rows, v_count
  from page;

  v_has_more := v_count > v_limit;
  if v_has_more then
    v_rows := v_rows - v_limit;
  end if;

  return jsonb_build_object(
    'rows', v_rows,
    'has_more', v_has_more,
    'cursor', coalesce((v_rows -> -1 -> 'row' ->> 'server_seq')::bigint, v_cursor),
    'reset_required', v_cursor > 0 and v_cursor < v_watermark
  );
end;
$$;

revoke execute on function
  public.apply_mutations(uuid, jsonb),
  public.pull_changes(bigint, integer),
  public.sync_purge_watermark(),
  public.synced_tables()
from public, anon;
grant execute on function
  public.apply_mutations(uuid, jsonb),
  public.pull_changes(bigint, integer),
  public.sync_purge_watermark(),
  public.synced_tables()
to authenticated, service_role;
