// Background service worker: one WebSocket to the Mac app on localhost, and a
// request router that runs each request against the right tab. The app is the
// only client: the socket is loopback-only and the hello carries the pairing
// code the user typed into the popup. Nothing here talks to the internet.

const DEFAULT_PORT = 47831;
const VERSION = chrome.runtime.getManifest().version;

let socket = null;
let backoff = 1000;
let status = { connected: false, detail: "starting", port: DEFAULT_PORT };

async function settings() {
  const s = await chrome.storage.local.get({ port: DEFAULT_PORT, token: "" });
  s.port = Number(s.port) || DEFAULT_PORT;
  return s;
}

function setStatus(connected, detail) {
  status = { ...status, connected, detail };
  chrome.storage.session?.set({ status }).catch(() => {});
  chrome.action.setBadgeText({ text: connected ? "" : "·" }).catch(() => {});
  chrome.action.setBadgeBackgroundColor({ color: connected ? "#2e7d32" : "#9e9e9e" }).catch(() => {});
}

async function connect() {
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  const { port, token } = await settings();
  status.port = port;
  let ws;
  try {
    ws = new WebSocket(`ws://127.0.0.1:${port}/`);
  } catch (e) {
    setStatus(false, `cannot open socket: ${e.message}`);
    scheduleReconnect();
    return;
  }
  socket = ws;
  ws.onopen = () => {
    backoff = 1000;
    ws.send(JSON.stringify({ type: "hello", token, version: VERSION, ua: navigator.userAgent }));
    setStatus(true, "connected to the app");
  };
  ws.onmessage = (ev) => handleFrame(ws, ev.data);
  ws.onerror = () => {};
  ws.onclose = (ev) => {
    if (socket === ws) socket = null;
    setStatus(false, ev.reason || "app not running");
    scheduleReconnect();
  };
}

function scheduleReconnect() {
  setTimeout(connect, backoff);
  backoff = Math.min(backoff * 2, 30000);
}

async function handleFrame(ws, raw) {
  let msg;
  try { msg = JSON.parse(raw); } catch { return; }
  if (msg.type === "unauthorized") {
    setStatus(false, "pairing code rejected — open the popup and enter the code from the app's Settings");
    return;
  }
  if (msg.type === "pong" || msg.type === "hello_ok") return;
  if (msg.id === undefined || !msg.method) return;
  try {
    const result = await dispatch(msg.method, msg.params || {});
    ws.send(JSON.stringify({ id: msg.id, result }));
  } catch (e) {
    ws.send(JSON.stringify({ id: msg.id, error: String(e && e.message ? e.message : e) }));
  }
}

// ----------------------------------------------------------------- tabs ----

async function targetTab(params) {
  if (params.tabId) {
    const t = await chrome.tabs.get(Number(params.tabId));
    if (!t) throw new Error(`no tab ${params.tabId}`);
    return t;
  }
  const [active] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (active) return active;
  const [any] = await chrome.tabs.query({ active: true });
  if (!any) throw new Error("no active tab");
  return any;
}

function tabInfo(t) {
  return { id: t.id, windowId: t.windowId, active: !!t.active, title: t.title || "", url: t.url || "" };
}

function isScriptable(url) {
  return /^(https?|file):/.test(url || "");
}

async function inPage(params, method, args) {
  const tab = await targetTab(params);
  if (!isScriptable(tab.url)) throw new Error(`cannot read ${tab.url || "this tab"} (browser-internal page)`);
  try {
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
  } catch (e) {
    throw new Error(`cannot inject into ${tab.url}: ${e.message}`);
  }
  const reply = await chrome.tabs.sendMessage(tab.id, { lmnh: true, method, args });
  if (reply && reply.error) throw new Error(reply.error);
  return { tab: tabInfo(tab), ...(reply && reply.result !== undefined ? reply.result : {}) };
}

async function waitForLoad(tabId, timeoutMs = 15000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const t = await chrome.tabs.get(tabId);
    if (t.status === "complete") return t;
    await new Promise((r) => setTimeout(r, 150));
  }
  return chrome.tabs.get(tabId);
}

