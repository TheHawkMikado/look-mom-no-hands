import { sql } from "@/lib/db";
import { assertCloudWritable, capCloudText, type Residency } from "@/lib/residency";
import type { CallOutcome } from "@/lib/vapi";

/**
 * The `calls` table (SPEC.md §5.5): one row per outbound call, holding the
 * provider's call id, the status, and — once the call ends — the structured
 * outcome and cost. Never the number dialled, never a transcript, never a
 * recording (§4.3): the outcome is a two-sentence summary plus a few typed
 * fields, which is what a receipt needs.
 */

export type CallStatus = "queued" | "ringing" | "in_progress" | "ended" | "failed";

export interface CallRow {
  id: string;
  email: string;
  task_id: string | null;
  provider: string;
  provider_call_id: string | null;
  status: CallStatus;
  /** What the call was for — the goal in one line, for the receipt. */
  goal: string;
  tier: number;
  outcome: CallOutcome | null;
  cost_cents: number;
  residency: Residency;
  created_at: Date;
  ended_at: Date | null;
}

export async function ensureCallSchema(db = sql()) {
  await db`
    CREATE TABLE IF NOT EXISTS calls (
      id               text PRIMARY KEY,
      email            text NOT NULL,
      task_id          text REFERENCES tasks(id) ON DELETE SET NULL,
      provider         text NOT NULL,
      provider_call_id text,
      status           text NOT NULL CHECK (status IN ('queued','ringing','in_progress','ended','failed')),
      goal             text NOT NULL DEFAULT '',
      tier             smallint NOT NULL DEFAULT 0 CHECK (tier BETWEEN 0 AND 4),
      outcome          jsonb,
      cost_cents       integer NOT NULL DEFAULT 0,
      residency        text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      created_at       timestamptz NOT NULL DEFAULT now(),
      ended_at         timestamptz
    )`;
  await db`CREATE INDEX IF NOT EXISTS calls_provider_idx ON calls (provider, provider_call_id)`;
  await db`CREATE INDEX IF NOT EXISTS calls_email_idx ON calls (email, created_at DESC)`;
}

const norm = (email: string) => email.trim().toLowerCase();

export async function insertCall(
  email: string,
  c: { task_id: string | null; provider: string; provider_call_id: string | null; status: CallStatus; goal: string; tier: number },
): Promise<CallRow> {
  const row = assertCloudWritable({
    kind: "call",
    residency: "cloud" as const,
    id: crypto.randomUUID(),
    email: norm(email),
    ...c,
    goal: capCloudText(c.goal, 300),
  });
  const [out] = await sql()<CallRow[]>`
    INSERT INTO calls (id, email, task_id, provider, provider_call_id, status, goal, tier, residency)
    VALUES (${row.id}, ${row.email}, ${row.task_id}, ${row.provider}, ${row.provider_call_id}, ${row.status}, ${row.goal}, ${row.tier}, ${row.residency})
    RETURNING *`;
  return out;
}

export async function getCall(email: string, id: string): Promise<CallRow | null> {
  const rows = await sql()<CallRow[]>`SELECT * FROM calls WHERE email = ${norm(email)} AND id = ${id}`;
  return rows[0] ? parse(rows[0]) : null;
}

export async function callByProviderId(provider: string, providerCallId: string): Promise<CallRow | null> {
  const rows = await sql()<CallRow[]>`SELECT * FROM calls WHERE provider = ${provider} AND provider_call_id = ${providerCallId}`;
  return rows[0] ? parse(rows[0]) : null;
}

export async function listCalls(email: string, limit = 50): Promise<CallRow[]> {
  const rows = await sql()<CallRow[]>`SELECT * FROM calls WHERE email = ${norm(email)} ORDER BY created_at DESC LIMIT ${Math.min(200, limit)}`;
  return rows.map(parse);
}

export async function updateCall(
  id: string,
  patch: Partial<Pick<CallRow, "provider_call_id" | "status" | "outcome" | "cost_cents" | "ended_at">>,
): Promise<CallRow | null> {
  const clean = assertCloudWritable({
    kind: "call",
    residency: "cloud" as const,
    ...patch,
    outcome: patch.outcome === undefined ? undefined : patch.outcome === null ? null : { ...patch.outcome, summary: capCloudText(patch.outcome.summary, 500) },
  });
  const { kind: _k, residency: _r, ...fields } = clean;
  const f = fields as Record<string, unknown>;
  if (f.outcome && typeof f.outcome === "object") f.outcome = JSON.stringify(f.outcome);
  const cols = Object.keys(f).filter((k) => f[k] !== undefined);
  if (cols.length === 0) return null;
  const db = sql();
  const rows = await db<CallRow[]>`UPDATE calls SET ${db(f, ...(cols as never[]))} WHERE id = ${id} RETURNING *`;
  return rows[0] ? parse(rows[0]) : null;
}

function parse(r: CallRow): CallRow {
  return { ...r, outcome: typeof r.outcome === "string" ? (JSON.parse(r.outcome) as CallOutcome) : r.outcome };
}
