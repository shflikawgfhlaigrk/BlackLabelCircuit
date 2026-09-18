import Foundation

enum VoiceDaemonAttemptContext: Equatable, Sendable {
    case warm
    case recycledCold

    var receiptLabel: String {
        switch self {
        case .warm:
            return "warm"
        case .recycledCold:
            return "recycled-cold"
        }
    }
}

enum VoiceStartDeadlinePolicy {
    private static let shortReplyCharacterLimit = 64
    private static let warmBaseSeconds: TimeInterval = 10
    private static let warmMaximumSeconds: TimeInterval = 30
    private static let recycledColdBaseSeconds: TimeInterval = 25
    private static let recycledColdMaximumSeconds: TimeInterval = 45

    static func seconds(
        forCharacterCount characterCount: Int,
        attemptContext: VoiceDaemonAttemptContext
    ) -> TimeInterval {
        let boundedCharacterCount = max(0, characterCount)
        let additionalCharacterCount = max(
            0,
            boundedCharacterCount - shortReplyCharacterLimit
        )
        let additionalSeconds = ceil(
            Double(additionalCharacterCount) / 64
        )
        switch attemptContext {
        case .warm:
            return min(
                warmMaximumSeconds,
                warmBaseSeconds + additionalSeconds
            )
        case .recycledCold:
            return min(
                recycledColdMaximumSeconds,
                recycledColdBaseSeconds + additionalSeconds
            )
        }
    }
}

enum VoiceDaemonDeliveryAttempt: Equatable, Sendable {
    case completed
    case interrupted
    case failed
    case startTimedOut
}

@MainActor
enum VoiceDaemonRecoveryPolicy {
    static func deliver(
        attempt: (
            VoiceDaemonAttemptContext
        ) async -> VoiceDaemonDeliveryAttempt,
        recycle: () -> Void
    ) async -> VoiceDaemonDeliveryAttempt {
        let firstAttempt = await attempt(.warm)
        guard firstAttempt == .startTimedOut else {
            return firstAttempt
        }
        recycle()
        return await attempt(.recycledCold)
    }
}
