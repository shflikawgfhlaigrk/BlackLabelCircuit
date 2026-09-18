#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  SetupWalkthrough.swift
//  Ace
//
//  Ace sets itself up, one thing at a time, and asks for everything it needs.
//
//  Before this file, first run was a scatter: each missing thing raised its own
//  alert whenever it happened to be noticed, some only after the owner had
//  already tried and failed, and several just NAMED a System Settings path and
//  left the person to go find it. That is fine for someone who knows macOS. Our
//  buyers are students. Founder ruling 2026-07-29: Ace walks through every step
//  itself, asks for each permission itself, and takes the owner through every
//  failure — nobody should ever be left holding a list.
//
//  So this is a sequencer, not a checklist. It knows every proof Ace needs,
//  in the order they actually matter, and for each one it:
//
//    1. CHECKS whether it is already done, and skips silently if so — a returning
//       owner must never be walked through work they finished months ago.
//    2. ASKS FOR IT ITSELF wherever macOS gives us an API to ask. Microphone,
//       Accessibility, Screen Recording and Speech all have real request calls
//       that raise the actual system prompt. Voice is owned by Ace and loaded
//       from the engine/model sealed inside the app.
//    3. Falls back to opening the EXACT settings pane when Apple gives no API
//       (on-device Dictation is the only remaining manual system switch).
//    4. WAITS and re-checks, then moves on by itself. The owner never has to
//       come back and tell us they did it.
//
//  Everything is worded for someone who has never opened System Settings.
//

#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(ApplicationServices) && !CIRCUIT_WINDOWS_SIM
import ApplicationServices
#endif
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
import Foundation
#if canImport(Speech) && !CIRCUIT_WINDOWS_SIM
import Speech
#endif

/// A clean-Mac consent kickoff is one bounded native registration. Register its
/// X cutoff first, then place that kickoff itself under the process-wide latch.
/// X first means no call; kickoff first completes before X generation-cuts the
/// setup step. Callback waits and all later work remain outside the latch.
nonisolated final class SetupPermissionPromptStealthBoundary:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let entryLatch: StealthEntryLatch
    private var acceptsPrompt: Bool
    private var cutoffRegistration: UUID?

    init(entryLatch: StealthEntryLatch = .shared) {
        self.entryLatch = entryLatch
        acceptsPrompt = !entryLatch.isRaised
        cutoffRegistration = nil
        cutoffRegistration =
            entryLatch.registerSynchronousEntryCutoff { [weak self] in
                self?.cutOffSynchronously()
            }
    }

    deinit {
        if let cutoffRegistration {
            entryLatch.unregisterSynchronousEntryCutoff(cutoffRegistration)
        }
    }

    @discardableResult
    func invokeIfAdmitted(_ body: () -> Void) -> Bool {
        invokeIfAdmitted(
            beforeNativeCommit: {},
            body
        )
    }

    /// `beforeNativeCommit` exists for deterministic offline race tests. It is
    /// deliberately outside the global latch; the actual native kickoff below
    /// is the source-to-sink commit and must observe X raised in this gap.
    @discardableResult
    func invokeIfAdmitted(
        beforeNativeCommit: () -> Void,
        _ body: () -> Void
    ) -> Bool {
        beforeNativeCommit()
        return entryLatch.performUnlessRaised {
            let mayInvoke = lock.withLock {
                guard acceptsPrompt else { return false }
                acceptsPrompt = false
                return true
            }
            guard mayInvoke else { return false }
            body()
            return true
        } == true
    }

    func cutOffSynchronously() {
        lock.withLock {
            acceptsPrompt = false
        }
    }
}

/// Single source-to-sink admission point for setup-owned visible effects.
///
/// Both checks are repeated inside `performUnlessRaised`, immediately beside
/// the bounded AppKit/Workspace commit. X and the commit therefore have one
/// total order: X first executes no effect; effect first completes the one
/// bounded request before X raises the visibility wall.
@MainActor
enum SetupVisibleEffectAdmission {
    static func commit(
        effect: () -> Bool
    ) -> Bool {
        commit(
            entryLatch: .shared,
            visibilityIsBlocked: {
                StealthVisibilityGate.shared.isActive
            },
            effect: effect
        )
    }

    static func commit(
        entryLatch: StealthEntryLatch,
        visibilityIsBlocked: () -> Bool,
        effect: () -> Bool
    ) -> Bool {
        guard !visibilityIsBlocked(), !entryLatch.isRaised else {
            return false
        }
        return entryLatch.performUnlessRaised {
            guard !visibilityIsBlocked() else { return false }
            return effect()
        } == true
    }

    /// Presents an alert without starting an AppKit modal session. Pumping a
    /// modal session consumes clicks aimed at Ace's menu-bar panel, making every
    /// visible panel control look alive while acting like a ghost button.
    static func runModalIfAdmitted(
        _ alert: NSAlert
    ) async -> NSApplication.ModalResponse? {
        let session = NonmodalAlertSession(alert: alert)
        let didPresent = commit {
            session.present()
        }
        guard didPresent else {
            session.finish(response: nil)
            return nil
        }
        return await session.waitForResponse()
    }
}

/// Receives NSAlert button actions without entering AppKit's application-wide
/// modal event filter. The alert can be key while the menu panel remains fully
/// interactive, and the privacy wall still retires it promptly.
@MainActor
private final class NonmodalAlertSession: NSObject, NSWindowDelegate {
    private let alert: NSAlert
    private let previousActivationPolicy: NSApplication.ActivationPolicy
    private var promotedForPresentation = false
    private var continuation:
        CheckedContinuation<NSApplication.ModalResponse?, Never>?
    private var finished = false
    private var terminalResponse: NSApplication.ModalResponse?
    private var privacyWatchdog: Task<Void, Never>?

    init(alert: NSAlert) {
        self.alert = alert
        previousActivationPolicy = NSApp.activationPolicy()
    }

