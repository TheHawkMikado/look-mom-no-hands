import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { bridgeWork } from "@/lib/tasks";

/** GET /api/app/bridge/work — what the bridge next to a localhost Paperclip
 *  should do now: issues to create, issues to watch, issues to close. */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  await ensureSchema();
  const work = await bridgeWork(email);
  if (!work) return NextResponse.json({ error: "no paperclip connection" }, { status: 404 });
  return NextResponse.json(work, { headers: { "cache-control": "no-store" } });
}
