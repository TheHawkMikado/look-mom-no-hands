"use client";

import { useState } from "react";

/**
 * The buy buttons. Split out as the only client component on the landing page:
 * the plans themselves are fetched on the server from the order form, and just
 * the click handling (and the Cloud/BYOK switch) needs to run in the browser.
 */

export interface PricingPlan {
  slug: string;
  name: string;
  tagline: string;
  /** Cloud price. `price_id` presence = purchasable in Cloud mode. */
  price_id: string | null;
  price_label: string;
  period: string;
  /** Bring-your-own-key price. `price_id_byok` presence = purchasable in BYOK. */
  price_id_byok: string | null;
  price_label_byok: string;
  period_byok: string;
  features: string[];
  featured: boolean;
}

type Mode = "cloud" | "byok";

// Cloud-only presentation until the Cloud build lands. The top tier is "Company"
// on Cloud (no resell) but "Community" on BYOK (resell), and Cloud plans lead with
// their included hours. Keyed by slug; interim, replaced when Cloud ships.
const CLOUD_NAME: Record<string, string> = { community: "Company" };
const CLOUD_HOURS: Record<string, string> = {
  solo: "3h controller + 6h dictation / wk",
  family: "9h controller + 18h dictation / wk",
  community: "27h controller + 81h dictation / wk",
};

export function Pricing({
  plans,
  defaultMode = "cloud",
}: {
  plans: PricingPlan[];
  defaultMode?: Mode;
}) {
  // Cloud is the intended default, but the page opens on whichever mode is
  // actually sellable — so while Cloud has no prices yet, buyers land on BYOK
  // instead of a wall of "coming soon".
  const [mode, setMode] = useState<Mode>(defaultMode);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState("");

  async function buy(slug: string) {
    setBusy(slug);
    setError("");
    try {
      const res = await fetch("/api/checkout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ plan: slug, mode }),
      });
      const data = await res.json();
      if (data.url) {
        window.location.href = data.url;
        return;
      }
      setError(data.error ?? "Could not start checkout. Try again in a moment.");
    } catch {
      setError("Network error — check your connection and try again.");
    }
    setBusy(null);
  }

  if (plans.length === 0) {
    return <p className="dim">Plans are being updated — check back in a moment.</p>;
  }

  return (
    <>
      <div className="mode-toggle" role="tablist" aria-label="Pricing mode">
        <button
          role="tab"
          aria-selected={mode === "cloud"}
          className={mode === "cloud" ? "on" : ""}
          onClick={() => setMode("cloud")}
        >
          Cloud
        </button>
        <button
          role="tab"
          aria-selected={mode === "byok"}
          className={mode === "byok" ? "on" : ""}
          onClick={() => setMode("byok")}
        >
          Bring your own key
        </button>
      </div>
      <p className="mode-note">
        {mode === "cloud"
          ? "We run the AI for you — nothing to set up. Just sign in and start talking."
          : "Use your own Anthropic (and ElevenLabs) keys. You pay those providers directly for what you use; we license the app."}
      </p>

      <div className="prices">
        {plans.map((p) => {
          const cloud = mode === "cloud";
          const label = cloud ? p.price_label : p.price_label_byok;
          const period = cloud ? p.period : p.period_byok;
          const available = cloud ? !!p.price_id : !!p.price_id_byok;
          // On Cloud the top tier is "Company" (no resell); its BYOK "resell
          // rights" tagline is dropped there.
          const name = cloud ? CLOUD_NAME[p.slug] ?? p.name : p.name;
          const tagline = cloud && CLOUD_NAME[p.slug] ? "" : p.tagline;
          return (
            <div key={p.slug} className={`price${p.featured ? " featured" : ""}`}>
              <span className="tag">
                {name}
                {tagline ? ` · ${tagline}` : ""}
              </span>
              <div className="amount">
                {label || "—"} <span>{period}</span>
              </div>
              <ul>
                {cloud && CLOUD_HOURS[p.slug] && <li>{CLOUD_HOURS[p.slug]}</li>}
                {p.features.map((f, i) => (
                  <li key={i}>{f}</li>
                ))}
                {cloud ? <li>We run the AI — no key needed</li> : <li>Use your own API keys</li>}
              </ul>
              <button
                className={`btn ${p.featured ? "btn-primary" : "btn-ghost"}`}
                disabled={busy !== null || !available}
                onClick={() => buy(p.slug)}
              >
                {!available
                  ? "Coming soon"
                  : busy === p.slug
                    ? "Opening checkout…"
                    : `Get ${name}`}
              </button>
            </div>
          );
        })}
      </div>
      <p className="err">{error}</p>
    </>
  );
}
