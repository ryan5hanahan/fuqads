// bl0cksh1t — node assert tests for the policy → dNR mapping (PLAN Phase 2.6).
// Run:  node Tests/policy.test.js
"use strict";

const assert = require("node:assert/strict");
const {
  fnv1a,
  ruleBaseFor,
  policyToRules,
  computeRules,
  cspFor,
  naiveEtldPlusOne,
} = require("../WebExtension/Resources/policy.js");

let n = 0;
function test(name, fn) {
  fn();
  n++;
  console.log("ok " + n + " — " + name);
}

// --- policyToRules -------------------------------------------------------

test("trusted and default produce no dNR rules", () => {
  assert.deepEqual(policyToRules("example.com", { state: "trusted" }), []);
  assert.deepEqual(policyToRules("example.com", { state: "default" }), []);
  assert.deepEqual(policyToRules("example.com", {}), []);
});

test("strict produces exactly one third-party block rule", () => {
  const rules = policyToRules("example.com", { state: "strict" });
  assert.equal(rules.length, 1);
  const r = rules[0];
  assert.equal(r.id, ruleBaseFor("example.com"));
  assert.equal(r.priority, 10);
  assert.deepEqual(r.action, { type: "block" });
  assert.deepEqual(r.condition.initiatorDomains, ["example.com"]);
  assert.deepEqual(r.condition.notRequestDomains, ["example.com"]);
  assert.deepEqual(r.condition.resourceTypes, ["script", "sub_frame", "websocket"]);
});

test("strict allowOrigins are exempted via notRequestDomains", () => {
  const rules = policyToRules("example.com", {
    state: "strict",
    allowOrigins: ["cdn.example.net", "fonts.gstatic.com"],
  });
  assert.equal(rules.length, 1);
  assert.deepEqual(rules[0].condition.notRequestDomains, [
    "example.com",
    "cdn.example.net",
    "fonts.gstatic.com",
  ]);
});

test("untrusted with CSP adds 1st-party block + modifyHeaders rules", () => {
  const base = ruleBaseFor("example.com");
  const rules = policyToRules("example.com", { state: "untrusted" }, true);
  assert.equal(rules.length, 3);
  assert.deepEqual(
    rules.map((r) => r.id),
    [base, base + 1, base + 2]
  );
  const fp = rules[1];
  assert.deepEqual(fp.action, { type: "block" });
  assert.deepEqual(fp.condition.initiatorDomains, ["example.com"]);
  assert.deepEqual(fp.condition.requestDomains, ["example.com"]);
  assert.deepEqual(fp.condition.resourceTypes, ["script"]);
  const csp = rules[2];
  assert.equal(csp.action.type, "modifyHeaders");
  assert.deepEqual(csp.action.headerOperations, [
    { header: "content-security-policy", operation: "set", value: "script-src 'none'" },
  ]);
  assert.deepEqual(csp.condition.requestDomains, ["example.com"]);
  assert.deepEqual(csp.condition.resourceTypes, ["document"]);
});

test("untrusted without CSP support drops only the modifyHeaders rule", () => {
  const base = ruleBaseFor("example.com");
  const rules = policyToRules("example.com", { state: "untrusted" }, false);
  assert.deepEqual(
    rules.map((r) => r.id),
    [base, base + 1]
  );
  assert.ok(!rules.some((r) => r.action.type === "modifyHeaders"));
});

test("untrusted allowOrigins reach both dNR exemptions and the CSP value", () => {
  const rules = policyToRules(
    "example.com",
    { state: "untrusted", allowOrigins: ["cdn.example.net"] },
    true
  );
  assert.equal(rules.length, 3);
  assert.deepEqual(rules[0].condition.notRequestDomains, [
    "example.com",
    "cdn.example.net",
  ]);
  assert.equal(
    rules[2].action.headerOperations[0].value,
    "script-src https://cdn.example.net"
  );
});

// --- cspFor ---------------------------------------------------------------

test("cspFor: none → script-src 'none'; allows → exact origin list", () => {
  assert.equal(cspFor([]), "script-src 'none'");
  assert.equal(cspFor(null), "script-src 'none'");
  assert.equal(cspFor(["a.com", "b.org"]), "script-src https://a.com https://b.org");
});

// --- rule IDs --------------------------------------------------------------

