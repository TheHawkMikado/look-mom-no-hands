import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { isAdmin, redeemLoginToken, startSession } from "@/lib/auth";

/**
 * GET /api/auth/callback?token=… — the target of the emailed sign-in link.
 *
 * Redeems the token (single-use, enforced in the database) and starts a session.
 * Admins land on the admin dashboard, everyone else on their account page.
 */

export const runtime = "nodejs";

export async function GET(req: NextRequest) {
  const token = req.nextUrl.searchParams.get("token") ?? "";
  const site = process.env.SITE_URL ?? req.nextUrl.origin;

  if (!token) return NextResponse.redirect(`${site}/login?error=missing`);

  try {
    await ensureSchema();
    const email = await redeemLoginToken(token);
    if (!email) {
      // Expired, already used, or invented. All three read the same to the
      // person holding the link, and asking them to request a new one is the
      // only useful next step in every case.
      return NextResponse.redirect(`${site}/login?error=expired`);
    }

    await startSession(email);
    return NextResponse.redirect(`${site}${isAdmin(email) ? "/admin" : "/account"}`);
  } catch (err) {
    console.error("sign-in callback failed", err);
    return NextResponse.redirect(`${site}/login?error=failed`);
  }
}
