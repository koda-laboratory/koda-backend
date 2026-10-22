// Request validation (zod). Schemas mirror the contract in .agents/skills/sync-contract/SKILL.md.
import { z } from "./deps.ts";
import { ApiError } from "./errors.ts";
import { SYNCED_TABLES } from "./domain/sync.ts";

const uuid = z.guid();
const isoDate = z.iso.date();
const isoDateTime = z.iso.datetime({ offset: true });

export const mutationSchema = z
  .object({
    table: z.enum(SYNCED_TABLES),
    id: uuid,
    op: z.enum(["upsert", "delete"]),
    fields: z.record(z.string(), z.unknown()).optional(),
    client_ts: isoDateTime,
  })
  .refine((m) => m.op === "delete" || m.fields !== undefined, {
    message: "fields is required for upsert",
    path: ["fields"],
  });

export const MAX_MUTATIONS_PER_PUSH = 500;

export const syncPushSchema = z.object({
  device_id: uuid.nullable().optional(),
  mutations: z.array(mutationSchema).max(MAX_MUTATIONS_PER_PUSH),
});
export type SyncPushBody = z.infer<typeof syncPushSchema>;

export const DEFAULT_PULL_LIMIT = 500;
export const MAX_PULL_LIMIT = 1000;

export const syncPullQuerySchema = z.object({
  cursor: z.coerce.number().int().min(0).default(0),
  limit: z.coerce.number().int().min(1).max(MAX_PULL_LIMIT).default(DEFAULT_PULL_LIMIT),
});
export type SyncPullQuery = z.infer<typeof syncPullQuerySchema>;

export const deviceSchema = z.object({
  id: uuid,
  apns_token: z.string().regex(/^[0-9a-fA-F]{32,200}$/, "apns_token must be hex"),
  platform: z.enum(["ios", "macos"]),
  apns_env: z.enum(["sandbox", "production"]),
  app_version: z.string().max(64).nullable().optional(),
});
export type DeviceBody = z.infer<typeof deviceSchema>;

export const MAX_PLAN_RANGE_DAYS = 62;

export const fromPlanSchema = z
  .object({ from: isoDate, to: isoDate })
  .refine((v) => v.to >= v.from, { message: "to must be on or after from", path: ["to"] })
  .refine(
    (v) => (Date.parse(v.to) - Date.parse(v.from)) / 86_400_000 <= MAX_PLAN_RANGE_DAYS,
    { message: `range must be at most ${MAX_PLAN_RANGE_DAYS} days`, path: ["to"] },
  );

export const expandSchema = z.object({
  servings: z.number().positive().max(100).nullable().optional(),
});

export const MEAL_SLOTS = ["breakfast", "lunch", "snack", "dinner"] as const;
const hhmm = z.string().regex(/^([01][0-9]|2[0-3]):[0-5][0-9]$/, "must be HH:MM (24 h)");

/** PATCH /households/:id/settings. slot_times may contain a subset of the four slots (merged). */
export const householdSettingsSchema = z
  .object({
    slot_times: z
      .object({ breakfast: hhmm, lunch: hhmm, snack: hhmm, dinner: hhmm })
      .partial()
      .strict()
      .optional(),
    shopping_weekday: z.number().int().min(1).max(7).optional(),
  })
  .strict()
  .refine((v) => v.slot_times !== undefined || v.shopping_weekday !== undefined, {
    message: "slot_times or shopping_weekday is required",
  });
export type HouseholdSettingsBody = z.infer<typeof householdSettingsSchema>;

export const idParamSchema = uuid;

/** Parses `input` or throws a 400 ApiError with the zod issues. */
export function parseOrThrow<T>(schema: z.ZodType<T>, input: unknown): T {
  const result = schema.safeParse(input);
  if (!result.success) {
    throw new ApiError(
      "invalid_request",
      "Invalid request",
      result.error.issues.map((issue) => ({ path: issue.path.join("."), message: issue.message })),
    );
  }
  return result.data;
}
