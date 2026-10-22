-- Household settings (PLAN.md 3.6): meal times per slot and the default shopping weekday.
--
--   slot_times        {"breakfast":"HH:MM","lunch":"HH:MM","snack":"HH:MM","dinner":"HH:MM"}, local time of
--                     each meal in the household timezone. Used to auto-log consumptions and to compute
--                     defrost reminders; meal_plan_entries.scheduled_time overrides it per entry.
--   shopping_weekday  ISO weekday (1 = Monday … 7 = Sunday) of the usual shopping day. Only used by the
--                     apps to propose the range when generating the shopping list from the planning.

alter table public.households
  add column slot_times jsonb not null
    default '{"breakfast":"09:00","lunch":"14:30","snack":"18:00","dinner":"21:30"}'::jsonb,
  add column shopping_weekday smallint not null default 5;

alter table public.households
  add constraint households_shopping_weekday_check check (shopping_weekday between 1 and 7),
  add constraint households_slot_times_check check (
    jsonb_typeof(slot_times) = 'object'
    and slot_times ?& array['breakfast', 'lunch', 'snack', 'dinner']
    and slot_times - array['breakfast', 'lunch', 'snack', 'dinner'] = '{}'::jsonb
    and slot_times ->> 'breakfast' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    and slot_times ->> 'lunch' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    and slot_times ->> 'snack' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    and slot_times ->> 'dinner' ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
  );

-- ---------------------------------------------------------------------------
-- /me: households include their settings
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
        'slot_times', h.slot_times,
        'shopping_weekday', h.shopping_weekday,
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

-- ---------------------------------------------------------------------------
-- update_household_settings
-- ---------------------------------------------------------------------------
-- Any member may change the settings (renaming the household stays owner-only through RLS), so this
-- function is SECURITY DEFINER and checks membership itself. p_slot_times may contain a subset of the
-- four slots; it is merged into the current value. Null arguments keep the current value.
-- Returns the household object exactly as get_me() lists it.
create or replace function public.update_household_settings(
  p_household_id uuid,
  p_slot_times jsonb default null,
  p_shopping_weekday smallint default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_key text;
  v_value jsonb;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if p_household_id is null or not exists (
    select 1 from public.household_members hm
    where hm.household_id = p_household_id and hm.user_id = auth.uid()
  ) then
    raise exception 'household % not found', p_household_id using errcode = 'no_data_found';
  end if;

  if p_slot_times is not null then
    if jsonb_typeof(p_slot_times) <> 'object' then
      raise exception 'slot_times must be an object' using errcode = 'invalid_parameter_value';
    end if;
    for v_key, v_value in select e.key, e.value from jsonb_each(p_slot_times) e loop
      if v_key not in ('breakfast', 'lunch', 'snack', 'dinner') then
        raise exception 'unknown slot %', v_key using errcode = 'invalid_parameter_value';
      end if;
      if jsonb_typeof(v_value) <> 'string' or not (v_value #>> '{}') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
        raise exception 'slot % must be HH:MM', v_key using errcode = 'invalid_parameter_value';
      end if;
    end loop;
  end if;
  if p_shopping_weekday is not null and p_shopping_weekday not between 1 and 7 then
    raise exception 'shopping_weekday must be between 1 and 7' using errcode = 'invalid_parameter_value';
  end if;

  update public.households h
  set slot_times = h.slot_times || coalesce(p_slot_times, '{}'::jsonb),
      shopping_weekday = coalesce(p_shopping_weekday, h.shopping_weekday)
  where h.id = p_household_id;

  return (
    select x.value
    from jsonb_array_elements(public.get_me() -> 'households') x
    where x.value ->> 'id' = p_household_id::text
  );
end;
$$;

revoke execute on function public.update_household_settings(uuid, jsonb, smallint) from public, anon;
grant execute on function public.update_household_settings(uuid, jsonb, smallint) to authenticated, service_role;
