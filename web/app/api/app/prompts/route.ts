import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { markSpoken, openPrompts } from "@/lib/prompts";

/**
 * GET /api/app/prompts — the questions the bot wants to ask, oldest first,
 * only those whose moment has come (quiet hours respected). The Mac speaks
 * them when idle. `?mark=spoken` stamps `spoken_at` on the ones returned so
 * two Macs on one account don't both ask.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  await ensureSchema();
  const prompts = await openPrompts(email);
  if (req.nextUrl.searchParams.get("mark") === "spoken") await markSpoken(email, prompts.map((p) => p.id));
  return NextResponse.json(
    {
      prompts: prompts.map((p) => ({
        id: p.id,
        kind: p.kind,
        taskId: p.task_id,
        question: p.question,
        defaultAnswer: p.default_answer,
        spokenAt: p.spoken_at ? new Date(p.spoken_at).toISOString() : null,
        createdAt: new Date(p.created_at).toISOString(),
      })),
    },
    { headers: { "cache-control": "no-store" } },
  );
}
