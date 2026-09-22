# Circuit Mac-first Cross-platform Converter

Status: implementation plan of record  
Product: Circuit for macOS  
Target: source-available applications converted between Mac and Windows with target-native proof

## Product promise

Circuit is a Mac-first desktop application and conversion control plane. It automatically converts source-available applications in both directions: Mac to Windows and Windows to Mac. Windows is the conversion target for the initial corpus acceptance lane; Mac is also a target through admitted online Mac workers. A developer opens Circuit on a Mac, selects a source project, chooses the direction and policy, and starts one conversion. Circuit writes to a separate workspace; it never edits the source project in place.

The converter lives inside Circuit, while target-native execution lives on admitted online workers. Circuit creates the immutable input manifest, minimizes and uploads the source bundle, dispatches the job, resumes checkpoints, fences lost workers, verifies returned hashes and receipts, and exposes the converted artifacts. A local compiler or generated source is an intermediate stage, never the completed product.

The output is not merely translated source. A successful conversion contains:

1. a Windows-native source workspace;
2. a reproducible dependency lock and build definition;
3. a runnable Windows application and installer candidate;
4. unit, integration, launch, lifecycle, and feature-parity results;
5. a file-by-file conversion ledger with source and output hashes;
6. an explicit list of anything that was omitted, substituted, degraded, or still needs a person; and
7. real-Windows evidence. Mac simulation alone never earns a complete verdict.

“All Mac apps” means Circuit accepts and produces an honest terminal result for every source-available Mac app. It does not claim that an encrypted, signed, binary-only third-party `.app` can be reconstructed without source. Unsupported source is never silently dropped or counted as converted.

## Non-negotiable invariants

- Mac-first: intake, policy, progress, comparison, and handoff live in the Circuit macOS app.
- Source-preserving: the original project is read-only; generated work goes to a new conversion workspace.
- Compiler-owned truth: generated code counts only after its target compiler accepts it.
- Target-owned completion: a complete verdict requires compile, install, launch, parity, artifact-hash, and cleanup evidence from an admitted Windows or Mac host matching the selected target.
- No silent isolation: code compiled out, stubbed, or omitted is residual work, not converted work.
- Deterministic first: known framework, path, process, filesystem, crypto, database, and networking mappings run locally without a model.
- Bounded synthesis second: novel UI and platform code may use a configured builder, but every patch is scoped, diffed, compiled, tested, and reversible.
- Explicit online conversion: local analysis stays air-gapped, while a started conversion uploads only a minimized, hashed source bundle to the configured broker and admitted target worker.
- One conversion identity: every attempt, artifact, check, retry, and approval binds to one immutable conversion ID and input manifest.
- Honest packaging: unsigned artifacts are labeled staging-only; Store or Authenticode signing is a separate release gate.

## Supported input contract

Circuit accepts a folder, `.xcodeproj`, `.xcworkspace`, or Swift package containing source owned or authorized by the developer. Intake discovers all products and asks which desktop application target is canonical. It records:

- repository revision and dirty-file hashes;
- Xcode project/workspace, schemes, configurations, deployment targets, build settings, and generated-source steps;
- Swift Package Manager, CocoaPods, Carthage, npm, Python, Rust, Go, CMake, and vendored dependencies;
- Swift, Objective-C, Objective-C++, C/C++, Rust, JavaScript/TypeScript, Python, shell, assets, localization, models, and data files;
- app extensions, login items, XPC services, launch agents, helper tools, privileged helpers, drivers, and command-line companions;
- entitlements, sandbox use, Keychain groups, iCloud/CloudKit, notifications, URL schemes, document types, accessibility, camera, microphone, location, Bluetooth, USB, and network use;
- tests, fixtures, screenshots, golden files, and existing CI; and
- signing, notarization, update, licensing, analytics, and crash-reporting surfaces without copying secrets.

The intake result is a signed-by-hash `conversion-input.json`. A changed input invalidates downstream proof and creates a new attempt.

## Conversion architecture

### Online broker and worker fleet

The Mac app owns a durable conversion job with an input-manifest hash, source and target platforms, target profile, fresh operation nonce, lease, fencing token, admitted worker identity, progress checkpoints, returned artifact hashes, compiler/install/launch/parity receipts, and cleanup receipt. Workers have zero capacity until their OS/CPU/RAM/disk/encryption/toolchain inventory and all three admission canaries pass. A lost worker is fenced, its unverified artifacts are invalidated, and the same job is safely requeued under a fresh nonce.

