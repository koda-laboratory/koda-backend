---
name: supabase-migrations
description: Create, test and deploy Koda Postgres migrations with the Supabase CLI — new migration files, tables/enums/functions/views, RLS, pgTAP tests in supabase/tests/database, local reset, and the dump → db push procedure for the single `koda` project. Use for any schema or SQL function change. Not for Edge Function code (edge-functions) or the client sync protocol (sync-contract).
---

# Supabase migrations

Follow rules [`supabase-migrations`](../../rules/supabase-migrations.md) and [`rls-policies`](../../rules/rls-policies.md).

## Workflow

1. `supabase start` (Docker must be running).
2. `supabase migration new <name>` → write SQL in `supabase/migrations/<timestamp>_<name>.sql`.
3. `supabase db reset` — re-applies every migration plus `seed.sql`. Must finish without errors.
4. Add or update pgTAP tests in `supabase/tests/database/NN_<topic>.test.sql` and run `supabase test db`.
5. If an Edge Function uses the change, update `_shared/` and run `deno task test`.
6. Commit migration + tests together.

## Deploy (only when the user asks)

1. `scripts/backup.sh` (dump roles, schema and data into ignored `backups/`).
2. `supabase db push` (review the list of pending migrations first; `--dry-run` shows it).
3. `supabase functions deploy` if functions changed.

The hosted project may also be operated through the Supabase MCP by the user; the same order applies.

## pgTAP conventions

```sql
begin;
create extension if not exists pgtap with schema extensions;
select plan(N);
-- fixtures as postgres (auth.users, households, household_members, data)
set local role authenticated;
set local request.jwt.claims to '{"sub":"<user uuid>","role":"authenticated"}';
-- assertions run with RLS
reset role;
select * from finish();
rollback;
```

- Use fixed UUIDs, distinct from `seed.sql` ones; tests must not depend on seed data.
- Check errors with `throws_ok(sql, 'SQLSTATE', null, description)`.
- Cover two households for anything RLS-related.

## Patterns

- Synced table template: copy `public.products` in `20261022000002_core_schema.sql` (columns, `unique (id, household_id)`, composite FKs, triggers, indexes) and follow skill `sync-contract`.
- Domain function template: `public.accept_meal_plan_draft` (plpgsql, `security invoker`, `search_path = ''`, explicit SQLSTATEs, revoke/grant block).
- Service-only function template: `public.purge_tombstones` (`security definer`, revoked from `authenticated`, granted to `service_role`).
- Scheduled jobs: `cron.schedule(name, cron, $$select private.<fn>()$$)`; URLs and secrets from Vault via `private.vault_secret`.
