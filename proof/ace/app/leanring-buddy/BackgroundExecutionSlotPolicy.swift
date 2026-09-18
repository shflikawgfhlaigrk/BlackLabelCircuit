import Foundation

nonisolated enum BackgroundExecutionSlot:
    String, Equatable, Hashable, Sendable
{
    case red
    case silver
}

nonisolated enum BackgroundExecutionSlotPolicy {
    /// Owner work gets Red first. While Red is occupied, one second task may
    /// use Silver only when Silver is not already running a task or a workflow.
    /// Additional requests remain queued until a slot is free.
    static func select(
        redAgentIsActive: Bool,
        silverAgentIsActive: Bool,
        silverWorkflowIsActive: Bool,
        privacyWallIsActive: Bool
    ) -> BackgroundExecutionSlot? {
        guard !privacyWallIsActive else { return nil }
        if !redAgentIsActive {
            return .red
        }
        if !silverAgentIsActive, !silverWorkflowIsActive {
            return .silver
        }
        return nil
    }
}

/// Retains every admitted request under its original identity until execution.
nonisolated struct BackgroundExecutionQueue<Work: Identifiable> where Work.ID == UUID {
    private var requests: [Work] = []
    var isEmpty: Bool { requests.isEmpty }
    var first: Work? { requests.first }
    var count: Int { requests.count }

    @discardableResult
    mutating func append(_ work: Work) -> Bool {
        guard !requests.contains(where: { $0.id == work.id }) else { return false }
        requests.append(work)
        return true
    }

    mutating func removeFirst() -> Work? {
        requests.isEmpty ? nil : requests.removeFirst()
    }

    mutating func removeAll() { requests.removeAll() }
}
