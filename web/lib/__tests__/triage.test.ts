import { test } from "node:test";
import assert from "node:assert/strict";
import { matchAgent, triage } from "../triage";
import { fallbackExtract } from "../extract";

const agents = [
  { id: "a1", name: "Content Drafter", role: "general", title: "Content Drafter", capabilities: "blog posts, social copy" },
  { id: "a2", name: "Researcher", role: "researcher", title: "Researcher", capabilities: null },
  { id: "a3", name: "Summarizer", role: "general", title: "Summarizer", capabilities: null },
];

test("agent first: a drafting request goes to the content agent", () => {
  const x = fallbackExtract("have the content agent draft a post about co-living and bring it to me by 3", null);
  assert.equal(x.capability, "draft_copy");
  assert.equal(x.blast_tier, 0);
  const t = triage(x, agents, true);
  assert.equal(t.owner_kind, "agent");
  assert.equal(t.owner_ref, "a1");
  assert.match(t.confirmation, /Content Drafter/);
});

test("a named agent wins over the capability match", () => {
  assert.equal(matchAgent("draft_copy", "researcher", agents)?.id, "a2");
});

test("research goes to the researcher by role", () => {
  const x = fallbackExtract("research the top three co-living operators in Florida", null);
  assert.equal(triage(x, agents, true).owner_ref, "a2");
});

test("money is never auto-delegated; it reaches the user as a decision", () => {
  const x = fallbackExtract("pay the plumber's invoice", null);
  assert.equal(x.blast_tier, 3);
  const t = triage(x, agents, true);
  assert.equal(t.owner_kind, "user");
});

test("no Paperclip connection: the user keeps the task, and hears why", () => {
  const x = fallbackExtract("draft a newsletter about the new offer", null);
  const t = triage(x, [], false);
  assert.equal(t.owner_kind, "user");
  assert.match(t.confirmation, /Connect a team/);
});

test("questions are not tasks", () => {
  assert.equal(fallbackExtract("what's outstanding from yesterday's meeting?", null).intent, "question");
});

test("titles drop the delegation wrapper and cut at a word boundary", async () => {
  const { titleFrom } = await import("../extract");
  assert.equal(titleFrom("have the content agent write a short LinkedIn post about co-living, and post it"), "Write a short LinkedIn post about co-living");
  assert.equal(titleFrom("please draft a newsletter about the new offer and bring it to me by 3"), "Draft a newsletter about the new offer");
  const long = titleFrom("write " + "word ".repeat(40));
  assert.ok(long.length <= 81 && long.endsWith("…") && !long.includes("wor…"));
});
