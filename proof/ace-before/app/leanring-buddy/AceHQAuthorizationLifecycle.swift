import Foundation

/// Pure state used by CompanionManager's HQ confirmation review. The exact
/// plan can arm only after the same immutable bytes finish verified verbatim
/// presentation, and a generic confirmation is scoped to that review ID.
nonisolated struct AceHQExactPlanReview: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case presenting
        case ready(expiresAt: Date)
    }

    let reviewIdentifier: UUID
    let request: ContextualOwnerRequest
    let capability: AceHQRequestedCapability
    let requestedAt: Date
    let phase: Phase

    var exactPlan: String { request.executionInstruction }

    func arming(
        reviewIdentifier: UUID,
        presentedExactPlan: String,
        at timestamp: Date,
        lifetime: TimeInterval = CrossAppActionPolicy.confirmationLifetime
    ) -> AceHQExactPlanReview? {
        guard case .presenting = phase,
              self.reviewIdentifier == reviewIdentifier,
              exactPlan == presentedExactPlan,
              timestamp >= requestedAt else {
            return nil
        }
        return AceHQExactPlanReview(
            reviewIdentifier: self.reviewIdentifier,
            request: request,
            capability: capability,
            // Authority starts only after the complete immutable plan has
            // finished verified verbatim presentation. A long plan must not
            // consume its own thirty-second confirmation window.
            requestedAt: timestamp,
            phase: .ready(
                expiresAt: timestamp.addingTimeInterval(
                    lifetime
                )
            )
        )
    }

    func acceptsConfirmation(
        reviewIdentifier: UUID,
        exactPlan: String,
        at timestamp: Date,
        lifetime: TimeInterval = CrossAppActionPolicy.confirmationLifetime
    ) -> Bool {
        guard case .ready(let expiresAt) = phase else { return false }
        return self.reviewIdentifier == reviewIdentifier
            && self.exactPlan == exactPlan
            && timestamp >= requestedAt
            && timestamp <= expiresAt
            && isFresh(at: timestamp, lifetime: lifetime)
    }

    func isFresh(
        at timestamp: Date,
        lifetime: TimeInterval = CrossAppActionPolicy.confirmationLifetime
    ) -> Bool {
        let age = timestamp.timeIntervalSince(requestedAt)
        return age >= 0
            && age <= lifetime
    }
}

/// Execution authority includes both immutable instruction bytes and the
/// app-owned canonical target. Confirmation cannot be replayed across either.
nonisolated struct AceHQExactExecutionReview: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case presenting
        case ready(expiresAt: Date)
    }

    let reviewIdentifier: UUID
    let request: ContextualOwnerRequest
    let capability: AceHQRequestedCapability
    let executionTarget: AceHQExecutionTarget
    let requestedAt: Date
    let phase: Phase

    var exactInstruction: String { request.executionInstruction }

    func arming(
        reviewIdentifier: UUID,
        presentedExactInstruction: String,
        presentedExecutionTarget: AceHQExecutionTarget,
        at timestamp: Date,
        lifetime: TimeInterval = CrossAppActionPolicy.confirmationLifetime
    ) -> AceHQExactExecutionReview? {
        guard case .presenting = phase,
              self.reviewIdentifier == reviewIdentifier,
              exactInstruction == presentedExactInstruction,
              executionTarget == presentedExecutionTarget,
              executionTarget.isAuthorized(for: capability),
              timestamp >= requestedAt else {
            return nil
        }
        return Self(
            reviewIdentifier: self.reviewIdentifier,
            request: request,
            capability: capability,
            executionTarget: executionTarget,
            requestedAt: timestamp,
            phase: .ready(
                expiresAt: timestamp.addingTimeInterval(lifetime)
            )
        )
    }

    func acceptsConfirmation(
        reviewIdentifier: UUID,
        exactInstruction: String,
        executionTarget: AceHQExecutionTarget,
        at timestamp: Date,
        lifetime: TimeInterval = CrossAppActionPolicy.confirmationLifetime
    ) -> Bool {
        guard case .ready(let expiresAt) = phase else { return false }
        let age = timestamp.timeIntervalSince(requestedAt)
        return self.reviewIdentifier == reviewIdentifier
            && self.exactInstruction == exactInstruction
            && self.executionTarget == executionTarget
            && executionTarget.isAuthorized(for: capability)
            && timestamp >= requestedAt
            && timestamp <= expiresAt
            && age >= 0
            && age <= lifetime
    }
}

/// Binds a first-run durable-consent continuation to the one review and the
/// immutable owner source/work identity that created it.
nonisolated struct AceHQCapabilityConsentContinuation: Equatable, Sendable {
    let request: ContextualOwnerRequest
    let capability: AceHQRequestedCapability
    let consentReviewIdentifier: UUID?
    let consentSourceSessionIdentifier: UUID?
    let consentSourceTurnIdentifier: UUID?
    let consentSourceCorrelationIdentifier: UUID?
    let consentWorkCorrelationIdentifier: UUID?

    func bound(to reviewIdentifier: UUID) -> Self? {
        guard consentReviewIdentifier == nil else { return nil }
        return Self(
            request: request,
            capability: capability,
            consentReviewIdentifier: reviewIdentifier,
            consentSourceSessionIdentifier:
                request.sourceSessionIdentifier,
            consentSourceTurnIdentifier: request.sourceTurnIdentifier,
            consentSourceCorrelationIdentifier:
                request.sourceCorrelationIdentifier,
            consentWorkCorrelationIdentifier:
                request.childWorkCorrelationIdentifier
        )
    }

    func matches(
        reviewIdentifier: UUID,
        request: String,
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        sourceCorrelationIdentifier: UUID,
        workCorrelationIdentifier: UUID
    ) -> Bool {
        consentReviewIdentifier == reviewIdentifier
            && self.request.resolvedRequest == request
            && consentSourceSessionIdentifier
                == sourceSessionIdentifier
            && consentSourceTurnIdentifier == sourceTurnIdentifier
            && consentSourceCorrelationIdentifier
                == sourceCorrelationIdentifier
            && consentWorkCorrelationIdentifier
                == workCorrelationIdentifier
    }
}