async function dispatch(method, params) {
  switch (method) {
    case "ping":
      return { version: VERSION };
    case "tabs.list": {
      const tabs = await chrome.tabs.query({});
      return { tabs: tabs.map(tabInfo) };
    }
    case "tabs.activate": {
      const t = await targetTab(params);
      await chrome.tabs.update(t.id, { active: true });
      await chrome.windows.update(t.windowId, { focused: true });
      return { tab: tabInfo(await chrome.tabs.get(t.id)) };
    }
    case "tabs.open": {
      if (!params.url) throw new Error("url required");
      const t = await chrome.tabs.create({ url: params.url, active: params.background ? false : true });
      return { tab: tabInfo(await waitForLoad(t.id)) };
    }
    case "tabs.navigate": {
      if (!params.url) throw new Error("url required");
      const t = await targetTab(params);
      await chrome.tabs.update(t.id, { url: params.url });
      return { tab: tabInfo(await waitForLoad(t.id)) };
    }
    case "tabs.back": {
      const t = await targetTab(params);
      await chrome.tabs.goBack(t.id);
      return { tab: tabInfo(await waitForLoad(t.id)) };
    }
    case "tabs.close": {
      const t = await targetTab(params);
      await chrome.tabs.remove(t.id);
      return { closed: t.id };
    }
    case "page.screenshot": {
      const t = await targetTab(params);
      const dataUrl = await chrome.tabs.captureVisibleTab(t.windowId, { format: "png" });
      return { tab: tabInfo(t), png_base64: dataUrl.replace(/^data:image\/png;base64,/, "") };
    }
    case "page.map":
    case "page.text":
    case "page.html":
    case "page.find":
    case "page.click":
    case "page.type":
    case "page.select":
    case "page.scroll":
    case "page.hover":
    case "page.press":
    case "page.focus": {
      const r = await inPage(params, method, params);
      // A click that navigates: give the new document a moment so the next
      // page.map sees it instead of the page that just went away.
      if (method === "page.click" || method === "page.press" || (method === "page.type" && params.submit)) {
        await new Promise((res) => setTimeout(res, 350));
        const t = await waitForLoad(r.tab.id, 8000);
        r.tab = tabInfo(t);
      }
      return r;
    }
    default:
      throw new Error(`unknown method ${method}`);
  }
}

// ------------------------------------------------------------- lifecycle ----

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg && msg.lmnhStatus) { reply(status); return true; }
  if (msg && typeof msg.lmnhPair === "string") {
    // The setup page handed us the pairing code (pair.js); storing it makes
    // the storage listener below reconnect with it.
    const token = msg.lmnhPair.trim().toUpperCase();
    if (token) chrome.storage.local.set({ token }).then(() => reply({ ok: true }));
    else reply({ ok: false });
    return true;
  }
  if (msg && msg.lmnhReconnect) {
    if (socket) { try { socket.close(); } catch {} socket = null; }
    backoff = 1000;
    connect().then(() => reply(status));
    return true;
  }
  return false;
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local") return;
  if (changes.port || changes.token) {
    if (socket) { try { socket.close(); } catch {} socket = null; }
    backoff = 1000;
    connect();
  }
});

// The service worker can be put to sleep; an alarm wakes it and the open
// socket keeps it alive while the app is around.
chrome.alarms.create("lmnh-keepalive", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((a) => { if (a.name === "lmnh-keepalive") connect(); });
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(async () => {
  connect();
  // The setup page is usually already open when the user clicks "Add to
  // Chrome"; content scripts don't reach existing tabs, so inject pair.js
  // there now and pairing completes without a reload.
  try {
    const tabs = await chrome.tabs.query({ url: ["https://nohandsapp.com/chrome-extension*", "https://www.nohandsapp.com/chrome-extension*", "http://127.0.0.1/chrome-extension*", "http://localhost/chrome-extension*"] });
    for (const t of tabs) chrome.scripting.executeScript({ target: { tabId: t.id }, files: ["pair.js"] }).catch(() => {});
  } catch {}
});
connect();
