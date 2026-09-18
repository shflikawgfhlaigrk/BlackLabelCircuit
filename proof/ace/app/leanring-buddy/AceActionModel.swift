#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import Foundation
import CircuitPortKit

struct AceActionID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

enum AceRecoveryRoute: Equatable, Codable, Sendable {
    case retry
    case openSystemSettings(String)
    case openURL(URL)
    case revealFile(URL)
    case reinstall
    case contactSupport
}

struct AceActionFailure: Error, Equatable, Codable, Sendable {
    let code: String
    let message: String
    let recoveryTitle: String
    let recovery: AceRecoveryRoute
}

struct AceActionSuccess: Equatable, Codable, Sendable {
    let message: String
}

enum AceActionPhase: Equatable, Sendable {
    case idle
    case running(startedAt: Date)
    case succeeded(AceActionSuccess)
    case failed(AceActionFailure)
    case cancelled
    case timedOut(AceActionFailure)
}

private enum AceActionRaceOutcome: Sendable {
    case succeeded(AceActionSuccess)
    case failed(AceActionFailure)
    case cancelled
    case timedOut
    case superseded
}

private final class AceActionRace: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: AceActionRaceOutcome?
    private var continuation:
        CheckedContinuation<AceActionRaceOutcome, Never>?

    func wait() async -> AceActionRaceOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ outcome: AceActionRaceOutcome) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}

@MainActor
final class AceActionModel: ObservableObject {
    private struct RunningExecution {
        let generation: UInt64
        let startedAt: Date
        let race: AceActionRace
        let operationTask: Task<Void, Never>
        let timeoutTask: Task<Void, Never>

        func cancel(with outcome: AceActionRaceOutcome) {
            operationTask.cancel()
            timeoutTask.cancel()
            race.resolve(outcome)
        }
    }

    @Published private(set) var phases: [
        AceActionID: AceActionPhase
    ] = [:]

    private let receiptStore: (any AceActionReceiptWriting)?
    private var generations: [AceActionID: UInt64] = [:]
    private var running: [AceActionID: RunningExecution] = [:]

    init(
        receiptStore: (any AceActionReceiptWriting)? =
            AceActionReceiptStore()
    ) {
        self.receiptStore = receiptStore
    }

    func phase(for id: AceActionID) -> AceActionPhase {
        phases[id] ?? .idle
    }

    func reset(_ id: AceActionID) {
        let generation = nextGeneration(for: id)
        generations[id] = generation
        running.removeValue(forKey: id)?.cancel(with: .superseded)
        phases[id] = .idle
    }

    func cancel(_ id: AceActionID) {
        guard let execution = running[id] else {
            return
        }
        phases[id] = .cancelled
        execution.cancel(with: .cancelled)
    }

    func execute(
        id: AceActionID,
        timeout: Duration,
        operation:
            @MainActor @escaping @Sendable () async throws
                -> AceActionSuccess
    ) async {
        let generation = nextGeneration(for: id)
        generations[id] = generation
        running.removeValue(forKey: id)?.cancel(with: .superseded)

        let startedAt = Date()
        phases[id] = .running(startedAt: startedAt)
        let race = AceActionRace()

        let operationTask = Task<Void, Never> {
            do {
                let success = try await operation()
                race.resolve(.succeeded(success))
            } catch let failure as AceActionFailure {
                race.resolve(.failed(failure))
            } catch is CancellationError {
                race.resolve(.cancelled)
            } catch {
                race.resolve(
                    .failed(
                        AceActionFailure(
                            code: "action.unexpected",
                            message:
                                "Ace could not complete this action.",
                            recoveryTitle: "Try again",
                            recovery: .retry
                        )
                    )
                )
            }
        }
        let timeoutTask = Task<Void, Never> {
            do {
                try await Task.sleep(for: timeout)
                race.resolve(.timedOut)
            } catch {
                return
            }
        }
        let execution = RunningExecution(
            generation: generation,
            startedAt: startedAt,
            race: race,
            operationTask: operationTask,
            timeoutTask: timeoutTask
        )
        running[id] = execution

        let outcome = await race.wait()
        operationTask.cancel()
        timeoutTask.cancel()

        guard generations[id] == generation else {
            return
        }
        running.removeValue(forKey: id)

        let receiptOutcome: String
        let failureCode: String?
        switch outcome {
        case let .succeeded(success):
            phases[id] = .succeeded(success)
            receiptOutcome = "succeeded"
            failureCode = nil
        case let .failed(failure):
            phases[id] = .failed(failure)
            receiptOutcome = "failed"
            failureCode = failure.code
        case .cancelled:
            phases[id] = .cancelled
            receiptOutcome = "cancelled"
            failureCode = nil
        case .timedOut:
            let failure = AceActionFailure(
                code: "action.timed_out",
                message: "Ace did not finish this action in time.",
                recoveryTitle: "Try again",
                recovery: .retry
            )
            phases[id] = .timedOut(failure)
            receiptOutcome = "timedOut"
            failureCode = failure.code
        case .superseded:
            return
        }

        guard let receiptStore else {
            return
        }
        do {
            try await receiptStore.append(
                AceActionReceipt(
                    actionID: id.rawValue,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    outcome: receiptOutcome,
                    failureCode: failureCode
                )
            )
        } catch {
            NSLog(
                "Ace action receipt write failed for action ID %@",
                id.rawValue
            )
        }
    }

    private func nextGeneration(for id: AceActionID) -> UInt64 {
        (generations[id] ?? 0) &+ 1
    }
}
