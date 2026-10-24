// Sync contract helpers: table list and pull response shaping.
import { callRpc, type RpcClient } from "../db.ts";

/** Synced tables in dependency order (parents first). Must match public.synced_tables(). */
export const SYNCED_TABLES = [
  "stores",
  "products",
  "product_stores",
  "recipes",
  "recipe_ingredients",
  "recipe_components",
  "recipe_photos",
  "meal_plan_drafts",
  "meal_plan_entries",
  "consumptions",
  "shopping_entries",
  "shopping_entry_items",
  "frozen_items",
] as const;
export type SyncedTable = (typeof SYNCED_TABLES)[number];

export interface Mutation {
  table: SyncedTable;
  id: string;
  op: "upsert" | "delete";
  fields?: Record<string, unknown>;
  client_ts: string;
}

export interface ApplyResult {
  applied: Array<{ table: string; id: string; server_seq: number; merged?: boolean }>;
  rejected: Array<{ table: string | null; id: unknown; reason: string; code?: string; message?: string }>;
  cursor: number | null;
}

/** Raw result of public.pull_changes. */
export interface RawPull {
  rows: Array<{ table: string; row: Record<string, unknown> }>;
  has_more: boolean;
  cursor: number;
  reset_required: boolean;
}

export interface PullResponse {
  changes: Partial<Record<SyncedTable, Record<string, unknown>[]>>;
  cursor: number;
  has_more: boolean;
  reset_required: boolean;
}

/** Groups pulled rows per table, preserving server_seq order inside each table. */
export function groupPull(raw: RawPull): PullResponse {
  const changes: PullResponse["changes"] = {};
  for (const { table, row } of raw.rows) {
    const key = table as SyncedTable;
    (changes[key] ??= []).push(row);
  }
  return {
    changes,
    cursor: Number(raw.cursor),
    has_more: Boolean(raw.has_more),
    reset_required: Boolean(raw.reset_required),
  };
}

export function applyMutations(db: RpcClient, deviceId: string | null, mutations: Mutation[]): Promise<ApplyResult> {
  return callRpc<ApplyResult>(db, "apply_mutations", { p_device_id: deviceId, p_mutations: mutations });
}

export async function pullChanges(db: RpcClient, cursor: number, limit: number): Promise<PullResponse> {
  const raw = await callRpc<RawPull>(db, "pull_changes", { p_cursor: cursor, p_limit: limit });
  return groupPull(raw);
}
