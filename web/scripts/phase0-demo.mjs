#!/usr/bin/env node
/**
 * Phase 0 demo (SPEC.md §9): text task → triage → Paperclip issue → agent
 * drafts → approval requested → approved (via the phone's existing endpoint)
 * → receipt visible. Exits non-zero if any step does not happen.
 *
 *   NOHANDS_API=http://localhost:3000 NOHANDS_APP_TOKEN=… node scripts/phase0-demo.mjs
 */
const API = (process.env.NOHANDS_API || "http://localhost:3000").replace(/\/+$/, "");
const TOKEN = process.env.NOHANDS_APP_TOKEN;
if (!TOKEN) { console.error("NOHANDS_APP_TOKEN required"); process.exit(2); }
const TEXT = process.env.DEMO_TEXT || "have the content agent write a short LinkedIn post about why co-living beats single-family rentals for cash flow, and post it";

async function api(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${JSON.stringify(json)}`);
  return json;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const step = (n, s) => console.log(`\n[${n}] ${s}`);
const fail = (s) => { console.error(`\nFAIL: ${s}`); process.exit(1); };

step(1, "Paperclip connection");
const conn = await api("GET", "/api/app/paperclip/connection");
if (!conn.connected) fail("no Paperclip connection — run Scripts/paperclip/bootstrap.mjs first");
console.log(`    ${conn.mode} → ${conn.url}, agents: ${conn.agents.map((a) => a.name).join(", ")}`);

step(2, `Intake: "${TEXT}"`);
const t0 = Date.now();
const r = await api("POST", "/api/app/tasks", { text: TEXT, source: "text" });
console.log(`    intent=${r.intent} in ${Date.now() - t0} ms`);
console.log(`    confirmation: ${r.confirmation}`);
if (!r.task) fail("no task created");
const id = r.task.id;
console.log(`    task ${id}: owner=${r.task.owner_kind}/${r.task.owner_name} tier=${r.task.blast_tier} status=${r.task.status} issue=${r.task.paperclip_issue_key ?? "(pending)"}`);
if (r.task.owner_kind !== "agent") fail("expected the task to be delegated to an agent");

step(3, "Waiting for the agent's draft");
let task = r.task;
for (let i = 0; i < 60 && !["awaiting_approval", "approved", "done", "failed"].includes(task.status); i++) {
  await sleep(3000);
  if (conn.mode === "direct") await api("POST", "/api/app/tasks/sync");
  ({ task } = await api("GET", `/api/app/tasks/${id}`));
  process.stdout.write(`    ${task.status}${task.paperclip_issue_key ? ` (${task.paperclip_issue_key})` : ""}\r`);
}
console.log();
if (task.status === "failed") fail("agent failed");
if (!task.result) fail(`no draft arrived (status ${task.status})`);
console.log(`    draft (${task.result.length} chars):\n      ${task.result.split("\n").slice(0, 4).join("\n      ")}`);

step(4, "Approval");
if (task.status === "awaiting_approval") {
  const { approvals } = await api("GET", `/api/app/tasks/${id}`);
  const open = approvals.find((a) => !a.decided_at);
  if (!open) fail("awaiting approval but no open approval row");
  console.log(`    tier ${open.tier} approval ${open.id}: "${open.question}"`);
  // The phone's existing endpoint — proves the approval card needs no change.
  const d = await api("POST", "/api/app/approvals/decide", { approvalId: open.id, verdict: "approve" });
  console.log(`    approved via /api/app/approvals/decide (recorded=${d.recorded})`);
} else {
  console.log(`    tier ${task.blast_tier} — auto-approved by the gate, no card shown`);
}

step(5, "Close-out");
for (let i = 0; i < 20 && task.status !== "done"; i++) {
  await sleep(2000);
  if (conn.mode === "direct") await api("POST", "/api/app/tasks/sync");
  ({ task } = await api("GET", `/api/app/tasks/${id}`));
}
if (task.status !== "done") fail(`task did not reach done (status ${task.status})`);
console.log(`    task done; issue ${task.paperclip_issue_key} closed`);

step(6, "Receipt");
const { receipts, approvals } = await api("GET", `/api/app/tasks/${id}`);
for (const x of receipts) console.log(`    ${x.created_at.slice(11, 19)}  ${x.actor.padEnd(6)} ${x.model_used ? `[${x.model_used}] ` : ""}${x.summary}`);
console.log(`    approvals: ${approvals.map((a) => `${a.decision ?? "open"} via ${a.decided_via ?? "-"}`).join(", ") || "none"}`);

const feed = await api("GET", "/api/app/feed");
const mine = feed.events.filter((e) => e.title === task.title);
console.log(`\n    phone feed events for this task: ${mine.map((e) => e.kind).reverse().join(" → ")}`);
console.log("\nPHASE 0 DEMO PASSED");
