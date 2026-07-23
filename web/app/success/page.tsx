import Link from "next/link";
import { ensureSchema, licenceForSession } from "@/lib/db";
import { stripe } from "@/lib/stripe";

/**
 * Post-checkout receipt. Reads the licence the *webhook* created rather than
 * creating one itself — otherwise anyone could mint a key by guessing a URL.
 *
 * The webhook and this redirect race, and the webhook usually loses by a second
 * or two, so a missing licence here means "not yet", not "failed". Hence the
 * poll below and the reassuring copy rather than an error.
 */

export const dynamic = "force-dynamic";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export default async function Success({
  searchParams,
}: {
  searchParams: Promise<{ session_id?: string }>;
}) {
  const { session_id: sessionId } = await searchParams;

  if (!sessionId) {
    return (
      <Shell title="Nothing to show here">
        <p className="steps">
          No checkout session in the link. If you&rsquo;ve just paid, your key is in your
          email — or write to support@nohandsapp.com.
        </p>
      </Shell>
    );
  }

  // Confirm with Stripe that this session was actually paid before showing
  // anything: the session id alone is only a claim.
  let paid = false;
  try {
    const session = await stripe().checkout.sessions.retrieve(sessionId);
    paid = session.payment_status === "paid" || session.status === "complete";
  } catch {
    paid = false;
  }

  if (!paid) {
    return (
      <Shell title="Payment not confirmed">
        <p className="steps">
          Stripe hasn&rsquo;t confirmed this payment. If you were charged, email
          support@nohandsapp.com with your receipt and you&rsquo;ll get a key straight
          away.
        </p>
      </Shell>
    );
  }

  await ensureSchema();

  // ~6s of patience, which comfortably covers normal webhook delivery.
  let licence = await licenceForSession(sessionId);
  for (let i = 0; i < 6 && !licence; i++) {
    await sleep(1000);
    licence = await licenceForSession(sessionId);
  }

  if (!licence) {
    return (
      <Shell title="Payment received — key on its way">
        <p className="steps">
          Your payment went through, but the key is still being issued. It will arrive by
          email within a minute. If it doesn&rsquo;t, email support@nohandsapp.com and
          quote <code>{sessionId}</code>.
        </p>
      </Shell>
    );
  }

  return (
    <Shell title="You're in. Here's your key.">
      <div className="keybox">
        <code>{licence.key}</code>
      </div>
      <p style={{ color: "var(--muted)", fontSize: 14 }}>
        Also emailed to {licence.email}. Keep it — it&rsquo;s how you reinstall or move
        Macs.
      </p>
      <ol className="steps">
        <li>
          <a href={process.env.NEXT_PUBLIC_DOWNLOAD_URL ?? "/#download"}>Download the app</a>{" "}
          and drag it into Applications.
        </li>
        <li>Open it and click the waveform icon in your menu bar.</li>
        <li>Paste the key above and hit Activate.</li>
        <li>Add your Anthropic API key, then click Start listening.</li>
      </ol>
    </Shell>
  );
}

function Shell({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="wrap">
      <div className="receipt">
        <h1 style={{ fontSize: 34 }}>{title}</h1>
        {children}
        <p style={{ marginTop: 40 }}>
          <Link className="btn btn-ghost" href="/">
            Back to nohandsapp.com
          </Link>
        </p>
      </div>
    </div>
  );
}
