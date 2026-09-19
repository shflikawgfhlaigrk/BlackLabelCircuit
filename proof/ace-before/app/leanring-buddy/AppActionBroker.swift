//
//  AppActionBroker.swift
//  Ace
//
//  App-owned, deterministic execution boundary for the bundled tool library.
//  A brain may propose only a Codable tool name plus arguments. It never sees
//  an executable path, approval UUID, or approval-file path.
//

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Total-orders the one exact wrapper spawn with the X event-tap latch. The
/// process is published to its synchronous cutoff before `Process.run()`, so X
/// either rejects the spawn or can freeze/terminate the complete published
/// tree before its callback returns.
nonisolated enum AppActionWrapperLaunchAdmission {
    enum Outcome: Equatable, Sendable {
        case launched
        case blockedByStealth
        case blockedByVisibility
        case blockedBySuspension
        case registrationFailed
        case launchFailed
    }

    static func commit(
        isSuspended: @escaping () -> Bool,
        visibilityIsBlocked: @escaping () -> Bool,
        performUnlessRaised:
            (_ body: () -> Outcome) -> Outcome?,
        registerBeforeLaunch: @escaping () -> Bool,
        launch: @escaping () -> Bool
    ) -> Outcome {
        guard !isSuspended() else { return .blockedBySuspension }
        guard !visibilityIsBlocked() else {
            return .blockedByVisibility
        }
        return performUnlessRaised {
            guard !isSuspended() else {
                return .blockedBySuspension
            }
            guard !visibilityIsBlocked() else {
                return .blockedByVisibility
            }
            guard registerBeforeLaunch() else {
                return .registrationFailed
            }
            guard launch() else { return .launchFailed }
            return .launched
        } ?? .blockedByStealth
    }
}

enum BundledAppTool: String, Codable, CaseIterable, Sendable {
    case webFetch = "web-fetch"
    case webSearch = "web-search"
    case calendarToday = "calendar-today"
    case calendarAdd = "calendar-add"
    case reminderAdd = "reminder-add"
    case noteCreate = "note-create"
    case screenshotTake = "screenshot-take"
    case findFile = "find-file"
    case clipboard
    case systemInfo = "system-info"
    case musicControl = "music-control"
    case volumeSet = "volume-set"
    case blackLabelStatus = "bl-status"
    case weather
    case timerSet = "timer-set"
    case contactFind = "contact-find"
    case emailDraft = "email-draft"
    case emailRead = "email-read"
    case emailSend = "email-send"
    case messages
    case shortcutRun = "shortcut-run"
    case darkMode = "dark-mode"
    case wifiPower = "wifi-power"
    case trashFile = "trash-file"
    case notify
    case appList = "app-list"
    case wallpaperSet = "wallpaper-set"
    case windowMove = "window-move"
}

struct PlannedAppAction: Codable, Equatable, Sendable {
    let tool: BundledAppTool
    let arguments: [String]

    init(tool: BundledAppTool, arguments: [String] = []) {
        self.tool = tool
        self.arguments = arguments
    }

    func validate() throws {
        _ = try AppActionRules.validate(self)
    }

    /// Exact, untruncated representation of every value the wrapper will see.
    func confirmationPreview() throws -> String {
        try AppActionRules.validate(self).confirmationPreview(for: self)
    }
}

enum AppActionValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case forbiddenTool(BundledAppTool, String)
    case wrongArguments(BundledAppTool, String)
    case invalidArgument(BundledAppTool, String, String)

    var description: String {
        switch self {
        case let .forbiddenTool(tool, reason):
            return "\(tool.rawValue) is blocked: \(reason)"
        case let .wrongArguments(tool, expected):
            return "\(tool.rawValue) requires \(expected)"
        case let .invalidArgument(tool, field, reason):
            return "\(tool.rawValue) has an invalid \(field): \(reason)"
        }
    }
}

struct AppActionConfirmationRequest: Equatable, Sendable {
    let preview: String
    let expiresAt: Date
}

struct AppActionExecutionReceipt: Equatable, Sendable {
    let tool: BundledAppTool
    let exitStatus: Int32
    let standardOutput: String
    let standardError: String
}

enum AppActionBlockReason: String, Equatable, Sendable {
    case noCurrentPlan
    case confirmationExpired
    case confirmationRejected
    case anotherActionRunning
    case stealthActive
    case suspendedForStealth
    case cancelled
    case approvalUnavailable
    case bundledToolUnavailable
    case toolSafetyBoundary
    case gmailAccountUnavailable
}

struct AppActionBlock: Equatable, Sendable {
    let reason: AppActionBlockReason
    let message: String
}

struct AppActionFailure: Equatable, Sendable {
    let tool: BundledAppTool?
    let message: String
    let exitStatus: Int32?
    let standardOutput: String
    let standardError: String
}

enum AppActionOutcome: Equatable, Sendable {
    case verified(AppActionExecutionReceipt)
    case attempted(AppActionExecutionReceipt)
    case failed(AppActionFailure)
    case blocked(AppActionBlock)
}

enum AppActionBrokerPreparationError: Error, Equatable, CustomStringConvertible, Sendable {
    case suspendedForStealth
    case stealthActive
    case anotherActionRunning

