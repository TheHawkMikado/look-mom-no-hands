import { NextRequest, NextResponse } from "next/server";
import { createLicence, ensureSchema, licenceForSession, sql } from "@/lib/db";
import { mintLicenceKey } from "@/lib/licence";
import { planForPrice, stripe } from "@/lib/stripe";
import { sendLicenceEmail } from "@/lib/email";

/**
 * POST /api/stripe/webhook — the only place a licence is ever created.
 *
 * Trusting the browser's "payment succeeded!" redirect instead would let anyone
 * mint themselves a licence by visiting /success. The signature check below is
 * what makes this endpoint authoritative, so it must read the *raw* body:
 * re-serialising parsed JSON changes bytes and the signature stops matching.
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

      // A lapsed or cancelled subscription stops the licence renewing. The app
      // keeps working through its grace window, so this is never an abrupt cut.
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

async function onCheckoutCompleted(session: any) {
  await ensureSchema();

  // Stripe redelivers events; the unique index on stripe_session makes this
  // idempotent, but bailing early also avoids a second email.
  if (await licenceForSession(session.id)) return;

  const email: string | null =
    session.customer_details?.email ?? session.customer_email ?? null;
  if (!email) throw new Error(`session ${session.id} has no email`);

  const items = await stripe().checkout.sessions.listLineItems(session.id, { limit: 1 });
  const priceId = items.data[0]?.price?.id ?? "";
  const spec = planForPrice(priceId);

  const key = mintLicenceKey();
  const expiresAt =
    spec.months === null
      ? null
      : new Date(Date.now() + spec.months * 30 * 24 * 60 * 60 * 1000);

  await createLicence({
    key,
    email,
    plan: spec.plan,
    expiresAt,
    seats: spec.seats,
    stripeSession: session.id,
    stripeCustomer: typeof session.customer === "string" ? session.customer : null,
  });

  // A failed send must not fail the webhook — the key is already saved, and the
  // success page shows it. Retrying here would re-charge nothing but would spam.
  try {
    await sendLicenceEmail(email, key);
  } catch (err) {
    console.error("licence email failed (key was still issued)", err);
  }
}

async function onSubscriptionEnded(subscription: any) {
  const customer =
    typeof subscription.customer === "string" ? subscription.customer : subscription.customer?.id;
  if (!customer) return;
  await sql()`
    UPDATE licences SET expires_at = now()
     WHERE stripe_customer = ${customer} AND (expires_at IS NULL OR expires_at > now())`;
}
