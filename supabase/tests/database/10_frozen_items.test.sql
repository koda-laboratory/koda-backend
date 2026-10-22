-- frozen_items: lifecycle from the shopping list, linking/relinking to planned meals, reminder time
-- math (DST included), client write restrictions, RLS and sync plumbing.
begin;
create extension if not exists pgtap with schema extensions;
select plan(40);

insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'h1@koda.test', 'authenticated', 'authenticated'),
  ('c2000000-0000-4000-8000-000000000002', 'h2@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name, timezone) values
  ('d1000000-0000-4000-8000-000000000001', 'House one', 'UTC'),
  ('d2000000-0000-4000-8000-000000000002', 'House two', 'UTC');
insert into public.household_members (household_id, user_id, role) values
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'owner'),
  ('d2000000-0000-4000-8000-000000000002', 'c2000000-0000-4000-8000-000000000002', 'owner');

-- Products: carrilleras (used by a sub-recipe of the paella), arroz (used by "Arroz blanco").
insert into public.products (id, household_id, name) values
  ('a1000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Carrilleras'),
  ('a1000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'Arroz');
insert into public.recipes (id, household_id, name) values
  ('b1000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Paella de carrilleras'),
  ('b1000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'Carrilleras guisadas'),
  ('b1000000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000001', 'Arroz blanco');
insert into public.recipe_components (household_id, parent_recipe_id, child_recipe_id) values
  ('d1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000002');
insert into public.recipe_ingredients (household_id, recipe_id, product_id, quantity, unit) values
  ('d1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000002', 'a1000000-0000-4000-8000-000000000001', 500, 'g'),
  ('d1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000003', 'a1000000-0000-4000-8000-000000000002', 200, 'g');

create temporary table d (today date);
insert into d select (now() at time zone 'UTC')::date;
grant select on d to authenticated;

-- m1: paella in 3 days (lunch), m2: paella in 5 days (dinner), m3: arroz blanco in 2 days (lunch).
insert into public.meal_plan_entries (id, household_id, date, slot, recipe_id)
select v.id::uuid, 'd1000000-0000-4000-8000-000000000001', d.today + v.off, v.slot::public.meal_slot, v.recipe::uuid
from d, (values
  ('e0000000-0000-4000-8000-000000000001', 3, 'lunch', 'b1000000-0000-4000-8000-000000000001'),
  ('e0000000-0000-4000-8000-000000000002', 5, 'dinner', 'b1000000-0000-4000-8000-000000000001'),
  ('e0000000-0000-4000-8000-000000000003', 2, 'lunch', 'b1000000-0000-4000-8000-000000000003')
) as v (id, off, slot, recipe);

-- ----------------------------------------------------------------- reminder time math (DST)
select is(
  private.meal_starts_at('2026-10-25', 'lunch', null, '{"breakfast":"09:00","lunch":"14:30","snack":"18:00","dinner":"21:30"}', 'Europe/Madrid')
    - interval '24 hours',
  '2026-10-24 13:30:00+00'::timestamptz,
  'autumn DST: 14:30 CET on Oct 25 minus 24 h is 15:30 CEST on Oct 24'
);
select is(
  private.meal_starts_at('2027-03-28', 'dinner', '20:00', '{"breakfast":"09:00","lunch":"14:30","snack":"18:00","dinner":"21:30"}', 'Europe/Madrid')
    - interval '24 hours',
  '2027-03-27 18:00:00+00'::timestamptz,
  'spring DST + scheduled_time: 20:00 CEST on Mar 28 minus 24 h is 19:00 CET on Mar 27'
);

-- ----------------------------------------------------------------- freezing a product entry
set local role authenticated;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';

select public.apply_mutations(null, $$[
  {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T10:00:00Z",
   "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","kind":"product","product_id":"a1000000-0000-4000-8000-000000000001","status":"frozen"}}
]$$::jsonb);

create temporary table fi on commit drop as
  select id from public.frozen_items where shopping_entry_id = '5e000000-0000-4000-8000-000000000001';
select is((select count(*)::int from fi), 1, 'status frozen creates one frozen item');
select results_eq(
  $$select f.product_id, f.shopping_entry_item_id, f.meal_plan_entry_id, f.resolved_at, f.reminded_at, f.server_seq > 0
    from public.frozen_items f join fi using (id)$$,
  $$values ('a1000000-0000-4000-8000-000000000001'::uuid, null::uuid, 'e0000000-0000-4000-8000-000000000001'::uuid,
            null::timestamptz, null::timestamptz, true)$$,
  'linked to the next meal whose recipe tree (sub-recipes included) uses the product'
);
select is(
  (select f.defrost_remind_at from public.frozen_items f join fi using (id)),
  (select ((today + 3) + time '14:30') at time zone 'UTC' - interval '24 hours' from d),
  'defrost_remind_at = meal date + slot time − 24 h'
);

update public.shopping_entries set text = 'otra cosa' where id = '5e000000-0000-4000-8000-000000000001';
select is((select count(*)::int from public.frozen_items where shopping_entry_id = '5e000000-0000-4000-8000-000000000001'),
  1, 'unrelated updates do not create more frozen items');

-- ----------------------------------------------------------------- recomputing on planning changes
reset role;
update public.frozen_items set reminded_at = now() where id = (select id from fi);
set local role authenticated;
update public.meal_plan_entries set date = (select today + 4 from d) where id = 'e0000000-0000-4000-8000-000000000001';
select results_eq(
  $$select f.defrost_remind_at, f.reminded_at from public.frozen_items f join fi using (id)$$,
  $$select ((today + 4) + time '14:30') at time zone 'UTC' - interval '24 hours', null::timestamptz from d$$,
  'moving the meal later recomputes the reminder and resets reminded_at'
);

reset role;
update public.frozen_items set reminded_at = now() where id = (select id from fi);
set local role authenticated;
update public.meal_plan_entries set scheduled_time = '13:00' where id = 'e0000000-0000-4000-8000-000000000001';
select results_eq(
  $$select f.defrost_remind_at, f.reminded_at is not null from public.frozen_items f join fi using (id)$$,
  $$select ((today + 4) + time '13:00') at time zone 'UTC' - interval '24 hours', true from d$$,
  'scheduled_time overrides the slot time; an earlier reminder keeps reminded_at'
);

update public.meal_plan_entries set slot = 'dinner', scheduled_time = null where id = 'e0000000-0000-4000-8000-000000000001';
select is(
  (select f.defrost_remind_at from public.frozen_items f join fi using (id)),
  (select ((today + 4) + time '21:30') at time zone 'UTC' - interval '24 hours' from d),
  'changing the slot recomputes the reminder'
);

update public.meal_plan_entries set skipped_at = now() where id = 'e0000000-0000-4000-8000-000000000001';
select results_eq(
  $$select f.meal_plan_entry_id, f.defrost_remind_at from public.frozen_items f join fi using (id)$$,
  $$select 'e0000000-0000-4000-8000-000000000002'::uuid, ((today + 5) + time '21:30') at time zone 'UTC' - interval '24 hours' from d$$,
  'a skipped meal relinks to the next meal that uses the product'
);

update public.meal_plan_entries set deleted_at = now() where id = 'e0000000-0000-4000-8000-000000000002';
select results_eq(
  $$select f.meal_plan_entry_id, f.defrost_remind_at, f.deleted_at from public.frozen_items f join fi using (id)$$,
  $$values (null::uuid, null::timestamptz, null::timestamptz)$$,
  'a tombstoned meal with no alternative leaves the item live but unlinked'
);

update public.meal_plan_entries set recipe_id = 'b1000000-0000-4000-8000-000000000001' where id = 'e0000000-0000-4000-8000-000000000003';
select is(
  (select f.meal_plan_entry_id from public.frozen_items f join fi using (id)),
  'e0000000-0000-4000-8000-000000000003'::uuid,
  'changing a meal recipe to one that uses the product links unlinked items'
);
update public.meal_plan_entries set recipe_id = 'b1000000-0000-4000-8000-000000000003' where id = 'e0000000-0000-4000-8000-000000000003';
select is(
  (select f.meal_plan_entry_id from public.frozen_items f join fi using (id)),
  null::uuid,
  'changing the linked meal recipe to one that does not use the product unlinks it'
);

insert into public.meal_plan_entries (id, household_id, date, slot, recipe_id, draft_id)
select 'e0000000-0000-4000-8000-000000000005', 'd1000000-0000-4000-8000-000000000001', today + 1, 'lunch',
       'b1000000-0000-4000-8000-000000000001', null from d;
select is(
  (select f.meal_plan_entry_id from public.frozen_items f join fi using (id)),
  'e0000000-0000-4000-8000-000000000005'::uuid,
  'planning a new meal that uses the product links the unlinked item'
);
insert into public.meal_plan_entries (id, household_id, date, slot, recipe_id)
select 'e0000000-0000-4000-8000-000000000006', 'd1000000-0000-4000-8000-000000000001', today + 1, 'breakfast',
       'b1000000-0000-4000-8000-000000000001' from d;
select is(
  (select f.meal_plan_entry_id from public.frozen_items f join fi using (id)),
  'e0000000-0000-4000-8000-000000000005'::uuid,
  'a new meal does not steal items that are already linked'
);
insert into public.meal_plan_entries (id, household_id, date, slot, recipe_id)
select 'e0000000-0000-4000-8000-000000000007', 'd1000000-0000-4000-8000-000000000001', today + 20, 'lunch',
       'b1000000-0000-4000-8000-000000000001' from d;
update public.meal_plan_entries set deleted_at = now()
where id in ('e0000000-0000-4000-8000-000000000005', 'e0000000-0000-4000-8000-000000000006');
select is(
  (select f.meal_plan_entry_id from public.frozen_items f join fi using (id)),
  null::uuid,
  'meals more than 14 days ahead are not linked'
);

update public.meal_plan_entries set date = (select today + 6 from d), deleted_at = null
where id = 'e0000000-0000-4000-8000-000000000007';
select is(
  (select f.meal_plan_entry_id from public.frozen_items f join fi using (id)),
  'e0000000-0000-4000-8000-000000000007'::uuid,
  'moving a meal into the 14-day window links the item'
);

select public.update_household_settings('d1000000-0000-4000-8000-000000000001', '{"lunch":"13:15"}'::jsonb, null);
select is(
  (select f.defrost_remind_at from public.frozen_items f join fi using (id)),
  (select ((today + 6) + time '13:15') at time zone 'UTC' - interval '24 hours' from d),
  'changing the household slot times recomputes reminders'
);

-- ----------------------------------------------------------------- unfreezing / refreezing
update public.shopping_entries set status = 'have' where id = '5e000000-0000-4000-8000-000000000001';
select isnt((select f.deleted_at from public.frozen_items f join fi using (id)), null,
  'status leaving frozen tombstones the frozen item');
update public.shopping_entries set status = 'frozen' where id = '5e000000-0000-4000-8000-000000000001';
select results_eq(
  $$select count(*)::int, bool_and(f.deleted_at is null), bool_and(f.id = (select id from fi)), bool_and(f.meal_plan_entry_id is not null)
    from public.frozen_items f where f.shopping_entry_id = '5e000000-0000-4000-8000-000000000001'$$,
  $$values (1, true, true, true)$$,
  'freezing again revives the same row and relinks it'
);
update public.shopping_entries set deleted_at = now() where id = '5e000000-0000-4000-8000-000000000001';
select is((select f.deleted_at from public.frozen_items f join fi using (id)), null,
  'deleting the shopping entry keeps the frozen item (it is still in the freezer)');

-- ----------------------------------------------------------------- client writes
select is(
  jsonb_array_length(public.apply_mutations(null, format($$[
    {"table":"frozen_items","id":"%s","op":"upsert","client_ts":"2026-01-02T10:00:00Z",
     "fields":{"resolved_at":"2026-01-02T10:00:00Z","product_id":"a1000000-0000-4000-8000-000000000002","defrost_remind_at":null}}
  ]$$, (select id from fi))::jsonb) -> 'applied'),
  1, 'clients can set resolved_at'
);
select results_eq(
  $$select f.resolved_at, f.product_id, f.defrost_remind_at is not null from public.frozen_items f join fi using (id)$$,
  $$values ('2026-01-02T10:00:00Z'::timestamptz, 'a1000000-0000-4000-8000-000000000001'::uuid, true)$$,
  'other fields sent by clients are ignored'
);
select is(
  public.apply_mutations(null, $$[
    {"table":"frozen_items","id":"f0000000-0000-4000-8000-0000000000aa","op":"upsert","client_ts":"2026-01-02T10:00:00Z",
     "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","product_id":"a1000000-0000-4000-8000-000000000001"}}
  ]$$::jsonb) -> 'rejected' -> 0 ->> 'reason',
  'forbidden', 'clients cannot create frozen items');
