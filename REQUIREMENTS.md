# bl0cksh1t — Requirements

P0 = v1 ships without it is pointless. P1 = v1 should have. P2 = later.

## Functional

### Blocking
| ID | P | Requirement |
|---|---|---|
| FR-1 | P0 | Block network requests matching enabled filter lists (network rules) on every Safari tab, including private windows, with no per-request JS. |
| FR-2 | P0 | Hide elements matching enabled lists' cosmetic rules. |
| FR-3 | P0 | Ship with EasyList, EasyPrivacy, uBO filters (ads, privacy, badware, unbreaking, quick-fixes), Peter Lowe's list enabled; uBO annoyances available but off. |
| FR-4 | P0 | Blocking works immediately after install from bundled pre-converted rules. |
| FR-5 | P0 | Lists auto-update at a configurable interval (default 24h) without the host app running. |
| FR-6 | P1 | User can add a custom list by URL and enable/disable any list. |
| FR-7 | P1 | Rule counts, unsupported-rule counts, and last update time are visible per list. |

### Per-site control
| ID | P | Requirement |
|---|---|---|
| FR-10 | P0 | Four site states: Trusted, Default, Strict, Untrusted, switchable from the toolbar panel, persisted per eTLD+1. |
| FR-11 | P0 | Trusted disables all blocking (network + cosmetic) for that site. |
| FR-12 | P0 | Strict blocks third-party scripts, sub-frames, and websockets. |
| FR-13 | P0 | Within Strict, user can allow individual third-party origins for that site from the panel; the allowance persists. |
| FR-14 | P1 | Untrusted additionally blocks first-party scripts and inline scripts (CSP). Degrades gracefully if header modification is unavailable (SPEC §5.5). |
| FR-15 | P0 | Global default state selectable: Default or Strict. |
| FR-16 | P0 | State changes take effect on next page load; the panel reloads the page automatically once rules are active. dNR changes < 100 ms; CB recompile shows progress. |
| FR-17 | P1 | Temporary allow: "Trust for this tab/session" without persisting. |

### Panel
| ID | P | Requirement |
|---|---|---|
| FR-20 | P0 | Shows current site, state switch, script/frame origins found on page grouped 1st/3rd party with per-origin toggle. |
| FR-21 | P1 | Shows approximate blocked count, clearly marked approximate. |
| FR-22 | P0 | Element picker: click an element → preview → save as user cosmetic rule for this site. |
| FR-23 | P1 | Keyboard navigable; works in Safari light/dark. |

### User rules
| ID | P | Requirement |
|---|---|---|
| FR-30 | P0 | Freeform user rules in ABP syntax (network + `##` cosmetic), applied via a dedicated content blocker. |
| FR-31 | P1 | Invalid/unsupported user rules are reported with line numbers, not silently dropped. |
| FR-32 | P2 | Import/export settings + rules as JSON. |

### App
| ID | P | Requirement |
|---|---|---|
| FR-40 | P0 | Onboarding detects whether each extension is enabled in Safari and links to Safari Extensions settings. |
| FR-41 | P0 | Settings: lists, global default, per-site table (view/edit/delete), user rules, update interval, "Update now". |
| FR-42 | P1 | Menu-bar-less: app may be quit after setup; everything keeps working. |

## Non-functional

| ID | P | Requirement |
|---|---|---|
| NFR-1 | P0 | No telemetry, analytics, or network traffic other than list downloads to user-enabled URLs. |
| NFR-2 | P0 | Each content blocker ≤ 150,000 rules; overflow handled per SPEC §5.2, never silently. |
| NFR-3 | P0 | Full conversion of default lists completes < 30 s on Apple Silicon; allowlist-only recompile < 5 s. |
| NFR-4 | P0 | Web extension background is non-persistent; idle memory negligible. Content script adds < 5 ms to `document_start`. |
| NFR-5 | P0 | macOS 14+ (Sonoma) minimum. Safari 17+. |
| NFR-6 | P0 | Signed and notarized; Developer ID build first, App Store later. |
| NFR-7 | P0 | Open source, GPL-3.0. |
| NFR-8 | P1 | Converter and policy→dNR mapping covered by unit tests; one end-to-end check page in-repo. |
| NFR-9 | P1 | Hardened runtime + App Sandbox on all targets. Network entitlement only on the extension handler and app. |
| NFR-10 | P2 | Localizable strings; English only shipped. |

## Explicitly out of scope (v1)
Procedural cosmetics, scriptlets, redirect resources, per-type filtering
matrix, iOS, sync, logger/request inspector (impossible on Safari).
