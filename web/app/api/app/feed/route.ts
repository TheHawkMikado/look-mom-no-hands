import { NextRequest, NextResponse } from "next/server";
import { agentEventsFor, approvalVerdictsSince, ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";

/**
 * GET /api/app/feed — the /api/status/feed payload, but bearer-authenticated
 * for the mobile app (which holds a device token, not a browser session).
 * Shape is kept identical so the phone and the web page render the same truth.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  await ensureSchema();
  const [events, decided] = await Promise.all([
    agentEventsFor(email),
    approvalVerdictsSince(email, null),
  ]);
  return NextResponse.json(
    {
      events: events.map((e) => ({
        id: e.id,
        kind: e.kind,
        title: e.title,
        detail: e.detail,
        approvalId: e.approval_id,
        createdAt: e.created_at.toISOString(),
      })),
      verdicts: Object.fromEntries(decided.map((v) => [v.approval_id, v.verdict])),
    },
    { headers: { "cache-control": "no-store" } },
  );
}
