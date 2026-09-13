import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { handleVapiWebhook } from "@/lib/calls";

/**
 * POST /api/calls/vapi — Vapi's server-URL webhook. Unauthenticated by
 * bearer (Vapi calls it), so a message is only acted on when its call id
 * matches a call we placed, and, when the account (or VAPI_WEBHOOK_SECRET)
 * has a secret, when `x-vapi-secret` matches. An end-of-call report becomes
 * the task's structured result and a receipt; the transcript in the payload
 * is never read into storage (SPEC.md §4.3).
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "bad request" }, { status: 400 });
  await ensureSchema();
  const r = await handleVapiWebhook(body, req.headers.get("x-vapi-secret"));
  return NextResponse.json({ ok: r.ok, handled: r.handled }, { status: r.status });
}
