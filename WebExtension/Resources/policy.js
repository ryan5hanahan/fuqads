// bl0cksh1t — policy → dNR dynamic rules (pure functions, no browser APIs).
//
// The background service worker loads this via importScripts() (Safari MV3)
// and the node tests (Tests/policy.test.js) require it directly. Keep this
// file free of any DOM/browser references.
//
// Design (SPEC §4.2):
//   trusted   → no dNR rules (the content blockers' allowlist does the work)
//   default   → no dNR rules
//   strict    → block third-party script / sub_frame / websocket issued from
//               the site, except the user-granted allowOrigins
//   untrusted → strict + block first-party scripts + (when dNR modifyHeaders
//               is available — probed in background.js, SPEC §5.5/FR-14) a
//               CSP on the document that kills inline scripts
//
// Rule IDs: deterministic per eTLD+1 (FNV-1a hash → base, base+1, base+2),
// so recomputing the whole set and diffing replaces rules in place instead
// of accumulating them (PLAN Phase 2.2).

"use strict";

function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

// dNR dynamic rule IDs are positive integers (max 2^31-1). Keep the per-site
// triple (base, base+1, base+2) inside [1, 2^30) so it can never collide
// with the probe ID used by background.js.
function ruleBaseFor(site) {
  return (fnv1a(String(site).toLowerCase()) % 0x3fffffff) + 1;
}

// Untrusted CSP: no inline scripts. With allowOrigins, exactly those origins
// may run scripts — first-party stays blocked, matching the dNR
// first-party block rule.
function cspFor(allowOrigins) {
  if (!allowOrigins || allowOrigins.length === 0) return "script-src 'none'";
  return "script-src " + allowOrigins.map((o) => "https://" + o).join(" ");
}

/**
 * dNR rules for one site (eTLD+1 key, or raw host for unkeyable hosts).
 *
 * @param {string} site
 * @param {{state: string, allowOrigins?: string[]}} policy
 * @param {boolean} cspSupported
 * @returns {Array<{id: number, priority: number, action: object, condition: object}>}
 */
function policyToRules(site, policy, cspSupported = true) {
  const state = policy && policy.state;
  const allows = ((policy && policy.allowOrigins) || []).filter(Boolean);
  if (state !== "strict" && state !== "untrusted") return [];

  const base = ruleBaseFor(site);
  const rules = [
    {
      // Third-party scripts, sub-frames, websockets — except allowOrigins.
      id: base,
      priority: 10,
      action: { type: "block" },
      condition: {
        initiatorDomains: [site],
        notRequestDomains: [site].concat(allows),
        resourceTypes: ["script", "sub_frame", "websocket"],
      },
    },
  ];

  if (state === "untrusted") {
    rules.push({
      // First-party scripts.
      id: base + 1,
      priority: 10,
      action: { type: "block" },
      condition: {
        initiatorDomains: [site],
        requestDomains: [site],
        resourceTypes: ["script"],
      },
    });
    if (cspSupported) {
      rules.push({
        // Inline scripts: inject CSP into the document response.
        id: base + 2,
        priority: 10,
        action: {
          type: "modifyHeaders",
          headerOperations: [
            {
              header: "content-security-policy",
              operation: "set",
              value: cspFor(allows),
            },
          ],
        },
        condition: {
          requestDomains: [site],
          resourceTypes: ["document"],
        },
      });
    }
  }
  return rules;
}

/**
 * The full dNR rule set for the whole policy state.
 *
 * `observed` are the eTLD+1 hosts currently seen on open tabs. With a
 * strict global default they get strict rules too — dNR cannot express
 * "third-party" without a concrete domain, so strict-by-default is
 * implemented over the observed origins (SPEC §4.2).
 *
 * @param {{
 *   sites?: Object<string, {state: string, allowOrigins?: string[]}>,
 *   observed?: string[],
 *   globalDefault?: string,
 *   cspSupported?: boolean,
 * }} input
 * @returns {Array<object>} dNR rules, ids unique
 */
function computeRules(input) {
  const {
    sites = {},
    observed = [],
    globalDefault = "default",
    cspSupported = true,
  } = input || {};
  const out = [];
  const seen = new Set();
  const add = (site, policy) => {
    for (const rule of policyToRules(site, policy, cspSupported)) {
      if (!seen.has(rule.id)) {
        seen.add(rule.id);
        out.push(rule);
      }
    }
  };
  for (const site of Object.keys(sites)) add(site, sites[site]);
  if (globalDefault === "strict") {
    for (const site of observed) {
      // An explicit per-site policy wins over the global default.
      if (!sites[site]) add(site, { state: "strict", allowOrigins: [] });
    }
  }
  return out;
}

// Naive eTLD+1 (last two labels) — fallback for when the native PSL lookup
// is unreachable. Exact PSL behaviour comes from the native `etldPlusOne`
// message (BlockerCore eTLDPlusOne).
function naiveEtldPlusOne(host) {
  const labels = String(host).toLowerCase().split(".");
  return labels.length >= 2 ? labels.slice(-2).join(".") : String(host).toLowerCase();
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    fnv1a,
    ruleBaseFor,
    policyToRules,
    computeRules,
    cspFor,
    naiveEtldPlusOne,
  };
}
