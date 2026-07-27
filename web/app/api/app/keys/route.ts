import { NextRequest, NextResponse } from "next/server";
import { ensureSchema, getAccountKeys, getPlatformKeys } from "@/lib/db";
import { appEmail, resolveEntitlement } from "@/lib/appauth";
import { meterStatusFor } from "@/lib/metering";

/**
 * GET /api/app/keys — the Anthropic + ElevenLabs keys the signed-in app runs on.
 *
 * - **Cloud** runs on the **platform's** keys — but only while the account is
 *   within its weekly hours or its prepaid credit covers the overage. Once that's
 *   spent, we return no keys (`depleted`) so the app stops until the week resets
 *   or they top up. That's the meter's teeth.
 * - **BYOK** runs on the account's own keys and is never metered.
 */

export const runtime = "nodejs";

const noStore = { headers: { "cache-control": "no-store" } };

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  await ensureSchema();
  const ent = await resolveEntitlement(email);

  if (ent?.mode === "cloud") {
    const meter = await meterStatusFor(email);
    if (!meter.ok) {
      return NextResponse.json({ anthropic: null, elevenlabs: null, depleted: true }, noStore);
    }
    const keys = await getPlatformKeys();
    return NextResponse.json({ anthropic: keys.anthropic, elevenlabs: keys.elevenlabs }, noStore);
  }

  const keys = await getAccountKeys(email);
  return NextResponse.json({ anthropic: keys.anthropic, elevenlabs: keys.elevenlabs }, noStore);
}
