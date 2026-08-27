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
  mode: string;
}

/** Idempotent — safe to call from any route, and it means no migration step.
 *  Memoized per process: the DDL is ~40 statements, and the polling routes
 *  (/status feed every 5s, approvals every 6s) would otherwise re-run all of
 *  it against the catalog on every request forever. */
let schemaReady: Promise<void> | null = null;
export function ensureSchema(): Promise<void> {
  schemaReady ??= ensureSchemaOnce().catch((e) => {
    schemaReady = null; // a failed attempt must not poison every later request
    throw e;
  });
  return schemaReady;
}

async function ensureSchemaOnce() {
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

  // Bring-your-own-key pricing: a second Stripe price + labels per plan. Cloud
  // (we supply the AI keys) uses the original price_id/price_label/period; BYOK
  // (the customer supplies their own keys) uses these. Nullable/blank until an
  // admin configures them, so the storefront just doesn't offer BYOK for a plan
  // that has no BYOK price yet.
  await db`ALTER TABLE plans ADD COLUMN IF NOT EXISTS price_id_byok text`;
  await db`ALTER TABLE plans ADD COLUMN IF NOT EXISTS price_label_byok text NOT NULL DEFAULT ''`;
  await db`ALTER TABLE plans ADD COLUMN IF NOT EXISTS period_byok text NOT NULL DEFAULT ''`;

  // Migrate the storefront to the Solo / Family / Community model. Entitlement
  // counts (devices, sub-users) are code-owned now, so they're set canonically
  // on every run; admin edits to name/price/features/visibility are preserved.
  // `unlimited` renames to `community` (one-time; no `community` row exists yet
  // when this first runs, so the slug rename can't collide).
  // Devices are uncapped on every plan now (9999 = the UNLIMITED sentinel), so
  // `computers` is no longer a limit — access is per-account and Cloud usage is
  // metered. Set canonically each run alongside the sub-user allowances.
  await db`UPDATE plans SET slug = 'community', resell = true WHERE slug = 'unlimited'`;
  await db`UPDATE plans SET computers = 9999, phones = 0, sub_users = 0 WHERE slug = 'solo'`;
  await db`UPDATE plans SET computers = 9999, phones = 0, sub_users = 5 WHERE slug = 'family'`;
  await db`UPDATE plans SET computers = 9999, phones = 0, sub_users = 9999, resell = true WHERE slug = 'community'`;

  // Rewrite any "N devices / computers / macs / phones" feature bullet to
  // "Unlimited devices" to match the no-cap model. Guarded on a digit before the
  // noun so it only touches old capped wording and is idempotent (the rewritten
  // bullet has no number, so it won't re-match) — other bullets are untouched.
  // First repair any features stored as a JSON *string* rather than an array (a
  // driver round-trip quirk) — `#>> '{}'` unwraps the scalar to its text, which is
  // itself a JSON array, and re-casts it to jsonb. Guarded so it only touches
  // scalars whose text actually looks like an array.
  await db`
    UPDATE plans SET features = (features #>> '{}')::jsonb
     WHERE jsonb_typeof(features) = 'string' AND (features #>> '{}') LIKE '[%]'`;

  // Then rewrite any "N devices / computers / macs / phones" bullet to "Unlimited
  // devices". `jsonb_typeof = 'array'` keeps jsonb_array_elements from choking on a
  // non-array; the digit guard makes it idempotent (the rewrite has no number).
  await db`
    UPDATE plans SET features = (
      SELECT jsonb_agg(
        CASE WHEN elem::text ~* '[0-9]+ *(device|computer|mac|phone)'
             THEN '"Unlimited devices"'::jsonb ELSE elem END)
      FROM jsonb_array_elements(features) elem)
    WHERE jsonb_typeof(features) = 'array'
      AND features::text ~* '[0-9]+ *(device|computer|mac|phone)'`;

  // The hidden "comp" plan: a free Solo account issued by hand. ON CONFLICT DO
  // NOTHING so it's created once and any later admin edits to it survive re-runs.
  await db`
    INSERT INTO plans (slug, name, tagline, price_label, period, features,
                       computers, phones, sub_users, resell, featured, visible, sort)
    VALUES ('comp', 'Comp', 'complimentary', 'Free', '',
            ${JSON.stringify(["Unlimited devices", "1 user", "Complimentary — issued by hand"])},
            9999, 0, 0, false, false, false, 100)
    ON CONFLICT (slug) DO NOTHING`;

  // Per-device usage the app reports back: metered controller/dictation hours and
  // API cost, split by workload, tagged by mode (cloud/byok). Feeds pricing
  // analysis now and Cloud overage metering later. One cumulative row per device;
  // no transcripts or content, only counts.
  await db`
    CREATE TABLE IF NOT EXISTS usage_reports (
      email        text NOT NULL,
      device       text NOT NULL,
      mode         text NOT NULL DEFAULT 'byok',
      ctrl_cost    double precision NOT NULL DEFAULT 0,
      ctrl_calls   integer NOT NULL DEFAULT 0,
      ctrl_seconds double precision NOT NULL DEFAULT 0,
      dict_cost    double precision NOT NULL DEFAULT 0,
      dict_calls   integer NOT NULL DEFAULT 0,
      dict_seconds double precision NOT NULL DEFAULT 0,
      updated_at   timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (email, device)
    )`;

  // Cloud vs BYOK per subscription — which keys the app runs on. Set at checkout
  // (nohands_mode metadata → webhook) or by an admin. Default 'byok', the app's
  // original model.
  await db`ALTER TABLE licences ADD COLUMN IF NOT EXISTS mode text NOT NULL DEFAULT 'byok'`;

  // The platform (owner's) Anthropic + ElevenLabs keys that Cloud subscribers run
  // on — the app fetches these instead of the account's own. One row, encrypted
  // exactly like account keys.
  await db`
    CREATE TABLE IF NOT EXISTS platform_keys (
      id             integer PRIMARY KEY DEFAULT 1,
      anthropic_enc  text,
      elevenlabs_enc text,
      updated_at     timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT platform_keys_singleton CHECK (id = 1)
    )`;

  // Cloud metering — this billing week's controller/dictation usage per account,
  // plus how much overage has already been drawn from the wallet this period.
  await db`
    CREATE TABLE IF NOT EXISTS usage_meter (
      email                 text PRIMARY KEY,
      period_start          timestamptz NOT NULL DEFAULT now(),
      ctrl_seconds          double precision NOT NULL DEFAULT 0,
      dict_seconds          double precision NOT NULL DEFAULT 0,
      overage_charged_cents integer NOT NULL DEFAULT 0
    )`;

  // Prepaid overage credit, in cents. Topped up via one-time checkout.
  await db`
    CREATE TABLE IF NOT EXISTS credit_wallet (
      email text PRIMARY KEY,
      cents integer NOT NULL DEFAULT 0
    )`;

  // One row per processed top-up payment — the idempotency guard so a redelivered
  // webhook can't credit a wallet twice (top-ups create no licence to key off).
  await db`
    CREATE TABLE IF NOT EXISTS credit_topups (
      stripe_session text PRIMARY KEY,
      email          text NOT NULL,
      cents          integer NOT NULL,
      created_at     timestamptz NOT NULL DEFAULT now()
    )`;

  // Small key/value store — e.g. the lazily-created Community overage price id.
  await db`
    CREATE TABLE IF NOT EXISTS settings (
      key   text PRIMARY KEY,
      value text NOT NULL
    )`;

  // Reseller accounts — a provisioning API key (SHA-256 only) for creating
  // sub-users programmatically, and a webhook (their URL + a signing secret we
  // sign outgoing events with). `price_cents` is what they charge their
  // customers; floored at the Solo price. They handle their own payment.
  await db`
    CREATE TABLE IF NOT EXISTS resellers (
      email               text PRIMARY KEY,
      connect_account_id  text,
      provision_key_hash  text,
      price_cents         integer NOT NULL DEFAULT 300,
      created_at          timestamptz NOT NULL DEFAULT now()
    )`;
  await db`ALTER TABLE resellers ADD COLUMN IF NOT EXISTS webhook_url text`;
  await db`ALTER TABLE resellers ADD COLUMN IF NOT EXISTS webhook_secret text`;

  // Remote agent visibility: status events the Mac app reports while an agent
  // runs, and the approve/deny verdicts the owner records from /status. Status
  // text only — never screenshots or transcripts (detail is capped at 500 chars
  // on write). Retention is the newest 200 events per account, pruned on insert,
  // so the table can't grow past a small multiple of the account count.
  await db`
    CREATE TABLE IF NOT EXISTS agent_events (
      email       text NOT NULL,
      id          text NOT NULL,          -- the app's event id; the dedupe key on re-sends
      kind        text NOT NULL,
      title       text NOT NULL DEFAULT '',
      detail      text NOT NULL DEFAULT '',
      approval_id text,
      created_at  timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (email, id)
    )`;
  await db`CREATE INDEX IF NOT EXISTS agent_events_email_created_idx
             ON agent_events (email, created_at DESC)`;
  await db`
    CREATE TABLE IF NOT EXISTS agent_approvals (
      email       text NOT NULL,
      approval_id text NOT NULL,
      verdict     text NOT NULL,          -- 'approve' | 'deny'
      decided_at  timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (email, approval_id)
    )`;
}

