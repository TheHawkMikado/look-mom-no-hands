import { sql } from "@/lib/db";
import { getSettings } from "@/lib/settings";

/**
 * Push notifications to the account's phones (SPEC.md §6: push with one-tap
 * approve is the fallback for voice). Tokens are Expo push tokens the phone
 * registers through /api/app/device, stored on the same `activations` row
 * as the device itself. Sent through Expo's push API, which needs no secret.
 *
 * Push is best-effort by rule: nothing that creates an approval or a prompt
 * may fail or stall because a phone was off. Every entry point here swallows
 * and logs; the caller gets a count, never an exception.
 */

export const EXPO_PUSH_URL = "https://exp.host/--/api/v2/push/send";
export const EXPO_RECEIPTS_URL = "https://exp.host/--/api/v2/push/getReceipts";
const SEND_TIMEOUT_MS = 4000;

export async function ensurePushSchema(db = sql()) {
  await db`ALTER TABLE activations ADD COLUMN IF NOT EXISTS push_token text`;
  await db`ALTER TABLE activations ADD COLUMN IF NOT EXISTS push_platform text`;
  // Expo receipts arrive minutes after the ticket; we keep the ticket ids so
  // the cron can collect them and drop tokens for uninstalled apps.
  await db`
    CREATE TABLE IF NOT EXISTS push_tickets (
      id         text PRIMARY KEY,
      email      text NOT NULL,
      token      text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now()
    )`;
}

export function isExpoPushToken(s: unknown): s is string {
  return typeof s === "string" && /^Expo(nent)?PushToken\[[A-Za-z0-9_-]+\]$/.test(s);
}

export async function setPushToken(licenceKey: string, device: string, token: string | null, platform: string | null) {
  await sql()`
    UPDATE activations SET push_token = ${token}, push_platform = ${platform}
     WHERE key = ${licenceKey} AND device = ${device}`;
}

/** Every registered phone on the account (all of its licences). */
export async function pushTokensFor(email: string): Promise<string[]> {
  const rows = await sql()<{ push_token: string }[]>`
    SELECT DISTINCT a.push_token FROM activations a JOIN licences l ON l.key = a.key
     WHERE lower(l.email) = ${email.trim().toLowerCase()} AND a.push_token IS NOT NULL`;
  return rows.map((r) => r.push_token);
}

async function clearToken(token: string) {
  await sql()`UPDATE activations SET push_token = NULL WHERE push_token = ${token}`;
}

export interface PushMessage {
  title: string;
  body: string;
  data?: Record<string, string>;
}

interface ExpoTicket {
  status: "ok" | "error";
  id?: string;
  message?: string;
  details?: { error?: string };
}

/** Send one message to every phone on the account. Never throws. */
export async function sendPush(email: string, m: PushMessage, fetchImpl: typeof fetch = fetch): Promise<{ sent: number; failed: number }> {
  try {
    const settings = await getSettings(email);
    if (!settings.push_enabled) return { sent: 0, failed: 0 };
    const tokens = await pushTokensFor(email);
    if (tokens.length === 0) return { sent: 0, failed: 0 };
    const messages = tokens.map((to) => ({ to, title: m.title.slice(0, 120), body: m.body.slice(0, 400), data: m.data ?? {}, sound: "default", priority: "high" }));
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), SEND_TIMEOUT_MS);
    let tickets: ExpoTicket[] = [];
    try {
      const res = await fetchImpl(EXPO_PUSH_URL, {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify(messages),
        signal: ctrl.signal,
      });
      const json = (await res.json().catch(() => ({}))) as { data?: ExpoTicket[] };
      tickets = Array.isArray(json.data) ? json.data : [];
    } finally {
      clearTimeout(timer);
    }
    let sent = 0;
    let failed = 0;
    const pending: { id: string; token: string }[] = [];
    for (let i = 0; i < tokens.length; i++) {
      const t = tickets[i];
      if (t?.status === "ok" && t.id) {
        sent++;
        pending.push({ id: t.id, token: tokens[i] });
      } else {
        failed++;
        if (t?.details?.error === "DeviceNotRegistered") await clearToken(tokens[i]).catch(() => undefined);
      }
    }
    if (pending.length) {
      await sql()`INSERT INTO push_tickets ${sql()(pending.map((p) => ({ id: p.id, email: email.trim().toLowerCase(), token: p.token })), "id", "email", "token")} ON CONFLICT (id) DO NOTHING`;
    }
    return { sent, failed };
  } catch (e) {
    console.warn("[push] send failed:", e instanceof Error ? e.message : e);
    return { sent: 0, failed: 0 };
  }
}

/** Collect Expo receipts for tickets old enough to have one; a
 *  DeviceNotRegistered receipt clears the token. Run from the cron. */
export async function collectPushReceipts(fetchImpl: typeof fetch = fetch, now = new Date()): Promise<{ checked: number; cleared: number }> {
  const db = sql();
  const rows = await db<{ id: string; token: string }[]>`
    SELECT id, token FROM push_tickets WHERE created_at < ${new Date(now.getTime() - 2 * 60_000)} ORDER BY created_at LIMIT 300`;
  if (rows.length === 0) return { checked: 0, cleared: 0 };
  let cleared = 0;
  try {
    const res = await fetchImpl(EXPO_RECEIPTS_URL, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ ids: rows.map((r) => r.id) }),
    });
    const json = (await res.json().catch(() => ({}))) as { data?: Record<string, ExpoTicket> };
    for (const r of rows) {
      const receipt = json.data?.[r.id];
      if (!receipt) continue; // not ready yet; try next round
      if (receipt.status === "error" && receipt.details?.error === "DeviceNotRegistered") {
        await clearToken(r.token);
        cleared++;
      }
      await db`DELETE FROM push_tickets WHERE id = ${r.id}`;
    }
  } catch (e) {
    console.warn("[push] receipts failed:", e instanceof Error ? e.message : e);
  }
  // Tickets Expo never answered are dropped after a day so the table cannot grow.
  await db`DELETE FROM push_tickets WHERE created_at < ${new Date(now.getTime() - 24 * 3_600_000)}`;
  return { checked: rows.length, cleared };
}
