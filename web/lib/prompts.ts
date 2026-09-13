import { sql } from "@/lib/db";
import { assertCloudWritable, capCloudText } from "@/lib/residency";

/**
 * Prompts: the questions the bot wants to ask the user by voice when there
 * is a good moment (SPEC.md §3.2 — the bot initiates, the human answers).
 * Each is one question with a default, so "yes" or silence is a valid
 * answer. The Mac polls the unspoken ones, speaks them when idle, and posts
 * the answer back; the phone gets the same question as a push.
 *
 * Kinds: `escalation` (a task blew past escalate_at), `deliver_reminder`
 * (a human ticket needs a nudge — the Mac supplies the address, we never
 * hold it), `daily_brief` (what's outstanding), `promotion` (Phase 4: may a
 * generic learning move to the Shared Brain).
 */

export type PromptKind = "escalation" | "daily_brief" | "promotion" | "deliver_reminder";
export const PROMPT_KINDS: readonly PromptKind[] = ["escalation", "daily_brief", "promotion", "deliver_reminder"];

export interface PromptRow {
  id: string;
  email: string;
  task_id: string | null;
  kind: PromptKind;
  question: string;
  default_answer: string;
  /** Set when created inside quiet hours: don't speak before this. */
  not_before: Date | null;
  spoken_at: Date | null;
  answered_at: Date | null;
  answer: string | null;
  residency: "cloud";
  created_at: Date;
}

export async function ensurePromptSchema(db = sql()) {
  await db`
    CREATE TABLE IF NOT EXISTS prompts (
      id             text PRIMARY KEY,
      email          text NOT NULL,
      task_id        text REFERENCES tasks(id) ON DELETE CASCADE,
      kind           text NOT NULL CHECK (kind IN ('escalation','daily_brief','promotion','deliver_reminder')),
      question       text NOT NULL,
      default_answer text NOT NULL DEFAULT '',
      not_before     timestamptz,
      spoken_at      timestamptz,
      answered_at    timestamptz,
      answer         text,
      residency      text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      created_at     timestamptz NOT NULL DEFAULT now()
    )`;
  await db`CREATE INDEX IF NOT EXISTS prompts_open_idx ON prompts (email, created_at) WHERE answered_at IS NULL`;
}

const norm = (email: string) => email.trim().toLowerCase();

export async function insertPrompt(
  email: string,
  p: { task_id: string | null; kind: PromptKind; question: string; default_answer: string; not_before?: Date | null },
): Promise<PromptRow> {
  const row = assertCloudWritable({
    kind: "prompt",
    residency: "cloud" as const,
    id: crypto.randomUUID(),
    email: norm(email),
    task_id: p.task_id,
    prompt_kind: p.kind,
    question: capCloudText(p.question, 500),
    default_answer: capCloudText(p.default_answer, 100),
    not_before: p.not_before ?? null,
  });
  const [out] = await sql()<PromptRow[]>`
    INSERT INTO prompts (id, email, task_id, kind, question, default_answer, not_before, residency)
    VALUES (${row.id}, ${row.email}, ${row.task_id}, ${row.prompt_kind}, ${row.question}, ${row.default_answer}, ${row.not_before}, ${row.residency})
    RETURNING *`;
  return out;
}

/** Unanswered prompts whose moment has come, oldest first. `spoken_at` is
 *  informational: a prompt the Mac spoke but nobody answered is still open. */
export async function openPrompts(email: string, now = new Date()): Promise<PromptRow[]> {
  return sql()<PromptRow[]>`
    SELECT * FROM prompts
     WHERE email = ${norm(email)} AND answered_at IS NULL
       AND (not_before IS NULL OR not_before <= ${now})
     ORDER BY created_at ASC LIMIT 50`;
}

/** An open prompt of this kind already exists for the task — don't ask twice. */
export async function openPromptFor(email: string, taskId: string, kind: PromptKind): Promise<PromptRow | null> {
  const rows = await sql()<PromptRow[]>`
    SELECT * FROM prompts WHERE email = ${norm(email)} AND task_id = ${taskId} AND kind = ${kind} AND answered_at IS NULL
     ORDER BY created_at DESC LIMIT 1`;
  return rows[0] ?? null;
}

export async function getPrompt(email: string, id: string): Promise<PromptRow | null> {
  const rows = await sql()<PromptRow[]>`SELECT * FROM prompts WHERE email = ${norm(email)} AND id = ${id}`;
  return rows[0] ?? null;
}

export async function markSpoken(email: string, ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  await sql()`UPDATE prompts SET spoken_at = now() WHERE email = ${norm(email)} AND id = ANY(${ids}) AND spoken_at IS NULL`;
}

/** Records the answer. First answer wins, like approvals. */
export async function recordAnswer(email: string, id: string, answer: string): Promise<PromptRow | null> {
  const rows = await sql()<PromptRow[]>`
    UPDATE prompts SET answer = ${capCloudText(answer, 500)}, answered_at = now()
     WHERE email = ${norm(email)} AND id = ${id} AND answered_at IS NULL
    RETURNING *`;
  return rows[0] ?? null;
}

/** Closing a task closes its open prompts: nothing to ask any more. */
export async function closePromptsForTask(email: string, taskId: string, answer = "(task closed)"): Promise<number> {
  const rows = await sql()`
    UPDATE prompts SET answer = ${answer}, answered_at = now()
     WHERE email = ${norm(email)} AND task_id = ${taskId} AND answered_at IS NULL RETURNING id`;
  return rows.length;
}
