/**
 * The secret beta offer: $99 for life (BYOK, one user, unlimited devices),
 * with discount codes of the form BETA## where ## is the dollar amount off,
 * up to the full $99 (BETA99 = free). Codes are a formula, not a list: any
 * value from 1 to 99 works, so the owner can hand out whatever discount a
 * conversation calls for without touching Stripe. Every redemption is logged
 * (lib/db-beta.ts) and the whole programme can be switched off from /admin.
 */

export const BETA_PRICE_DOLLARS = 99;
export const BETA_PLAN = "beta";
const CODE = /^BETA(\d{1,2})$/;

/** Dollars off for a code, or null when the code is not a beta code. */
export function parseBetaCode(raw: string | null | undefined): number | null {
  const code = String(raw ?? "").trim().toUpperCase().replace(/[\s-]/g, "");
  const m = CODE.exec(code);
  if (!m) return null;
  const off = Number(m[1]);
  if (!Number.isInteger(off) || off < 1 || off > BETA_PRICE_DOLLARS) return null;
  return off;
}

/** Normalised code for logging ("beta50" → "BETA50"). */
export function normaliseBetaCode(raw: string | null | undefined): string {
  return String(raw ?? "").trim().toUpperCase().replace(/[\s-]/g, "");
}

/** What the buyer pays, in dollars, after a (possibly absent) code. */
export function betaPriceDollars(code: string | null | undefined): number {
  const off = parseBetaCode(code) ?? 0;
  return Math.max(0, BETA_PRICE_DOLLARS - off);
}
