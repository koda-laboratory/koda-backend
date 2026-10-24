-- MCP tools (PLAN.md section 8): one Postgres function per tool.
--
-- Every function is SECURITY INVOKER: it runs with the caller's OAuth access token, so RLS limits it to the
-- caller's household exactly like the apps. Writes go through the usual triggers (server_seq, push queue,
-- frozen items), so the apps see them within seconds. Each tool is one transaction.
--
-- Koda households have one shared plan; a user belongs to one household, so writes use the caller's first
-- (and only) household.

create or replace function public.mcp_household_id()
returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select h into v_id from public.household_ids_for_user() h limit 1;
  if v_id is null then
    raise exception 'the user does not belong to a household' using errcode = 'insufficient_privilege';
  end if;
  return v_id;
end;
$$;

-- Today in the household's time zone.
create or replace function public.mcp_today()
returns date
language sql
stable
security invoker
set search_path = ''
as $$
  select (now() at time zone h.timezone)::date
  from public.households h
  where h.id = public.mcp_household_id();
$$;

-- ---------------------------------------------------------------------------
-- Meals
-- ---------------------------------------------------------------------------
create or replace function public.mcp_get_meals(p_from date, p_to date default null, p_slot text default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_to date := coalesce(p_to, p_from);
begin
  if p_from is null or v_to < p_from then
    raise exception 'invalid date range' using errcode = 'invalid_parameter_value';
  end if;
  if v_to - p_from > 62 then
    raise exception 'date range too large (max 62 days)' using errcode = 'invalid_parameter_value';
  end if;
  if p_slot is not null and p_slot not in ('breakfast', 'lunch', 'snack', 'dinner') then
    raise exception 'invalid slot %', p_slot using errcode = 'invalid_parameter_value';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', e.id,
      'date', e.date,
      'slot', e.slot,
      'time', to_char(coalesce(e.scheduled_time, (h.slot_times ->> e.slot::text)::time), 'HH24:MI'),
      'recipe_id', e.recipe_id,
      'recipe', r.name,
      'free_text', e.free_text,
      'servings', e.servings,
      'note', e.note,
      'skipped', e.skipped_at is not null,
      'eaten', exists (
        select 1 from public.consumptions c where c.meal_plan_entry_id = e.id and c.deleted_at is null
      )
    ) order by e.date, e.slot, e.position)
    from public.meal_plan_entries e
    join public.households h on h.id = e.household_id
    left join public.recipes r on r.id = e.recipe_id
    where e.deleted_at is null
      and e.draft_id is null
      and e.date between p_from and v_to
      and (p_slot is null or e.slot::text = p_slot)
  ), '[]'::jsonb);
end;
$$;

