// Entry point of the `api` Edge Function. Routes live in app.ts.
import { createApiApp } from "./app.ts";
import { createUserClient, verifyAccessToken } from "../_shared/supabase.ts";

const app = createApiApp({
  verifyToken: verifyAccessToken,
  clientFor: createUserClient,
});

Deno.serve(app.fetch);
