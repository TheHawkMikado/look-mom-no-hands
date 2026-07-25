import { NextRequest } from "next/server";
import { appTokenEmail, keyOwnerEmail, licencesForEmail, type LicenceRow } from "@/lib/db";
import { UNLIMITED } from "@/lib/stripe";

/**
 * Shared auth for the macOS app's API. The app holds a per-device bearer token
 * (minted at /app/login); every /api/app/* route resolves it to an account email
 * here, then to that account's entitlement.
 */

/** The account email behind a request's `Authorization: Bearer` app token, or null. */
export async function appEmail(req: NextRequest): Promise<string | null> {
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer\s+(.+)$/i);
  if (!m) return null;
  return appTokenEmail(m[1].trim());
}

export interface AppEntitlement {
  active: boolean;
  plan: string;
  /** 'cloud' (runs on the platform's keys) or 'byok' (the account's own keys). */
  mode: string;
  /** Devices the account may activate. Uncapped for every plan — access is tied
   *  to the account, and Cloud usage is metered, so more devices just means more
   *  usage (and revenue), never a limit to police. Reported as UNLIMITED. */
  devices: number;
  /** Sub-users the account may add. */
  subUsers: number;
  isSubUser: boolean;
  parentEmail: string | null;
  expiresAt: Date | null;
  licence: LicenceRow;
}

/**
 * The account's current entitlement — its newest non-revoked, unexpired licence
 * (a sub-user's is the sub-licence issued under its parent). Returns null only
 * when the account has no licence at all; an expired/revoked one is returned with
 * `active: false` so the app can say *why* it's locked.
 */
export async function resolveEntitlement(email: string): Promise<AppEntitlement | null> {
  const lics = await licencesForEmail(email); // newest-first
  if (lics.length === 0) return null;
  const now = Date.now();
  const live = (l: LicenceRow) => !l.revoked && (!l.expires_at || l.expires_at.getTime() > now);
  const licence = lics.find(live) ?? lics[0];
  const isSubUser = !!licence.parent_key;
  return {
    active: live(licence),
    plan: licence.plan,
    mode: licence.mode ?? "byok",
    devices: UNLIMITED,
    subUsers: licence.sub_users,
    isSubUser,
    parentEmail: isSubUser ? await keyOwnerEmail(email) : null,
    expiresAt: licence.expires_at,
    licence,
  };
}
