# BlackLabelRealEstate — converted for windows by Circuit

Generated 2026-09-18T07:16:58.214Z from `/Users/michaelbarber/BlackLabelRealEstate`. The source repo was not modified.

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 22 | 6,945 |
| Converted, builds for Windows | 4 | 973 |
| Builds for Windows with some declarations kept for the Mac | 29 | 4,201 build · 6,763 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 23 | 11,514 |
| **Total app code considered** | **78** | **30,396** |

**39.9% of the app code builds for Windows** (12,119 of 30,396 lines) — measured by the compiler. The port check's estimate before converting was 43.7% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.

## What replaced the Apple-only parts

- `swift-toolchain-sqlite` — https://github.com/swiftlang/swift-toolchain-sqlite.git (from 1.0.0)
- `swift-crypto` — https://github.com/apple/swift-crypto.git (from 3.0.0)
- `OpenCombine` — https://github.com/OpenCombine/OpenCombine.git (from 0.14.0)
- `CircuitPortKit` (in `kit/`) — Logger / os_log, UTType, and the Combine scheduler bridge

## Windows parts still needed

| Apple part | Files | Lines | Size | Windows counterpart |
|---|---:|---:|---|---|
| SwiftUI | 29 | 13,260 | L | WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI) |
| (uses code that was isolated) | 22 | 4,874 |  |  |
| MapKit | 2 | 1,714 | M | a WebView2 map (MapLibre) or the Bing Maps SDK |
| AuthenticationServices | 2 | 525 | M | browser sign-in (OAuth) and WebAuthn through Windows Hello |
| CoreLocation | 1 | 288 | S | Windows.Devices.Geolocation |
| UserNotifications | 1 | 146 | S | Windows toast notifications (AppNotificationManager) |
| Security | 1 | 143 | M | Windows Credential Manager (CredRead/CredWrite) and DPAPI |
| LocalAuthentication | 1 | 143 | M | Windows Hello (UserConsentVerifier) |

## Code kept for the Mac only, with the compiler's reason

