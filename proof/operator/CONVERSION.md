# BlackLabelSovereign — converted for windows by Circuit

Generated 2026-09-19T01:35:12.863Z from `/Users/michaelbarber/BlackLabelSovereign`. The source repo was not modified.

Source read: 80 files, sha256 `97e0de5720f5bda8` (git 59705d49e + 46 uncommitted change(s)).

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 11 | 2,273 |
| Converted, builds for Windows | 14 | 3,889 |
| Builds for Windows with some declarations kept for the Mac | 30 | 4,772 build · 6,411 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 25 | 11,552 |
| **Total app code considered** | **80** | **28,897** |

**37.8% of the app code builds for Windows** (10,934 of 28,897 lines) — measured by the compiler. The port check's estimate before converting was 12.2% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.

## What replaced the Apple-only parts

- `OpenCombine` — https://github.com/OpenCombine/OpenCombine.git (from 0.14.0)
- `swift-toolchain-sqlite` — https://github.com/swiftlang/swift-toolchain-sqlite.git (from 1.0.0)
- `swift-crypto` — https://github.com/apple/swift-crypto.git (from 3.0.0)
- `CircuitPortKit` (in `kit/`) — Logger / os_log, UTType, the Combine scheduler bridge, and the Keychain (Windows Credential Manager) with SecRandomCopyBytes

## Windows parts still needed

| Apple part | Files | Lines | Size | Windows counterpart |
|---|---:|---:|---|---|
| SwiftUI | 40 | 14,939 | L | WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI) |
| (uses code that was isolated) | 8 | 1,540 |  |  |
| AuthenticationServices | 3 | 686 | M | browser sign-in (OAuth) and WebAuthn through Windows Hello |
| CoreText | 1 | 494 | M | DirectWrite |
| AVFoundation | 3 | 465 | L | Media Foundation and WASAPI (audio), Windows.Media.Capture (camera) |
| CoreGraphics | 1 | 453 | M | Direct2D / WIC for drawing, Win32 for displays and window lists |
| CommonCrypto | 1 | 270 | S | swift-crypto or BCrypt |
| UserNotifications | 1 | 214 | S | Windows toast notifications (AppNotificationManager) |
| PDFKit | 1 | 117 | M | Windows.Data.Pdf or PDFium |
| NaturalLanguage | 1 | 98 | M | an on-device model through ONNX Runtime |
| CoreLocation | 1 | 91 | S | Windows.Devices.Geolocation |

## Code kept for the Mac only, with the compiler's reason

