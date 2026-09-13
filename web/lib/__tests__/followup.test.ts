import { test } from "node:test";
import assert from "node:assert/strict";
import { escalationQuestion, summarize } from "../followup";
import type { TaskRow } from "../db-tasks";
import { HOUR } from "../when";

// Wednesday 2026-09-16 16:30 New York (EDT) = 20:30Z.
const TZ = "America/New_York";
const NOW = new Date("2026-09-16T20:30:00Z");

function task(p: Partial<TaskRow>): TaskRow {
  return {
    id: "t1", email: "hawk@example.com", project_id: null, title: "Get the vendor quote", detail: "", capability: "other",
    owner_kind: "human", owner_ref: null, owner_name: "Amari", blast_tier: 2, status: "assigned", confirmation: "",
    due_at: new Date("2026-09-16T19:00:00Z"), check_in_at: null, escalate_at: null, paperclip_issue_id: null, paperclip_issue_key: null,
    result: null, closed_at: null, nudged_at: null, escalated_at: null, deliver_channel: "email", delivered_at: null,
    source: "voice", residency: "cloud", created_at: NOW, updated_at: NOW, ...p,
  };
}

test("escalation is one question with a default, phrased for the owner kind", () => {
  const h = escalationQuestion(task({}), NOW, TZ);
  assert.equal(h.question, `Amari hasn't come back on "Get the vendor quote" — it was due today at 3 pm. Nudge again tomorrow morning, or handle it yourself?`);
  assert.equal(h.default_answer, "nudge");

  const a = escalationQuestion(task({ owner_kind: "agent", owner_name: "Content Drafter", status: "in_progress", due_at: null }), NOW, TZ);
  assert.match(a.question, /^Content Drafter hasn't delivered "Get the vendor quote"\. Nudge again tomorrow morning/);

  const u = escalationQuestion(task({ owner_kind: "user", owner_name: null, status: "needs_decision" }), NOW, TZ);
  assert.match(u.question, /still waiting on you\. Decide now, or push it to tomorrow morning\?/);
  assert.equal(u.default_answer, "push");

  const friday = new Date("2026-09-18T20:30:00Z");
  assert.match(escalationQuestion(task({}), friday, TZ).question, /Nudge again Monday morning/);
});

test("the outstanding summary counts by owner and speaks the top three", () => {
  const tasks = [
    task({ id: "1", title: "Vendor quote", due_at: new Date(NOW.getTime() - 2 * HOUR) }),
    task({ id: "2", title: "Draft the post", owner_kind: "agent", owner_name: "Content Drafter", status: "in_progress", due_at: new Date(NOW.getTime() + 2 * HOUR) }),
    task({ id: "3", title: "Approve the ad", owner_kind: "user", owner_name: null, status: "awaiting_approval", due_at: null }),
    task({ id: "4", title: "Fourth thing", owner_kind: "user", owner_name: null, status: "needs_decision", due_at: null }),
  ];
  const o = summarize(tasks, NOW, TZ);
  assert.deepEqual(o.counts, { total: 4, agent: 1, human: 1, user: 2, overdue: 1, awaiting_approval: 1 });
  assert.equal(o.top.length, 3);
  assert.equal(o.top[0].overdue, true);
  assert.equal(o.spoken, "4 outstanding: 1 with agents, 1 with the team, 2 waiting on you; 1 overdue; 1 awaiting your approval. Top: Vendor quote (Amari, was due today at 2:30 pm); Draft the post (Content Drafter, due today at 6:30 pm); Approve the ad (you).");
  assert.equal(summarize([], NOW, TZ).spoken, "Nothing outstanding. You're clear.");
});
