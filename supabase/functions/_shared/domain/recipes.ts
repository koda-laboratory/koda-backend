// Recipe expansion (tree + flattened ingredients). The app computes the same thing locally;
// the API version validates it against the server data.
import { callRpc, type RpcClient } from "../db.ts";
import { ApiError } from "../errors.ts";

export interface RecipeTreeNode {
  recipe_id: string;
  parent_recipe_id: string | null;
  name: string;
  depth: number;
  servings_factor: number;
  path: string[];
}

export interface FlatIngredient {
  product_id: string;
  product_name: string;
  unit: string | null;
  quantity: number | null;
  recipe_ids: string[];
}

export interface RecipeExpansion {
  recipe_id: string;
  servings: number | null;
  tree: RecipeTreeNode[];
  ingredients: FlatIngredient[];
}

export async function expandRecipe(db: RpcClient, recipeId: string, servings: number | null): Promise<RecipeExpansion> {
  const tree = await callRpc<RecipeTreeNode[]>(db, "recipe_tree", { p_recipe_id: recipeId });
  if (!tree || tree.length === 0) throw new ApiError("not_found", "Recipe not found");
  const ingredients = await callRpc<FlatIngredient[]>(db, "recipe_flat_ingredients", {
    p_recipe_id: recipeId,
    p_servings: servings,
  });
  return { recipe_id: recipeId, servings, tree, ingredients: ingredients ?? [] };
}

/** Human label of a recipe tree: "Pollo al horno + Patatas al airfryer". */
export function treeLabel(tree: Pick<RecipeTreeNode, "name">[]): string {
  return tree.map((node) => node.name).join(" + ");
}
