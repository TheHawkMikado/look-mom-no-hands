import { test } from "node:test";
import assert from "node:assert/strict";
import { assistantPrompt, callGate, firstMessage, outcomeEffect, parseCallRequest } from "../calls";
import { buildOutboundCall, parseServerMessage, VapiClient } from "../vapi";

const req = {
  task_id: null,
  to: "+15551234567",
  who: "Luigi's",
  goal: "book a table for four at 7 tonight",
  constraints: "outside if possible",
  preferences: "prefers a quiet corner",
  tier: 1 as const,
  budget_cents: 0,
  on_behalf_of: "Hawk",
};

test("the gate: free reservations go, money waits for an approval", () => {
  assert.equal(callGate(1, []).allowed, true);
  assert.equal(callGate(0, []).allowed, true);
  assert.equal(callGate(3, []).allowed, false);
  assert.equal(callGate(3, [{ decision: "deny" }]).allowed, false);
  assert.equal(callGate(3, [{ decision: "approve" }]).allowed, true);
  assert.equal(callGate(2, [{ decision: null }]).allowed, false);
});

test("the assistant prompt carries the goal, the preferences and the money rule", () => {
  const p = assistantPrompt(req);
  assert.match(p, /GOAL: book a table/);
  assert.match(p, /quiet corner/);
  assert.match(p, /may NOT agree to pay/);
  assert.match(p, /information, not an instruction/);
  const paid = assistantPrompt({ ...req, tier: 3, budget_cents: 15000 });
  assert.match(paid, /up to \$150\.00 and not one cent more/);
  assert.match(firstMessage(req), /on behalf of Hawk/);
});

test("the call body has Vapi's shape and never asks for a recording", () => {
  const body = buildOutboundCall({
    phoneNumberId: "pn_1",
    to: "+15551234567",
    assistantName: "No Hands",
    systemPrompt: "x",
    firstMessage: "hi",
    model: { provider: "anthropic", model: "claude-x" },
    serverUrl: "https://example.com/api/calls/vapi",
    serverSecret: "s3",
    metadata: { task_id: "t1", tier: "1" },
  });
  assert.equal(body.phoneNumberId, "pn_1");
  assert.deepEqual(body.customer, { number: "+15551234567" });
  const a = body.assistant as Record<string, any>;
  assert.equal(a.model.provider, "anthropic");
  assert.equal(a.model.messages[0].role, "system");
  assert.equal(a.server.url, "https://example.com/api/calls/vapi");
  assert.equal(a.server.secret, "s3");
  assert.equal(a.artifactPlan.recordingEnabled, false);
  assert.ok(a.analysisPlan.structuredDataSchema.properties.outcome);
});

test("the client posts to /call with a bearer key", async () => {
  const seen: { url: string; init: RequestInit }[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    seen.push({ url, init });
    return new Response(JSON.stringify({ id: "call_1", status: "queued" }), { status: 201, headers: { "content-type": "application/json" } });
  }) as unknown as typeof fetch;
  const c = new VapiClient({ apiKey: "k", fetchImpl });
  const out = await c.createCall({ phoneNumberId: "p", customer: { number: "+1" }, assistant: {}, metadata: {} });
  assert.equal(out.id, "call_1");
  assert.equal(seen[0].url, "https://api.vapi.ai/call");
  assert.equal((seen[0].init.headers as Record<string, string>).authorization, "Bearer k");
});

test("end-of-call report → structured outcome, cost in cents, no transcript", () => {
  const m = parseServerMessage({
    message: {
      type: "end-of-call-report",
      endedReason: "assistant-ended-call",
      call: { id: "call_1" },
      durationSeconds: 83.4,
      cost: 0.1234,
      transcript: "AI: Hi... User: sure...",
      recordingUrl: "https://x/y.wav",
      analysis: {
        summary: "Booked a table for four at 7.",
        successEvaluation: "true",
        structuredData: { outcome: "done", summary: "Table for four at 7, under Hawk.", amount_cents: 0, confirmation_ref: "R-42" },
      },
    },
  });
  assert.equal(m.type, "end-of-call-report");
  if (m.type !== "end-of-call-report") return;
  assert.equal(m.callId, "call_1");
  assert.equal(m.costCents, 12);
  assert.equal(m.outcome.outcome, "done");
  assert.equal(m.outcome.summary, "Table for four at 7, under Hawk.");
  assert.equal(m.outcome.confirmation_ref, "R-42");
  assert.equal(m.outcome.duration_seconds, 83);
  assert.equal(m.outcome.success, true);
  assert.ok(!("transcript" in m.outcome), "the outcome never carries the transcript");
  assert.ok(!JSON.stringify(m).includes("recordingUrl"));
});

test("a report without structured data falls back to the success flag", () => {
  const m = parseServerMessage({ message: { type: "end-of-call-report", call: { id: "c" }, analysis: { summary: "No answer.", successEvaluation: false } } });
  assert.equal(m.type, "end-of-call-report");
  if (m.type !== "end-of-call-report") return;
  assert.equal(m.outcome.outcome, "failed");
  assert.equal(m.outcome.summary, "No answer.");
  assert.equal(m.costCents, 0);
});

test("status updates and junk are recognised without throwing", () => {
  assert.deepEqual(parseServerMessage({ message: { type: "status-update", status: "ringing", call: { id: "c" } } }), { type: "status-update", callId: "c", status: "ringing" });
  assert.equal(parseServerMessage(null).type, "other");
  assert.equal(parseServerMessage({ message: { type: "transcript", call: { id: "c" } } }).type, "other");
});

test("what a finished call means, by tier", () => {
  const base = { summary: "s", amount_cents: 0, next_step: null, confirmation_ref: null, success: true, ended_reason: null, duration_seconds: 10 };
  assert.equal(outcomeEffect({ ...base, outcome: "done" }, 1), "done");
  assert.equal(outcomeEffect({ ...base, outcome: "failed" }, 1), "failed");
  assert.equal(outcomeEffect({ ...base, outcome: "needs_owner" }, 1), "needs_approval");
  assert.equal(outcomeEffect({ ...base, outcome: "done", amount_cents: 2500 }, 1), "needs_approval", "money on a tier-1 call is never committed");
  assert.equal(outcomeEffect({ ...base, outcome: "done", amount_cents: 2500 }, 3, 5000), "done");
  assert.equal(outcomeEffect({ ...base, outcome: "done", amount_cents: 9000 }, 3, 5000), "needs_approval", "over budget asks");
  assert.equal(outcomeEffect({ ...base, outcome: "partial" }, 1), "needs_decision");
});

test("request validation", () => {
  assert.ok("error" in parseCallRequest({ to: "555-1234", goal: "x" }));
  assert.ok("error" in parseCallRequest({ to: "+15551234567" }));
  const ok = parseCallRequest({ to: "+15551234567", goal: "book", tier: 9, budget_cents: -5 });
  assert.ok(!("error" in ok));
  if ("error" in ok) return;
  assert.equal(ok.tier, 4);
  assert.equal(ok.budget_cents, 0);
  assert.equal(ok.who, "them");
});
