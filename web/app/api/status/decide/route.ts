import { NextRequest, NextResponse } from "next/server";
import { getSession } from "@/lib/auth";
import { decideApproval, ensureSchema } from "@/lib/db";

/**
 * POST /api/status/decide { approvalId, verdict } — records the signed-in
 * owner's approve/deny on a pending agent approval. Scoped to the session's own
 * account; the first decision wins (a repeat is an ok no-op), so the Mac app
 * can never see a verdict flip between polls.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const session = await getSession();
  if (!session) return NextResponse.json({ error: "Sign in first." }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const approvalId = String(body.approvalId ?? "").trim();
  const verdict = String(body.verdict ?? "");
  if (!approvalId || (verdict !== "approve" && verdict !== "deny")) {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }

  await ensureSchema();
  const recorded = await decideApproval(session.email, approvalId, verdict);
  return NextResponse.json({ ok: true, recorded });
}
