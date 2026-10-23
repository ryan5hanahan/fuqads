# bl0cksh1t — Plan

Environment: Xcode 27.1, macOS 26.7, Swift 6, SwiftUI. Web extension in
plain JS (no bundler, no framework). Converter via Swift Package dependency.

## Phase 0 — Spikes (1 week, throwaway code, each answers one question)

| ID | Question | Pass criterion |
|---|---|---|
| S1 | Does `SafariConverterLib` convert EasyList + EasyPrivacy + uBO filters within the 150k/shard budget and < 30 s? | Rule counts per list, timing, unsupported-rule report. Decide shard layout. |
| S2 | Does Safari's dNR support `modifyHeaders` (CSP injection) and `initiatorDomains`/`requestDomains`/`domainType`? | Test extension with each condition; record what matches. Decides FR-14 and the Strict rule shape. |
| S3 | Can `SFContentBlockerManager.reloadContentBlocker` be called from the web extension's native handler (not the app)? Reload latency for a 150k shard? | Measured seconds. Decides whether updates need the app process. |
| S4 | Does `ignore-previous-rules` + `if-top-url` in each shard fully allowlist a site, including cosmetic rules? | Trusted site shows ads. |
| S5 | `browser.alarms` fires in Safari non-persistent background while app is closed? | Log over 48h. Decides FR-5 mechanism (fallback: `NSBackgroundActivityScheduler` login item). |

Outcomes are written back into SPEC.md. Anything that fails changes the spec, not the code.

## Phase 1 — Static blocking MVP (2 weeks)

1. Xcode project: app + 4 content blocker targets + web extension target, App Group, shared Swift package `BlockerCore` (conversion, sharding, storage).
2. `BlockerCore`: `ListStore` (fetch, cache raw text), `Compiler` (convert → shard → append allowlist → write JSON), `Reloader`.
3. Build-time script generates bundled `blockerList.json` per shard from pinned list snapshots (FR-4).
4. Native handler: `updateLists`, `setSiteState`, `getState` messages.
5. Background.js: alarm → `updateLists`.
6. Minimal app: enable-extensions onboarding, "Update now", list toggles.
7. Tests: XCTest on `Compiler` (sharding boundaries, allowlist append, overflow policy). One fixture list.

Exit: ads blocked on a known test page set; Trusted works via allowlist; lists update on schedule.

## Phase 2 — NoScript half (2 weeks)

1. Policy model in `BlockerCore` (`SiteState`, exceptions) shared via App Group.
2. Background.js: `policy → dNR dynamic rules` pure function + apply on change. Rule IDs derived deterministically from eTLD+1 hash so updates replace, not accumulate.
3. Content script: script/frame origin inventory, posted to background on load and on DOM mutation (debounced).
4. Popup: state switch, origin list with toggles, spinner during CB reload, auto page reload.
5. Untrusted via CSP if S2 passed; otherwise degraded mode text.
6. Tests: node `assert` script for `policyToRules()` (pure JS, no framework). Manual matrix: 4 states × 1st/3rd-party script page.

Exit: Strict mode blocks 3rd-party scripts on a test page, per-origin allow restores them, state survives restart.

## Phase 3 — User rules + picker (1 week)

1. Element picker content script: hover highlight, click → selector (id > class chain > nth-child), preview hide, confirm.
2. Save as `site.com##selector` into `userRules`; compile ContentBlocker-User only.
3. User rules editor in app with per-line error list from the converter.

Exit: pick an element, reload, it stays hidden; invalid rule shows a line error.

## Phase 4 — Polish and ship (1–2 weeks)

1. Approximate blocked count (SPEC §5.4).
2. Per-site table in app, temporary trust (FR-17), custom list URLs (FR-6).
3. App Sandbox + hardened runtime on every target; network entitlement audit.
4. Developer ID signing, notarization, DMG. GitHub release + Sparkle later if needed (not v1).
5. README, LICENSE (GPL-3.0), test page in `tests/pages/`.

## Repo layout

```
bl0cksh1t.xcodeproj
App/                      SwiftUI host app
Blockers/Ads|Privacy|Annoyances|User/   each: Info.plist + ContentBlockerRequestHandler.swift
WebExtension/
  Resources/manifest.json background.js content.js popup.{html,js,css}
  SafariWebExtensionHandler.swift
BlockerCore/              Swift package: ListStore, Compiler, Reloader, Policy
Scripts/bundle-lists.sh   pins + pre-converts default lists at build time
tests/
  BlockerCoreTests/       XCTest
  policy.test.js          node assert
  pages/                  local HTML pages exercising each state
```

## Risks

| Risk | Mitigation |
|---|---|
| Safari dNR gaps (S2) | Degraded Untrusted mode already specified. |
| Lists outgrow 4×150k | Add a shard target; deterministic overflow policy. |
| GPL via converter | Acceptable for v1; permissive own converter is a bounded later task. |
| CB reload UX feels slow | Spinner + auto reload; allowlist path only recompiles appended rules. |
| App Store review (content blockers + web extension in one app) | Established pattern (AdGuard, 1Blocker). Ship Developer ID first. |

## Skipped on purpose
Procedural cosmetics, scriptlets, request logger, sync, iOS — see SPEC §3.
Add when v1 is in daily use and a concrete site breaks without them.
