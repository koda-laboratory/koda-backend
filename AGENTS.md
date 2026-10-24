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

- `supabase/config.toml`: local stack config (sign-ups disabled, email/password only, OAuth server enabled for the MCP, `verify_jwt = false` on all functions because they authenticate themselves).
- `supabase/migrations/`:
  - `…01_extensions` pg_trgm, unaccent, pg_net, pg_cron, schema `private`, `normalize_text`.
  - `…02_core_schema` enums, households/profiles/members, `household_ids_for_user()`, synced tables, `sync_seq` + `private.sync_row()`, cascade tombstones, indexes.
  - `…03_rls` policies and grants.
  - `…04_domain_functions` anti-cycle trigger, `recipe_tree`, `recipe_flat_ingredients`, `recipe_stats` view, `match_product`, `accept_meal_plan_draft`, `discard_meal_plan_draft`, `shopping_from_plan`, `get_me`.
  - `…05_sync_rpc` `apply_mutations`, `pull_changes`, purge watermark.
  - `…06_push` `devices`, `register_device`, `push_queue` + enqueue trigger, `claim_push_batch`, `push_devices_for_households`, `purge_tombstones`, Vault-driven pg_cron jobs.
  - `…07_household_settings` `households.slot_times` / `shopping_weekday`, `get_me` with settings, `update_household_settings`.
  - `…08_auto_consumptions` `meal_plan_entries.scheduled_time` / `skipped_at`, `consumptions.source` + live unique index per entry, `private.meal_starts_at`, `auto_log_consumptions` (pg_cron every 15 min).
  - `…09_shopping_status` `status` (`pending|have|frozen`) on `shopping_entries` / `shopping_entry_items` kept consistent with `checked`, `apply_mutations` with `status` in the `checked_at` group and the `frozen_items` write rules.
  - `…10_frozen_items` synced `frozen_items` (server-maintained, linking/relinking triggers), `push_queue.dedupe_key` + kind-aware uniqueness, `due_defrost_reminders` (pg_cron every 15 min).
  - `…11_mcp_tools` one SECURITY INVOKER function per MCP tool (`mcp_get_meals`, `mcp_plan_meal`, `mcp_shopping_list`, `mcp_add_shopping_items`, `mcp_set_shopping_status`, `mcp_add_recipe_to_shopping`, `mcp_search_recipes`, `mcp_resolve_recipe`, `mcp_get_recipe`, `mcp_recipe_stats`, `mcp_meal_history`, `mcp_create_meal_plan_draft`, `mcp_list_drafts`, `mcp_remove_planned_meal`, `mcp_today`, `mcp_household_id`).
  - `…12_recipe_images` private Storage bucket `recipe-images` + folder policies, `recipes.image_source`, synced `recipe_photos`, `mcp_recipes_missing_cover`, `mcp_check_recipe_image`, `mcp_set_recipe_cover`, `mcp_add_recipe_photo`.
  - `…13_recipe_image_cleanup` `orphan_recipe_images` (service role): images no live recipe or photo references, removed daily by `keepalive`.
- `supabase/seed.sql`: local-only household "Casa (local)" with `a@koda.test` / `b@koda.test` (password `koda-local-password`) and sample data.
- `supabase/tests/database/*.test.sql`: pgTAP (RLS isolation, recipe components, stats/matching, drafts/shopping, apply_mutations conflicts, server_seq/pull/push queue/purge, household settings, auto-logged consumptions, shopping status, frozen items, defrost reminders).
- `supabase/functions/`: `api` (Hono routes in `app.ts`), `push` (`handler.ts`: silent `sync` pushes + visible `defrost` alerts), `keepalive` (`handler.ts`: tombstone purge + orphan recipe image cleanup), `mcp` (remote MCP server: `app.ts` auth + discovery, `tools.ts`, `images.ts` (cover/gallery tools, URL download and signed uploads), `prompts.ts` (`plan_week`, `illustrate_recipes`), `resolve.ts`), `_shared/` (deps, env, clients, errors, validation, apns, `domain/` with `sync`, `recipes`, `planning`, `households`, `push`). `.env.example` lists the function secrets.
- `tests/functions`, `tests/scripts`: Deno unit tests (no network).
- `web/oauth/consent.html`: OAuth consent page of the MCP server, published to GitHub Pages by `.github/workflows/oauth-pages.yml`.
- `scripts/`: `create-user.ts`, `import-notion.ts` (+ `lib/notion_import.ts`), `backup.sh`.
- `.github/workflows/`: weekly `backup.yml`, daily `keepalive.yml`, `oauth-pages.yml` (consent page).

### API (`/functions/v1/api`)

`GET /health` · `GET /me` · `PATCH /households/:id/settings` · `POST /sync/push` · `GET /sync/pull?cursor&limit` · `PUT /devices` · `DELETE /devices/:id` · `POST /drafts/:id/accept|discard` · `POST /recipes/:id/expand` · `POST /shopping/from-plan`.

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
