import { approvalVerdictsFor } from "@/lib/db";
import {
  getPaperclipConnection,
  getTask,
  insertReceipt,
  insertTask,
  openAgentTasks,
  openApprovals,
  updateTask,
  type PaperclipConnection,
  type TaskRow,
  type TaskStatus,
} from "@/lib/db-tasks";
import { extractTask, type Extraction } from "@/lib/extract";
import { applyVerdict, gateNotify, requestApproval } from "@/lib/gate";
import { ISSUE_DELIVERED, ISSUE_FAILED, latestAgentComment, PaperclipClient } from "@/lib/paperclip";
import { triage } from "@/lib/triage";

/**
 * The task pipeline: intake → extract → triage → dispatch → (agent works) →
 * draft → gate → verdict → finish. The state machine lives here and is driven
 * by *observations* of Paperclip, which arrive one of two ways:
 *
 *  - direct mode: this service calls Paperclip itself (`syncAccount`);
 *  - bridge mode: Paperclip is on the user's machine, so a bridge next to it
 *    fetches `bridgeWork`, does the calls, and posts observations back.
 *
 * Either way the same `advance()` moves the task, so there is exactly one
 * place where "the draft is ready" or "the issue failed" is decided.
 */

export interface IntakeResult {
  intent: Extraction["intent"];
  task: TaskRow | null;
  confirmation: string;
  extraction: Extraction;
}

export async function intake(
  email: string,
  text: string,
  source: "text" | "voice" | "meeting" = "text",
): Promise<IntakeResult> {
  const x = await extractTask(email, text);

  // Not every utterance becomes a cloud task. Questions are answered from the
  // brain (Phase 1); notes and decisions are Local Brain content and MUST NOT
  // be stored here (SPEC.md §4.3). The Mac keeps them; we only say so.
  if (x.intent !== "task") {
    const confirmation =
      x.intent === "question" ? "That's a question — I'll answer from your brain once Phase 1 lands."
      : x.intent === "note" ? "Noted. That stays on your Mac."
      : x.intent === "decision" ? "Recorded as a decision, on your Mac."
      : "Got it.";
    return { intent: x.intent, task: null, confirmation, extraction: x };
  }

  const conn = await getPaperclipConnection(email);
  const t = triage(x, conn?.agents ?? [], !!conn);
  const status: TaskStatus =
    t.owner_kind === "agent" ? "dispatching" : t.owner_kind === "human" ? "assigned" : "needs_decision";

  const task = await insertTask(email, {
    title: x.title,
    detail: x.detail,
    capability: x.capability,
    owner_kind: t.owner_kind,
    owner_ref: t.owner_ref,
    owner_name: t.owner_name,
    blast_tier: x.blast_tier,
    status,
    confirmation: t.confirmation,
    source,
  });
  await insertReceipt(email, {
    task_id: task.id,
    actor: "model",
    model_used: x.model_used ?? "rules",
    summary: `Extracted from ${source}: "${x.title}" (tier ${x.blast_tier}, ${x.capability}).`,
  });
  await insertReceipt(email, {
    task_id: task.id,
    actor: "system",
    summary: `Triaged to ${t.owner_kind}${t.owner_name ? ` (${t.owner_name})` : ""}: ${t.reason}.`,
  });

  if (t.owner_kind === "user") {
    await gateNotify(email, `${task.id}:decision`, "goal_progress", task.title, t.confirmation, null);
  }

  // Direct mode: delegate right now. Bridge mode: the bridge picks it up on
  // its next poll (a few seconds). Neither delays the confirmation the user
  // hears — that was decided before this point.
  let out = task;
  if (t.owner_kind === "agent" && conn && conn.mode === "direct") {
    out = (await dispatchDirect(conn, task)) ?? task;
  }
  return { intent: x.intent, task: out, confirmation: t.confirmation, extraction: x };
}

// MARK: - Observations and the state machine

export interface Observation {
  task_id: string;
  /** The issue this task was delegated as (present once created). */
  issue?: { id: string; identifier: string | null; status: string } | null;
  /** The agent's newest comment body, if any. */
  draft?: string | null;
  /** Set when the outside call failed. */
  error?: string | null;
  /** Set by the bridge after it closed the issue out. */
  closed?: boolean;
}

