---
description: Write additive, tested Supabase migrations for Koda's single production database
globs: supabase/migrations/**,supabase/seed.sql,supabase/tests/**
alwaysApply: false
---

# Supabase migrations

There is exactly one Supabase project (`koda`) and it holds real data. Docker (`supabase start`) exists only to run tests.

- Create files with `supabase migration new <snake_case_name>`; never edit a migration that has been pushed. Fix forward with a new one.
- Additive by default: add tables, columns (nullable or with defaults), indexes, functions. Renames, drops, type changes and data rewrites need an explicit plan, a fresh dump (`scripts/backup.sh`) and the user's approval.
- Every new synced table follows the sync conventions in [`sync-contract`](sync-contract.md) and gets RLS per [`rls-policies`](rls-policies.md) in the same migration.
- Functions: `set search_path = ''`, schema-qualify everything (`public.`, `extensions.`, `auth.uid()`), `security invoker` unless there is a documented reason. After creating a function, `revoke execute ... from public, anon` and grant only to the roles that need it (Supabase grants EXECUTE to `anon` by default).
- Internal helpers live in schema `private` (not exposed by the Data API). Trigger functions may live there.
- Extensions go to schema `extensions` (`pg_cron` to `pg_catalog`).
- Use SQLSTATE codes the API maps (`errors.ts`): `P0002` not found, `55000` wrong state, `22023` invalid input, `23514` constraint, `42501` forbidden.
- Never put secrets in migrations; read them from Vault (`private.vault_secret`).
- `seed.sql` is local-only test data with fake `@koda.test` users. It must never be loaded into `koda`.

Verification before any push: `supabase db reset` applies cleanly and `supabase test db` passes. Deploy order: `scripts/backup.sh` → `supabase db push` → `supabase functions deploy`.
