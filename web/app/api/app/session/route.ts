import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail, resolveEntitlement } from "@/lib/appauth";

/** GET /api/app/session — who the app is signed in as, and their current plan +
 *  entitlement status. Read-only; the app calls it to render status and re-check. */

export const runtime = "nodejs";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  await ensureSchema();
  const ent = await resolveEntitlement(email);
  return NextResponse.json(
    {
      email,
      active: ent?.active ?? false,
      plan: ent?.plan ?? null,
      mode: ent?.mode ?? "byok",
      isSubUser: ent?.isSubUser ?? false,
      parentEmail: ent?.parentEmail ?? null,
      entitlements: ent ? { devices: ent.devices, subUsers: ent.subUsers } : null,
      expiresAt: ent?.expiresAt ? Math.floor(ent.expiresAt.getTime() / 1000) : 0,
    },
    { headers: { "cache-control": "no-store" } },
  );
}
