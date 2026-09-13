#!/usr/bin/env node
/**
 * Phase 3 demo (SPEC.md §9): the follow-up engine and human tickets.
 *
 *  1. "ask Amari to get the vendor quote by 3pm" with a one-time email
 *     hand-off → due_at / check_in_at / escalate_at set, tier 2, approval asked.
 *  2. Approve, deliver → a receipt (sent, or "not sent: no email provider
 *     configured" when Resend is unset — never a failure).
 *  3. Clock past check-in → a deliver_reminder prompt; answered with a fresh
 *     hand-off → reminder receipt.
 *  4. Clock past escalation → escalation prompt + goal_progress event.
 *  5. Answer "handle" → the owner becomes the user.
 *  6. A task with no due phrase → 24 h / 48 h defaults; past escalation,
 *     answer "nudge" → rescheduled to the next working morning.
 *  7. "What's outstanding" and the calls gate without Vapi.
 *
 *   NOHANDS_API=http://localhost:3000 NOHANDS_APP_TOKEN=… node scripts/phase3-demo.mjs
 *
 * The clock override (`now`) is honoured by the dev server only.
 */
const API = (process.env.NOHANDS_API || "http://localhost:3000").replace(/\/+$/, "");
const TOKEN = process.env.NOHANDS_APP_TOKEN;
if (!TOKEN) { console.error("NOHANDS_APP_TOKEN required"); process.exit(2); }

