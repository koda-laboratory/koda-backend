-- apply_mutations: row LWW, field-level LWW for the shopping list, tombstones and batch behaviour.
begin;
create extension if not exists pgtap with schema extensions;
select plan(25);

insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'h1@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name) values ('d1000000-0000-4000-8000-000000000001', 'House one');
insert into public.household_members (household_id, user_id, role) values
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'owner');

set local role authenticated;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';

create temporary table r (k text primary key, v jsonb) on commit drop;

-- ----------------------------------------------------------------- row LWW
insert into r values ('insert', public.apply_mutations('f1000000-0000-4000-8000-000000000001', $$[
  {"table":"products","id":"e0000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T10:00:00Z",
   "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","name":"Leche","category":"basics","server_seq":1,"updated_by":"c2000000-0000-4000-8000-000000000002"}}
]$$::jsonb));
select is(jsonb_array_length((select v -> 'applied' from r where k = 'insert')), 1, 'upsert of a new row is applied');
select ok((select (v -> 'applied' -> 0 ->> 'server_seq')::bigint > 1 from r where k = 'insert'), 'server_seq comes from the sequence, not from the client');
select results_eq(
  $$select name, category::text, updated_by from public.products where id = 'e0000000-0000-4000-8000-000000000001'$$,
  $$values ('Leche'::text, 'basics'::text, 'c1000000-0000-4000-8000-000000000001'::uuid)$$,
  'row inserted with server-managed updated_by'
);
select is(
  (select v ->> 'cursor' from r where k = 'insert'),
  (select v -> 'applied' -> 0 ->> 'server_seq' from r where k = 'insert'),
  'cursor is the highest server_seq applied'
);

insert into r values ('newer', public.apply_mutations(null, $$[
  {"table":"products","id":"e0000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T12:00:00Z","fields":{"name":"Leche entera"}}
]$$::jsonb));
select is((select name from public.products where id = 'e0000000-0000-4000-8000-000000000001'), 'Leche entera', 'a newer client_ts wins');

insert into r values ('older', public.apply_mutations(null, $$[
  {"table":"products","id":"e0000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T11:00:00Z","fields":{"name":"Leche desnatada"}}
]$$::jsonb));
select is((select v -> 'rejected' -> 0 ->> 'reason' from r where k = 'older'), 'stale', 'an older client_ts is rejected as stale');
select is((select name from public.products where id = 'e0000000-0000-4000-8000-000000000001'), 'Leche entera', 'stale write did not change the row');

insert into r values ('household', public.apply_mutations(null, $$[
  {"table":"products","id":"e0000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T12:30:00Z","fields":{"household_id":"d2000000-0000-4000-8000-000000000002","emoji":"🥛"}}
]$$::jsonb));
select results_eq(
  $$select household_id, emoji from public.products where id = 'e0000000-0000-4000-8000-000000000001'$$,
  $$values ('d1000000-0000-4000-8000-000000000001'::uuid, '🥛'::text)$$,
  'household_id is ignored on updates'
);

-- ----------------------------------------------------------------- tombstones
insert into r values ('delete_old', public.apply_mutations(null, $$[
  {"table":"products","id":"e0000000-0000-4000-8000-000000000001","op":"delete","client_ts":"2025-12-01T00:00:00Z"}
]$$::jsonb));
select is(jsonb_array_length((select v -> 'applied' from r where k = 'delete_old')), 1, 'a delete applies even with an older client_ts');
select isnt((select deleted_at from public.products where id = 'e0000000-0000-4000-8000-000000000001'), null, 'the row is a tombstone');

insert into r values ('resurrect', public.apply_mutations(null, $$[
  {"table":"products","id":"e0000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2027-01-01T00:00:00Z","fields":{"name":"Zombie"}}
]$$::jsonb));
select is((select v -> 'rejected' -> 0 ->> 'reason' from r where k = 'resurrect'), 'deleted', 'tombstone wins over a later update');

insert into r values ('missing', public.apply_mutations(null, $$[
  {"table":"products","id":"e0000000-0000-4000-8000-0000000000ff","op":"delete","client_ts":"2026-01-01T00:00:00Z"}
]$$::jsonb));
select is((select v -> 'rejected' -> 0 ->> 'reason' from r where k = 'missing'), 'not_found', 'deleting an unknown row is reported as not_found');

