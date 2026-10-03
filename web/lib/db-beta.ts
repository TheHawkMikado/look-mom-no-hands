import { getSetting, setSetting, sql } from "@/lib/db";
import { assertCloudWritable } from "@/lib/residency";

/** Beta redemptions — who used which code for how much. */
export interface BetaRedemption {
  id: string;
  email: string;
  code: string | null;
  discount_cents: number;
  paid_cents: number;
  stripe_session: string | null;
  licence_key: string;
  created_at: Date;
}

export async function ensureBetaSchema(db = sql()) {
  await db`
    CREATE TABLE IF NOT EXISTS beta_redemptions (
      id             text PRIMARY KEY,
      email          text NOT NULL,
      code           text,
      discount_cents integer NOT NULL DEFAULT 0,
      paid_cents     integer NOT NULL DEFAULT 0,
      stripe_session text UNIQUE,
      licence_key    text NOT NULL,
      residency      text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      created_at     timestamptz NOT NULL DEFAULT now()
    )`;
  await db`CREATE INDEX IF NOT EXISTS beta_redemptions_email_idx ON beta_redemptions (email)`;
}

export async function recordBetaRedemption(r: Omit<BetaRedemption, "id" | "created_at">) {
  const row = assertCloudWritable({ kind: "beta_redemption", residency: "cloud" as const, id: crypto.randomUUID(), ...r });
  await sql()`
    INSERT INTO beta_redemptions (id, email, code, discount_cents, paid_cents, stripe_session, licence_key, residency)
    VALUES (${row.id}, ${row.email.toLowerCase()}, ${row.code}, ${row.discount_cents}, ${row.paid_cents},
            ${row.stripe_session}, ${row.licence_key}, ${row.residency})
    ON CONFLICT (stripe_session) DO NOTHING`;
}

export async function listBetaRedemptions(limit = 200): Promise<BetaRedemption[]> {
  return sql()<BetaRedemption[]>`SELECT * FROM beta_redemptions ORDER BY created_at DESC LIMIT ${limit}`;
}

/** The programme switch. Default on; /admin can turn it off. */
export async function betaEnabled(): Promise<boolean> {
  return (await getSetting("beta_enabled")) !== "0";
}
export async function setBetaEnabled(on: boolean) {
  await setSetting("beta_enabled", on ? "1" : "0");
}
