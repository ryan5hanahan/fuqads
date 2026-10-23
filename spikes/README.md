# Phase 0 spikes

Each spike answers one question from PLAN.md §Phase 0. Results get written
back into `SPEC.md`; a failing spike changes the spec, not the code.

## S1 — converter budget (headless, no Safari needed)

`spikes/S1-converter` converts the default lists with
`SafariConverterLib 4.3.1` and reports per-list + per-shard rule counts,
timing, and unsupported-rule counts.

```
cd spikes/S1-converter
swift run S1Converter                 # downloads lists, converts, writes report.md
swift run S1Converter --offline       # reuse lists/*.txt
swift run S1Converter --version 16.4  # conservative target (Safari 17+ floor)
swift run S1Converter --dump          # also write combined shard JSON to out/
```

Pass: every default-enabled shard < 150k rules and < 30 s (NFR-3).

## S2–S5 — spike app (needs Safari)

One host app + one content blocker (`SpikeCB`) + one web extension
(`SpikeWE`). Build:

```
cd spikes/SpikeApp
python3 Scripts/gen-spike-data.py     # CB rule lists + ad.png (already committed)
xcodegen
xcodebuild -project Spike.xcodeproj -scheme Spike -configuration Release build
open build/Release/Spike.app          # or: xcodebuild ... -scheme Spike run
```

Then in **Safari › Settings › Extensions** enable *bl0cksh1t spike (cb)* and
*bl0cksh1t spike (web)*. The app UI drives each spike and shows live logs.

All logs land in the App Group container:
`~/Library/Group Containers/group.dev.bl0cksh1t/` (`s2.jsonl`, `s3.jsonl`,
`s5.jsonl`).

### S2 — dNR capabilities (`s2.jsonl` + the s2.html page)

background.js registers five dynamic rules on install:

| id | condition | question |
|----|-----------|----------|
| 1  | `modifyHeaders` CSP `script-src 'none'` on `main_frame` | does Safari support header modification? (FR-14) |
| 2  | `initiatorDomains: ["127.0.0.1"]` | initiator matching |
| 3  | `requestDomains: ["127.0.0.1"]` | request-domain matching |
| 4  | `domainType: "thirdParty"` on a 1st-party request | negative test: must NOT block |
| 5  | plain block | baseline: dynamic rules work at all |

s2.html probes each with a fetch and self-reports. PASS criteria per rule:
1 → inline script on s2.html does not run; 2,3,5 → fetch blocked; 4 → fetch
succeeds. Any `dnr-add ok:false` line in `s2.jsonl` records an unsupported
construct (its error text goes into the SPEC §5.5 degraded-mode decision).

### S3 — CB reload from the native handler (`s3.jsonl`)

- *Handler* probe: `SpikeWE`'s `SafariWebExtensionHandler` rewrites
  `SpikeCB.appex/blockerList.json` (150k or 1 rule) from the extension
  process and calls `SFContentBlockerManager.reloadContentBlocker`. Triggered
  from the app UI, and automatically every 5 min while Safari is open.
- *App* probe: same rewrite + reload from the host app (baseline).

Pass: handler-side rewrite + reload succeeds with the app closed; 150k reload
latency recorded (NFR-3: allowlist-only recompile < 5 s; full conversion < 30 s
is S1's, this is recompile time).

### S4 — allowlist shape (`s4.jsonl`-adjacent, visual + `s4.jsonl`)

SpikeCB ships two list shapes:

- `s4-block`: blocks `/ad.png` (image) + hides `#cosmetic-test`
  (`css-display-none`).
- `s4-allow`: same + `ignore-previous-rules` with `if-top-url: 127.0.0.1:8642`
  appended last.

Toggle in the app, reload s4.html in Safari. PASS: block mode hides the ad
pixel and the green box; allow mode shows both — i.e. one appended
`ignore-previous-rules` rule fully allowlists the site including cosmetic
rules.

### S5 — alarms with the app closed (`s5.jsonl`)

Alarms `s5-quick` (5 min) and `s5-hourly` (60 min) log through the native
handler to `s5.jsonl`. Procedure: quit the spike app, leave Safari open,
check `s5.jsonl` after ~30 min (quick signal) and after 48 h (plan criterion).

PASS: entries keep arriving with the app process not running. FAIL → FR-5
falls back to `NSBackgroundActivityScheduler` login item (PLAN S5 fallback).

## Cleanup

Spikes are throwaway. After results are written back into SPEC.md, delete
`spikes/` before Phase 1 merges.
