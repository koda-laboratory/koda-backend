import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";
import { createMcpApp, type McpDeps } from "../../supabase/functions/mcp/app.ts";
import type { RpcClient } from "../../supabase/functions/_shared/db.ts";
import { addDays } from "../../supabase/functions/mcp/resolve.ts";
import { sniffImage } from "../../supabase/functions/mcp/images.ts";

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);

const USER_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const GOOD_TOKEN = "good-token";
const RESOURCE = "https://koda.example/functions/v1/mcp";
const TODAY = "2026-10-24";

type RpcHandler = (args: Record<string, unknown> | undefined) => { data?: unknown; error?: unknown };

class FakeDb implements RpcClient {
  calls: Array<{ fn: string; args?: Record<string, unknown> }> = [];
  constructor(private handlers: Record<string, RpcHandler> = {}) {}
  rpc(fn: string, args?: Record<string, unknown>) {
    this.calls.push({ fn, args });
    const handler = this.handlers[fn] ?? (fn === "mcp_today" ? () => ({ data: TODAY }) : undefined);
    const result = handler ? handler(args) : { data: null };
    return Promise.resolve({ data: result.data ?? null, error: result.error ?? null });
  }
}

function setup(
  handlers: Record<string, RpcHandler> = {},
  images: Record<string, Uint8Array | number> = {},
) {
  const db = new FakeDb(handlers);
  const uploads: Array<{ path: string; contentType: string; size: number }> = [];
  const authorizations: string[] = [];
  const deps: McpDeps = {
    verifyToken: (jwt) => Promise.resolve(jwt === GOOD_TOKEN ? { id: USER_ID } : null),
    clientFor: (authorization) => {
      authorizations.push(authorization);
      return db;
    },
    storeFor: () => ({
      upload: (path, bytes, contentType) => {
        uploads.push({ path, contentType, size: bytes.length });
        return Promise.resolve();
      },
      signedUploadUrl: (path) => Promise.resolve(`https://storage.example/upload/${path}?token=t`),
    }),
    fetchImage: (url) => {
      const image = images[url];
      if (image === undefined) return Promise.resolve(new Response("nope", { status: 404 }));
      if (typeof image === "number") return Promise.resolve(new Response(new Uint8Array(image)));
      return Promise.resolve(new Response(new Uint8Array(image)));
    },
    resourceUrl: RESOURCE,
    authorizationServer: "https://koda.example/auth/v1",
  };
  const app = createMcpApp(deps);
  let nextId = 1;
  const rpc = async (method: string, params: Record<string, unknown> = {}, token: string | null = GOOD_TOKEN) => {
    const response = await app.request("/mcp", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        "mcp-protocol-version": "2025-06-18",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params }),
    });
    return response;
  };
  const callTool = async (name: string, args: Record<string, unknown> = {}) => {
    const response = await rpc("tools/call", { name, arguments: args });
    const body = await response.json();
    return body.result as { content: Array<{ text: string }>; isError?: boolean };
  };
  return { app, db, authorizations, rpc, callTool, uploads };
}

Deno.test("health and the protected resource metadata are public", async () => {
  const { app } = setup();
  assertEquals((await app.request("/mcp/health")).status, 200);
  const metadata = await (await app.request("/mcp/.well-known/oauth-protected-resource")).json();
  assertEquals(metadata.resource, RESOURCE);
  assertEquals(metadata.authorization_servers, ["https://koda.example/auth/v1"]);
});

Deno.test("requests without a valid token get 401 pointing to the resource metadata", async () => {
  const { rpc, db } = setup();
  for (const token of [null, "expired"]) {
    const response = await rpc("tools/list", {}, token);
    assertEquals(response.status, 401);
    assertEquals(
      response.headers.get("WWW-Authenticate"),
      `Bearer resource_metadata="${RESOURCE}/.well-known/oauth-protected-resource"`,
    );
  }
  assertEquals(db.calls.length, 0);
});

Deno.test("initialize advertises Koda with tools, prompts and instructions", async () => {
  const { rpc } = setup();
  const response = await rpc("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "test", version: "1" },
  });
  assertEquals(response.status, 200);
  const { result } = await response.json();
  assertEquals(result.serverInfo.name, "koda");
  assert(result.capabilities.tools);
  assert(result.capabilities.prompts);
  assertStringIncludes(result.instructions, "get_household");
});

