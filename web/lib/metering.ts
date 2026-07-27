/**
 * Cloud usage metering. Cloud subscriptions run on the platform's keys, so their
 * usage has to be capped: each plan includes a weekly bucket of controller and
 * dictation hours, and anything beyond that is drawn from a prepaid credit wallet
 * at the overage rate. When the wallet can't cover the overage, the app stops
 * getting the platform keys until the week resets or they top up.
 *
 * BYOK is never metered — the customer pays their own provider.
 */

/** Included weekly hours per Cloud plan (controller = screen control, dictation
 *  = transcription). The Cloud top tier is the "community" plan row (shown as
 *  "Company"). */
export const CLOUD_ALLOWANCE: Record<string, { ctrl: number; dict: number }> = {
  solo: { ctrl: 3, dict: 6 },
  family: { ctrl: 9, dict: 18 },
  community: { ctrl: 27, dict: 81 },
  company: { ctrl: 27, dict: 81 },
};

/** Overage price per hour (≈10× our estimated cost — the pricing rule). Editable
 *  as the measured cost firms up. */
export const OVERAGE_CTRL_PER_HOUR = 15;
export const OVERAGE_DICT_PER_HOUR = 3.5;

/** Prepaid credit top-up blocks (USD). */
export const TOPUP_BLOCKS = [10, 25, 50, 100, 250, 500];

/** Metering week length. */
export const PERIOD_DAYS = 7;

export interface MeterStatus {
  metered: boolean; // false for BYOK / unknown plans
  ok: boolean; // may the app run right now?
  ctrlHours: number;
  dictHours: number;
  allowance: { ctrl: number; dict: number };
  overageDue: number; // dollars of overage accrued this period
  creditDollars: number; // wallet balance
}

/** Dollars of overage for usage beyond the allowance. */
export function overageDollars(
  usedCtrlHours: number,
  usedDictHours: number,
  allowance: { ctrl: number; dict: number },
): number {
  const oc = Math.max(0, usedCtrlHours - allowance.ctrl);
  const od = Math.max(0, usedDictHours - allowance.dict);
  return oc * OVERAGE_CTRL_PER_HOUR + od * OVERAGE_DICT_PER_HOUR;
}

// MARK: - Server-side metering (composes appauth + db)

import { chargeMeter, currentMeter, walletCents } from "@/lib/db";
import { resolveEntitlement } from "@/lib/appauth";

/**
 * Who a Cloud account meters against and on what allowance. Sub-users share the
 * account holder's meter and allowance — a Family/Company bucket is pooled across
 * the holder and their sub-users, not granted per person. Returns null for BYOK
 * or unmetered plans.
 */
async function meterTarget(
  email: string,
): Promise<{ ownerEmail: string; allowance: { ctrl: number; dict: number } } | null> {
  const ent = await resolveEntitlement(email);
  if (!ent || ent.mode !== "cloud") return null;
  const ownerEmail = ent.isSubUser && ent.parentEmail ? ent.parentEmail : email;
  const ownerPlan =
    ownerEmail === email ? ent.plan : (await resolveEntitlement(ownerEmail))?.plan ?? ent.plan;
  const allowance = CLOUD_ALLOWANCE[ownerPlan];
  return allowance ? { ownerEmail, allowance } : null;
}

/** Adds a usage delta to the right account's Cloud meter (no-op for BYOK). */
export async function chargeCloudMeter(email: string, dCtrlSeconds: number, dDictSeconds: number) {
  const t = await meterTarget(email);
  if (!t) return;
  await chargeMeter(
    t.ownerEmail,
    t.allowance,
    (c, d) => overageDollars(c, d, t.allowance),
    dCtrlSeconds,
    dDictSeconds,
  );
}

/** Current metering status for the account the app is signed in as. */
export async function meterStatusFor(email: string): Promise<MeterStatus> {
  const t = await meterTarget(email);
  if (!t) {
    return {
      metered: false,
      ok: true,
      ctrlHours: 0,
      dictHours: 0,
      allowance: { ctrl: 0, dict: 0 },
      overageDue: 0,
      creditDollars: 0,
    };
  }
  const meter = await currentMeter(t.ownerEmail);
  const ctrlHours = meter.ctrlSeconds / 3600;
  const dictHours = meter.dictSeconds / 3600;
  const overageDue = overageDollars(ctrlHours, dictHours, t.allowance);
  const cents = await walletCents(t.ownerEmail);
  // Runnable while all the overage accrued this week has been paid from the wallet.
  const ok = Math.round(overageDue * 100) <= meter.overageChargedCents;
  return {
    metered: true,
    ok,
    ctrlHours,
    dictHours,
    allowance: t.allowance,
    overageDue,
    creditDollars: cents / 100,
  };
}