// MARK: - Resellers (Stripe Connect + provisioning)

export interface Reseller {
  email: string;
  connect_account_id: string | null;
  provision_key_hash: string | null;
  price_cents: number;
  webhook_url: string | null;
  webhook_secret: string | null;
}

export async function getReseller(email: string): Promise<Reseller | null> {
  const db = sql();
  const rows = await db<Reseller[]>`
    SELECT email, connect_account_id, provision_key_hash, price_cents,
           webhook_url, webhook_secret
      FROM resellers WHERE lower(email) = lower(${email})`;
  return rows[0] ?? null;
}

export async function setResellerWebhookUrl(email: string, url: string | null) {
  await ensureReseller(email);
  const db = sql();
  await db`UPDATE resellers SET webhook_url = ${url} WHERE lower(email) = lower(${email})`;
}

/** Mints a webhook signing secret (we HMAC outgoing events with it; the reseller
 *  verifies). Shown once. */
export async function mintWebhookSecret(email: string): Promise<string> {
  await ensureReseller(email);
  const secret = "whsec_" + randomBytes(24).toString("base64url");
  const db = sql();
  await db`UPDATE resellers SET webhook_secret = ${secret} WHERE lower(email) = lower(${email})`;
  return secret;
}

async function ensureReseller(email: string) {
  const db = sql();
  await db`INSERT INTO resellers (email) VALUES (${email}) ON CONFLICT (email) DO NOTHING`;
}

