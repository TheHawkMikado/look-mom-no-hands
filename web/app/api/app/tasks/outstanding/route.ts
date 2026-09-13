import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { outstanding } from "@/lib/followup";

/** GET /api/app/tasks/outstanding — { counts, top, spoken } for the Mac's
 *  "what's outstanding?" (SPEC.md §5.4). */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  await ensureSchema();
  return NextResponse.json(await outstanding(email), { headers: { "cache-control": "no-store" } });
}
