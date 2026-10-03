import { Lockup } from "@/components/Logo";

export const metadata = {
  title: "Terms of Service — Look Ma, No Hands",
  description: "The agreement that governs your use of the Look Ma, No Hands app and nohandsapp.com.",
};

export default function Terms() {
  return (
    <div className="wrap">
      <nav>
        <span className="brand">
          <a href="/" style={{ textDecoration: "none" }}>
            <Lockup />
          </a>
        </span>
        <a href="/privacy">Privacy</a>
        <a href="/account">Sign in</a>
      </nav>

      <section style={{ borderTop: 0, paddingTop: 56, maxWidth: "72ch" }}>
        <h1>Terms of Service</h1>
        <p className="dim">Effective October 3, 2026</p>

        <p>
          These terms are an agreement between you and InVert Inc. (“we”, “us”) for the Look Ma,
          No Hands macOS app, its companion phone app and Chrome extension, and nohandsapp.com
          (together, “the service”). By installing the app or creating an account you accept
          them. If you are using the service for an organization, you confirm you may bind it.
        </p>

        <h2>1. What the service is</h2>
        <p>
          Look Ma, No Hands is a voice-controlled assistant that runs on your Mac. On your spoken
          instruction it opens apps and websites, clicks and types on your screen, takes
          dictation, joins and records meetings, and produces notes. It does these things by
          sending your requests to third-party AI services (described in our{" "}
          <a href="/privacy">Privacy Policy</a>) and acting on the result.
        </p>

        <h2>2. Accounts, plans, and licences</h2>
        <ul>
          <li>
            You need an account (an email address) for paid plans and the phone companion. Keep
            your sign-in private; you are responsible for activity under your account.
          </li>
          <li>
            Plans are described at checkout: a free trial, weekly subscriptions, lifetime
            licences, and beta or team offers. A licence covers the devices and seats stated in
            the plan. Prices and plan contents may change; changes do not affect a lifetime
            licence already purchased.
          </li>
          <li>
            Subscriptions renew automatically until cancelled from your account page. Payments
            are processed by Stripe under its terms. For refund requests, contact{" "}
            <a href="mailto:support@nohandsapp.com">support@nohandsapp.com</a>.
          </li>
          <li>
            We grant you a personal, non-transferable, revocable licence to use the app under
            these terms. You may not resell it, reverse-engineer it beyond what law allows, or
            use it to build a competing product from its outputs.
          </li>
        </ul>

        <h2>3. Your API keys and third-party services</h2>
        <p>
          On a “bring your own keys” plan you supply API keys for Anthropic and ElevenLabs. Those
          providers bill you directly under your own agreements with them, and you are
          responsible for keeping your keys secure and for their usage. On a Cloud plan we supply
          the keys and meter usage against your plan; sustained usage beyond the plan may be
          throttled or billed as described at checkout. Connecting a calendar is subject to
          Google&apos;s or Microsoft&apos;s terms for your account.
        </p>

        <h2>4. The app acts on your behalf — and on your instruction</h2>
        <p>
          The assistant does what you tell it to on your own computer, with the permissions you
          granted. AI systems make mistakes: a command can be misheard, a button misidentified, a
          page misread. <strong>You are responsible for the actions taken on your screen and the
          messages, purchases, or changes they produce.</strong> Do not rely on the app for
          irreversible or safety-critical actions without checking the result, and keep the
          “Stop” controls within reach. We may add safeguards (for example the app will not grant
          websites microphone or camera access on your behalf) but they are not a substitute for
          your supervision.
        </p>

        <h2>5. Recording and consent</h2>
        <p>
          The app can record meetings and transcribe speech. Laws on recording conversations vary
          and in many places require the consent of every participant. <strong>You are solely
          responsible for obtaining any consent required where you and the other participants
          are located</strong>, for honoring any participant&apos;s objection, and for how you
          store and share recordings and notes. The “announce recording out loud” setting is
          provided to help; leaving it on does not by itself satisfy any law.
        </p>

        <h2>6. Acceptable use</h2>
        <p>You agree not to use the service to:</p>
        <ul>
          <li>record, monitor, or control a computer or conversation without authorization;</li>
          <li>send spam, harass, defraud, or impersonate anyone, or automate access to services in breach of their terms;</li>
          <li>circumvent licence limits, share accounts beyond your plan, or probe or disrupt our systems;</li>
          <li>break any applicable law.</li>
        </ul>
        <p>We may suspend or terminate accounts that do.</p>

        <h2>7. Your content</h2>
        <p>
          Your voice, dictations, transcripts, recordings, notes, and screen contents are yours.
          We claim no ownership and use them only to provide the service as described in the
          Privacy Policy. You are responsible for having the rights to anything you dictate,
          record, or export.
        </p>

        <h2>8. Updates and availability</h2>
        <p>
          The app checks for updates and installs them when your Mac is idle; you can trigger or
          postpone an update from the menu. We may change, suspend, or discontinue features, and
          third-party AI services may change their behavior or pricing, which can affect the app.
          We aim for high availability but do not guarantee the service will be uninterrupted or
          error-free.
        </p>

        <h2>9. Disclaimers</h2>
        <p>
          THE SERVICE IS PROVIDED “AS IS” AND “AS AVAILABLE”, WITHOUT WARRANTIES OF ANY KIND,
          EXPRESS OR IMPLIED, INCLUDING MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND
          NON-INFRINGEMENT. AI-GENERATED TRANSCRIPTS, NOTES, AND ACTIONS MAY BE INACCURATE.
        </p>

        <h2>10. Limitation of liability</h2>
        <p>
          TO THE FULLEST EXTENT PERMITTED BY LAW, INVERT INC. WILL NOT BE LIABLE FOR INDIRECT,
          INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES, OR FOR LOST PROFITS, DATA, OR
          GOODWILL, ARISING FROM THE SERVICE OR THESE TERMS. OUR TOTAL LIABILITY FOR ANY CLAIM
          IS LIMITED TO THE AMOUNT YOU PAID US IN THE TWELVE MONTHS BEFORE THE CLAIM AROSE. Some
          jurisdictions do not allow these limits; where they do not, they apply to the extent
          permitted.
        </p>

        <h2>11. Termination</h2>
        <p>
          You may stop using the service and delete your account at any time. We may terminate
          or suspend access for breach of these terms. Sections 4, 5, 7, 9, 10, and 12 survive
          termination.
        </p>

        <h2>12. General</h2>
        <p>
          These terms are governed by the laws of the jurisdiction in which InVert Inc. is
          organized, without regard to conflict-of-law rules, and any dispute will be brought in
          its courts, unless applicable consumer law gives you additional rights. If a provision
          is unenforceable, the rest remains in effect. These terms, with the Privacy Policy and
          the plan description at checkout, are the entire agreement. We may update these terms;
          material changes are notified by email to account holders and take effect 14 days after
          notice.
        </p>

        <h2>Contact</h2>
        <p>
          InVert Inc. ·{" "}
          <a href="mailto:support@nohandsapp.com">support@nohandsapp.com</a>
        </p>
      </section>

      <footer>
        <a href="/">Home</a>
        <a href="/privacy">Privacy</a>
        <a href="mailto:support@nohandsapp.com">support@nohandsapp.com</a>
      </footer>
    </div>
  );
}
