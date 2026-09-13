import { NextRequest, NextResponse } from "next/server";
import { ensureSchema, sql } from "@/lib/db";
import { syncAccount } from "@/lib/tasks";

/**
 * GET /api/cron/sync — Vercel cron: one direct-mode sync round for every
 * account with a Paperclip connection. The phone's feed poll already drives
 * sync while the app is open; this covers accounts with nothing open.
 * Protected by CRON_SECRET (Vercel sends it as a bearer token).
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (secret && req.headers.get("authorization") !== `Bearer ${secret}`) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  await ensureSchema();
  const rows = await sql()<{ email: string }[]>`SELECT email FROM paperclip_connections WHERE mode = 'direct'`;
  const out: Record<string, number> = {};
  for (const { email } of rows) {
    try {
      out[email] = (await syncAccount(email)).touched;
    } catch (e) {
      out[email] = -1;
      console.warn("[cron/sync]", email, e instanceof Error ? e.message : e);
    }
  }
  return NextResponse.json({ ok: true, accounts: rows.length, touched: out });
}
