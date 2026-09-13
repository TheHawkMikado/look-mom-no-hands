import { NextRequest, NextResponse } from "next/server";
import { appEmail } from "@/lib/appauth";
import { getSop } from "@/lib/brain";

/** GET /api/app/brain/sops/{id} — one published SOP, body included. */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { id } = await ctx.params;
  const sop = await getSop(id);
  if (!sop) return NextResponse.json({ error: "not found" }, { status: 404 });
  return NextResponse.json({ sop }, { headers: { "cache-control": "private, max-age=300" } });
}
