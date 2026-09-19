#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import Foundation
#if canImport(ServiceManagement) && !CIRCUIT_WINDOWS_SIM
import ServiceManagement
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif

@main
enum AceLaunch {
    /// The gold tool lane spawns Ace's own binary as a headless MCP stdio
    /// server. That mode must be decided before any SwiftUI/AppKit state
    /// exists — the server process is a plain child of the brain CLI and must
    /// never touch the status item, lifecycle receipts, or single-instance
    /// behavior — and it never returns.
    static func main() {
        if CommandLine.arguments.dropFirst().first == AcademicDocumentHeadlessCommand.launchFlag {
            AcademicDocumentHeadlessCommand.runForever()
        }
        if CommandLine.arguments.contains(BrowserBackendHeadlessCommand.launchFlag)
            || CommandLine.arguments.dropFirst().first == BrowserBackendHeadlessCommand.dataLaunchFlag {
            BrowserBackendHeadlessCommand.runForever()
        }
        if CommandLine.arguments.contains(GmailBackendHeadlessCommand.launchFlag) {
            GmailBackendHeadlessCommand.runForever()
        }
        if CommandLine.arguments.contains(AceGoldToolServer.launchFlag) {
            AceGoldToolServer.runForever()
        }
        if CommandLine.arguments.contains(
            DesktopActionHeadlessCommand.launchFlag
        ) {
            DesktopActionHeadlessCommand.runForever()
        }
        if CommandLine.arguments.contains(
            WindowMoveHeadlessCommand.launchFlag
        ) {
            WindowMoveHeadlessCommand.runForever()
        }
        // Background workers may use the signed headless data adapters, but
        // never instantiate SwiftUI or feed a second visible Ace process.
        if ProcessInfo.processInfo.environment["ACE_BACKGROUND_EXECUTION_MODE"] == "backend" {
            FileHandle.standardError.write(Data("Background work cannot launch Ace's visible interface.\n".utf8))
            exit(6)
        }
        _ = AceRunningReleaseSnapshot.atLaunch
        leanring_buddyApp.main()
    }
}

struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    AceTrackedButton("Show Ace") {
                        (NSApp.delegate as? CompanionAppDelegate)?
                            .showAceForExplicitOpen()
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

/// One registration attempt survives only while the process-wide Stealth
/// latch has never raised. The event-tap cutoff invalidates it synchronously,
/// so lowering Stealth later cannot revive a blocked external transition.
private final class BackgroundServiceRegistrationClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var validStorage = true

    var isValid: Bool {
        lock.withLock { validStorage }
    }

    func invalidate() {
        lock.withLock {
            validStorage = false
        }
    }
}

/// The one quit path every user-facing Quit control must use. A raw
/// `NSApp.terminate(nil)` can be swallowed silently (a delegate, modal
/// session, or wedged main-actor task can stall it), which shipped as a
/// dead Quit button in Build 61 — pid 10128 outlived its own Quit click.
/// This helper writes the intent receipt first, asks AppKit to terminate,
/// and if the process is provably still alive shortly after, force-exits so
/// Quit can never again do nothing.
@MainActor
enum AceGuaranteedQuit {
    static func perform(reason: String, allowDiscardingNotes: Bool = false) {
        let manager = (NSApp.delegate as? CompanionAppDelegate)?.activeCompanionManager
        guard manager?.meetingNotetaker.hasUnsavedNotes != true || allowDiscardingNotes else { return }
        if allowDiscardingNotes {
            guard manager?.stealthActive != true,
                  !StealthEntryLatch.shared.isRaised,
                  !StealthVisibilityGate.shared.isActive else { return }
        }
        LifecycleLog.append("EXIT requested (\(reason))")
        NSApp.terminate(nil)
        // Reached only if terminate was cancelled or stalled: applicationWillTerminate
        // never ran, so the clean-quit receipt is missing. Force the exit and say so.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            LifecycleLog.append(
                "EXIT forced (terminate stalled after \(reason))"
            )
            exit(0)
        }
    }
}

/// Durable launch/exit receipts. "Where did he go" must be answerable from
/// lifecycle.log: an EXIT line names the clean path (quit, SIGTERM); a LAUNCH
/// with no EXIT after it means the process was killed hard (crash, kill -9,
/// force-quit) — the absence is itself the diagnosis.
enum LifecycleLog {
    /// Logs must never grow without bound. Any receipt log over ~1MB is
    /// trimmed to its most recent 256KB on launch, with a rotation marker.
    static func rotateOversizedLogs() {
        guard let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true) else { return }
        for logFileName in [
            "brain.log",
            "agent.log",
            "voice.log",
            "voice-safety.log",
            "notes.log",
            "lifecycle.log",
            "runtime.log",
        ] {
            let fileURL = directory.appendingPathComponent(logFileName)
            guard let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
                  fileSize > 1_000_000,
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let trimmedTail = String(contents.suffix(256_000))
            let rotated = "— rotated \(ISO8601DateFormatter().string(from: Date())) (was \(fileSize) bytes) —\n" + trimmedTail
            try? rotated.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
    }

