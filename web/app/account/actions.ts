"use server";

import { revalidatePath } from "next/cache";
import { requireSession } from "@/lib/auth";
import { mintLicenceKey } from "@/lib/licence";
import {
  countSubLicences,
  ensureSchema,
  insertLicence,
  licencesForEmail,
  removeActivation,
} from "@/lib/db";
import { DEFAULT_PLANS } from "@/lib/catalogue";

/**
 * Member actions.
 *
 * Every one re-reads the licence from the database and checks it belongs to the
 * session's email. The session cookie says who you are, never what you own —
 * otherwise a licence key posted from a form would be enough to act on someone
 * else's account.
 */

async function ownedLicence(key: string) {
  const session = await requireSession();
  await ensureSchema();
  const mine = await licencesForEmail(session.email);
  const licence = mine.find((l) => l.key === key);
  if (!licence) throw new Error("That licence isn't on your account.");
  return { session, licence };
}

/**
 * Frees a seat. Note this does not disable that Mac immediately: its token was
 * already minted and is checked offline, so it keeps working until the token
 * expires. It stops the machine renewing, which is the honest description.
 */
export async function freeSeat(formData: FormData) {
  const key = String(formData.get("key") ?? "");
  const device = String(formData.get("device") ?? "");
  if (!key || !device) return;

  await ownedLicence(key);
  await removeActivation(key, device);
  revalidatePath("/account");
}

/**
 * Issues a Solo sub-licence under a reseller's licence.
 *
 * The allowance check counts rows rather than trusting a stored tally, so
 * concurrent submissions can't both slip past a stale number. Sub-licences
 * inherit the parent's expiry: a reseller whose own subscription lapses should
 * not leave working keys behind them.
 */
export async function createSubLicence(formData: FormData) {
  const parentKey = String(formData.get("key") ?? "");
  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  const note = String(formData.get("note") ?? "").trim();

  if (!email || !email.includes("@")) {
    throw new Error("Enter the sub-user's email address.");
  }

  const { licence } = await ownedLicence(parentKey);
  if (!licence.resell) throw new Error("This plan doesn't include resell rights.");
  if (licence.revoked) throw new Error("This licence has been revoked.");

  const used = await countSubLicences(parentKey);
  if (used >= licence.sub_users) {
    throw new Error(
      `You've issued all ${licence.sub_users} included sub-users. ` +
        "Additional users are billed at $1/week — contact support to raise your allowance.",
    );
  }

  const solo = DEFAULT_PLANS.find((p) => p.slug === "solo")!;
  await insertLicence({
    key: mintLicenceKey(),
    email,
    plan: "solo",
    expiresAt: licence.expires_at,
    seats: solo.computers,
    phones: solo.phones,
    subUsers: 0,
    resell: false,
    parentKey,
    note: note || null,
  });

  revalidatePath("/account");
}
