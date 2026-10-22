import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { type ApiDeps, createApiApp } from "../../supabase/functions/api/app.ts";
import type { RpcClient } from "../../supabase/functions/_shared/db.ts";

const USER_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const GOOD_TOKEN = "good-token";

type RpcHandler = (args: Record<string, unknown> | undefined) => { data?: unknown; error?: unknown };

class FakeDb implements RpcClient {
  calls: Array<{ fn: string; args?: Record<string, unknown> }> = [];
  constructor(private handlers: Record<string, RpcHandler> = {}) {}
  rpc(fn: string, args?: Record<string, unknown>) {
    this.calls.push({ fn, args });
    const handler = this.handlers[fn];
    const result = handler ? handler(args) : { data: null };
    return Promise.resolve({ data: result.data ?? null, error: result.error ?? null });
  }
}

function setup(handlers: Record<string, RpcHandler> = {}) {
  const db = new FakeDb(handlers);
  const authorizations: string[] = [];
  const deps: ApiDeps = {
    verifyToken: (jwt) => Promise.resolve(jwt === GOOD_TOKEN ? { id: USER_ID } : null),
    clientFor: (authorization) => {
      authorizations.push(authorization);
      return db;
    },
  };
  const app = createApiApp(deps);
  const request = (method: string, path: string, body?: unknown, token: string | null = GOOD_TOKEN) =>
    app.request(`/api${path}`, {
      method,
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(body !== undefined ? { "content-type": "application/json" } : {}),
      },
      body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
    });
  return { db, authorizations, request };
}

const mutation = {
  table: "shopping_entries",
  id: "5e000000-0000-4000-8000-000000000001",
  op: "upsert",
  fields: { household_id: "11111111-1111-4111-8111-111111111111", kind: "text", text: "Pan" },
  client_ts: "2026-10-22T10:00:00Z",
};

Deno.test("health does not require auth", async () => {
  const { request } = setup();
  const response = await request("GET", "/health", undefined, null);
  assertEquals(response.status, 200);
});

Deno.test("missing or invalid token is 401", async () => {
  const { request, db } = setup();
  assertEquals((await request("GET", "/me", undefined, null)).status, 401);
  const invalid = await request("GET", "/me", undefined, "expired");
  assertEquals(invalid.status, 401);
  assertEquals((await invalid.json()).error.code, "unauthorized");
  assertEquals(db.calls.length, 0);
});

Deno.test("the database client is bound to the caller JWT", async () => {
  const { request, authorizations, db } = setup({ get_me: () => ({ data: { user_id: USER_ID, households: [] } }) });
  const response = await request("GET", "/me");
  assertEquals(response.status, 200);
  assertEquals((await response.json()).user_id, USER_ID);
  assertEquals(authorizations, [`Bearer ${GOOD_TOKEN}`]);
  assertEquals(db.calls[0].fn, "get_me");
});

Deno.test("sync/push forwards the batch to apply_mutations", async () => {
  const result = {
    applied: [{ table: "shopping_entries", id: mutation.id, server_seq: 42 }],
    rejected: [],
    cursor: 42,
  };
  const { request, db } = setup({ apply_mutations: () => ({ data: result }) });
  const response = await request("POST", "/sync/push", {
    device_id: "f1000000-0000-4000-8000-000000000001",
    mutations: [mutation, {
      table: "products",
      id: "e0000000-0000-4000-8000-000000000001",
      op: "delete",
      client_ts: "2026-10-22T10:00:00+02:00",
    }],
  });
  assertEquals(response.status, 200);
  assertEquals(await response.json(), result);
  assertEquals(db.calls[0].fn, "apply_mutations");
  assertEquals(db.calls[0].args?.p_device_id, "f1000000-0000-4000-8000-000000000001");
  assertEquals((db.calls[0].args?.p_mutations as unknown[]).length, 2);
});

Deno.test("sync/push validates the payload", async () => {
  const { request, db } = setup();
  const cases: unknown[] = [
    "{not json",
    {},
    { mutations: [{ ...mutation, table: "auth.users" }] },
    { mutations: [{ ...mutation, op: "merge" }] },
    { mutations: [{ ...mutation, id: "nope" }] },
    { mutations: [{ ...mutation, client_ts: "yesterday" }] },
    { mutations: [{ ...mutation, fields: undefined }] },
    { mutations: Array.from({ length: 501 }, () => mutation) },
  ];
  for (const body of cases) {
    const response = await request("POST", "/sync/push", body);
    assertEquals(response.status, 400, JSON.stringify(body).slice(0, 80));
    assertEquals((await response.json()).error.code, "invalid_request");
  }
  assertEquals(db.calls.length, 0);
});

