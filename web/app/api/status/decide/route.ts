import { NextRequest, NextResponse } from "next/server";
import { getSession } from "@/lib/auth";
import { decidePayload } from "@/lib/feed";

/** POST /api/status/decide — the web page's approve/deny. Validation and
 *  first-decision-wins semantics live in lib/feed, shared with the phone's
 *  /api/app/approvals/decide. */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const session = await getSession();
  if (!session) return NextResponse.json({ error: "Sign in first." }, { status: 401 });
  const result = await decidePayload(session.email, await req.json().catch(() => ({})));
  return NextResponse.json(result.json, { status: result.status });
}
