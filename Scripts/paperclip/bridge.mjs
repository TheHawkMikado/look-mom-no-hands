#!/usr/bin/env node
/**
 * The bridge: lets a Paperclip on YOUR machine work for your No Hands account
 * even though the web service can't reach localhost. It polls the account's
 * work list, does the Paperclip calls, and reports what it saw. All state
 * lives in the web service; this process can be restarted at any time.
 *
 *   node Scripts/paperclip/bridge.mjs
 *
 * Reads .connection.json (from bootstrap.mjs). Env: NOHANDS_APP_TOKEN
 * overrides the token; BRIDGE_INTERVAL_MS (default 5000).
 */
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const conn = JSON.parse(readFileSync(resolve(HERE, ".connection.json"), "utf8"));
const TOKEN = process.env.NOHANDS_APP_TOKEN || conn.token;
if (!TOKEN) {
  console.error("No app token. Run bootstrap.mjs with NOHANDS_APP_TOKEN first.");
  process.exit(1);
}
const API = (process.env.NOHANDS_API || conn.api || "https://nohandsapp.com").replace(/\/+$/, "");
const PC = conn.url.replace(/\/+$/, "");
const INTERVAL = Number(process.env.BRIDGE_INTERVAL_MS || 5000);

async function http(base, method, path, body, auth) {
  const res = await fetch(`${base}${path}`, {
    method,
    headers: { "content-type": "application/json", ...(auth ? { authorization: `Bearer ${auth}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = text; }
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${typeof json === "string" ? json : JSON.stringify(json)}`);
  return json;
}
const web = (m, p, b) => http(API, m, p, b, TOKEN);
const pc = (m, p, b) => http(PC, m, p, b, null);

function latestAgentComment(comments) {
  const byAgent = comments.filter((c) => c.authorAgentId);
  return byAgent.length ? byAgent.reduce((a, b) => (a.createdAt > b.createdAt ? a : b)) : null;
}

let lastAgentsSync = 0;
let lastBoardSync = 0;
const BOARD_EVERY_MS = Number(process.env.BRIDGE_BOARD_MS || 15000);
async function round() {
  const work = await web("GET", "/api/app/bridge/work");
  const observations = [];
  for (const c of work.create) {
    try {
      const issue = await pc("POST", `/api/companies/${work.company_id}/issues`, {
        title: c.title, description: c.description, status: "todo", priority: "medium", assigneeAgentId: c.assignee_agent_id,
      });
      observations.push({ task_id: c.task_id, issue: { id: issue.id, identifier: issue.identifier, status: issue.status } });
      console.log(`[bridge] created ${issue.identifier} for task ${c.task_id}`);
    } catch (e) {
      observations.push({ task_id: c.task_id, error: e.message });
    }
  }
  for (const w of work.watch) {
    try {
      const [issue, comments] = await Promise.all([pc("GET", `/api/issues/${w.issue_id}`), pc("GET", `/api/issues/${w.issue_id}/comments`)]);
      const draft = latestAgentComment(comments);
      observations.push({ task_id: w.task_id, issue: { id: issue.id, identifier: issue.identifier, status: issue.status }, draft: draft?.body ?? null });
    } catch (e) {
      observations.push({ task_id: w.task_id, error: e.message });
    }
  }
  for (const k of work.close) {
    try {
      await pc("POST", `/api/issues/${k.issue_id}/comments`, { body: k.approved ? "Approved by the owner via No Hands." : "Denied by the owner via No Hands." });
      await pc("PATCH", `/api/issues/${k.issue_id}`, { status: k.approved ? "done" : "cancelled" }).catch(() =>
        pc("PATCH", `/api/issues/${k.issue_id}`, { status: "done" }));
      observations.push({ task_id: k.task_id, closed: true });
      console.log(`[bridge] closed ${k.issue_id} (${k.approved ? "approved" : "denied"})`);
    } catch (e) {
      observations.push({ task_id: k.task_id, error: e.message });
    }
  }
  // Follow-up engine (SPEC.md §5.4): an agent past its check-in with nothing
  // delivered gets its heartbeat invoked. The web service decides *who*; we
  // only make the call and say we did.
  for (const n of work.nudge ?? []) {
    try {
      await pc("POST", `/api/agents/${n.agent_id}/heartbeat/invoke`, { reason: "on_demand" });
      observations.push({ task_id: n.task_id, nudged: true });
      console.log(`[bridge] nudged agent ${n.agent_id} for task ${n.task_id}`);
    } catch (e) {
      observations.push({ task_id: n.task_id, error: `nudge: ${e.message}` });
    }
  }
  // Refresh the agent roster every few minutes so newly hired agents become
  // eligible for triage without rerunning bootstrap.
  let agents;
  if (Date.now() - lastAgentsSync > 5 * 60_000) {
    agents = (await pc("GET", `/api/companies/${work.company_id}/agents`)).map((a) => ({ id: a.id, name: a.name, role: a.role, title: a.title ?? null, capabilities: a.capabilities ?? null }));
    lastAgentsSync = Date.now();
  }
  // The team board: every member's open issues, humans and bots. Titles and
  // statuses only — descriptions and comments never leave Paperclip.
  let board = null;
  if (Date.now() - lastBoardSync > BOARD_EVERY_MS) {
    const [ag, mem, issues] = await Promise.all([
      pc("GET", `/api/companies/${work.company_id}/agents`),
      pc("GET", `/api/companies/${work.company_id}/members`).catch(() => ({ members: [] })),
      pc("GET", `/api/companies/${work.company_id}/issues?status=backlog,todo,in_progress,in_review,blocked`),
    ]);
    board = {
      agents: ag.map((a) => ({ id: a.id, name: a.name, role: a.role, title: a.title ?? null, status: a.status ?? null })),
      members: (mem.members ?? []).map((m) => ({ id: m.id, principalType: m.principalType, principalId: m.principalId, status: m.status, membershipRole: m.membershipRole, user: m.user ? { id: m.user.id, email: m.user.email ?? null, name: m.user.name ?? null } : null })),
      issues: issues.map((i) => ({ id: i.id, identifier: i.identifier ?? null, title: i.title, status: i.status, priority: i.priority ?? null, assigneeAgentId: i.assigneeAgentId ?? null, assigneeUserId: i.assigneeUserId ?? null, updatedAt: i.updatedAt })),
    };
    lastBoardSync = Date.now();
  }
  if (observations.length || agents || board) await web("POST", "/api/app/bridge/report", { observations, agents, board });
}

console.log(`[bridge] ${PC} ⇄ ${API} every ${INTERVAL} ms`);
for (;;) {
  try { await round(); } catch (e) { console.error(`[bridge] ${e.message}`); }
  await new Promise((r) => setTimeout(r, INTERVAL));
}
