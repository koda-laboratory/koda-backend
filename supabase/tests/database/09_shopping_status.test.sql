-- Shopping status: status <-> checked consistency (both ways) and field-level LWW with checked_at.
begin;
create extension if not exists pgtap with schema extensions;
select plan(18);

insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'h1@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name) values ('d1000000-0000-4000-8000-000000000001', 'House one');
insert into public.household_members (household_id, user_id, role) values
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'owner');
insert into public.products (id, household_id, name) values
  ('a1000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Pan');

set local role authenticated;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ----------------------------------------------------------------- trigger
insert into public.shopping_entries (id, household_id, kind, text) values
  ('5e000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'text', 'Leche');
select results_eq(
  $$select status, checked from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'$$,
  $$values ('pending'::text, false)$$, 'defaults: pending / unchecked');

update public.shopping_entries set checked = true where id = '5e000000-0000-4000-8000-000000000001';
select is((select status from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'),
  'have', 'old clients: checked = true sets status have');
update public.shopping_entries set checked = false where id = '5e000000-0000-4000-8000-000000000001';
select is((select status from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'),
  'pending', 'old clients: checked = false sets status pending');
update public.shopping_entries set status = 'frozen' where id = '5e000000-0000-4000-8000-000000000001';
select is((select checked from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'),
  true, 'status frozen sets checked');
update public.shopping_entries set status = 'pending', checked = true where id = '5e000000-0000-4000-8000-000000000001';
select is((select checked from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'),
  false, 'when both change, status wins');
update public.shopping_entries set text = 'Leche entera' where id = '5e000000-0000-4000-8000-000000000001';
select results_eq(
  $$select status, checked from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'$$,
  $$values ('pending'::text, false)$$, 'unrelated updates keep both');

insert into public.shopping_entries (id, household_id, kind, text, checked) values
  ('5e000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'text', 'Huevos', true);
select is((select status from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000002'),
  'have', 'insert with checked = true gets status have');
select throws_ok(
  $$update public.shopping_entries set status = 'bought' where id = '5e000000-0000-4000-8000-000000000002'$$,
  '23514', null, 'status is limited to pending|have|frozen');

insert into public.shopping_entries (id, household_id, kind, recipe_id, text) values
  ('5e000000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000001', 'recipe', null, 'Tostadas');
insert into public.shopping_entry_items (id, household_id, entry_id, product_id, status) values
  ('5f000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', '5e000000-0000-4000-8000-000000000003',
   'a1000000-0000-4000-8000-000000000001', 'have');
select is((select checked from public.shopping_entry_items where id = '5f000000-0000-4000-8000-000000000001'),
  true, 'items: insert with status have sets checked');
update public.shopping_entry_items set checked = false where id = '5f000000-0000-4000-8000-000000000001';
select is((select status from public.shopping_entry_items where id = '5f000000-0000-4000-8000-000000000001'),
  'pending', 'items: checked = false sets status pending');

-- ----------------------------------------------------------------- apply_mutations LWW
select is(
  jsonb_array_length(public.apply_mutations(null, $$[
    {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T10:00:00Z",
     "fields":{"status":"have","checked_at":"2026-01-01T10:00:00Z"}}
  ]$$::jsonb) -> 'applied'), 1, 'a status change is applied');
select results_eq(
  $$select status, checked, checked_at, checked_by from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'$$,
  $$values ('have'::text, true, '2026-01-01T10:00:00Z'::timestamptz, 'c1000000-0000-4000-8000-000000000001'::uuid)$$,
  'status, checked, checked_at and checked_by are written together');

select is(
  public.apply_mutations(null, $$[
    {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T12:00:00Z",
     "fields":{"status":"frozen","checked_at":"2026-01-01T09:00:00Z"}}
  ]$$::jsonb) -> 'rejected' -> 0 ->> 'reason',
  'stale', 'a status with an older checked_at loses even with a newer client_ts');

select is(
  public.apply_mutations(null, $$[
    {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T12:00:00Z",
     "fields":{"checked":false,"checked_at":"2026-01-01T09:30:00Z","position":7}}
  ]$$::jsonb) -> 'applied' -> 0 -> 'merged',
  'true'::jsonb, 'old clients: an older checked loses, other fields merge');
select results_eq(
  $$select status, checked, position from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'$$,
  $$values ('have'::text, true, 7)$$, 'the merged write kept status have');

select public.apply_mutations(null, $$[
  {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T13:00:00Z",
   "fields":{"checked":false,"checked_at":"2026-01-01T13:00:00Z"}}
]$$::jsonb);
select is((select status from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'),
  'pending', 'old clients: a newer checked = false resets status to pending');

select public.apply_mutations(null, $$[
  {"table":"shopping_entry_items","id":"5f000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T13:00:00Z",
   "fields":{"status":"have"}}
]$$::jsonb);
select results_eq(
  $$select status, checked, checked_at from public.shopping_entry_items where id = '5f000000-0000-4000-8000-000000000001'$$,
  $$values ('have'::text, true, '2026-01-01T13:00:00Z'::timestamptz)$$,
  'items: status uses checked_at (defaults to client_ts)');

select public.apply_mutations(null, $$[
  {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000009","op":"upsert","client_ts":"2026-01-01T14:00:00Z",
   "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","kind":"text","text":"Sal","status":"have"}}
]$$::jsonb);
select results_eq(
  $$select status, checked, checked_at, checked_by from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000009'$$,
  $$values ('have'::text, true, '2026-01-01T14:00:00Z'::timestamptz, 'c1000000-0000-4000-8000-000000000001'::uuid)$$,
  'insert with a non-pending status fills checked_at and checked_by');

reset role;
select * from finish();
rollback;
