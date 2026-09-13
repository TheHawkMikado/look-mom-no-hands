import { test } from "node:test";
import assert from "node:assert/strict";
import { floorTierFor, resolveTier, needsApproval, clampTier } from "../tiers";

test("drafting is tier 0", () => {
  assert.equal(floorTierFor("have the content agent draft a post about co-living and bring it to me"), 0);
});

test("publishing is at least tier 2", () => {
  assert.equal(floorTierFor("publish the blog post about co-living"), 2);
  assert.equal(floorTierFor("post it to LinkedIn"), 2);
});

test("money is at least tier 3", () => {
  assert.equal(floorTierFor("pay the invoice from the plumber"), 3);
  assert.equal(floorTierFor("book a tow truck"), 3);
  assert.equal(floorTierFor("send an email to the client about the delay"), 3);
});

test("irreversible is tier 4", () => {
  assert.equal(floorTierFor("delete all the old transcripts"), 4);
  assert.equal(floorTierFor("cancel my contract with the vendor"), 4);
});

test("the model can raise a tier but never lower it below the floor", () => {
  assert.equal(resolveTier("pay the invoice", 0), 3);
  assert.equal(resolveTier("draft a post", 2), 2);
  assert.equal(resolveTier("draft a post", 9), 4);
  assert.equal(resolveTier("draft a post", "nope"), 0);
});

test("approval is required from tier 2", () => {
  assert.equal(needsApproval(0), false);
  assert.equal(needsApproval(1), false);
  assert.equal(needsApproval(2), true);
  assert.equal(needsApproval(4), true);
  assert.equal(clampTier(-3), 0);
});
