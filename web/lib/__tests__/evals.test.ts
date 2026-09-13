import { test } from "node:test";
import assert from "node:assert/strict";
import { FIXTURES, LOCAL_ENGINES, p50, runDeterministic, scoreDeterministic, type DeterministicCase } from "../evals/run";

const rules = LOCAL_ENGINES.rules;
const local = (text: string) => Promise.resolve({ x: rules(text), ms: 1 });

test("every fixture set has a task_type and enough cases", () => {
  for (const [name, set] of Object.entries(FIXTURES)) {
    assert.equal(set.task_type, name);
    assert.ok(set.cases.length >= 5, `${name} has ${set.cases.length} cases`);
    const ids = new Set(set.cases.map((c) => c.id));
    assert.equal(ids.size, set.cases.length, `${name} has duplicate ids`);
  }
});

test("exact scoring: a case passes only when every expected field matches", () => {
  const cases: DeterministicCase[] = [{ id: "x", text: "t", expected: { capability: "research", blast_tier: 0 } }];
  assert.equal(scoreDeterministic(cases, [{ id: "x", got: { capability: "research", blast_tier: 0 }, ms: 1 }])[0].pass, true);
  assert.equal(scoreDeterministic(cases, [{ id: "x", got: { capability: "research", blast_tier: 2 }, ms: 1 }])[0].pass, false);
  assert.equal(scoreDeterministic(cases, [])[0].note, "no output");
  assert.equal(p50([5, 1, 3]), 3);
});

for (const name of ["intent_classify", "task_extract", "triage_decision"] as const) {
  test(`the rules engine clears the quality floor on ${name} and every miss is explainable`, async () => {
    const set = FIXTURES[name];
    const { outputs } = await runDeterministic(set, local);
    const results = scoreDeterministic(set.cases as DeterministicCase[], outputs);
    const misses = results.filter((r) => !r.pass);
    for (const m of misses) console.log(`  miss ${m.id}: got ${JSON.stringify(m.got)} expected ${JSON.stringify(m.expected)}`);
    const score = results.filter((r) => r.pass).length / results.length;
    console.log(`  ${name}: rules scored ${score.toFixed(2)} (${results.length - misses.length}/${results.length})`);
    assert.ok(score >= 0.6, `rules scored ${score} on ${name}`);
  });
}
