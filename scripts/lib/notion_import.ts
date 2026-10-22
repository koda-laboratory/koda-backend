// Pure transformation of the Notion "Comidita" extraction into Koda rows.
// No I/O here: scripts/import-notion.ts reads the file and writes to Supabase.
import { generate as uuidV5 } from "jsr:@std/uuid@1.1.2/v5";

/** Fixed namespace for deterministic ids. Never change it: ids must stay stable across runs. */
export const KODA_NOTION_NAMESPACE = "5b0f3c7e-2a64-4d8e-9a51-6c3e8f1d2b47";

export interface NotionData {
  extracted_at?: string;
  stores: Array<{ name: string }>;
  products: NotionProduct[];
  recipes: NotionRecipe[];
}

export interface NotionProduct {
  notion_id: string;
  name: string | null;
  category: string | null;
  stores: string[] | null;
  price_per_kg: number | null;
  price_total: number | null;
  servings: number | null;
  servings_per_week: number | null;
  add_to_list?: boolean;
  bought?: boolean;
}

export interface NotionRecipe {
  notion_id: string;
  name: string | null;
  meal_types: string[] | null;
  nutrients: string[] | null;
  time_minutes: number | null;
  ingredient_product_notion_ids: string[] | null;
  last_eaten_on: string | null;
  steps: string[] | null;
  notes: string | null;
  emoji?: string | null;
}

export type Row = Record<string, unknown> & { id: string };

/** Tables in insertion order (parents first). */
export const IMPORT_TABLES = [
  "stores",
  "products",
  "product_stores",
  "recipes",
  "recipe_ingredients",
  "meal_plan_entries",
  "consumptions",
  "shopping_entries",
] as const;
export type ImportTable = (typeof IMPORT_TABLES)[number];

export interface ImportPlan {
  rows: Record<ImportTable, Row[]>;
  warnings: string[];
}

/** Lower-case, accent-free key used to map Notion select values. */
export function normalizeKey(value: string): string {
  return value.normalize("NFD").replace(/\p{Diacritic}/gu, "").trim().toLowerCase();
}

const CATEGORY: Record<string, string> = {
  "comida basicos": "basics",
  "comida": "food",
  "limpieza": "cleaning",
  "cocina": "kitchen",
  "bano": "bathroom",
  "aseo": "toiletries",
};
const MEAL_TYPE: Record<string, string> = {
  "desayuno": "breakfast",
  "comida": "lunch",
  "merienda": "snack",
  "cena": "dinner",
};
const NUTRIENT: Record<string, string> = {
  "grasas": "fats",
  "fibra": "fiber",
  "vegetales": "vegetables",
  "proteina": "protein",
  "carbohidratos": "carbs",
};

function mapValue(table: Record<string, string>, value: string): string | undefined {
  const key = normalizeKey(value);
  if (table[key]) return table[key];
  // Already-English values are accepted as is.
  return Object.values(table).includes(key) ? key : undefined;
}

function mapList(table: Record<string, string>, values: string[] | null, label: string, warnings: string[]): string[] {
  const out: string[] = [];
  for (const value of values ?? []) {
    const mapped = mapValue(table, value);
    if (!mapped) warnings.push(`${label}: unknown value "${value}" ignored`);
    else if (!out.includes(mapped)) out.push(mapped);
  }
  return out;
}

/** First meal type that is lunch or dinner, else the first one, else lunch. */
export function slotFor(mealTypes: string[]): string {
  return mealTypes.find((m) => m === "lunch" || m === "dinner") ?? mealTypes[0] ?? "lunch";
}

/** Today's date (YYYY-MM-DD) in the given IANA time zone. */
export function todayIn(timeZone: string, now: Date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
}

function cleanNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : null;
}

function cleanText(value: string | null | undefined): string | null {
  const text = (value ?? "").trim();
  return text.length > 0 ? text : null;
}

/**
 * Builds every row to import into `householdId`. Ids are UUID v5 derived from the household and
 * the Notion id (or the store name), so re-running the import targets the same rows.
 * `today` (YYYY-MM-DD, Europe/Madrid) decides which planned dates also become consumptions.
 */