    func present() -> Bool {
        if previousActivationPolicy == .accessory {
            promotedForPresentation = NSApp.setActivationPolicy(.regular)
        }
        alert.layout()
        for (index, button) in alert.buttons.enumerated() {
            button.target = self
            button.action = #selector(buttonChosen(_:))
            button.tag = NSApplication.ModalResponse
                .alertFirstButtonReturn.rawValue + index
        }
        alert.window.delegate = self
        NSApp.unhide(nil)
        alert.window.level = .modalPanel
        alert.window.collectionBehavior.insert([
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ])
        alert.window.makeKeyAndOrderFront(nil)
        _ = NSRunningApplication.current.activate(options: [
            .activateAllWindows,
            .activateIgnoringOtherApps
        ])
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
        alert.window.orderFrontRegardless()
        privacyWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled,
                  !StealthEntryLatch.shared.isRaised,
                  !StealthVisibilityGate.shared.isActive {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard !Task.isCancelled else { return }
            self?.finish(response: nil)
        }
        return alert.window.isVisible
    }

    func waitForResponse() async -> NSApplication.ModalResponse? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if finished {
                    continuation.resume(returning: terminalResponse)
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(response: nil)
            }
        }
    }

    @objc private func buttonChosen(_ sender: NSButton) {
        finish(
            response: NSApplication.ModalResponse(rawValue: sender.tag)
        )
    }

    func windowWillClose(_ notification: Notification) {
        finish(response: nil)
    }

    func finish(response: NSApplication.ModalResponse?) {
        guard !finished else { return }
        finished = true
        terminalResponse = response
        privacyWatchdog?.cancel()
        privacyWatchdog = nil
        alert.window.delegate = nil
        alert.window.orderOut(nil)
        alert.window.close()
        if promotedForPresentation {
            _ = NSApp.setActivationPolicy(previousActivationPolicy)
        }
        let pendingContinuation = continuation
        continuation = nil
        pendingContinuation?.resume(returning: response)
    }
}

/// Persistent running/terminal receipt for an action chosen from an AppKit
/// modal. Presentation is committed beside the global visibility latch, and a
/// registered cutoff plus repeated dwell checks retire it at the privacy wall.
@MainActor
final class ActionReceiptPanelPresenter {
    private var window: NSPanel?
    private var statusLabel: NSTextField?
    private var stealthCutoffIdentifier: UUID?

    /// MUST stay free of `StealthEntryLatch`. Registering the cutoff here
    /// deadlocked Ace at launch: `StealthEntryLatch.performUnlessRaised` holds
    /// its non-recursive `NSLock` across the caller's closure, and
    /// `registerSynchronousEntryCutoff` takes that same lock. Constructing a
    /// presenter inside such a closure — which `AceUpdateCheck.shared`'s
    /// `dispatch_once` initializer did, straight from
    /// `applicationDidFinishLaunching` — re-entered the lock on the same thread
    /// and blocked the main thread forever. The app stayed alive at 0% CPU with
    /// no window, no menu-bar icon, and no way in: "I opened Ace and nothing
    /// appeared." The cutoff is registered on first presentation instead, which
    /// is the only time it can matter — a presenter with no panel has nothing
    /// to cut off.
    init() {}

