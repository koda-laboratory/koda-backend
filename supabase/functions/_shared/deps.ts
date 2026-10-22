// Single place for third-party imports and their pinned versions.
// Edge Functions and tests import from here so upgrades are one-line changes.
export { Hono } from "npm:hono@4.13.13";
export type { Context, MiddlewareHandler } from "npm:hono@4.13.13";
export { HTTPException } from "npm:hono@4.13.13/http-exception";
export { z } from "npm:zod@4.6.7";
export { createClient } from "npm:@supabase/supabase-js@2.118.0";
export type { SupabaseClient } from "npm:@supabase/supabase-js@2.118.0";
export { importPKCS8, SignJWT } from "npm:jose@6.2.13";
