# Fleet audit — the "grep-only-no-compile" Swift test-lane defect class

**Date:** 2026-07-15 · **Seat:** circuit-engineer · **Contract:** contract_76a7da61224de61733d80c4a6ed1e7f9
**Posture:** read-only reporting. No peer seat dispatched. b5 left STAGED behind `circuit.GO`. Authenticode untouched.

## Headline — the dispatched premise is FALSIFIED

The audit was dispatched to find the **grep-only-no-compile** defect class: Swift test lanes that assert
symbols by matching source text without ever type-checking them.

**No seat in the fleet is grep-only.** Every Swift-bearing seat with a Swift test lane invokes a real
compiler (`swiftc` / `xcodebuild`) on real app sources. The hypothesised defect class does not exist here.

The real defect is a different, quieter one, and the hypothesis would have walked straight past it:

> **COMPILE COVERAGE, not compile ABSENCE.** Three lanes compile a hand-picked SUBSET of their sources
> with no guard that notices the unlisted remainder. A file dropped from the list is not a red test —
> it is silence. `BlackLabelRealEstate/run_tests.command:7` records that exactly this drift once let
> **22 files sit outside the test compile unnoticed**.

Grep assertions DO exist (Academy, Sovereign), but each sits **behind** a compile gate and is documented
as a source-contract lock, not as proof of behaviour. That is a legitimate pattern, not the defect.

## Report table — one row per Swift-bearing seat

| Seat | Tree | Test entrypoint | Compile or grep? | One-line proof (reproduced) |
|---|---|---|---|---|
| **circuit-engineer** (reference) | `~/Circuit` | `npm test` → `test/launcher.test.js` | **COMPILE — fails closed, mutation-proven** | Injected `let _x: Int = "s"` into `macos/CircuitLauncher.swift` → `fail 2` (`swiftc -typecheck failed for arm64…`, `…x86_64…`); restored byte-identical |
| **realestate-engineer** | `~/BlackLabelRealEstate` | `run_tests.command` | **COMPILE + anti-drift manifest — best in fleet** | 65 `Sources/*.swift`: **64 compiled, 1 excluded-with-reason, 0 unclassified** → guard green |
| **sovereign-engineer** | `~/BlackLabelSovereign` | `tests/run.command` | **COMPILE — globs all sources** | `tests/run.command:32` `xcrun swiftc`; source list = `for f in Sources/*.swift` minus `main.swift` → no hand-list to drift |
| **marketing-engineer** | `~/BlackLabelMarketing` | `tests/typecheck.sh` | **COMPILE — globs all sources** | `typecheck.sh:19` `xcrun swiftc -typecheck`; sources = `find "$SRC" -name '*.swift'` → whole-module |
| **academy-engineer** | `~/BlackLabelAcademy` | `tests/xctest.sh` (+ pytest contract locks) | **COMPILE — `xcodebuild test` + zero-test guard** | `xctest.sh:33` `xcodebuild test`; parses `Executed N tests` and fails on 0/absent; test scheme has 10 `BuildableReference` |
| **trading-engineer** | `~/BlackLabelTrading` | `tests/run-tests.sh` | COMPILE — **subset, no drift guard** | `run-tests.sh:41` `xcrun --sdk macosx swiftc`; **20 of 36** `Sources/*.swift` in a hand-written `SOURCES=()` array |
| **sunset-engineer** | `~/BlackLabelAcetate` | `tests/run_audio_regression.sh` | COMPILE — **subset, no drift guard** | `run_audio_regression.sh:50` `swiftc`; **15 of ~40** app sources in a hand-written `SOURCES=()` array |
| **homefront-engineer** | `~/BlackLabelHome` | `test.sh` | COMPILE — **subset, no drift guard** | `test.sh:27` `swiftc -O -sdk …`; **7 of 19** top-level sources; 12 uncompiled (below) |
| **client-engineer-1** | `~/Blackwater` (`worker-ios`) | `ops`: `node --test tests/*.test.js` | **NO Swift compile in the local lane** | `grep -c swiftc ops/tests/*.js` → **0**. Swift compiles only in GH Actions `xcodebuild archive` |

