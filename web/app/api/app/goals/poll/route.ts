import { NextRequest, NextResponse } from "next/server";
import { ensureSchema, takePendingGoals } from "@/lib/db";
import { appEmail } from "@/lib/appauth";

/**
 * POST /api/app/goals/poll — the Mac collects the account's pending spoken
 * goals. Delivery is take-once (UPDATE…RETURNING marks them delivered), so a
 * second Mac polling the same account can never double-run a goal.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  await ensureSchema();
  const goals = await takePendingGoals(email);
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
