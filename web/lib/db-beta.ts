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

// ---------------------------------------------------------------------------
// Beta testers programme: 10 free seats for 5+ hours a month and a feedback
// form each month, for three months. Applications land here, the owner
// accepts from /admin (which mints the free `beta` licence and emails it),
// and testers file their monthly form at /testers/feedback.

export type ApplicationStatus = "pending" | "accepted" | "declined";

export interface BetaApplication {
  id: string;
  name: string;
  email: string;
  role: string;
  machine: string;
  use_case: string;
  social: string;
  status: ApplicationStatus;
  licence_key: string | null;
  created_at: Date;
  decided_at: Date | null;
}

export interface BetaFeedback {
  id: string;
  email: string;
  month: string;        // "2026-10"
  hours: number;
  worked: string;
  broke: string;
  wish: string;
  score: number;        // 0–10
  created_at: Date;
}

export async function ensureBetaTesterSchema(db = sql()) {
  await db`
    CREATE TABLE IF NOT EXISTS beta_applications (
      id          text PRIMARY KEY,
      name        text NOT NULL,
      email       text NOT NULL,
      role        text NOT NULL DEFAULT '',
      machine     text NOT NULL DEFAULT '',
      use_case    text NOT NULL DEFAULT '',
      social      text NOT NULL DEFAULT '',
      status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','declined')),
      licence_key text,
      residency   text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      created_at  timestamptz NOT NULL DEFAULT now(),
      decided_at  timestamptz
    )`;
  await db`CREATE UNIQUE INDEX IF NOT EXISTS beta_applications_email_idx ON beta_applications (lower(email))`;
  await db`
    CREATE TABLE IF NOT EXISTS beta_feedback (
      id         text PRIMARY KEY,
      email      text NOT NULL,
      month      text NOT NULL,
      hours      integer NOT NULL DEFAULT 0,
      worked     text NOT NULL DEFAULT '',
      broke      text NOT NULL DEFAULT '',
      wish       text NOT NULL DEFAULT '',
      score      integer NOT NULL DEFAULT 0,
      residency  text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      created_at timestamptz NOT NULL DEFAULT now()
    )`;
  await db`CREATE INDEX IF NOT EXISTS beta_feedback_email_idx ON beta_feedback (lower(email), month)`;
}

export const BETA_TESTER_SEATS = 10;

export async function submitApplication(a: Pick<BetaApplication, "name" | "email" | "role" | "machine" | "use_case" | "social">) {
  const row = assertCloudWritable({ kind: "beta_application", residency: "cloud" as const, id: crypto.randomUUID(), ...a });
  await sql()`
    INSERT INTO beta_applications (id, name, email, role, machine, use_case, social, residency)
    VALUES (${row.id}, ${row.name}, ${row.email.toLowerCase()}, ${row.role}, ${row.machine}, ${row.use_case}, ${row.social}, ${row.residency})
    ON CONFLICT ((lower(email))) DO UPDATE
      SET name = EXCLUDED.name, role = EXCLUDED.role, machine = EXCLUDED.machine,
          use_case = EXCLUDED.use_case, social = EXCLUDED.social`;
}

export async function listApplications(limit = 300): Promise<BetaApplication[]> {
  return sql()<BetaApplication[]>`
    SELECT * FROM beta_applications
    ORDER BY (status = 'pending') DESC, created_at DESC LIMIT ${limit}`;
}

export async function countAcceptedTesters(): Promise<number> {
  const [r] = await sql()<{ n: number }[]>`SELECT count(*)::int AS n FROM beta_applications WHERE status = 'accepted'`;
  return r?.n ?? 0;
}

export async function getApplication(id: string): Promise<BetaApplication | null> {
  const [r] = await sql()<BetaApplication[]>`SELECT * FROM beta_applications WHERE id = ${id}`;
  return r ?? null;
}

export async function markApplication(id: string, status: ApplicationStatus, licenceKey: string | null) {
  await sql()`
    UPDATE beta_applications SET status = ${status}, licence_key = ${licenceKey}, decided_at = now()
    WHERE id = ${id}`;
}

export async function submitFeedback(f: Omit<BetaFeedback, "id" | "created_at">) {
  const row = assertCloudWritable({ kind: "beta_feedback", residency: "cloud" as const, id: crypto.randomUUID(), ...f });
  await sql()`
    INSERT INTO beta_feedback (id, email, month, hours, worked, broke, wish, score, residency)
    VALUES (${row.id}, ${row.email.toLowerCase()}, ${row.month}, ${row.hours}, ${row.worked}, ${row.broke}, ${row.wish}, ${row.score}, ${row.residency})`;
}

export async function listFeedback(limit = 300): Promise<BetaFeedback[]> {
  return sql()<BetaFeedback[]>`SELECT * FROM beta_feedback ORDER BY created_at DESC LIMIT ${limit}`;
}

/** "2026-10" for a date: the month a feedback form belongs to. */
export function feedbackMonth(d = new Date()): string {
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}
