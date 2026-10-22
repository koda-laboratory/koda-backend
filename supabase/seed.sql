-- LOCAL ONLY seed (supabase start / supabase db reset). Never load into the `koda` project.
-- One household, two fake users (password: koda-local-password) and a small catalog.

-- ---------------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change,
  email_change_token_current, phone_change, phone_change_token, reauthentication_token
)
select
  '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email,
  extensions.crypt('koda-local-password', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
  '', '', '', '', '', '', '', ''
from (values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid, 'a@koda.test'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid, 'b@koda.test')
) as u (id, email);

insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), u.id, u.id::text,
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
  'email', now(), now(), now()
from auth.users u
where u.email in ('a@koda.test', 'b@koda.test');

-- ---------------------------------------------------------------------------
-- Household
-- ---------------------------------------------------------------------------
insert into public.households (id, name) values ('11111111-1111-4111-8111-111111111111', 'Casa (local)');

insert into public.profiles (id, display_name, avatar_emoji) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Ana', '🦊'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'Bruno', '🐻');

insert into public.household_members (household_id, user_id, role) values
  ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'owner'),
  ('11111111-1111-4111-8111-111111111111', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'member');

-- ---------------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------------
insert into public.stores (id, household_id, name, color) values
  ('51000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'Mercadona', '#2E7D32'),
  ('51000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'Aldi', '#1565C0');

insert into public.products (id, household_id, name, category, default_unit, price_total, emoji) values
  ('52000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'Leche entera', 'basics', 'l', 0.95, '🥛'),
  ('52000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'Huevos', 'basics', 'ud', 2.40, '🥚'),
  ('52000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'Muslos de pollo', 'food', 'g', 4.20, '🍗'),
  ('52000000-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'Patatas', 'food', 'g', 1.99, '🥔'),
  ('52000000-0000-4000-8000-000000000005', '11111111-1111-4111-8111-111111111111', 'Lentejas', 'food', 'g', 1.30, null),
  ('52000000-0000-4000-8000-000000000006', '11111111-1111-4111-8111-111111111111', 'Plátano', 'food', 'ud', 1.80, '🍌'),
  ('52000000-0000-4000-8000-000000000007', '11111111-1111-4111-8111-111111111111', 'Aceite de oliva', 'kitchen', 'ml', 7.50, '🫒'),
  ('52000000-0000-4000-8000-000000000008', '11111111-1111-4111-8111-111111111111', 'Lavavajillas', 'cleaning', 'ud', 3.10, null);

insert into public.product_stores (household_id, product_id, store_id) values
  ('11111111-1111-4111-8111-111111111111', '52000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000001'),
  ('11111111-1111-4111-8111-111111111111', '52000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000002'),
  ('11111111-1111-4111-8111-111111111111', '52000000-0000-4000-8000-000000000003', '51000000-0000-4000-8000-000000000001');

-- ---------------------------------------------------------------------------
-- Recipes: "Pollo al horno" includes "Patatas al airfryer"
-- ---------------------------------------------------------------------------
insert into public.recipes (id, household_id, name, meal_types, nutrients, time_minutes, servings, steps, emoji) values
  ('53000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'Pollo al horno',
    array['lunch', 'dinner'], array['protein'], 60, 2,
    '["Precalentar el horno a 200 ºC", "Hornear el pollo 45 minutos"]', '🍗'),
  ('53000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'Patatas al airfryer',
    array['lunch', 'dinner'], array['carbs'], 25, 2, '["Cortar las patatas", "Airfryer 20 minutos a 190 ºC"]', '🥔'),
  ('53000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'Lentejas estofadas',
    array['lunch'], array['protein', 'fiber', 'vegetables'], 50, 4, '[]', '🍲');

insert into public.recipe_ingredients (household_id, recipe_id, product_id, quantity, unit, position) values
  ('11111111-1111-4111-8111-111111111111', '53000000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000003', 600, 'g', 0),
  ('11111111-1111-4111-8111-111111111111', '53000000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000007', 20, 'ml', 1),
  ('11111111-1111-4111-8111-111111111111', '53000000-0000-4000-8000-000000000002', '52000000-0000-4000-8000-000000000004', 400, 'g', 0),
  ('11111111-1111-4111-8111-111111111111', '53000000-0000-4000-8000-000000000002', '52000000-0000-4000-8000-000000000007', 10, 'ml', 1),
  ('11111111-1111-4111-8111-111111111111', '53000000-0000-4000-8000-000000000003', '52000000-0000-4000-8000-000000000005', 300, 'g', 0);

insert into public.recipe_components (household_id, parent_recipe_id, child_recipe_id, servings_factor) values
  ('11111111-1111-4111-8111-111111111111', '53000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000002', 1);

-- ---------------------------------------------------------------------------
-- Planning, history and shopping list
-- ---------------------------------------------------------------------------
insert into public.meal_plan_entries (id, household_id, date, slot, recipe_id, servings) values
  ('54000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', current_date, 'lunch',
    '53000000-0000-4000-8000-000000000001', 2),
  ('54000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', current_date + 1, 'dinner',
    '53000000-0000-4000-8000-000000000003', 2);

insert into public.consumptions (household_id, recipe_id, eaten_on, slot, servings) values
  ('11111111-1111-4111-8111-111111111111', '53000000-0000-4000-8000-000000000003', current_date - 20, 'lunch', 4);

insert into public.shopping_entries (household_id, kind, product_id, quantity, unit, position) values
  ('11111111-1111-4111-8111-111111111111', 'product', '52000000-0000-4000-8000-000000000001', 2, 'l', 0);
insert into public.shopping_entries (household_id, kind, text, position) values
  ('11111111-1111-4111-8111-111111111111', 'text', 'Pan de pueblo', 1);

-- Seed writes are not user activity: drop the queued silent pushes.
delete from public.push_queue;
