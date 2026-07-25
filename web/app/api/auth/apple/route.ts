import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";
import { APPLE_STATE_COOKIE, appleConfig, newAppleState } from "@/lib/apple";

/**
 * GET /api/auth/apple — start "Sign in with Apple".
 *
 * Like the Google flow, this ends in the same signed session cookie as a
 * magic-link sign-in. The difference is the return trip: because we ask for the
 * email scope, Apple posts the result back (response_mode=form_post), so the
 * callback is a POST and the CSRF cookie must be SameSite=None to survive it.
 */

export const runtime = "nodejs";

export async function GET(req: NextRequest) {
  const site = process.env.SITE_URL ?? req.nextUrl.origin;
  const cfg = appleConfig();
  if (!cfg) {
    return NextResponse.redirect(`${site}/login?error=apple_unconfigured`);
  }

  const state = newAppleState();
  (await cookies()).set(APPLE_STATE_COOKIE, state, {
    httpOnly: true,
    sameSite: "none", // Apple returns via cross-site form_post; Lax wouldn't send it
    secure: true, // mandatory with SameSite=None (Apple sign-in is HTTPS-only anyway)
    path: "/",
    maxAge: 600,
  });

  // Apple requires an HTTPS, non-localhost return URL that exactly matches the
  // one registered on the Services ID. Deterministic via SITE_URL.
  const redirectUri = `${site}/api/auth/apple/callback`;
  const url = new URL("https://appleid.apple.com/auth/authorize");
  url.searchParams.set("client_id", cfg.clientId);
  url.searchParams.set("redirect_uri", redirectUri);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", "email");
  url.searchParams.set("response_mode", "form_post");
  url.searchParams.set("state", state);
  return NextResponse.redirect(url.toString());
}
