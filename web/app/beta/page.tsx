import type { Metadata } from "next";
import { Lockup } from "@/components/Logo";
import { BetaBuy } from "@/components/BetaBuy";
import { ensureSchema } from "@/lib/db";
import { betaEnabled } from "@/lib/db-beta";

/**
 * The secret beta sales page. Not linked from anywhere, not indexed (robots
 * meta + robots.txt), reachable only by people who were given the URL — and a
 * BETA## code if you want them to pay less than $99.
 */

export const metadata: Metadata = {
  title: "Beta — Look Ma, No Hands",
  robots: { index: false, follow: false, nocache: true, googleBot: { index: false, follow: false } },
};
export const dynamic = "force-dynamic";

export default async function Beta({ searchParams }: { searchParams: Promise<{ code?: string }> }) {
  const { code = "" } = await searchParams;
  let open = true;
  try {
    await ensureSchema();
    open = await betaEnabled();
  } catch (err) {
    console.error("beta page could not read the programme switch", err);
  }

  return (
    <div className="wrap">
      <nav>
        <span className="brand">
          <a href="/" style={{ textDecoration: "none" }}>
            <Lockup />
          </a>
        </span>
        <a href="/account">Sign in</a>
      </nav>

      <section style={{ borderTop: 0, paddingTop: 56 }}>
        <p className="stat-label" style={{ textAlign: "center" }}>Private beta · by invitation</p>
        <h1 style={{ textAlign: "center" }}>A chief of staff that never needs your hands.</h1>
        <p className="sub" style={{ textAlign: "center", maxWidth: "48ch", margin: "0 auto" }}>
          Talk to it and it delegates to your team, confirms out loud, and brings you back the
          result to approve. Sit it in a meeting and it learns who’s who, pulls out every action
          item, hands them out, and reads you the summary. It follows up on its own and asks you
          one question at a time, at a good moment.
        </p>

        {open ? (
          <BetaBuy initialCode={code} />
        ) : (
          <p className="dim" style={{ textAlign: "center", marginTop: 24 }}>The beta is closed for now.</p>
        )}

        <div className="grid" style={{ marginTop: 40 }}>
          <div className="card">
            <h3>What you get</h3>
            <p>The Mac app, the phone app, and the website, for life. Unlimited devices. Your own
              Anthropic and ElevenLabs keys, so there is no metering and no monthly bill from us.</p>
          </div>
          <div className="card">
            <h3>What we ask</h3>
            <p>Use it for real work and tell us what broke. Beta seats get every update first,
              including the rough ones.</p>
          </div>
          <div className="card">
            <h3>Your data</h3>
            <p>Audio and transcripts never leave your Mac. The service only ever sees task titles,
              statuses, and receipts. That is enforced in code, with a test that fails the build.</p>
          </div>
        </div>

        <p className="dim small" style={{ textAlign: "center", marginTop: 32 }}>
          Beta is a one-time payment for a bring-your-own-key lifetime licence. Not transferable,
          one user per seat. If a seat was given to you with a code, the price above already
          reflects it.
        </p>
      </section>
    </div>
  );
}
