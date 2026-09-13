/**
 * Blast-radius tiers (SPEC.md §6). The tier is a property of the *action the
 * task will take in the world*, not of how hard it is. Drafting a post is
 * tier 0; publishing it is tier 2; paying for the ad is tier 3.
 */

export type Tier = 0 | 1 | 2 | 3 | 4;

export type TierPolicy =
  | "auto" // do it, say nothing
  | "auto_notify" // do it, tell the user afterwards
  | "ask" // ask before doing; batchable
  | "ask_each" // explicit approval per item
  | "ask_confirm"; // explicit approval + confirmation phrase

export interface TierSpec {
  tier: Tier;
  name: string;
  policy: TierPolicy;
  examples: string;
}

export const TIERS: readonly TierSpec[] = [
  { tier: 0, name: "Internal", policy: "auto", examples: "drafts, research, summaries, memory writes" },
  { tier: 1, name: "Reversible external, no money", policy: "auto_notify", examples: "reservations, calendar holds, internal notes" },
  { tier: 2, name: "Public or team-facing", policy: "ask", examples: "publish blog/social, email a team member a task, update site copy" },
  { tier: 3, name: "Money or third-party commitment", policy: "ask_each", examples: "pay, sign up, commit a vendor, email a client" },
  { tier: 4, name: "Irreversible / high stakes", policy: "ask_confirm", examples: "delete data, cancel contracts, legal/financial above ceiling" },
] as const;

export function tierSpec(t: Tier): TierSpec {
  return TIERS[t];
}

/** Does this tier require the user's explicit approval before the action? */
export function needsApproval(t: Tier): boolean {
  return t >= 2;
}

export function clampTier(n: unknown): Tier {
  const v = Math.round(Number(n));
  if (!Number.isFinite(v)) return 0;
  return Math.min(4, Math.max(0, v)) as Tier;
}

/**
 * Deterministic tier classifier. The model proposes a tier during extraction;
 * this is the floor. Whatever the model says, a request that mentions paying
 * or deleting can never be filed below the matching tier. Conservative by
 * design (§3.4): a false high tier costs one tap; a false low tier costs money.
 */
const TIER_4 = /\b(delete|erase|wipe|cancel (the|my|our) (contract|account|subscription)|terminate|wire|sign (the )?contract|notariz)/i;
const TIER_3 = /\b(pay|purchase|buy|order|book (a|the) (tow|plumber|flight|hotel)|hire|subscribe|sign ?up|charge|invoice|send (an? )?(email|message|text) to (the |our |my )?(client|customer|vendor|lawyer)|call (the |a )?(vendor|client|customer|tow))/i;
const TIER_2 = /\b(publish|post (it|this|to)|tweet|send (it|this|the) (to|out)|email (the )?team|announce|update (the )?(site|website|homepage|copy)|schedule (a |the )?(post|newsletter)|share with)/i;
const TIER_1 = /\b(reserve|reservation|table for|calendar hold|hold (a |the )?(slot|time)|remind|add to (my )?calendar|note (it|this) in)/i;

export function floorTierFor(text: string): Tier {
  if (TIER_4.test(text)) return 4;
  if (TIER_3.test(text)) return 3;
  if (TIER_2.test(text)) return 2;
  if (TIER_1.test(text)) return 1;
  return 0;
}

/** Final tier: the higher of the model's proposal and the deterministic floor. */
export function resolveTier(text: string, proposed: unknown): Tier {
  return Math.max(floorTierFor(text), clampTier(proposed)) as Tier;
}