The broker protocol supports immutable job submission, chunked minimized-source upload, target-worker claim, progress, artifact return, cancellation, restart recovery, and lost-host recovery. Production transport is HTTPS. Loopback transport exists only for deterministic protocol tests and does not count as target proof.

### 1. Mac intake and capability graph

Circuit extends its existing repository graph into a platform-capability graph. Each file, target, dependency, entitlement, asset, and runtime service becomes a node. Edges describe imports, linking, IPC, data ownership, launch order, permissions, and feature dependencies.

Every reachable user feature receives one of four initial classes:

- `portable`: expected to build unchanged on Windows;
- `mapped`: a deterministic compatibility rule exists;
- `synthesizable`: a Windows implementation can be generated behind a typed interface;
- `manual-gate`: hardware, legal, account, signing, or product behavior requires a named decision.

Unknown is a first-class state. Circuit must not turn unknown into portable.

### 2. Intermediate representation

The converter uses a language-independent app IR rather than global search-and-replace. The IR contains:

- product and target graph;
- typed declarations and call sites;
- UI scene tree, state bindings, commands, navigation, focus, accessibility, and keyboard shortcuts;
- lifecycle events and background work;
- data models, persistence, migrations, and file locations;
- network clients, authentication flows, local IPC, and service boundaries;
- permission and entitlement intent;
- asset catalog, fonts, colors, localizations, and responsive layout constraints; and
- tests and observable acceptance behaviors.

Source adapters initially cover SwiftSyntax/SourceKit for Swift, Clang for Objective-C/C/C++, and the existing Circuit parsers for supporting languages. When exact semantic tooling is unavailable, the IR marks confidence and the compiler/checker decides the result.

### 3. Target profiles

Circuit selects one explicit Windows target profile per product:

| Mac application shape | Default Windows profile | Rule |
|---|---|---|
| SwiftUI/AppKit native desktop | WinUI 3 + Windows App SDK | Default for a truly native Windows UI |
| Existing web UI or local web service | Tauri 2 + WebView2 | Reuse the real web UI and portable engine |
| Electron app | Electron Windows target | Preserve framework and port native modules |
| Flutter app | Flutter Windows desktop | Preserve Dart UI and port plugins |
| Qt app | Qt 6 Windows | Preserve Qt UI and platform adapters |
| CLI/menu utility without rich UI | Native Swift/C++/Rust executable | Smallest compatible runtime |

Profile selection is policy, not a guess. The user can override it before generation; after generation it is immutable for that attempt.

### 4. Compatibility packs

Compatibility is implemented behind typed CircuitPort interfaces. Each pack owns source rewrite rules, target code, fixtures, unit tests, native-Windows tests, and a support-level declaration.

Required packs:

| Pack | macOS surface | Windows surface |
|---|---|---|
| UI | SwiftUI/AppKit scenes, controls, menus, commands, sheets, focus, drag/drop | WinUI 3/XAML and Windows App SDK lifecycle |
| Foundation | URLSession, dates, files, notifications, processes | swift-corelibs Foundation and FoundationNetworking plus adapters |
| POSIX | Darwin, file descriptors, signals, locks, process IDs | UCRT and Win32 wrappers with explicit semantic tests |
| Security | generic Keychain passwords and secure random | Windows Credential Manager and CNG |
| Crypto | CryptoKit | swift-crypto or Windows CNG where semantics require it |
| Database | SQLite3/Core Data/SwiftData | SQLite, generated repositories, and explicit migration policy |
| Logging | os/OSLog/signposts | ETW and Windows Event Log plus local structured logs |
| Types/assets | UTType, CoreGraphics geometry, colors, images, fonts, asset catalogs | Windows type registry, Win2D/Direct2D/WIC, packaged assets |
| Networking | Network.framework paths, listeners, connections | Winsock, Windows.Networking, and Network List Manager |
| IPC/services | XPC, distributed notifications, launch agents | named pipes, App Services, Windows services, scheduled tasks |
| Notifications | UserNotifications | Windows App SDK notifications |
| Browser/auth | ASWebAuthenticationSession, universal links | Web Authentication Broker/system browser and protocol activation |
| Clipboard/share | NSPasteboard, sharing services | Windows clipboard and share contracts |
| Media | AVFoundation, speech, camera, microphone | Media Foundation, WASAPI, Windows speech and capture APIs |
| Devices | IOKit, Bluetooth, USB, location | SetupAPI/WinUSB, Windows.Devices, Windows Location |
| Accessibility | AX APIs and accessibility metadata | UI Automation with WCAG and keyboard acceptance tests |
| Updates | Sparkle/custom updater | Store updates or a separately signed updater |

