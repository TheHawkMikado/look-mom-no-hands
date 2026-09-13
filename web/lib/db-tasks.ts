import { sql } from "@/lib/db";
import { assertCloudWritable, capCloudText, type Residency } from "@/lib/residency";
import type { Tier } from "@/lib/tiers";
import { ensureRoutingSchema } from "@/lib/router";
import { ensureTeamSchemaSQL } from "@/lib/team";
import { ensureBrainSchema } from "@/lib/db-brain";
import { decryptSecret, encryptSecret } from "@/lib/crypto";
import { ensureSettingsSchema } from "@/lib/settings";
import { ensurePromptSchema } from "@/lib/prompts";
import { ensureIntegrationSchema } from "@/lib/integrations";
import { ensurePushSchema } from "@/lib/push";
import { ensureCallSchema } from "@/lib/db-calls";

/**
 * The chief-of-staff tables (SPEC.md §10): projects, tasks, approvals,
 * receipts, and the per-account Paperclip connection. All keyed by account
 * email like the rest of the schema. Every row carries `residency`, and every
 * insert goes through `assertCloudWritable` — see lib/residency.ts.
 */

export type OwnerKind = "agent" | "human" | "user";
export type TaskStatus =
  | "triaged" // extracted and tiered, no owner action yet
  | "dispatching" // owner=agent, waiting for the issue to be created (bridge or direct)
  | "in_progress" // issue exists, agent working
  | "awaiting_approval" // draft ready, tier ≥2, waiting on the user
  | "approved"
  | "denied"
  | "assigned" // owner=human, ticket sent
  | "needs_decision" // owner=user
  | "done"
  | "failed";
export type TaskSource = "text" | "voice" | "meeting";

export interface TaskRow {
  id: string;
  email: string;
  project_id: string | null;
  title: string;
  detail: string;
  capability: string;
  owner_kind: OwnerKind;
  owner_ref: string | null;
  owner_name: string | null;
  blast_tier: Tier;
  status: TaskStatus;
  confirmation: string;
  due_at: Date | null;
  check_in_at: Date | null;
  escalate_at: Date | null;
  paperclip_issue_id: string | null;
  paperclip_issue_key: string | null;
  result: string | null;
  closed_at: Date | null;
  /** Follow-up engine bookkeeping (§5.4): when the owner was last nudged and
   *  when the task was last brought to the user. Null = not yet. */
  nudged_at: Date | null;
  escalated_at: Date | null;
  /** How a human ticket went out ('email' | 'sms'); never the address. */
  deliver_channel: string | null;
  delivered_at: Date | null;
  source: TaskSource;
  residency: Residency;
  created_at: Date;
  updated_at: Date;
}

export interface ApprovalRow {
  id: string;
  task_id: string;
  email: string;
  tier: Tier;
  question: string;
  requested_at: Date;
  decided_at: Date | null;
  decision: "approve" | "deny" | null;
  decided_via: "voice" | "push" | "text" | null;
  speaker_verified: boolean;
  residency: Residency;
}

export interface ReceiptRow {
  id: string;
  task_id: string;
  email: string;
  actor: "model" | "agent" | "human" | "user" | "system";
  actor_ref: string | null;
  model_used: string | null;
  cost_cents: number;
  summary: string;
  ref: string | null;
  residency: Residency;
  created_at: Date;
}

export interface ProjectRow {
  id: string;
  email: string;
  title: string;
  budget_cap_cents: number;
  budget_spent_cents: number;
  status: string;
  residency: Residency;
  created_at: Date;
}

export interface PaperclipAgentRef {
  id: string;
  name: string;
  role: string;
  title: string | null;
  capabilities: string | null;
}

export interface PaperclipConnection {
  email: string;
  url: string;
  /** 'direct': this service can reach the URL. 'bridge': only the user's
   *  machine can (Paperclip on localhost); a bridge next to it polls us. */
  mode: "direct" | "bridge";
  company_id: string;
  agents: PaperclipAgentRef[];
  created_at: Date;
  last_seen_at: Date | null;
}

