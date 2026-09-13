import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { runEvals } from "@/lib/evals/run";

/**
 * GET /api/cron/evals — Vercel cron (weekly, Sunday 03:00 UTC): the eval
 * job behind the router (SPEC.md §7). Runs every fixture set against every
 * candidate in `routing_scores` and writes measured scores back. Protected
 * by CRON_SECRET like /api/cron/sync. Without an Anthropic key only the
 * `local` candidates are measured; model rows are skipped with a warning.
 * `?types=task_extract,triage_decision` narrows the run.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

export async function GET(req: NextRequest) {
  const secret = process.env.CRON_SECRET;
  if (secret && req.headers.get("authorization") !== `Bearer ${secret}`) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }
  await ensureSchema();
  const types = req.nextUrl.searchParams.get("types")?.split(",").filter(Boolean);
  const summary = await runEvals({ taskTypes: types });
  return NextResponse.json({ ok: true, ...summary });
}
