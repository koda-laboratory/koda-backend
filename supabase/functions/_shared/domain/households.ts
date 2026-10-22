// Household settings (meal times per slot and the default shopping weekday).
import { callRpc, type RpcClient } from "../db.ts";
import { ApiError } from "../errors.ts";

export type MealSlot = "breakfast" | "lunch" | "snack" | "dinner";

export interface HouseholdSettings {
  slot_times?: Partial<Record<MealSlot, string>>;
  /** ISO weekday: 1 = Monday … 7 = Sunday. */
  shopping_weekday?: number;
}

/** Household object as listed by GET /me. */
export interface Household {
  id: string;
  name: string;
  timezone: string;
  slot_times: Record<MealSlot, string>;
  shopping_weekday: number;
  role: "owner" | "member";
  members: Array<{ user_id: string; role: string; display_name: string | null; avatar_emoji: string | null }>;
}

/** Any member may update the settings; returns the updated household. */
export async function updateHouseholdSettings(
  db: RpcClient,
  householdId: string,
  settings: HouseholdSettings,
): Promise<Household> {
  const household = await callRpc<Household | null>(db, "update_household_settings", {
    p_household_id: householdId,
    p_slot_times: settings.slot_times ?? null,
    p_shopping_weekday: settings.shopping_weekday ?? null,
  });
  if (!household) throw new ApiError("not_found", "Household not found");
  return household;
}
