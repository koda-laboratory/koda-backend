// Entry point of the `mcp` Edge Function. Server, tools and auth live in app.ts.
import { createMcpApp } from "./app.ts";
import { optionalEnv, requireEnv } from "../_shared/env.ts";
import { createUserClient, verifyAccessToken } from "../_shared/supabase.ts";

// Hosted, SUPABASE_URL is the public project URL. Locally it is the internal gateway, so MCP_PUBLIC_URL
// (e.g. http://127.0.0.1:54321) gives the address clients see.
const publicUrl = optionalEnv("MCP_PUBLIC_URL") ?? requireEnv("SUPABASE_URL");

const app = createMcpApp({
  verifyToken: verifyAccessToken,
  clientFor: createUserClient,
  resourceUrl: `${publicUrl}/functions/v1/mcp`,
  authorizationServer: `${publicUrl}/auth/v1`,
});

Deno.serve(app.fetch);