select is(
  public.apply_mutations(null, format($$[{"table":"frozen_items","id":"%s","op":"delete","client_ts":"2026-01-02T10:00:00Z"}]$$,
    (select id from fi))::jsonb) -> 'rejected' -> 0 ->> 'reason',
  'forbidden', 'clients cannot delete frozen items');
select throws_ok(
  $$insert into public.frozen_items (household_id, product_id) values ('d1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001')$$,
  '42501', null, 'direct inserts are not allowed');
select throws_ok(
  $$update public.frozen_items set meal_plan_entry_id = null$$,
  '42501', null, 'direct updates of server-maintained columns are not allowed');

-- Resolved items are history: unfreezing keeps them; freezing again creates a new row.
reset role;
update public.shopping_entries set deleted_at = null where id = '5e000000-0000-4000-8000-000000000001';
set local role authenticated;
update public.shopping_entries set status = 'pending' where id = '5e000000-0000-4000-8000-000000000001';
select is((select f.deleted_at from public.frozen_items f join fi using (id)), null,
  'a resolved frozen item is not tombstoned when the entry leaves frozen');
update public.shopping_entries set status = 'frozen' where id = '5e000000-0000-4000-8000-000000000001';
select results_eq(
  $$select count(*)::int, count(*) filter (where resolved_at is null)::int
    from public.frozen_items where shopping_entry_id = '5e000000-0000-4000-8000-000000000001'$$,
  $$values (2, 1)$$,
  'freezing again after resolving creates a new open frozen item'
);