    var description: String {
        switch self {
        case .suspendedForStealth:
            return "App actions are suspended for Private Mode."
        case .stealthActive:
            return "App actions are unavailable while Private Mode is active."
        case .anotherActionRunning:
            return "Another app action is already running."
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class AppActionBroker {
    static let confirmationLifetime: TimeInterval = 30

    private struct PendingPlan {
        let action: PlannedAppAction
        let validated: ValidatedAppAction
        let requestedAt: Date
    }

    private enum ActiveInterruption {
        case cancelled
        case stealth
    }

    private let clock: () -> Date
    private let processBox = RunningProcessBox()
    private let wrapperProcessCutoff = AppActionWrapperProcessCutoff()
    private var pendingPlan: PendingPlan?
    private var isExecuting = false
    private var isSuspendedForStealth = false
    private var activeGeneration: UInt64?
    private var activeTool: BundledAppTool?
    private var activeToolURL: URL?
    private var activeWrapperDidLaunch = false
    private var activeEmailDraftCleanupAuthority:
        EmailDraftCleanupAuthority?
    private var activeMessagesRequestMaterial: PrivateWrapperInput?
    private var activeMessagesInputWriteHandle: FileHandle?
    private var activeMessagesInputCompletionSignal: DispatchSemaphore?
    private var nextGeneration: UInt64 = 0
    private var activeInterruption: ActiveInterruption?
    private var activeCompletionSignal: DispatchSemaphore?
    private var didSynchronouslyAwaitTermination = false

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Stages one validated value plan and returns the exact text the owner must
    /// review. A later plan replaces the prior unconfirmed plan in full.
    func prepare(_ action: PlannedAppAction) throws -> AppActionConfirmationRequest {
        guard !StealthEntryLatch.shared.isRaised else {
            throw AppActionBrokerPreparationError.suspendedForStealth
        }
        guard !isExecuting else {
            throw AppActionBrokerPreparationError.anotherActionRunning
        }
        guard !isSuspendedForStealth else {
            throw AppActionBrokerPreparationError.suspendedForStealth
        }
        guard !StealthVisibilityGate.shared.isActive else {
            throw AppActionBrokerPreparationError.stealthActive
        }

        let validated = try AppActionRules.validate(action)
        let requestedAt = clock()
        let request = AppActionConfirmationRequest(
            preview: validated.confirmationPreview(for: action),
            expiresAt: requestedAt.addingTimeInterval(Self.confirmationLifetime)
        )
        guard let staged = try StealthEntryLatch.shared.performUnlessRaised({
            guard !isExecuting else {
                throw AppActionBrokerPreparationError.anotherActionRunning
            }
            guard !isSuspendedForStealth else {
                throw AppActionBrokerPreparationError.suspendedForStealth
            }
            guard !StealthVisibilityGate.shared.isActive else {
                throw AppActionBrokerPreparationError.stealthActive
            }
            pendingPlan = PendingPlan(
                action: action,
                validated: validated,
                requestedAt: requestedAt
            )
            return request
        }) else {
            throw AppActionBrokerPreparationError.suspendedForStealth
        }
        return staged
    }

    func discardCurrentPlan() {
        pendingPlan = nil
    }

    var hasPreparedEmailSend: Bool { pendingPlan?.action.tool == .emailSend }

    /// Executes the current app-owned validated plan immediately. The plan is
    /// consumed before launch, so retries cannot repeat the external effect.
    func executePrepared() async -> AppActionOutcome {
        await executeCurrentPlan(requiringDirectConfirmation: nil)
    }

    /// Compatibility entry point for non-owner flows that still provide an
    /// explicit direct-user token. Owner work uses executePrepared().
    func executeCurrentPlan(
        afterDirectUserConfirmation utterance: String
    ) async -> AppActionOutcome {
        await executeCurrentPlan(
            requiringDirectConfirmation: utterance
        )
    }

    private func executeCurrentPlan(
        requiringDirectConfirmation utterance: String?
    ) async -> AppActionOutcome {
        guard !isExecuting else {
            return blocked(
                .anotherActionRunning,
                "Another app action is already running."
            )
        }
        guard !StealthEntryLatch.shared.isRaised else {
            pendingPlan = nil
            return blocked(
                .suspendedForStealth,
                "The app action was blocked for Private Mode."
            )
        }
        guard !isSuspendedForStealth else {
            pendingPlan = nil
            return blocked(
                .suspendedForStealth,
                "The app action was blocked for Private Mode."
            )
        }
        guard !StealthVisibilityGate.shared.isActive else {
            pendingPlan = nil
            return blocked(
                .stealthActive,
                "The app action was blocked because Private Mode is active."
            )
        }
        guard let pendingPlan else {
            return blocked(.noCurrentPlan, "There is no current app action to confirm.")
        }
        if pendingPlan.action.tool == .emailSend, utterance == nil {
            return blocked(.confirmationRejected, "Review the exact email and select Send.")
        }

        let now = clock()
        let age = now.timeIntervalSince(pendingPlan.requestedAt)
        guard age >= 0, age <= Self.confirmationLifetime else {
            self.pendingPlan = nil
            return blocked(
                .confirmationExpired,
                "The app action confirmation expired; review a new preview."
            )
        }
        if let utterance {
            guard Self.isExactConfirmation(utterance) else {
                self.pendingPlan = nil
                return blocked(
                    .confirmationRejected,
                    "The response did not exactly confirm the previewed app action."
                )
            }
        }

        let revalidated: ValidatedAppAction
        do {
            revalidated = try AppActionRules.validate(pendingPlan.action)
        } catch {
            self.pendingPlan = nil
            return .failed(
                AppActionFailure(
                    tool: pendingPlan.action.tool,
                    message: "The confirmed plan no longer passed validation.",
                    exitStatus: nil,
                    standardOutput: "",
                    standardError: ""
                )
            )
        }
        guard revalidated == pendingPlan.validated else {
            self.pendingPlan = nil
            return .failed(
                AppActionFailure(
                    tool: pendingPlan.action.tool,
                    message: "The confirmed plan changed after its preview.",
                    exitStatus: nil,
                    standardOutput: "",
                    standardError: ""
                )
            )
        }

        self.pendingPlan = nil
        isExecuting = true
        activeInterruption = nil
        nextGeneration &+= 1
        let generation = nextGeneration
        activeGeneration = generation
        activeTool = pendingPlan.action.tool
        defer {
            wrapperProcessCutoff.clear(generation: generation)
            activeGeneration = nil
            activeTool = nil
            activeToolURL = nil
            activeWrapperDidLaunch = false
            activeEmailDraftCleanupAuthority = nil
            activeMessagesRequestMaterial = nil
            activeMessagesInputWriteHandle = nil
            activeMessagesInputCompletionSignal = nil
            activeInterruption = nil
            activeCompletionSignal = nil
            didSynchronouslyAwaitTermination = false
            isExecuting = false
        }

        let approval: OwnerTurnEffectAuthority
        do {
            // Generated only after one app-owned plan is consumed. The UUID and
            // its path remain private to this broker and the exact wrapper.
            approval = try OwnerTurnEffectAuthority.issue()
        } catch {
            return blocked(
                .approvalUnavailable,
                "The app could not create a one-time approval for this action."
            )
        }
        defer { approval.destroy() }

        let emailDraftCleanupAuthority:
            EmailDraftCleanupAuthority?
        if pendingPlan.action.tool == .emailDraft {
            do {
                emailDraftCleanupAuthority =
                    try EmailDraftCleanupAuthority.issue(
                        for: pendingPlan.action
                    )
            } catch {
                return blocked(
                    .approvalUnavailable,
                    "The app could not create the exact draft-cleanup authority."
                )
            }
        } else {
            emailDraftCleanupAuthority = nil
        }
        defer { emailDraftCleanupAuthority?.destroy() }
        activeEmailDraftCleanupAuthority =
            emailDraftCleanupAuthority

        let messagesRequestMaterial: PrivateWrapperInput?
        if pendingPlan.action.tool == .messages {
            do {
                messagesRequestMaterial = try approval.issueMessagesRequest(
                    for: pendingPlan.action
                )
            } catch {
                return blocked(
                    .approvalUnavailable,
                    "The app could not stage the private Messages request."
                )
            }
        } else if Self.emailTools.contains(pendingPlan.action.tool) {
            // Email runs on the buyer's own Google account now. Without an app
            // password there is nothing to send with, and saying so plainly
            // beats a transport error the buyer cannot act on.
            let credential: GmailAccountCredential?
            do {
                credential = try await GmailAccountStore().loadUsableCredential()
            } catch {
                return blocked(
                    .gmailAccountUnavailable,
                    "Ace could not connect the saved Gmail account. Reconnect it in Email settings."
                )
            }
            guard let credential else {
                return blocked(
                    .gmailAccountUnavailable,
                    "Connect Gmail in Email settings to use this account."
                )
            }
            do {
                messagesRequestMaterial = try GmailRequestMaterial.issue(
                    credential: credential
                )
            } catch {
                return blocked(
                    .gmailAccountUnavailable,
                    "Reconnect Gmail in Email settings to restore this account."
                )
            }
        } else {
            messagesRequestMaterial = nil
        }
        defer { messagesRequestMaterial?.destroy() }
        activeMessagesRequestMaterial = messagesRequestMaterial

        guard let toolURL = Self.exactBundledToolURL(for: pendingPlan.action.tool) else {
            return blocked(
                .bundledToolUnavailable,
                "The exact bundled tool is missing or is not a regular executable."
            )
        }
        activeToolURL = toolURL

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let messagesInputPipe = messagesRequestMaterial.map { _ in Pipe() }
        process.executableURL = toolURL
        process.arguments = messagesRequestMaterial?.wrapperArguments(
            replacing: pendingPlan.action.arguments
        ) ?? pendingPlan.action.arguments
        var wrapperEnvironment = approval.wrapperEnvironment()
        if let emailDraftCleanupAuthority {
            emailDraftCleanupAuthority.addOriginalWrapperEnvironment(
                to: &wrapperEnvironment
            )
        }
        process.environment = wrapperEnvironment
        process.standardInput = messagesInputPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let messagesInputPipe,
           Darwin.fcntl(
               messagesInputPipe.fileHandleForWriting.fileDescriptor,
               F_SETNOSIGPIPE,
               1
           ) != 0 {
            return .failed(
                AppActionFailure(
                    tool: pendingPlan.action.tool,
                    message:
                        "The private Messages request stream could not be prepared.",
                    exitStatus: nil,
                    standardOutput: "",
                    standardError: ""
                )
            )
        }
        defer {
            try? messagesInputPipe?.fileHandleForWriting.close()
        }
        var messagesInputTask: Task<Bool, Never>?

        // The event-tap cutoff is registered before admission. If X already
        // won, registration invokes it immediately and the latch rejects the
        // launch. If launch wins, the process is published before spawn while
        // the latch is held; X then freezes/kills that exact tree.
        let cutoffIdentifier =
            StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                [wrapperProcessCutoff] in
                wrapperProcessCutoff.cancelSynchronously(
                    generation: generation
                )
            }
        defer {
            StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(
                cutoffIdentifier
            )
        }

        let launchOutcome = AppActionWrapperLaunchAdmission.commit(
            isSuspended: { [weak self] in
                self?.isSuspendedForStealth != false
            },
            visibilityIsBlocked: {
                StealthVisibilityGate.shared.isActive
            },
            performUnlessRaised: { body in
                StealthEntryLatch.shared.performUnlessRaised(body)
            },
            registerBeforeLaunch: {
                [processBox, wrapperProcessCutoff] in
                guard wrapperProcessCutoff.register(
                    process,
                    generation: generation
                ) else {
                    return false
                }
                processBox.register(process, generation: generation)
                return true
            },
            launch: {
                do {
                    try process.run()
                    return true
                } catch {
                    return false
                }
            }
        )
        switch launchOutcome {
        case .launched:
            activeWrapperDidLaunch = true
            if let messagesInputPipe, let messagesRequestMaterial {
                do {
                    let inputHandle = messagesInputPipe.fileHandleForWriting
                    let inputData = try messagesRequestMaterial.consumeData()
                    let inputCompletion = DispatchSemaphore(value: 0)
                    activeMessagesInputWriteHandle = inputHandle
                    activeMessagesInputCompletionSignal = inputCompletion
                    messagesInputTask = Task.detached(priority: .userInitiated) {
                        var privateInput = inputData
                        defer {
                            if !privateInput.isEmpty {
                                privateInput.resetBytes(
                                    in: 0..<privateInput.count
                                )
                            }
                            try? inputHandle.close()
                            inputCompletion.signal()
                        }
                        do {
                            try inputHandle.write(contentsOf: privateInput)
                            return true
                        } catch {
                            return false
                        }
                    }
                } catch {
                    wrapperProcessCutoff.cancelSynchronously(
                        generation: generation
                    )
                    process.waitUntilExit()
                    processBox.clear(generation: generation)
                    wrapperProcessCutoff.clear(generation: generation)
                    return .failed(
                        AppActionFailure(
                            tool: pendingPlan.action.tool,
                            message:
                                "The private Messages request could not be streamed to the reviewed wrapper.",
                            exitStatus: process.terminationStatus,
                            standardOutput: "",
                            standardError: ""
                        )
                    )
                }
            }
        case .blockedBySuspension, .blockedByStealth:
            processBox.clear(generation: generation)
            wrapperProcessCutoff.clear(generation: generation)
            return blocked(
                .suspendedForStealth,
                "The app action was blocked for Private Mode."
            )
        case .blockedByVisibility:
            processBox.clear(generation: generation)
            wrapperProcessCutoff.clear(generation: generation)
            return blocked(
                .stealthActive,
                "The app action was blocked because Private Mode is active."
            )
        case .registrationFailed, .launchFailed:
            processBox.clear(generation: generation)
            wrapperProcessCutoff.clear(generation: generation)
            return .failed(
                AppActionFailure(
                    tool: pendingPlan.action.tool,
                    message: "The exact bundled tool could not be launched.",
                    exitStatus: nil,
                    standardOutput: "",
                    standardError: ""
                )
            )
        }

        let completionSignal = DispatchSemaphore(value: 0)
        activeCompletionSignal = completionSignal
        let capture = await Self.capture(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            completionSignal: completionSignal
        )
        let messagesInputSucceeded = await messagesInputTask?.value ?? true
        activeMessagesInputWriteHandle = nil
        activeMessagesInputCompletionSignal = nil
        messagesRequestMaterial?.destroy()
        processBox.clear(generation: generation)

        // The post-completion Stealth check precedes output interpretation or a
        // success claim. A wrapper killed during entry can never report success.
        //
        // But "killed" and "already finished" are not the same thing, and this
        // check could not tell them apart. A wrapper that ran to completion has
        // ALREADY produced its effect — the file is in the Trash, the event is
        // on the calendar, the draft is in Mail — so if a stop or a Private Mode
        // entry lands in the window between its exit and this continuation
        // resuming, reporting "The app action was cancelled." states something
        // about the world that is false, and leaves a real change unaccounted
        // for. Cancellation is a reporting question, so it defers to the
        // evidence. Private Mode is not: it keeps terminating the report
        // unconditionally, because its contract is about what may be surfaced,
        // not about what happened.
        let effectAlreadyLanded =
            capture.reason == .exit && capture.exitStatus == 0
        if let activeInterruption {
            switch activeInterruption {
            case .cancelled:
                if !effectAlreadyLanded {
                    return blocked(.cancelled, "The app action was cancelled.")
                }
            case .stealth:
                return blocked(
                    .suspendedForStealth,
                    "The app action was terminated for Private Mode."
                )
            }
        }
        guard !isSuspendedForStealth else {
            return blocked(
                .suspendedForStealth,
                "The app action was terminated for Private Mode."
            )
        }
        guard !StealthVisibilityGate.shared.isActive else {
            return blocked(
                .stealthActive,
                "Private Mode became active before the action result was accepted."
            )
        }
        guard !capture.timedOut else {
            return .failed(
                AppActionFailure(
                    tool: pendingPlan.action.tool,
                    message:
                        "The exact bundled tool exceeded its 45-second "
                        + "deadline and was terminated. Its outcome is unknown; "
                        + "do not retry automatically.",
                    exitStatus: capture.exitStatus,
                    standardOutput: capture.standardOutput,
                    standardError: capture.standardError
                )
            )
        }
        guard messagesInputSucceeded else {
            return .failed(
                AppActionFailure(
                    tool: pendingPlan.action.tool,
                    message:
                        "The private Messages request could not be streamed to the reviewed wrapper.",
                    exitStatus: capture.exitStatus,
                    standardOutput: "",
                    standardError: ""
                )
            )
        }

        let receipt = AppActionExecutionReceipt(
            tool: pendingPlan.action.tool,
            exitStatus: capture.exitStatus,
            standardOutput: capture.standardOutput,
            standardError: capture.standardError
        )
        if [4, 5, 6].contains(capture.exitStatus) {
            return blocked(
                .toolSafetyBoundary,
                Self.nonemptyDiagnostic(
                    stdout: capture.standardOutput,
                    stderr: capture.standardError,
                    fallback: "The bundled tool's safety boundary blocked the action."
                )
            )
        }
        guard capture.reason == .exit, capture.exitStatus == 0 else {
            return .failed(
                AppActionFailure(
                    tool: pendingPlan.action.tool,
                    message: Self.nonemptyDiagnostic(
                        stdout: capture.standardOutput,
                        stderr: capture.standardError,
                        fallback: "The bundled tool failed."
                    ),
                    exitStatus: capture.exitStatus,
                    standardOutput: capture.standardOutput,
                    standardError: capture.standardError
                )
            )
        }
        guard !capture.standardOutput.isEmpty else {
            return .failed(
                AppActionFailure(
                    tool: pendingPlan.action.tool,
                    message: "The bundled tool exited without a result to verify.",
                    exitStatus: capture.exitStatus,
                    standardOutput: "",
                    standardError: capture.standardError
                )
            )
        }
        return revalidated.verifiedOnSuccessfulExit
            ? .verified(receipt)
            : .attempted(receipt)
    }

    /// Synchronous Stealth entry boundary. CompanionManager should call this
    /// before StealthVisibilityGate.activate(), so a wrapper waiting on TCC is
    /// frozen and its complete descendant tree is gone before the shared
    /// visible-effect lock is acquired.
    func suspendForStealth() {
        guard !isSuspendedForStealth else { return }
        isSuspendedForStealth = true
        pendingPlan = nil
        activeInterruption = .stealth
        terminateAndSynchronouslyAwaitActiveWrapper()
    }

    /// New executions remain blocked until the app has fully left Stealth.
    @discardableResult
    func resumeAfterStealth() -> Bool {
        guard !StealthVisibilityGate.shared.isActive else { return false }
        isSuspendedForStealth = false
        return true
    }

    /// Cancels the exact active wrapper tree, or discards an unconfirmed plan.
    func cancelCurrentAction() {
        pendingPlan = nil
        activeInterruption = .cancelled
        terminateAndSynchronouslyAwaitActiveWrapper()
    }

    private func terminateAndSynchronouslyAwaitActiveWrapper() {
        guard let activeGeneration else { return }
        // Bounded libproc discovery stops every parent before inspecting its
        // children, then kills leaf-first. No helper process or wait runs from
        // the X callback, and the original wrapper is never resumed.
        wrapperProcessCutoff.cancelSynchronously(
            generation: activeGeneration
        )
        activeMessagesRequestMaterial?.destroy()
        try? activeMessagesInputWriteHandle?.close()
        if let activeMessagesInputCompletionSignal {
            _ = activeMessagesInputCompletionSignal.wait(
                timeout: .now() + 1
            )
        }
        if activeInterruption == .stealth,
           activeTool == .emailDraft,
           let activeToolURL,
           let activeEmailDraftCleanupAuthority,
           activeWrapperDidLaunch {
            // The draft being removed lives in the buyer's Gmail, so the
            // cleanup copy of the wrapper needs the same credential. A missing
            // one is passed through as nil: the wrapper then reports that it
            // could not remove the draft rather than claiming it did.
            let cleanupCredential = try? GmailAccountStore().loadCredential()
            _ = Self.performBoundedEmailDraftCleanup(
                toolURL: activeToolURL,
                authority: activeEmailDraftCleanupAuthority,
                credentialData: cleanupCredential.map { credential in
                    Data([
                        credential.transportSchema,
                        credential.transportSecret,
                        credential.address,
                        "", "", "",
                    ].joined(separator: "\n").utf8)
                }
            )
        }
        guard !didSynchronouslyAwaitTermination,
              let activeCompletionSignal else { return }
        // A wedged wrapper must never delay the in-process Stealth wall
        // indefinitely. The process tree has already received SIGKILL; wait
        // only long enough for the capture lane to close its pipes.
        _ = activeCompletionSignal.wait(timeout: .now() + 1)
        didSynchronouslyAwaitTermination = true
    }

    /// The only post-X mutation authority in this broker. The original draft
    /// wrapper tree is frozen and killed leaf-first before this starts. A
    /// separately spawned copy of the exact bundled wrapper receives no
    /// ordinary mutation approval and can consume only its pre-minted,
    /// exact-draft cleanup token.
    nonisolated private static func performBoundedEmailDraftCleanup(
        toolURL: URL,
        authority: EmailDraftCleanupAuthority,
        credentialData: Data?
    ) -> Bool {
        guard exactBundledToolURL(for: .emailDraft) == toolURL,
              authority.filesRemainSafeForCleanup() else {
            return false
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let completion = DispatchSemaphore(value: 0)
        let stdout = AppActionDataBox()
        let stderr = AppActionDataBox()
        let readers = DispatchGroup()

        process.executableURL = toolURL
        process.arguments = [
            "--stealth-cleanup",
            authority.operationID,
        ]
        process.environment = authority.cleanupWrapperEnvironment()
        let credentialPipe = credentialData.map { _ in Pipe() }
        process.standardInput = credentialPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            try? credentialPipe?.fileHandleForWriting.close()
            return false
        }

        if let credentialPipe, var privateInput = credentialData {
            let handle = credentialPipe.fileHandleForWriting
            defer {
                privateInput.resetBytes(in: 0..<privateInput.count)
                try? handle.close()
            }
            try? handle.write(contentsOf: privateInput)
        }

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.store(
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            )
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.store(
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            )
            readers.leave()
        }

        guard completion.wait(timeout: .now() + 1.5) == .success else {
            RunningProcessBox.terminateProcessTree(process)
            _ = completion.wait(timeout: .now() + 0.25)
            return false
        }
        guard readers.wait(timeout: .now() + 0.25) == .success else {
            RunningProcessBox.terminateProcessTree(process)
            return false
        }
        let acknowledgement = decodeOutput(stdout.load())
        return process.terminationReason == .exit
            && process.terminationStatus == 0
            && stderr.load().isEmpty
            && acknowledgement
                == "private-mode cleanup complete: exact Gmail draft removed"
            && authority.cleanupTokenWasConsumed()
    }

    private static func isExactConfirmation(_ utterance: String) -> Bool {
        CrossAppActionPolicy.isExplicitConfirmation(utterance)
    }

    nonisolated private static func exactBundledToolURL(
        for tool: BundledAppTool
    ) -> URL? {
        let resolvedToolsURL: URL?
#if APP_ACTION_BROKER_STANDALONE_TEST
        if let testDirectory = ProcessInfo.processInfo.environment[
            "ACE_APP_ACTION_TEST_TOOL_DIRECTORY"
        ], !testDirectory.isEmpty {
            resolvedToolsURL = URL(
                fileURLWithPath: testDirectory,
                isDirectory: true
            ).standardizedFileURL
        } else {
            resolvedToolsURL = Bundle.main.resourceURL?
                .appendingPathComponent("tools", isDirectory: true)
                .standardizedFileURL
        }
#else
        resolvedToolsURL = Bundle.main.resourceURL?
            .appendingPathComponent("tools", isDirectory: true)
            .standardizedFileURL
#endif
        guard let toolsURL = resolvedToolsURL else { return nil }
        let toolURL = toolsURL
            .appendingPathComponent(tool.rawValue, isDirectory: false)
            .standardizedFileURL
        guard toolURL.deletingLastPathComponent() == toolsURL,
              toolsURL.resolvingSymlinksInPath() == toolsURL,
              toolURL.resolvingSymlinksInPath() == toolURL,
              FileManager.default.isExecutableFile(atPath: toolURL.path),
              let toolsValues = try? toolsURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              toolsValues.isDirectory == true,
              toolsValues.isSymbolicLink != true,
              let values = try? toolURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return nil
        }
        return toolURL
    }

