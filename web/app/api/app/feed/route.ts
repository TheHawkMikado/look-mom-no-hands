import { NextRequest, NextResponse } from "next/server";
import { feedResponse } from "@/lib/feed";
import { appEmail } from "@/lib/appauth";

/** GET /api/app/feed — the feed for the mobile app (bearer auth). Payload and
 *  ETag/304 behavior come from the shared lib/feed builder, same as the web. */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  return feedResponse(email, req);
}
