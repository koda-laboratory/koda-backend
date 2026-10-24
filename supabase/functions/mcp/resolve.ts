// Turns what an agent says ("tortilla", "mañana") into the ids and dates the SQL functions take.
import { callRpc, type RpcClient } from "../_shared/db.ts";
import { ApiError } from "../_shared/errors.ts";

interface RecipeCandidate {
  id: string;
  name: string;
  score: number;
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
const RELATIVE_DAYS: Record<string, number> = {
  yesterday: -1,
  ayer: -1,
  today: 0,
  hoy: 0,
  tomorrow: 1,
  "mañana": 1,
  manana: 1,
};

/** A recipe id from an id or a name: a clear best match wins; ambiguous names list the candidates. */
export async function resolveRecipe(db: RpcClient, ref: string): Promise<RecipeCandidate> {
  const candidates = await callRpc<RecipeCandidate[]>(db, "mcp_resolve_recipe", { p_ref: ref });
  if (!candidates || candidates.length === 0) {
    throw new ApiError("not_found", `No recipe matches "${ref}". Use search_recipes to find it.`);
  }
  const [best, second] = candidates;
  if (best.score >= 1 || !second || best.score - second.score >= 0.2) return best;
  throw new ApiError(
    "conflict",
    `"${ref}" matches several recipes: ${candidates.map((c) => `${c.name} (${c.id})`).join(", ")}. ` +
      "Ask which one and pass its id.",
  );
}

/** "today" / "tomorrow" / "yesterday" (also in Spanish) in the household time zone, or an ISO date. */
export async function resolveDate(db: RpcClient, value: string): Promise<string> {
  const trimmed = value.trim().toLowerCase();
  if (ISO_DATE.test(trimmed)) return trimmed;
  const offset = RELATIVE_DAYS[trimmed];
  if (offset === undefined) {
    throw new ApiError("invalid_request", `Use a YYYY-MM-DD date or today/tomorrow/yesterday, not "${value}".`);
  }
  const today = await callRpc<string>(db, "mcp_today");
  return addDays(today, offset);
}

export function addDays(isoDate: string, days: number): string {
  const date = new Date(`${isoDate}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}
