import { NextRequest, NextResponse } from "next/server";
import { ensureSchema, recordUsage, type UsageBucket } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { chargeCloudMeter } from "@/lib/metering";

/**
 * POST /api/app/usage — the app reports its cumulative per-device usage (metered
 * controller/dictation API cost + hours, split by workload, tagged by mode). Only
 * counts, never content. Feeds pricing analysis across both Cloud and BYOK, and
 * seeds Cloud overage metering.
 */

export const runtime = "nodejs";

const bucket = (v: unknown): UsageBucket => {
  const o = (v ?? {}) as Record<string, unknown>;
  return {
    cost: Math.max(0, Number(o.cost) || 0),
    calls: Math.max(0, Math.floor(Number(o.calls) || 0)),
    seconds: Math.max(0, Number(o.seconds) || 0),
  };
};

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const device = String(body.device ?? "").trim();
  if (!device) return NextResponse.json({ error: "no_device" }, { status: 400 });
  const mode = body.mode === "cloud" ? "cloud" : "byok";

  await ensureSchema();
  const delta = await recordUsage(email, device, mode, bucket(body.controller), bucket(body.dictation));
  // Cloud usage draws down the weekly allowance (and then the wallet); BYOK no-ops.
  await chargeCloudMeter(email, delta.dCtrlSeconds, delta.dDictSeconds);
  return NextResponse.json({ ok: true });
}
