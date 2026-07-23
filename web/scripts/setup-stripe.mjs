#!/usr/bin/env node
/**
 * One-shot Stripe setup: products, weekly prices, and the webhook endpoint.
 *
 *   STRIPE_SECRET_KEY=sk_... node scripts/setup-stripe.mjs
 *   STRIPE_SECRET_KEY=sk_... node scripts/setup-stripe.mjs --print-env
 *
 * Safe to re-run. Prices are matched by `lookup_key` and products by metadata,
 * so a second run reports what already exists instead of creating duplicates —
 * which matters because Stripe prices are immutable and a stray duplicate is
 * the kind of thing you only notice in a reconciliation months later.
 *
 * The one thing it will not silently redo is the webhook endpoint: Stripe
 * returns a signing secret only at creation, so an existing endpoint for the
 * same URL is left alone and reported rather than replaced.
 */

import Stripe from "stripe";

const KEY = process.env.STRIPE_SECRET_KEY;
if (!KEY) {
  console.error("STRIPE_SECRET_KEY is not set.");
  process.exit(1);
}

const stripe = new Stripe(KEY);
const LIVE = KEY.startsWith("sk_live_");
const SITE = process.env.SITE_URL ?? "https://nohandsapp.com";
const WEBHOOK_URL = `${SITE}/api/stripe/webhook`;

/** Must stay in step with PRICE_ENV and PLANS in lib/stripe.ts. */
const CATALOGUE = [
  {
    key: "solo",
    env: "STRIPE_PRICE_SOLO",
    name: "Look Ma No Hands App - Solo",
    description: "2 computers and 1 phone. Billed weekly, cancel any time.",
    cents: 300,
  },
  {
    key: "family",
    env: "STRIPE_PRICE_FAMILY",
    name: "Look Ma No Hands App - Family",
    description: "9 computers and 9 phones. Billed weekly, cancel any time.",
    cents: 900,
  },
  {
    key: "unlimited",
    env: "STRIPE_PRICE_UNLIMITED",
    name: "Look Ma No Hands App - Unlimited",
    description:
      "Unlimited computers and phones, plus resell rights. Includes 27 Solo " +
      "sub-users; each additional user is $1/week. Billed weekly.",
    cents: 2700,
  },
];

/**
 * The events the webhook actually handles. `invoice.paid` is the load-bearing
 * one — licences are valid only to the end of the period Stripe has collected
 * for, so without it every subscriber stops working after their first week.
 */
const EVENTS = [
  "checkout.session.completed",
  "invoice.paid",
  "customer.subscription.deleted",
];

const log = (...a) => console.log(...a);

async function findProduct(lookup) {
  // `search` is eventually consistent on brand-new objects; listing is exact,
  // and the catalogue is three items, so just scan.
  for await (const p of stripe.products.list({ limit: 100, active: true })) {
    if (p.metadata?.nohands_plan === lookup) return p;
  }
  return null;
}

async function findPrice(lookupKey) {
  const found = await stripe.prices.list({ lookup_keys: [lookupKey], limit: 1 });
  return found.data[0] ?? null;
}

async function ensurePlan(item) {
  const lookupKey = `nohands_${item.key}_weekly`;

  let price = await findPrice(lookupKey);
  if (price) {
    log(`  ✓ ${item.key.padEnd(9)} price exists   ${price.id}`);
    return { env: item.env, id: price.id, created: false };
  }

  let product = await findProduct(item.key);
  if (product) {
    log(`  · ${item.key.padEnd(9)} product exists ${product.id}`);
  } else {
    product = await stripe.products.create({
      name: item.name,
      description: item.description,
      metadata: { nohands_plan: item.key },
    });
    log(`  + ${item.key.padEnd(9)} product created ${product.id}`);
  }

  price = await stripe.prices.create({
    product: product.id,
    unit_amount: item.cents,
    currency: "usd",
    recurring: { interval: "week", interval_count: 1 },
    lookup_key: lookupKey,
    metadata: { nohands_plan: item.key },
  });
  log(`  + ${item.key.padEnd(9)} price created   ${price.id}  $${item.cents / 100}/wk`);
  return { env: item.env, id: price.id, created: true };
}

async function ensureWebhook() {
  const existing = await stripe.webhookEndpoints.list({ limit: 100 });
  const match = existing.data.find((e) => e.url === WEBHOOK_URL);

  if (match) {
    const missing = EVENTS.filter((e) => !match.enabled_events.includes(e));
    if (missing.length) {
      await stripe.webhookEndpoints.update(match.id, { enabled_events: EVENTS });
      log(`  ~ webhook updated, added: ${missing.join(", ")}`);
    } else {
      log(`  ✓ webhook exists ${match.id}`);
    }
    // Stripe only ever hands back the signing secret at creation time.
    log(`  ! signing secret not retrievable for an existing endpoint —`);
    log(`    copy it from the Stripe dashboard, or delete the endpoint and re-run.`);
    return null;
  }

  const created = await stripe.webhookEndpoints.create({
    url: WEBHOOK_URL,
    enabled_events: EVENTS,
    description: "nohandsapp.com licence issuance",
  });
  log(`  + webhook created ${created.id} -> ${WEBHOOK_URL}`);
  return created.secret;
}

const account = await stripe.accounts.retrieve().catch(() => null);
log("");
log(`Stripe setup — ${LIVE ? "LIVE MODE" : "test mode"}${account?.id ? `  (${account.id})` : ""}`);
log(`Webhook target: ${WEBHOOK_URL}`);
log("");

log("Products and prices:");
const results = [];
for (const item of CATALOGUE) results.push(await ensurePlan(item));

log("");
log("Webhook:");
const secret = await ensureWebhook();

log("");
log("Environment variables to set:");
log("");
for (const r of results) log(`  ${r.env}=${r.id}`);
if (secret) log(`  STRIPE_WEBHOOK_SECRET=${secret}`);
log("");

if (process.argv.includes("--print-env")) {
  // Machine-readable tail, so the caller can pipe straight into `vercel env add`.
  console.log("---ENV---");
  for (const r of results) console.log(`${r.env}=${r.id}`);
  if (secret) console.log(`STRIPE_WEBHOOK_SECRET=${secret}`);
}
