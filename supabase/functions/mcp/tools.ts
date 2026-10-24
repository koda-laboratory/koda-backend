// Koda's MCP tools (PLAN.md 8.3). Each handler is thin: validate, resolve names and relative dates, call one
// SECURITY INVOKER Postgres function with the caller's token (RLS applies), and return JSON.
import { type McpServer, z } from "../_shared/deps.ts";
import { callRpc, type RpcClient } from "../_shared/db.ts";
import { ApiError } from "../_shared/errors.ts";
import { acceptDraft, discardDraft } from "../_shared/domain/planning.ts";
import { resolveDate, resolveRecipe } from "./resolve.ts";

const slot = z.enum(["breakfast", "lunch", "snack", "dinner"]);
const day = z.string().describe("A YYYY-MM-DD date, or today / tomorrow / yesterday (household time zone).");
const recipeRef = z.string().min(1).describe("Recipe id, or its name (an unambiguous part of it is enough).");
const uuid = z.guid();

const READ = { readOnlyHint: true, destructiveHint: false, openWorldHint: false } as const;
const WRITE = { readOnlyHint: false, destructiveHint: false, openWorldHint: false } as const;
const DESTRUCTIVE = { readOnlyHint: false, destructiveHint: true, openWorldHint: false } as const;

type ToolResult = { content: Array<{ type: "text"; text: string }>; isError?: boolean };

/** Runs a handler and turns its value (or error) into an MCP result agents can read. */
async function run(handler: () => Promise<unknown>): Promise<ToolResult> {
  try {
    const value = await handler();
    return { content: [{ type: "text", text: JSON.stringify(value ?? null, null, 2) }] };
  } catch (error) {
    const message = error instanceof ApiError ? error.message : "Unexpected error";
    if (!(error instanceof ApiError)) console.error("mcp: tool failed", error);
    return { content: [{ type: "text", text: message }], isError: true };
  }
}

