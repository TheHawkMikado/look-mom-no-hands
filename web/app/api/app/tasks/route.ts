import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { listTasks, type TaskStatus } from "@/lib/db-tasks";
import { appEmail } from "@/lib/appauth";
import { intake } from "@/lib/tasks";

/**
 * POST /api/app/tasks — the front door for "talk to it" (SPEC.md §5.1).
 * Body: { text, source?: 'text'|'voice'|'meeting' }. Returns the extracted
 * task (if the utterance was one), and the one-sentence confirmation to speak.
 *
 * GET /api/app/tasks?status=a,b&limit=n — the account's tasks, newest first.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const text = String(body.text ?? "").trim().slice(0, 4000);
  if (!text) return NextResponse.json({ error: "text required" }, { status: 400 });
  const source = body.source === "voice" || body.source === "meeting" ? body.source : "text";
  await ensureSchema();
  const r = await intake(email, text, source);
  return NextResponse.json(
    { intent: r.intent, confirmation: r.confirmation, task: r.task, extraction: r.extraction },
    { headers: { "cache-control": "no-store" } },
  );
}

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  await ensureSchema();
  const status = req.nextUrl.searchParams.get("status")?.split(",").filter(Boolean) as TaskStatus[] | undefined;
  const limit = Number(req.nextUrl.searchParams.get("limit") ?? 50);
  const tasks = await listTasks(email, { status, limit });
  return NextResponse.json({ tasks }, { headers: { "cache-control": "no-store" } });
}
