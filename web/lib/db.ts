import postgres from "postgres";

/**
 * Licence storage.
 *
 * Plain Postgres over `DATABASE_URL` rather than a vendor-specific SDK, so the
 * same code runs against Neon, Supabase, RDS or a local box — the storage
 * products bundled with hosting platforms get renamed and repackaged often, and
 * a connection string outlives all of it.
 */

declare global {
  // eslint-disable-next-line no-var
  var __sql: ReturnType<typeof postgres> | undefined;
}

/**
 * Connects on first use, not at import time — a missing DATABASE_URL should
 * break the routes that need a database, not the marketing pages that don't.
 * The instance is cached on `globalThis` because serverless invocations reuse
 * module scope, so a burst of activations shares one small pool instead of
 * opening a connection per request.
 */
export function sql() {
  if (!global.__sql) {
    const url = process.env.DATABASE_URL;
    if (!url) throw new Error("DATABASE_URL is not set");
    global.__sql = postgres(url, { ssl: "require", max: 3, idle_timeout: 20 });
  }
  return global.__sql;
}

export interface Licence {
  key: string;
  email: string;
  plan: string;
  expires_at: Date | null;
  seats: number;
  revoked: boolean;
}

/** Idempotent — safe to call from any route, and it means no migration step. */
export async function ensureSchema() {
  const db = sql();
  await db`
    CREATE TABLE IF NOT EXISTS licences (
      key             text PRIMARY KEY,
      email           text NOT NULL,
      plan            text NOT NULL DEFAULT 'pro',
      expires_at      timestamptz,          -- NULL = perpetual
      seats           integer NOT NULL DEFAULT 3,
      revoked         boolean NOT NULL DEFAULT false,
      stripe_session  text UNIQUE,          -- also the idempotency guard on webhooks
      stripe_customer text,
      created_at      timestamptz NOT NULL DEFAULT now()
    )`;
  await db`
    CREATE TABLE IF NOT EXISTS activations (
      key           text NOT NULL REFERENCES licences(key) ON DELETE CASCADE,
      device        text NOT NULL,
      app_version   text,
      last_seen     timestamptz NOT NULL DEFAULT now(),
      created_at    timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (key, device)
    )`;
  await db`CREATE INDEX IF NOT EXISTS licences_email_idx ON licences (email)`;
}

export async function findLicence(key: string): Promise<Licence | null> {
  const db = sql();
  const rows = await db<Licence[]>`
    SELECT key, email, plan, expires_at, seats, revoked
      FROM licences WHERE key = ${key}`;
  return rows[0] ?? null;
}

export async function createLicence(l: {
  key: string;
  email: string;
  plan: string;
  expiresAt: Date | null;
  seats: number;
  stripeSession: string;
  stripeCustomer: string | null;
}) {
  const db = sql();
  await db`
    INSERT INTO licences (key, email, plan, expires_at, seats, stripe_session, stripe_customer)
    VALUES (${l.key}, ${l.email}, ${l.plan}, ${l.expiresAt}, ${l.seats},
            ${l.stripeSession}, ${l.stripeCustomer})
    ON CONFLICT (stripe_session) DO NOTHING`;
}

/** Stripe retries webhooks; look up by session so a retry returns the first key. */
export async function licenceForSession(sessionId: string): Promise<Licence | null> {
  const db = sql();
  const rows = await db<Licence[]>`
    SELECT key, email, plan, expires_at, seats, revoked
      FROM licences WHERE stripe_session = ${sessionId}`;
  return rows[0] ?? null;
}

export async function countDevices(key: string): Promise<number> {
  const db = sql();
  const rows = await db<{ n: number }[]>`
    SELECT count(*)::int AS n FROM activations WHERE key = ${key}`;
  return rows[0]?.n ?? 0;
}

export async function deviceKnown(key: string, device: string): Promise<boolean> {
  const db = sql();
  const rows = await db`
    SELECT 1 FROM activations WHERE key = ${key} AND device = ${device}`;
  return rows.length > 0;
}

/** Re-activating the same Mac refreshes last_seen rather than burning a seat. */
export async function recordActivation(key: string, device: string, version: string) {
  const db = sql();
  await db`
    INSERT INTO activations (key, device, app_version)
    VALUES (${key}, ${device}, ${version})
    ON CONFLICT (key, device)
    DO UPDATE SET last_seen = now(), app_version = EXCLUDED.app_version`;
}
