import { recordAgentEvents } from "@/lib/db";
import {
  getPaperclipConnection,
  getTask,
  insertReceipt,
  outstandingTasks,
  tasksDueForFollowup,
  updateTask,
  type TaskRow,
} from "@/lib/db-tasks";
import { gateNotify } from "@/lib/gate";
import type { Delivery } from "@/lib/notify";
import { PaperclipClient } from "@/lib/paperclip";
import { closePromptsForTask, getPrompt, insertPrompt, openPromptFor, recordAnswer, type PromptRow } from "@/lib/prompts";
import { collectPushReceipts, sendPush } from "@/lib/push";
import { accountsWithFollowups, getSettings, setSettings, type AccountSettings } from "@/lib/settings";
import { deliverTask, intake, type IntakeResult } from "@/lib/tasks";
import { describe, inQuietHours, localDate, nextMorning, parseWhen, pastLocalTime, quietHoursEnd, reschedule } from "@/lib/when";

/**
 * The follow-up engine (SPEC.md §5.4): the bot initiates, the human answers.
 * Every open task carries `check_in_at` and `escalate_at`. A cron wakes this
 * every five minutes:
 *
 *  - past check-in, agent owner, nothing delivered → poke the agent (a
 *    Paperclip heartbeat; the bridge does it when Paperclip is on the Mac);
 *  - past check-in, human owner → a `deliver_reminder` prompt: the Mac has
 *    the person's address, we don't, so it fulfils the reminder;
 *  - past escalation, anyone → one question with a default, as a prompt the
 *    Mac speaks when idle and a push the phone shows;
 *  - at the account's brief time → a `daily_brief` prompt.
 *
 * Quiet hours are respected by dating prompts `not_before`; the phone is not
 * buzzed for those. Every action leaves a receipt on the task.
 */

export interface FollowupStats {
  nudged: number;
  reminders: number;
  escalations: number;
  briefs: number;
  errors: number;
}

// MARK: - Wording (pure)

const ownerWord = (t: TaskRow) =>
  t.owner_kind === "agent" ? (t.owner_name ?? "The agent") : t.owner_kind === "human" ? (t.owner_name ?? "Your teammate") : null;

/** "Amari's vendor quote is overdue. Nudge again Friday morning, or handle
 *  it yourself?" — one question, one default. */
export function escalationQuestion(task: TaskRow, now: Date, tz: string): { question: string; default_answer: string } {
  const again = describe(nextMorning(now, tz), now, tz);
  const who = ownerWord(task);
  const title = task.title.replace(/\.$/, "");
  if (task.owner_kind === "user") {
    return {
      question: `"${title}" is still waiting on you. Decide now, or push it to ${again}?`,
      default_answer: "push",
    };
  }
  if (task.status === "awaiting_approval") {
    return {
      question: `"${title}" has been waiting on your approval since ${describe(new Date(task.updated_at), now, tz)}. Approve it now, or push it to ${again}?`,
      default_answer: "push",
    };
  }
  const state = task.owner_kind === "agent" ? "hasn't delivered" : "hasn't come back on";
  return {
    question: `${who} ${state} "${title}"${task.due_at ? ` — it was due ${describe(new Date(task.due_at), now, tz)}` : ""}. Nudge again ${again}, or handle it yourself?`,
    default_answer: "nudge",
  };
}

export interface Outstanding {
  counts: { total: number; agent: number; human: number; user: number; overdue: number; awaiting_approval: number };
  top: { id: string; title: string; owner_kind: TaskRow["owner_kind"]; owner_name: string | null; status: string; due_at: string | null; overdue: boolean }[];
  /** One spoken paragraph for the Mac. */
  spoken: string;
}

