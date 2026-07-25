"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { requireAdmin } from "@/lib/auth";
import { mintLicenceKey } from "@/lib/licence";
import { stripe } from "@/lib/stripe";
import {
  deleteLicence,
  deletePlan,
  ensureSchema,
  insertLicence,
  overrideLicence,
  planBySlug,
  setExpiry,
  setPlatformKey,
  setRevoked,
  setSeats,
  upsertPlan,
  type PlanRow,
} from "@/lib/db";

const asMode = (v: FormDataEntryValue | null) => (String(v ?? "") === "cloud" ? "cloud" : "byok");

/**
 * Admin actions.
 *
 * Every one starts with `requireAdmin()`. Server actions are POST endpoints
 * with generated URLs, not private functions — anyone who finds one can call
 * it, so the check has to live in the action itself rather than in the page
 * that renders the button.
 */

const num = (v: FormDataEntryValue | null, fallback = 0) => {
  const n = Number(String(v ?? ""));
  return Number.isFinite(n) ? n : fallback;
};

// MARK: - Licences

export async function adminSetRevoked(formData: FormData) {
  await requireAdmin();
  await ensureSchema();
  await setRevoked(String(formData.get("key")), formData.get("revoked") === "1");
  revalidatePath("/admin");
}

export async function adminSetSeats(formData: FormData) {
  await requireAdmin();
  await ensureSchema();
  await setSeats(String(formData.get("key")), Math.max(0, num(formData.get("seats"), 1)));
  revalidatePath("/admin");
}

/** Push an expiry out by N days — the usual fix for a support case. */
export async function adminExtend(formData: FormData) {
  await requireAdmin();
  await ensureSchema();
  const days = num(formData.get("days"), 7);
  await setExpiry(String(formData.get("key")), new Date(Date.now() + days * 86_400_000));
  revalidatePath("/admin");
}

/**
 * Deletes a licence outright. Cascades to its activations. Does NOT touch
 * Stripe: if the customer still has a live subscription they keep being billed,
 * so cancel there first. Revoking is nearly always the better move — it keeps
 * the audit trail.
 */
export async function adminDelete(formData: FormData) {
  await requireAdmin();
  await ensureSchema();
  await deleteLicence(String(formData.get("key")));
  revalidatePath("/admin");
}

/**
 * Creates a user by hand — comps, replacements, anything outside Stripe.
 *
 * Entitlements come from the chosen plan (so "comp" grants exactly a free Solo,
 * "family" grants the family allowance, etc.) rather than being typed in; use the
 * per-licence Override afterwards for anything bespoke. No Stripe subscription is
 * created, so nothing bills and nothing renews — days of 0 is a permanent key.
 */
export async function adminIssue(formData: FormData) {
  await requireAdmin();
  await ensureSchema();

  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  if (!email.includes("@")) throw new Error("Enter a valid email address.");

  const slug = String(formData.get("plan") ?? "comp").trim().toLowerCase() || "comp";
  const plan = await planBySlug(slug);
  // Unknown slug falls back to a Solo-shaped comp rather than failing — an admin
  // typing a slug that doesn't exist still gets a sane, minimal grant.
  const seats = plan ? plan.computers : 3;
  const phones = plan ? plan.phones : 0;
  const subUsers = plan ? plan.sub_users : 0;
  const resell = plan ? plan.resell : false;

  const days = num(formData.get("days"), 0);
  await insertLicence({
    key: mintLicenceKey(),
    email,
    plan: slug,
    // 0 days means perpetual: a comp that never needs renewing.
    expiresAt: days > 0 ? new Date(Date.now() + days * 86_400_000) : null,
    seats,
    phones,
    subUsers,
    resell,
    mode: asMode(formData.get("mode")),
    parentKey: null,
    note: String(formData.get("note") ?? "").trim() || null,
  });
  revalidatePath("/admin");
}

/**
 * Overrides a licence's entitlements outright — the manual lever for support and
 * for comping someone extra devices/sub-users or a custom expiry. The form is
 * pre-filled from the current row, so every field is always submitted; an empty
 * expiry means "perpetual".
 */
export async function adminOverride(formData: FormData) {
  await requireAdmin();
  await ensureSchema();

  const key = String(formData.get("key") ?? "");
  if (!key) return;

  const expiryRaw = String(formData.get("expiry") ?? "").trim();
  // A YYYY-MM-DD value is taken as end-of-day UTC so the licence stays valid
  // through the whole day the admin picked, not from midnight before it.
  const expiresAt = expiryRaw ? new Date(`${expiryRaw}T23:59:59Z`) : null;
  if (expiryRaw && Number.isNaN(expiresAt!.getTime())) throw new Error("Invalid expiry date.");

  await overrideLicence(key, {
    plan: String(formData.get("plan") ?? "solo").trim().toLowerCase() || "solo",
    seats: Math.max(0, num(formData.get("seats"), 3)),
    subUsers: Math.max(0, num(formData.get("subUsers"), 0)),
    expiresAt,
    resell: formData.get("resell") === "on",
    mode: asMode(formData.get("mode")),
  });
  revalidatePath("/admin");
}

