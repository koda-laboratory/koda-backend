---
description: Structure, auth and testing rules for Koda's Deno Edge Functions
globs: supabase/functions/**,tests/**,scripts/**,deno.json
alwaysApply: false
---

# Edge Functions

- Functions: `api` (Hono, app routes), `mcp` (MCP server, phase 6), `push` (internal, APNs), `keepalive` (internal, purge + activity). Shared code lives in `supabase/functions/_shared/`; domain logic in `_shared/domain/`.
- Third-party imports only through `_shared/deps.ts` with pinned versions (`npm:`/`jsr:` specifiers, no import maps).
- `verify_jwt = false` in `config.toml` for every function: `api`/`mcp` verify the bearer token themselves (`verifyAccessToken`), `push`/`keepalive` require the `x-koda-secret` header (`hasInternalSecret`, constant-time).
- User requests always run with `createUserClient(authorization)` so RLS applies. `createAdminClient()` (secret key) is only allowed in internal functions and scripts.
- Keep handlers thin: validate with zod (`_shared/validation.ts`, `parseOrThrow`), call a domain function or a Postgres RPC (`callRpc`), return JSON. Prefer SQL functions for multi-row writes so they are atomic.
- Errors: throw `ApiError`; database errors go through `fromDbError`. Responses use `{ "error": { "code", "message", "details"? } }`.
- Make code testable with injected ports (`ApiDeps`, `RpcClient`, `PushStore`, `ApnsSender`). `index.ts` only wires real dependencies and calls `Deno.serve`.
- Tests live in `tests/` (`deno task test`), with fakes, no network. Also run `deno task check` and `deno task lint`.
- Smoke-test locally with `supabase functions serve --env-file supabase/functions/.env` (copy `.env.example`); never point local tooling at the hosted project.
- Secrets come from `supabase secrets set` (hosted) or the ignored `supabase/functions/.env` (local). Never log tokens, secrets or personal data.
