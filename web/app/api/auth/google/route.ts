import { NextRequest, NextResponse } from "next/server";
import { randomBytes } from "node:crypto";
import { cookies } from "next/headers";
import { OAUTH_STATE_COOKIE } from "@/lib/auth";

/**
 * GET /api/auth/google — start "Sign in with Google".
 *
 * Google is just another way to prove control of an email: we bounce the user
 * through Google's consent screen and, on the way back, mint the *same* signed
 * session cookie the magic-link flow uses. No new auth system, no third-party
 * session store — identity stays the email, exactly as at checkout.
 */

export const runtime = "nodejs";

export async function GET(req: NextRequest) {
  const clientId = process.env.GOOGLE_CLIENT_ID;
  const site = process.env.SITE_URL ?? req.nextUrl.origin;
  if (!clientId) {
    return NextResponse.redirect(`${site}/login?error=google_unconfigured`);
  }

  // CSRF: a random value echoed back by Google and checked in the callback. Kept
  // in an httpOnly cookie rather than server state so the flow stays stateless.
  const state = randomBytes(16).toString("base64url");
  (await cookies()).set(OAUTH_STATE_COOKIE, state, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: 600, // 10 minutes — long enough to pick an account, short enough to expire
  });

  // Derive the redirect URI from the actual host so the same code works on
  // localhost and in production; both must be registered in Google Cloud.
  const redirectUri = `${req.nextUrl.origin}/api/auth/google/callback`;
  const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
  url.searchParams.set("client_id", clientId);
  url.searchParams.set("redirect_uri", redirectUri);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", "openid email");
  url.searchParams.set("state", state);
  url.searchParams.set("access_type", "online");
  url.searchParams.set("prompt", "select_account");
  return NextResponse.redirect(url.toString());
}