create or replace function public.mcp_plan_meal(
  p_date date,
  p_slot text,
  p_recipe_id uuid default null,
  p_free_text text default null,
  p_servings numeric default null,
  p_time time default null,
  p_note text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household uuid := public.mcp_household_id();
  v_id uuid := gen_random_uuid();
  v_position integer;
  v_text text := nullif(btrim(p_free_text), '');
begin
  if p_date is null or p_slot not in ('breakfast', 'lunch', 'snack', 'dinner') then
    raise exception 'a date and a slot (breakfast, lunch, snack, dinner) are required'
      using errcode = 'invalid_parameter_value';
  end if;
  if (p_recipe_id is null) = (v_text is null) then
    raise exception 'give either a recipe or a free text, not both' using errcode = 'invalid_parameter_value';
  end if;

  select coalesce(max(e.position), -1) + 1 into v_position
  from public.meal_plan_entries e
  where e.household_id = v_household and e.date = p_date and e.slot::text = p_slot and e.deleted_at is null;

  insert into public.meal_plan_entries (
    id, household_id, date, slot, recipe_id, free_text, servings, scheduled_time, note, position
  ) values (
    v_id, v_household, p_date, p_slot::public.meal_slot, p_recipe_id, v_text, p_servings, p_time,
    nullif(btrim(p_note), ''), v_position
  );

  return (select m from jsonb_array_elements(public.mcp_get_meals(p_date, p_date, p_slot)) m
          where m ->> 'id' = v_id::text);
end;
$$;

create or replace function public.mcp_remove_planned_meal(p_entry_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.meal_plan_entries
  set deleted_at = now()
  where id = p_entry_id and deleted_at is null and draft_id is null;
  return found;
end;
$$;

create or replace function public.mcp_meal_history(p_from date, p_to date default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_to date := coalesce(p_to, p_from);
begin
  if p_from is null or v_to < p_from or v_to - p_from > 366 then
    raise exception 'invalid date range (max 366 days)' using errcode = 'invalid_parameter_value';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'date', c.eaten_on, 'slot', c.slot, 'recipe_id', c.recipe_id, 'recipe', r.name, 'servings', c.servings
    ) order by c.eaten_on, c.slot)
    from public.consumptions c
    join public.recipes r on r.id = c.recipe_id
    where c.deleted_at is null and c.eaten_on between p_from and v_to
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Recipes
-- ---------------------------------------------------------------------------
create or replace function public.mcp_search_recipes(
  p_query text default null,
  p_meal_type text default null,
  p_nutrients text[] default null,
  p_max_minutes integer default null,
  p_favorites_only boolean default false,
  p_limit integer default 25
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (select public.normalize_text(btrim(coalesce(p_query, ''))) as n)
  select coalesce(jsonb_agg(row_to_json(x)::jsonb order by x.relevance desc, x.name), '[]'::jsonb)
  from (
    select r.id, r.name, r.meal_types, r.nutrients, nullif(r.time_minutes, 0) as time_minutes, r.servings,
      r.is_favorite, r.image_path is not null as has_cover,
      coalesce(s.times_eaten, 0) as times_eaten, s.last_eaten_on,
      case
        when q.n = '' then 0
        when public.normalize_text(r.name) like '%' || q.n || '%' then 1
        else extensions.word_similarity(q.n, public.normalize_text(r.name))
      end as relevance
    from public.recipes r
    cross join q
    left join public.recipe_stats s on s.recipe_id = r.id
    where r.deleted_at is null
      and (p_meal_type is null or p_meal_type = any (r.meal_types))
      and (p_nutrients is null or r.nutrients @> p_nutrients)
      and (p_max_minutes is null or (r.time_minutes > 0 and r.time_minutes <= p_max_minutes))
      and (not coalesce(p_favorites_only, false) or r.is_favorite)
      and (
        q.n = ''
        or public.normalize_text(r.name) like '%' || q.n || '%'
        or extensions.word_similarity(q.n, public.normalize_text(r.name)) >= 0.4
        or exists (
          select 1 from public.recipe_ingredients i
          join public.products p on p.id = i.product_id
          where i.recipe_id = r.id and i.deleted_at is null
            and public.normalize_text(p.name) like '%' || q.n || '%'
        )
      )
    order by relevance desc, r.name
    limit greatest(1, least(coalesce(p_limit, 25), 200))
  ) x;
$$;

-- Resolves a recipe reference (id or name) to ranked candidates; the MCP server picks a clear winner or asks.
create or replace function public.mcp_resolve_recipe(p_ref text)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (select public.normalize_text(btrim(p_ref)) as n)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'score', c.score)
    order by c.score desc, length(c.name)), '[]'::jsonb)
  from (
    select r.id, r.name,
      case
        when r.id::text = btrim(p_ref) then 2.0
        when public.normalize_text(r.name) = q.n then 1.0
        when public.normalize_text(r.name) like q.n || '%' then 0.9
        when public.normalize_text(r.name) like '%' || q.n || '%' then 0.8
        else extensions.word_similarity(q.n, public.normalize_text(r.name))
      end::real as score
    from public.recipes r, q
    where r.deleted_at is null and q.n <> ''
  ) c
  where c.score >= 0.4
  limit 5;
$$;

