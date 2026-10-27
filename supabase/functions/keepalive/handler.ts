// Daily maintenance of the internal `keepalive` function: purge old tombstones and remove recipe and product images
// that no live row references any more. The image cleanup never fails the run: the purge keeps the project healthy.

/** Buckets with app-uploaded images and the RPC that lists their orphans. */
export const IMAGE_BUCKETS = {
  "recipe-images": "orphan_recipe_images",
  "product-images": "orphan_product_images",
} as const;
export type ImageBucket = keyof typeof IMAGE_BUCKETS;

export interface KeepaliveStore {
  purgeTombstones(): Promise<Record<string, unknown>>;
  /** Storage paths in `bucket` that no live row points to (`public.orphan_recipe_images` / `orphan_product_images`). */
  orphanImages(bucket: ImageBucket, limit: number): Promise<string[]>;
  removeImages(bucket: ImageBucket, paths: string[]): Promise<void>;
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
  let failed = false;
  for (const bucket of Object.keys(IMAGE_BUCKETS) as ImageBucket[]) {
    try {
      const orphans = await store.orphanImages(bucket, imageLimit);
      for (let start = 0; start < orphans.length; start += REMOVE_BATCH) {
        const batch = orphans.slice(start, start + REMOVE_BATCH);
        await store.removeImages(bucket, batch);
        removed += batch.length;
      }
    } catch (error) {
      // A failing bucket must not keep the other one from being cleaned.
      console.error(`keepalive: ${bucket} cleanup failed`, error);
      failed = true;
    }
  }
  return failed
    ? { ...purge, images_removed: removed, images_error: "cleanup_failed" }
    : { ...purge, images_removed: removed };
}