    nonisolated private static func capture(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        completionSignal: DispatchSemaphore
    ) async -> CapturedAppActionProcess {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let stdout = AppActionDataBox()
                let stderr = AppActionDataBox()
                let timedOut = AppActionBooleanBox()
                let readers = DispatchGroup()

                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    stdout.store(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderr.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    readers.leave()
                }

                let watchdog = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.store(true)
                    RunningProcessBox.terminateProcessTree(process)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + 45,
                    execute: watchdog
                )
                process.waitUntilExit()
                watchdog.cancel()
                readers.wait()
                completionSignal.signal()
                continuation.resume(
                    returning: CapturedAppActionProcess(
                        exitStatus: process.terminationStatus,
                        reason: process.terminationReason,
                        timedOut: timedOut.load(),
                        standardOutput: Self.decodeOutput(stdout.load()),
                        standardError: Self.decodeOutput(stderr.load())
                    )
                )
            }
        }
    }

    nonisolated private static func decodeOutput(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonemptyDiagnostic(
        stdout: String,
        stderr: String,
        fallback: String
    ) -> String {
        if !stderr.isEmpty { return stderr }
        if !stdout.isEmpty { return stdout }
        return fallback
    }

    /// Every wrapper that reaches the buyer's Google account and therefore
    /// needs the app password on its private stdin pipe.
    fileprivate static let emailTools: Set<BundledAppTool> = [
        .emailDraft, .emailSend,
    ]

    private func blocked(
        _ reason: AppActionBlockReason,
        _ message: String
    ) -> AppActionOutcome {
        .blocked(AppActionBlock(reason: reason, message: message))
    }
}
#endif // circuit-convert

