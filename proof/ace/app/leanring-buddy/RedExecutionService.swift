//
//  RedExecutionService.swift
//  Ace
//
//  The sole exact-once authority for effects originating in an admitted owner
//  turn. Gold and Partner describe an objective; Red owns execution.
//

import Foundation

nonisolated enum RedTargetBinding: Equatable, Sendable {
    case none
    case desktop(DesktopActionRequest)
    case nativePrivate(identifier: String)
}

nonisolated struct RedExecutionRequest: Equatable, Sendable {
    let envelope: OwnerRequestEnvelope
    let objective: String
    let provider: BrainCLI
    let targetBinding: RedTargetBinding
    let workID: UUID
    let idempotencyKey: String
}

nonisolated enum RedExecutionPhase: Equatable, Sendable {
    case processing
    case executing
    case committed
    case terminal(OwnerCapabilityResult)
}

nonisolated enum RedExecutionServiceError: Error, Equatable {
    case invalidObjective
    case invalidPrivateBinding
}

nonisolated final class RedExecutionService: @unchecked Sendable {
    private struct Record: Sendable {
        let request: RedExecutionRequest
        var phase: RedExecutionPhase
    }

    private let lock = NSLock()
    private var turnByCorrelation: [UUID: UUID] = [:]
    private var recordsByTurn: [UUID: Record] = [:]

    func claim(
        envelope: OwnerRequestEnvelope,
        objective rawObjective: String,
        provider: BrainCLI,
        targetBinding: RedTargetBinding,
        workID suppliedWorkID: UUID? = nil
    ) throws -> RedExecutionRequest? {
        let objective = rawObjective.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !objective.isEmpty,
              objective.count <= 1_200 else {
            throw RedExecutionServiceError.invalidObjective
        }
        if case .nativePrivate(let identifier) = targetBinding {
            guard !identifier.isEmpty,
                  identifier.count <= 160,
                  identifier == identifier.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ) else {
                throw RedExecutionServiceError.invalidPrivateBinding
            }
        }

        return lock.withLock {
            guard turnByCorrelation[envelope.correlationID] == nil,
                  recordsByTurn[envelope.turnID] == nil else {
                return nil
            }
            let request = RedExecutionRequest(
                envelope: envelope,
                objective: objective,
                provider: provider,
                targetBinding: targetBinding,
                workID: suppliedWorkID ?? UUID(),
                idempotencyKey: [
                    "red",
                    envelope.sessionID.uuidString.lowercased(),
                    envelope.turnID.uuidString.lowercased(),
                    envelope.correlationID.uuidString.lowercased(),
                ].joined(separator: ":")
            )
            turnByCorrelation[envelope.correlationID] = envelope.turnID
            recordsByTurn[envelope.turnID] = Record(
                request: request,
                phase: .processing
            )
            return request
        }
    }

    func phase(turnID: UUID) -> RedExecutionPhase? {
        lock.withLock { recordsByTurn[turnID]?.phase }
    }

    @discardableResult
    func markExecuting(turnID: UUID) -> Bool {
        transition(turnID: turnID) { phase in
            guard phase == .processing else { return false }
            phase = .executing
            return true
        }
    }

    @discardableResult
    func markCommitted(turnID: UUID) -> Bool {
        transition(turnID: turnID) { phase in
            switch phase {
            case .processing, .executing:
                phase = .committed
                return true
            case .committed, .terminal:
                return false
            }
        }
    }

    @discardableResult
    func cancelBeforeCommit(turnID: UUID) -> Bool {
        transition(turnID: turnID) { phase in
            switch phase {
            case .processing, .executing:
                phase = .terminal(Self.cancelled("cancelled-pre-commit"))
                return true
            case .committed, .terminal:
                return false
            }
        }
    }

    @discardableResult
    func finish(
        turnID: UUID,
        result: OwnerCapabilityResult
    ) -> Bool {
        transition(turnID: turnID) { phase in
            guard case .terminal = phase else {
                phase = .terminal(result)
                return true
            }
            return false
        }
    }

    @discardableResult
    func cancelPrecommitWork(
        sessionID: UUID,
        excludingTurnID: UUID? = nil
    ) -> Int {
        lock.withLock {
            var cancelledCount = 0
            for turnID in recordsByTurn.keys where turnID != excludingTurnID {
                guard var record = recordsByTurn[turnID],
                      record.request.envelope.sessionID == sessionID else {
                    continue
                }
                switch record.phase {
                case .processing, .executing:
                    record.phase = .terminal(
                        Self.cancelled("replaced-pre-commit")
                    )
                    recordsByTurn[turnID] = record
                    cancelledCount += 1
                case .committed, .terminal:
                    break
                }
            }
            return cancelledCount
        }
    }

    private func transition(
        turnID: UUID,
        _ body: (inout RedExecutionPhase) -> Bool
    ) -> Bool {
        lock.withLock {
            guard var record = recordsByTurn[turnID] else { return false }
            let changed = body(&record.phase)
            if changed { recordsByTurn[turnID] = record }
            return changed
        }
    }

    private static func cancelled(
        _ receipt: String
    ) -> OwnerCapabilityResult {
        OwnerCapabilityResult(
            status: .cancelled,
            spokenSummary: "Stopped before the action committed.",
            contentFreeReceipt: receipt,
            recoveryReference: nil
        )
    }
}
