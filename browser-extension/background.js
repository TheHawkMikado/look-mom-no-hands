// No Hands Browser Runner — service worker.
//
// Dials the Mac app's loopback WebSocket (BrowserBridge.swift), pairs with the
// code shown in the app, then answers requests: read the active tab as a
// ref-based snapshot, click / type / select / scroll by ref, wait for the page
// to settle, list and switch tabs, navigate. It never decides anything: the
// Mac app plans and gates, this executes. Page content only ever flows back as
// data in a result; nothing on a page can issue a request.

const DEFAULT_PORT = 47831;
const PROTOCOL_VERSION = 1;

let socket = null;
let rejected = false;
let reconnectDelay = 1000;
let keepalive = null;
let status = { connected: false, paired: false, error: null, port: DEFAULT_PORT };

function readSettings() {
  return new Promise((resolve) =>
    chrome.storage.local.get(["lmnh:token", "lmnh:port"], (r) =>
      resolve({ token: r["lmnh:token"] || "", port: Number(r["lmnh:port"]) || DEFAULT_PORT })
    )
  );
}

function setStatus(patch) {
  status = { ...status, ...patch };
  chrome.storage.session?.set({ "lmnh:status": status }).catch?.(() => {});
  chrome.action.setBadgeText({ text: status.paired ? "on" : "" });
  chrome.action.setBadgeBackgroundColor({ color: "#2e7d32" });
}

function send(obj) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(obj));
}

async function connect() {
  if (rejected) return;
  if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
  const { token, port } = await readSettings();
  if (!token) { setStatus({ connected: false, paired: false, error: "Enter the pairing code from the No Hands app.", port }); return; }
  let ws;
  try { ws = new WebSocket(`ws://127.0.0.1:${port}/lmnh`); } catch (e) { scheduleReconnect(); return; }
  socket = ws;
  ws.onopen = () => {
    reconnectDelay = 1000;
    setStatus({ connected: true, error: null, port });
    send({ type: "hello", token, extension: chrome.runtime.id, version: chrome.runtime.getManifest().version, protocol: PROTOCOL_VERSION });
    clearInterval(keepalive);
    // Chrome extends a service worker's life while WebSocket traffic flows; a
    // ping every 20 s keeps this worker (and the connection) alive.
    keepalive = setInterval(() => send({ type: "ping" }), 20000);
  };
  ws.onmessage = (ev) => { handle(ev.data).catch((e) => console.warn("[lmnh] handler failed", e)); };
  ws.onclose = () => {
    clearInterval(keepalive);
    setStatus({ connected: false, paired: false, error: rejected ? status.error : null });
    socket = null;
    if (!rejected) scheduleReconnect();
  };
  ws.onerror = () => { /* onclose follows */ };
}

function scheduleReconnect() {
  setTimeout(connect, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, 30000);
}

async function handle(raw) {
  let msg;
  try { msg = JSON.parse(raw); } catch (_) { return; }
  if (msg.type === "welcome") { setStatus({ paired: true, error: null }); return; }
  if (msg.type === "bye") {
    // Wrong pairing code: stop reconnecting until the user saves a new one.
    rejected = true;
    setStatus({ paired: false, error: "The app rejected the pairing code. Check it in Look Ma, No Hands › Agents › Browser." });
    try { socket && socket.close(); } catch (_) {}
    return;
  }
  if (msg.type === "pong" || msg.type === "ping") { if (msg.type === "ping") send({ type: "pong" }); return; }
  if (typeof msg.id === "undefined" || !msg.method) return;
  try {
    const result = await dispatch(msg.method, msg.params || {});
    send({ id: msg.id, result });
  } catch (e) {
    send({ id: msg.id, error: String((e && e.message) || e) });
  }
}

// --- tab helpers ----------------------------------------------------------

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (tab) return tab;
  const [any] = await chrome.tabs.query({ active: true });
  if (!any) throw new Error("no active tab");
  return any;
}

async function resolveTab(params) {
  if (params.tabId) {
    const t = await chrome.tabs.get(Number(params.tabId));
    if (!t) throw new Error(`no tab ${params.tabId}`);
    return t;
  }
  return activeTab();
}

function tabInfo(t) {
  return { tabId: t.id, windowId: t.windowId, title: t.title || "", url: t.url || "", active: !!t.active, status: t.status || "" };
}

function isScriptable(url) {
  return /^(https?|file):/i.test(url || "");
}

