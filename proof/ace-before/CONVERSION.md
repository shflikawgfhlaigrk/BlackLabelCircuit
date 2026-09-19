# Ace-Build85-20260913 — converted for windows by Circuit

Generated 2026-09-19T01:30:27.174Z from `/private/tmp/claude-501/-Users-michaelbarber-Desktop-Black-Label-B-ots-BlackLabel-Team-black-label-city-spec-d2180e/5435c4da-dbf5-4ec9-af9b-866272aed8e6/scratchpad/snap/Ace-Build85-20260913`. The source repo was not modified.

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 115 | 20,758 |
| Converted, builds for Windows | 37 | 13,321 |
| Builds for Windows with some declarations kept for the Mac | 31 | 10,150 build · 17,035 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 49 | 59,604 |
| **Total app code considered** | **232** | **120,868** |

**36.6% of the app code builds for Windows** (44,229 of 120,868 lines) — measured by the compiler. The port check's estimate before converting was 17.3% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.

## What replaced the Apple-only parts

- `swift-crypto` — https://github.com/apple/swift-crypto.git (from 3.0.0)
- `OpenCombine` — https://github.com/OpenCombine/OpenCombine.git (from 0.14.0)
- `swift-toolchain-sqlite` — https://github.com/swiftlang/swift-toolchain-sqlite.git (from 1.0.0)
- `CircuitPortKit` (in `kit/`) — Logger / os_log, UTType, and the Combine scheduler bridge

## Windows parts still needed

| Apple part | Files | Lines | Size | Windows counterpart |
|---|---:|---:|---|---|
| SwiftUI | 22 | 45,010 | L | WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI) |
| AVFoundation | 14 | 42,110 | L | Media Foundation and WASAPI (audio), Windows.Media.Capture (camera) |
| Speech | 8 | 38,912 | M | Windows.Media.SpeechRecognition or an on-device model (whisper.cpp) |
| AppKit | 37 | 35,450 | L | WinUI 3 / Win32 windows, menus and dialogs |
| ApplicationServices | 12 | 34,012 | L | UI Automation (reading and targeting other apps) and SendInput (typing) |
| ScreenCaptureKit | 5 | 29,728 | L | Windows.Graphics.Capture |
| (uses code that was isolated) | 17 | 9,974 |  |  |
| CoreGraphics | 8 | 4,620 | M | Direct2D / WIC for drawing, Win32 for displays and window lists |
| Network | 5 | 2,454 | M | Winsock / Windows.Networking (NWConnection, NWPathMonitor, Bonjour browsing) |
| IOKit | 1 | 1,567 | M | SetupAPI / WMI |
| ServiceManagement | 1 | 1,494 | S | a startup task or the HKCU Run key |
| Security | 2 | 1,464 | M | Windows Credential Manager (CredRead/CredWrite) and DPAPI |
| Vision | 2 | 856 | M | Windows.Media.Ocr or ONNX Runtime |
| CoreServices | 1 | 804 | M | Win32 file and launch APIs |
| EventKit | 1 | 756 | M | Microsoft Graph calendar or Windows.ApplicationModel.Appointments |
| PDFKit | 1 | 756 | M | Windows.Data.Pdf or PDFium |
| ImageIO | 2 | 526 | S | Windows Imaging Component (WIC) |
| CoreImage | 1 | 426 | M | Direct2D effects / WIC |
| CoreMedia | 1 | 426 | M | Media Foundation |
| WebKit | 1 | 261 | M | WebView2 |
| CoreLocation | 1 | 123 | S | Windows.Devices.Geolocation |
| AuthenticationServices | 1 | 66 | M | browser sign-in (OAuth) and WebAuthn through Windows Hello |

## Code kept for the Mac only, with the compiler's reason

