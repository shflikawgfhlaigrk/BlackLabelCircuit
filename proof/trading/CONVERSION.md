# BlackLabelTrading — converted for windows by Circuit

Generated 2026-09-18T07:14:45.136Z from `/Users/michaelbarber/BlackLabelTrading`. The source repo was not modified.

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 33 | 11,925 |
| Converted, builds for Windows | 4 | 973 |
| Builds for Windows with some declarations kept for the Mac | 7 | 850 build · 1,264 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 19 | 12,335 |
| **Total app code considered** | **63** | **27,347** |

**50.3% of the app code builds for Windows** (13,748 of 27,347 lines) — measured by the compiler. The port check's estimate before converting was 47.8% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.

## What replaced the Apple-only parts

- `OpenCombine` — https://github.com/OpenCombine/OpenCombine.git (from 0.14.0)
- `swift-crypto` — https://github.com/apple/swift-crypto.git (from 3.0.0)
- `CircuitPortKit` (in `kit/`) — Logger / os_log, UTType, and the Combine scheduler bridge

## Windows parts still needed

| Apple part | Files | Lines | Size | Windows counterpart |
|---|---:|---:|---|---|
| SwiftUI | 11 | 7,612 | L | WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI) |
| AppKit | 9 | 5,456 | L | WinUI 3 / Win32 windows, menus and dialogs |
| (uses code that was isolated) | 13 | 4,758 |  |  |
| Charts | 3 | 4,425 | M | charts drawn in the Windows UI layer |
| UserNotifications | 1 | 1,556 | S | Windows toast notifications (AppNotificationManager) |
| CoreGraphics | 1 | 690 | M | Direct2D / WIC for drawing, Win32 for displays and window lists |
| CoreText | 1 | 690 | M | DirectWrite |
| ImageIO | 1 | 690 | S | Windows Imaging Component (WIC) |
| AuthenticationServices | 1 | 322 | M | browser sign-in (OAuth) and WebAuthn through Windows Hello |
| Security | 1 | 322 | M | Windows Credential Manager (CredRead/CredWrite) and DPAPI |

## Code kept for the Mac only, with the compiler's reason

- `Sources/Analytics.swift` — whole file (253 lines) — 24:42 cannot find type 'TradeDirection' in scope (+1 more)
- `Sources/Auth.swift` — whole file (322 lines) — 42:42 type annotation missing in pattern (+98 more)
- `Sources/Backtest.swift` — 134 of 277 lines — 170:96 cannot find type 'TradeStat' in scope (+1 more)
- `Sources/BacktestDepth.swift` — 113 of 150 lines — 101:31 cannot find type 'TradeStat' in scope (+4 more)
- `Sources/ChartRender.swift` — whole file (690 lines) — 187:32 cannot find type 'CGContext' in scope (+23 more)
- `Sources/ChartScreen.swift` — whole file (723 lines) — 100:34 cannot find type 'FeedClient' in scope (+340 more)
- `Sources/EngineFireMarkers.swift` — whole file (154 lines) — 75:23 cannot find type 'EngineMarker' in scope (+2 more)
- `Sources/FeedClient.swift` — whole file (503 lines) — 494:32 cannot find type 'ApiFeedStatus' in scope (+3 more)
- `Sources/Feeds.swift` — 447 of 573 lines — 114:15 cannot find type 'Color' in scope (+190 more)
- `Sources/Holographic.swift` — whole file (607 lines) — 153:17 cannot find type 'Color' in scope (+218 more)
- `Sources/JournalImport.swift` — 76 of 247 lines — 188:35 cannot find type 'TradeStat' in scope (+2 more)
- `Sources/LiveChart.swift` — whole file (301 lines) — 36:28 cannot find type 'NSView' in scope (+76 more)
- `Sources/Model.swift` — 270 of 547 lines — 18:15 cannot find type 'Color' in scope (+19 more)
- `Sources/PaperTrade.swift` — whole file (115 lines) — 17:20 cannot find type 'TradeDirection' in scope (+5 more)
- `Sources/Replay.swift` — 36 of 56 lines — 29:48 cannot find type 'VisualStrategy' in scope
- `Sources/Screens.swift` — whole file (2,140 lines) — 15:28 cannot find type 'Color' in scope (+193 more)
- `Sources/Screens2.swift` — whole file (1,556 lines) — 43:33 cannot find type 'Nav' in scope (+201 more)
- `Sources/Screens3.swift` — whole file (729 lines) — 22:44 cannot find type 'View' in scope (+526 more)
- `Sources/StrategyBuilder.swift` — 188 of 264 lines — 88:20 cannot find type 'TradeDirection' in scope (+6 more)
- `Sources/Theme.swift` — whole file (232 lines) — 144:23 cannot find type 'View' in scope (+144 more)
- `Sources/ThemeStudio.swift` — whole file (285 lines) — 13:6 unknown attribute 'EnvironmentObject' (+125 more)
- `Sources/UpdaterUI.swift` — whole file (539 lines) — 57:17 cannot find 'NSAlert' in scope (+5 more)

## Converted files

- `Sources/AlertsEngine.swift` — Combine → OpenCombine (same API)
- `Sources/TradingKeychain.swift` — CryptoKit → swift-crypto (same API); Security → Windows Credential Manager (CredRead/CredWrite) and DPAPI
- `Sources/Updater.swift` — CryptoKit → swift-crypto (same API); Security → Windows Credential Manager (CredRead/CredWrite) and DPAPI; FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/WatchlistModel.swift` — Combine → OpenCombine (same API)
