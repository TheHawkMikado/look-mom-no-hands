import { approvalVerdictsFor } from "@/lib/db";
import {
  approvalsForTask,
  getPaperclipConnection,
  getTask,
  insertReceipt,
  insertTask,
  openAgentTasks,
  openApprovals,
  updateTask,
  type ApprovalRow,
  type PaperclipConnection,
  type TaskRow,
  type TaskStatus,
} from "@/lib/db-tasks";
import { extractTask, type Extraction } from "@/lib/extract";
import { applyVerdict, gateNotify, requestApproval } from "@/lib/gate";
import { deliverTicket, deliveryTierFloor, type Delivery, type Purpose, type SendResult } from "@/lib/notify";
import { ISSUE_DELIVERED, ISSUE_FAILED, latestAgentComment, PaperclipClient } from "@/lib/paperclip";
import { closePromptsForTask } from "@/lib/prompts";
import { getSettings } from "@/lib/settings";
import { needsApproval, type Tier } from "@/lib/tiers";
import { triage } from "@/lib/triage";
import { captureDirect, storeRawBoard, type RawBoard } from "@/lib/team";
import { onAdProcessIntake } from "@/lib/projects";
import { parseWhen, schedule } from "@/lib/when";

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
  /** When the Mac asked for a human ticket: what happened to it. */
  delivery?: DeliveryOutcome;
}

export interface DeliveryOutcome {
  status: "sent" | "not_sent" | "awaiting_approval";
  channel: Delivery["channel"];
  summary: string;
  approval_id?: string;
}

export interface IntakeOptions {
  /** The Mac's one-time hand-off for a human ticket (lib/notify). Its
   *  presence is the Mac asserting "this person is on the team" — the
   *  Person record lives there, not here. */
  deliver?: Delivery | null;
  now?: Date;
}

export async function intake(
  email: string,
  text: string,
  source: "text" | "voice" | "meeting" = "text",
  opts: IntakeOptions = {},
): Promise<IntakeResult> {
  const now = opts.now ?? new Date();
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

  const [conn, settings] = await Promise.all([getPaperclipConnection(email), getSettings(email)]);
  let t = triage(x, conn?.agents ?? [], !!conn);
  let tier = x.blast_tier;

  // The Mac named a person and gave us a one-time address: that is the
  // human step of §5.3 (Person records live on the Mac). Messaging a human
  // is at least tier 2 (§6), a client at least 3.
  const deliver = opts.deliver ?? null;
  if (deliver) {
    tier = Math.max(tier, deliveryTierFloor(deliver)) as Tier;
    const when = x.due_phrase ? ` ${x.due_phrase}` : "";
    t = {
      owner_kind: "human",
      owner_ref: null,
      owner_name: deliver.name,
      confirmation: `I'll send that to ${deliver.name} by ${deliver.channel}${when} and follow up.`,
      reason: `the Mac named ${deliver.name} on the team (${deliver.channel})`,
    };
  }

  // Timing (§5.4): the phrase the user said, in their zone, or the defaults.
  const due = parseWhen(x.due_phrase, { now, tz: settings.tz });
  const clocks = schedule(due?.at ?? null, now);
  const status: TaskStatus =
    t.owner_kind === "agent" ? "dispatching" : t.owner_kind === "human" ? "assigned" : "needs_decision";

  const task = await insertTask(email, {
    title: x.title,
    detail: x.detail,
    capability: x.capability,
    owner_kind: t.owner_kind,
    owner_ref: t.owner_ref,
    owner_name: t.owner_name,
    blast_tier: tier,
    status,
    confirmation: t.confirmation,
    source,
    due_at: clocks.due_at,
    check_in_at: clocks.check_in_at,
    escalate_at: clocks.escalate_at,
    deliver_channel: deliver?.channel ?? null,
  });
  await insertReceipt(email, {
    task_id: task.id,
    actor: "model",
    model_used: x.model_used ?? "rules",
    summary: `Extracted from ${source}: "${x.title}" (tier ${tier}, ${x.capability}).`,
  });
  await insertReceipt(email, {
    task_id: task.id,
    actor: "system",
    summary: `Triaged to ${t.owner_kind}${t.owner_name ? ` (${t.owner_name})` : ""}: ${t.reason}.`
      + (x.due_phrase ? ` Due "${x.due_phrase}" → ${due ? `${due.at.toISOString()} (${due.rule})` : "unparsed, defaults"}.` : ""),
  });

  if (t.owner_kind === "user") {
    await gateNotify(email, `${task.id}:decision`, "goal_progress", task.title, t.confirmation, null);
  }

  // Direct mode: delegate right now. Bridge mode: the bridge picks it up on
  // its next poll (a few seconds). Neither delays the confirmation the user
  // hears — that was decided before this point.
  let out = task;
  let delivery: DeliveryOutcome | undefined;
  if (t.owner_kind === "agent" && conn && conn.mode === "direct") {
    out = (await dispatchDirect(conn, task)) ?? task;
  } else if (deliver) {
    const d = await deliverTask(email, task, deliver, "ticket", now);
    delivery = d.outcome;
    out = d.task ?? task;
  }
  // Phase 5: "run the ad process for X with a $N cap" gets a project with a
  // budget and the step issues nested under the task's issue.
  if (x.capability === "ad_process") {
    await onAdProcessIntake(out, x).catch((e) => console.warn("[ad-process]", e instanceof Error ? e.message : e));
  }
  return { intent: x.intent, task: out, confirmation: t.confirmation, extraction: x, delivery };
}

