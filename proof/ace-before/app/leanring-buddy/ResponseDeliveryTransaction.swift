import Foundation

enum ResponseDeliveryPhase: Equatable, Sendable {
    case received
    case visible
    case speechQueued
    case speechStarted
    case completed
    case failed(reason: String)
}

struct ResponseDeliveryTransaction: Equatable, Sendable {
    let id: UUID
    let responseText: String
    private(set) var phase: ResponseDeliveryPhase

    init(
        id: UUID = UUID(),
        responseText: String
    ) {
        self.id = id
        self.responseText = responseText
        phase = .received
    }

    @discardableResult
    mutating func advance(
        _ next: ResponseDeliveryPhase,
        for transactionID: UUID
    ) -> Bool {
        guard transactionID == id,
              Self.permits(from: phase, to: next) else {
            return false
        }
        phase = next
        return true
    }

    private static func permits(
        from current: ResponseDeliveryPhase,
        to next: ResponseDeliveryPhase
    ) -> Bool {
        switch (current, next) {
        case (.received, .visible),
             (.visible, .speechQueued),
             (.speechQueued, .speechStarted),
             (.speechStarted, .completed):
            return true
        case (.visible, .failed(let reason)),
             (.speechQueued, .failed(let reason)),
             (.speechStarted, .failed(let reason)):
            return !reason.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        default:
            return false
        }
    }
}
