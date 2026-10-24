-- MCP tool functions: reads, writes through RLS (caller's household only), product matching, drafts.
begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

insert into auth.users (id, email, aud, role) values
  ('c1100000-0000-4000-8000-000000000001', 'mcp1@koda.test', 'authenticated', 'authenticated'),
  ('c1100000-0000-4000-8000-000000000002', 'mcp2@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name) values
  ('d1100000-0000-4000-8000-000000000001', 'MCP house'),
  ('d1100000-0000-4000-8000-000000000002', 'Other house');
insert into public.household_members (household_id, user_id, role) values
  ('d1100000-0000-4000-8000-000000000001', 'c1100000-0000-4000-8000-000000000001', 'owner'),
  ('d1100000-0000-4000-8000-000000000002', 'c1100000-0000-4000-8000-000000000002', 'owner');
insert into public.products (id, household_id, name) values
  ('a1100000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000001', 'Huevos'),
  ('a1100000-0000-4000-8000-000000000002', 'd1100000-0000-4000-8000-000000000001', 'Patatas'),
  ('a1100000-0000-4000-8000-000000000003', 'd1100000-0000-4000-8000-000000000001', 'Lentejas'),
  ('a1100000-0000-4000-8000-000000000009', 'd1100000-0000-4000-8000-000000000002', 'Huevos');
insert into public.recipes (id, household_id, name, meal_types, servings) values
  ('b1100000-0000-4000-8000-000000000001', 'd1100000-0000-4000-8000-000000000001', 'Tortilla de patata',
   array['dinner'], 2),
  ('b1100000-0000-4000-8000-000000000002', 'd1100000-0000-4000-8000-000000000001', 'Lentejas estofadas',
   array['lunch'], 4),
  ('b1100000-0000-4000-8000-000000000009', 'd1100000-0000-4000-8000-000000000002', 'Tortilla ajena',
   array['dinner'], 2);
insert into public.recipe_ingredients (household_id, recipe_id, product_id, quantity, unit) values
  ('d1100000-0000-4000-8000-000000000001', 'b1100000-0000-4000-8000-000000000001',
   'a1100000-0000-4000-8000-000000000001', 4, 'u'),
  ('d1100000-0000-4000-8000-000000000001', 'b1100000-0000-4000-8000-000000000001',
   'a1100000-0000-4000-8000-000000000002', 500, 'g');

set local role authenticated;
set local request.jwt.claims to '{"sub":"c1100000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ----------------------------------------------------------------- household
select is(public.mcp_household_id(), 'd1100000-0000-4000-8000-000000000001'::uuid, 'household of the caller');
select is(public.mcp_today(), (now() at time zone 'Europe/Madrid')::date, 'today in the household time zone');

-- ----------------------------------------------------------------- planning
select is(
  (public.mcp_plan_meal('2026-11-02', 'dinner', 'b1100000-0000-4000-8000-000000000001')) ->> 'recipe',
  'Tortilla de patata', 'plan_meal with a recipe returns the entry with its name');
select is(
  (public.mcp_plan_meal('2026-11-02', 'lunch', null, 'Comemos fuera')) ->> 'time',
  '14:30', 'plan_meal with free text uses the household slot time');
select throws_ok(
  $$select public.mcp_plan_meal('2026-11-02', 'lunch', 'b1100000-0000-4000-8000-000000000001', 'Fuera')$$,
  '22023', null, 'recipe and free text together are rejected');
select throws_ok(
  $$select public.mcp_plan_meal('2026-11-02', 'brunch', null, 'X')$$,
  '22023', null, 'unknown slots are rejected');
select is(jsonb_array_length(public.mcp_get_meals('2026-11-02')), 2, 'get_meals for one day');
select is(jsonb_array_length(public.mcp_get_meals('2026-11-02', '2026-11-02', 'dinner')), 1, 'get_meals by slot');
select throws_ok($$select public.mcp_get_meals('2026-11-01', '2027-03-01')$$, '22023', null, 'ranges are capped');
select ok(
  public.mcp_remove_planned_meal(
    ((public.mcp_get_meals('2026-11-02', '2026-11-02', 'lunch')) -> 0 ->> 'id')::uuid),
  'remove_planned_meal tombstones the entry');
select is(jsonb_array_length(public.mcp_get_meals('2026-11-02')), 1, 'the removed meal is gone');

-- ----------------------------------------------------------------- recipes
select is((public.mcp_resolve_recipe('tortilla') -> 0 ->> 'name'), 'Tortilla de patata',
  'resolve_recipe ranks the caller''s recipes by name');
select is(jsonb_array_length(public.mcp_resolve_recipe('tortilla')), 1, 'other households'' recipes stay hidden');
select is(jsonb_array_length(public.mcp_search_recipes('huevos')), 1, 'search_recipes matches by ingredient');
select is(jsonb_array_length(public.mcp_search_recipes(null, 'lunch')), 1, 'search_recipes filters by meal type');
select is(jsonb_array_length((public.mcp_get_recipe('b1100000-0000-4000-8000-000000000001')) -> 'ingredients'), 2,
  'get_recipe lists the ingredients');
select is(public.mcp_get_recipe('b1100000-0000-4000-8000-000000000009'), null, 'get_recipe is limited by RLS');

-- ----------------------------------------------------------------- shopping
select is(
  (select jsonb_agg(x ->> 'status' order by x ->> 'name') from jsonb_array_elements(
    public.mcp_add_shopping_items('[{"name":"huevos"},{"name":"Pilas AA"}]')) x),
  '["added", "added"]'::jsonb, 'add_shopping_items adds a catalog product and a free text');
select is(
  (public.mcp_add_shopping_items('[{"name":"Huevos"}]') -> 0 ->> 'status'), 'already_on_list',
  'a product already pending is not added twice');
select is(
  (select count(*)::integer from public.shopping_entries where source = 'mcp'), 2,
  'entries are written with source mcp in the caller''s household');
select is(
  (public.mcp_add_recipe_to_shopping('b1100000-0000-4000-8000-000000000001') ->> 'products')::integer, 2,
  'add_recipe_to_shopping writes one grouped entry with its products');
select is(
  (public.mcp_set_shopping_status(
    array(select id from public.shopping_entry_items where status = 'pending'), 'have') ->> 'updated')::integer, 2,
  'set_shopping_status marks recipe items');

-- ----------------------------------------------------------------- drafts
select is(
  (public.mcp_create_meal_plan_draft('2026-11-09', '2026-11-15',
    '[{"date":"2026-11-09","slot":"lunch","recipe_id":"b1100000-0000-4000-8000-000000000002"},
      {"date":"2026-11-10","slot":"dinner","free_text":"Pizza casera"}]', 'Semana ligera') ->> 'entries')::integer,
  2, 'create_meal_plan_draft stores the proposal');
select is(jsonb_array_length(public.mcp_get_meals('2026-11-09', '2026-11-15')), 0,
  'draft entries never appear in the planning until accepted');

select * from finish();
rollback;
