-- recipe_stats view and match_product.
begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, email, aud, role) values
  ('c1000000-0000-4000-8000-000000000001', 'h1@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name) values ('d1000000-0000-4000-8000-000000000001', 'House one');
insert into public.household_members (household_id, user_id, role) values
  ('d1000000-0000-4000-8000-000000000001', 'c1000000-0000-4000-8000-000000000001', 'owner');
insert into public.recipes (id, household_id, name) values
  ('a0000000-0000-4000-8000-00000000000a', 'd1000000-0000-4000-8000-000000000001', 'Lentejas'),
  ('a0000000-0000-4000-8000-00000000000b', 'd1000000-0000-4000-8000-000000000001', 'Paella'),
  ('a0000000-0000-4000-8000-00000000000c', 'd1000000-0000-4000-8000-000000000001', 'Nunca comida');

-- Lentejas: today, 13 days ago (inside 14d), 14 days ago (outside), 40 days ago; plus a tombstoned one.
insert into public.consumptions (household_id, recipe_id, eaten_on, deleted_at)
select 'd1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000a',
       (now() at time zone 'Europe/Madrid')::date - d, null
from unnest(array[0, 13, 14, 40]) d;
insert into public.consumptions (household_id, recipe_id, eaten_on, deleted_at) values
  ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000a', (now() at time zone 'Europe/Madrid')::date - 1, now());
insert into public.consumptions (household_id, recipe_id, eaten_on) values
  ('d1000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-00000000000b', (now() at time zone 'Europe/Madrid')::date - 30);

insert into public.products (household_id, name) values
  ('d1000000-0000-4000-8000-000000000001', 'Leche entera'),
  ('d1000000-0000-4000-8000-000000000001', 'Plátano de Canarias'),
  ('d1000000-0000-4000-8000-000000000001', 'Lechuga'),
  ('d1000000-0000-4000-8000-000000000001', 'Papel higiénico');

set local role authenticated;
set local request.jwt.claims to '{"sub":"c1000000-0000-4000-8000-000000000001","role":"authenticated"}';

select results_eq(
  $$select times_eaten, last_eaten_on, eaten_last_14d from public.recipe_stats where recipe_id = 'a0000000-0000-4000-8000-00000000000a'$$,
  $$select 4, (now() at time zone 'Europe/Madrid')::date, 2$$,
  'recipe_stats counts live consumptions and the last 14 days'
);
select results_eq(
  $$select times_eaten, eaten_last_14d from public.recipe_stats where recipe_id = 'a0000000-0000-4000-8000-00000000000b'$$,
  $$values (1, 0)$$,
  'recipe_stats for a recipe eaten 30 days ago'
);
select results_eq(
  $$select times_eaten, last_eaten_on, eaten_last_14d from public.recipe_stats where recipe_id = 'a0000000-0000-4000-8000-00000000000c'$$,
  $$values (0, null::date, 0)$$,
  'recipe_stats includes never-eaten recipes'
);

reset role;
update public.recipes set deleted_at = now() where id = 'a0000000-0000-4000-8000-00000000000b';
set local role authenticated;
select is(
  (select count(*)::int from public.recipe_stats where recipe_id = 'a0000000-0000-4000-8000-00000000000b'),
  0,
  'recipe_stats excludes deleted recipes'
);

select is(
  (select name from public.match_product('leche') limit 1),
  'Leche entera',
  'match_product finds by prefix'
);
select is(
  (select name from public.match_product('PLATANO') limit 1),
  'Plátano de Canarias',
  'match_product ignores accents and case'
);
select is(
  (select name from public.match_product('papel higienico') limit 1),
  'Papel higiénico',
  'match_product matches multi-word names'
);
select is(
  (select name from public.match_product('lechga') limit 1),
  'Lechuga',
  'match_product tolerates typos'
);
select is(
  (select count(*)::int from public.match_product('zzzzzz')),
  0,
  'match_product returns nothing for unrelated text'
);

reset role;
select * from finish();
rollback;