Deno.test("tools are listed with read-only hints on reads", async () => {
  const { rpc } = setup();
  const { result } = await (await rpc("tools/list")).json();
  const tools = new Map<string, { annotations?: { readOnlyHint?: boolean; destructiveHint?: boolean } }>(
    result.tools.map((tool: { name: string }) => [tool.name, tool]),
  );
  for (
    const name of [
      "get_household",
      "get_meals",
      "plan_meal",
      "remove_planned_meal",
      "get_meal_history",
      "search_recipes",
      "get_recipe",
      "get_recipe_stats",
      "get_shopping_list",
      "add_to_shopping_list",
      "set_shopping_status",
      "add_recipe_to_shopping_list",
      "create_meal_plan_draft",
      "list_meal_plan_drafts",
      "accept_meal_plan_draft",
      "discard_meal_plan_draft",
      "list_recipes_missing_cover",
      "set_recipe_cover",
      "add_recipe_photo",
      "create_recipe_image_upload",
      "finish_recipe_image_upload",
    ]
  ) {
    assert(tools.has(name), `missing tool ${name}`);
  }
  assertEquals(tools.get("get_meals")?.annotations?.readOnlyHint, true);
  assertEquals(tools.get("remove_planned_meal")?.annotations?.destructiveHint, true);
});

Deno.test("get_meals resolves 'tomorrow' in the household time zone with the caller's token", async () => {
  const { callTool, db, authorizations } = setup({
    mcp_get_meals: () => ({ data: [{ recipe: "Lentejas", slot: "lunch" }] }),
  });
  const result = await callTool("get_meals", { from: "tomorrow" });
  assertEquals(result.isError, undefined);
  assertEquals(JSON.parse(result.content[0].text)[0].recipe, "Lentejas");
  const call = db.calls.find((c) => c.fn === "mcp_get_meals");
  assertEquals(call?.args, { p_from: "2026-10-25", p_to: "2026-10-25", p_slot: null });
  assertEquals(authorizations, [`Bearer ${GOOD_TOKEN}`]);
});

Deno.test("recipes are resolved by name; ambiguous names list the candidates", async () => {
  const candidates = [
    { id: "r1", name: "Tortilla de patata", score: 0.8 },
    { id: "r2", name: "Tortilla francesa", score: 0.75 },
  ];
  const { callTool, db } = setup({ mcp_resolve_recipe: () => ({ data: candidates }) });
  const ambiguous = await callTool("get_recipe", { recipe: "tortilla" });
  assertEquals(ambiguous.isError, true);
  assertStringIncludes(ambiguous.content[0].text, "Tortilla francesa (r2)");
  assertEquals(db.calls.some((c) => c.fn === "mcp_get_recipe"), false);

  const exact = setup({
    mcp_resolve_recipe: () => ({ data: [{ id: "r1", name: "Tortilla de patata", score: 1 }, candidates[1]] }),
    mcp_get_recipe: (args) => ({ data: { id: args?.p_recipe_id } }),
  });
  const result = await exact.callTool("get_recipe", { recipe: "tortilla de patata" });
  assertEquals(JSON.parse(result.content[0].text).id, "r1");
});

Deno.test("plan_meal requires either a recipe or a free text", async () => {
  const { callTool, db } = setup();
  const result = await callTool("plan_meal", { date: "2026-11-02", slot: "dinner" });
  assertEquals(result.isError, true);
  assertEquals(db.calls.some((c) => c.fn === "mcp_plan_meal"), false);
});

Deno.test("create_meal_plan_draft resolves recipe names and relative dates", async () => {
  const { callTool, db } = setup({
    mcp_resolve_recipe: () => ({ data: [{ id: "r9", name: "Lentejas estofadas", score: 1 }] }),
    mcp_create_meal_plan_draft: () => ({ data: { draft_id: "d1", entries: 2, status: "pending" } }),
  });
  const result = await callTool("create_meal_plan_draft", {
    from: "tomorrow",
    to: "2026-10-31",
    rationale: "Semana ligera",
    entries: [
      { date: "tomorrow", slot: "lunch", recipe: "lentejas" },
      { date: "2026-10-26", slot: "dinner", free_text: "Pizza casera" },
    ],
  });
  assertEquals(JSON.parse(result.content[0].text).draft_id, "d1");
  const call = db.calls.find((c) => c.fn === "mcp_create_meal_plan_draft");
  assertEquals(call?.args?.p_from, "2026-10-25");
  assertEquals((call?.args?.p_entries as Array<{ recipe_id: string | null }>).map((e) => e.recipe_id), ["r9", null]);
});

