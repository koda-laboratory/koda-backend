// Entry point of the internal `keepalive` Edge Function.
// Called daily by pg_cron and by the GitHub Actions fallback. It keeps the free-plan project
// active and purges tombstones older than 30 days (public.purge_tombstones).
import { optionalEnv } from "../_shared/env.ts";
import { hasInternalSecret } from "../_shared/internal.ts";
import { createAdminClient } from "../_shared/supabase.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  if (!hasInternalSecret(request, optionalEnv("KEEPALIVE_SECRET"))) {
    return Response.json({ error: { code: "unauthorized", message: "Invalid secret" } }, { status: 401 });
  }
  const { data, error } = await createAdminClient().rpc("purge_tombstones");
  if (error) {
    console.error("keepalive: purge failed", error);
    return Response.json({ error: { code: "internal", message: "Purge failed" } }, { status: 500 });
  }
  return Response.json({ ok: true, ...data });
});
