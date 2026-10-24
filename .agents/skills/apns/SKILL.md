---
name: apns
description: Operate and extend Koda's Apple Push Notification pipeline — devices table and PUT/DELETE /devices, push_queue enqueueing, the internal `push` Edge Function (ES256 provider token, HTTP/2 to sandbox/production, silent background payload, 410 handling), pg_cron/pg_net scheduling with Vault secrets, and the APNS_* secrets. Use when changing push payloads, adding visible notifications, debugging pushes that do not arrive, or rotating APNs keys. Not for the app-side registration code (push-notifications skill in koda-app-ios-macos).
---

# APNs

## Flow

1. App registers its token after login: `PUT /functions/v1/api/devices` `{ id, apns_token (hex), platform: ios|macos, apns_env: sandbox|production, app_version }` → `public.register_device` (moves a token/installation to the current user). Logout: `DELETE /devices/:id`.
2. Any write to a synced table → trigger `t90_enqueue_push` → one `public.push_queue` row per (household, transaction) with `payload = { reasons, cursor }`, `actor_device_id` from `apply_mutations`.
3. pg_cron job `koda-push` (every minute) → `private.kick_push()` → if there are pending rows, `net.http_post` to `<koda_functions_url>/push` with header `x-koda-secret` (Vault `koda_push_secret`).
4. `push` function: `claim_push_batch` (marks rows sent) → `push_devices_for_households` → `planPushes` (`sync`: one silent push per device, skipping a device only if it was the actor of every change of its household; `defrost`: one alert per reminder and device) → `ApnsClient.send` → `410` sets `devices.disabled_at`.

## Silent payload

```json
{ "aps": { "content-available": 1 }, "koda": { "reason": "planning|shopping", "cursor": 1234 } }
```

Headers: `apns-push-type: background`, `apns-priority: 5`, `apns-expiration: now + 3600`, `apns-topic: com.kodalabs.app` (same bundle id on iOS and macOS). Host: `api.sandbox.push.apple.com` for `sandbox` devices (Xcode builds), `api.push.apple.com` for `production` (TestFlight).

## Visible defrost alert

`due_defrost_reminders()` (pg_cron every 15 min) inserts `push_queue` rows with `kind = 'defrost'`, `payload = { title, body, frozen_item_id, product_id, meal_plan_entry_id, recipe_id }` (Spanish copy, e.g. "Descongela carrilleras" / "Mañana a las 14:30 toca Paella de carrilleras") and `dedupe_key = 'defrost:<frozen_item_id>:<remind epoch>'` (unique; sync rows are unique per `(household_id, txid) where kind = 'sync'`). The `push` function sends each one to **every** device of the household, actor included:

```json
{ "aps": { "alert": { "title": "…", "body": "…" }, "sound": "default", "category": "DEFROST", "thread-id": "defrost" },
  "koda": { "kind": "defrost", "frozen_item_id": "…", "recipe_id": "…", "meal_plan_entry_id": "…" } }
```

Headers: `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration: now + 12 h`, `apns-collapse-id: defrost-<frozen_item_id>`. `sync` rows keep the batched silent push; unknown kinds are ignored.

## Secrets

| Name | Where | Value |
|---|---|---|
| `APNS_KEY_ID` | function secret | `38H2AWSNST` |
| `APNS_TEAM_ID` | function secret | `MUDCX7X324` |
| `APNS_BUNDLE_ID` | function secret | `com.kodalabs.app` |
| `APNS_PRIVATE_KEY` | function secret | PEM content of `AuthKey_38H2AWSNST.p8` (set from the file, never committed or printed) |
| `PUSH_INTERNAL_SECRET` | function secret + Vault `koda_push_secret` | random string |

`supabase secrets set APNS_PRIVATE_KEY="$(cat /path/to/AuthKey_38H2AWSNST.p8)"`. Without the APNS_* secrets the function returns `skipped: apns_not_configured` and leaves the queue untouched.

## Extending

- Visible notifications: add a `kind`, a payload builder next to `buildDefrostPayload` and a branch in `planPushes`; send with `ALERT_PUSH_OPTIONS`; keep silent sync pushes separate.
- Provider tokens are cached 50 min; `403 ExpiredProviderToken` clears the cache.
- Tests: `tests/functions/push_test.ts` (planning, drain, 410) and `apns_test.ts` (JWT header/claims, hosts, headers) with fake fetch and a generated P-256 key. Never use the real key in tests.

## Debugging

- `select * from public.push_queue order by id desc limit 20;` — rows with `sent_at` null are pending.
- `select * from net._http_response order by id desc limit 5;` — results of pg_net calls.
- `select * from cron.job_run_details order by start_time desc limit 5;`
- Device disabled? `select id, apns_env, disabled_at from public.devices;` — a token from a Debug build registered as `production` (or vice versa) gets `400 BadDeviceToken`.
