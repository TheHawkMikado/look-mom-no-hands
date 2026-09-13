import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { getTask } from "@/lib/db-tasks";
import { appEmail } from "@/lib/appauth";
import { parseDelivery } from "@/lib/notify";
import { deliverTask } from "@/lib/tasks";

/**
 * POST /api/app/tasks/:id/deliver — send (or re-send) a human ticket.
 * Body: { channel: 'email'|'sms', to, name, from?, audience?: 'team'|'client',
 *        purpose?: 'ticket'|'reminder' }
 * The Mac supplies the address from its Local Brain every time; it is used
 * for this send and not stored. Tier 2+ needs an approved approval on the
 * task (or an `auto_deliver_tier` that covers it) — otherwise one is
 * requested and the response says `awaiting_approval`.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const { id } = await ctx.params;
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const deliver = parseDelivery(body);
  if (!deliver) return NextResponse.json({ error: "channel ('email'|'sms'), to and name required" }, { status: 400 });
  const purpose = body.purpose === "reminder" ? "reminder" : "ticket";

  await ensureSchema();
  const task = await getTask(email, id);
  if (!task) return NextResponse.json({ error: "not found" }, { status: 404 });
  if (task.closed_at) return NextResponse.json({ error: "task is closed" }, { status: 409 });
  const r = await deliverTask(email, task, deliver, purpose);
  return NextResponse.json({ ok: true, delivery: r.outcome, task: r.task, receipt: r.send?.receipt ?? null }, { headers: { "cache-control": "no-store" } });
}
