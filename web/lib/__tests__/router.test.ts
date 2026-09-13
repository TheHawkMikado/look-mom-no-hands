import { test } from "node:test";
import assert from "node:assert/strict";
import { rank, resolve } from "../router";
import { ROUTING_SEED } from "../routing-seed";

test("highest score above the floor wins, cost breaks ties", () => {
  const rows = ROUTING_SEED.filter((r) => r.task_type === "task_extract");
  const r = resolve("task_extract", rows);
  assert.equal(r?.model, "claude-opus-5");
  assert.equal(r?.candidates.length, 2);
  assert.equal(r?.candidates[1].model, "claude-haiku-4-5");
});

test("latency-first task types pick the fastest eligible model", () => {
  const ranked = rank([
    { task_type: "intent_classify", model: "slow-smart", provider: "anthropic", score: 0.95, cost_per_1k: 1, latency_p50: 3000, latency_first: true },
    { task_type: "intent_classify", model: "fast-ok", provider: "anthropic", score: 0.7, cost_per_1k: 0.1, latency_p50: 400, latency_first: true },
  ]);
  assert.equal(ranked[0].model, "fast-ok");
});

test("below-floor models are only used when nothing else exists", () => {
  const ranked = rank([
    { task_type: "code_change", model: "weak", provider: "anthropic", score: 0.3, cost_per_1k: 0, latency_p50: 1, latency_first: false },
  ]);
  assert.equal(ranked[0].model, "weak");
  const withGood = rank([
    { task_type: "code_change", model: "weak", provider: "anthropic", score: 0.3, cost_per_1k: 0, latency_p50: 1, latency_first: false },
    { task_type: "code_change", model: "good", provider: "anthropic", score: 0.8, cost_per_1k: 5, latency_p50: 9000, latency_first: false },
  ]);
  assert.equal(withGood.length, 1);
  assert.equal(withGood[0].model, "good");
});

test("every seed row has a model and provider", () => {
  for (const r of ROUTING_SEED) {
    assert.ok(r.model && r.provider, r.task_type);
    assert.ok(r.score >= 0 && r.score <= 1);
  }
});
