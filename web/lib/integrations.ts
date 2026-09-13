import { sql } from "@/lib/db";
import { decryptSecret, encryptSecret } from "@/lib/crypto";
import { assertCloudWritable } from "@/lib/residency";

/**
 * Third-party connections the account has chosen to add (SPEC.md §11):
 * GoHighLevel for SMS/email tickets, Vapi for outbound calls. One row per
 * (account, provider); the whole config blob is encrypted with lib/crypto
 * so an API key never sits in plaintext, and the table stays generic so the
 * next integration is a new provider string, not a new table.
 *
 * Like the Paperclip connection, deleting the row is how a user opts out.
 */

export type Provider = "ghl" | "vapi";
export const PROVIDERS: readonly Provider[] = ["ghl", "vapi"];

/** Which config keys each provider needs, and which of them are secrets
 *  (never echoed back by GET). */
export const PROVIDER_FIELDS: Record<Provider, { required: string[]; optional: string[]; secret: string[] }> = {
  ghl: { required: ["api_key", "location_id"], optional: ["from_number", "from_email"], secret: ["api_key"] },
  vapi: { required: ["api_key", "phone_number_id"], optional: ["assistant_id", "webhook_secret"], secret: ["api_key", "webhook_secret"] },
};

export interface IntegrationRow {
  email: string;
  provider: Provider;
  /** { v: 1, enc: "<lib/crypto ciphertext of the JSON config>" } */
  config_enc: { v: number; enc: string } | string;
  residency: "cloud";
  created_at: Date;
  updated_at: Date;
}

export async function ensureIntegrationSchema(db = sql()) {
  await db`
    CREATE TABLE IF NOT EXISTS integrations (
      email       text NOT NULL,
      provider    text NOT NULL,
      config_enc  jsonb NOT NULL,
      residency   text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      created_at  timestamptz NOT NULL DEFAULT now(),
      updated_at  timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (email, provider)
    )`;
}

const norm = (email: string) => email.trim().toLowerCase();

export function isProvider(s: unknown): s is Provider {
  return typeof s === "string" && (PROVIDERS as readonly string[]).includes(s);
}

/** Keeps only the keys the provider knows about; refuses a config missing a
 *  required one. Returns the error message rather than throwing so the route
 *  can 400 with it. */
export function validateConfig(provider: Provider, input: Record<string, unknown>): { config: Record<string, string> } | { error: string } {
  const spec = PROVIDER_FIELDS[provider];
  const config: Record<string, string> = {};
  for (const k of [...spec.required, ...spec.optional]) {
    const v = input[k];
    if (v == null || v === "") continue;
    config[k] = String(v).trim().slice(0, 500);
  }
  const missing = spec.required.filter((k) => !config[k]);
  if (missing.length) return { error: `${provider}: ${missing.join(", ")} required` };
  return { config };
}

export async function setIntegration(email: string, provider: Provider, config: Record<string, string>): Promise<void> {
  const row = assertCloudWritable({
    kind: "integration",
    residency: "cloud" as const,
    email: norm(email),
    provider,
    config_enc: { v: 1, enc: encryptSecret(JSON.stringify(config)) },
  });
  await sql()`
    INSERT INTO integrations (email, provider, config_enc, residency)
    VALUES (${row.email}, ${row.provider}, ${JSON.stringify(row.config_enc)}, ${row.residency})
    ON CONFLICT (email, provider) DO UPDATE SET config_enc = EXCLUDED.config_enc, updated_at = now()`;
}

/** The decrypted config, or null when the account has no such integration
 *  (or the ciphertext no longer decrypts — treated as absent, never as a 500). */
export async function getIntegration(email: string, provider: Provider): Promise<Record<string, string> | null> {
  const rows = await sql()<IntegrationRow[]>`SELECT * FROM integrations WHERE email = ${norm(email)} AND provider = ${provider}`;
  const r = rows[0];
  if (!r) return null;
  const blob = typeof r.config_enc === "string" ? (JSON.parse(r.config_enc) as { enc: string }) : r.config_enc;
  const plain = blob?.enc ? decryptSecret(blob.enc) : null;
  if (!plain) return null;
  try {
    return JSON.parse(plain) as Record<string, string>;
  } catch {
    return null;
  }
}

/** What GET shows: presence and the non-secret fields, never a key. */
export async function describeIntegration(email: string, provider: Provider): Promise<{ connected: boolean; provider: Provider; config?: Record<string, string | boolean>; created_at?: Date; updated_at?: Date }> {
  const rows = await sql()<IntegrationRow[]>`SELECT * FROM integrations WHERE email = ${norm(email)} AND provider = ${provider}`;
  const r = rows[0];
  if (!r) return { connected: false, provider };
  const cfg = (await getIntegration(email, provider)) ?? {};
  const spec = PROVIDER_FIELDS[provider];
  const shown: Record<string, string | boolean> = {};
  for (const [k, v] of Object.entries(cfg)) shown[k] = spec.secret.includes(k) ? !!v : v;
  return { connected: true, provider, config: shown, created_at: r.created_at, updated_at: r.updated_at };
}

export async function deleteIntegration(email: string, provider: Provider): Promise<boolean> {
  const rows = await sql()`DELETE FROM integrations WHERE email = ${norm(email)} AND provider = ${provider} RETURNING provider`;
  return rows.length > 0;
}
