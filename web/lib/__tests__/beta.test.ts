import { test } from "node:test";
import assert from "node:assert/strict";
import { betaPriceDollars, parseBetaCode, normaliseBetaCode } from "../beta";

test("BETA## is dollars off, 1–99", () => {
  assert.equal(parseBetaCode("BETA50"), 50);
  assert.equal(parseBetaCode("beta30"), 30);
  assert.equal(parseBetaCode(" BETA-99 "), 99);
  assert.equal(parseBetaCode("BETA1"), 1);
});

test("anything else is not a code", () => {
  for (const bad of ["BETA0", "BETA100", "BETA", "BETA5x", "FRIEND50", "", null, undefined]) {
    assert.equal(parseBetaCode(bad as string), null, String(bad));
  }
});

test("price is 99 minus the code, never below zero", () => {
  assert.equal(betaPriceDollars(undefined), 99);
  assert.equal(betaPriceDollars("BETA30"), 69);
  assert.equal(betaPriceDollars("BETA50"), 49);
  assert.equal(betaPriceDollars("BETA99"), 0);
  assert.equal(betaPriceDollars("nonsense"), 99);
});

test("codes normalise for logging", () => {
  assert.equal(normaliseBetaCode(" beta 50 "), "BETA50");
});
