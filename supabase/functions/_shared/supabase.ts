// Supabase client factories.
//
// User-facing functions (api, mcp) MUST use `createUserClient` so every query runs with the
// caller's JWT and RLS applies. `createAdminClient` bypasses RLS and is reserved for internal
// system functions (push, keepalive) that are protected by a shared secret.
import { createClient, type SupabaseClient } from "./deps.ts";
import { publishableKey, requireEnv, secretKey } from "./env.ts";

const NO_SESSION = { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false };

export function createUserClient(authorization: string): SupabaseClient {
  return createClient(requireEnv("SUPABASE_URL"), publishableKey(), {
    auth: NO_SESSION,
    global: { headers: { Authorization: authorization } },
  });
}

export function createAdminClient(): SupabaseClient {
  return createClient(requireEnv("SUPABASE_URL"), secretKey(), { auth: NO_SESSION });
}

/** Returns the user id for a valid access token, or null. Verified by Supabase Auth. */
export async function verifyAccessToken(jwt: string): Promise<{ id: string } | null> {
  const client = createClient(requireEnv("SUPABASE_URL"), publishableKey(), { auth: NO_SESSION });
  const { data, error } = await client.auth.getUser(jwt);
  if (error || !data.user) return null;
  return { id: data.user.id };
}
