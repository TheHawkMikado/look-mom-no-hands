import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { runFollowupsFor } from "@/lib/followup";

/**
 * POST /api/app/followups/run — run one follow-up round for this account
 * now (the Mac calls it after "what's outstanding?" so nudges are fresh).
 * Body: { now?: ISO8601 } — the clock override is honoured only outside
 * production; it exists for the demo script and tests.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  let now = new Date();
  if (body.now && process.env.NODE_ENV !== "production") {
    const d = new Date(String(body.now));
    if (!Number.isNaN(d.getTime())) now = d;
  }
  await ensureSchema();
  const stats = await runFollowupsFor(email, now);
  return NextResponse.json({ ok: true, now: now.toISOString(), ...stats });
}
