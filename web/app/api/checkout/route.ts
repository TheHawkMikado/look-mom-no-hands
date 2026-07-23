import { NextRequest, NextResponse } from "next/server";
import { stripe } from "@/lib/stripe";

/**
 * POST /api/checkout  { plan } -> { url }
 *
 * The browser names a plan; this route resolves it to a Price ID from the
 * environment. Prices never travel from the client, so nobody can open devtools
 * and check out at a price they chose themselves.
 */

export const runtime = "nodejs";

const PRICE_ENV: Record<string, string> = {
  personal: "STRIPE_PRICE_PERSONAL",
  pro: "STRIPE_PRICE_PRO",
  yearly: "STRIPE_PRICE_YEARLY",
};

export async function POST(req: NextRequest) {
  const { plan = "pro" } = await req.json().catch(() => ({ plan: "pro" }));

  const envName = PRICE_ENV[plan];
  if (!envName) {
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
  const isSubscription = plan === "yearly";

  try {
    const session = await stripe().checkout.sessions.create({
      mode: isSubscription ? "subscription" : "payment",
      line_items: [{ price: priceId, quantity: 1 }],
      // The licence is emailed and shown on the success page, so an address is
      // mandatory — without it a customer who closes the tab has no way back in.
      customer_creation: isSubscription ? undefined : "always",
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
