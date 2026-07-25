import { createHash, randomBytes } from "node:crypto";
import postgres from "postgres";
import { decryptSecret, encryptSecret } from "@/lib/crypto";

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
    const url = connectionString();
    if (!url) {
      throw new Error(
        "No Postgres connection string. Set DATABASE_URL (or connect a Postgres " +
          "integration, which sets POSTGRES_URL).",
      );
    }
    global.__sql = postgres(url, { ssl: "require", max: 3, idle_timeout: 20 });
  }
  return global.__sql;
}

/**
 * Hosting integrations each name this differently — Vercel's Postgres/Neon
 * integration injects `POSTGRES_URL`, Prisma setups add their own — and which
 * you get depends on how the database was attached. Accepting the usual aliases
 * means connecting a database from the dashboard just works, rather than
 * failing at the first webhook with a variable that is set under another name.
 *
 * Pooled URLs come first: these routes run serverless, so a connection pooler
 * is what keeps a burst of renewals from exhausting the database's limit.
 */
function connectionString(): string | undefined {
  for (const name of [
    "DATABASE_URL",
    "POSTGRES_URL",
    "POSTGRES_PRISMA_URL",
    "DATABASE_POSTGRES_URL",
    "POSTGRES_URL_NON_POOLING",
    "DATABASE_URL_UNPOOLED",
  ]) {
    const v = process.env[name];
    if (v) return v;
  }
  return undefined;
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

  // Added after the move to weekly billing. Separate ALTERs rather than a
  // rewritten CREATE, so deployments that already have the old table pick these
  // up instead of skipping the whole statement on IF NOT EXISTS.
  await db`ALTER TABLE licences ADD COLUMN IF NOT EXISTS stripe_subscription text`;
  await db`ALTER TABLE licences ADD COLUMN IF NOT EXISTS phones integer NOT NULL DEFAULT 0`;
  await db`ALTER TABLE licences ADD COLUMN IF NOT EXISTS sub_users integer NOT NULL DEFAULT 0`;
  await db`ALTER TABLE licences ADD COLUMN IF NOT EXISTS resell boolean NOT NULL DEFAULT false`;
  await db`CREATE INDEX IF NOT EXISTS licences_subscription_idx ON licences (stripe_subscription)`;

  // Sub-licences a reseller issued. Self-referencing rather than a second table:
  // a sub-user's licence behaves exactly like any other at activation time, and
  // the only difference is who it hangs off.
  await db`ALTER TABLE licences ADD COLUMN IF NOT EXISTS parent_key text`;
  await db`ALTER TABLE licences ADD COLUMN IF NOT EXISTS note text`;
  await db`CREATE INDEX IF NOT EXISTS licences_parent_idx ON licences (parent_key)`;

  // Sign-in tokens. Only the SHA-256 is stored, so a database dump can't be
  // replayed into anyone's account.
  await db`
    CREATE TABLE IF NOT EXISTS login_tokens (
      token_hash  text PRIMARY KEY,
      email       text NOT NULL,
      expires_at  timestamptz NOT NULL,
      used_at     timestamptz,
      created_at  timestamptz NOT NULL DEFAULT now()
    )`;
  await db`CREATE INDEX IF NOT EXISTS login_tokens_email_idx ON login_tokens (email)`;

  // The account's shared Anthropic + ElevenLabs keys, encrypted at rest (AES-GCM,
  // see lib/crypto). One row per account email; a sub-user has no row and reads
  // its parent's keys. Stored here rather than in the app so every device the
  // account (and its sub-users) sign in on picks them up automatically.
  await db`
    CREATE TABLE IF NOT EXISTS account_keys (
      email          text PRIMARY KEY,
      anthropic_enc  text,
      elevenlabs_enc text,
      updated_at     timestamptz NOT NULL DEFAULT now()
    )`;

  // Long-lived per-device bearer tokens the macOS app holds after signing in.
  // Only the SHA-256 is stored (same reasoning as login_tokens); one row per
  // device so a single Mac can be signed out without touching the others.
  await db`
    CREATE TABLE IF NOT EXISTS app_tokens (
      token_hash   text PRIMARY KEY,
      email        text NOT NULL,
      device       text,
      created_at   timestamptz NOT NULL DEFAULT now(),
      last_used_at timestamptz,
      revoked      boolean NOT NULL DEFAULT false
    )`;
  await db`CREATE INDEX IF NOT EXISTS app_tokens_email_idx ON app_tokens (email)`;

  // The order form. Rows here drive what the pricing page offers, so plans can
  // be renamed, reordered, hidden or repriced without a deploy. Seeded from the
  // code catalogue on first run; see lib/catalogue.ts.
  await db`
    CREATE TABLE IF NOT EXISTS plans (
      slug        text PRIMARY KEY,
      name        text NOT NULL,
      tagline     text NOT NULL DEFAULT '',
      price_id    text,                        -- Stripe price_...
      price_label text NOT NULL DEFAULT '',    -- e.g. "$3"
      period      text NOT NULL DEFAULT '/ week',
      features    jsonb NOT NULL DEFAULT '[]',
      computers   integer NOT NULL DEFAULT 1,
      phones      integer NOT NULL DEFAULT 0,
      sub_users   integer NOT NULL DEFAULT 0,
      resell      boolean NOT NULL DEFAULT false,
      featured    boolean NOT NULL DEFAULT false,
      visible     boolean NOT NULL DEFAULT true,
      sort        integer NOT NULL DEFAULT 0
    )`;

  // Migrate the storefront to the Solo / Family / Community model. Entitlement
  // counts (devices, sub-users) are code-owned now, so they're set canonically
  // on every run; admin edits to name/price/features/visibility are preserved.
  // `unlimited` renames to `community` (one-time; no `community` row exists yet
  // when this first runs, so the slug rename can't collide).
  await db`UPDATE plans SET slug = 'community', resell = true WHERE slug = 'unlimited'`;
  await db`UPDATE plans SET computers = 3, phones = 0, sub_users = 0 WHERE slug = 'solo'`;
  await db`UPDATE plans SET computers = 3, phones = 0, sub_users = 5 WHERE slug = 'family'`;
  await db`UPDATE plans SET computers = 3, phones = 0, sub_users = 9999, resell = true WHERE slug = 'community'`;
}

