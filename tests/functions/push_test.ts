import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  buildDefrostPayload,
  buildSilentPayload,
  planPushes,
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
    {
      token: string;
      env: string;
      payload: unknown;
      pushType: string;
      priority: number;
      expiration: number;
      collapseId?: string;
    }
  > = [];
  constructor(private statusFor: (token: string) => number = () => 200) {}
  send(
    token: string,
    env: "sandbox" | "production",
    payload: unknown,
    options: { pushType: string; priority: number; expirationSeconds: number; collapseId?: string },
  ): Promise<ApnsResult> {
    this.sent.push({
      token,
      env,
      payload,
      pushType: options.pushType,
      priority: options.priority,
      expiration: options.expirationSeconds,
      collapseId: options.collapseId,
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

function defrostRow(id: number, household: string, actor: string | null, frozenItemId: string): QueueRow {
  return {
    id,
    household_id: household,
    actor_user_id: null,
    actor_device_id: actor,
    kind: "defrost",
    payload: {
      title: "Descongela carrilleras",
      body: "Mañana a las 14:30 toca Paella de carrilleras",
      frozen_item_id: frozenItemId,
      product_id: "p1",
      meal_plan_entry_id: "m1",
      recipe_id: "r1",
    },
    created_at: "2026-10-22T10:00:00Z",
  };
}

Deno.test("defrost payload is a visible alert with category and thread", () => {
  assertEquals(buildDefrostPayload(defrostRow(1, H1, null, "f1").payload), {
    aps: {
      alert: { title: "Descongela carrilleras", body: "Mañana a las 14:30 toca Paella de carrilleras" },
      sound: "default",
      category: "DEFROST",
      "thread-id": "defrost",
    },
    koda: { kind: "defrost", frozen_item_id: "f1", recipe_id: "r1", meal_plan_entry_id: "m1" },
  });
});

Deno.test("defrost reminders go to every household device, including the actor", () => {
  const pushes = planPushes(
    [defrostRow(1, H1, "A", "f1"), defrostRow(2, H1, null, "f2")],
    [device("A", H1), device("B", H1), device("X", H2)],
  );
  assertEquals(pushes.map((p) => [p.kind, p.device.device_id]), [
    ["defrost", "A"],
    ["defrost", "B"],
    ["defrost", "A"],
    ["defrost", "B"],
  ]);
});

Deno.test("sync rows stay batched and silent next to defrost rows; unknown kinds are ignored", () => {
  const unknown: QueueRow = { ...row(9, H1, null, ["shopping"], 99), kind: "mystery" };
  const pushes = planPushes(
    [row(1, H1, "A", ["shopping"], 10), defrostRow(2, H1, null, "f1"), row(3, H1, "A", ["planning"], 12), unknown],
    [device("A", H1), device("B", H1)],
  );
  const sync = pushes.filter((p) => p.kind === "sync");
  assertEquals(sync.map((p) => p.device.device_id), ["B"]);
  assertEquals(sync[0].payload, { aps: { "content-available": 1 }, koda: { reason: "planning|shopping", cursor: 12 } });
  assertEquals(pushes.filter((p) => p.kind === "defrost").map((p) => p.device.device_id), ["A", "B"]);
});

Deno.test("drain sends defrost alerts with alert headers and silent pushes with background headers", async () => {
  const store = new FakeStore(
    [row(1, H1, "A", ["shopping"], 7), defrostRow(2, H1, "A", "f1")],
    [device("A", H1), device("B", H1, "sandbox")],
  );
  const apns = new FakeApns();
  const result = await drainPushQueue(store, apns);
  assertEquals(result, { claimed: 2, sent: 3, failed: 0, disabled: 0 });
  assertEquals(apns.sent.map((s) => [s.token, s.pushType, s.priority, s.expiration, s.collapseId ?? null]), [
    ["token-B", "background", 5, 3600, null],
    ["token-A", "alert", 10, 43200, "defrost-f1"],
    ["token-B", "alert", 10, 43200, "defrost-f1"],
  ]);
  const alert = apns.sent[1].payload as { aps: { alert: { title: string } }; koda: { kind: string } };
  assertEquals(alert.aps.alert.title, "Descongela carrilleras");
  assertEquals(alert.koda.kind, "defrost");
});
