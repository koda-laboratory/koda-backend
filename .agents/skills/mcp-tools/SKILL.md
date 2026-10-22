---
name: mcp-tools
description: Build Koda's remote MCP server (Edge Function `mcp`, phase 6) — stateless Streamable HTTP transport, OAuth 2.1 through the Supabase Auth OAuth server, the tools of PLAN.md 8.3 (get_meals, get_shopping_list, add_to_shopping_list, check_shopping_items, add_recipe_to_shopping_list, search_recipes, get_recipe, get_meal_history, get_recipe_stats, plan_meal, log_meal, create_meal_plan_draft), the plan_week prompt, annotations and tests. Use when implementing or changing MCP tools or MCP auth. Not for the app API (edge-functions).
---

# MCP tools

Status: `supabase/functions/mcp/index.ts` is a skeleton (`GET /mcp/health`, everything else 501). Phase 6 implements it.

## Principles

- Every request runs with the caller's OAuth access token (a Supabase JWT) through `createUserClient`, so RLS applies exactly as in the app. No secret-key shortcuts.
- Reuse `_shared/domain/` and Postgres functions: `match_product`, `recipe_tree`, `recipe_flat_ingredients`, `recipe_stats`, `shopping_from_plan`, `accept_meal_plan_draft`. Put new shared logic there, not in the MCP handler.
- Writes go straight to Postgres; triggers assign `server_seq` and enqueue silent pushes (no actor device, so every app refreshes).
- Relative dates ("mañana", "la semana que viene") are resolved in the household timezone (`households.timezone`, default Europe/Madrid).
- Annotate tools: `readOnlyHint: true` for reads; `destructiveHint` for writes that remove or overwrite; set `source = 'mcp'` on shopping entries and drafts.
- Drafts never replace the planning: `create_meal_plan_draft` inserts `meal_plan_drafts` + entries with `draft_id`; accepting is done in the app (or explicitly via an accept tool).

## Auth (PLAN.md 8.2)

- `[auth.oauth_server] enabled = true`, `allow_dynamic_registration = true` in `config.toml`.
- Publish `/.well-known/oauth-protected-resource` pointing to Supabase Auth; consent UI in `web/oauth/` (GitHub Pages).
- Fallback if OAuth fails: personal access tokens stored hashed.

## Implementation checklist

1. Pick the transport library recommended by the Supabase MCP guide at that time (official TypeScript SDK or `mcp-lite`) and pin it in `_shared/deps.ts`.
2. One file per tool group under `mcp/tools/`, zod input schemas, thin handlers calling `_shared/domain`.
3. `plan_week` prompt: use `get_recipe_stats`, avoid recipes eaten in the last 14 days, balance nutrients, respect planned entries.
4. Deno tests per tool with fake `RpcClient`; a pgTAP test for any new SQL function.
5. Manual check from Claude: "¿Qué hay mañana para comer?", "Añade huevos a la compra", "Haz un borrador del planning semanal".
