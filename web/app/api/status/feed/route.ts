import { NextResponse } from "next/server";
import { getSession } from "@/lib/auth";
import { agentEventsFor, approvalVerdictsSince, ensureSchema } from "@/lib/db";

/**
 * GET /api/status/feed — what the /status page polls every few seconds: the
 * signed-in account's recent agent events (newest first) plus a map of decided
 * approvals, so pending ones can be told apart from settled ones.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  const session = await getSession();
  if (!session) return NextResponse.json({ error: "Sign in first." }, { status: 401 });

  await ensureSchema();
  // Independent reads — don't serialize them on a 5-second poll path.
  const [events, decided] = await Promise.all([
    agentEventsFor(session.email),
    approvalVerdictsSince(session.email, null),
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
