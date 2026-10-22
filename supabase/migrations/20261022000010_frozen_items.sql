-- Frozen products and defrost reminders (PLAN.md 3.6).
--
-- frozen_items (synced, server-maintained; clients only set resolved_at with the "Hecho" button):
--   product_id              what is in the freezer
--   shopping_entry_id       source product entry (kind = 'product'), or
--   shopping_entry_item_id  source item of a recipe entry (exactly one of the two is set)
--   meal_plan_entry_id      meal it is frozen for (null = no planned meal uses it yet)
--   frozen_at               when it was marked as frozen
--   defrost_remind_at       meal time (household timezone) − 24 h; null when unlinked
--   reminded_at             when the visible "defrost" push was enqueued
--   resolved_at             set by the app ("Hecho"); resolved rows are never touched again
--
-- Lifecycle (AFTER triggers):
--   * shopping entry/item status → 'frozen' creates (or revives the last tombstone of) one live
--     frozen_items row for that source; status leaving 'frozen' tombstones it unless resolved.
--     Tombstoning the shopping entry itself keeps the frozen item (it is still in the freezer).
--   * Linking: the source's planning entry (items: the parent entry's meal_plan_entry_id) or else the
--     next live, accepted, non-skipped planning entry within 14 days (household timezone, meal time
--     still ahead) whose recipe tree uses the product; earliest meal time first.
--   * Recomputed when the linked entry changes date/slot/scheduled_time/recipe, is tombstoned,
--     skipped or moved back to a draft (relinks), when a new entry is planned (links unlinked items)
--     and when the household slot times or timezone change. reminded_at is reset when the reminder
--     moves to a later time.
--
-- public.due_defrost_reminders() (pg_cron, every 15 minutes) enqueues a visible push_queue row with
-- kind = 'defrost' for every due reminder and sets reminded_at.

-- Composite FK target for frozen_items.
alter table public.shopping_entry_items
  add constraint shopping_entry_items_id_household_id_key unique (id, household_id);

create table public.frozen_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  product_id uuid not null,
  shopping_entry_id uuid,
  shopping_entry_item_id uuid,
  meal_plan_entry_id uuid,
  frozen_at timestamptz not null default now(),
  defrost_remind_at timestamptz,
  reminded_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users (id) on delete set null,
  deleted_at timestamptz,
  client_updated_at timestamptz,
  server_seq bigint not null default 0,
  unique (id, household_id),
  foreign key (product_id, household_id) references public.products (id, household_id) on delete cascade,
  foreign key (shopping_entry_id, household_id) references public.shopping_entries (id, household_id)
    on delete set null (shopping_entry_id),
  foreign key (shopping_entry_item_id, household_id) references public.shopping_entry_items (id, household_id)
    on delete set null (shopping_entry_item_id),
  foreign key (meal_plan_entry_id, household_id) references public.meal_plan_entries (id, household_id)
    on delete set null (meal_plan_entry_id)
);

create trigger t10_sync_row before insert or update on public.frozen_items
  for each row execute function private.sync_row();
create index frozen_items_household_id_idx on public.frozen_items (household_id);
create index frozen_items_server_seq_idx on public.frozen_items (server_seq);
create index frozen_items_deleted_at_idx on public.frozen_items (deleted_at) where deleted_at is not null;
create index frozen_items_product_id_idx on public.frozen_items (product_id);
create index frozen_items_meal_plan_entry_id_idx on public.frozen_items (meal_plan_entry_id);
create index frozen_items_shopping_entry_item_id_idx on public.frozen_items (shopping_entry_item_id);
-- One open (live, unresolved) frozen item per source.
create unique index frozen_items_open_entry_unique on public.frozen_items (shopping_entry_id)
  where shopping_entry_id is not null and deleted_at is null and resolved_at is null;
create unique index frozen_items_open_item_unique on public.frozen_items (shopping_entry_item_id)
  where shopping_entry_item_id is not null and deleted_at is null and resolved_at is null;
create index frozen_items_due_idx on public.frozen_items (defrost_remind_at)
  where deleted_at is null and resolved_at is null and reminded_at is null;

create trigger t90_enqueue_push after insert or update on public.frozen_items
  for each row execute function private.enqueue_sync_push('shopping');
create trigger t34_tombstone_frozen_items after update of deleted_at on public.products
  for each row execute function private.cascade_tombstone('frozen_items', 'product_id');

-- RLS: members read; the only client write is resolved_at (through apply_mutations).
alter table public.frozen_items enable row level security;
create policy frozen_items_select on public.frozen_items for select to authenticated
  using (household_id in (select public.household_ids_for_user()));
create policy frozen_items_update on public.frozen_items for update to authenticated
  using (household_id in (select public.household_ids_for_user()))
  with check (household_id in (select public.household_ids_for_user()));
