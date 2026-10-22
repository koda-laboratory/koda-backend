-- Domain views and functions. All of them are SECURITY INVOKER (RLS applies) unless stated.

-- ---------------------------------------------------------------------------
-- Anti-cycle trigger for recipe_components
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER so the walk sees every component regardless of RLS (composite FKs already
-- guarantee both recipes belong to the same household).
create or replace function private.prevent_recipe_cycles()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.deleted_at is not null then
    return new;
  end if;
  if new.parent_recipe_id = new.child_recipe_id then
    raise exception 'a recipe cannot include itself' using errcode = 'check_violation';
  end if;
  if exists (
    with recursive descendants (id) as (
      select new.child_recipe_id
      union
      select c.child_recipe_id
      from public.recipe_components c
      join descendants d on c.parent_recipe_id = d.id
      where c.deleted_at is null and c.id <> new.id
    )
    select 1 from descendants where id = new.parent_recipe_id
  ) then
    raise exception 'recipe_components cycle: % already includes %', new.child_recipe_id, new.parent_recipe_id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger t20_prevent_cycles before insert or update on public.recipe_components
  for each row execute function private.prevent_recipe_cycles();

-- ---------------------------------------------------------------------------
-- Recipe tree and flattened ingredients
-- ---------------------------------------------------------------------------
-- The root recipe (depth 0) and every live sub-recipe, with the cumulative servings factor.
create or replace function public.recipe_tree(p_recipe_id uuid)
returns table (
  recipe_id uuid,
  parent_recipe_id uuid,
  name text,
  depth integer,
  servings_factor numeric,
  path uuid[]
)
language sql
stable
security invoker
set search_path = ''
as $$
  with recursive tree as (
    select r.id as recipe_id, null::uuid as parent_recipe_id, r.name, 0 as depth,
           1::numeric as servings_factor, array[r.id] as path, array[0] as sort_key
    from public.recipes r
    where r.id = p_recipe_id and r.deleted_at is null
    union all
    select c.child_recipe_id, c.parent_recipe_id, child.name, t.depth + 1,
           t.servings_factor * c.servings_factor, t.path || c.child_recipe_id, t.sort_key || c.position
    from tree t
    join public.recipe_components c on c.parent_recipe_id = t.recipe_id and c.deleted_at is null
    join public.recipes child on child.id = c.child_recipe_id and child.deleted_at is null
    where not (c.child_recipe_id = any (t.path)) and t.depth < 16
  )
  select tree.recipe_id, tree.parent_recipe_id, tree.name, tree.depth, tree.servings_factor, tree.path
  from tree
  order by tree.sort_key, tree.depth;
$$;

-- Products aggregated over the whole tree, grouped by product and unit.
-- p_servings scales quantities relative to the root recipe's servings (null = as written).
create or replace function public.recipe_flat_ingredients(p_recipe_id uuid, p_servings numeric default null)
returns table (
  product_id uuid,
  product_name text,
  unit text,
  quantity numeric,
  recipe_ids uuid[]
)
language sql
stable
security invoker
set search_path = ''
as $$
  with tree as (
    select * from public.recipe_tree(p_recipe_id)
  ),
  scale as (
    select case when p_servings is null then 1::numeric else p_servings / r.servings end as k
    from public.recipes r
    where r.id = p_recipe_id
  )
  select i.product_id, p.name, i.unit,
         sum(i.quantity * t.servings_factor * s.k) as quantity,
         array_agg(distinct t.recipe_id) as recipe_ids
  from tree t
  join public.recipe_ingredients i on i.recipe_id = t.recipe_id and i.deleted_at is null
  join public.products p on p.id = i.product_id and p.deleted_at is null
  cross join scale s
  group by i.product_id, p.name, i.unit
  order by p.name, i.unit;
$$;

