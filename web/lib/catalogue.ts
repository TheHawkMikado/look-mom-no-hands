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
    features: ["2 Computers", "1 Phone", "Every update while active", "Cancel any time"],
    computers: 2,
    phones: 1,
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
    features: ["9 Computers", "9 Phones", "Every update while active", "Cancel any time"],
    computers: 9,
    phones: 9,
    sub_users: 0,
    resell: false,
    featured: true,
    visible: true,
    sort: 20,
  },
  {
    slug: "unlimited",
    name: "Unlimited",
    tagline: "resell rights",
    price_id: null,
    price_label: "$27",
    period: "/ week",
    features: [
      "Unlimited* Computers & Phones",
      "Resell rights",
      "Includes 27 Solo sub-users",
      "Then $1 / week per extra user",
    ],
    computers: UNLIMITED,
    phones: UNLIMITED,
    sub_users: 27,
    resell: true,
    featured: false,
    visible: true,
    sort: 30,
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
  computers: number;
  phones: number;
  subUsers: number;
  resell: boolean;
}

const toEntitlements = (p: PlanRow): Entitlements => ({
  plan: p.slug,
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
      const hit = rows.find((p) => p.price_id && p.price_id === priceId);
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

/** Resolves the Stripe price for a plan slug: database first, environment second. */
export async function priceIdForPlan(slug: string): Promise<string | null> {
  try {
    const rows = await allPlans();
    const hit = rows.find((p) => p.slug === slug && p.visible);
    if (hit?.price_id) return hit.price_id;
  } catch (err) {
    console.error("price lookup failed, trying environment:", err);
  }
  return process.env[PRICE_ENV[slug] ?? ""] ?? null;
}
