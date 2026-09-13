import { test } from "node:test";
import assert from "node:assert/strict";
import { buildSnapshot } from "../team";

const raw = {
  agents: [
    { id: "a1", name: "Content Drafter", role: "general", title: "Content Drafter", status: "idle" },
    { id: "a2", name: "Researcher", role: "researcher", title: "Researcher", status: "running" },
  ],
  members: [
    { id: "m1", principalType: "user", principalId: "u1", status: "active", membershipRole: "owner", user: { id: "u1", email: "hawk@example.com", name: "Hawk" } },
    { id: "m2", principalType: "user", principalId: "u2", status: "inactive", membershipRole: "member", user: { id: "u2", email: "gone@example.com", name: "Gone" } },
  ],
  issues: [
    { id: "i1", identifier: "NOH-1", title: "Draft post", status: "in_review", priority: "medium", assigneeAgentId: "a1", assigneeUserId: null, updatedAt: "2026-09-13T01:00:00Z" },
    { id: "i2", identifier: "NOH-2", title: "Old one", status: "done", priority: "medium", assigneeAgentId: "a1", assigneeUserId: null, updatedAt: "2026-09-13T00:00:00Z" },
    { id: "i3", identifier: "NOH-3", title: "Compare vendors", status: "in_progress", priority: "high", assigneeAgentId: "a2", assigneeUserId: null, updatedAt: "2026-09-13T02:00:00Z" },
    { id: "i4", identifier: "NOH-4", title: "Sign the lease", status: "todo", priority: "medium", assigneeAgentId: null, assigneeUserId: "u1", updatedAt: "2026-09-13T03:00:00Z" },
    { id: "i5", identifier: "NOH-5", title: "Nobody's yet", status: "backlog", priority: "low", assigneeAgentId: null, assigneeUserId: null, updatedAt: "2026-09-13T04:00:00Z" },
  ],
};

test("every member gets a board: bots and humans", () => {
  const s = buildSnapshot(raw, "c1");
  assert.deepEqual(s.members.map((m) => `${m.kind}:${m.name}`), ["agent:Content Drafter", "agent:Researcher", "human:Hawk"]);
  assert.equal(s.members[0].items.length, 1, "done issues are not on the board");
  assert.equal(s.members[0].items[0].key, "NOH-1");
  assert.equal(s.members[2].items[0].title, "Sign the lease");
});

test("inactive members are dropped and unassigned work is visible", () => {
  const s = buildSnapshot(raw, "c1");
  assert.ok(!s.members.some((m) => m.name === "Gone"));
  assert.deepEqual(s.unassigned.map((i) => i.key), ["NOH-5"]);
  assert.deepEqual(s.counts, { open: 4, in_progress: 1, in_review: 1, blocked: 0 });
});

test("agent runtime status rides along", () => {
  const s = buildSnapshot(raw, "c1");
  assert.equal(s.members[1].status, "running");
});
