import { NextRequest, NextResponse } from "next/server";
import { stripe, UNLIMITED } from "@/lib/stripe";
import { createLicence, ensureSchema } from "@/lib/db";
import { getSession } from "@/lib/auth";
import { mintLicenceKey } from "@/lib/licence";
import { sendLicenceEmail } from "@/lib/email";
import { BETA_PLAN, BETA_PRICE_DOLLARS, betaPriceDollars, normaliseBetaCode, parseBetaCode } from "@/lib/beta";
import { betaEnabled, recordBetaRedemption } from "@/lib/db-beta";

/**
 * POST /api/checkout/beta { code? } -> { url }
 *
 * The secret beta offer: $99 for life, less a BETA## code. A paid amount goes
 * through a one-time Stripe checkout (price_data, like /api/checkout/lifetime)
 * and the webhook mints the licence. A code worth the full $99 makes it free:
 * no Stripe, the licence is minted here for the signed-in account — so a free
 * code needs a sign-in, which also stops anonymous mass minting.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => ({}));
  const raw = body.code ? normaliseBetaCode(String(body.code)) : "";
  const off = raw ? parseBetaCode(raw) : null;
  if (raw && off === null) return NextResponse.json({ error: "That code isn't valid." }, { status: 400 });

  await ensureSchema();
  if (!(await betaEnabled())) return NextResponse.json({ error: "The beta is closed." }, { status: 403 });

  const dollars = betaPriceDollars(raw);
  const origin = process.env.SITE_URL ?? req.nextUrl.origin;

  if (dollars === 0) {
    const session = await getSession();
    if (!session) {
      return NextResponse.json({ error: "sign_in", next: `/beta?code=${encodeURIComponent(raw)}` }, { status: 401 });
    }
    const key = mintLicenceKey();
    await createLicence({
      key,
      email: session.email,
      plan: BETA_PLAN,
      expiresAt: null,
      seats: UNLIMITED,
      phones: 0,
      subUsers: 0,
      resell: false,
      mode: "byok",
      stripeSession: `beta-free-${crypto.randomUUID()}`,
      stripeCustomer: null,
      stripeSubscription: null,
    });
    await recordBetaRedemption({
      email: session.email,
      code: raw,
      discount_cents: BETA_PRICE_DOLLARS * 100,
      paid_cents: 0,
      stripe_session: null,
      licence_key: key,
    });
    try {
      await sendLicenceEmail(session.email, key);
    } catch (err) {
      console.error("beta licence email failed (key was still issued)", err);
    }
    return NextResponse.json({ url: `${origin}/account?beta=1` });
  }

  try {
    const session = await stripe().checkout.sessions.create({
      mode: "payment",
      line_items: [
        {
          price_data: {
            currency: "usd",
            product_data: { name: `NoHandsApp.com — Beta (Lifetime, BYOK)${raw ? ` · ${raw}` : ""}` },
            unit_amount: dollars * 100,
          },
          quantity: 1,
        },
      ],
      metadata: {
        nohands_beta: "1",
        nohands_beta_code: raw,
        nohands_beta_discount_cents: String((BETA_PRICE_DOLLARS - dollars) * 100),
        nohands_mode: "byok",
      },
      success_url: `${origin}/success?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${origin}/beta${raw ? `?code=${encodeURIComponent(raw)}` : ""}`,
      // The BETA code IS the discount; Stripe promo codes would stack on top.
      allow_promotion_codes: false,
      automatic_tax: { enabled: process.env.STRIPE_TAX === "1" },
    });
    return NextResponse.json({ url: session.url });
  } catch (err) {
    console.error("beta checkout failed", err);
    return NextResponse.json({ error: "Could not start checkout." }, { status: 500 });
  }
}
