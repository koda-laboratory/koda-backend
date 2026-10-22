-- due_defrost_reminders: due/stale/resolved selection, Spanish copy, payload, idempotence, dedupe.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'h1@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name, timezone) values ('d1000000-0000-4000-8000-000000000001', 'House one', 'UTC');
insert into public.household_members (household_id, user_id, role) values
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'owner');
insert into public.products (id, household_id, name) values
  ('a1000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Carrilleras'),
  ('a1000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'Guisantes');
insert into public.recipes (id, household_id, name) values
  ('b1000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Paella de carrilleras');
insert into public.recipe_ingredients (household_id, recipe_id, product_id) values
  ('d1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001'),
  ('d1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000002');

-- Meals at now + N hours (minute precision): m1 +20 h (due), m2 +50 h (not yet), m3 +10 h (reminder
-- 14 h old: stale), m4 +22 h (due), m5 +20 h (resolved).
insert into public.meal_plan_entries (id, household_id, date, slot, recipe_id, scheduled_time)
select v.id::uuid, 'd1000000-0000-4000-8000-000000000001',
       ((now() + make_interval(hours => v.h)) at time zone 'UTC')::date, 'lunch',
       'b1000000-0000-4000-8000-000000000001',
       date_trunc('minute', (now() + make_interval(hours => v.h)) at time zone 'UTC')::time
from (values
  ('e0000000-0000-4000-8000-000000000001', 20), ('e0000000-0000-4000-8000-000000000002', 50),
  ('e0000000-0000-4000-8000-000000000003', 10), ('e0000000-0000-4000-8000-000000000004', 22),
  ('e0000000-0000-4000-8000-000000000005', 20)
) as v (id, h);

-- One frozen product entry per meal (the entry's meal_plan_entry_id is the link).
insert into public.shopping_entries (id, household_id, kind, product_id, meal_plan_entry_id, status)
select ('5e000000-0000-4000-8000-00000000000' || g)::uuid, 'd1000000-0000-4000-8000-000000000001', 'product',
       case when g = 4 then 'a1000000-0000-4000-8000-000000000002' else 'a1000000-0000-4000-8000-000000000001' end::uuid,
       ('e0000000-0000-4000-8000-00000000000' || g)::uuid, 'frozen'
from generate_series(1, 5) g;
update public.frozen_items set resolved_at = now() where meal_plan_entry_id = 'e0000000-0000-4000-8000-000000000005';

create temporary table fi as
  select f.id, right(f.meal_plan_entry_id::text, 1)::int as n from public.frozen_items f
  where f.household_id = 'd1000000-0000-4000-8000-000000000001';

delete from public.push_queue;

select is(public.due_defrost_reminders(), 2, 'two reminders are due (stale, future and resolved ones are skipped)');
select results_eq(
  $$select fi.n, f.reminded_at is not null from public.frozen_items f join fi using (id) order by fi.n$$,
  $$values (1, true), (2, false), (3, false), (4, true), (5, false)$$,
  'reminded_at is set only on the reminded items'
);
select is(
  (select count(*)::int from public.push_queue where kind = 'defrost'),
  2, 'several reminders of one household in one transaction are all enqueued'
);
select results_eq(
  $$select q.payload ->> 'title', q.payload ->> 'body', q.payload ->> 'product_id', q.payload ->> 'meal_plan_entry_id',
           q.payload ->> 'recipe_id', q.actor_device_id, q.sent_at
    from public.push_queue q join fi on fi.id::text = q.payload ->> 'frozen_item_id'
    where q.kind = 'defrost' and fi.n = 1$$,
  $$select 'Descongela carrilleras',
           format('%s a las %s toca Paella de carrilleras',
                  case when e.date = (now() at time zone 'UTC')::date then 'Hoy' else 'Mañana' end,
                  to_char(e.scheduled_time, 'HH24:MI')),
           'a1000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000001',
           'b1000000-0000-4000-8000-000000000001', null::uuid, null::timestamptz
    from public.meal_plan_entries e where e.id = 'e0000000-0000-4000-8000-000000000001'$$,
  'payload: Spanish title/body (product lowercased, Hoy/Mañana + meal time + recipe) and ids'
);
select is(
  (select q.dedupe_key from public.push_queue q join fi on fi.id::text = q.payload ->> 'frozen_item_id' where fi.n = 1),
  (select format('defrost:%s:%s', f.id, extract(epoch from f.defrost_remind_at)::bigint)
   from public.frozen_items f join fi using (id) where fi.n = 1),
  'dedupe_key = defrost:<frozen_item_id>:<remind epoch>'
);
select is(
  (select count(*)::int from public.push_queue where kind = 'sync' and household_id = 'd1000000-0000-4000-8000-000000000001'),
  1, 'the reminded_at updates also enqueue the silent sync row'
);

select is(public.due_defrost_reminders(), 0, 'a second run sends nothing (idempotent)');

-- The same reminder cannot be enqueued twice even if reminded_at is cleared by hand.
update public.frozen_items set reminded_at = null where id = (select id from fi where n = 1);
select is(public.due_defrost_reminders(), 0, 'a reminder already in the queue is not counted again');
select is((select count(*)::int from public.push_queue where kind = 'defrost'), 2, 'dedupe_key blocks duplicates');

-- Moving the meal later resets reminded_at; the new reminder is a new notification.
update public.meal_plan_entries set scheduled_time = scheduled_time + interval '1 hour'
where id = 'e0000000-0000-4000-8000-000000000001';
select is((select f.reminded_at from public.frozen_items f join fi using (id) where fi.n = 1), null,
  'a later reminder resets reminded_at');
select is(public.due_defrost_reminders(), 1, 'the moved meal is reminded again');
select is((select count(*)::int from public.push_queue where kind = 'defrost'), 3, 'with a new queue row');

set local role authenticated;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';
select throws_ok($$select public.due_defrost_reminders()$$, '42501', null, 'users cannot run due_defrost_reminders');
reset role;

select is(
  (select schedule from cron.job where jobname = 'koda-defrost-reminders'),
  '*/15 * * * *',
  'pg_cron runs due_defrost_reminders every 15 minutes'
);

select * from finish();
rollback;
