import { NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { getSession } from "@/lib/auth";
import { teamBoard } from "@/lib/team";

/** GET /api/status/team — the same board behind the cookie session, for /team. */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  const session = await getSession();
  if (!session) return NextResponse.json({ error: "Sign in first." }, { status: 401 });
  await ensureSchema();
  return NextResponse.json(await teamBoard(session.email), { headers: { "cache-control": "no-store" } });
}
