import { NextRequest, NextResponse } from "next/server";
import { approvalVerdictsSince, ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";

/**
 * POST /api/app/approvals/poll — the Mac app asks whether the owner has decided
 * any pending approvals (recorded from /status). Body: { since: ISO8601|null };
 * returns every verdict for this account decided after `since`, oldest first,
 * so the app can carry the last decidedAt forward as its next cursor.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const parsed = body.since == null ? null : new Date(String(body.since));
  const since = parsed && !Number.isNaN(parsed.getTime()) ? parsed : null;

  await ensureSchema();
  const rows = await approvalVerdictsSince(email, since);
  return NextResponse.json(
    {
      verdicts: rows.map((r) => ({
        approvalId: r.approval_id,
        verdict: r.verdict,
        decidedAt: r.decided_at.toISOString(),
      })),
    },
    { headers: { "cache-control": "no-store" } },
  );
}