create or replace function public.mcp_get_recipe(p_recipe_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'id', r.id,
    'name', r.name,
    'meal_types', r.meal_types,
    'nutrients', r.nutrients,
    'time_minutes', nullif(r.time_minutes, 0),
    'servings', r.servings,
    'is_favorite', r.is_favorite,
    'has_cover', r.image_path is not null,
    'steps', r.steps,
    'notes', r.notes,
    'ingredients', coalesce((
      select jsonb_agg(jsonb_build_object('product', p.name, 'quantity', i.quantity, 'unit', i.unit)
        order by i.position, p.name)
      from public.recipe_ingredients i
      join public.products p on p.id = i.product_id
      where i.recipe_id = r.id and i.deleted_at is null
    ), '[]'::jsonb),
    'includes_recipes', coalesce((
      select jsonb_agg(jsonb_build_object('recipe_id', c.child_recipe_id, 'name', cr.name,
        'servings_factor', c.servings_factor) order by c.position)
      from public.recipe_components c
      join public.recipes cr on cr.id = c.child_recipe_id and cr.deleted_at is null
      where c.parent_recipe_id = r.id and c.deleted_at is null
    ), '[]'::jsonb),
    'all_ingredients', coalesce((
      select jsonb_agg(jsonb_build_object('product', f.product_name, 'quantity', f.quantity, 'unit', f.unit)
        order by f.product_name)
      from public.recipe_flat_ingredients(r.id, null) f
    ), '[]'::jsonb),
    'times_eaten', coalesce(s.times_eaten, 0),
    'last_eaten_on', s.last_eaten_on
  )
  from public.recipes r
  left join public.recipe_stats s on s.recipe_id = r.id
  where r.id = p_recipe_id and r.deleted_at is null;
$$;

create or replace function public.mcp_recipe_stats(p_not_eaten_since_days integer default null, p_limit integer default 50)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(row_to_json(x)::jsonb order by x.last_eaten_on nulls first, x.name), '[]'::jsonb)
  from (
    select r.id, r.name, r.meal_types, coalesce(s.times_eaten, 0) as times_eaten, s.last_eaten_on,
      coalesce(s.eaten_last_14d, 0) as eaten_last_14d
    from public.recipes r
    left join public.recipe_stats s on s.recipe_id = r.id
    where r.deleted_at is null
      and (
        p_not_eaten_since_days is null
        or s.last_eaten_on is null
        or s.last_eaten_on < public.mcp_today() - p_not_eaten_since_days
      )
    order by s.last_eaten_on nulls first, r.name
    limit greatest(1, least(coalesce(p_limit, 50), 500))
  ) x;
$$;

-- ---------------------------------------------------------------------------
-- Shopping list
-- ---------------------------------------------------------------------------
create or replace function public.mcp_shopping_list(p_include_done boolean default false)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'kind', s.kind,
    'name', coalesce(p.name, s.text),
    'quantity', s.quantity,
    'unit', s.unit,
    'status', s.status,
    'source', s.source,
    'items', case when s.kind = 'recipe' then coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'name', ip.name, 'quantity', i.quantity, 'unit', i.unit,
        'status', i.status) order by ip.name)
      from public.shopping_entry_items i
      join public.products ip on ip.id = i.product_id
      where i.entry_id = s.id and i.deleted_at is null and (coalesce(p_include_done, false) or i.status = 'pending')
    ), '[]'::jsonb) end
  ) order by s.position), '[]'::jsonb)
  from public.shopping_entries s
  left join public.products p on p.id = s.product_id
  where s.deleted_at is null and (coalesce(p_include_done, false) or s.status <> 'have');
$$;

