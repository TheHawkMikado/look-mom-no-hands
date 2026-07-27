"use client";

import { useState } from "react";

/** Opens a one-time lifetime checkout for a tier (or the Team→Reseller upgrade). */
export function LifetimeBuy({
  tier,
  label,
  featured = false,
  upgrade = false,
}: {
  tier: string;
  label: string;
  featured?: boolean;
  upgrade?: boolean;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function buy() {
    setBusy(true);
    setError("");
    try {
      const res = await fetch("/api/checkout/lifetime", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ tier, upgrade }),
      });
      const data = await res.json();
      if (data.url) {
        window.location.href = data.url;
      } else {
        setError(data.error ?? "Could not start checkout.");
        setBusy(false);
      }
    } catch {
      setError("Could not start checkout.");
      setBusy(false);
    }
  }

  return (
    <>
      <button
        className={`btn ${featured ? "btn-primary" : "btn-ghost"}`}
        disabled={busy}
        onClick={buy}
      >
        {busy ? "Opening checkout…" : label}
      </button>
      {error && <p className="err">{error}</p>}
    </>
  );
}
