import { NextRequest, NextResponse } from "next/server";
import { appEmail } from "@/lib/appauth";
import { pendingCandidates } from "@/lib/brain";

/** GET /api/app/brain/pending — candidates waiting for this user's one-time
 *  consent. The Mac speaks each once; default no. */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  return NextResponse.json({ candidates: await pendingCandidates(email) }, { headers: { "cache-control": "no-store" } });
}
