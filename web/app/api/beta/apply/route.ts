import { NextRequest, NextResponse } from "next/server";
import { ensureSchema } from "@/lib/db";
import { submitApplication } from "@/lib/db-beta";
import { sendPlainEmail } from "@/lib/email";

export const runtime = "nodejs";

const clip = (v: unknown, n: number) => String(v ?? "").trim().slice(0, n);

/** POST /api/beta/apply — a beta-tester application from /testers. */
export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => ({}));
  // Honeypot: real people never fill a hidden field.
  if (body.website) return NextResponse.json({ ok: true });
  const name = clip(body.name, 120);
  const email = clip(body.email, 200).toLowerCase();
  const role = clip(body.role, 200);
  const machine = clip(body.machine, 200);
  const use_case = clip(body.use_case, 2000);
  const social = clip(body.social, 300);
  if (!name || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    return NextResponse.json({ error: "A name and a real email are required." }, { status: 400 });
  }
  if (!body.commit_hours || !body.commit_forms) {
    return NextResponse.json({ error: "Please confirm both commitments." }, { status: 400 });
  }
  await ensureSchema();
  await submitApplication({ name, email, role, machine, use_case, social });
  try {
    await sendPlainEmail(
      email,
      "Got your beta application — Look Ma, No Hands",
      `Hey ${name},\n\nGot it. Ten seats, and I read every application myself. If you're in, you'll get an email with your licence and the install steps.\n\nThe deal, so it's in writing: 5+ hours of real use a month, one short feedback form a month, for three months. In return the app is yours for life.\n\n— Hawk\nnohandsapp.com`,
    );
  } catch (err) {
    console.error("application ack email failed", err);
  }
  return NextResponse.json({ ok: true });
}