Seats with no Swift and therefore no row: `leads-engineer` (`~/BlackLabelLeads` **absent from disk**),
`gcwars-site-engineer`, `asgolf-site-engineer`, `client-engineer-2`, `outreach-operator`.

## Findings, per owning seat, with the specific missing step

### 1. `homefront-engineer` — 12 of 19 top-level sources never type-checked by `test.sh`
`BlackLabelHome/test.sh:27` compiles a fixed 7-file list. Uncompiled:
`AwayAlertsViews, ClimateViews, Discovery, EnergyViews, Geofence, HomeStore, HomeViews, Homefront,
MenuBarViews, SensorViews, VigilHouse3DView, VigilHouseView`.
`Homefront.swift` is the app entry; `HomeStore`/`Geofence` are logic, not just views.
**Missing step:** adopt RealEstate's anti-drift manifest — classify every `*.swift` as compiled or
excluded-with-a-named-reason, and fail on unclassified.

### 2. `trading-engineer` — 16 of 36 sources outside the test compile, hand-list drift
`BlackLabelTrading/tests/run-tests.sh:41`. Uncompiled include `Execution.swift`, `TradingKeychain.swift`,
`Auth.swift`, `FeedClient.swift`, `Model.swift` — money/credential-adjacent, not merely UI.
**Missing step:** same anti-drift manifest + guard.

### 3. `sunset-engineer` — 15 of ~40 sources compiled, hand-list drift
`BlackLabelAcetate/tests/run_audio_regression.sh:50`.
**Missing step:** same anti-drift manifest + guard.