private struct ValidatedAppAction: Equatable {
    let preview: String
    let verifiedOnSuccessfulExit: Bool

    func confirmationPreview(for action: PlannedAppAction) -> String {
        """
        Tool: \(action.tool.rawValue)
        Exact wrapper arguments: \(Self.argumentsJSON(action.arguments))
        \(preview)
        """
    }

    private static func argumentsJSON(_ arguments: [String]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: arguments,
            options: [.withoutEscapingSlashes]
        ),
        let encoded = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return encoded
    }
}

private enum AppActionRules {
    private static let maximumArgumentCount = 64
    private static let maximumTotalCharacters = 220_000

    static func validate(_ action: PlannedAppAction) throws -> ValidatedAppAction {
        guard action.arguments.count <= maximumArgumentCount else {
            throw AppActionValidationError.wrongArguments(
                action.tool,
                "at most \(maximumArgumentCount) arguments"
            )
        }
        let totalCharacters = action.arguments.reduce(0) { partial, value in
            min(maximumTotalCharacters + 1, partial + value.count)
        }
        guard totalCharacters <= maximumTotalCharacters else {
            throw AppActionValidationError.invalidArgument(
                action.tool,
                "content",
                "the complete plan exceeds \(maximumTotalCharacters) characters"
            )
        }
        for (index, argument) in action.arguments.enumerated() {
            if argument.unicodeScalars.contains(where: { $0.value == 0 }) {
                throw AppActionValidationError.invalidArgument(
                    action.tool,
                    "argument \(index + 1)",
                    "NUL characters are not allowed"
                )
            }
            if argument.unicodeScalars.contains(
                where: unsafeInvisibleFormatScalar
            ) {
                throw AppActionValidationError.invalidArgument(
                    action.tool,
                    "argument \(index + 1)",
                    "invisible Unicode format controls are not allowed"
                )
            }
        }

        switch action.tool {
        case .webFetch:
            let opensWebsite = action.arguments.first == "--open"
            if let firstArgument = action.arguments.first,
               firstArgument.hasPrefix("--"),
               !opensWebsite {
                throw invalid(
                    action,
                    "mode",
                    "use exactly --open or omit the mode"
                )
            }
            try requireCount(
                action,
                exactly: opensWebsite ? 2 : 1,
                expected: opensWebsite
                    ? "--open and exactly one URL"
                    : "exactly one URL"
            )
            let value = action.arguments[opensWebsite ? 1 : 0]
            guard value.count <= 2_048,
                  let components = URLComponents(string: value),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil else {
                throw invalid(action, "URL", "use one credential-free http or https URL")
            }
            if opensWebsite {
                return attempted(
                    "Open one website in the default browser.\n"
                        + "URL: \(quoted(value))"
                )
            }
            return verified(
                "Fetch one web page.\nURL: \(quoted(value))"
            )

        case .webSearch:
            let opensTopResult =
                action.arguments.first == "--open-first"
            if let firstArgument = action.arguments.first,
               firstArgument.hasPrefix("--"),
               !opensTopResult {
                throw invalid(
                    action,
                    "mode",
                    "use exactly --open-first or omit the mode"
                )
            }
            let query = try joinedSingleLine(
                action,
                start: opensTopResult ? 1 : 0,
                field: "query",
                maximum: 1_000
            )
            if opensTopResult {
                return attempted(
                    "Search the web and open the top result.\n"
                        + "Query: \(quoted(query))"
                )
            }
            return verified(
                "Search the web.\nQuery: \(quoted(query))"
            )

        case .calendarToday:
            try requireCount(action, exactly: 0, expected: "no arguments")
            return verified("Read today's events from every Calendar calendar.")

        case .calendarAdd:
            try requireCount(
                action,
                exactly: 4,
                expected: "calendar selector, title, local start, and duration"
            )
            try selector(action, index: 0, field: "calendar selector")
            try singleLine(action, index: 1, field: "title", maximum: 240)
            try localDate(action, index: 2, field: "start")
            try integer(
                action,
                index: 3,
                field: "duration",
                range: 1...10_080
            )
            return verified(
                """
                Create one Calendar event.
                Calendar selector: \(quoted(action.arguments[0]))
                Title: \(quoted(action.arguments[1]))
                Local start: \(quoted(action.arguments[2]))
                Duration in minutes: \(quoted(action.arguments[3]))
                """
            )

        case .reminderAdd:
            try requireCount(
                action,
                range: 3...4,
                expected: "account selector, list selector, text, and optional local due time"
            )
            try selector(action, index: 0, field: "account selector")
            try selector(action, index: 1, field: "list selector")
            try singleLine(action, index: 2, field: "reminder text", maximum: 500)
            if action.arguments.count == 4 {
                try localDate(action, index: 3, field: "due time")
            }
            return verified(
                """
                Create one Reminder.
                Account selector: \(quoted(action.arguments[0]))
                List selector: \(quoted(action.arguments[1]))
                Text: \(quoted(action.arguments[2]))
                Local due time: \(action.arguments.count == 4 ? quoted(action.arguments[3]) : "none")
                """
            )

        case .noteCreate:
            try requireCount(
                action,
                exactly: 4,
                expected: "exact account, exact folder, title, and body"
            )
            try singleLine(action, index: 0, field: "account", maximum: 255)
            try singleLine(action, index: 1, field: "folder", maximum: 255)
            try singleLine(action, index: 2, field: "title", maximum: 255)
            try body(action, index: 3, field: "body", maximum: 200_000)
            return verified(
                """
                Create one Apple Note.
                Account: \(quoted(action.arguments[0]))
                Folder: \(quoted(action.arguments[1]))
                Title: \(quoted(action.arguments[2]))
                Body: \(quoted(action.arguments[3]))
                """
            )

        case .screenshotTake:
            // The wrapper's no-argument form chooses a path after confirmation.
            // The broker requires the destination in the preview instead.
            try requireCount(
                action,
                exactly: 1,
                expected: "one explicit absolute new PNG destination"
            )
            try absolutePath(
                action,
                index: 0,
                field: "destination",
                maximum: 2_048
            )
            let pathExtension = (action.arguments[0] as NSString).pathExtension.lowercased()
            guard pathExtension == "png" else {
                throw invalid(action, "destination", "the path must end in .png")
            }
            return verified(
                "Capture the complete screen to one new PNG.\nDestination: \(quoted(action.arguments[0]))"
            )

        case .findFile:
            let query = try joinedSingleLine(
                action,
                start: 0,
                field: "query",
                maximum: 1_000
            )
            return verified("Search local files with Spotlight.\nQuery: \(quoted(query))")

        case .clipboard:
            guard let operation = action.arguments.first else {
                throw wrong(action, "get, or set followed by exact text")
            }
            switch operation {
            case "get":
                try requireCount(action, exactly: 1, expected: "only get")
                return verified("Read the current clipboard text.")
            case "set":
                let content = try joinedContent(
                    action,
                    start: 1,
                    field: "clipboard content",
                    maximum: 100_000
                )
                return verified("Replace the clipboard text.\nContent: \(quoted(content))")
            default:
                throw invalid(action, "operation", "use exactly get or set")
            }

        case .systemInfo:
            try requireCount(action, exactly: 0, expected: "no arguments")
            return verified("Read this Mac's system, battery, disk, memory, Wi-Fi, and uptime information.")

        case .musicControl:
            try enumArgument(
                action,
                allowed: ["play", "pause", "next", "previous", "current"],
                field: "operation"
            )
            return verified("Use Music operation: \(quoted(action.arguments[0])).")

        case .volumeSet:
            try requireCount(action, exactly: 1, expected: "one volume value")
            let value = action.arguments[0]
            if !["mute", "unmute"].contains(value) {
                try integer(action, index: 0, field: "volume", range: 0...100)
            }
            return verified("Set system output volume to: \(quoted(value)).")

        case .blackLabelStatus:
            try requireCount(action, exactly: 0, expected: "no arguments")
            return verified("Read Black Label internal status if this is the founder's Mac.")

        case .weather:
            if action.arguments.isEmpty {
                return verified("Read current weather for the network-derived local location.")
            }
            let location = try joinedSingleLine(
                action,
                start: 0,
                field: "location",
                maximum: 240
            )
            return verified("Read current weather.\nLocation: \(quoted(location))")

        case .timerSet:
            guard let operation = action.arguments.first else {
                throw wrong(action, "list, set, or cancel with its documented fields")
            }
            switch operation {
            case "list":
                try requireCount(action, exactly: 1, expected: "only list")
                return verified("Read the durable timer list.")
            case "cancel":
                try requireCount(
                    action,
                    exactly: 2,
                    expected: "cancel and one exact operation ID"
                )
                try operationID(action, index: 1)
                return verified(
                    "Cancel one durable timer.\nOperation ID: \(quoted(action.arguments[1]))"
                )
            case "set":
                try requireCount(
                    action,
                    range: 3...maximumArgumentCount,
                    expected: "set, operation ID, duration, and optional label"
                )
                try operationID(action, index: 1)
                try timerDuration(action, index: 2)
                let label: String
                if action.arguments.count == 3 {
                    label = "Timer"
                } else {
                    label = try joinedSingleLine(
                        action,
                        start: 3,
                        field: "label",
                        maximum: 160
                    )
                }
                return verified(
                    """
                    Set one durable timer.
                    Operation ID: \(quoted(action.arguments[1]))
                    Duration: \(quoted(action.arguments[2]))
                    Label: \(quoted(label))
                    """
                )
            default:
                throw invalid(
                    action,
                    "operation",
                    "use only documented set, list, or cancel; worker mode is blocked"
                )
            }

        case .contactFind:
            // One argument preserves one exact displayed name; no implicit join.
            try requireCount(action, exactly: 1, expected: "one exact full name")
            try singleLine(action, index: 0, field: "full name", maximum: 255)
            return verified(
                "Read one uniquely matching Contacts card.\nExact full name: \(quoted(action.arguments[0]))"
            )

        case .emailDraft:
            // An explicit sender makes every target visible before confirmation.
            try requireCount(
                action,
                range: 5...maximumArgumentCount,
                expected: "--from, exact sender, exact recipient, subject, and body"
            )
            guard action.arguments[0] == "--from" else {
                throw invalid(
                    action,
                    "sender",
                    "an explicit --from address is required for an exact preview"
                )
            }
            try emailAddress(action, index: 1, field: "sender")
            try emailAddress(action, index: 2, field: "recipient")
            try singleLine(action, index: 3, field: "subject", maximum: 998)
            let bodyValue = try joinedContent(
                action,
                start: 4,
                field: "body",
                maximum: 200_000
            )
            return verified(
                """
                Create one visible Gmail draft. This does not send.
                From: \(quoted(action.arguments[1]))
                To: \(quoted(action.arguments[2]))
                Subject: \(quoted(action.arguments[3]))
                Body: \(quoted(bodyValue))
                """
            )

        case .emailRead:
            let count: String
            let mode: String
            switch action.arguments.count {
            case 0:
                count = "5"
                mode = "all"
            case 1:
                if action.arguments[0] == "unread" {
                    count = "5"
                    mode = "unread"
                } else {
                    try integer(action, index: 0, field: "count", range: 1...20)
                    count = action.arguments[0]
                    mode = "all"
                }
            case 2:
                try integer(action, index: 0, field: "count", range: 1...20)
                guard ["unread", "all"].contains(action.arguments[1]) else {
                    throw invalid(action, "filter", "use exactly unread or all")
                }
                count = action.arguments[0]
                mode = action.arguments[1]
            default:
                throw wrong(action, "optional count followed by optional unread or all")
            }
            return verified(
                """
                Read Apple Mail without changing read status.
                Maximum messages: \(quoted(count))
                Filter: \(quoted(mode))
                """
            )

        case .emailSend:
            try requireCount(action, exactly: 7,
                expected: "reviewed operation ID, exact sender, recipient, subject, and body")
            guard action.arguments[0] == "--send-reviewed",
                  UUID(uuidString: action.arguments[1]) != nil,
                  action.arguments[2] == "--from" else {
                throw invalid(action, "mode", "use one reviewed email operation")
            }
            try emailAddress(action, index: 3, field: "sender")
            try emailAddress(action, index: 4, field: "recipient")
            try singleLine(action, index: 5, field: "subject", maximum: 998)
            try body(action, index: 6, field: "body", maximum: 200_000)
            return attempted(
                """
                Send this email through your connected Gmail account.
                From: \(quoted(action.arguments[3]))
                To: \(quoted(action.arguments[4]))
                Subject: \(quoted(action.arguments[5]))
                Body: \(quoted(action.arguments[6]))
                Gmail acceptance is checked; recipient delivery is a separate result.
                """
            )

        case .messages:
            try requireCount(
                action,
                exactly: 2,
                expected: "one exact resolved recipient handle and body"
            )
            try singleLine(
                action,
                index: 0,
                field: "recipient handle",
                maximum: 512
            )
            try body(
                action,
                index: 1,
                field: "body",
                maximum: 20_000
            )
            return attempted(
                """
                Send one message through the signed-in Messages account.
                Recipient: \(quoted(action.arguments[0]))
                Body: \(quoted(action.arguments[1]))
                Delivery is attempted, not verified.
                """
            )

        case .shortcutRun:
            guard action.arguments == ["list"] else {
                throw AppActionValidationError.forbiddenTool(
                    action.tool,
                    "opaque Shortcut execution cannot be previewed or verified"
                )
            }
            return verified("Read the names of available Shortcuts. No Shortcut will run.")

        case .darkMode:
            try enumArgument(
                action,
                allowed: ["get", "dark", "light", "toggle"],
                field: "operation"
            )
            return verified("Use system appearance operation: \(quoted(action.arguments[0])).")

        case .wifiPower:
            try enumArgument(
                action,
                allowed: ["status", "on", "off"],
                field: "operation"
            )
            return verified("Use Wi-Fi power operation: \(quoted(action.arguments[0])).")

        case .trashFile:
            try requireCount(action, exactly: 1, expected: "one exact absolute file path")
            try absolutePath(
                action,
                index: 0,
                field: "file path",
                maximum: 2_048
            )
            let protected = [
                "/", NSHomeDirectory(), "/Applications", "/Library",
                "/System", "/Users", "/Volumes",
            ]
            guard !protected.contains(action.arguments[0]) else {
                throw invalid(action, "file path", "protected roots cannot be trashed")
            }
            return verified(
                "Move one exact regular file to Trash.\nFile: \(quoted(action.arguments[0]))"
            )

        case .notify:
            let message = try joinedContent(
                action,
                start: 0,
                field: "message",
                maximum: 500
            )
            return attempted(
                "Request one macOS notification from Ace.\nMessage: \(quoted(message))"
            )

        case .appList:
            try requireCount(action, exactly: 0, expected: "no arguments")
            return verified("Read the names of currently open foreground apps.")

        case .wallpaperSet:
            try requireCount(action, exactly: 1, expected: "dark, list, or one absolute image path")
            let target = action.arguments[0]
            if target == "list" {
                return verified("Read available desktop-picture paths.")
            }
            if target == "dark" {
                return attempted("Request a solid black wallpaper on every display.")
            }
            try absolutePath(
                action,
                index: 0,
                field: "image path",
                maximum: 2_048
            )
            let allowedExtensions = ["png", "jpg", "jpeg", "heic"]
            guard allowedExtensions.contains((target as NSString).pathExtension.lowercased()) else {
                throw invalid(
                    action,
                    "image path",
                    "use an absolute .png, .jpg, .jpeg, or .heic path"
                )
            }
            return attempted(
                "Request one wallpaper on every display.\nImage: \(quoted(target))"
            )

        case .windowMove:
            try requireCount(
                action,
                range: 4...5,
                expected: "exact app name, PID, window ID, display, and optional fill"
            )
            try singleLine(action, index: 0, field: "app name", maximum: 255)
            try integer(
                action,
                index: 1,
                field: "process identifier",
                range: 1...Int(Int32.max)
            )
            try integer(
                action,
                index: 2,
                field: "window ID",
                range: 1...Int(UInt32.max)
            )
            guard ["left", "right", "main"].contains(action.arguments[3]) else {
                throw invalid(action, "display", "use exactly left, right, or main")
            }
            if action.arguments.count == 5, action.arguments[4] != "fill" {
                throw invalid(action, "sizing", "use exactly fill or omit it")
            }
            return verified(
                """
                Move one identity-bound window of one already-running app.
                App: \(quoted(action.arguments[0]))
                Process ID: \(quoted(action.arguments[1]))
                Window ID: \(quoted(action.arguments[2]))
                Display: \(quoted(action.arguments[3]))
                Sizing: \(action.arguments.count == 5 ? quoted(action.arguments[4]) : "preserve current size")
                """
            )
        }
    }