Every compatibility symbol has `exact`, `equivalent`, `degraded`, or `unsupported` semantics. Only exact/equivalent results can satisfy parity without a recorded product decision.

### 5. UI conversion

SwiftUI/AppKit is the largest gap and therefore a first-class compiler, not a collection of regexes.

The UI compiler performs:

1. extract scenes, windows, views, modifiers, bindings, environment values, commands, menus, sheets, alerts, navigation, lists, tables, grids, canvases, and accessibility metadata into the UI IR;
2. generate WinUI 3 XAML plus strongly typed view models and command bindings;
3. convert colors, typography, spacing, images, symbols, localization, keyboard shortcuts, and responsive constraints into a generated design system;
4. map lifecycle and state restoration to Windows App SDK activation and persistence;
5. generate adapters for unsupported controls behind stable interfaces;
6. compile, inspect diagnostics, and repair only the affected IR node;
7. render deterministic Mac reference states and Windows candidate states; and
8. compare structure, text, focus order, accessibility tree, screenshots, and interaction traces.

Pixel equality is not required where platform conventions differ. Behavioral parity, information parity, accessibility, and a reviewed platform-native design are required.

### 6. Compiler-guided conversion loop

For each target, Circuit runs a bounded loop:

1. generate a fresh target tree from the immutable input manifest;
2. apply deterministic mappings;
3. compile on macOS where cross-compilation is authoritative;
4. dispatch the minimized workspace to an admitted Windows builder;
5. parse target compiler and linker diagnostics into IR nodes;
6. apply a known fix or request one bounded synthesis patch;
7. reject patches outside the named files or without a mapped diagnostic;
8. rerun affected unit tests, then the target build;
9. stop on success, repeated identical failure, exhausted retry budget, or a manual gate; and
10. retain every attempt and diff in the conversion ledger.

The loop never “succeeds” by wrapping the entire failing file in an Apple-only conditional. Isolation remains visible residual work.

### 7. Windows build and packaging

The generated workspace is self-contained and reproducible from documented tools. CI produces x64 first, then arm64 when dependencies support it. Packaging defaults to MSIX for Store-first distribution and produces an unsigned staging package until a real Partner Center identity is supplied. Optional self-distribution uses a separately approved Authenticode path.

The build stage records toolchain versions, dependency locks, compiler arguments, binary inventory, SBOM, licenses, hashes, Defender scan results, and installer contents. No signing secret is stored in the conversion workspace.

## Mac application workflow

1. **Choose Mac app** — folder/project picker, recent projects, and drag/drop.
2. **Select target** — Circuit shows discovered app targets and refuses to guess when multiple desktop products exist.
3. **Review capability report** — feature graph, supported packs, manual gates, predicted build lane, and data/network policy.
4. **Choose output** — a new empty destination outside the source tree.
5. **Convert** — deterministic transforms and local checks run first; the progress view is organized by feature and build stage, not token activity.
6. **Windows proof** — Circuit dispatches to an admitted local/remote Windows builder or exports a sealed CI job.
7. **Compare** — side-by-side feature matrix, interaction replay, accessibility results, screenshots, logs, and residuals.
8. **Package** — create an unsigned MSIX staging artifact; enable signing/submission only through their existing gates.
9. **Handoff** — export the Windows workspace, conversion report, evidence bundle, rollback instructions, and remaining manual decisions.

The Mac UI must support pause/resume, crash-safe checkpoints, cancellation between bounded steps, and complete deletion of generated outputs without touching the source app.

## Execution phases

### Phase 0 — Truth baseline and corpus

- Freeze the nine current Black Label app revisions as the primary corpus.
- Add small fixtures for every compatibility pack and failure class.
- Reproduce the current 35.6% native-Windows line result from the pinned inputs.
- Define feature-level parity tests for each app; line percentage remains diagnostic only.

Exit: every input and expected feature is hashed, every current result is reproducible, and no app has an unlabeled target.

### Phase 1 — Mac-first product shell

- Make Convert a primary Mac navigation surface with intake, target selection, policy, output, progress, comparison, and handoff.
- Add conversion database, resume checkpoints, cancellation, history, and evidence browser.
- Keep command-line/API routes as automation adapters over the same engine.

Exit: a user can complete, resume, inspect, and remove a conversion from the Mac app without Terminal.

### Phase 2 — Project and semantic IR

- Implement Xcode/workspace/scheme resolution and dependency/build-script inventory.
- Add SwiftSyntax/SourceKit and Clang adapters.
- Emit stable app IR and UI IR with source anchors and confidence.

Exit: all corpus apps produce schema-valid IR whose target/file/feature inventory reconciles with their builds.

