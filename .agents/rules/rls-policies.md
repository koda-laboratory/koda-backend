---
description: Row Level Security is mandatory on every Koda table and is the only authorization layer
globs: supabase/migrations/**,supabase/tests/**,supabase/functions/**
alwaysApply: false
---

# RLS policies

- `alter table ... enable row level security` in the same migration that creates the table. pgTAP test `01_rls_isolation` asserts that no `public` table lacks RLS.
- Household data: `household_id in (select public.household_ids_for_user())` for `select`, `insert` (with check) and `update` (using + with check). Wrap `auth.uid()` and the helper in `select` so Postgres caches them per statement.
- Per-user data (`devices`): `user_id = (select auth.uid())`.
- Synced tables have no `delete` policy and `delete`/`truncate` are revoked from `authenticated`: clients write tombstones (`deleted_at`). Hard deletes only happen in `public.purge_tombstones()` (service role).
- Internal tables (`push_queue`, `private.*`) have RLS on and no policies; only `security definer` functions and the secret key touch them.
- Revoke everything from `anon` on new tables and functions; grant `authenticated` only what the policies need.
- `security definer` functions must set `search_path = ''`, validate `auth.uid()` when they act for a user, and be revoked from `public`/`anon` (and from `authenticated` when they are service-only).
- Child tables carry `household_id` and composite foreign keys `(parent_id, household_id) → parent(id, household_id)`, so a row can never point to another household's data.
- Edge Functions never bypass RLS for user requests: they use `createUserClient` (caller's JWT). The secret key is only for `push`, `keepalive` and scripts.
- Every policy change needs a pgTAP test that proves isolation between two households.
