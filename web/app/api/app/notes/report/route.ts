import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { reportForNote } from "@/lib/notes";
import { intake } from "@/lib/tasks";

/**
 * POST /api/app/notes/report { text } — summarize a phone dictation into
 * { title, summary, keyPoints, actionItems, tasks }. Each action item then
 * goes through the normal task intake (extract → triage → owner), so a
 * dictated to-do lands on the Tasks board assigned like any spoken request.
 * Stateless otherwise: the phone owns the note and stores the report beside it.
 */

export const runtime = "nodejs";
// Opus with thinking on a long note runs well past the default function
// budget; the phone shows the note immediately and waits for this in the
// background, so latency here costs nothing visible.
export const maxDuration = 60;

const TEXT_MAX = 20000;
/** A rambling note can list a dozen to-dos; past this they still show as
 *  action items, they just aren't auto-filed — each one is a model call. */
const TASKS_MAX = 6;

interface CreatedTask {
  id: string;
  title: string;
  status: string;
  owner_name: string | null;
}

async function fileActionItems(email: string, items: string[]): Promise<CreatedTask[]> {
  const results = await Promise.all(
    items.slice(0, TASKS_MAX).map(async (item): Promise<CreatedTask | null> => {
      try {
        const r = await intake(email, item, "voice");
        return r.task
          ? { id: r.task.id, title: r.task.title, status: r.task.status, owner_name: r.task.owner_name }
          : null;
      } catch (e) {
        // One item failing to file must not cost the note its report.
        console.warn("[notes/report] intake failed for action item:", e instanceof Error ? e.message : e);
        return null;
      }
    }),
  );
  return results.filter((t): t is CreatedTask => t !== null);
}

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const text = String(body.text ?? "").trim().slice(0, TEXT_MAX);
  if (!text) return NextResponse.json({ error: "empty note" }, { status: 400 });

  await ensureSchema();
  try {
    const report = await reportForNote(email, text);
    if (!report) {
      return NextResponse.json({ error: "no Anthropic key on this account" }, { status: 503 });
    }
    const tasks = await fileActionItems(email, report.actionItems);
    return NextResponse.json({ ...report, tasks });
  } catch (e) {
    console.warn("[notes/report] failed:", e instanceof Error ? e.message : e);
    return NextResponse.json({ error: "summary failed" }, { status: 502 });
  }
}
