import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { approvalsForTask, getTask, receiptsForTask } from "@/lib/db-tasks";
import { appEmail } from "@/lib/appauth";

/** GET /api/app/tasks/:id — one task with its approvals and receipts. */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { id } = await ctx.params;
  await ensureSchema();
  const task = await getTask(email, id);
  if (!task) return NextResponse.json({ error: "not found" }, { status: 404 });
  const [approvals, receipts] = await Promise.all([approvalsForTask(id), receiptsForTask(id)]);
  return NextResponse.json({ task, approvals, receipts }, { headers: { "cache-control": "no-store" } });
}
