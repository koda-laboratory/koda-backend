-- Shopping list item status (PLAN.md 3.6): 'pending' | 'have' | 'frozen'.
--
--   have    bought or already at home (what `checked` meant so far)
--   frozen  not bought because it is in the freezer (creates a frozen_items row, migration …10)
--
-- `checked` stays for old app builds and always equals (status <> 'pending'):
--   * a write that changes status sets checked from it;
--   * a write that only changes checked (old clients) sets status to 'have' / 'pending'.
-- In apply_mutations, status belongs to the field-level LWW group resolved by checked_at.

alter table public.shopping_entries add column status text not null default 'pending';
alter table public.shopping_entries
  add constraint shopping_entries_status_check check (status in ('pending', 'have', 'frozen'));
alter table public.shopping_entry_items add column status text not null default 'pending';
alter table public.shopping_entry_items
  add constraint shopping_entry_items_status_check check (status in ('pending', 'have', 'frozen'));

-- Backfill (goes through the sync triggers so devices pull the new column).
update public.shopping_entries set status = 'have' where checked and status = 'pending';
update public.shopping_entry_items set status = 'have' where checked and status = 'pending';

create or replace function private.sync_shopping_status()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'pending' then
      new.checked := true;
    elsif new.checked then
      new.status := 'have';
    end if;
  elsif new.status is distinct from old.status then
    new.checked := new.status <> 'pending';
  elsif new.checked is distinct from old.checked then
    new.status := case when new.checked then 'have' else 'pending' end;
  end if;
  return new;
end;
$$;

-- BEFORE triggers fire in name order: after t10_sync_row.
create trigger t15_shopping_status before insert or update on public.shopping_entries
  for each row execute function private.sync_shopping_status();
create trigger t15_shopping_status before insert or update on public.shopping_entry_items
  for each row execute function private.sync_shopping_status();

revoke execute on all functions in schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- apply_mutations
-- ---------------------------------------------------------------------------
-- p_mutations: [{ table, id, op: 'upsert' | 'delete', fields: {...}, client_ts }]
-- Returns { applied: [{table, id, server_seq, merged?}], rejected: [{table, id, reason, ...}], cursor }.
--
-- Conflict rules:
--   * Row LWW by client_ts against client_updated_at (ties apply).
--   * shopping_entries / shopping_entry_items: field-level LWW.
--       status/checked/checked_at resolved by checked_at (defaults to client_ts); status and
--                                 checked are kept consistent by private.sync_shopping_status()
--       text/quantity/unit        resolved by name_updated_at (shopping_entries only)
--       any other field           row LWW by client_ts
--   * frozen_items is server-maintained: clients may only update resolved_at ("Hecho"); other
--     fields are ignored, inserts and deletes are rejected as 'forbidden'.
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
  v_check_cols constant text[] := array['checked', 'checked_at', 'status'];
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

      if v_table = 'frozen_items' and (v_op = 'delete' or v_existing is null) then
        v_rejected := v_rejected || jsonb_build_object('table', v_table, 'id', v_id, 'reason', 'forbidden');
        continue;
      end if;

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
        and (not (f.key = any (v_server_cols)) or (f.key = 'household_id' and v_existing is null))
        and (v_table <> 'frozen_items' or f.key = 'resolved_at');

      if v_existing is null then
        -- Insert. Fill server-side defaults for the field-level LWW timestamps.
        if v_table in ('shopping_entries', 'shopping_entry_items') then
          if not v_clean ? 'checked_at'
            and (coalesce((v_clean ->> 'checked')::boolean, false) or coalesce(v_clean ->> 'status', 'pending') <> 'pending') then
            v_clean := v_clean || jsonb_build_object('checked_at', v_ts);
          end if;
          if v_table = 'shopping_entries' then
            if coalesce((v_clean ->> 'checked')::boolean, false) or coalesce(v_clean ->> 'status', 'pending') <> 'pending' then
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
        -- status/checked group, resolved by checked_at
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

revoke execute on function public.apply_mutations(uuid, jsonb) from public, anon;
grant execute on function public.apply_mutations(uuid, jsonb) to authenticated, service_role;
