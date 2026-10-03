import type { Metadata } from "next";
import { Lockup } from "@/components/Logo";
import { ExtensionPairStatus } from "@/components/ExtensionPairStatus";

export const metadata: Metadata = {
  title: "Chrome extension — Look Ma, No Hands",
  description: "Let the assistant read every element on a web page and click the exact one.",
};

const RELEASES = "https://github.com/TheHawkMikado/look-mom-no-hands/releases/latest";
// Set once the listing is live (Vercel env). Until then the page explains the
// unpacked install, which is what the app's "Show extension folder" is for.
const STORE = process.env.NEXT_PUBLIC_CHROME_WEBSTORE_URL ?? "";

/**
 * Setup page for the Chrome extension. The Mac app opens it as
 * /chrome-extension#code=XXXXXX, so install + pairing is one click: the
 * extension's content script reads the code from the fragment (never sent to
 * the server) and connects.
 */
export default function ChromeExtension() {
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

      <section style={{ borderTop: 0, paddingTop: 48 }}>
        <p className="stat-label">Chrome extension</p>
        <h1>See the page the way the browser does.</h1>
        <p className="sub" style={{ maxWidth: "52ch" }}>
          With the extension installed, the assistant reads every link, button, field and
          result on the page as a numbered map, and clicks or types by that exact number.
          No more guessing from screenshots. It only ever talks to the app on your Mac.
        </p>

        {STORE ? (
          <p style={{ marginTop: 20 }}>
            <a className="btn btn-primary" href={STORE} target="_blank" rel="noreferrer">
              Add to Chrome
            </a>
            <span className="dim small" style={{ marginLeft: 12 }}>
              One click in the Chrome Web Store. Works in Brave, Edge, Arc and Vivaldi too.
            </span>
          </p>
        ) : null}

        <ExtensionPairStatus />

        <h2 style={{ marginTop: 40 }}>{STORE ? "Installing by hand instead" : "Installing"}</h2>
        <div className="grid" style={{ marginTop: 12 }}>
          <div className="card">
            <h3>1. Find the extension folder</h3>
            <p>
              In the Mac app open Settings, scroll to <strong>Chrome extension</strong>, and click
              <strong> Show extension folder</strong>. Or download it from the{" "}
              <a href={RELEASES}>latest release</a> (the <code>chrome-extension-…zip</code> file) and unzip it.
            </p>
          </div>
          <div className="card">
            <h3>2. Load it in Chrome</h3>
            <p>
              Paste <code>chrome://extensions</code> into the address bar. Turn on{" "}
              <strong>Developer mode</strong> (top right). Click <strong>Load unpacked</strong> and choose
              that folder.
            </p>
          </div>
          <div className="card">
            <h3>3. Pair it</h3>
            <p>
              Come back to this page from the app&rsquo;s Settings (Install Chrome extension) and it pairs
              itself. Or click the extension&rsquo;s icon and enter the <strong>pairing code</strong> from Settings.
            </p>
          </div>
        </div>

        <h2 style={{ marginTop: 40 }}>What it can do</h2>
        <ul className="dim">
          <li>Read the page: every interactive element with a ref, headings, a text excerpt, and the full HTML of any element on request.</li>
          <li>Act: click, type, pick from dropdowns, scroll, hover, press keys, by ref.</li>
          <li>Tabs: list, switch, open, go back, close.</li>
          <li>Shadow DOM and same-origin frames are included. Browser-internal pages are not.</li>
        </ul>

        <h2 style={{ marginTop: 32 }}>Privacy</h2>
        <p className="dim">
          The extension connects only to <code>127.0.0.1</code> on this Mac, never to a server. A page is read
          only when the assistant is working on it, and what it reads goes exactly where the
          Accessibility snapshot already goes: into the planner for that one command.{" "}
          <a href="/chrome-extension/privacy">Full privacy policy</a>.
        </p>
      </section>
    </div>
  );
}
