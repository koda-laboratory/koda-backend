import { assertEquals } from "jsr:@std/assert@1.0.19";
import { type KeepaliveStore, REMOVE_BATCH, runKeepalive } from "../../supabase/functions/keepalive/handler.ts";

function store(orphans: string[], failRemove = false): KeepaliveStore & { removed: string[][] } {
  const removed: string[][] = [];
  return {
    removed,
    purgeTombstones: () => Promise.resolve({ recipes: 2 }),
    orphanRecipeImages: (limit) => Promise.resolve(orphans.slice(0, limit)),
    removeRecipeImages: (paths) => {
      if (failRemove) return Promise.reject(new Error("storage down"));
      removed.push(paths);
      return Promise.resolve();
    },
  };
}

Deno.test("keepalive purges and removes orphan images in batches", async () => {
  const orphans = Array.from({ length: REMOVE_BATCH + 5 }, (_, i) => `h/r/${i}.jpg`);
  const fake = store(orphans);
  const result = await runKeepalive(fake);
  assertEquals(result, { recipes: 2, images_removed: REMOVE_BATCH + 5 });
  assertEquals(fake.removed.map((batch) => batch.length), [REMOVE_BATCH, 5]);
});

Deno.test("keepalive with nothing to clean removes nothing", async () => {
  const fake = store([]);
  assertEquals(await runKeepalive(fake), { recipes: 2, images_removed: 0 });
  assertEquals(fake.removed, []);
});

Deno.test("a failed image cleanup keeps the purge result", async () => {
  const result = await runKeepalive(store(["h/r/a.jpg"], true));
  assertEquals(result, { recipes: 2, images_removed: 0, images_error: "cleanup_failed" });
});
