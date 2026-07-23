import { NextRequest, NextResponse } from "next/server";
import { PRICE_ENV, planByName, stripe } from "@/lib/stripe";

/**
 * POST /api/checkout  { plan } -> { url }
 *
 * The browser names a plan; this route resolves it to a Price ID from the
 * environment. Prices never travel from the client, so nobody can open devtools
 * and check out at a price they chose themselves.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const { plan = "solo" } = await req.json().catch(() => ({ plan: "solo" }));

  const envName = PRICE_ENV[plan];
  if (!envName || !planByName(plan)) {
    return NextResponse.json({ error: `Unknown plan "${plan}".` }, { status: 400 });
  }
  // A known plan with no price id means the deployment is missing config, not
  // that the buyer asked for something silly. Worth separating: the first is a
  // 500 you need to go fix, the second is a 400 you can ignore.
  const priceId = process.env[envName];
  if (!priceId) {
    console.error(`${envName} is not set — cannot sell the "${plan}" plan`);
    return NextResponse.json(
      { error: "This plan isn't available for purchase yet. Try again shortly." },
      { status: 503 },
    );
  }

  const origin = process.env.SITE_URL ?? req.nextUrl.origin;

  try {
    const session = await stripe().checkout.sessions.create({
      // Every plan bills weekly, so there is no one-off path any more. Stripe
      // always creates a customer for a subscription, hence no customer_creation.
      mode: "subscription",
      line_items: [{ price: priceId, quantity: 1 }],
      success_url: `${origin}/success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${origin}/#pricing`,
      allow_promotion_codes: true,
      // Stripe Tax handles VAT/sales-tax calculation; you still own registration
      // and remittance in each jurisdiction (see web/README.md).
      automatic_tax: { enabled: true },
    });
    return NextResponse.json({ url: session.url });
  } catch (err) {
    console.error("checkout failed", err);
    return NextResponse.json({ error: "Could not start checkout." }, { status: 500 });
  }
}
