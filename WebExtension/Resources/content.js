// bl0cksh1t — content script: page script/frame inventory (FR-20, SPEC §4.4).
//
// Reports the origins of <script src> / <iframe src> to the background —
// once on load and again (debounced) when the DOM mutates — and answers
// getInventory messages from the popup with a fresh scan.
//
// The 1st/3rd-party split here is a hostname heuristic (a content script
// has no PSL); it is display-only. The dNR rules use the native PSL via
// eTLD+1 initiator domains, so the blocking behaviour does not depend on
// this grouping.

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

  browser.runtime.onMessage.addListener((msg) => {
    if (msg && msg.type === "getInventory") {
      return Promise.resolve(inventory());
    }
  });

  push();
})();
