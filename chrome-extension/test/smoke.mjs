// Loads the unpacked extension into Chromium, plays the Mac app on the
// loopback WebSocket, and drives fixture.html by ref. Exit 1 on any failure.
import { chromium } from "playwright";
import { WebSocketServer } from "ws";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import assert from "node:assert/strict";

const here = path.dirname(new URL(import.meta.url).pathname);
const ext = path.resolve(here, "..");
const PORT = 47831;

// --- the "Mac app": one WS server, one request queue ----------------------
const wss = new WebSocketServer({ host: "127.0.0.1", port: PORT });
let sock = null, nextId = 1; const pending = new Map();
const hellos = [];
let onHello = null;
const hello = new Promise((res) => {
  wss.on("connection", (ws) => {
    sock = ws;
    ws.on("message", (raw) => {
      const m = JSON.parse(raw);
      if (m.type === "hello") { ws.send(JSON.stringify({ type: "hello_ok" })); hellos.push(m); if (onHello) onHello(m); res(m); return; }
      const p = pending.get(m.id); if (!p) return; pending.delete(m.id);
      m.error ? p.reject(new Error(m.error)) : p.resolve(m.result);
    });
  });
});
const call = (method, params = {}) => new Promise((resolve, reject) => {
  const id = nextId++; pending.set(id, { resolve, reject });
  sock.send(JSON.stringify({ id, method, params }));
  setTimeout(() => { if (pending.delete(id)) reject(new Error(`${method} timed out`)); }, 15000);
});

// --- a page to drive -------------------------------------------------------
const PAIR_PAGE = `<!doctype html><html><head><meta charset="utf-8"><title>Setup</title></head>
<body><h1>Setup</h1><p data-lmnh-status>Install the extension to continue.</p></body></html>`;
const srv = http.createServer((q, r) => {
  r.setHeader("content-type", "text/html");
  if (q.url.startsWith("/chrome-extension")) return r.end(PAIR_PAGE);
  r.end(fs.readFileSync(path.join(here, "fixture.html")));
});
await new Promise((r) => srv.listen(0, "127.0.0.1", r));
const fixture = `http://127.0.0.1:${srv.address().port}/`;

// --- Chromium with the extension -------------------------------------------
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "lmnh-ext-"));
const executablePath = process.env.CHROME_PATH || undefined;
const ctx = await chromium.launchPersistentContext(profile, {
  headless: true,
  channel: executablePath ? undefined : "chromium",
  executablePath,
  args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`],
});
let failed = false;
try {
  const page = await ctx.newPage();
  await page.goto(fixture);
  const h = await Promise.race([hello, new Promise((_, rej) => setTimeout(() => rej(new Error("extension never connected")), 20000))]);
  console.log(`✓ extension ${h.version} connected`);

  const ping = await call("ping"); assert.equal(ping.version, h.version);
  const tabs = await call("tabs.list"); assert.ok(tabs.tabs.some((t) => t.url === fixture)); console.log("✓ tabs.list");

  const map = await call("page.map", { maxElements: 50 });
  assert.equal(map.title, "Fixture — Chrome hand");
  const byName = (n) => map.elements.find((e) => e.name === n);
  assert.ok(byName("Pricing")?.href === "/pricing", "link with href");
  assert.equal(byName("Documentation").role, "link", "title used as the name");
  assert.equal(byName("Email address").role, "textbox", "label[for] names the input");
  assert.equal(byName("Email address").placeholder, "you@example.com");
  assert.equal(byName("Plan").role, "combobox"); assert.deepEqual(byName("Plan").options, ["Starter", "Team"]);
  assert.equal(byName("Sign in").role, "button");
  assert.ok(byName("Shadow button"), "shadow DOM walked");
  assert.ok(!byName("Invisible"), "display:none dropped");
  assert.equal(byName("Note").role, "textbox"); assert.equal(byName("Note").value, "old");
  assert.ok(byName("Far away link").inView === false, "offscreen flagged");
  assert.ok(map.headings[0].startsWith("h1 Welcome"));
  assert.ok(map.text.includes("Welcome to the fixture"));
  console.log(`✓ page.map (${map.elements.length} elements)`);

  const f = await call("page.find", { query: "the sign in button" });
  assert.equal(f.matches[0].name, "Sign in"); console.log("✓ page.find");

  await call("page.click", { ref: byName("Click me").ref });
  await call("page.click", { ref: byName("Click me").ref });
  assert.equal(await page.locator("#count").textContent(), "Clicked 2"); console.log("✓ page.click (real handler ran twice)");

  await call("page.click", { ref: byName("Shadow button").ref });
  assert.equal(await page.locator("#out").textContent(), "shadow clicked"); console.log("✓ click inside shadow DOM");

  await call("page.type", { ref: byName("Email address").ref, text: "hawk@example.com" });
  assert.equal(await page.inputValue("#email"), "hawk@example.com");
  await call("page.select", { ref: byName("Plan").ref, value: "team" });
  assert.equal(await page.inputValue("#plan"), "t");
  await call("page.type", { ref: byName("Note").ref, text: "new note" });
  assert.equal(await page.locator("#note").textContent(), "new note");
  console.log("✓ page.type / page.select / contenteditable");

  await call("page.press", { ref: byName("Email address").ref, key: "Enter" });
  assert.equal(await page.locator("#out").textContent(), "submitted:hawk@example.com"); console.log("✓ Enter submits the form");

  const sc = await call("page.scroll", { direction: "bottom" }); assert.ok(sc.y > 1000);
  const map2 = await call("page.map", { maxElements: 50 });
  assert.equal(map2.elements.find((e) => e.name === "Far away link").inView, true); console.log("✓ page.scroll + re-map");

  const html = await call("page.html", { ref: map2.elements.find((e) => e.name === "Sign in").ref });
  assert.ok(html.html.startsWith("<button")); console.log("✓ page.html");
  const txt = await call("page.text"); assert.ok(txt.text.includes("Far away link")); console.log("✓ page.text");

  await assert.rejects(call("page.click", { ref: "e999" }), /unknown ref/); console.log("✓ unknown ref is an error, not a guess");

  const opened = await call("tabs.open", { url: fixture + "?second" });
  assert.ok(opened.tab.url.endsWith("?second"));
  const m3 = await call("page.map"); assert.ok(m3.url.endsWith("?second"), "map follows the active tab");
  await call("tabs.close", { tabId: opened.tab.id }); console.log("✓ tabs.open / tabs.close");

  const shot = await call("page.screenshot"); assert.ok(shot.png_base64.length > 1000); console.log("✓ page.screenshot");

  // Pairing through the setup page: the code rides in the URL fragment, the
  // content script stores it, and the extension reconnects announcing it.
  const paired = new Promise((res) => { onHello = (m) => { if (m.token === "TEST42") res(m); }; });
  const setup = await ctx.newPage();
  await setup.goto(fixture + "chrome-extension#code=test42");
  await Promise.race([paired, new Promise((_, rej) => setTimeout(() => rej(new Error("no reconnect with the pairing code")), 15000))]);
  await setup.waitForFunction(() => document.querySelector("[data-lmnh-status]")?.getAttribute("data-state") === "ok", null, { timeout: 10000 });
  assert.equal(await setup.getAttribute("html", "data-lmnh-extension"), "installed");
  console.log("✓ pairing via the setup page (fragment code → storage → reconnect)");
  await setup.close();
  console.log("\nALL GREEN");
} catch (e) {
  failed = true; console.error("\n✗", e.message);
} finally {
  await ctx.close(); srv.close(); wss.close(); fs.rmSync(profile, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
