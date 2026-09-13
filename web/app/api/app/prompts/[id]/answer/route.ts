import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { answerPrompt } from "@/lib/followup";
import { parseDelivery } from "@/lib/notify";

/**
 * POST /api/app/prompts/:id/answer — { answer, deliver? }
 * "nudge" (or a time) reschedules, "handle" makes it the user's, "done" /
 * "drop" close it, anything else is a new instruction and goes through
 * intake. For a `deliver_reminder`, "yes" plus a `deliver` block (the Mac's
 * one-time address for the person) sends the reminder; without the block the
 * answer is recorded and `applied` is `needs_address`. An empty answer means
 * the default.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { id } = await ctx.params;
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const answer = String(body.answer ?? "").trim().slice(0, 2000);
  const deliver = body.deliver ? parseDelivery(body.deliver) : null;
  if (body.deliver && !deliver) return NextResponse.json({ error: "deliver needs { channel: 'email'|'sms', to, name }" }, { status: 400 });

  await ensureSchema();
  const r = await answerPrompt(email, id, answer, { deliver });
  if (!r) return NextResponse.json({ error: "not found" }, { status: 404 });
  return NextResponse.json(
    {
      ok: true,
      applied: r.applied,
      prompt: r.prompt,
      task: r.task,
      next_at: r.next_at ?? null,
      delivery: r.delivery ?? null,
      new_task: r.intake?.task ?? null,
      confirmation: r.intake?.confirmation ?? null,
    },
    { headers: { "cache-control": "no-store" } },
  );
}
