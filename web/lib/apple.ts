import { createPrivateKey, randomBytes, sign } from "node:crypto";

/**
 * "Sign in with Apple" helpers.
 *
 * Apple is the odd one out among OAuth providers: the "client secret" isn't a
 * static string but a short-lived JWT you sign yourself (ES256) with the .p8 key
 * from the Apple Developer portal. We mint a fresh one per request rather than
 * storing a long-lived secret — nothing to rotate, and it can't leak stale.
 */

/** CSRF cookie for the Apple round-trip. SameSite=None because Apple returns via
 *  a cross-site form_post, on which a Lax cookie would never be sent. */
export const APPLE_STATE_COOKIE = "nh_apple_state";

export function newAppleState(): string {
  return randomBytes(16).toString("base64url");
}

/** The four values from the Apple Developer portal, or null if unconfigured. */
export function appleConfig() {
  const clientId = process.env.APPLE_CLIENT_ID; // the Services ID, e.g. com.nohandsapp.web
  const teamId = process.env.APPLE_TEAM_ID;
  const keyId = process.env.APPLE_KEY_ID;
  const privateKey = process.env.APPLE_PRIVATE_KEY; // .p8 PEM contents
  if (!clientId || !teamId || !keyId || !privateKey) return null;
  return { clientId, teamId, keyId, privateKey };
}

/**
 * Builds the ES256-signed client-secret JWT Apple's token endpoint expects.
 * Signed with `ieee-p1363` so the signature is the raw R||S pair JOSE wants,
 * not Node's default DER — no JWT library needed.
 */
export function appleClientSecret(): string {
  const cfg = appleConfig();
  if (!cfg) throw new Error("Apple sign-in is not configured");

  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: cfg.keyId, typ: "JWT" };
  const payload = {
    iss: cfg.teamId,
    iat: now,
    exp: now + 60 * 30, // 30 minutes — well under Apple's 6-month ceiling
    aud: "https://appleid.apple.com",
    sub: cfg.clientId,
  };
  const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const signingInput = `${b64(header)}.${b64(payload)}`;

  // Env vars often carry the key with escaped newlines — normalise before parsing.
  const key = createPrivateKey(cfg.privateKey.replace(/\\n/g, "\n"));
  const signature = sign("sha256", Buffer.from(signingInput), {
    key,
    dsaEncoding: "ieee-p1363",
  }).toString("base64url");
  return `${signingInput}.${signature}`;
}