    private static func verified(_ preview: String) -> ValidatedAppAction {
        ValidatedAppAction(preview: preview, verifiedOnSuccessfulExit: true)
    }

    /// Bidirectional overrides, isolates, soft hyphens, word joiners, and other
    /// invisible format controls can make an immutable review card display
    /// different text from the wrapper's bytes. ZWNJ/ZWJ remain allowed because
    /// they are required for ordinary scripts and joined emoji.
    private static func unsafeInvisibleFormatScalar(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        guard scalar.properties.generalCategory == .format else {
            return false
        }
        return scalar.value != 0x200C && scalar.value != 0x200D
    }

    private static func attempted(_ preview: String) -> ValidatedAppAction {
        ValidatedAppAction(preview: preview, verifiedOnSuccessfulExit: false)
    }

    private static func requireCount(
        _ action: PlannedAppAction,
        exactly count: Int,
        expected: String
    ) throws {
        guard action.arguments.count == count else { throw wrong(action, expected) }
    }

    private static func requireCount(
        _ action: PlannedAppAction,
        range: ClosedRange<Int>,
        expected: String
    ) throws {
        guard range.contains(action.arguments.count) else { throw wrong(action, expected) }
    }

    private static func wrong(
        _ action: PlannedAppAction,
        _ expected: String
    ) -> AppActionValidationError {
        .wrongArguments(action.tool, expected)
    }

