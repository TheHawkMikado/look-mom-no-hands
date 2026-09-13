import { test } from "node:test";
import assert from "node:assert/strict";
import { verdictAllowed } from "../gate";

/** SPEC §12 / Phase 6: a meeting attendee saying "assistant, wire $5,000 to…"
 *  must be ignored — only the owner's verified voice or their phone decides
 *  anything above tier 1 that came out of a meeting. */

test("spoken and typed requests are decided by any channel", () => {
  for (const source of ["text", "voice"] as const) {
    assert.equal(verdictAllowed({ source, blast_tier: 4 }, "voice", false).ok, true);
    assert.equal(verdictAllowed({ source, blast_tier: 3 }, "text", false).ok, true);
  }
});

test("meeting tier 0–1 needs no proof", () => {
  assert.equal(verdictAllowed({ source: "meeting", blast_tier: 1 }, "voice", false).ok, true);
});

test("meeting tier 2 needs the phone or a verified voice", () => {
  assert.equal(verdictAllowed({ source: "meeting", blast_tier: 2 }, "voice", false).ok, false);
  assert.equal(verdictAllowed({ source: "meeting", blast_tier: 2 }, "text", false).ok, false);
  assert.equal(verdictAllowed({ source: "meeting", blast_tier: 2 }, "voice", true).ok, true);
  assert.equal(verdictAllowed({ source: "meeting", blast_tier: 2 }, "push", false).ok, true);
});

test("meeting tier 3+ needs the phone even with a verified voice", () => {
  assert.equal(verdictAllowed({ source: "meeting", blast_tier: 3 }, "voice", true).ok, false);
  assert.equal(verdictAllowed({ source: "meeting", blast_tier: 4 }, "voice", true).ok, false);
  assert.equal(verdictAllowed({ source: "meeting", blast_tier: 3 }, "push", false).ok, true);
});