- `leanring-buddy/AcademicSettingsView.swift` — 12 of 13 lines — 7:20 cannot find type 'View' in scope (+1 more)
- `leanring-buddy/AccessibilityVisualTargetResolver.swift` — whole file (435 lines) — 18:8 type 'AccessibilityVisualTargetCandidate' does not conform to protocol 'Equatable' (+29 more)
- `leanring-buddy/AccessibilityWindowIdentity.swift` — 63 of 104 lines — 89:10 cannot find type 'CGWindowID' in scope (+1 more)
- `leanring-buddy/AceDeviceAuthorizationWindow.swift` — whole file (321 lines) — 15:5 cannot find type 'NSWindowDelegate' in scope (+58 more)
- `leanring-buddy/AceIntroWindow.swift` — whole file (2,048 lines) — 75:49 cannot find type 'NSWindowDelegate' in scope (+469 more)
- `leanring-buddy/AceLanguagePanel.swift` — whole file (44 lines) — 8:6 unknown attribute 'ObservedObject' (+17 more)
- `leanring-buddy/AceLicense.swift` — 1,567 of 1,932 lines — 505:37 cannot find type 'NWPathMonitor' in scope (+23 more)
- `leanring-buddy/AceLocalBrain.swift` — whole file (735 lines) — 228:36 cannot find 'AceLocalVisionOCR' in scope
- `leanring-buddy/AceLocalVisionOCR.swift` — 100 of 133 lines — 54:47 value of type 'CGRect' has no member 'width' (+11 more)
- `leanring-buddy/AceManagedControls.swift` — 335 of 423 lines — 22:32 cannot find type 'View' in scope (+76 more)
- `leanring-buddy/AceMotionEffects.swift` — whole file (299 lines) — 12:59 type annotation missing in pattern (+87 more)
- `leanring-buddy/AceMotionPolicy.swift` — 143 of 176 lines — 32:20 type 'AceFlightFrame' does not conform to protocol 'Equatable' (+42 more)
- `leanring-buddy/AceNativeUpdate.swift` — whole file (271 lines) — 35:24 cannot find type 'NSPanel' in scope (+23 more)
- `leanring-buddy/AceStageOverlay.swift` — whole file (952 lines) — 50:22 cannot find type 'Color' in scope (+148 more)
- `leanring-buddy/AceUpdateCheck.swift` — whole file (274 lines) — 80:24 cannot find 'NSWorkspace' in scope (+8 more)
- `leanring-buddy/AppActionBroker.swift` — 833 of 2,522 lines — 248:16 cannot find 'StealthVisibilityGate' in scope (+5 more)
- `leanring-buddy/AppleSpeechTranscriptionProvider.swift` — 316 of 382 lines — 156:30 cannot find type 'SFSpeechRecognizerAuthorizationStatus' in scope (+18 more)
- `leanring-buddy/AppSwitcher.swift` — whole file (1,201 lines) — 240:24 cannot find type 'AXUIElement' in scope (+9 more)
- `leanring-buddy/AssistantAvailabilityPolicy.swift` — whole file (225 lines) — 136:32 value of type 'CGRect' has no member 'minX' (+19 more)
- `leanring-buddy/BackgroundAgent.swift` — 744 of 1,230 lines — 558:33 cannot find type 'BackgroundBrowserService' in scope (+2 more)
- `leanring-buddy/BackgroundBrowserService.swift` — whole file (261 lines) — 18:49 cannot find type 'WKNavigationDelegate' in scope (+56 more)
- `leanring-buddy/BackgroundDataAdapter.swift` — whole file (64 lines) — 46:32 cannot find 'BrainConnectionProbe' in scope
- `leanring-buddy/BrainConnection.swift` — 1,717 of 2,131 lines — 1998:27 cannot find 'BrainBackend' in scope (+31 more)
- `leanring-buddy/BrowserBackendHeadlessCommand.swift` — 60 of 80 lines — 49:26 cannot find 'NWEndpoint' in scope (+1 more)
- `leanring-buddy/BuddyAudioConversionSupport.swift` — 112 of 153 lines — 128:51 cannot find type 'AVAudioPCMBuffer' in scope (+12 more)
- `leanring-buddy/BuddyAudioReplayBuffer.swift` — whole file (275 lines) — 41:22 cannot find type 'AVAudioPCMBuffer' in scope (+8 more)
- `leanring-buddy/BuddyDictationAudioCaptureLease.swift` — whole file (85 lines) — 8:22 cannot find type 'AVAudioFormat' in scope (+12 more)
- `leanring-buddy/BuddyDictationManager.swift` — whole file (2,504 lines) — 138:20 cannot find type 'NSEvent' in scope (+9 more)
- `leanring-buddy/BuddyTranscriptionProvider.swift` — 131 of 516 lines — 39:43 cannot find type 'AVAudioPCMBuffer' in scope (+9 more)
- `leanring-buddy/ClaudeAPI.swift` — whole file (2,064 lines) — 168:28 cannot find 'AceLocalBrain' in scope (+6 more)
- `leanring-buddy/CompanionManager.swift` — whole file (24,445 lines) — 65:20 cannot find type 'NSView' in scope (+40 more)
- `leanring-buddy/CompanionPanelView.swift` — whole file (4,283 lines) — 32:53 cannot find type 'NSView' in scope (+149 more)
- `leanring-buddy/CompanionResponseOverlay.swift` — whole file (246 lines) — 44:31 cannot find type 'NSPanel' in scope (+7 more)
- `leanring-buddy/CompanionScreenCaptureUtility.swift` — whole file (773 lines) — 84:28 cannot find type 'CGDirectDisplayID' in scope (+11 more)
- `leanring-buddy/DashboardHost.swift` — 484 of 825 lines — 262:27 cannot find type 'NWListener' in scope (+9 more)
- `leanring-buddy/DesignSystem.swift` — whole file (1,018 lines) — 253:62 cannot find type 'Color' in scope (+78 more)
- `leanring-buddy/DesktopActionHeadlessCommand.swift` — whole file (70 lines) — 40:26 cannot find 'DesktopActionSystemBackend' in scope
- `leanring-buddy/DesktopActionSystemBackend.swift` — whole file (1,256 lines) — 26:22 cannot find type 'AXUIElement' in scope (+23 more)
- `leanring-buddy/FirstRunFailureRecoveryView.swift` — whole file (131 lines) — 10:6 unknown attribute 'ObservedObject' (+18 more)
- `leanring-buddy/FirstRunFailureReporter.swift` — 310 of 454 lines — 258:16 cannot find 'StealthVisibilityGate' in scope (+1 more)
- `leanring-buddy/FloatingInboxAppleMail.swift` — whole file (131 lines) — 19:23 cannot find type 'FloatingInboxCancellation' in scope (+2 more)
- `leanring-buddy/FloatingInboxController.swift` — whole file (296 lines) — 55:17 cannot find 'NSWorkspace' in scope (+14 more)
- `leanring-buddy/FloatingInboxGmail.swift` — whole file (94 lines) — 6:23 cannot find type 'GmailNetworkWire' in scope (+2 more)
- `leanring-buddy/FloatingInboxModels.swift` — 18 of 99 lines — 13:36 value of type 'CGRect' has no member 'intersection' (+8 more)
- `leanring-buddy/FloatingInboxPanel.swift` — whole file (240 lines) — 10:33 cannot find type 'NSPanel' in scope (+125 more)
- `leanring-buddy/GlobalPushToTalkShortcutMonitor.swift` — whole file (656 lines) — 456:20 cannot find type 'CGEvent' in scope (+20 more)
- `leanring-buddy/GmailAccountController.swift` — whole file (294 lines) — 65:53 cannot find 'GmailGoogleConnection' in scope (+7 more)
- `leanring-buddy/GmailBackendHeadlessCommand.swift` — whole file (71 lines) — 28:54 cannot find 'GmailNetworkWire' in scope
- `leanring-buddy/GmailIMAPSession.swift` — 82 of 144 lines — 13:29 cannot find type 'NWConnection' in scope
- `leanring-buddy/GmailOAuth.swift` — 66 of 160 lines — 113:80 cannot find type 'ASWebAuthenticationPresentationContextProviding' in scope (+9 more)
- `leanring-buddy/HostedBrainClient.swift` — 171 of 420 lines — 201:13 cannot find 'AceLicense' in scope (+1 more)
- `leanring-buddy/InstallLocation.swift` — 1,398 of 1,855 lines — 40:24 cannot find type 'NSPanel' in scope (+58 more)
- `leanring-buddy/leanring_buddyApp.swift` — whole file (1,494 lines) — 69:66 type annotation missing in pattern (+6 more)
- `leanring-buddy/MeetingNotesReviewView.swift` — whole file (291 lines) — 20:20 cannot find type 'View' in scope (+66 more)
- `leanring-buddy/MeetingNotetaker.swift` — 3,613 of 4,407 lines — 652:30 cannot find type 'AVAudioEngine' in scope (+114 more)
- `leanring-buddy/MenuBarPanelManager.swift` — whole file (741 lines) — 80:70 cannot find type 'NSScreen' in scope
- `leanring-buddy/MorningBriefPolicy.swift` — 425 of 890 lines — 560:28 cannot find 'NSWorkspace' in scope (+2 more)
- `leanring-buddy/NativeLocationManager.swift` — whole file (123 lines) — 14:55 cannot find type 'CLLocationManagerDelegate' in scope (+8 more)
- `leanring-buddy/NativeWindowCloseService.swift` — 69 of 142 lines — 83:18 cannot find type 'AXUIElement' in scope (+32 more)
- `leanring-buddy/NoraVoice.swift` — 1,159 of 1,733 lines — 1011:15 cannot find 'VoiceReadiness' in scope (+21 more)
- `leanring-buddy/NotchConcealment.swift` — 47 of 63 lines — 37:49 value of type 'CGRect' has no member 'maxX' (+5 more)
- `leanring-buddy/OverlayWindow.swift` — whole file (1,643 lines) — 116:39 cannot find type 'Path' in scope (+94 more)
- `leanring-buddy/OwnerTurnLifecycleCoordinator.swift` — whole file (1,132 lines) — 443:17 cannot find 'AppSwitcher' in scope (+3 more)
- `leanring-buddy/PartnerModePanel.swift` — whole file (891 lines) — 13:59 type annotation missing in pattern (+22 more)
- `leanring-buddy/PartnerModePolicy.swift` — 756 of 1,120 lines — 280:30 cannot find 'EKEventStore' in scope (+6 more)
- `leanring-buddy/PermissionRepairCoordinator.swift` — 104 of 875 lines — 527:34 cannot find type 'NSRunningApplication' in scope
- `leanring-buddy/PermissionWarmup.swift` — 804 of 1,043 lines — 281:30 cannot find type 'NSRunningApplication' in scope (+18 more)
- `leanring-buddy/PrivateModePolicy.swift` — whole file (1,976 lines) — 24:28 cannot find type 'CGDirectDisplayID' in scope (+217 more)
- `leanring-buddy/ScreenCaptureImageProvider.swift` — 426 of 526 lines — 147:20 cannot find type 'CGImage' in scope (+53 more)
- `leanring-buddy/SetupWalkthrough.swift` — whole file (1,367 lines) — 152:16 cannot find type 'NSApplication' in scope (+16 more)
- `leanring-buddy/StealthExitOnlyCapture.swift` — whole file (336 lines) — 20:26 cannot find type 'SFSpeechAudioBufferRecognitionRequest' in scope (+15 more)
- `leanring-buddy/StealthMode.swift` — 440 of 1,775 lines — 288:21 cannot find type 'NSApplication' in scope (+15 more)
- `leanring-buddy/VoiceReadiness.swift` — 530 of 859 lines — 434:22 cannot find 'NSApplication' in scope
- `leanring-buddy/WindowMoveHeadlessCommand.swift` — whole file (253 lines) — 28:12 type 'WindowMoveHeadlessCommand.Request' does not conform to protocol 'Equatable' (+2 more)
- `leanring-buddy/WindowPositionManager.swift` — whole file (471 lines) — 393:61 cannot find type 'CGDirectDisplayID' in scope (+2 more)
- `leanring-buddy/WindowTiler.swift` — whole file (428 lines) — 29:57 cannot find type 'NSScreen' in scope (+11 more)
- `leanring-buddy/WorkflowRuntime.swift` — whole file (1,810 lines) — 391:44 cannot find 'HostedBrainClient' in scope (+5 more)

