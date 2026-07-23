import { NextRequest, NextResponse } from "next/server";
import { endSession } from "@/lib/auth";

/** POST /api/auth/logout — clears the session cookie and returns home. */
export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  await endSession();
  const site = process.env.SITE_URL ?? req.nextUrl.origin;
  return NextResponse.redirect(`${site}/`, { status: 303 });
}
