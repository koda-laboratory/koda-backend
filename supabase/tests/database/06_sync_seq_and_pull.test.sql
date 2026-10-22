-- server_seq monotonicity, pull_changes paging, push_queue enqueueing and tombstone purge.
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'h1@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name) values ('d1000000-0000-4000-8000-000000000001', 'House one');
insert into public.household_members (household_id, user_id, role) values
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'owner');

create temporary table seqs (step int, seq bigint);
grant all on seqs to authenticated;

set local role authenticated;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';

insert into public.products (id, household_id, name) values
  ('e0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Uno');
insert into seqs select 1, server_seq from public.products where id = 'e0000000-0000-4000-8000-000000000001';
insert into public.stores (id, household_id, name) values
  ('e0000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'Tienda');
insert into seqs select 2, server_seq from public.stores where id = 'e0000000-0000-4000-8000-000000000002';
update public.products set name = 'Uno bis' where id = 'e0000000-0000-4000-8000-000000000001';
insert into seqs select 3, server_seq from public.products where id = 'e0000000-0000-4000-8000-000000000001';
update public.products set deleted_at = now() where id = 'e0000000-0000-4000-8000-000000000001';
insert into seqs select 4, server_seq from public.products where id = 'e0000000-0000-4000-8000-000000000001';

select ok(
  (select bool_and(seq > prev) from (select seq, lag(seq) over (order by step) as prev from seqs) s where prev is not null),
  'server_seq strictly increases across inserts, updates and tombstones of different tables'
);
select is(
  (select count(distinct seq)::int from seqs),
  4,
  'every write gets a new server_seq'
);
select throws_ok(
  $$select nextval('public.sync_seq')$$,
  '42501',
  null,
  'clients cannot consume the sequence directly'
);
update public.stores set server_seq = 1, updated_at = '2000-01-01' where id = 'e0000000-0000-4000-8000-000000000002';
select ok(
  (select server_seq > (select max(seq) from seqs) and updated_at > '2001-01-01' from public.stores where id = 'e0000000-0000-4000-8000-000000000002'),
  'server_seq and updated_at are always server-assigned'
);

-- ----------------------------------------------------------------- pull_changes
insert into public.products (household_id, name)
select 'd1000000-0000-4000-8000-000000000001', 'Producto ' || g from generate_series(1, 5) g;

select is((public.pull_changes(0, 3) ->> 'has_more')::boolean, true, 'first page has more');
select is(jsonb_array_length(public.pull_changes(0, 3) -> 'rows'), 3, 'page size is respected');
select is(
  (public.pull_changes(0, 3) ->> 'cursor')::bigint,
  (public.pull_changes(0, 3) -> 'rows' -> 2 -> 'row' ->> 'server_seq')::bigint,
  'cursor is the server_seq of the last row'
);
select is(
  jsonb_array_length(public.pull_changes((public.pull_changes(0, 3) ->> 'cursor')::bigint, 100) -> 'rows'),
  4,
  'the next page returns the remaining rows (one row per latest version)'
);
select ok(
  (select bool_and((x -> 'row' ->> 'server_seq')::bigint > (public.pull_changes(0, 3) ->> 'cursor')::bigint)
   from jsonb_array_elements(public.pull_changes((public.pull_changes(0, 3) ->> 'cursor')::bigint, 100) -> 'rows') x),
  'pages do not overlap'
);
select is(
  (select x -> 'row' ->> 'deleted_at' is not null from jsonb_array_elements(public.pull_changes(0, 100) -> 'rows') x
   where x -> 'row' ->> 'id' = 'e0000000-0000-4000-8000-000000000001'),
  true,
  'tombstones are included in pulls'
);
select is(
  (public.pull_changes(999999999, 10) ->> 'cursor')::bigint,
  999999999::bigint,
  'an empty pull keeps the cursor'
);

-- ----------------------------------------------------------------- push queue
reset role;
delete from public.push_queue;
set local role authenticated;
select public.apply_mutations('f1000000-0000-4000-8000-000000000001', $$[
  {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T10:00:00Z",
   "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","kind":"text","text":"Pan"}},
  {"table":"meal_plan_entries","id":"5e000000-0000-4000-8000-000000000002","op":"upsert","client_ts":"2026-01-01T10:00:00Z",
   "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","date":"2026-01-02","slot":"dinner","free_text":"Pizza"}}
]$$::jsonb);
reset role;
select results_eq(
  $$select count(*)::int, min(actor_device_id::text), min(actor_user_id::text) from public.push_queue$$,
  $$values (1, 'f1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001')$$,
  'one push_queue row per household and transaction, with the actor device'
);
select results_eq(
  $$select array(select jsonb_array_elements_text(payload -> 'reasons') order by 1) from public.push_queue$$,
  $$values (array['planning', 'shopping'])$$,
  'reasons aggregate every touched area'
);

-- ----------------------------------------------------------------- purge
update public.products set deleted_at = now() - interval '31 days' where id = 'e0000000-0000-4000-8000-000000000001';
select is(
  (public.purge_tombstones() -> 'purged' ->> 'products')::int,
  1,
  'purge_tombstones hard-deletes tombstones older than 30 days'
);
set local role authenticated;
select is(
  (public.pull_changes(1, 10) ->> 'reset_required')::boolean,
  true,
  'clients behind the purge watermark must resync'
);

reset role;
select * from finish();
rollback;