    static func append(_ message: String) {
        guard let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true) else { return }
        // THIS IS THE FIRST WRITE OF THE APP'S LIFE — the LAUNCH receipt — so on
        // a buyer's fresh Mac it is what CREATES the support directory. A bare
        // createDirectory uses the umask (0755), and tools/effect-guard.sh
        // refuses EVERY bundled tool unless this directory is exactly 0700:
        // weather, system-info, calendar, reminders, notes, email, clipboard,
        // screenshot, timers, music, volume. All of them, silently, reported to
        // the owner as "Ace's effect boundary is unsafe".
        //
        // It never reproduced here because this Mac's directory was repaired by
        // hand on 2026-08-01. Route through the helper that already enforces and
        // REPAIRS the mode, instead of racing whichever subsystem writes first.
        try? PrivateSupportDirectory.ensure(at: directory)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let fileURL = directory.appendingPathComponent("lifecycle.log")
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: fileURL, options: .atomic)
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private static let launchPermissionRevalidationFailureIdentifier =
        "permissions.launchRevalidationFailed"

    enum StealthLaunchDisposition: Equatable {
        case normalRuntime
        case recoveredStealthRuntime
        case holdHidden
    }

    private static let deferredStealthRecoveryDiagnosticKey =
        "DeferredStealthRecoveryDiagnostic.v1"
    private static let retiredServiceBundleIdentifier =
        "com.blacklabel.background-service"
    private static let retiredServiceStatusArgument =
        "--background-service-status"
    private static let retiredServiceUnregisterArgument =
        "--unregister-background-service"

    private var menuBarPanelManager: MenuBarPanelManager?
    private var companionManagerStorage: CompanionManager?
    var activeCompanionManager: CompanionManager? {
        companionManagerStorage
    }
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var installReadinessSignalSource: DispatchSourceSignal?
    private var lifecycleReceiptsAreSafe = false
    private var pendingStableInstallResumeStage: String?
    private var entitlementUsableObserver: NSObjectProtocol?
    private var startupWasDeferredForEntitlement = false
    private var entitlementRelaunchIsInFlight = false
    private var reopenApplicationEventHandlerIsInstalled = false

    /// CompanionManager owns voice, capture, workers, and persistent receipts.
    /// Do not construct it until launch has either proved Stealth absent or
    /// safely opened the support boundary needed by the recovered exit runtime.
    private var companionManager: CompanionManager {
        if let companionManagerStorage {
            return companionManagerStorage
        }
        let manager = CompanionManager()
        companionManagerStorage = manager
        return manager
    }

    static func stealthLaunchDisposition(
        restorationState: StealthDurableIntent.RestorationState,
        supportBoundaryPrepared: Bool
    ) -> StealthLaunchDisposition {
        guard supportBoundaryPrepared else { return .holdHidden }
        switch restorationState {
        case .absent:
            return .normalRuntime
        case .present:
            return .recoveredStealthRuntime
        case .unsafeOrUnreadable:
            return .holdHidden
        }
    }

    /// Pure launch admission policy. The initial receipt probe is only a
    /// snapshot; every startup checkpoint supplies a fresh state plus the
    /// event-tap latch. Visible/runtime work is admitted only when both still
    /// prove normal operation.
    /// Acquires the runtime singleton, tolerating a deliberate handoff.
    ///
    /// Ace relaunches itself on purpose — after licensing
    /// (`resumeDeferredStartupAfterEntitlement`) and for a fresh screen-content
    /// proof. Both release the `flock` and immediately start a replacement, but
    /// the outgoing process is still finishing `applicationWillTerminate` when
    /// the replacement boots. A single non-blocking `LOCK_EX | LOCK_NB` attempt
    /// therefore lost that race: the replacement saw the lock held, treated
    /// itself as a duplicate, and terminated — then the original terminated as
    /// planned, leaving NOTHING running. Licensing the Mac made Ace vanish
    /// completely, which is the single worst moment for it to happen: it is the
    /// first thing a paying buyer does.
    ///
    /// A bounded retry closes the handoff window without weakening the
    /// guarantee — a genuine second instance still loses after the deadline,
    /// because a real owner never releases.
    static func acquireRuntimeInstanceLockAcrossHandoff(
        deadline: TimeInterval = 5.0
    ) -> Bool {
        if AceRuntimeInstanceLock.shared.acquire() { return true }
        let handoffDeadline = Date().addingTimeInterval(deadline)
        while Date() < handoffDeadline {
            // 100ms: short enough that a real duplicate exits promptly, long
            // enough to outlast an outgoing process's terminate.
            Thread.sleep(forTimeInterval: 0.1)
            if AceRuntimeInstanceLock.shared.acquire() {
                LifecycleLog.append(
                    "RUNTIME singleton acquired after handoff wait"
                )
                return true
            }
        }
        return false
    }

    static func normalRuntimeAdmissionIsOpen(
        restorationState: StealthDurableIntent.RestorationState,
        entryLatchIsRaised: Bool
    ) -> Bool {
        restorationState == .absent && !entryLatchIsRaised
    }

    /// Retains only the two command-line controls needed to erase registrations
    /// left by older Ace builds. Current builds never create this service.
    private func handleRetiredServiceCleanupArguments() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let service = SMAppService.loginItem(
            identifier: Self.retiredServiceBundleIdentifier
        )
        let legacyMainAppService = SMAppService.mainApp
        if arguments.contains(Self.retiredServiceStatusArgument) {
            // macOS reports `.notFound` when Background Task Management has no
            // helper record for this exact app. For maintenance/uninstall that
            // is the same terminal state as `.notRegistered`; exposing the raw
            // value made a genuinely absent service look like a failed erase.
            //
            // `.notRegistered` itself was missing from this arm while the
            // legacy-main arm below normalized both — so a SUCCESSFUL
            // `--unregister-background-service` printed
            // `SMAppServiceStatus(rawValue: 0)`, the uninstaller's contract
            // check rejected its own clean terminal, and `uninstall_ace.command`
            // refused with "the background service is still registered" on
            // every Mac. Ace could not be uninstalled by the owner at all.
            let serviceStatus = service.status == .notRegistered
                || service.status == .notFound
                ? "notRegistered"
                : "\(service.status)"
            let legacyMainStatus = legacyMainAppService.status == .notRegistered
                || legacyMainAppService.status == .notFound
                ? "notRegistered"
                : "\(legacyMainAppService.status)"
            let message = "background-service status=\(serviceStatus) "
                + "legacy-main status=\(legacyMainStatus)\n"
            FileHandle.standardOutput.write(Data(message.utf8))
            NSApp.terminate(nil)
            return true
        }
        guard arguments.contains(Self.retiredServiceUnregisterArgument) else {
            return false
        }

        do {
            if service.status != .notRegistered
                && service.status != .notFound {
                try service.unregister()
            }
            if legacyMainAppService.status == .enabled
                || legacyMainAppService.status == .requiresApproval {
                try legacyMainAppService.unregister()
            }
            if let endpointURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?
                .appendingPathComponent("BlackLabel", isDirectory: true)
                .appendingPathComponent(
                    "background-service-endpoint-v1.archive",
                    isDirectory: false
                ) {
                try? FileManager.default.removeItem(at: endpointURL)
            }
            UserDefaults.standard.removeObject(
                forKey: "ConfiguredBackgroundServiceBundlePath.v1"
            )
            UserDefaults.standard.removeObject(
                forKey: "DidConfigureLoginItem"
            )
            FileHandle.standardOutput.write(
                Data("background-service unregistered\n".utf8)
            )
        } catch {
            let message = "background-service unregister failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        NSApp.terminate(nil)
        return true
    }

    /// A copy opened from a disk image, Downloads, or App Translocation is an
    /// installer only. It must never restore entitlement, acquire Ace's global
    /// runtime lock, start a provider, or request TCC before the canonical copy
    /// has launched. Otherwise the source installer owns the singleton while
    /// waiting for /Applications/Ace.app, forcing the canonical child to exit.
    private func admitStableInstallBeforeRuntime() -> Bool {
        guard InstallLocation.isRunningFromAllowedStableLocation else {
            guard StealthDurableIntent.restorationState() == .absent else {
                StealthEntryLatch.shared.raiseInProcess()
                StealthVisibilityGate.shared.activateLocalWall()
                NSApp.terminate(nil)
                return false
            }
            InstallLocation.offerMoveIfNeeded()
            return false
        }

        do {
            pendingStableInstallResumeStage =
                try StableInstallResumeStore().consume()
        } catch {
            pendingStableInstallResumeStage = nil
            FileHandle.standardError.write(
                Data("stable-install resume receipt was rejected: \(error)\n".utf8)
            )
        }
        return true
    }

    private func installReopenApplicationEventHandler() {
        guard !reopenApplicationEventHandlerIsInstalled else { return }
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopenApplicationEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
        reopenApplicationEventHandlerIsInstalled = true
    }

    private func removeReopenApplicationEventHandler() {
        guard reopenApplicationEventHandlerIsInstalled else { return }
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
        reopenApplicationEventHandlerIsInstalled = false
    }

    @objc private func handleReopenApplicationEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        _ = event
        _ = replyEvent
        if lifecycleReceiptsAreSafe {
            LifecycleLog.append("MANUAL-OPEN source=apple-event-reopen")
        }
        showAceForExplicitOpen()
    }

    private func observeDeferredEntitlementStartupIfNeeded() {
        guard entitlementUsableObserver == nil else { return }
        entitlementUsableObserver = NotificationCenter.default.addObserver(
            forName: .aceEntitlementDidBecomeUsable,
            object: AceLicense.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resumeDeferredStartupAfterEntitlement()
            }
        }
    }

    /// A locked launch intentionally stopped before analytics, onboarding,
    /// login-item registration, update checks, and readiness probes. Once the
    /// browser approval or legacy key produces a verified lease, relaunch the
    /// exact canonical app so that entire startup path runs once from its real
    /// beginning. Release the singleton first or the replacement would exit as
    /// a duplicate—the same failure mode as the historical DMG installer.
    private func resumeDeferredStartupAfterEntitlement() {
        guard startupWasDeferredForEntitlement,
              !entitlementRelaunchIsInFlight,
              AceLicense.shared.admits(.premiumRuntimeStartup),
              InstallLocation.isRunningFromAllowedStableLocation,
              !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else {
            return
        }
        entitlementRelaunchIsInFlight = true
        AceRuntimeInstanceLock.shared.release()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        let replacementRequest: Void = NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] application, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var replacementDetail: String?
                if let application {
                    try? await Task.sleep(for: .seconds(1))
                    if !application.isTerminated,
                       application.bundleURL?.standardizedFileURL.path
                            == InstallLocation.allowedBundlePath {
                        // A live replacement at the canonical path IS the
                        // successful handoff — so hand off and exit.
                        //
                        // Build 64 terminated the child here instead, waiting
                        // for a "Task 3 nonce-bound startup attestation" that
                        // has no publisher anywhere in the app: nothing can
                        // ever send it, so the condition could never be met.
                        // The result was unconditional and reproducible on
                        // every Mac — the moment a buyer licensed, this owner
                        // killed its own healthy replacement and then exited
                        // itself, leaving NO Ace running at all. Linking the
                        // Mac, the first thing anyone does after paying, made
                        // the app disappear.
                        LifecycleLog.append(
                            "ENTITLEMENT relaunch handed off to pid="
                            + "\(application.processIdentifier)"
                        )
                        self.entitlementRelaunchIsInFlight = false
                        NSApp.terminate(nil)
                        return
                    }
                    replacementDetail =
                        "The replacement did not stay open at the canonical path."
                }

                self.entitlementRelaunchIsInFlight = false
                guard AceRuntimeInstanceLock.shared.acquire() else {
                    // Another exact Ace process won the singleton after the
                    // release above, so this process must leave it as owner.
                    NSApp.terminate(nil)
                    return
                }
                let detail = replacementDetail
                    ?? error?.localizedDescription
                    ?? "The replacement process did not stay open."
                FirstRunFailureReporter.shared.report(
                    FirstRunFailure(
                        id: "license.resumeStartupFailed",
                        summary: "Ace linked this Mac but could not finish reopening.",
                        remedy: detail + " Try again, or quit and open Ace from Applications.",
                        repairButtonTitle: "Try Again"
                    ),
                    interrupt: true,
                    repairRevision: "entitlement-startup-resume-v1",
                    verifiedRepair: { [weak self] in
                        guard let self else {
                            return .failed(
                                PermissionRepairFailure(
                                    code: "startup.owner_released",
                                    message: "The startup controller is no longer available."
                                )
                            )
                        }
                        self.resumeDeferredStartupAfterEntitlement()
                        return await PermissionRepairObservation.wait(
                            maximumPollCount: 600
                        ) {
                            guard !self.entitlementRelaunchIsInFlight else {
                                return nil
                            }
                            return .failed(
                                PermissionRepairFailure(
                                    code: self.startupWasDeferredForEntitlement
                                        ? "startup.child_attestation_deferred"
                                        : "startup.relaunch_not_verified",
                                    message: "Ace has not confirmed that the replacement app opened and finished starting. Quit Ace, open it from Applications, and check Buyer Recovery."
                                )
                            )
                        }
                    }
                )
            }
        }
        _ = replacementRequest
    }

    @MainActor
    static func reportCredentialStoreFailure(_ error: Error) {
        guard !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else { return }
        FirstRunFailureReporter.shared.report(
            FirstRunFailure(
                id: "credentials.firstLaunchInitializationFailed",
                summary: error.localizedDescription,
                remedy: "If you have a backup, restore the original credentials.v1.json and credentials.v1.key together. Check or recover first verifies the current files; unreadable files can be preserved before you reset and link this Mac again.",
                repairButtonTitle: "Check or recover"
            ),
            interrupt: false,
            repairRevision: "credential-store-recovery-v2",
            verifiedRepair: { await Self.repairCredentialStore() }
        )
    }

    @MainActor
    private static func repairCredentialStore() async -> PermissionRepairResult {
        let store = PromptFreeCredentialStore.shared
        guard !Task.isCancelled else {
            return .failed(PermissionRepairFailure(code: "credentials.recovery_cancelled", message: "Credential recovery was cancelled."))
        }
        let commitIfAllowed: (() -> Bool) -> Bool = { body in
            !Task.isCancelled && SetupVisibleEffectAdmission.commit(effect: body)
        }
        do {
            try store.verifyForRecovery(commitIfAllowed: commitIfAllowed)
            return .succeeded(.verifiedOperation("saved_credentials_read_back"))
        } catch {
            if error as? PromptFreeCredentialStoreError == .recoveryInterrupted
                || !commitIfAllowed({ true }) {
                return .failed(PermissionRepairFailure(code: "credentials.recovery_retired", message: "Credential recovery stopped before replacing the saved files."))
            }
            do {
                let review = try store.reviewUnreadableCredentials()
                let alert = NSAlert()
                alert.messageText = "Preserve and reset saved credentials?"
                alert.informativeText = "Ace will keep a private copy of the unreadable credential document and any existing encryption key in a credential-recovery folder inside Ace's Application Support folder, then create fresh local credentials. Link this Mac again using your original purchase. Encrypted Partner memories may remain unavailable until the original credentials are restored. Conversation history, provider sign-ins, settings and other files stay in place. You can cancel and restore the original files from your backup instead."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Preserve and reset")
                guard let choice = await SetupVisibleEffectAdmission.runModalIfAdmitted(alert),
                      choice == .alertSecondButtonReturn,
                      !Task.isCancelled else {
                    return .failed(PermissionRepairFailure(
                        code: "credentials.recovery_cancelled",
                        message: "Credential recovery was cancelled. Saved credentials were left unchanged."
                    ))
                }
                let archive = try store.recoverUnreadableCredentials(
                    reviewed: review, commitIfAllowed: commitIfAllowed
                )
                return .succeeded(.verifiedOperation(
                    "fresh local credentials; original files preserved in \(archive.lastPathComponent). Link this Mac again using your original purchase"
                ))
            } catch {
                return .failed(PermissionRepairFailure(
                    code: "credentials.recovery_failed", message: error.localizedDescription
                ))
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests need the app executable as their bundle loader so
        // they can exercise internal app types. Do not start Ace's UI, login
        // item, microphone, brain, or speech pipeline in that test host.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        if handleRetiredServiceCleanupArguments() {
            return
        }

        guard admitStableInstallBeforeRuntime() else {
            return
        }
        (AceAppearancePreference(rawValue: UserDefaults.standard.string(
            forKey: AceAppearancePreference.preferenceKey
        ) ?? "system") ?? .system).apply()
        installReopenApplicationEventHandler()

        // Establish local server-issued entitlement truth before ANY alternate
        // executable mode can branch around the companion runtime. This restore
        // performs no network/UI work; DashboardHostCLI applies the same central
        // admission gate before it serves a byte or starts a reader.
        AceLicense.shared.restoreLocalAdmissionForLaunch()

        // Owner intent survives crashes and relaunches. Normal UI is admitted
        // only after a tri-state probe proves both receipts absent inside a
        // safely opened owner-only support directory. An unsafe boundary never
        // constructs CompanionManager: it holds the process hidden and leaves
        // a content-free diagnostic for the first later verified normal launch.
        let initialRestorationState =
            StealthDurableIntent.restorationState()
        let supportBoundaryPrepared =
            StealthEntryLatch.shared.prepareExternalReceipt()
        let restorationState: StealthDurableIntent.RestorationState
        if supportBoundaryPrepared,
           initialRestorationState == .absent {
            // Close the missing-directory creation race. The first probe can
            // prove a nonexistent directory; receipt preparation creates it,
            // and this second probe must still prove both marker names absent.
            restorationState = StealthDurableIntent.restorationState()
        } else if supportBoundaryPrepared {
            restorationState = initialRestorationState
        } else {
            restorationState = .unsafeOrUnreadable
        }
        let stealthLaunchDisposition = Self.stealthLaunchDisposition(
            restorationState: restorationState,
            supportBoundaryPrepared: supportBoundaryPrepared
        )
        if supportBoundaryPrepared {
            installReadinessSignalHandler()
        }

        // A generated dashboard is a second signed Ace process and therefore
        // branches before the ordinary singleton lock, but never before licence
        // or Private Mode truth. Its own async refresh publishes server refusal
        // into the same admission gate used by every request and active reader.
        if ProcessInfo.processInfo.arguments.contains("--dashboard-host") {
            guard stealthLaunchDisposition == .normalRuntime,
                  !StealthEntryLatch.shared.isRaised else {
                NSApp.terminate(nil)
                return
            }
            AceLicense.shared.start()
            if DashboardHostCLI.startIfRequested() {
                return
            }
        }
        if supportBoundaryPrepared,
           !Self.acquireRuntimeInstanceLockAcrossHandoff() {
            // Another exact Ace process owns all normal UI/services. Never let
            // an updater, recovery overlap, or double-open create a second
            // runtime whose receipt snapshot can race the owner's wall entry.
            if stealthLaunchDisposition == .normalRuntime {
                UserDefaults.standard.set(
                    true,
                    forKey: Self.deferredStealthRecoveryDiagnosticKey
                )
            }
            StealthEntryLatch.shared.raiseInProcess()
            StealthVisibilityGate.shared.activateLocalWall()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return
        }
        if stealthLaunchDisposition != .normalRuntime {
            StealthEntryLatch.shared.raiseInProcess()
            StealthVisibilityGate.shared.activateLocalWall()
        }
        switch stealthLaunchDisposition {
        case .recoveredStealthRuntime:
            companionManager.start(restoringDurableStealth: true)
            return
        case .holdHidden:
            return
        case .normalRuntime:
            break
        }

        do {
            try PromptFreeCredentialStore.shared.initializeEmptyDocumentIfNeeded()
        } catch {
            Self.reportCredentialStoreFailure(error)
        }
        ClaudeAPI.purgePrivateTemporaryInputsFromPriorRuns()

        lifecycleReceiptsAreSafe = supportBoundaryPrepared
        print("🎯 BlackLabel: Starting...")
        print("🎯 BlackLabel: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
        if lifecycleReceiptsAreSafe {
            LifecycleLog.rotateOversizedLogs()
            LifecycleLog.append(
                "LAUNCH pid=\(ProcessInfo.processInfo.processIdentifier)"
                + " version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"
            )
        }
        installTerminationSignalHandlers()

        // A second Ace instance can publish X intent after the launch snapshot
        // above. Re-probe immediately before constructing the runtime. If the
        // receipt appeared, initialize only the silent recovered-exit control;
        // an unsafe boundary remains completely hidden and constructs nothing.
        let finalPreRuntimeRestorationState =
            StealthDurableIntent.restorationState()
        guard Self.normalRuntimeAdmissionIsOpen(
            restorationState: finalPreRuntimeRestorationState,
            entryLatchIsRaised: StealthEntryLatch.shared.isRaised
        ) else {
            UserDefaults.standard.set(
                true,
                forKey: Self.deferredStealthRecoveryDiagnosticKey
            )
            StealthEntryLatch.shared.raiseInProcess()
            StealthVisibilityGate.shared.activateLocalWall()
            if finalPreRuntimeRestorationState == .present {
                companionManager.start(restoringDurableStealth: true)
            }
            return
        }

        // License owns the first normal-runtime startup decision. Its local
        // restore is synchronous and runs before CompanionManager is even
        // constructed; the network refresh can later revoke access, which the
        // manager observes and quiesces process-wide.
        AceLicense.shared.start()
        let admittedCompanionManager = companionManager
        admittedCompanionManager.start()
        guard admittedCompanionManager
                .enforceStealthForLaunchRaceIfNeeded() else {
            UserDefaults.standard.set(
                true,
                forKey: Self.deferredStealthRecoveryDiagnosticKey
            )
            return
        }

        // The status item is also the recovery surface. Construct it before any
        // install repair, onboarding, analytics, permission probe, login item,
        // updater, or premium task, then stop launch here while locked.
        let admittedMenuBarPanelManager = MenuBarPanelManager(
            companionManager: admittedCompanionManager
        )
        menuBarPanelManager = admittedMenuBarPanelManager
        FloatingInboxController.shared.start()
        observeDeferredEntitlementStartupIfNeeded()
        guard admittedCompanionManager
                .enforceStealthForLaunchRaceIfNeeded() else {
            return
        }
        guard AceLicense.shared.admits(.premiumRuntimeStartup) else {
            startupWasDeferredForEntitlement = true
            admittedMenuBarPanelManager.showPanelForManualOpen()
            // A LOCKED install still checks for updates: a buyer stuck on a
            // broken build is exactly the buyer who must be able to discover
            // the fixed one (Build 61 installs that could not link were also
            // blind to every later release).
            AceUpdateCheck.shared.beginPeriodicChecks()
            // Helper registration/reconciliation is deliberately ABSENT from
            // the locked path (audited 2026-08-15, kept by design): Private
            // Mode ENTRY is a premium admission (AceEntitlementAdmissionPolicy
            // gates `.privateModeEntry`; the chord logs "STEALTH enter refused
            // reason=unlicensed"), so a locked install can never start a
            // stealth session for the helper to recover. The launches where
            // recovery duty is live — the recovered-stealth branch and the
            // explicit `--ace-exit-stealth-from-background-service` restore —
            // both branch BEFORE this license gate and never consult it, and
            // the helper's own login-time `start()` arms the physical chord
            // independent of Ace's license. Once a lease lands,
            // resumeDeferredStartupAfterEntitlement relaunches the canonical
            // app and the fresh startup performs registration for real.
            return
        }
        startupWasDeferredForEntitlement = false

        guard admittedCompanionManager.performNormalStartupCommit({
            emitDeferredStealthRecoveryDiagnosticIfNeeded()
            UserDefaults.standard.register(
                defaults: ["NSInitialToolTipDelay": 0]
            )
            BlackLabelAnalytics.configure()
            BlackLabelAnalytics.trackAppOpened()
        }) else {
            return
        }

        // BEFORE the intro presents: setup and every path-bound service require
        // the exact stable /Applications/Ace.app location. Downloads, mounted
        // disk images, App Translocation, renamed copies, and symlinks all stay
        // blocked until the owner accepts this repair or follows its exact
        // Finder instructions.
        guard admittedCompanionManager
                .enforceStealthForLaunchRaceIfNeeded() else {
            return
        }
        // This can intentionally show a modal first-run repair. Never hold the
        // event-tap latch across a modal loop; the reporter rechecks both walls
        // and StealthVisibilityGate aborts an alert if X arrives while it runs.
        InstallLocation.offerMoveIfNeeded()

        // First launch gets the full intro window, not the 320pt popover: a new
        // owner has to connect a CLI brain before Ace can answer anything, and
        // that walkthrough does not fit — nor belong — in a menu-bar panel.
        // Afterwards the panel is enough, and only opens if macOS dropped a
        // permission.
        let resumesStableInstallSetup =
            pendingStableInstallResumeStage == "onboarding"
        pendingStableInstallResumeStage = nil
        if !companionManager.hasCompletedOnboarding,
           (!companionManager.hasViewedFirstRunTour
                || resumesStableInstallSetup),
           InstallLocation.isRunningFromAllowedStableLocation {
            // The presenter owns its bounded setup-window admission. Do not
            // recursively hold the startup latch around that inner commit.
            AceIntroWindowController.shared.present(
                companionManager: companionManager
            ) { [weak companionManager] in
                companionManager?.triggerOnboarding()
            }
            guard admittedCompanionManager
                    .enforceStealthForLaunchRaceIfNeeded() else {
                return
            }
        } else if !companionManager.hasCompletedOnboarding,
                  !companionManager.hasViewedFirstRunTour {
            LifecycleLog.append(
                "ONBOARDING presentation blocked — Ace is not at "
                    + InstallLocation.allowedBundlePath
            )
        } else if !companionManager.hasCompletedOnboarding,
                  InstallLocation.isRunningFromAllowedStableLocation {
            LifecycleLog.append(
                "ONBOARDING incomplete — Finish Setup exposed without replaying tour"
            )
            menuBarPanelManager?.showPanelForManualOpen()
        } else if InstallLocation.isRunningFromAllowedStableLocation {
            guard admittedCompanionManager.performNormalStartupCommit({
                reconcileCompletedLaunchAfterAutomationRevalidation()
            }) else {
                return
            }
        }
        guard admittedCompanionManager
                .enforceStealthForLaunchRaceIfNeeded() else {
            return
        }
        retireRemovedBackgroundServiceIfPresent()

        // A shipped Ace has to be able to learn that a newer build exists —
        // AceUpdateCheck polls the storefront's /api/ace/version manifest
        // (first check 15s after launch, hourly, and after wake/foreground) and offers the account
        // page. Silent on every failure: offline or unreachable must never
        // surface an error or cost launch time.
        guard admittedCompanionManager.performNormalStartupCommit({
            AceUpdateCheck.shared.beginPeriodicChecks()
        }) else {
            return
        }

        // A notched Mac with a crowded menu bar can hide the status item
        // entirely — with no dock icon that reads as "Ace never opened".
        // Checked once, well after launch so the status bar has settled.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            guard let self else { return }
            guard self.companionManager
                    .enforceStealthForLaunchRaceIfNeeded() else {
                return
            }
            NotchConcealment.checkAndReport(
                menuBarPanelManager: self.menuBarPanelManager
            )
        }

        // Ace's mouth is sealed into the app: universal daemon, engine, model,
        // and voice profile. Probe those exact bytes at launch rather than
        // waiting for the first attempt to speak. A failed returning-owner probe may offer an explicit repair;
        // it must never reopen the completed first-run walkthrough itself.
        Task { @MainActor in
            guard admittedCompanionManager
                    .enforceStealthForLaunchRaceIfNeeded() else {
                return
            }
            let voiceState =
                await VoiceReadiness.shared.probeAndWaitForFullVerdict()
            guard admittedCompanionManager
                    .enforceStealthForLaunchRaceIfNeeded() else {
                return
            }
            if let voiceFailure = FirstRunFailure.voice(voiceState) {
                FirstRunFailureReporter.shared.report(
                    voiceFailure,
                    interrupt:
                        !AceIntroWindowController.shared.isVisible,
                    repairRevision: "voice-readiness-v1",
                    verifiedRepair: {
                        let verdict = await VoiceReadiness.shared
                            .probeAndWaitForFullVerdict(
                                requiresFreshDaemonVerdict: true
                            )
                        if verdict == .ready {
                            FirstRunFailureReporter.shared.clearVoiceFailures(
                                except: voiceFailure.id
                            )
                            return .succeeded(
                                .permissionReadback(permission: .voice)
                            )
                        }
                        return .failed(
                                PermissionRepairFailure(
                                    code: "voice.readiness_not_verified",
                                    message: verdict.ownerFacingSummary
                                )
                            )
                    }
                )
            }

            // Deafness check, UP FRONT, using the exact same authorization +
            // on-device-model predicate as live dictation. `isAvailable` alone
            // produced false-ready clean Macs.
            if companionManager.hasCompletedOnboarding,
               !companionManager.isOnDeviceDictationReady {
                FirstRunFailureReporter.shared.report(
                    .listeningUnavailable(
                        providerMessage:
                            companionManager
                                .appleSpeechRecognitionReadiness
                                .unavailableExplanation
                            ?? "this Mac's on-device dictation isn't ready."
                    ),
                    interrupt:
                        !AceIntroWindowController.shared.isVisible,
                    repairRevision: "speech-settings-v1",
                    verifiedRepair: {
                        await WindowPositionManager
                            .openSettingsAndWaitForReadback(
                                .dictation,
                                permission: .speechRecognition,
                                readback: {
                                    self.companionManager
                                        .isOnDeviceDictationReady
                                }
                            )
                    }
                )
            }

            // Brainlessness check — cheap existence probes only, never the
            // costly answer probes (BrainConnection owns those, in setup, where
            // the owner can act on the verdict). During onboarding the intro is
            // already showing brain state in context, so this only speaks up on
            // a Mac that finished setup and has since lost Claude — the
            // state where the hotkey would otherwise fail with nothing but a
            // spoken error from a possibly-dead mouth.
            let brainAvailable = AceBrainRoute.current == .customerOwned
                ? BrainBackend.resolveExecutable(
                    for: BrainBackend.selectedCLI
                  ) != nil
                : AceLicense.shared.hostedBrainCredentials != nil
            // The hosted token lives in Ace's private prompt-free credential
            // file, so a failure to read it back looks exactly like "no brain"
            // from the outside. Record which
            // one it was -- presence only, never the token itself.
            // Both lanes are recorded, not just the active one: on a developer
            // Mac the hosted credential is never consulted, so a credential
            // file read that silently failed would stay invisible until a buyer hit it.
            LifecycleLog.append(
                "BRAIN lane="
                    + (AceBrainRoute.current == .customerOwned
                        ? "customer-\(BrainBackend.selectedCLI.rawValue)"
                        : "founder-hosted")
                    + " active=" + (brainAvailable ? "resolved" : "missing")
                    + " hostedCredential="
                    + (AceLicense.shared.hostedBrainCredentials != nil
                        ? "resolved" : "missing")
            )
            if companionManager.hasCompletedOnboarding, !brainAvailable {
                FirstRunFailureReporter.shared.report(
                    .noBrainConnected,
                    interrupt:
                        !AceIntroWindowController.shared.isVisible,
                    repairRevision: "open-setup-v1",
                    verifiedRepair: { [weak self] in
                        guard let self else {
                            return .failed(
                                PermissionRepairFailure(
                                    code: "setup.owner_released",
                                    message: "The setup controller is no longer available."
                                )
                            )
                        }
                        AceIntroWindowController.shared.present(
                            companionManager: self.companionManager
                        ) { [weak companionManager] in
                                companionManager?.triggerOnboarding()
                        }
                        return AceIntroWindowController.shared.isVisible
                            ? .succeeded(.verifiedOperation("setup_window_visible"))
                            : .failed(
                                PermissionRepairFailure(
                                    code: "setup.window_not_visible",
                                    message: "Ace did not observe its Setup window after opening it."
                                )
                            )
                    }
                )
            }
        }

        // The automatic ResumeTourAfterRelaunch branch is retired, per
        // docs/superpowers/plans/2026-08-06-ace-build45-fresh-mac-remediation.md:
        // "Replace automatic ResumeTourAfterRelaunch behavior with Finish Setup
        // after the first presentation; keep explicit replay." The Finish Setup
        // footer action is the replacement and is wired.
        //
        // The setter was removed when that landed; only this reader survived, so
        // the branch could never execute while its comment claimed to be "the
        // normal buyer path on a clean Mac". A dead branch documented as the
        // live path is worse than no branch — it reads as coverage for the
        // tap-dead relaunch case and provides none. Removed rather than left to
        // mislead the next reader.

        #if DEBUG
        // The RUN_* flag files below do not exist in a Release compilation.
        // The development-Mac check is a second boundary for debug builds.
        guard DeveloperMachine.isDeveloperMachine else { return }

        // Observability: if a RUN_DEMO flag file exists, run the walkthrough on
        // launch so it can be watched/debugged without voice.
        if let flag = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel/RUN_DEMO"),
           FileManager.default.fileExists(atPath: flag.path) {
            try? FileManager.default.removeItem(at: flag)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak companionManager] in
                companionManager?.startWalkthrough()
            }
        }

        // Observability: a RUN_CONNECT flag file opens setup and runs the CLI
        // install for real, so the connect lane can be proven on a Mac where the
        // developer can't click a button from a shell. Same code path the button
        // calls — nothing is stubbed.
        if let connectFlag = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel/RUN_CONNECT"),
           FileManager.default.fileExists(atPath: connectFlag.path) {
            try? FileManager.default.removeItem(at: connectFlag)
            AceIntroWindowController.shared.present(companionManager: companionManager) { [weak companionManager] in
                companionManager?.triggerOnboarding()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                NotificationCenter.default.post(name: .aceRunConnectTest, object: nil)
            }
        }

        // Observability: a RUN_SIGNIN flag file exercises the sign-in hand-off —
        // the Apple Event that opens a Terminal already running the login. That
        // event needs a one-time Automation consent, so whether it SUCCEEDS is a
        // fact about this Mac that only a real run can establish.
        if let signInFlag = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel/RUN_SIGNIN"),
           FileManager.default.fileExists(atPath: signInFlag.path) {
            try? FileManager.default.removeItem(at: signInFlag)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NotificationCenter.default.post(name: .aceRunSignInTest, object: nil)
            }
        }

        // Observability: a RUN_TOUR flag file runs the first-run gem tour on
        // launch, so the introduction can be watched and verified without
        // clicking through the whole setup window every time.
        if let tourFlag = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel/RUN_TOUR"),
           FileManager.default.fileExists(atPath: tourFlag.path) {
            // The flag's CONTENT (optional) names the stage: a substring of the
            // target display's name ("built-in", "LG"). The mouse-follow rule is
            // right for buyers but loses to a hand on the mouse during filming.
            let screenHint = ((try? String(contentsOf: tourFlag, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: tourFlag)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak companionManager] in
                companionManager?.tourScreenHint = screenHint.isEmpty ? nil : screenHint
                companionManager?.startFirstRunTour()
            }
        }

        // Observability: a RUN_SAY flag file injects its contents as spoken
        // utterances on launch, so any voice-routing path can be tested
        // headlessly. Each LINE is one utterance, delivered 20s apart, so
        // follow-up flows ("find safari" → "open it") are testable too.
        if let sayFlag = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel/RUN_SAY"),
           FileManager.default.fileExists(atPath: sayFlag.path) {
            let injectedUtterances = ((try? String(contentsOf: sayFlag, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            try? FileManager.default.removeItem(at: sayFlag)
            for (utteranceIndex, utterance) in injectedUtterances.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(utteranceIndex) * 20) { [weak companionManager] in
                    // Labeled as a developer injection, so a Release build
                    // refuses it at the admission wall as well as here.
                    companionManager?.ingestOwnerUtterance(
                        utterance,
                        origin: .developerInjection
                    )
                }
            }
        }
        // Observability: a RUN_NOTES flag file runs a meeting-notes capture on
        // launch (file content = capture seconds, default 45) so the notetaker
        // pipeline can be verified headlessly, without voice.
        if let notesFlag = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel/RUN_NOTES"),
           FileManager.default.fileExists(atPath: notesFlag.path) {
            let flagContents = (try? String(contentsOf: notesFlag, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let captureSeconds = Int(flagContents ?? "") ?? 45
            try? FileManager.default.removeItem(at: notesFlag)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak companionManager] in
                companionManager?.debugRunMeetingNotes(seconds: captureSeconds)
            }
        }
        #endif
    }

    /// Resolve every ordinary manual open through one visible surface. AppKit
    /// does not reliably send `applicationShouldHandleReopen` to an LSUIElement
    /// menu-bar app when the already-running bundle is double-clicked in
    /// Applications; it does activate the process. Handling both callbacks is
    /// what makes a closed/interrupted setup reachable again without knowing
    /// where the status icon landed on a crowded menu bar.
    func showAceForExplicitOpen() {
        guard let companionManager = companionManagerStorage,
              companionManager.exitPrivateModeForManualOpen() else { return }
        showManualProductSurfaceIfReady()
    }

    private func showManualProductSurfaceIfReady() {
        guard let companionManager = companionManagerStorage,
              !companionManager.stealthActive,
              !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else {
            return
        }
        guard AceLicense.shared.admits(.premiumRuntimeStartup) else {
            menuBarPanelManager?.showPanelForManualOpen()
            return
        }
        guard InstallLocation.isRunningFromAllowedStableLocation else {
            InstallLocation.offerMoveIfNeeded()
            return
        }

        if companionManager.hasCompletedOnboarding
            || companionManager.hasViewedFirstRunTour {
            menuBarPanelManager?.showPanelForManualOpen()
        } else {
            AceIntroWindowController.shared.present(
                companionManager: companionManager
            ) { [weak companionManager] in
                companionManager?.triggerOnboarding()
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if lifecycleReceiptsAreSafe {
            LifecycleLog.append("MANUAL-OPEN source=app-delegate-reopen")
        }
        showAceForExplicitOpen()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        FloatingInboxController.shared.stop()
        removeReopenApplicationEventHandler()
        if let entitlementUsableObserver {
            NotificationCenter.default.removeObserver(
                entitlementUsableObserver
            )
            self.entitlementUsableObserver = nil
        }
        if lifecycleReceiptsAreSafe {
            LifecycleLog.append("EXIT applicationWillTerminate (clean quit)")
        }
        companionManagerStorage?.stop()
        AceRuntimeInstanceLock.shared.release()
    }

    private func emitDeferredStealthRecoveryDiagnosticIfNeeded() {
        guard lifecycleReceiptsAreSafe,
              UserDefaults.standard.bool(
                  forKey: Self.deferredStealthRecoveryDiagnosticKey
              ) else {
            return
        }
        UserDefaults.standard.removeObject(
            forKey: Self.deferredStealthRecoveryDiagnosticKey
        )
        LifecycleLog.append(
            "STEALTH prior hidden launch resolved; normal runtime admitted "
                + "after verified receipt absence"
        )
    }

    /// CompanionManager starts both no-prompt checks synchronously, so no stale
    /// false verdict can flash the panel or suppress a healthy overlay. The wait
    /// is bounded: a wedged proof is invalidated while still false, then opens
    /// the panel and offers an explicit guided retry.
    private func reconcileCompletedLaunchAfterAutomationRevalidation() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<150 {
                let automationIsPending =
                    self.companionManager.permissionWarmup
                        .isRevalidatingAutomation
                let screenContentIsPending =
                    self.companionManager.isRequestingScreenContent
                guard automationIsPending || screenContentIsPending else {
                    break
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            guard self.companionManager
                    .enforceStealthForLaunchRaceIfNeeded() else {
                return
            }

            let automationTimedOut =
                self.companionManager.permissionWarmup
                    .isRevalidatingAutomation
            let screenContentTimedOut =
                self.companionManager.isRequestingScreenContent
            if automationTimedOut || screenContentTimedOut {
                if automationTimedOut {
                    self.companionManager.permissionWarmup
                        .failCurrentNoninteractiveRevalidation()
                }
                if screenContentTimedOut {
                    self.companionManager
                        .failCurrentScreenContentProofRequest()
                }
                LifecycleLog.append(
                    "PERMISSION-REVALIDATE launch reconciliation timed out; "
                        + "guided retry required"
                )
                guard !StealthVisibilityGate.shared.isActive else {
                    return
                }
                self.menuBarPanelManager?.showPanelOnLaunch()
                self.reportLaunchPermissionRevalidationFailure()
                return
            }
            guard self.companionManager.hasCompletedOnboarding,
                  InstallLocation.isRunningFromAllowedStableLocation,
                  !StealthVisibilityGate.shared.isActive else {
                return
            }
            if self.companionManager.allPermissionsGranted {
                self.finishLaunchWithAllPermissionsGranted()
            } else {
                // The aggregate includes async proofs the pending-loop above
                // does not cover (on-device speech readiness lands on its own
                // schedule). A repair card must only ever report a PROVEN
                // missing dependency — never a proof that has not landed yet.
                // Deciding immediately fired ghost "Repair Ace" cards on the
                // 08-07, 08-10, and 08-12 launches, losing the race by well
                // under a second each time.
                for _ in 0..<100 {
                    if self.companionManager.allPermissionsGranted { break }
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        return
                    }
                }
                if self.companionManager.allPermissionsGranted {
                    LifecycleLog.append(
                        "REPAIR-EVAL proofs settled granted after wait; "
                            + "ghost repair card suppressed"
                    )
                    self.finishLaunchWithAllPermissionsGranted()
                } else {
                    LifecycleLog.append(
                        "REPAIR-EVAL dependency still missing after settle "
                            + "wait; repair card is legitimate"
                    )
                    self.menuBarPanelManager?.showPanelOnLaunch()
                    self.reportCompletedSetupRepairRequired()
                }
            }
        }
    }

    private func finishLaunchWithAllPermissionsGranted() {
        FirstRunFailureReporter.shared.clear(
            identifier:
                Self.launchPermissionRevalidationFailureIdentifier
        )
        NotificationCenter.default.post(
            name: .blacklabelDismissPanel,
            object: nil
        )
        if companionManager.isBlackLabelCursorEnabled {
            companionManager.setBlackLabelCursorEnabled(true)
        }
    }

    private func reportCompletedSetupRepairRequired() {
        let failure = FirstRunFailure(
            id: "permissions.completedSetupRepairRequired",
            summary: "Ace detected that a setup dependency is no longer ready.",
            remedy: "Choose Repair Ace to restore only what is missing. "
                + "Your completed setup will not restart.",
            repairButtonTitle: "Repair Ace"
        )
        FirstRunFailureReporter.shared.report(
            failure,
            repairRevision: "guided-repair-v1",
            verifiedRepair: { [weak self] in
                guard let self,
                      !StealthVisibilityGate.shared.isActive else {
                    return .failed(
                        PermissionRepairFailure(
                            code: "setup.repair_not_admitted",
                            message: "Exit Private Mode before starting guided repair."
                        )
                    )
                }
                return await SetupWalkthrough.shared.performExplicitRepair(
                    companionManager: self.companionManager,
                    successProof: .verifiedOperation(
                        "all_permissions_readback"
                    ),
                    isSatisfied: {
                        self.companionManager.allPermissionsGranted
                    },
                    incompleteFailure: PermissionRepairFailure(
                        code: "setup.repair_incomplete",
                        message: "The guided repair ended with one or more permissions still unverified."
                    )
                )
            }
        )
    }

    /// A timeout is not a permission verdict. Keep the proof false, surface the
    /// failure without relying on voice, and let the owner explicitly enter the
    /// guided repair flow. No consent prompt is raised until they choose a setup
    /// action.
    private func reportLaunchPermissionRevalidationFailure() {
        let failure = FirstRunFailure(
            id: Self.launchPermissionRevalidationFailureIdentifier,
            summary: "Ace couldn't finish checking screen and app access.",
            remedy: "Choose Retry to open the guided permission check. "
                + "Ace will ask before macOS shows any permission prompts.",
            repairButtonTitle: "Retry"
        )
        FirstRunFailureReporter.shared.report(
            failure,
            repairRevision: "launch-permission-retry-v1",
            verifiedRepair: { [weak self] in
                guard let self,
                      !StealthVisibilityGate.shared.isActive else {
                    return .failed(
                        PermissionRepairFailure(
                            code: "setup.retry_not_admitted",
                            message: "Exit Private Mode before retrying permission setup."
                        )
                    )
                }
                return await SetupWalkthrough.shared.performExplicitRepair(
                    companionManager: self.companionManager,
                    successProof: .verifiedOperation(
                        "launch_permissions_readback"
                    ),
                    isSatisfied: {
                        self.companionManager.allPermissionsGranted
                    },
                    incompleteFailure: PermissionRepairFailure(
                        code: "setup.launch_permissions_incomplete",
                        message: "The retry ended with one or more launch permissions still unverified."
                    )
                )
            }
        )
    }

    /// SIGTERM/SIGINT (e.g. `pkill`, the build script's install step) normally
    /// kill a GUI app without a trace. Route them through a logged, graceful
    /// terminate so lifecycle.log can tell a signal from a menu-bar quit —
    /// and a crash (no EXIT line at all) from either.
    private func installTerminationSignalHandlers() {
        for (signalNumber, signalName) in [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                if self?.lifecycleReceiptsAreSafe == true {
                    LifecycleLog.append(
                        "EXIT signal \(signalName) — terminating cleanly"
                    )
                }
                NSApp.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    /// SIGUSR1 is only a wake-up edge. DispatchSource transfers it to the main
    /// actor, where the app validates the owner-only nonce request, refreshes
    /// the content-free activity projection, and atomically replaces one
    /// receipt. No owner text is read or written by this path.
    private func installReadinessSignalHandler() {
        guard installReadinessSignalSource == nil else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: SIGUSR1,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.answerInstallReadinessChallenge()
        }
        source.resume()
        installReadinessSignalSource = source
    }

    private func answerInstallReadinessChallenge() {
        guard let supportDirectory = FileManager.default
            .urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?
            .appendingPathComponent("BlackLabel", isDirectory: true)
        else { return }
        let requestURL = supportDirectory.appendingPathComponent(
            InstallReadinessReceiptWriter.requestFileName,
            isDirectory: false
        )
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let request = try? InstallReadinessRequest.load(
            from: requestURL,
            actualProcessIdentifier: processIdentifier
        ) else {
            return
        }

        if let companionManagerStorage {
            companionManagerStorage.refreshInstallReadinessSnapshot()
        } else {
            // A launch that has not constructed its runtime is not idle.
            InstallReadinessCoordinator.shared.set(
                .setupAuth,
                active: true
            )
        }

        guard let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String,
        let sourceSHA256 = Bundle.main.object(
            forInfoDictionaryKey: "BLAppSourceSHA256"
        ) as? String,
        let receipt = try? InstallReadinessCoordinator.shared.makeReceipt(
            for: request,
            processIdentifier: processIdentifier,
            build: build,
            sourceSHA256: sourceSHA256.lowercased()
        ) else {
            return
        }
        _ = try? InstallReadinessReceiptWriter.write(
            receipt,
            supportDirectoryURL: supportDirectory
        )
    }

    /// Removes every registration and receipt left by builds that shipped the
    /// retired recovery helper. This is migration cleanup only: the current app
    /// never registers, launches, prompts for, or depends on a login item.
    private func retireRemovedBackgroundServiceIfPresent() {
        guard !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else {
            return
        }

        let retiredService = SMAppService.loginItem(
            identifier: Self.retiredServiceBundleIdentifier
        )
        if retiredService.status != .notRegistered,
           retiredService.status != .notFound {
            do {
                try retiredService.unregister()
                LifecycleLog.append(
                    "INSTALL retired legacy background-service registration"
                )
            } catch {
                LifecycleLog.append(
                    "INSTALL legacy background-service retirement deferred: "
                        + error.localizedDescription
                )
            }
        }

        let legacyMainService = SMAppService.mainApp
        if legacyMainService.status != .notRegistered,
           legacyMainService.status != .notFound {
            try? legacyMainService.unregister()
        }

        let defaults = UserDefaults.standard
        for key in [
            "ConfiguredBackgroundServiceBundlePath.v1",
            "BackgroundServiceRegistrationReceipt.v2",
            "DidConfigureLoginItem",
        ] {
            defaults.removeObject(forKey: key)
        }
        for suffix in [
            "ownerApprovalRequired",
            "approvalRequired",
            "endpointUnavailable",
            "recoveryAccessRequired",
            "registrationFailed",
            "migrationFailed",
        ] {
            FirstRunFailureReporter.shared.clear(
                identifier: "backgroundService." + suffix
            )
        }
    }
}
#endif // circuit-convert
