-- Product images and recipe video links.
--
--   * Product images mirror recipe images (20261024000012): a private bucket `product-images` with objects at
--     `<household_id>/<product_id>/<uuid>.<ext>`, a cover in products.image_path (+ image_source) and a gallery in
--     the new synced table product_photos. The photos let the household recognise the exact product (brand,
--     package) when buying it.
--   * recipe_links: links to short videos of a recipe (TikTok, Instagram reels, YouTube shorts). The app derives
--     the platform and the account from the URL, so only the URL is stored.
--
-- Both tables join the sync contract: synced_tables, pull_changes, purge order, push triggers and a cascade
-- tombstone with their parent. orphan_product_images feeds the keepalive cleanup like orphan_recipe_images.

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy product_images_select on storage.objects for select to authenticated
  using (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] in (select h::text from public.household_ids_for_user() h)
  );
create policy product_images_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] in (select h::text from public.household_ids_for_user() h)
  );
create policy product_images_update on storage.objects for update to authenticated
  using (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] in (select h::text from public.household_ids_for_user() h)
  )
  with check (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] in (select h::text from public.household_ids_for_user() h)
  );
create policy product_images_delete on storage.objects for delete to authenticated
  using (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] in (select h::text from public.household_ids_for_user() h)
  );

-- ---------------------------------------------------------------------------
-- Product cover
-- ---------------------------------------------------------------------------
alter table public.products add column image_path text;
alter table public.products add column image_source text;
alter table public.products
  add constraint products_image_source_check check (image_source in ('photo', 'ai'));

-- ---------------------------------------------------------------------------
-- product_photos (synced)
-- ---------------------------------------------------------------------------
create table public.product_photos (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  product_id uuid not null,
  storage_path text not null check (length(btrim(storage_path)) > 0),
  width integer check (width > 0),
  height integer check (height > 0),
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users (id) on delete set null,
  deleted_at timestamptz,
  client_updated_at timestamptz,
  server_seq bigint not null default 0,
  unique (id, household_id),
  foreign key (product_id, household_id) references public.products (id, household_id) on delete cascade
);

create trigger t10_sync_row before insert or update on public.product_photos
  for each row execute function private.sync_row();
create index product_photos_household_id_idx on public.product_photos (household_id);
create index product_photos_server_seq_idx on public.product_photos (server_seq);
create index product_photos_deleted_at_idx on public.product_photos (deleted_at) where deleted_at is not null;
create index product_photos_product_id_idx on public.product_photos (product_id);

create trigger t90_enqueue_push after insert or update on public.product_photos
  for each row execute function private.enqueue_sync_push('catalog');
create trigger t35_tombstone_product_photos after update of deleted_at on public.products
  for each row execute function private.cascade_tombstone('product_photos', 'product_id');

alter table public.product_photos enable row level security;
create policy product_photos_select on public.product_photos for select to authenticated
  using (household_id in (select public.household_ids_for_user()));
create policy product_photos_insert on public.product_photos for insert to authenticated
  with check (household_id in (select public.household_ids_for_user()));
create policy product_photos_update on public.product_photos for update to authenticated
  using (household_id in (select public.household_ids_for_user()))
  with check (household_id in (select public.household_ids_for_user()));
revoke all on public.product_photos from anon;
revoke delete, truncate on public.product_photos from authenticated;
grant select, insert, update on public.product_photos to authenticated;

-- ---------------------------------------------------------------------------
-- recipe_links (synced)
-- ---------------------------------------------------------------------------
create table public.recipe_links (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  recipe_id uuid not null,
  url text not null check (url ~* '^https?://\S+$' and length(url) <= 2048),
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references auth.users (id) on delete set null,
  deleted_at timestamptz,
  client_updated_at timestamptz,
  server_seq bigint not null default 0,
  unique (id, household_id),
  foreign key (recipe_id, household_id) references public.recipes (id, household_id) on delete cascade
);

create trigger t10_sync_row before insert or update on public.recipe_links
  for each row execute function private.sync_row();
create index recipe_links_household_id_idx on public.recipe_links (household_id);
create index recipe_links_server_seq_idx on public.recipe_links (server_seq);
create index recipe_links_deleted_at_idx on public.recipe_links (deleted_at) where deleted_at is not null;
create index recipe_links_recipe_id_idx on public.recipe_links (recipe_id);

create trigger t90_enqueue_push after insert or update on public.recipe_links
  for each row execute function private.enqueue_sync_push('recipes');
create trigger t36_tombstone_recipe_links after update of deleted_at on public.recipes
  for each row execute function private.cascade_tombstone('recipe_links', 'recipe_id');

alter table public.recipe_links enable row level security;
create policy recipe_links_select on public.recipe_links for select to authenticated
  using (household_id in (select public.household_ids_for_user()));
create policy recipe_links_insert on public.recipe_links for insert to authenticated
  with check (household_id in (select public.household_ids_for_user()));
create policy recipe_links_update on public.recipe_links for update to authenticated
  using (household_id in (select public.household_ids_for_user()))
  with check (household_id in (select public.household_ids_for_user()));
revoke all on public.recipe_links from anon;
revoke delete, truncate on public.recipe_links from authenticated;
grant select, insert, update on public.recipe_links to authenticated;

-- ---------------------------------------------------------------------------
-- Synced table list, pull and purge (product_photos after product_stores, recipe_links after recipe_photos)
-- ---------------------------------------------------------------------------
create or replace function public.synced_tables()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
    'stores', 'products', 'product_stores', 'product_photos', 'recipes', 'recipe_ingredients', 'recipe_components',
    'recipe_photos', 'recipe_links', 'meal_plan_drafts', 'meal_plan_entries', 'consumptions', 'shopping_entries',
    'shopping_entry_items', 'frozen_items'
  ]::text[];
