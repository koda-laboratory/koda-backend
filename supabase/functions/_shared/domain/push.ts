// Silent-push planning: turns claimed push_queue rows into one notification per device.

export interface QueueRow {
  id: number;
  household_id: string;
  actor_user_id: string | null;
  actor_device_id: string | null;
  kind: string;
  payload: { reasons?: string[]; cursor?: number | string | null } | null;
  created_at: string;
}

export interface PushDevice {
  household_id: string;
  device_id: string;
  user_id: string;
  apns_token: string;
  apns_env: "sandbox" | "production";
  platform: "ios" | "macos";
}

export interface SilentPush {
  device: PushDevice;
  payload: SilentPayload;
}

export interface SilentPayload {
  aps: { "content-available": 1 };
  koda: { reason: string; cursor: number | null };
}

/** Builds the silent background payload (PLAN.md 6.4). Multiple reasons are joined with "|". */
export function buildSilentPayload(reasons: Iterable<string>, cursor: number | null): SilentPayload {
  const unique = [...new Set(reasons)].filter((r) => r.length > 0).sort();
  return {
    aps: { "content-available": 1 },
    koda: { reason: unique.length > 0 ? unique.join("|") : "sync", cursor },
  };
}

interface HouseholdGroup {
  reasons: Set<string>;
  cursor: number | null;
  /** Devices that caused *every* queued change; null once a change has no known actor device. */
  actorDevices: Set<string> | null;
  first: boolean;
}

/**
 * Groups queue rows per household and plans one push per live device of that household.
 * A device is skipped only when it is the actor of every queued change of its household
 * (it already has the data). Each device appears at most once.
 */
export function planSilentPushes(queue: QueueRow[], devices: PushDevice[]): SilentPush[] {
  const groups = new Map<string, HouseholdGroup>();
  for (const row of queue) {
    let group = groups.get(row.household_id);
    if (!group) {
      group = { reasons: new Set(), cursor: null, actorDevices: new Set(), first: true };
      groups.set(row.household_id, group);
    }
    for (const reason of row.payload?.reasons ?? []) group.reasons.add(reason);
    const cursor = row.payload?.cursor == null ? null : Number(row.payload.cursor);
    if (cursor !== null && Number.isFinite(cursor)) {
      group.cursor = group.cursor === null ? cursor : Math.max(group.cursor, cursor);
    }
    // Intersection of actor devices across rows.
    if (group.actorDevices !== null) {
      if (!row.actor_device_id) {
        group.actorDevices = null;
      } else if (group.first) {
        group.actorDevices.add(row.actor_device_id);
      } else if (!group.actorDevices.has(row.actor_device_id)) {
        group.actorDevices = null;
      } else {
        group.actorDevices = new Set([row.actor_device_id]);
      }
    }
    group.first = false;
  }

  const pushes: SilentPush[] = [];
  const seen = new Set<string>();
  for (const device of devices) {
    const group = groups.get(device.household_id);
    if (!group) continue;
    if (group.actorDevices?.has(device.device_id)) continue;
    if (seen.has(device.device_id)) continue;
    seen.add(device.device_id);
    pushes.push({ device, payload: buildSilentPayload(group.reasons, group.cursor) });
  }
  return pushes;
}
