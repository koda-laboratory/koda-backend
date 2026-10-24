// Recipe image tools (PLAN.md 8.4). Koda never generates images: the agent makes one with whatever image tool it
// has and hands it over in one of two ways:
//   * by URL (`set_recipe_cover` / `add_recipe_photo`): the server downloads it, checks it and stores it;
//   * by upload (`create_recipe_image_upload` → PUT the file → `finish_recipe_image_upload`): for agents with a
//     shell or file access, so the image never travels inside a tool call.
// Objects live in the private bucket `recipe-images` under `<household>/<recipe>/<uuid>.<ext>`; storage policies
// and the `mcp_*` SQL functions keep everything inside the caller's household.
import { type McpServer, z } from "../_shared/deps.ts";
import { callRpc, type RpcClient } from "../_shared/db.ts";
import { ApiError } from "../_shared/errors.ts";
import { resolveRecipe } from "./resolve.ts";

export const RECIPE_IMAGES_BUCKET = "recipe-images";
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

/** Storage port bound to the caller's token. */
export interface ImageStore {
  upload(path: string, bytes: Uint8Array, contentType: string): Promise<void>;
  /** A one-time URL the agent can PUT the file to. */
  signedUploadUrl(path: string): Promise<string>;
}

export type ImageFetcher = (url: string) => Promise<Response>;

type ImageType = { mime: string; ext: string };

const TYPES: Record<string, ImageType> = {
  jpeg: { mime: "image/jpeg", ext: "jpg" },
  png: { mime: "image/png", ext: "png" },
  webp: { mime: "image/webp", ext: "webp" },
};

/** Detects JPEG, PNG or WebP from the file's first bytes (headers are not trusted). */
export function sniffImage(bytes: Uint8Array): ImageType | null {
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return TYPES.jpeg;
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    return TYPES.png;
  }
  if (
    bytes.length >= 12 && String.fromCharCode(...bytes.slice(0, 4)) === "RIFF" &&
    String.fromCharCode(...bytes.slice(8, 12)) === "WEBP"
  ) return TYPES.webp;
  return null;
}

/** Downloads an image over HTTPS, capped at 5 MB, and checks it really is JPEG, PNG or WebP. */
export async function downloadImage(
  fetcher: ImageFetcher,
  url: string,
): Promise<{ bytes: Uint8Array; type: ImageType }> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new ApiError("invalid_request", "image_url is not a valid URL.");
  }
  if (parsed.protocol !== "https:") throw new ApiError("invalid_request", "image_url must use https.");

  let response: Response;
  try {
    response = await fetcher(parsed.toString());
  } catch {
    throw new ApiError("invalid_request", "The image could not be downloaded from that URL.");
  }
  if (!response.ok || !response.body) {
    throw new ApiError("invalid_request", `The image URL answered ${response.status}; it may be private or expired.`);
  }
  const declared = Number(response.headers.get("content-length") ?? "0");
  if (declared > MAX_IMAGE_BYTES) throw new ApiError("invalid_request", "The image is larger than 5 MB.");

  const chunks: Uint8Array[] = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > MAX_IMAGE_BYTES) throw new ApiError("invalid_request", "The image is larger than 5 MB.");
    chunks.push(chunk);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  const type = sniffImage(bytes);
  if (!type) throw new ApiError("invalid_request", "That URL is not a JPEG, PNG or WebP image.");
  return { bytes, type };
}

async function newImagePath(db: RpcClient, recipeId: string, ext: string): Promise<string> {
  const household = await callRpc<string>(db, "mcp_household_id");
  return `${household}/${recipeId}/${crypto.randomUUID()}.${ext}`;
}

type ToolResult = { content: Array<{ type: "text"; text: string }>; isError?: boolean };
type Run = (handler: () => Promise<unknown>) => Promise<ToolResult>;

const purpose = z.enum(["cover", "photo"]).describe("cover = the recipe's header image; photo = add to its gallery.");

