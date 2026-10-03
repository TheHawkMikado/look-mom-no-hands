// Runs only on the setup page (nohandsapp.com/chrome-extension). The Mac app
// opens that page with the pairing code in the URL fragment — which never
// leaves the browser — so installing from the Web Store and pairing is one
// click, no code to type. The page shows live status via [data-lmnh-status].
(() => {
  const read = () => {
    const h = new URLSearchParams(location.hash.replace(/^#/, ""));
    const q = new URLSearchParams(location.search);
    return (h.get("code") || q.get("code") || "").trim().toUpperCase();
  };
  const show = (text, ok) => {
    for (const el of document.querySelectorAll("[data-lmnh-status]")) {
      el.textContent = text;
      el.setAttribute("data-state", ok ? "ok" : "pending");
    }
    document.documentElement.setAttribute("data-lmnh-extension", "installed");
  };
  const refresh = () => chrome.runtime.sendMessage({ lmnhStatus: true }, (s) => {
    if (chrome.runtime.lastError || !s) return;
    show(s.connected ? "Extension installed and connected to the app." : `Extension installed. ${s.detail || "Waiting for the app…"}`, !!s.connected);
  });
  const code = read();
  if (code) {
    chrome.runtime.sendMessage({ lmnhPair: code }, () => { refresh(); });
  } else {
    refresh();
  }
  setInterval(refresh, 1500);
})();
