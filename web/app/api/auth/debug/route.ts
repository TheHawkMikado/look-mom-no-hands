import { NextResponse } from "next/server";

/**
 * GET /api/auth/debug — TEMPORARY. Reports which auth env vars actually reached
 * this deployment's runtime, as booleans/shape only (never secret values), so a
 * broken sign-in can be diagnosed without server logs. Delete after use.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  const set = (v?: string) => !!(v && v.trim().length > 0);
  const pk = (process.env.APPLE_PRIVATE_KEY ?? "").replace(/\\n/g, "\n");
  const admins = (process.env.ADMIN_EMAILS ?? "").split(",").map((s) => s.trim()).filter(Boolean);

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
    ADMIN_EMAILS_count: admins.length,
  });
}