// MARK: - Sign-in tokens

const hashToken = (t: string) => createHash("sha256").update(t).digest("hex");

export async function createLoginToken(email: string, token: string, minutes: number) {
  const db = sql();
  await db`
    INSERT INTO login_tokens (token_hash, email, expires_at)
    VALUES (${hashToken(token)}, ${email}, now() + (${minutes} || ' minutes')::interval)`;
  // Opportunistic cleanup — this table is write-heavy and read-once, and a cron
  // job for it would be more moving parts than the problem deserves.
  await db`DELETE FROM login_tokens WHERE expires_at < now() - interval '1 day'`;
}

/**
 * Marks the token spent and returns its email, atomically. The `used_at IS NULL`
 * check lives inside the UPDATE so two simultaneous clicks on the same link
 * can't both succeed — a mail client that pre-fetches links would otherwise
 * consume the token before the human ever clicks it.
 */
export async function consumeLoginToken(token: string): Promise<string | null> {
  const db = sql();
  const rows = await db<{ email: string }[]>`
    UPDATE login_tokens SET used_at = now()
     WHERE token_hash = ${hashToken(token)}
       AND used_at IS NULL
       AND expires_at > now()
    RETURNING email`;
  return rows[0]?.email ?? null;
}

// MARK: - Account API keys (shared with sub-users)

/**
 * The email whose shared keys an account uses: a sub-user borrows its parent
 * account's keys; everyone else uses their own. Resolved via the sub-user's
 * licence `parent_key` → the parent licence's email.
 */
export async function keyOwnerEmail(email: string): Promise<string> {
  const db = sql();
  const rows = await db<{ parent_email: string }[]>`
    SELECT p.email AS parent_email
      FROM licences c
      JOIN licences p ON p.key = c.parent_key
     WHERE lower(c.email) = lower(${email}) AND c.parent_key IS NOT NULL
     LIMIT 1`;
  return rows[0]?.parent_email ?? email;
}

/** Sets (or clears, with null) one of the account's keys. Per-key so saving one
 *  never clobbers the other. Encrypted before it touches the database. */
