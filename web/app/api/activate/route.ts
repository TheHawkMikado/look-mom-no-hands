import { NextRequest, NextResponse } from "next/server";
import { countDevices, deviceKnown, ensureSchema, findLicence, recordActivation } from "@/lib/db";
import { normaliseKey, signToken } from "@/lib/licence";

/**
 * POST /api/activate  { key, device, version } -> { token }
 *
 * Called once per Mac, by the app, in exchange for a signed entitlement it can
 * then verify offline forever. Every error path returns a message written for
 * the customer staring at the panel, because that string is displayed verbatim.
 */

export const runtime = "nodejs"; // node:crypto Ed25519 — not available on edge

const json = (body: unknown, status = 200) => NextResponse.json(body, { status });

export async function POST(req: NextRequest) {
  let body: { key?: string; device?: string; version?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Malformed request." }, 400);
  }

  const key = normaliseKey(body.key ?? "");
  const device = (body.device ?? "").trim();
  const version = (body.version ?? "unknown").slice(0, 32);

  if (!key) return json({ error: "No licence key supplied." }, 400);
  // The app derives this from the hardware UUID; absent means a build we can't
  // seat-count, so refuse rather than issue an unbound token.
  if (!device) return json({ error: "This build did not send a device identifier." }, 400);

  await ensureSchema();

  const licence = await findLicence(key);
  if (!licence) {
    return json({ error: "That licence key isn't recognised. Check for typos, or reply to your receipt email." }, 404);
  }
  if (licence.revoked) {
    return json({ error: "This licence has been revoked. Get in touch if that's unexpected." }, 403);
  }
  if (licence.expires_at && licence.expires_at.getTime() < Date.now()) {
    return json({ error: "This licence has expired. Renew at nohandsapp.com to reactivate." }, 403);
  }

  // Seat check runs only for genuinely new machines, so reinstalling on a Mac
  // that's already activated never costs a seat.
  const known = await deviceKnown(key, device);
  if (!known && (await countDevices(key)) >= licence.seats) {
    return json(
      { error: `This licence is already active on ${licence.seats} Macs. Deactivate one from its panel, then try again.` },
      403,
    );
  }

  await recordActivation(key, device, version);

  const token = signToken({
    email: licence.email,
    plan: licence.plan,
    exp: licence.expires_at ? Math.floor(licence.expires_at.getTime() / 1000) : 0,
    issuedAt: Math.floor(Date.now() / 1000),
    device,
  });

  return json({ token, email: licence.email, plan: licence.plan });
}
