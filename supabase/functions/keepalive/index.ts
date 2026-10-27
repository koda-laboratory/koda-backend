// Entry point of the internal `keepalive` Edge Function.
// Called daily by pg_cron and by the GitHub Actions fallback. It keeps the free-plan project
// active, purges tombstones older than 30 days (public.purge_tombstones) and removes orphan recipe and product images.
import { optionalEnv } from "../_shared/env.ts";
import { hasInternalSecret } from "../_shared/internal.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import { IMAGE_BUCKETS, type KeepaliveStore, runKeepalive } from "./handler.ts";

function adminStore(): KeepaliveStore {
  const client = createAdminClient();
  return {
    async purgeTombstones() {
      const { data, error } = await client.rpc("purge_tombstones");
      if (error) throw error;
      return (data ?? {}) as Record<string, unknown>;
    },
    async orphanImages(bucket, limit) {
      const { data, error } = await client.rpc(IMAGE_BUCKETS[bucket], { p_limit: limit });
      if (error) throw error;
      return (data ?? []) as string[];
    },
    async removeImages(bucket, paths) {
      const { error } = await client.storage.from(bucket).remove(paths);
      if (error) throw error;
    },
  };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  if (!hasInternalSecret(request, optionalEnv("KEEPALIVE_SECRET"))) {
    return Response.json({ error: { code: "unauthorized", message: "Invalid secret" } }, { status: 401 });
  }
  try {
    return Response.json({ ok: true, ...(await runKeepalive(adminStore())) });
  } catch (error) {
    console.error("keepalive: purge failed", error);
    return Response.json({ error: { code: "internal", message: "Purge failed" } }, { status: 500 });
  }
});
