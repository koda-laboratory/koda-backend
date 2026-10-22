-- auto_log_consumptions: due entries, skip rules, idempotence, live uniqueness per entry, cron job.
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'h1@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name, timezone) values ('d1000000-0000-4000-8000-000000000001', 'House one', 'UTC');
insert into public.household_members (household_id, user_id, role) values
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'owner');
insert into public.recipes (id, household_id, name) values
  ('a1000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Lentejas');
insert into public.meal_plan_drafts (id, household_id, from_date, to_date) values
  ('a2000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', current_date - 7, current_date + 7);

create temporary table d (today date);
insert into d select (now() at time zone 'UTC')::date;

-- e1 yesterday (due), e2 today with scheduled_time 00:00 (due), e3 tomorrow, e4 five days ago,
-- e5 skipped, e6 draft, e7 free text, e8 already had a (tombstoned) consumption, e9 tombstone.
insert into public.meal_plan_entries (id, household_id, date, slot, recipe_id, free_text, servings, scheduled_time, skipped_at, draft_id, deleted_at)
select v.id::uuid, 'd1000000-0000-4000-8000-000000000001', d.today + v.off, v.slot::public.meal_slot,
       case when v.free then null else 'a1000000-0000-4000-8000-000000000001'::uuid end,
       case when v.free then 'Comemos fuera' end, 2, v.at::time, v.skipped, v.draft::uuid, v.deleted
from d, (values
  ('e0000000-0000-4000-8000-000000000001', -1, 'lunch', false, null, null::timestamptz, null, null::timestamptz),
  ('e0000000-0000-4000-8000-000000000002', 0, 'dinner', false, '00:00', null, null, null),
  ('e0000000-0000-4000-8000-000000000003', 1, 'lunch', false, null, null, null, null),
  ('e0000000-0000-4000-8000-000000000004', -5, 'lunch', false, null, null, null, null),
  ('e0000000-0000-4000-8000-000000000005', -1, 'dinner', false, null, now(), null, null),
  ('e0000000-0000-4000-8000-000000000006', -1, 'snack', false, null, null, 'a2000000-0000-4000-8000-000000000001', null),
  ('e0000000-0000-4000-8000-000000000007', -1, 'breakfast', true, null, null, null, null),
  ('e0000000-0000-4000-8000-000000000008', -2, 'lunch', false, null, null, null, null),
  ('e0000000-0000-4000-8000-000000000009', -2, 'dinner', false, null, null, null, now())
) as v (id, off, slot, free, at, skipped, draft, deleted);

insert into public.consumptions (household_id, recipe_id, eaten_on, slot, meal_plan_entry_id, deleted_at)
select 'd1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', d.today - 2, 'lunch',
       'e0000000-0000-4000-8000-000000000008', now()
from d;

delete from public.push_queue;

select cmp_ok(public.auto_log_consumptions(), '>=', 2, 'the first run logs the due entries');
select is(
  (select count(*)::int from public.consumptions
   where household_id = 'd1000000-0000-4000-8000-000000000001' and source = 'auto'),
  2, 'only due entries of the household are logged');
select results_eq(
  $$select meal_plan_entry_id::text from public.consumptions
    where household_id = 'd1000000-0000-4000-8000-000000000001' and source = 'auto' order by 1$$,
  $$values ('e0000000-0000-4000-8000-000000000001'), ('e0000000-0000-4000-8000-000000000002')$$,
  'yesterday and today-with-scheduled_time-in-the-past are logged; skipped, draft, free text, future, old, tombstoned and previously logged entries are not'
);
select results_eq(
  $$select c.eaten_on = e.date, c.slot = e.slot, c.servings, c.logged_by, c.recipe_id::text, c.deleted_at is null
    from public.consumptions c join public.meal_plan_entries e on e.id = c.meal_plan_entry_id
    where c.meal_plan_entry_id = 'e0000000-0000-4000-8000-000000000001'$$,
  $$values (true, true, 2::numeric, null::uuid, 'a1000000-0000-4000-8000-000000000001', true)$$,
  'the consumption copies date, slot, servings and recipe; logged_by is null'
);
select is(public.auto_log_consumptions(), 0, 'a second run is a no-op (idempotent)');
select ok(
  (select server_seq > 0 from public.consumptions where meal_plan_entry_id = 'e0000000-0000-4000-8000-000000000001'),
  'auto consumptions go through the sync trigger'
);
select results_eq(
  $$select kind, actor_device_id, payload -> 'reasons' ? 'planning' from public.push_queue
    where household_id = 'd1000000-0000-4000-8000-000000000001'$$,
  $$values ('sync'::text, null::uuid, true)$$,
  'a silent sync push is enqueued for every device (no actor)'
);

-- A tombstoned auto consumption ("no lo comimos") is not re-created.
update public.consumptions set deleted_at = now() where meal_plan_entry_id = 'e0000000-0000-4000-8000-000000000002';
select is(public.auto_log_consumptions(), 0, 'a tombstoned consumption is never re-created');

-- Moving an entry into the past makes it due on the next run.
update public.meal_plan_entries set date = (select today - 1 from d) where id = 'e0000000-0000-4000-8000-000000000003';
select is(public.auto_log_consumptions(), 1, 'an entry moved into the past is logged on the next run');

-- Defaults and uniqueness.
select is(
  (select source from public.consumptions where meal_plan_entry_id = 'e0000000-0000-4000-8000-000000000008'),
  'manual', 'source defaults to manual');
select throws_ok(
  $$insert into public.consumptions (household_id, recipe_id, eaten_on, source) values
    ('d1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', current_date, 'robot')$$,
  '23514', null, 'source is limited to auto|manual|siri|mcp');
select throws_ok(
  $$insert into public.consumptions (household_id, recipe_id, eaten_on, meal_plan_entry_id) values
    ('d1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', current_date, 'e0000000-0000-4000-8000-000000000001')$$,
  '23505', null, 'only one live consumption per planning entry');
select lives_ok(
  $$insert into public.consumptions (household_id, recipe_id, eaten_on, meal_plan_entry_id, source) values
    ('d1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', current_date, 'e0000000-0000-4000-8000-000000000002', 'siri')$$,
  'a new live consumption is allowed when the previous one is a tombstone');

set local role authenticated;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';
select is(
  public.apply_mutations(null, $$[
    {"table":"consumptions","id":"e1000000-0000-4000-8000-0000000000aa","op":"upsert","client_ts":"2026-01-01T10:00:00Z",
     "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","recipe_id":"a1000000-0000-4000-8000-000000000001",
               "eaten_on":"2026-01-01","meal_plan_entry_id":"e0000000-0000-4000-8000-000000000001","source":"manual"}}
  ]$$::jsonb) -> 'rejected' -> 0 ->> 'reason',
  'conflict',
  'a client consumption for an already logged entry is rejected as conflict'
);
select throws_ok($$select public.auto_log_consumptions()$$, '42501', null, 'users cannot run auto_log_consumptions');
reset role;

select is(
  (select schedule from cron.job where jobname = 'koda-auto-log-consumptions'),
  '*/15 * * * *',
  'pg_cron runs auto_log_consumptions every 15 minutes'
);

select * from finish();
rollback;
