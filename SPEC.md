# bl0cksh1t — Specification

Native macOS/Safari content blocker combining uBlock Origin-style ad/tracker
blocking with NoScript-style per-site script control.

## 1. What Safari allows (design constraints, not choices)

| Capability | Safari reality | Consequence |
|---|---|---|
| Blocking `webRequest` | Not supported | No uBO-style dynamic request inspection. Everything is declarative. |
| Content Blocker extension | Native, WebKit-compiled JSON rules. 150,000 rules per extension. Actions: `block`, `block-cookies`, `css-display-none`, `ignore-previous-rules`, `make-https`. | Carries the static filter lists. Fastest, zero JS in request path, extension never sees traffic. Reload (recompile) takes seconds. |
| Web Extension (MV3) `declarativeNetRequest` | Supported Safari 15.4+. Dynamic/session rules update instantly. | Carries per-site script/frame policy (the NoScript half). |
| Content scripts | Supported, `document_start` | Element picker, page script inventory, cosmetic fallbacks. |
| Native messaging | `sendNativeMessage` → `SFSafariWebExtensionHandler` (Swift, in-bundle) | Filter list download + ABP→Safari JSON conversion happen in Swift, not JS. |
| Distribution | Must ship inside a signed macOS app (App Store or Developer ID + notarization). | One Xcode project, one app, several extension targets. |
| Blocked-request counts | Content blockers do not report matches. | Badge counts are approximate (see §5.4). |

## 2. Goals

- Block ads and trackers on par with uBO default lists (EasyList, EasyPrivacy, uBO filters, Peter Lowe).
- Per-site script control: trust / default / strict / untrusted, one click from the toolbar.
- Per-site "disable blocking" allowlist.
- Element picker producing persistent user cosmetic rules.
- Auto-updating lists without the host app running.
- Open-source, no telemetry, no network calls except list downloads.

## 3. Non-goals (v1)

- Procedural cosmetic filters (`:has-text`, `:xpath`, …).
- uBO scriptlets (`##+js(...)`) and redirect resources.
- Dynamic filtering matrix (uMatrix-style per-type grid).
- iOS/iPadOS (architecture permits it later; not targeted).
- Sync across devices.

## 4. Architecture

```
bl0cksh1t.app (SwiftUI; settings, list manager, onboarding)
├── ContentBlocker-Ads        (Safari Content Blocker)  EasyList + uBO filters
├── ContentBlocker-Privacy    (Safari Content Blocker)  EasyPrivacy + Peter Lowe + uBO privacy
├── ContentBlocker-Annoyances (Safari Content Blocker)  off by default
├── ContentBlocker-User       (Safari Content Blocker)  user cosmetic + network rules
└── WebExtension              (Safari Web Extension, MV3)
    ├── background.js         popup state, per-site policy → dNR dynamic rules, alarms
    ├── content.js            script inventory, element picker
    ├── popup/                 toolbar panel
    └── SafariWebExtensionHandler.swift   list fetch, convert, write, reload
```

Shared state lives in an App Group container (`group.<bundle-prefix>.bl0cksh1t`):
`UserDefaults` for settings/policies, files for compiled rule JSON.

### 4.1 Static blocking (Content Blockers)

1. Native handler downloads raw ABP-syntax lists on a schedule (web extension
   `browser.alarms` → `sendNativeMessage("updateLists")`), so updates run
   while Safari is open even if the app isn't.
2. Converts with AdGuard `SafariConverterLib` (Swift package, GPL-3; proven at
   scale, handles the ABP→Safari subset, reports unsupported rules).
3. Shards output ≤150,000 rules per target, writes `blockerList.json` per
   target into the App Group container.
4. Appends allowlist rules: for every allowlisted site, one
   `ignore-previous-rules` rule with `if-top-url` to every shard.
5. `SFContentBlockerManager.reloadContentBlocker(withIdentifier:)` per target.

Allowlist changes reuse the cached converted base and only redo steps 4–5.

### 4.2 Per-site script policy (Web Extension dNR)

Four per-site states, stored keyed by eTLD+1:

| State | Effect |
|---|---|
| **Trusted** | Nothing blocked on this site (allowlisted in CBs, no dNR rules). |
| **Default** | Ads/trackers blocked. Scripts allowed. |
| **Strict** | Default + block third-party `script`, `sub_frame`, `websocket` via dNR dynamic rules, except per-origin exceptions the user grants from the panel. |
| **Untrusted** | Strict + block first-party scripts. Inline scripts via dNR `modifyHeaders` injecting `Content-Security-Policy: script-src 'none'`. |

Global default state is configurable (Default or Strict). Strict-by-default
is the NoScript experience.

### 4.2.1 dNR rule mapping (Phase 2 implementation)

Strict/Untrusted for one eTLD+1 are compiled to at most three dynamic
rules (`WebExtension/Resources/policy.js`, pure + node-tested):

