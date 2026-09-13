import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { cleanSettingsPatch, getSettings, setSettings } from "@/lib/settings";

/**
 * GET  /api/app/settings — the account's follow-up settings.
 * PUT  /api/app/settings — { tz?, quiet_hours_start?, quiet_hours_end?,
 *      daily_brief_at?, push_enabled?, auto_deliver_tier? }; null clears a
 *      time. The Mac sends its zone on sign-in so "by 3" means the user's 3.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const noStore = { headers: { "cache-control": "no-store" } };

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  await ensureSchema();
  return NextResponse.json({ settings: await getSettings(email) }, noStore);
}

export async function PUT(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const patch = cleanSettingsPatch(body);
  await ensureSchema();
  return NextResponse.json({ ok: true, settings: await setSettings(email, patch) }, noStore);
}

export { PUT as POST };
