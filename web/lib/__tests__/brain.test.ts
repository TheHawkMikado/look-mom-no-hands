import { test } from "node:test";
import assert from "node:assert/strict";
import { classifyHeuristic, prepareCandidate, RAW_PII, scrub, titleFor } from "../brain";

test("scrub replaces every kind of specific with a placeholder, deterministically", () => {
  const raw = [
    "I'm Hawk Mikado and I paid $1,200 to Dr. Patel on Sept 13, 2026 for the roof.",
    "Call (813) 555-0142 or +44 20 7946 0958, email hawk@hawkmikado.com, 2026-09-13.",
    "Ship to 123 Main Street, Apt 4B, Tampa, FL 33602. Contact: https://app.gohighlevel.com/contacts/8f3a9b2c-1234-4d5e-8f00-abcdef123456?tab=notes",
    "Invoice 9/13/2026 for 350 dollars, card 4111 1111 1111 1111, SSN 123-45-6789.",
  ].join("\n");
  const a = scrub(raw);
  const b = scrub(raw);
  assert.equal(a.text, b.text);
  assert.doesNotMatch(a.text, /hawkmikado|Hawk|Patel|555-0142|7946|Main Street|33602|8f3a9b2c|4111|123-45/);
  assert.match(a.text, /\[email\]/);
  assert.match(a.text, /\[phone\]/);
  assert.match(a.text, /\[amount\]/);
  assert.match(a.text, /\[date\]/);
  assert.match(a.text, /\[address\]/);
  assert.match(a.text, /\[name\]/);
  assert.match(a.text, /\[card\]/);
  assert.match(a.text, /\[id\]/);
  assert.match(a.text, /https:\/\/app\.gohighlevel\.com\/contacts\/\[id\]\?\[params\]/);
  assert.ok(a.replacements.email >= 1 && a.replacements.phone >= 2 && a.replacements.amount >= 2 && a.replacements.date >= 3);
  assert.doesNotMatch(a.text, RAW_PII);
});

test("scrub keeps a generic procedure readable", () => {
  const s = scrub("1. Go to Ads Manager and click Create.\n2. Pick the Leads objective.\n3. Set the daily budget to $20 and submit for review.");
  assert.equal(s.text, "1. Go to Ads Manager and click Create.\n2. Pick the Leads objective.\n3. Set the daily budget to [amount] and submit for review.");
});

test("a URL without an id survives; one with an id is placeholdered", () => {
  assert.equal(scrub("see https://ads.google.com/home").text, "see https://ads.google.com/home");
  assert.equal(scrub("see https://crm.example.com/leads/48213/edit").text, "see https://crm.example.com/leads/[id]/edit");
});

test("the classifier: a repeatable website flow is generic, a first-person fact is not", () => {
  const flow = classifyHeuristic("Every time a lead comes in: open the CRM, click the lead, then tag it 'new' and submit the welcome SMS template.");
  assert.equal(flow.generic, true);
  assert.equal(flow.certain, true);
  const fact = classifyHeuristic("My wife wants us to move to Orlando next year, and I paid the deposit already. First step is the school search.");
  assert.equal(fact.generic, false);
  assert.equal(fact.certain, true);
  const short = classifyHeuristic("click submit");
  assert.equal(short.generic, false);
  const borderline = classifyHeuristic("The process for vendor quotes is basically getting two references before accepting anything from anyone.");
  assert.equal(borderline.certain, false);
  assert.equal(borderline.generic, false, "borderline defaults to no");
});

test("an email or phone can never be stored raw: the only row builder scrubs", () => {
  const c = prepareCandidate(
    "Whenever a tenant applies: email them at tenant@example.com, then call 813-555-0199 to confirm, then log it.",
    "sop",
    classifyHeuristic("x"),
  );
  assert.doesNotMatch(JSON.stringify(c), /tenant@example\.com|555-0199/);
  assert.doesNotMatch(c.body, RAW_PII);
  assert.equal(c.scrubbed.email, 1);
  assert.equal(c.scrubbed.phone, 1);
  assert.equal(c.title, "Whenever a tenant applies: email them at [email], then call [phone] to…");
});

test("titleFor takes the first line or sentence, capitalised and capped", () => {
  assert.equal(titleFor("1. go to settings\n2. click export"), "Go to settings");
  assert.equal(titleFor("send the brief. then wait."), "Send the brief.");
});