    private static func invalid(
        _ action: PlannedAppAction,
        _ field: String,
        _ reason: String
    ) -> AppActionValidationError {
        .invalidArgument(action.tool, field, reason)
    }

    private static func singleLine(
        _ action: PlannedAppAction,
        index: Int,
        field: String,
        maximum: Int
    ) throws {
        let value = action.arguments[index]
        guard !value.isEmpty,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              !value.isEmpty,
              !value.contains("\n"),
              !value.contains("\r"),
              !value.contains("\t"),
              value.count <= maximum else {
            throw invalid(
                action,
                field,
                "use nonblank, trimmed, single-line text of at most \(maximum) characters"
            )
        }
    }

    private static func body(
        _ action: PlannedAppAction,
        index: Int,
        field: String,
        maximum: Int
    ) throws {
        let value = action.arguments[index]
        guard value.rangeOfCharacter(from: .nonBaseCharacters.inverted) != nil,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximum else {
            throw invalid(action, field, "use nonblank text of at most \(maximum) characters")
        }
    }

    private static func selector(
        _ action: PlannedAppAction,
        index: Int,
        field: String
    ) throws {
        let value = action.arguments[index]
        let prefixes = ["name:", "id:"]
        guard let prefix = prefixes.first(where: { value.hasPrefix($0) }) else {
            throw invalid(action, field, "use an explicit name: or id: selector")
        }
        let payload = String(value.dropFirst(prefix.count))
        guard !payload.isEmpty,
              payload.trimmingCharacters(in: .whitespacesAndNewlines) == payload,
              !payload.contains("\n"),
              !payload.contains("\r"),
              !payload.contains("\t"),
              payload.count <= 512 else {
            throw invalid(action, field, "selector content must be trimmed, single-line, and at most 512 characters")
        }
    }

    private static func localDate(
        _ action: PlannedAppAction,
        index: Int,
        field: String
    ) throws {
        let value = action.arguments[index]
        guard value.range(
            of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$"#,
            options: .regularExpression
        ) != nil else {
            throw invalid(action, field, "use exactly YYYY-MM-DD HH:MM")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        guard let parsed = formatter.date(from: value),
              formatter.string(from: parsed) == value else {
            throw invalid(action, field, "use a real local date and time")
        }
    }

    private static func integer(
        _ action: PlannedAppAction,
        index: Int,
        field: String,
        range: ClosedRange<Int>
    ) throws {
        let value = action.arguments[index]
        guard value.range(of: #"^(?:0|[1-9][0-9]*)$"#, options: .regularExpression) != nil,
              let parsed = Int(value),
              range.contains(parsed) else {
            throw invalid(action, field, "use a whole number from \(range.lowerBound) through \(range.upperBound)")
        }
    }

    private static func enumArgument(
        _ action: PlannedAppAction,
        allowed: Set<String>,
        field: String
    ) throws {
        try requireCount(action, exactly: 1, expected: "one documented operation")
        guard allowed.contains(action.arguments[0]) else {
            throw invalid(action, field, "use one of: \(allowed.sorted().joined(separator: ", "))")
        }
    }

    private static func absolutePath(
        _ action: PlannedAppAction,
        index: Int,
        field: String,
        maximum: Int
    ) throws {
        let path = action.arguments[index]
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"),
              path != "/",
              !path.hasSuffix("/"),
              path.count <= maximum,
              !components.contains(where: { $0 == "." || $0 == ".." }),
              !path.contains("//"),
              !path.contains("\n"),
              !path.contains("\r"),
              !path.contains("\t") else {
            throw invalid(action, field, "use one normalized absolute path")
        }
    }

    private static func emailAddress(
        _ action: PlannedAppAction,
        index: Int,
        field: String
    ) throws {
        let value = action.arguments[index]
        let matches = value.range(
            of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+$"#,
            options: .regularExpression
        ) != nil
        guard matches,
              !value.hasPrefix("."),
              !value.contains(".."),
              !value.contains(".@"),
              value.count <= 320 else {
            throw invalid(action, field, "use one exact email address")
        }
    }

    private static func operationID(
        _ action: PlannedAppAction,
        index: Int
    ) throws {
        guard action.arguments[index].range(
            of: #"^[A-Za-z0-9-]{16,64}$"#,
            options: .regularExpression
        ) != nil else {
            throw invalid(
                action,
                "operation ID",
                "use 16–64 letters, digits, or hyphens"
            )
        }
    }

    private static func timerDuration(
        _ action: PlannedAppAction,
        index: Int
    ) throws {
        let value = action.arguments[index]
        guard let match = value.range(
            of: #"^([1-9][0-9]{0,6})([smh])$"#,
            options: .regularExpression
        ) else {
            throw invalid(action, "duration", "use a positive integer and exact lowercase s, m, or h")
        }
        let matched = String(value[match])
        let unit = matched.last!
        let magnitude = Int(matched.dropLast())!
        let multiplier: Int
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        default: multiplier = 3_600
        }
        guard magnitude <= 2_592_000 / multiplier else {
            throw invalid(action, "duration", "the duration must not exceed 30 days")
        }
    }

    private static func joinedSingleLine(
        _ action: PlannedAppAction,
        start: Int,
        field: String,
        maximum: Int
    ) throws -> String {
        guard action.arguments.count > start else {
            throw wrong(action, "nonblank \(field)")
        }
        for index in start..<action.arguments.count {
            try singleLine(
                action,
                index: index,
                field: field,
                maximum: maximum
            )
        }
        let value = action.arguments[start...].joined(separator: " ")
        guard value.count <= maximum else {
            throw invalid(action, field, "use at most \(maximum) characters")
        }
        return value
    }

    private static func joinedContent(
        _ action: PlannedAppAction,
        start: Int,
        field: String,
        maximum: Int
    ) throws -> String {
        guard action.arguments.count > start else {
            throw wrong(action, "nonblank \(field)")
        }
        let value = action.arguments[start...].joined(separator: " ")
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximum else {
            throw invalid(action, field, "use nonblank content of at most \(maximum) characters")
        }
        return value
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: [value],
            options: [.withoutEscapingSlashes]
        ),
        let encoded = String(data: data, encoding: .utf8),
        encoded.count >= 2 else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }
}

