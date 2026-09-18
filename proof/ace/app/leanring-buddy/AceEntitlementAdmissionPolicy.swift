//
//  AceEntitlementAdmissionPolicy.swift
//  Ace
//
//  One pure, exhaustive admission decision for every product and recovery
//  surface. UI and runtimes consume this policy; they do not reinterpret a
//  stored key, onboarding bit, cached permission, or prior approval as access.
//

import Foundation

/// The activation server's current authority for this process.
enum AceLicenseState: Equatable {
    case unknown
    case licensed(until: Date)
    case needsKey
    case requiresOnlineVerification(message: String)
    case refused(message: String)
}

/// Every route that can either exercise Ace or help the owner recover/leave.
/// Adding a new surface is a compile-visible decision: it must be classified in
/// `kind`, and the exhaustive regression keeps premium and recovery paths apart.
enum AceEntitlementSurface: CaseIterable, Equatable, Sendable {
    case premiumRuntimeStartup
    case normalVoice
    case partnerMode
    case meetingNotes
    case workflow
    case appAction
    case companyDispatch
    case approval
    case dashboardTool
    case backgroundAgent
    case standingTask
    case backgroundResume
    case trading
    case screenObservation
    case onboarding
    case productPanelControl
    case permissionRepair
    case providerConnection
    case privateModeEntry

    case activation
    case account
    case subscriptionCancellation
    case support
    case stop
    case mute
    case endSession
    case cancelPendingWork
    case privateModeExit
    case dismiss
    case quit

    fileprivate enum Kind {
        case premium
        case recovery
    }

    fileprivate var kind: Kind {
        switch self {
        case .premiumRuntimeStartup,
             .normalVoice,
             .partnerMode,
             .meetingNotes,
             .workflow,
             .appAction,
             .companyDispatch,
             .approval,
             .dashboardTool,
             .backgroundAgent,
             .standingTask,
             .backgroundResume,
             .trading,
             .screenObservation,
             .onboarding,
             .productPanelControl,
             .permissionRepair,
             .providerConnection,
             .privateModeEntry:
            return .premium
        case .activation,
             .account,
             .subscriptionCancellation,
             .support,
             .stop,
             .mute,
             .endSession,
             .cancelPendingWork,
             .privateModeExit,
             .dismiss,
             .quit:
            return .recovery
        }
    }
}

enum AceEntitlementRuntimeTransition: Equatable, Sendable {
    case none
    case quiescePremiumRuntime
    case openNewPremiumAdmission
}

/// A deliberately exact recovery grammar evaluated before the premium voice
/// gate. It never routes ordinary product requests while unlicensed; it only
/// lets the owner stop already-running work, leave, or reach account recovery.
enum AceUnlicensedRecoveryVoiceAction: Equatable, Sendable {
    case stopAll
    case mute
    case endSession
    case discardMeetingNotes
    case cancelWorkflow
    case privateModeExit
    case activation
    case account
    case subscriptionCancellation
    case support
    case quit
}

enum AceUnlicensedRecoveryVoicePolicy {
    static func action(
        for transcript: String
    ) -> AceUnlicensedRecoveryVoiceAction? {
        let normalized = normalize(transcript)
        switch normalized {
        case "stop", "stop everything", "stop all work",
             "cancel", "cancel everything", "cancel all work":
            return .stopAll
        case "mute", "mute ace", "mute yourself", "quiet", "be quiet",
             "shut up":
            return .mute
        case "end session", "end partner mode", "stop partner mode":
            return .endSession
        case "discard notes", "discard meeting notes", "stop notes",
             "stop meeting notes":
            return .discardMeetingNotes
        case "abort workflow", "cancel workflow", "stop workflow",
             "abort build", "cancel build", "stop build":
            return .cancelWorkflow
        case "exit private mode", "leave private mode",
             "turn off private mode":
            return .privateModeExit
        case "unlock", "unlock ace", "activate ace", "enter key",
             "enter license key":
            return .activation
        case "account", "open account", "open my account":
            return .account
        case "cancel subscription", "manage subscription":
            return .subscriptionCancellation
        case "support", "contact support", "get support", "email support":
            return .support
        case "quit", "quit ace", "exit ace":
            return .quit
        default:
            return nil
        }
    }

