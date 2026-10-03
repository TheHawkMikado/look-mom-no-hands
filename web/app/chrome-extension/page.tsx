import type { Metadata } from "next";
import { Lockup } from "@/components/Logo";

export const metadata: Metadata = {
  title: "Chrome extension — Look Ma, No Hands",
  description: "Let the assistant read every element on a web page and click the exact one.",
};

const RELEASES = "https://github.com/TheHawkMikado/look-mom-no-hands/releases/latest";

/**
 * Setup guide for the Chrome extension. The Mac app's Settings link here, and
 * the extension itself ships inside the app (Settings › Chrome extension ›
 * Show extension folder) and as a zip on every release.
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

        <div className="grid" style={{ marginTop: 28 }}>
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
              that folder. Works the same in Brave, Edge, Arc and Vivaldi.
            </p>
          </div>
          <div className="card">
            <h3>3. Pair it</h3>
            <p>
              Click the extension&rsquo;s icon in the toolbar, enter the <strong>pairing code</strong> shown in
              the app&rsquo;s Settings, and save. The dot turns green when the two are talking.
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
          Accessibility snapshot already goes: into the planner for that one command.
        </p>
      </section>
    </div>
  );
}