    private func registerStealthCutoffIfNeeded() {
        guard stealthCutoffIdentifier == nil else { return }
        stealthCutoffIdentifier =
            StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                [weak self] in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.close() }
                }
            }
    }

    deinit {
        if let stealthCutoffIdentifier {
            StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(
                stealthCutoffIdentifier
            )
        }
    }

    @discardableResult
    func show(
        identifier: String,
        title: String,
        state: PermissionRepairState
    ) -> Bool {
        close()
        guard ActionReceiptVisibilityPolicy.allowsVisibleReceipt(
            entryLatchIsRaised: StealthEntryLatch.shared.isRaised,
            visibilityIsBlocked: StealthVisibilityGate.shared.isActive
        ) else { return false }
        // Registered here, not in `init` — see the note on `init`. A panel is
        // about to go on screen, so this is exactly when the cutoff must exist.
        registerStealthCutoffIfNeeded()

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        let statusLabel = NSTextField(
            wrappingLabelWithString: state.visibleStatus ?? "Waiting…"
        )
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier(identifier + ".state")
        statusLabel.setAccessibilityValue(state.accessibilityValue)

        let stack = NSStackView(views: [titleLabel, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(
            top: 12, left: 14, bottom: 12, right: 14
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 92),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Ace"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = stack
        panel.setAccessibilityIdentifier(identifier + ".receipt")
        let targetScreen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
        if let visibleFrame = targetScreen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: max(visibleFrame.minX, visibleFrame.maxX - panel.frame.width - 16),
                y: max(visibleFrame.minY, visibleFrame.maxY - panel.frame.height - 16)
            ))
        }
        let didPresent = SetupVisibleEffectAdmission.commit {
            self.window = panel
            self.statusLabel = statusLabel
            panel.orderFrontRegardless()
            return true
        }
        if !didPresent { panel.close() }
        return didPresent
    }

    @discardableResult
    func update(_ state: PermissionRepairState) -> Bool {
        guard let statusLabel, let window else { return false }
        let didUpdate = SetupVisibleEffectAdmission.commit {
            // commit already checks both privacy walls while owning the latch.
            // Reading isRaised here would reenter its non-recursive lock.
            statusLabel.stringValue = state.visibleStatus ?? "Waiting…"
            statusLabel.setAccessibilityValue(state.accessibilityValue)
            return window.isVisible
        }
        guard didUpdate else {
            close()
            return false
        }
        return true
    }

    func dwellWhileVisible(
        nanoseconds: UInt64 = 2_000_000_000
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(
            by: .nanoseconds(Int64(clamping: nanoseconds))
        )
        while ContinuousClock.now < deadline {
            guard ActionReceiptVisibilityPolicy.allowsVisibleReceipt(
                entryLatchIsRaised: StealthEntryLatch.shared.isRaised,
                visibilityIsBlocked: StealthVisibilityGate.shared.isActive
            ) else {
                close()
                return false
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        statusLabel = nil
    }
}

/// Owns the one asynchronous setup walk so an interactive session can stop it
/// before taking over Ace's visible and audio surfaces.
@MainActor
final class SetupWalkthroughRunLoop {
    private var task: Task<Void, Never>?
    private var activeRunIdentifier: UUID?

    var isRunning: Bool {
        task != nil
    }

    @discardableResult
    func startIfAllowed(
        interactiveSessionActive: Bool,
        operation: @escaping @MainActor () async -> Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard !interactiveSessionActive, task == nil else {
            return false
        }
        let runIdentifier = UUID()
        activeRunIdentifier = runIdentifier
        task = Task { @MainActor [weak self] in
            let completed = await operation()
            guard let self,
                  self.activeRunIdentifier == runIdentifier else {
                return
            }
            self.activeRunIdentifier = nil
            self.task = nil
            completion(completed)
        }
        return true
    }

    func cancelForInteractiveSession() {
        task?.cancel()
    }

    func cancelAndWaitForStop() async {
        task?.cancel()
        while task != nil { await Task.yield() }
    }
}

@MainActor
final class SetupWalkthrough {

    private enum StepID {
        static let install = "ace.walkthrough.install"
        static let license = "ace.walkthrough.license"
        static let microphone = "ace.walkthrough.microphone"
        static let accessibility = "ace.walkthrough.accessibility"
        static let screenRecording = "ace.walkthrough.screen-recording"
        static let screenRestart = "ace.walkthrough.screen-restart"
        static let screenContent = "ace.walkthrough.screen-content"
        static let appAutomation = "ace.walkthrough.app-automation"
        static let voice = "ace.walkthrough.voice"
        static let dictation = "ace.walkthrough.dictation"
        static let brain = "ace.walkthrough.brain"
    }

    static let shared = SetupWalkthrough()
    static let appAutomationInstruction =
        "Ace needs your permission before it can work with Mail, Notes, "
        + "Calendar, Reminders, Contacts, Messages, Music, Finder, and System Events.\n\n"
        + "Ace checks \(PermissionAutomationTarget.allCases.count) app permissions, one at a time. "
        + "macOS asks only for grants that are still needed. "
        + "Keep this window open and click Allow on each prompt. Ace performs only harmless read-only "
        + "checks here.\n\nThe Mail check reads the app version; it does not open a message, "
        + "create a draft, or send email. Local Apple Mail inbox reads separately require "
        + "Local Mail Access. Connected Gmail does not require that permission. "
        + "Access to a different app or a protected folder may still need its own macOS grant."

    private enum WaitOutcome: Equatable {
        case satisfied
        case timedOut
        case deferredForStealth
        case cancelled
    }

    /// One thing Ace needs, and everything required to get it without help.
    private struct Step {
        let identifier: String
        let title: String
        /// Plain instruction. No jargon, no menu paths the owner has to follow —
        /// if a path appears here it is because Ace is about to open it for them.
        let instruction: String
        /// Title of the button that DOES it.
        let actionTitle: String
        /// True once this is genuinely satisfied on this Mac.
        let isDone: () -> Bool
        /// Ask macOS for it, or open the one place it can be switched on.
        let perform: () -> Bool
        /// True when `perform` raises a system prompt we can wait on. False when
        /// it opens System Settings and the owner has to do something there —
        /// those get a longer wait and a nudge instead.
        let isSystemPrompt: Bool
        /// Some first-run downloads take far longer than an ordinary consent
        /// sheet. A required step never becomes "done" merely because this
        /// deadline elapsed; it only controls when Ace offers Try Again.
        let timeoutSeconds: TimeInterval
        /// True while an honest yes/no verdict is still arriving. This prevents
        /// a fallback action from appearing just because the speech daemon is
        /// still compiling on a Mac with a working voice.
        let isWaitingForInitialVerdict: () -> Bool
        /// Re-probes work completed outside Ace while this step waits.
        let refreshWhileWaiting: () -> Void
        let refreshIntervalSeconds: TimeInterval

        init(
            identifier: String,
            title: String,
            instruction: String,
            actionTitle: String,
            isDone: @escaping () -> Bool,
            perform: @escaping () -> Bool,
            isSystemPrompt: Bool,
            timeoutSeconds: TimeInterval? = nil,
            isWaitingForInitialVerdict: @escaping () -> Bool = { false },
            refreshWhileWaiting: @escaping () -> Void = {},
            refreshIntervalSeconds: TimeInterval = 10
        ) {
            self.identifier = identifier
            self.title = title
            self.instruction = instruction
            self.actionTitle = actionTitle
            self.isDone = isDone
            self.perform = perform
            self.isSystemPrompt = isSystemPrompt
            self.timeoutSeconds = timeoutSeconds ?? (isSystemPrompt ? 60 : 180)
            self.isWaitingForInitialVerdict = isWaitingForInitialVerdict
            self.refreshWhileWaiting = refreshWhileWaiting
            self.refreshIntervalSeconds = refreshIntervalSeconds
        }
    }

    private let runLoop = SetupWalkthroughRunLoop()
    private weak var pendingResumeCompanionManager: CompanionManager?
    private var activeCompletion: (() -> Void)?
    private var activeIntent: SetupWalkthroughIntent?
    private var pendingResumeCompletion: (() -> Void)?
    private var pendingResumeIntent: SetupWalkthroughIntent?
    private var explicitRepairOwner: UUID?
    private let stepAttemptCoordinator = PermissionRepairCoordinator()
    private let stepReceiptPresenter = ActionReceiptPanelPresenter()

    var isRunning: Bool {
        runLoop.isRunning
    }

    private init() {}

    /// Start takes ownership from any older setup wait, including the brain
    /// window's hour-long wait. Its old completion must never restart a tour.
    func cancelForStart() async {
        activeCompletion = nil
        activeIntent = nil
        pendingResumeCompanionManager = nil
        pendingResumeCompletion = nil
        pendingResumeIntent = nil
        stepReceiptPresenter.close()
        await runLoop.cancelAndWaitForStop()
        pendingResumeCompanionManager = nil
        pendingResumeCompletion = nil
        pendingResumeIntent = nil
    }

    /// Process-wide admission for every UI surface that starts guided repair.
    /// A second control receives an explicit busy result and can never adopt
    /// the first control's global walkthrough outcome as its own proof.
    func performExplicitRepair(
        companionManager: CompanionManager,
        successProof: PermissionRepairProof,
        isSatisfied: @escaping @MainActor () -> Bool,
        incompleteFailure: PermissionRepairFailure
    ) async -> PermissionRepairResult {
        guard explicitRepairOwner == nil, !isRunning else {
            return .failed(
                PermissionRepairFailure(
                    code: "setup.walkthrough_busy",
                    message: "Another guided setup repair already owns the walkthrough."
                )
            )
        }
        guard !companionManager.partnerModeIsActive,
              !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else {
            return .failed(
                PermissionRepairFailure(
                    code: "setup.walkthrough_not_admitted",
                    message: "End the active private or partner session before guided repair."
                )
            )
        }
        let owner = UUID()
        explicitRepairOwner = owner
        defer {
            if explicitRepairOwner == owner { explicitRepairOwner = nil }
        }
        var completed = false
        runIfAnythingIsMissing(
            companionManager: companionManager,
            intent: AssistantAvailabilityPolicy.ownedPermissionRepairIntent(
                hasCompletedOnboarding: companionManager.hasCompletedOnboarding
            ),
            onComplete: { completed = true }
        )
        let didStart = completed || isRunning
        guard didStart else {
            return .failed(
                PermissionRepairFailure(
                    code: "setup.walkthrough_not_started",
                    message: "The guided repair did not start for this control."
                )
            )
        }
        let outcome = await SetupWalkthroughOwnedRunWaiter.wait(
            completed: { completed },
            isRunning: { self.isRunning },
            cancelAndWait: {
                await self.runLoop.cancelAndWaitForStop()
            }
        )
        switch outcome {
        case .completed:
            return isSatisfied()
                ? .succeeded(successProof)
                : .failed(incompleteFailure)
        case .stopped:
            return .failed(incompleteFailure)
        case .cancelled:
            return .failed(
                PermissionRepairFailure(
                    code: "setup.walkthrough_cancelled",
                    message: "The owned guided repair stopped before publishing a terminal proof."
                )
            )
        }
    }

    /// Resumes unfinished first-run setup, or performs a failure-driven repair
    /// the owner explicitly requested. A completed setup is never admitted back
    /// into the automatic first-run lane.
    func runIfAnythingIsMissing(
        companionManager: CompanionManager,
        intent: SetupWalkthroughIntent = .automaticFirstRunResume,
        onComplete: (() -> Void)? = nil
    ) {
        let steps = buildSteps(
            companionManager: companionManager,
            intent: intent
        )
        let outstanding = steps.filter { !$0.isDone() }
        guard AssistantAvailabilityPolicy.mayRunSetupWalkthrough(
            hasCompletedOnboarding:
                companionManager.hasCompletedOnboarding,
            intent: intent,
            hasOutstandingSteps: !outstanding.isEmpty
        ) else {
            LifecycleLog.append(
                "SETUP-WALKTHROUGH blocked by one-time lifecycle policy "
                    + "intent=\(String(describing: intent)) "
                    + "completed=\(companionManager.hasCompletedOnboarding) "
                    + "outstanding=\(outstanding.count)"
            )
            return
        }
        guard !isRunning else {
            if let onComplete {
                pendingResumeCompanionManager = companionManager
                pendingResumeCompletion = onComplete
                pendingResumeIntent = intent
            }
            return
        }
        guard !companionManager.partnerModeIsActive else {
            LifecycleLog.append(
                "SETUP-WALKTHROUGH deferred (Partner Mode active)"
            )
            pendingResumeCompanionManager = companionManager
            pendingResumeCompletion = onComplete
            pendingResumeIntent = intent
            return
        }
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else {
            LifecycleLog.append("SETUP-WALKTHROUGH deferred (stealth)")
            pendingResumeCompanionManager = companionManager
            pendingResumeCompletion = onComplete
            pendingResumeIntent = intent
            return
        }
        guard !outstanding.isEmpty else {
            LifecycleLog.append("SETUP-WALKTHROUGH nothing outstanding")
            onComplete?()
            return
        }
        activeCompletion = onComplete
        activeIntent = intent
        LifecycleLog.append("SETUP-WALKTHROUGH \(outstanding.count) of \(steps.count) outstanding")
        let started = runLoop.startIfAllowed(
            interactiveSessionActive:
                companionManager.partnerModeIsActive,
            operation: { [weak self] in
                guard let self else { return false }
                return await self.walk(outstanding)
            },
            completion: { [weak self, weak companionManager] completed in
                guard let self, let companionManager else { return }
                let completion = self.activeCompletion
                let intent = self.activeIntent
                self.activeCompletion = nil
                self.activeIntent = nil
                if completed {
                    completion?()
                } else if StealthVisibilityGate.shared.isActive
                            || StealthEntryLatch.shared.isRaised
                            || companionManager.partnerModeIsActive {
                    self.pendingResumeCompanionManager =
                        companionManager
                    if self.pendingResumeCompletion == nil {
                        self.pendingResumeCompletion = completion
                    }
                    if self.pendingResumeIntent == nil {
                        self.pendingResumeIntent = intent
                    }
                }
                self.resumePendingWalkIfNeeded()
            }
        )
        if !started {
            activeCompletion = nil
            activeIntent = nil
            pendingResumeCompanionManager = companionManager
            pendingResumeCompletion = onComplete
            pendingResumeIntent = intent
        }
    }

    /// Partner owns the next visible and microphone interaction. Cancel the
    /// current modal immediately, but keep setup's completion so the walkthrough
    /// can continue after the owner ends Partner Mode.
    func suspendForPartnerActivation(
        companionManager: CompanionManager
    ) {
        guard isRunning else { return }
        pendingResumeCompanionManager = companionManager
        if pendingResumeCompletion == nil {
            pendingResumeCompletion = activeCompletion
        }
        if pendingResumeIntent == nil {
            pendingResumeIntent = activeIntent
        }
        activeCompletion = nil
        activeIntent = nil
        LifecycleLog.append(
            "SETUP-WALKTHROUGH suspended for Partner Mode"
        )
        runLoop.cancelForInteractiveSession()
    }

    /// Called after CompanionManager has lowered the process-wide stealth gate.
    /// If the old modal is still unwinding, remember the request and restart as
    /// soon as that walk releases `isRunning`.
    func resumeAfterStealth(companionManager: CompanionManager) {
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else {
            LifecycleLog.append("SETUP-WALKTHROUGH resume deferred (stealth still active)")
            return
        }
        guard isRunning else {
            LifecycleLog.append("SETUP-WALKTHROUGH resuming after stealth")
            let completion = pendingResumeCompletion
            let intent = pendingResumeIntent
            pendingResumeCompletion = nil
            pendingResumeIntent = nil
            runIfAnythingIsMissing(
                companionManager: companionManager,
                intent: intent ?? .automaticFirstRunResume,
                onComplete: completion
            )
            return
        }

        pendingResumeCompanionManager = companionManager
        pendingResumeCompletion = activeCompletion
        pendingResumeIntent = activeIntent
        LifecycleLog.append("SETUP-WALKTHROUGH resume queued while prior walk stops")
    }

    func resumeAfterPartnerMode(
        companionManager: CompanionManager
    ) {
        guard !companionManager.partnerModeIsActive else {
            LifecycleLog.append(
                "SETUP-WALKTHROUGH resume deferred (Partner Mode still active)"
            )
            return
        }
        guard !isRunning else {
            pendingResumeCompanionManager = companionManager
            LifecycleLog.append(
                "SETUP-WALKTHROUGH Partner resume queued while prior walk stops"
            )
            return
        }
        resumePendingWalkIfNeeded()
    }

    private func resumePendingWalkIfNeeded() {
        guard let companionManager = pendingResumeCompanionManager else { return }
        pendingResumeCompanionManager = nil
        let completion = pendingResumeCompletion
        let intent = pendingResumeIntent
        pendingResumeCompletion = nil
        pendingResumeIntent = nil
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else {
            LifecycleLog.append("SETUP-WALKTHROUGH queued resume deferred (stealth active again)")
            pendingResumeCompanionManager = companionManager
            pendingResumeCompletion = completion
            pendingResumeIntent = intent
            return
        }
        guard !companionManager.partnerModeIsActive else {
            LifecycleLog.append(
                "SETUP-WALKTHROUGH queued resume deferred (Partner Mode active)"
            )
            pendingResumeCompanionManager = companionManager
            pendingResumeCompletion = completion
            pendingResumeIntent = intent
            return
        }
        LifecycleLog.append("SETUP-WALKTHROUGH running queued resume")
        runIfAnythingIsMissing(
            companionManager: companionManager,
            intent: intent ?? .automaticFirstRunResume,
            onComplete: completion
        )
    }

    private func walk(_ steps: [Step]) async -> Bool {
        for (index, step) in steps.enumerated() {
            guard !Task.isCancelled else { return false }
            guard !deferIfStealthActivated(at: step.title) else { return false }

            await waitForInitialVerdict(step)
            guard !Task.isCancelled else { return false }
            guard !deferIfStealthActivated(at: step.title) else { return false }

            // Re-check: an earlier step may have fixed this one (turning on
            // Dictation downloads the speech model that Speech then reports).
            if step.isDone() { continue }

            var isFirstAttempt = true
            while !step.isDone() {
                guard !Task.isCancelled else { return false }
                let proceed = isFirstAttempt
                    ? await present(
                        step: step,
                        position: index + 1,
                        outOf: steps.count
                    )
                    : await presentStillMissing(step: step)
                guard !Task.isCancelled else { return false }
                guard !deferIfStealthActivated(at: step.title) else { return false }
                guard proceed else {
                    LifecycleLog.append("SETUP-WALKTHROUGH stopped by owner at \(step.title)")
                    return false
                }
                let attemptCompleted = await performOwnedStepAttempt(
                    step,
                    isRetry: !isFirstAttempt
                )
                guard let attemptCompleted else { return false }
                LifecycleLog.append(
                    "SETUP-WALKTHROUGH \(step.title) → \(attemptCompleted ? "done" : "still missing")"
                )
                isFirstAttempt = false
            }
        }
        LifecycleLog.append("SETUP-WALKTHROUGH finished")
        return true
    }

    /// Binds every walkthrough button — including every generated Try Again —
    /// to one typed generation and a persistent running/terminal receipt.
    private func performOwnedStepAttempt(
        _ step: Step,
        isRetry: Bool
    ) async -> Bool? {
        // The receipt surface appends ".state", so the base here must pair the
        // initial attempt as `<step>.action` / `<step>.state` and the retry as
        // `<step>.retry.action` / `<step>.retry.state` — never `.action.state`.
        let stateIdentifier = step.identifier + (isRetry ? ".retry" : "")
        let admitted = stepAttemptCoordinator.start { [weak self] in
            guard let self else {
                return .failed(
                    PermissionRepairFailure(
                        code: "step.owner_released",
                        message: "The guided setup owner was released before this attempt ran."
                    )
                )
            }
            guard self.perform(step) else {
                return .failed(
                    PermissionRepairFailure(
                        code: "step.action_not_admitted",
                        message: "The setup action was not admitted; nothing was counted as complete."
                    )
                )
            }
            LifecycleLog.append("SETUP-WALKTHROUGH requested \(step.title)")
            switch await self.waitUntilDone(step) {
            case .satisfied:
                return .succeeded(
                    .verifiedOperation(step.identifier + ".satisfied")
                )
            case .timedOut:
                return .failed(
                    PermissionRepairFailure(
                        code: "step.not_satisfied",
                        message: "The requested setup postcondition was not verified before this attempt timed out."
                    )
                )
            case .deferredForStealth:
                return .failed(
                    PermissionRepairFailure(
                        code: "step.deferred_for_stealth",
                        message: "The setup attempt stopped because Private Mode became active."
                    )
                )
            case .cancelled:
                return .failed(
                    PermissionRepairFailure(
                        code: "step.cancelled",
                        message: "The setup attempt was cancelled before a postcondition was proven."
                    )
                )
            }
        }
        guard admitted,
              let admittedAttempt = stepAttemptCoordinator.state.attempt else {
            return false
        }
        // The brain window already owns connection progress and its actions.
        // A second floating receipt obscures that window and offers no action.
        let showsReceipt = step.identifier != StepID.brain
        guard !showsReceipt || stepReceiptPresenter.show(
            identifier: stateIdentifier,
            title: isRetry ? "Trying \(step.title) again" : "Setting up \(step.title)",
            state: stepAttemptCoordinator.state
        ) else {
            stepAttemptCoordinator.invalidate()
            return nil
        }
        while stepAttemptCoordinator.state == .running(
            attempt: admittedAttempt
        ) {
            if Task.isCancelled
                || StealthEntryLatch.shared.isRaised
                || StealthVisibilityGate.shared.isActive {
                stepAttemptCoordinator.invalidate()
                stepReceiptPresenter.close()
                return nil
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard stepAttemptCoordinator.state.attempt == admittedAttempt else {
            stepReceiptPresenter.close()
            return nil
        }
        let terminal = stepAttemptCoordinator.state
        if showsReceipt {
            guard stepReceiptPresenter.update(terminal),
                  await stepReceiptPresenter.dwellWhileVisible() else {
                stepAttemptCoordinator.invalidate()
                return nil
            }
        }
        stepReceiptPresenter.close()
        stepAttemptCoordinator.invalidate()
        guard !Task.isCancelled else { return nil }
        if case .succeeded = terminal { return true }
        if case let .failed(_, failure) = terminal,
           failure.code == "step.deferred_for_stealth"
                || failure.code == "step.cancelled" {
            return nil
        }
        return false
    }

    private func deferIfStealthActivated(at stepTitle: String) -> Bool {
        guard StealthVisibilityGate.shared.isActive
                || StealthEntryLatch.shared.isRaised else {
            return false
        }
        LifecycleLog.append("SETUP-WALKTHROUGH deferred at \(stepTitle) (stealth)")
        return true
    }

    /// The only action funnel. Keeping the gate beside the imperative call
    /// guarantees permission prompts, Settings launches, installers, and setup
    /// windows all stop together.
    private func perform(_ step: Step) -> Bool {
        guard !deferIfStealthActivated(at: step.title) else { return false }
        // This is orchestration, not an effect boundary. Every concrete sink in
        // a step owns its own source-to-sink admission (prompt, visible commit,
        // process runner, capture boundary, or relaunch broker). Holding the
        // non-recursive global latch around the composite closure would deadlock
        // when it reached one of those tighter boundaries.
        let admitted = step.perform()
        return admitted && !deferIfStealthActivated(at: step.title)
    }

    /// Polls until the step reports done, or we run out of patience. System
    /// prompts resolve in seconds; a settings pane means the owner is clicking
    /// around, and a voice download can genuinely take minutes.
    private func waitUntilDone(_ step: Step) async -> WaitOutcome {
        let deadline = Date().addingTimeInterval(step.timeoutSeconds)
        var nextRefresh = Date()
        while Date() < deadline {
            if Task.isCancelled {
                return .cancelled
            }
            if StealthVisibilityGate.shared.isActive
                || StealthEntryLatch.shared.isRaised {
                return .deferredForStealth
            }
            if step.isDone() { return .satisfied }
            if Date() >= nextRefresh {
                step.refreshWhileWaiting()
                nextRefresh = Date().addingTimeInterval(step.refreshIntervalSeconds)
            }
            do {
                try await Task.sleep(
                    nanoseconds: 1_000_000_000
                )
            } catch {
                return .cancelled
            }
        }
        guard !Task.isCancelled else { return .cancelled }
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else {
            return .deferredForStealth
        }
        return step.isDone() ? .satisfied : .timedOut
    }

    private func waitForInitialVerdict(_ step: Step) async {
        let deadline = Date().addingTimeInterval(30)
        var nextRefresh = Date()
        while step.isWaitingForInitialVerdict(), Date() < deadline {
            guard !Task.isCancelled else { return }
            guard !StealthVisibilityGate.shared.isActive,
                  !StealthEntryLatch.shared.isRaised else {
                return
            }
            if Date() >= nextRefresh {
                step.refreshWhileWaiting()
                nextRefresh = Date().addingTimeInterval(step.refreshIntervalSeconds)
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
        }
    }

    // MARK: - Talking to the owner

    private func present(
        step: Step,
        position: Int,
        outOf total: Int
    ) async -> Bool {
        guard !deferIfStealthActivated(at: step.title) else { return false }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Setting up Ace — \(position) of \(total)"
        alert.informativeText = step.instruction
        let action = alert.addButton(withTitle: step.actionTitle)
        action.setAccessibilityIdentifier(step.identifier + ".action")
        action.setAccessibilityValue("phase=ready")
        alert.addButton(withTitle: "Stop for now")
        return await SetupVisibleEffectAdmission.runModalIfAdmitted(alert)
            == .alertFirstButtonReturn
    }

    private func presentStillMissing(step: Step) async -> Bool {
        guard !deferIfStealthActivated(at: step.title) else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "That one didn't take"
        alert.informativeText = step.instruction + "\n\nAce will wait while you do it."
        let action = alert.addButton(withTitle: "Try again")
        action.setAccessibilityIdentifier(step.identifier + ".retry.action")
        action.setAccessibilityValue("phase=failed;code=step.not_satisfied")
        alert.addButton(withTitle: "Stop for now")
        return await SetupVisibleEffectAdmission.runModalIfAdmitted(alert)
            == .alertFirstButtonReturn
    }

    @discardableResult
    private static func openSetupURL(_ url: URL) -> Bool {
        SetupVisibleEffectAdmission.commit {
            return NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Required proofs

    private func buildSteps(
        companionManager: CompanionManager,
        intent: SetupWalkthroughIntent
    ) -> [Step] {
        let steps = [
            Step(
                identifier: StepID.install,
                title: "Applications install",
                instruction: StableInstallCoordinator.repairInstruction,
                actionTitle: StableInstallCoordinator.repairActionTitle,
                isDone: {
                    InstallLocation.isRunningFromAllowedStableLocation
                },
                perform: {
                    InstallLocation.showInstallerInFinder()
                },
                isSystemPrompt: false,
                timeoutSeconds: 120
            ),
            Step(
                identifier: StepID.license,
                title: "licence",
                instruction:
                    "Link this Mac with the Ace account that owns your purchase. "
                    + "Ace opens a secure browser approval and finishes here automatically. "
                    + "An older licence key remains available inside that window if needed.",
                actionTitle: "Link this Mac",
                isDone: { AceLicense.shared.allowsUse },
                perform: {
                    AceLicense.shared.presentDeviceAuthorization()
                },
                isSystemPrompt: false,
                timeoutSeconds: 600
            ),
            Step(
                identifier: StepID.microphone,
                title: "microphone",
                instruction: "Ace needs your microphone to hear you. "
                    + "Your Mac will ask — click OK.",
                actionTitle: "Ask me now",
                isDone: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
                perform: {
                    let status = AVCaptureDevice.authorizationStatus(
                        for: .audio
                    )
                    if status == .denied || status == .restricted {
                        return Self.openSetupURL(
                            PermissionSystemSettingsPane.microphone.deepLink
                        )
                    }
                    guard status == .notDetermined else { return false }
                    let promptBoundary =
                        SetupPermissionPromptStealthBoundary()
                    let didRequest = promptBoundary.invokeIfAdmitted {
                        AVCaptureDevice.requestAccess(for: .audio) {
                            granted in
                            guard !granted else { return }
                            Task { @MainActor in
                                _ = Self.openSetupURL(
                                    PermissionSystemSettingsPane.microphone
                                        .deepLink
                                )
                            }
                        }
                    }
                    return didRequest
                },
                isSystemPrompt: true,
                timeoutSeconds: 20
            ),
            Step(
                identifier: StepID.accessibility,
                title: "accessibility",
                instruction: "Ace needs permission to see the Command+Shift keys. "
                    + "Your Mac will open a list — switch Ace on in it. "
                    + "Without this, holding the keys does nothing at all.",
                actionTitle: "Ask me now",
                isDone: { WindowPositionManager.hasAccessibilityPermission() },
                perform: {
                    // The prompting variant: macOS raises its own dialog with a
                    // button straight into the right list, which is far better
                    // than dropping someone in Settings to hunt for it.
                    let options = ["AXTrustedCheckOptionPrompt": true]
                    let promptBoundary =
                        SetupPermissionPromptStealthBoundary()
                    let didRequest = promptBoundary.invokeIfAdmitted {
                        _ = AXIsProcessTrustedWithOptions(
                            options as CFDictionary
                        )
                    }
                    guard didRequest == true else { return false }
                    guard !StealthVisibilityGate.shared.isActive,
                          !StealthEntryLatch.shared.isRaised else {
                        return false
                    }
                    return Self.openSetupURL(
                        PermissionSystemSettingsPane.accessibility.deepLink
                    )
                },
                isSystemPrompt: false
            ),
            Step(
                identifier: StepID.screenRecording,
                title: "screen recording",
                instruction: "Ace needs to see your screen to answer about it. "
                    + "Switch Ace on in the list that opens. "
                    + "When the switch is on, Ace will offer one Restart button. "
                    + "macOS only applies a new Screen Recording grant to a fresh app process.",
                actionTitle: "Ask me now",
                isDone: { CGPreflightScreenCaptureAccess() },
                perform: {
                    let promptBoundary =
                        SetupPermissionPromptStealthBoundary()
                    let didRequest = promptBoundary.invokeIfAdmitted {
                        _ = CGRequestScreenCaptureAccess()
                    }
                    guard didRequest == true else { return false }
                    guard !StealthVisibilityGate.shared.isActive,
                          !StealthEntryLatch.shared.isRaised else {
                        return false
                    }
                    return Self.openSetupURL(
                        PermissionSystemSettingsPane.screenRecording.deepLink
                    )
                },
                isSystemPrompt: false,
                timeoutSeconds: 300
            ),
            Step(
                identifier: StepID.screenRestart,
                title: "restart for screen check",
                instruction: "Screen Recording is switched on, but this copy of Ace "
                    + "started before macOS granted it.\n\n"
                    + "1. Click Restart Ace.\n"
                    + "2. Ace opens only the exact app at /Applications/Ace.app.\n"
                    + "3. Setup resumes automatically at the screen check.",
                actionTitle: "Restart Ace",
                isDone: {
                    CompanionManager
                        .screenContentRelaunchStepIsSatisfied(
                            screenRecordingWasAuthorizedAtProcessLaunch:
                                companionManager
                                    .screenRecordingWasAuthorizedAtProcessLaunch,
                            hasProcessScopedScreenContentProof:
                                companionManager
                                    .hasScreenContentPermission
                        )
                },
                perform: { [weak companionManager] in
                    companionManager?
                        .relaunchForFreshScreenContentProof() == true
                },
                isSystemPrompt: false,
                timeoutSeconds: 120
            ),
            Step(
                identifier: StepID.screenContent,
                title: "screen content",
                instruction: "One fresh, harmless capture proves this running copy "
                    + "can actually read the screen — not just that a switch is on. "
                    + "The tiny test image stays in memory only and is discarded.",
                actionTitle: "Check it now",
                isDone: { companionManager.hasScreenContentPermission },
                perform: { [weak companionManager] in
                    guard let outcome = companionManager?
                        .requestScreenContentPermission() else { return false }
                    if case .failed = outcome { return false }
                    return true
                },
                isSystemPrompt: true,
                timeoutSeconds: 90,
                isWaitingForInitialVerdict: {
                    companionManager.isRequestingScreenContent
                }
            ),
            Step(
                identifier: StepID.appAutomation,
                title: "app automation",
                instruction: Self.appAutomationInstruction,
                actionTitle: "Check every app",
                isDone: {
                    AssistantAvailabilityPolicy.setupStepIsSatisfied(
                        intent: intent,
                        hasCurrentProof:
                            companionManager.permissionWarmup
                                .hasProvenAppAutomation
                    )
                },
                perform: { [weak companionManager] in
                    companionManager?.permissionWarmup.runForSetup() == true
                },
                isSystemPrompt: true,
                timeoutSeconds: 1_800,
                refreshWhileWaiting: { [weak companionManager] in
                    guard let permissionWarmup = companionManager?.permissionWarmup,
                          !permissionWarmup.isRunning,
                          !permissionWarmup.hasProvenAppAutomation else { return }
                    permissionWarmup.runForSetup()
                },
                refreshIntervalSeconds: 15
            ),
            Step(
                identifier: StepID.voice,
                title: "ace voice",
                instruction: "Ace Voice is built into the app. "
                    + "There is no Siri setting, voice download, account, or cloud speech service.\n\n"
                    + "Click Check Ace Voice to verify the sealed engine and model, then start the live voice daemon.",
                actionTitle: "Check Ace Voice",
                isDone: { VoiceReadiness.shared.state == .ready },
                perform: {
                    VoiceReadiness.shared.probe(
                        requiresFreshDaemonVerdict: true
                    )
                },
                isSystemPrompt: false,
                timeoutSeconds: 45,
                isWaitingForInitialVerdict: {
                    VoiceReadiness.shared.state == .unknown
                        && VoiceReadiness.shared
                            .provenHostExecutablePath == nil
                },
                refreshWhileWaiting: {
                    VoiceReadiness.shared.probe()
                },
                refreshIntervalSeconds: 10
            ),
            Step(
                identifier: StepID.dictation,
                title: "dictation",
                instruction: "Dictation is what lets Ace hear you. Your Mac downloads its "
                    + "speech files when you switch it on.\n\n"
                    + "System Settings opens on Keyboard.\n"
                    + "1. Find Dictation and turn the switch ON.\n"
                    + "2. Click Enable if your Mac asks to confirm.\n"
                    + "3. Wait for the download to finish.\n\n"
                    + "Ace waits here until it can hear you.",
                actionTitle: "Open it for me",
                isDone: { companionManager.isOnDeviceDictationReady },
                perform: {
                    let authorization =
                        SFSpeechRecognizer.authorizationStatus()
                    if authorization == .notDetermined {
                        let promptBoundary =
                            SetupPermissionPromptStealthBoundary()
                        let didRequest = promptBoundary.invokeIfAdmitted {
                            SFSpeechRecognizer.requestAuthorization {
                                resolvedStatus in
                                Task { @MainActor in
                                    let destination: URL =
                                        resolvedStatus == .authorized
                                            ? PermissionSystemSettingsPane
                                                .dictation.deepLink
                                            : PermissionSystemSettingsPane
                                                .speechRecognition.deepLink
                                    _ = Self.openSetupURL(destination)
                                }
                            }
                        }
                        return didRequest
                    }
                    guard !StealthVisibilityGate.shared.isActive,
                          !StealthEntryLatch.shared.isRaised else {
                        return false
                    }
                    let destination: URL = authorization == .authorized
                        ? PermissionSystemSettingsPane.dictation.deepLink
                        : PermissionSystemSettingsPane.speechRecognition
                            .deepLink
                    return Self.openSetupURL(destination)
                },
                isSystemPrompt: false,
                timeoutSeconds: 900
            ),
            Step(
                identifier: StepID.brain,
                title: "brain",
                instruction: AceBrainRoute.current == .customerOwned
                    ? "Last one. Check your selected \(BrainBackend.selectedCLI.displayName) connection in Setup. Ace verifies a real answer before continuing."
                    : "Last one. Ace checks the private founder-hosted Black Label Codex brain.",
                actionTitle: "Set it up",
                isDone: {
                    AssistantAvailabilityPolicy.setupStepIsSatisfied(
                        intent: intent,
                        hasCurrentProof:
                            BrainConnectionProof.hasAnsweredRealProbe
                    )
                },
                perform: { [weak companionManager] in
                    guard let companionManager else { return false }
                    AceIntroWindowController.shared.present(
                        companionManager: companionManager,
                        onFinish: {}
                    )
                    return AceIntroWindowController.shared.isVisible
                },
                isSystemPrompt: false,
                timeoutSeconds: 3_600
            ),
        ]
        let automationRecovery = AssistantAvailabilityPolicy
            .aggregateAutomationRecoveryPlan(
                intent: intent,
                hasCurrentProof:
                    companionManager.permissionWarmup
                        .hasProvenAppAutomation
            )
        return steps.filter {
            $0.identifier != StepID.appAutomation
                || automationRecovery.schedulesStep
        }
    }
}
#endif // circuit-convert
