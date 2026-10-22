// Shared-secret check for internal functions (push, keepalive), called by pg_cron/pg_net or CI.

export const INTERNAL_SECRET_HEADER = "x-koda-secret";

/** Constant-time string comparison. */
export function timingSafeEqual(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  let diff = left.length ^ right.length;
  const length = Math.max(left.length, right.length);
  for (let i = 0; i < length; i++) {
    diff |= (left[i] ?? 0) ^ (right[i] ?? 0);
  }
  return diff === 0;
}

/** True when the request carries the expected secret. A missing expected secret always fails. */
export function hasInternalSecret(request: Request, expected: string | undefined): boolean {
  if (!expected) return false;
  const provided = request.headers.get(INTERNAL_SECRET_HEADER) ?? "";
  return timingSafeEqual(provided, expected);
}
