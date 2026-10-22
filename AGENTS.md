# Koda backend repository instructions

Backend of Koda, a private household app (first module: Comidita — recipes, meal planning and shopping list) for two people. Supabase: Postgres + Auth + Deno Edge Functions. The iPhone/Mac app lives in `../koda-app-ios-macos`; the authoritative plan is `../PLAN.md` (sections 3, 6, 8, 11 and 12 concern this repo).

## Invariants

- **Single Supabase environment**: one hosted project, `koda`. No dev/staging. The app (Debug and TestFlight), the MCP and the scripts all point at it. `supabase start` (Docker) exists only to run tests and smoke checks; nothing ever points the app at it.
- **RLS always**: every table has RLS enabled; authorization lives in policies, never in function code. See rule `rls-policies`.
- **User JWT in functions**: user-facing functions (`api`, `mcp`) create the Supabase client with the caller's `Authorization` header (`createUserClient`). The secret key is only used by internal functions (`push`, `keepalive`, protected by `x-koda-secret`) and by `scripts/`.
- **No secrets in git**: keys, `.p8`, `.env*` (except `.env.example`), dumps and Notion data are ignored. Secrets live in `supabase secrets`, Vault and GitHub Actions secrets. Never print or copy the APNs `.p8`.
- **Dump before db push**: `scripts/backup.sh` before every `supabase db push`. Migrations are additive; anything destructive needs a dump and explicit approval.
- **Sync contract is shared with the apps**: see rule and skill `sync-contract`. `server_seq` order equals commit order; clients never hard-delete; conflict rules live in `apply_mutations`.
- **Local only for agents**: do not run `supabase link`, `db push`, `functions deploy` or other remote commands unless the user explicitly asks. `seed.sql` is test data and never goes to `koda`.
- Bundle id / APNs topic: `com.kodalabs.app` (iOS and macOS). Apple team `MUDCX7X324`.
- English for code, comments, docs and commit messages. Conventional Commits (`feat(sync): …`, `test(db): …`, `chore(ai): …`).

## Project map

- `supabase/config.toml`: local stack config (sign-ups disabled, email/password only, OAuth server enabled for the future MCP, `verify_jwt = false` on all functions because they authenticate themselves).
- `supabase/migrations/`:
  - `…01_extensions` pg_trgm, unaccent, pg_net, pg_cron, schema `private`, `normalize_text`.
  - `…02_core_schema` enums, households/profiles/members, `household_ids_for_user()`, synced tables, `sync_seq` + `private.sync_row()`, cascade tombstones, indexes.
  - `…03_rls` policies and grants.
  - `…04_domain_functions` anti-cycle trigger, `recipe_tree`, `recipe_flat_ingredients`, `recipe_stats` view, `match_product`, `accept_meal_plan_draft`, `discard_meal_plan_draft`, `shopping_from_plan`, `get_me`.
  - `…05_sync_rpc` `apply_mutations`, `pull_changes`, purge watermark.
  - `…06_push` `devices`, `register_device`, `push_queue` + enqueue trigger, `claim_push_batch`, `push_devices_for_households`, `purge_tombstones`, Vault-driven pg_cron jobs.
- `supabase/seed.sql`: local-only household "Casa (local)" with `a@koda.test` / `b@koda.test` (password `koda-local-password`) and sample data.
- `supabase/tests/database/*.test.sql`: pgTAP (RLS isolation, recipe components, stats/matching, drafts/shopping, apply_mutations conflicts, server_seq/pull/push queue/purge).
- `supabase/functions/`: `api` (Hono routes in `app.ts`), `push` (`handler.ts`), `keepalive`, `mcp` (skeleton, phase 6), `_shared/` (deps, env, clients, errors, validation, apns, `domain/`). `.env.example` lists the function secrets.
- `tests/functions`, `tests/scripts`: Deno unit tests (no network).
- `scripts/`: `create-user.ts`, `import-notion.ts` (+ `lib/notion_import.ts`), `backup.sh`.
- `.github/workflows/`: weekly `backup.yml`, daily `keepalive.yml`.

### API (`/functions/v1/api`)

`GET /health` · `GET /me` · `POST /sync/push` · `GET /sync/pull?cursor&limit` · `PUT /devices` · `DELETE /devices/:id` · `POST /drafts/:id/accept|discard` · `POST /recipes/:id/expand` · `POST /shopping/from-plan`.

## Commands

```bash
supabase start                      # local stack (Docker)
supabase db reset                   # re-apply migrations + seed
supabase test db                    # pgTAP
deno task test                      # Deno unit tests
deno task check && deno task lint   # type-check and lint functions, tests, scripts
supabase functions serve --env-file supabase/functions/.env
supabase stop
```

Deploy (user-driven): `scripts/backup.sh` → `supabase db push` → `supabase functions deploy`. Details and secrets in `README.md`.

## AI configuration

`.agents/` is canonical: `rules/` (`supabase-migrations`, `edge-functions`, `rls-policies`, `sync-contract`) and `skills/<name>/SKILL.md` (`supabase-migrations`, `edge-functions`, `sync-contract`, `apns`, `mcp-tools`). Tool folders are relative symlinks: `.claude/{rules,skills}`, `.cursor/rules/<rule>.mdc`, `.cursor/skills`, `.cursor/mcp.json -> ../.mcp.json`, `.agent/skills`, `.continue/skills`, `.windsurf/skills`; `CLAUDE.md -> AGENTS.md`. `.codex/config.toml` is a real file. Edit only the canonical files and add a `.cursor/rules/<rule>.mdc` symlink for every new rule.

## MCP

`.mcp.json` / `.codex/config.toml` register `supabase-local`, the MCP endpoint of the local stack (`http://127.0.0.1:54321/mcp`, available after `supabase start`). The hosted project is operated by the user, not wired into this repository.
