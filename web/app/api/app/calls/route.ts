import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { parseCallRequest, placeCall } from "@/lib/calls";
import { listCalls } from "@/lib/db-calls";

/**
 * POST /api/app/calls — place an outbound call (SPEC.md §5.5).
 * Body: { task_id?, to (E.164), who, goal, constraints?, preferences?,
 *        tier?, budget_cents?, on_behalf_of? }
 * `to`, `preferences` and `on_behalf_of` are used for this call and not
 * stored. Tier 0–1 goes now; tier 2+ needs an approved approval on the task
 * — the first call requests one and returns 202 `awaiting_approval`; call
 * again after the owner approves. 409 when Vapi is not connected.
 *
 * GET /api/app/calls — recent calls with their structured outcomes.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const noStore = { headers: { "cache-control": "no-store" } };

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const r = parseCallRequest(await req.json().catch(() => ({})));
  if ("error" in r) return NextResponse.json({ error: r.error }, { status: 400 });
  await ensureSchema();
  const out = await placeCall(email, r);
  const status = out.status === "placed" ? 200 : out.status === "awaiting_approval" ? 202 : out.status === "not_configured" ? 409 : 502;
  return NextResponse.json(out, { status, ...noStore });
}

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  await ensureSchema();
  return NextResponse.json({ calls: await listCalls(email) }, noStore);
}
