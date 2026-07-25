import { NextRequest, NextResponse } from "next/server";
import { ensureSchema, getAccountKeys } from "@/lib/db";
import { appEmail } from "@/lib/appauth";

/**
 * GET /api/app/keys — the Anthropic + ElevenLabs keys the signed-in app should
 * use. A sub-user transparently gets its parent account's keys (resolved in
 * getAccountKeys). This is the shared-key delivery: the account holder sets the
 * keys once on the website, every signed-in device fetches them here.
 */

export const runtime = "nodejs";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  await ensureSchema();
  const keys = await getAccountKeys(email);
  return NextResponse.json(
    { anthropic: keys.anthropic, elevenlabs: keys.elevenlabs },
    { headers: { "cache-control": "no-store" } },
  );
}