async function api(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok && res.status !== 202) throw new Error(`${method} ${path} → ${res.status}: ${JSON.stringify(json)}`);
  return json;
}
const step = (n, s) => console.log(`\n[${n}] ${s}`);
const fail = (s) => { console.error(`\nFAIL: ${s}`); process.exit(1); };
const plus = (iso, ms) => new Date(new Date(iso).getTime() + ms).toISOString();
const localHour = (iso, tz) => Number(new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", hourCycle: "h23" }).format(new Date(iso)));
const receiptsOf = async (id) => (await api("GET", `/api/app/tasks/${id}`)).receipts;

step(1, "Settings: New York, no quiet hours for the demo");
const { settings } = await api("PUT", "/api/app/settings", { tz: "America/New_York", quiet_hours_start: null, quiet_hours_end: null });
console.log(`    tz=${settings.tz} auto_deliver_tier=${settings.auto_deliver_tier} daily_brief_at=${settings.daily_brief_at}`);

step(2, `Intake with a human hand-off: "ask Amari to get the vendor quote for the roof by 3pm"`);
const deliver = { channel: "email", to: "amari@example.com", name: "Amari", from: "Hawk" };
const r = await api("POST", "/api/app/tasks", { text: "ask Amari to get the vendor quote for the roof by 3pm", source: "voice", deliver });
if (!r.task) fail("no task");
let task = r.task;
console.log(`    confirmation: ${r.confirmation}`);
console.log(`    owner=${task.owner_kind}/${task.owner_name} tier=${task.blast_tier} status=${task.status} channel=${task.deliver_channel}`);
console.log(`    due=${task.due_at}  check_in=${task.check_in_at}  escalate=${task.escalate_at}`);
if (task.owner_kind !== "human" || task.owner_name !== "Amari") fail("expected a human ticket for Amari");
if (!task.due_at || !task.check_in_at || !task.escalate_at) fail("clocks not set");
if (localHour(task.due_at, "America/New_York") !== 15) fail(`due_at is not 3 pm New York (${task.due_at})`);
if (new Date(task.escalate_at) - new Date(task.due_at) !== 3_600_000) fail("escalate_at is not due + 1h");
if (new Date(task.check_in_at) > new Date(task.due_at) - 3_600_000) fail("check_in_at is later than an hour before due");
if (task.blast_tier < 2) fail("messaging a teammate must be tier ≥ 2");
console.log(`    delivery: ${r.delivery?.status} — ${r.delivery?.summary}`);
if (r.delivery?.status !== "awaiting_approval") fail("tier 2 ticket should ask first (auto_deliver_tier is 1)");
const detail = await api("GET", `/api/app/tasks/${task.id}`);
if (detail.task.deliver_channel !== "email") fail("channel not recorded");
if (JSON.stringify(detail).includes("amari@example.com")) fail("the address leaked into the task, approvals or receipts");
console.log("    residency: the address appears nowhere in the stored task, approvals or receipts");

step(3, "Approve (typed, on the Mac) then deliver with a fresh hand-off");
await api("POST", `/api/app/tasks/${task.id}/decide`, { verdict: "approve", via: "text" });
const d = await api("POST", `/api/app/tasks/${task.id}/deliver`, deliver);
console.log(`    delivery: ${d.delivery.status} — ${d.delivery.summary}`);
task = d.task;
if (task.status !== "assigned") fail(`expected assigned, got ${task.status}`);
if (d.delivery.status === "not_sent" && !/not sent: no email provider configured/.test(d.delivery.summary)) fail("not-sent receipt must say why");
if (d.delivery.status === "sent") console.log("    (Resend is configured — a real email went to amari@example.com)");

step(4, "Clock past check-in → the Mac is asked to send a reminder");
let f = await api("POST", "/api/app/followups/run", { now: plus(task.check_in_at, 1000) });
console.log(`    followups at ${f.now}: nudged=${f.nudged} reminders=${f.reminders} escalations=${f.escalations} briefs=${f.briefs} errors=${f.errors}`);
let { prompts } = await api("GET", "/api/app/prompts");
let reminder = prompts.find((p) => p.taskId === task.id && p.kind === "deliver_reminder");
if (!reminder) fail("no deliver_reminder prompt");
console.log(`    prompt (${reminder.kind}): "${reminder.question}" [default: ${reminder.defaultAnswer}]`);
const ra = await api("POST", `/api/app/prompts/${reminder.id}/answer`, { answer: "yes", deliver });
console.log(`    answered "yes" with the address → applied=${ra.applied}: ${ra.delivery?.summary}`);
if (ra.applied !== "reminded") fail("reminder not applied");

step(5, "Clock past escalation → one question with a default, plus a feed event");
f = await api("POST", "/api/app/followups/run", { now: plus(task.escalate_at, 1000) });
console.log(`    followups at ${f.now}: escalations=${f.escalations}`);
({ prompts } = await api("GET", "/api/app/prompts?mark=spoken"));
const esc = prompts.find((p) => p.taskId === task.id && p.kind === "escalation");
if (!esc) fail("no escalation prompt");
console.log(`    prompt (${esc.kind}): "${esc.question}" [default: ${esc.defaultAnswer}]`);
if (!/Amari/.test(esc.question)) fail("the question should name Amari");
const feed = await api("GET", "/api/app/feed");
const ev = feed.events.find((e) => e.kind === "goal_progress" && e.title === task.title && e.detail === esc.question);
if (!ev) fail("no goal_progress event carrying the question");
console.log(`    feed: goal_progress "${ev.title}"`);

step(6, `Answer "handle" → the task becomes the owner's`);
const ha = await api("POST", `/api/app/prompts/${esc.id}/answer`, { answer: "I'll handle it" });
console.log(`    applied=${ha.applied} owner=${ha.task.owner_kind} status=${ha.task.status}`);
if (ha.applied !== "handled" || ha.task.owner_kind !== "user" || ha.task.status !== "needs_decision") fail("handle did not reassign to the user");

step(7, "A task with no due phrase → 24 h / 48 h defaults; 'nudge' reschedules to the next working morning");
const r2 = await api("POST", "/api/app/tasks", { text: "have the researcher compare three roofing vendors on price and lead time", source: "voice" });
const t2 = r2.task;
if (!t2) fail("no second task");
console.log(`    owner=${t2.owner_kind}/${t2.owner_name} status=${t2.status} check_in=${t2.check_in_at} escalate=${t2.escalate_at}`);
const ci = new Date(t2.check_in_at) - new Date(t2.created_at);
const es = new Date(t2.escalate_at) - new Date(t2.created_at);
if (Math.abs(ci - 24 * 3_600_000) > 5000 || Math.abs(es - 48 * 3_600_000) > 5000) fail("defaults are not 24h/48h");
f = await api("POST", "/api/app/followups/run", { now: plus(t2.check_in_at, 1000) });
console.log(`    past check-in: nudged=${f.nudged}`);
const nudgeReceipt = (await receiptsOf(t2.id)).find((x) => /Nudged|Nudge failed|Check-in/.test(x.summary));
if (t2.owner_kind === "agent" && !nudgeReceipt) fail("no nudge receipt for the agent task");
if (nudgeReceipt) console.log(`    receipt: ${nudgeReceipt.summary}`);
f = await api("POST", "/api/app/followups/run", { now: plus(t2.escalate_at, 1000) });
({ prompts } = await api("GET", "/api/app/prompts"));
const esc2 = prompts.find((p) => p.taskId === t2.id && p.kind === "escalation");
if (!esc2) fail("no escalation prompt for the second task");
console.log(`    prompt: "${esc2.question}"`);
const na = await api("POST", `/api/app/prompts/${esc2.id}/answer`, { answer: "nudge" });
console.log(`    answered "nudge" → applied=${na.applied} next check-in ${na.next_at} (${localHour(na.next_at, "America/New_York")}:00 New York)`);
if (na.applied !== "rescheduled" || localHour(na.next_at, "America/New_York") !== 9) fail("nudge did not reschedule to 9 am");
if (na.task.nudged_at || na.task.escalated_at) fail("reschedule must reset the nudge/escalation marks");

step(8, "What's outstanding, and the calls gate without Vapi");
const o = await api("GET", "/api/app/tasks/outstanding");
console.log(`    counts: ${JSON.stringify(o.counts)}`);
console.log(`    spoken: ${o.spoken}`);
const call = await fetch(`${API}/api/app/calls`, { method: "POST", headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" }, body: JSON.stringify({ to: "+15551234567", who: "Luigi's", goal: "book a table for four at 7", tier: 1 }) });
const cj = await call.json();
console.log(`    POST /api/app/calls → ${call.status} ${cj.status}: ${cj.error ?? ""}`);
if (call.status === 409 && cj.status !== "not_configured") fail("expected not_configured without a Vapi integration");

step(9, "Receipts for the ticket");
for (const x of await receiptsOf(task.id)) console.log(`    ${x.created_at.slice(11, 19)}  ${x.actor.padEnd(6)} ${x.summary}`);

console.log("\nPHASE 3 DEMO PASSED");
