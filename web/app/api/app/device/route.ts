import { NextRequest, NextResponse } from "next/server";
import { ensureSchema, recordActivation } from "@/lib/db";
import { appEmail, resolveEntitlement } from "@/lib/appauth";
import { signToken } from "@/lib/licence";

/**
 * POST /api/app/device { device, version } — register this Mac against the
 * account and return a device-bound offline entitlement token.
 *
 * There's no device cap: access is tied to the account, and Cloud usage is
 * metered (more devices = more usage = more revenue), so we record the device
 * for visibility but never refuse one. A re-checking device just refreshes its
 * timestamp.
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
    isSubUser: ent.isSubUser,
    entitlements: { devices: ent.devices, subUsers: ent.subUsers },
    token,
  });
}