// MARK: - Human tickets

/**
 * Send (or re-send) a human ticket, through the gate. A ticket at or below
 * the account's `auto_deliver_tier` goes now; above it, an approval is
 * requested and the Mac must call again with the address once the owner has
 * approved (we never keep it). The address in `deliver` is used for this
 * one send and dropped.
 */
export async function deliverTask(
  email: string,
  task: TaskRow,
  deliver: Delivery,
  purpose: Purpose,
  now = new Date(),
): Promise<{ outcome: DeliveryOutcome; task: TaskRow | null; send?: SendResult }> {
  const settings = await getSettings(email);
  const tier = task.blast_tier as Tier;
  if (needsApproval(tier) && tier > settings.auto_deliver_tier) {
    const approvals = await approvalsForTask(task.id);
    const approved = approvals.some((a) => a.decision === "approve");
    if (!approved) {
      const open = approvals.find((a) => !a.decided_at);
      if (open) {
        return { outcome: { status: "awaiting_approval", channel: deliver.channel, summary: "Waiting on the owner.", approval_id: open.id }, task };
      }
      const gate = await requestApproval(task, `Send "${task.title}" to ${deliver.name} by ${deliver.channel}?`);
      return {
        outcome: { status: "awaiting_approval", channel: deliver.channel, summary: `Tier ${tier} — asking the owner before messaging ${deliver.name}.`, approval_id: gate.approval?.id },
        task: await getTask(email, task.id),
      };
    }
  }
  const send = await deliverTicket(email, task, deliver, purpose, now, settings.tz);
  const patch: Parameters<typeof updateTask>[2] = {
    deliver_channel: deliver.channel,
    owner_kind: "human",
    owner_name: deliver.name,
  };
  if (send.sent) patch.delivered_at = now;
  if (task.status === "awaiting_approval" || task.status === "approved" || task.status === "triaged") patch.status = "assigned";
  const fresh = await updateTask(email, task.id, patch);
  return {
    outcome: { status: send.sent ? "sent" : "not_sent", channel: deliver.channel, summary: send.summary },
    task: fresh,
    send,
  };
}

/** The most recent approval decision on a task, for the calls gate. */
export async function approvedOn(taskId: string): Promise<ApprovalRow | null> {
  const approvals = await approvalsForTask(taskId);
  return [...approvals].reverse().find((a) => a.decision === "approve") ?? null;
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
  /** Set by the bridge after it invoked the agent's heartbeat (a nudge). */
  nudged?: boolean;
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

  if (obs.nudged && !task.nudged_at) {
    await insertReceipt(email, { task_id: task.id, actor: "system", actor_ref: task.owner_ref, summary: `Nudged ${task.owner_name ?? "the agent"} (heartbeat invoked).` });
    const next = await updateTask(email, task.id, { nudged_at: new Date() });
    if (obs.issue === undefined && obs.draft === undefined && !obs.closed) return next;
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
      await closePromptsForTask(email, task.id);
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
  // The team board rides the same clock. A failed capture keeps the last one.
  await captureDirect(email, conn).catch((e) => console.warn("[team] capture failed:", e instanceof Error ? e.message : e));
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
  /** Agents past their check-in with nothing delivered: invoke a heartbeat
   *  (follow-up engine, §5.4). The bridge reports `{ task_id, nudged: true }`. */
  nudge: { task_id: string; agent_id: string; issue_id: string }[];
}

export async function bridgeWork(email: string, now = new Date()): Promise<BridgeWork | null> {
  const conn = await getPaperclipConnection(email);
  if (!conn) return null;
  await absorbPhoneVerdicts(email);
  const work: BridgeWork = { company_id: conn.company_id, create: [], watch: [], close: [], nudge: [] };
  for (const t of await openAgentTasks(email)) {
    if (t.status === "dispatching") {
      work.create.push({ task_id: t.id, title: t.title, description: issueDescription(t), assignee_agent_id: t.owner_ref, tier: t.blast_tier });
    } else if (t.status === "in_progress" && t.paperclip_issue_id) {
      work.watch.push({ task_id: t.id, issue_id: t.paperclip_issue_id });
      if (t.owner_ref && t.check_in_at && new Date(t.check_in_at) <= now && !t.nudged_at) {
        work.nudge.push({ task_id: t.id, agent_id: t.owner_ref, issue_id: t.paperclip_issue_id });
      }
    } else if ((t.status === "approved" || t.status === "denied") && t.paperclip_issue_id) {
      work.close.push({ task_id: t.id, issue_id: t.paperclip_issue_id, approved: t.status === "approved" });
    }
  }
  return work;
}

export async function bridgeReport(email: string, observations: Observation[], board?: RawBoard | null): Promise<number> {
  if (board && typeof board === "object") {
    await storeRawBoard(email, board).catch((e) => console.warn("[team] bridge board failed:", e instanceof Error ? e.message : e));
  }
  let n = 0;
  for (const o of observations) {
    if (!o || typeof o.task_id !== "string") continue;
    if (await advance(email, { ...o, draft: o.draft ? String(o.draft).slice(0, 4000) : o.draft })) n++;
  }
  return n;
}
