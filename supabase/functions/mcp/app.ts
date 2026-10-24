// `mcp` Edge Function: a remote MCP server (Streamable HTTP, stateless) usable from any MCP client.
//
// Authentication is standard OAuth 2.1 through the Supabase Auth OAuth server: unauthenticated requests get a 401
// whose WWW-Authenticate header points to this resource's metadata, which names Supabase Auth as the
// authorization server (discovery and dynamic client registration happen there). Every tool then runs with the
// caller's access token, so RLS limits it to their household exactly like the apps.
import { cors, Hono, McpServer, WebStandardStreamableHTTPServerTransport } from "../_shared/deps.ts";
import type { RpcClient } from "../_shared/db.ts";
import { registerTools, run } from "./tools.ts";
import { type ImageFetcher, type ImageStore, registerImageTools } from "./images.ts";
import { registerPrompts } from "./prompts.ts";

export interface McpDeps {
  /** Verifies an access token and returns the user, or null when invalid or expired. */
  verifyToken(jwt: string): Promise<{ id: string } | null>;
  /** Database client bound to the caller's `Authorization` header. */
  clientFor(authorization: string): RpcClient;
  /** Recipe image storage bound to the caller's `Authorization` header. */
  storeFor(authorization: string): ImageStore;
  /** Downloads images agents hand over by URL. */
  fetchImage: ImageFetcher;
  /** Public URL of this function (`https://<ref>.supabase.co/functions/v1/mcp`). */
  resourceUrl: string;
  /** Supabase Auth issuer (`https://<ref>.supabase.co/auth/v1`). */
  authorizationServer: string;
}

export const SERVER_INFO = { name: "koda", title: "Koda", version: "1.0.0" };

const INSTRUCTIONS = [
  "Koda is a household app for meals: recipes, the meal planning and the shopping list, shared by the members",
  "of one household. Dates are in the household's time zone: call get_household first for today's date and the",
  "usual meal times. Recipes can be referred to by name. Planned meals that already passed are logged as eaten",
  "automatically. To propose several meals at once, create a draft (create_meal_plan_draft) that the household",
  "reviews in the app instead of planning them one by one. Recipe images: Koda does not generate them; make one",
  "with your own image tool and hand it over with set_recipe_cover (a URL) or create_recipe_image_upload (a file),",
  "and never replace an existing cover unless asked. Reply in the user's language.",
].join(" ");

const PROTECTED_RESOURCE_PATH = "/.well-known/oauth-protected-resource";

export function createMcpApp(deps: McpDeps): Hono {
  const app = new Hono().basePath("/mcp");
  const metadataUrl = `${deps.resourceUrl}${PROTECTED_RESOURCE_PATH}`;

  app.use(
    "*",
    cors({
      origin: "*",
      allowHeaders: ["Authorization", "Content-Type", "Mcp-Session-Id", "Mcp-Protocol-Version", "Last-Event-ID"],
      exposeHeaders: ["WWW-Authenticate", "Mcp-Session-Id"],
      allowMethods: ["GET", "POST", "DELETE", "OPTIONS"],
    }),
  );

  app.get("/health", (c) => c.json({ ok: true, server: SERVER_INFO.name, version: SERVER_INFO.version }));

  // RFC 9728: where clients learn which authorization server issues tokens for this resource.
  app.get(PROTECTED_RESOURCE_PATH, (c) =>
    c.json({
      resource: deps.resourceUrl,
      authorization_servers: [deps.authorizationServer],
      bearer_methods_supported: ["header"],
      scopes_supported: ["openid", "email", "profile"],
      resource_name: "Koda",
      resource_documentation: "https://github.com/koda-laboratory/koda-backend",
    }));

  app.all("*", async (c) => {
    const authorization = c.req.header("Authorization") ?? "";
    const token = /^Bearer\s+(.+)$/i.exec(authorization)?.[1]?.trim();
    const user = token ? await deps.verifyToken(token) : null;
    if (!token || !user) {
      return c.json(
        { jsonrpc: "2.0", id: null, error: { code: -32001, message: "Authentication required" } },
        401,
        { "WWW-Authenticate": `Bearer resource_metadata="${metadataUrl}"` },
      );
    }

    // Stateless: a server per request, bound to this caller's database client.
    const server = new McpServer(SERVER_INFO, { instructions: INSTRUCTIONS });
    const db = deps.clientFor(`Bearer ${token}`);
    registerTools(server, db);
    registerImageTools(server, db, deps.storeFor(`Bearer ${token}`), deps.fetchImage, run);
    registerPrompts(server);
    const transport = new WebStandardStreamableHTTPServerTransport({ enableJsonResponse: true });
    await server.connect(transport);
    return transport.handleRequest(c.req.raw);
  });

  return app;
}
