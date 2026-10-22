-- Row Level Security: enabled on every table.
-- Synced tables: rows are visible and writable only for members of the owning household.
-- Clients never hard-delete synced rows (they write tombstones), so there is no DELETE policy.

-- Households: members read; owners rename.
alter table public.households enable row level security;
create policy households_select on public.households for select to authenticated
  using (id in (select public.household_ids_for_user()));
create policy households_update on public.households for update to authenticated
  using (id in (
    select hm.household_id from public.household_members hm
    where hm.user_id = (select auth.uid()) and hm.role = 'owner'
  ))
  with check (id in (select public.household_ids_for_user()));

-- Profiles: own profile and profiles of people sharing a household.
alter table public.profiles enable row level security;
create policy profiles_select on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or id in (
      select hm.user_id from public.household_members hm
      where hm.household_id in (select public.household_ids_for_user())
    )
  );
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Membership: members see the members of their households. Managed with the secret key only.
alter table public.household_members enable row level security;
create policy household_members_select on public.household_members for select to authenticated
  using (household_id in (select public.household_ids_for_user()));

revoke all on public.households, public.profiles, public.household_members from anon;
grant select, update on public.households to authenticated;
grant select, update on public.profiles to authenticated;
grant select on public.household_members to authenticated;

do $$
declare
  t text;
begin
  foreach t in array array[
    'stores', 'products', 'product_stores', 'recipes', 'recipe_ingredients', 'recipe_components',
    'meal_plan_drafts', 'meal_plan_entries', 'consumptions', 'shopping_entries', 'shopping_entry_items'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (household_id in (select public.household_ids_for_user()))',
      t || '_select', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated with check (household_id in (select public.household_ids_for_user()))',
      t || '_insert', t);
    execute format(
      'create policy %I on public.%I for update to authenticated using (household_id in (select public.household_ids_for_user())) with check (household_id in (select public.household_ids_for_user()))',
      t || '_update', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke delete, truncate on public.%I from authenticated', t);
    execute format('grant select, insert, update on public.%I to authenticated', t);
  end loop;
end;
$$;

revoke execute on function public.household_ids_for_user() from public, anon;
grant execute on function public.household_ids_for_user() to authenticated;
