import { Resend } from "resend";

/**
 * Outbound mail: licence keys and sign-in links.
 *
 * Every function reports whether it actually delivered rather than throwing on
 * a missing API key, because the two callers want opposite things. Issuing a
 * licence must never fail just because mail is down — the key is already saved
 * and the success page shows it. A sign-in link that wasn't sent, on the other
 * hand, has to surface: the user is staring at an empty inbox.
 */

const FROM = process.env.LICENCE_FROM ?? "Look Ma, No Hands <licences@nohandsapp.com>";

function client(): Resend | null {
  const apiKey = process.env.RESEND_API_KEY;
  return apiKey ? new Resend(apiKey) : null;
}

/** @returns true if the mail was handed to the provider. */
export async function sendLicenceEmail(to: string, key: string): Promise<boolean> {
  const resend = client();
  if (!resend) {
    console.warn(`RESEND_API_KEY unset — not emailing licence ${key} to ${to}`);
    return false;
  }

  const site = process.env.SITE_URL ?? "https://nohandsapp.com";

  await resend.emails.send({
    from: FROM,
    to,
    subject: "Your Look Ma, No Hands licence key",
    text: [
      "Thanks for subscribing to Look Ma, No Hands.",
      "",
      `Your licence key:  ${key}`,
      "",
      "To activate:",
      `  1. Download the app: ${site}/#download`,
      "  2. Drag it to Applications and open it",
      "  3. Click the menu-bar icon, paste the key, hit Activate",
      "",
      `Manage your subscription and devices any time at ${site}/account —`,
      "sign in with this email address, no password needed.",
      "",
      "Reply to this address if anything goes wrong.",
    ].join("\n"),
  });
  return true;
}

/** @returns true if the sign-in link was handed to the provider. */
export async function sendLoginEmail(to: string, url: string): Promise<boolean> {
  const resend = client();
  if (!resend) return false;

  await resend.emails.send({
    from: FROM,
    to,
    subject: "Your sign-in link",
    text: [
      "Here's your sign-in link for Look Ma, No Hands:",
      "",
      url,
      "",
      "It works once and expires in 20 minutes.",
      "",
      "If you didn't ask for this, ignore this email — nobody can sign in",
      "without the link above, and it will expire on its own.",
    ].join("\n"),
  });
  return true;
}
