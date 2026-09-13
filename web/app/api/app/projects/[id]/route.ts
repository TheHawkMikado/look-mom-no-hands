import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { receiptsForTask } from "@/lib/db-tasks";
import { getProject, stepsOf } from "@/lib/projects";

/** GET /api/app/projects/{id} — the project, its steps (with Paperclip issue
 *  keys) and the receipts on its task. */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { id } = await ctx.params;
  await ensureSchema();
  const project = await getProject(email, id);
  if (!project) return NextResponse.json({ error: "not found" }, { status: 404 });
  const [steps, receipts] = await Promise.all([stepsOf(project.id), project.task_id ? receiptsForTask(project.task_id) : Promise.resolve([])]);
  return NextResponse.json({ project, steps, receipts }, { headers: { "cache-control": "no-store" } });
}
