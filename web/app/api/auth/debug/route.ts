import { NextResponse } from "next/server";
import { appleClientSecret, appleConfig } from "@/lib/apple";
import {
  activationsFor,
  ensureSchema,
  licenceStats,
  licencesForEmail,
  searchLicences,
  sql,
  subLicencesOf,
} from "@/lib/db";
import { catalogue } from "@/lib/catalogue";

/**
 * GET /api/auth/debug — TEMPORARY. Reports which auth env vars reached this
 * deployment (booleans/shape only, never secret values) AND probes each
 * provider's token endpoint with a dummy code so we can tell a wrong secret
 * (invalid_client) from a good one (invalid_grant) without a real login.
 * Delete after use.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const set = (v?: string) => !!(v && v.trim().length > 0);

/** Extracts the OAuth error code from a token-endpoint error body. */
function errorCode(status: number, body: string): string {
  try {
    return (JSON.parse(body) as { error?: string }).error ?? `http_${status}`;
  } catch {
    return `http_${status}`;
  }
}

/** Probe Google: a bad code with real client creds → `invalid_grant` means the
 *  secret + redirect_uri are accepted; `invalid_client` means the secret is wrong. */
async function probeGoogle(site: string) {
  const client_id = process.env.GOOGLE_CLIENT_ID;
  const client_secret = process.env.GOOGLE_CLIENT_SECRET;
  if (!client_id || !client_secret) return "unconfigured";
  try {
    const res = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code: "debug-invalid-code",
        client_id,
        client_secret,
        redirect_uri: `${site}/api/auth/google/callback`,
        grant_type: "authorization_code",
      }),
    });
    if (res.ok) return "unexpected_ok";
    return errorCode(res.status, await res.text());
  } catch (err) {
    return `fetch_error:${err instanceof Error ? err.message : "unknown"}`;
  }
}

/** Probe Apple: first check the client-secret JWT can even be signed (throws if
 *  the .p8 is malformed), then a bad code → `invalid_grant` means the key/config
 *  are accepted; `invalid_client` means Apple rejected them. */
async function probeApple(site: string) {
  if (!appleConfig()) return "unconfigured";
  let secret: string;
  try {
    secret = appleClientSecret();
  } catch (err) {
    return `cannot_sign_secret:${err instanceof Error ? err.message : "unknown"}`;
  }
  try {
    const res = await fetch("https://appleid.apple.com/auth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code: "debug-invalid-code",
        client_id: process.env.APPLE_CLIENT_ID ?? "",
        client_secret: secret,
        redirect_uri: `${site}/api/auth/apple/callback`,
        grant_type: "authorization_code",
      }),
    });
    if (res.ok) return "unexpected_ok";
    return errorCode(res.status, await res.text());
  } catch (err) {
    return `fetch_error:${err instanceof Error ? err.message : "unknown"}`;
  }
}

/** Actually connect to the database the pages use, so a bad connection string or
 *  unreachable DB is reported here instead of 500-ing a dashboard. */
async function probeDb() {
  try {
    await ensureSchema();
    const rows = await sql()<{ ok: number }[]>`select 1 as ok`;
    return rows[0]?.ok === 1 ? "ok" : "unexpected";
  } catch (err) {
    return `error:${err instanceof Error ? err.message : "unknown"}`;
  }
}

/** Runs the exact queries the /account and /admin pages run for a given email,
 *  so a query that 500s a dashboard is reported here with the real message. */
async function probePages(email: string) {
  try {
    await ensureSchema();
    // /account path (LicenceCard does these per licence, unguarded on the page):
    const lics = await licencesForEmail(email);
    for (const l of lics) {
      await activationsFor(l.key);
      if (l.resell) await subLicencesOf(l.key);
    }
    // /admin path:
    await Promise.all([licenceStats(), searchLicences(""), catalogue()]);
    return `ok (account licences: ${lics.length})`;
  } catch (err) {
    return `error:${err instanceof Error ? err.message : "unknown"}`;
  }
}

export async function GET() {
  const site = process.env.SITE_URL ?? "https://nohandsapp.com";
  const pk = (process.env.APPLE_PRIVATE_KEY ?? "").replace(/\\n/g, "\n");
  const admins = (process.env.ADMIN_EMAILS ?? "").split(",").map((s) => s.trim()).filter(Boolean);

  const testEmail = admins[0] ?? "probe@example.com";
  const [google, apple, db, pages] = await Promise.all([
    probeGoogle(site),
    probeApple(site),
    probeDb(),
    probePages(testEmail),
  ]);

  return NextResponse.json({
    NODE_ENV: process.env.NODE_ENV ?? null,
    SITE_URL: process.env.SITE_URL ?? null,
    SESSION_SECRET: { set: set(process.env.SESSION_SECRET), len: (process.env.SESSION_SECRET ?? "").length },
    GOOGLE_CLIENT_ID: set(process.env.GOOGLE_CLIENT_ID),
    GOOGLE_CLIENT_SECRET: set(process.env.GOOGLE_CLIENT_SECRET),
    APPLE_CLIENT_ID: set(process.env.APPLE_CLIENT_ID),
    APPLE_TEAM_ID: set(process.env.APPLE_TEAM_ID),
    APPLE_KEY_ID: set(process.env.APPLE_KEY_ID),
    APPLE_PRIVATE_KEY: { set: set(process.env.APPLE_PRIVATE_KEY), looksPem: pk.includes("BEGIN PRIVATE KEY") },
    DATABASE_URL: set(process.env.DATABASE_URL),
    POSTGRES_URL: set(process.env.POSTGRES_URL),
    ADMIN_EMAILS_count: admins.length,
    // Probes — read these to see the REAL provider verdict:
    //   invalid_grant  => credentials good (our dummy code is just rejected)
    //   invalid_client => the secret/key is wrong
    //   redirect_uri_mismatch => the callback URL isn't registered exactly
    google_probe: google,
    apple_probe: apple,
    db_probe: db, // "ok" => reachable; "error:…" => the reason a dashboard 500s
    pages_probe: pages, // runs the actual /account + /admin queries; "error:…" => the 500
  });
}