-- ----------------------------------------------------------------- recipe items
insert into public.shopping_entries (id, household_id, kind, recipe_id, text, meal_plan_entry_id) values
  ('5e000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'recipe',
   'b1000000-0000-4000-8000-000000000003', 'Arroz blanco', 'e0000000-0000-4000-8000-000000000003');
insert into public.shopping_entry_items (id, household_id, entry_id, product_id, quantity, unit) values
  ('5f000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', '5e000000-0000-4000-8000-000000000002',
   'a1000000-0000-4000-8000-000000000002', 200, 'g');
update public.shopping_entry_items set status = 'frozen' where id = '5f000000-0000-4000-8000-000000000001';
select results_eq(
  $$select shopping_entry_id, product_id, meal_plan_entry_id from public.frozen_items
    where shopping_entry_item_id = '5f000000-0000-4000-8000-000000000001' and deleted_at is null$$,
  $$values (null::uuid, 'a1000000-0000-4000-8000-000000000002'::uuid, 'e0000000-0000-4000-8000-000000000003'::uuid)$$,
  'a frozen recipe item is linked to its parent entry meal'
);
update public.shopping_entry_items set checked = false where id = '5f000000-0000-4000-8000-000000000001';
select is(
  (select count(*)::int from public.frozen_items where shopping_entry_item_id = '5f000000-0000-4000-8000-000000000001' and deleted_at is null),
  0, 'old clients unchecking a frozen item tombstone its frozen item');

