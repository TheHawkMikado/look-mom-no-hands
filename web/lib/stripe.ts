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

/** What each Stripe Price entitles the buyer to. */
export interface PlanSpec {
  plan: string;
  seats: number;
  /** null = perpetual licence; a number = months until the licence lapses. */
  months: number | null;
}

/**
 * Maps a Stripe Price ID to entitlements. Keeping this server-side means the
 * seat count and duration can't be tampered with from the checkout call — the
 * client only ever names a plan, never its terms.
 */
export function planForPrice(priceId: string): PlanSpec {
  const table: Record<string, PlanSpec> = {
    [process.env.STRIPE_PRICE_PERSONAL ?? "__personal"]: { plan: "personal", seats: 2, months: null },
    [process.env.STRIPE_PRICE_PRO ?? "__pro"]: { plan: "pro", seats: 5, months: null },
    [process.env.STRIPE_PRICE_YEARLY ?? "__yearly"]: { plan: "yearly", seats: 5, months: 12 },
  };
  return table[priceId] ?? { plan: "personal", seats: 2, months: null };
}
