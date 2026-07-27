import { NextRequest, NextResponse } from "next/server";
import { getSession } from "@/lib/auth";
import { stripe } from "@/lib/stripe";
import { TOPUP_BLOCKS } from "@/lib/metering";

/**
 * POST /api/checkout/topup { amount } -> { url }
 *
 * A one-time payment that adds Cloud overage credit to the signed-in account's
 * wallet. The account email is stamped in metadata so the webhook credits the
 * right wallet regardless of the email entered at checkout.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const session = await getSession();
  if (!session) return NextResponse.json({ error: "Sign in first." }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const amount = Number(body.amount);
  if (!TOPUP_BLOCKS.includes(amount)) {
    return NextResponse.json({ error: "Choose a valid top-up amount." }, { status: 400 });
  }

  const origin = process.env.SITE_URL ?? req.nextUrl.origin;
  try {
    const checkout = await stripe().checkout.sessions.create({
      mode: "payment",
      customer_email: session.email,
      line_items: [
        {
          price_data: {
            currency: "usd",
            product_data: { name: `NoHandsApp.com — Cloud credit ($${amount})` },
            unit_amount: amount * 100,
          },
          quantity: 1,
        },
      ],
      metadata: {
        nohands_topup_cents: String(amount * 100),
        nohands_topup_email: session.email,
      },
      success_url: `${origin}/account`,
      cancel_url: `${origin}/account`,
    });
    return NextResponse.json({ url: checkout.url });
  } catch (err) {
    console.error("top-up checkout failed", err);
    return NextResponse.json({ error: "Could not start checkout." }, { status: 500 });
  }
}
