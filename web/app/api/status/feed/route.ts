import { NextRequest, NextResponse } from "next/server";
import { getSession } from "@/lib/auth";
import { feedResponse } from "@/lib/feed";

/** GET /api/status/feed — what the /status page polls: same payload the phone
 *  gets, built by the shared lib/feed builder, behind the cookie session. */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const session = await getSession();
  if (!session) return NextResponse.json({ error: "Sign in first." }, { status: 401 });
  return feedResponse(session.email, req);
}
