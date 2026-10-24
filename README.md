# koda-backend

Supabase backend for **Koda** (household recipes, meal planning and shopping list): Postgres schema with RLS, a local-first sync API, silent APNs pushes and maintenance jobs. Agent instructions live in [`AGENTS.md`](AGENTS.md).

There is a **single** hosted environment, the Supabase project `koda`. The local Docker stack is only for tests.

## Requirements

- Docker Desktop (running)
- Supabase CLI ≥ 2.121 (`brew install supabase/tap/supabase`)
- Deno ≥ 2.x

## Local development

```bash
supabase start          # applies migrations + seed.sql; prints URLs and local keys
supabase status         # show them again
supabase db reset       # re-apply every migration and the seed
supabase stop
```

Seed (local only): household "Casa (local)" with `a@koda.test` and `b@koda.test`, password `koda-local-password`.

### Serving functions

```bash
cp supabase/functions/.env.example supabase/functions/.env   # local values; ignored by git
supabase functions serve --env-file supabase/functions/.env

PK=$(supabase status -o env | sed -n 's/^PUBLISHABLE_KEY="\(.*\)"/\1/p')
TOKEN=$(curl -s -X POST "http://127.0.0.1:54321/auth/v1/token?grant_type=password" \
  -H "apikey: $PK" -H 'content-type: application/json' \
  -d '{"email":"a@koda.test","password":"koda-local-password"}' | deno eval 'console.log(JSON.parse(await new Response(Deno.stdin.readable).text()).access_token)')

curl -s http://127.0.0.1:54321/functions/v1/api/me -H "Authorization: Bearer $TOKEN"
curl -s "http://127.0.0.1:54321/functions/v1/api/sync/pull?cursor=0&limit=500" -H "Authorization: Bearer $TOKEN"
curl -s -X POST http://127.0.0.1:54321/functions/v1/api/sync/push -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"device_id":null,"mutations":[{"table":"shopping_entries","id":"5e000000-0000-4000-8000-0000000000aa","op":"upsert","client_ts":"2026-10-22T12:00:00Z","fields":{"household_id":"11111111-1111-4111-8111-111111111111","kind":"text","text":"Pan"}}]}'
```

## Tests

```bash
supabase test db        # pgTAP: supabase/tests/database
deno task test          # Deno unit tests: tests/
deno task check         # type-check functions, tests and scripts
deno task lint
deno task fmt
```

## API (`/functions/v1/api`)

| Method | Path | Notes |
|---|---|---|
| GET | `/health` | no auth |
| GET | `/me` | profile, households (with `slot_times`, `shopping_weekday`) and members |
| PATCH | `/households/:id/settings` | `{ slot_times?: { breakfast?, lunch?, snack?, dinner?: "HH:MM" }, shopping_weekday?: 1–7 }` (ISO, 1 = Monday; any member; partial slot times are merged) → household as in `/me` |
| POST | `/sync/push` | `{ device_id, mutations: [{ table, id, op: upsert\|delete, fields, client_ts }] }` → `{ applied, rejected, cursor }` |
| GET | `/sync/pull?cursor=N&limit=500` | `{ changes: { table: rows[] }, cursor, has_more, reset_required }` |
| PUT | `/devices` | `{ id, apns_token, platform: ios\|macos, apns_env: sandbox\|production, app_version }` |
| DELETE | `/devices/:id` | 204 / 404 |
| POST | `/drafts/:id/accept`, `/drafts/:id/discard` | 404 unknown, 409 not pending |
| POST | `/recipes/:id/expand` | `{ servings? }` → `{ tree, ingredients }` |
| POST | `/shopping/from-plan` | `{ from, to }` (YYYY-MM-DD, ≤ 62 days) → `{ created, entry_ids }` |

All routes except `/health` require `Authorization: Bearer <access token>` and run with that JWT (RLS). Errors: `{ "error": { "code", "message", "details"? } }`. Sync semantics: [`.agents/skills/sync-contract/SKILL.md`](.agents/skills/sync-contract/SKILL.md).

Internal functions: `push` and `keepalive` (POST with header `x-koda-secret`). `mcp` is the remote MCP server (see below).

## Scripts

