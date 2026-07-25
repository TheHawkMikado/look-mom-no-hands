import { NextRequest, NextResponse } from "next/server";
import { revokeAppToken } from "@/lib/db";

/** POST /api/app/logout — revoke the calling app token (sign this device out). */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer\s+(.+)$/i);
  if (m) await revokeAppToken(m[1].trim());
  return NextResponse.json({ ok: true });
}
