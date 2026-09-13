import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { runFollowups } from "@/lib/followup";

/**
 * GET /api/cron/followups — Vercel cron, every five minutes: check-ins,
 * nudges, escalations and daily briefs for every account (SPEC.md §5.4).
 * Protected by CRON_SECRET like /api/cron/sync.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (secret && req.headers.get("authorization") !== `Bearer ${secret}`) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  await ensureSchema();
  const stats = await runFollowups(new Date());
  return NextResponse.json({ ok: true, ...stats });
}
