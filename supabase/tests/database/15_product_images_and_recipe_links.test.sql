-- Product images (storage isolation, product_photos sync, cascade, orphans) and recipe video links.
begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

insert into auth.users (id, email, aud, role) values
  ('c1500000-0000-4000-8000-000000000001', 'pimg1@koda.test', 'authenticated', 'authenticated'),
  ('c1500000-0000-4000-8000-000000000002', 'pimg2@koda.test', 'authenticated', 'authenticated');
insert into public.households (id, name) values
  ('d1500000-0000-4000-8000-000000000001', 'Products house'),
  ('d1500000-0000-4000-8000-000000000002', 'Other house');
insert into public.household_members (household_id, user_id, role) values
  ('d1500000-0000-4000-8000-000000000001', 'c1500000-0000-4000-8000-000000000001', 'owner'),
  ('d1500000-0000-4000-8000-000000000002', 'c1500000-0000-4000-8000-000000000002', 'owner');
insert into public.products (id, household_id, name) values
  ('a1500000-0000-4000-8000-000000000001', 'd1500000-0000-4000-8000-000000000001', 'Aguja de ternera'),
  ('a1500000-0000-4000-8000-000000000002', 'd1500000-0000-4000-8000-000000000001', 'Yogur griego');
insert into public.recipes (id, household_id, name) values
  ('b1500000-0000-4000-8000-000000000001', 'd1500000-0000-4000-8000-000000000001', 'Albóndigas');

select is((select public from storage.buckets where id = 'product-images'), false, 'the product bucket is private');
select ok('product_photos' = any (public.synced_tables()), 'product_photos is a synced table');
select ok(
  array_position(public.synced_tables(), 'recipe_links') > array_position(public.synced_tables(), 'recipes'),
  'recipe_links syncs after recipes');

set local role authenticated;
set local request.jwt.claims to '{"sub":"c1500000-0000-4000-8000-000000000001","role":"authenticated"}';

-- ----------------------------------------------------------------- storage
select lives_ok(
  $$insert into storage.objects (bucket_id, name) values
    ('product-images', 'd1500000-0000-4000-8000-000000000001/a1500000-0000-4000-8000-000000000001/front.jpg')$$,
  'members upload into their household folder');
select throws_ok(
  $$insert into storage.objects (bucket_id, name) values
    ('product-images', 'd1500000-0000-4000-8000-000000000002/a1500000-0000-4000-8000-000000000001/x.jpg')$$,
  '42501', null, 'uploads into another household''s folder are rejected');

-- ----------------------------------------------------------------- product cover and photos
select lives_ok(
  $$update public.products set image_path =
      'd1500000-0000-4000-8000-000000000001/a1500000-0000-4000-8000-000000000001/front.jpg', image_source = 'photo'
    where id = 'a1500000-0000-4000-8000-000000000001'$$,
  'a product gets a photo cover');
select throws_ok(
  $$update public.products set image_source = 'other' where id = 'a1500000-0000-4000-8000-000000000001'$$,
  '23514', null, 'image_source is photo or ai');
select is(
  jsonb_array_length(public.apply_mutations(null, jsonb_build_array(jsonb_build_object(
    'table', 'product_photos', 'id', 'e1500000-0000-4000-8000-000000000001', 'op', 'upsert',
    'client_ts', now(),
    'fields', jsonb_build_object('household_id', 'd1500000-0000-4000-8000-000000000001',
      'product_id', 'a1500000-0000-4000-8000-000000000002',
      'storage_path', 'd1500000-0000-4000-8000-000000000001/a1500000-0000-4000-8000-000000000002/pack.jpg',
      'width', 1600, 'height', 1200)
  ))) -> 'applied'), 1, 'apps push product_photos through apply_mutations');
select ok((select server_seq > 0 from public.product_photos limit 1), 'product_photos rows get a server_seq');
select ok(
  exists (select 1 from jsonb_array_elements(public.pull_changes(0, 1000) -> 'rows') r
          where r ->> 'table' = 'product_photos'),
  'pull_changes includes product_photos');
update public.products set deleted_at = now() where id = 'a1500000-0000-4000-8000-000000000002';
select is(
  (select count(*)::integer from public.product_photos
   where product_id = 'a1500000-0000-4000-8000-000000000002' and deleted_at is null),
  0, 'tombstoning a product tombstones its photos');

-- ----------------------------------------------------------------- recipe_links
select is(
  jsonb_array_length(public.apply_mutations(null, jsonb_build_array(jsonb_build_object(
    'table', 'recipe_links', 'id', 'f1500000-0000-4000-8000-000000000001', 'op', 'upsert',
    'client_ts', now(),
    'fields', jsonb_build_object('household_id', 'd1500000-0000-4000-8000-000000000001',
      'recipe_id', 'b1500000-0000-4000-8000-000000000001',
      'url', 'https://www.tiktok.com/@cocinaconana/video/7412345678901234567')
  ))) -> 'applied'), 1, 'apps push recipe_links through apply_mutations');
select throws_ok(
  $$insert into public.recipe_links (household_id, recipe_id, url) values
    ('d1500000-0000-4000-8000-000000000001', 'b1500000-0000-4000-8000-000000000001', 'javascript:alert(1)')$$,
  '23514', null, 'only http(s) links are accepted');
select ok(
  exists (select 1 from jsonb_array_elements(public.pull_changes(0, 1000) -> 'rows') r
          where r ->> 'table' = 'recipe_links'),
  'pull_changes includes recipe_links');
update public.recipes set deleted_at = now() where id = 'b1500000-0000-4000-8000-000000000001';
select is(
  (select count(*)::integer from public.recipe_links where deleted_at is null),
  0, 'tombstoning a recipe tombstones its links');

set local request.jwt.claims to '{"sub":"c1500000-0000-4000-8000-000000000002","role":"authenticated"}';
select is((select count(*)::integer from public.product_photos), 0, 'other households see no product photos');

-- ----------------------------------------------------------------- orphans (service role)
reset role;
update storage.objects set created_at = now() - interval '4 days' where bucket_id = 'product-images';
insert into storage.objects (bucket_id, name, created_at) values
  ('product-images', 'd1500000-0000-4000-8000-000000000001/a1500000-0000-4000-8000-000000000001/old.jpg',
   now() - interval '4 days');
select results_eq(
  $$select * from public.orphan_product_images()$$,
  array['d1500000-0000-4000-8000-000000000001/a1500000-0000-4000-8000-000000000001/old.jpg']::text[],
  'only images no live product or photo points to are orphans');

select * from finish();
rollback;
