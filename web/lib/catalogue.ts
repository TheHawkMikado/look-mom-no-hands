import { PlanRow, allPlans, ensureSchema, upsertPlan, visiblePlans } from "@/lib/db";
import { PRICE_ENV, UNLIMITED } from "@/lib/stripe";

/**
 * The order form: what the pricing page offers and what each plan entitles you to.
 *
 * Rows live in Postgres so the admin dashboard can rename, reorder, hide or
 * reprice a plan without a deploy. The definitions below are the seed for a
 * fresh database *and* the fallback when the database can't be reached — a
 * marketing page that 500s because Postgres hiccuped would cost far more than
 * showing slightly stale pricing.
 */

export const DEFAULT_PLANS: PlanRow[] = [
  {
    slug: "solo",
    name: "Solo",
    tagline: "",
    price_id: null,
    price_label: "$3",
    period: "/ week",
    price_id_byok: null,
    price_label_byok: "",
    period_byok: "",
    features: ["Unlimited devices", "1 user", "Every update while active", "Cancel any time"],
    computers: UNLIMITED,
    phones: 0,
    sub_users: 0,
    resell: false,
    featured: false,
    visible: true,
    sort: 10,
  },
  {
    slug: "family",
    name: "Family",
    tagline: "most popular",
    price_id: null,
    price_label: "$9",
    period: "/ week",
    price_id_byok: null,
    price_label_byok: "",
    period_byok: "",
    features: ["Unlimited devices per user", "Add up to 5 sub-users", "Every update while active", "Cancel any time"],
    computers: UNLIMITED,
    phones: 0,
    sub_users: 5,
    resell: false,
    featured: true,
    visible: true,
    sort: 20,
  },
  {
    slug: "community",
    name: "Community",
    tagline: "resell rights",
    price_id: null,
    price_label: "$27",
    period: "/ week",
    price_id_byok: null,
    price_label_byok: "",
    period_byok: "",
    features: [
      "Unlimited devices per user",
      "Unlimited sub-users",
      "First 27 included free",
      "Then $1 / week per extra user",
    ],
    computers: UNLIMITED,
    phones: 0,
    sub_users: UNLIMITED,
    resell: true,
    featured: false,
    visible: true,
    sort: 30,
  },
  {
    // Comp: a free Solo account issued by hand from the admin. Hidden from the
    // pricing page (visible:false) and never sold, so it has no Stripe price —
    // it's the "give someone a free account" tier. Solo entitlements, one user.
    slug: "comp",
    name: "Comp",
    tagline: "complimentary",
    price_id: null,
    price_label: "Free",
    period: "",
    price_id_byok: null,
    price_label_byok: "",
    period_byok: "",
    features: ["Unlimited devices", "1 user", "Complimentary — issued by hand"],
    computers: UNLIMITED,
    phones: 0,
    sub_users: 0,
    resell: false,
    featured: false,
    visible: false,
    sort: 100,
  },
];

/** Seed values, with any price id already configured in the environment. */
function seeded(): PlanRow[] {
  return DEFAULT_PLANS.map((p) => ({
    ...p,
    price_id: process.env[PRICE_ENV[p.slug] ?? ""] ?? null,
  }));
}

/**
 * Plans for the public pricing page. Falls back to the code defaults rather
 * than throwing: the storefront must render even with no database.
 */
export async function storefront(): Promise<PlanRow[]> {
  try {
    await ensureSchema();
    let rows = await visiblePlans();
    if (rows.length === 0) {
      // First run against an empty database — plant the catalogue so the admin
      // has something to edit rather than a blank screen.
      for (const p of seeded()) await upsertPlan(p);
      rows = await visiblePlans();
    }
    return rows;
  } catch (err) {
    console.error("storefront falling back to code defaults:", err);
    return seeded().filter((p) => p.visible);
  }
}

/** Every plan including hidden ones — for the admin editor. */
export async function catalogue(): Promise<PlanRow[]> {
  await ensureSchema();
  const rows = await allPlans();
  if (rows.length === 0) {
    for (const p of seeded()) await upsertPlan(p);
    return allPlans();
  }
  return rows;
}

export interface Entitlements {
  plan: string;
  /** Combined per-user device pool (Macs + phones). Same value as `computers`,
   *  named for the new model; this is what the app enforces against. */
  devices: number;
  computers: number;
  phones: number;
  subUsers: number;
  resell: boolean;
}

const toEntitlements = (p: PlanRow): Entitlements => ({
  plan: p.slug,
  devices: p.computers,
  computers: p.computers,
  phones: p.phones,
  subUsers: p.sub_users,
  resell: p.resell,
});

/**
 * Maps a Stripe price back to what it buys. Database first, so entitlements
 * edited in the admin take effect for the next purchase; environment second,
 * for the deploys configured before the plans table existed.
 *
 * An unrecognised price falls back to the *smallest* plan on purpose:
 * under-serving a customer is a support ticket, over-serving one hands out
 * resell rights nobody paid for.
 */
export async function entitlementsForPrice(priceId: string): Promise<Entitlements> {
  if (priceId) {
    try {
      const rows = await allPlans();
      // Match either the Cloud or the BYOK price — both map to the same plan
      // entitlements; the mode only changes who supplies the AI keys and the price.
      const hit = rows.find(
        (p) => (p.price_id && p.price_id === priceId) || (p.price_id_byok && p.price_id_byok === priceId),
      );
      if (hit) return toEntitlements(hit);
    } catch (err) {
      console.error("plan lookup failed, trying environment:", err);
    }
    for (const [slug, envVar] of Object.entries(PRICE_ENV)) {
      if (process.env[envVar] === priceId) {
        const d = DEFAULT_PLANS.find((p) => p.slug === slug);
        if (d) return toEntitlements(d);
      }
    }
  }
  console.error(`No plan matches price ${priceId} — defaulting to the smallest`);
  return toEntitlements(DEFAULT_PLANS[0]);
}

/**
 * Resolves the Stripe price for a plan slug in a given mode: database first,
 * environment second. BYOK returns the plan's `price_id_byok` (no environment
 * fallback — BYOK prices are only ever configured in the admin), so a plan with
 * no BYOK price simply isn't purchasable that way.
 */
export async function priceIdForPlan(
  slug: string,
  mode: "cloud" | "byok" = "cloud",
): Promise<string | null> {
  try {
    const rows = await allPlans();
    const hit = rows.find((p) => p.slug === slug && p.visible);
    if (mode === "byok") return hit?.price_id_byok || null;
    if (hit?.price_id) return hit.price_id;
  } catch (err) {
    console.error("price lookup failed, trying environment:", err);
  }
  if (mode === "byok") return null;
  return process.env[PRICE_ENV[slug] ?? ""] ?? null;
}
