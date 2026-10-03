import type { Metadata } from "next";
import { Lockup } from "@/components/Logo";

export const metadata: Metadata = {
  title: "Chrome extension privacy policy — Look Ma, No Hands",
  description: "What the Look Ma, No Hands Chrome extension reads, where it goes, and what it never does.",
};

/** The privacy policy the Chrome Web Store listing links to. */
export default function ExtensionPrivacy() {
  return (
    <div className="wrap">
      <nav>
        <span className="brand">
          <a href="/" style={{ textDecoration: "none" }}>
            <Lockup />
          </a>
        </span>
        <a href="/chrome-extension">Chrome extension</a>
      </nav>
      <section style={{ borderTop: 0, paddingTop: 48, maxWidth: "70ch" }}>
        <p className="stat-label">Privacy policy</p>
        <h1>The Chrome extension</h1>
        <p className="dim">Effective 3 October 2026.</p>

        <h2>What it does</h2>
        <p>
          The extension lets the Look Ma, No Hands desktop app read the structure of the web page you are
          working on and act on it (click, type, scroll, switch tabs) when you ask the app to do something
          in your browser.
        </p>

        <h2>What it reads, and when</h2>
        <ul className="dim">
          <li>Only when the desktop app asks, during a command you gave it. It does not read pages in the background.</li>
          <li>The page&rsquo;s interactive elements (links, buttons, fields, headings), a short text excerpt, and on request the HTML of an element or a screenshot of the visible tab.</li>
          <li>Your open tabs&rsquo; titles and addresses, to pick the right tab.</li>
        </ul>

        <h2>Where it goes</h2>
        <ul className="dim">
          <li>Only to the desktop app running on the same computer, over a local connection to <code>127.0.0.1</code>. The extension makes no network requests to any server.</li>
          <li>The desktop app uses what was read to carry out that one command. It is not stored by the extension.</li>
          <li>The extension stores two things locally in your browser: the port number and the pairing code you entered. Nothing else.</li>
        </ul>

        <h2>What it never does</h2>
        <ul className="dim">
          <li>No analytics, no tracking, no advertising, no selling or sharing of data.</li>
          <li>No reading of passwords: password fields are listed without their value.</li>
          <li>No access to browser-internal pages.</li>
        </ul>

        <h2>Permissions, plainly</h2>
        <ul className="dim">
          <li><strong>Access to all sites</strong>: so it can read whichever page you ask the app to act on. It only does so on request.</li>
          <li><strong>Tabs</strong>: to list and switch tabs by title.</li>
          <li><strong>Scripting</strong>: to read the page and perform the click or typing you asked for.</li>
          <li><strong>Storage</strong>: to remember the pairing code and port.</li>
          <li><strong>Alarms</strong>: to keep the local connection to the app alive.</li>
        </ul>

        <h2>Contact</h2>
        <p className="dim">Questions: hello@nohandsapp.com.</p>
      </section>
    </div>
  );
}
