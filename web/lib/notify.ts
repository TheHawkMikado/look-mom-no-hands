import { insertReceipt, type ReceiptRow, type TaskRow } from "@/lib/db-tasks";
import { emailConfigured, sendPlainEmail } from "@/lib/email";
import { GhlClient } from "@/lib/ghl";
import { getIntegration } from "@/lib/integrations";
import { describe } from "@/lib/when";

/**
 * Human tickets (SPEC.md §5.3 step 2, §11). A task assigned to a person on
 * the team goes to them by email or SMS. Persons live on the Mac; this
 * service never stores an address. The Mac hands us `{ channel, to, name }`
 * for one send, we use it, and it is gone — the task keeps only the channel
 * and the owner's name. A reminder later is a new hand-off from the Mac.
 *
 * Every attempt produces a receipt, including "not sent": a missing provider
 * must not fail the task, only tell the truth about it.
 */

export type Channel = "email" | "sms";

export interface Delivery {
  channel: Channel;
  /** The address — used once, never stored. */
  to: string;
  /** The person's name, as the owner says it. Stored on the task. */
  name: string;
  /** Who the ticket is from, for the message text. Not stored. */
  from?: string | null;
  /** Teammate (tier 2) or client (tier 3) — sets the floor for the task's tier. */
  audience?: "team" | "client";
}

/** Validate the Mac's delivery block. Returns null when it is unusable so
 *  the route can 400 rather than send a ticket to nobody. */
export function parseDelivery(input: unknown): Delivery | null {
  if (!input || typeof input !== "object") return null;
  const o = input as Record<string, unknown>;
  const channel = o.channel === "sms" ? "sms" : o.channel === "email" ? "email" : null;
  const to = String(o.to ?? "").trim();
  const name = String(o.name ?? "").trim().slice(0, 80);
  if (!channel || !to || !name) return null;
  if (channel === "email" && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) return null;
  if (channel === "sms" && !/^\+?[0-9][0-9 ()-]{6,}$/.test(to)) return null;
  return {
    channel,
    to,
    name,
    from: o.from ? String(o.from).trim().slice(0, 80) : null,
    audience: o.audience === "client" ? "client" : "team",
  };
}

/** The tier floor for messaging a human (§6): team-facing is 2, a client is 3. */
export function deliveryTierFloor(d: Delivery): 2 | 3 {
  return d.audience === "client" ? 3 : 2;
}

export type Purpose = "ticket" | "reminder";

/** Short, tier-appropriate, says who asked and by when. SMS gets the first
 *  line only. */
export function ticketText(task: TaskRow, d: Pick<Delivery, "name" | "from" | "audience">, purpose: Purpose, now = new Date(), tz = "America/New_York"): { subject: string; body: string; sms: string } {
  const from = d.from?.trim() || "the No Hands owner";
  const first = d.name.split(/\s+/)[0] || d.name;
  const when = task.due_at ? ` by ${describe(new Date(task.due_at), now, tz)}` : "";
  const client = d.audience === "client";
  const opener = purpose === "reminder"
    ? (client ? `A quick reminder from ${from}:` : `Quick nudge from ${from}:`)
    : (client ? `${from} asked me to pass this along:` : `${from} asked for a hand with this:`);
  const ask = `${task.title}${when}.`;
  const detail = task.detail && task.detail !== task.title ? `\n\n${task.detail}` : "";
  const signoff = client
    ? `\n\nReply to this message and it reaches ${from} directly.\n\n— No Hands, on behalf of ${from}`
    : `\n\nReply here when it's done or if anything's in the way.\n\n— No Hands, for ${from}`;
  const subject = purpose === "reminder" ? `Reminder: ${task.title}` : `${from}: ${task.title}`;
  const body = `Hi ${first},\n\n${opener} ${ask}${detail}${signoff}`;
  const sms = `${first} — ${opener} ${ask}${purpose === "reminder" ? "" : " Reply here when done."} (${from} via No Hands)`.slice(0, 320);
  return { subject, body, sms };
}

export interface SendResult {
  sent: boolean;
  via: "resend" | "ghl" | null;
  summary: string;
  receipt: ReceiptRow;
}

/**
 * Send the ticket (or a reminder) and write the receipt. Provider choice:
 * SMS needs GoHighLevel; email prefers Resend, falls back to GoHighLevel.
 * Neither configured → not sent, receipt says so, no throw.
 */
export async function deliverTicket(email: string, task: TaskRow, d: Delivery, purpose: Purpose, now = new Date(), tz?: string): Promise<SendResult> {
  const text = ticketText(task, d, purpose, now, tz);
  const what = purpose === "reminder" ? "Reminder" : "Ticket";
  let via: SendResult["via"] = null;
  let sent = false;
  let summary: string;
  try {
    if (d.channel === "sms") {
      const ghl = await getIntegration(email, "ghl");
      if (ghl) {
        const c = new GhlClient({ apiKey: ghl.api_key, locationId: ghl.location_id });
        const contact = await c.upsertContact({ phone: d.to, name: d.name });
        await c.sendSms(contact.id, text.sms, ghl.from_number ?? null);
        via = "ghl";
        sent = true;
      }
    } else if (emailConfigured()) {
      sent = await sendPlainEmail(d.to, text.subject, text.body, email);
      via = sent ? "resend" : null;
    } else {
      const ghl = await getIntegration(email, "ghl");
      if (ghl) {
        const c = new GhlClient({ apiKey: ghl.api_key, locationId: ghl.location_id });
        const contact = await c.upsertContact({ email: d.to, name: d.name });
        await c.sendEmail(contact.id, { subject: text.subject, text: text.body, emailFrom: ghl.from_email ?? null });
        via = "ghl";
        sent = true;
      }
    }
    summary = sent
      ? `${what} sent to ${d.name} by ${d.channel} via ${via}.`
      : `${what} to ${d.name} not sent: no ${d.channel === "sms" ? "SMS provider (connect GoHighLevel)" : "email provider configured"}.`;
  } catch (e) {
    summary = `${what} to ${d.name} by ${d.channel} failed: ${e instanceof Error ? e.message : String(e)}`.slice(0, 400);
    console.warn("[notify]", summary);
  }
  if (!sent) console.warn(`[notify] ${summary}`);
  const receipt = await insertReceipt(email, {
    task_id: task.id,
    actor: "system",
    actor_ref: via,
    summary,
  });
  return { sent, via, summary, receipt };
}