$$;

create or replace function public.pull_changes(p_cursor bigint default 0, p_limit integer default 500)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_cursor bigint := greatest(coalesce(p_cursor, 0), 0);
  v_limit integer := greatest(1, least(coalesce(p_limit, 500), 1000));
  v_rows jsonb;
  v_count integer;
  v_has_more boolean;
  v_watermark bigint := public.sync_purge_watermark();
begin
  with changes as (
    select 'stores' as t, x.server_seq, to_jsonb(x) as r from public.stores x where x.server_seq > v_cursor
    union all
    select 'products', x.server_seq, to_jsonb(x) from public.products x where x.server_seq > v_cursor
    union all
    select 'product_stores', x.server_seq, to_jsonb(x) from public.product_stores x where x.server_seq > v_cursor
    union all
    select 'product_photos', x.server_seq, to_jsonb(x) from public.product_photos x where x.server_seq > v_cursor
    union all
    select 'recipes', x.server_seq, to_jsonb(x) from public.recipes x where x.server_seq > v_cursor
    union all
    select 'recipe_ingredients', x.server_seq, to_jsonb(x) from public.recipe_ingredients x where x.server_seq > v_cursor
    union all
    select 'recipe_components', x.server_seq, to_jsonb(x) from public.recipe_components x where x.server_seq > v_cursor
    union all
    select 'recipe_photos', x.server_seq, to_jsonb(x) from public.recipe_photos x where x.server_seq > v_cursor
    union all
    select 'recipe_links', x.server_seq, to_jsonb(x) from public.recipe_links x where x.server_seq > v_cursor
    union all
    select 'meal_plan_drafts', x.server_seq, to_jsonb(x) from public.meal_plan_drafts x where x.server_seq > v_cursor
    union all
    select 'meal_plan_entries', x.server_seq, to_jsonb(x) from public.meal_plan_entries x where x.server_seq > v_cursor
    union all
    select 'consumptions', x.server_seq, to_jsonb(x) from public.consumptions x where x.server_seq > v_cursor
    union all
    select 'shopping_entries', x.server_seq, to_jsonb(x) from public.shopping_entries x where x.server_seq > v_cursor
    union all
    select 'shopping_entry_items', x.server_seq, to_jsonb(x) from public.shopping_entry_items x where x.server_seq > v_cursor
    union all
    select 'frozen_items', x.server_seq, to_jsonb(x) from public.frozen_items x where x.server_seq > v_cursor
  ),
  page as (
    select * from changes order by server_seq limit v_limit + 1
  )
  select coalesce(jsonb_agg(jsonb_build_object('table', page.t, 'row', page.r) order by page.server_seq), '[]'::jsonb),
         count(*)
  into v_rows, v_count
  from page;

  v_has_more := v_count > v_limit;
  if v_has_more then
    v_rows := v_rows - v_limit;
  end if;

  return jsonb_build_object(
    'rows', v_rows,
    'has_more', v_has_more,
    'cursor', coalesce((v_rows -> -1 -> 'row' ->> 'server_seq')::bigint, v_cursor),
    'reset_required', v_cursor > 0 and v_cursor < v_watermark
  );
end;
$$;

create or replace function public.purge_tombstones(p_older_than interval default interval '30 days')
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_cutoff timestamptz := now() - p_older_than;
  v_table text;
  v_count bigint;
  v_max bigint;
  v_watermark bigint := 0;
  v_counts jsonb := '{}'::jsonb;
  v_queue bigint;
begin
  foreach v_table in array array[
    'frozen_items', 'shopping_entry_items', 'shopping_entries', 'consumptions', 'meal_plan_entries', 'meal_plan_drafts',
    'recipe_links', 'recipe_photos', 'recipe_components', 'recipe_ingredients', 'recipes', 'product_photos',
    'product_stores', 'products', 'stores'
  ] loop
    execute format(
      'with d as (delete from public.%I where deleted_at < $1 returning server_seq) select count(*), max(server_seq) from d',
      v_table
    ) into v_count, v_max using v_cutoff;
    v_counts := v_counts || jsonb_build_object(v_table, v_count);
    v_watermark := greatest(v_watermark, coalesce(v_max, 0));
  end loop;

  with d as (delete from public.push_queue where sent_at < now() - interval '7 days' returning 1)
  select count(*) into v_queue from d;

  update private.sync_state
  set purge_watermark = greatest(purge_watermark, v_watermark),
      last_purge_at = now(),
      keepalive_at = now()
  where id;

  return jsonb_build_object(
    'purged', v_counts,
    'push_queue_trimmed', v_queue,
    'watermark', public.sync_purge_watermark(),
    'at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Orphan product images (removed by keepalive through the Storage API)
-- ---------------------------------------------------------------------------
-- Only objects older than p_min_age count: the apps upload a photo independently of the outbox, so for a while an
-- image can exist before its product_photos row reaches the server.
create or replace function public.orphan_product_images(
  p_min_age interval default interval '3 days',
  p_limit integer default 500
)
returns setof text
language sql
stable
security invoker
set search_path = ''
as $$
  select o.name
  from storage.objects o
  where o.bucket_id = 'product-images'
    and o.created_at < now() - p_min_age
    and not exists (
      select 1 from public.product_photos p where p.storage_path = o.name and p.deleted_at is null
    )
    and not exists (
      select 1 from public.products r where r.image_path = o.name and r.deleted_at is null
    )
  order by o.created_at
  limit greatest(coalesce(p_limit, 500), 0);
$$;

revoke execute on function public.orphan_product_images(interval, integer) from public, anon, authenticated;
grant execute on function public.orphan_product_images(interval, integer) to service_role;
