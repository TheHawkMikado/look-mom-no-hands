import { NextRequest, NextResponse } from "next/server";
import { getSession } from "@/lib/auth";
import { ensureSchema } from "@/lib/db";
import { runEvals } from "@/lib/evals/run";

/**
 * POST /api/admin/evals/run — run the router evals now (admin session, the
 * same cookie /admin uses). Body: { types?: string[], key?: string }. `key`
 * is used for this run only and never stored; without it the platform key
 * (ANTHROPIC_API_KEY) is used when set, else only local candidates run.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

export async function POST(req: NextRequest) {
  const session = await getSession();
  if (!session) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  if (!session.admin) return NextResponse.json({ error: "forbidden" }, { status: 403 });
  const body = (await req.json().catch(() => ({}))) as { types?: unknown; key?: unknown };
  const types = Array.isArray(body.types) ? body.types.map(String) : undefined;
  const key = typeof body.key === "string" && body.key.trim() ? body.key.trim() : undefined;
  await ensureSchema();
  const summary = await runEvals({ taskTypes: types, ...(key ? { key } : {}) });
  return NextResponse.json({ ok: true, ...summary });
}
