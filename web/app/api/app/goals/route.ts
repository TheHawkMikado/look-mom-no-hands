import { NextRequest, NextResponse } from "next/server";
import { ensureSchema, submitPhoneGoal } from "@/lib/db";
import { appEmail } from "@/lib/appauth";

/**
 * POST /api/app/goals — the phone submits a spoken task for the account's Mac.
 * Same bearer-token auth as every device endpoint; the Mac collects pending
 * goals via /api/app/goals/poll. Text only, capped — the goal is an instruction,
 * not a payload.
 */

export const runtime = "nodejs";

const TEXT_MAX = 2000;

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const text = String(body.text ?? "").trim().slice(0, TEXT_MAX);
  if (!text) return NextResponse.json({ error: "empty goal" }, { status: 400 });

  await ensureSchema();
  const id = await submitPhoneGoal(email, text);
  return NextResponse.json({ ok: true, id });
}