-- ---------------------------------------------------------------------------
-- Recipe statistics
-- ---------------------------------------------------------------------------
-- eaten_last_14d counts consumptions in the last 14 days (today included, household timezone).
create or replace view public.recipe_stats
with (security_invoker = true)
as
select
  r.id as recipe_id,
  r.household_id,
  count(c.id)::integer as times_eaten,
  max(c.eaten_on) as last_eaten_on,
  (count(c.id) filter (
    where c.eaten_on > (now() at time zone h.timezone)::date - 14
  ))::integer as eaten_last_14d
from public.recipes r
join public.households h on h.id = r.household_id
left join public.consumptions c on c.recipe_id = r.id and c.deleted_at is null
where r.deleted_at is null
group by r.id, r.household_id;

revoke all on public.recipe_stats from anon;
grant select on public.recipe_stats to authenticated;

-- ---------------------------------------------------------------------------
-- Product matching (Siri, MCP): accent and case insensitive, fuzzy.
-- ---------------------------------------------------------------------------
create or replace function public.match_product(p_name text, p_limit integer default 5)
returns table (
  product_id uuid,
  name text,
  category public.product_category,
  score real
)
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (select public.normalize_text(btrim(p_name)) as n),
  candidates as (
    select p.id, p.name, p.category, public.normalize_text(p.name) as pn, q.n
    from public.products p, q
    where p.deleted_at is null and q.n <> ''
  ),
  scored as (
    select c.id, c.name, c.category,
      case
        when c.pn = c.n then 1.0
        when c.pn like c.n || '%' then 0.9
        when c.pn like '%' || c.n || '%' then 0.8
        else greatest(extensions.similarity(c.pn, c.n), extensions.word_similarity(c.n, c.pn) * 0.9)
      end::real as score
    from candidates c
  )
  select s.id, s.name, s.category, s.score
  from scored s
  where s.score >= 0.3
  order by s.score desc, length(s.name), s.name
  limit greatest(1, least(coalesce(p_limit, 5), 50));
$$;

