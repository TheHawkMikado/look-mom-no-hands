import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { issueLoginToken, loginURL, normaliseEmail } from "@/lib/auth";
import { sendLoginEmail } from "@/lib/email";

/**
 * POST /api/auth/request  { email } -> { sent: true }
 *
 * Always answers `sent: true`, whether or not that address has ever bought
 * anything. Saying "no such account" would turn this endpoint into a way to
 * test which email addresses are customers, and the honest-looking error buys
 * the user nothing they can act on.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => ({}));
  const email = normaliseEmail(String(body.email ?? ""));

  // Deliberately loose: real addresses are stranger than any regex, and the
  // send either lands or it doesn't.
  if (!email || !email.includes("@") || email.length > 320) {
    return NextResponse.json({ error: "Enter a valid email address." }, { status: 400 });
  }

  try {
    await ensureSchema();
    const token = await issueLoginToken(email);
    const url = loginURL(token);

    const delivered = await sendLoginEmail(email, url);

    // Local development without a mail provider would otherwise be unusable.
    // Guarded on NODE_ENV so a misconfigured production deploy can never hand a
    // sign-in link to whoever typed the address.
    if (!delivered && process.env.NODE_ENV !== "production") {
      console.warn(`[dev] sign-in link for ${email}: ${url}`);
      return NextResponse.json({ sent: true, devLink: url });
    }
    if (!delivered) {
      console.error("RESEND_API_KEY missing — cannot send sign-in links");
      return NextResponse.json(
        { error: "Sign-in email isn't configured yet. Contact support@nohandsapp.com." },
        { status: 503 },
      );
    }
  } catch (err) {
    console.error("sign-in request failed", err);
    return NextResponse.json({ error: "Couldn't send the link. Try again." }, { status: 500 });
  }

  return NextResponse.json({ sent: true });
}