export function registerImageTools(
  server: McpServer,
  db: RpcClient,
  store: ImageStore,
  fetcher: ImageFetcher,
  run: Run,
): void {
  const READ = { readOnlyHint: true, destructiveHint: false, openWorldHint: false } as const;
  const WRITE = { readOnlyHint: false, destructiveHint: false, openWorldHint: true } as const;

  async function attach(recipeId: string, path: string, kind: "cover" | "photo", overwrite: boolean) {
    return kind === "cover"
      ? await callRpc(db, "mcp_set_recipe_cover", { p_recipe_id: recipeId, p_path: path, p_overwrite: overwrite })
      : await callRpc(db, "mcp_add_recipe_photo", { p_recipe_id: recipeId, p_path: path });
  }

  async function fromUrl(recipe: string, url: string, kind: "cover" | "photo", overwrite: boolean) {
    const { id } = await resolveRecipe(db, recipe);
    const { bytes, type } = await downloadImage(fetcher, url);
    const path = await newImagePath(db, id, type.ext);
    await store.upload(path, bytes, type.mime);
    return await attach(id, path, kind, overwrite);
  }

  server.registerTool("list_recipes_missing_cover", {
    title: "Recipes without a cover",
    description: "Recipes that have no cover image yet, with their ingredients, steps and notes so you can " +
      "picture the dish. Use it to illustrate recipes one by one.",
    inputSchema: { limit: z.number().int().positive().max(200).optional() },
    annotations: READ,
  }, ({ limit }) => run(() => callRpc(db, "mcp_recipes_missing_cover", { p_limit: limit ?? 20 })));

  server.registerTool("set_recipe_cover", {
    title: "Set a recipe cover from a URL",
    description: "Downloads a JPEG, PNG or WebP image (max 5 MB) from an https URL and makes it the recipe's " +
      "cover. Koda does not generate images: create one with your own image tool first. A recipe that already " +
      "has a cover (for example a photo the household took) keeps it unless overwrite is true. If you can't " +
      "provide a public URL but can run commands or read files, use create_recipe_image_upload instead.",
    inputSchema: {
      recipe: z.string().min(1).describe("Recipe id or name."),
      image_url: z.string().describe("https URL of the image."),
      overwrite: z.boolean().optional().describe("Replace an existing cover. Only if the user asks."),
    },
    annotations: WRITE,
  }, ({ recipe, image_url, overwrite }) => run(() => fromUrl(recipe, image_url, "cover", overwrite ?? false)));

  server.registerTool("add_recipe_photo", {
    title: "Add a photo to a recipe from a URL",
    description: "Downloads a JPEG, PNG or WebP image (max 5 MB) from an https URL and adds it to the recipe's " +
      "photo gallery.",
    inputSchema: { recipe: z.string().min(1).describe("Recipe id or name."), image_url: z.string() },
    annotations: WRITE,
  }, ({ recipe, image_url }) => run(() => fromUrl(recipe, image_url, "photo", false)));

  server.registerTool("create_recipe_image_upload", {
    title: "Start a recipe image upload",
    description: "Returns a one-time upload URL for a recipe image, for agents that have the image as a file. " +
      'Upload with an HTTP PUT of the raw file and the given Content-Type (e.g. curl -X PUT -H "Content-Type: ' +
      'image/png" --data-binary @dish.png "<upload_url>"), then call finish_recipe_image_upload with the ' +
      "returned image_path. JPEG, PNG or WebP, max 5 MB.",
    inputSchema: {
      recipe: z.string().min(1).describe("Recipe id or name."),
      format: z.enum(["jpeg", "png", "webp"]),
    },
    annotations: WRITE,
  }, ({ recipe, format }) =>
    run(async () => {
      const { id, name } = await resolveRecipe(db, recipe);
      const type = TYPES[format];
      const path = await newImagePath(db, id, type.ext);
      const uploadUrl = await store.signedUploadUrl(path);
      return {
        recipe_id: id,
        recipe: name,
        image_path: path,
        upload_url: uploadUrl,
        method: "PUT",
        content_type: type.mime,
        next_step: "PUT the file to upload_url, then call finish_recipe_image_upload with image_path.",
      };
    }));

  server.registerTool("finish_recipe_image_upload", {
    title: "Finish a recipe image upload",
    description: "After uploading with create_recipe_image_upload, attaches the image to the recipe as its cover " +
      "or as a gallery photo. A recipe that already has a cover keeps it unless overwrite is true.",
    inputSchema: {
      recipe: z.string().min(1).describe("The same recipe id or name."),
      image_path: z.string().min(1),
      purpose,
      overwrite: z.boolean().optional(),
    },
    annotations: WRITE,
  }, ({ recipe, image_path, purpose, overwrite }) =>
    run(async () => {
      const { id } = await resolveRecipe(db, recipe);
      return await attach(id, image_path, purpose, overwrite ?? false);
    }));
}
