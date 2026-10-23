// bl0cksh1t spike — background (Safari web extension)
//
// S2: registers dNR dynamic rules probing modifyHeaders / initiatorDomains /
//     requestDomains / domainType; results reported to s2.jsonl.
// S3: on s5-quick alarm and on app dispatchMessage, asks the native handler to
//     rewrite + reload the content blocker and time it (s3.jsonl).
// S5: hourly + 5-min alarms; every firing is logged to s5.jsonl via the
//     native handler (works only if alarms fire with the app closed).

const NATIVE_ID = "bl0cksh1t-spike"; // Safari ignores this argument

function now() { return new Date().toISOString(); }

function native(payload) {
  return browser.runtime.sendNativeMessage({ ...payload, ts: now() });
}

async function logEvent(file, entry) {
  try {
    await native({ type: "log", file, entry });
  } catch (e) {
    console.warn("native log failed", e);
  }
}

// --- S2 ---------------------------------------------------------------------

const S2_RULES = [
  {
    id: 1,
    priority: 1,
    action: {
      type: "modifyHeaders",
      requestHeaders: [
        { header: "Content-Security-Policy", operation: "set", value: "script-src 'none'" }
      ]
    },
    condition: {
      urlFilter: "|http://127.0.0.1:8642/s2.html",
      resourceTypes: ["main_frame"]
    }
  },
  {
    id: 2,
    priority: 1,
    action: { type: "block" },
    condition: {
      urlFilter: "||127.0.0.1:8642/dnr-initiator.txt",
      resourceTypes: ["xmlhttprequest"],
      initiatorDomains: ["127.0.0.1"]
    }
  },
  {
    id: 3,
    priority: 1,
    action: { type: "block" },
    condition: {
      urlFilter: "||127.0.0.1:8642/dnr-requestdomains.txt",
      resourceTypes: ["xmlhttprequest"],
      requestDomains: ["127.0.0.1"]
    }
  },
  {
    id: 4,
    priority: 1,
    action: { type: "block" },
    condition: {
      urlFilter: "||127.0.0.1:8642/dnr-domaintype.txt",
      resourceTypes: ["xmlhttprequest"],
      domainType: "thirdParty"
    }
  },
  {
    id: 5,
    priority: 1,
    action: { type: "block" },
    condition: {
      urlFilter: "||127.0.0.1:8642/dnr-baseline.txt",
      resourceTypes: ["xmlhttprequest"]
    }
  }
];

async function applyS2Rules() {
  for (const rule of S2_RULES) {
    try {
      await browser.declarativeNetRequest.updateDynamicRules({
        removeRuleIds: [rule.id],
        addRules: [rule]
      });
      await logEvent("s2.jsonl", { event: "dnr-add", id: rule.id, ok: true });
    } catch (e) {
      await logEvent("s2.jsonl", {
        event: "dnr-add", id: rule.id, ok: false, error: String(e.message || e)
      });
    }
  }
  try {
    const current = await browser.declarativeNetRequest.getDynamicRules();
    await logEvent("s2.jsonl", { event: "dnr-active", ids: current.map((r) => r.id) });
  } catch (e) {
    await logEvent("s2.jsonl", { event: "dnr-active-error", error: String(e.message || e) });
  }
}

// --- S3 ---------------------------------------------------------------------

function s3Probe(size) {
  return native({ type: "s3probe", size })
    .then((r) => logEvent("s2.jsonl", { event: "s3probe-response", r }))
    .catch((e) => logEvent("s2.jsonl", { event: "s3probe-error", error: String(e.message || e) }));
}

// --- S5 ---------------------------------------------------------------------

async function setupAlarms() {
  try {
    await browser.alarms.create("s5-hourly", { periodInMinutes: 60 });
    await browser.alarms.create("s5-quick", { periodInMinutes: 5 });
    const alarms = await browser.alarms.getAll();
    await logEvent("s2.jsonl", { event: "alarms-created", alarms });
  } catch (e) {
    await logEvent("s2.jsonl", { event: "alarms-error", error: String(e.message || e) });
  }
}

browser.alarms.onAlarm.addListener(async (alarm) => {
  await logEvent("s5.jsonl", { event: "alarm", name: alarm.name });
  if (alarm.name === "s5-quick") {
    s3Probe("150k");
  }
});

// --- app -> extension (SFSafariApplication.dispatchMessage) ------------------

try {
  const port = browser.runtime.connectNative(NATIVE_ID);
  port.onMessage.addListener((msg) => {
    logEvent("s2.jsonl", { event: "port-message", msg });
    if (msg && msg.type === "s3probe") {
      s3Probe(msg.size || "150k");
    }
  });
  port.onDisconnect.addListener(() => {
    logEvent("s2.jsonl", { event: "port-disconnect" });
  });
} catch (e) {
  logEvent("s2.jsonl", { event: "connectNative-error", error: String(e.message || e) });
}

browser.runtime.onMessage.addListener((msg) => {
  logEvent("s2.jsonl", { event: "on-message", msg });
  if (msg && msg.type === "s3probe") s3Probe(msg.size || "150k");
});

// --- lifecycle ---------------------------------------------------------------

browser.runtime.onInstalled.addListener(async () => {
  await logEvent("s2.jsonl", { event: "onInstalled" });
  await setupAlarms();
  await applyS2Rules();
});

browser.runtime.onStartup.addListener(async () => {
  await logEvent("s2.jsonl", { event: "onStartup" });
  await applyS2Rules();
});
