import Foundation

nonisolated enum AceHQPreDispatchStealthPurge {
    static func purge<Value>(_ terminals: inout [UUID: Value]) {
        terminals.removeAll(keepingCapacity: false)
    }
}

struct AceHQDispatchRetrySnapshot: Equatable, Sendable {
    let intent: AceHQDispatchIntent
    let acceptedDispatch: AceHQPendingDispatch?
}

/// A terminal claimant proves only ordering. Expensive persistence, event-bus,
/// UI, and speech work happens after both synchronization locks are released.
struct AceHQDispatchTerminalClaim: Equatable, Sendable {
    let generation: UUID
}

enum AceHQDurablePublicationOutcome: Equatable, Sendable {
    case persistenceDeferred
    case publicationDeferred
    case published
}

/// Durable-first publication shared by pre-dispatch HQ terminals. The caller
/// retains the exact tuple on either refusal, and the publication closure can
/// run only inside its final Stealth admission.
nonisolated enum AceHQDurablePublicationGate {
    static func finish(
        persistenceCompleted: Bool,
        persist: () -> Bool,
        publishUnlessRaised: (_ body: () -> Bool) -> Bool,
        publish: @escaping () -> Bool
    ) -> AceHQDurablePublicationOutcome {
        guard persistenceCompleted || persist() else {
            return .persistenceDeferred
        }
        guard publishUnlessRaised(publish) else {
            return .publicationDeferred
        }
        return .published
    }
}

/// Companion-side terminal finalization intentionally runs after a successful
/// claim has released both synchronization locks.
nonisolated enum AceHQDispatchTerminalFinalizer {
    @discardableResult
    static func finalize<Claim, Result>(
        claim: Claim?,
        body: () -> Result
    ) -> Result? {
        guard claim != nil else { return nil }
        return body()
    }
}

