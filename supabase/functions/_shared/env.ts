// Environment helpers. Supabase injects SUPABASE_URL and the API keys into every function;
// the rest come from `supabase secrets set` (hosted) or supabase/functions/.env (local).

export function optionalEnv(name: string): string | undefined {
  const value = Deno.env.get(name);
  return value && value.length > 0 ? value : undefined;
}

export function requireEnv(name: string): string {
  const value = optionalEnv(name);
  if (!value) throw new Error(`Missing environment variable ${name}`);
  return value;
}

/** First defined variable among `names`. */
export function firstEnv(...names: string[]): string | undefined {
  for (const name of names) {
    const value = optionalEnv(name);
    if (value) return value;
  }
  return undefined;
}

/** Publishable (client) key: new `sb_publishable_…` key, falling back to the legacy anon key. */
export function publishableKey(): string {
  const key = firstEnv("SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY");
  if (!key) throw new Error("Missing SUPABASE_PUBLISHABLE_KEY / SUPABASE_ANON_KEY");
  return key;
}

/** Secret key: only for internal system functions (push, keepalive). */
export function secretKey(): string {
  const key = firstEnv("SUPABASE_SECRET_KEY", "SUPABASE_SERVICE_ROLE_KEY");
  if (!key) throw new Error("Missing SUPABASE_SECRET_KEY / SUPABASE_SERVICE_ROLE_KEY");
  return key;
}
