#!/usr/bin/env node
/**
 * Phase 5 demo (SPEC.md §9): the ad process as a No Hands project with a
 * budget cap and a review gate, against a running Paperclip (direct mode).
 *
 *  1. Intake "run the ad process for the co-living offer with a $300 cap"
 *     → capability ad_process, $300 cap, tier 3, delegated to the content
 *     agent (an issue in Paperclip).
 *  2. POST /api/app/projects/ad-process {task_id} → project + 7 step issues
 *     under the task's issue (idempotent; intake does this itself once the
 *     hook in lib/tasks.ts is wired).
 *  3. Spend to 80% → one goal_progress event: "Ad process is at 80% of its
 *     $300 cap — keep going?". Spend past the cap → 409, nothing recorded.
 *
 *   NOHANDS_APP_TOKEN=… node scripts/phase5-demo.mjs
 */
const API = (process.env.NOHANDS_API || "http://localhost:3000").replace(/\/+$/, "");
const TOKEN = process.env.NOHANDS_APP_TOKEN;
if (!TOKEN) { console.error("NOHANDS_APP_TOKEN required"); process.exit(2); }

async function api(method, path, body, okStatuses = []) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok && !okStatuses.includes(res.status)) throw new Error(`${method} ${path} → ${res.status}: ${JSON.stringify(json)}`);
  return { status: res.status, ...json };
}
const step = (n, s) => console.log(`\n[${n}] ${s}`);
const fail = (s) => { console.error(`\nFAIL: ${s}`); process.exit(1); };

step(1, `Intake: "run the ad process for the co-living offer with a $300 cap"`);
const r = await api("POST", "/api/app/tasks", { text: "run the ad process for the co-living offer with a $300 cap", source: "voice" });
if (!r.task) fail("no task");
console.log(`    confirmation: ${r.confirmation}`);
console.log(`    capability=${r.extraction.capability} cap=${r.extraction.budget_cap_cents} tier=${r.task.blast_tier} owner=${r.task.owner_kind}/${r.task.owner_name} status=${r.task.status} issue=${r.task.paperclip_issue_key ?? "—"}`);
if (r.extraction.capability !== "ad_process") fail("capability should be ad_process");
if (r.extraction.budget_cap_cents !== 30000) fail("cap should be 30000 cents");
if (r.task.blast_tier < 3) fail("a spend cap floors the tier at 3");

step(2, "Start the ad process for the task (project + step issues)");
const p = await api("POST", "/api/app/projects/ad-process", { task_id: r.task.id });
console.log(`    project ${p.project.id}: "${p.project.title}" cap=${p.project.budget_cap_cents} spent=${p.project.budget_spent_cents} status=${p.project.status}`);
console.log(`    paperclip: ${p.paperclip.issues} issues${p.paperclip.project_id ? ` in project ${p.paperclip.project_id}` : ""}${p.paperclip.error ? ` — ERROR ${p.paperclip.error}` : ""}`);
for (const s of p.steps) console.log(`      ${s.step_no}. ${s.title.padEnd(48)} tier ${s.blast_tier}  ${s.paperclip_issue_key ?? "(no issue)"}${s.assignee_agent_id ? "  → agent" : "  → owner"}`);
if (p.steps.length !== 7) fail("expected 7 steps");
if (p.steps[5].blast_tier !== 2 || p.steps[6].blast_tier !== 3) fail("review gate must be tier 2 and funding tier 3");
if (p.paperclip.error) fail(`Paperclip step issues failed: ${p.paperclip.error}`);
// Intake already started the project (the hook in tasks.ts), so this call
// creates nothing new; what matters is that every step carries an issue.
const withIssues = p.steps.filter((s) => s.paperclip_issue_key).length;
if (withIssues !== 7) fail(`expected 7 Paperclip issues, got ${withIssues} (is the connection in direct mode?)`);
const again = await api("POST", "/api/app/projects/ad-process", { task_id: r.task.id });
if (again.project.id !== p.project.id || again.paperclip.issues !== 0) fail("ad-process start is not idempotent");
console.log("    idempotent: a second start returns the same project and files nothing new");

step(3, "Spend $100, then $140 → crosses 80% of $300 → the owner is asked once");
const s1 = await api("POST", `/api/app/projects/${p.project.id}/spend`, { cents: 10000, note: "Meta ads: angle 1 test" });
console.log(`    after $100: spent=${s1.project.budget_spent_cents} warned=${s1.warned}`);
if (s1.warned) fail("80% must not fire at 33%");
const s2 = await api("POST", `/api/app/projects/${p.project.id}/spend`, { cents: 14000, note: "Meta ads: angles 2–3" });
console.log(`    after $240: spent=${s2.project.budget_spent_cents} warned=${s2.warned} status=${s2.project.status}`);
if (!s2.warned) fail("crossing 80% should ask the owner");
const feed = await api("GET", "/api/app/feed");
const events = feed.events ?? feed.items ?? [];
const ev = events.find((e) => e.id === `${p.project.id}:budget80` || /80% of its \$300 cap/.test(e.detail ?? ""));
if (!ev) fail("no goal_progress event for the 80% line");
console.log(`    event: [${ev.kind}] ${ev.title} — ${ev.detail}`);
const s3 = await api("POST", `/api/app/projects/${p.project.id}/spend`, { cents: 1000, note: "one more" });
if (s3.warned) fail("the 80% question is asked once");
const over = await api("POST", `/api/app/projects/${p.project.id}/spend`, { cents: 10000, note: "over the top" }, [409]);
console.log(`    $100 more → ${over.status}: ${over.error}`);
if (over.status !== 409) fail("a spend past the cap must be refused");

step(4, "The project page: steps, issues and receipts");
const view = await api("GET", `/api/app/projects/${p.project.id}`);
console.log(`    spent ${view.project.budget_spent_cents} / ${view.project.budget_cap_cents}; ${view.receipts.length} receipts`);
for (const rc of view.receipts.slice(-4)) console.log(`      · ${rc.summary}`);
if (view.project.budget_spent_cents !== 25000) fail("the refused spend must not be recorded");

console.log("\nPhase 5 demo passed.");