export async function ensureTaskSchema(db = sql()) {
  await db`
    CREATE TABLE IF NOT EXISTS projects (
      id                 text PRIMARY KEY,
      email              text NOT NULL,
      title              text NOT NULL,
      budget_cap_cents   integer NOT NULL DEFAULT 0,
      budget_spent_cents integer NOT NULL DEFAULT 0,
      status             text NOT NULL DEFAULT 'open',
      residency          text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      created_at         timestamptz NOT NULL DEFAULT now()
    )`;
  await db`CREATE INDEX IF NOT EXISTS projects_email_idx ON projects (email)`;

  await db`
    CREATE TABLE IF NOT EXISTS tasks (
      id                   text PRIMARY KEY,
      email                text NOT NULL,
      project_id           text REFERENCES projects(id) ON DELETE SET NULL,
      title                text NOT NULL,
      detail               text NOT NULL DEFAULT '',
      capability           text NOT NULL DEFAULT 'other',
      owner_kind           text NOT NULL CHECK (owner_kind IN ('agent','human','user')),
      owner_ref            text,
      owner_name           text,
      blast_tier           smallint NOT NULL CHECK (blast_tier BETWEEN 0 AND 4),
      status               text NOT NULL,
      confirmation         text NOT NULL DEFAULT '',
      due_at               timestamptz,
      check_in_at          timestamptz,
      escalate_at          timestamptz,
      paperclip_issue_id   text,
      paperclip_issue_key  text,
      result               text,
      source               text NOT NULL DEFAULT 'text' CHECK (source IN ('text','voice','meeting')),
      residency            text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      created_at           timestamptz NOT NULL DEFAULT now(),
      updated_at           timestamptz NOT NULL DEFAULT now()
    )`;
  await db`CREATE INDEX IF NOT EXISTS tasks_email_status_idx ON tasks (email, status, created_at DESC)`;
  // Set once the Paperclip issue has been closed out (done or denied) so the
  // sync loop and the bridge stop looking at it.
  await db`ALTER TABLE tasks ADD COLUMN IF NOT EXISTS closed_at timestamptz`;
  // Phase 3 (follow-up engine + human tickets). Channel only, never an address.
  await db`ALTER TABLE tasks ADD COLUMN IF NOT EXISTS nudged_at timestamptz`;
  await db`ALTER TABLE tasks ADD COLUMN IF NOT EXISTS escalated_at timestamptz`;
  await db`ALTER TABLE tasks ADD COLUMN IF NOT EXISTS deliver_channel text CHECK (deliver_channel IN ('email','sms'))`;
  await db`ALTER TABLE tasks ADD COLUMN IF NOT EXISTS delivered_at timestamptz`;
  await db`CREATE INDEX IF NOT EXISTS tasks_followup_idx ON tasks (email, check_in_at, escalate_at) WHERE closed_at IS NULL`;

  await db`
    CREATE TABLE IF NOT EXISTS task_approvals (
      id               text PRIMARY KEY,
      task_id          text NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
      email            text NOT NULL,
      tier             smallint NOT NULL CHECK (tier BETWEEN 0 AND 4),
      question         text NOT NULL DEFAULT '',
      requested_at     timestamptz NOT NULL DEFAULT now(),
      decided_at       timestamptz,
      decision         text CHECK (decision IN ('approve','deny')),
      decided_via      text CHECK (decided_via IN ('voice','push','text')),
      speaker_verified boolean NOT NULL DEFAULT false,
      residency        text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud'))
    )`;
  await db`CREATE INDEX IF NOT EXISTS task_approvals_task_idx ON task_approvals (task_id)`;
  await db`CREATE INDEX IF NOT EXISTS task_approvals_open_idx ON task_approvals (email) WHERE decided_at IS NULL`;

  await db`
    CREATE TABLE IF NOT EXISTS receipts (
      id          text PRIMARY KEY,
      task_id     text NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
      email       text NOT NULL,
      actor       text NOT NULL CHECK (actor IN ('model','agent','human','user','system')),
      actor_ref   text,
      model_used  text,
      cost_cents  integer NOT NULL DEFAULT 0,
      summary     text NOT NULL,
      ref         text,
      residency   text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      created_at  timestamptz NOT NULL DEFAULT now()
    )`;
  await db`CREATE INDEX IF NOT EXISTS receipts_task_idx ON receipts (task_id, created_at)`;

  await db`
    CREATE TABLE IF NOT EXISTS paperclip_connections (
      email        text PRIMARY KEY,
      url          text NOT NULL,
      mode         text NOT NULL DEFAULT 'direct' CHECK (mode IN ('direct','bridge')),
      api_key_enc  text,
      company_id   text NOT NULL,
      agents       jsonb NOT NULL DEFAULT '[]',
      created_at   timestamptz NOT NULL DEFAULT now(),
      last_seen_at timestamptz
    )`;

  await ensureRoutingSchema(db);
  await ensureTeamSchemaSQL(db);
  // Phase 3: settings, prompts, integrations, push tokens, calls.
  await ensureSettingsSchema(db);
  await ensurePromptSchema(db);
  await ensureIntegrationSchema(db);
  await ensurePushSchema(db);
  await ensureCallSchema(db);
  // Phase 4–5: eval runs, shared brain, promotion queue, ad-process steps.
  await ensureBrainSchema(db);
}

