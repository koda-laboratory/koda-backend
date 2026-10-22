import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  buildSilentPayload,
  planSilentPushes,
  type PushDevice,
  type QueueRow,
} from "../../supabase/functions/_shared/domain/push.ts";
import { drainPushQueue, type PushStore } from "../../supabase/functions/push/handler.ts";
import type { ApnsResult, ApnsSender } from "../../supabase/functions/_shared/apns.ts";

const H1 = "11111111-1111-4111-8111-111111111111";
const H2 = "22222222-2222-4222-8222-222222222222";

function row(id: number, household: string, device: string | null, reasons: string[], cursor: number): QueueRow {
  return {
    id,
    household_id: household,
    actor_user_id: null,
    actor_device_id: device,
    kind: "sync",
    payload: { reasons, cursor },
    created_at: "2026-10-22T10:00:00Z",
  };
}

function device(id: string, household: string, env: "sandbox" | "production" = "production"): PushDevice {
  return {
    household_id: household,
    device_id: id,
    user_id: "u",
    apns_token: `token-${id}`,
    apns_env: env,
    platform: "ios",
  };
}

Deno.test("silent payload matches PLAN 6.4", () => {
  assertEquals(buildSilentPayload(["shopping", "planning", "shopping"], 42), {
    aps: { "content-available": 1 },
    koda: { reason: "planning|shopping", cursor: 42 },
  });
  assertEquals(buildSilentPayload([], null).koda.reason, "sync");
});

Deno.test("the actor device is excluded, other devices of the household get one push", () => {
  const pushes = planSilentPushes(
    [row(1, H1, "A", ["shopping"], 10), row(2, H1, "A", ["planning"], 12)],
    [device("A", H1), device("B", H1), device("M", H1, "sandbox"), device("X", H2)],
  );
  assertEquals(pushes.map((p) => p.device.device_id), ["B", "M"]);
  assertEquals(pushes[0].payload.koda, { reason: "planning|shopping", cursor: 12 });
});

Deno.test("a device is notified when other actors also changed data", () => {
  const pushes = planSilentPushes(
    [row(1, H1, "A", ["shopping"], 10), row(2, H1, "B", ["shopping"], 11), row(3, H1, null, ["recipes"], 12)],
    [device("A", H1), device("B", H1)],
  );
  assertEquals(pushes.map((p) => p.device.device_id), ["A", "B"]);
});

class FakeStore implements PushStore {
  disabled: string[] = [];
  claimed = 0;
  constructor(private queue: QueueRow[], private devices: PushDevice[]) {}
  claimBatch() {
    this.claimed++;
    const rows = this.queue;
    this.queue = [];
    return Promise.resolve(rows);
  }
  devicesFor(ids: string[]) {
    return Promise.resolve(this.devices.filter((d) => ids.includes(d.household_id)));
  }
  disableDevice(id: string) {
    this.disabled.push(id);
    return Promise.resolve();
  }
}

class FakeApns implements ApnsSender {
  sent: Array<
    { token: string; env: string; payload: unknown; pushType: string; priority: number; expiration: number }
  > = [];
  constructor(private statusFor: (token: string) => number = () => 200) {}
  send(
    token: string,
    env: "sandbox" | "production",
    payload: unknown,
    options: { pushType: string; priority: number; expirationSeconds: number },
  ): Promise<ApnsResult> {
    this.sent.push({
      token,
      env,
      payload,
      pushType: options.pushType,
      priority: options.priority,
      expiration: options.expirationSeconds,
    });
    const status = this.statusFor(token);
    return Promise.resolve({
      ok: status === 200,
      status,
      unregistered: status === 410,
      reason: status === 410 ? "Unregistered" : undefined,
    });
  }
}

Deno.test("drain sends background pushes and disables unregistered devices", async () => {
  const store = new FakeStore([row(1, H1, "A", ["shopping"], 7)], [
    device("A", H1),
    device("B", H1),
    device("C", H1, "sandbox"),
  ]);
  const apns = new FakeApns((token) => (token === "token-C" ? 410 : 200));
  const result = await drainPushQueue(store, apns);
  assertEquals(result, { claimed: 1, sent: 1, failed: 1, disabled: 1 });
  assertEquals(apns.sent.map((s) => [s.token, s.env, s.pushType, s.priority, s.expiration]), [
    ["token-B", "production", "background", 5, 3600],
    ["token-C", "sandbox", "background", 5, 3600],
  ]);
  assertEquals(store.disabled, ["C"]);
});

Deno.test("drain without APNs configuration leaves the queue untouched", async () => {
  const store = new FakeStore([row(1, H1, "A", ["shopping"], 7)], []);
  const result = await drainPushQueue(store, null);
  assertEquals(result.skipped, "apns_not_configured");
  assertEquals(store.claimed, 0);
});

Deno.test("drain with an empty queue does nothing", async () => {
  const apns = new FakeApns();
  assertEquals(await drainPushQueue(new FakeStore([], []), apns), { claimed: 0, sent: 0, failed: 0, disabled: 0 });
  assertEquals(apns.sent.length, 0);
});
