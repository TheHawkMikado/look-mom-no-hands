import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { cookies } from "next/headers";
import { consumeLoginToken, createLoginToken } from "@/lib/db";

/**
 * Passwordless auth for the member and admin dashboards.
 *
 * Sign-in is a one-time link mailed to the address used at checkout. That
 * address is already the only identity we hold, so proving control of it proves
 * ownership of the purchase — and there are no passwords to hash, leak, or
 * reset. Admin is the same flow with an allowlist on top rather than a second
 * login system, because two auth paths is two things to get wrong.
 *
 * Sessions are stateless: an HMAC-signed cookie, no server-side session table.
 * The trade is that a session can't be revoked before it expires, which is why
 * they're short and why anything destructive re-checks the licence in the
 * database rather than trusting the cookie's claims.
 */

const COOKIE = "nh_session";
const SESSION_DAYS = 14;
/** Long enough to find the mail, short enough that a leaked link is stale. */
export const LOGIN_TOKEN_MINUTES = 20;

function secret(): Buffer {
  const s = process.env.SESSION_SECRET;
  if (!s) throw new Error("SESSION_SECRET is not set");
  return Buffer.from(s, "utf8");
}

export interface Session {
  email: string;
  admin: boolean;
  /** Seconds since epoch. */
  exp: number;
}

const b64 = (b: Buffer) => b.toString("base64url");

function sign(payload: Buffer): string {
  return b64(createHmac("sha256", secret()).update(payload).digest());
}

/** Constant-time compare — a fast `!==` here leaks signature bytes by timing. */
function signatureMatches(a: string, b: string): boolean {
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  return ba.length === bb.length && timingSafeEqual(ba, bb);
}

export function isAdmin(email: string): boolean {
  const list = (process.env.ADMIN_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
  return list.includes(email.trim().toLowerCase());
}

export function normaliseEmail(raw: string): string {
  return raw.trim().toLowerCase();
}

// MARK: - Session cookie

export async function startSession(email: string) {
  const session: Session = {
    email: normaliseEmail(email),
    admin: isAdmin(email),
    exp: Math.floor(Date.now() / 1000) + SESSION_DAYS * 86_400,
  };
  const payload = Buffer.from(JSON.stringify(session), "utf8");
  const value = `${b64(payload)}.${sign(payload)}`;

  (await cookies()).set(COOKIE, value, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: SESSION_DAYS * 86_400,
  });
}

export async function endSession() {
  (await cookies()).delete(COOKIE);
}

export async function getSession(): Promise<Session | null> {
  const raw = (await cookies()).get(COOKIE)?.value;
  if (!raw) return null;

  const [encoded, signature] = raw.split(".");
  if (!encoded || !signature) return null;

  let payload: Buffer;
  try {
    payload = Buffer.from(encoded, "base64url");
  } catch {
    return null;
  }
  if (!signatureMatches(sign(payload), signature)) return null;

  try {
    const session = JSON.parse(payload.toString("utf8")) as Session;
    if (!session.email || session.exp * 1000 < Date.now()) return null;
    // Re-derive rather than trusting the cookie's own claim: removing someone
    // from ADMIN_EMAILS must take effect immediately, not in a fortnight.
    return { ...session, admin: isAdmin(session.email) };
  } catch {
    return null;
  }
}

export async function requireSession(): Promise<Session> {
  const session = await getSession();
  if (!session) throw new Error("Not signed in.");
  return session;
}

export async function requireAdmin(): Promise<Session> {
  const session = await requireSession();
  if (!session.admin) throw new Error("Not authorised.");
  return session;
}

// MARK: - Magic links

/**
 * Mints a single-use sign-in token. Only its SHA-256 lives in the database, so
 * a leaked database dump can't be replayed into anyone's account — the same
 * reason you'd never store a raw password.
 */
export async function issueLoginToken(email: string): Promise<string> {
  const token = randomBytes(32).toString("base64url");
  await createLoginToken(normaliseEmail(email), token, LOGIN_TOKEN_MINUTES);
  return token;
}

/** Returns the email the token was issued to, or null if it's spent/expired. */
export async function redeemLoginToken(token: string): Promise<string | null> {
  return consumeLoginToken(token);
}

export function loginURL(token: string): string {
  const site = process.env.SITE_URL ?? "https://nohandsapp.com";
  return `${site}/api/auth/callback?token=${encodeURIComponent(token)}`;
}
