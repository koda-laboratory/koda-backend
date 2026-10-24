// Daily maintenance of the internal `keepalive` function: purge old tombstones and remove recipe images that no
// live row references any more. The image cleanup never fails the run: the purge keeps the project healthy.

export interface KeepaliveStore {
  purgeTombstones(): Promise<Record<string, unknown>>;
  /** Storage paths in `recipe-images` that no live recipe or photo points to (`public.orphan_recipe_images`). */
  orphanRecipeImages(limit: number): Promise<string[]>;
  removeRecipeImages(paths: string[]): Promise<void>;
}

export interface KeepaliveResult extends Record<string, unknown> {
  images_removed: number;
  images_error?: string;
}

/** Storage removes at most this many objects per call. */
export const REMOVE_BATCH = 100;

export async function runKeepalive(store: KeepaliveStore, imageLimit = 500): Promise<KeepaliveResult> {
  const purge = await store.purgeTombstones();
  let removed = 0;
  try {
    const orphans = await store.orphanRecipeImages(imageLimit);
    for (let start = 0; start < orphans.length; start += REMOVE_BATCH) {
      const batch = orphans.slice(start, start + REMOVE_BATCH);
      await store.removeRecipeImages(batch);
      removed += batch.length;
    }
  } catch (error) {
    console.error("keepalive: recipe image cleanup failed", error);
    return { ...purge, images_removed: removed, images_error: "cleanup_failed" };
  }
  return { ...purge, images_removed: removed };
}
