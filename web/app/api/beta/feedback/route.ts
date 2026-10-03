import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { feedbackMonth, submitFeedback } from "@/lib/db-beta";

export const runtime = "nodejs";

const clip = (v: unknown, n: number) => String(v ?? "").trim().slice(0, n);

/** POST /api/beta/feedback — a tester's monthly form from /testers/feedback. */
export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => ({}));
  if (body.website) return NextResponse.json({ ok: true });
  const email = clip(body.email, 200).toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return NextResponse.json({ error: "The email you applied with is required." }, { status: 400 });
  }
  const month = /^\d{4}-\d{2}$/.test(String(body.month ?? "")) ? String(body.month) : feedbackMonth();
  const hours = Math.max(0, Math.min(500, parseInt(String(body.hours ?? "0"), 10) || 0));
  const score = Math.max(0, Math.min(10, parseInt(String(body.score ?? "0"), 10) || 0));
  const worked = clip(body.worked, 4000);
  const broke = clip(body.broke, 4000);
  const wish = clip(body.wish, 4000);
  if (!worked && !broke && !wish) {
    return NextResponse.json({ error: "Tell me at least one thing." }, { status: 400 });
  }
  await ensureSchema();
  await submitFeedback({ email, month, hours, worked, broke, wish, score });
  return NextResponse.json({ ok: true });
}
