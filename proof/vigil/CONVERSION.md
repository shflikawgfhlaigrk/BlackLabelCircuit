# BlackLabelHome — converted for windows by Circuit

Generated 2026-09-19T01:32:02.618Z from `/Users/michaelbarber/BlackLabelHome`. The source repo was not modified.

Source read: 114 files, sha256 `793f1b348aa1e197` (git af989d8c4).

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 90 | 16,100 |
| Converted, builds for Windows | 5 | 2,844 |
| Builds for Windows with some declarations kept for the Mac | 2 | 118 build · 323 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 15 | 11,224 |
| Mac-only parts skipped on Windows | 2 | 1,430 |
| **Total app code considered** | **114** | **32,039** |

**59.5% of the app code builds for Windows** (19,062 of 32,039 lines) — measured by the compiler. The port check's estimate before converting was 57.3% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.

## What replaced the Apple-only parts

- `OpenCombine` — https://github.com/OpenCombine/OpenCombine.git (from 0.14.0)
- `swift-toolchain-sqlite` — https://github.com/swiftlang/swift-toolchain-sqlite.git (from 1.0.0)
- `CircuitPortKit` (in `kit/`) — Logger / os_log, UTType, the Combine scheduler bridge, and the Keychain (Windows Credential Manager) with SecRandomCopyBytes

## Windows parts still needed

| Apple part | Files | Lines | Size | Windows counterpart |
|---|---:|---:|---|---|
| SwiftUI | 12 | 8,695 | L | WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI) |
| AppKit | 7 | 6,689 | L | WinUI 3 / Win32 windows, menus and dialogs |
| SceneKit | 2 | 2,553 | L | no Windows build: a cross-platform 3D engine |
| (uses code that was isolated) | 3 | 2,502 |  |  |
| CoreWLAN | 1 | 2,209 | M | Native Wifi API (WlanApi) |
| AVFoundation | 1 | 2,209 | L | Media Foundation and WASAPI (audio), Windows.Media.Capture (camera) |
| Vision | 1 | 2,209 | M | Windows.Media.Ocr or ONNX Runtime |
| simd | 1 | 2,209 | S | the standard library SIMD types; simd_* functions need a portable implementation |
| UserNotifications | 1 | 848 | S | Windows toast notifications (AppNotificationManager) |
| Network | 2 | 520 | M | Winsock / Windows.Networking (NWConnection, NWPathMonitor, Bonjour browsing) |
| AVKit | 1 | 513 | M | MediaPlayerElement (WinUI) |
| WebKit | 1 | 118 | M | WebView2 |
| CoreLocation | 1 | 103 | S | Windows.Devices.Geolocation |

## Code kept for the Mac only, with the compiler's reason

- `AwayAlertsViews.swift` — whole file (167 lines) — 21:6 unknown attribute 'EnvironmentObject' (+85 more)
- `CameraViews.swift` — whole file (513 lines) — 79:27 cannot find type 'NSImage' in scope (+174 more)
- `ClimateViews.swift` — 205 of 283 lines — 104:6 unknown attribute 'EnvironmentObject' (+125 more)
- `Discovery.swift` — whole file (247 lines) — 32:28 cannot find type 'NWBrowser' in scope (+16 more)
- `EnergyViews.swift` — whole file (273 lines) — 108:6 unknown attribute 'EnvironmentObject' (+100 more)
- `Geofence.swift` — whole file (103 lines) — 17:57 cannot find type 'CLLocationManagerDelegate' in scope (+13 more)
- `Homefront.swift` — whole file (2,209 lines) — 246:29 cannot find type 'HomeStore' in scope (+95 more)
- `HomeStore.swift` — whole file (848 lines) — 27:50 cannot find type 'UNUserNotificationCenterDelegate' in scope (+28 more)
- `HomeViews.swift` — whole file (1,728 lines) — 45:35 cannot find type 'HomeStore' in scope (+159 more)
- `MenuBarViews.swift` — whole file (116 lines) — 23:44 type annotation missing in pattern (+73 more)
- `SensorViews.swift` — whole file (703 lines) — 19:6 unknown attribute 'State' (+382 more)
- `Shared/BLShell.swift` — 118 of 158 lines — 24:26 cannot find 'Color' in scope (+58 more)
- `VigilHouse3DView.swift` — whole file (344 lines) — 44:42 cannot find type 'SCNView' in scope (+81 more)
- `VigilHouseView.swift` — whole file (1,471 lines) — 36:37 cannot find 'NSApplication' in scope (+34 more)

## Converted files

- `Climate.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Energy.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `HomeCore.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `HomeDatabase.swift` — SQLite3 → swift-toolchain-sqlite (the same C API)
- `Updater.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
