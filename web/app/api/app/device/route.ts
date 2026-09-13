import { NextRequest, NextResponse } from "next/server";
import { ensureSchema, recordActivation } from "@/lib/db";
import { appEmail, resolveEntitlement } from "@/lib/appauth";
import { signToken } from "@/lib/licence";
import { isExpoPushToken, setPushToken } from "@/lib/push";

/**
 * POST /api/app/device { device, version, pushToken?, platform? } — register
 * this Mac or phone against the account and return a device-bound offline
 * entitlement token.
 *
 * There's no device cap: access is tied to the account, and Cloud usage is
 * metered (more devices = more usage = more revenue), so we record the device
 * for visibility but never refuse one. A re-checking device just refreshes its
 * timestamp.
 *
 * A phone sends its Expo push token (`ExponentPushToken[...]`) and platform
 * (`ios` | `android`); approvals and escalation prompts are pushed to every
 * registered token (lib/push). Sending `pushToken: null` clears it.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const device = String(body.device ?? "").trim();
  const version = String(body.version ?? "");
  if (!device) return NextResponse.json({ error: "no_device" }, { status: 400 });

  await ensureSchema();
  const ent = await resolveEntitlement(email);
  if (!ent) return NextResponse.json({ error: "no_subscription" }, { status: 403 });
  if (!ent.active) return NextResponse.json({ error: "inactive" }, { status: 403 });

  // No device cap — record for visibility, never refuse.
  await recordActivation(ent.licence.key, device, version);
  if ("pushToken" in body) {
    const token = isExpoPushToken(body.pushToken) ? body.pushToken : null;
    if (body.pushToken && !token) return NextResponse.json({ error: "bad_push_token" }, { status: 400 });
    const platform = body.platform === "ios" || body.platform === "android" ? body.platform : null;
    await setPushToken(ent.licence.key, device, token, token ? platform : null);
  }

  // Device-bound Ed25519 token for offline grace — same format the Swift app
  // already verifies against its compiled public key.
  const token = signToken({
    email,
    plan: ent.plan,
    exp: ent.expiresAt ? Math.floor(ent.expiresAt.getTime() / 1000) : 0,
    issuedAt: Math.floor(Date.now() / 1000),
    device,
    devices: ent.devices,
    subUsers: ent.subUsers,
  });

  return NextResponse.json({
    ok: true,
    email,
    plan: ent.plan,
    mode: ent.mode,
    isSubUser: ent.isSubUser,
    entitlements: { devices: ent.devices, subUsers: ent.subUsers },
    token,
  });
}
