import { NextRequest, NextResponse } from "next/server";
import { stripe } from "@/lib/stripe";
import { priceIdForPlan } from "@/lib/catalogue";

/**
 * POST /api/checkout  { plan } -> { url }
 *
 * The browser names a plan; this route resolves it to a Price ID from the
 * environment. Prices never travel from the client, so nobody can open devtools
 * and check out at a price they chose themselves.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const { plan = "solo", mode = "cloud" } = await req
    .json()
    .catch(() => ({ plan: "solo", mode: "cloud" }));

  if (typeof plan !== "string" || !/^[a-z0-9_-]{1,40}$/.test(plan)) {
    return NextResponse.json({ error: `Unknown plan "${plan}".` }, { status: 400 });
  }
  // Cloud (we supply the AI keys) vs BYOK (the buyer supplies their own) select
  // different Stripe prices for the same plan. Anything unexpected is Cloud.
  const buyMode: "cloud" | "byok" = mode === "byok" ? "byok" : "cloud";

  // A visible plan with no price id means the storefront is half-configured,
  // not that the buyer asked for something silly. Worth separating: the first is
  // something you need to go fix, the second is noise.
  const priceId = await priceIdForPlan(plan, buyMode);
  if (!priceId) {
    console.error(`no Stripe price for plan "${plan}" (${buyMode})`);
    return NextResponse.json(
      {
        error:
          buyMode === "byok"
            ? "Bring-your-own-key isn't available for this plan yet."
            : "This plan isn't available for purchase yet. Try again shortly.",
      },
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
      // Stamp plan + key-mode so the webhook (and support) can see how this
      // subscription was sold without re-deriving it from the price id.
      metadata: { nohands_plan: plan, nohands_mode: buyMode },
      subscription_data: { metadata: { nohands_plan: plan, nohands_mode: buyMode } },
      success_url: `${origin}/success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${origin}/#pricing`,
      allow_promotion_codes: true,
      // Off unless explicitly switched on: Stripe rejects the whole session if
      // automatic tax is enabled before an origin address and registrations
      // exist, which would turn "we haven't done tax setup yet" into "nobody can
      // buy anything". Set STRIPE_TAX=1 once Stripe Tax is configured. Note it
      // only *calculates* — you still own registration and remittance.
      automatic_tax: { enabled: process.env.STRIPE_TAX === "1" },
    });
    return NextResponse.json({ url: session.url });
  } catch (err) {
    console.error("checkout failed", err);
    return NextResponse.json({ error: "Could not start checkout." }, { status: 500 });
  }
}
