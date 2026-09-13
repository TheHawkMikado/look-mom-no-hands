import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { getTask } from "@/lib/db-tasks";
import { parseBudgetCents } from "@/lib/extract";
import { onAdProcessIntake } from "@/lib/projects";

/**
 * POST /api/app/projects/ad-process — body { task_id }. Starts (or returns)
 * the ad-process project for a task with capability `ad_process`. Intake
 * calls `onAdProcessIntake` itself once the hook is wired; this route is the
 * explicit door for the Mac and the demo, and is idempotent per task.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const body = (await req.json().catch(() => ({}))) as { task_id?: unknown };
  const taskId = String(body.task_id ?? "");
  if (!taskId) return NextResponse.json({ error: "task_id required" }, { status: 400 });
  await ensureSchema();
  const task = await getTask(email, taskId);
  if (!task) return NextResponse.json({ error: "task not found" }, { status: 404 });
  if (task.capability !== "ad_process") return NextResponse.json({ error: `task capability is ${task.capability}, not ad_process` }, { status: 400 });
  const r = await onAdProcessIntake(task, { title: task.title, detail: task.detail, budget_cap_cents: parseBudgetCents(task.detail) });
  return NextResponse.json(r, { status: 201, headers: { "cache-control": "no-store" } });
}
