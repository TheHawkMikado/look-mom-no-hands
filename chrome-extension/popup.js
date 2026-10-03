const $ = (id) => document.getElementById(id);
async function refresh() {
  const s = await chrome.storage.local.get({ port: 47831, token: "" });
  $("token").value = s.token || "";
  $("port").value = s.port || 47831;
  chrome.runtime.sendMessage({ lmnhStatus: true }, (status) => {
    if (!status) return;
    $("dot").className = "dot" + (status.connected ? " on" : "");
    $("detail").textContent = status.connected ? "Connected to the app" : status.detail || "Not connected";
  });
}
$("save").addEventListener("click", async () => {
  const token = $("token").value.trim().toUpperCase();
  const port = Number($("port").value) || 47831;
  await chrome.storage.local.set({ token, port });
  chrome.runtime.sendMessage({ lmnhReconnect: true }, () => setTimeout(refresh, 600));
});
refresh();
setInterval(refresh, 1500);