-- Adds products (matched against the catalog) or free texts. A product already pending on the list is not
-- added twice.
create or replace function public.mcp_add_shopping_items(p_items jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household uuid := public.mcp_household_id();
  v_item jsonb;
  v_name text;
  v_match record;
  v_existing uuid;
  v_id uuid;
  v_position integer;
  v_results jsonb := '[]'::jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'items must be a non-empty array' using errcode = 'invalid_parameter_value';
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_name := btrim(coalesce(v_item ->> 'name', ''));
    if v_name = '' then
      raise exception 'every item needs a name' using errcode = 'invalid_parameter_value';
    end if;

    select m.product_id, m.name into v_match
    from public.match_product(v_name, 1) m
    where m.score >= 0.9;

    select coalesce(max(s.position), -1) + 1 into v_position
    from public.shopping_entries s
    where s.household_id = v_household and s.deleted_at is null;

    if v_match.product_id is not null then
      select s.id into v_existing
      from public.shopping_entries s
      where s.household_id = v_household and s.deleted_at is null and s.kind = 'product'
        and s.product_id = v_match.product_id and s.status = 'pending'
      limit 1;
      if v_existing is not null then
        v_results := v_results || jsonb_build_object('name', v_match.name, 'entry_id', v_existing,
          'matched_product', true, 'status', 'already_on_list');
        continue;
      end if;
      v_id := gen_random_uuid();
      insert into public.shopping_entries (
        id, household_id, kind, product_id, quantity, unit, source, name_updated_at, position
      ) values (
        v_id, v_household, 'product', v_match.product_id, (v_item ->> 'quantity')::numeric,
        nullif(btrim(v_item ->> 'unit'), ''), 'mcp', now(), v_position
      );
      v_results := v_results || jsonb_build_object('name', v_match.name, 'entry_id', v_id,
        'matched_product', true, 'status', 'added');
    else
      v_id := gen_random_uuid();
      insert into public.shopping_entries (
        id, household_id, kind, text, quantity, unit, source, name_updated_at, position
      ) values (
        v_id, v_household, 'text', v_name, (v_item ->> 'quantity')::numeric,
        nullif(btrim(v_item ->> 'unit'), ''), 'mcp', now(), v_position
      );
      v_results := v_results || jsonb_build_object('name', v_name, 'entry_id', v_id,
        'matched_product', false, 'status', 'added');
    end if;
  end loop;

  return v_results;
end;
$$;

-- Sets the status of entries and/or recipe items: 'pending' (to buy), 'have' (bought or at home) or 'frozen'
-- (in the freezer; the frozen_items trigger schedules the defrost reminder).
create or replace function public.mcp_set_shopping_status(p_ids uuid[], p_status text)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_entries integer;
  v_items integer;
begin
  if p_status not in ('pending', 'have', 'frozen') then
    raise exception 'status must be pending, have or frozen' using errcode = 'invalid_parameter_value';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 then
    raise exception 'ids must not be empty' using errcode = 'invalid_parameter_value';
  end if;

  update public.shopping_entries
  set status = p_status, checked_at = now()
  where id = any (p_ids) and deleted_at is null and status <> p_status;
  get diagnostics v_entries = row_count;

  update public.shopping_entry_items
  set status = p_status, checked_at = now()
  where id = any (p_ids) and deleted_at is null and status <> p_status;
  get diagnostics v_items = row_count;

  return jsonb_build_object('updated', v_entries + v_items);
end;
$$;

-- One grouped entry with the recipe's flattened products (sub-recipes expanded), like "Generar compra".
create or replace function public.mcp_add_recipe_to_shopping(p_recipe_id uuid, p_servings numeric default null)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household uuid := public.mcp_household_id();
  v_servings numeric;
  v_label text;
  v_position integer;
  v_id uuid := gen_random_uuid();
  v_items integer;
begin
  select coalesce(p_servings, r.servings) into v_servings
  from public.recipes r
  where r.id = p_recipe_id and r.deleted_at is null;
  if not found then
    raise exception 'recipe not found' using errcode = 'no_data_found';
  end if;

  select string_agg(t.name, ' + ' order by t.depth, t.path) into v_label from public.recipe_tree(p_recipe_id) t;

  select coalesce(max(s.position), -1) + 1 into v_position
  from public.shopping_entries s
  where s.household_id = v_household and s.deleted_at is null;

  insert into public.shopping_entries (
    id, household_id, kind, recipe_id, text, quantity, unit, source, name_updated_at, position
  ) values (
    v_id, v_household, 'recipe', p_recipe_id, v_label, v_servings, 'servings', 'mcp', now(), v_position
  );

  insert into public.shopping_entry_items (household_id, entry_id, product_id, quantity, unit)
  select v_household, v_id, f.product_id, f.quantity, f.unit
  from public.recipe_flat_ingredients(p_recipe_id, v_servings) f;
  get diagnostics v_items = row_count;

  return jsonb_build_object('entry_id', v_id, 'name', v_label, 'servings', v_servings, 'products', v_items);
end;
$$;

-- ---------------------------------------------------------------------------
-- Meal plan drafts
-- ---------------------------------------------------------------------------
-- A proposal the household reviews in the app: it never touches the planning until accepted.
create or replace function public.mcp_create_meal_plan_draft(
  p_from date,
  p_to date,
  p_entries jsonb,
  p_rationale text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household uuid := public.mcp_household_id();
  v_draft uuid := gen_random_uuid();
  v_entry jsonb;
  v_date date;
  v_slot text;
  v_recipe uuid;
  v_text text;
  v_count integer := 0;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 31 then
    raise exception 'invalid date range (max 31 days)' using errcode = 'invalid_parameter_value';
  end if;
  if p_entries is null or jsonb_typeof(p_entries) <> 'array' or jsonb_array_length(p_entries) = 0 then
    raise exception 'entries must be a non-empty array' using errcode = 'invalid_parameter_value';
  end if;

  insert into public.meal_plan_drafts (id, household_id, from_date, to_date, source, rationale)
  values (v_draft, v_household, p_from, p_to, 'mcp', nullif(btrim(p_rationale), ''));

  for v_entry in select * from jsonb_array_elements(p_entries) loop
    v_date := (v_entry ->> 'date')::date;
    v_slot := v_entry ->> 'slot';
    v_recipe := nullif(v_entry ->> 'recipe_id', '')::uuid;
    v_text := nullif(btrim(v_entry ->> 'free_text'), '');
    if v_date is null or v_date < p_from or v_date > p_to then
      raise exception 'entry date % is outside the draft range', v_date using errcode = 'invalid_parameter_value';
    end if;
    if v_slot not in ('breakfast', 'lunch', 'snack', 'dinner') then
      raise exception 'invalid slot %', v_slot using errcode = 'invalid_parameter_value';
    end if;
    if (v_recipe is null) = (v_text is null) then
      raise exception 'each entry needs either recipe_id or free_text' using errcode = 'invalid_parameter_value';
    end if;
    insert into public.meal_plan_entries (household_id, date, slot, recipe_id, free_text, servings, note, draft_id,
      position)
    values (v_household, v_date, v_slot::public.meal_slot, v_recipe, v_text, (v_entry ->> 'servings')::numeric,
      nullif(btrim(v_entry ->> 'note'), ''), v_draft, v_count);
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('draft_id', v_draft, 'entries', v_count, 'status', 'pending');
end;
$$;

create or replace function public.mcp_list_drafts()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'from', d.from_date, 'to', d.to_date, 'source', d.source, 'rationale', d.rationale,
    'created_at', d.created_at,
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object('date', e.date, 'slot', e.slot, 'recipe', r.name,
        'free_text', e.free_text, 'servings', e.servings) order by e.date, e.slot, e.position)
      from public.meal_plan_entries e
      left join public.recipes r on r.id = e.recipe_id
      where e.draft_id = d.id and e.deleted_at is null
    ), '[]'::jsonb)
  ) order by d.created_at desc), '[]'::jsonb)
  from public.meal_plan_drafts d
  where d.deleted_at is null and d.status = 'pending';
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'mcp_household_id()', 'mcp_today()', 'mcp_get_meals(date, date, text)',
    'mcp_plan_meal(date, text, uuid, text, numeric, time, text)', 'mcp_remove_planned_meal(uuid)',
    'mcp_meal_history(date, date)', 'mcp_search_recipes(text, text, text[], integer, boolean, integer)',
    'mcp_resolve_recipe(text)', 'mcp_get_recipe(uuid)', 'mcp_recipe_stats(integer, integer)',
    'mcp_shopping_list(boolean)', 'mcp_add_shopping_items(jsonb)', 'mcp_set_shopping_status(uuid[], text)',
    'mcp_add_recipe_to_shopping(uuid, numeric)', 'mcp_create_meal_plan_draft(date, date, jsonb, text)',
    'mcp_list_drafts()'
  ] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;
