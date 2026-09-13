import { test } from "node:test";
import assert from "node:assert/strict";
import { deliveryTierFloor, parseDelivery, ticketText } from "../notify";
import { GhlClient } from "../ghl";
import { isExpoPushToken } from "../push";
import type { TaskRow } from "../db-tasks";

const NOW = new Date("2026-09-16T14:00:00Z");
const task = {
  id: "t1", email: "hawk@example.com", project_id: null, title: "Get the vendor quote for the roof", detail: "Get the vendor quote for the roof by 3pm", capability: "other",
  owner_kind: "human", owner_ref: null, owner_name: "Amari", blast_tier: 2, status: "assigned", confirmation: "",
  due_at: new Date("2026-09-16T19:00:00Z"), check_in_at: null, escalate_at: null, paperclip_issue_id: null, paperclip_issue_key: null,
  result: null, closed_at: null, nudged_at: null, escalated_at: null, deliver_channel: "email", delivered_at: null,
  source: "voice", residency: "cloud", created_at: NOW, updated_at: NOW,
} as TaskRow;

test("the delivery block is validated and the address is never part of what we keep", () => {
  assert.equal(parseDelivery({ channel: "email", to: "not-an-email", name: "Amari" }), null);
  assert.equal(parseDelivery({ channel: "sms", to: "call me", name: "Amari" }), null);
  assert.equal(parseDelivery({ channel: "fax", to: "x@y.co", name: "Amari" }), null);
  const d = parseDelivery({ channel: "email", to: "amari@example.com", name: "Amari Jones", from: "Hawk", audience: "client" });
  assert.ok(d);
  assert.equal(d!.audience, "client");
  assert.equal(deliveryTierFloor(d!), 3);
  assert.equal(deliveryTierFloor(parseDelivery({ channel: "sms", to: "+1 555 123 4567", name: "Amari" })!), 2);
});

test("the ticket says who asked and by when, short, and tier-appropriate", () => {
  const t = ticketText(task, { name: "Amari Jones", from: "Hawk", audience: "team" }, "ticket", NOW, "America/New_York");
  assert.equal(t.subject, "Hawk: Get the vendor quote for the roof");
  assert.match(t.body, /^Hi Amari,/);
  assert.match(t.body, /Hawk asked for a hand with this: Get the vendor quote for the roof by today at 3 pm\./);
  assert.match(t.body, /Reply here when it's done/);
  assert.ok(t.sms.length <= 320);
  assert.match(t.sms, /Amari — Quick nudge|Amari — Hawk asked/);

  const c = ticketText(task, { name: "Dana", from: "Hawk", audience: "client" }, "ticket", NOW, "America/New_York");
  assert.match(c.body, /Hawk asked me to pass this along/);
  assert.match(c.body, /on behalf of Hawk/);

  const r = ticketText(task, { name: "Amari", from: null, audience: "team" }, "reminder", NOW, "America/New_York");
  assert.equal(r.subject, "Reminder: Get the vendor quote for the roof");
  assert.match(r.body, /Quick nudge from the No Hands owner/);
});

test("GHL client: upsert then send, with the v2 headers", async () => {
  const seen: { url: string; init: RequestInit }[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    seen.push({ url, init });
    if (url.endsWith("/contacts/upsert")) return new Response(JSON.stringify({ contact: { id: "ct_1" } }), { status: 200 });
    return new Response(JSON.stringify({ conversationId: "cv_1", messageId: "m_1" }), { status: 201 });
  }) as unknown as typeof fetch;
  const c = new GhlClient({ apiKey: "k", locationId: "loc", fetchImpl });
  const contact = await c.upsertContact({ phone: "+15551234567", name: "Amari" });
  const sent = await c.sendSms(contact.id, "hi", "+15550000000");
  assert.equal(contact.id, "ct_1");
  assert.equal(sent.messageId, "m_1");
  assert.equal(seen[0].url, "https://services.leadconnectorhq.com/contacts/upsert");
  assert.equal(JSON.parse(String(seen[0].init.body)).locationId, "loc");
  const h = seen[1].init.headers as Record<string, string>;
  assert.equal(h.authorization, "Bearer k");
  assert.equal(h.version, "2021-04-15");
  assert.equal(JSON.parse(String(seen[1].init.body)).type, "SMS");
});

test("push tokens are Expo's shape or nothing", () => {
  assert.equal(isExpoPushToken("ExponentPushToken[abc123-XYZ]"), true);
  assert.equal(isExpoPushToken("ExpoPushToken[abc123]"), true);
  assert.equal(isExpoPushToken("apns:deadbeef"), false);
  assert.equal(isExpoPushToken(null), false);
});
