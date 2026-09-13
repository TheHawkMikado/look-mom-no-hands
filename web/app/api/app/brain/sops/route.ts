import { NextRequest, NextResponse } from "next/server";
import { appEmail } from "@/lib/appauth";
import { listSops } from "@/lib/brain";

/** GET /api/app/brain/sops — the Shared Brain index: latest version of each
 *  published SOP (title, version, source hash, date). */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  return NextResponse.json({ sops: await listSops() }, { headers: { "cache-control": "private, max-age=300" } });
}
