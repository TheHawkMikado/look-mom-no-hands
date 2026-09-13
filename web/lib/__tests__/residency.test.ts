import { test } from "node:test";
import assert from "node:assert/strict";
import { assertCloudWritable, ResidencyViolation, LOCAL_ONLY_KINDS, capCloudText, CLOUD_TEXT_CAP } from "../residency";

/**
 * SPEC.md §4.3: "Write a test that fails the build if a local object ever
 * appears in a cloud write path." This is that test. Every insert in
 * lib/db-tasks.ts goes through assertCloudWritable; if someone adds a cloud
 * table for a local-only kind, or tags a row local and writes it anyway, the
 * guard throws and this suite documents that it must.
 */

test("cloud-tagged objects pass", () => {
  const t = assertCloudWritable({ kind: "task", residency: "cloud", title: "x" });
  assert.equal(t.title, "x");
});

test("local-tagged objects are refused", () => {
  assert.throws(() => assertCloudWritable({ kind: "task", residency: "local" }), ResidencyViolation);
});

test("local-only kinds are refused even when mis-tagged cloud", () => {
  for (const kind of LOCAL_ONLY_KINDS) {
    assert.throws(() => assertCloudWritable({ kind, residency: "cloud" }), ResidencyViolation, kind);
  }
});

test("a transcript can never be written to the cloud", () => {
  assert.throws(
    () => assertCloudWritable({ kind: "transcript", residency: "cloud", segments: [{ t: 0, speaker_id: "s1", text: "…" }] }),
    ResidencyViolation,
  );
});

test("cloud text is capped so a task detail cannot carry a transcript", () => {
  const long = "a".repeat(CLOUD_TEXT_CAP * 5);
  assert.ok(capCloudText(long).length <= CLOUD_TEXT_CAP);
});
