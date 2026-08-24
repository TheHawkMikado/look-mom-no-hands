import { NextRequest, NextResponse } from "next/server";
import {
  AGENT_EVENT_KINDS,
  ensureSchema,
  recordAgentEvents,
  type AgentEventKind,
} from "@/lib/db";
import { appEmail } from "@/lib/appauth";

/**
 * POST /api/app/events — the Mac app reports agent activity (goal started /
 * progress / needs approval / done / failed) so the owner can watch from
 * /status on any device. Status text only — never screenshots or transcripts;
 * `detail` is capped server-side so a chatty client can't smuggle content in.
 * Events are per-account, retained newest-200 (pruned on insert).
 *
 * Body: { events: [{ id, kind, title, detail, approvalId, createdAt }] }
 */

export const runtime = "nodejs";

const DETAIL_MAX = 500;
const TITLE_MAX = 200;
const ID_MAX = 128;
/** More than fits retention anyway — bounds the write per call. */
const BATCH_MAX = 50;

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const raw: unknown[] = Array.isArray(body.events) ? body.events : [];

  const events = [];
  for (const item of raw.slice(0, BATCH_MAX)) {
    const o = (item ?? {}) as Record<string, unknown>;
    const id = String(o.id ?? "").trim();
    const kind = String(o.kind ?? "");
    if (!id || !(AGENT_EVENT_KINDS as readonly string[]).includes(kind)) continue;
    const createdAt = new Date(String(o.createdAt ?? ""));
    events.push({
      id: id.slice(0, ID_MAX),
      kind: kind as AgentEventKind,
      title: String(o.title ?? "").slice(0, TITLE_MAX),
      detail: String(o.detail ?? "").slice(0, DETAIL_MAX),
      approvalId: o.approvalId == null ? null : String(o.approvalId).slice(0, ID_MAX),
      createdAt: Number.isNaN(createdAt.getTime()) ? new Date() : createdAt,
    });
  }

  await ensureSchema();
  if (events.length > 0) await recordAgentEvents(email, events);
  return NextResponse.json({ ok: true, stored: events.length });
}