```bash
# Create a user (sign-ups are disabled). Password from KODA_USER_PASSWORD or an interactive prompt.
SUPABASE_URL=https://<ref>.supabase.co SUPABASE_SECRET_KEY=sb_secret_... \
  deno run --allow-env --allow-net scripts/create-user.ts \
  --email someone@example.com --name "Name" --household-name "Casa" --role owner
#   ...then the second person with --household-id <uuid> --role member

# Import the Notion extraction (../notion-data/comidita.json) into a household. Idempotent
# (UUID v5 per Notion id; existing rows are never overwritten). Always run against the local
# stack first, then dump `koda` and import for real.
deno run --allow-env --allow-read --allow-net scripts/import-notion.ts --household-id <uuid> --dry-run
SUPABASE_URL=... SUPABASE_SECRET_KEY=... deno run --allow-env --allow-read --allow-net \
  scripts/import-notion.ts --household-id <uuid>

# Dump roles, schema and data into backups/<timestamp>/ (ignored)
SUPABASE_DB_URL=postgresql://... scripts/backup.sh     # or: scripts/backup.sh --local | (linked project)
```

Notion mapping: product `Tipo` (Comida básicos→basics, Comida→food, Limpieza→cleaning, Cocina→kitchen, Baño→bathroom, Aseo→toiletries; missing → food), meal types (Desayuno→breakfast, Comida→lunch, Merienda→snack, Cena→dinner), nutrients (Grasas→fats, Fibra→fiber, Vegetales→vegetables, Proteína→protein, Carbohidratos→carbs). `last_eaten_on` creates a planning entry (slot: first of lunch/dinner, else first meal type, else lunch) and, only for dates before today (Europe/Madrid), a consumption. Products with `add_to_list` and not `bought` become unchecked shopping entries. Empty-named products are skipped.

## Deploy (hosted `koda`)

Always in this order, and only on purpose:

1. `scripts/backup.sh` — dump first (there are no backups on the free plan).
2. `supabase db push` — review pending migrations (`supabase db push --dry-run`).
3. `supabase functions deploy` — all functions (`api`, `push`, `keepalive`, `mcp`).
4. Set or rotate secrets when needed (below), then configure Vault for the scheduled jobs.

Never load `supabase/seed.sql` into `koda`.

### Function secrets (`supabase secrets set`)

| Secret | Value |
|---|---|
| `APNS_KEY_ID` | `38H2AWSNST` |
| `APNS_TEAM_ID` | `MUDCX7X324` |
| `APNS_BUNDLE_ID` | `com.kodalabs.app` |
| `APNS_PRIVATE_KEY` | content of the `.p8`, set straight from the file (never commit, paste or print it) |
| `PUSH_INTERNAL_SECRET` | long random string (`openssl rand -hex 32`) |
| `KEEPALIVE_SECRET` | another long random string |

```bash
supabase secrets set APNS_KEY_ID=38H2AWSNST APNS_TEAM_ID=MUDCX7X324 APNS_BUNDLE_ID=com.kodalabs.app
supabase secrets set APNS_PRIVATE_KEY="$(cat ../koda-app-ios-macos-certs/AuthKey_38H2AWSNST.p8)"
supabase secrets set PUSH_INTERNAL_SECRET=<random> KEEPALIVE_SECRET=<random>
```

`SUPABASE_URL` and the publishable/secret keys are injected by the platform.

### Scheduled jobs (pg_cron + pg_net + Vault)

| Job | Schedule | Does |
|---|---|---|
| `koda-push` (`…06_push`) | every minute | calls `push` only when `push_queue` has pending rows |
| `koda-keepalive` (`…06_push`) | daily 04:17 UTC | calls `keepalive` (tombstone purge + activity) |
| `koda-auto-log-consumptions` (`…08`) | `*/15 * * * *` | `public.auto_log_consumptions()`: logs planned meals whose time has passed (source `auto`, 3-day look-back, skipped/draft/free-text entries never) |
| `koda-defrost-reminders` (`…10`) | `*/15 * * * *` | `public.due_defrost_reminders()`: enqueues visible `defrost` pushes 24 h before the meal of a frozen product |

