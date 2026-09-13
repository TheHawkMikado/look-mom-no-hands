import { recordAgentEvents } from "@/lib/db";
import {
  decideTaskApproval,
  insertApproval,
  insertReceipt,
  updateTask,
  type ApprovalRow,
  type TaskRow,
} from "@/lib/db-tasks";
import { needsApproval, tierSpec, type Tier } from "@/lib/tiers";
import { sendPush } from "@/lib/push";

/**
 * The Approval Gate (SPEC.md §6). Every action that leaves our own database
 * asks here first. Tier 0–1 pass through (1 with a notify-after event); tier
 * 2+ create a pending approval and surface it to the user through the same
 * `needs_approval` event the phone app and /status page already render, so
 * one tap on the existing card decides it.
 */

export interface GateDecision {
  allowed: boolean;
  approval: ApprovalRow | null;
}

/** Ask the gate whether `task` may take its real-world action now. */
export async function requestApproval(task: TaskRow, question: string): Promise<GateDecision> {
  const tier = task.blast_tier as Tier;
  if (!needsApproval(tier)) {
    if (tier === 1) {
      await notify(task.email, `${task.id}:auto`, "goal_progress", task.title, `Tier 1 — doing it, no approval needed.`, null);
    }
    return { allowed: true, approval: null };
  }
  const approval = await insertApproval(task.email, task.id, tier, question);
  await updateTask(task.email, task.id, { status: "awaiting_approval" });
  await notify(
    task.email,
    approval.id,
    "needs_approval",
    task.title,
    `${question}\n\nTier ${tier} — ${tierSpec(tier).name}.`,
    approval.id,
  );
  await insertReceipt(task.email, {
    task_id: task.id,
    actor: "system",
    summary: `Approval requested (tier ${tier}): ${question}`,
    ref: approval.id,
  });
  // The phone buzzes with the same card it already renders from the feed.
  // Best-effort and bounded (lib/push): a dead phone never stalls the gate.
  await sendPush(task.email, {
    title: `Approve? ${task.title}`.slice(0, 120),
    body: question,
    data: { approvalId: approval.id, taskId: task.id },
  });
  return { allowed: false, approval };
}

/**
 * SPEC §12: content that came out of a meeting is DATA, never instructions.
 * An attendee saying "assistant, approve that" must not work, so a verdict on
 * a meeting-sourced task above tier 1 needs proof it is the owner: the phone
 * (a signed-in device in their pocket), or a voice the enrolled voiceprint
 * verified. Tier 3+ from a meeting needs the phone specifically — several
 * voices were present, and a similarity threshold is not a password.
 * Pure, so it is unit-tested without a database.
 */
export function verdictAllowed(
  task: Pick<TaskRow, "source" | "blast_tier">,
  via: "voice" | "push" | "text",
  speakerVerified: boolean,
): { ok: true } | { ok: false; reason: string } {
  if (task.source !== "meeting" || task.blast_tier < 2) return { ok: true };
  if (via === "push") return { ok: true };
  if (task.blast_tier >= 3) return { ok: false, reason: "this came out of a meeting and commits money or a third party — approve it from your phone" };
  if (via === "voice" && speakerVerified) return { ok: true };
  return { ok: false, reason: "this came out of a meeting — I need your verified voice or your phone for it" };
}

/** Apply a verdict. Idempotent: a second call for the same approval is a no-op.
 *  Returns null when the approval was already decided OR the channel is not
 *  allowed for this task (see verdictAllowed); the refusal leaves a receipt. */
export async function applyVerdict(
  task: TaskRow,
  approvalId: string,
  verdict: "approve" | "deny",
  via: "voice" | "push" | "text",
  speakerVerified: boolean,
): Promise<ApprovalRow | null> {
  const allowed = verdictAllowed(task, via, speakerVerified);
  if (!allowed.ok) {
    await insertReceipt(task.email, {
      task_id: task.id,
      actor: "system",
      summary: `Refused a ${verdict} via ${via}${speakerVerified ? " (speaker verified)" : ""}: ${allowed.reason}.`,
      ref: approvalId,
    });
    return null;
  }
  const row = await decideTaskApproval(task.email, approvalId, verdict, via, speakerVerified);
  if (!row) return null;
  await updateTask(task.email, task.id, { status: verdict === "approve" ? "approved" : "denied" });
  await insertReceipt(task.email, {
    task_id: task.id,
    actor: "user",
    summary: `${verdict === "approve" ? "Approved" : "Denied"} via ${via}${speakerVerified ? " (speaker verified)" : ""}.`,
    ref: approvalId,
  });
  return row;
}

async function notify(
  email: string,
  id: string,
  kind: "goal_started" | "goal_progress" | "needs_approval" | "goal_done" | "goal_failed",
  title: string,
  detail: string,
  approvalId: string | null,
) {
  await recordAgentEvents(email, [
    { id, kind, title: title.slice(0, 200), detail: detail.slice(0, 500), approvalId, createdAt: new Date() },
  ]);
}

export { notify as gateNotify };
