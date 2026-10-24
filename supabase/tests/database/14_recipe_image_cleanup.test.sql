-- Orphan recipe images: what keepalive may remove from the `recipe-images` bucket.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into public.households (id, name) values ('d1400000-0000-4000-8000-000000000001', 'Cleanup house');
insert into public.recipes (id, household_id, name, image_path) values
  ('b1400000-0000-4000-8000-000000000001', 'd1400000-0000-4000-8000-000000000001', 'Live', 'h/live/cover.jpg'),
  ('b1400000-0000-4000-8000-000000000002', 'd1400000-0000-4000-8000-000000000001', 'Gone', 'h/gone/cover.jpg');
update public.recipes set deleted_at = now() where id = 'b1400000-0000-4000-8000-000000000002';
insert into public.recipe_photos (id, household_id, recipe_id, storage_path) values
  ('e1400000-0000-4000-8000-000000000001', 'd1400000-0000-4000-8000-000000000001',
   'b1400000-0000-4000-8000-000000000001', 'h/live/photo.jpg'),
  ('e1400000-0000-4000-8000-000000000002', 'd1400000-0000-4000-8000-000000000001',
   'b1400000-0000-4000-8000-000000000001', 'h/live/deleted.jpg');
update public.recipe_photos set deleted_at = now() where id = 'e1400000-0000-4000-8000-000000000002';

insert into storage.objects (bucket_id, name, created_at) values
  ('recipe-images', 'h/live/cover.jpg', now() - interval '10 days'),
  ('recipe-images', 'h/live/photo.jpg', now() - interval '10 days'),
  ('recipe-images', 'h/live/deleted.jpg', now() - interval '10 days'),
  ('recipe-images', 'h/gone/cover.jpg', now() - interval '10 days'),
  ('recipe-images', 'h/live/fresh.jpg', now() - interval '1 hour');

select set_eq(
  $$select public.orphan_recipe_images()$$,
  array['h/live/deleted.jpg', 'h/gone/cover.jpg'],
  'deleted photos and covers of deleted recipes are orphans; live covers, live photos and fresh uploads are not');
select is(
  (select count(*)::int from public.orphan_recipe_images(interval '1 minute')), 3,
  'without the grace period a fresh upload without its row counts too');
select is((select count(*)::int from public.orphan_recipe_images(interval '3 days', 1)), 1, 'the limit applies');

set local role authenticated;
select throws_ok($$select public.orphan_recipe_images()$$, '42501', null, 'users cannot list orphans');
reset role;
set local role service_role;
select lives_ok($$select public.orphan_recipe_images()$$, 'the service role can');

select * from finish();
rollback;
