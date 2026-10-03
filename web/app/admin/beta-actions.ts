"use server";

import { revalidatePath } from "next/cache";
import { requireAdmin } from "@/lib/auth";
import { createLicence } from "@/lib/db";
import { getApplication, markApplication, recordBetaRedemption, setBetaEnabled } from "@/lib/db-beta";
import { mintLicenceKey } from "@/lib/licence";
import { sendPlainEmail } from "@/lib/email";
import { UNLIMITED } from "@/lib/stripe";
import { BETA_PLAN } from "@/lib/beta";

export async function adminToggleBeta(formData: FormData) {
  await requireAdmin();
  await setBetaEnabled(formData.get("on") === "1");
  revalidatePath("/admin");
  revalidatePath("/beta");
}

export async function adminAcceptTester(formData: FormData) {
  await requireAdmin();
  const id = String(formData.get("id") ?? "");
  const app = await getApplication(id);
  if (!app || app.status !== "pending") return;
  const key = mintLicenceKey();
  await createLicence({
    key,
    email: app.email,
    plan: BETA_PLAN,
    expiresAt: null,
    seats: UNLIMITED,
    phones: 0,
    subUsers: 0,
    resell: false,
    mode: "byok",
    stripeSession: `beta-tester-${id}`,
    stripeCustomer: null,
    stripeSubscription: null,
  });
  await recordBetaRedemption({
    email: app.email,
    code: "TESTER",
    discount_cents: 9900,
    paid_cents: 0,
    stripe_session: null,
    licence_key: key,
  });
  await markApplication(id, "accepted", key);
  const site = process.env.SITE_URL ?? "https://nohandsapp.com";
  try {
    await sendPlainEmail(
      app.email,
      "You're in — your Look Ma, No Hands beta seat",
      `Hey ${app.name},\n\nYou're one of the ten. Here's your lifetime licence key:\n\n    ${key}\n\nGet going:\n1. Download the Mac app: ${site}/#download\n2. Sign in at ${site}/account with this email, enter the key, and add your Anthropic API key (Settings → API keys; costs cents).\n3. Chrome hand: in the app, Settings → Chrome extension → Install Chrome extension.\n4. Say "Hey Mama" and hand it something.\n\nThe deal: 5+ hours a month, one feedback form a month, three months. The form lives here, bookmark it: ${site}/testers/feedback\n\nWhen something breaks, that's the gold. Tell me.\n\n— Hawk`,
    );
  } catch (err) {
    console.error("tester acceptance email failed (licence was still issued)", err);
  }
  revalidatePath("/admin");
  revalidatePath("/testers");
}

export async function adminDeclineTester(formData: FormData) {
  await requireAdmin();
  const id = String(formData.get("id") ?? "");
  const app = await getApplication(id);
  if (!app || app.status !== "pending") return;
  await markApplication(id, "declined", null);
  revalidatePath("/admin");
}