- `Sources/ActivityLog.swift` — 220 of 264 lines — 62:15 cannot find type 'Color' in scope (+8 more)
- `Sources/ActivityScreen.swift` — whole file (493 lines) — 26:33 cannot find type 'ClientStore' in scope (+297 more)
- `Sources/Agent.swift` — whole file (840 lines) — 143:25 cannot find type 'BrainRouter' in scope (+7 more)
- `Sources/AgentScreen.swift` — whole file (229 lines) — 14:6 unknown attribute 'EnvironmentObject' (+157 more)
- `Sources/Auth.swift` — whole file (271 lines) — 10:6 unknown attribute 'EnvironmentObject' (+118 more)
- `Sources/AutomateScreen.swift` — whole file (381 lines) — 13:6 unknown attribute 'EnvironmentObject' (+366 more)
- `Sources/Brain.swift` — 554 of 1,044 lines — 583:32 cannot find type 'AppSettings' in scope (+1 more)
- `Sources/Calendar.swift` — 115 of 173 lines — 95:24 cannot find type 'ActivityLog' in scope
- `Sources/ChatScreen.swift` — whole file (1,734 lines) — 22:35 cannot find type 'Store' in scope (+98 more)
- `Sources/ClaudeSubscriptionConnector.swift` — 79 of 98 lines — 53:36 cannot find 'ExternalAuth' in scope (+8 more)
- `Sources/Clients.swift` — 255 of 307 lines — 104:15 cannot find type 'Color' in scope (+30 more)
- `Sources/ClientsScreen.swift` — whole file (283 lines) — 14:6 unknown attribute 'EnvironmentObject' (+213 more)
- `Sources/Compat.swift` — 11 of 228 lines — 47:11 cannot find type 'View' in scope (+1 more)
- `Sources/ConnectorOAuthSheet.swift` — whole file (119 lines) — 20:41 type annotation missing in pattern (+48 more)
- `Sources/ConnectorsGallery.swift` — whole file (396 lines) — 16:6 unknown attribute 'EnvironmentObject' (+179 more)
- `Sources/ControlArbiter.swift` — 453 of 574 lines — 41:20 cannot find type 'CGKeyCode' in scope (+9 more)
- `Sources/CustomAgent.swift` — 52 of 162 lines — 166:18 cannot find 'DemoSeed' in scope
- `Sources/CustomAgentsScreen.swift` — whole file (285 lines) — 16:6 unknown attribute 'EnvironmentObject' (+162 more)
- `Sources/DailyDigest.swift` — whole file (205 lines) — 27:19 cannot find type 'DealStage' in scope (+3 more)
- `Sources/DemoSeed.swift` — whole file (224 lines) — 168:49 cannot find type 'Deal' in scope (+13 more)
- `Sources/Dictation.swift` — 182 of 247 lines — 47:24 cannot find type 'ActivityLog' in scope
- `Sources/DocumentText.swift` — whole file (117 lines) — 41:29 cannot find 'PDFDocument' in scope (+1 more)
- `Sources/ExternalAuth.swift` — 361 of 851 lines — 589:24 cannot find type 'ActivityLog' in scope
- `Sources/Files.swift` — 166 of 250 lines — 246:24 cannot find type 'SemanticRAG' in scope (+1 more)
- `Sources/GuideLibrary.swift` — 45 of 106 lines — 73:41 type annotation missing in pattern (+26 more)
- `Sources/Holographic.swift` — whole file (475 lines) — 22:30 cannot find type 'EnvironmentKey' in scope (+179 more)
- `Sources/KnowledgeScreen.swift` — whole file (289 lines) — 18:6 unknown attribute 'EnvironmentObject' (+199 more)
- `Sources/Markdown.swift` — whole file (267 lines) — 125:46 cannot find type 'Color' in scope (+56 more)
- `Sources/MCP.swift` — 277 of 653 lines — 393:22 cannot find 'OAuthConnector' in scope (+2 more)
- `Sources/Memory.swift` — 103 of 176 lines — 72:17 cannot find 'DemoSeed' in scope
- `Sources/MemoryScreen.swift` — whole file (384 lines) — 17:33 cannot find type 'ClientStore' in scope (+251 more)
- `Sources/MenuBar.swift` — whole file (209 lines) — 143:35 cannot find type 'HoloTheme' in scope (+23 more)
- `Sources/Model.swift` — 270 of 451 lines — 106:17 cannot find 'DemoSeed' in scope (+10 more)
- `Sources/OAuthCore.swift` — 305 of 540 lines — 293:57 cannot find type 'ASWebAuthenticationPresentationContextProviding' in scope
- `Sources/OperatorAX.swift` — 134 of 598 lines — 536:32 cannot find type 'ActivityLog' in scope (+1 more)
- `Sources/OrnithSetup.swift` — whole file (122 lines) — 74:26 cannot find type 'AppSettings' in scope (+8 more)
- `Sources/Prompts.swift` — 88 of 150 lines — 98:18 cannot find 'DemoSeed' in scope
- `Sources/PromptsScreen.swift` — whole file (190 lines) — 14:6 unknown attribute 'EnvironmentObject' (+116 more)
- `Sources/RAG.swift` — 98 of 123 lines — 34:35 cannot find type 'NLEmbedding' in scope (+2 more)
- `Sources/Recall.swift` — 267 of 594 lines — 352:24 cannot find type 'ActivityLog' in scope (+1 more)
- `Sources/Runtime.swift` — whole file (214 lines) — 27:29 cannot find type 'Store' in scope (+21 more)
- `Sources/Scheduler.swift` — 256 of 345 lines — 120:22 cannot find type 'ActivityOutcome' in scope (+22 more)
- `Sources/Screens.swift` — whole file (932 lines) — 44:6 unknown attribute 'State' (+630 more)
- `Sources/SelfCoding.swift` — 198 of 492 lines — 282:32 cannot find type 'ActivityLog' in scope (+2 more)
- `Sources/Settings.swift` — 405 of 523 lines — 172:17 cannot find type 'Color' in scope (+22 more)
- `Sources/SettingsScreen.swift` — whole file (2,115 lines) — 13:37 cannot find type 'Session' in scope (+129 more)
- `Sources/Shell.swift` — 708 of 856 lines — 123:35 cannot find type 'Store' in scope (+353 more)
- `Sources/Skills.swift` — 73 of 91 lines — 54:18 cannot find 'DemoSeed' in scope
- `Sources/SkillsScreen.swift` — whole file (284 lines) — 13:6 unknown attribute 'EnvironmentObject' (+207 more)
- `Sources/Social.swift` — 110 of 154 lines — 73:55 cannot find type 'ASWebAuthenticationPresentationContextProviding' in scope (+7 more)
- `Sources/Store.swift` — 252 of 385 lines — 314:21 cannot find type 'FilesConnector' in scope (+7 more)
- `Sources/Theme.swift` — whole file (494 lines) — 224:26 cannot find type 'View' in scope (+191 more)
- `Sources/Voice.swift` — 45 of 351 lines — 28:25 cannot find 'AVSpeechSynthesizer' in scope (+13 more)
- `Sources/Wake.swift` — 238 of 287 lines — 79:24 cannot find type 'ActivityLog' in scope
- `Sources/Weather.swift` — 91 of 110 lines — 113:31 cannot find 'CLGeocoder' in scope (+1 more)

## Converted files

- `Sources/AI.swift` — SwiftUI → WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI); Combine → OpenCombine (same API); the file used Combine without importing it (SwiftUI and Foundation re-export it on the Mac)
- `Sources/AmbientSampler.swift` — SQLite3 → swift-toolchain-sqlite (the same C API); os → CircuitPortKit Logger / os_log
- `Sources/ComputerUseSidecar.swift` — CoreGraphics → Direct2D / WIC for drawing, Win32 for displays and window lists; os → CircuitPortKit Logger / os_log
- `Sources/ConnectorSecrets.swift` — Security → CircuitPortKit Keychain (Windows Credential Manager) + SecRandomCopyBytes
- `Sources/DemoMode.swift` — SwiftUI → WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI); Combine → OpenCombine (same API); the file used Combine without importing it (SwiftUI and Foundation re-export it on the Mac)
- `Sources/iOSNav.swift` — SwiftUI → WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI)
- `Sources/LaunchAtLogin.swift` — Combine → OpenCombine (same API); the file used Combine without importing it (SwiftUI and Foundation re-export it on the Mac)
- `Sources/ModelLibrary.swift` — SwiftUI → WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI); Combine → OpenCombine (same API); the file used Combine without importing it (SwiftUI and Foundation re-export it on the Mac); FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/Ollama.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/OpenAIEndpointBrain.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/ScreenCapture.swift` — CoreGraphics → Direct2D / WIC for drawing, Win32 for displays and window lists; os → CircuitPortKit Logger / os_log
- `Sources/ToolClient.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/Updater.swift` — Security → CircuitPortKit Keychain names (the Mac gets them through Foundation); FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/WebFetch.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
