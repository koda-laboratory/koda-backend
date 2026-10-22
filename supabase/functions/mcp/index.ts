// `mcp` Edge Function: skeleton only (phase 0/1).
//
// TODO(phase 6, PLAN.md section 8):
// - Streamable HTTP MCP server (stateless) with the tools of section 8.3 and the `plan_week` prompt.
// - OAuth 2.1 through the Supabase Auth OAuth server; publish /.well-known/oauth-protected-resource.
// - Every request uses the caller's JWT (createUserClient) so RLS applies; share logic with `api`
//   through _shared/domain.
import { Hono } from "../_shared/deps.ts";

const app = new Hono().basePath("/mcp");

app.get("/health", (c) => c.json({ ok: true, server: "koda-mcp", status: "skeleton" }));

app.all("*", (c) =>
  c.json(
    { jsonrpc: "2.0", id: null, error: { code: -32601, message: "Koda MCP server is not implemented yet" } },
    501,
  ));

Deno.serve(app.fetch);
