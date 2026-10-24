-- Recipe image cleanup (PLAN.md phase 6b).
--
-- Deleting a gallery photo, replacing a cover or deleting a recipe leaves the image in the `recipe-images` bucket.
-- `orphan_recipe_images` lists the objects no live row points to; the daily `keepalive` function removes them through
-- the Storage API (objects must not be deleted with SQL: the files would stay behind).
--
-- Only objects older than `p_min_age` count: the apps upload a photo independently of the outbox, so for a while an
-- image can exist before its `recipe_photos` row reaches the server.

create or replace function public.orphan_recipe_images(
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
  where o.bucket_id = 'recipe-images'
    and o.created_at < now() - p_min_age
    and not exists (
      select 1 from public.recipe_photos p where p.storage_path = o.name and p.deleted_at is null
    )
    and not exists (
      select 1 from public.recipes r where r.image_path = o.name and r.deleted_at is null
    )
  order by o.created_at
  limit greatest(coalesce(p_limit, 500), 0);
$$;

revoke execute on function public.orphan_recipe_images(interval, integer) from public, anon, authenticated;
grant execute on function public.orphan_recipe_images(interval, integer) to service_role;