revoke all on public.frozen_items from anon, authenticated;
grant select on public.frozen_items to authenticated;
grant update (resolved_at, client_updated_at) on public.frozen_items to authenticated;

-- ---------------------------------------------------------------------------
-- Synced table list, pull and purge
-- ---------------------------------------------------------------------------
create or replace function public.synced_tables()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
    'stores', 'products', 'product_stores', 'recipes', 'recipe_ingredients', 'recipe_components',
    'meal_plan_drafts', 'meal_plan_entries', 'consumptions', 'shopping_entries', 'shopping_entry_items',
    'frozen_items'
  ]::text[];
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
    union all
    select 'frozen_items', x.server_seq, to_jsonb(x) from public.frozen_items x where x.server_seq > v_cursor
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

-- ---------------------------------------------------------------------------
-- Tombstone purge (keepalive)
-- ---------------------------------------------------------------------------
-- Hard-deletes tombstones older than p_older_than (children first), records the purge
-- watermark used by pull_changes.reset_required, trims old push_queue rows and touches the
-- keepalive timestamp. Service role only.
create or replace function public.purge_tombstones(p_older_than interval default interval '30 days')
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_cutoff timestamptz := now() - p_older_than;
  v_table text;
  v_count bigint;
  v_max bigint;
  v_watermark bigint := 0;
  v_counts jsonb := '{}'::jsonb;
  v_queue bigint;
