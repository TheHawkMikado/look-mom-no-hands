import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { recordSpend } from "@/lib/projects";

/**
 * POST /api/app/projects/{id}/spend — body { cents, note? }. Records spend
 * against the project's cap with a receipt on its task. 409 when the spend
 * would cross the cap. Crossing 80% emits one goal_progress event asking the
 * owner whether to keep going (SPEC.md §9 Phase 5).
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(req: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { id } = await ctx.params;
  const body = (await req.json().catch(() => ({}))) as { cents?: unknown; note?: unknown };
  await ensureSchema();
  const r = await recordSpend(email, id, Number(body.cents), String(body.note ?? "").slice(0, 300));
  if (!r) return NextResponse.json({ error: "not found" }, { status: 404 });
  if (!r.ok) return NextResponse.json({ error: r.reason, project: r.project }, { status: r.reason?.startsWith("would exceed") ? 409 : 400 });
  return NextResponse.json({ project: r.project, warned: r.warned, capped: r.capped }, { headers: { "cache-control": "no-store" } });
}
