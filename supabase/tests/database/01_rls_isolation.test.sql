-- RLS: two households cannot see or write each other's data.
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

-- Fixtures (as postgres).
insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'h1@koda.test', 'authenticated', 'authenticated'),
  ('c2000000-0000-4000-8000-000000000002', 'h2@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name) values
  ('d1000000-0000-4000-8000-000000000001', 'House one'),
  ('d2000000-0000-4000-8000-000000000002', 'House two');
insert into public.household_members (household_id, user_id, role) values
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'owner'),
  ('d2000000-0000-4000-8000-000000000002', 'c2000000-0000-4000-8000-000000000002', 'owner');
insert into public.profiles (id, display_name) values
  ('c1000000-0000-4000-8000-000000000001', 'One'),
  ('c2000000-0000-4000-8000-000000000002', 'Two');
insert into public.products (id, household_id, name) values
  ('e1000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Leche uno'),
  ('e2000000-0000-4000-8000-000000000002', 'd2000000-0000-4000-8000-000000000002', 'Leche dos');
insert into public.devices (id, user_id, apns_token, platform, apns_env) values
  ('f1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'token-one', 'ios', 'sandbox'),
  ('f2000000-0000-4000-8000-000000000002', 'c2000000-0000-4000-8000-000000000002', 'token-two', 'ios', 'sandbox');

-- Every public table has RLS enabled.
select is(
  (select count(*)::int from pg_tables where schemaname = 'public' and not rowsecurity),
  0,
  'every public table has RLS enabled'
);

-- ----------------------------------------------------------------- user one
set local role authenticated;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';

select is((select count(*)::int from public.households where id in ('d1000000-0000-4000-8000-000000000001', 'd2000000-0000-4000-8000-000000000002')), 1,
  'user one sees only their household');
select results_eq(
  $$select name from public.products where id in ('e1000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000002')$$,
  array['Leche uno'],
  'user one sees only their products'
);
select is((select count(*)::int from public.profiles where id = 'c2000000-0000-4000-8000-000000000002'), 0,
  'user one cannot see profiles of other households');
select is((select count(*)::int from public.devices), 1, 'user one sees only their devices');
select throws_ok($$select count(*) from public.push_queue$$, '42501', null, 'push_queue is not readable by users');

select throws_ok(
  $$insert into public.products (id, household_id, name) values (gen_random_uuid(), 'd2000000-0000-4000-8000-000000000002', 'Intruso')$$,
  '42501',
  null,
  'user one cannot insert into another household'
);

update public.products set name = 'Hacked' where id = 'e2000000-0000-4000-8000-000000000002';
select lives_ok(
  $$update public.products set household_id = 'd2000000-0000-4000-8000-000000000002' where id = 'e1000000-0000-4000-8000-000000000001'$$,
  'moving a row to another household is silently ignored (household_id is immutable)'
);
select throws_ok(
  $$delete from public.products where id = 'e1000000-0000-4000-8000-000000000001'$$,
  '42501',
  null,
  'clients cannot hard-delete synced rows'
);
select throws_ok(
  $$select public.purge_tombstones()$$,
  '42501',
  null,
  'purge_tombstones is not callable by users'
);
select throws_ok(
  $$select * from public.claim_push_batch()$$,
  '42501',
  null,
  'claim_push_batch is not callable by users'
);
select is(
  (public.apply_mutations('f1000000-0000-4000-8000-000000000001', '[{"table":"products","id":"e2000000-0000-4000-8000-000000000002","op":"upsert","fields":{"household_id":"d1000000-0000-4000-8000-000000000001","name":"Hacked"},"client_ts":"2026-01-01T00:00:00Z"}]'::jsonb)
    -> 'rejected' -> 0 ->> 'reason'),
  'conflict',
  'apply_mutations cannot overwrite a row of another household'
);
select is(
  jsonb_array_length(public.pull_changes(0, 1000) -> 'rows') ,
  (select count(*)::int from public.products where household_id = 'd1000000-0000-4000-8000-000000000001')
    + (select count(*)::int from public.stores),
  'pull_changes only returns rows of the caller household'
);

-- ----------------------------------------------------------------- user two
reset role;
set local role authenticated;
set local request.jwt.claims to '{"sub":"c2000000-0000-4000-8000-000000000002","role":"authenticated"}';

select results_eq(
  $$select name from public.products where id = 'e2000000-0000-4000-8000-000000000002'$$,
  array['Leche dos'],
  'user two data was not modified by user one'
);

-- ----------------------------------------------------------------- anon
reset role;
set local role anon;
set local request.jwt.claims to '{"role":"anon"}';
select throws_ok($$select count(*) from public.products$$, '42501', null, 'anon cannot read products');
select throws_ok($$select public.apply_mutations(null, '[]'::jsonb)$$, '42501', null, 'anon cannot call apply_mutations');

reset role;
select * from finish();
rollback;
