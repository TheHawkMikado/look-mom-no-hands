import Stripe from "stripe";

/**
 * One Stripe client for the app, built on first use rather than at import time.
 *
 * Lazily, because `new Stripe(undefined)` throws: constructing at module scope
 * would turn a missing key into a build-time crash of the whole site, including
 * the marketing pages that need no Stripe at all. This way the landing page
 * deploys and works before commerce is configured, and only checkout errors.
 *
 * No `apiVersion` is pinned on purpose — the account's own default then applies,
 * which is what the Stripe dashboard shows you, and it moves when you decide
 * rather than whenever this file's dependency is bumped.
 */
let client: Stripe | null = null;

export function stripe(): Stripe {
  if (!client) {
    const key = process.env.STRIPE_SECRET_KEY;
    if (!key) throw new Error("STRIPE_SECRET_KEY is not set");
    client = new Stripe(key);
  }
  return client;
}

/** What a plan entitles the subscriber to. */
export interface PlanSpec {
  plan: string;
  /** Macs that may be activated at once. */
  computers: number;
  /** Phones allowed. Sold but not yet enforceable — see the note below. */
  phones: number;
  /** Solo sub-licences a reseller may issue before overage billing starts. */
  subUsers: number;
  /** Resellers may issue sub-licences under their own account. */
  resell: boolean;
}

/** Stands in for "unlimited" — a real integer keeps the seat check branch-free. */
export const UNLIMITED = 9_999;

/**
 * The catalogue. Every plan bills weekly.
 *
 * Phone counts are recorded but nothing enforces them: activation is keyed on a
 * Mac's hashed IOPlatformUUID and there is no iOS client yet. When one exists it
 * should register against a separate `phones` allowance rather than spending a
 * computer seat.
 *
 * Sub-user counts are likewise recorded but unissued — reseller provisioning
 * (minting Solo keys under a parent licence, and metering the $1/wk overage) is
 * not built. Selling Unlimited before it is means fulfilling those by hand.
 */
const PLANS: Record<string, PlanSpec> = {
  solo: { plan: "solo", computers: 2, phones: 1, subUsers: 0, resell: false },
  family: { plan: "family", computers: 9, phones: 9, subUsers: 0, resell: false },
  unlimited: {
    plan: "unlimited",
    computers: UNLIMITED,
    phones: UNLIMITED,
    subUsers: 27,
    resell: true,
  },
};

/** Env var holding each plan's Stripe Price id. */
export const PRICE_ENV: Record<string, string> = {
  solo: "STRIPE_PRICE_SOLO",
  family: "STRIPE_PRICE_FAMILY",
  unlimited: "STRIPE_PRICE_UNLIMITED",
};

export function planByName(name: string): PlanSpec | null {
  return PLANS[name] ?? null;
}

/**
 * Resolves a Stripe Price id back to its entitlements. Server-side on purpose:
 * the browser only ever names a plan, so nobody can open devtools and check out
 * with a seat count they invented.
 */
export function planForPrice(priceId: string): PlanSpec {
  for (const [name, envVar] of Object.entries(PRICE_ENV)) {
    if (priceId && process.env[envVar] === priceId) return PLANS[name];
  }
  // An unrecognised price means the catalogue and Stripe have drifted. Fall back
  // to the smallest plan: under-serving is recoverable by hand, over-serving
  // (handing out resell rights) is not.
  console.error(`No plan matches price ${priceId} — defaulting to solo`);
  return PLANS.solo;
}
