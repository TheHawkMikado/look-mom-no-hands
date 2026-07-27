"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireSession } from "@/lib/auth";
import { mintLicenceKey } from "@/lib/licence";
import {
  countSubLicences,
  deleteLicence,
  ensureSchema,
  insertLicence,
  licencesForEmail,
  mintProvisionKey,
  mintWebhookSecret,
  removeActivation,
  setAccountKey,
  setResellerPrice,
  setResellerWebhookUrl,
  subLicencesOf,
} from "@/lib/db";
import { DEFAULT_PLANS } from "@/lib/catalogue";
import { syncCommunityOverage } from "@/lib/overage";

/** The floor a reseller may charge their customers — our Solo weekly price. */
const RESELL_FLOOR_CENTS = 300;

async function resellerLicence(email: string) {
  const mine = await licencesForEmail(email);
  return mine.find((l) => !l.parent_key && l.resell) ?? null;
}

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
 * Adds a sub-user under this account. Gated on the plan's `sub_users` allowance
 * (not "resell" — sub-users are a normal plan feature now). The allowance count
 * is a live row count so two submissions can't both slip past a stale number.
 * Sub-users get a Solo entitlement (their own login + a 3-device pool) that
 * expires with the parent's subscription. Community past its free tier is billed
 * per extra user; that Stripe quantity sync lives in the webhook/overage code.
 */
export async function createSubLicence(formData: FormData) {
  const parentKey = String(formData.get("key") ?? "");
  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  const note = String(formData.get("note") ?? "").trim();

  if (!email || !email.includes("@")) {
    throw new Error("Enter the sub-user's email address.");
  }

  const { licence } = await ownedLicence(parentKey);
  if (licence.revoked) throw new Error("This licence has been revoked.");
  if (licence.sub_users <= 0) {
    throw new Error("Your plan doesn't include sub-users — upgrade to Family or Community to add them.");
  }

  const used = await countSubLicences(parentKey);
  if (used >= licence.sub_users) {
    throw new Error(`You've reached your ${licence.sub_users} sub-users. Contact support to raise your allowance.`);
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
    mode: licence.mode, // a Cloud account's sub-users run on Cloud too
    parentKey,
    note: note || null,
  });

  // Bill the reseller for this one if it's past the 27 free (best-effort — the
  // sub-user is created regardless; billing re-syncs on the next add/remove).
  try {
    await syncCommunityOverage(licence);
  } catch (err) {
    console.error("community overage sync failed", err);
  }

  revalidatePath("/account");
}

/** Removes a sub-user and re-syncs the reseller's overage billing downward. */
export async function removeSubUser(formData: FormData) {
  const parentKey = String(formData.get("key") ?? "");
  const subKey = String(formData.get("subKey") ?? "");
  const { licence } = await ownedLicence(parentKey);

  const subs = await subLicencesOf(parentKey);
  if (!subs.some((s) => s.key === subKey)) {
    throw new Error("That sub-user isn't on your account.");
  }
  await deleteLicence(subKey);
  try {
    await syncCommunityOverage(licence);
  } catch (err) {
    console.error("community overage sync failed", err);
  }

  revalidatePath("/account");
}

// MARK: - Shared account API keys

/** Saves (or clears, with an empty value) one of the account's shared keys. Only
 *  the account holder uses this — sub-users inherit the parent's keys. */
export async function saveAccountKey(formData: FormData) {
  const session = await requireSession();
  const which = String(formData.get("which") ?? "");
  const value = String(formData.get("value") ?? "").trim();
  if (which !== "anthropic" && which !== "elevenlabs") return;
  await ensureSchema();
  await setAccountKey(session.email, which, value || null);
  revalidatePath("/account");
}

/** Removes one of the account's shared keys. */
export async function clearAccountKey(formData: FormData) {
  const session = await requireSession();
  const which = String(formData.get("which") ?? "");
  if (which !== "anthropic" && which !== "elevenlabs") return;
  await ensureSchema();
  await setAccountKey(session.email, which, null);
  revalidatePath("/account");
}

// MARK: - Reseller tools (Stripe Connect + provisioning)

/** Registers the reseller's webhook URL — where we POST signed provisioning
 *  events for their integration. Clear it by submitting an empty value. */
export async function saveResellerWebhook(formData: FormData) {
  const session = await requireSession();
  await ensureSchema();
  if (!(await resellerLicence(session.email))) throw new Error("A reseller plan is required.");

  const url = String(formData.get("url") ?? "").trim();
  if (url && !/^https:\/\/.+/i.test(url)) throw new Error("Enter an https:// URL.");
  await setResellerWebhookUrl(session.email, url || null);
  revalidatePath("/account");
}

/** Mints a fresh webhook signing secret and shows it once via the URL. */
export async function newWebhookSecret() {
  const session = await requireSession();
  await ensureSchema();
  if (!(await resellerLicence(session.email))) throw new Error("A reseller plan is required.");
  const secret = await mintWebhookSecret(session.email);
  redirect(`/account?whsecret=${encodeURIComponent(secret)}`);
}

/** Sets what the reseller charges their customers — floored at our Solo price. */
export async function saveResellerPrice(formData: FormData) {
  const session = await requireSession();
  await ensureSchema();
  if (!(await resellerLicence(session.email))) throw new Error("A reseller plan is required.");

  const dollars = Number(String(formData.get("price") ?? "0"));
  const cents = Math.round(dollars * 100);
  if (!Number.isFinite(cents) || cents < RESELL_FLOOR_CENTS) {
    throw new Error(`Your price must be at least $${(RESELL_FLOOR_CENTS / 100).toFixed(2)}/week.`);
  }
  await setResellerPrice(session.email, cents);
  revalidatePath("/account");
}

/** Mints a fresh provisioning API key and shows it once via the URL. */
export async function newProvisionKey() {
  const session = await requireSession();
  await ensureSchema();
  if (!(await resellerLicence(session.email))) throw new Error("A reseller plan is required.");
  const raw = await mintProvisionKey(session.email);
  redirect(`/account?provkey=${encodeURIComponent(raw)}`);
}