| id | state | action | condition |
|---|---|---|---|
| base | strict, untrusted | `block` | `initiatorDomains: [site]`, `notRequestDomains: [site, …allowOrigins]`, `resourceTypes: [script, sub_frame, websocket]` |
| base+1 | untrusted | `block` | `initiatorDomains: [site]`, `requestDomains: [site]`, `resourceTypes: [script]` |
| base+2 | untrusted, only if `modifyHeaders` is probed OK | `modifyHeaders` — `content-security-policy: set <csp>` | `requestDomains: [site]`, `resourceTypes: [document]` |

- `base` = FNV-1a(eTLD+1) mod 2^30, so the whole set is recomputed on
  every change and applied as a diff — rules replace in place, never
  accumulate (pending spike S2 confirms `initiatorDomains`/
  `notRequestDomains` matching; see §8).
- CSP value: `script-src 'none'`, or `script-src https://<each
  allowOrigin>` when the user granted exceptions (first-party stays
  blocked, matching the base+1 rule).
- **Strict global default:** dNR cannot express "third-party" without a
  concrete domain, so unvisited sites under a strict global default get
  rules only once their top-level origin is observed (content-script
  inventory push + `tabs` events, in-memory set capped at 200). An
  explicit per-site policy always beats the global default.
- **modifyHeaders probe:** one cold-start round-trip installs/removes an
  inert `modifyHeaders` rule. On failure Untrusted degrades to base+base+1
  (SPEC §5.5) and the panel says so.
- Policy edits made from the host app (different process) are picked up by
  a 30 s `getState` poll plus the tab-activation/`policyChanged` triggers.

### 4.3 Cosmetic filtering

- List-derived element hiding → `css-display-none` rules in the CB shards
  (converter handles it).
- Element picker (content script) → CSS selector → `##` rule in user rules →
  ContentBlocker-User recompiled (small list, fast). Picker UX: hover
  highlight, click → hide preview + confirm bar (Esc cancels). Selector
  strategy: `#id` if present, else a `tag.class` chain disambiguated with
  `:nth-child`. Saved rules are scoped to the page's eTLD+1
  (`site.com##selector`), so they never leak to other sites.
- Generic hiding fallback in content script: none in v1 (non-goal).

### 4.4 Toolbar panel

- Site name, current state, four-state switch.
- Script inventory: origins of `<script src>` / `<iframe src>` found in the
  DOM, grouped 1st/3rd party, each with allow/block toggle (feeds Strict
  exceptions).
- Approximate blocked count.
- Buttons: element picker, open settings, reload page.

### 4.5 Host app

- List manager: enable/disable built-in lists, add custom list URL, update now,
  last-updated + rule counts + unsupported-rule count per list.
- Global default state, per-site overrides table (edit/delete).
- User rules editor (plain textarea, ABP syntax).
- Onboarding: deep-link to Safari › Settings › Extensions; detect enabled state
  via `SFContentBlockerManager.getStateOfContentBlocker`.

## 5. Behaviours and edge cases

### 5.1 First launch
Ship pre-converted JSON for default lists in the bundle so blocking works
before the first download completes.

### 5.2 Rule budget
If a shard exceeds 150,000 after conversion, drop lowest-priority list rules
first (order: annoyances → cosmetic generic → network). Surface the count in
the list manager. Never silently truncate user rules.

### 5.3 Reload latency
CB recompilation is seconds. Panel shows a spinner on state change; the page
auto-reloads when the reload callback returns.

### 5.4 Blocked count
`ponytail:` heuristic — content script counts DOM resource origins absent
from `performance.getEntriesByType("resource")`. Undercounts (beacons,
XHR) and can overcount (lazy loads). Labelled "≈" in the UI. Upgrade path:
none exists on Safari; accept.

### 5.5 Untrusted + CSP
If dNR `modifyHeaders` proves unavailable (see PLAN spike S2), Untrusted
degrades to Strict + first-party `script` blocking only, and the panel
says so.

### 5.6 Privacy
No analytics. Only outbound traffic is list downloads over HTTPS to the
URLs the user has enabled. Per-site state never leaves the device.

## 6. Storage schema (App Group UserDefaults)

```json
{
  "globalDefault": "default" | "strict",
  "sites": { "example.com": { "state": "strict", "allowOrigins": ["cdn.example.net"] } },
  "lists":  { "<id>": { "url": "...", "enabled": true, "updatedAt": 0, "ruleCount": 0, "unsupported": 0 } },
  "userRules": "string, ABP syntax, newline-separated",
  "updateIntervalHours": 24
}
```

## 7. Licensing

GPL-3.0 (forced by SafariConverterLib and compatible with EasyList/uBO
filter licences). Alternative: write a converter for the ABP subset we need
under a permissive licence — deferred unless GPL is unacceptable.

## 8. Phase 0 spike results

### S1 — converter budget (PASS)

Measured 2026-10-22 on macOS 26.7 (M5 Max), SafariConverterLib 4.3.1,
target Safari v26. Reproduce: `spikes/S1-converter` (see spikes/README.md).

