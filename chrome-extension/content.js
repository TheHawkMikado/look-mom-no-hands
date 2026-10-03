// Content script: the page as a numbered map, and actions by number.
//
// page.map walks the live DOM (open shadow roots and same-origin frames
// included) and hands back every interactive element plus headings and a text
// excerpt, each with a ref like "e12". The refs stay valid until the next map
// or until the element leaves the document. Actions look the ref up and act on
// the real element with real events, so React/Vue/etc. see what a user does.
(() => {
  if (window.__lmnh) return;
  const L = (window.__lmnh = { refs: new Map(), gen: 0 });

  const INTERACTIVE = "a[href],button,input,select,textarea,summary,[role],[contenteditable],[onclick],[tabindex],label,img[alt],video,audio,h1,h2,h3,h4";
  const IMPLICIT_ROLE = {
    a: "link", button: "button", select: "combobox", textarea: "textbox", summary: "button",
    h1: "heading", h2: "heading", h3: "heading", h4: "heading", img: "image", video: "video", audio: "audio",
    option: "option", label: "label", nav: "navigation", main: "main", form: "form",
  };
  const INPUT_ROLE = {
    button: "button", submit: "button", reset: "button", image: "button", checkbox: "checkbox", radio: "radio",
    range: "slider", file: "file", search: "searchbox", number: "spinbutton", date: "date", time: "time",
    color: "color", hidden: null,
  };

  const text = (s) => (s || "").replace(/\s+/g, " ").trim();
  const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);

  function role(el) {
    const explicit = text(el.getAttribute("role"));
    if (explicit) return explicit.split(" ")[0];
    const tag = el.tagName.toLowerCase();
    if (tag === "input") {
      const t = (el.getAttribute("type") || "text").toLowerCase();
      if (t in INPUT_ROLE) return INPUT_ROLE[t];
      return "textbox";
    }
    if (el.isContentEditable && el.getAttribute("contenteditable") !== "false") return "textbox";
    return IMPLICIT_ROLE[tag] || (el.hasAttribute("onclick") || el.hasAttribute("tabindex") ? "clickable" : "");
  }

  function labelledBy(el) {
    const ids = text(el.getAttribute("aria-labelledby"));
    if (!ids) return "";
    return text(ids.split(" ").map((id) => el.ownerDocument.getElementById(id)?.innerText || "").join(" "));
  }

  function name(el) {
    const candidates = [
      text(el.getAttribute("aria-label")),
      labelledBy(el),
      el.labels && el.labels.length ? text(el.labels[0].innerText) : "",
      text(el.getAttribute("alt")),
      text(el.getAttribute("title")),
      text(el.getAttribute("placeholder")),
      text(el.innerText),
      text(el.getAttribute("value")),
      text(el.getAttribute("name")),
      el.querySelector && el.querySelector("img[alt]") ? text(el.querySelector("img[alt]").getAttribute("alt")) : "",
    ];
    const n = candidates.find((c) => c);
    return clip(n || "", 80);
  }

  function visible(el) {
    if (el.getAttribute("aria-hidden") === "true") return false;
    const style = el.ownerDocument.defaultView.getComputedStyle(el);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  function inViewport(el) {
    const r = el.getBoundingClientRect();
    const w = el.ownerDocument.defaultView;
    return r.bottom > 0 && r.right > 0 && r.top < w.innerHeight && r.left < w.innerWidth;
  }

  function state(el) {
    const s = [];
    if (el.disabled || el.getAttribute("aria-disabled") === "true") s.push("disabled");
    if (el.checked || el.getAttribute("aria-checked") === "true") s.push("checked");
    if (el.getAttribute("aria-expanded") === "true") s.push("expanded");
    if (el.getAttribute("aria-selected") === "true" || el.selected) s.push("selected");
    if (el.required || el.getAttribute("aria-required") === "true") s.push("required");
    if (el === el.ownerDocument.activeElement) s.push("focused");
    return s;
  }

  // Walk the document, open shadow roots and same-origin frames.
  function* walk(root, framePrefix) {
    const all = root.querySelectorAll("*");
    for (const el of all) {
      if (el.matches(INTERACTIVE)) yield { el, framePrefix };
      if (el.shadowRoot) yield* walk(el.shadowRoot, framePrefix);
      if (el.tagName === "IFRAME" || el.tagName === "FRAME") {
        let doc = null;
        try { doc = el.contentDocument; } catch { doc = null; }
        if (doc && doc.body) yield* walk(doc, (framePrefix ? framePrefix + ">" : "") + "frame");
      }
    }
  }

  function describe(el, framePrefix) {
    const r = role(el);
    if (r === null) return null;
    if (!visible(el)) return null;
    const tag = el.tagName.toLowerCase();
    const entry = { role: r || tag, name: name(el) };
    if (!entry.name && !["textbox", "searchbox", "combobox", "checkbox", "radio", "image"].includes(entry.role)) {
      // An unlabeled div with a tabindex is noise; keep only real controls.
      if (!["a", "button", "input", "select", "textarea"].includes(tag)) return null;
    }
    if (tag === "a") {
      const href = el.getAttribute("href") || "";
      if (href && !href.startsWith("javascript:")) entry.href = clip(href, 120);
    }
    if (tag === "input" || tag === "textarea" || tag === "select") {
      if (tag !== "input" || !["password"].includes((el.type || "").toLowerCase())) {
        const v = tag === "select" ? (el.selectedOptions[0]?.text || "") : el.value || "";
        if (v) entry.value = clip(text(v), 60);
      }
      const ph = text(el.getAttribute("placeholder"));
      if (ph && ph !== entry.name) entry.placeholder = clip(ph, 60);
      if (tag === "select") entry.options = Array.from(el.options).slice(0, 20).map((o) => clip(text(o.text), 40));
    } else if (el.isContentEditable) {
      const v = text(el.innerText);
      if (v) entry.value = clip(v, 60);
    }
    const st = state(el);
    if (st.length) entry.state = st;
    entry.inView = inViewport(el);
    if (framePrefix) entry.frame = framePrefix;
    const b = el.getBoundingClientRect();
    entry.box = [Math.round(b.left), Math.round(b.top), Math.round(b.width), Math.round(b.height)];
    return entry;
  }

  function buildMap(args) {
    const max = Math.max(10, Math.min(400, Number(args.maxElements) || 150));
    L.refs = new Map();
    L.gen += 1;
    const seen = new Set();
    const entries = [];
    for (const { el, framePrefix } of walk(document, "")) {
      if (seen.has(el)) continue;
      seen.add(el);
      // A label wrapping its input duplicates the input; keep the control.
      if (el.tagName === "LABEL" && el.control) continue;
      const d = describe(el, framePrefix);
      if (d) entries.push({ el, d });
    }
    // Headings and in-view elements first, then the rest in document order,
    // so a capped map still shows what the user is looking at.
    const prioritized = entries
      .map((e, i) => ({ ...e, i }))
      .sort((a, b) => (Number(b.d.inView) - Number(a.d.inView)) || a.i - b.i);
    const kept = prioritized.slice(0, max).sort((a, b) => a.i - b.i);
    const elements = kept.map((e, n) => {
      const ref = `e${n + 1}`;
      L.refs.set(ref, e.el);
      return { ref, ...e.d };
    });
    const headings = Array.from(document.querySelectorAll("h1,h2,h3")).filter(visible)
      .slice(0, 25).map((h) => `${h.tagName.toLowerCase()} ${clip(text(h.innerText), 90)}`);
    const body = text(document.body ? document.body.innerText : "");
    return {
      url: location.href,
      title: document.title,
      gen: L.gen,
      total: entries.length,
      elements,
      headings,
      text: clip(body, Number(args.textChars) || 1500),
      scroll: { y: Math.round(window.scrollY), height: Math.round(document.documentElement.scrollHeight), viewport: Math.round(window.innerHeight) },
    };
  }

  function lookup(ref) {
    if (!ref) throw new Error("ref required (e.g. e12)");
    const key = String(ref).toLowerCase().replace(/[\[\]\s]/g, "");
    const el = L.refs.get(key);
    if (!el) throw new Error(`unknown ref ${key} — read the page (page.map) first`);
    if (!el.isConnected) throw new Error(`${key} is no longer on the page — read the page again`);
    return el;
  }

  function score(entry, q) {
    const n = (entry.name || "").toLowerCase();
    const h = (entry.href || "").toLowerCase();
    const v = (entry.value || entry.placeholder || "").toLowerCase();
    if (!n && !h && !v) return 0;
    if (n === q) return 100;
    let s = 0;
    if (n.startsWith(q)) s = Math.max(s, 85);
    if (n.includes(q)) s = Math.max(s, 70);
    if (v.includes(q)) s = Math.max(s, 60);
    if (h.includes(q)) s = Math.max(s, 40);
    const qt = q.split(/\W+/).filter((t) => t.length > 1);
    if (qt.length) {
      const hits = qt.filter((t) => n.includes(t) || v.includes(t) || h.includes(t)).length;
      s = Math.max(s, Math.round((hits / qt.length) * 65));
    }
    // "the sign in button": the role word in the query is a hint, not a name.
    if (qt.includes(entry.role)) s += 5;
    return s;
  }

  const STOP = /\b(the|a|an|button|link|field|box|input|icon|tab|menu|item|on|in|at|to|please|click|press|tap)\b/g;

  function find(args) {
    const map = L.refs.size ? null : buildMap(args);
    const q = text(String(args.query || "")).toLowerCase().replace(STOP, " ").replace(/\s+/g, " ").trim();
    if (!q) throw new Error("query required");
    const entries = map ? map.elements : Array.from(L.refs.entries()).map(([ref, el]) => ({ ref, ...(describe(el, "") || {}) }));
    const ranked = entries
      .filter((e) => e.role)
      .map((e) => ({ ref: e.ref, role: e.role, name: e.name, score: score(e, q) }))
      .filter((e) => e.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, 8);
    return { query: q, matches: ranked };
  }

  function realClick(el) {
    el.scrollIntoView({ block: "center", inline: "center" });
    const r = el.getBoundingClientRect();
    const x = r.left + r.width / 2, y = r.top + r.height / 2;
    const opts = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, button: 0, buttons: 1, view: el.ownerDocument.defaultView };
    for (const type of ["pointerover", "mouseover", "pointerdown", "mousedown"]) {
      el.dispatchEvent(type.startsWith("pointer") ? new PointerEvent(type, { ...opts, pointerId: 1, pointerType: "mouse", isPrimary: true }) : new MouseEvent(type, opts));
    }
    if (typeof el.focus === "function") el.focus({ preventScroll: true });
    for (const type of ["pointerup", "mouseup"]) {
      el.dispatchEvent(type.startsWith("pointer") ? new PointerEvent(type, { ...opts, pointerId: 1, pointerType: "mouse", isPrimary: true, buttons: 0 }) : new MouseEvent(type, { ...opts, buttons: 0 }));
    }
    if (typeof el.click === "function") el.click();
    else el.dispatchEvent(new MouseEvent("click", opts));
  }

  function setNativeValue(el, value) {
    const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype
      : el.tagName === "SELECT" ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
    if (setter) setter.call(el, value); else el.value = value;
  }

  function typeInto(el, value, clear) {
    el.focus({ preventScroll: true });
    if (el.isContentEditable) {
      if (clear) {
        el.ownerDocument.getSelection()?.selectAllChildren(el);
        el.ownerDocument.execCommand("delete");
      }
      if (!el.ownerDocument.execCommand("insertText", false, value)) {
        el.textContent = (clear ? "" : el.textContent) + value;
        el.dispatchEvent(new InputEvent("input", { bubbles: true, data: value, inputType: "insertText" }));
      }
      return;
    }
    const next = clear ? value : (el.value || "") + value;
    el.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, key: value.slice(-1) || "a" }));
    setNativeValue(el, next);
    el.dispatchEvent(new InputEvent("input", { bubbles: true, data: value, inputType: "insertText" }));
    el.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true, key: value.slice(-1) || "a" }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function pressKey(el, key) {
    const KEYS = { enter: ["Enter", 13], escape: ["Escape", 27], esc: ["Escape", 27], tab: ["Tab", 9], backspace: ["Backspace", 8], space: [" ", 32], arrowdown: ["ArrowDown", 40], arrowup: ["ArrowUp", 38], down: ["ArrowDown", 40], up: ["ArrowUp", 38] };
    const k = KEYS[String(key).toLowerCase()] || [key, 0];
    const init = { bubbles: true, cancelable: true, key: k[0], code: k[0] === " " ? "Space" : k[0], keyCode: k[1], which: k[1] };
    const target = el || document.activeElement || document.body;
    const notCancelled = target.dispatchEvent(new KeyboardEvent("keydown", init));
    target.dispatchEvent(new KeyboardEvent("keypress", init));
    target.dispatchEvent(new KeyboardEvent("keyup", init));
    // Enter on a form field submits like the real key would when nothing
    // intercepted it; synthetic keydowns alone never reach the browser's
    // default action.
    if (k[0] === "Enter" && notCancelled && target.form && typeof target.form.requestSubmit === "function") {
      target.form.requestSubmit();
    }
  }

  function editable(el) {
    const tag = el.tagName;
    return el.isContentEditable || tag === "TEXTAREA" || (tag === "INPUT" && !["button", "submit", "reset", "checkbox", "radio", "file", "image"].includes((el.type || "").toLowerCase())) || tag === "SELECT";
  }

  const handlers = {
    "page.map": (a) => buildMap(a),
    "page.text": (a) => ({ url: location.href, title: document.title, text: clip(text(document.body?.innerText || ""), Number(a.maxChars) || 12000) }),
    "page.html": (a) => {
      const el = a.ref ? lookup(a.ref) : document.documentElement;
      return { ref: a.ref || null, html: clip(el.outerHTML, Number(a.maxChars) || 20000), length: el.outerHTML.length };
    },
    "page.find": (a) => find(a),
    "page.click": (a) => {
      const el = lookup(a.ref);
      realClick(el);
      return { clicked: a.ref, role: role(el), name: name(el) };
    },
    "page.hover": (a) => {
      const el = lookup(a.ref);
      el.scrollIntoView({ block: "center" });
      const r = el.getBoundingClientRect();
      const opts = { bubbles: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
      el.dispatchEvent(new PointerEvent("pointerover", { ...opts, pointerType: "mouse" }));
      el.dispatchEvent(new MouseEvent("mouseover", opts));
      el.dispatchEvent(new MouseEvent("mouseenter", opts));
      el.dispatchEvent(new MouseEvent("mousemove", opts));
      return { hovered: a.ref };
    },
    "page.focus": (a) => { const el = lookup(a.ref); el.focus(); return { focused: a.ref }; },
    "page.type": (a) => {
      let el = a.ref ? lookup(a.ref) : document.activeElement;
      if (el && el.tagName === "LABEL" && el.control) el = el.control;
      if (!el || !editable(el)) throw new Error(a.ref ? `${a.ref} is not a text field` : "nothing editable is focused — pass the field's ref");
      if (el.tagName === "SELECT") throw new Error("use page.select for a dropdown");
      typeInto(el, String(a.text ?? ""), a.clear !== false);
      if (a.submit) pressKey(el, "Enter");
      return { typed: String(a.text ?? "").length, ref: a.ref || null, submitted: !!a.submit };
    },
    "page.select": (a) => {
      const el = lookup(a.ref);
      if (el.tagName !== "SELECT") throw new Error(`${a.ref} is not a dropdown`);
      const want = text(String(a.value ?? "")).toLowerCase();
      const opt = Array.from(el.options).find((o) => text(o.text).toLowerCase() === want || o.value.toLowerCase() === want)
        || Array.from(el.options).find((o) => text(o.text).toLowerCase().includes(want));
      if (!opt) throw new Error(`no option matching "${a.value}"`);
      setNativeValue(el, opt.value);
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
      return { selected: text(opt.text) };
    },
    "page.scroll": (a) => {
      if (a.ref) { lookup(a.ref).scrollIntoView({ block: "center", behavior: "instant" }); }
      else {
        const dir = String(a.direction || "down").toLowerCase();
        const step = window.innerHeight * 0.8;
        if (dir === "top") window.scrollTo(0, 0);
        else if (dir === "bottom") window.scrollTo(0, document.documentElement.scrollHeight);
        else if (dir === "up") window.scrollBy(0, -step);
        else if (dir === "left") window.scrollBy(-window.innerWidth * 0.8, 0);
        else if (dir === "right") window.scrollBy(window.innerWidth * 0.8, 0);
        else window.scrollBy(0, step);
      }
      return { y: Math.round(window.scrollY), height: Math.round(document.documentElement.scrollHeight) };
    },
    "page.press": (a) => { pressKey(a.ref ? lookup(a.ref) : null, a.key || "Enter"); return { pressed: a.key || "Enter" }; },
  };

  chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
    if (!msg || !msg.lmnh) return false;
    try {
      const h = handlers[msg.method];
      if (!h) throw new Error(`unknown page method ${msg.method}`);
      reply({ result: h(msg.args || {}) });
    } catch (e) {
      reply({ error: String(e && e.message ? e.message : e) });
    }
    return true;
  });
})();
