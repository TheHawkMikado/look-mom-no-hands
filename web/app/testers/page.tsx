import type { Metadata } from "next";
import { Lockup } from "@/components/Logo";
import { ApplyForm } from "@/components/TesterForms";
import { ensureSchema } from "@/lib/db";
import { BETA_TESTER_SEATS, countAcceptedTesters } from "@/lib/db-beta";

export const metadata: Metadata = {
  title: "Beta testers — Look Ma, No Hands",
  description: "Ten free lifetime seats for people who'll use it for real and tell us the truth.",
};
export const dynamic = "force-dynamic";

/** The public beta-tester application: ten seats, free for life. */
export default async function Testers() {
  let taken = 0;
  try {
    await ensureSchema();
    taken = await countAcceptedTesters();
  } catch (err) {
    console.error("testers page could not count seats", err);
  }
  const left = Math.max(0, BETA_TESTER_SEATS - taken);

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
        <p className="stat-label" style={{ textAlign: "center" }}>Beta testers · {left} of {BETA_TESTER_SEATS} seats left</p>
        <h1 style={{ textAlign: "center" }}>Ten people. Free for life. One catch.</h1>
        <p className="sub" style={{ textAlign: "center", maxWidth: "50ch", margin: "0 auto" }}>
          Look Ma, No Hands is a voice-first chief of staff for your Mac: it delegates to your
          team, sits in your meetings, hands out the action items, and reads you back what
          happened. I&rsquo;m giving ten lifetime seats to people who&rsquo;ll use it for real and tell me
          what broke.
        </p>

        <div className="grid" style={{ marginTop: 32 }}>
          <div className="card">
            <h3>You get</h3>
            <p>The Mac app, the phone app, the Chrome extension and every update, for life. The
              normal lifetime licence is $99. Yours is $0.</p>
          </div>
          <div className="card">
            <h3>You give</h3>
            <p><strong>5+ hours a month</strong> of real use, for three months, and <strong>one short feedback
              form a month</strong>. Three forms total. Miss them and the seat goes to the next person.</p>
          </div>
          <div className="card">
            <h3>You need</h3>
            <p>A Mac on macOS 14 or newer and your own AI key (Anthropic; I&rsquo;ll show you where to get one
              and it costs cents). Chrome if you want the browser hand.</p>
          </div>
        </div>

        <div style={{ maxWidth: 520, margin: "0 auto" }}>
          {left > 0 ? (
            <ApplyForm />
          ) : (
            <p className="dim" style={{ textAlign: "center", marginTop: 24 }}>All ten seats are taken. Apply anyway and you&rsquo;re first in line if one opens up.</p>
          )}
          {left === 0 ? <ApplyForm /> : null}
        </div>

        <p className="dim small" style={{ textAlign: "center", marginTop: 32 }}>
          Your voice, audio and transcripts never leave your Mac. The service only ever sees task
          titles, statuses and receipts. That&rsquo;s enforced in code, with a test that fails the build.
        </p>
      </section>
    </div>
  );
}