The two SQL jobs need no configuration. `koda-push` and `koda-keepalive` read their configuration from Vault and do nothing until it exists. Run once in the SQL editor of `koda`:

```sql
select vault.create_secret('https://<project-ref>.supabase.co/functions/v1', 'koda_functions_url');
select vault.create_secret('<PUSH_INTERNAL_SECRET>', 'koda_push_secret');
select vault.create_secret('<KEEPALIVE_SECRET>', 'koda_keepalive_secret');
```

Check with `select * from cron.job_run_details order by start_time desc limit 5;` and `select * from net._http_response order by id desc limit 5;`. pg_cron also accepts sub-minute schedules (`'15 seconds'`) if pushes need lower latency.

### GitHub Actions secrets

| Secret | Used by | Value |
|---|---|---|
| `SUPABASE_DB_URL` | `backup.yml` (weekly, artifact kept 30 days) | Postgres connection string of `koda` (session pooler) |
| `KODA_FUNCTIONS_URL` | `keepalive.yml` (daily fallback) | `https://<project-ref>.supabase.co/functions/v1` |
| `KEEPALIVE_SECRET` | `keepalive.yml` | same value as the function secret |

Both workflows fail until these secrets exist.

## Auth

## MCP server (`/functions/v1/mcp`)

A standard remote MCP server (Streamable HTTP, stateless) usable from any MCP client: Claude, ChatGPT, Cursor, Codex, Gemini CLI… Authentication is OAuth 2.1 through the Supabase Auth OAuth server, with discovery and dynamic client registration:

1. The client calls `https://<ref>.supabase.co/functions/v1/mcp` and gets `401` with `WWW-Authenticate: Bearer resource_metadata=".../mcp/.well-known/oauth-protected-resource"`.
2. That metadata names `https://<ref>.supabase.co/auth/v1` as the authorization server; the client registers itself and starts the authorization code flow with PKCE.
3. Supabase Auth sends the person to the consent page `web/oauth/consent.html` (GitHub Pages: `https://koda-laboratory.github.io/koda-backend/oauth/consent`), where they sign in with their Koda account and approve.
4. Every tool runs with that access token, so RLS limits it to their household. Tools are SQL functions `public.mcp_*` (migration `…11_mcp_tools`).

Recipe images (migration `…12_recipe_images`) live in the private Storage bucket `recipe-images` at `<household>/<recipe>/<uuid>.<ext>` (5 MB, JPEG/PNG/WebP), with Storage policies on the household folder. The gallery is the synced table `recipe_photos`; the cover is `recipes.image_path` with `image_source` `photo` (app) or `ai` (agent). Agents find recipes without a cover with `list_recipes_missing_cover` and attach an image either by https URL (`set_recipe_cover`, `add_recipe_photo`) or, when they hold the bytes, with a signed upload (`create_recipe_image_upload` → `PUT` → `finish_recipe_image_upload`). The `illustrate_recipes` prompt carries the house cover style (painted food on a plain `#CCA097` background) and the whole flow. Images that no live recipe or photo references any more (older than 3 days) are removed daily by `keepalive` (`orphan_recipe_images`, migration `…13`).

Hosted setup (once, in the dashboard):

- Authentication → OAuth Server: enable it, allow dynamic client registration, authorization path `/koda-backend/oauth/consent`.
- Authentication → URL Configuration: Site URL `https://koda-laboratory.github.io`.
- GitHub repository → Settings → Pages: source "GitHub Actions" (workflow `oauth-pages.yml` publishes `web/`).

Connect a client with the URL `https://<ref>.supabase.co/functions/v1/mcp` (for example `claude mcp add --transport http koda <url>`, or "Add custom connector" in Claude / ChatGPT). Local smoke test: `supabase functions serve mcp --no-verify-jwt` with `MCP_PUBLIC_URL=http://127.0.0.1:54321`.

## Auth

Email + password only, sign-ups disabled (`[auth] enable_signup = false`). Note that `[auth.email] enable_signup` must stay `true`: in the CLI it enables the email provider itself. The hosted project needs the same settings in the dashboard (Authentication → Sign In / Providers): disable "Allow new users to sign up", keep Email enabled. The OAuth 2.1 server is enabled for the MCP server (see above).
