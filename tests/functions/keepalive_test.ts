import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  type ImageBucket,
  type KeepaliveStore,
  REMOVE_BATCH,
  runKeepalive,
} from "../../supabase/functions/keepalive/handler.ts";

function store(
  orphans: Partial<Record<ImageBucket, string[]>>,
  failing: ImageBucket[] = [],
): KeepaliveStore & { removed: [ImageBucket, number][] } {
  const removed: [ImageBucket, number][] = [];
  return {
    removed,
    purgeTombstones: () => Promise.resolve({ recipes: 2 }),
    orphanImages: (bucket, limit) => Promise.resolve((orphans[bucket] ?? []).slice(0, limit)),
    removeImages: (bucket, paths) => {
      if (failing.includes(bucket)) return Promise.reject(new Error("storage down"));
      removed.push([bucket, paths.length]);
      return Promise.resolve();
    },
  };
}

Deno.test("keepalive purges and removes orphan images in batches", async () => {
  const orphans = Array.from({ length: REMOVE_BATCH + 5 }, (_, i) => `h/r/${i}.jpg`);
  const fake = store({ "recipe-images": orphans });
  const result = await runKeepalive(fake);
  assertEquals(result, { recipes: 2, images_removed: REMOVE_BATCH + 5 });
  assertEquals(fake.removed, [["recipe-images", REMOVE_BATCH], ["recipe-images", 5]]);
});

Deno.test("keepalive cleans recipe and product images", async () => {
  const fake = store({ "recipe-images": ["h/r/a.jpg"], "product-images": ["h/p/a.jpg", "h/p/b.jpg"] });
  assertEquals(await runKeepalive(fake), { recipes: 2, images_removed: 3 });
  assertEquals(fake.removed, [["recipe-images", 1], ["product-images", 2]]);
});

Deno.test("keepalive with nothing to clean removes nothing", async () => {
  const fake = store({});
  assertEquals(await runKeepalive(fake), { recipes: 2, images_removed: 0 });
  assertEquals(fake.removed, []);
});

Deno.test("a failed image cleanup keeps the purge result and cleans the other bucket", async () => {
  const fake = store({ "recipe-images": ["h/r/a.jpg"], "product-images": ["h/p/a.jpg"] }, ["recipe-images"]);
  const result = await runKeepalive(fake);
  assertEquals(result, { recipes: 2, images_removed: 1, images_error: "cleanup_failed" });
  assertEquals(fake.removed, [["product-images", 1]]);
});
