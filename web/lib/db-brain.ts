import { sql } from "@/lib/db";

/**
 * Phase 4–5 tables (SPEC.md §7, §8.2–8.3, §9 Phase 5): eval runs for the
 * router, the Shared Brain (published SOPs) and its promotion queue, and the
 * step issues of a No Hands project. Called from `ensureTaskSchema` (lib/
 * db-tasks.ts) so every entry point that runs `ensureSchema()` gets them.
 *
 * Residency: everything here is `cloud` by construction. Promotion
 * candidates are scrubbed before they are written (lib/brain.ts) and the
 * queue row never carries the raw text; shared SOPs carry a source hash, not
 * an email.
 */
let ready: Promise<void> | null = null;

/** Idempotent and cheap; the Phase 4–5 modules call it themselves so they
 *  work before (and after) `ensureTaskSchema` is wired to call it. */
export function ensureBrainSchema(db = sql()): Promise<void> {
  ready ??= createBrainTables(db).catch((e) => {
    ready = null;
    throw e;
  });
  return ready;
}

async function createBrainTables(db: ReturnType<typeof sql>) {
  // One row per (task_type, model) per eval run — the audit trail behind a
  // routing_scores.score. `status`: scored | skipped (no key) | unrunnable
  // (a local candidate with no engine) | failed (provider error).
  await db`
    CREATE TABLE IF NOT EXISTS eval_runs (
      id           text PRIMARY KEY,
      task_type    text NOT NULL,
      model        text NOT NULL,
      provider     text NOT NULL,
      status       text NOT NULL CHECK (status IN ('scored','skipped','unrunnable','failed')),
      score        double precision,
      cases        integer NOT NULL DEFAULT 0,
      passed       integer NOT NULL DEFAULT 0,
      cost_per_1k  double precision,
      latency_p50  integer,
      detail       jsonb NOT NULL DEFAULT '{}',
      ran_at       timestamptz NOT NULL DEFAULT now()
    )`;
  await db`CREATE INDEX IF NOT EXISTS eval_runs_type_idx ON eval_runs (task_type, model, ran_at DESC)`;

  // Shared Brain (§8.2): generic SOPs, versioned, attributable to a source
  // user only by hash. Never an email, never unscrubbed text.
  await db`
    CREATE TABLE IF NOT EXISTS shared_sops (
      id               text PRIMARY KEY,
      title            text NOT NULL,
      body             text NOT NULL,
      version          integer NOT NULL DEFAULT 1,
      source_user_hash text NOT NULL,
      published_at     timestamptz NOT NULL DEFAULT now(),
      residency        text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud'))
    )`;
  await db`CREATE INDEX IF NOT EXISTS shared_sops_title_idx ON shared_sops (title, version DESC)`;

  // Promotion pipeline (§8.3): classifier → scrubber → consent (default no)
  // → review → publish. `candidate` is the scrubbed candidate only.
  await db`
    CREATE TABLE IF NOT EXISTS promotion_queue (
      id           text PRIMARY KEY,
      email        text NOT NULL,
      candidate    jsonb NOT NULL,
      status       text NOT NULL DEFAULT 'pending_consent'
                   CHECK (status IN ('pending_consent','awaiting_review','approved','rejected','published')),
      consent_at   timestamptz,
      reviewed_at  timestamptz,
      sop_id       text,
      residency    text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      created_at   timestamptz NOT NULL DEFAULT now()
    )`;
  await db`CREATE INDEX IF NOT EXISTS promotion_queue_email_idx ON promotion_queue (email, status, created_at DESC)`;

  // Phase 5: the steps of a No Hands project (the ad process) and the
  // Paperclip issue each became. Titles and statuses only.
  await db`
    CREATE TABLE IF NOT EXISTS project_steps (
      id                  text PRIMARY KEY,
      project_id          text NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      email               text NOT NULL,
      step_no             integer NOT NULL,
      title               text NOT NULL,
      blast_tier          integer NOT NULL DEFAULT 0,
      assignee_agent_id   text,
      paperclip_issue_id  text,
      paperclip_issue_key text,
      status              text NOT NULL DEFAULT 'planned',
      residency           text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      created_at          timestamptz NOT NULL DEFAULT now(),
      UNIQUE (project_id, step_no)
    )`;
  // The Paperclip-side project the steps live in, when direct mode created one.
  await db`ALTER TABLE projects ADD COLUMN IF NOT EXISTS paperclip_project_id text`;
  await db`ALTER TABLE projects ADD COLUMN IF NOT EXISTS task_id text`;
  await db`ALTER TABLE projects ADD COLUMN IF NOT EXISTS budget_warned_at timestamptz`;
}
