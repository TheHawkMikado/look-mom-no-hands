"use client";

import { useState } from "react";

/** Cloud overage credit top-up buttons — one per block; opens Stripe checkout. */
export function TopUp({ blocks }: { blocks: number[] }) {
  const [busy, setBusy] = useState<number | null>(null);
  const [error, setError] = useState("");

  async function buy(amount: number) {
    setBusy(amount);
    setError("");
    try {
      const res = await fetch("/api/checkout/topup", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ amount }),
      });
      const data = await res.json();
      if (data.url) {
        window.location.href = data.url;
      } else {
        setError(data.error ?? "Could not start checkout.");
        setBusy(null);
      }
    } catch {
      setError("Could not start checkout.");
      setBusy(null);
    }
  }

  return (
    <div>
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        {blocks.map((b) => (
          <button
            key={b}
            className="btn btn-ghost"
            disabled={busy !== null}
            onClick={() => buy(b)}
          >
            {busy === b ? "…" : `$${b}`}
          </button>
        ))}
      </div>
      {error && <p className="err">{error}</p>}
    </div>
  );
}
