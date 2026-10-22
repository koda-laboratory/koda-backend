---
description: Invariants of the push/pull sync contract shared with the Koda apps
globs: supabase/migrations/**,supabase/functions/**,tests/**
alwaysApply: false
---

# Sync contract

The apps (`../koda-app-ios-macos`) are local-first and depend on these invariants. Breaking one silently corrupts offline data. Details: skill `sync-contract`.

- Synced tables: `stores`, `products`, `product_stores`, `recipes`, `recipe_ingredients`, `recipe_components`, `meal_plan_drafts`, `meal_plan_entries`, `consumptions`, `shopping_entries`, `shopping_entry_items`. The list exists in `public.synced_tables()`, `_shared/domain/sync.ts` (`SYNCED_TABLES`), `pull_changes`, the purge order and the push triggers; update all of them together.
- Every synced table has `id` (client UUID), `household_id`, `created_at`, `updated_at`, `updated_by`, `deleted_at`, `client_updated_at`, `server_seq`, the `t10_sync_row` trigger and the `t90_enqueue_push` trigger.
- `server_seq` comes only from `public.sync_seq` via `private.sync_row()`, which takes the transaction advisory lock so `server_seq` order equals commit order. Never write `server_seq` by hand or bypass the trigger.
- Rows are never hard-deleted by clients. Deletes are tombstones; `keepalive` purges tombstones older than 30 days and advances the purge watermark (`reset_required`).
- Conflict rules live in `public.apply_mutations` only: row LWW by `client_ts`; field-level LWW on the shopping list (`checked_at`, `name_updated_at`); tombstone wins. Change them only together with the app's `ConflictResolver` and tests.
- Adding a column is backwards compatible; renaming or removing one breaks old app builds still on TestFlight.
