import { NextRequest, NextResponse } from "next/server";
import { appEmail } from "@/lib/appauth";
import { consent } from "@/lib/brain";

/**
 * POST /api/app/brain/{id}/consent — body { yes: boolean }. Anything but an
 * explicit `true` is a no, and a no is final: the candidate is rejected and
 * never asked about again (SPEC.md §8.3, "asked once, default no").
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(req: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { id } = await ctx.params;
  const body = (await req.json().catch(() => ({}))) as { yes?: unknown };
  const row = await consent(email, id, body.yes === true);
  if (!row) return NextResponse.json({ error: "not found or already answered" }, { status: 404 });
  return NextResponse.json({ candidate: row }, { headers: { "cache-control": "no-store" } });
}
