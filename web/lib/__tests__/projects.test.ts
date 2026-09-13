import { test } from "node:test";
import assert from "node:assert/strict";
import { adProcessPlan, crossed80, dollars, offerFrom } from "../projects";
import { fallbackExtract } from "../extract";
import { triage } from "../triage";

test("the ad process is seven ordered steps with a review gate before publish", () => {
  const paid = adProcessPlan("the co-living offer", 30000);
  assert.deepEqual(paid.map((s) => s.key), ["research", "angles", "variants", "images", "compliance", "review", "publish"]);
  assert.equal(paid[5].blast_tier, 2, "review gate is tier 2");
  assert.equal(paid[6].blast_tier, 3, "funding is tier 3");
  assert.match(paid[6].detail, /\$300 cap/);
  const unpaid = adProcessPlan("the co-living offer", null);
  assert.equal(unpaid[6].blast_tier, 2, "staging without a budget is tier 2");
  assert.ok(paid.slice(0, 5).every((s) => s.blast_tier === 0), "drafting steps are internal");
  assert.equal(paid[5].role, null, "the gate belongs to the owner");
});

test("intake text → ad_process, $300 cap, tier 3, content agent owns it", () => {
  const x = fallbackExtract("run the ad process for the co-living offer with a $300 cap", null);
  assert.equal(x.capability, "ad_process");
  assert.equal(x.budget_cap_cents, 30000);
  assert.equal(x.blast_tier, 3);
  assert.equal(offerFrom(x.title, x.detail), "co-living");
  const t = triage(x, [{ id: "a1", name: "Content Drafter", role: "general", title: "Content Drafter", capabilities: "social copy" }], true);
  assert.equal(t.owner_ref, "a1");
  assert.match(t.confirmation, /run the ad process for/);
});

test("80% is crossed exactly once and never without a cap", () => {
  assert.equal(crossed80(0, 24000, 30000), true);
  assert.equal(crossed80(24000, 25000, 30000), false);
  assert.equal(crossed80(20000, 23999, 30000), false);
  assert.equal(crossed80(0, 1000, 0), false);
  assert.equal(dollars(30000), "$300");
  assert.equal(dollars(120050), "$1,200.50");
});
