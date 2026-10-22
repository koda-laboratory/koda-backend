#!/usr/bin/env -S deno run --allow-env --allow-read --allow-net
// Imports the Notion "Comidita" extraction (PLAN.md section 11) into one household.
//
// Usage:
//   deno run --allow-env --allow-read --allow-net scripts/import-notion.ts \
//     --household-id <uuid> [--file ../notion-data/comidita.json] [--dry-run] [--today YYYY-MM-DD]
//
// Env (not needed with --dry-run): SUPABASE_URL, SUPABASE_SECRET_KEY.
//
// Idempotent: ids are UUID v5 of (household, Notion id). Rows that already exist are left
// untouched (never overwritten), so a second run inserts 0 rows and keeps edits made in the app.
// Always validate against the local stack first, then dump `koda` before the real import.
import { parseArgs } from "jsr:@std/cli@1.0.32/parse-args";
import { createClient } from "../supabase/functions/_shared/deps.ts";
import { buildImportPlan, IMPORT_TABLES, type NotionData, summarize, todayIn } from "./lib/notion_import.ts";

const args = parseArgs(Deno.args, {
  string: ["household-id", "file", "today"],
  boolean: ["dry-run", "help"],
  default: { file: new URL("../../notion-data/comidita.json", import.meta.url).pathname },
});

if (args.help || !args["household-id"]) {
  console.log("Usage: import-notion.ts --household-id <uuid> [--file path] [--dry-run] [--today YYYY-MM-DD]");
  Deno.exit(args.help ? 0 : 1);
}

const householdId = args["household-id"]!;
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(householdId)) {
  console.error("--household-id must be a UUID");
  Deno.exit(1);
}

const data = JSON.parse(await Deno.readTextFile(args.file)) as NotionData;
const today = args.today ?? todayIn("Europe/Madrid");
const plan = await buildImportPlan(data, householdId, today);

console.log(`Source: ${args.file} (extracted_at ${data.extracted_at ?? "unknown"}), today=${today}`);
if (plan.warnings.length > 0) {
  console.log(`Warnings (${plan.warnings.length}):`);
  for (const warning of plan.warnings) console.log(`  - ${warning}`);
}
console.log("Rows per table:");
console.table(summarize(plan));

if (args["dry-run"]) {
  console.log("Dry run: nothing was written.");
  Deno.exit(0);
}

const url = Deno.env.get("SUPABASE_URL");
const key = Deno.env.get("SUPABASE_SECRET_KEY");
if (!url || !key) {
  console.error("SUPABASE_URL and SUPABASE_SECRET_KEY are required");
  Deno.exit(1);
}
const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

const { data: household, error: householdError } = await db.from("households").select("id, name").eq("id", householdId)
  .maybeSingle();
if (householdError) throw householdError;
if (!household) {
  console.error(`Household ${householdId} not found`);
  Deno.exit(1);
}
console.log(`Importing into household "${household.name}" (${url})`);

const CHUNK = 200;
const result: Record<string, { inserted: number; existing: number }> = {};
for (const table of IMPORT_TABLES) {
  const rows = plan.rows[table];
  const existing = new Set<string>();
  for (let i = 0; i < rows.length; i += CHUNK) {
    const ids = rows.slice(i, i + CHUNK).map((r) => r.id);
    const { data: found, error } = await db.from(table).select("id").in("id", ids);
    if (error) throw new Error(`${table}: ${error.message}`);
    for (const row of found ?? []) existing.add(row.id as string);
  }
  const missing = rows.filter((r) => !existing.has(r.id));
  for (let i = 0; i < missing.length; i += CHUNK) {
    const { error } = await db.from(table).insert(missing.slice(i, i + CHUNK));
    if (error) throw new Error(`${table}: ${error.message}`);
  }
  result[table] = { inserted: missing.length, existing: existing.size };
}
console.log("Result:");
console.table(result);
