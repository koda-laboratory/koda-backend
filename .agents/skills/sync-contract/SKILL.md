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
- Rejection reasons: `stale` (older than the server), `deleted` (row is a tombstone), `not_found` (delete of an unknown/invisible row), `forbidden` (also: insert/delete of `frozen_items`), `conflict` (id used by another household), `missing_reference`, `constraint_violation` (includes recipe cycles), `invalid_value`, `unknown_table`, `invalid_op`, `invalid_mutation`, `error`.
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
   - `status`, `checked`, `checked_at` → by `checked_at` (defaults to `client_ts`); sets `checked_by` on entries. An insert with `checked = true` or `status <> 'pending'` gets `checked_at = client_ts`.
   - `text`, `quantity`, `unit` (entries only) → by `name_updated_at` (defaults to `client_ts`).
   - other fields → row LWW. Partially applied mutations return `merged: true`.
3. `frozen_items`: only `resolved_at` is writable (row LWW); other fields are ignored, inserts and deletes are rejected as `forbidden`.
4. Tombstone wins: `delete` always applies (even with an older `client_ts`); `upsert` on a tombstone is rejected as `deleted`. Tombstoning a parent cascades to live children (`private.cascade_tombstone`).

## Shopping status

`status text` on `shopping_entries` and `shopping_entry_items`: `pending` | `have` (bought or already at home) | `frozen` (in the freezer, not bought). `checked` is kept for old builds and always equals `status <> 'pending'` (BEFORE trigger `t15_shopping_status`): a write that changes `status` sets `checked`; a write that only changes `checked` sets `status` to `have`/`pending`. New clients send `status` (+ `checked_at`).

## Frozen items (`frozen_items`, server-maintained)

Columns: `id, household_id, product_id, shopping_entry_id?, shopping_entry_item_id?, meal_plan_entry_id?, frozen_at, defrost_remind_at?, reminded_at?, resolved_at?` + sync columns. Reason `shopping` for silent pushes.

- `status → 'frozen'` on a product entry (`kind = 'product'`) or a recipe item creates one open row (or revives the last tombstone of that source); `status` leaving `frozen` tombstones the open row (resolved rows are kept). Tombstoning the shopping entry keeps the frozen item. Tombstoning the product cascades.
- Link: the source's `meal_plan_entry_id` (items: the parent entry's), else the next live, accepted, non-skipped entry within 14 days (household timezone, meal time still ahead) whose recipe tree uses the product. Relinked when the meal changes date/slot/`scheduled_time`/recipe, is tombstoned, skipped or back in a draft; unlinked rows are linked when a meal that uses the product is planned.
- `defrost_remind_at = (date + coalesce(scheduled_time, households.slot_times[slot])) at time zone households.timezone − 24 h`; null when unlinked. `reminded_at` resets when the reminder moves later.
- The app only writes `resolved_at` ("Hecho"). Today shows "Descongelar hoy" from `defrost_remind_at` while `resolved_at` is null.

## Server-created rows

- `auto_log_consumptions()` (pg_cron every 15 min) inserts `consumptions` with `source = 'auto'`, `logged_by = null`, `client_updated_at = null` for planned recipes whose meal time passed (3-day look-back; never for drafts, `skipped_at`, free text, or entries that ever had a consumption). One live consumption per `meal_plan_entry_id` (unique index): a client insert for an already logged entry is rejected as `conflict`. "No lo comimos" = tombstone the consumption + set `meal_plan_entries.skipped_at`.
- `frozen_items` rows and their link/reminder updates.

## Silent pushes

`t90_enqueue_push` adds one `push_queue` row (`kind = 'sync'`) per household and transaction with `reasons` (`catalog`, `recipes`, `planning`, `shopping`) and the max `server_seq`. `apply_mutations` stores `device_id` in `koda.device_id` so the actor device is excluded. See skill `apns`.

## Adding a synced table

1. Migration: table with the sync columns, `unique (id, household_id)` if it can be a parent, composite FKs to parents, RLS (rule `rls-policies`), add it to the `t10_sync_row`/index loop pattern, `t90_enqueue_push` with a reason, cascade-tombstone triggers.
2. Add it to `public.synced_tables()` (dependency order), `pull_changes`, `purge_tombstones` (children first) and `SYNCED_TABLES` in `_shared/domain/sync.ts`.
3. pgTAP: RLS isolation, apply/pull round trip. Deno: validation accepts the table.
4. Tell the app side (`local-first-sync` skill in `koda-app-ios-macos`).
