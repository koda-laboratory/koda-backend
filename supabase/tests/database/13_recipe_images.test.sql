-- Recipe images: storage folder isolation, recipe_photos sync (RLS, push/pull, cascade), MCP cover rules.
begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, email, aud, role) values
  ('c1300000-0000-4000-8000-000000000001', 'img1@koda.test', 'authenticated', 'authenticated'),
  ('c1300000-0000-4000-8000-000000000002', 'img2@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name) values
  ('d1300000-0000-4000-8000-000000000001', 'Images house'),
  ('d1300000-0000-4000-8000-000000000002', 'Other house');
insert into public.household_members (household_id, user_id, role) values
  ('d1300000-0000-4000-8000-000000000001', 'c1300000-0000-4000-8000-000000000001', 'owner'),
  ('d1300000-0000-4000-8000-000000000002', 'c1300000-0000-4000-8000-000000000002', 'owner');
insert into public.recipes (id, household_id, name) values
  ('b1300000-0000-4000-8000-000000000001', 'd1300000-0000-4000-8000-000000000001', 'Tortilla'),
  ('b1300000-0000-4000-8000-000000000002', 'd1300000-0000-4000-8000-000000000001', 'Lentejas');

select is((select public from storage.buckets where id = 'recipe-images'), false, 'the bucket is private');

set local role authenticated;
set local request.jwt.claims to '{"sub":"c1300000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ----------------------------------------------------------------- storage
select lives_ok(
  $$insert into storage.objects (bucket_id, name) values
    ('recipe-images', 'd1300000-0000-4000-8000-000000000001/b1300000-0000-4000-8000-000000000001/cover.jpg'),
    ('recipe-images', 'd1300000-0000-4000-8000-000000000001/b1300000-0000-4000-8000-000000000001/photo.jpg'),
    ('recipe-images', 'd1300000-0000-4000-8000-000000000001/b1300000-0000-4000-8000-000000000002/other.jpg')$$,
  'members upload into their household folder');
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values
    ('recipe-images', 'd1300000-0000-4000-8000-000000000002/b1300000-0000-4000-8000-000000000001/x.jpg')$$,
  '42501', null, 'uploads into another household''s folder are rejected');

-- ----------------------------------------------------------------- MCP cover rules
select is((public.mcp_recipes_missing_cover() -> 0 ->> 'name'), 'Lentejas', 'recipes without cover, by name');
select throws_ok(
  $$select public.mcp_set_recipe_cover('b1300000-0000-4000-8000-000000000001',
    'd1300000-0000-4000-8000-000000000001/b1300000-0000-4000-8000-000000000002/other.jpg')$$,
  '22023', null, 'the image must be in the recipe''s own folder');
select throws_ok(
  $$select public.mcp_set_recipe_cover('b1300000-0000-4000-8000-000000000001',
    'd1300000-0000-4000-8000-000000000001/b1300000-0000-4000-8000-000000000001/missing.jpg')$$,
  'P0002', null, 'the image must have been uploaded');
select is(
  (public.mcp_set_recipe_cover('b1300000-0000-4000-8000-000000000001',
    'd1300000-0000-4000-8000-000000000001/b1300000-0000-4000-8000-000000000001/cover.jpg') ->> 'replaced')::boolean,
  false, 'an agent sets a cover on a recipe without one');
select is((select image_source from public.recipes where id = 'b1300000-0000-4000-8000-000000000001'), 'ai',
  'the cover is marked as AI-made');
update public.recipes set image_source = 'photo' where id = 'b1300000-0000-4000-8000-000000000001';
select throws_ok(
  $$select public.mcp_set_recipe_cover('b1300000-0000-4000-8000-000000000001',
    'd1300000-0000-4000-8000-000000000001/b1300000-0000-4000-8000-000000000001/photo.jpg')$$,
  '55000', null, 'an existing cover (a photo) is kept unless overwrite');
select is(
  (public.mcp_set_recipe_cover('b1300000-0000-4000-8000-000000000001',
    'd1300000-0000-4000-8000-000000000001/b1300000-0000-4000-8000-000000000001/photo.jpg', true) ->> 'replaced')::boolean,
  true, 'overwrite replaces it');

-- ----------------------------------------------------------------- recipe_photos
select ok(
  (public.mcp_add_recipe_photo('b1300000-0000-4000-8000-000000000001',
    'd1300000-0000-4000-8000-000000000001/b1300000-0000-4000-8000-000000000001/photo.jpg', 1600, 1200)
    ->> 'photo_id') is not null,
  'add_recipe_photo adds to the gallery');
select ok((select server_seq > 0 from public.recipe_photos limit 1), 'recipe_photos rows get a server_seq');
select ok(
  exists (select 1 from jsonb_array_elements(public.pull_changes(0, 1000) -> 'rows') r
          where r ->> 'table' = 'recipe_photos'),
  'pull_changes includes recipe_photos');
select is(
  jsonb_array_length(public.apply_mutations(null, jsonb_build_array(jsonb_build_object(
    'table', 'recipe_photos', 'id', 'e1300000-0000-4000-8000-000000000001', 'op', 'upsert',
    'client_ts', now(),
    'fields', jsonb_build_object('household_id', 'd1300000-0000-4000-8000-000000000001',
      'recipe_id', 'b1300000-0000-4000-8000-000000000002',
      'storage_path', 'd1300000-0000-4000-8000-000000000001/b1300000-0000-4000-8000-000000000002/other.jpg')
  ))) -> 'applied'), 1, 'apps push recipe_photos through apply_mutations');

update public.recipes set deleted_at = now() where id = 'b1300000-0000-4000-8000-000000000002';
select is(
  (select count(*)::integer from public.recipe_photos
   where recipe_id = 'b1300000-0000-4000-8000-000000000002' and deleted_at is null),
  0, 'tombstoning a recipe tombstones its photos');

set local request.jwt.claims to '{"sub":"c1300000-0000-4000-8000-000000000002","role":"authenticated"}';
select is((select count(*)::integer from public.recipe_photos), 0, 'other households see no photos');

select * from finish();
rollback;
