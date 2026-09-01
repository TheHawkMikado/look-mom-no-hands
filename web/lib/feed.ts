import { createHash } from "crypto";
import { NextRequest, NextResponse } from "next/server";
import { agentEventsFor, approvalVerdictsFor, decideApproval, ensureSchema } from "@/lib/db";

/**
 * The one place the feed and decide payloads are built. The phone
 * (/api/app/*, bearer auth) and the web page (/api/status/*, cookie auth) must
 * render the same truth — that used to be enforced by keeping two copies of
 * this code identical by hand, which had already drifted. Routes are now auth
 * adapters around these.
 */

export async function feedPayload(email: string) {
  await ensureSchema();
  const events = await agentEventsFor(email);
  // Verdicts only for approvals actually visible in the event window — the
  // old unbounded query shipped every verdict from 30 days of history on a
  // 5-second poll path.
  const approvalIds = events.map((e) => e.approval_id).filter((id): id is string => !!id);
  const decided = await approvalVerdictsFor(email, approvalIds);
  return {
    events: events.map((e) => ({
      id: e.id,
      kind: e.kind,
      title: e.title,
      detail: e.detail,
      approvalId: e.approval_id,
      createdAt: e.created_at.toISOString(),
    })),
    verdicts: Object.fromEntries(decided.map((v) => [v.approval_id, v.verdict])),
  };
}

/**
 * The feed as a full HTTP response with ETag/304 handling. Polled every 5s per
 * client and byte-identical almost every tick on an idle Mac — a 304 turns
 * ~100KB of repeated JSON into a header exchange. Both feed routes route
 * through here so phone and web get the same payload AND the same caching.
 */
export async function feedResponse(email: string, req: NextRequest): Promise<NextResponse> {
  const payload = await feedPayload(email);
  const body = JSON.stringify(payload);
  const etag = `"${createHash("sha1").update(body).digest("hex")}"`;
  if (req.headers.get("if-none-match") === etag) {
    return new NextResponse(null, { status: 304, headers: { etag } });
  }
  return new NextResponse(body, {
    headers: { "content-type": "application/json", "cache-control": "no-store", etag },
  });
}

export async function decidePayload(
  email: string,
  body: unknown,
): Promise<{ status: number; json: Record<string, unknown> }> {
  const o = (body ?? {}) as Record<string, unknown>;
  const approvalId = String(o.approvalId ?? "").trim().slice(0, 128);
  const verdict = o.verdict === "approve" ? "approve" : o.verdict === "deny" ? "deny" : null;
  if (!approvalId || !verdict) return { status: 400, json: { error: "bad request" } };
  await ensureSchema();
  const recorded = await decideApproval(email, approvalId, verdict);
  return { status: 200, json: { ok: true, recorded } };
}
