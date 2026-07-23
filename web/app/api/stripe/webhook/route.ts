import { NextRequest, NextResponse } from "next/server";
import {
  createLicence,
  endSubscription,
  ensureSchema,
  extendSubscription,
  licenceForSession,
} from "@/lib/db";
import { mintLicenceKey } from "@/lib/licence";
import { planForPrice, stripe } from "@/lib/stripe";
import { sendLicenceEmail } from "@/lib/email";

/**
 * POST /api/stripe/webhook — the only place a licence is created or extended.
 *
 * Trusting the browser's "payment succeeded!" redirect instead would let anyone
 * mint themselves a licence by visiting /success. The signature check below is
 * what makes this endpoint authoritative, so it must read the *raw* body:
 * re-serialising parsed JSON changes bytes and the signature stops matching.
 *
 * Everything bills weekly, so a licence is only ever valid until the end of the
 * period Stripe has actually collected for. `invoice.paid` is therefore not
 * optional bookkeeping — without it every subscriber stops working after their
 * first week.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const signature = req.headers.get("stripe-signature");
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!signature || !secret) {
    return NextResponse.json({ error: "Not configured." }, { status: 400 });
  }

  const raw = await req.text();
  let event;
  try {
    event = stripe().webhooks.constructEvent(raw, signature, secret);
  } catch (err) {
    console.error("bad webhook signature", err);
    return NextResponse.json({ error: "Bad signature." }, { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed":
        await onCheckoutCompleted(event.data.object);
        break;

      // Fires on the first charge and on every weekly renewal thereafter.
      case "invoice.paid":
        await onInvoicePaid(event.data.object);
        break;

      // Cancelled, or dunning gave up. The app keeps working through its short
      // grace window, so this is never an abrupt mid-session cut.
      case "customer.subscription.deleted":
        await onSubscriptionEnded(event.data.object);
        break;
    }
  } catch (err) {
    // 500 asks Stripe to retry — better than swallowing a failure and leaving a
    // paying customer with no key.
    console.error(`handling ${event.type} failed`, err);
    return NextResponse.json({ error: "Handler failed." }, { status: 500 });
  }

  return NextResponse.json({ received: true });
}

/** Stripe moved period fields onto the subscription item; fall back for older shapes. */
function periodEnd(subscription: any): Date {
  const seconds =
    subscription?.items?.data?.[0]?.current_period_end ??
    subscription?.current_period_end;
  if (typeof seconds === "number") return new Date(seconds * 1000);
  // A week from now is the right guess when the shape surprises us: it matches
  // the billing cadence, and the next invoice.paid corrects it anyway.
  console.warn("no current_period_end on subscription; defaulting to +7d");
  return new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
}

async function onCheckoutCompleted(session: any) {
  await ensureSchema();

  // Stripe redelivers events; the unique index on stripe_session makes this
  // idempotent, but bailing early also avoids a second email.
  if (await licenceForSession(session.id)) return;

  const email: string | null =
    session.customer_details?.email ?? session.customer_email ?? null;
  if (!email) throw new Error(`session ${session.id} has no email`);

  const items = await stripe().checkout.sessions.listLineItems(session.id, { limit: 1 });
  const spec = planForPrice(items.data[0]?.price?.id ?? "");

  const subscriptionId =
    typeof session.subscription === "string" ? session.subscription : session.subscription?.id;
  if (!subscriptionId) throw new Error(`session ${session.id} has no subscription`);

  const subscription = await stripe().subscriptions.retrieve(subscriptionId);

  const key = mintLicenceKey();
  await createLicence({
    key,
    email,
    plan: spec.plan,
    expiresAt: periodEnd(subscription),
    seats: spec.computers,
    phones: spec.phones,
    subUsers: spec.subUsers,
    resell: spec.resell,
    stripeSession: session.id,
    stripeCustomer: typeof session.customer === "string" ? session.customer : null,
    stripeSubscription: subscriptionId,
  });

  // A failed send must not fail the webhook — the key is already saved and the
  // success page shows it, so retrying would only duplicate mail.
  try {
    await sendLicenceEmail(email, key);
  } catch (err) {
    console.error("licence email failed (key was still issued)", err);
  }
}

async function onInvoicePaid(invoice: any) {
  const subscriptionId =
    typeof invoice.subscription === "string"
      ? invoice.subscription
      : invoice.subscription?.id ?? invoice.parent?.subscription_details?.subscription;
  if (!subscriptionId) return;

  await ensureSchema();
  const subscription = await stripe().subscriptions.retrieve(subscriptionId);
  await extendSubscription(subscriptionId, periodEnd(subscription));
}

async function onSubscriptionEnded(subscription: any) {
  if (!subscription?.id) return;
  await ensureSchema();
  await endSubscription(subscription.id);
}