/// Synchronous ownership wall between a long-running HQ poll and Stealth X.
/// Every accepted cursor is retained under one lock; cancellation invalidates
/// the generation and preserves that exact request for an explicit later retry.
nonisolated final class AceHQDispatchStealthBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UUID?
    private var intent: AceHQDispatchIntent?
    private var latestPending: AceHQPendingDispatch?
    private var task: Task<Void, Never>?
    private var interruptedRetry: AceHQDispatchRetrySnapshot?
    private var deferredTerminalClaim: AceHQDispatchTerminalClaim?
    private var cancelled = false
    private var terminalClaimed = false
    private var terminalFinalized = false
    private var reservedTerminalClaim: AceHQDispatchTerminalClaim?
    private var terminalPublicationClaimed = false
    private var acknowledgementPublicationClaimed = false

    @discardableResult
    func begin(
        generation: UUID,
        intent: AceHQDispatchIntent,
        acceptedDispatch: AceHQPendingDispatch? = nil
    ) -> Bool {
        lock.withLock {
            guard !cancelled, self.generation == nil else { return false }
            self.generation = generation
            self.intent = intent
            latestPending = acceptedDispatch
            return true
        }
    }

    @discardableResult
    func register(_ task: Task<Void, Never>, generation: UUID) -> Bool {
        let shouldCancel = lock.withLock {
            guard !cancelled, self.generation == generation else {
                return true
            }
            self.task = task
            return false
        }
        if shouldCancel {
            task.cancel()
            return false
        }
        return true
    }

    /// Returns false when Stealth already won, but still retains a late start
    /// acknowledgement so retry resumes the exact accepted HQ turn.
    @discardableResult
    func recordPending(
        _ pending: AceHQPendingDispatch,
        generation: UUID
    ) -> Bool {
        lock.withLock {
            guard self.generation == generation,
                  !terminalClaimed,
                  let intent else {
                return false
            }
            latestPending = pending
            if cancelled {
                interruptedRetry = AceHQDispatchRetrySnapshot(
                    intent: intent,
                    acceptedDispatch: pending
                )
                return false
            }
            return true
        }
    }

    func cancelSynchronously() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            cancelled = true
            if terminalClaimed, !terminalFinalized {
                deferredTerminalClaim = reservedTerminalClaim
            }
            if !terminalFinalized, let intent {
                interruptedRetry = AceHQDispatchRetrySnapshot(
                    intent: intent,
                    acceptedDispatch: latestPending
                )
            }
            return self.task
        }
        task?.cancel()
    }

    /// Claims terminal ownership under both small locks. This function never
    /// runs caller persistence or UI work; it returns a token after unlocking.
    func claimAcknowledgementIfCurrent(
        generation: UUID,
        performUnlessRaised:
            (_ body: () -> AceHQDispatchTerminalClaim)
                -> AceHQDispatchTerminalClaim?
    ) -> AceHQDispatchTerminalClaim? {
        let preflight = lock.withLock {
            !cancelled
                && !terminalClaimed
                && self.generation == generation
        }
        guard preflight else { return nil }
        let claim = performUnlessRaised {
            AceHQDispatchTerminalClaim(generation: generation)
        }
        guard let claim else {
            lock.withLock {
                guard self.generation == generation,
                      let intent else { return }
                interruptedRetry = AceHQDispatchRetrySnapshot(
                    intent: intent,
                    acceptedDispatch: latestPending
                )
            }
            return nil
        }
        return lock.withLock {
            guard !cancelled, self.generation == generation else {
                return nil
            }
            return claim
        }
    }

    func claimTerminalIfCurrent(
        generation: UUID,
        performUnlessRaised:
            (_ body: () -> AceHQDispatchTerminalClaim)
                -> AceHQDispatchTerminalClaim?
    ) -> AceHQDispatchTerminalClaim? {
        let preflight = lock.withLock {
            guard !cancelled,
                  !terminalClaimed,
                  self.generation == generation else {
                return false
            }
            return true
        }
        guard preflight else { return nil }
        let claim = performUnlessRaised {
            AceHQDispatchTerminalClaim(generation: generation)
        }
        guard let claim else {
            lock.withLock {
                guard self.generation == generation,
                      let intent else { return }
                interruptedRetry = AceHQDispatchRetrySnapshot(
                    intent: intent,
                    acceptedDispatch: latestPending
                )
            }
            return nil
        }
        return lock.withLock {
            guard !cancelled,
                  !terminalClaimed,
                  self.generation == generation else {
                deferredTerminalClaim = claim
                if let intent {
                    interruptedRetry = AceHQDispatchRetrySnapshot(
                        intent: intent,
                        acceptedDispatch: latestPending
                    )
                }
                return nil
            }
            terminalClaimed = true
            reservedTerminalClaim = claim
            return claim
        }
    }

    /// Completes the second phase only after the durable terminal save returns
    /// true. Cancellation or save failure retains the exact accepted cursor.
    @discardableResult
    func finalizeTerminalClaim(
        _ claim: AceHQDispatchTerminalClaim,
        persisted: Bool
    ) -> Bool {
        lock.withLock {
            guard terminalClaimed,
                  !terminalFinalized,
                  reservedTerminalClaim == claim,
                  self.generation == claim.generation else {
                return false
            }
            guard persisted else {
                if let intent {
                    interruptedRetry = AceHQDispatchRetrySnapshot(
                        intent: intent,
                        acceptedDispatch: latestPending
                    )
                }
                return false
            }
            terminalFinalized = true
            intent = nil
            latestPending = nil
            interruptedRetry = nil
            deferredTerminalClaim = nil
            reservedTerminalClaim = nil
            return true
        }
    }

    /// A nonterminal acknowledgement token is only a reservation. This second
    /// admission performs the bounded EventBus/UI mutation while the Stealth
    /// latch is held, closing the token-to-body race without doing disk or
    /// awaited work under either lock.
    func commitAcknowledgementPublicationIfCurrent(
        _ claim: AceHQDispatchTerminalClaim,
        performUnlessRaised:
            (_ body: () -> Bool) -> Bool?,
        publish: @escaping () -> Bool
    ) -> Bool {
        let preflight = lock.withLock {
            !cancelled
                && !terminalClaimed
                && !acknowledgementPublicationClaimed
                && generation == claim.generation
        }
        guard preflight else { return false }
        let committed = performUnlessRaised {
            let admitted = self.lock.withLock {
                guard !self.cancelled,
                      !self.terminalClaimed,
                      !self.acknowledgementPublicationClaimed,
                      self.generation == claim.generation else {
                    return false
                }
                self.acknowledgementPublicationClaimed = true
                return true
            }
            guard admitted else { return false }
            let published = publish()
            if !published {
                self.lock.withLock {
                    self.acknowledgementPublicationClaimed = false
                }
            }
            return published
        } ?? false
        guard committed else {
            lock.withLock {
                guard generation == claim.generation,
                      let intent else { return }
                interruptedRetry = AceHQDispatchRetrySnapshot(
                    intent: intent,
                    acceptedDispatch: latestPending
                )
            }
            return false
        }
        return true
    }

    /// Same final admission for an actual terminal after durable phase two.
    /// The publication callback is bounded in-process work only.
    func commitTerminalPublicationIfFinalized(
        _ claim: AceHQDispatchTerminalClaim,
        performUnlessRaised:
            (_ body: () -> Bool) -> Bool?,
        publish: @escaping () -> Bool
    ) -> Bool {
        let preflight = lock.withLock {
            terminalFinalized
                && !terminalPublicationClaimed
                && !cancelled
                && generation == claim.generation
        }
        guard preflight else { return false }
        return performUnlessRaised {
            let admitted = self.lock.withLock {
                guard self.terminalFinalized,
                      !self.terminalPublicationClaimed,
                      !self.cancelled,
                      self.generation == claim.generation else {
                    return false
                }
                self.terminalPublicationClaimed = true
                return true
            }
            guard admitted else { return false }
            let published = publish()
            if !published {
                self.lock.withLock {
                    self.terminalPublicationClaimed = false
                }
            }
            return published
        } ?? false
    }

    func consumeDeferredTerminalClaim() -> AceHQDispatchTerminalClaim? {
        lock.withLock {
            let claim = deferredTerminalClaim
            deferredTerminalClaim = nil
            return claim
        }
    }

    func consumeInterruptedRetry() -> AceHQDispatchRetrySnapshot? {
        lock.withLock {
            let snapshot = interruptedRetry
            interruptedRetry = nil
            return snapshot
        }
    }

    var hasInterruptedRetry: Bool {
        lock.withLock { interruptedRetry != nil }
    }

    func isCurrent(generation: UUID) -> Bool {
        lock.withLock {
            !cancelled && self.generation == generation
        }
    }
}