- `Sources/AdaptiveLayout.swift` — 51 of 126 lines — 89:11 cannot find type 'Font' in scope (+22 more)
- `Sources/Auth.swift` — whole file (363 lines) — 12:19 cannot find type 'View' in scope (+143 more)
- `Sources/Compat.swift` — 13 of 158 lines — 18:11 cannot find type 'View' in scope (+1 more)
- `Sources/Comps.swift` — 450 of 600 lines — 417:66 cannot find type 'ParcelLookup' in scope (+1 more)
- `Sources/CoverageScreen.swift` — whole file (132 lines) — 17:6 unknown attribute 'State' (+36 more)
- `Sources/CSVImport.swift` — whole file (183 lines) — 122:99 cannot find type 'Lead' in scope (+5 more)
- `Sources/DatabaseListEngine.swift` — 146 of 374 lines — 392:33 cannot find type 'PropertyRecord' in scope (+7 more)
- `Sources/DealAccounting.swift` — 65 of 120 lines — 101:63 cannot find type 'Lead' in scope (+3 more)
- `Sources/DealScorecard.swift` — 229 of 313 lines — 113:39 cannot find type 'Deal' in scope (+7 more)
- `Sources/DealScreens.swift` — whole file (691 lines) — 140:38 cannot find type 'SettingsStore' in scope (+378 more)
- `Sources/DemoData.swift` — whole file (315 lines) — 47:47 cannot find type 'Lead' in scope (+9 more)
- `Sources/Dispositions.swift` — 59 of 83 lines — 77:38 cannot find type 'Deal' in scope
- `Sources/FieldModeScreen.swift` — 288 of 329 lines — 58:32 cannot find type 'CLLocationCoordinate2D' in scope (+146 more)
- `Sources/FileExport.swift` — 17 of 28 lines — 30:17 cannot find 'NSSavePanel' in scope
- `Sources/Holographic.swift` — 573 of 668 lines — 134:17 cannot find type 'Color' in scope (+190 more)
- `Sources/Keychain.swift` — 143 of 352 lines — 245:23 cannot find 'LAContext' in scope (+1 more)
- `Sources/LeadScoring.swift` — 127 of 171 lines — 112:28 cannot find type 'Lead' in scope (+7 more)
- `Sources/LeadScreens.swift` — whole file (599 lines) — 22:6 unknown attribute 'EnvironmentObject' (+543 more)
- `Sources/ListBuilderScreen.swift` — whole file (859 lines) — 23:6 unknown attribute 'EnvironmentObject' (+495 more)
- `Sources/ListEngine.swift` — whole file (212 lines) — 15:22 cannot find type 'LeadSource' in scope (+33 more)
- `Sources/LotFlipScout.swift` — 648 of 871 lines — 494:88 cannot find type 'PropertyRecord' in scope (+10 more)
- `Sources/LotFlipScoutScreen.swift` — whole file (614 lines) — 87:6 unknown attribute 'EnvironmentObject' (+326 more)
- `Sources/MarketIntelligence.swift` — 197 of 483 lines — 340:35 cannot find type 'AppModel' in scope (+117 more)
- `Sources/Model.swift` — 1,044 of 1,345 lines — 169:15 cannot find type 'Color' in scope (+47 more)
- `Sources/MoreScreens.swift` — whole file (915 lines) — 22:45 cannot find type 'Offer' in scope (+696 more)
- `Sources/NationalPropertyBulkImport.swift` — 256 of 335 lines — 88:20 cannot find 'CSVImport' in scope (+2 more)
- `Sources/NationalPropertyIndex.swift` — 150 of 417 lines — 354:20 cannot find 'CSVImport' in scope (+1 more)
- `Sources/OutreachEngine.swift` — 140 of 346 lines — 145:89 cannot find type 'Lead' in scope (+10 more)
- `Sources/OutreachScreens.swift` — whole file (594 lines) — 19:15 cannot find type 'Color' in scope (+497 more)
- `Sources/ParcelLookup.swift` — 604 of 1,331 lines — 886:78 cannot find type 'PropertyPage' in scope
- `Sources/PipelineScreen.swift` — whole file (745 lines) — 17:6 unknown attribute 'EnvironmentObject' (+466 more)
- `Sources/PowerScreens.swift` — whole file (397 lines) — 17:6 unknown attribute 'EnvironmentObject' (+425 more)
- `Sources/Premium.swift` — whole file (216 lines) — 22:35 cannot find 'Color' in scope (+71 more)
- `Sources/PropertyDossier.swift` — whole file (452 lines) — 392:6 unknown attribute 'Binding' (+83 more)
- `Sources/PropertyIndexScreen.swift` — whole file (534 lines) — 29:6 unknown attribute 'EnvironmentObject' (+197 more)
- `Sources/PropertyMapScreen.swift` — whole file (1,426 lines) — 39:21 cannot find type 'CLLocationCoordinate2D' in scope (+126 more)
- `Sources/RealEstateAPI.swift` — 337 of 482 lines — 449:24 cannot find 'Keychain' in scope (+24 more)
- `Sources/RouteScreen.swift` — whole file (221 lines) — 89:38 cannot find type 'SettingsStore' in scope (+123 more)
- `Sources/SavedSearchMonitor.swift` — 59 of 142 lines — 62:38 cannot find type 'PropertyRecord' in scope (+4 more)
- `Sources/SavedSearchMonitorScreen.swift` — whole file (146 lines) — 23:56 cannot find type 'UNUserNotificationCenterDelegate' in scope (+66 more)
- `Sources/Screens.swift` — whole file (1,263 lines) — 77:35 cannot find type 'AppModel' in scope (+860 more)
- `Sources/Settings.swift` — 127 of 147 lines — 27:18 cannot find type 'Color' in scope (+20 more)
- `Sources/SkipTrace.swift` — 56 of 103 lines — 55:35 cannot find type 'Lead' in scope (+8 more)
- `Sources/SkipTraceProvider.swift` — 145 of 297 lines — 150:36 cannot find type 'Lead' in scope (+3 more)
- `Sources/SkipTraceWaterfall.swift` — 99 of 161 lines — 71:35 cannot find type 'Lead' in scope (+5 more)
- `Sources/SocialAuth.swift` — 162 of 247 lines — 33:35 cannot find type 'ASWebAuthenticationPresentationContextProviding' in scope (+8 more)
- `Sources/SourceFinder.swift` — 83 of 157 lines — 86:45 cannot find type 'ParcelLookup' in scope (+3 more)
- `Sources/TeardownScout.swift` — whole file (196 lines) — 80:48 cannot find type 'PropertyRecord' in scope (+3 more)
- `Sources/Theme.swift` — 341 of 458 lines — 410:23 cannot find type 'View' in scope (+167 more)
- `Sources/TitleChainScreen.swift` — 154 of 320 lines — 189:6 unknown attribute 'EnvironmentObject' (+87 more)
- `Sources/Trial.swift` — whole file (315 lines) — 70:27 cannot find 'Keychain' in scope (+1 more)
- `Sources/TrialGate.swift` — whole file (126 lines) — 88:33 type annotation missing in pattern (+50 more)

## Converted files

- `Sources/LocalDatabase.swift` — SQLite3 → swift-toolchain-sqlite (the same C API)
- `Sources/MailSend.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/Route.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/Updater.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
