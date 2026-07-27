import { stripe } from "@/lib/stripe";
import { countSubLicences, getSetting, setSetting, type LicenceRow } from "@/lib/db";

/**
 * Community reseller overage: the first 27 sub-users are free, each one after is
 * $1/week, billed on the reseller's own Community subscription as a second line
 * item whose quantity tracks the sub-user count. A lifetime Reseller (no
 * subscription) is unlimited at no charge, so this is a no-op there.
 */

const FREE_SUBUSERS = 27;
const OVERAGE_SETTING = "community_overage_price_id";

/** The $1/week per-sub-user price, created once and cached in settings. */
export async function communityOveragePriceId(): Promise<string> {
  const cached = await getSetting(OVERAGE_SETTING);
  if (cached) return cached;

  const product = await stripe().products.create({
    name: "NoHandsApp.com — Community sub-user (overage)",
    metadata: { nohands_overage: "community" },
  });
  const price = await stripe().prices.create({
    product: product.id,
    unit_amount: 100, // $1.00
    currency: "usd",
    recurring: { interval: "week", interval_count: 1 },
    metadata: { nohands_overage: "community" },
  });
  await setSetting(OVERAGE_SETTING, price.id);
  return price.id;
}

/** Recomputes and syncs the reseller's weekly overage line to `max(0, subs-27)`. */
export async function syncCommunityOverage(parent: LicenceRow) {
  // Only a recurring, resell subscription is billed for overage. Lifetime resellers
  // and non-resell plans have no subscription to adjust.
  if (!parent.resell || !parent.stripe_subscription) return;

  const count = await countSubLicences(parent.key);
  const qty = Math.max(0, count - FREE_SUBUSERS);
  const priceId = await communityOveragePriceId();

  const sub = await stripe().subscriptions.retrieve(parent.stripe_subscription);
  const item = sub.items.data.find((i) => i.price.id === priceId);

  if (qty > 0) {
    if (item) {
      if (item.quantity !== qty) {
        await stripe().subscriptionItems.update(item.id, { quantity: qty, proration_behavior: "none" });
      }
    } else {
      await stripe().subscriptionItems.create({
        subscription: parent.stripe_subscription,
        price: priceId,
        quantity: qty,
        proration_behavior: "none",
      });
    }
  } else if (item) {
    // Back within the free tier — remove the overage line entirely.
    await stripe().subscriptionItems.del(item.id, { proration_behavior: "none" });
  }
}