export async function setResellerConnect(email: string, accountId: string) {
  await ensureReseller(email);
  const db = sql();
  await db`UPDATE resellers SET connect_account_id = ${accountId} WHERE lower(email) = lower(${email})`;
}

export async function setResellerPrice(email: string, cents: number) {
  await ensureReseller(email);
  const db = sql();
  await db`UPDATE resellers SET price_cents = ${cents} WHERE lower(email) = lower(${email})`;
}

/** Mints a provisioning API key for a reseller (stores only its hash). */
export async function mintProvisionKey(email: string): Promise<string> {
  await ensureReseller(email);
  const raw = "nhk_" + randomBytes(24).toString("base64url");
  const db = sql();
  await db`UPDATE resellers SET provision_key_hash = ${hashToken(raw)} WHERE lower(email) = lower(${email})`;
  return raw;
}

/** The reseller email behind a raw provisioning key, or null. */
export async function resellerByProvisionKey(raw: string): Promise<string | null> {
  const db = sql();
  const rows = await db<{ email: string }[]>`
    SELECT email FROM resellers WHERE provision_key_hash = ${hashToken(raw)}`;
  return rows[0]?.email ?? null;
}

export async function getSetting(key: string): Promise<string | null> {
  const db = sql();
  const rows = await db<{ value: string }[]>`SELECT value FROM settings WHERE key = ${key}`;
  return rows[0]?.value ?? null;
}