export function registerTools(server: McpServer, db: RpcClient): void {
  // ----------------------------------------------------------------- household
  server.registerTool("get_household", {
    title: "Household",
    description: "The household, its members, today's date in its time zone, the usual meal times per slot " +
      "and the shopping weekday (1 = Monday … 7 = Sunday). Call it first to resolve relative dates.",
    annotations: READ,
  }, () =>
    run(async () => {
      const me = await callRpc<{ households?: unknown[] }>(db, "get_me");
      const today = await callRpc<string>(db, "mcp_today");
      return { today, household: me?.households?.[0] ?? null };
    }));

  // ----------------------------------------------------------------- planning
  server.registerTool("get_meals", {
    title: "Planned meals",
    description: "Meals planned between two dates (inclusive, max 62 days), optionally for one slot. Each meal " +
      "has its time, the recipe or free text, servings, whether it was eaten and whether it was skipped.",
    inputSchema: { from: day, to: day.optional(), slot: slot.optional() },
    annotations: READ,
  }, ({ from, to, slot }) =>
    run(async () => {
      const start = await resolveDate(db, from);
      const end = to ? await resolveDate(db, to) : start;
      return await callRpc(db, "mcp_get_meals", { p_from: start, p_to: end, p_slot: slot ?? null });
    }));

  server.registerTool("plan_meal", {
    title: "Plan a meal",
    description: 'Adds a meal to the planning: a recipe (by id or name) or a free text such as "Comemos fuera". ' +
      "Existing meals in that slot are kept. Optional own time (HH:MM), servings and note.",
    inputSchema: {
      date: day,
      slot,
      recipe: recipeRef.optional(),
      free_text: z.string().min(1).optional(),
      servings: z.number().positive().optional(),
      time: z.string().regex(/^\d{2}:\d{2}$/).optional().describe("HH:MM, only if different from the usual time."),
      note: z.string().optional(),
    },
    annotations: WRITE,
  }, ({ date, slot, recipe, free_text, servings, time, note }) =>
    run(async () => {
      if (!recipe === !free_text) throw new ApiError("invalid_request", "Give either recipe or free_text.");
      const recipeId = recipe ? (await resolveRecipe(db, recipe)).id : null;
      return await callRpc(db, "mcp_plan_meal", {
        p_date: await resolveDate(db, date),
        p_slot: slot,
        p_recipe_id: recipeId,
        p_free_text: free_text ?? null,
        p_servings: servings ?? null,
        p_time: time ?? null,
        p_note: note ?? null,
      });
    }));

  server.registerTool("remove_planned_meal", {
    title: "Remove a planned meal",
    description: "Removes one planned meal by its id (from get_meals).",
    inputSchema: { entry_id: uuid },
    annotations: DESTRUCTIVE,
  }, ({ entry_id }) =>
    run(async () => {
      const removed = await callRpc<boolean>(db, "mcp_remove_planned_meal", { p_entry_id: entry_id });
      if (!removed) throw new ApiError("not_found", "No planned meal with that id.");
      return { removed: true };
    }));

  server.registerTool("get_meal_history", {
    title: "Meal history",
    description: "Recipes actually eaten between two dates (max 366 days).",
    inputSchema: { from: day, to: day.optional() },
    annotations: READ,
  }, ({ from, to }) =>
    run(async () => {
      const start = await resolveDate(db, from);
      return await callRpc(db, "mcp_meal_history", { p_from: start, p_to: to ? await resolveDate(db, to) : start });
    }));

  // ----------------------------------------------------------------- recipes
  server.registerTool("search_recipes", {
    title: "Search recipes",
    description: "The household's recipes, filtered by text (name or ingredient), meal type, nutrients, maximum " +
      "minutes and favourites. Includes how often and when each one was last eaten.",
    inputSchema: {
      query: z.string().optional(),
      meal_type: slot.optional(),
      nutrients: z.array(z.enum(["fats", "fiber", "vegetables", "protein", "carbs"])).optional(),
      max_minutes: z.number().int().positive().optional(),
      favorites_only: z.boolean().optional(),
      limit: z.number().int().positive().max(200).optional(),
    },
    annotations: READ,
  }, (args) =>
    run(() =>
      callRpc(db, "mcp_search_recipes", {
        p_query: args.query ?? null,
        p_meal_type: args.meal_type ?? null,
        p_nutrients: args.nutrients ?? null,
        p_max_minutes: args.max_minutes ?? null,
        p_favorites_only: args.favorites_only ?? false,
        p_limit: args.limit ?? 25,
      })
    ));

  server.registerTool("get_recipe", {
    title: "Recipe",
    description: "A recipe with its ingredients, the recipes it includes, every ingredient flattened, steps, " +
      "notes and stats.",
    inputSchema: { recipe: recipeRef },
    annotations: READ,
  }, ({ recipe }) =>
    run(async () => {
      const { id } = await resolveRecipe(db, recipe);
      return await callRpc(db, "mcp_get_recipe", { p_recipe_id: id });
    }));

  server.registerTool("get_recipe_stats", {
    title: "Recipe stats",
    description: "Recipes with times eaten, last eaten date and meals in the last 14 days, oldest first. Use " +
      "not_eaten_since_days to find what has not been eaten for a while.",
    inputSchema: {
      not_eaten_since_days: z.number().int().nonnegative().optional(),
      limit: z.number().int().positive().max(500).optional(),
    },
    annotations: READ,
  }, ({ not_eaten_since_days, limit }) =>
    run(() =>
      callRpc(db, "mcp_recipe_stats", {
        p_not_eaten_since_days: not_eaten_since_days ?? null,
        p_limit: limit ?? 50,
      })
    ));

  // ----------------------------------------------------------------- shopping
  server.registerTool("get_shopping_list", {
    title: "Shopping list",
    description: "What is on the shopping list. Each entry and recipe product has a status: pending (to buy), " +
      "have (bought or at home) or frozen (in the freezer, a defrost reminder follows). By default lists what " +
      "is still to buy or frozen.",
    inputSchema: { include_done: z.boolean().optional() },
    annotations: READ,
  }, ({ include_done }) => run(() => callRpc(db, "mcp_shopping_list", { p_include_done: include_done ?? false })));

  server.registerTool("add_to_shopping_list", {
    title: "Add to the shopping list",
    description: "Adds items to the shopping list. Names are matched against the product catalog (accents and " +
      "case don't matter); unknown names become free-text entries. A product already pending is not repeated.",
    inputSchema: {
      items: z.array(z.object({
        name: z.string().min(1),
        quantity: z.number().positive().optional(),
        unit: z.string().optional(),
      })).min(1).max(50),
    },
    annotations: WRITE,
  }, ({ items }) => run(() => callRpc(db, "mcp_add_shopping_items", { p_items: items })));

  server.registerTool("set_shopping_status", {
    title: "Mark shopping items",
    description: "Sets the status of shopping entries or recipe products (ids from get_shopping_list): have " +
      "(bought or at home), pending (to buy again) or frozen (in the freezer).",
    inputSchema: { ids: z.array(uuid).min(1).max(100), status: z.enum(["pending", "have", "frozen"]) },
    annotations: WRITE,
  }, ({ ids, status }) => run(() => callRpc(db, "mcp_set_shopping_status", { p_ids: ids, p_status: status })));

  server.registerTool("add_recipe_to_shopping_list", {
    title: "Add a recipe to the shopping list",
    description: "Adds one grouped entry with all the products of a recipe (sub-recipes included), scaled to " +
      "the given servings or the recipe's own.",
    inputSchema: { recipe: recipeRef, servings: z.number().positive().optional() },
    annotations: WRITE,
  }, ({ recipe, servings }) =>
    run(async () => {
      const { id } = await resolveRecipe(db, recipe);
      return await callRpc(db, "mcp_add_recipe_to_shopping", { p_recipe_id: id, p_servings: servings ?? null });
    }));

  // ----------------------------------------------------------------- drafts
  server.registerTool("create_meal_plan_draft", {
    title: "Draft a meal plan",
    description: "Proposes meals for a date range (max 31 days) as a draft the household reviews and accepts in " +
      "the Koda app. It never changes the planning by itself. Each entry has a date, a slot and a recipe (id or " +
      "name) or a free text.",
    inputSchema: {
      from: day,
      to: day,
      rationale: z.string().optional().describe("Why this plan: variety, nutrients, what was not eaten lately…"),
      entries: z.array(z.object({
        date: day,
        slot,
        recipe: recipeRef.optional(),
        free_text: z.string().min(1).optional(),
        servings: z.number().positive().optional(),
        note: z.string().optional(),
      })).min(1).max(124),
    },
    annotations: WRITE,
  }, ({ from, to, rationale, entries }) =>
    run(async () => {
      const resolved = [];
      for (const entry of entries) {
        if (!entry.recipe === !entry.free_text) {
          throw new ApiError("invalid_request", `Entry ${entry.date} ${entry.slot}: give either recipe or free_text.`);
        }
        resolved.push({
          date: await resolveDate(db, entry.date),
          slot: entry.slot,
          recipe_id: entry.recipe ? (await resolveRecipe(db, entry.recipe)).id : null,
          free_text: entry.free_text ?? null,
          servings: entry.servings ?? null,
          note: entry.note ?? null,
        });
      }
      return await callRpc(db, "mcp_create_meal_plan_draft", {
        p_from: await resolveDate(db, from),
        p_to: await resolveDate(db, to),
        p_entries: resolved,
        p_rationale: rationale ?? null,
      });
    }));

  server.registerTool("list_meal_plan_drafts", {
    title: "Pending meal plan drafts",
    description: "Drafts waiting for review, with their meals.",
    annotations: READ,
  }, () => run(() => callRpc(db, "mcp_list_drafts")));

  server.registerTool("accept_meal_plan_draft", {
    title: "Accept a meal plan draft",
    description: "Moves a draft's meals into the planning. Existing planned meals are kept. Only when the user " +
      "explicitly asks to accept it; otherwise they review it in the app.",
    inputSchema: { draft_id: uuid },
    annotations: WRITE,
  }, ({ draft_id }) => run(() => acceptDraft(db, draft_id)));

  server.registerTool("discard_meal_plan_draft", {
    title: "Discard a meal plan draft",
    description: "Discards a pending draft and its proposed meals.",
    inputSchema: { draft_id: uuid },
    annotations: DESTRUCTIVE,
  }, ({ draft_id }) => run(() => discardDraft(db, draft_id)));
}
