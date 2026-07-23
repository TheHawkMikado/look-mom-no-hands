import { Lockup, Mark } from "@/components/Logo";
import { Pricing } from "@/components/Pricing";
import { storefront } from "@/lib/catalogue";

/**
 * Landing page. Everything the buyer needs to decide, on one scroll: what it
 * does, the honest requirements, price, and the questions that would otherwise
 * arrive as refund requests (Apple Silicon vs Intel, the API key, the App Store).
 */

const DOWNLOAD_URL =
  process.env.NEXT_PUBLIC_DOWNLOAD_URL ??
  "https://github.com/TheHawkMikado/look-mom-no-hands/releases/latest";

export const dynamic = "force-dynamic";

export default async function Home() {
  const plans = await storefront();

  return (
    <>
      <div className="wrap">
        <nav>
          <span className="brand">
            <Lockup />
          </span>
          <a href="#how">How it works</a>
          <a href="#pricing">Pricing</a>
          <a href="#faq">FAQ</a>
          <a href={DOWNLOAD_URL}>Download</a>
          <a href="/account">Sign in</a>
        </nav>

        <header className="hero">
          <Mark size={92} className="hero-mark" />
          <h1>
            Run your Mac by <span className="said">saying so</span>.
          </h1>
          <p className="lede">
            Say &ldquo;Hey Mama&rdquo;, then just talk. It opens apps, drives websites,
            clicks buttons, types where your cursor is, and turns rambling into a
            clean set of notes. Your speech is recognised on your own machine.
          </p>
          <div className="cta-row">
            <a className="btn btn-primary" href="#pricing">
              Buy — 7-day free trial
            </a>
            <a className="btn btn-ghost" href={DOWNLOAD_URL} id="download">
              Download for Mac
            </a>
          </div>
          <p className="requires">
            macOS 14 or later · Intel and Apple Silicon · 2 MB download
          </p>

          <div className="demo">
            <div className="row">
              <span className="who">You</span>
              <span className="what">&ldquo;Hey Mama, open the pricing page on our site in Chrome&rdquo;</span>
            </div>
            <div className="row">
              <span className="who">App</span>
              <span className="what">
                <code>open_app Chrome → open_url /pricing</code>
              </span>
            </div>
            <div className="row">
              <span className="who">You</span>
              <span className="what">&ldquo;Mama, dictate this&rdquo; …</span>
            </div>
            <div className="row">
              <span className="who">App</span>
              <span className="what">
                <code>cleaned text pasted at your cursor</code>
              </span>
            </div>
          </div>
        </header>
      </div>

      <section id="how">
        <div className="wrap">
          <h2>Four things it actually does</h2>
          <p className="sub">
            No macros to record, no scripts to write. You describe the outcome and it
            works out the steps.
          </p>
          <div className="grid">
            <div className="card">
              <h3>Drives real apps</h3>
              <p>
                Reads what&rsquo;s genuinely on screen through the accessibility layer,
                then clicks, types, scrolls and sends shortcuts. One sentence can carry
                several steps.
              </p>
            </div>
            <div className="card">
              <h3>Dictates anywhere</h3>
              <p>
                A chord or a spoken phrase starts recording; it tidies up the filler and
                pastes clean text wherever your cursor is.
              </p>
            </div>
            <div className="card">
              <h3>Turns talk into notes</h3>
              <p>
                Ramble for ten minutes and get a title, a summary, key points, action
                items and the full transcript — all stored locally.
              </p>
            </div>
            <div className="card">
              <h3>Asks instead of guessing</h3>
              <p>
                When a request is ambiguous it says so and offers options, out loud and
                on screen. Answer by clicking or just by talking back.
              </p>
            </div>
          </div>
        </div>
      </section>

      <section id="pricing">
        <div className="wrap">
          <h2>Pricing</h2>
          <p className="sub">
            Try it free for 7 days — no card. Billed weekly, cancel any time.
          </p>
          <Pricing plans={plans} />

          <p className="footnote">
            *Unlimited includes 27 Solo sub-users. Each additional user is $1 / week.
          </p>
        </div>
      </section>

      <section id="faq">
        <div className="wrap">
          <h2>Questions worth asking first</h2>
          <p className="sub">The awkward ones, answered before you pay.</p>

          <details>
            <summary>Do I need my own Anthropic API key?</summary>
            <p>
              Yes. Speech is recognised on your Mac, but working out what you meant and
              writing your notes runs through Claude, and you bring your own key so your
              text never passes through our servers. Typical use runs a few dollars a
              month, billed to you by Anthropic. Paste the key once into the menu-bar
              panel; it&rsquo;s stored in your Keychain.
            </p>
          </details>

          <details>
            <summary>Is my voice sent anywhere?</summary>
            <p>
              Speech-to-text happens on your machine using Apple&rsquo;s on-device
              recogniser — audio never leaves your Mac. The resulting <em>text</em> goes
              to Claude with your key so it can act on it. Transcripts and logs are
              written only to your own Application Support folder.
            </p>
          </details>

          <details>
            <summary>Why isn&rsquo;t this in the Mac App Store?</summary>
            <p>
              Because it couldn&rsquo;t be. App Store apps must run sandboxed, and the
              sandbox forbids reading and controlling other applications — which is the
              entire product. Every app of this kind (Keyboard Maestro, BetterTouchTool,
              Raycast, Alfred) ships direct for the same reason. The download is signed
              and notarised by Apple, so it opens with no warnings.
            </p>
          </details>

          <details>
            <summary>Does it work on an Intel Mac?</summary>
            <p>
              Yes. The download is a universal binary — one file that runs natively on
              both Apple Silicon and Intel Macs, macOS 14 or later.
            </p>
          </details>

          <details>
            <summary>What permissions will it ask for?</summary>
            <p>
              Microphone and Speech Recognition (prompted on first launch), and
              Accessibility, which you grant by hand in System Settings. Accessibility is
              what allows clicking and typing; opening apps and websites works without
              it.
            </p>
          </details>

          <details>
            <summary>Can I move it to a new Mac?</summary>
            <p>
              Yes — deactivate from the old Mac&rsquo;s panel and activate on the new one
              with the same key. Your plan sets how many Macs can be active at once.
            </p>
          </details>

          <details>
            <summary>What if it doesn&rsquo;t work for me?</summary>
            <p>
              The 7-day trial is the real test, and it needs no card. If you buy and
              it still isn&rsquo;t right, email within 30 days and you&rsquo;ll get a
              refund.
            </p>
          </details>
        </div>
      </section>

      <div className="wrap">
        <footer>
          <span>© {new Date().getFullYear()} Look Ma, No Hands</span>
          <a href="mailto:support@nohandsapp.com">support@nohandsapp.com</a>
          <a href="/privacy">Privacy</a>
          <a href="/terms">Terms</a>
        </footer>
      </div>
    </>
  );
}
