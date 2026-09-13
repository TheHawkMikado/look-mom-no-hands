import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { invalidateRoutingCache, resolvedRouting } from "@/lib/router";
import { QUALITY_FLOOR } from "@/lib/routing-seed";

/** GET /api/app/routing — the resolved model routing table for clients to
 *  cache. Never hardcode a model in a client; read this. */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  await ensureSchema();
  // `?fresh=1` skips the 60 s table cache (the eval demo and admin checks).
  if (req.nextUrl.searchParams.get("fresh")) invalidateRoutingCache();
  const routes = await resolvedRouting();
  return NextResponse.json(
    { quality_floor: QUALITY_FLOOR, routes },
    { headers: { "cache-control": "private, max-age=300" } },
  );
}