## Converted files

- `leanring-buddy/AcademicDocument.swift` — CryptoKit → swift-crypto (same API)
- `leanring-buddy/AcademicDocumentHeadlessCommand.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/AcademicDOCX.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/AcademicSourceFetcher.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `leanring-buddy/AceActionModel.swift` — Combine → OpenCombine (same API)
- `leanring-buddy/AceActionReceiptStore.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/AceBuyerRecovery.swift` — AppKit → WinUI 3 / Win32 windows, menus and dialogs; Combine → OpenCombine (same API); FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `leanring-buddy/AceConversationHistory.swift` — CryptoKit → swift-crypto (same API); Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/AceDeviceAuthorizationProtocol.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `leanring-buddy/AceEventBus.swift` — Combine → OpenCombine (same API)
- `leanring-buddy/AceGoldContextStore.swift` — CryptoKit → swift-crypto (same API)
- `leanring-buddy/AceHQDispatchClient.swift` — CryptoKit → swift-crypto (same API); FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `leanring-buddy/AceHQPendingDispatchStore.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux; CryptoKit → swift-crypto (same API)
- `leanring-buddy/AceNativeUpdateArtifact.swift` — CryptoKit → swift-crypto (same API); Security → Windows Credential Manager (CredRead/CredWrite) and DPAPI
- `leanring-buddy/AceNativeUpdateDownload.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `leanring-buddy/AcePurchaseRecovery.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `leanring-buddy/AceSignedLease.swift` — CryptoKit → swift-crypto (same API)
- `leanring-buddy/AgentCapabilityConsentStore.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/AppleMailAccountProvider.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/AppleMessagesActionProvider.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/ArtifactReceiptStore.swift` — CryptoKit → swift-crypto (same API); Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/BoundedPipeCapture.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/CodexModelResolver.swift` — CryptoKit → swift-crypto (same API); Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/ExplicitMemoryStore.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/GmailAccount.swift` — Security → Windows Credential Manager (CredRead/CredWrite) and DPAPI
- `leanring-buddy/InstallReadiness.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/LaneManager.swift` — Combine → OpenCombine (same API)
- `leanring-buddy/NativeHeadlessEffectAuthority.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/PartnerModeController.swift` — Combine → OpenCombine (same API)
- `leanring-buddy/PartnerProfileKeyStore.swift` — CryptoKit → swift-crypto (same API)
- `leanring-buddy/PartnerSecureStore.swift` — CryptoKit → swift-crypto (same API)
- `leanring-buddy/PrivateSupportDirectory.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/PromptFreeCredentialStore.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux; CryptoKit → swift-crypto (same API)
- `leanring-buddy/RedProviderExecutionProfile.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/StableInstallResumeStore.swift` — Darwin → ucrt + WinSDK on Windows, Glibc on Linux
- `leanring-buddy/StandingTaskRuntime.swift` — Combine → OpenCombine (same API)
- `leanring-buddy/TradingLane.swift` — Combine → OpenCombine (same API)