Deno.test("sync/pull groups rows per table and reports has_more", async () => {
  const { request, db } = setup({
    pull_changes: () => ({
      data: {
        rows: [
          { table: "products", row: { id: "p1", server_seq: 11 } },
          { table: "shopping_entries", row: { id: "s1", server_seq: 12 } },
          { table: "products", row: { id: "p2", server_seq: 13 } },
        ],
        has_more: true,
        cursor: 13,
        reset_required: false,
      },
    }),
  });
  const response = await request("GET", "/sync/pull?cursor=10&limit=3");
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.cursor, 13);
  assertEquals(body.has_more, true);
  assertEquals(body.changes.products.map((r: { id: string }) => r.id), ["p1", "p2"]);
  assertEquals(body.changes.shopping_entries.length, 1);
  assertEquals(db.calls[0].args, { p_cursor: 10, p_limit: 3 });
});

Deno.test("sync/pull defaults and limits", async () => {
  const { request, db } = setup({
    pull_changes: () => ({ data: { rows: [], has_more: false, cursor: 0, reset_required: false } }),
  });
  assertEquals((await request("GET", "/sync/pull")).status, 200);
  assertEquals(db.calls[0].args, { p_cursor: 0, p_limit: 500 });
  assertEquals((await request("GET", "/sync/pull?limit=5000")).status, 400);
  assertEquals((await request("GET", "/sync/pull?cursor=-1")).status, 400);
});

Deno.test("PUT /devices registers the device", async () => {
  const { request, db } = setup({ register_device: (args) => ({ data: { id: args?.p_id } }) });
  const response = await request("PUT", "/devices", {
    id: "f1000000-0000-4000-8000-000000000001",
    apns_token: "AB".repeat(32),
    platform: "ios",
    apns_env: "sandbox",
    app_version: "1.0 (1)",
  });
  assertEquals(response.status, 200);
  assertEquals(db.calls[0].args?.p_apns_token, "ab".repeat(32));
  assertEquals(
    (await request("PUT", "/devices", { id: "x", apns_token: "zz", platform: "android", apns_env: "dev" })).status,
    400,
  );
});

Deno.test("DELETE /devices/:id", async () => {
  let deleted = true;
  const { request } = setup({ unregister_device: () => ({ data: deleted }) });
  assertEquals((await request("DELETE", "/devices/f1000000-0000-4000-8000-000000000001")).status, 204);
  deleted = false;
  assertEquals((await request("DELETE", "/devices/f1000000-0000-4000-8000-000000000001")).status, 404);
  assertEquals((await request("DELETE", "/devices/not-a-uuid")).status, 400);
});

Deno.test("drafts map database errors to HTTP statuses", async () => {
  const draft = "b0000000-0000-4000-8000-000000000001";
  let error: unknown = null;
  const { request } = setup({
    accept_meal_plan_draft: () => (error ? { error } : { data: 3 }),
    discard_meal_plan_draft: () => ({ data: 1 }),
  });
  const ok = await request("POST", `/drafts/${draft}/accept`);
  assertEquals(ok.status, 200);
  assertEquals(await ok.json(), { draft_id: draft, entries: 3 });
  error = { code: "P0002", message: "draft not found" };
  assertEquals((await request("POST", `/drafts/${draft}/accept`)).status, 404);
  error = { code: "55000", message: "draft is accepted" };
  assertEquals((await request("POST", `/drafts/${draft}/accept`)).status, 409);
  error = { code: "XX000", message: "boom" };
  const internal = await request("POST", `/drafts/${draft}/accept`);
  assertEquals(internal.status, 500);
  assertEquals((await request("POST", `/drafts/${draft}/discard`)).status, 200);
});

Deno.test("recipes/:id/expand returns tree and ingredients, 404 when missing", async () => {
  let tree: unknown[] = [{ recipe_id: "r", name: "Pollo al horno", depth: 0 }];
  const { request, db } = setup({
    recipe_tree: () => ({ data: tree }),
    recipe_flat_ingredients: () => ({ data: [{ product_id: "p", quantity: 600 }] }),
  });
  const id = "a0000000-0000-4000-8000-00000000000a";
  const response = await request("POST", `/recipes/${id}/expand`, { servings: 4 });
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.tree.length, 1);
  assertEquals(body.ingredients[0].quantity, 600);
  assertEquals(db.calls[1].args, { p_recipe_id: id, p_servings: 4 });
  tree = [];
  assertEquals((await request("POST", `/recipes/${id}/expand`)).status, 404);
});

