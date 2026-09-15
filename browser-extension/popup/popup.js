const $ = (id) => document.getElementById(id);
function render(s) {
  const dot = $("dot");
  dot.className = "dot " + (s.paired ? "on" : s.connected ? "half" : "");
  $("state").textContent = s.paired ? "Connected to the No Hands app" : s.connected ? "Connected, waiting for pairing…" : "Not connected";
  $("err").textContent = s.error || "";
}
chrome.storage.local.get(["lmnh:token", "lmnh:port"], (r) => {
  $("token").value = r["lmnh:token"] || "";
  $("port").value = r["lmnh:port"] || 47831;
});
chrome.runtime.sendMessage({ type: "lmnh:status" }, (s) => render(s || {}));
$("save").addEventListener("click", () => {
  const token = $("token").value.trim();
  const port = parseInt($("port").value, 10) || 47831;
  chrome.storage.local.set({ "lmnh:token": token, "lmnh:port": port }, () => {
    chrome.runtime.sendMessage({ type: "lmnh:reconnect" }, () => {
      setTimeout(() => chrome.runtime.sendMessage({ type: "lmnh:status" }, (s) => render(s || {})), 800);
    });
  });
});
