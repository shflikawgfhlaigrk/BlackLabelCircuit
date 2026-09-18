# BlackLabelMarketing — converted for windows by Circuit

Generated 2026-09-18T07:22:06.601Z from `/Users/michaelbarber/BlackLabelMarketing`. The source repo was not modified.

**Compiler check: passed** — simulated Windows configuration on macOS (-DCIRCUIT_WINDOWS_SIM); Apple Swift version 6.4 (swiftlang-6.4.0.33.1 clang-2100.3.33.1).

| | Files | Lines |
|---|---:|---:|
| Builds for Windows unchanged | 30 | 4,492 |
| Converted, builds for Windows | 10 | 2,339 |
| Builds for Windows with some declarations kept for the Mac | 58 | 7,707 build · 10,808 isolated |
| Needs a Windows part (kept byte-for-byte for the Mac build, compiled out elsewhere) | 53 | 31,408 |
| **Total app code considered** | **151** | **56,754** |

**25.6% of the app code builds for Windows** (14,538 of 56,754 lines) — measured by the compiler. The port check's estimate before converting was 19.1% of lines with no Mac-only parts; it reads imports and cannot see code that leans on a Mac-only file, so the compiler figure is the one to go by.

## Build it

```sh
swift build                                   # Windows, Linux or macOS
swift build -Xswiftc -DCIRCUIT_WINDOWS_SIM       # on a Mac: the Windows configuration
```

`.github/workflows/circuit-windows-build.yml` runs the same build on a Windows runner.

## What replaced the Apple-only parts

- `swift-crypto` — https://github.com/apple/swift-crypto.git (from 3.0.0)
- `swift-toolchain-sqlite` — https://github.com/swiftlang/swift-toolchain-sqlite.git (from 1.0.0)
- `CircuitPortKit` (in `kit/`) — Logger / os_log, UTType, and the Combine scheduler bridge

## Windows parts still needed

| Apple part | Files | Lines | Size | Windows counterpart |
|---|---:|---:|---|---|
| SwiftUI | 52 | 26,399 | L | WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI) |
| (uses code that was isolated) | 43 | 11,318 |  |  |
| AVFoundation | 5 | 3,901 | L | Media Foundation and WASAPI (audio), Windows.Media.Capture (camera) |
| Security | 10 | 3,270 | M | Windows Credential Manager (CredRead/CredWrite) and DPAPI |
| CoreGraphics | 7 | 2,373 | M | Direct2D / WIC for drawing, Win32 for displays and window lists |
| AVKit | 1 | 2,286 | M | MediaPlayerElement (WinUI) |
| WebKit | 1 | 2,270 | M | WebView2 |
| CoreImage | 5 | 1,770 | M | Direct2D effects / WIC |
| ImageIO | 3 | 1,364 | S | Windows Imaging Component (WIC) |
| AuthenticationServices | 2 | 536 | M | browser sign-in (OAuth) and WebAuthn through Windows Hello |
| CoreText | 2 | 490 | M | DirectWrite |
| Network | 1 | 274 | M | Winsock / Windows.Networking (NWConnection, NWPathMonitor, Bonjour browsing) |
| Speech | 1 | 208 | M | Windows.Media.SpeechRecognition or an on-device model (whisper.cpp) |
| Vision | 1 | 165 | M | Windows.Media.Ocr or ONNX Runtime |

## Code kept for the Mac only, with the compiler's reason

