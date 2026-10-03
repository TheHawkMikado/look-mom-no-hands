"use client";

import { useEffect, useState } from "react";

/**
 * Live install/pair status on the setup page. The extension's content script
 * (pair.js) writes into [data-lmnh-status] and stamps <html data-lmnh-extension>;
 * this component only reads the pairing code out of the URL fragment to tell
 * the person what is about to happen. The fragment never reaches the server.
 */
export function ExtensionPairStatus() {
  const [code, setCode] = useState("");
  useEffect(() => {
    const h = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    setCode((h.get("code") || "").toUpperCase());
  }, []);
  return (
    <div className="panel-card" style={{ marginTop: 20 }}>
      <div className="stat-label">Status</div>
      <p data-lmnh-status style={{ margin: "6px 0 0", fontWeight: 500 }}>
        Extension not detected yet.
      </p>
      {code ? (
        <p className="dim small" style={{ marginTop: 8 }}>
          Pairing code <code>{code}</code> came along from the app. As soon as the extension is
          installed it pairs by itself; nothing to type.
        </p>
      ) : (
        <p className="dim small" style={{ marginTop: 8 }}>
          Opened from the app&rsquo;s Settings, this page pairs the extension automatically. Otherwise
          click the extension&rsquo;s icon and enter the code shown in Settings.
        </p>
      )}
    </div>
  );
}
