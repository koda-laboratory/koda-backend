// MCP prompts: reusable instructions an agent can pull in.
import { type McpServer, z } from "../_shared/deps.ts";

export function registerPrompts(server: McpServer): void {
  server.registerPrompt("plan_week", {
    title: "Plan the week",
    description: "Drafts a varied meal plan for a week for the household to review in the Koda app.",
    argsSchema: {
      week_start: z.string().optional().describe("First day (YYYY-MM-DD). Defaults to next Monday."),
      notes: z.string().optional().describe("Anything to keep in mind: guests, a busy day, a craving…"),
    },
  }, ({ week_start, notes }) => ({
    messages: [{
      role: "user",
      content: {
        type: "text",
        text: [
          "Draft the household's meal plan for one week in Koda.",
          `Week: ${week_start ? `starting ${week_start}` : "the next Monday to Sunday (use get_household for today)"}.`,
          notes ? `Keep in mind: ${notes}` : "",
          "",
          "1. Call get_household for today's date, the meal times and the members.",
          "2. Call get_meals for that week and keep what is already planned; fill only the empty lunch and dinner slots.",
          "3. Call get_recipe_stats (and search_recipes with meal_type) to choose recipes. Avoid recipes eaten in the " +
          "last 14 days, prefer ones not eaten for a long time, balance nutrients (vegetables, protein, carbs) " +
          "across the week, and keep quick recipes for busy days.",
          "4. Call create_meal_plan_draft once with all the proposed meals and a short rationale.",
          "5. Summarise the draft for the user in their language and tell them to review it in the Koda app. Do not " +
          "accept it unless they explicitly ask.",
        ].filter((line) => line !== "").join("\n"),
      },
    }],
  }));
}