/** Counts plus the three soonest-due, and a sentence to say them with. */
export function summarize(tasks: TaskRow[], now: Date, tz: string): Outstanding {
  const overdue = (t: TaskRow) => !!t.due_at && new Date(t.due_at).getTime() < now.getTime();
  const counts = {
    total: tasks.length,
    agent: tasks.filter((t) => t.owner_kind === "agent").length,
    human: tasks.filter((t) => t.owner_kind === "human").length,
    user: tasks.filter((t) => t.owner_kind === "user").length,
    overdue: tasks.filter(overdue).length,
    awaiting_approval: tasks.filter((t) => t.status === "awaiting_approval").length,
  };
  const top = tasks.slice(0, 3).map((t) => ({
    id: t.id,
    title: t.title,
    owner_kind: t.owner_kind,
    owner_name: t.owner_name,
    status: t.status,
    due_at: t.due_at ? new Date(t.due_at).toISOString() : null,
    overdue: overdue(t),
  }));
  if (tasks.length === 0) return { counts, top, spoken: "Nothing outstanding. You're clear." };
  const parts: string[] = [];
  if (counts.agent) parts.push(`${counts.agent} with agents`);
  if (counts.human) parts.push(`${counts.human} with the team`);
  if (counts.user) parts.push(`${counts.user} waiting on you`);
  const head = `${counts.total} outstanding: ${parts.join(", ")}${counts.overdue ? `; ${counts.overdue} overdue` : ""}${counts.awaiting_approval ? `; ${counts.awaiting_approval} awaiting your approval` : ""}.`;
  const line = (t: TaskRow) => {
    const who = t.owner_kind === "user" ? "you" : (t.owner_name ?? t.owner_kind);
    const due = t.due_at ? (overdue(t) ? `, was due ${describe(new Date(t.due_at), now, tz)}` : `, due ${describe(new Date(t.due_at), now, tz)}`) : "";
    return `${t.title} (${who}${due})`;
  };
  return { counts, top, spoken: `${head} Top: ${tasks.slice(0, 3).map(line).join("; ")}.` };
}

export async function outstanding(email: string, now = new Date()): Promise<Outstanding> {
  const [tasks, settings] = await Promise.all([outstandingTasks(email), getSettings(email)]);
  return summarize(tasks, now, settings.tz);
}

// MARK: - The engine

function notBefore(now: Date, s: AccountSettings): Date | null {
  return inQuietHours(now, s.tz, s.quiet_hours_start, s.quiet_hours_end) ? quietHoursEnd(now, s.tz, s.quiet_hours_start, s.quiet_hours_end) : null;
}

export async function runFollowupsFor(email: string, now = new Date()): Promise<FollowupStats> {
  const stats: FollowupStats = { nudged: 0, reminders: 0, escalations: 0, briefs: 0, errors: 0 };
  const [settings, conn] = await Promise.all([getSettings(email), getPaperclipConnection(email)]);
  const quiet = notBefore(now, settings);

  for (const task of await tasksDueForFollowup(email, now)) {
    try {
      const pastEscalate = task.escalate_at && new Date(task.escalate_at) <= now && !task.escalated_at;
      const pastCheckIn = task.check_in_at && new Date(task.check_in_at) <= now && !task.nudged_at;
      if (pastEscalate) {
        await escalate(email, task, now, settings, quiet);
        stats.escalations++;
        // An escalation supersedes a pending check-in: one question, not two.
        if (pastCheckIn) await updateTask(email, task.id, { nudged_at: now });
        continue;
      }
      if (!pastCheckIn) continue;
      if (task.owner_kind === "agent") {
        if (task.status !== "dispatching" && task.status !== "in_progress") {
          await updateTask(email, task.id, { nudged_at: now }); // delivered already; nothing to nudge
          continue;
        }
        if (conn?.mode === "bridge") continue; // the bridge nudges (bridgeWork.nudge) and reports back
        if (conn && task.owner_ref) {
          const pc = new PaperclipClient({ url: conn.url, apiKey: conn.apiKey, timeoutMs: 8000 });
          try {
            await pc.invokeHeartbeat(task.owner_ref, "on_demand");
            await insertReceipt(email, { task_id: task.id, actor: "system", actor_ref: task.owner_ref, summary: `Nudged ${task.owner_name ?? "the agent"} (heartbeat invoked).` });
          } catch (e) {
            await insertReceipt(email, { task_id: task.id, actor: "system", summary: `Nudge failed: ${e instanceof Error ? e.message : String(e)}`.slice(0, 400) });
          }
        } else {
          await insertReceipt(email, { task_id: task.id, actor: "system", summary: "Check-in: no Paperclip connection to nudge; will escalate." });
        }
        await updateTask(email, task.id, { nudged_at: now });
        stats.nudged++;
      } else if (task.owner_kind === "human" && task.status === "assigned") {
        if (!(await openPromptFor(email, task.id, "deliver_reminder"))) {
          await insertPrompt(email, {
            task_id: task.id,
            kind: "deliver_reminder",
            question: `Remind ${task.owner_name ?? "your teammate"} about "${task.title}"${task.due_at ? ` (due ${describe(new Date(task.due_at), now, settings.tz)})` : ""}?`,
            default_answer: "yes",
            not_before: quiet,
          });
          await insertReceipt(email, { task_id: task.id, actor: "system", summary: `Check-in: reminder for ${task.owner_name ?? "teammate"} queued for the Mac to send.` });
        }
        await updateTask(email, task.id, { nudged_at: now });
        stats.reminders++;
      } else {
        // The user's own decisions and unsent tickets: the escalation clock
        // is the only nudge that makes sense.
        await updateTask(email, task.id, { nudged_at: now });
      }
    } catch (e) {
      stats.errors++;
      console.warn("[followup]", email, task.id, e instanceof Error ? e.message : e);
    }
  }

  // Daily brief, once per local day, at or after the set time.
  if (settings.daily_brief_at && pastLocalTime(now, settings.tz, settings.daily_brief_at) && settings.last_brief_date !== localDate(now, settings.tz)) {
    try {
      const o = summarize(await outstandingTasks(email), now, settings.tz);
      const prompt = await insertPrompt(email, { task_id: null, kind: "daily_brief", question: o.spoken, default_answer: "ok", not_before: null });
      await setSettings(email, { last_brief_date: localDate(now, settings.tz) });
      await sendPush(email, { title: "Today's outstanding", body: o.spoken, data: { promptId: prompt.id } });
      stats.briefs++;
    } catch (e) {
      stats.errors++;
      console.warn("[followup] brief", email, e instanceof Error ? e.message : e);
    }
  }
  return stats;
}