### 4. `client-engineer-1` — no Swift compile in the routine lane
`ops` `npm test` is `node --test tests/*.test.js`; zero `swiftc` references. The only compile of the 11
`worker-ios/Sources/*.swift` is `.github/workflows/worker-ios-release.yml:180` (`xcodebuild archive`),
triggered on `workflow_dispatch` or `push` limited to `paths: worker-ios/**`.
`worker-ios/ci/appstore_toolchain_guard.sh` **is not a compile** — it only runs `xcodebuild -version`
to refuse beta toolchains (line 15).
**Nuance (do not overstate):** the Swift IS compiled on any push touching `worker-ios/**`. The gap is
that an ops-side change cannot turn the iOS Swift red locally, and a developer running the seat's test
lane gets no Swift signal at all.
**Missing step:** a local `swiftc -typecheck` gate over `worker-ios/Sources/*.swift` in the ops lane
(Circuit's `launcher.test.js` is a drop-in shape), so Swift breakage is not release-time-only.

## The reference "good" pattern — and its honest limits

`Circuit/test/launcher.test.js` is the pattern the fleet should copy, on three properties:
1. **It compiles** — `xcrun swiftc -typecheck -parse-as-library` per shipped arch (`arm64`, `x86_64`).
2. **A missing toolchain is a FAILURE, not a skip** — `macosSDKPath()` calls `assert.fail` when `xcrun`
   is unavailable, so "we could not compile" can never be reported as "the Swift compiles."
3. **It is load-bearing** — proven by mutation, not by assertion (below).

**Limits, stated plainly:** Circuit has exactly **1** Swift file, so "full coverage" is trivial for this
seat and is NOT evidence the pattern scales. **`realestate-engineer`'s anti-drift manifest is the
stronger pattern at fleet scale** (65 files, 0 unclassified) and is what findings 1–3 should adopt.
Circuit contributes the fail-closed toolchain check and the mutation proof; RealEstate contributes
coverage enforcement. The two are complementary.

## Reproductions (commands, not claims)

**Circuit gate is load-bearing** — the only mutation test run in this audit:
```
$ printf '\nlet _deliberateTypeError: Int = "not an int"\n' >> macos/CircuitLauncher.swift
$ node --test test/launcher.test.js
ℹ tests 5 / ℹ pass 3 / ℹ fail 2
  AssertionError: swiftc -typecheck failed for arm64-apple-macosx11.0 (exit 1) — the macOS launcher does not compile
  AssertionError: swiftc -typecheck failed for x86_64-apple-macosx11.0 (exit 1) — the macOS launcher does not compile
$ # restored: sha256 ab471fa2…4392a == backup; `git status --short` empty
```
Clean baseline: `npm test` → `tests 125 / pass 125 / fail 0 / skipped 0`.

**RealEstate guard green:** `Sources on disk: 65 | compiled: 64 | excluded-with-reason: 1 | unclassified: NONE`.

**Blackwater has no local Swift compile:** `grep -c 'swiftc' ops/tests/*.js` → `0`.

## Corrections to standing assumptions (recorded so they are not re-inherited)

- **The dispatch's "run 29206008027 (123 pass + 2 honest darwin skips)" was NOT verified here.**
  `gh` is logged out (`gh auth login` required), so the CI run's conclusion is **unconfirmed by this
  audit**. What IS reproduced is the LOCAL darwin run: **125 pass, 0 skipped** — on darwin the two
  Swift gates RUN rather than skip, which is consistent with (but not proof of) the 2 skips being the
  Windows runner.
- **The circuit-engineer charter is stale on ship truth.** It states "latest ship: build 2, commit
  `8b2539c`". `ships.jsonl` actually records **build 4, commit `bd96996`**, notarized 2026-07-12.
  Charter should be corrected; `ships.jsonl` is the only ship record.
- **`~/BlackLabelLeads` does not exist on disk**, though `leads-engineer` is a live seat and
  `BlackLabelHome/test.sh:19` cites `BlackLabelLeads/Tests/run-tests.command` as a passing fleet runner.
  The Leads Swift lives at `~/BlackLabelSwift/xcode/Leads`. Flagged for the owning seat, not chased here.
- **`tests/` and `Tests/` are the SAME directory** on this case-insensitive filesystem. Fleet-wide greps
  double-count them; this report deduplicates.

## b5 ship-decision state (read-only probe — nothing touched, nothing published)

Verified today, since the ship decision had to be routed somewhere real:

- **b5 IS genuinely staged and sealed.** `work/circuit-stage/Circuit.app` → `CFBundleVersion` **5**,
  `xcrun stapler validate` → "The validate action worked!", `spctl -a -vvv -t install` →
  **Notarized Developer ID … 745ZPGFRA5**. `provenance.json`: commit `54222ab`, built 2026-07-12T16:30:48Z.
  (An earlier read of mine saw no `circuit-b5*` and nearly reported "b5 is not staged" — that was wrong;
  b5 is staged as an unzipped bundle, not as a `-b5.zip`. Corrected before it reached this report.)
- **b5 is NOT a mintable GO-board row yet.** Every GO-READY row cites a `<app>-bN.zip` + `.sha256`
  sidecar. b5 has **neither** — no `work/circuit-b5.zip`, no sidecar. `work/circuit.zip` hashes to
  `163f21f1…` = the **shipped build 4**, not b5.
- **The GO board is STALE on Circuit.** `STATE/FOUNDER-GO-BOARD.md` row **(h)** is still
  "Circuit **b4** publish — 🔒 DOUBLE-GATED (price ruling)" citing `067d8d50…`. But `ships.jsonl`
  records **build 4 SHIPPED** (`dry_run:false`) at 2026-07-12T11:38:04Z, sha `163f21f1…`, notary
  `5a2ddcc4…`, and `circuit-manifest.json` reads `latest_build: 4`, `published: 2026-07-12T11:38:02Z`.
  Row (h) is therefore **SUPERSEDED-SHIPPED**, and b5 (built 16:30Z, five hours later) has no row at all.

**Not actioned by this seat, deliberately.** The GO board is `construction-engineer`'s single-writer
surface under the `founder-go-board` / `infra-goboard` lock; this seat holds only the `circuit` lock.
Minting a b5 row is construction-engineer's write, on founder authority — not mine to force.

## Founder gate — routed, not forced

🔒 **Publishing Circuit b5 remains gated on `circuit.GO`.** b5 stays staged; this audit changed no ship
state. `ships.jsonl` byte-identical, verified by SHA before and after:
`5753826d7e904e5aae874011fdaa5317377fe5cbce5ec8d67e332fb3a3d557ba`. Ship decision → HQ Review Inbox.
🔒 Authenticode cert purchase remains a founder money gate (§3). Untouched.
