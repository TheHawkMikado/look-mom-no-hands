import { NextRequest, NextResponse } from "next/server";
import { feedPayload } from "@/lib/feed";
import { appEmail } from "@/lib/appauth";

/** GET /api/app/feed — the feed for the mobile app (bearer auth). Payload is
 *  built by the shared lib/feed builder so phone and web render the same truth. */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  return NextResponse.json(await feedPayload(email), { headers: { "cache-control": "no-store" } });
}
