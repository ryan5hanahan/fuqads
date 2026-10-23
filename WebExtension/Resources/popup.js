// bl0cksh1t — toolbar panel (FR-10, FR-13, FR-16, FR-20, FR-23).
//
// Flow on state / allow change (FR-16): persist natively (App Group —
// survives restarts) → tell the background worker to re-apply the dNR
// rules (milliseconds) → wait for a content-blocker reload if one is in
// flight (trusted state triggers the allowlist recompile, SPEC §5.3) →
// reload the page once → close.

"use strict";

const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function native(payload) {
  return browser.runtime
    .sendNativeMessage(payload)
    .then((res) => (Array.isArray(res) ? res[0] ?? null : res));
}

let tab = null;
let siteKey = null;
let state_ = null;
let cspSupported = false;
let busy = false;

function setBusy(next, msg) {
  busy = next;
  document.querySelectorAll("button").forEach((b) => {
    b.disabled = next;
  });
  $("status").textContent = next ? (msg || "applying…") : "";
}

function fail(msg) {
  $("status").textContent = msg;
}

function explicitPolicy() {
  if (!state_) return null;
  return (state_.sites || []).find((s) => s.site === siteKey) || null;
}

function effectiveState() {
  const p = explicitPolicy();
  return p ? p.state : state_.globalDefault || "default";
}

function effectiveAllows() {
  const p = explicitPolicy();
  return (p && p.allowOrigins) || [];
}

function renderState() {
  const eff = effectiveState();
  const p = explicitPolicy();
  document.querySelectorAll("#stateSwitch button").forEach((b) => {
    b.classList.toggle("active", b.dataset.state === eff);
  });
  $("effective").textContent = p
    ? eff + " (this site)"
    : eff + " (global default)";
  // Untrusted degrades without dNR header modification (SPEC §5.5).
  const note = $("cspNote");
  if (eff === "untrusted" && !cspSupported) {
    note.textContent =
      "This Safari's dNR cannot modify response headers, so Untrusted " +
      "blocks 1st- and 3rd-party scripts but not inline scripts.";
    note.classList.remove("hidden");
  } else {
    note.classList.add("hidden");
  }
}

function renderInventory(inv) {
  const third = $("thirdParty");
  const first = $("firstParty");
  const note = $("inventoryNote");
  third.textContent = "";
  first.textContent = "";
  if (!inv || !inv.ok) {
    note.textContent =
      "Inventory unavailable on this page (Safari-internal page, private " +
      "window, or content scripts disabled).";
    note.classList.remove("hidden");
    return;
  }
  note.classList.add("hidden");
  const allows = effectiveAllows();
  const eff = effectiveState();
  for (const o of inv.origins || []) {
    const li = document.createElement("li");
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = o.origin.replace(/^https?:\/\//, "");
    name.title = o.origin;
    const kinds = document.createElement("span");
    kinds.className = "kinds";
    kinds.textContent = o.kinds.join(", ");
    li.appendChild(name);
    li.appendChild(kinds);
    if (o.firstParty) {
      const tag = document.createElement("span");
      tag.className = "state-tag" + (eff === "untrusted" ? " blocked" : "");
      tag.textContent = eff === "untrusted" ? "blocked (untrusted)" : "allowed";
      li.appendChild(tag);
      first.appendChild(li);
    } else {
      const btn = document.createElement("button");
      btn.type = "button";
      const allowed = allows.includes(o.host);
      btn.textContent = allowed ? "allowed ✓" : "allow";
      btn.classList.toggle("allowed", allowed);
      btn.title = allowed
        ? "Click to block this origin under Strict/Untrusted"
        : "Click to allow this origin under Strict/Untrusted (FR-13)";
      btn.addEventListener("click", () => toggleAllow(o.host));
      li.appendChild(btn);
    }
    (o.firstParty ? first : third).appendChild(li);
  }
}

// Wait until no content-blocker reload is in progress. dNR changes are
// immediate; only the trusted-state allowlist recompile takes seconds
// (NFR-3: < 5 s; allow 12 s of polling to be safe).
async function waitIdle() {
  let saw = false;
  for (let i = 0; i < 24; i++) {
    await sleep(500);
    const st = await native({ type: "getState" }).catch(() => null);
    if (!st) break;
    if (st.updateInProgress) saw = true;
    else if (saw) break;
  }
}

async function applyPolicy(nextState, allowOrigins) {
  if (busy || !state_) return;
  setBusy(true);
  try {
    await native({
      type: "setSiteState",
      site: siteKey,
      state: nextState,
      allowOrigins,
    });
    await browser.runtime.sendMessage({ type: "policyChanged" }).catch(() => {});
    await waitIdle();
    await browser.tabs.reload(tab.id);
    window.close();
  } catch (e) {
    fail("change failed: " + ((e && e.message) || e));
    setBusy(false);
  }
}

function chooseState(stateName) {
  applyPolicy(stateName, effectiveAllows());
}

function toggleAllow(host) {
  const allows = effectiveAllows();
  const next = allows.includes(host)
    ? allows.filter((o) => o !== host)
    : allows.concat([host]);
  applyPolicy(effectiveState(), next);
}

async function load() {
  setBusy(true, "loading…");
  const [active] = await browser.tabs.query({ active: true, currentWindow: true });
  tab = active;
  if (!tab || !tab.url) return fail("no web page in this window");
  let host;
  try {
    host = new URL(tab.url).hostname;
  } catch {
    return fail("cannot read the page origin");
  }
  const r = await native({ type: "etldPlusOne", host }).catch(() => null);
  siteKey = (r && r.etldPlusOne) || host;
  $("site").textContent = siteKey;

  const [st, csp] = await Promise.all([
    native({ type: "getState" }).catch(() => null),
    browser.runtime.sendMessage({ type: "getCspSupport" }).catch(() => null),
  ]);
  state_ = st;
  cspSupported = !!(csp && csp.cspSupported);
  if (!st) return fail("bl0cksh1t is not responding (web extension disabled?)");

  renderState();
  setBusy(false);
  const inv = await browser
    .tabs.sendMessage(tab.id, { type: "getInventory" })
    .catch(() => null);
  renderInventory(inv);
}

document.querySelectorAll("#stateSwitch button").forEach((b) => {
  b.addEventListener("click", () => chooseState(b.dataset.state));
});
$("reload").addEventListener("click", async () => {
  try {
    await browser.tabs.reload(tab.id);
    window.close();
  } catch {
    // Tab already gone.
  }
});

load().catch((e) => fail(String((e && e.message) || e)));
