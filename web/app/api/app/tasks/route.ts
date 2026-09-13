import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { listTasks, type TaskStatus } from "@/lib/db-tasks";
import { appEmail } from "@/lib/appauth";
import { parseDelivery } from "@/lib/notify";
import { intake } from "@/lib/tasks";

/**
 * POST /api/app/tasks — the front door for "talk to it" (SPEC.md §5.1).
 * Body: { text, source?: 'text'|'voice'|'meeting',
 *         deliver?: { channel: 'email'|'sms', to, name, from?, audience?: 'team'|'client' } }
 * Returns the extracted task (if the utterance was one), the one-sentence
 * confirmation to speak, and — when `deliver` was given — what happened to
 * the human ticket. `deliver.to` is used once and never stored; the Mac's
 * Local Brain is the only place the person's address lives.
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
  const deliver = body.deliver ? parseDelivery(body.deliver) : null;
  if (body.deliver && !deliver) return NextResponse.json({ error: "deliver needs { channel: 'email'|'sms', to, name }" }, { status: 400 });
  await ensureSchema();
  const r = await intake(email, text, source, { deliver });
  return NextResponse.json(
    { intent: r.intent, confirmation: r.confirmation, task: r.task, extraction: r.extraction, delivery: r.delivery ?? null },
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
