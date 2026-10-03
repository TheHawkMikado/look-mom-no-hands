import { Lockup } from "@/components/Logo";

export const metadata = {
  title: "Privacy Policy — Look Ma, No Hands",
  description:
    "What the Look Ma, No Hands app and nohandsapp.com collect, why, where it goes, and how to delete it.",
};

// Legal page, intentionally plain: Google OAuth verification and app-store
// reviewers read this for substance, not design. Every section describes what
// the shipped app actually does — keep it in sync when a data path changes.
export default function Privacy() {
  return (
    <div className="wrap">
      <nav>
        <span className="brand">
          <a href="/" style={{ textDecoration: "none" }}>
            <Lockup />
          </a>
        </span>
        <a href="/terms">Terms</a>
        <a href="/account">Sign in</a>
      </nav>

      <section style={{ borderTop: 0, paddingTop: 56, maxWidth: "72ch" }}>
        <h1>Privacy Policy</h1>
        <p className="dim">Effective October 3, 2026</p>

        <p>
          Look Ma, No Hands (“the app”) is a voice-controlled assistant for macOS made by
          InVert Inc. (“we”, “us”). This policy covers the Mac app, the companion phone
          app, the Chrome extension, and this website, nohandsapp.com. It is written to be
          read, not skimmed: it says exactly what the app can access, why, where that
          information goes, and how you delete it.
        </p>

        <h2>The short version</h2>
        <ul>
          <li>The app runs on your Mac and keeps its data on your Mac by default.</li>
          <li>
            Your voice, your screen, and your calendar are used only to do what you asked —
            never for advertising, never sold, never used to train AI models.
          </li>
          <li>
            Understanding your requests requires AI services (Anthropic for language, ElevenLabs
            for speech). Only the words and, when needed, the screenshot required to carry out a
            request are sent, over encrypted connections.
          </li>
          <li>
            Our own servers see your account details and anonymous usage counts — never your
            audio, transcripts, screenshots, or calendar contents.
          </li>
        </ul>

        <h2>What the app can access on your Mac, and why</h2>
        <p>
          Each capability is gated by a macOS permission you grant explicitly, and each can be
          turned off in Settings.
        </p>
        <ul>
          <li>
            <strong>Microphone.</strong> The app listens for its wake phrase (“Hey Mama”) using
            Apple&apos;s on-device speech recognition. Nothing leaves your Mac while it waits for
            the wake phrase. After you wake it, the words of your command or dictation are sent
            to the AI services described below so they can be understood and acted on.
          </li>
          <li>
            <strong>Speech Recognition.</strong> Apple&apos;s on-device recognizer converts your
            speech to text. It runs locally and is subject to Apple&apos;s privacy terms.
          </li>
          <li>
            <strong>Accessibility.</strong> To click, type, and read what is on screen, the app
            uses the macOS Accessibility API. Text labels from the frontmost window are sent with
            your command so the assistant knows what it can click. It never reads password fields
            and is instructed never to grant websites microphone or camera access on your behalf.
          </li>
          <li>
            <strong>Screen Recording.</strong> Two uses, both optional: (1) when the Accessibility
            tree cannot find something you asked it to click, a screenshot is sent to the AI
            service to locate it visually (“Vision fallback”, off-switchable in Settings);
            (2) to record a meeting you asked it to join, it captures system audio. It never
            records your screen as video.
          </li>
          <li>
            <strong>Calendars.</strong> With your permission the app reads upcoming events to find
            Google Meet, Zoom, and Microsoft Teams links, so “join my meeting” knows which meeting
            you mean. It reads event titles, times, locations, descriptions, and conference links.
            It never writes to, edits, or deletes events. See <em>Connected calendars</em> below.
          </li>
          <li>
            <strong>Clipboard.</strong> When you dictate in insert mode, the cleaned-up text is
            placed on your clipboard and pasted where your cursor is.
          </li>
          <li>
            <strong>Files.</strong> Notes, transcripts, meeting recordings, and the activity log are
            stored under <code>~/Library/Application Support/LookMaNoHands/</code>. If you turn on
            Notes export, copies are also written to a folder you choose (for example your
            Dropbox folder). That folder is yours; the app only writes to it.
          </li>
        </ul>

        <h2>Connected calendars (Google, Microsoft, Apple)</h2>
        <p>
          You can connect Google Calendar or Microsoft Outlook inside the app, or allow access to
          the calendars already on your Mac. For Google and Microsoft, you sign in through your
          browser; the app receives a read-only access token which is stored in your Mac&apos;s
          Keychain and used only to fetch your upcoming events.
        </p>
        <ul>
          <li>
            <strong>What is read:</strong> event titles, start and end times, locations,
            descriptions, and conference links, for the next ten hours, plus the email address of
            the connected account so Settings can show which account is connected.
          </li>
          <li>
            <strong>Where it goes:</strong> nowhere. Event details stay in the app&apos;s memory on
            your Mac and are discarded as they pass. The titles and links of upcoming meetings are
            included in the request sent to the AI service <em>only</em> when you give a meeting
            command, so it can pick the right one. They are not stored on our servers, not shared
            with anyone, not used for advertising, and not used to train models. No human at
            InVert Inc. ever sees them.
          </li>
          <li>
            <strong>Revoking access:</strong> click Disconnect in Settings → Meetings, which deletes
            the token from your Keychain. You can also revoke the app from your Google Account
            (myaccount.google.com → Security → Third-party access) or Microsoft account at any
            time.
          </li>
        </ul>
        <p>
          Look Ma, No Hands&apos; use and transfer of information received from Google APIs
          adheres to the{" "}
          <a href="https://developers.google.com/terms/api-services-user-data-policy">
            Google API Services User Data Policy
          </a>
          , including the Limited Use requirements.
        </p>

        <h2>Meeting recordings and notes</h2>
        <p>
          When you ask the app to join a meeting, it records the call&apos;s audio (what you hear,
          plus your microphone) to an audio file on your Mac and, by default, announces out loud
          that it is recording. After the meeting, if you have provided an ElevenLabs key, the
          recording is sent to ElevenLabs for transcription and the transcript is sent to
          Anthropic to produce notes (summary, key points, action items). Recordings and notes
          stay on your Mac (and in your export folder if enabled). <strong>You are responsible
          for complying with recording-consent laws where you and other participants are
          located</strong> — in many places every participant must consent to being recorded.
        </p>

        <h2>Services that process your data</h2>
        <p>
          The app cannot understand language on its own. These providers process the minimum
          needed for each request, over TLS-encrypted connections:
        </p>
        <ul>
          <li>
            <strong>Anthropic</strong> (Claude): the text of your commands and dictations, the
            on-screen labels or screenshot needed to act, meeting transcripts for note-taking,
            and short descriptions of apps you use. Governed by Anthropic&apos;s privacy policy
            and commercial terms, under which API inputs are not used to train models.
          </li>
          <li>
            <strong>ElevenLabs</strong>: audio clips for higher-accuracy transcription (if you
            enable it) and the short text of spoken replies for text-to-speech.
          </li>
          <li>
            <strong>Google and Microsoft</strong>: only when you connect a calendar, as described
            above.
          </li>
        </ul>
        <p>
          On a “bring your own keys” plan these requests are made with your own API keys, under
          your own agreements with those providers; the keys are stored in your Keychain and
          never sent to us. On a Cloud plan the requests are made with keys we hold, and we
          record the cost and duration of each request (not its content) to meter your plan.
        </p>

        <h2>What our servers see</h2>
        <p>nohandsapp.com and its API hold only what is needed to run your account:</p>
        <ul>
          <li>Your email address, licence and plan, and a random identifier for each device.</li>
          <li>
            Usage counts per device: number of requests, metered cost, and active seconds, split
            by workload (commands, dictation, agents, meetings). Never audio, text, screenshots,
            or calendar data.
          </li>
          <li>
            If you use the phone companion: short status lines about tasks (for example “started”,
            “done”, “needs your approval”) and the tasks you send from the phone to your Mac.
            Transcripts and screen contents never pass through the phone relay.
          </li>
          <li>Payment records are handled by Stripe; we never see your card number.</li>
          <li>Standard web server logs (IP address, browser, pages visited), kept briefly.</li>
        </ul>
        <p>
          We do not sell personal information, do not share it with data brokers, and do not
          show advertising. Our hosting providers (Vercel, Neon) process data on our behalf
          under their own security commitments.
        </p>

        <h2>Retention and deletion</h2>
        <ul>
          <li>
            <strong>On your Mac:</strong> everything in{" "}
            <code>~/Library/Application Support/LookMaNoHands/</code> is yours to delete at any
            time; the app keeps no hidden copies. Deleting the app and that folder removes all
            local data. Tokens and keys live in your Keychain.
          </li>
          <li>
            <strong>Your export folder:</strong> we never delete from it; manage it like any other
            folder.
          </li>
          <li>
            <strong>Our servers:</strong> email{" "}
            <a href="mailto:support@nohandsapp.com">support@nohandsapp.com</a> to delete your
            account; we remove account, device, and usage records within 30 days, keeping only
            what tax and payment law requires.
          </li>
        </ul>

        <h2>Security</h2>
        <p>
          The app is signed with an Apple Developer ID and notarized. Secrets are stored in the
          macOS Keychain. All network connections use TLS. The app never captures password
          fields, and system-wide protections (Accessibility, Screen Recording, Calendars) are
          enforced by macOS permissions you control in System Settings → Privacy &amp; Security.
        </p>

        <h2>Children</h2>
        <p>The app and website are not directed at children under 16 and we do not knowingly collect their data.</p>

        <h2>Changes</h2>
        <p>
          When this policy changes we update the effective date above, and for material changes
          we notify account holders by email.
        </p>

        <h2>Contact</h2>
        <p>
          InVert Inc. ·{" "}
          <a href="mailto:support@nohandsapp.com">support@nohandsapp.com</a>
        </p>
      </section>

      <footer>
        <a href="/">Home</a>
        <a href="/terms">Terms</a>
        <a href="mailto:support@nohandsapp.com">support@nohandsapp.com</a>
      </footer>
    </div>
  );
}
