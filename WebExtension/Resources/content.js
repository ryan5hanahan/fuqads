// bl0cksh1t — content script: page script/frame inventory (FR-20, SPEC §4.4)
// and the element picker (FR-22, SPEC §4.3, PLAN Phase 3.1).
//
// Inventory: reports the origins of <script src> / <iframe src> to the
// background — once on load and again (debounced) when the DOM mutates —
// and answers getInventory messages from the popup with a fresh scan.
// The 1st/3rd-party split is a hostname heuristic (a content script has
// no PSL); display-only. The dNR rules use the native PSL via eTLD+1
// initiator domains, so blocking does not depend on this grouping.
//
// Picker: startPicker → hover highlight, click → hide preview + confirm
// bar. Save sends {type:"pickerResult", selector, host} to the background,
// which persists `site##selector` in the user rules and reloads the tab.
// Esc cancels. Selector strategy (PLAN Phase 3.1): id > class chain >
// nth-child.

(function () {
  "use strict";
  if (typeof browser === "undefined") return;

  const topOrigin = document.location.origin;
  const topHost = document.location.hostname;

  function inventory() {
    const map = new Map(); // origin -> entry
    for (const el of document.querySelectorAll("script[src], iframe[src]")) {
      const src = el.getAttribute("src");
      if (!src) continue;
      let origin, host;
      try {
        const u = new URL(src, document.baseURI);
        if (u.protocol === "data:" || u.protocol === "blob:") {
          origin = "(inline)";
          host = topHost;
        } else if (u.protocol !== "http:" && u.protocol !== "https:") {
          continue;
        } else {
          origin = u.origin;
          host = u.hostname;
        }
      } catch {
        continue;
      }
      const kind = el.tagName === "IFRAME" ? "sub_frame" : "script";
      let entry = map.get(origin);
      if (!entry) {
        entry = {
          origin,
          host,
          firstParty: host === topHost || host.endsWith("." + topHost),
          kinds: [],
        };
        map.set(origin, entry);
      }
      if (!entry.kinds.includes(kind)) entry.kinds.push(kind);
    }
    return { ok: true, topOrigin, origins: [...map.values()] };
  }

  function push() {
    try {
      browser.runtime.sendMessage({ type: "inventory", ...inventory() }).catch(
        () => {}
      );
    } catch {
      // Extension context invalidated (update/reload) — ignore.
    }
  }

  // Debounced rescan on DOM mutation (PLAN Phase 2.3).
  let timer = 0;
  const observer = new MutationObserver(() => {
    clearTimeout(timer);
    timer = setTimeout(push, 1000);
  });
  observer.observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["src"],
  });

  // --- element picker (FR-22) --------------------------------------------

  let picker = null; // active picker state
  // Picker-internal classes must never leak into generated selectors.
  const PICKER_CLASSES = new Set(["bl0cksh1t-pick-target", "bl0cksh1t-pick-hidden"]);

  function escapeCss(s) {
    return window.CSS && CSS.escape ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g, "\\$&");
  }

  function cssSelectorFor(el) {
    if (el.id) return "#" + escapeCss(el.id);
    const parts = [];
    let node = el;
    while (node && node.nodeType === 1 && node.tagName !== "HTML") {
      let part = node.tagName.toLowerCase();
      const classes = [...node.classList].filter((c) => c && !PICKER_CLASSES.has(c));
      if (classes.length) part += "." + classes.map(escapeCss).join(".");
      const parent = node.parentElement;
      if (parent) {
        const sameTag = [...parent.children].filter((c) => c.tagName === node.tagName);
        if (sameTag.length > 1) {
          // :nth-child counts ALL children; use the real child index.
          part += ":nth-child(" + ([...parent.children].indexOf(node) + 1) + ")";
        }
      }
      parts.unshift(part);
      node = parent;
    }
    return parts.join(" > ");
  }

  function inBar(el) {
    return picker && picker.bar && picker.bar.contains(el);
  }

  function setPickTarget(el) {
    if (!picker || picker.target === el) return;
    if (picker.target) picker.target.classList.remove("bl0cksh1t-pick-target");
    picker.target = el;
    el.classList.add("bl0cksh1t-pick-target");
  }

  function startPicker() {
    stopPicker(false);
    const p = { style: null, bar: null, target: null, previewed: null, selector: null, prevCursor: "" };
    picker = p;
    p.style = document.createElement("style");
    p.style.textContent =
      ".bl0cksh1t-pick-target{outline:2px dashed #e04040 !important;outline-offset:-2px}" +
      ".bl0cksh1t-pick-hidden{display:none !important}";
    (document.head || document.documentElement).appendChild(p.style);
    p.prevCursor = document.body.style.cursor;
    document.body.style.cursor = "crosshair";
    document.addEventListener("mouseover", onPickOver, true);
    document.addEventListener("click", onPickClick, true);
    document.addEventListener("keydown", onPickKey, true);
  }

  function stopPicker(keepPreview) {
    if (!picker) return;
    const p = picker;
    picker = null;
    if (p.style) p.style.remove();
    if (p.bar) p.bar.remove();
    if (p.target) p.target.classList.remove("bl0cksh1t-pick-target");
    if (p.previewed && !keepPreview) p.previewed.classList.remove("bl0cksh1t-pick-hidden");
    document.body.style.cursor = p.prevCursor;
    document.removeEventListener("mouseover", onPickOver, true);
    document.removeEventListener("click", onPickClick, true);
    document.removeEventListener("keydown", onPickKey, true);
  }

  function onPickOver(e) {
    if (!picker || inBar(e.target)) return;
    const el = e.target;
    if (el.nodeType === 1 && el !== picker.previewed) setPickTarget(el);
  }

  function onPickClick(e) {
    if (!picker || inBar(e.target)) return;
    e.preventDefault();
    e.stopPropagation();
    const el = e.target;
    if (el.nodeType !== 1 || el === picker.previewed) return;
    if (picker.previewed) picker.previewed.classList.remove("bl0cksh1t-pick-hidden");
    picker.previewed = el;
    picker.selector = cssSelectorFor(el);
    el.classList.add("bl0cksh1t-pick-hidden");
    showPickBar();
  }

  function showPickBar() {
    const p = picker;
    if (!p) return;
    if (p.bar) p.bar.remove();
    const bar = document.createElement("div");
    bar.style.cssText =
      "position:fixed;left:12px;right:12px;bottom:12px;z-index:2147483647;" +
      "background:#1d1d1f;color:#fff;font:13px/1.4 -apple-system,system-ui,sans-serif;" +
      "padding:10px 14px;border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.4);" +
      "display:flex;align-items:center;gap:10px";
    const label = document.createElement("span");
    label.style.cssText = "flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap";
    label.textContent = "Hide " + p.selector + " on " + topHost + "?";
    const makeButton = (text, bg, color) => {
      const b = document.createElement("button");
      b.textContent = text;
      b.style.cssText =
        "font:600 13px -apple-system,system-ui,sans-serif;padding:6px 14px;border:none;" +
        "border-radius:6px;cursor:pointer;background:" + bg + ";color:" + color;
      return b;
    };
    const save = makeButton("Save", "#34c759", "#fff");
    const cancel = makeButton("Cancel", "transparent", "#fff");
    cancel.style.border = "1px solid #666";
    save.addEventListener("click", (ev) => {
      ev.stopPropagation();
      const selector = p.selector;
      stopPicker(true); // keep the preview hidden until the reload
      try {
        browser.runtime
          .sendMessage({ type: "pickerResult", selector, host: topHost })
          .catch(() => {});
      } catch {
        // Extension context invalidated — nothing to persist to.
      }
    });
    cancel.addEventListener("click", (ev) => {
      ev.stopPropagation();
      stopPicker(false); // restore the preview
    });
    bar.addEventListener("click", (e) => e.stopPropagation());
    bar.appendChild(label);
    bar.appendChild(save);
    bar.appendChild(cancel);
    (document.body || document.documentElement).appendChild(bar);
    p.bar = bar;
  }

  function onPickKey(e) {
    if (!picker || e.key !== "Escape") return;
    e.preventDefault();
    e.stopPropagation();
    stopPicker(false);
  }

  browser.runtime.onMessage.addListener((msg) => {
    if (!msg || typeof msg.type !== "string") return;
    if (msg.type === "getInventory") {
      return Promise.resolve(inventory());
    }
    if (msg.type === "startPicker") {
      startPicker();
      return Promise.resolve({ ok: true });
    }
    if (msg.type === "stopPicker") {
      stopPicker(false);
      return Promise.resolve({ ok: true });
    }
  });

  push();
})();
