// bl0cksh1t — web extension background (Safari, MV3, non-persistent).
//
// Responsibilities:
//   Phase 1 (FR-5): keep the filter lists fresh while the host app is
//     closed — a periodic alarm sized to the user's update interval plus
//     a staleness check on install/startup (the native handler does all
//     the network work; this file stays trivially cheap).
//   Phase 2 (FR-10..FR-16): per-site script policy via dNR dynamic rules.
//     - policyToRules/computeRules live in policy.js (pure, node-tested);
//     - the full rule set is recomputed on every change and applied as a
//       diff, so rule IDs (derived from the eTLD+1 hash) replace rules in
//       place instead of accumulating;
//     - top-level origins of open tabs are observed so a Strict global
//       default also blocks 3rd-party scripts on sites the user has not
//       set explicitly (dNR cannot express "third-party" without a
//       concrete domain);
//     - dNR modifyHeaders support is probed once per cold start; Untrusted
//       degrades to strict + 1st-party blocking without inline-script
//       blocking when it fails (SPEC §5.5, FR-14).
//
// Protocol (JSON, browser.runtime.sendNativeMessage):
//   -> { type: "getState" }              <- statePayload (see handler)
//   -> { type: "updateLists" }           <- { ok: true, async: true }
//   -> { type: "etldPlusOne", "host" }   <- { ok: true, "etldPlusOne" }
//
// Messages from the popup / content script (runtime.sendMessage):
//   { type: "policyChanged" }            recompute dNR rules now
//   { type: "getCspSupport" }            <- { ok, cspSupported }
//   { type: "inventory", topOrigin, … }  <- { ok }   (content-script push)
//
// A cold start (browser launch, extension install/update, or the worker
// being recycled) re-runs this whole file: the probe, tab observation,
// and rule application happen in startup().

importScripts("policy.js");

const UPDATE_ALARM = "bl0cksh1t-update-lists";
// Safari enforces a coarse minimum for periodic alarms; a 60-minute floor
// keeps the schedule honest even when the user picks a short interval.
const MIN_PERIOD_MINUTES = 60;
const STALE_MARGIN_MINUTES = 60; // update if older than interval + margin
// Policy edits made from the host app (different process, same App Group
// UserDefaults) are picked up by this poll — the app cannot message the
// extension directly on macOS.
const POLICY_POLL_MS = 30000;
// Outside ruleBaseFor's range (base ≤ 2^30 − 1, see policy.js).
const PROBE_RULE_ID = 2147483646;
const MAX_OBSERVED_SITES = 200;

let cspSupported = null;
const appliedRules = new Map(); // id -> rule currently installed in dNR
const observedSites = new Map(); // eTLD+1 -> last-seen timestamp
const etldCache = new Map(); // host -> eTLD+1

function native(payload) {
  return browser.runtime.sendNativeMessage(payload);
}

function normalize(res) {
  if (Array.isArray(res)) return res[0] ?? null;
  return res;
}

async function state() {
  try {
    return normalize(await native({ type: "getState" })) ?? null;
  } catch {
    return null; // native handler unreachable; the next trigger retries
  }
}

async function updateIfStale(intervalHours) {
  const s = await state();
  if (!s) return;
  const ageMinutes = s.lastUpdateFinished
    ? (Date.now() / 1000 - s.lastUpdateFinished) / 60
    : Infinity;
  const staleAfter = intervalHours * 60 + STALE_MARGIN_MINUTES;
  if (!s.updateInProgress && ageMinutes > staleAfter) {
    try {
      await native({ type: "updateLists" });
    } catch {
      // Next alarm retries.
    }
  }
}

function scheduleUpdateAlarm(intervalHours) {
  const period = Math.max(MIN_PERIOD_MINUTES, Math.round(intervalHours * 60));
  // Safari's alarms API has no get/getAll: clear + create is idempotent.
  browser.alarms
    .clear(UPDATE_ALARM)
    .then(() => browser.alarms.create(UPDATE_ALARM, { periodInMinutes: period }))
    .catch(() => {});
}

// --- Phase 2: dNR dynamic rules ----------------------------------------

// Does this Safari's dNR implementation accept modifyHeaders? The probe
// installs and removes one inert rule. (Pending spike S2 in SPEC §8; this
// probe is the runtime fallback so Untrusted degrades, per SPEC §5.5.)
async function probeCspSupport() {
  const rule = {
    id: PROBE_RULE_ID,
    priority: 1,
    action: {
      type: "modifyHeaders",
      headerOperations: [
        { header: "x-bl0cksh1t-probe", operation: "set", value: "1" },
      ],
    },
    condition: {
      requestDomains: ["probe.bl0cksh1t.invalid"],
      resourceTypes: ["image"],
    },
  };
  try {
    await browser.declarativeNetRequest.updateDynamicRules({ addRules: [rule] });
    await browser.declarativeNetRequest.updateDynamicRules({
      removeRuleIds: [PROBE_RULE_ID],
    });
    return true;
  } catch {
    return false;
  }
}

