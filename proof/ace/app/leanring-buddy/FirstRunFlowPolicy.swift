import Foundation

nonisolated enum AceFirstRunPhase: Equatable, Sendable {
    case provider
    case corePermissions
    case liveCommandShiftProof
    case complete
}

nonisolated struct AceFirstRunEvidence: Equatable, Sendable {
    var providerAnsweredLive: Bool
    var corePermissionsReady: Bool
    var liveScreenAnswerSucceeded: Bool
    var shortcutPressObserved: Bool
    var transcriptObserved: Bool
    var shortcutReleaseObserved: Bool
}

/// First-run authority. Start uses the provider/core readiness boundary; the
/// optional tour can still grade its own richer live interaction exercise
/// without withholding an otherwise ready product from the owner.
nonisolated enum FirstRunFlowPolicy {
    /// The Start button activates the product after the setup screen has
    /// already proved the selected provider and the core Mac permissions.
    /// The live screen demo, narrated tour, and owner rehearsal are useful
    /// optional exercises; none of them may turn Start into a second setup
    /// gate or leave the owner trapped behind an overlay.
    static func mayActivateFromStart(
        isRunningFromCanonicalInstall: Bool,
        providerAnsweredLive: Bool,
        corePermissionsReady: Bool
    ) -> Bool {
        isRunningFromCanonicalInstall
            && providerAnsweredLive
            && corePermissionsReady
    }

    static func phase(
        for evidence: AceFirstRunEvidence,
        setupWasPreviouslyCompleted: Bool = false,
        tourWasViewed _: Bool = false,
        optionalAutomationReady _: Bool = false
    ) -> AceFirstRunPhase {
        if setupWasPreviouslyCompleted {
            return .complete
        }
        guard evidence.providerAnsweredLive else {
            return .provider
        }
        guard evidence.corePermissionsReady else {
            return .corePermissions
        }
        guard evidence.liveScreenAnswerSucceeded,
              evidence.shortcutPressObserved,
              evidence.transcriptObserved,
              evidence.shortcutReleaseObserved else {
            return .liveCommandShiftProof
        }
        return .complete
    }

    static func prerequisitesAreReady(
        providerAnsweredLive: Bool,
        corePermissionsReady: Bool
    ) -> Bool {
        phase(
            for: AceFirstRunEvidence(
                providerAnsweredLive: providerAnsweredLive,
                corePermissionsReady: corePermissionsReady,
                liveScreenAnswerSucceeded: false,
                shortcutPressObserved: false,
                transcriptObserved: false,
                shortcutReleaseObserved: false
            )
        ) == .liveCommandShiftProof
    }
}