- `Sources/AccountDeletionRunner.swift` — whole file (171 lines) — 136:43 cannot find 'ConsentedEgress' in scope
- `Sources/Ads.swift` — 54 of 120 lines — 127:11 cannot find type 'AppModel' in scope (+2 more)
- `Sources/AICaptionEngine.swift` — 155 of 210 lines — 112:16 cannot find 'Studio' in scope (+1 more)
- `Sources/AnalyticsConnect.swift` — whole file (507 lines) — 61:6 unknown attribute 'EnvironmentObject' (+192 more)
- `Sources/Audience.swift` — 61 of 293 lines — 38:11 cannot find type 'AppModel' in scope (+1 more)
- `Sources/AudienceScreens.swift` — whole file (524 lines) — 21:6 unknown attribute 'EnvironmentObject' (+303 more)
- `Sources/Auth.swift` — whole file (232 lines) — 7:6 unknown attribute 'EnvironmentObject' (+105 more)
- `Sources/BackgroundPublish.swift` — 59 of 288 lines — 146:21 cannot find 'AppModel' in scope (+3 more)
- `Sources/BrandKitImportControl.swift` — 44 of 51 lines — 13:6 unknown attribute 'EnvironmentObject' (+20 more)
- `Sources/BrandKitLive.swift` — whole file (63 lines) — 14:17 cannot find type 'Prefs' in scope (+2 more)
- `Sources/BrandProfiler.swift` — whole file (141 lines) — 32:9 cannot find 'ConsentedEgress' in scope
- `Sources/CallsScreen.swift` — whole file (311 lines) — 20:15 cannot find type 'Lead' in scope (+35 more)
- `Sources/CameraPolisher.swift` — whole file (334 lines) — 187:33 cannot find 'blmCameraLog' in scope
- `Sources/CameraRecording.swift` — whole file (665 lines) — 433:43 cannot find 'MarketingVirtualSetModel' in scope (+35 more)
- `Sources/CampaignBuilderLive.swift` — 39 of 46 lines — 47:83 cannot find type 'ReelProject' in scope (+2 more)
- `Sources/CloudflareAnalytics.swift` — 165 of 294 lines — 271:42 cannot find 'ConsentedEgress' in scope (+1 more)
- `Sources/CloudflareEmail.swift` — 266 of 369 lines — 301:46 cannot find 'ConsentedEgress' in scope (+4 more)
- `Sources/CommandBar.swift` — 89 of 129 lines — 36:53 cannot find type 'Activity' in scope (+4 more)
- `Sources/Compat.swift` — 10 of 252 lines — 21:11 cannot find type 'View' in scope (+1 more)
- `Sources/ConnectorsScreen.swift` — whole file (2,606 lines) — 33:35 cannot find type 'AppModel' in scope (+133 more)
- `Sources/ConsentedEgress.swift` — 274 of 775 lines — 538:22 cannot find type 'DNSServiceRef' in scope (+22 more)
- `Sources/CRMConnector.swift` — 1,036 of 1,260 lines — 94:25 cannot find type 'Lead' in scope (+34 more)
- `Sources/CRMStore.swift` — whole file (376 lines) — 9:11 cannot find type 'AppModel' in scope (+2 more)
- `Sources/DeliverabilityScore.swift` — 141 of 245 lines — 255:36 cannot find type 'Lead' in scope (+6 more)
- `Sources/DeliverabilityScreen.swift` — whole file (790 lines) — 37:6 unknown attribute 'State' (+351 more)
- `Sources/DeliverabilityTools.swift` — 173 of 343 lines — 28:47 cannot find type 'ConsentedEgress' in scope (+9 more)
- `Sources/DeliveryDashboard.swift` — 60 of 68 lines — 14:35 cannot find type 'AppModel' in scope (+29 more)
- `Sources/DeliveryMetrics.swift` — 56 of 70 lines — 31:35 cannot find type 'Activity' in scope
- `Sources/DemoData.swift` — 290 of 378 lines — 110:6 unknown attribute 'State' (+22 more)
- `Sources/DesignCanvas.swift` — 340 of 435 lines — 93:24 cannot find type 'TextAlignment' in scope (+27 more)
- `Sources/DesignCanvasScreen.swift` — whole file (1,462 lines) — 29:38 cannot find 'DesignDocumentStore' in scope (+615 more)
- `Sources/DesignExport.swift` — whole file (284 lines) — 238:34 cannot find type 'DesignDocument' in scope (+14 more)
- `Sources/DesignPhotoEdit.swift` — whole file (239 lines) — 51:17 cannot find 'ReelColorGrade' in scope (+17 more)
- `Sources/EmailOAuth.swift` — whole file (246 lines) — 36:35 cannot find type 'ASWebAuthenticationPresentationContextProviding' in scope (+8 more)
- `Sources/Enrichment.swift` — 36 of 127 lines — 65:37 cannot find type 'Lead' in scope
- `Sources/EnrichmentProvider.swift` — 156 of 294 lines — 164:52 cannot find 'ConsentedEgress' in scope (+1 more)
- `Sources/EnrichmentWaterfall.swift` — 69 of 117 lines — 82:37 cannot find type 'EnrichmentProviderClient' in scope (+2 more)
- `Sources/Funnel.swift` — whole file (100 lines) — 14:16 cannot find type 'DealStage' in scope (+4 more)
- `Sources/GA4Analytics.swift` — 256 of 452 lines — 314:43 cannot find 'ConsentedEgress' in scope (+1 more)
- `Sources/GrowthEngine.swift` — 63 of 422 lines — 125:11 cannot find type 'AppModel' in scope (+1 more)
- `Sources/GrowthEngineScreens.swift` — whole file (586 lines) — 17:35 cannot find type 'AppModel' in scope (+389 more)
- `Sources/GrowthScreens.swift` — whole file (1,242 lines) — 31:35 cannot find type 'AppModel' in scope (+804 more)
- `Sources/GuideReaderScreen.swift` — whole file (298 lines) — 25:6 unknown attribute 'State' (+122 more)
- `Sources/Holographic.swift` — whole file (765 lines) — 47:22 cannot find type 'Color' in scope (+213 more)
- `Sources/ImageMagicEngine.swift` — 165 of 218 lines — 233:45 cannot find type 'CGImage' in scope
- `Sources/IMAPClient.swift` — 188 of 329 lines — 229:25 cannot find type 'RawEgressStream' in scope (+11 more)
- `Sources/Inbox.swift` — 147 of 263 lines — 128:11 cannot find type 'AppModel' in scope (+4 more)
- `Sources/Intelligence.swift` — 217 of 251 lines — 30:19 cannot find type 'Color' in scope (+22 more)
- `Sources/IntelligenceStore.swift` — whole file (257 lines) — 14:17 cannot find type 'Lead' in scope (+14 more)
- `Sources/Journey.swift` — 52 of 123 lines — 81:11 cannot find type 'AppModel' in scope (+2 more)
- `Sources/JourneyExecution.swift` — 17 of 145 lines — 153:27 cannot find type 'NewsletterDeliveryProgress' in scope
- `Sources/LeadDatabase.swift` — whole file (490 lines) — 239:35 cannot find type 'AppModel' in scope (+173 more)
- `Sources/LeadDBPurchase.swift` — 262 of 313 lines — 192:54 cannot find 'LeadDB' in scope (+14 more)
- `Sources/LeadDomain.swift` — 241 of 378 lines — 23:15 cannot find type 'Color' in scope (+35 more)
- `Sources/LeadEngines.swift` — 77 of 126 lines — 124:11 cannot find type 'AppModel' in scope (+3 more)
- `Sources/LeadEngineSettings.swift` — 141 of 339 lines — 147:18 cannot find type 'DealStage' in scope (+15 more)
- `Sources/LeadFinder.swift` — 121 of 161 lines — 147:50 cannot find 'ConsentedEgress' in scope
- `Sources/LeadImportEngine.swift` — whole file (293 lines) — 232:21 cannot find type 'Lead' in scope (+7 more)
- `Sources/LeadImportScreen.swift` — whole file (216 lines) — 18:6 unknown attribute 'EnvironmentObject' (+128 more)
- `Sources/LeadPipelineScreens.swift` — whole file (356 lines) — 13:6 unknown attribute 'EnvironmentObject' (+141 more)
- `Sources/LeadsMigration.swift` — 143 of 175 lines — 98:36 cannot find type 'AppModel' in scope (+15 more)
- `Sources/MarketingHubScreens.swift` — whole file (439 lines) — 14:6 unknown attribute 'Binding' (+137 more)
- `Sources/MarketingOSScreen.swift` — whole file (205 lines) — 10:14 cannot find type 'Section' in scope (+57 more)
- `Sources/MessagesScreen.swift` — whole file (364 lines) — 17:6 unknown attribute 'EnvironmentObject' (+103 more)
- `Sources/Messaging.swift` — 183 of 374 lines — 228:29 cannot find type 'AppModel' in scope (+1 more)
- `Sources/MktFinder.swift` — 126 of 198 lines — 177:50 cannot find 'ConsentedEgress' in scope
- `Sources/Model.swift` — whole file (2,009 lines) — 175:28 cannot find type 'ReelProject' in scope (+28 more)
- `Sources/NewsletterAutoSend.swift` — whole file (86 lines) — 13:31 cannot find type 'AppModel' in scope (+8 more)
- `Sources/OutboundMailer.swift` — whole file (166 lines) — 41:29 cannot find type 'AppModel' in scope (+4 more)
- `Sources/Outreach.swift` — whole file (540 lines) — 29:49 cannot find type 'Lead' in scope (+13 more)
- `Sources/Pass5AI.swift` — 103 of 139 lines — 138:28 value of type 'String' has no member 'capitalizedFirst'
- `Sources/Pass5Engines.swift` — 27 of 318 lines — 323:11 cannot find type 'AppModel' in scope
- `Sources/Pass5Screens.swift` — whole file (1,079 lines) — 19:25 unknown attribute 'Binding' (+851 more)
- `Sources/PostInsights.swift` — 200 of 527 lines — 76:36 cannot find type 'ScheduledPost' in scope (+4 more)
- `Sources/PostInsightsScreen.swift` — whole file (299 lines) — 11:35 cannot find type 'AppModel' in scope (+119 more)
- `Sources/Prefs.swift` — 280 of 333 lines — 104:16 cannot find type 'Color' in scope (+25 more)
- `Sources/PremiumFX.swift` — whole file (206 lines) — 53:77 cannot find type 'Font' in scope (+74 more)
- `Sources/PublishEverywhere.swift` — whole file (447 lines) — 129:6 unknown attribute 'EnvironmentObject' (+154 more)
- `Sources/ReelAudio.swift` — 203 of 270 lines — 283:81 cannot find type 'AVAssetTrack' in scope (+32 more)
- `Sources/ReelCaptions.swift` — 133 of 176 lines — 115:38 cannot find type 'ReelProject' in scope (+2 more)
- `Sources/ReelColorGrade.swift` — whole file (162 lines) — 34:38 cannot find type 'CIImage' in scope (+11 more)
- `Sources/ReelEngine.swift` — 915 of 1,327 lines — 374:16 cannot find type 'ReelColorGrade' in scope (+40 more)
- `Sources/ReelLayerTracks.swift` — whole file (175 lines) — 9:6 unknown attribute 'Binding' (+110 more)
- `Sources/ReelVideoClips.swift` — 289 of 377 lines — 269:37 cannot find type 'ReelProject' in scope (+21 more)
- `Sources/ReferenceReelEngine.swift` — whole file (586 lines) — 109:42 cannot find 'ConsentedEgress' in scope (+3 more)
- `Sources/ReferenceReelStudio.swift` — whole file (450 lines) — 294:93 cannot find 'BLTheme' in scope (+41 more)
- `Sources/RemoteMusicLoader.swift` — 38 of 59 lines — 46:47 cannot find 'ConsentedEgress' in scope (+1 more)
- `Sources/Schedule.swift` — 28 of 102 lines — 54:108 cannot find type 'ScheduledPost' in scope (+3 more)
- `Sources/ScreenRecording.swift` — whole file (785 lines) — 600:62 cannot find 'BLTheme' in scope (+30 more)
- `Sources/Screens.swift` — whole file (2,270 lines) — 24:20 cannot find type 'View' in scope (+193 more)
- `Sources/SearchConsoleAnalytics.swift` — 203 of 304 lines — 252:31 cannot find 'GA4Analytics' in scope (+4 more)
- `Sources/SEOEngine.swift` — 31 of 252 lines — 246:39 cannot find 'ConsentedEgress' in scope
- `Sources/SEOScreens.swift` — whole file (449 lines) — 15:41 cannot find type 'Color' in scope (+320 more)
- `Sources/SequenceRunner.swift` — whole file (119 lines) — 20:31 cannot find type 'AppModel' in scope (+17 more)
- `Sources/Shortlinks.swift` — 530 of 687 lines — 415:39 cannot find 'ConsentedEgress' in scope (+10 more)
- `Sources/ShortlinksScreen.swift` — whole file (424 lines) — 26:6 unknown attribute 'State' (+199 more)
- `Sources/Social.swift` — 184 of 603 lines — 470:15 cannot find type 'Color' in scope (+13 more)
- `Sources/SocialAuth.swift` — 290 of 342 lines — 76:20 cannot find type 'View' in scope (+26 more)
- `Sources/SocialPublishClient.swift` — 447 of 1,078 lines — 831:39 cannot find 'ConsentedEgress' in scope (+1 more)
- `Sources/SpeechCaptions.swift` — 208 of 240 lines — 83:25 cannot find type 'SFSpeechRecognizer' in scope (+1 more)
- `Sources/SplitRecording.swift` — whole file (664 lines) — 265:18 cannot find 'MarketingScreenRecorder' in scope (+20 more)
- `Sources/StudioScreens.swift` — whole file (2,286 lines) — 25:35 cannot find type 'AppModel' in scope (+1298 more)
- `Sources/Teleprompter.swift` — 205 of 310 lines — 132:6 unknown attribute 'ObservedObject' (+82 more)
- `Sources/Theme.swift` — whole file (416 lines) — 12:25 cannot find 'Color' in scope (+159 more)
- `Sources/ThemeStudio.swift` — whole file (321 lines) — 25:6 unknown attribute 'EnvironmentObject' (+163 more)
- `Sources/WebsiteBackgroundEngine.swift` — whole file (326 lines) — 187:34 cannot find type 'MarketingCameraFraming' in scope (+3 more)
- `Sources/WebsiteLiveSync.swift` — 226 of 262 lines — 65:29 cannot find type 'AppModel' in scope (+23 more)
- `Sources/WebsiteVirtualSet.swift` — whole file (266 lines) — 204:54 cannot find 'BLFonts' in scope (+22 more)
- `Sources/Workflows.swift` — 139 of 190 lines — 101:28 cannot find type 'ProspectStatus' in scope (+10 more)
- `Sources/Workspace.swift` — 157 of 188 lines — 48:15 cannot find type 'Color' in scope (+21 more)

## Converted files

- `Sources/EmailAPI.swift` — Security → Windows Credential Manager (CredRead/CredWrite) and DPAPI; FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/GA4OAuth.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/LeadDBCredential.swift` — Security → Windows Credential Manager (CredRead/CredWrite) and DPAPI
- `Sources/MarketingKeychain.swift` — Security → Windows Credential Manager (CredRead/CredWrite) and DPAPI
- `Sources/PublishRelay.swift` — SwiftUI → WinUI 3 through swift-winrt, or SwiftCrossUI (SwiftUI-style views on WinUI); AVFoundation → Media Foundation and WASAPI (audio), Windows.Media.Capture (camera)
- `Sources/ReelPresenterOverlay.swift` — CoreGraphics → Direct2D / WIC for drawing, Win32 for displays and window lists
- `Sources/Sendblue.swift` — Security → Windows Credential Manager (CredRead/CredWrite) and DPAPI; FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/SessionStore.swift` — Security → Windows Credential Manager (CredRead/CredWrite) and DPAPI
- `Sources/Updater.swift` — FoundationNetworking → URLSession lives in FoundationNetworking off Apple platforms
- `Sources/WorkspaceStore.swift` — SQLite3 → swift-toolchain-sqlite (the same C API)
