import { NextRequest, NextResponse } from "next/server";
import { stripe } from "@/lib/stripe";
import { countLifetimeLicences } from "@/lib/db";
import { lifetimePrice, lifetimeTier, RESELLER_UPGRADE_PRICE } from "@/lib/lifetime";

/**
 * POST /api/checkout/lifetime { tier, upgrade? } -> { url }
 *
 * A one-time payment (mode: "payment") for a lifetime BYOK plan. The amount is
 * resolved server-side from the live sold count — founder price for the first
 * 100, standard after — so the client can't pick a price. `upgrade` uses the
 * fixed Team→Reseller discount. The amount is passed inline (price_data), so
 * there are no pre-created Stripe prices to manage.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => ({}));
  const tier = lifetimeTier(String(body.tier ?? ""));
  if (!tier) return NextResponse.json({ error: "Unknown lifetime tier." }, { status: 400 });

  const isUpgrade = (body.upgrade === true || body.upgrade === "1") && tier.key === "reseller";
  const sold = await countLifetimeLicences();
  const dollars = isUpgrade ? RESELLER_UPGRADE_PRICE : lifetimePrice(tier, sold);

  const origin = process.env.SITE_URL ?? req.nextUrl.origin;
  try {
    const session = await stripe().checkout.sessions.create({
      mode: "payment",
      line_items: [
        {
          price_data: {
            currency: "usd",
            product_data: {
              name: `NoHandsApp.com — ${tier.name}${isUpgrade ? " upgrade" : ""} (Lifetime, BYOK)`,
            },
            unit_amount: Math.round(dollars * 100),
          },
          quantity: 1,
        },
      ],
      // Stamp the tier + mode so the webhook mints the right perpetual licence.
      metadata: {
        nohands_lifetime: tier.key,
        nohands_mode: "byok",
        nohands_upgrade: isUpgrade ? "1" : "0",
      },
      success_url: `${origin}/success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${origin}/lifetime`,
      allow_promotion_codes: true,
      automatic_tax: { enabled: process.env.STRIPE_TAX === "1" },
    });
    return NextResponse.json({ url: session.url });
  } catch (err) {
    console.error("lifetime checkout failed", err);
    return NextResponse.json({ error: "Could not start checkout." }, { status: 500 });
  }
}
