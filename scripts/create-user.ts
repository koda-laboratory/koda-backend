#!/usr/bin/env -S deno run --allow-env --allow-net
// Creates a Koda user (sign-ups are disabled) and attaches it to a household.
//
// Usage:
//   SUPABASE_URL=... SUPABASE_SECRET_KEY=... deno run --allow-env --allow-net scripts/create-user.ts \
//     --email someone@example.com --name "Name" [--emoji 🦊] \
//     (--household-id <uuid> | --household-name "Casa") [--role owner|member]
//
// The password is read from KODA_USER_PASSWORD or asked interactively (it is never a flag, so it
// does not end up in the shell history). Re-running for an existing email only ensures the
// profile and membership exist.
import { parseArgs } from "jsr:@std/cli@1.0.32/parse-args";
import { createClient } from "../supabase/functions/_shared/deps.ts";

const args = parseArgs(Deno.args, {
  string: ["email", "name", "emoji", "household-id", "household-name", "role"],
  boolean: ["help"],
  default: { role: "member" },
});

function fail(message: string): never {
  console.error(message);
  Deno.exit(1);
}

if (args.help || !args.email || !args.name || (!args["household-id"] && !args["household-name"])) {
  console.log(
    'Usage: create-user.ts --email <email> --name <name> [--emoji 🦊] (--household-id <uuid> | --household-name "Casa") [--role owner|member]',
  );
  Deno.exit(args.help ? 0 : 1);
}
if (!["owner", "member"].includes(args.role!)) fail("--role must be owner or member");

const url = Deno.env.get("SUPABASE_URL") ?? fail("SUPABASE_URL is required");
const secretKey = Deno.env.get("SUPABASE_SECRET_KEY") ?? fail("SUPABASE_SECRET_KEY is required");
const admin = createClient(url, secretKey, { auth: { persistSession: false, autoRefreshToken: false } });
const email = args.email!.trim().toLowerCase();

async function findUserId(): Promise<string | null> {
  for (let page = 1; page < 50; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw error;
    const user = data.users.find((u) => u.email?.toLowerCase() === email);
    if (user) return user.id;
    if (data.users.length < 200) return null;
  }
  return null;
}

let userId = await findUserId();
if (userId) {
  console.log(`User ${email} already exists (${userId}); ensuring profile and membership.`);
} else {
  const password = Deno.env.get("KODA_USER_PASSWORD") ?? prompt(`Password for ${email}:`) ?? "";
  if (password.length < 8) fail("Password must have at least 8 characters");
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (error || !data.user) fail(`createUser failed: ${error?.message}`);
  userId = data.user.id;
  console.log(`Created user ${email} (${userId}).`);
}

const { error: profileError } = await admin.from("profiles").upsert({
  id: userId,
  display_name: args.name,
  ...(args.emoji ? { avatar_emoji: args.emoji } : {}),
});
if (profileError) fail(`profile: ${profileError.message}`);

let householdId = args["household-id"];
if (!householdId) {
  const { data, error } = await admin.from("households").insert({ name: args["household-name"] }).select("id").single();
  if (error) fail(`household: ${error.message}`);
  householdId = data.id as string;
  console.log(`Created household "${args["household-name"]}" (${householdId}).`);
}

const { error: memberError } = await admin.from("household_members").upsert({
  household_id: householdId,
  user_id: userId,
  role: args.role,
});
if (memberError) fail(`membership: ${memberError.message}`);
console.log(`${email} is ${args.role} of household ${householdId}.`);