/** Move one task according to what was observed. Safe to call repeatedly. */
export async function advance(email: string, obs: Observation): Promise<TaskRow | null> {
  const task = await getTask(email, obs.task_id);
  if (!task) return null;

  if (obs.error) {
    await insertReceipt(email, { task_id: task.id, actor: "system", summary: `Paperclip error: ${obs.error}` });
    // A transient error on a dispatching task is retried next round; a failed
    // issue is terminal.
    return task;
  }

  switch (task.status) {
    case "dispatching": {
      if (!obs.issue) return task;
      const next = await updateTask(email, task.id, {
        status: "in_progress",
        paperclip_issue_id: obs.issue.id,
        paperclip_issue_key: obs.issue.identifier,
      });
      await insertReceipt(email, {
        task_id: task.id,
        actor: "agent",
        actor_ref: task.owner_ref,
        summary: `Delegated to ${task.owner_name ?? "agent"} as ${obs.issue.identifier ?? obs.issue.id}.`,
        ref: obs.issue.id,
      });
      await gateNotify(email, `${task.id}:started`, "goal_started", task.title, `${task.owner_name ?? "Agent"} is on it.`, null);
      return next;
    }
    case "in_progress": {
      if (obs.issue && ISSUE_FAILED.has(obs.issue.status)) {
        await insertReceipt(email, { task_id: task.id, actor: "agent", actor_ref: task.owner_ref, summary: `Issue ${obs.issue.status}.` });
        await gateNotify(email, `${task.id}:failed`, "goal_failed", task.title, `The agent could not finish (${obs.issue.status}).`, null);
        return updateTask(email, task.id, { status: "failed", closed_at: new Date() });
      }
      const delivered = !!obs.draft || (obs.issue ? ISSUE_DELIVERED.has(obs.issue.status) : false);
      if (!delivered) return task;
      const withResult = (await updateTask(email, task.id, { result: obs.draft ?? "(no draft text)" })) ?? task;
      await insertReceipt(email, {
        task_id: task.id,
        actor: "agent",
        actor_ref: task.owner_ref,
        summary: `${task.owner_name ?? "Agent"} delivered a draft (${(obs.draft ?? "").length} chars).`,
      });
      const gate = await requestApproval(withResult, `Approve "${task.title}"?`);
      if (gate.allowed) return updateTask(email, task.id, { status: "approved" });
      return getTask(email, task.id);
    }
    case "approved":
    case "denied": {
      if (!obs.closed) return task;
      const done = task.status === "approved";
      await insertReceipt(email, {
        task_id: task.id,
        actor: "system",
        summary: done ? "Closed out in Paperclip as done." : "Closed out in Paperclip as denied.",
      });
      if (done) {
        await gateNotify(email, `${task.id}:done`, "goal_done", task.title, (task.result ?? "").slice(0, 500), null);
      }
      return updateTask(email, task.id, { status: done ? "done" : "denied", closed_at: new Date() });
    }
    default:
      return task;
  }
}

/** Verdicts the phone recorded through the existing approval cards, folded
 *  into task approvals. Shared by sync (direct) and the bridge poll. */
export async function absorbPhoneVerdicts(email: string): Promise<number> {
  const open = await openApprovals(email);
  if (open.length === 0) return 0;
  const verdicts = await approvalVerdictsFor(email, open.map((a) => a.id));
  let n = 0;
  for (const v of verdicts) {
    const a = open.find((o) => o.id === v.approval_id);
    if (!a) continue;
    const task = await getTask(email, a.task_id);
    if (!task) continue;
    const verdict = v.verdict === "approve" ? "approve" : "deny";
    if (await applyVerdict(task, a.id, verdict, "push", false)) n++;
  }
  return n;
}

// MARK: - Direct mode

function client(conn: PaperclipConnection & { apiKey: string | null }) {
  return new PaperclipClient({ url: conn.url, apiKey: conn.apiKey });
}

export function issueDescription(task: TaskRow): string {
  return [
    task.detail || task.title,
    "",
    "---",
    `No Hands task ${task.id}. Blast-radius tier ${task.blast_tier}.`,
    "When your work is ready, post it as a comment on this issue and set the issue to in_review.",
    task.blast_tier >= 2
      ? "Do NOT publish, send, or spend anything yourself — the owner approves that step."
      : "",
  ].join("\n");
}

