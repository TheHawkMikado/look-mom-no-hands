import { createHmac } from "node:crypto";
import { getReseller } from "@/lib/db";

/**
 * Delivers a signed event to a reseller's registered webhook. The body is signed
 * with their webhook secret (HMAC-SHA256, hex) in `X-NoHands-Signature`, which the
 * reseller verifies. Best-effort — a down endpoint never fails the caller.
 */
export async function fireResellerWebhook(email: string, event: Record<string, unknown>) {
  const reseller = await getReseller(email);
  if (!reseller?.webhook_url || !reseller.webhook_secret) return;

  const body = JSON.stringify(event);
  const signature = createHmac("sha256", reseller.webhook_secret).update(body).digest("hex");
  try {
    await fetch(reseller.webhook_url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-NoHands-Signature": signature },
      body,
    });
  } catch (err) {
    console.error("reseller webhook delivery failed", err);
  }
}