| list | source lines | Safari rules | advanced (scriptlets/extended CSS — non-goal v1) | unsupported |
|---|---|---|---|---|
| EasyList | 84,993 | 66,651 | 464 | 37 |
| EasyPrivacy | 56,365 | 56,387 | 35 | 42 |
| uBO filters | 6,215 | 3,049 | 3,089 | 336 |
| uBO privacy | 1,257 | 958 | 303 | 532 |
| uBO badware | 4,693 | 4,891 | 40 | 322 |
| uBO unbreak | 2,178 | 1,402 | 423 | 390 |
| uBO quick-fixes | 518 | 272 | 210 | 51 |
| Peter Lowe | 3,573 | 3,573 | 0 | 0 |
| uBO annoyances (off by default) | 3,554 | 634 | 2,872 | 72 |

Combined per-shard totals (default-enabled lists):

| shard | rules | time | budget (150k / 30 s) |
|---|---|---|---|
| ads (EasyList, uBO filters, unbreak, quick-fixes) | 71,259 | 0.95 s | PASS |
| privacy (EasyPrivacy, uBO privacy, Peter Lowe, badware) | 65,806 | 0.59 s | PASS |
| annoyances (off) | 634 | 0.10 s | PASS |

Decisions:
- Keep the 4-target layout (ads / privacy / annoyances / user). Headroom
  ~48% before the overflow policy (SPEC §5.2) engages.
- Roughly half of uBO filters and most of uBO annoyances are advanced
  rules (scriptlets, extended CSS, redirects) that v1 does not apply
  (non-goals, §3). The list manager surfaces per-list counts per FR-7 so
  this loss is visible, not silent.
- uBO list URLs moved: `uBlockOrigin/uBlockfilters/gh-pages` 404s; the
  canonical mirror is now `uBlockOrigin/uAssets` (`filters/*.txt`, privacy
  list renamed to `privacy.txt`, annoyances split into `annoyances-*.txt`).

### S2, S3, S4, S5 — pending

Run via the spike app (`spikes/SpikeApp`, see spikes/README.md). Results
fill in here when observed in Safari; S2 decides FR-14, S3 decides the
update path (§4.1), S4 ratifies the allowlist rule shape, S5 decides FR-5.

### Phase 2 verification (manual, 2026-10-23)

Policy→dNR mapping is unit-tested in node (`Tests/policy.test.js`) and the
extension builds clean; the behavioural matrix needs a signed Safari run:

1. `xcodegen generate && sh Scripts/build.sh build`
2. Serve the test pages: `python3 -m http.server -d Tests/pages 8000`
3. In Safari: enable bl0cksh1t + all content blockers + the web extension
   (app onboarding screen links to the settings page), then open
   `http://127.0.0.1:8000/index.html`.
4. `ads.html` — Phase 1 re-check: all rows BLOCKED + cosmetic box hidden;
   set the site Trusted from the toolbar panel → auto-reload → all LOADED,
   box visible (FR-11).
5. `scripts.html?expect=<state>` for each of the four states after
   switching in the panel — the verdict line must read PASS. This is the
   FR-10..FR-16 exit matrix; it also observes S2's open questions
   (`initiatorDomains`/`notRequestDomains` matching on the page origin,
   `modifyHeaders` for inline scripts). Note the page origin is an IP
   host (127.0.0.1); if initiator-domain matching fails only for IPs,
   repeat with a hostname (e.g. `127.0.0.1 bl0cksh1t.localhost` in
   /etc/hosts → `http://bl0cksh1t.localhost:8000`).
6. Under Strict on scripts.html, allow `connect.facebook.net` (or
   `googletagmanager.com`) from the panel → auto-reload → that resource
   LOADED again, the other still BLOCKED (FR-13).
7. Quit Safari, relaunch → states and allowances still applied (persistence
   via the App Group).

### Phase 3 verification (manual, 2026-10-23)

Picker + user-rule diagnostics logic is covered by stubbed-DOM node
harnesses and XCTest (`testCompileUserShard*`,
`testUserRuleDiagnosticsReportsPerLine`); the picker's end-to-end path
needs Safari:

1. Open `http://127.0.0.1:8000/ads.html` (or any http page) with bl0cksh1t
   enabled.
2. Toolbar panel → **Pick element** → hover the green cosmetic box (or any
   element) → click → it disappears (preview) → confirm bar → **Save** →
   the tab auto-reloads and the element stays hidden (the saved
   `127.0.0.1##…` / site-scoped rule is now in the User shard). The rule
   shows in the app's User rules editor.
3. Pick the same element again → saving is a no-op (rule already present).
4. App → User rules: add an invalid line (e.g. a bare `##`) and save →
   the line is listed with its number and reason (FR-31); valid lines and
   `##+js(…)` scriptlets are labelled "advanced — not applied in v1".
5. Set the site to **Trusted** → reload → picked element visible again
   (allowlist rules sit after the user rules in the User shard).