// Ask the content script; inject it first if this tab was open before the
// extension loaded (or was restored) and has no script yet.
async function askPage(tab, message) {
  if (!isScriptable(tab.url)) throw new Error(`cannot act on ${tab.url || "this tab"} (not a web page)`);
  const trySend = () => new Promise((resolve, reject) =>
    chrome.tabs.sendMessage(tab.id, message, (res) => {
      const err = chrome.runtime.lastError;
      if (err) reject(new Error(err.message)); else resolve(res);
    }));
  let res;
  try {
    res = await trySend();
  } catch (e) {
    if (!/Receiving end does not exist|Could not establish connection/i.test(e.message)) throw e;
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
    res = await trySend();
  }
  // The content script reports its own failures as { error } (a thrown error
  // cannot cross the message channel); surface them as a failed request.
  if (res && res.error) throw new Error(res.error);
  if (res === undefined) throw new Error("the page did not answer (reload it and retry)");
  return res;
}

function waitForTabLoad(tabId, { urlContains, timeoutMs }) {
  return new Promise((resolve) => {
    const started = Date.now();
    let done = false;
    const finish = (how) => {
      if (done) return;
      done = true;
      chrome.tabs.onUpdated.removeListener(listener);
      clearInterval(poll);
      resolve(how);
    };
    const check = async () => {
      let t;
      try { t = await chrome.tabs.get(tabId); } catch (_) { return finish("gone"); }
      const urlOk = !urlContains || (t.url || "").toLowerCase().includes(String(urlContains).toLowerCase());
      if (t.status === "complete" && urlOk) return finish("loaded");
      if (Date.now() - started > timeoutMs) return finish("timeout");
    };
    const listener = (id) => { if (id === tabId) check(); };
    chrome.tabs.onUpdated.addListener(listener);
    const poll = setInterval(check, 250);
    check();
  });
}

// --- request dispatch ------------------------------------------------------

async function dispatch(method, params) {
  switch (method) {
    case "tabs": {
      const tabs = await chrome.tabs.query({});
      return { tabs: tabs.map(tabInfo) };
    }
    case "active_tab": return tabInfo(await activeTab());
    case "activate_tab": {
      const t = await chrome.tabs.get(Number(params.tabId));
      await chrome.tabs.update(t.id, { active: true });
      await chrome.windows.update(t.windowId, { focused: true });
      return tabInfo(await chrome.tabs.get(t.id));
    }
    case "navigate": {
      if (!params.url) throw new Error("navigate needs a url");
      const tab = params.newTab ? await chrome.tabs.create({ url: params.url }) : await chrome.tabs.update((await resolveTab(params)).id, { url: params.url });
      const how = await waitForTabLoad(tab.id, { urlContains: params.urlContains || "", timeoutMs: params.timeoutMs || 15000 });
      return { ...tabInfo(await chrome.tabs.get(tab.id)), loaded: how === "loaded" };
    }
    case "wait": {
      const tab = await resolveTab(params);
      const timeoutMs = params.timeoutMs || 10000;
      const started = Date.now();
      if (params.navigation || params.urlContains) {
        const how = await waitForTabLoad(tab.id, { urlContains: params.urlContains || "", timeoutMs });
        if (how !== "loaded") return { ok: false, reason: how, elapsedMs: Date.now() - started, ...tabInfo(await chrome.tabs.get(tab.id).catch(() => tab)) };
      }
      const remaining = Math.max(500, timeoutMs - (Date.now() - started));
      const res = await askPage(await chrome.tabs.get(tab.id), { method: "wait", params: { ...params, timeoutMs: remaining } });
      return { ...res, ...tabInfo(await chrome.tabs.get(tab.id)) };
    }
    case "snapshot": case "click": case "type": case "select": case "scroll": case "extract": case "press": {
      const tab = await resolveTab(params);
      const res = await askPage(tab, { method, params });
      return { ...res, tabId: tab.id };
    }
    case "status": return { ...status, protocol: PROTOCOL_VERSION };
    default: throw new Error(`unknown method ${method}`);
  }
}

// Tell the app when a tab finishes loading; it can skip a wait round-trip.
chrome.tabs.onUpdated.addListener((tabId, info, tab) => {
  if (info.status === "complete" && tab.active) send({ event: "navigated", ...tabInfo(tab) });
});

// Popup → worker: settings changed or a manual reconnect.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "lmnh:reconnect") {
    if (socket) { try { socket.close(); } catch (_) {} socket = null; }
    rejected = false;
    reconnectDelay = 1000;
    connect().then(() => sendResponse({ ok: true }));
    return true;
  }
  if (msg && msg.type === "lmnh:status") { sendResponse(status); }
});

chrome.alarms.create("lmnh-reconnect", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((a) => { if (a.name === "lmnh-reconnect") connect(); });
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
connect();
