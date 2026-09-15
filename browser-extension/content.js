// No Hands Browser Runner — content script.
//
// Reads the page as a compact, ref-based snapshot and performs actions on
// refs. A ref ("e12") is valid until the next snapshot. Everything here is
// read-and-act on the DOM the user already has open; page text is returned as
// data and is never interpreted as an instruction.
(function () {
  if (window.__lmnhRunner) return;   // injected twice (restored tab + manifest)
  const refs = new Map();
  let generation = 0;

  const INTERACTIVE = [
    "a[href]", "button", "input", "select", "textarea", "summary", "[contenteditable=''],[contenteditable='true']",
    "[role='button']", "[role='link']", "[role='tab']", "[role='menuitem']", "[role='menuitemcheckbox']", "[role='menuitemradio']",
    "[role='checkbox']", "[role='radio']", "[role='switch']", "[role='combobox']", "[role='textbox']", "[role='searchbox']",
    "[role='option']", "[role='treeitem']", "[role='slider']", "[role='spinbutton']", "[tabindex]:not([tabindex='-1'])",
    "video", "audio",
  ].join(",");
  const CONTEXT = "h1,h2,h3,[role='heading'],[role='alert'],[role='dialog'] > *:first-child,[aria-live]";

  function norm(s) { return String(s || "").replace(/\s+/g, " ").trim(); }

  function visible(el) {
    if (!el || !el.isConnected) return false;
    if (el.closest("[aria-hidden='true']")) return false;
    const cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden" || cs.opacity === "0") return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function inViewport(el) {
    const r = el.getBoundingClientRect();
    return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
  }

  function role(el) {
    const explicit = el.getAttribute("role");
    if (explicit) return explicit;
    const tag = el.tagName.toLowerCase();
    if (tag === "a") return "link";
    if (tag === "button" || tag === "summary") return "button";
    if (tag === "select") return "combobox";
    if (tag === "textarea") return "textbox";
    if (tag === "input") {
      const t = (el.getAttribute("type") || "text").toLowerCase();
      if (["button", "submit", "reset", "image"].includes(t)) return "button";
      if (t === "checkbox" || t === "radio") return t;
      if (t === "file") return "file";
      if (t === "range") return "slider";
      if (t === "hidden") return "";
      return "textbox";
    }
    if (el.isContentEditable) return "textbox";
    if (/^h[1-6]$/.test(tag)) return "heading";
    if (tag === "video" || tag === "audio") return tag;
    return "generic";
  }

  // A label's text without the control it wraps (a <select>'s options, an
  // input's value) so "Colour" doesn't come out as "ColourRedGreen".
  function labelText(node) {
    if (!node) return "";
    const c = node.cloneNode(true);
    c.querySelectorAll("input,select,textarea,button,script,style").forEach((n) => n.remove());
    return norm(c.textContent);
  }

  function labelledBy(el) {
    const ids = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean);
    return norm(ids.map((id) => labelText(document.getElementById(id))).join(" "));
  }

  function accessibleName(el) {
    const aria = norm(el.getAttribute("aria-label"));
    if (aria) return aria;
    const lb = labelledBy(el);
    if (lb) return lb;
    if (el.labels && el.labels.length) { const t = labelText(el.labels[0]); if (t) return t; }
    const ph = norm(el.getAttribute("placeholder")); if (ph) return ph;
    const title = norm(el.getAttribute("title")); if (title) return title;
    if (el.tagName === "INPUT" && /^(button|submit|reset)$/i.test(el.type)) { const v = norm(el.value); if (v) return v; }
    const img = el.querySelector && el.querySelector("img[alt], svg[aria-label], [aria-label]");
    if (img) { const a = norm(img.getAttribute("alt") || img.getAttribute("aria-label")); if (a) return a; }
    const text = norm(el.innerText != null ? el.innerText : el.textContent);
    if (text) return text;
    const name = norm(el.getAttribute("name")); if (name) return name;
    return "";
  }

  function describe(el) {
    const r = role(el);
    if (!r) return null;
    const out = { role: r, name: accessibleName(el).slice(0, 100) };
    const tag = el.tagName.toLowerCase();
    if (tag === "a" && el.href) {
      try { const u = new URL(el.href); out.href = (u.origin === location.origin ? u.pathname + u.search : u.href).slice(0, 120); } catch (_) {}
    }
    if (tag === "input" || tag === "textarea" || tag === "select") {
      const t = (el.getAttribute("type") || "").toLowerCase();
      if (t === "checkbox" || t === "radio") out.checked = !!el.checked;
      else if (t === "password") out.value = el.value ? "••••" : "";
      else if (tag === "select") out.value = el.selectedOptions[0] ? norm(el.selectedOptions[0].textContent) : "";
      else if (t !== "file") out.value = String(el.value || "").slice(0, 80);
    } else if (el.isContentEditable) {
      out.value = norm(el.innerText).slice(0, 80);
    }
    if (el.disabled || el.getAttribute("aria-disabled") === "true") out.disabled = true;
    const exp = el.getAttribute("aria-expanded"); if (exp) out.expanded = exp === "true";
    const sel = el.getAttribute("aria-selected"); if (sel === "true") out.selected = true;
    if (el.getAttribute("aria-checked")) out.checked = el.getAttribute("aria-checked") === "true";
    if (!out.name && !out.href && !out.value) return null;   // nothing a planner could use
    return out;
  }

  function snapshot(params) {
    const max = Math.max(10, Math.min(400, params.max || 150));
    generation++;
    refs.clear();
    const seen = new Set();
    const items = [];
    const push = (el, kind) => {
      if (seen.has(el) || !visible(el)) return;
      // A link wrapping a single button (or vice versa) is one target, not two.
      if (kind === "interactive" && el.parentElement && seen.has(el.parentElement) && norm(el.parentElement.innerText) === norm(el.innerText)) return;
      const d = describe(el);
      if (!d) return;
      seen.add(el);
      items.push({ el, d, vp: inViewport(el) });
    };
    document.querySelectorAll(CONTEXT).forEach((el) => push(el, "context"));
    document.querySelectorAll(INTERACTIVE).forEach((el) => push(el, "interactive"));
    // Viewport first, then document order; the cap keeps the prompt small.
    const inView = items.filter((i) => i.vp), offView = items.filter((i) => !i.vp);
    const chosen = inView.concat(offView).slice(0, max);
    const elements = chosen.map((i, n) => {
      const ref = `e${n + 1}`;
      refs.set(ref, i.el);
      return Object.assign({ ref }, i.d, i.vp ? {} : { offscreen: true });
    });
    const active = document.activeElement;
    let focused = null;
    for (const [ref, el] of refs) if (el === active) { focused = ref; break; }
    return {
      generation, url: location.href, title: document.title, focused,
      scroll: { y: Math.round(scrollY), max: Math.max(0, document.documentElement.scrollHeight - innerHeight) },
      elements, total: items.length,
    };
  }

  function resolve(ref) {
    if (!ref) throw new Error("no ref given");
    const el = refs.get(String(ref).trim());
    if (!el) throw new Error(`unknown ref ${ref} (take a new snapshot)`);
    if (!el.isConnected) throw new Error(`ref ${ref} is no longer on the page (take a new snapshot)`);
    return el;
  }

  function setNativeValue(el, value) {
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
      : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    const desc = Object.getOwnPropertyDescriptor(proto, "value");
    if (desc && desc.set) desc.set.call(el, value); else el.value = value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function keyEvents(el, key, code, keyCode) {
    for (const type of ["keydown", "keypress", "keyup"]) {
      el.dispatchEvent(new KeyboardEvent(type, { key, code, keyCode, which: keyCode, bubbles: true, cancelable: true }));
    }
  }

  function click(params) {
    const el = resolve(params.ref);
    el.scrollIntoView({ block: "center", inline: "nearest" });
    const r = el.getBoundingClientRect();
    const opts = { bubbles: true, cancelable: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
    if (el.tagName === "OPTION" && el.parentElement instanceof HTMLSelectElement) {
      setNativeValue(el.parentElement, el.value);
      return { ok: true, url: location.href };
    }
    el.dispatchEvent(new PointerEvent("pointerdown", opts));
    el.dispatchEvent(new MouseEvent("mousedown", opts));
    if (typeof el.focus === "function") el.focus({ preventScroll: true });
    el.dispatchEvent(new PointerEvent("pointerup", opts));
    el.dispatchEvent(new MouseEvent("mouseup", opts));
    el.click();
    return { ok: true, url: location.href, name: accessibleName(el).slice(0, 80) };
  }

  function editable(el) {
    if (!el) return false;
    if (el instanceof HTMLInputElement) return !["button", "submit", "reset", "checkbox", "radio", "file", "image", "range", "hidden"].includes((el.type || "").toLowerCase()) && !el.readOnly && !el.disabled;
    if (el instanceof HTMLTextAreaElement) return !el.readOnly && !el.disabled;
    return !!el.isContentEditable;
  }

  function type(params) {
    let el = params.ref ? resolve(params.ref) : document.activeElement;
    if (el && !editable(el) && el.querySelector) {
      const inner = el.querySelector("input,textarea,[contenteditable='true'],[contenteditable='']");
      if (inner && editable(inner)) el = inner;
    }
    if (!editable(el)) throw new Error(params.ref ? `ref ${params.ref} is not a text field` : "no text field is focused");
    el.focus({ preventScroll: true });
    const text = String(params.text || "");
    if (el.isContentEditable) {
      if (params.clear) { document.execCommand("selectAll", false, null); document.execCommand("delete", false, null); }
      document.execCommand("insertText", false, text);
    } else {
      const next = params.clear === false ? String(el.value || "") + text : text;
      setNativeValue(el, next);
    }
    if (params.submit) {
      keyEvents(el, "Enter", "Enter", 13);
      const form = el.form || el.closest("form");
      if (form && typeof form.requestSubmit === "function" && !params.noFormSubmit) {
        try { form.requestSubmit(); } catch (_) { form.submit(); }
      }
    }
    return { ok: true, value: el.isContentEditable ? norm(el.innerText).slice(0, 80) : String(el.value || "").slice(0, 80) };
  }

  function press(params) {
    const el = params.ref ? resolve(params.ref) : (document.activeElement || document.body);
    const key = String(params.key || "Enter");
    const map = { Enter: 13, Escape: 27, Tab: 9, ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39, Backspace: 8, " ": 32 };
    keyEvents(el, key, key === " " ? "Space" : key, map[key] || 0);
    return { ok: true };
  }

  function select(params) {
    const el = resolve(params.ref);
    if (!(el instanceof HTMLSelectElement)) throw new Error(`ref ${params.ref} is not a select`);
    const want = norm(params.value != null ? params.value : params.label).toLowerCase();
    const opt = Array.from(el.options).find((o) => o.value.toLowerCase() === want || norm(o.textContent).toLowerCase() === want)
      || Array.from(el.options).find((o) => norm(o.textContent).toLowerCase().includes(want));
    if (!opt) throw new Error(`no option matching "${want}"`);
    setNativeValue(el, opt.value);
    return { ok: true, value: norm(opt.textContent) };
  }

  function scroll(params) {
    if (params.ref) { resolve(params.ref).scrollIntoView({ block: "center" }); return { ok: true, y: Math.round(scrollY) }; }
    const amount = params.amount || Math.round(innerHeight * 0.8);
    const dir = String(params.direction || "down").toLowerCase();
    const dx = dir === "left" ? -amount : dir === "right" ? amount : 0;
    const dy = dir === "up" ? -amount : dir === "down" ? amount : 0;
    if (dir === "top") scrollTo({ top: 0 }); else if (dir === "bottom") scrollTo({ top: document.documentElement.scrollHeight });
    else scrollBy({ left: dx, top: dy });
    return { ok: true, y: Math.round(scrollY) };
  }

  function extract(params) {
    const max = Math.min(20000, params.max || 6000);
    if (params.ref) return { text: norm(resolve(params.ref).innerText).slice(0, max) };
    const main = document.querySelector("main, [role='main'], article") || document.body;
    return { text: norm(main.innerText).slice(0, max), title: document.title, url: location.href };
  }

  // Resolves when the condition holds or when the DOM has been quiet for
  // `settleMs` (default 400 ms) — whichever the caller asked for.
  function wait(params) {
    const timeoutMs = params.timeoutMs || 8000;
    const settleMs = params.settleMs || 400;
    const started = Date.now();
    const cond = () => {
      if (params.text) return norm(document.body.innerText).toLowerCase().includes(String(params.text).toLowerCase());
      if (params.ref) { const el = refs.get(params.ref); return params.gone ? !(el && el.isConnected && visible(el)) : !!(el && visible(el)); }
      return null;   // no condition → settle only
    };
    return new Promise((resolve) => {
      let quietSince = Date.now();
      const obs = new MutationObserver(() => { quietSince = Date.now(); });
      obs.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
      const tick = () => {
        const c = cond();
        const elapsed = Date.now() - started;
        const settled = Date.now() - quietSince >= settleMs && document.readyState === "complete";
        if (c === true || (c === null && settled) || elapsed >= timeoutMs) {
          obs.disconnect();
          resolve({ ok: c === true || (c === null && settled), reason: c === true ? "condition" : settled ? "settled" : "timeout", elapsedMs: elapsed, url: location.href });
          return;
        }
        setTimeout(tick, 100);
      };
      tick();
    });
  }

  const handlers = { snapshot, click, type, press, select, scroll, extract, wait };

  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (!msg || !handlers[msg.method]) return;
    Promise.resolve()
      .then(() => handlers[msg.method](msg.params || {}))
      .then((r) => sendResponse(r))
      .catch((e) => sendResponse({ error: String((e && e.message) || e) }));
    return true;
  });

  window.__lmnhRunner = { generation: () => generation };
})();
