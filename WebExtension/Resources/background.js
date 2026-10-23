// bl0cksh1t — web extension background (Safari, MV3, non-persistent).
//
// Phase 1 responsibilities (FR-5, NFR-4):
//   - keep filter lists fresh while the host app is closed: a periodic
//     alarm sized to the user's update interval (pending spike S5 will
//     confirm alarm delivery; fallback is a login item, SPEC/PLAN);
//   - on install and on Safari startup: run an update if the native
//     state says the last one is stale.
//
// Everything network-heavy happens natively in SafariWebExtensionHandler;
// this file only coordinates and must stay trivially cheap.
//
// Protocol (JSON, browser.runtime.sendNativeMessage):
//   -> { type: "getState" }            <- statePayload (see handler)
//   -> { type: "updateLists" }         <- { ok: true, async: true }

const UPDATE_ALARM = "bl0cksh1t-update-lists";
// Safari enforces a coarse minimum for periodic alarms; a 60-minute floor
// keeps the schedule honest even when the user picks a short interval.
const MIN_PERIOD_MINUTES = 60;
const STALE_MARGIN_MINUTES = 60; // update if older than interval + margin

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
    return null; // native handler unreachable; the next alarm retries
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

browser.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === UPDATE_ALARM) {
    native({ type: "updateLists" }).catch(() => {});
  }
});

browser.runtime.onInstalled.addListener(async () => {
  const s = await state();
  const intervalHours = s?.updateIntervalHours ?? 24;
  scheduleUpdateAlarm(intervalHours);
  updateIfStale(intervalHours);
});

browser.runtime.onStartup.addListener(async () => {
  const s = await state();
  const intervalHours = s?.updateIntervalHours ?? 24;
  scheduleUpdateAlarm(intervalHours);
  updateIfStale(intervalHours);
});