export async function buildImportPlan(data: NotionData, householdId: string, today: string): Promise<ImportPlan> {
  const encoder = new TextEncoder();
  const id = (kind: string, key: string) =>
    uuidV5(KODA_NOTION_NAMESPACE, encoder.encode(`${householdId}:${kind}:${key}`));
  const warnings: string[] = [];
  const rows: ImportPlan["rows"] = {
    stores: [],
    products: [],
    product_stores: [],
    recipes: [],
    recipe_ingredients: [],
    meal_plan_entries: [],
    consumptions: [],
    shopping_entries: [],
  };

  // Stores: declared ones plus any referenced by a product.
  const storeIds = new Map<string, string>();
  const storeNames = [...data.stores.map((s) => s.name), ...data.products.flatMap((p) => p.stores ?? [])];
  for (const raw of storeNames) {
    const name = cleanText(raw);
    if (!name) continue;
    const key = normalizeKey(name);
    if (storeIds.has(key)) continue;
    const storeId = await id("store", key);
    storeIds.set(key, storeId);
    rows.stores.push({ id: storeId, household_id: householdId, name });
  }

  // Products.
  const productIds = new Map<string, string>();
  let shoppingPosition = 0;
  for (const product of data.products) {
    const name = cleanText(product.name);
    if (!name) {
      warnings.push(`product ${product.notion_id}: empty name, skipped`);
      continue;
    }
    let category = product.category ? mapValue(CATEGORY, product.category) : undefined;
    if (!category) {
      warnings.push(
        `product "${name}": ${product.category ? `unknown category "${product.category}"` : "no category"}, using food`,
      );
      category = "food";
    }
    const productId = await id("product", product.notion_id);
    productIds.set(product.notion_id, productId);
    rows.products.push({
      id: productId,
      household_id: householdId,
      name,
      category,
      price_per_kg: cleanNumber(product.price_per_kg),
      price_total: cleanNumber(product.price_total),
      servings: cleanNumber(product.servings),
      servings_per_week: cleanNumber(product.servings_per_week),
    });

    const linked = new Set<string>();
    for (const storeName of product.stores ?? []) {
      const storeId = storeIds.get(normalizeKey(storeName));
      if (!storeId || linked.has(storeId)) continue;
      linked.add(storeId);
      rows.product_stores.push({
        id: await id("product_store", `${product.notion_id}:${normalizeKey(storeName)}`),
        household_id: householdId,
        product_id: productId,
        store_id: storeId,
      });
    }

    if (product.add_to_list === true && product.bought !== true) {
      rows.shopping_entries.push({
        id: await id("shopping", product.notion_id),
        household_id: householdId,
        kind: "product",
        product_id: productId,
        source: "manual",
        checked: false,
        position: shoppingPosition++,
      });
    }
  }

  // Recipes, ingredients and planning/history.
  for (const recipe of data.recipes) {
    const name = cleanText(recipe.name);
    if (!name) {
      warnings.push(`recipe ${recipe.notion_id}: empty name, skipped`);
      continue;
    }
    const recipeId = await id("recipe", recipe.notion_id);
    const mealTypes = mapList(MEAL_TYPE, recipe.meal_types, `recipe "${name}" meal type`, warnings);
    const nutrients = mapList(NUTRIENT, recipe.nutrients, `recipe "${name}" nutrient`, warnings);
    rows.recipes.push({
      id: recipeId,
      household_id: householdId,
      name,
      meal_types: mealTypes,
      nutrients,
      time_minutes: typeof recipe.time_minutes === "number" && recipe.time_minutes >= 0
        ? Math.round(recipe.time_minutes)
        : null,
      steps: (recipe.steps ?? []).map((s) => s.trim()).filter((s) => s.length > 0),
      notes: cleanText(recipe.notes),
      emoji: cleanText(recipe.emoji ?? null),
    });

    const seen = new Set<string>();
    let position = 0;
    for (const productNotionId of recipe.ingredient_product_notion_ids ?? []) {
      const productId = productIds.get(productNotionId);
      if (!productId) {
        warnings.push(`recipe "${name}": ingredient ${productNotionId} not imported, skipped`);
        continue;
      }
      if (seen.has(productId)) continue;
      seen.add(productId);
      rows.recipe_ingredients.push({
        id: await id("recipe_ingredient", `${recipe.notion_id}:${productNotionId}`),
        household_id: householdId,
        recipe_id: recipeId,
        product_id: productId,
        position: position++,
      });
    }

    const date = cleanText(recipe.last_eaten_on);
    if (date) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
        warnings.push(`recipe "${name}": invalid last_eaten_on "${date}", skipped`);
        continue;
      }
      const slot = slotFor(mealTypes);
      const entryId = await id("meal_plan_entry", `${recipe.notion_id}:${date}`);
      rows.meal_plan_entries.push({
        id: entryId,
        household_id: householdId,
        date,
        slot,
        recipe_id: recipeId,
        position: 0,
      });
      if (date < today) {
        rows.consumptions.push({
          id: await id("consumption", `${recipe.notion_id}:${date}`),
          household_id: householdId,
          recipe_id: recipeId,
          eaten_on: date,
          slot,
          meal_plan_entry_id: entryId,
        });
      }
    }
  }

  return { rows, warnings };
}

export function summarize(plan: ImportPlan): Record<ImportTable, number> {
  return Object.fromEntries(IMPORT_TABLES.map((t) => [t, plan.rows[t].length])) as Record<ImportTable, number>;
}