const norm = (email: string) => email.trim().toLowerCase();

// MARK: - Projects

export async function createProject(
  email: string,
  title: string,
  budgetCapCents = 0,
): Promise<ProjectRow> {
  const db = sql();
  const row = assertCloudWritable({
    kind: "project",
    residency: "cloud" as const,
    id: crypto.randomUUID(),
    email: norm(email),
    title: capCloudText(title, 200),
    budget_cap_cents: budgetCapCents,
  });
  const [out] = await db<ProjectRow[]>`
    INSERT INTO projects (id, email, title, budget_cap_cents, residency)
    VALUES (${row.id}, ${row.email}, ${row.title}, ${row.budget_cap_cents}, ${row.residency})
    RETURNING *`;
  return out;
}

// MARK: - Tasks

export interface NewTask {
  title: string;
  detail: string;
  capability: string;
  owner_kind: OwnerKind;
  owner_ref: string | null;
  owner_name: string | null;
  blast_tier: Tier;
  status: TaskStatus;
  confirmation: string;
  source: TaskSource;
  project_id?: string | null;
  due_at?: Date | null;
  check_in_at?: Date | null;
  escalate_at?: Date | null;
  deliver_channel?: "email" | "sms" | null;
}

export async function insertTask(email: string, t: NewTask): Promise<TaskRow> {
  const db = sql();
  const row = assertCloudWritable({
    kind: "task",
    residency: "cloud" as const,
    id: crypto.randomUUID(),
    email: norm(email),
    ...t,
    title: capCloudText(t.title, 200),
    detail: capCloudText(t.detail),
    confirmation: capCloudText(t.confirmation, 300),
  });
  const [out] = await db<TaskRow[]>`
    INSERT INTO tasks (id, email, project_id, title, detail, capability, owner_kind, owner_ref, owner_name,
                       blast_tier, status, confirmation, due_at, check_in_at, escalate_at, deliver_channel, source, residency)
    VALUES (${row.id}, ${row.email}, ${row.project_id ?? null}, ${row.title}, ${row.detail}, ${row.capability},
            ${row.owner_kind}, ${row.owner_ref}, ${row.owner_name}, ${row.blast_tier}, ${row.status},
            ${row.confirmation}, ${row.due_at ?? null}, ${row.check_in_at ?? null}, ${row.escalate_at ?? null},
            ${row.deliver_channel ?? null}, ${row.source}, ${row.residency})
    RETURNING *`;
  return out;
}

export async function getTask(email: string, id: string): Promise<TaskRow | null> {
  const db = sql();
  const rows = await db<TaskRow[]>`SELECT * FROM tasks WHERE email = ${norm(email)} AND id = ${id}`;
  return rows[0] ?? null;
}

export async function listTasks(
  email: string,
  opts: { status?: TaskStatus[]; limit?: number } = {},
): Promise<TaskRow[]> {
  const db = sql();
  const limit = Math.min(200, opts.limit ?? 50);
  if (opts.status && opts.status.length > 0) {
    return db<TaskRow[]>`
      SELECT * FROM tasks WHERE email = ${norm(email)} AND status = ANY(${opts.status})
       ORDER BY created_at DESC LIMIT ${limit}`;
  }
  return db<TaskRow[]>`
    SELECT * FROM tasks WHERE email = ${norm(email)} ORDER BY created_at DESC LIMIT ${limit}`;
}

/** Tasks whose next step lives outside this service: agent tasks that are
 *  being created or are running in Paperclip. Both the sync loop (direct) and
 *  the bridge (localhost Paperclip) work this list. */