async function dispatchDirect(conn: PaperclipConnection & { apiKey: string | null }, task: TaskRow): Promise<TaskRow | null> {
  try {
    const issue = await client(conn).createIssue(conn.company_id, {
      title: task.title,
      description: issueDescription(task),
      status: "todo",
      priority: "medium",
      assigneeAgentId: task.owner_ref,
    });
    return advance(task.email, { task_id: task.id, issue: { id: issue.id, identifier: issue.identifier, status: issue.status } });
  } catch (e) {
    return advance(task.email, { task_id: task.id, error: e instanceof Error ? e.message : String(e) });
  }
}

/** One sync round for an account in direct mode. Returns tasks touched. */
export async function syncAccount(email: string): Promise<{ touched: number; mode: string | null }> {
  const conn = await getPaperclipConnection(email);
  await absorbPhoneVerdicts(email);
  if (!conn || conn.mode !== "direct") return { touched: 0, mode: conn?.mode ?? null };
  const pc = client(conn);
  let touched = 0;
  for (const task of await openAgentTasks(email)) {
    try {
      if (task.status === "dispatching") {
        if (await dispatchDirect(conn, task)) touched++;
        continue;
      }
      if (!task.paperclip_issue_id) continue;
      if (task.status === "in_progress") {
        const [issue, comments] = await Promise.all([pc.getIssue(task.paperclip_issue_id), pc.listComments(task.paperclip_issue_id)]);
        const draft = latestAgentComment(comments);
        const before = task.status;
        const after = await advance(email, {
          task_id: task.id,
          issue: { id: issue.id, identifier: issue.identifier, status: issue.status },
          draft: draft?.body ?? null,
        });
        if (after && after.status !== before) touched++;
        continue;
      }
      // approved / denied: close the issue out.
      const approved = task.status === "approved";
      await pc.addComment(task.paperclip_issue_id, approved ? "Approved by the owner via No Hands." : "Denied by the owner via No Hands.");
      await pc.updateIssue(task.paperclip_issue_id, { status: approved ? "done" : "cancelled" }).catch(async () => {
        // Older Paperclip builds have no cancelled status; a done+comment is still honest.
        await pc.updateIssue(task.paperclip_issue_id!, { status: "done" });
      });
      await advance(email, { task_id: task.id, closed: true });
      touched++;
    } catch (e) {
      await advance(email, { task_id: task.id, error: e instanceof Error ? e.message : String(e) });
    }
  }
  return { touched, mode: conn.mode };
}

/** Throttled sync hook for the feed poll: the phone polls every 5 s, and that
 *  is a perfectly good clock for direct-mode sync without a queue. */
const lastSync = new Map<string, number>();
const SYNC_EVERY_MS = 15_000;
export async function maybeSync(email: string) {
  const now = Date.now();
  if (now - (lastSync.get(email) ?? 0) < SYNC_EVERY_MS) return;
  lastSync.set(email, now);
  try {
    await syncAccount(email);
  } catch (e) {
    console.warn("[tasks] sync failed:", e instanceof Error ? e.message : e);
  }
}

// MARK: - Bridge mode

export interface BridgeWork {
  company_id: string;
  create: { task_id: string; title: string; description: string; assignee_agent_id: string | null; tier: number }[];
  watch: { task_id: string; issue_id: string }[];
  close: { task_id: string; issue_id: string; approved: boolean }[];
}

export async function bridgeWork(email: string): Promise<BridgeWork | null> {
  const conn = await getPaperclipConnection(email);
  if (!conn) return null;
  await absorbPhoneVerdicts(email);
  const work: BridgeWork = { company_id: conn.company_id, create: [], watch: [], close: [] };
  for (const t of await openAgentTasks(email)) {
    if (t.status === "dispatching") {
      work.create.push({ task_id: t.id, title: t.title, description: issueDescription(t), assignee_agent_id: t.owner_ref, tier: t.blast_tier });
    } else if (t.status === "in_progress" && t.paperclip_issue_id) {
      work.watch.push({ task_id: t.id, issue_id: t.paperclip_issue_id });
    } else if ((t.status === "approved" || t.status === "denied") && t.paperclip_issue_id) {
      work.close.push({ task_id: t.id, issue_id: t.paperclip_issue_id, approved: t.status === "approved" });
    }
  }
  return work;
}

export async function bridgeReport(email: string, observations: Observation[]): Promise<number> {
  let n = 0;
  for (const o of observations) {
    if (!o || typeof o.task_id !== "string") continue;
    if (await advance(email, { ...o, draft: o.draft ? String(o.draft).slice(0, 4000) : o.draft })) n++;
  }
  return n;
}
