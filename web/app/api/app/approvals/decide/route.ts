import { NextRequest, NextResponse } from "next/server";
import { decideApproval, ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";

/**
 * POST /api/app/approvals/decide — approve/deny from the mobile app (bearer
 * auth; /api/status/decide is the cookie-session twin for the web page).
 * First decision wins, same as everywhere: `recorded:false` means someone beat
 * you to it, and the app should refresh rather than assume.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const approvalId = String(body.approvalId ?? "").trim().slice(0, 128);
  const verdict = body.verdict === "approve" ? "approve" : body.verdict === "deny" ? "deny" : null;
  if (!approvalId || !verdict) return NextResponse.json({ error: "bad request" }, { status: 400 });

  await ensureSchema();
  const recorded = await decideApproval(email, approvalId, verdict);
  return NextResponse.json({ ok: true, recorded });
}