/// Event-tap-safe cutoff for every broker wrapper. Process publication and
/// spawn happen under StealthEntryLatch; X then freezes parent-before-child
/// and kills leaf-first using bounded libproc discovery. No helper process,
/// pipe read, filesystem operation, or wait occurs on the keyboard callback.
nonisolated private final class AppActionWrapperProcessCutoff:
    @unchecked Sendable
{
    private static let maximumProcessCount = 128

    private let lock = NSLock()
    private var process: Process?
    private var generation: UInt64?
    private var cancelledGenerations: Set<UInt64> = []

    @discardableResult
    func register(
        _ process: Process,
        generation: UInt64
    ) -> Bool {
        lock.withLock {
            guard !cancelledGenerations.contains(generation) else {
                return false
            }
            self.process = process
            self.generation = generation
            return true
        }
    }

    func cancelSynchronously(generation: UInt64) {
        let processToTerminate = lock.withLock { () -> Process? in
            cancelledGenerations.insert(generation)
            guard self.generation == generation else {
                return nil
            }
            return process
        }
        guard let processToTerminate,
              processToTerminate.isRunning else {
            return
        }
        Self.freezeAndKillProcessTree(
            root: processToTerminate.processIdentifier
        )
    }

    func clear(generation: UInt64) {
        lock.withLock {
            cancelledGenerations.remove(generation)
            if self.generation == generation {
                process = nil
                self.generation = nil
            }
        }
    }

    private static func freezeAndKillProcessTree(root: pid_t) {
        guard root > 1 else { return }
        _ = Darwin.kill(root, SIGSTOP)

        var frozenProcessIdentifiers: [pid_t] = [root]
        var inspectionIndex = 0
        while inspectionIndex < frozenProcessIdentifiers.count,
              frozenProcessIdentifiers.count < maximumProcessCount {
            let parent = frozenProcessIdentifiers[inspectionIndex]
            inspectionIndex += 1
            let remainingCapacity =
                maximumProcessCount
                - frozenProcessIdentifiers.count
            var children = [pid_t](
                repeating: 0,
                count: remainingCapacity
            )
            let discoveredCount =
                children.withUnsafeMutableBytes { buffer in
                    proc_listchildpids(
                        parent,
                        buffer.baseAddress,
                        Int32(buffer.count)
                    )
                }
            guard discoveredCount > 0 else { continue }
            let boundedDiscoveredCount = min(
                Int(discoveredCount),
                remainingCapacity
            )
            for child in children.prefix(
                boundedDiscoveredCount
            ) where child > 1 {
                _ = Darwin.kill(child, SIGSTOP)
                frozenProcessIdentifiers.append(child)
            }
        }
        for processIdentifier in frozenProcessIdentifiers.reversed() {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}

/// One-use, exact-message authority for the only compensating operation Ace
/// permits after X: deleting the already-created Apple Mail draft. The model,
/// preview, original wrapper arguments, and every other tool never receive
/// cleanup approval.
nonisolated private final class EmailDraftCleanupAuthority:
    @unchecked Sendable
{
    static let tokenSchema =
        "ACE-MAIL-DRAFT-CLEANUP-AUTHORITY-V1"
    static let stateSchema = "ACE-MAIL-DRAFT-STATE-V1"

    let operationID: String
    let identitySHA256: String

    private let tokenURL: URL
    private let stateURL: URL
    private let consumedURL: URL
    private let supportDirectoryURL: URL
    private let approvalDirectoryURL: URL

    private init(
        operationID: String,
        identitySHA256: String,
        tokenURL: URL,
        stateURL: URL,
        consumedURL: URL,
        supportDirectoryURL: URL,
        approvalDirectoryURL: URL
    ) {
        self.operationID = operationID
        self.identitySHA256 = identitySHA256
        self.tokenURL = tokenURL
        self.stateURL = stateURL
        self.consumedURL = consumedURL
        self.supportDirectoryURL = supportDirectoryURL
        self.approvalDirectoryURL = approvalDirectoryURL
    }

    static func issue(
        for action: PlannedAppAction
    ) throws -> EmailDraftCleanupAuthority {
        guard action.tool == .emailDraft,
              action.arguments.count >= 5,
              action.arguments[0] == "--from",
              let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
              ).first else {
            throw AuthorityError.invalidAction
        }
        let supportURL = applicationSupportURL
            .appendingPathComponent("BlackLabel", isDirectory: true)
        let approvalURL = supportURL
            .appendingPathComponent(
                "action-approvals",
                isDirectory: true
            )
        try secureDirectory(supportURL)
        try secureDirectory(approvalURL)

        let operationID = UUID().uuidString.lowercased()
        let fields = [
            action.arguments[1],
            action.arguments[2],
            action.arguments[3],
            action.arguments[4...].joined(separator: " "),
        ]
        let identitySHA256 = hash(fields: fields)
        let tokenURL = approvalURL.appendingPathComponent(
            "mail-draft-cleanup-\(operationID)",
            isDirectory: false
        )
        let stateURL = approvalURL.appendingPathComponent(
            "mail-draft-state-\(operationID)",
            isDirectory: false
        )
        let consumedURL = URL(
            fileURLWithPath: tokenURL.path + ".consumed",
            isDirectory: true
        )
        let marker = "__ACE_MAIL_DRAFT_PENDING__\(operationID)"
        let token = Data(
            """
            \(tokenSchema)
            \(operationID)
            \(identitySHA256)

            """.utf8
        )
        let state = Data(
            """
            \(stateSchema)
            \(operationID)
            \(identitySHA256)
            MARKER
            \(marker)

            """.utf8
        )
        do {
            try writeExclusive(token, to: tokenURL)
            try writeExclusive(state, to: stateURL)
        } catch {
            try? FileManager.default.removeItem(at: tokenURL)
            try? FileManager.default.removeItem(at: stateURL)
            throw error
        }
        return EmailDraftCleanupAuthority(
            operationID: operationID,
            identitySHA256: identitySHA256,
            tokenURL: tokenURL,
            stateURL: stateURL,
            consumedURL: consumedURL,
            supportDirectoryURL: supportURL,
            approvalDirectoryURL: approvalURL
        )
    }

    func addOriginalWrapperEnvironment(
        to environment: inout [String: String]
    ) {
        environment["ACE_MAIL_DRAFT_OPERATION_ID"] = operationID
        environment["ACE_MAIL_DRAFT_STATE_PATH"] = stateURL.path
        environment["ACE_MAIL_DRAFT_CLEANUP_TOKEN_PATH"] =
            tokenURL.path
        environment["ACE_MAIL_DRAFT_IDENTITY_SHA256"] =
            identitySHA256
    }

    func cleanupWrapperEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("ACE_") {
            environment.removeValue(forKey: key)
        }
        environment["ACE_MAIL_DRAFT_CLEANUP_APPROVED"] = "1"
        addOriginalWrapperEnvironment(to: &environment)
        environment["ACE_EFFECT_GUARD_SUPPORT_DIRECTORY"] =
            supportDirectoryURL.path
        environment["ACE_STEALTH_ENTRY_REQUEST"] =
            supportDirectoryURL.appendingPathComponent(
                "stealth-entry-request-v1",
                isDirectory: false
            ).path
        environment["ACE_STEALTH_INTENT"] =
            supportDirectoryURL.appendingPathComponent(
                "stealth-intent-v1",
                isDirectory: false
            ).path
        environment["ACE_STEALTH_MARKER"] =
            supportDirectoryURL.appendingPathComponent(
                "stealth-active",
                isDirectory: false
            ).path
        return environment
    }

    func filesRemainSafeForCleanup() -> Bool {
        Self.secureDirectoryIsSafe(supportDirectoryURL)
            && Self.secureDirectoryIsSafe(approvalDirectoryURL)
            && Self.privateFileIsSafe(tokenURL)
            && Self.privateFileIsSafe(stateURL)
            && !FileManager.default.fileExists(atPath: consumedURL.path)
    }

    func cleanupTokenWasConsumed() -> Bool {
        guard let values = try? consumedURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: consumedURL.path
        ),
        let ownerID = attributes[.ownerAccountID] as? NSNumber else {
            return false
        }
        return ownerID.uint32Value == getuid()
    }

    func destroy() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: tokenURL)
        try? fileManager.removeItem(at: stateURL)
        try? fileManager.removeItem(at: consumedURL)
    }

    private static func hash(fields: [String]) -> String {
        var canonical = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            canonical.append(Data(String(bytes.count).utf8))
            canonical.append(0x3a)
            canonical.append(bytes)
            canonical.append(0x0a)
        }
        return SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func secureDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard secureDirectoryIsSafe(url) else {
            throw AuthorityError.unsafeDirectory
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private static func secureDirectoryIsSafe(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
        let ownerID = attributes[.ownerAccountID] as? NSNumber,
        let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return ownerID.uint32Value == getuid()
            && permissions.intValue & 0o777 == 0o700
    }

    private static func privateFileIsSafe(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
        let ownerID = attributes[.ownerAccountID] as? NSNumber,
        let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return ownerID.uint32Value == getuid()
            && permissions.intValue & 0o777 == 0o600
    }

    private static func writeExclusive(
        _ data: Data,
        to url: URL
    ) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw AuthorityError.fileCreationFailed
        }
        var completed = false
        defer {
            Darwin.close(descriptor)
            if !completed {
                Darwin.unlink(url.path)
            }
        }
        let wroteAll = data.withUnsafeBytes {
            bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else {
                return data.isEmpty
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        guard wroteAll, Darwin.fsync(descriptor) == 0 else {
            throw AuthorityError.fileCreationFailed
        }
        completed = true
    }

    private enum AuthorityError: Error {
        case invalidAction
        case unsafeDirectory
        case fileCreationFailed
    }
}

