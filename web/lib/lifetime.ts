import { UNLIMITED } from "@/lib/stripe";

/**
 * Lifetime plans — one-time purchase, perpetual access, BYOK only (never Cloud,
 * which is metered). The first {@link FOUNDER_CAP} accounts across all three
 * tiers get founder pricing; after that the price steps up and there's no cap.
 *
 * Prices resolve server-side from the live sold count, so nobody can grab the
 * founder price once it's gone. There are no pre-created Stripe prices — checkout
 * passes the amount inline (price_data), which keeps this self-contained.
 */

export const FOUNDER_CAP = 100;

export interface LifetimeTier {
  key: "startup" | "team" | "reseller";
  name: string;
  tagline: string;
  subUsers: number;
  resell: boolean;
  /** Price for the first FOUNDER_CAP accounts. */
  founder: number;
  /** Price once the founder spots are gone. */
  standard: number;
  features: string[];
  featured?: boolean;
}

export const LIFETIME_TIERS: LifetimeTier[] = [
  {
    key: "startup",
    name: "Startup",
    tagline: "",
    subUsers: 5,
    resell: false,
    founder: 297,
    standard: 999,
    features: ["1 user + 5 sub-users", "Unlimited devices", "Bring your own key", "Pay once — yours for life"],
  },
  {
    key: "team",
    name: "Team",
    tagline: "most popular",
    subUsers: 27,
    resell: false,
    founder: 999,
    standard: 2997,
    features: ["1 user + 27 sub-users", "Unlimited devices", "Bring your own key", "Pay once — yours for life"],
    featured: true,
  },
  {
    key: "reseller",
    name: "Reseller",
    tagline: "resell rights",
    subUsers: UNLIMITED,
    resell: true,
    founder: 4995,
    standard: 18999,
    features: [
      "Unlimited resell accounts",
      "No per-user fees, ever",
      "Unlimited devices",
      "Bring your own key",
      "Pay once — yours for life",
    ],
  },
];

/** Fixed price for an existing Team buyer to upgrade to Reseller (a discount vs
 *  the $4,995 list). */
export const RESELLER_UPGRADE_PRICE = 2997;

export const lifetimeTier = (key: string): LifetimeTier | undefined =>
  LIFETIME_TIERS.find((t) => t.key === key);

/** The price a new buyer pays right now, given how many lifetime accounts have
 *  already sold. */
export const lifetimePrice = (tier: LifetimeTier, sold: number): number =>
  sold < FOUNDER_CAP ? tier.founder : tier.standard;

/** Upsell offers — a focused page per step, and shown after a matching purchase.
 *  `from` is the plan a buyer is coming from; `tier` the lifetime tier offered. */
export interface Upsell {
  slug: string;
  from: string;
  tier: LifetimeTier["key"];
  upgrade: boolean;
  headline: string;
  pitch: string;
}

export const UPSELLS: Upsell[] = [
  {
    slug: "startup",
    from: "Family",
    tier: "startup",
    upgrade: false,
    headline: "Make it a lifetime deal",
    pitch:
      "You're on Family. Startup is the same — 5 sub-users, unlimited devices, your own keys — but you pay once and never see a weekly charge again.",
  },
  {
    slug: "team",
    from: "Community",
    tier: "team",
    upgrade: false,
    headline: "Go lifetime with Team",
    pitch:
      "27 sub-users, unlimited devices, on your own keys — one payment and it's yours for good. No more weekly billing.",
  },
  {
    slug: "reseller",
    from: "Team",
    tier: "reseller",
    upgrade: true,
    headline: "Upgrade to Reseller",
    pitch:
      "Unlimited resell accounts with no per-user fees, ever. Upgrade from Team for a one-time $2,997 — a discount on the $4,995 list price.",
  },
];

export const upsellBySlug = (slug: string): Upsell | undefined =>
  UPSELLS.find((u) => u.slug === slug);

/** Which upsell to show after buying a given plan, or undefined for none. */
export const upsellAfter = (plan: string): Upsell | undefined => {
  const map: Record<string, string> = { family: "startup", community: "team", team: "reseller" };
  return map[plan] ? upsellBySlug(map[plan]) : undefined;
};
