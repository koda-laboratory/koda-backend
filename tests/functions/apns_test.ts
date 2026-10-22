import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { ApnsClient, SILENT_PUSH_OPTIONS } from "../../supabase/functions/_shared/apns.ts";
import { hasInternalSecret, timingSafeEqual } from "../../supabase/functions/_shared/internal.ts";

async function generatePem(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const base64 = btoa(String.fromCharCode(...pkcs8)).replace(/(.{64})/g, "$1\n");
  // Stored in secrets with literal "\n" sequences, as `supabase secrets set` often does.
  return `-----BEGIN PRIVATE KEY-----\\n${base64.replace(/\n/g, "\\n")}\\n-----END PRIVATE KEY-----`;
}

function decodeSegment(segment: string): Record<string, unknown> {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(segment.length / 4) * 4, "=");
  return JSON.parse(atob(padded));
}

Deno.test("APNs client signs an ES256 provider token and sends a background push", async () => {
  const requests: Array<{ url: string; headers: Headers; body: string }> = [];
  const fakeFetch = ((input: string | URL | Request, init?: RequestInit) => {
    requests.push({ url: String(input), headers: new Headers(init?.headers), body: String(init?.body) });
    const status = requests.length === 2 ? 410 : 200;
    const body = status === 410 ? JSON.stringify({ reason: "Unregistered" }) : null;
    return Promise.resolve(new Response(body, { status, headers: { "apns-id": "abc" } }));
  }) as typeof fetch;
  const now = 1_790_000_000_000;
  const client = new ApnsClient(
    { keyId: "38H2AWSNST", teamId: "MUDCX7X324", privateKey: await generatePem(), bundleId: "com.kodalabs.app" },
    fakeFetch,
    () => now,
  );
  const payload = { aps: { "content-available": 1 }, koda: { reason: "shopping", cursor: 1 } };

  const ok = await client.send("aa11", "production", payload, SILENT_PUSH_OPTIONS);
  assertEquals(ok, { ok: true, status: 200, apnsId: "abc", unregistered: false });
  const gone = await client.send("bb22", "sandbox", payload, SILENT_PUSH_OPTIONS);
  assertEquals(gone.unregistered, true);
  assertEquals(gone.reason, "Unregistered");

  assertEquals(requests[0].url, "https://api.push.apple.com/3/device/aa11");
  assertEquals(requests[1].url, "https://api.sandbox.push.apple.com/3/device/bb22");
  const headers = requests[0].headers;
  assertEquals(headers.get("apns-topic"), "com.kodalabs.app");
  assertEquals(headers.get("apns-push-type"), "background");
  assertEquals(headers.get("apns-priority"), "5");
  assertEquals(headers.get("apns-expiration"), String(now / 1000 + 3600));
  assertEquals(JSON.parse(requests[0].body), payload);

  const jwt = headers.get("authorization")!.replace("bearer ", "");
  const [header, claims] = jwt.split(".").map((part, i) => (i < 2 ? decodeSegment(part) : part)) as Record<
    string,
    unknown
  >[];
  assertEquals(header, { alg: "ES256", kid: "38H2AWSNST" });
  assertEquals(claims, { iss: "MUDCX7X324", iat: now / 1000 });
  // Token is cached between requests.
  assertEquals(requests[1].headers.get("authorization"), headers.get("authorization"));
});

Deno.test("internal secret comparison", () => {
  assert(timingSafeEqual("abc", "abc"));
  assert(!timingSafeEqual("abc", "abd"));
  assert(!timingSafeEqual("abc", "abcd"));
  const request = new Request("http://x", { headers: { "x-koda-secret": "s3cret" } });
  assert(hasInternalSecret(request, "s3cret"));
  assert(!hasInternalSecret(request, "other"));
  assert(!hasInternalSecret(request, undefined));
  assert(!hasInternalSecret(new Request("http://x"), "s3cret"));
});
