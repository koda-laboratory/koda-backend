-- recipe_components: anti-cycle trigger, recipe_tree and recipe_flat_ingredients.
begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'h1@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name) values ('d1000000-0000-4000-8000-000000000001', 'House one');
insert into public.household_members (household_id, user_id, role) values
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'owner');

insert into public.products (id, household_id, name) values
  ('e0000000-0000-4000-8000-000000000001', 'd1000000-0000-4000-8000-000000000001', 'Pollo'),
  ('e0000000-0000-4000-8000-000000000002', 'd1000000-0000-4000-8000-000000000001', 'Patatas'),
  ('e0000000-0000-4000-8000-000000000003', 'd1000000-0000-4000-8000-000000000001', 'Aceite');
-- A: Pollo al horno (2 servings) includes B: Patatas (factor 1) which includes C: Alioli (factor 0.5)
insert into public.recipes (id, household_id, name, servings) values
  ('a0000000-0000-4000-8000-00000000000a', 'd1000000-0000-4000-8000-000000000001', 'Pollo al horno', 2),
  ('a0000000-0000-4000-8000-00000000000b', 'd1000000-0000-4000-8000-000000000001', 'Patatas al airfryer', 2),
  ('a0000000-0000-4000-8000-00000000000c', 'd1000000-0000-4000-8000-000000000001', 'Alioli', 2),
  ('a0000000-0000-4000-8000-00000000000d', 'd1000000-0000-4000-8000-000000000001', 'Otra', 2);
insert into public.recipe_ingredients (household_id, recipe_id, product_id, quantity, unit) values
  ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000a', 'e0000000-0000-4000-8000-000000000001', 600, 'g'),
  ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000a', 'e0000000-0000-4000-8000-000000000003', 20, 'ml'),
  ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000b', 'e0000000-0000-4000-8000-000000000002', 400, 'g'),
  ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000b', 'e0000000-0000-4000-8000-000000000003', 10, 'ml'),
  ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000c', 'e0000000-0000-4000-8000-000000000003', 40, 'ml');

set local role authenticated;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';

select lives_ok(
  $$insert into public.recipe_components (id, household_id, parent_recipe_id, child_recipe_id, servings_factor)
    values ('b0000000-0000-4000-8000-0000000000ab', 'd1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-00000000000b', 1)$$,
  'A can include B'
);
select lives_ok(
  $$insert into public.recipe_components (id, household_id, parent_recipe_id, child_recipe_id, servings_factor)
    values ('b0000000-0000-4000-8000-0000000000bc', 'd1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000b', 'a0000000-0000-4000-8000-00000000000c', 0.5)$$,
  'B can include C'
);
select throws_ok(
  $$insert into public.recipe_components (household_id, parent_recipe_id, child_recipe_id)
    values ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-00000000000a')$$,
  '23514',
  null,
  'a recipe cannot include itself'
);
select throws_ok(
  $$insert into public.recipe_components (household_id, parent_recipe_id, child_recipe_id)
    values ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000c', 'a0000000-0000-4000-8000-00000000000a')$$,
  '23514',
  null,
  'C cannot include A (indirect cycle A -> B -> C -> A)'
);
select throws_ok(
  $$update public.recipe_components set child_recipe_id = 'a0000000-0000-4000-8000-00000000000a'
    where id = 'b0000000-0000-4000-8000-0000000000bc'$$,
  '23514',
  null,
  'updating a component into a cycle is rejected'
);
select lives_ok(
  $$insert into public.recipe_components (household_id, parent_recipe_id, child_recipe_id)
    values ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000d', 'a0000000-0000-4000-8000-00000000000c')$$,
  'a diamond (shared sub-recipe) is allowed'
);

select results_eq(
  $$select name, depth, servings_factor from public.recipe_tree('a0000000-0000-4000-8000-00000000000a')$$,
  $$values ('Pollo al horno'::text, 0, 1::numeric), ('Patatas al airfryer', 1, 1), ('Alioli', 2, 0.5)$$,
  'recipe_tree returns the root and nested sub-recipes with cumulative factors'
);
select results_eq(
  $$select product_name, unit, quantity from public.recipe_flat_ingredients('a0000000-0000-4000-8000-00000000000a')$$,
  $$values ('Aceite'::text, 'ml'::text, 50::numeric), ('Patatas', 'g', 400), ('Pollo', 'g', 600)$$,
  'recipe_flat_ingredients aggregates the whole tree (20 + 10 + 40 * 0.5 ml of oil)'
);
select results_eq(
  $$select product_name, quantity from public.recipe_flat_ingredients('a0000000-0000-4000-8000-00000000000a', 4) where product_name = 'Pollo'$$,
  $$values ('Pollo'::text, 1200::numeric)$$,
  'recipe_flat_ingredients scales by servings'
);

-- Tombstoning the child removes it from the tree and tombstones its components.
update public.recipes set deleted_at = now() where id = 'a0000000-0000-4000-8000-00000000000b';
select is(
  (select count(*)::int from public.recipe_tree('a0000000-0000-4000-8000-00000000000a')),
  1,
  'deleted sub-recipes disappear from the tree'
);
select is(
  (select count(*)::int from public.recipe_components where child_recipe_id = 'a0000000-0000-4000-8000-00000000000b' and deleted_at is null),
  0,
  'tombstoning a recipe tombstones the components that reference it'
);
select is(
  (select count(*)::int from public.recipe_ingredients where recipe_id = 'a0000000-0000-4000-8000-00000000000b' and deleted_at is null),
  0,
  'tombstoning a recipe tombstones its ingredients'
);

reset role;
select * from finish();
rollback;
