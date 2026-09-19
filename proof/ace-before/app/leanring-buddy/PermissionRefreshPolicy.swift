import Foundation

enum PermissionRefreshMode: Equatable, Sendable {
    case stopped
    case pending(interval: TimeInterval)
    case stable
}

enum PermissionRefreshPolicy {
    static func mode(
        runtimeIsActive: Bool,
        explicitPromptIsPending: Bool
    ) -> PermissionRefreshMode {
        guard runtimeIsActive else { return .stopped }
        if explicitPromptIsPending {
            return .pending(interval: 1.5)
        }
        return .stable
    }
}

enum TourSpeechAdvancePolicy {
    static func shouldAdvance(
        exactLineCompleted: Bool,
        taskIsCancelled: Bool
    ) -> Bool {
        exactLineCompleted && !taskIsCancelled
    }
}
