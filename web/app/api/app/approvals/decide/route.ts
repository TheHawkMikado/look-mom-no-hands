import { NextRequest, NextResponse } from "next/server";
import { decidePayload } from "@/lib/feed";
import { appEmail } from "@/lib/appauth";

/** POST /api/app/approvals/decide — approve/deny from the mobile app (bearer
 *  auth). Validation and first-decision-wins semantics live in lib/feed,
 *  shared with the web page's /api/status/decide. */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const result = await decidePayload(email, await req.json().catch(() => ({})));
  return NextResponse.json(result.json, { status: result.status });
}
