# BlackLabelAcetate — converted for windows by Circuit

Generated 2026-09-19T01:31:38.623Z from `/Users/michaelbarber/BlackLabelAcetate`. The source repo was not modified.

Source read: 75 files, sha256 `7d422e4d8c277d06` (git b28bb3bdd + 19 uncommitted change(s)).

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 42 | 8,752 |
| Converted, builds for Windows | 4 | 1,424 |
| Builds for Windows with some declarations kept for the Mac | 9 | 1,005 build · 1,219 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 20 | 8,181 |
| **Total app code considered** | **75** | **20,581** |

**54.3% of the app code builds for Windows** (11,181 of 20,581 lines) — measured by the compiler. The port check's estimate before converting was 60.2% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.

## What replaced the Apple-only parts

- `OpenCombine` — https://github.com/OpenCombine/OpenCombine.git (from 0.14.0)
- `swift-crypto` — https://github.com/apple/swift-crypto.git (from 3.0.0)
- `CircuitPortKit` (in `kit/`) — Logger / os_log, UTType, the Combine scheduler bridge, and the Keychain (Windows Credential Manager) with SecRandomCopyBytes

## Windows parts still needed

| Apple part | Files | Lines | Size | Windows counterpart |
|---|---:|---:|---|---|
| SwiftUI | 14 | 5,756 | L | WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI) |
| AppKit | 8 | 4,127 | L | WinUI 3 / Win32 windows, menus and dialogs |
| (uses code that was isolated) | 9 | 2,593 |  |  |
| AVFoundation | 3 | 564 | L | Media Foundation and WASAPI (audio), Windows.Media.Capture (camera) |
| AudioToolbox | 2 | 491 | M | WASAPI / Media Foundation |
| Accelerate | 2 | 308 | M | a portable DSP / linear-algebra path (vDSP and BLAS have no Windows build) |
| WebKit | 1 | 202 | M | WebView2 |
| AuthenticationServices | 1 | 202 | M | browser sign-in (OAuth) and WebAuthn through Windows Hello |
| SceneKit | 1 | 110 | L | no Windows build: a cross-platform 3D engine |

## Code kept for the Mac only, with the compiler's reason

- `Audio/AudioFileIO.swift` — 430 of 533 lines — 419:44 cannot find type 'AudioFormatID' in scope (+11 more)
- `Audio/MasteringEngine.swift` — whole file (333 lines) — 46:29 cannot find type 'ReferenceDNA' in scope
- `Audio/MixEngine.swift` — whole file (777 lines) — 133:24 cannot find 'FFTAnalyzer' in scope (+1 more)
- `Audio/PlaybackEngine.swift` — whole file (73 lines) — 15:26 cannot find 'AVAudioEngine' in scope (+10 more)
- `DSP/CodecPreview.swift` — 61 of 78 lines — 56:69 cannot find 'kAudioFormatMPEG4AAC' in scope
- `DSP/FFTAnalyzer.swift` — 79 of 119 lines — 17:16 cannot find type 'vDSP_Length' in scope (+28 more)
- `DSP/LowEndAnalyzer.swift` — 143 of 182 lines — 64:24 cannot find 'FFTAnalyzer' in scope
- `DSP/MaskingDetector.swift` — whole file (171 lines) — 36:35 cannot find type 'FFTAnalyzer' in scope
- `DSP/ReferenceMatch.swift` — whole file (229 lines) — 46:57 cannot find type 'FFTAnalyzer' in scope (+2 more)
- `Model/AudioDoctor.swift` — whole file (830 lines) — 134:17 cannot find type 'MasterResult' in scope (+17 more)
- `Model/DNAProfile.swift` — 48 of 60 lines — 20:14 cannot find type 'ReferenceDNA' in scope (+10 more)
- `Model/MasterProof.swift` — 36 of 48 lines — 24:33 cannot find type 'MasterResult' in scope
- `Model/Project.swift` — whole file (1,190 lines) — 51:28 cannot find type 'MasterResult' in scope (+56 more)
- `Model/ReportCard.swift` — whole file (68 lines) — 31:33 cannot find type 'MasterResult' in scope
- `Model/SessionChain.swift` — 187 of 873 lines — 750:32 cannot find type 'MixEngine' in scope (+18 more)
- `Shared/BLShell.swift` — 202 of 295 lines — 40:26 cannot find 'Color' in scope (+125 more)
- `UI/ContentView.swift` — whole file (528 lines) — 17:35 cannot find type 'AppState' in scope (+251 more)
- `UI/DoctorView.swift` — whole file (326 lines) — 7:35 cannot find type 'AppState' in scope (+211 more)
- `UI/MasterChainView.swift` — whole file (201 lines) — 16:6 unknown attribute 'EnvironmentObject' (+58 more)
- `UI/MetersView.swift` — whole file (89 lines) — 19:20 cannot find type 'View' in scope (+24 more)
- `UI/MixConsoleView.swift` — whole file (834 lines) — 16:6 unknown attribute 'EnvironmentObject' (+255 more)
- `UI/ReferenceView.swift` — whole file (121 lines) — 16:6 unknown attribute 'EnvironmentObject' (+44 more)
- `UI/Spectrum3DView.swift` — whole file (110 lines) — 22:47 cannot find type 'SCNView' in scope (+49 more)
- `UI/SpectrumView.swift` — whole file (106 lines) — 17:20 cannot find type 'View' in scope (+25 more)
- `UI/StudioDashboardView.swift` — whole file (1,764 lines) — 15:35 cannot find type 'AppState' in scope (+89 more)
- `UI/StudioTheme.swift` — whole file (169 lines) — 26:29 cannot find type 'View' in scope (+59 more)
- `UI/SunsetApp.swift` — 33 of 36 lines — 11:1 'SunsetApp' is annotated with '@main' and must provide a main static function of type () -> Void, () throws -> Void, () async -> Void, or () async throws -> Void (+12 more)
- `UI/UpdaterUI.swift` — whole file (179 lines) — 72:38 cannot find type 'NSPanel' in scope (+18 more)
- `UI/WaveformView.swift` — whole file (83 lines) — 16:15 cannot find type 'Color' in scope (+14 more)

## Converted files

- `DSP/LoudnessMeter.swift` — Accelerate → a portable DSP / linear-algebra path (vDSP and BLAS have no Windows build)
- `DSP/SpeechLeveler.swift` — Accelerate → a portable DSP / linear-algebra path (vDSP and BLAS have no Windows build)
- `Model/LinkReference.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Shared/Updater.swift` — CryptoKit → swift-crypto (same API); Security → CircuitPortKit Keychain (Windows Credential Manager) + SecRandomCopyBytes; FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
