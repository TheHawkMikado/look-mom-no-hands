import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { teamBoard } from "@/lib/team";

/** GET /api/app/team — every team member's board (humans and bots), for the
 *  phone and the Mac. Bearer auth. */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  await ensureSchema();
  return NextResponse.json(await teamBoard(email), { headers: { "cache-control": "no-store" } });
}
