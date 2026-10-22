-- Household settings: defaults, get_me, update_household_settings validation and membership.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'h1@koda.test', 'authenticated', 'authenticated'),
  ('c1000000-0000-4000-8000-000000000002', 'h1b@koda.test', 'authenticated', 'authenticated'),
  ('c2000000-0000-4000-8000-000000000002', 'h2@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name) values
  ('d1000000-0000-4000-8000-000000000001', 'House one'),
  ('d2000000-0000-4000-8000-000000000002', 'House two');
insert into public.household_members (household_id, user_id, role) values
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'owner'),
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000002', 'member'),
  ('d2000000-0000-4000-8000-000000000002', 'c2000000-0000-4000-8000-000000000002', 'owner');

select is(
  (select slot_times from public.households where id = 'd1000000-0000-4000-8000-000000000001'),
  '{"breakfast":"09:00","lunch":"14:30","snack":"18:00","dinner":"21:30"}'::jsonb,
  'slot_times default'
);
select is((select shopping_weekday from public.households where id = 'd1000000-0000-4000-8000-000000000001'),
  5::smallint, 'shopping_weekday defaults to Friday (ISO 5)');
select throws_ok(
  $$update public.households set shopping_weekday = 8 where id = 'd1000000-0000-4000-8000-000000000001'$$,
  '23514', null, 'shopping_weekday is limited to 1..7');
select throws_ok(
  $$update public.households set slot_times = '{"breakfast":"9:00","lunch":"14:30","snack":"18:00","dinner":"21:30"}' where id = 'd1000000-0000-4000-8000-000000000001'$$,
  '23514', null, 'slot_times must hold four HH:MM values');

-- ----------------------------------------------------------------- as a plain member
set local role authenticated;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000002","role":"authenticated"}';

select is(
  (public.get_me() -> 'households' -> 0 -> 'slot_times' ->> 'lunch'),
  '14:30',
  'get_me includes slot_times'
);
select is((public.get_me() -> 'households' -> 0 ->> 'shopping_weekday')::int, 5, 'get_me includes shopping_weekday');

select is(
  public.update_household_settings('d1000000-0000-4000-8000-000000000001', '{"lunch":"14:00"}'::jsonb, null) -> 'slot_times',
  '{"breakfast":"09:00","lunch":"14:00","snack":"18:00","dinner":"21:30"}'::jsonb,
  'a member (not owner) can update slot times; partial objects are merged'
);
select is(
  (public.update_household_settings('d1000000-0000-4000-8000-000000000001', null, 6::smallint) ->> 'shopping_weekday')::int,
  6,
  'shopping_weekday is updated and slot times kept'
);
select is(
  (public.update_household_settings('d1000000-0000-4000-8000-000000000001', null, null) ->> 'name'),
  'House one',
  'the result is the get_me household object'
);
select throws_ok(
  $$select public.update_household_settings('d1000000-0000-4000-8000-000000000001', '{"lunch":"25:00"}'::jsonb, null)$$,
  '22023', null, 'invalid HH:MM is rejected');
select throws_ok(
  $$select public.update_household_settings('d1000000-0000-4000-8000-000000000001', '{"brunch":"11:00"}'::jsonb, null)$$,
  '22023', null, 'unknown slots are rejected');
select throws_ok(
  $$select public.update_household_settings('d1000000-0000-4000-8000-000000000001', null, 0::smallint)$$,
  '22023', null, 'shopping_weekday out of range is rejected');
select throws_ok(
  $$select public.update_household_settings('d2000000-0000-4000-8000-000000000002', null, 3::smallint)$$,
  'P0002', null, 'other households are not found');

reset role;
select is((select shopping_weekday from public.households where id = 'd2000000-0000-4000-8000-000000000002'),
  5::smallint, 'the other household was not changed');

select * from finish();
rollback;