Deno.test("database errors come back as tool errors, not transport failures", async () => {
  const { callTool } = setup({
    mcp_add_shopping_items: () => ({ error: { code: "22023", message: "every item needs a name" } }),
  });
  const result = await callTool("add_to_shopping_list", { items: [{ name: "x" }] });
  assertEquals(result.isError, true);
  assertEquals(result.content[0].text, "every item needs a name");
});

Deno.test("plan_week prompt guides the agent to a draft", async () => {
  const { rpc } = setup();
  const { result } =
    await (await rpc("prompts/get", { name: "plan_week", arguments: { notes: "invitados el sábado" } }))
      .json();
  const text = result.messages[0].content.text as string;
  assertStringIncludes(text, "create_meal_plan_draft");
  assertStringIncludes(text, "invitados el sábado");
});

Deno.test("addDays crosses months", () => {
  assertEquals(addDays("2026-10-31", 1), "2026-11-01");
  assertEquals(addDays("2026-03-01", -1), "2026-02-28");
});

const HOUSEHOLD = "11111111-1111-4111-8111-111111111111";
const imageHandlers: Record<string, RpcHandler> = {
  mcp_resolve_recipe: () => ({ data: [{ id: "r1", name: "Tortilla de patata", score: 1 }] }),
  mcp_household_id: () => ({ data: HOUSEHOLD }),
  mcp_set_recipe_cover: (args) => ({ data: { recipe_id: args?.p_recipe_id, image_path: args?.p_path } }),
};

Deno.test("sniffImage trusts the bytes, not the headers", () => {
  assertEquals(sniffImage(PNG)?.mime, "image/png");
  assertEquals(sniffImage(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]))?.ext, "jpg");
  assertEquals(sniffImage(new TextEncoder().encode("<html>")), null);
});

Deno.test("set_recipe_cover downloads the image into the recipe's household folder", async () => {
  const { callTool, db, uploads } = setup(imageHandlers, { "https://img.example/tortilla.png": PNG });
  const result = await callTool("set_recipe_cover", {
    recipe: "tortilla",
    image_url: "https://img.example/tortilla.png",
  });
  assertEquals(result.isError, undefined);
  assertEquals(uploads.length, 1);
  assertEquals(uploads[0].contentType, "image/png");
  assert(uploads[0].path.startsWith(`${HOUSEHOLD}/r1/`) && uploads[0].path.endsWith(".png"));
  const call = db.calls.find((c) => c.fn === "mcp_set_recipe_cover");
  assertEquals(call?.args?.p_path, uploads[0].path);
  assertEquals(call?.args?.p_overwrite, false);
});

Deno.test("set_recipe_cover refuses non-https URLs, non-images and files over 5 MB", async () => {
  const { callTool, uploads } = setup(imageHandlers, {
    "https://img.example/page.html": new TextEncoder().encode("<html>"),
    "https://img.example/huge.png": 5 * 1024 * 1024 + 1,
  });
  for (const url of ["http://img.example/x.png", "https://img.example/page.html", "https://img.example/huge.png"]) {
    const result = await callTool("set_recipe_cover", { recipe: "tortilla", image_url: url });
    assertEquals(result.isError, true, url);
  }
  const expired = await callTool("set_recipe_cover", { recipe: "tortilla", image_url: "https://img.example/gone.png" });
  assertStringIncludes(expired.content[0].text, "404");
  assertEquals(uploads.length, 0);
});

Deno.test("the upload flow hands out a one-time URL and attaches the uploaded file", async () => {
  const { callTool, db } = setup({
    ...imageHandlers,
    mcp_add_recipe_photo: (args) => ({ data: { photo_id: "p1", image_path: args?.p_path } }),
  });
  const started = JSON.parse(
    (await callTool("create_recipe_image_upload", { recipe: "tortilla", format: "webp" }))
      .content[0].text,
  );
  assertEquals(started.method, "PUT");
  assertEquals(started.content_type, "image/webp");
  assert(started.image_path.startsWith(`${HOUSEHOLD}/r1/`) && started.image_path.endsWith(".webp"));
  assertStringIncludes(started.upload_url, started.image_path);

  const finished = await callTool("finish_recipe_image_upload", {
    recipe: "tortilla",
    image_path: started.image_path,
    purpose: "photo",
  });
  assertEquals(JSON.parse(finished.content[0].text).photo_id, "p1");
  assertEquals(db.calls.find((c) => c.fn === "mcp_add_recipe_photo")?.args?.p_path, started.image_path);
});