Deno.test("shopping/from-plan validates the range", async () => {
  const { request, db } = setup({ shopping_from_plan: () => ({ data: { created: 2, entry_ids: ["a", "b"] } }) });
  const ok = await request("POST", "/shopping/from-plan", { from: "2026-11-02", to: "2026-11-08" });
  assertEquals(ok.status, 201);
  assertEquals((await ok.json()).created, 2);
  assertEquals(db.calls[0].args, { p_from: "2026-11-02", p_to: "2026-11-08" });
  assertEquals((await request("POST", "/shopping/from-plan", { from: "2026-11-08", to: "2026-11-02" })).status, 400);
  assertEquals((await request("POST", "/shopping/from-plan", { from: "2026-01-01", to: "2026-12-31" })).status, 400);
  assertEquals((await request("POST", "/shopping/from-plan", { from: "mañana" })).status, 400);
});

Deno.test("unknown routes are 404 JSON", async () => {
  const { request } = setup();
  const response = await request("GET", "/nope");
  assertEquals(response.status, 404);
  assert((await response.json()).error);
});

Deno.test("PATCH /households/:id/settings updates slot times and shopping weekday", async () => {
  const household = "11111111-1111-4111-8111-111111111111";
  const updated = {
    id: household,
    name: "Casa",
    timezone: "Europe/Madrid",
    slot_times: { breakfast: "09:00", lunch: "14:00", snack: "18:00", dinner: "21:30" },
    shopping_weekday: 6,
    role: "member",
    members: [],
  };
  const { request, db } = setup({ update_household_settings: () => ({ data: updated }) });
  const response = await request("PATCH", `/households/${household}/settings`, {
    slot_times: { lunch: "14:00" },
    shopping_weekday: 6,
  });
  assertEquals(response.status, 200);
  assertEquals(await response.json(), updated);
  assertEquals(db.calls[0], {
    fn: "update_household_settings",
    args: { p_household_id: household, p_slot_times: { lunch: "14:00" }, p_shopping_weekday: 6 },
  });

  await request("PATCH", `/households/${household}/settings`, { shopping_weekday: 1 });
  assertEquals(db.calls[1].args, { p_household_id: household, p_slot_times: null, p_shopping_weekday: 1 });
});

Deno.test("PATCH /households/:id/settings validates the body", async () => {
  const household = "11111111-1111-4111-8111-111111111111";
  const { request, db } = setup();
  const cases: unknown[] = [
    {},
    { slot_times: { lunch: "2:30" } },
    { slot_times: { lunch: "24:00" } },
    { slot_times: { brunch: "11:00" } },
    { slot_times: "14:30" },
    { shopping_weekday: 0 },
    { shopping_weekday: 8 },
    { shopping_weekday: 2.5 },
    { name: "Otra casa" },
  ];
  for (const body of cases) {
    const response = await request("PATCH", `/households/${household}/settings`, body);
    assertEquals(response.status, 400, JSON.stringify(body));
    assertEquals((await response.json()).error.code, "invalid_request");
  }
  assertEquals((await request("PATCH", "/households/nope/settings", { shopping_weekday: 1 })).status, 400);
  assertEquals(db.calls.length, 0);
});

Deno.test("PATCH /households/:id/settings maps database errors", async () => {
  const household = "11111111-1111-4111-8111-111111111111";
  let result: { data?: unknown; error?: unknown } = { error: { code: "P0002", message: "household not found" } };
  const { request } = setup({ update_household_settings: () => result });
  assertEquals((await request("PATCH", `/households/${household}/settings`, { shopping_weekday: 3 })).status, 404);
  result = { error: { code: "22023", message: "slot lunch must be HH:MM" } };
  assertEquals((await request("PATCH", `/households/${household}/settings`, { shopping_weekday: 3 })).status, 400);
  result = { data: null };
  assertEquals((await request("PATCH", `/households/${household}/settings`, { shopping_weekday: 3 })).status, 404);
});

Deno.test("sync/push accepts frozen_items mutations", async () => {
  const { request, db } = setup({ apply_mutations: () => ({ data: { applied: [], rejected: [], cursor: null } }) });
  const response = await request("POST", "/sync/push", {
    mutations: [{
      table: "frozen_items",
      id: "f0000000-0000-4000-8000-000000000001",
      op: "upsert",
      fields: { resolved_at: "2026-10-22T10:00:00Z" },
      client_ts: "2026-10-22T10:00:00Z",
    }],
  });
  assertEquals(response.status, 200);
  assertEquals(db.calls[0].fn, "apply_mutations");
});
