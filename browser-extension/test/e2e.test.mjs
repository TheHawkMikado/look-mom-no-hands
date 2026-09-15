// Loads the unpacked extension into Chromium, stands in for the Mac app with a
// loopback WebSocket server, and drives a fixture page through the protocol:
// hello/pairing, snapshot with refs, click, wait, type+submit, select, scroll,
// extract, tabs and navigate.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { WSServer } from "./ws-server.mjs";

const here = path.dirname(new URL(import.meta.url).pathname);
const extDir = path.join(here, "..");
const fixture = fs.readFileSync(path.join(here, "fixtures", "page.html"), "utf8");

class App {
  constructor(server) {
    this.server = server; this.client = null; this.nextId = 1; this.pending = new Map(); this.events = []; this.hello = null;
    server.on("connection", (c) => { this.client = c; });
    server.on("message", (c, raw) => {
      const m = JSON.parse(raw);
      if (m.type === "hello") {
        this.hello = m;
        if (m.token === "123456") { c.send({ type: "welcome" }); }
        else { c.send({ type: "bye" }); setTimeout(() => c.sock.end(), 50); }   // as BrowserBridge does: bye, then cancel
        return;
      }
      if (m.type === "ping") { c.send({ type: "pong" }); return; }
      if (m.event) { this.events.push(m); return; }
      const p = this.pending.get(m.id);
      if (p) { this.pending.delete(m.id); m.error ? p.reject(new Error(m.error)) : p.resolve(m.result); }
    });
  }
  call(method, params = {}) {
    const id = this.nextId++;
    this.client.send({ id, method, params });
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => { if (this.pending.delete(id)) reject(new Error(`timeout on ${method}`)); }, 15000);
    });
  }
  waitFor(pred, ms = 10000) {
    return new Promise((resolve, reject) => {
      const t0 = Date.now();
      const tick = () => { if (pred()) return resolve(); if (Date.now() - t0 > ms) return reject(new Error("waitFor timeout")); setTimeout(tick, 50); };
      tick();
    });
  }
}

