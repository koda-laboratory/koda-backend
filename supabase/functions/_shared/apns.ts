// APNs provider client (token-based authentication).
//
// - JWT ES256 signed with the team's .p8 key (APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY),
//   cached for 50 minutes (Apple rejects tokens older than 1 hour and refreshes more often than
//   every 20 minutes).
// - HTTP/2 POST to api.push.apple.com or api.sandbox.push.apple.com depending on the device.
//   Deno's fetch negotiates HTTP/2 through ALPN, which APNs requires.
// - Topic = bundle id (same app id on iOS and macOS).
import { importPKCS8, SignJWT } from "./deps.ts";
import { optionalEnv } from "./env.ts";

export type ApnsEnvironment = "sandbox" | "production";

export const APNS_HOSTS: Record<ApnsEnvironment, string> = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
};

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  /** PKCS#8 PEM content of the .p8 file. Literal "\n" sequences are accepted. */
  privateKey: string;
  bundleId: string;
}

export interface ApnsRequestOptions {
  pushType: "background" | "alert";
  /** 5 for background pushes, 10 for immediate alerts. */
  priority: 5 | 10;
  /** Seconds from now after which APNs drops the notification. */
  expirationSeconds: number;
  collapseId?: string;
}

export interface ApnsResult {
  ok: boolean;
  status: number;
  reason?: string;
  apnsId?: string;
  /** The token is no longer valid for the topic (410): disable the device. */
  unregistered: boolean;
}

export interface ApnsSender {
  send(token: string, env: ApnsEnvironment, payload: unknown, options: ApnsRequestOptions): Promise<ApnsResult>;
}

export const SILENT_PUSH_OPTIONS: ApnsRequestOptions = {
  pushType: "background",
  priority: 5,
  expirationSeconds: 3600,
};

/** Visible alerts (defrost reminders): delivered immediately, dropped after 12 hours. */
export const ALERT_PUSH_OPTIONS: ApnsRequestOptions = {
  pushType: "alert",
  priority: 10,
  expirationSeconds: 12 * 3600,
};

const TOKEN_TTL_MS = 50 * 60 * 1000;

/** Reads the APNs configuration from the environment; null when incomplete. */
export function apnsConfigFromEnv(): ApnsConfig | null {
  const keyId = optionalEnv("APNS_KEY_ID");
  const teamId = optionalEnv("APNS_TEAM_ID");
  const privateKey = optionalEnv("APNS_PRIVATE_KEY");
  const bundleId = optionalEnv("APNS_BUNDLE_ID");
  if (!keyId || !teamId || !privateKey || !bundleId) return null;
  return { keyId, teamId, privateKey, bundleId };
}

export function normalizePem(pem: string): string {
  return pem.replace(/\\n/g, "\n").trim();
}

export class ApnsClient implements ApnsSender {
  #config: ApnsConfig;
  #fetch: typeof fetch;
  #now: () => number;
  #token: { value: string; issuedAt: number } | null = null;
  #key: CryptoKey | null = null;

  constructor(config: ApnsConfig, fetchImpl: typeof fetch = fetch, now: () => number = Date.now) {
    this.#config = config;
    this.#fetch = fetchImpl;
    this.#now = now;
  }

  /** Provider token, re-signed every 50 minutes. */
  async providerToken(): Promise<string> {
    const now = this.#now();
    if (this.#token && now - this.#token.issuedAt < TOKEN_TTL_MS) return this.#token.value;
    this.#key ??= await importPKCS8(normalizePem(this.#config.privateKey), "ES256");
    const value = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: this.#config.keyId })
      .setIssuer(this.#config.teamId)
      .setIssuedAt(Math.floor(now / 1000))
      .sign(this.#key);
    this.#token = { value, issuedAt: now };
    return value;
  }

  async send(token: string, env: ApnsEnvironment, payload: unknown, options: ApnsRequestOptions): Promise<ApnsResult> {
    const headers: Record<string, string> = {
      authorization: `bearer ${await this.providerToken()}`,
      "apns-topic": this.#config.bundleId,
      "apns-push-type": options.pushType,
      "apns-priority": String(options.priority),
      "apns-expiration": String(Math.floor(this.#now() / 1000) + options.expirationSeconds),
      "content-type": "application/json",
    };
    if (options.collapseId) headers["apns-collapse-id"] = options.collapseId;

    const response = await this.#fetch(`${APNS_HOSTS[env]}/3/device/${token}`, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
    });
    const apnsId = response.headers.get("apns-id") ?? undefined;
    if (response.ok) {
      await response.body?.cancel();
      return { ok: true, status: response.status, apnsId, unregistered: false };
    }
    let reason: string | undefined;
    try {
      reason = ((await response.json()) as { reason?: string }).reason;
    } catch {
      reason = undefined;
    }
    if (response.status === 403 && reason === "ExpiredProviderToken") this.#token = null;
    return { ok: false, status: response.status, reason, apnsId, unregistered: response.status === 410 };
  }
}
