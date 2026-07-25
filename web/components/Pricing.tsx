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
          const label = mode === "byok" ? p.price_label_byok : p.price_label;
          const period = mode === "byok" ? p.period_byok : p.period;
          const available = mode === "cloud" ? !!p.price_id : !!p.price_id_byok;
          return (
            <div key={p.slug} className={`price${p.featured ? " featured" : ""}`}>
              <span className="tag">
                {p.name}
                {p.tagline ? ` · ${p.tagline}` : ""}
              </span>
              <div className="amount">
                {available && label ? label : "—"} <span>{available ? period : ""}</span>
              </div>
              <ul>
                {p.features.map((f, i) => (
                  <li key={i}>{f}</li>
                ))}
                {mode === "byok" && <li>Use your own API keys</li>}
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
                    : `Get ${p.name}`}
              </button>
            </div>
          );
        })}
      </div>
      <p className="err">{error}</p>
    </>
  );
}