test("browser runner protocol end to end", async (t) => {
  const server = new WSServer();
  const port = await server.listen();
  const app = new App(server);
  const userDir = fs.mkdtempSync(path.join(os.tmpdir(), "lmnh-profile-"));
  const context = await chromium.launchPersistentContext(userDir, {
    channel: "chromium", headless: true,
    args: [`--disable-extensions-except=${extDir}`, `--load-extension=${extDir}`],
  });
  t.after(async () => { await context.close(); server.close(); });
  await context.route("https://fixture.test/**", (route) => {
    const u = new URL(route.request().url());
    const body = u.pathname === "/docs" ? "<title>Docs page</title><h1>Documentation</h1><a href='/'>Home</a>" : fixture;
    route.fulfill({ contentType: "text/html", body });
  });

  let [sw] = context.serviceWorkers();
  if (!sw) sw = await context.waitForEvent("serviceworker");
  await sw.evaluate((port) => new Promise((r) => chrome.storage.local.set({ "lmnh:token": "123456", "lmnh:port": port }, r)), port);
  await sw.evaluate(() => connect());
  await app.waitFor(() => app.hello && app.client);
  assert.equal(app.hello.protocol, 1);
  assert.match(app.hello.extension, /^[a-p]{32}$/);
  await app.waitFor(() => true);

  const page = await context.newPage();
  await page.goto("https://fixture.test/");
  await page.bringToFront();

  // --- snapshot with refs ---
  const snap = await app.call("snapshot", { max: 50 });
  assert.equal(snap.title, "Runner Fixture");
  assert.equal(snap.url, "https://fixture.test/");
  const byName = (n) => snap.elements.find((e) => e.name === n);
  assert.equal(byName("Welcome to the fixture").role, "heading");
  assert.equal(byName("Docs").role, "link");
  assert.equal(byName("Docs").href, "/docs");
  assert.equal(byName("Elsewhere").href, "https://elsewhere.test/x");
  assert.equal(byName("Search").role, "textbox");
  assert.equal(byName("Colour").role, "combobox");
  assert.equal(byName("Colour").value, "Red");
  assert.equal(byName("I agree").checked, false);
  assert.equal(byName("Password").value, "••••", "passwords are never sent");
  assert.equal(byName("Hidden button"), undefined, "invisible elements are skipped");
  assert.equal(byName("Bottom link").offscreen, true);
  assert.ok(snap.elements.every((e, i) => e.ref === `e${i + 1}`));
  assert.equal(snap.elements[0].offscreen, undefined, "viewport elements come first");

  // --- click + wait for content ---
  const more = byName("Load more");
  const clicked = await app.call("click", { ref: more.ref });
  assert.equal(clicked.ok, true);
  const waited = await app.call("wait", { text: "Loaded item 3", timeoutMs: 5000 });
  assert.equal(waited.ok, true);
  assert.equal(waited.reason, "condition");

  // --- type + submit (React-safe events) ---
  const typed = await app.call("type", { ref: byName("Search").ref, text: "cats", submit: true });
  assert.equal(typed.ok, true);
  await app.call("wait", { text: "Searched: cats", timeoutMs: 3000 });
  assert.equal(await page.locator("#searched").textContent(), "Searched: cats");
  const events = await page.evaluate(() => window.__events);
  assert.ok(events.some(([k, n, v]) => k === "input" && n === "q" && v === "cats"), "input event fired for frameworks");

  // --- type into the focused element without a ref, and into contenteditable ---
  await app.call("click", { ref: byName("Note").ref });
  const noteTyped = await app.call("type", { text: "hello note" });
  assert.equal(noteTyped.value, "hello note");
  await assert.rejects(app.call("type", { ref: more.ref, text: "x" }), /not a text field/);

  // --- select, checkbox, scroll, extract ---
  assert.equal((await app.call("select", { ref: byName("Colour").ref, label: "green" })).value, "Green");
  await app.call("click", { ref: byName("I agree").ref });
  assert.equal(await page.locator("#agree").isChecked(), true);
  const scrolled = await app.call("scroll", { direction: "down" });
  assert.ok(scrolled.y > 0);
  const extracted = await app.call("extract", { max: 200 });
  assert.match(extracted.text, /Welcome to the fixture/);

  // --- stale ref after a new snapshot ---
  const snap2 = await app.call("snapshot", {});
  assert.ok(snap2.generation > snap.generation);
  await assert.rejects(app.call("click", { ref: "e999" }), /unknown ref/);

  // --- tabs + navigate + navigated event ---
  const tabs = await app.call("tabs");
  assert.ok(tabs.tabs.some((x) => x.url === "https://fixture.test/"));
  const nav = await app.call("navigate", { url: "https://fixture.test/docs", urlContains: "/docs" });
  assert.equal(nav.loaded, true);
  assert.equal(nav.title, "Docs page");
  await app.waitFor(() => app.events.some((e) => e.event === "navigated" && e.url === "https://fixture.test/docs"));
  const docsSnap = await app.call("snapshot", {});
  assert.equal(docsSnap.elements.find((e) => e.name === "Home").href, "/");

  const status = await app.call("status");
  assert.equal(status.paired, true);

  // --- a wrong pairing code is refused and the extension stops retrying ---
  await sw.evaluate(() => new Promise((r) => chrome.storage.local.set({ "lmnh:token": "000000" }, r)));
  await sw.evaluate(() => { socket.close(); });
  await app.waitFor(() => !server.clients.size);
  app.hello = null;
  await sw.evaluate(() => connect());
  await app.waitFor(() => app.hello && app.hello.token === "000000");
  await sw.evaluate(() => new Promise((r) => { const t = () => (rejected ? r() : setTimeout(t, 50)); t(); }));
  const refused = await sw.evaluate(() => status);
  assert.equal(refused.paired, false);
  assert.match(refused.error, /rejected the pairing code/);
  await new Promise((r) => setTimeout(r, 1500));
  assert.equal(server.clients.size, 0, "no reconnect after a refusal");

  // --- the right code again (what the popup's Save does) pairs once more ---
  await sw.evaluate(() => new Promise((r) => chrome.storage.local.set({ "lmnh:token": "123456" }, r)));
  await sw.evaluate(() => { rejected = false; reconnectDelay = 1000; return connect(); });
  await app.waitFor(() => app.hello && app.hello.token === "123456");
  await sw.evaluate(() => new Promise((r) => { const t = () => (status.paired ? r() : setTimeout(t, 50)); t(); }));
  assert.equal((await app.call("status")).paired, true);
});