test("ruleBaseFor is deterministic, in range, and collision-free", () => {
  assert.equal(ruleBaseFor("example.com"), ruleBaseFor("example.com"));
  assert.equal(ruleBaseFor("Example.COM"), ruleBaseFor("example.com"));
  const base = ruleBaseFor("example.com");
  assert.ok(base >= 1 && base + 2 <= 0x3fffffff, "base triple fits [1, 2^30)");
  assert.ok(ruleBaseFor("example.com") !== ruleBaseFor("example.net"));

  // No two sites in a fixed sample may share a rule-id triple — otherwise
  // recomputing the set would replace one site's rules with another's.
  const domains = [];
  for (const tld of ["com", "net", "org", "io", "co.uk"]) {
    for (let i = 0; i < 60; i++) domains.push("site" + i + "." + tld);
  }
  const used = new Set();
  for (const d of domains) {
    const b = ruleBaseFor(d);
    for (const id of [b, b + 1, b + 2]) {
      assert.ok(!used.has(id), "id collision at " + id + " for " + d);
      used.add(id);
    }
  }
});

test("fnv1a is deterministic (no Math.random/Date inputs)", () => {
  // Pinned: FNV-1a 32 of "bl0cksh1t". Changes here change every rule ID.
  assert.equal(fnv1a("bl0cksh1t"), 1670524937);
  assert.ok(fnv1a("a") !== fnv1a("b"));
});

// --- computeRules ----------------------------------------------------------

const SITES = {
  "a.com": { state: "strict", allowOrigins: ["cd.a.com"] },
  "b.org": { state: "untrusted", allowOrigins: [] },
  "c.net": { state: "default" },
  "d.io": { state: "trusted" },
};

function idsFor(sites, rules) {
  const base = ruleBaseFor(sites);
  return rules.filter((r) => [base, base + 1, base + 2].includes(r.id)).length;
}

test("computeRules: explicit sites only, default global", () => {
  const rules = computeRules({ sites: SITES, observed: [], globalDefault: "default" });
  assert.equal(idsFor("a.com", rules), 1); // strict
  assert.equal(idsFor("b.org", rules), 3); // untrusted + CSP
  assert.equal(idsFor("c.net", rules), 0);
  assert.equal(idsFor("d.io", rules), 0);
  assert.equal(rules.length, 4);
});

test("computeRules: strict global default covers observed sites", () => {
  const rules = computeRules({
    sites: SITES,
    observed: ["a.com", "e.co.uk"],
    globalDefault: "strict",
  });
  // e.co.uk: unobserved explicitly → gets strict rules via global default.
  assert.equal(idsFor("e.co.uk", rules), 1);
  // a.com already explicit → no duplicate ids.
  assert.equal(idsFor("a.com", rules), 1);
  const allIds = rules.map((r) => r.id);
  assert.equal(new Set(allIds).size, allIds.length, "ids unique");
});

test("computeRules: explicit default/trusted beat the strict global default", () => {
  const rules = computeRules({
    sites: { "c.net": { state: "default" }, "d.io": { state: "trusted" } },
    observed: ["c.net", "d.io", "f.dev"],
    globalDefault: "strict",
  });
  assert.equal(idsFor("c.net", rules), 0);
  assert.equal(idsFor("d.io", rules), 0);
  assert.equal(idsFor("f.dev", rules), 1);
});

test("computeRules: cspSupported=false removes every modifyHeaders rule", () => {
  const rules = computeRules({
    sites: { "b.org": { state: "untrusted" } },
    observed: ["g.com"],
    globalDefault: "strict",
    cspSupported: false,
  });
  assert.ok(!rules.some((r) => r.action.type === "modifyHeaders"));
  assert.equal(idsFor("b.org", rules), 2);
  assert.equal(idsFor("g.com", rules), 1);
});

test("computeRules: allowOrigins survive the full-set mapping", () => {
  const rules = computeRules({
    sites: { "a.com": { state: "strict", allowOrigins: ["cd.a.com"] } },
  });
  const rule = rules.find((r) => r.id === ruleBaseFor("a.com"));
  assert.deepEqual(rule.condition.notRequestDomains, ["a.com", "cd.a.com"]);
});

// --- naiveEtldPlusOne -------------------------------------------------------

test("naiveEtldPlusOne: last-two-label fallback", () => {
  assert.equal(naiveEtldPlusOne("www.example.com"), "example.com");
  assert.equal(naiveEtldPlusOne("example.com"), "example.com");
  assert.equal(naiveEtldPlusOne("localhost"), "localhost");
  assert.equal(naiveEtldPlusOne("WWW.Example.COM"), "example.com");
});

console.log("\n" + n + " tests passed");
