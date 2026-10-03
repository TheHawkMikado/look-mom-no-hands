import { test } from "node:test";
import assert from "node:assert/strict";
import { parseReport } from "../notes";

test("parseReport maps the model's snake_case into the phone's shape", () => {
  assert.deepEqual(
    parseReport({
      title: " Roof repair plan ",
      summary: "Fix the leak before the rains.",
      key_points: ["north side leak", "quote from Bob"],
      action_items: ["call Bob Monday"],
    }),
    {
      title: "Roof repair plan",
      summary: "Fix the leak before the rains.",
      keyPoints: ["north side leak", "quote from Bob"],
      actionItems: ["call Bob Monday"],
    },
  );
});

test("parseReport degrades missing or malformed fields instead of throwing", () => {
  assert.deepEqual(parseReport({ title: 7, key_points: "nope", action_items: ["ok", "", 3] }), {
    title: "",
    summary: "",
    keyPoints: [],
    actionItems: ["ok"],
  });
  assert.deepEqual(parseReport(null), { title: "", summary: "", keyPoints: [], actionItems: [] });
});