### Phase 3 — Runtime compatibility packs

- Finish POSIX and process semantics.
- Finish Foundation networking and Network.framework adapters.
- Complete security, crypto, database, logging, types/assets, notifications, browser/auth, clipboard/share, IPC/service, media, devices, and accessibility packs.
- Add native Windows fixtures for every exported symbol and failure mode.

Exit: pack fixtures pass on macOS simulation and real Windows; unsupported symbols fail explicitly.

### Phase 4 — SwiftUI/AppKit to WinUI compiler

- Build UI IR extraction and WinUI 3 generation.
- Land navigation, data binding, controls, tables/lists/grids, commands/menus, windows/sheets/dialogs, drag/drop, focus, keyboard, localization, accessibility, and state restoration.
- Add render-state and interaction-trace comparison.

Exit: the defined UI fixture suite reaches behavioral parity and the corpus apps launch their primary workflows on Windows.

### Phase 5 — Services, helpers, and extensions

- Convert XPC and helper processes to typed named-pipe/App Service interfaces.
- Convert login/background jobs to explicit Windows service or scheduled-task manifests.
- Route privileged operations through a separately reviewed service boundary.
- Produce honest alternate behavior for Apple-only extensions that have no Windows product equivalent.

Exit: every non-main target is converted, deliberately excluded by product policy, or held at a named manual gate.

### Phase 6 — Proof, repair, and packaging

- Run real-Windows clean-build, install, launch, feature, restart, upgrade, uninstall, Defender, accessibility, and resource tests.
- Run bounded diagnostic repair with independent diff and evidence checks.
- Produce x64 MSIX; add arm64 where the dependency graph is compatible.

Exit: each app has a reproducible artifact and a complete evidence bundle, or a precise terminal residual verdict.

### Phase 7 — Portfolio acceptance

- Convert all nine pinned Black Label apps from clean source.
- Test their canonical user journeys on Windows.
- Compare against their Mac reference behavior.
- Re-run from scratch to prove the result is generated, not hand-maintained drift.

Exit: every required journey passes on Windows, no required feature is hidden or silently degraded, and the second clean conversion reproduces equivalent artifacts from the same input.

## Verification matrix

Each app receives these gates:

| Gate | Required evidence |
|---|---|
| Intake | input manifest, revision, dirty-file hashes, target selection |
| Transform | deterministic rule ledger and bounded synthesis diffs |
| Compile | zero unexpected compiler/linker errors on Windows |
| Unit | generated and preserved tests pass on Windows |
| Launch | clean Windows machine starts the installed app |
| Lifecycle | close, restart, state restore, crash recovery, update behavior |
| Features | canonical journey assertions and outputs |
| UI | screenshots, interaction traces, keyboard/focus, accessibility tree |
| Data | migration, persistence, path, encoding, locale, timezone, line-ending tests |
| Security | secret scan, dependency/SBOM review, least privilege, local data boundaries |
| Package | installer contents, hashes, install/upgrade/uninstall, Defender result |
| Parity | exact/equivalent/degraded/unsupported decision for every required feature |
| Reproduction | second clean run from the same manifest produces equivalent results |

## Terminal verdicts

- `complete`: every required gate passes on real Windows and no required feature is degraded or unsupported.
- `complete-with-approved-differences`: all gates pass and every intentional platform difference has an explicit product decision.
- `partial`: a runnable artifact exists but required features or gates remain.
- `held`: a named external decision, credential, hardware device, signing identity, or account action is required.
- `failed`: conversion or verification reached a terminal technical failure with reproducible evidence.

Only the first two are shippable conversion outcomes.

## Machine-readable contract

[`mac-first-windows-converter-plan.json`](mac-first-windows-converter-plan.json) is the executable plan index. Tests lock the Mac-first direction, immutable-source rule, phase ordering, required compatibility packs, real-Windows gate, and terminal verdict meanings. Implementation receipts must cite its plan version and requirement IDs.

## Current checkpoint and next implementation slice

The existing converter branch already supplies deterministic transforms, compiler-guided Swift isolation, a Tauri shell, Mac and Windows build lanes, Keychain/Credential Manager support, conversion UI, and native Windows measurements. Its latest measured corpus result is 118,342 of 332,174 lines compiling on Windows (35.6%), with zero measured line loss relative to the previous pass.

The next slice is Phase 3 POSIX/process semantics, followed by Network.framework. Those packs unblock engine code, but they do not complete the product. SwiftUI/AppKit-to-WinUI Phase 4 is the dominant requirement for full application conversion and must not be represented as a minor rewrite rule.