insert into public.shopping_entries (id, household_id, kind, text) values
  ('5e000000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000001', 'text', 'Hielo');
update public.shopping_entries set status = 'frozen' where id = '5e000000-0000-4000-8000-000000000003';
select is((select count(*)::int from public.frozen_items where shopping_entry_id = '5e000000-0000-4000-8000-000000000003'),
  0, 'text entries never create frozen items');

-- ----------------------------------------------------------------- sync plumbing
select ok('frozen_items' = any (public.synced_tables()), 'frozen_items is a synced table');
select is((public.synced_tables())[array_length(public.synced_tables(), 1)], 'frozen_items', 'and comes last (dependency order)');
select ok(
  exists (select 1 from jsonb_array_elements(public.pull_changes(0, 1000) -> 'rows') x
          where x ->> 'table' = 'frozen_items' and x -> 'row' ->> 'id' = (select id::text from fi)),
  'pull_changes returns frozen_items'
);

-- ----------------------------------------------------------------- RLS
set local request.jwt.claims to '{"sub":"c2000000-0000-4000-8000-000000000002","role":"authenticated"}';
select is((select count(*)::int from public.frozen_items), 0, 'other households cannot see frozen items');
select is(
  public.apply_mutations(null, format($$[
    {"table":"frozen_items","id":"%s","op":"upsert","client_ts":"2026-01-03T10:00:00Z","fields":{"resolved_at":null}}
  ]$$, (select id from fi))::jsonb) -> 'rejected' -> 0 ->> 'reason',
  'forbidden', 'other households cannot resolve frozen items');
update public.frozen_items set resolved_at = null;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';
select isnt((select f.resolved_at from public.frozen_items f join fi using (id)), null,
  'an update from another household changes nothing');

-- ----------------------------------------------------------------- cascade and push
reset role;
delete from public.push_queue;
update public.products set deleted_at = now() where id = 'a1000000-0000-4000-8000-000000000001';
select is(
  (select count(*)::int from public.frozen_items where product_id = 'a1000000-0000-4000-8000-000000000001' and deleted_at is null),
  0, 'tombstoning the product tombstones its frozen items');
select results_eq(
  $$select kind, payload -> 'reasons' ? 'shopping' from public.push_queue where household_id = 'd1000000-0000-4000-8000-000000000001'$$,
  $$values ('sync'::text, true)$$,
  'frozen_items changes enqueue a silent shopping sync push'
);

select * from finish();
rollback;