// Install `targetRules`, diffed against what is currently applied.
async function applyRules(targetRules) {
  const target = new Map(targetRules.map((r) => [r.id, r]));
  const addRules = [...target.values()].filter((r) => !appliedRules.has(r.id));
  const removeRuleIds = [...appliedRules.keys()].filter((id) => !target.has(id));
  if (addRules.length === 0 && removeRuleIds.length === 0) return;
  try {
    await browser.declarativeNetRequest.updateDynamicRules({
      addRules,
      removeRuleIds,
    });
    target.forEach((rule, id) => appliedRules.set(id, rule));
    for (const id of removeRuleIds) appliedRules.delete(id);
  } catch (e) {
    console.warn("bl0cksh1t: dNR update failed", e);
  }
}

// Recompute the full rule set from the native state + observed origins and
// apply the diff. Cheap; safe to call on every trigger.
async function recompute() {
  const s = await state();
  if (!s) return;
  const sites = {};
  for (const site of s.sites || []) {
    sites[site.site] = { state: site.state, allowOrigins: site.allowOrigins || [] };
  }
  await applyRules(
    computeRules({
      sites,
      observed: [...observedSites.keys()],
      globalDefault: s.globalDefault || "default",
      cspSupported: cspSupported === true,
    })
  );
}

// Record the eTLD+1 of a page URL as observed (strict-global-default
// coverage). New hostnames are resolved via the native PSL, cached.
async function observeUrl(url) {
  let origin;
  try {
    origin = new URL(url).origin;
  } catch {
    return;
  }
  if (!/^https?:/.test(origin)) return;
  const host = new URL(origin).hostname;
  let site = etldCache.get(host);
  if (site == null) {
    site = naiveEtldPlusOne(host);
    try {
      const r = normalize(await native({ type: "etldPlusOne", host }));
      if (r && r.etldPlusOne) site = r.etldPlusOne;
    } catch {
      // Keep the naive fallback.
    }
    etldCache.set(host, site);
  }
  const isNew = !observedSites.has(site);
  observedSites.set(site, Date.now());
  while (observedSites.size > MAX_OBSERVED_SITES) {
    let oldest = null;
    for (const [k, t] of observedSites) {
      if (oldest == null || t < observedSites.get(oldest)) oldest = k;
    }
    observedSites.delete(oldest);
  }
  if (isNew) recompute().catch(() => {});
}

async function observeAllTabs() {
  let tabs = [];
  try {
    tabs = await browser.tabs.query({});
  } catch {
    return;
  }
  for (const tab of tabs) {
    if (tab.url) observeUrl(tab.url).catch(() => {});
  }
}

// --- wiring --------------------------------------------------------------

browser.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === UPDATE_ALARM) {
    native({ type: "updateLists" }).catch(() => {});
  }
});

browser.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || typeof msg.type !== "string") return;
  switch (msg.type) {
    case "policyChanged":
      // The popup persists the policy natively before sending this; re-read
      // and re-apply so dNR rules are active within milliseconds (FR-16).
      return recompute().then(() => ({ ok: true }));
    case "getCspSupport":
      return Promise.resolve({ ok: true, cspSupported: cspSupported === true });
    case "inventory":
      // Content-script push (load + debounced DOM mutation): used to keep
      // the observed-origins set current.
      if (msg.topOrigin) observeUrl(msg.topOrigin).catch(() => {});
      return Promise.resolve({ ok: true });
  }
  return;
});

browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === "complete" && tab.url) {
    observeUrl(tab.url).catch(() => {});
  }
});

browser.tabs.onActivated.addListener(async (activeInfo) => {
  try {
    const tab = await browser.tabs.get(activeInfo.tabId);
    if (tab.url) await observeUrl(tab.url);
  } catch {
    // Tab gone or unreadable — nothing to observe.
  }
});

async function startup() {
  cspSupported = await probeCspSupport();
  const s = await state();
  const intervalHours = (s && s.updateIntervalHours) || 24;
  scheduleUpdateAlarm(intervalHours);
  updateIfStale(intervalHours);
  await observeAllTabs();
  await recompute();
  setInterval(() => {
    recompute().catch(() => {});
  }, POLICY_POLL_MS);
}

browser.runtime.onInstalled.addListener(startup);
browser.runtime.onStartup.addListener(startup);
