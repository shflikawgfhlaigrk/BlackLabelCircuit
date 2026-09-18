import Foundation

nonisolated enum AceHQCompanionExecutionDecision: Equatable, Sendable {
    case planOnly
    case requiresExecutionConfirmation(AceHQExactExecutionReview)
}

nonisolated enum AceHQCompanionExecutionProgressState: Equatable, Sendable {
    case executing
    case progress
}

nonisolated struct AceHQCompanionExecutionProgress: Equatable, Sendable {
    let state: AceHQCompanionExecutionProgressState
    let executionID: String
    let phase: AceHQExecutionPhase
}

nonisolated enum AceHQCompanionTerminalDisposition: Equatable, Sendable {
    case reportedPlanSuccess
    case reportedPlanFailure
    case verifiedExecutionSuccess
    case reportedExecutionFailure
    case invalid
}

/// Pure policy boundary between CompanionManager's presentation lifecycle and
/// the HQ protocol. Execution authority is created only from a fresh review of
/// one app-owned canonical target; a missing target remains plan-only before
/// dispatch and never mutates an accepted executable envelope.
nonisolated enum AceHQCompanionExecutionPolicy {
    static func decision(
        request: ContextualOwnerRequest,
        capability: AceHQRequestedCapability,
        reviewIdentifier: UUID,
        at timestamp: Date
    ) -> AceHQCompanionExecutionDecision {
        guard let executionTarget = AceHQCompanyWorkPolicy.executionTarget(
            for: request,
            capability: capability
        ) else {
            return .planOnly
        }
        return .requiresExecutionConfirmation(AceHQExactExecutionReview(
            reviewIdentifier: reviewIdentifier,
            request: request,
            capability: capability,
            executionTarget: executionTarget,
            requestedAt: timestamp,
            phase: .presenting
        ))
    }

    static func presentation(
        for review: AceHQExactExecutionReview
    ) -> String {
        [
            "HQ execution authorization.",
            "Canonical target: \(review.executionTarget.id.rawValue).",
            "Exact instruction:",
            review.exactInstruction,
            "Confirm this exact execution after the readback finishes.",
        ].joined(separator: "\n")
    }

    static func confirmedIntent(
        review: AceHQExactExecutionReview,
        reviewIdentifier: UUID,
        presentedReview: String,
        durableConsent: AceHQDurableCapabilityConsent,
        at timestamp: Date
    ) -> AceHQDispatchIntent? {
        guard presentedReview == presentation(for: review),
              review.acceptsConfirmation(
                  reviewIdentifier: reviewIdentifier,
                  exactInstruction: review.exactInstruction,
                  executionTarget: review.executionTarget,
                  at: timestamp
              ),
              let intent = AceHQCompanyWorkPolicy.makeExecutableIntent(
                  request: review.request,
                  capability: review.capability,
                  durableConsent: durableConsent,
                  consentValidatedAt: timestamp,
                  exactExecutionConfirmedAt: timestamp
              ),
              intent.executionTarget == review.executionTarget else {
            return nil
        }
        return intent
    }

    static func progress(
        previous: AceHQPendingDispatch,
        updated: AceHQPendingDispatch
    ) -> AceHQCompanionExecutionProgress? {
        guard previous.envelope.authority == .executeWhitelisted,
              updated.envelope.authority == .executeWhitelisted,
              previous.envelope == updated.envelope,
              previous.sessionID == updated.sessionID,
              previous.acceptedEventID == updated.acceptedEventID,
              updated.nextEventSequence >= previous.nextEventSequence,
              let executionID = updated.executionID,
              !executionID.isEmpty,
              let phase = updated.executionPhase,
              phase != .accepted,
              phase != .terminal,
              previous.executionID != updated.executionID
                || previous.executionPhase != phase
                || previous.nextEventSequence != updated.nextEventSequence else {
            return nil
        }
        let state: AceHQCompanionExecutionProgressState = phase == .executing
            ? .executing
            : .progress
        return AceHQCompanionExecutionProgress(
            state: state,
            executionID: executionID,
            phase: phase
        )
    }

    static func terminalDisposition(
        _ receipt: AceHQTerminalReceipt
    ) -> AceHQCompanionTerminalDisposition {
        let isExecution = receipt.executionID != nil
            || receipt.executionTarget != nil
            || !receipt.evidence.isEmpty
        if !isExecution {
            guard receipt.verificationState == .reported else {
                return .invalid
            }
            return receipt.outcome == .succeeded
                ? .reportedPlanSuccess
                : .reportedPlanFailure
        }

        guard let executionID = receipt.executionID,
              !executionID.isEmpty,
              receipt.executionTarget != nil else {
            return .invalid
        }
        switch receipt.outcome {
        case .succeeded:
            guard receipt.verificationState == .verified,
                  let target = receipt.executionTarget,
                  hasVerifiedSuccessEvidence(
                      receipt.evidence,
                      target: target
                  ) else {
                return .invalid
            }
            return .verifiedExecutionSuccess
        case .failed:
            return receipt.verificationState == .reported
                ? .reportedExecutionFailure
                : .invalid
        }
    }

    private static func hasVerifiedSuccessEvidence(
        _ evidence: [AceHQExecutionEvidence],
        target: AceHQExecutionTarget
    ) -> Bool {
        guard evidence.count == AceHQExecutionEvidenceKind.allCases.count,
              Set(evidence.map(\.kind))
                == Set(AceHQExecutionEvidenceKind.allCases),
              let source = evidence.first(where: { $0.kind == .source }),
              let deploy = evidence.first(where: { $0.kind == .deploy }),
              let live = evidence.first(where: { $0.kind == .live }),
              source.reference.hasPrefix("git:"),
              deploy.reference.hasPrefix("cloudflare:"),
              source.observedAt == nil,
              deploy.observedAt == nil,
              source.sha256?.range(
                  of: #"^[a-f0-9]{64}$"#,
                  options: .regularExpression
              ) != nil,
              deploy.sha256?.range(
                  of: #"^[a-f0-9]{64}$"#,
                  options: .regularExpression
              ) != nil,
              live.sha256 == nil,
              live.observedAt != nil else {
            return false
        }
        let requiredHost: String?
        switch target.id {
        case .aceWebsite:
            requiredHost = "ace-bl.tech"
        case .blackLabelWebsite:
            requiredHost = "blacklabelbots.com"
        default:
            requiredHost = nil
        }
        guard let requiredHost else {
            return live.reference.hasPrefix("https://")
        }
        guard let components = URLComponents(string: live.reference) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.user == nil
            && components.password == nil
            && (components.port == nil || components.port == 443)
            && components.host?.lowercased() == requiredHost
    }
}
