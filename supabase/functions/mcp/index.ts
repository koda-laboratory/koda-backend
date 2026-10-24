// Entry point of the `mcp` Edge Function. Server, tools and auth live in app.ts.
import { createMcpApp } from "./app.ts";
import { optionalEnv, requireEnv } from "../_shared/env.ts";
import { createUserClient, verifyAccessToken } from "../_shared/supabase.ts";
import { ApiError } from "../_shared/errors.ts";
import { type ImageStore, RECIPE_IMAGES_BUCKET } from "./images.ts";

/** Supabase Storage with the caller's token: storage policies keep it inside their household folder. */
function storeFor(authorization: string): ImageStore {
  const bucket = createUserClient(authorization).storage.from(RECIPE_IMAGES_BUCKET);
  return {
    async upload(path, bytes, contentType) {
      const { error } = await bucket.upload(path, bytes, { contentType, upsert: false });
      if (error) throw new ApiError("internal", `The image could not be stored: ${error.message}`);
    },
    async signedUploadUrl(path) {
      const { data, error } = await bucket.createSignedUploadUrl(path);
      if (error || !data) throw new ApiError("internal", "An upload URL could not be created.");
      return data.signedUrl;
    },
  };
}

// Hosted, SUPABASE_URL is the public project URL. Locally it is the internal gateway, so MCP_PUBLIC_URL
// (e.g. http://127.0.0.1:54321) gives the address clients see.
const publicUrl = optionalEnv("MCP_PUBLIC_URL") ?? requireEnv("SUPABASE_URL");

const app = createMcpApp({
  verifyToken: verifyAccessToken,
  clientFor: createUserClient,
  storeFor,
  fetchImage: (url) => fetch(url, { redirect: "follow", signal: AbortSignal.timeout(20_000) }),
  resourceUrl: `${publicUrl}/functions/v1/mcp`,
  authorizationServer: `${publicUrl}/auth/v1`,
});

Deno.serve(app.fetch);