export async function setSetting(key: string, value: string) {
  const db = sql();
  await db`
    INSERT INTO settings (key, value) VALUES (${key}, ${value})
    ON CONFLICT (key) DO UPDATE SET value = ${value}`;
}

// MARK: - Platform keys (what Cloud subscribers run on)

/** Sets (or clears) one of the owner's platform keys — the keys Cloud users run
 *  on. Encrypted at rest; mirrors setAccountKey. */
export async function setPlatformKey(which: "anthropic" | "elevenlabs", value: string | null) {
  const db = sql();
  const enc = value && value.trim() ? encryptSecret(value.trim()) : null;
  const col = which === "anthropic" ? "anthropic_enc" : "elevenlabs_enc";
  await db.unsafe(
    `INSERT INTO platform_keys (id, ${col}, updated_at) VALUES (1, $1, now())
     ON CONFLICT (id) DO UPDATE SET ${col} = $1, updated_at = now()`,
    [enc],
  );
}

export async function getPlatformKeys(): Promise<{ anthropic: string | null; elevenlabs: string | null }> {
  const db = sql();
  const rows = await db<{ anthropic_enc: string | null; elevenlabs_enc: string | null }[]>`
    SELECT anthropic_enc, elevenlabs_enc FROM platform_keys WHERE id = 1`;
  const row = rows[0];
  return {
    anthropic: row?.anthropic_enc ? decryptSecret(row.anthropic_enc) : null,
    elevenlabs: row?.elevenlabs_enc ? decryptSecret(row.elevenlabs_enc) : null,
  };
}