-- ----------------------------------------------------------------- shopping list: field-level LWW
insert into r values ('entry', public.apply_mutations(null, $$[
  {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T10:00:00Z",
   "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","kind":"text","text":"Leche","position":1}}
]$$::jsonb));
select is(
  (select name_updated_at from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'),
  '2026-01-01T10:00:00Z'::timestamptz,
  'name_updated_at defaults to client_ts on insert'
);

-- Device A checks it at 10:30.
insert into r values ('check', public.apply_mutations(null, $$[
  {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T10:30:00Z",
   "fields":{"checked":true,"checked_at":"2026-01-01T10:30:00Z"}}
]$$::jsonb));
-- Device B (offline since 10:20) renamed it at 10:20 and moved it: the row is older, but the name group is newer.
insert into r values ('rename', public.apply_mutations(null, $$[
  {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T10:20:00Z",
   "fields":{"text":"Leche sin lactosa","name_updated_at":"2026-01-01T10:20:00Z","position":7}}
]$$::jsonb));
select results_eq(
  $$select checked, text, position, checked_by from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'$$,
  $$values (true, 'Leche sin lactosa'::text, 1, 'c1000000-0000-4000-8000-000000000001'::uuid)$$,
  'concurrent check and rename both survive; the stale position does not'
);
select is((select v -> 'applied' -> 0 ->> 'merged' from r where k = 'rename'), 'true', 'partially applied mutations are flagged as merged');

-- Device B unchecks with an older checked_at: refused.
insert into r values ('uncheck_old', public.apply_mutations(null, $$[
  {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T11:00:00Z",
   "fields":{"checked":false,"checked_at":"2026-01-01T10:10:00Z"}}
]$$::jsonb));
select is((select v -> 'rejected' -> 0 ->> 'reason' from r where k = 'uncheck_old'), 'stale', 'an older checked_at loses');
select is((select checked from public.shopping_entries where id = '5e000000-0000-4000-8000-000000000001'), true, 'the entry stays checked');

-- Item: checked by checked_at, quantity by row LWW.
insert into r values ('item', public.apply_mutations(null, $$[
  {"table":"shopping_entry_items","id":"5f000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T10:00:00Z",
   "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","entry_id":"5e000000-0000-4000-8000-000000000002","product_id":"e0000000-0000-4000-8000-000000000002","quantity":2}},
  {"table":"shopping_entries","id":"5e000000-0000-4000-8000-000000000002","op":"upsert","client_ts":"2026-01-01T10:00:00Z",
   "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","kind":"recipe","text":"Tortilla"}},
  {"table":"products","id":"e0000000-0000-4000-8000-000000000002","op":"upsert","client_ts":"2026-01-01T10:00:00Z",
   "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","name":"Huevos"}}
]$$::jsonb));
select is(jsonb_array_length((select v -> 'applied' from r where k = 'item')), 3, 'children sent before their parents are applied in dependency order');
insert into r values ('item_check', public.apply_mutations(null, $$[
  {"table":"shopping_entry_items","id":"5f000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T09:00:00Z",
   "fields":{"checked":true,"checked_at":"2026-01-01T10:45:00Z","quantity":5}}
]$$::jsonb));
select results_eq(
  $$select checked, quantity from public.shopping_entry_items where id = '5f000000-0000-4000-8000-000000000001'$$,
  $$values (true, 2::numeric)$$,
  'item: newer checked_at applies, stale quantity does not'
);

-- ----------------------------------------------------------------- batch robustness
insert into r values ('mixed', public.apply_mutations(null, $$[
  {"table":"secrets","id":"e0000000-0000-4000-8000-000000000009","op":"upsert","client_ts":"2026-01-01T10:00:00Z","fields":{}},
  {"table":"products","id":"not-a-uuid","op":"upsert","client_ts":"2026-01-01T10:00:00Z","fields":{}},
  {"table":"products","id":"e0000000-0000-4000-8000-000000000003","op":"upsert","client_ts":"2026-01-01T10:00:00Z","fields":{"household_id":"d1000000-0000-4000-8000-000000000001","name":"Pan","category":"not-a-category"}},
  {"table":"recipes","id":"a0000000-0000-4000-8000-00000000000a","op":"upsert","client_ts":"2026-01-01T10:00:00Z","fields":{"household_id":"d1000000-0000-4000-8000-000000000001","name":"Tortilla","meal_types":["dinner"],"steps":["Batir"]}},
  {"table":"products","id":"e0000000-0000-4000-8000-000000000004","op":"merge","client_ts":"2026-01-01T10:00:00Z","fields":{}}
]$$::jsonb));
select is(jsonb_array_length((select v -> 'applied' from r where k = 'mixed')), 1, 'valid mutations apply even when others fail');
select results_eq(
  $$select x ->> 'reason' from r, jsonb_array_elements(r.v -> 'rejected') x where r.k = 'mixed' order by 1$$,
  array['invalid_op', 'invalid_value', 'invalid_value', 'unknown_table'],
  'invalid mutations are rejected with a reason'
);
select is((select steps from public.recipes where id = 'a0000000-0000-4000-8000-00000000000a'), '["Batir"]'::jsonb, 'jsonb fields are stored');

insert into r values ('cycle', public.apply_mutations(null, $$[
  {"table":"recipe_components","id":"b0000000-0000-4000-8000-000000000001","op":"upsert","client_ts":"2026-01-01T10:00:00Z",
   "fields":{"household_id":"d1000000-0000-4000-8000-000000000001","parent_recipe_id":"a0000000-0000-4000-8000-00000000000a","child_recipe_id":"a0000000-0000-4000-8000-00000000000a"}}
]$$::jsonb));
select is((select v -> 'rejected' -> 0 ->> 'reason' from r where k = 'cycle'), 'constraint_violation', 'cycles are rejected');

insert into r values ('future', public.apply_mutations(null, $$[
  {"table":"products","id":"e0000000-0000-4000-8000-000000000002","op":"upsert","client_ts":"2099-01-01T00:00:00Z","fields":{"name":"Huevos camperos"}}
]$$::jsonb));
select ok(
  (select client_updated_at <= now() + interval '5 minutes' from public.products where id = 'e0000000-0000-4000-8000-000000000002'),
  'client_ts far in the future is clamped'
);

select throws_ok(
  $$select public.apply_mutations(null, '{"not":"an array"}'::jsonb)$$,
  '22023',
  null,
  'mutations must be an array'
);

reset role;
select * from finish();
rollback;
