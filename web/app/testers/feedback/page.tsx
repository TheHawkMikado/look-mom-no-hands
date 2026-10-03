import type { Metadata } from "next";
import { Lockup } from "@/components/Logo";
import { FeedbackForm } from "@/components/TesterForms";
import { feedbackMonth } from "@/lib/db-beta";

export const metadata: Metadata = {
  title: "Monthly feedback — Look Ma, No Hands",
  description: "The beta tester's monthly form.",
  robots: { index: false, follow: false },
};

/** The tester's monthly feedback form. Linked from the acceptance email. */
export default function Feedback() {
  return (
    <div className="wrap">
      <nav>
        <span className="brand">
          <a href="/" style={{ textDecoration: "none" }}>
            <Lockup />
          </a>
        </span>
        <a href="/testers">Beta testers</a>
      </nav>
      <section style={{ borderTop: 0, paddingTop: 56 }}>
        <p className="stat-label" style={{ textAlign: "center" }}>Beta testers · monthly feedback</p>
        <h1 style={{ textAlign: "center" }}>Tell me what actually happened.</h1>
        <p className="sub" style={{ textAlign: "center", maxWidth: "48ch", margin: "0 auto" }}>
          Five minutes. Blunt is better than polite. The things that made you take over are the
          most valuable lines on this form.
        </p>
        <div style={{ maxWidth: 560, margin: "0 auto" }}>
          <FeedbackForm month={feedbackMonth()} />
        </div>
      </section>
    </div>
  );
}