export async function platformKeyStatus(): Promise<{ anthropic: boolean; elevenlabs: boolean }> {
  const db = sql();
  const rows = await db<{ a: boolean; e: boolean }[]>`
    SELECT anthropic_enc IS NOT NULL AS a, elevenlabs_enc IS NOT NULL AS e
      FROM platform_keys WHERE id = 1`;
  return { anthropic: rows[0]?.a ?? false, elevenlabs: rows[0]?.e ?? false };
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

// MARK: - Usage reporting (for pricing analysis + Cloud metering)

export interface UsageBucket {
  cost: number;
  calls: number;
  seconds: number;
}

/** Records the app's cumulative per-device usage and returns the delta (in
 *  seconds) since the last report from this device — the amount to add to the
 *  metering week. Reports are running totals, so an upsert keeps one row per
 *  device; a decrease (the app's meter was reset) yields a zero delta. */
export async function recordUsage(
  email: string,
  device: string,
  mode: string,
  controller: UsageBucket,
  dictation: UsageBucket,
): Promise<{ dCtrlSeconds: number; dDictSeconds: number }> {
  const db = sql();
  const prev = await db<{ ctrl_seconds: number; dict_seconds: number }[]>`
    SELECT ctrl_seconds, dict_seconds FROM usage_reports
     WHERE email = ${email} AND device = ${device}`;
  const dCtrlSeconds = Math.max(0, controller.seconds - (prev[0]?.ctrl_seconds ?? 0));
  const dDictSeconds = Math.max(0, dictation.seconds - (prev[0]?.dict_seconds ?? 0));

  await db`
    INSERT INTO usage_reports
      (email, device, mode, ctrl_cost, ctrl_calls, ctrl_seconds,
       dict_cost, dict_calls, dict_seconds, updated_at)
    VALUES (${email}, ${device}, ${mode},
       ${controller.cost}, ${controller.calls}, ${controller.seconds},
       ${dictation.cost}, ${dictation.calls}, ${dictation.seconds}, now())
    ON CONFLICT (email, device) DO UPDATE SET
      mode = EXCLUDED.mode,
      ctrl_cost = EXCLUDED.ctrl_cost, ctrl_calls = EXCLUDED.ctrl_calls,
      ctrl_seconds = EXCLUDED.ctrl_seconds, dict_cost = EXCLUDED.dict_cost,
      dict_calls = EXCLUDED.dict_calls, dict_seconds = EXCLUDED.dict_seconds,
      updated_at = now()`;

  return { dCtrlSeconds, dDictSeconds };
}

// MARK: - Agent events & approvals (remote visibility)

export const AGENT_EVENT_KINDS = [
  "goal_started",
  "goal_progress",
  "needs_approval",
  "goal_done",
  "goal_failed",
] as const;
export type AgentEventKind = (typeof AGENT_EVENT_KINDS)[number];

export interface AgentEvent {
  id: string;
  kind: AgentEventKind;
  title: string;
  detail: string;
  approval_id: string | null;
  created_at: Date;
}

export interface ApprovalVerdict {
  approval_id: string;
  verdict: string;
  decided_at: Date;
}

/** Newest events kept per account; older rows are pruned on insert. */
const AGENT_EVENTS_KEPT = 200;

/** Stores a batch of agent events for the account and prunes past the retention
 *  cap. Re-sent events (the app retries on flaky networks) dedupe on (email, id)
 *  rather than duplicating rows. */
export async function recordAgentEvents(
  email: string,
  events: {
    id: string;
    kind: AgentEventKind;
    title: string;
    detail: string;
    approvalId: string | null;
    createdAt: Date;
  }[],
) {
  const db = sql();
  const account = email.trim().toLowerCase();
  if (events.length === 0) return;
  // One round trip for the whole batch, not one per event — this runs on every
  // 8-second flush from every running Mac.
  const rows = events.map((e) => ({
    email: account,
    id: e.id,
    kind: e.kind,
    title: e.title,
    detail: e.detail,
    approval_id: e.approvalId,
    created_at: e.createdAt,
  }));
  await db`
    INSERT INTO agent_events ${db(rows, "email", "id", "kind", "title", "detail", "approval_id", "created_at")}
    ON CONFLICT (email, id) DO NOTHING`;
  // Prune only when this batch could actually push the account past the cap —
  // the count query is cheap (index-only) and skips the sort-heavy DELETE on
  // the overwhelmingly common under-cap call.
  const [{ count }] = await db<{ count: string }[]>`
    SELECT count(*) FROM agent_events WHERE email = ${account}`;
  if (Number(count) > AGENT_EVENTS_KEPT) {
    await db`
      DELETE FROM agent_events
       WHERE email = ${account}
         AND id NOT IN (SELECT id FROM agent_events WHERE email = ${account}
                         ORDER BY created_at DESC, id DESC LIMIT ${AGENT_EVENTS_KEPT})`;
  }
}

/** The account's recent agent events, newest first. */
export async function agentEventsFor(email: string, limit = AGENT_EVENTS_KEPT): Promise<AgentEvent[]> {
  const db = sql();
  // Writes store email pre-lowercased; comparing the normalized PARAM (not
  // lower(column)) keeps the (email, created_at) index usable — lower(email)
  // was a sequential scan on every 5-second poll.
  return db<AgentEvent[]>`
    SELECT id, kind, title, detail, approval_id, created_at
      FROM agent_events WHERE email = ${email.trim().toLowerCase()}
     ORDER BY created_at DESC, id DESC LIMIT ${limit}`;
}

/** Records a verdict. The first decision wins — a second click (or a second
 *  device deciding the same approval) is a no-op, so the app can never see the
 *  verdict flip. Returns false if it was already decided. */
export async function decideApproval(
  email: string,
  approvalId: string,
  verdict: "approve" | "deny",
): Promise<boolean> {
  const db = sql();
  const account = email.trim().toLowerCase();
  const rows = await db`
    INSERT INTO agent_approvals (email, approval_id, verdict)
    VALUES (${account}, ${approvalId}, ${verdict})
    ON CONFLICT (email, approval_id) DO NOTHING
    RETURNING approval_id`;
  // Opportunistic cleanup, same reasoning as login_tokens — the poll only ever
  // asks for recent verdicts, so month-old rows are dead weight.
  await db`
    DELETE FROM agent_approvals
     WHERE email = ${account} AND decided_at < now() - interval '30 days'`;
  return rows.length > 0;
}

/** Verdicts decided after `since` (all of them when null), oldest first so the
 *  app can use the last row's decided_at as its next cursor. */
export async function approvalVerdictsSince(
  email: string,
  since: Date | null,
): Promise<ApprovalVerdict[]> {
  const db = sql();
  // Normalized param, not lower(column) — see agentEventsFor.
  return db<ApprovalVerdict[]>`
    SELECT approval_id, verdict, decided_at
      FROM agent_approvals
     WHERE email = ${email.trim().toLowerCase()}
       AND decided_at > ${since ?? new Date(0)}
     ORDER BY decided_at ASC`;
}

// MARK: - Cloud metering (usage_meter + credit_wallet)

interface MeterRow {
  period_start: Date;
  ctrl_seconds: number;
  dict_seconds: number;
  overage_charged_cents: number;
}

const PERIOD_MS = 7 * 24 * 60 * 60 * 1000;

/** Adds this report's delta to the account's metering week and, if it pushes
 *  past the included hours, draws the overage from the prepaid wallet (down to
 *  zero — an empty wallet is what the key gate checks). The week resets lazily
 *  when the stored period is over 7 days old. */
export async function chargeMeter(
  email: string,
  allowance: { ctrl: number; dict: number },
  overageDollars: (ctrlHours: number, dictHours: number) => number,
  dCtrlSeconds: number,
  dDictSeconds: number,
) {
  const db = sql();
  const rows = await db<MeterRow[]>`SELECT * FROM usage_meter WHERE email = ${email}`;
  const now = Date.now();
  const cur =
    rows[0] && now - new Date(rows[0].period_start).getTime() < PERIOD_MS
      ? rows[0]
      : { period_start: new Date(), ctrl_seconds: 0, dict_seconds: 0, overage_charged_cents: 0 };

  const ctrl = cur.ctrl_seconds + dCtrlSeconds;
  const dict = cur.dict_seconds + dDictSeconds;
  const dueCents = Math.round(overageDollars(ctrl / 3600, dict / 3600) * 100);
  const toCharge = Math.max(0, dueCents - cur.overage_charged_cents);

  let chargedCents = cur.overage_charged_cents;
  if (toCharge > 0) {
    const bal = await walletCents(email);
    const take = Math.min(toCharge, bal);
    if (take > 0) {
      await db`UPDATE credit_wallet SET cents = cents - ${take} WHERE email = ${email}`;
      chargedCents += take;
    }
  }

  await db`
    INSERT INTO usage_meter (email, period_start, ctrl_seconds, dict_seconds, overage_charged_cents)
    VALUES (${email}, ${cur.period_start}, ${ctrl}, ${dict}, ${chargedCents})
    ON CONFLICT (email) DO UPDATE SET
      period_start = EXCLUDED.period_start, ctrl_seconds = EXCLUDED.ctrl_seconds,
      dict_seconds = EXCLUDED.dict_seconds, overage_charged_cents = EXCLUDED.overage_charged_cents`;
}

export async function walletCents(email: string): Promise<number> {
  const db = sql();
  const rows = await db<{ cents: number }[]>`SELECT cents FROM credit_wallet WHERE email = ${email}`;
  return rows[0]?.cents ?? 0;
}

/** Adds prepaid credit (from a top-up payment). */
export async function addCredit(email: string, cents: number) {
  const db = sql();
  await db`
    INSERT INTO credit_wallet (email, cents) VALUES (${email}, ${cents})
    ON CONFLICT (email) DO UPDATE SET cents = credit_wallet.cents + ${cents}`;
}

/** Credits a top-up exactly once (guarded by the Stripe session id). Returns
 *  false if this session was already processed. */
export async function creditTopup(sessionId: string, email: string, cents: number): Promise<boolean> {
  const db = sql();
  const rows = await db`
    INSERT INTO credit_topups (stripe_session, email, cents)
    VALUES (${sessionId}, ${email}, ${cents})
    ON CONFLICT (stripe_session) DO NOTHING
    RETURNING stripe_session`;
  if (rows.length === 0) return false;
  await addCredit(email, cents);
  return true;
}

/** The account's current metering week (zeroed if the stored period has lapsed). */
export async function currentMeter(
  email: string,
): Promise<{ ctrlSeconds: number; dictSeconds: number; overageChargedCents: number }> {
  const db = sql();
  const rows = await db<MeterRow[]>`SELECT * FROM usage_meter WHERE email = ${email}`;
  const r = rows[0];
  if (!r || Date.now() - new Date(r.period_start).getTime() >= PERIOD_MS) {
    return { ctrlSeconds: 0, dictSeconds: 0, overageChargedCents: 0 };
  }
  return {
    ctrlSeconds: r.ctrl_seconds,
    dictSeconds: r.dict_seconds,
    overageChargedCents: r.overage_charged_cents,
  };
}

export interface UsageSummary {
  devices: number;
  ctrl_cost: number;
  ctrl_hours: number;
  ctrl_perHour: number;
  dict_cost: number;
  dict_hours: number;
  dict_perHour: number;
}

/** Fleet-wide usage totals, optionally filtered by mode — the raw material for
 *  refining Cloud pricing against real utilization. */
export async function usageSummary(mode?: string): Promise<UsageSummary> {
  const db = sql();
  const rows = await db<Record<string, number>[]>`
    SELECT count(*)::int AS devices,
           coalesce(sum(ctrl_cost), 0) AS ctrl_cost,
           coalesce(sum(ctrl_seconds), 0) / 3600.0 AS ctrl_hours,
           coalesce(sum(dict_cost), 0) AS dict_cost,
           coalesce(sum(dict_seconds), 0) / 3600.0 AS dict_hours
      FROM usage_reports
     ${mode ? db`WHERE mode = ${mode}` : db``}`;
  const r = rows[0] ?? {};
  const ch = Number(r.ctrl_hours ?? 0), dh = Number(r.dict_hours ?? 0);
  const cc = Number(r.ctrl_cost ?? 0), dc = Number(r.dict_cost ?? 0);
  return {
    devices: Number(r.devices ?? 0),
    ctrl_cost: cc, ctrl_hours: ch, ctrl_perHour: ch > 0 ? cc / ch : 0,
    dict_cost: dc, dict_hours: dh, dict_perHour: dh > 0 ? dc / dh : 0,
  };
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
    SELECT key, email, plan, expires_at, seats, revoked, mode
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
  mode?: string;
  stripeSession: string;
  stripeCustomer: string | null;
  stripeSubscription: string | null;
}) {
  const db = sql();
  await db`
    INSERT INTO licences (key, email, plan, expires_at, seats, phones, sub_users,
                          resell, mode, stripe_session, stripe_customer, stripe_subscription)
    VALUES (${l.key}, ${l.email}, ${l.plan}, ${l.expiresAt}, ${l.seats}, ${l.phones},
            ${l.subUsers}, ${l.resell}, ${l.mode ?? "byok"}, ${l.stripeSession}, ${l.stripeCustomer},
            ${l.stripeSubscription})
    ON CONFLICT (stripe_session) DO NOTHING`;
}