export async function setAccountKey(
  email: string,
  which: "anthropic" | "elevenlabs",
  value: string | null,
) {
  const db = sql();
  const enc = value && value.trim() ? encryptSecret(value.trim()) : null;
  const col = which === "anthropic" ? "anthropic_enc" : "elevenlabs_enc";
  await db.unsafe(
    `INSERT INTO account_keys (email, ${col}, updated_at) VALUES ($1, $2, now())
     ON CONFLICT (email) DO UPDATE SET ${col} = $2, updated_at = now()`,
    [email, enc],
  );
}

/** The decrypted keys this account should use (its own, or its parent's if a
 *  sub-user). Either may be null if unset or undecryptable. */
export async function getAccountKeys(
  email: string,
): Promise<{ anthropic: string | null; elevenlabs: string | null }> {
  const db = sql();
  const owner = await keyOwnerEmail(email);
  const rows = await db<{ anthropic_enc: string | null; elevenlabs_enc: string | null }[]>`
    SELECT anthropic_enc, elevenlabs_enc FROM account_keys WHERE lower(email) = lower(${owner})`;
  const row = rows[0];
  return {
    anthropic: row?.anthropic_enc ? decryptSecret(row.anthropic_enc) : null,
    elevenlabs: row?.elevenlabs_enc ? decryptSecret(row.elevenlabs_enc) : null,
  };
}

/** Whether THIS account (not a parent) has each key set — for the account UI's
 *  status pills, without decrypting. */
export async function accountKeyStatus(
  email: string,
): Promise<{ anthropic: boolean; elevenlabs: boolean }> {
  const db = sql();
  const rows = await db<{ a: boolean; e: boolean }[]>`
    SELECT anthropic_enc IS NOT NULL AS a, elevenlabs_enc IS NOT NULL AS e
      FROM account_keys WHERE lower(email) = lower(${email})`;
  return { anthropic: rows[0]?.a ?? false, elevenlabs: rows[0]?.e ?? false };
}

// MARK: - App bearer tokens (macOS app sessions)

/** Mints a per-device bearer token for the app; only its hash is stored. */
export async function createAppToken(email: string, device: string | null): Promise<string> {
  const db = sql();
  const raw = randomBytes(32).toString("base64url");
  await db`
    INSERT INTO app_tokens (token_hash, email, device)
    VALUES (${hashToken(raw)}, ${email}, ${device})`;
  return raw;
}

/** The email a live (non-revoked) app token belongs to, or null. Touches last_used. */
export async function appTokenEmail(raw: string): Promise<string | null> {
  const db = sql();
  const rows = await db<{ email: string }[]>`
    UPDATE app_tokens SET last_used_at = now()
     WHERE token_hash = ${hashToken(raw)} AND NOT revoked
    RETURNING email`;
  return rows[0]?.email ?? null;
}

export async function revokeAppToken(raw: string) {
  const db = sql();
  await db`UPDATE app_tokens SET revoked = true WHERE token_hash = ${hashToken(raw)}`;
}

/**
 * Pushes a licence's expiry out to the end of the period Stripe just billed.
 * Called on every renewal — a weekly subscriber's licence is only ever valid a
 * week at a time, so this is what keeps a paying customer working.
 */
export async function extendSubscription(subscriptionId: string, expiresAt: Date) {
  const db = sql();
  await db`
    UPDATE licences SET expires_at = ${expiresAt}
     WHERE stripe_subscription = ${subscriptionId}`;
}

