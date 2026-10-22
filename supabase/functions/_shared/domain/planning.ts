// Meal plan drafts and shopping list generation from the planning.
import { callRpc, type RpcClient } from "../db.ts";

export async function acceptDraft(db: RpcClient, draftId: string): Promise<{ draft_id: string; entries: number }> {
  const entries = await callRpc<number>(db, "accept_meal_plan_draft", { p_draft_id: draftId });
  return { draft_id: draftId, entries };
}

export async function discardDraft(db: RpcClient, draftId: string): Promise<{ draft_id: string; entries: number }> {
  const entries = await callRpc<number>(db, "discard_meal_plan_draft", { p_draft_id: draftId });
  return { draft_id: draftId, entries };
}

export function shoppingFromPlan(
  db: RpcClient,
  from: string,
  to: string,
): Promise<{ created: number; entry_ids: string[] }> {
  return callRpc(db, "shopping_from_plan", { p_from: from, p_to: to });
}
