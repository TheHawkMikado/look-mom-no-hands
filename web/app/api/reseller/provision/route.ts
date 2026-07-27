import { NextRequest, NextResponse } from "next/server";
import {
  countSubLicences,
  ensureSchema,
  insertLicence,
  licencesForEmail,
  resellerByProvisionKey,
} from "@/lib/db";
import { mintLicenceKey } from "@/lib/licence";
import { DEFAULT_PLANS } from "@/lib/catalogue";
import { syncCommunityOverage } from "@/lib/overage";

/**
 * POST /api/reseller/provision  { email }  (Authorization: Bearer <provision key>)
 *
 * Creates a Solo sub-user under the reseller's account — the programmatic path
 * for the free/bundled distribution mode. The customer signs in with `email` and
 * runs on the reseller's keys. Recurring resellers are billed the usual overage
 * past 27; lifetime Resellers are unlimited.
 */

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer\s+(.+)$/i);
  if (!m) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  await ensureSchema();
  const resellerEmail = await resellerByProvisionKey(m[1].trim());
  if (!resellerEmail) return NextResponse.json({ error: "unauthorized" }, { status: 401 });

  const body = await req.json().catch(() => ({}));
  const email = String(body.email ?? "").trim().toLowerCase();
  if (!email.includes("@")) return NextResponse.json({ error: "invalid_email" }, { status: 400 });

  const mine = await licencesForEmail(resellerEmail);
  const licence = mine.find((l) => !l.parent_key && l.resell);
  if (!licence || licence.revoked) {
    return NextResponse.json({ error: "no_reseller_plan" }, { status: 403 });
  }

  const used = await countSubLicences(licence.key);
  if (used >= licence.sub_users) {
    return NextResponse.json({ error: "allowance_reached" }, { status: 403 });
  }

  const solo = DEFAULT_PLANS.find((p) => p.slug === "solo")!;
  const key = mintLicenceKey();
  await insertLicence({
    key,
    email,
    plan: "solo",
    expiresAt: licence.expires_at,
    seats: solo.computers,
    phones: solo.phones,
    subUsers: 0,
    resell: false,
    mode: licence.mode,
    parentKey: licence.key,
    note: "provisioned via API",
  });
  try {
    await syncCommunityOverage(licence);
  } catch (err) {
    console.error("community overage sync failed", err);
  }

  return NextResponse.json({ ok: true, email });
}