export async function openAgentTasks(email: string): Promise<TaskRow[]> {
  const db = sql();
  return db<TaskRow[]>`
    SELECT * FROM tasks
     WHERE email = ${norm(email)} AND owner_kind = 'agent'
       AND status IN ('dispatching','in_progress','approved','denied')
       AND closed_at IS NULL
     ORDER BY created_at ASC LIMIT 50`;
}

/** Statuses that still have a next step somewhere — the follow-up engine's
 *  definition of "outstanding". */
export const OPEN_STATUSES: readonly TaskStatus[] = [
  "triaged", "dispatching", "in_progress", "awaiting_approval", "approved", "assigned", "needs_decision",
];

/** Open tasks whose clock has run: past check-in and not yet nudged, or past
 *  escalation and not yet escalated. Both clocks are read here so the engine
 *  makes one query per account. */
export async function tasksDueForFollowup(email: string, now = new Date()): Promise<TaskRow[]> {
  const db = sql();
  return db<TaskRow[]>`
    SELECT * FROM tasks
     WHERE email = ${norm(email)} AND closed_at IS NULL AND status = ANY(${[...OPEN_STATUSES]})
       AND ((check_in_at IS NOT NULL AND check_in_at <= ${now} AND nudged_at IS NULL)
         OR (escalate_at IS NOT NULL AND escalate_at <= ${now} AND escalated_at IS NULL))
     ORDER BY COALESCE(due_at, escalate_at) ASC LIMIT 100`;
}

/** Everything still open, soonest due first — the daily brief and "what's
 *  outstanding" read this. */
export async function outstandingTasks(email: string): Promise<TaskRow[]> {
  const db = sql();
  return db<TaskRow[]>`
    SELECT * FROM tasks
     WHERE email = ${norm(email)} AND closed_at IS NULL AND status = ANY(${[...OPEN_STATUSES]})
     ORDER BY due_at ASC NULLS LAST, created_at ASC LIMIT 200`;
}

export async function updateTask(
  email: string,
  id: string,
  patch: Partial<Pick<TaskRow,
    | "status" | "paperclip_issue_id" | "paperclip_issue_key" | "result" | "owner_kind" | "owner_ref" | "owner_name"
    | "blast_tier" | "confirmation" | "closed_at" | "due_at" | "check_in_at" | "escalate_at" | "nudged_at" | "escalated_at"
    | "deliver_channel" | "delivered_at">>,
): Promise<TaskRow | null> {
  const db = sql();
  const clean = assertCloudWritable({
    kind: "task",
    residency: "cloud" as const,
    ...patch,
    result: patch.result == null ? patch.result : capCloudText(patch.result),
  });
  const { kind: _k, residency: _r, ...fields } = clean;
  const cols = Object.keys(fields).filter((k) => (fields as Record<string, unknown>)[k] !== undefined);
  if (cols.length === 0) return getTask(email, id);
  const rows = await db<TaskRow[]>`
    UPDATE tasks SET ${db(fields as Record<string, unknown>, ...(cols as never[]))}, updated_at = now()
     WHERE email = ${norm(email)} AND id = ${id}
    RETURNING *`;
  return rows[0] ?? null;
}

// MARK: - Approvals

export async function insertApproval(
  email: string,
  taskId: string,
  tier: Tier,
  question: string,
): Promise<ApprovalRow> {
  const db = sql();
  const row = assertCloudWritable({
    kind: "approval",
    residency: "cloud" as const,
    id: crypto.randomUUID(),
    email: norm(email),
    task_id: taskId,
    tier,
    question: capCloudText(question, 500),
  });
  const [out] = await db<ApprovalRow[]>`
    INSERT INTO task_approvals (id, task_id, email, tier, question, residency)
    VALUES (${row.id}, ${row.task_id}, ${row.email}, ${row.tier}, ${row.question}, ${row.residency})
    RETURNING *`;
  return out;
}

export async function openApprovals(email: string): Promise<ApprovalRow[]> {
  const db = sql();
  return db<ApprovalRow[]>`
    SELECT * FROM task_approvals WHERE email = ${norm(email)} AND decided_at IS NULL
     ORDER BY requested_at ASC`;
}

export async function approvalsForTask(taskId: string): Promise<ApprovalRow[]> {
  const db = sql();
  return db<ApprovalRow[]>`SELECT * FROM task_approvals WHERE task_id = ${taskId} ORDER BY requested_at ASC`;
}

