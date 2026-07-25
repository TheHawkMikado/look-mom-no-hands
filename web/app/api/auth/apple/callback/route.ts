import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";
import { isAdmin, normaliseEmail, startSession } from "@/lib/auth";
import { APPLE_STATE_COOKIE, appleClientSecret, appleConfig } from "@/lib/apple";

/**
 * POST /api/auth/apple/callback — Apple posts here (form_post) with `code`.
 *
 * Exchanges the code (using a freshly-minted JWT client secret), reads the
 * verified email out of the ID token, and hands off to the shared `startSession`
 * — so an Apple sign-in lands in the same session as Google or a magic link.
 * A 303 turns Apple's POST into a plain GET of the destination page.
 */

export const runtime = "nodejs";

interface AppleClaims {
  iss?: string;
  aud?: string;
  exp?: number;
  email?: string;
  email_verified?: boolean | string; // Apple sends this as a boolean or "true"
}

export async function POST(req: NextRequest) {
  const site = process.env.SITE_URL ?? req.nextUrl.origin;

  // Consume the CSRF cookie whatever happens — it's single-use.
  const jar = await cookies();
  const expectedState = jar.get(APPLE_STATE_COOKIE)?.value;
  jar.delete(APPLE_STATE_COOKIE);

  const form = await req.formData().catch(() => null);
  if (!form || form.get("error")) {
    // User cancelled at Apple, or the body wasn't what we expected.
    return NextResponse.redirect(`${site}/login?error=apple`, 303);
  }

  const code = String(form.get("code") ?? "");
  const state = String(form.get("state") ?? "");
  if (!code || !state || !expectedState || state !== expectedState) {
    return NextResponse.redirect(`${site}/login?error=apple_state`, 303);
  }

  const cfg = appleConfig();
  if (!cfg) return NextResponse.redirect(`${site}/login?error=apple_unconfigured`, 303);

  try {
    const redirectUri = `${site}/api/auth/apple/callback`;
    const tokenRes = await fetch("https://appleid.apple.com/auth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: cfg.clientId,
        client_secret: appleClientSecret(),
        code,
        grant_type: "authorization_code",
        redirect_uri: redirectUri,
      }),
    });
    if (!tokenRes.ok) {
      console.error("apple token exchange failed", await tokenRes.text());
      return NextResponse.redirect(`${site}/login?error=apple`, 303);
    }

    const tokens = (await tokenRes.json()) as { id_token?: string };
    const claims = decodeIdToken(tokens.id_token);
    if (!claims) return NextResponse.redirect(`${site}/login?error=apple`, 303);

    // The token came straight from Apple's token endpoint over TLS, so we trust
    // its signature — but still confirm it was minted for us, is fresh, and
    // carries a verified address before treating it as identity.
    const issuedForUs = claims.aud === cfg.clientId;
    const fromApple = claims.iss === "https://appleid.apple.com";
    const fresh = typeof claims.exp === "number" && claims.exp * 1000 > Date.now();
    const email = typeof claims.email === "string" ? normaliseEmail(claims.email) : "";
    const verified = claims.email_verified === true || claims.email_verified === "true";

    if (!issuedForUs || !fromApple || !fresh || !email || !verified) {
      return NextResponse.redirect(`${site}/login?error=apple`, 303);
    }

    await startSession(email);
    return NextResponse.redirect(`${site}${isAdmin(email) ? "/admin" : "/account"}`, 303);
  } catch (err) {
    console.error("apple sign-in failed", err);
    return NextResponse.redirect(`${site}/login?error=apple`, 303);
  }
}

/** Apple always POSTs here; a stray GET (someone opening the URL) goes to login. */
export async function GET(req: NextRequest) {
  const site = process.env.SITE_URL ?? req.nextUrl.origin;
  return NextResponse.redirect(`${site}/login`, 303);
}

/** Reads the ID token's payload — no signature check needed on a token fetched
 *  directly from Apple over HTTPS. */
function decodeIdToken(idToken?: string): AppleClaims | null {
  if (!idToken) return null;
  const parts = idToken.split(".");
  if (parts.length !== 3) return null;
  try {
    return JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")) as AppleClaims;
  } catch {
    return null;
  }
}