    private static func normalize(_ transcript: String) -> String {
        var words = transcript
            .lowercased()
            .components(
                separatedBy: CharacterSet.alphanumerics.inverted
            )
            .filter { !$0.isEmpty }
        if words.first == "hey", words.dropFirst().first == "ace" {
            words.removeFirst(2)
        } else if words.first == "ace" {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }
}

enum AceEntitlementPanelRecoveryAction: Equatable, Sendable {
    case activation
    case account
    case subscriptionCancellation
    case support
    case dismiss
    case quit
}

enum AceEntitlementPanelPresentation: Equatable, Sendable {
    case premium
    case locked(
        message: String,
        actions: [AceEntitlementPanelRecoveryAction]
    )
}

enum AceEntitlementPanelPolicy {
    static func presentation(
        state: AceLicenseState,
        now: Date = Date()
    ) -> AceEntitlementPanelPresentation {
        guard !AceEntitlementAdmissionPolicy.hasCurrentEntitlement(
            state: state,
            now: now
        ) else {
            return .premium
        }
        let message: String
        switch state {
        case .refused(let refusal),
             .requiresOnlineVerification(let refusal):
            message = refusal
        case .unknown:
            message = "Ace is checking this Mac's account access."
        case .needsKey:
            message = "Enter the key from your account page to unlock Ace."
        case .licensed:
            message = "Ace needs to verify this Mac's account access again."
        }
        return .locked(
            message: message,
            actions: [
                .activation,
                .account,
                .subscriptionCancellation,
                .support,
                .dismiss,
                .quit,
            ]
        )
    }
}

enum AceEntitlementAdmissionPolicy {
    static func admitsDuringNativeUpdate(_ surface: AceEntitlementSurface) -> Bool {
        switch surface {
        case .activation, .account, .subscriptionCancellation, .support,
             .stop, .mute, .endSession, .cancelPendingWork,
             .privateModeEntry, .privateModeExit, .dismiss, .quit:
            return true
        case .premiumRuntimeStartup, .normalVoice, .partnerMode, .meetingNotes,
             .workflow, .appAction, .companyDispatch, .approval, .dashboardTool,
             .backgroundAgent, .standingTask, .backgroundResume, .trading,
             .screenObservation, .onboarding, .productPanelControl,
             .permissionRepair, .providerConnection:
            return false
        }
    }

    static func hasCurrentEntitlement(
        state: AceLicenseState,
        now: Date = Date()
    ) -> Bool {
        guard case .licensed(let until) = state else {
            return false
        }
        return until > now
    }

    static func admits(
        _ surface: AceEntitlementSurface,
        state: AceLicenseState,
        now: Date = Date()
    ) -> Bool {
        switch surface.kind {
        case .premium:
            return hasCurrentEntitlement(state: state, now: now)
        case .recovery:
            return true
        }
    }

    /// Losing admission kills/suspends premium work. Regaining admission opens
    /// only NEW work; this result never asks a runtime to resurrect killed work.
    static func runtimeTransition(
        from previous: AceLicenseState,
        to current: AceLicenseState,
        now: Date = Date()
    ) -> AceEntitlementRuntimeTransition {
        let wasOpen = hasCurrentEntitlement(
            state: previous,
            now: now
        )
        let isOpen = hasCurrentEntitlement(
            state: current,
            now: now
        )
        switch (wasOpen, isOpen) {
        case (true, false):
            return .quiescePremiumRuntime
        case (false, true):
            return .openNewPremiumAdmission
        case (false, false), (true, true):
            return .none
        }
    }
}

/// Lock-protected projection of `AceLicense.state` for non-MainActor process
/// boundaries such as the loopback dashboard host. It carries no independent
/// entitlement logic; every read delegates back to the pure central policy.
nonisolated final class AceEntitlementRuntimeAdmissionGate:
    @unchecked Sendable
{
    static let shared = AceEntitlementRuntimeAdmissionGate()

    private let lock = NSLock()
    private var state: AceLicenseState

    init(initialState: AceLicenseState = .unknown) {
        state = initialState
    }

    func publish(_ newState: AceLicenseState) {
        lock.withLock {
            state = newState
        }
    }

    func admits(
        _ surface: AceEntitlementSurface,
        now: Date = Date()
    ) -> Bool {
        let snapshot = lock.withLock { state }
        return AceEntitlementAdmissionPolicy.admits(
            surface,
            state: snapshot,
            now: now
        )
    }
}