-- ---------------------------------------------------------------------------
-- Meal plan drafts
-- ---------------------------------------------------------------------------
-- Promotes the draft's entries to the planning (they keep their date/slot) in one transaction.
-- Existing planning entries are kept: the draft adds, it never silently replaces.
create or replace function public.accept_meal_plan_draft(p_draft_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_status public.draft_status;
  v_count integer;
begin
  select d.status into v_status
  from public.meal_plan_drafts d
  where d.id = p_draft_id and d.deleted_at is null
  for update;

  if not found then
    raise exception 'draft % not found', p_draft_id using errcode = 'no_data_found';
  end if;
  if v_status <> 'pending' then
    raise exception 'draft % is %', p_draft_id, v_status using errcode = 'object_not_in_prerequisite_state';
  end if;

  update public.meal_plan_entries
  set draft_id = null
  where draft_id = p_draft_id and deleted_at is null;
  get diagnostics v_count = row_count;

  update public.meal_plan_drafts set status = 'accepted' where id = p_draft_id;
  return v_count;
end;
$$;

-- Marks the draft as discarded and tombstones its entries.
create or replace function public.discard_meal_plan_draft(p_draft_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_status public.draft_status;
  v_count integer;
begin
  select d.status into v_status
  from public.meal_plan_drafts d
  where d.id = p_draft_id and d.deleted_at is null
  for update;

  if not found then
    raise exception 'draft % not found', p_draft_id using errcode = 'no_data_found';
  end if;
  if v_status <> 'pending' then
    raise exception 'draft % is %', p_draft_id, v_status using errcode = 'object_not_in_prerequisite_state';
  end if;

  update public.meal_plan_entries
  set deleted_at = now()
  where draft_id = p_draft_id and deleted_at is null;
  get diagnostics v_count = row_count;

  update public.meal_plan_drafts set status = 'discarded' where id = p_draft_id;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Shopping list from the planning
-- ---------------------------------------------------------------------------
-- Creates one kind='recipe' shopping entry (with flattened items) per planned recipe in
-- [p_from, p_to]. Planning entries that already have a live shopping entry are skipped.
create or replace function public.shopping_from_plan(p_from date, p_to date)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_entry record;
  v_entry_id uuid;
  v_ids uuid[] := '{}';
  v_label text;
  v_position integer;
begin
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'invalid date range' using errcode = 'invalid_parameter_value';
  end if;
  if p_to - p_from > 62 then
    raise exception 'date range too large' using errcode = 'invalid_parameter_value';
  end if;

  for v_entry in
    select e.id, e.household_id, e.recipe_id, coalesce(e.servings, r.servings) as servings
    from public.meal_plan_entries e
    join public.recipes r on r.id = e.recipe_id and r.deleted_at is null
    where e.date between p_from and p_to
      and e.deleted_at is null
      and e.draft_id is null
      and not exists (
        select 1 from public.shopping_entries s
        where s.meal_plan_entry_id = e.id and s.deleted_at is null
      )
    order by e.date, e.slot, e.position
  loop
    select string_agg(t.name, ' + ' order by t.depth, t.path) into v_label
    from public.recipe_tree(v_entry.recipe_id) t;

    select coalesce(max(s.position), -1) + 1 into v_position
    from public.shopping_entries s
    where s.household_id = v_entry.household_id and s.deleted_at is null;

    v_entry_id := gen_random_uuid();
    insert into public.shopping_entries (
      id, household_id, kind, recipe_id, text, quantity, unit, source, meal_plan_entry_id,
      name_updated_at, position
    ) values (
      v_entry_id, v_entry.household_id, 'recipe', v_entry.recipe_id, v_label, v_entry.servings, 'servings',
      'plan', v_entry.id, now(), v_position
    );

    insert into public.shopping_entry_items (household_id, entry_id, product_id, quantity, unit)
    select v_entry.household_id, v_entry_id, f.product_id, f.quantity, f.unit
    from public.recipe_flat_ingredients(v_entry.recipe_id, v_entry.servings) f;

    v_ids := v_ids || v_entry_id;
  end loop;

  return jsonb_build_object('created', coalesce(array_length(v_ids, 1), 0), 'entry_ids', to_jsonb(v_ids));
end;
$$;

-- ---------------------------------------------------------------------------
-- /me
-- ---------------------------------------------------------------------------
create or replace function public.get_me()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'user_id', (select auth.uid()),
    'profile', (
      select jsonb_build_object('id', p.id, 'display_name', p.display_name, 'avatar_emoji', p.avatar_emoji)
      from public.profiles p where p.id = (select auth.uid())
    ),
    'households', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', h.id,
        'name', h.name,
        'timezone', h.timezone,
        'role', me.role,
        'members', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'user_id', m.user_id,
            'role', m.role,
            'display_name', pr.display_name,
            'avatar_emoji', pr.avatar_emoji
          ) order by m.created_at), '[]'::jsonb)
          from public.household_members m
          left join public.profiles pr on pr.id = m.user_id
          where m.household_id = h.id
        )
      ) order by h.created_at)
      from public.household_members me
      join public.households h on h.id = me.household_id
      where me.user_id = (select auth.uid())
    ), '[]'::jsonb)
  );
$$;

-- Function privileges: authenticated only.
revoke execute on function
  public.recipe_tree(uuid),
  public.recipe_flat_ingredients(uuid, numeric),
  public.match_product(text, integer),
  public.accept_meal_plan_draft(uuid),
  public.discard_meal_plan_draft(uuid),
  public.shopping_from_plan(date, date),
  public.get_me(),
  public.normalize_text(text)
from public, anon;
grant execute on function
  public.recipe_tree(uuid),
  public.recipe_flat_ingredients(uuid, numeric),
  public.match_product(text, integer),
  public.accept_meal_plan_draft(uuid),
  public.discard_meal_plan_draft(uuid),
  public.shopping_from_plan(date, date),
  public.get_me(),
  public.normalize_text(text)
to authenticated, service_role;