async function escalate(email: string, task: TaskRow, now: Date, settings: AccountSettings, quiet: Date | null) {
  const q = escalationQuestion(task, now, settings.tz);
  let prompt = await openPromptFor(email, task.id, "escalation");
  if (!prompt) {
    prompt = await insertPrompt(email, { task_id: task.id, kind: "escalation", question: q.question, default_answer: q.default_answer, not_before: quiet });
  }
  await recordAgentEvents(email, [{
    id: `${task.id}:escalated:${now.getTime()}`,
    kind: "goal_progress",
    title: task.title.slice(0, 200),
    detail: q.question.slice(0, 500),
    approvalId: null,
    createdAt: now,
  }]);
  await insertReceipt(email, { task_id: task.id, actor: "system", summary: `Escalated to you: ${q.question}`, ref: prompt.id });
  await updateTask(email, task.id, { escalated_at: now });
  if (!quiet) {
    await sendPush(email, { title: `Overdue: ${task.title}`.slice(0, 120), body: q.question, data: { promptId: prompt.id, taskId: task.id } });
  }
}

/** One round for every account. The cron calls this. */
export async function runFollowups(now = new Date()): Promise<FollowupStats & { accounts: number }> {
  const totals: FollowupStats & { accounts: number } = { accounts: 0, nudged: 0, reminders: 0, escalations: 0, briefs: 0, errors: 0 };
  for (const email of await accountsWithFollowups()) {
    totals.accounts++;
    try {
      const s = await runFollowupsFor(email, now);
      totals.nudged += s.nudged; totals.reminders += s.reminders; totals.escalations += s.escalations; totals.briefs += s.briefs; totals.errors += s.errors;
    } catch (e) {
      totals.errors++;
      console.warn("[followup]", email, e instanceof Error ? e.message : e);
    }
  }
  await collectPushReceipts(fetch, now).catch(() => undefined);
  return totals;
}

// MARK: - Answers

export type Applied = "rescheduled" | "handled" | "done" | "dropped" | "new_task" | "reminded" | "needs_address" | "skipped" | "noted" | "already_answered";

export interface AnswerResult {
  prompt: PromptRow;
  applied: Applied;
  task: TaskRow | null;
  intake?: IntakeResult;
  /** For `rescheduled`: when the next check-in is. */
  next_at?: string;
  delivery?: { status: string; summary: string };
}