nonisolated private final class AppActionDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return snapshot
    }
}

nonisolated private final class AppActionBooleanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func store(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Bool {
        lock.lock()
        let snapshot = value
        lock.unlock()
        return snapshot
    }
}

private struct CapturedAppActionProcess {
    let exitStatus: Int32
    let reason: Process.TerminationReason
    let timedOut: Bool
    let standardOutput: String
    let standardError: String
}

/// Module-internal one-use effect authority issued after an owner turn reaches
/// an app-owned executor. Model and plan values never receive the token path.
final class OwnerTurnEffectAuthority {
    private let tokenURL: URL
    private let consumedURL: URL
    private let supportDirectoryURL: URL

    private init(
        tokenURL: URL,
        consumedURL: URL,
        supportDirectoryURL: URL
    ) {
        self.tokenURL = tokenURL
        self.consumedURL = consumedURL
        self.supportDirectoryURL = supportDirectoryURL
    }

    static func issue() throws -> OwnerTurnEffectAuthority {
        let fileManager = FileManager.default
        let resolvedSupportURL: URL?
#if APP_ACTION_BROKER_STANDALONE_TEST
        if let testDirectory = ProcessInfo.processInfo.environment[
            "ACE_APP_ACTION_TEST_SUPPORT_DIRECTORY"
        ], !testDirectory.isEmpty {
            resolvedSupportURL = URL(
                fileURLWithPath: testDirectory,
                isDirectory: true
            ).standardizedFileURL
        } else {
            resolvedSupportURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent(
                "BlackLabel",
                isDirectory: true
            )
        }
#else
        resolvedSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("BlackLabel", isDirectory: true)
#endif
        guard let supportURL = resolvedSupportURL else {
            throw ApprovalError.applicationSupportUnavailable
        }
        let approvalDirectoryURL = supportURL
            .appendingPathComponent("action-approvals", isDirectory: true)
        try secureDirectory(supportURL, fileManager: fileManager)
        try secureDirectory(approvalDirectoryURL, fileManager: fileManager)

        let identifier = UUID().uuidString
        let tokenURL = approvalDirectoryURL
            .appendingPathComponent("token-\(identifier)", isDirectory: false)
        let consumedURL = URL(fileURLWithPath: tokenURL.path + ".consumed")
        try writeExclusive(
            Data("\(identifier)\n".utf8),
            to: tokenURL
        )
        return OwnerTurnEffectAuthority(
            tokenURL: tokenURL,
            consumedURL: consumedURL,
            supportDirectoryURL: supportURL
        )
    }

    func wrapperEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("ACE_") {
            environment.removeValue(forKey: key)
        }
#if APP_ACTION_BROKER_STANDALONE_TEST
        for key in [
            "ACE_OSASCRIPT_BIN",
            "ACE_MESSAGES_TEST_COUNTER_PATH",
        ] {
            if let value = ProcessInfo.processInfo.environment[key] {
                environment[key] = value
            }
        }
#endif
        environment["ACE_APP_MUTATION_APPROVED"] = "1"
        environment["ACE_APP_MUTATION_TOKEN_PATH"] = tokenURL.path
        environment["ACE_EFFECT_GUARD_SUPPORT_DIRECTORY"] = supportDirectoryURL.path
        environment["ACE_STEALTH_MARKER"] = supportDirectoryURL
            .appendingPathComponent("stealth-active", isDirectory: false).path
        environment["ACE_STEALTH_INTENT"] = supportDirectoryURL
            .appendingPathComponent(
                "stealth-intent-v1",
                isDirectory: false
            ).path
        return environment
    }

    fileprivate func issueMessagesRequest(
        for action: PlannedAppAction
    ) throws -> MessagesRequestMaterial {
        try MessagesRequestMaterial.issue(for: action)
    }

    func destroy() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: tokenURL)
        try? fileManager.removeItem(at: consumedURL)
    }

    private static func secureDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ApprovalError.unsafeDirectory
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw ApprovalError.tokenCreationFailed }
        var completed = false
        defer {
            Darwin.close(descriptor)
            if !completed {
                Darwin.unlink(url.path)
            }
        }

        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        guard wroteAll, Darwin.fsync(descriptor) == 0 else {
            throw ApprovalError.tokenCreationFailed
        }
        completed = true
    }

    private enum ApprovalError: Error {
        case applicationSupportUnavailable
        case unsafeDirectory
        case tokenCreationFailed
    }
}

/// One private value handed to one wrapper over one pipe, then zeroed.
/// Implementations never let the value reach argv, defaults, receipts or logs.
fileprivate protocol PrivateWrapperInput: AnyObject {
    /// The arguments the wrapper should run with. Messages replaces its planned
    /// arguments entirely; the email wrappers keep theirs and receive only the
    /// credential on the pipe.
    func wrapperArguments(replacing planned: [String]) -> [String]
    func consumeData() throws -> Data
    func destroy()
}

/// Exists only between exact direct-human confirmation and one wrapper exit.
/// The provider values never enter argv, defaults, receipts, or log output.
fileprivate final class MessagesRequestMaterial: PrivateWrapperInput {
    private var requestData: Data?

    fileprivate func wrapperArguments(replacing planned: [String]) -> [String] {
        ["--request-stdin"]
    }

    private init(requestData: Data) {
        self.requestData = requestData
    }

    fileprivate static func issue(
        for action: PlannedAppAction
    ) throws -> MessagesRequestMaterial {
        guard action.tool == .messages, action.arguments.count == 2 else {
            throw MaterialError.invalidAction
        }
        let payload: [String: String] = [
            "schema": "ACE-MESSAGES-REQUEST-V1",
            "handle": action.arguments[0],
            "body": action.arguments[1],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ) else {
            throw MaterialError.encodingFailed
        }
        return MessagesRequestMaterial(requestData: data)
    }

    fileprivate func consumeData() throws -> Data {
        guard let requestData else {
            throw MaterialError.requestAlreadyConsumed
        }
        self.requestData = nil
        return requestData
    }

    fileprivate func destroy() {
        if let byteCount = requestData?.count {
            requestData?.resetBytes(in: 0..<byteCount)
            requestData = nil
        }
    }

    deinit {
        destroy()
    }

    private enum MaterialError: Error {
        case invalidAction
        case encodingFailed
        case requestAlreadyConsumed
    }
}

/// The buyer's Gmail app password on its way to one email wrapper.
///
/// Ace replaced Apple Mail automation with the buyer's own Google account, so
/// every email wrapper needs the credential. It travels the same private pipe
/// the Messages recipient uses: never argv (which `ps` exposes to every process
/// on the Mac), never an environment variable, never a file, never a receipt.
///
/// The wrapper's own arguments are untouched, so the draft identity digest and
/// the approval preview the buyer confirmed still describe the exact message.
fileprivate final class GmailRequestMaterial: PrivateWrapperInput {
    static let schema = "ACE-GMAIL-REQUEST-V1"

    private var requestData: Data?

    private init(requestData: Data) {
        self.requestData = requestData
    }

    fileprivate func wrapperArguments(replacing planned: [String]) -> [String] {
        planned
    }

    /// Six newline-separated lines the wrappers read with `read -r`. Only the
    /// credential is carried here; recipient, subject and body stay in the
    /// approved arguments, so nothing the buyer confirmed can be swapped after
    /// confirmation.
    fileprivate static func issue(
        credential: GmailAccountCredential
    ) throws -> GmailRequestMaterial {
        guard !credential.address.isEmpty,
              !credential.transportSecret.isEmpty,
              !credential.transportSecret.contains(where: { $0.isWhitespace }),
              !credential.address.contains(where: { $0.isNewline }) else {
            throw MaterialError.invalidCredential
        }
        let lines = [
            credential.transportSchema,
            credential.transportSecret,
            credential.address,
            "",
            "",
            "",
        ]
        return GmailRequestMaterial(
            requestData: Data(lines.joined(separator: "\n").utf8)
        )
    }

    fileprivate func consumeData() throws -> Data {
        guard let requestData else {
            throw MaterialError.requestAlreadyConsumed
        }
        self.requestData = nil
        return requestData
    }

    fileprivate func destroy() {
        if let byteCount = requestData?.count {
            requestData?.resetBytes(in: 0..<byteCount)
            requestData = nil
        }
    }

    deinit {
        destroy()
    }

    private enum MaterialError: Error {
        case invalidCredential
        case requestAlreadyConsumed
    }
}
