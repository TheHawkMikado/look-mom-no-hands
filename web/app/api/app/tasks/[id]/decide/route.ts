import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { approvalsForTask, getTask } from "@/lib/db-tasks";
import { appEmail } from "@/lib/appauth";
import { applyVerdict, verdictAllowed } from "@/lib/gate";
import { syncAccount } from "@/lib/tasks";

/**
 * POST /api/app/tasks/:id/decide — a verdict from the Mac (voice or typed).
 * Body: { verdict: 'approve'|'deny', via?: 'voice'|'text', speakerVerified?: bool }.
 * The phone keeps using /api/app/approvals/decide; its verdicts are absorbed
 * by the sync loop. Both land in the same task_approvals row.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { id } = await ctx.params;
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const verdict = body.verdict === "approve" ? "approve" : body.verdict === "deny" ? "deny" : null;
  if (!verdict) return NextResponse.json({ error: "verdict required" }, { status: 400 });
  const via = body.via === "voice" ? "voice" : "text";
  const speakerVerified = body.speakerVerified === true;

  await ensureSchema();
  const task = await getTask(email, id);
  if (!task) return NextResponse.json({ error: "not found" }, { status: 404 });
  const open = (await approvalsForTask(id)).find((a) => !a.decided_at);
  if (!open) return NextResponse.json({ error: "nothing awaiting approval" }, { status: 409 });

  const allowed = verdictAllowed(task, via, speakerVerified);
  const row = await applyVerdict(task, open.id, verdict, via, speakerVerified);
  if (!row && !allowed.ok) {
    return NextResponse.json({ error: "not_allowed", reason: allowed.reason, task }, { status: 409 });
  }
  // Direct mode can close the issue out immediately; bridge mode does it on
  // the bridge's next poll.
  await syncAccount(email).catch(() => undefined);
  const fresh = await getTask(email, id);
  return NextResponse.json({ ok: true, approval: row, task: fresh });
}
