import Foundation

enum FirstRunLaunchAction: Equatable, Sendable {
    case presentTour
    case exposeFinishSetup
    case exposeRepair
    case normal
}

enum FirstRunTourRequest: Equatable, Sendable {
    case automatic
    case explicitReplay

    /// Only the unfinished first-run flow may collect the onboarding hotkey
    /// proof. An owner deliberately replaying the product tour has already
    /// completed setup, so replay must remain a demonstration rather than
    /// reopening setup or publishing a setup-failed timeout.
    var requiresOwnerRehearsal: Bool {
        self == .automatic
    }
}

enum FirstRunTourAdmission: Equatable, Sendable {
    case acquired
    case alreadyViewed
    case alreadyActive
}

/// Keeps the one-time product tour independent from setup readiness. The
/// persisted viewed bit survives crashes and relaunches; the in-process lease
/// prevents two presentation paths from stacking windows or tour tasks.
@MainActor
final class FirstRunExperienceState {
    static let shared = FirstRunExperienceState()

    private static let viewedTourDefaultsKey =
        "hasViewedFirstRunTour"

    private let defaults: UserDefaults
    private var tourPresentationIsActive = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasViewedFirstRunTour: Bool {
        defaults.bool(forKey: Self.viewedTourDefaultsKey)
    }

    func launchAction(
        setupCompleted: Bool,
        currentSetupProofsReady: Bool
    ) -> FirstRunLaunchAction {
        if !hasViewedFirstRunTour {
            return .presentTour
        }
        if !setupCompleted {
            return .exposeFinishSetup
        }
        if !currentSetupProofsReady {
            return .exposeRepair
        }
        return .normal
    }

    func launchAction(
        setupCompleted: Bool,
        evidence: AceFirstRunEvidence
    ) -> FirstRunLaunchAction {
        if !hasViewedFirstRunTour, !setupCompleted {
            return .presentTour
        }
        if !setupCompleted {
            return .exposeFinishSetup
        }
        return FirstRunFlowPolicy.phase(
            for: evidence
        ) == .complete ? .normal : .exposeRepair
    }

    /// Returns true only for the caller that owns the presentation. The viewed
    /// bit is written before presentation work begins so a quit or crash cannot
    /// turn the next launch into another automatic tour.
    func beginTourPresentation(
        request: FirstRunTourRequest
    ) -> FirstRunTourAdmission {
        guard !tourPresentationIsActive else { return .alreadyActive }
        if request == .automatic, hasViewedFirstRunTour {
            return .alreadyViewed
        }
        tourPresentationIsActive = true
        defaults.set(true, forKey: Self.viewedTourDefaultsKey)
        return .acquired
    }

    func endTourPresentation() {
        tourPresentationIsActive = false
    }
}