/** Ends a licence now — cancellation, or a final failed payment. */
export async function endSubscription(subscriptionId: string) {
  const db = sql();
  await db`
    UPDATE licences SET expires_at = now()
     WHERE stripe_subscription = ${subscriptionId}
       AND (expires_at IS NULL OR expires_at > now())`;
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
  phones: number;
  subUsers: number;
  resell: boolean;
  stripeSession: string;
  stripeCustomer: string | null;
  stripeSubscription: string | null;
}) {
  const db = sql();
  await db`
    INSERT INTO licences (key, email, plan, expires_at, seats, phones, sub_users,
                          resell, stripe_session, stripe_customer, stripe_subscription)
    VALUES (${l.key}, ${l.email}, ${l.plan}, ${l.expiresAt}, ${l.seats}, ${l.phones},
            ${l.subUsers}, ${l.resell}, ${l.stripeSession}, ${l.stripeCustomer},
            ${l.stripeSubscription})
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

// MARK: - Dashboard reads

/** Everything shown on a licence row in either dashboard. */
export interface LicenceRow extends Licence {
  phones: number;
  sub_users: number;
  resell: boolean;
  parent_key: string | null;
  note: string | null;
  created_at: Date;
  stripe_customer: string | null;
  devices: number;
}

const LICENCE_COLUMNS = `
  l.key, l.email, l.plan, l.expires_at, l.seats, l.revoked, l.phones,
  l.sub_users, l.resell, l.parent_key, l.note, l.created_at, l.stripe_customer,
  (SELECT count(*)::int FROM activations a WHERE a.key = l.key) AS devices`;

/** A member's own licences — never sub-licences they were issued by a reseller's parent. */
export async function licencesForEmail(email: string): Promise<LicenceRow[]> {
  const db = sql();
  return db.unsafe(
    `SELECT ${LICENCE_COLUMNS} FROM licences l WHERE lower(l.email) = lower($1)
     ORDER BY l.created_at DESC`,
    [email],
  ) as unknown as Promise<LicenceRow[]>;
}

export async function subLicencesOf(parentKey: string): Promise<LicenceRow[]> {
  const db = sql();
  return db.unsafe(
    `SELECT ${LICENCE_COLUMNS} FROM licences l WHERE l.parent_key = $1
     ORDER BY l.created_at DESC`,
    [parentKey],
  ) as unknown as Promise<LicenceRow[]>;
}

export async function countSubLicences(parentKey: string): Promise<number> {
  const db = sql();
  const rows = await db<{ n: number }[]>`
    SELECT count(*)::int AS n FROM licences WHERE parent_key = ${parentKey}`;
  return rows[0]?.n ?? 0;
}

export interface Activation {
  device: string;
  app_version: string | null;
  last_seen: Date;
  created_at: Date;
}

export async function activationsFor(key: string): Promise<Activation[]> {
  const db = sql();
  return db<Activation[]>`
    SELECT device, app_version, last_seen, created_at
      FROM activations WHERE key = ${key} ORDER BY last_seen DESC`;
}

/** Frees a seat. The Mac keeps working until its token expires — the token was
 *  already minted and is verified offline, so this is not an instant kill. */
export async function removeActivation(key: string, device: string) {
  const db = sql();
  await db`DELETE FROM activations WHERE key = ${key} AND device = ${device}`;
}

// MARK: - Admin

export async function searchLicences(term: string, limit = 100): Promise<LicenceRow[]> {
  const db = sql();
  const like = `%${term.trim()}%`;
  if (!term.trim()) {
    return db.unsafe(
      `SELECT ${LICENCE_COLUMNS} FROM licences l ORDER BY l.created_at DESC LIMIT $1`,
      [limit],
    ) as unknown as Promise<LicenceRow[]>;
  }
  return db.unsafe(
    `SELECT ${LICENCE_COLUMNS} FROM licences l
      WHERE l.email ILIKE $1 OR l.key ILIKE $1 OR l.plan ILIKE $1
      ORDER BY l.created_at DESC LIMIT $2`,
    [like, limit],
  ) as unknown as Promise<LicenceRow[]>;
}

export async function setRevoked(key: string, revoked: boolean) {
  const db = sql();
  await db`UPDATE licences SET revoked = ${revoked} WHERE key = ${key}`;
}

export async function setExpiry(key: string, expiresAt: Date | null) {
  const db = sql();
  await db`UPDATE licences SET expires_at = ${expiresAt} WHERE key = ${key}`;
}

export async function setSeats(key: string, seats: number) {
  const db = sql();
  await db`UPDATE licences SET seats = ${seats} WHERE key = ${key}`;
}

export async function deleteLicence(key: string) {
  const db = sql();
  await db`DELETE FROM licences WHERE key = ${key}`;
}

/** Issues a licence outside Stripe — comps, support replacements, sub-users. */
export async function insertLicence(l: {
  key: string;
  email: string;
  plan: string;
  expiresAt: Date | null;
  seats: number;
  phones: number;
  subUsers: number;
  resell: boolean;
  parentKey: string | null;
  note: string | null;
}) {
  const db = sql();
  await db`
    INSERT INTO licences (key, email, plan, expires_at, seats, phones, sub_users,
                          resell, parent_key, note)
    VALUES (${l.key}, ${l.email}, ${l.plan}, ${l.expiresAt}, ${l.seats}, ${l.phones},
            ${l.subUsers}, ${l.resell}, ${l.parentKey}, ${l.note})`;
}

export interface Stats {
  total: number;
  active: number;
  revoked: number;
  devices: number;
}

export async function licenceStats(): Promise<Stats> {
  const db = sql();
  const rows = await db<Stats[]>`
    SELECT
      count(*)::int AS total,
      count(*) FILTER (WHERE NOT revoked
                         AND (expires_at IS NULL OR expires_at > now()))::int AS active,
      count(*) FILTER (WHERE revoked)::int AS revoked,
      (SELECT count(*)::int FROM activations) AS devices
    FROM licences`;
  return rows[0] ?? { total: 0, active: 0, revoked: 0, devices: 0 };
}

// MARK: - Plans (the order form)

export interface PlanRow {
  slug: string;
  name: string;
  tagline: string;
  price_id: string | null;
  price_label: string;
  period: string;
  features: string[];
  computers: number;
  phones: number;
  sub_users: number;
  resell: boolean;
  featured: boolean;
  visible: boolean;
  sort: number;
}

/**
 * The `features` jsonb column can come back as a real array OR as a JSON string,
 * depending on how the driver decodes it — and every page that shows a plan does
 * `features.map(...)` / `.join(...)`, which throws on a string and 500s the whole
 * page (including the marketing homepage). Coerce to a string[] on read so no
 * renderer can crash on it, whatever the driver returns.
 */
function asFeatures(f: unknown): string[] {
  if (Array.isArray(f)) return f.map(String);
  if (typeof f === "string") {
    try {
      const parsed = JSON.parse(f);
      return Array.isArray(parsed) ? parsed.map(String) : [];
    } catch {
      return [];
    }
  }
  return [];
}

function coercePlan(p: PlanRow): PlanRow {
  return { ...p, features: asFeatures((p as { features: unknown }).features) };
}

export async function allPlans(): Promise<PlanRow[]> {
  const db = sql();
  const rows = await db<PlanRow[]>`SELECT * FROM plans ORDER BY sort, slug`;
  return rows.map(coercePlan);
}

export async function visiblePlans(): Promise<PlanRow[]> {
  const db = sql();
  const rows = await db<PlanRow[]>`SELECT * FROM plans WHERE visible ORDER BY sort, slug`;
  return rows.map(coercePlan);
}

export async function planBySlug(slug: string): Promise<PlanRow | null> {
  const db = sql();
  const rows = await db<PlanRow[]>`SELECT * FROM plans WHERE slug = ${slug}`;
  return rows[0] ? coercePlan(rows[0]) : null;
}

export async function upsertPlan(p: PlanRow) {
  const db = sql();
  await db`
    INSERT INTO plans (slug, name, tagline, price_id, price_label, period, features,
                       computers, phones, sub_users, resell, featured, visible, sort)
    VALUES (${p.slug}, ${p.name}, ${p.tagline}, ${p.price_id}, ${p.price_label},
            ${p.period}, ${JSON.stringify(p.features)}, ${p.computers}, ${p.phones},
            ${p.sub_users}, ${p.resell}, ${p.featured}, ${p.visible}, ${p.sort})
    ON CONFLICT (slug) DO UPDATE SET
      name = EXCLUDED.name, tagline = EXCLUDED.tagline, price_id = EXCLUDED.price_id,
      price_label = EXCLUDED.price_label, period = EXCLUDED.period,
      features = EXCLUDED.features, computers = EXCLUDED.computers,
      phones = EXCLUDED.phones, sub_users = EXCLUDED.sub_users,
      resell = EXCLUDED.resell, featured = EXCLUDED.featured,
      visible = EXCLUDED.visible, sort = EXCLUDED.sort`;
}

export async function deletePlan(slug: string) {
  const db = sql();
  await db`DELETE FROM plans WHERE slug = ${slug}`;
}
