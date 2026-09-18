# BlackLabelAcetate — converted for windows by Circuit

Generated 2026-09-18T07:13:11.641Z from `/Users/michaelbarber/BlackLabelAcetate`. The source repo was not modified.

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 55 | 13,347 |
| Converted, builds for Windows | 2 | 519 |
| Builds for Windows with some declarations kept for the Mac | 4 | 216 build · 726 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 14 | 5,773 |
| **Total app code considered** | **75** | **20,581** |

**68.4% of the app code builds for Windows** (14,082 of 20,581 lines) — measured by the compiler. The port check's estimate before converting was 66.1% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.

## What replaced the Apple-only parts

- `swift-crypto` — https://github.com/apple/swift-crypto.git (from 3.0.0)
- `CircuitPortKit` (in `kit/`) — Logger / os_log, UTType, and the Combine scheduler bridge

## Windows parts still needed

| Apple part | Files | Lines | Size | Windows counterpart |
|---|---:|---:|---|---|
| SwiftUI | 14 | 5,756 | L | WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI) |
| AppKit | 8 | 4,127 | L | WinUI 3 / Win32 windows, menus and dialogs |
| AVFoundation | 3 | 564 | L | Media Foundation and WASAPI (audio), Windows.Media.Capture (camera) |
| AudioToolbox | 2 | 491 | M | WASAPI / Media Foundation |
| WebKit | 1 | 202 | M | WebView2 |
| AuthenticationServices | 1 | 202 | M | browser sign-in (OAuth) and WebAuthn through Windows Hello |
| SceneKit | 1 | 110 | L | no Windows build: a cross-platform 3D engine |

## Code kept for the Mac only, with the compiler's reason

- `Audio/AudioFileIO.swift` — 430 of 533 lines — 418:44 cannot find type 'AudioFormatID' in scope (+11 more)
- `Audio/PlaybackEngine.swift` — whole file (73 lines) — 15:26 cannot find 'AVAudioEngine' in scope (+10 more)
- `DSP/CodecPreview.swift` — 61 of 78 lines — 56:69 cannot find 'kAudioFormatMPEG4AAC' in scope
- `Model/Project.swift` — whole file (1,190 lines) — 179:20 cannot find 'PlaybackEngine' in scope (+14 more)
- `Shared/BLShell.swift` — 202 of 295 lines — 32:26 cannot find 'Color' in scope (+120 more)
- `UI/ContentView.swift` — whole file (528 lines) — 17:6 unknown attribute 'EnvironmentObject' (+252 more)
- `UI/DoctorView.swift` — whole file (326 lines) — 7:6 unknown attribute 'EnvironmentObject' (+150 more)
- `UI/MasterChainView.swift` — whole file (201 lines) — 16:6 unknown attribute 'EnvironmentObject' (+58 more)
- `UI/MetersView.swift` — whole file (89 lines) — 19:20 cannot find type 'View' in scope (+24 more)
- `UI/MixConsoleView.swift` — whole file (834 lines) — 16:6 unknown attribute 'EnvironmentObject' (+309 more)
- `UI/ReferenceView.swift` — whole file (121 lines) — 16:6 unknown attribute 'EnvironmentObject' (+69 more)
- `UI/Spectrum3DView.swift` — whole file (110 lines) — 22:47 cannot find type 'SCNView' in scope (+49 more)
- `UI/SpectrumView.swift` — whole file (106 lines) — 17:20 cannot find type 'View' in scope (+41 more)
- `UI/StudioDashboardView.swift` — whole file (1,764 lines) — 15:35 cannot find type 'AppState' in scope (+83 more)
- `UI/StudioTheme.swift` — whole file (169 lines) — 26:29 cannot find type 'View' in scope (+57 more)
- `UI/SunsetApp.swift` — 33 of 36 lines — 11:1 'SunsetApp' is annotated with '@main' and must provide a main static function of type () -> Void, () throws -> Void, () async -> Void, or () async throws -> Void (+11 more)
- `UI/UpdaterUI.swift` — whole file (179 lines) — 72:38 cannot find type 'NSPanel' in scope (+13 more)
- `UI/WaveformView.swift` — whole file (83 lines) — 16:15 cannot find type 'Color' in scope (+18 more)

## Converted files

- `Model/LinkReference.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Shared/Updater.swift` — CryptoKit → swift-crypto (same API); Security → Windows Credential Manager (CredRead/CredWrite) and DPAPI; FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
