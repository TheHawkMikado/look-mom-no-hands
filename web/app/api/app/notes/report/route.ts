import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { reportForNote } from "@/lib/notes";

/**
 * POST /api/app/notes/report { text } — summarize a phone dictation into
 * { title, summary, keyPoints, actionItems }. Stateless: the phone owns the
 * note and stores the report beside it.
 */

export const runtime = "nodejs";
// Opus with thinking on a long note runs well past the default function
// budget; the phone shows the note immediately and waits for this in the
// background, so latency here costs nothing visible.
export const maxDuration = 60;

const TEXT_MAX = 20000;

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
    return NextResponse.json(report);
  } catch (e) {
    console.warn("[notes/report] failed:", e instanceof Error ? e.message : e);
    return NextResponse.json({ error: "summary failed" }, { status: 502 });
  }
}
