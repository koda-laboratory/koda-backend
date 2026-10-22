import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1.0.19";
import { buildImportPlan, type NotionData, slotFor, summarize, todayIn } from "../../scripts/lib/notion_import.ts";

const HOUSEHOLD = "11111111-1111-4111-8111-111111111111";

// Tiny synthetic fixture (not real data).
const fixture: NotionData = {
  stores: [{ name: "Tienda A" }, { name: "Tienda B" }],
  products: [
    {
      notion_id: "p1",
      name: "Leche",
      category: "Comida básicos",
      stores: ["Tienda A", "Tienda B"],
      price_per_kg: null,
      price_total: 1.2,
      servings: null,
      servings_per_week: null,
      add_to_list: true,
      bought: false,
    },
    {
      notion_id: "p2",
      name: "Lejía",
      category: "Limpieza",
      stores: [],
      price_per_kg: null,
      price_total: null,
      servings: null,
      servings_per_week: null,
      add_to_list: true,
      bought: true,
    },
    {
      notion_id: "p3",
      name: "",
      category: "Comida",
      stores: [],
      price_per_kg: null,
      price_total: null,
      servings: null,
      servings_per_week: null,
      add_to_list: false,
      bought: false,
    },
    {
      notion_id: "p4",
      name: "Masa",
      category: null,
      stores: ["Tienda C"],
      price_per_kg: null,
      price_total: null,
      servings: null,
      servings_per_week: null,
      add_to_list: false,
      bought: false,
    },
    {
      notion_id: "p5",
      name: "Masa",
      category: "Baño",
      stores: [],
      price_per_kg: null,
      price_total: null,
      servings: null,
      servings_per_week: null,
      add_to_list: false,
      bought: false,
    },
  ],
  recipes: [
    {
      notion_id: "r1",
      name: "Tortilla",
      meal_types: ["Desayuno", "Cena"],
      nutrients: ["Proteina", "Grasas"],
      time_minutes: 20,
      ingredient_product_notion_ids: ["p1", "p3", "p1"],
      last_eaten_on: "2026-10-20",
      steps: ["Batir", " "],
      notes: "Sin cebolla",
      emoji: "🍳",
    },
    {
      notion_id: "r2",
      name: "Tostada",
      meal_types: ["Merienda"],
      nutrients: [],
      time_minutes: null,
      ingredient_product_notion_ids: [],
      last_eaten_on: "2026-10-22",
      steps: [],
      notes: null,
      emoji: null,
    },
    {
      notion_id: "r3",
      name: "Sopa",
      meal_types: [],
      nutrients: ["Unknown"],
      time_minutes: null,
      ingredient_product_notion_ids: ["p4"],
      last_eaten_on: null,
      steps: [],
      notes: null,
    },
  ],
};

Deno.test("maps Notion values and tolerates dirty data", async () => {
  const plan = await buildImportPlan(fixture, HOUSEHOLD, "2026-10-22");
  assertEquals(summarize(plan), {
    stores: 3,
    products: 4,
    product_stores: 3,
    recipes: 3,
    recipe_ingredients: 2,
    meal_plan_entries: 2,
    consumptions: 1,
    shopping_entries: 1,
  });
  const byName = (name: string) => plan.rows.products.filter((p) => p.name === name);
  assertEquals(byName("Leche")[0].category, "basics");
  assertEquals(byName("Lejía")[0].category, "cleaning");
  assertEquals(byName("Masa").map((p) => p.category), ["food", "bathroom"]);
  assertNotEquals(byName("Masa")[0].id, byName("Masa")[1].id);
  assert(plan.warnings.some((w) => w.includes("empty name")));
  assert(plan.warnings.some((w) => w.includes("no category")));
  assert(plan.warnings.some((w) => w.includes('unknown value "Unknown"')));

  const tortilla = plan.rows.recipes.find((r) => r.name === "Tortilla")!;
  assertEquals(tortilla.meal_types, ["breakfast", "dinner"]);
  assertEquals(tortilla.nutrients, ["protein", "fats"]);
  assertEquals(tortilla.steps, ["Batir"]);
  assertEquals(tortilla.notes, "Sin cebolla");
});

Deno.test("planned dates become entries; only past ones become consumptions", async () => {
  const plan = await buildImportPlan(fixture, HOUSEHOLD, "2026-10-22");
  assertEquals(plan.rows.meal_plan_entries.map((e) => [e.date, e.slot]), [["2026-10-20", "dinner"], [
    "2026-10-22",
    "snack",
  ]]);
  assertEquals(plan.rows.consumptions.map((c) => c.eaten_on), ["2026-10-20"]);
  assertEquals(plan.rows.consumptions[0].meal_plan_entry_id, plan.rows.meal_plan_entries[0].id);
});

Deno.test("only products to buy become shopping entries", async () => {
  const plan = await buildImportPlan(fixture, HOUSEHOLD, "2026-10-22");
  assertEquals(plan.rows.shopping_entries.length, 1);
  assertEquals(plan.rows.shopping_entries[0].kind, "product");
  assertEquals(plan.rows.shopping_entries[0].checked, false);
});

Deno.test("ids are deterministic per household", async () => {
  const a = await buildImportPlan(fixture, HOUSEHOLD, "2026-10-22");
  const b = await buildImportPlan(fixture, HOUSEHOLD, "2026-10-22");
  const other = await buildImportPlan(fixture, "22222222-2222-4222-8222-222222222222", "2026-10-22");
  assertEquals(a.rows.products.map((p) => p.id), b.rows.products.map((p) => p.id));
  assertNotEquals(a.rows.products[0].id, other.rows.products[0].id);
});

Deno.test("slot rule and Madrid date", () => {
  assertEquals(slotFor(["breakfast", "dinner"]), "dinner");
  assertEquals(slotFor(["snack"]), "snack");
  assertEquals(slotFor([]), "lunch");
  assertEquals(todayIn("Europe/Madrid", new Date("2026-10-21T22:30:00Z")), "2026-10-22");
});