/** Records the decision. First decision wins, like agent_approvals. */
export async function decideTaskApproval(
  email: string,
  approvalId: string,
  decision: "approve" | "deny",
  via: "voice" | "push" | "text",
  speakerVerified: boolean,
): Promise<ApprovalRow | null> {
  const db = sql();
  const rows = await db<ApprovalRow[]>`
    UPDATE task_approvals
       SET decision = ${decision}, decided_via = ${via}, speaker_verified = ${speakerVerified}, decided_at = now()
     WHERE email = ${norm(email)} AND id = ${approvalId} AND decided_at IS NULL
    RETURNING *`;
  return rows[0] ?? null;
}

// MARK: - Receipts

export async function insertReceipt(
  email: string,
  r: {
    task_id: string;
    actor: ReceiptRow["actor"];
    actor_ref?: string | null;
    model_used?: string | null;
    cost_cents?: number;
    summary: string;
    ref?: string | null;
  },
): Promise<ReceiptRow> {
  const db = sql();
  const row = assertCloudWritable({
    kind: "receipt",
    residency: "cloud" as const,
    id: crypto.randomUUID(),
    email: norm(email),
    task_id: r.task_id,
    actor: r.actor,
    actor_ref: r.actor_ref ?? null,
    model_used: r.model_used ?? null,
    cost_cents: r.cost_cents ?? 0,
    summary: capCloudText(r.summary, 500),
    ref: r.ref ?? null,
  });
  const [out] = await db<ReceiptRow[]>`
    INSERT INTO receipts (id, task_id, email, actor, actor_ref, model_used, cost_cents, summary, ref, residency)
    VALUES (${row.id}, ${row.task_id}, ${row.email}, ${row.actor}, ${row.actor_ref}, ${row.model_used},
            ${row.cost_cents}, ${row.summary}, ${row.ref}, ${row.residency})
    RETURNING *`;
  return out;
}

export async function receiptsForTask(taskId: string): Promise<ReceiptRow[]> {
  const db = sql();
  return db<ReceiptRow[]>`SELECT * FROM receipts WHERE task_id = ${taskId} ORDER BY created_at ASC`;
}

// MARK: - Paperclip connection

export async function setPaperclipConnection(
  email: string,
  c: { url: string; mode: "direct" | "bridge"; apiKey: string | null; companyId: string; agents: PaperclipAgentRef[] },
): Promise<void> {
  const db = sql();
  const enc = c.apiKey ? encryptSecret(c.apiKey) : null;
  await db`
    INSERT INTO paperclip_connections (email, url, mode, api_key_enc, company_id, agents, last_seen_at)
    VALUES (${norm(email)}, ${c.url}, ${c.mode}, ${enc}, ${c.companyId}, ${JSON.stringify(c.agents)}, now())
    ON CONFLICT (email) DO UPDATE SET
      url = EXCLUDED.url, mode = EXCLUDED.mode, api_key_enc = EXCLUDED.api_key_enc,
      company_id = EXCLUDED.company_id, agents = EXCLUDED.agents, last_seen_at = now()`;
}

export async function updatePaperclipAgents(email: string, agents: PaperclipAgentRef[]) {
  const db = sql();
  await db`
    UPDATE paperclip_connections SET agents = ${JSON.stringify(agents)}, last_seen_at = now()
     WHERE email = ${norm(email)}`;
}

export async function getPaperclipConnection(
  email: string,
): Promise<(PaperclipConnection & { apiKey: string | null }) | null> {
  const db = sql();
  const rows = await db<(PaperclipConnection & { api_key_enc: string | null })[]>`
    SELECT * FROM paperclip_connections WHERE email = ${norm(email)}`;
  const r = rows[0];
  if (!r) return null;
  const agents = typeof r.agents === "string" ? (JSON.parse(r.agents) as PaperclipAgentRef[]) : r.agents;
  return { ...r, agents, apiKey: r.api_key_enc ? decryptSecret(r.api_key_enc) : null };
}

/** Deleting the connection is how the user opts out of the cloud brain. Tasks
 *  already delegated keep their issue ids for the audit trail but stop syncing. */
export async function deletePaperclipConnection(email: string): Promise<boolean> {
  const db = sql();
  const rows = await db`DELETE FROM paperclip_connections WHERE email = ${norm(email)} RETURNING email`;
  return rows.length > 0;
}
