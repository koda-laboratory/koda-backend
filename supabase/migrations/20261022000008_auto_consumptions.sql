-- Meals that log themselves (PLAN.md 3.6).
--
--   meal_plan_entries.scheduled_time  local time of this entry; overrides households.slot_times[slot]
--   meal_plan_entries.skipped_at      "No lo comimos": the entry is never auto-logged
--   consumptions.source               'auto' (pg_cron), 'manual' (app), 'siri', 'mcp'
--
-- public.auto_log_consumptions() (pg_cron, every 15 minutes) creates the consumption of every planned
-- recipe whose date + time has passed in the household timezone.

alter table public.meal_plan_entries
  add column scheduled_time time,
  add column skipped_at timestamptz;

alter table public.consumptions
  add column source text not null default 'manual';
alter table public.consumptions
  add constraint consumptions_source_check check (source in ('auto', 'manual', 'siri', 'mcp'));

-- At most one live consumption per planning entry. Defensive clean-up before the index: later live
-- duplicates (if any) become tombstones, the earliest one is kept.
update public.consumptions c
set deleted_at = now()
where c.meal_plan_entry_id is not null
  and c.deleted_at is null
  and exists (
    select 1 from public.consumptions o
    where o.meal_plan_entry_id = c.meal_plan_entry_id
      and o.deleted_at is null
      and (o.created_at, o.id) < (c.created_at, c.id)
  );

create unique index consumptions_meal_plan_entry_live_unique on public.consumptions (meal_plan_entry_id)
  where meal_plan_entry_id is not null and deleted_at is null;

-- ---------------------------------------------------------------------------
-- Meal time helper
-- ---------------------------------------------------------------------------
-- Absolute instant of a planned meal: entry date + (scheduled_time, else the household slot time)
-- interpreted in the household timezone (DST-aware).
create or replace function private.meal_starts_at(
  p_date date,
  p_slot public.meal_slot,
  p_scheduled_time time,
  p_slot_times jsonb,
  p_timezone text
)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select (
    p_date + coalesce(
      p_scheduled_time,
      (p_slot_times ->> p_slot::text)::time,
      ('{"breakfast":"09:00","lunch":"14:30","snack":"18:00","dinner":"21:30"}'::jsonb ->> p_slot::text)::time
    )
  ) at time zone p_timezone;
$$;

-- ---------------------------------------------------------------------------
-- auto_log_consumptions
-- ---------------------------------------------------------------------------
-- For every live, accepted (non-draft), non-skipped planning entry with a recipe whose meal time has
-- passed (looking back at most 3 days) and that has never had a consumption (live or tombstone),
-- inserts one consumption with source 'auto'. Idempotent; concurrent runs are stopped by the unique
-- index. Writes go through the sync triggers, so devices receive a silent push. Service role only.
create or replace function public.auto_log_consumptions()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  perform private.sync_lock();

  insert into public.consumptions (
    household_id, recipe_id, eaten_on, slot, servings, meal_plan_entry_id, logged_by, source
  )
  select e.household_id, e.recipe_id, e.date, e.slot, e.servings, e.id, null, 'auto'
  from public.meal_plan_entries e
  join public.households h on h.id = e.household_id
  join public.recipes r on r.id = e.recipe_id and r.deleted_at is null
  where e.deleted_at is null
    and e.draft_id is null
    and e.skipped_at is null
    and e.recipe_id is not null
    and e.date >= (now() at time zone h.timezone)::date - 3
    and e.date <= (now() at time zone h.timezone)::date
    and private.meal_starts_at(e.date, e.slot, e.scheduled_time, h.slot_times, h.timezone) <= now()
    and not exists (select 1 from public.consumptions c where c.meal_plan_entry_id = e.id)
  order by e.date, e.slot, e.position
  on conflict (meal_plan_entry_id) where meal_plan_entry_id is not null and deleted_at is null do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.auto_log_consumptions() from public, anon, authenticated;
grant execute on function public.auto_log_consumptions() to service_role;
revoke execute on all functions in schema private from public, anon, authenticated;

select cron.schedule('koda-auto-log-consumptions', '*/15 * * * *', $$select public.auto_log_consumptions()$$);
