"use client";

import { useState } from "react";

/**
 * The buy buttons. Split out as the only client component on the landing page:
 * the plans themselves are fetched on the server from the order form, and just
 * the click handling needs to run in the browser.
 */

export interface PricingPlan {
  slug: string;
  name: string;
  tagline: string;
  price_label: string;
  period: string;
  features: string[];
  featured: boolean;
}

export function Pricing({ plans }: { plans: PricingPlan[] }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState("");

  async function buy(slug: string) {
    setBusy(slug);
    setError("");
    try {
      const res = await fetch("/api/checkout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ plan: slug }),
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
      <div className="prices">
        {plans.map((p) => (
          <div key={p.slug} className={`price${p.featured ? " featured" : ""}`}>
            <span className="tag">
              {p.name}
              {p.tagline ? ` · ${p.tagline}` : ""}
            </span>
            <div className="amount">
              {p.price_label} <span>{p.period}</span>
            </div>
            <ul>
              {p.features.map((f, i) => (
                <li key={i}>{f}</li>
              ))}
            </ul>
            <button
              className={`btn ${p.featured ? "btn-primary" : "btn-ghost"}`}
              disabled={busy !== null}
              onClick={() => buy(p.slug)}
            >
              {busy === p.slug ? "Opening checkout…" : `Get ${p.name}`}
            </button>
          </div>
        ))}
      </div>
      <p className="err">{error}</p>
    </>
  );
}
