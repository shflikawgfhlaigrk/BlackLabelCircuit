import Foundation

/// The Silver confirmation clock does not exist until the exact plan readback
/// receives a verified speech-DONE receipt. Keeping that transition explicit
/// prevents planning and narration latency from consuming the owner's window.
struct SilverConfirmationWindow: Equatable, Sendable {
    private(set) var openedAt: Date?
    let lifetime: TimeInterval

    init(
        openedAt: Date? = nil,
        lifetime: TimeInterval = 30
    ) {
        self.openedAt = openedAt
        self.lifetime = lifetime
    }

    @discardableResult
    mutating func openAfterVerifiedReadback(now: Date) -> Bool {
        guard openedAt == nil else { return false }
        openedAt = now
        return true
    }

    func isCurrent(now: Date) -> Bool {
        guard let openedAt else { return false }
        return Self.isCurrent(
            openedAt: openedAt,
            now: now,
            lifetime: lifetime
        )
    }

    static func isCurrent(
        openedAt: Date,
        now: Date,
        lifetime: TimeInterval
    ) -> Bool {
        let age = now.timeIntervalSince(openedAt)
        return age >= 0 && age <= lifetime
    }
}

struct GoldAnswerIdentity: Equatable, Sendable {
    var sourceSessionIdentifier: UUID
    var sourceTurnIdentifier: UUID
    var sourceCorrelationIdentifier: UUID
    var ownerGeneration: UUID
}

enum GoldAnswerInterruption: Equatable, Sendable {
    case explicitStop
    case stealth
    case shutdown
    case deadline
}

enum GoldAnswerDiscardReason: Equatable, Sendable {
    case newerOwnerTurn
    case sourceMismatch
    case explicitStop
    case stealth
    case shutdown
    case deadline
}

enum GoldAnswerDeliveryDecision: Equatable, Sendable {
    case deliver
    case discarded(GoldAnswerDiscardReason)
    case duplicate
}

/// A response is admitted by identity, never by elapsed time. The gate is
/// single-use so a duplicate callback cannot display or speak the same answer
/// twice after a long model or speech delay.
struct GoldAnswerDeliveryGate: Sendable {
    let expected: GoldAnswerIdentity
    private var isResolved = false

    init(expected: GoldAnswerIdentity) {
        self.expected = expected
    }

    mutating func claim(
        current: GoldAnswerIdentity,
        interruption: GoldAnswerInterruption?
    ) -> GoldAnswerDeliveryDecision {
        guard !isResolved else { return .duplicate }
        isResolved = true

        if let interruption {
            switch interruption {
            case .explicitStop:
                return .discarded(.explicitStop)
            case .stealth:
                return .discarded(.stealth)
            case .shutdown:
                return .discarded(.shutdown)
            case .deadline:
                return .discarded(.deadline)
            }
        }
        guard expected.sourceSessionIdentifier
                == current.sourceSessionIdentifier,
              expected.sourceTurnIdentifier
                == current.sourceTurnIdentifier,
              expected.sourceCorrelationIdentifier
                == current.sourceCorrelationIdentifier else {
            return .discarded(.sourceMismatch)
        }
        guard expected.ownerGeneration
                == current.ownerGeneration else {
            return .discarded(.newerOwnerTurn)
        }
        return .deliver
    }
}