const HANDLE = /^(i(’|')?ll )?(handle|take|do) (it|this|that)( myself)?$|^(handle|mine|me|myself|i got it|i'?ll do it)$/i;
const DONE = /^(done|it'?s done|finished|already done|complete[d]?)$/i;
const DROP = /^(drop|drop it|cancel|cancel it|forget it|never ?mind|kill it|skip it)$/i;
const NUDGE = /^(nudge|nudge (it|them|again)|later|push|push it|remind|remind (them|again)|snooze|again|yes|ok|okay|sure|fine)$/i;
const NO = /^(no|nope|skip|not now|don'?t)$/i;
const ACK = /^(ok|okay|yes|sure|thanks|thank you|got it|fine|noted)$/i;

/**
 * Apply the user's answer to a prompt. "Nudge" (or a time) reschedules,
 * "handle" makes it the user's, "done"/"drop" close it, and anything else
 * is a new instruction and goes through intake like any spoken request.
 */
export async function answerPrompt(
  email: string,
  promptId: string,
  answerText: string,
  opts: { deliver?: Delivery | null; now?: Date } = {},
): Promise<AnswerResult | null> {
  const now = opts.now ?? new Date();
  const existing = await getPrompt(email, promptId);
  if (!existing) return null;
  if (existing.answered_at) return { prompt: existing, applied: "already_answered", task: existing.task_id ? await getTask(email, existing.task_id) : null };
  const a = (answerText ?? "").trim() || existing.default_answer;
  const prompt = (await recordAnswer(email, promptId, a)) ?? existing;
  const settings = await getSettings(email);
  const task = prompt.task_id ? await getTask(email, prompt.task_id) : null;
  const isDefault = a.toLowerCase() === prompt.default_answer.toLowerCase();

  if (prompt.kind === "escalation" && task) {
    if (HANDLE.test(a)) {
      const next = await updateTask(email, task.id, { owner_kind: "user", owner_ref: null, owner_name: null, status: "needs_decision", nudged_at: now, escalated_at: now });
      await insertReceipt(email, { task_id: task.id, actor: "user", summary: "Owner took it over.", ref: prompt.id });
      await closePromptsForTask(email, task.id, "(owner handling)");
      return { prompt, applied: "handled", task: next };
    }
    if (DONE.test(a)) {
      const next = await updateTask(email, task.id, { status: "done", closed_at: now });
      await insertReceipt(email, { task_id: task.id, actor: "user", summary: "Owner marked it done.", ref: prompt.id });
      await closePromptsForTask(email, task.id, "(done)");
      await gateNotify(email, `${task.id}:done`, "goal_done", task.title, "Marked done by the owner.", null);
      return { prompt, applied: "done", task: next };
    }
    if (DROP.test(a)) {
      const next = await updateTask(email, task.id, { status: "failed", closed_at: now });
      await insertReceipt(email, { task_id: task.id, actor: "user", summary: "Owner dropped it.", ref: prompt.id });
      await closePromptsForTask(email, task.id, "(dropped)");
      return { prompt, applied: "dropped", task: next };
    }
    const when = parseWhen(a.replace(/^(nudge|remind|push|snooze)( (it|them|again))?( (on|to|until|till))?\s*/i, ""), { now, tz: settings.tz });
    if (isDefault || NUDGE.test(a) || when) {
      const s = reschedule(now, settings.tz, when?.at ?? null);
      const next = await updateTask(email, task.id, { check_in_at: s.check_in_at, escalate_at: s.escalate_at, nudged_at: null, escalated_at: null });
      await insertReceipt(email, { task_id: task.id, actor: "user", summary: `Owner: nudge again ${describe(s.check_in_at, now, settings.tz)}.`, ref: prompt.id });
      return { prompt, applied: "rescheduled", task: next, next_at: s.check_in_at.toISOString() };
    }
    const r = await intake(email, a, "voice", { now });
    await insertReceipt(email, { task_id: task.id, actor: "user", summary: `Owner answered with a new instruction: "${a.slice(0, 200)}"${r.task ? ` → task ${r.task.id}` : ""}.`, ref: prompt.id });
    return { prompt, applied: "new_task", task, intake: r };
  }

  if (prompt.kind === "deliver_reminder" && task) {
    if (NO.test(a)) {
      await insertReceipt(email, { task_id: task.id, actor: "user", summary: "Owner skipped the reminder.", ref: prompt.id });
      return { prompt, applied: "skipped", task };
    }
    if (isDefault || NUDGE.test(a)) {
      if (!opts.deliver) return { prompt, applied: "needs_address", task };
      const d = await deliverTask(email, task, opts.deliver, "reminder", now);
      return { prompt, applied: "reminded", task: d.task, delivery: { status: d.outcome.status, summary: d.outcome.summary } };
    }
    const r = await intake(email, a, "voice", { now });
    return { prompt, applied: "new_task", task, intake: r };
  }

  // daily_brief / promotion / anything without a task
  if (isDefault || ACK.test(a) || NO.test(a)) return { prompt, applied: "noted", task };
  const r = await intake(email, a, "voice", { now });
  return { prompt, applied: "new_task", task, intake: r };
}
