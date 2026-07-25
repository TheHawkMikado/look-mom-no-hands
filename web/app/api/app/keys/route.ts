import { NextRequest, NextResponse } from "next/server";
import { ensureSchema, getAccountKeys, getPlatformKeys } from "@/lib/db";
import { appEmail, resolveEntitlement } from "@/lib/appauth";

/**
 * GET /api/app/keys — the Anthropic + ElevenLabs keys the signed-in app should
 * run on.
 *
 * - **Cloud** subscriptions run on the **platform's** keys (the owner's, set in
 *   the admin) — that's what "we supply the AI" means.
 * - **BYOK** subscriptions run on the **account's own** keys (a sub-user
 *   transparently gets its parent's, resolved in getAccountKeys).
 *
 * This is the shared-key delivery: the keys are set once (on the account for
 * BYOK, in the admin for Cloud) and every signed-in device fetches them here.
 */

export const runtime = "nodejs";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  await ensureSchema();
  const ent = await resolveEntitlement(email);
  const keys = ent?.mode === "cloud" ? await getPlatformKeys() : await getAccountKeys(email);
  return NextResponse.json(
    { anthropic: keys.anthropic, elevenlabs: keys.elevenlabs },
    { headers: { "cache-control": "no-store" } },
  );
}
