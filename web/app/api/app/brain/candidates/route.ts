import { NextRequest, NextResponse } from "next/server";
import { appEmail } from "@/lib/appauth";
import { submitCandidate } from "@/lib/brain";
import { anthropicKeyFor } from "@/lib/extract";

/**
 * POST /api/app/brain/candidates — the Mac offers a learning for the Shared
 * Brain (SPEC.md §8.3). Body: { text, kind?: 'sop'|'website_flow'|'checklist'|'other' }.
 * The text is scrubbed before anything else looks at it; only a generic
 * candidate is stored, as `pending_consent`, and the user is asked once.
 * Returns { candidate|null, generic, reasons }.
 */

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  const email = await appEmail(req);
  if (!email) return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const text = String(body.text ?? "").trim().slice(0, 8000);
  if (!text) return NextResponse.json({ error: "text required" }, { status: 400 });
  const key = await anthropicKeyFor(email).catch(() => null);
  const r = await submitCandidate(email, { text, kind: body.kind, key });
  return NextResponse.json(
    { candidate: r.stored, generic: r.generic, reasons: r.reasons },
    { status: r.stored ? 201 : 200, headers: { "cache-control": "no-store" } },
  );
}
