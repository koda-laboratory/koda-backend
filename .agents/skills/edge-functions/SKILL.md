---
name: edge-functions
description: Build, test and serve Koda's Deno Edge Functions (Hono `api`, internal `push` and `keepalive`, `mcp`) with the shared `_shared/` modules — adding an API route, zod validation, error mapping, user-JWT Supabase clients, dependency injection for tests, local serving and curl smoke tests. Use whenever code under supabase/functions or tests/ changes. Not for SQL (supabase-migrations), APNs specifics (apns) or MCP tools (mcp-tools).
---

# Edge Functions

Follow rule [`edge-functions`](../../rules/edge-functions.md).

## Layout

```
supabase/functions/
├── _shared/   deps.ts (pinned imports) env.ts supabase.ts (clients) errors.ts db.ts (callRpc)
│              validation.ts (zod) internal.ts (x-koda-secret) apns.ts domain/{sync,recipes,planning,push}.ts
├── api/       app.ts (createApiApp(deps): routes) + index.ts (wiring)
├── push/      handler.ts (drainPushQueue) + index.ts
├── keepalive/ index.ts
└── mcp/       index.ts (skeleton until phase 6)
tests/functions/*_test.ts, tests/scripts/*_test.ts
```

## Add an `api` route

1. Schema in `_shared/validation.ts`.
2. Logic: a Postgres function (atomic, RLS) called through `callRpc`, wrapped in `_shared/domain/<area>.ts` when it is reused (the MCP will reuse it).
3. Route in `api/app.ts`: `parseOrThrow(schema, await readJson(c))` → domain call → `c.json(...)`. Use `c.get("db")` (user JWT client); never the admin client.
4. Tests in `tests/functions/api_test.ts` with `FakeDb` handlers: happy path, validation 400, error mapping.
5. Document the route in `AGENTS.md`/README if it is part of the app contract and in the app's `supabase-api` skill.

## Commands

```bash
deno task test     # unit tests (no network)
deno task check    # type-check functions, tests and scripts
deno task lint
deno task fmt

supabase start
supabase functions serve --env-file supabase/functions/.env   # copy .env.example first
# token for a seeded user
curl -s -X POST "http://127.0.0.1:54321/auth/v1/token?grant_type=password" \
  -H "apikey: <PUBLISHABLE_KEY from supabase status>" -H 'content-type: application/json' \
  -d '{"email":"a@koda.test","password":"koda-local-password"}'
curl -s http://127.0.0.1:54321/functions/v1/api/me -H "Authorization: Bearer $TOKEN"
```

## Gotchas

- The function path includes its name: Hono apps use `basePath("/api")` / `basePath("/mcp")`.
- `SUPABASE_URL` inside the local runtime is `http://kong:8000`; it is injected automatically, as are the publishable/anon and secret/service keys.
- Internal functions answer 401 without the right `x-koda-secret`; pg_cron calls them through `private.invoke_internal_function` with secrets read from Vault.
- Writes not made through `apply_mutations` (e.g. `/shopping/from-plan`) enqueue silent pushes without an actor device, so the caller also receives one.
