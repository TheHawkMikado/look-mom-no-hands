import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { appEmail } from "@/lib/appauth";
import { syncAccount } from "@/lib/tasks";

/** POST /api/app/tasks/sync — run one direct-mode sync round now. */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  await ensureSchema();
  const r = await syncAccount(email);
  return NextResponse.json(r);
}