begin
  foreach v_table in array array[
    'frozen_items', 'shopping_entry_items', 'shopping_entries', 'consumptions', 'meal_plan_entries', 'meal_plan_drafts',
    'recipe_components', 'recipe_ingredients', 'recipes', 'product_stores', 'products', 'stores'
  ] loop
    execute format(
      'with d as (delete from public.%I where deleted_at < $1 returning server_seq) select count(*), max(server_seq) from d',
      v_table
    ) into v_count, v_max using v_cutoff;
    v_counts := v_counts || jsonb_build_object(v_table, v_count);
    v_watermark := greatest(v_watermark, coalesce(v_max, 0));
  end loop;

  with d as (delete from public.push_queue where sent_at < now() - interval '7 days' returning 1)
  select count(*) into v_queue from d;

  update private.sync_state
  set purge_watermark = greatest(purge_watermark, v_watermark),
      last_purge_at = now(),
      keepalive_at = now()
  where id;

  return jsonb_build_object(
    'purged', v_counts,
    'push_queue_trimmed', v_queue,
    'watermark', public.sync_purge_watermark(),
    'at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Linking helpers
-- ---------------------------------------------------------------------------
-- Whether the recipe tree (sub-recipes included) uses the product.
create or replace function private.recipe_uses_product(p_recipe_id uuid, p_product_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.recipe_flat_ingredients(p_recipe_id) f where f.product_id = p_product_id
  );
$$;

-- Whether a planning entry can be the meal of a frozen product.
create or replace function private.frozen_link_valid(p_entry_id uuid, p_product_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.meal_plan_entries e
    where e.id = p_entry_id
      and e.deleted_at is null
      and e.draft_id is null
      and e.skipped_at is null
      and e.recipe_id is not null
      and private.recipe_uses_product(e.recipe_id, p_product_id)
  );
$$;

-- Validates/relinks one open frozen item and recomputes defrost_remind_at. Writes only on change.
create or replace function private.refresh_frozen_item(p_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_item public.frozen_items;
  v_household public.households;
  v_entry uuid;
  v_remind timestamptz;
  v_today date;
begin
  select * into v_item from public.frozen_items f where f.id = p_id for update;
  if not found or v_item.deleted_at is not null or v_item.resolved_at is not null then
    return;
  end if;
  select * into v_household from public.households h where h.id = v_item.household_id;

  v_entry := v_item.meal_plan_entry_id;
  if v_entry is not null and not private.frozen_link_valid(v_entry, v_item.product_id) then
    v_entry := null;
  end if;

  if v_entry is null then
    v_today := (now() at time zone v_household.timezone)::date;
    select e.id into v_entry
    from public.meal_plan_entries e
    where e.household_id = v_item.household_id
      and e.deleted_at is null
      and e.draft_id is null
      and e.skipped_at is null
      and e.recipe_id is not null
      and e.date between v_today and v_today + 14
      and private.meal_starts_at(e.date, e.slot, e.scheduled_time, v_household.slot_times, v_household.timezone) > now()
      and private.recipe_uses_product(e.recipe_id, v_item.product_id)
    order by private.meal_starts_at(e.date, e.slot, e.scheduled_time, v_household.slot_times, v_household.timezone),
             e.position, e.id
    limit 1;
  end if;

  if v_entry is not null then
    select private.meal_starts_at(e.date, e.slot, e.scheduled_time, v_household.slot_times, v_household.timezone)
           - interval '24 hours'
    into v_remind
    from public.meal_plan_entries e
    where e.id = v_entry;
  end if;

  if v_entry is distinct from v_item.meal_plan_entry_id or v_remind is distinct from v_item.defrost_remind_at then
    update public.frozen_items f
    set meal_plan_entry_id = v_entry,
        defrost_remind_at = v_remind,
        reminded_at = case
          when v_remind is not null and (v_item.defrost_remind_at is null or v_remind > v_item.defrost_remind_at)
            then null
          else f.reminded_at
        end
    where f.id = p_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Shopping list → frozen_items
-- ---------------------------------------------------------------------------
create or replace function private.frozen_from_shopping()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_is_item boolean := tg_table_name = 'shopping_entry_items';
  v_entry_id uuid;
  v_item_id uuid;
  v_meal uuid;
  v_id uuid;
begin
  if v_is_item then
    v_item_id := new.id;
  else
    if new.kind <> 'product' then
      return null;
    end if;
    v_entry_id := new.id;
  end if;

  if new.status = 'frozen' and new.deleted_at is null and (tg_op = 'INSERT' or old.status <> 'frozen') then
    perform private.sync_lock();
    select f.id into v_id from public.frozen_items f
    where f.deleted_at is null and f.resolved_at is null
      and (f.shopping_entry_id = v_entry_id or f.shopping_entry_item_id = v_item_id);
    if found then
      return null;
    end if;

    if v_is_item then
      select s.meal_plan_entry_id into v_meal from public.shopping_entries s where s.id = new.entry_id;
    else
      v_meal := new.meal_plan_entry_id;
    end if;

    select f.id into v_id from public.frozen_items f
    where f.deleted_at is not null
      and (f.shopping_entry_id = v_entry_id or f.shopping_entry_item_id = v_item_id)
    order by f.deleted_at desc
    limit 1;

    if found then
      update public.frozen_items f
      set deleted_at = null, resolved_at = null, reminded_at = null, defrost_remind_at = null,
          frozen_at = now(), product_id = new.product_id, meal_plan_entry_id = v_meal
      where f.id = v_id;
    else
      v_id := gen_random_uuid();
      insert into public.frozen_items (
        id, household_id, product_id, shopping_entry_id, shopping_entry_item_id, meal_plan_entry_id
      ) values (v_id, new.household_id, new.product_id, v_entry_id, v_item_id, v_meal);
    end if;
    perform private.refresh_frozen_item(v_id);
  elsif tg_op = 'UPDATE' and old.status = 'frozen' and new.status <> 'frozen' then
    update public.frozen_items f
    set deleted_at = now()
    where f.deleted_at is null and f.resolved_at is null
      and (f.shopping_entry_id = v_entry_id or f.shopping_entry_item_id = v_item_id);
  end if;
  return null;
end;
$$;

create trigger t40_frozen_items after insert or update on public.shopping_entries
  for each row execute function private.frozen_from_shopping();
create trigger t40_frozen_items after insert or update on public.shopping_entry_items
  for each row execute function private.frozen_from_shopping();

-- ---------------------------------------------------------------------------
-- Planning → frozen_items
-- ---------------------------------------------------------------------------
create or replace function private.frozen_from_meal_plan()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if tg_op = 'UPDATE' then
    for v_id in
      select f.id from public.frozen_items f
      where f.meal_plan_entry_id = new.id and f.deleted_at is null and f.resolved_at is null
    loop
      perform private.refresh_frozen_item(v_id);
    end loop;
  end if;

  if new.deleted_at is null and new.draft_id is null and new.skipped_at is null and new.recipe_id is not null then
    for v_id in
      select f.id from public.frozen_items f
      where f.household_id = new.household_id and f.meal_plan_entry_id is null
        and f.deleted_at is null and f.resolved_at is null
    loop
      perform private.refresh_frozen_item(v_id);
    end loop;
  end if;
  return null;
end;
$$;

create trigger t40_frozen_items
  after insert or update of date, slot, scheduled_time, recipe_id, deleted_at, skipped_at, draft_id
  on public.meal_plan_entries
  for each row execute function private.frozen_from_meal_plan();

-- Slot times or timezone changed: every open frozen item of the household gets a new reminder time.
create or replace function private.frozen_from_household()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if new.slot_times is distinct from old.slot_times or new.timezone is distinct from old.timezone then
    for v_id in
      select f.id from public.frozen_items f
      where f.household_id = new.id and f.deleted_at is null and f.resolved_at is null
    loop
      perform private.refresh_frozen_item(v_id);
    end loop;
  end if;
  return null;
end;
$$;

create trigger t40_frozen_items after update of slot_times, timezone on public.households
  for each row execute function private.frozen_from_household();

-- ---------------------------------------------------------------------------
-- push_queue: visible notifications next to the per-transaction sync rows
-- ---------------------------------------------------------------------------
-- kind = 'sync'    one row per (household, transaction), merged by enqueue_sync_push (silent push)
-- kind = 'defrost' one row per reminder; dedupe_key = 'defrost:<frozen_item_id>:<remind epoch>'
alter table public.push_queue add column dedupe_key text;
drop index public.push_queue_household_txid_idx;
create unique index push_queue_household_txid_idx on public.push_queue (household_id, txid) where kind = 'sync';
create unique index push_queue_dedupe_key_idx on public.push_queue (dedupe_key) where dedupe_key is not null;

create or replace function private.enqueue_sync_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.push_queue (household_id, actor_user_id, actor_device_id, kind, payload)
  values (
    new.household_id,
    auth.uid(),
    nullif(current_setting('koda.device_id', true), '')::uuid,
    'sync',
    jsonb_build_object('reasons', jsonb_build_array(tg_argv[0]), 'cursor', new.server_seq)
  )
  on conflict (household_id, txid) where kind = 'sync' do update set
    payload = jsonb_build_object(
      'reasons', (
        select jsonb_agg(distinct r.value)
        from jsonb_array_elements_text(
          coalesce(public.push_queue.payload -> 'reasons', '[]'::jsonb) || (excluded.payload -> 'reasons')
        ) r
      ),
      'cursor', greatest(
        (public.push_queue.payload ->> 'cursor')::bigint,
        (excluded.payload ->> 'cursor')::bigint
      )
    ),
    actor_user_id = coalesce(public.push_queue.actor_user_id, excluded.actor_user_id),
    actor_device_id = coalesce(public.push_queue.actor_device_id, excluded.actor_device_id);
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- due_defrost_reminders
-- ---------------------------------------------------------------------------
-- Enqueues one visible 'defrost' push per open frozen item whose reminder is due (not older than
-- 12 hours) and sets reminded_at. Idempotent (reminded_at + push_queue.dedupe_key). Returns the number
-- of queued notifications. Service role only.
-- payload: { title, body, frozen_item_id, product_id, meal_plan_entry_id, recipe_id }
create or replace function public.due_defrost_reminders()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_row record;
  v_meal_at timestamptz;
  v_today date;
  v_day text;
  v_inserted integer;
  v_count integer := 0;
begin
  perform private.sync_lock();
  for v_row in
    select f.id, f.household_id, f.product_id, f.meal_plan_entry_id, f.defrost_remind_at,
           p.name as product_name, e.recipe_id, e.date, e.slot, e.scheduled_time,
           r.name as recipe_name, h.timezone, h.slot_times
    from public.frozen_items f
    join public.products p on p.id = f.product_id
    join public.meal_plan_entries e on e.id = f.meal_plan_entry_id and e.deleted_at is null
    join public.recipes r on r.id = e.recipe_id
    join public.households h on h.id = f.household_id
    where f.deleted_at is null
      and f.resolved_at is null
      and f.reminded_at is null
      and f.defrost_remind_at <= now()
      and f.defrost_remind_at > now() - interval '12 hours'
    order by f.defrost_remind_at, f.id
    for update of f skip locked
  loop
    v_meal_at := private.meal_starts_at(v_row.date, v_row.slot, v_row.scheduled_time, v_row.slot_times, v_row.timezone);
    v_today := (now() at time zone v_row.timezone)::date;
    v_day := case
      when v_row.date <= v_today then 'Hoy'
      when v_row.date = v_today + 1 then 'Mañana'
      else 'El ' || (array['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'])[
        extract(isodow from v_row.date)::int]
    end;

    insert into public.push_queue (household_id, kind, payload, dedupe_key)
    values (
      v_row.household_id,
      'defrost',
      jsonb_build_object(
        'title', 'Descongela ' || lower(v_row.product_name),
        'body', format('%s a las %s toca %s', v_day,
                       to_char(v_meal_at at time zone v_row.timezone, 'HH24:MI'), v_row.recipe_name),
        'frozen_item_id', v_row.id,
        'product_id', v_row.product_id,
        'meal_plan_entry_id', v_row.meal_plan_entry_id,
        'recipe_id', v_row.recipe_id
      ),
      format('defrost:%s:%s', v_row.id, extract(epoch from v_row.defrost_remind_at)::bigint)
    )
    on conflict (dedupe_key) where dedupe_key is not null do nothing;
    get diagnostics v_inserted = row_count;

    update public.frozen_items f set reminded_at = now() where f.id = v_row.id;
    v_count := v_count + v_inserted;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.due_defrost_reminders() from public, anon, authenticated;
grant execute on function public.due_defrost_reminders() to service_role;
revoke execute on all functions in schema private from public, anon, authenticated;

select cron.schedule('koda-defrost-reminders', '*/15 * * * *', $$select public.due_defrost_reminders()$$);