/** Stripe retries webhooks; look up by session so a retry returns the first key. */
export async function licenceForSession(sessionId: string): Promise<Licence | null> {
  const db = sql();
  const rows = await db<Licence[]>`
    SELECT key, email, plan, expires_at, seats, revoked, mode
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
  stripe_subscription: string | null;
  mode: string;
  devices: number;
}

const LICENCE_COLUMNS = `
  l.key, l.email, l.plan, l.expires_at, l.seats, l.revoked, l.phones,
  l.sub_users, l.resell, l.parent_key, l.note, l.created_at, l.stripe_customer,
  l.stripe_subscription, l.mode,
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

/** How many lifetime accounts (Startup/Team/Reseller) have sold — drives founder
 *  pricing. Top-level only; sub-users a reseller issues don't count. */
export async function countLifetimeLicences(): Promise<number> {
  const db = sql();
  const rows = await db<{ n: number }[]>`
    SELECT count(*)::int AS n FROM licences
     WHERE plan IN ('startup', 'team', 'reseller') AND parent_key IS NULL`;
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

/**
 * Admin override of a licence's entitlements — the "set it to whatever I say"
 * escape hatch for support and comps. Sets all overridable fields at once (the
 * admin form always submits every one, pre-filled from the current row), so
 * there's no partial-update ambiguity. `expiresAt` null means perpetual.
 */
export async function overrideLicence(
  key: string,
  f: { plan: string; seats: number; subUsers: number; expiresAt: Date | null; resell: boolean; mode: string },
) {
  const db = sql();
  await db`
    UPDATE licences
       SET plan = ${f.plan}, seats = ${f.seats}, sub_users = ${f.subUsers},
           expires_at = ${f.expiresAt}, resell = ${f.resell}, mode = ${f.mode}
     WHERE key = ${key}`;
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
  mode?: string;
  parentKey: string | null;
  note: string | null;
}) {
  const db = sql();
  await db`
    INSERT INTO licences (key, email, plan, expires_at, seats, phones, sub_users,
                          resell, mode, parent_key, note)
    VALUES (${l.key}, ${l.email}, ${l.plan}, ${l.expiresAt}, ${l.seats}, ${l.phones},
            ${l.subUsers}, ${l.resell}, ${l.mode ?? "byok"}, ${l.parentKey}, ${l.note})`;
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
  /** Bring-your-own-key pricing (customer supplies their own AI keys). Blank/null
   *  means this plan isn't offered in BYOK mode. */
  price_id_byok: string | null;
  price_label_byok: string;
  period_byok: string;
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
    INSERT INTO plans (slug, name, tagline, price_id, price_label, period,
                       price_id_byok, price_label_byok, period_byok, features,
                       computers, phones, sub_users, resell, featured, visible, sort)
    VALUES (${p.slug}, ${p.name}, ${p.tagline}, ${p.price_id}, ${p.price_label},
            ${p.period}, ${p.price_id_byok}, ${p.price_label_byok}, ${p.period_byok},
            ${JSON.stringify(p.features)}, ${p.computers}, ${p.phones},
            ${p.sub_users}, ${p.resell}, ${p.featured}, ${p.visible}, ${p.sort})
    ON CONFLICT (slug) DO UPDATE SET
      name = EXCLUDED.name, tagline = EXCLUDED.tagline, price_id = EXCLUDED.price_id,
      price_label = EXCLUDED.price_label, period = EXCLUDED.period,
      price_id_byok = EXCLUDED.price_id_byok, price_label_byok = EXCLUDED.price_label_byok,
      period_byok = EXCLUDED.period_byok,
      features = EXCLUDED.features, computers = EXCLUDED.computers,
      phones = EXCLUDED.phones, sub_users = EXCLUDED.sub_users,
      resell = EXCLUDED.resell, featured = EXCLUDED.featured,
      visible = EXCLUDED.visible, sort = EXCLUDED.sort`;
}

export async function deletePlan(slug: string) {
  const db = sql();
  await db`DELETE FROM plans WHERE slug = ${slug}`;
}