// MARK: - Platform keys (what Cloud subscribers run on)

/** Saves (or clears, with an empty value) one of the owner's platform keys. */
export async function adminSavePlatformKey(formData: FormData) {
  await requireAdmin();
  await ensureSchema();
  const which = String(formData.get("which") ?? "");
  const value = String(formData.get("value") ?? "").trim();
  if (which !== "anthropic" && which !== "elevenlabs") return;
  await setPlatformKey(which, value || null);
  revalidatePath("/admin");
}

export async function adminClearPlatformKey(formData: FormData) {
  await requireAdmin();
  await ensureSchema();
  const which = String(formData.get("which") ?? "");
  if (which !== "anthropic" && which !== "elevenlabs") return;
  await setPlatformKey(which, null);
  revalidatePath("/admin");
}

// MARK: - Order form

export async function adminSavePlan(formData: FormData) {
  await requireAdmin();
  await ensureSchema();

  const slug = String(formData.get("slug") ?? "").trim().toLowerCase();
  if (!/^[a-z0-9_-]{1,40}$/.test(slug)) {
    throw new Error("Slug must be lowercase letters, numbers, dashes or underscores.");
  }

  const plan: PlanRow = {
    slug,
    name: String(formData.get("name") ?? slug),
    tagline: String(formData.get("tagline") ?? ""),
    price_id: String(formData.get("price_id") ?? "").trim() || null,
    price_label: String(formData.get("price_label") ?? ""),
    period: String(formData.get("period") ?? "/ week"),
    price_id_byok: String(formData.get("price_id_byok") ?? "").trim() || null,
    price_label_byok: String(formData.get("price_label_byok") ?? ""),
    period_byok: String(formData.get("period_byok") ?? ""),
    // One feature per line is the least fiddly thing to edit in a textarea.
    features: String(formData.get("features") ?? "")
      .split("\n")
      .map((s) => s.trim())
      .filter(Boolean),
    computers: Math.max(0, num(formData.get("computers"), 1)),
    phones: Math.max(0, num(formData.get("phones"), 0)),
    sub_users: Math.max(0, num(formData.get("sub_users"), 0)),
    resell: formData.get("resell") === "on",
    featured: formData.get("featured") === "on",
    visible: formData.get("visible") === "on",
    sort: num(formData.get("sort"), 0),
  };

  await upsertPlan(plan);
  // The pricing page is cached; without this the edit wouldn't show until the
  // next deploy.
  revalidatePath("/");
  revalidatePath("/admin");
}

export async function adminDeletePlan(formData: FormData) {
  await requireAdmin();
  await ensureSchema();
  await deletePlan(String(formData.get("slug")));
  revalidatePath("/");
  revalidatePath("/admin");
}

// MARK: - Stripe products and prices

/**
 * Creates a product and a recurring price, then points the plan at it.
 *
 * Stripe prices are immutable, so "change the price" always means create a new
 * one and repoint — existing subscribers stay on the price they signed up at
 * until they're migrated deliberately.
 */
type PriceInterval = "day" | "week" | "month" | "year";

/**
 * Creates a Stripe product + recurring price and points the plan at the right
 * column (Cloud or BYOK). Shared by the manual form and the one-click setup.
 * Product name always carries "NoHandsApp.com" so it stands out in a shared
 * Stripe account.
 */
async function createAndWirePrice(o: {
  slug: string;
  mode: "cloud" | "byok";
  dollars: number;
  interval?: PriceInterval;
  name?: string;
  description?: string;
}): Promise<string> {
  const interval = o.interval ?? "week";
  const modeLabel = o.mode === "byok" ? "BYOK" : "Cloud";
  const custom = (o.name ?? "").trim();
  const titleSlug = o.slug ? o.slug.charAt(0).toUpperCase() + o.slug.slice(1) : "Plan";
  const name = custom
    ? (/nohandsapp\.com/i.test(custom) ? custom : `NoHandsApp.com — ${custom}`)
    : `NoHandsApp.com — ${titleSlug} (${modeLabel})`;

  const product = await stripe().products.create({
    name,
    description: (o.description ?? "").trim() || undefined,
    metadata: { nohands_plan: o.slug, nohands_mode: o.mode },
  });
  const price = await stripe().prices.create({
    product: product.id,
    unit_amount: Math.round(o.dollars * 100),
    currency: "usd",
    recurring: { interval, interval_count: 1 },
    metadata: { nohands_plan: o.slug, nohands_mode: o.mode },
  });

  const existing = await planBySlug(o.slug);
  if (existing) {
    await upsertPlan(
      o.mode === "byok"
        ? { ...existing, price_id_byok: price.id, price_label_byok: `$${o.dollars}`, period_byok: `/ ${interval}` }
        : { ...existing, price_id: price.id, price_label: `$${o.dollars}`, period: `/ ${interval}` },
    );
  }
  return price.id;
}

