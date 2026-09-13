#!/usr/bin/env node
/**
 * The starter "Content Drafter" agent for Paperclip's `process` adapter.
 *
 * Paperclip runs this on every wake with the run's identity in the environment
 * (PAPERCLIP_API_URL, PAPERCLIP_API_KEY, PAPERCLIP_AGENT_ID, PAPERCLIP_RUN_ID).
 * The contract is simple and it is the same one No Hands relies on:
 *
 *   1. find issues assigned to me that still need work (inbox-lite)
 *   2. check each one out
 *   3. produce the work
 *   4. post it as a COMMENT on the issue and move the issue to in_review
 *
 * Step 4 is what No Hands watches for. It never publishes, sends, or spends —
 * the owner approves that step from the phone.
 *
 * Drafts with Claude when ANTHROPIC_API_KEY is set (passed through by
 * bootstrap.mjs from Scripts/paperclip/.env); otherwise posts a clearly
 * labelled stub so the pipeline can be exercised without a key.
 */
const API = (process.env.PAPERCLIP_API_URL || "http://127.0.0.1:3100").replace(/\/+$/, "");
const KEY = process.env.PAPERCLIP_API_KEY;
const RUN = process.env.PAPERCLIP_RUN_ID || "";
const ANTHROPIC = process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.NOHANDS_DRAFT_MODEL || "claude-opus-5";

if (!KEY) {
  console.error("No PAPERCLIP_API_KEY in the environment. Set PAPERCLIP_AGENT_JWT_SECRET for the server (up.sh does).");
  process.exit(1);
}

async function pc(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: {
      authorization: `Bearer ${KEY}`,
      "content-type": "application/json",
      ...(RUN && method !== "GET" ? { "x-paperclip-run-id": RUN } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = text; }
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${typeof json === "string" ? json : JSON.stringify(json)}`);
  return json;
}

async function draftWithClaude(title, description) {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": ANTHROPIC, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 4000,
      system:
        "You are the Content Drafter on a founder's team. Write the requested piece in full, ready to publish, in the founder's voice: direct, warm, no filler. Return only the piece — no preamble, no options.",
      messages: [{ role: "user", content: `Task: ${title}\n\nDetails:\n${description || "(none)"}` }],
    }),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`Anthropic ${res.status}: ${JSON.stringify(json).slice(0, 300)}`);
  const text = (json.content || []).filter((b) => b.type === "text").map((b) => b.text).join("\n").trim();
  return { text, model: json.model || MODEL, usage: json.usage || null };
}

function stubDraft(title, description) {
  return {
    text: [
      `**[STUB DRAFT — no ANTHROPIC_API_KEY configured for the Content Drafter]**`,
      ``,
      `# ${title}`,
      ``,
      description || "(no details given)",
      ``,
      `_Add ANTHROPIC_API_KEY to Scripts/paperclip/.env and rerun bootstrap.mjs to get real drafts._`,
    ].join("\n"),
    model: "stub",
    usage: null,
  };
}

const me = await pc("GET", "/api/agents/me");
const inbox = await pc("GET", "/api/agents/me/inbox-lite");
const issues = Array.isArray(inbox) ? inbox : inbox?.issues ?? [];
console.log(`[drafter] ${me.name}: ${issues.length} issue(s) in inbox`);

let failures = 0;
for (const brief of issues) {
  try {
    await pc("POST", `/api/issues/${brief.id}/checkout`, {
      agentId: me.id,
      expectedStatuses: ["todo", "backlog", "blocked", "in_review", "in_progress"],
    }).catch((e) => {
      if (!/409/.test(String(e))) throw e; // someone else owns it; skip quietly
      throw new Error("owned by another agent");
    });
    const issue = await pc("GET", `/api/issues/${brief.id}`);
    const comments = await pc("GET", `/api/issues/${brief.id}/comments`);
    if (comments.some((c) => c.authorAgentId === me.id)) {
      console.log(`[drafter] ${issue.identifier}: already drafted, leaving it in review`);
      continue;
    }
    const d = ANTHROPIC ? await draftWithClaude(issue.title, issue.description) : stubDraft(issue.title, issue.description);
    const receipt = d.usage
      ? `\n\n---\n_Drafted by ${d.model} · ${d.usage.input_tokens} in / ${d.usage.output_tokens} out_`
      : `\n\n---\n_Drafted by ${d.model}_`;
    await pc("POST", `/api/issues/${brief.id}/comments`, { body: d.text + receipt });
    await pc("PATCH", `/api/issues/${brief.id}`, { status: "in_review" });
    console.log(`[drafter] ${issue.identifier}: draft posted (${d.text.length} chars, ${d.model})`);
  } catch (e) {
    failures++;
    console.error(`[drafter] ${brief.identifier ?? brief.id}: ${e.message}`);
  }
}
process.exit(failures > 0 && failures === issues.length ? 1 : 0);
