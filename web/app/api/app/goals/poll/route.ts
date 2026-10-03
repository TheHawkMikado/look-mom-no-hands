import { NextRequest, NextResponse } from "next/server";
import { ensureSchema, takePendingGoals } from "@/lib/db";
import { appEmail } from "@/lib/appauth";

/**
 * POST /api/app/goals/poll { idleSeconds? } — the Mac collects the account's
 * pending spoken goals. Delivery is take-once (DELETE…RETURNING), so a second
 * Mac polling the same account can never double-run a goal — but it CAN win
 * the race, so a Mac reports how long since the user last touched it and an
 * idle one holds back briefly. A poll that doesn't say (an older build) is
 * treated as idle: unknown must not outrun the Mac the user is sitting at.
 */

export const runtime = "nodejs";

/** No input for this long means nobody is at that Mac right now. */
const ACTIVE_WITHIN_SECONDS = 120;

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = (await req.json().catch(() => ({}))) as { idleSeconds?: unknown };
  const idle = Number(body.idleSeconds);
  const active = Number.isFinite(idle) && idle >= 0 && idle < ACTIVE_WITHIN_SECONDS;

  await ensureSchema();
  const goals = await takePendingGoals(email, active);
  return NextResponse.json(
    {
      goals: goals.map((g) => ({
        id: g.id,
        text: g.text,
        kind: g.kind,
        createdAt: g.created_at.toISOString(),
      })),
    },
    // no-store is load-bearing here: delivery is destructive, so a cache layer
    // replaying a taken batch would hand the Mac goals that no longer exist.
    { headers: { "cache-control": "no-store" } },
  );
}