export async function adminCreatePrice(formData: FormData) {
  await requireAdmin();
  await ensureSchema();

  const slug = String(formData.get("slug") ?? "").trim().toLowerCase();
  const dollars = Number(String(formData.get("amount") ?? "0"));
  if (!Number.isFinite(dollars) || dollars <= 0) throw new Error("Enter an amount.");

  await createAndWirePrice({
    slug,
    mode: asMode(formData.get("mode")),
    dollars,
    interval: String(formData.get("interval") ?? "week") as PriceInterval,
    name: String(formData.get("name") ?? ""),
    description: String(formData.get("description") ?? ""),
  });

  revalidatePath("/");
  revalidatePath("/admin");
}

/** The canonical plan pricing (BYOK flat; Cloud metered). */
const STANDARD_PRICES: { slug: string; mode: "cloud" | "byok"; dollars: number }[] = [
  { slug: "solo", mode: "cloud", dollars: 9.99 },
  { slug: "family", mode: "cloud", dollars: 27.99 },
  { slug: "community", mode: "cloud", dollars: 99.99 },
  { slug: "solo", mode: "byok", dollars: 4.95 },
  { slug: "family", mode: "byok", dollars: 9.99 },
  { slug: "community", mode: "byok", dollars: 49.95 },
];

/**
 * One click: create every standard plan price that isn't wired yet. Idempotent —
 * skips a plan/mode that already has a price, so re-running only fills the gaps
 * and never makes duplicate products.
 */
export async function adminCreateStandardPrices() {
  await requireAdmin();

  // Surface the real failure to the admin instead of an opaque error digest, so a
  // Stripe or database problem is diagnosable without digging through logs.
  let failure = "";
  try {
    await ensureSchema();
    for (const s of STANDARD_PRICES) {
      const plan = await planBySlug(s.slug);
      if (!plan) continue;
      const wired = s.mode === "byok" ? plan.price_id_byok : plan.price_id;
      if (wired) continue;
      await createAndWirePrice(s);
    }
  } catch (err) {
    console.error("create standard prices failed", err);
    failure = err instanceof Error ? err.message : String(err);
  }

  revalidatePath("/");
  revalidatePath("/admin");
  if (failure) redirect(`/admin?err=${encodeURIComponent(failure.slice(0, 300))}#orderform`);
}

/** Archives a price so it can no longer be bought. Stripe never deletes them. */
export async function adminArchivePrice(formData: FormData) {
  await requireAdmin();
  await stripe().prices.update(String(formData.get("price_id")), { active: false });
  revalidatePath("/admin");
}

// MARK: - Promo codes

/**
 * Creates a coupon and a customer-facing promotion code in one step. Stripe
 * models these separately — the coupon is the discount, the code is the string
 * someone types — but there is no reason to make that distinction visible here.
 */
export async function adminCreatePromo(formData: FormData) {
  await requireAdmin();

  const code = String(formData.get("code") ?? "").trim().toUpperCase();
  if (!/^[A-Z0-9_-]{3,40}$/.test(code)) {
    throw new Error("Codes are 3–40 characters: letters, numbers, dashes, underscores.");
  }

  const percent = Number(String(formData.get("percent") ?? "0"));
  const amount = Number(String(formData.get("amount") ?? "0"));
  if (percent <= 0 && amount <= 0) throw new Error("Set a percentage or an amount off.");

  const months = Number(String(formData.get("months") ?? "0"));
  const coupon = await stripe().coupons.create({
    name: code,
    ...(percent > 0
      ? { percent_off: percent }
      : { amount_off: Math.round(amount * 100), currency: "usd" }),
    // "forever" discounts a weekly subscription every single week, which is
    // rarely what's meant; default to the first billing period only.
    duration: months > 1 ? "repeating" : months === 0 ? "forever" : "once",
    ...(months > 1 ? { duration_in_months: months } : {}),
  });

  const max = Number(String(formData.get("max") ?? "0"));
  await stripe().promotionCodes.create({
    // Current API wraps this in a `promotion` discriminated union rather than
    // taking a bare `coupon` id, leaving room for non-coupon promotion types.
    promotion: { type: "coupon", coupon: coupon.id },
    code,
    ...(max > 0 ? { max_redemptions: max } : {}),
  });

  revalidatePath("/admin");
}

export async function adminTogglePromo(formData: FormData) {
  await requireAdmin();
  await stripe().promotionCodes.update(String(formData.get("id")), {
    active: formData.get("active") === "1",
  });
  revalidatePath("/admin");
}
