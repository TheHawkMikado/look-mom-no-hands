import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";
import { isAdmin, normaliseEmail, OAUTH_STATE_COOKIE, startSession } from "@/lib/auth";

/**
 * GET /api/auth/google/callback — Google redirects here with `?code`.
 *
 * Exchanges the code for tokens server-to-server, reads the verified email out
 * of the ID token, then hands off to the shared `startSession` — so a Google
 * sign-in ends up in exactly the same session as a magic-link sign-in.
 */

export const runtime = "nodejs";

interface IdTokenClaims {
  iss?: string;
  aud?: string;
  exp?: number;
  email?: string;
  email_verified?: boolean;
}

export async function GET(req: NextRequest) {
  const site = process.env.SITE_URL ?? req.nextUrl.origin;
  const params = req.nextUrl.searchParams;
  const code = params.get("code");
  const state = params.get("state");

  // Consume the CSRF cookie whatever happens — it's single-use.
  const jar = await cookies();
  const expectedState = jar.get(OAUTH_STATE_COOKIE)?.value;
  jar.delete(OAUTH_STATE_COOKIE);

  if (params.get("error")) {
    // User declined consent, or Google reported a problem.
    return NextResponse.redirect(`${site}/login?error=google`);
  }
  if (!code || !state || !expectedState || state !== expectedState) {
    return NextResponse.redirect(`${site}/login?error=google_state`);
  }

  const clientId = process.env.GOOGLE_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    return NextResponse.redirect(`${site}/login?error=google_unconfigured`);
  }

  // Surface the specific failure reason back to the login page so a broken
  // sign-in is diagnosable without digging through server logs.
  const fail = (detail: string) =>
    NextResponse.redirect(`${site}/login?error=google&detail=${encodeURIComponent(detail)}`);

  try {
    const redirectUri = `${req.nextUrl.origin}/api/auth/google/callback`;
    const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: redirectUri,
        grant_type: "authorization_code",
      }),
    });
    if (!tokenRes.ok) {
      const body = await tokenRes.text();
      console.error("google token exchange failed", body);
      let code = "token_exchange";
      try {
        code = (JSON.parse(body) as { error?: string }).error || code;
      } catch {
        // non-JSON body — keep the generic code
      }
      return fail(code); // e.g. invalid_client (wrong secret) / redirect_uri_mismatch
    }

    const tokens = (await tokenRes.json()) as { id_token?: string };
    const claims = decodeIdToken(tokens.id_token);
    if (!claims) return fail("no_id_token");

    // The token came straight from Google's token endpoint over TLS, so its
    // signature is implicitly trusted (per Google's OIDC guidance) — but we
    // still check it was minted for *us*, hasn't expired, and carries a
    // verified address before treating that address as proof of identity.
    const issuedForUs = claims.aud === clientId;
    const fromGoogle =
      claims.iss === "accounts.google.com" || claims.iss === "https://accounts.google.com";
    const fresh = typeof claims.exp === "number" && claims.exp * 1000 > Date.now();
    const email = typeof claims.email === "string" ? normaliseEmail(claims.email) : "";

    if (!issuedForUs || !fromGoogle || !fresh || !email || claims.email_verified !== true) {
      return fail("token_invalid");
    }

    await startSession(email);
    return NextResponse.redirect(`${site}${isAdmin(email) ? "/admin" : "/account"}`);
  } catch (err) {
    console.error("google sign-in failed", err);
    const sessionSecretMissing = err instanceof Error && /SESSION_SECRET/.test(err.message);
    return fail(sessionSecretMissing ? "session_secret_missing" : "server_error");
  }
}

/** Reads the ID token's payload (base64url JSON) — no signature check needed on
 *  a token fetched directly from Google over HTTPS. */
function decodeIdToken(idToken?: string): IdTokenClaims | null {
  if (!idToken) return null;
  const parts = idToken.split(".");
  if (parts.length !== 3) return null;
  try {
    const payload = Buffer.from(parts[1], "base64url").toString("utf8");
    return JSON.parse(payload) as IdTokenClaims;
  } catch {
    return null;
  }
}
