import { Resend } from "resend";

/**
 * Licence delivery. Optional by design: if RESEND_API_KEY is absent the send is
 * skipped with a log line rather than throwing, so the site can be stood up and
 * tested end to end before email is configured. The success page always shows
 * the key, so a missing email is a degraded experience, not a lost purchase.
 */

const FROM = process.env.LICENCE_FROM ?? "Look Ma, No Hands <licences@nohandsapp.com>";

export async function sendLicenceEmail(to: string, key: string) {
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) {
    console.warn(`RESEND_API_KEY unset — not emailing licence ${key} to ${to}`);
    return;
  }

  const downloadURL = `${process.env.SITE_URL ?? "https://nohandsapp.com"}/#download`;

  await new Resend(apiKey).emails.send({
    from: FROM,
    to,
    subject: "Your Look Ma, No Hands licence key",
    text: [
      "Thanks for buying Look Ma, No Hands.",
      "",
      `Your licence key:  ${key}`,
      "",
      "To activate:",
      `  1. Download the app: ${downloadURL}`,
      "  2. Drag it to Applications and open it",
      "  3. Click the menu-bar icon, paste the key, hit Activate",
      "",
      "Keep this email — the key is how you reinstall or move to a new Mac.",
      "Reply to this address if anything goes wrong.",
    ].join("\n"),
  });
}
