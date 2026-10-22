---
name: sync-contract
description: Reference and procedure for Koda's local-first sync contract — POST /sync/push (apply_mutations), GET /sync/pull (pull_changes cursor paging), sync columns, conflict rules (row LWW, shopping field-level LWW, tombstones), server_seq ordering, purge watermark and silent-push enqueueing. Use when adding a synced table or column, changing conflict resolution, debugging missing or duplicated rows between devices, or answering how the apps must talk to the backend. Not for APNs delivery details (apns) or generic migration style (supabase-migrations).
---

# Sync contract

## Endpoints (Edge Function `api`)

`POST /functions/v1/api/sync/push`

```json
{ "device_id": "<uuid|null>",
  "mutations": [{ "table": "shopping_entries", "id": "<uuid>", "op": "upsert|delete",
                  "fields": { "...": "..." }, "client_ts": "2026-10-22T10:00:00Z" }] }
```

→ `{ "applied": [{ "table", "id", "server_seq", "merged"? }], "rejected": [{ "table", "id", "reason", "server_seq"?, "code"?, "message"? }], "cursor": <max server_seq applied | null> }`

- Max 500 mutations per request (API), applied in table dependency order, each in its own subtransaction: one bad mutation never aborts the batch.
- Rejection reasons: `stale` (older than the server), `deleted` (row is a tombstone), `not_found` (delete of an unknown/invisible row), `forbidden`, `conflict` (id used by another household), `missing_reference`, `constraint_violation` (includes recipe cycles), `invalid_value`, `unknown_table`, `invalid_op`, `invalid_mutation`, `error`.
- Client: drop applied and rejected entries from the outbox; for `stale`/`deleted`/`merged` the server copy wins and arrives in the next pull. Do **not** move the pull cursor from the push response.

`GET /functions/v1/api/sync/pull?cursor=N&limit=500` (limit 1–1000)

→ `{ "changes": { "<table>": [row, ...] }, "cursor": M, "has_more": bool, "reset_required": bool }`

- Rows with `server_seq > N` of every synced table, tombstones included, ordered by `server_seq`. Loop while `has_more`. Persist `cursor` only after applying the page in one local transaction.
- `reset_required`: the cursor is older than purged tombstones (30 days) → wipe local synced data and pull from 0 (keep the outbox).

## Columns and server behaviour

`id` (client UUID), `household_id` (immutable), `created_at`, `updated_at`, `updated_by` (`auth.uid()`), `deleted_at`, `client_updated_at`, `server_seq`. Clients may send any non-server column; `id`, `created_at`, `updated_at`, `updated_by`, `deleted_at`, `client_updated_at`, `server_seq` are ignored, `household_id` only counts on insert.

`private.sync_row()` (trigger `t10_sync_row`) takes `pg_advisory_xact_lock(hashtextextended('koda.sync_seq', 0))` and assigns `server_seq = nextval('public.sync_seq')`, so commit order = `server_seq` order and a cursor never skips a row. Every write path (API, MCP, scripts, SQL functions) goes through it.

## Conflict rules (`public.apply_mutations`)

1. Row LWW: apply when `client_ts >= client_updated_at`. `client_ts` more than 5 minutes in the future is clamped to `now()`.
2. `shopping_entries` / `shopping_entry_items`, field groups:
   - `checked`, `checked_at` → by `checked_at` (defaults to `client_ts`); sets `checked_by` on entries.
   - `text`, `quantity`, `unit` (entries only) → by `name_updated_at` (defaults to `client_ts`).
   - other fields → row LWW. Partially applied mutations return `merged: true`.
3. Tombstone wins: `delete` always applies (even with an older `client_ts`); `upsert` on a tombstone is rejected as `deleted`. Tombstoning a parent cascades to live children (`private.cascade_tombstone`).

## Silent pushes

`t90_enqueue_push` adds one `push_queue` row per household and transaction with `reasons` (`catalog`, `recipes`, `planning`, `shopping`) and the max `server_seq`. `apply_mutations` stores `device_id` in `koda.device_id` so the actor device is excluded. See skill `apns`.

## Adding a synced table

1. Migration: table with the sync columns, `unique (id, household_id)` if it can be a parent, composite FKs to parents, RLS (rule `rls-policies`), add it to the `t10_sync_row`/index loop pattern, `t90_enqueue_push` with a reason, cascade-tombstone triggers.
2. Add it to `public.synced_tables()` (dependency order), `pull_changes`, `purge_tombstones` (children first) and `SYNCED_TABLES` in `_shared/domain/sync.ts`.
3. pgTAP: RLS isolation, apply/pull round trip. Deno: validation accepts the table.
4. Tell the app side (`local-first-sync` skill in `koda-app-ios-macos`).
