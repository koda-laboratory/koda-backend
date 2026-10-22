// Entry point of the internal `push` Edge Function.
// Invoked every minute by pg_cron (private.kick_push) with the `x-koda-secret` header.
import { ApnsClient, apnsConfigFromEnv } from "../_shared/apns.ts";
import { optionalEnv } from "../_shared/env.ts";
import { hasInternalSecret } from "../_shared/internal.ts";
import { createAdminClient } from "../_shared/supabase.ts";
import type { PushDevice, QueueRow } from "../_shared/domain/push.ts";
import { drainPushQueue, type PushStore } from "./handler.ts";

const config = apnsConfigFromEnv();
const apns = config ? new ApnsClient(config) : null;

function adminStore(): PushStore {
  const admin = createAdminClient();
  return {
    async claimBatch(limit) {
      const { data, error } = await admin.rpc("claim_push_batch", { p_limit: limit });
      if (error) throw new Error(`claim_push_batch: ${error.message}`);
      return (data ?? []) as QueueRow[];
    },
    async devicesFor(householdIds) {
      const { data, error } = await admin.rpc("push_devices_for_households", { p_household_ids: householdIds });
      if (error) throw new Error(`push_devices_for_households: ${error.message}`);
      return (data ?? []) as PushDevice[];
    },
    async disableDevice(deviceId) {
      const { error } = await admin.from("devices").update({ disabled_at: new Date().toISOString() }).eq(
        "id",
        deviceId,
      );
      if (error) throw new Error(`disable device: ${error.message}`);
    },
  };
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  if (!hasInternalSecret(request, optionalEnv("PUSH_INTERNAL_SECRET"))) {
    return Response.json({ error: { code: "unauthorized", message: "Invalid secret" } }, { status: 401 });
  }
  try {
    return Response.json(await drainPushQueue(adminStore(), apns));
  } catch (error) {
    console.error("push: drain failed", error);
    return Response.json({ error: { code: "internal", message: "Drain failed" } }, { status: 500 });
  }
});
