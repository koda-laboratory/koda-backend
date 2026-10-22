// `api` Edge Function (Hono). Every route except /health requires `Authorization: Bearer <jwt>`
// and talks to Postgres with a client bound to that JWT, so RLS always applies.
import { type Context, Hono, type MiddlewareHandler } from "../_shared/deps.ts";
import { ApiError, errorBody } from "../_shared/errors.ts";
import { callRpc, type RpcClient } from "../_shared/db.ts";
import { applyMutations, type Mutation, pullChanges } from "../_shared/domain/sync.ts";
import { expandRecipe } from "../_shared/domain/recipes.ts";
import { acceptDraft, discardDraft, shoppingFromPlan } from "../_shared/domain/planning.ts";
import {
  deviceSchema,
  expandSchema,
  fromPlanSchema,
  idParamSchema,
  parseOrThrow,
  syncPullQuerySchema,
  syncPushSchema,
} from "../_shared/validation.ts";

export interface ApiDeps {
  /** Verifies an access token and returns the user, or null when invalid/expired. */
  verifyToken(jwt: string): Promise<{ id: string } | null>;
  /** Database client bound to the caller's `Authorization` header. */
  clientFor(authorization: string): RpcClient;
}

type Env = { Variables: { userId: string; db: RpcClient } };

async function readJson(c: Context): Promise<unknown> {
  const text = await c.req.text();
  if (text.trim().length === 0) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new ApiError("invalid_request", "Body must be valid JSON");
  }
}

function requireAuth(deps: ApiDeps): MiddlewareHandler<Env> {
  return async (c, next) => {
    const authorization = c.req.header("Authorization") ?? "";
    const match = /^Bearer\s+(.+)$/i.exec(authorization);
    if (!match) throw new ApiError("unauthorized", "Missing bearer token");
    const user = await deps.verifyToken(match[1].trim());
    if (!user) throw new ApiError("unauthorized", "Invalid or expired token");
    c.set("userId", user.id);
    c.set("db", deps.clientFor(`Bearer ${match[1].trim()}`));
    await next();
  };
}

export function createApiApp(deps: ApiDeps): Hono<Env> {
  const app = new Hono<Env>().basePath("/api");

  app.onError((err, c) => {
    if (err instanceof ApiError) return c.json(errorBody(err), err.status as 400);
    console.error("api: unhandled error", err);
    return c.json(errorBody(new ApiError("internal", "Internal error")), 500);
  });
  app.notFound((c) => c.json(errorBody(new ApiError("not_found", "Route not found")), 404));

  app.get("/health", (c) => c.json({ ok: true }));

  app.use("*", requireAuth(deps));

  app.get("/me", async (c) => c.json(await callRpc(c.get("db"), "get_me")));

  app.post("/sync/push", async (c) => {
    const body = parseOrThrow(syncPushSchema, await readJson(c));
    const result = await applyMutations(c.get("db"), body.device_id ?? null, body.mutations as Mutation[]);
    return c.json(result);
  });

  app.get("/sync/pull", async (c) => {
    const query = parseOrThrow(syncPullQuerySchema, {
      cursor: c.req.query("cursor") ?? undefined,
      limit: c.req.query("limit") ?? undefined,
    });
    return c.json(await pullChanges(c.get("db"), query.cursor, query.limit));
  });

  app.put("/devices", async (c) => {
    const body = parseOrThrow(deviceSchema, await readJson(c));
    const device = await callRpc(c.get("db"), "register_device", {
      p_id: body.id,
      p_apns_token: body.apns_token.toLowerCase(),
      p_platform: body.platform,
      p_apns_env: body.apns_env,
      p_app_version: body.app_version ?? null,
    });
    return c.json(device);
  });

  app.delete("/devices/:id", async (c) => {
    const id = parseOrThrow(idParamSchema, c.req.param("id"));
    const deleted = await callRpc<boolean>(c.get("db"), "unregister_device", { p_id: id });
    if (!deleted) throw new ApiError("not_found", "Device not found");
    return c.body(null, 204);
  });

  app.post("/drafts/:id/accept", async (c) => {
    const id = parseOrThrow(idParamSchema, c.req.param("id"));
    return c.json(await acceptDraft(c.get("db"), id));
  });

  app.post("/drafts/:id/discard", async (c) => {
    const id = parseOrThrow(idParamSchema, c.req.param("id"));
    return c.json(await discardDraft(c.get("db"), id));
  });

  app.post("/recipes/:id/expand", async (c) => {
    const id = parseOrThrow(idParamSchema, c.req.param("id"));
    const body = parseOrThrow(expandSchema, await readJson(c));
    return c.json(await expandRecipe(c.get("db"), id, body.servings ?? null));
  });

  app.post("/shopping/from-plan", async (c) => {
    const body = parseOrThrow(fromPlanSchema, await readJson(c));
    return c.json(await shoppingFromPlan(c.get("db"), body.from, body.to), 201);
  });

  return app;
}
