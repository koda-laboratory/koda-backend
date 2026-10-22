-- accept_meal_plan_draft, discard_meal_plan_draft and shopping_from_plan.
begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'h1@koda.test', 'authenticated', 'authenticated'),
  ('c2000000-0000-4000-8000-000000000002', 'h2@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name) values
  ('d1000000-0000-4000-8000-000000000001', 'House one'),
  ('d2000000-0000-4000-8000-000000000002', 'House two');
insert into public.household_members (household_id, user_id, role) values
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'owner'),
  ('d2000000-0000-4000-8000-000000000002', 'c2000000-0000-4000-8000-000000000002', 'owner');
insert into public.products (id, household_id, name) values
  ('e0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Pollo'),
  ('e0000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'Patatas');
insert into public.recipes (id, household_id, name, servings) values
  ('a0000000-0000-4000-8000-00000000000a', 'd1000000-0000-4000-8000-000000000001', 'Pollo al horno', 2),
  ('a0000000-0000-4000-8000-00000000000b', 'd1000000-0000-4000-8000-000000000001', 'Patatas al airfryer', 2);
insert into public.recipe_components (household_id, parent_recipe_id, child_recipe_id) values
  ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-00000000000b');
insert into public.recipe_ingredients (household_id, recipe_id, product_id, quantity, unit) values
  ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000a', 'e0000000-0000-4000-8000-000000000001', 600, 'g'),
  ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000b', 'e0000000-0000-4000-8000-000000000002', 400, 'g');

insert into public.meal_plan_drafts (id, household_id, from_date, to_date, source, rationale) values
  ('b0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', '2026-11-02', '2026-11-08', 'mcp', 'Week plan'),
  ('b0000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', '2026-11-02', '2026-11-08', 'mcp', 'Alternative');
insert into public.meal_plan_entries (id, household_id, date, slot, recipe_id, draft_id) values
  ('f0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', '2026-11-02', 'lunch', 'a0000000-0000-4000-8000-00000000000a', 'b0000000-0000-4000-8000-000000000001'),
  ('f0000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', '2026-11-03', 'dinner', 'a0000000-0000-4000-8000-00000000000b', 'b0000000-0000-4000-8000-000000000001'),
  ('f0000000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000001', '2026-11-04', 'dinner', 'a0000000-0000-4000-8000-00000000000b', 'b0000000-0000-4000-8000-000000000002');
insert into public.meal_plan_entries (id, household_id, date, slot, free_text) values
  ('f0000000-0000-4000-8000-000000000004', 'd1000000-0000-4000-8000-000000000001', '2026-11-05', 'dinner', 'Pizza');

-- ----------------------------------------------------------------- other household
set local role authenticated;
set local request.jwt.claims to '{"sub":"c2000000-0000-4000-8000-000000000002","role":"authenticated"}';
select throws_ok(
  $$select public.accept_meal_plan_draft('b0000000-0000-4000-8000-000000000001')$$,
  'P0002',
  null,
  'another household cannot accept the draft'
);

-- ----------------------------------------------------------------- owner household
reset role;
set local role authenticated;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';

select is(public.accept_meal_plan_draft('b0000000-0000-4000-8000-000000000001'), 2, 'accept promotes the 2 draft entries');
select is(
  (select status::text from public.meal_plan_drafts where id = 'b0000000-0000-4000-8000-000000000001'),
  'accepted',
  'draft is marked accepted'
);
select is(
  (select count(*)::int from public.meal_plan_entries where draft_id is null and deleted_at is null and date between '2026-11-02' and '2026-11-08'),
  3,
  'accepted entries are part of the planning'
);
select throws_ok(
  $$select public.accept_meal_plan_draft('b0000000-0000-4000-8000-000000000001')$$,
  '55000',
  null,
  'an accepted draft cannot be accepted again'
);

select is(public.discard_meal_plan_draft('b0000000-0000-4000-8000-000000000002'), 1, 'discard tombstones the draft entries');
select is(
  (select deleted_at is not null from public.meal_plan_entries where id = 'f0000000-0000-4000-8000-000000000003'),
  true,
  'discarded draft entries are tombstones'
);
select throws_ok(
  $$select public.accept_meal_plan_draft('b0000000-0000-4000-8000-000000000002')$$,
  '55000',
  null,
  'a discarded draft cannot be accepted'
);

-- ----------------------------------------------------------------- shopping_from_plan
select is(
  (public.shopping_from_plan('2026-11-02', '2026-11-08') ->> 'created')::int,
  2,
  'shopping_from_plan creates one entry per planned recipe (free text and drafts excluded)'
);
select is(
  (select text from public.shopping_entries where meal_plan_entry_id = 'f0000000-0000-4000-8000-000000000001'),
  'Pollo al horno + Patatas al airfryer',
  'recipe entries are labelled with the recipe tree'
);
select results_eq(
  $$select p.name, i.quantity from public.shopping_entry_items i
    join public.shopping_entries s on s.id = i.entry_id
    join public.products p on p.id = i.product_id
    where s.meal_plan_entry_id = 'f0000000-0000-4000-8000-000000000001' order by p.name$$,
  $$values ('Patatas'::text, 400::numeric), ('Pollo', 600)$$,
  'items are the flattened recipe tree'
);
select is(
  (select kind::text || '/' || source::text from public.shopping_entries where meal_plan_entry_id = 'f0000000-0000-4000-8000-000000000001'),
  'recipe/plan',
  'entries are kind=recipe, source=plan'
);
select is(
  (public.shopping_from_plan('2026-11-02', '2026-11-08') ->> 'created')::int,
  0,
  'running it again does not duplicate entries'
);
select throws_ok(
  $$select public.shopping_from_plan('2026-11-08', '2026-11-02')$$,
  '22023',
  null,
  'an inverted range is rejected'
);

reset role;
select * from finish();
rollback;
