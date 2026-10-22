// Drains push_queue: one silent background push per device for sync rows (PLAN.md 6.2 / 6.4) and a
// visible alert to every household device for defrost reminders (PLAN.md 3.6).
import { ALERT_PUSH_OPTIONS, type ApnsRequestOptions, type ApnsSender, SILENT_PUSH_OPTIONS } from "../_shared/apns.ts";
import { type PlannedPush, planPushes, type PushDevice, type QueueRow } from "../_shared/domain/push.ts";

export interface PushStore {
  /** Claims (marks as sent) pending queue rows. */
  claimBatch(limit: number): Promise<QueueRow[]>;
  devicesFor(householdIds: string[]): Promise<PushDevice[]>;
  disableDevice(deviceId: string): Promise<void>;
}

export interface DrainResult {
  claimed: number;
  sent: number;
  failed: number;
  disabled: number;
  skipped?: string;
}

function optionsFor(push: PlannedPush): ApnsRequestOptions {
  return push.kind === "defrost" ? { ...ALERT_PUSH_OPTIONS, collapseId: push.collapseId } : SILENT_PUSH_OPTIONS;
}

export async function drainPushQueue(
  store: PushStore,
  apns: ApnsSender | null,
  batchSize = 500,
): Promise<DrainResult> {
  if (!apns) {
    // Leave the queue untouched so nothing is lost once APNs is configured.
    return { claimed: 0, sent: 0, failed: 0, disabled: 0, skipped: "apns_not_configured" };
  }
  const queue = await store.claimBatch(batchSize);
  if (queue.length === 0) return { claimed: 0, sent: 0, failed: 0, disabled: 0 };

  const householdIds = [...new Set(queue.map((row) => row.household_id))];
  const devices = await store.devicesFor(householdIds);
  const pushes = planPushes(queue, devices);

  const results = await Promise.allSettled(
    pushes.map(async (push) => {
      const { device, payload } = push;
      const result = await apns.send(device.apns_token, device.apns_env, payload, optionsFor(push));
      if (result.unregistered) await store.disableDevice(device.device_id);
      if (!result.ok) {
        console.warn("push: APNs rejected", {
          device: device.device_id,
          kind: push.kind,
          status: result.status,
          reason: result.reason,
        });
      }
      return result;
    }),
  );

  let sent = 0, failed = 0, disabled = 0;
  for (const settled of results) {
    if (settled.status === "fulfilled" && settled.value.ok) sent++;
    else failed++;
    if (settled.status === "fulfilled" && settled.value.unregistered) disabled++;
    if (settled.status === "rejected") console.error("push: send failed", settled.reason);
  }
  return { claimed: queue.length, sent, failed, disabled };
}
