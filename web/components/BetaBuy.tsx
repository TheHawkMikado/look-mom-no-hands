"use client";

import { useState } from "react";

/** The beta offer's code box + buy button. The price shown is computed the
 *  same way the server does it (99 minus the code's value), so what you see
 *  is what checkout charges. */
export function BetaBuy({ initialCode = "" }: { initialCode?: string }) {
  const [code, setCode] = useState(initialCode.toUpperCase());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const m = /^BETA(\d{1,2})$/.exec(code.trim().toUpperCase().replace(/[\s-]/g, ""));
  const off = m ? Math.min(99, Math.max(0, Number(m[1]))) : 0;
  const invalid = code.trim() !== "" && (!m || off < 1);
  const price = Math.max(0, 99 - off);

  async function buy() {
    setBusy(true);
    setError("");
    try {
      const res = await fetch("/api/checkout/beta", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: code.trim() || undefined }),
      });
      const data = await res.json();
      if (res.status === 401 && data.next) {
        window.location.href = `/login?next=${encodeURIComponent(data.next)}`;
        return;
      }
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
    <div className="panel-card" style={{ maxWidth: 420, margin: "24px auto 0" }}>
      <div className="stat-label">Beta · lifetime · bring your own key</div>
      <div className="stat-value" style={{ marginTop: 6 }}>
        {price === 0 ? "Free" : `$${price}`}
        {off > 0 && !invalid && (
          <span className="dim" style={{ fontSize: 16, marginLeft: 10, textDecoration: "line-through" }}>$99</span>
        )}
      </div>
      <p className="dim small" style={{ margin: "4px 0 14px" }}>One payment. Yours for life. No subscription.</p>
      <label className="dim small" style={{ display: "block", textAlign: "left" }}>
        Invite code
        <input
          className="field"
          style={{ marginTop: 6 }}
          value={code}
          onChange={(e) => setCode(e.target.value.toUpperCase())}
          placeholder="BETA50"
          autoCapitalize="characters"
          spellCheck={false}
        />
      </label>
      {invalid && <p className="err">That code isn’t valid.</p>}
      <button className="btn btn-primary" disabled={busy || invalid} onClick={buy} style={{ marginTop: 12, width: "100%" }}>
        {busy ? "Opening checkout…" : price === 0 ? "Claim my free beta seat" : `Get the beta for $${price}`}
      </button>
      {error && <p className="err">{error}</p>}
      {price === 0 && !invalid && (
        <p className="dim small" style={{ marginTop: 10 }}>A free seat needs a sign-in so the licence has somewhere to live.</p>
      )}
    </div>
  );
}
