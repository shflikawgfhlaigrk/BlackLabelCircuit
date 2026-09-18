import Foundation

enum AceHQRequestedCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case websiteProduction = "website_production"
    case releaseBuild = "release_build"
    case appEngineering = "app_engineering"
    case qualityAssurance = "quality_assurance"
    case companyCoordination = "company_coordination"

    /// App-owned capability boundary mirrored by HQ's schema-v2 validator.
    /// Caller text and registry order may select only within this allowlist.
    var authorizedSeatIDs: [String] {
        switch self {
        case .websiteProduction:
            return ["web-producer", "web-engineer"]
        case .releaseBuild:
            return ["release-engineer"]
        case .appEngineering:
            return ["cto"]
        case .qualityAssurance:
            return [
                "sovereign-qa",
                "leads-qa",
                "realestate-qa",
                "trading-qa",
            ]
        case .companyCoordination:
            return ["chief-of-staff", "cto"]
        }
    }
}

struct AceHQSourceTurnIdentity: Codable, Equatable, Sendable {
    let sessionID: String
    let turnID: String
    let correlationID: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case turnID = "turn_id"
        case correlationID = "correlation_id"
    }
}

struct AceHQWorkCorrelation: Codable, Equatable, Sendable {
    let correlationID: String
    let parentCorrelationID: String?
    let hqWorkID: String?

    private enum CodingKeys: String, CodingKey {
        case correlationID = "correlation_id"
        case parentCorrelationID = "parent_correlation_id"
        case hqWorkID = "hq_work_id"
    }
}

enum AceHQCorrectionKind: String, Codable, Equatable, Sendable {
    case retry
    case amendment
}

/// Typed, app-owned correction evidence. This remains separate from both the
/// immutable objective and the exact execution instruction so neither a model
/// nor an HQ adapter can silently rewrite the failed work being retried.
struct AceHQCorrectionContext: Codable, Equatable, Sendable {
    let kind: AceHQCorrectionKind
    let ownerCorrection: String
    let priorTerminalOutcome: String?
    let priorTerminalVerification: String?
    let priorTerminalReason: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case ownerCorrection = "owner_correction"
        case priorTerminalOutcome = "prior_terminal_outcome"
        case priorTerminalVerification = "prior_terminal_verification"
        case priorTerminalReason = "prior_terminal_reason"
    }

    func executionInstruction(objective: String) -> String {
        var fields = [
            "ORIGINAL OBJECTIVE:\n" + objective,
            "OWNER CORRECTION KIND:\n" + kind.rawValue,
            "OWNER CORRECTION:\n" + ownerCorrection,
        ]
        if let priorTerminalOutcome {
            fields.append(
                "PRIOR APP-OBSERVED OUTCOME:\n" + priorTerminalOutcome
            )
        }
        if let priorTerminalVerification {
            fields.append(
                "PRIOR APP-OBSERVED VERIFICATION:\n"
                    + priorTerminalVerification
            )
        }
        if let priorTerminalReason {
            fields.append(
                "PRIOR APP-OBSERVED REASON:\n" + priorTerminalReason
            )
        }
        fields.append(
            kind == .retry
                ? "Continue the same exact work lineage. Re-read the bound target before retrying and preserve any completed steps. If a prior effect is present or its outcome is uncertain, report the evidence and stop instead of repeating that effect. Retry only the remaining original objective and verify the result."
                : "Continue the same exact work lineage and apply the owner's correction to the original objective. Re-read the bound target's current state and preserve steps already completed. A request to submit an existing draft changes its prior leave-unsent instruction; do not retype or duplicate the draft. If submission already occurred or its outcome is unclear, report that state instead of submitting again."
        )
        return fields.joined(separator: "\n\n")
    }
}

/// Local owner authority for retrying an already-accepted HQ handoff. The HQ
/// session/turn in `AceHQPendingDispatch` remains immutable and is reconciled
/// only; this separate child records the owner's new turn and the exact typed
/// failure that caused the retry without pretending HQ accepted a second job.
struct AceHQReconciliationAttempt: Codable, Equatable, Sendable {
    let acceptedWorkCorrelationID: String
    let source: AceHQSourceTurnIdentity
    let work: AceHQWorkCorrelation
    let exactOwnerTranscript: String
    let resolvedRequest: String
    let executionInstruction: String
    let correctionContext: AceHQCorrectionContext

    private enum CodingKeys: String, CodingKey {
        case acceptedWorkCorrelationID = "accepted_work_correlation_id"
        case source
        case work
        case exactOwnerTranscript = "exact_owner_transcript"
        case resolvedRequest = "resolved_request"
        case executionInstruction = "execution_instruction"
        case correctionContext = "correction_context"
    }

    func isValid(for acceptedIntent: AceHQDispatchIntent) -> Bool {
        guard canonicalUUID(acceptedWorkCorrelationID),
              acceptedWorkCorrelationID
                == acceptedIntent.work.correlationID,
              canonicalUUID(source.sessionID),
              canonicalUUID(source.turnID),
              canonicalUUID(source.correlationID),
              canonicalUUID(work.correlationID),
              let parent = work.parentCorrelationID,
              canonicalUUID(parent),
              work.correlationID != parent,
              work.correlationID != acceptedIntent.work.correlationID,
              work.hqWorkID == nil,
              correctionContext.kind == .retry,
              !exactOwnerTranscript.isEmpty,
              exactOwnerTranscript.count <= 8_000,
              correctionContext.ownerCorrection == exactOwnerTranscript,
              !resolvedRequest.isEmpty,
              resolvedRequest.count <= 1_200,
              resolvedRequest == acceptedIntent.resolvedRequest,
              correctionContext.priorTerminalOutcome?.hasPrefix(
                  "blocked."
              ) == true,
              correctionContext.priorTerminalVerification == "none",
              executionInstruction == correctionContext
                .executionInstruction(objective: resolvedRequest) else {
            return false
        }
        return true
    }

    private func canonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

struct AceHQDurableCapabilityConsent: Equatable, Sendable {
    let receiptReference: String
    let receiptSchemaVersion: Int
    let approvedScopes: [String]
    let approvedWorkspaceRoots: [String]
    let approvedAt: Date
}

enum AceHQAuthorizationRequirement: String, Codable, Equatable, Sendable {
    case nonconsequentialPlan = "nonconsequential_plan"
    case consequentialPlan = "consequential_plan"
    case consequentialExecution = "consequential_execution"
}

enum AceHQExecutionTargetKind: String, Codable, Equatable, Sendable {
    case canonicalResource = "canonical_resource"
}

/// The app, never owner/model prose, selects one identity from this finite
/// registry. A filesystem path, working directory, URL, or display title
/// cannot be represented as an executable target.
enum AceHQExecutionTargetID: String, Codable, CaseIterable, Equatable, Sendable {
    case aceWebsite = "site:ace-bl.tech"
    case blackLabelWebsite = "site:blacklabelbots.com"
    case aceProduct = "product:ace"
    case sovereignProduct = "product:sovereign"
    case leadsProduct = "product:leads"
    case tradingProduct = "product:trading"
    case homefrontProduct = "product:homefront"
    case realEstateProduct = "product:realestate"
    case marketingProduct = "product:marketing"
    case blackLabelCompany = "company:black-label"
}

struct AceHQExecutionTarget: Codable, Equatable, Sendable {
    let kind: AceHQExecutionTargetKind
    let id: AceHQExecutionTargetID

    func isAuthorized(for capability: AceHQRequestedCapability) -> Bool {
        guard kind == .canonicalResource else { return false }
        switch capability {
        case .websiteProduction:
            return id == .aceWebsite || id == .blackLabelWebsite
        case .releaseBuild, .appEngineering, .qualityAssurance:
            return [
                .aceProduct,
                .sovereignProduct,
                .leadsProduct,
                .tradingProduct,
                .homefrontProduct,
                .realEstateProduct,
                .marketingProduct,
            ].contains(id)
        case .companyCoordination:
            return id == .blackLabelCompany
        }
    }
}

struct AceHQCapabilityConsentEvidence: Codable, Equatable, Sendable {
    static let durableReceiptReference = "agent-capability-consent.v1.json"
    static let currentReceiptSchemaVersion = 1
    static let completeScopeIDs: Set<String> = [
        "appAutomation",
        "browserControl",
        "bundledCLITools",
        "mcpAndPlugins",
        "networkAccess",
        "screenContext",
        "shellAndProcesses",
        "workspaceReadWrite",
    ]

    let evidenceID: String
    let receiptReference: String
    let receiptSchemaVersion: Int
    let approvedScopes: [String]
    let approvedWorkspaceRoots: [String]
    let approvedAt: Date
    let validatedAt: Date
    let source: AceHQSourceTurnIdentity
    let workCorrelationID: String

    private enum CodingKeys: String, CodingKey {
        case evidenceID = "evidence_id"
        case receiptReference = "receipt_reference"
        case receiptSchemaVersion = "receipt_schema_version"
        case approvedScopes = "approved_scopes"
        case approvedWorkspaceRoots = "approved_workspace_roots"
        case approvedAt = "approved_at"
        case validatedAt = "validated_at"
        case source
        case workCorrelationID = "work_correlation_id"
    }

    init(
        evidenceID: String,
        receiptReference: String,
        receiptSchemaVersion: Int,
        approvedScopes: [String],
        approvedWorkspaceRoots: [String],
        approvedAt: Date,
        validatedAt: Date,
        source: AceHQSourceTurnIdentity,
        workCorrelationID: String
    ) {
        self.evidenceID = evidenceID
        self.receiptReference = receiptReference
        self.receiptSchemaVersion = receiptSchemaVersion
        self.approvedScopes = approvedScopes
        self.approvedWorkspaceRoots = approvedWorkspaceRoots
        self.approvedAt = approvedAt
        self.validatedAt = validatedAt
        self.source = source
        self.workCorrelationID = workCorrelationID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        evidenceID = try values.decode(String.self, forKey: .evidenceID)
        receiptReference = try values.decode(String.self, forKey: .receiptReference)
        receiptSchemaVersion = try values.decode(Int.self, forKey: .receiptSchemaVersion)
        approvedScopes = try values.decode([String].self, forKey: .approvedScopes)
        approvedWorkspaceRoots = try values.decode([String].self, forKey: .approvedWorkspaceRoots)
        let approvedTimestamp = try values.decode(String.self, forKey: .approvedAt)
        guard let approvedDate = AceHQAuthorizationTimestamp.date(from: approvedTimestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .approvedAt,
                in: values,
                debugDescription: "approved_at is not an ISO-8601 timestamp"
            )
        }
        approvedAt = approvedDate
        let validatedTimestamp = try values.decode(String.self, forKey: .validatedAt)
        guard let validatedDate = AceHQAuthorizationTimestamp.date(from: validatedTimestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .validatedAt,
                in: values,
                debugDescription: "validated_at is not an ISO-8601 timestamp"
            )
        }
        validatedAt = validatedDate
        source = try values.decode(AceHQSourceTurnIdentity.self, forKey: .source)
        workCorrelationID = try values.decode(String.self, forKey: .workCorrelationID)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(evidenceID, forKey: .evidenceID)
        try values.encode(receiptReference, forKey: .receiptReference)
        try values.encode(receiptSchemaVersion, forKey: .receiptSchemaVersion)
        try values.encode(approvedScopes, forKey: .approvedScopes)
        try values.encode(approvedWorkspaceRoots, forKey: .approvedWorkspaceRoots)
        try values.encode(AceHQAuthorizationTimestamp.string(from: approvedAt), forKey: .approvedAt)
        try values.encode(AceHQAuthorizationTimestamp.string(from: validatedAt), forKey: .validatedAt)
        try values.encode(source, forKey: .source)
        try values.encode(workCorrelationID, forKey: .workCorrelationID)
    }
}

struct AceHQExactPlanConfirmationEvidence: Codable, Equatable, Sendable {
    let evidenceID: String
    let exactPlan: String
    let requestedCapability: AceHQRequestedCapability
    let source: AceHQSourceTurnIdentity
    let workCorrelationID: String
    let confirmedAt: Date

    private enum CodingKeys: String, CodingKey {
        case evidenceID = "evidence_id"
        case exactPlan = "exact_plan"
        case requestedCapability = "requested_capability"
        case source
        case workCorrelationID = "work_correlation_id"
        case confirmedAt = "confirmed_at"
    }

    init(
        evidenceID: String,
        exactPlan: String,
        requestedCapability: AceHQRequestedCapability,
        source: AceHQSourceTurnIdentity,
        workCorrelationID: String,
        confirmedAt: Date
    ) {
        self.evidenceID = evidenceID
        self.exactPlan = exactPlan
        self.requestedCapability = requestedCapability
        self.source = source
        self.workCorrelationID = workCorrelationID
        self.confirmedAt = confirmedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        evidenceID = try values.decode(String.self, forKey: .evidenceID)
        exactPlan = try values.decode(String.self, forKey: .exactPlan)
        requestedCapability = try values.decode(AceHQRequestedCapability.self, forKey: .requestedCapability)
        source = try values.decode(AceHQSourceTurnIdentity.self, forKey: .source)
        workCorrelationID = try values.decode(String.self, forKey: .workCorrelationID)
        let timestamp = try values.decode(String.self, forKey: .confirmedAt)
        guard let date = AceHQAuthorizationTimestamp.date(from: timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .confirmedAt,
                in: values,
                debugDescription: "confirmed_at is not an ISO-8601 timestamp"
            )
        }
        confirmedAt = date
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(evidenceID, forKey: .evidenceID)
        try values.encode(exactPlan, forKey: .exactPlan)
        try values.encode(requestedCapability, forKey: .requestedCapability)
        try values.encode(source, forKey: .source)
        try values.encode(workCorrelationID, forKey: .workCorrelationID)
        try values.encode(AceHQAuthorizationTimestamp.string(from: confirmedAt), forKey: .confirmedAt)
    }
}

struct AceHQExactExecutionConfirmationEvidence: Codable, Equatable, Sendable {
    let evidenceID: String
    let exactInstruction: String
    let executionTarget: AceHQExecutionTarget
    let requestedCapability: AceHQRequestedCapability
    let source: AceHQSourceTurnIdentity
    let workCorrelationID: String
    let confirmedAt: Date

    private enum CodingKeys: String, CodingKey {
        case evidenceID = "evidence_id"
        case exactInstruction = "exact_instruction"
        case executionTarget = "execution_target"
        case requestedCapability = "requested_capability"
        case source
        case workCorrelationID = "work_correlation_id"
        case confirmedAt = "confirmed_at"
    }

    init(
        evidenceID: String,
        exactInstruction: String,
        executionTarget: AceHQExecutionTarget,
        requestedCapability: AceHQRequestedCapability,
        source: AceHQSourceTurnIdentity,
        workCorrelationID: String,
        confirmedAt: Date
    ) {
        self.evidenceID = evidenceID
        self.exactInstruction = exactInstruction
        self.executionTarget = executionTarget
        self.requestedCapability = requestedCapability
        self.source = source
        self.workCorrelationID = workCorrelationID
        self.confirmedAt = confirmedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        evidenceID = try values.decode(String.self, forKey: .evidenceID)
        exactInstruction = try values.decode(String.self, forKey: .exactInstruction)
        executionTarget = try values.decode(AceHQExecutionTarget.self, forKey: .executionTarget)
        requestedCapability = try values.decode(AceHQRequestedCapability.self, forKey: .requestedCapability)
        source = try values.decode(AceHQSourceTurnIdentity.self, forKey: .source)
        workCorrelationID = try values.decode(String.self, forKey: .workCorrelationID)
        let timestamp = try values.decode(String.self, forKey: .confirmedAt)
        guard let date = AceHQAuthorizationTimestamp.date(from: timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .confirmedAt,
                in: values,
                debugDescription: "confirmed_at is not an ISO-8601 timestamp"
            )
        }
        confirmedAt = date
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(evidenceID, forKey: .evidenceID)
        try values.encode(exactInstruction, forKey: .exactInstruction)
        try values.encode(executionTarget, forKey: .executionTarget)
        try values.encode(requestedCapability, forKey: .requestedCapability)
        try values.encode(source, forKey: .source)
        try values.encode(workCorrelationID, forKey: .workCorrelationID)
        try values.encode(AceHQAuthorizationTimestamp.string(from: confirmedAt), forKey: .confirmedAt)
    }
}

enum AceHQAuthorizationEvidence: Codable, Equatable, Sendable {
    case capabilityConsent(AceHQCapabilityConsentEvidence)
    case exactPlanConfirmation(AceHQExactPlanConfirmationEvidence)
    case exactExecutionConfirmation(AceHQExactExecutionConfirmationEvidence)

    private enum Kind: String, Codable {
        case capabilityConsent = "capability_consent"
        case exactPlanConfirmation = "exact_plan_confirmation"
        case exactExecutionConfirmation = "exact_execution_confirmation"
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case evidence
    }

    var evidenceID: String {
        switch self {
        case .capabilityConsent(let evidence): evidence.evidenceID
        case .exactPlanConfirmation(let evidence): evidence.evidenceID
        case .exactExecutionConfirmation(let evidence): evidence.evidenceID
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .capabilityConsent:
            self = .capabilityConsent(
                try values.decode(AceHQCapabilityConsentEvidence.self, forKey: .evidence)
            )
        case .exactPlanConfirmation:
            self = .exactPlanConfirmation(
                try values.decode(AceHQExactPlanConfirmationEvidence.self, forKey: .evidence)
            )
        case .exactExecutionConfirmation:
            self = .exactExecutionConfirmation(
                try values.decode(AceHQExactExecutionConfirmationEvidence.self, forKey: .evidence)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .capabilityConsent(let evidence):
            try values.encode(Kind.capabilityConsent, forKey: .kind)
            try values.encode(evidence, forKey: .evidence)
        case .exactPlanConfirmation(let evidence):
            try values.encode(Kind.exactPlanConfirmation, forKey: .kind)
            try values.encode(evidence, forKey: .evidence)
        case .exactExecutionConfirmation(let evidence):
            try values.encode(Kind.exactExecutionConfirmation, forKey: .kind)
            try values.encode(evidence, forKey: .evidence)
        }
    }
}

struct AceHQAuthorizationBundle: Codable, Equatable, Sendable {
    let requirement: AceHQAuthorizationRequirement
    let evidence: [AceHQAuthorizationEvidence]
}

enum AceHQDispatchAuthority: String, Codable, Equatable, Sendable {
    case planOnly = "plan_only"
    case executeWhitelisted = "execute_whitelisted"
}

private enum AceHQAuthorizationTimestamp {
    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(from timestamp: String) -> Date? {
        formatter().date(from: timestamp)
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

struct AceHQVerificationRequest: Codable, Equatable, Sendable {
    let required: Bool
    let acceptanceCriteria: [String]
    let verifierSeatID: String?

    private enum CodingKeys: String, CodingKey {
        case required
        case acceptanceCriteria = "acceptance_criteria"
        case verifierSeatID = "verifier_seat_id"
    }
}

struct AceHQDispatchIntent: Codable, Equatable, Sendable {
    let source: AceHQSourceTurnIdentity
    let work: AceHQWorkCorrelation
    let exactOwnerTranscript: String
    let resolvedRequest: String
    let executionInstruction: String
    let correctionContext: AceHQCorrectionContext?
    let requestedCapability: AceHQRequestedCapability
    let executionTarget: AceHQExecutionTarget?
    let authorization: AceHQAuthorizationBundle
    let verificationRequest: AceHQVerificationRequest

    private enum CodingKeys: String, CodingKey {
        case source
        case work
        case exactOwnerTranscript = "exact_owner_transcript"
        case resolvedRequest = "resolved_request"
        case executionInstruction = "execution_instruction"
        case correctionContext = "correction_context"
        case requestedCapability = "requested_capability"
        case executionTarget = "execution_target"
        case authorization
        case verificationRequest = "verification_request"
    }

    init(
        source: AceHQSourceTurnIdentity,
        work: AceHQWorkCorrelation,
        exactOwnerTranscript: String,
        resolvedRequest: String,
        executionInstruction: String,
        correctionContext: AceHQCorrectionContext?,
        requestedCapability: AceHQRequestedCapability,
        executionTarget: AceHQExecutionTarget? = nil,
        authorization: AceHQAuthorizationBundle,
        verificationRequest: AceHQVerificationRequest
    ) {
        self.source = source
        self.work = work
        self.exactOwnerTranscript = exactOwnerTranscript
        self.resolvedRequest = resolvedRequest
        self.executionInstruction = executionInstruction
        self.correctionContext = correctionContext
        self.requestedCapability = requestedCapability
        self.executionTarget = executionTarget
        self.authorization = authorization
        self.verificationRequest = verificationRequest
    }

    func bound(to selectedSeat: AceHQSelectedSeat) -> AceHQDispatchEnvelope {
        var identityParts = [
            "ace-hq-dispatch-v2",
            source.sessionID,
            source.turnID,
            source.correlationID,
            work.correlationID,
        ]
        if let executionTarget {
            identityParts.append(AceHQDispatchAuthority.executeWhitelisted.rawValue)
            identityParts.append(executionTarget.id.rawValue)
        }
        let identity = identityParts.joined(separator: ":")
        return AceHQDispatchEnvelope(
            schemaVersion: 2,
            idempotencyKey: identity,
            authority: executionTarget == nil ? .planOnly : .executeWhitelisted,
            source: source,
            work: work,
            exactOwnerTranscript: exactOwnerTranscript,
            resolvedRequest: resolvedRequest,
            executionInstruction: executionInstruction,
            correctionContext: correctionContext,
            requestedCapability: requestedCapability,
            executionTarget: executionTarget,
            selectedSeat: selectedSeat,
            authorization: authorization,
            verificationRequest: verificationRequest
        )
    }
}

struct AceHQSelectedSeat: Codable, Equatable, Sendable {
    let seatID: String
    let providerID: String

    private enum CodingKeys: String, CodingKey {
        case seatID = "seat_id"
        case providerID = "provider_id"
    }
}

struct AceHQDispatchEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let idempotencyKey: String
    let authority: AceHQDispatchAuthority
    let source: AceHQSourceTurnIdentity
    let work: AceHQWorkCorrelation
    let exactOwnerTranscript: String
    let resolvedRequest: String
    let executionInstruction: String
    let correctionContext: AceHQCorrectionContext?
    let requestedCapability: AceHQRequestedCapability
    let executionTarget: AceHQExecutionTarget?
    let selectedSeat: AceHQSelectedSeat
    let authorization: AceHQAuthorizationBundle
    let verificationRequest: AceHQVerificationRequest

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case idempotencyKey = "idempotency_key"
        case authority
        case source
        case work
        case exactOwnerTranscript = "exact_owner_transcript"
        case resolvedRequest = "resolved_request"
        case executionInstruction = "execution_instruction"
        case correctionContext = "correction_context"
        case requestedCapability = "requested_capability"
        case executionTarget = "execution_target"
        case selectedSeat = "selected_seat"
        case authorization
        case verificationRequest = "verification_request"
    }

    // These keys stay stable if registry health changes between retries. The
    // selected seat remains part of the keyed request body, so HQ rejects a
    // changed seat as an idempotency conflict instead of creating duplicate work.
    var sessionIdempotencyKey: String { "\(idempotencyKey):session" }
    var turnIdempotencyKey: String { "\(idempotencyKey):turn" }

    var hasCoherentAuthority: Bool {
        let exactPlans: [AceHQExactPlanConfirmationEvidence] =
            authorization.evidence.compactMap { item in
            guard case .exactPlanConfirmation(let evidence) = item else {
                return nil
            }
            return evidence
        }
        let exactExecutions: [AceHQExactExecutionConfirmationEvidence] =
            authorization.evidence.compactMap { item in
            guard case .exactExecutionConfirmation(let evidence) = item else {
                return nil
            }
            return evidence
        }
        switch authority {
        case .planOnly:
            guard executionTarget == nil,
                  exactExecutions.isEmpty else { return false }
            switch authorization.requirement {
            case .nonconsequentialPlan:
                return exactPlans.isEmpty
            case .consequentialPlan:
                return exactPlans.count == 1
            case .consequentialExecution:
                return false
            }
        case .executeWhitelisted:
            guard authorization.requirement == .consequentialExecution,
                  exactPlans.isEmpty,
                  exactExecutions.count == 1,
                  let executionTarget,
                  executionTarget.isAuthorized(
                      for: requestedCapability
                  ) else { return false }
            let confirmation = exactExecutions[0]
            return confirmation.exactInstruction == executionInstruction
                && confirmation.executionTarget == executionTarget
                && confirmation.requestedCapability == requestedCapability
                && confirmation.source == source
                && confirmation.workCorrelationID == work.correlationID
        }
    }

    var intent: AceHQDispatchIntent {
        AceHQDispatchIntent(
            source: source,
            work: work,
            exactOwnerTranscript: exactOwnerTranscript,
            resolvedRequest: resolvedRequest,
            executionInstruction: executionInstruction,
            correctionContext: correctionContext,
            requestedCapability: requestedCapability,
            executionTarget: executionTarget,
            authorization: authorization,
            verificationRequest: verificationRequest
        )
    }

    func canonicalPrompt() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let prompt = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: [], debugDescription: "dispatch envelope is not UTF-8")
            )
        }
        return prompt
    }
}

struct AceHQAgentAssessment: Codable, Equatable, Sendable {
    let operationalStatus: String

    private enum CodingKeys: String, CodingKey {
        case operationalStatus = "operational_status"
    }
}

struct AceHQAgentRecord: Codable, Equatable, Sendable {
    let id: String
    let sourceKind: String
    let lifecycle: String
    let capabilities: [String]
    let assessment: AceHQAgentAssessment

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceKind = "source_kind"
        case lifecycle
        case capabilities
        case assessment
    }
}

struct AceHQCapabilityRecord: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let owner: String
    let status: String
}

struct AceHQProviderRecord: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let state: String
    let capabilities: [String]
}

struct AceHQDispatchRegistry: Equatable, Sendable {
    let agents: [AceHQAgentRecord]
    let capabilities: [AceHQCapabilityRecord]
    let providers: [AceHQProviderRecord]
}

struct AceHQSeatMapping: Equatable, Sendable {
    let routes: [AceHQRequestedCapability: [String]]
}

enum AceHQSeatSelectionError: Error, Equatable, Sendable {
    case unmappedCapability(AceHQRequestedCapability)
    case noEligibleActiveSeat(AceHQRequestedCapability)
}

enum AceHQSeatSelector {
    static func select(
        capability requestedCapability: AceHQRequestedCapability,
        mapping: AceHQSeatMapping,
        registry: AceHQDispatchRegistry
    ) throws -> AceHQSelectedSeat {
        guard let candidates = mapping.routes[requestedCapability], !candidates.isEmpty else {
            throw AceHQSeatSelectionError.unmappedCapability(requestedCapability)
        }

        var visited = Set<String>()
        for seatID in candidates where visited.insert(seatID).inserted {
            guard let agent = registry.agents.first(where: { $0.id == seatID }),
                  agent.sourceKind == "canonical",
                  agent.lifecycle == "active",
                  agent.assessment.operationalStatus == "active",
                  agent.capabilities.contains("runtime:\(seatID)"),
                  agent.capabilities.contains("dispatch:\(seatID)"),
                  registry.capabilities.contains(where: {
                      $0.id == "runtime:\(seatID)"
                          && $0.kind == "agent_runtime"
                          && $0.owner == seatID
                          && $0.status == "healthy"
                  }),
                  registry.capabilities.contains(where: {
                      $0.id == "dispatch:\(seatID)"
                          && $0.kind == "dispatch"
                          && $0.owner == seatID
                          && $0.status == "configured"
                  }) else {
                continue
            }

            let providerID = "agent:\(seatID)"
            guard registry.providers.contains(where: {
                $0.id == providerID
                    && $0.kind == "named_agent"
                    && $0.state == "available"
                    && $0.capabilities.contains("sessions.create")
                    && $0.capabilities.contains("events.stream")
            }) else {
                continue
            }
            return AceHQSelectedSeat(seatID: seatID, providerID: providerID)
        }

        throw AceHQSeatSelectionError.noEligibleActiveSeat(requestedCapability)
    }
}

enum AceHQAcknowledgementState: String, Codable, Equatable, Sendable {
    case queued
    case running
}

struct AceHQDispatchAcknowledgements: Codable, Equatable, Sendable {
    let session: AceHQAcknowledgementState
    let turn: AceHQAcknowledgementState
    let sessionIdempotentReplay: Bool
    let turnIdempotentReplay: Bool

    private enum CodingKeys: String, CodingKey {
        case session
        case turn
        case sessionIdempotentReplay = "session_idempotent_replay"
        case turnIdempotentReplay = "turn_idempotent_replay"
    }
}

struct AceHQPendingDispatch: Codable, Equatable, Sendable {
    let envelope: AceHQDispatchEnvelope
    let sessionID: String
    let acceptedEventID: String
    let nextEventSequence: Int
    let acknowledgements: AceHQDispatchAcknowledgements
    let executionID: String?
    let executionPhase: AceHQExecutionPhase?

    private enum CodingKeys: String, CodingKey {
        case envelope
        case sessionID = "session_id"
        case acceptedEventID = "accepted_event_id"
        case nextEventSequence = "next_event_sequence"
        case acknowledgements
        case executionID = "execution_id"
        case executionPhase = "execution_phase"
    }

    init(
        envelope: AceHQDispatchEnvelope,
        sessionID: String,
        acceptedEventID: String,
        nextEventSequence: Int,
        acknowledgements: AceHQDispatchAcknowledgements,
        executionID: String? = nil,
        executionPhase: AceHQExecutionPhase? = nil
    ) {
        self.envelope = envelope
        self.sessionID = sessionID
        self.acceptedEventID = acceptedEventID
        self.nextEventSequence = nextEventSequence
        self.acknowledgements = acknowledgements
        self.executionID = executionID
        self.executionPhase = executionPhase
    }

    var intent: AceHQDispatchIntent { envelope.intent }
    var isTerminal: Bool { false }

    func advancing(
        to sequence: Int,
        executionID: String? = nil,
        executionPhase: AceHQExecutionPhase? = nil
    ) -> AceHQPendingDispatch {
        AceHQPendingDispatch(
            envelope: envelope,
            sessionID: sessionID,
            acceptedEventID: acceptedEventID,
            nextEventSequence: sequence,
            acknowledgements: acknowledgements,
            executionID: executionID ?? self.executionID,
            executionPhase: executionPhase ?? self.executionPhase
        )
    }
}

enum AceHQTerminalOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
}

enum AceHQVerificationState: String, Codable, Equatable, Sendable {
    case reported
    case verified
}

enum AceHQExecutionPhase: String, Codable, Equatable, Sendable {
    case accepted
    case executing
    case progress
    case terminal
}

enum AceHQExecutionEvidenceKind: String, Codable, CaseIterable, Equatable, Sendable {
    case source
    case deploy
    case live
}

struct AceHQExecutionEvidence: Codable, Equatable, Sendable {
    let kind: AceHQExecutionEvidenceKind
    let reference: String
    let sha256: String?
    let observedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case kind
        case reference
        case sha256
        case observedAt = "observed_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(AceHQExecutionEvidenceKind.self, forKey: .kind)
        reference = try values.decode(String.self, forKey: .reference)
        sha256 = try values.decodeIfPresent(String.self, forKey: .sha256)
        if let timestamp = try values.decodeIfPresent(String.self, forKey: .observedAt) {
            guard let date = AceHQAuthorizationTimestamp.date(from: timestamp) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .observedAt,
                    in: values,
                    debugDescription: "observed_at is not an ISO-8601 timestamp"
                )
            }
            observedAt = date
        } else {
            observedAt = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(reference, forKey: .reference)
        try values.encodeIfPresent(sha256, forKey: .sha256)
        try values.encodeIfPresent(
            observedAt.map(AceHQAuthorizationTimestamp.string(from:)),
            forKey: .observedAt
        )
    }
}

struct AceHQExecutionReceipt: Codable, Equatable, Sendable {
    let executionID: String
    let phase: AceHQExecutionPhase
    let source: AceHQSourceTurnIdentity
    let work: AceHQWorkCorrelation
    let selectedSeat: AceHQSelectedSeat
    let executionTarget: AceHQExecutionTarget
    let outcome: AceHQTerminalOutcome?
    let verificationState: AceHQVerificationState?
    let evidence: [AceHQExecutionEvidence]
    let output: String?

    private enum CodingKeys: String, CodingKey {
        case executionID = "execution_id"
        case phase
        case source
        case work
        case selectedSeat = "selected_seat"
        case executionTarget = "execution_target"
        case outcome
        case verificationState = "verification_state"
        case evidence
        case output
    }
}

struct AceHQTerminalReceipt: Codable, Equatable, Sendable {
    let outcome: AceHQTerminalOutcome
    let verificationState: AceHQVerificationState
    let source: AceHQSourceTurnIdentity
    let work: AceHQWorkCorrelation
    let selectedSeat: AceHQSelectedSeat
    let sessionID: String
    let acceptedEventID: String
    let terminalEventID: String
    let terminalSequence: Int
    let providerEventID: String?
    let output: String
    let executionID: String?
    let executionTarget: AceHQExecutionTarget?
    let evidence: [AceHQExecutionEvidence]

    private enum CodingKeys: String, CodingKey {
        case outcome
        case verificationState = "verification_state"
        case source
        case work
        case selectedSeat = "selected_seat"
        case sessionID = "session_id"
        case acceptedEventID = "accepted_event_id"
        case terminalEventID = "terminal_event_id"
        case terminalSequence = "terminal_sequence"
        case providerEventID = "provider_event_id"
        case output
        case executionID = "execution_id"
        case executionTarget = "execution_target"
        case evidence
    }

    init(
        outcome: AceHQTerminalOutcome,
        verificationState: AceHQVerificationState,
        source: AceHQSourceTurnIdentity,
        work: AceHQWorkCorrelation,
        selectedSeat: AceHQSelectedSeat,
        sessionID: String,
        acceptedEventID: String,
        terminalEventID: String,
        terminalSequence: Int,
        providerEventID: String?,
        output: String,
        executionID: String? = nil,
        executionTarget: AceHQExecutionTarget? = nil,
        evidence: [AceHQExecutionEvidence] = []
    ) {
        self.outcome = outcome
        self.verificationState = verificationState
        self.source = source
        self.work = work
        self.selectedSeat = selectedSeat
        self.sessionID = sessionID
        self.acceptedEventID = acceptedEventID
        self.terminalEventID = terminalEventID
        self.terminalSequence = terminalSequence
        self.providerEventID = providerEventID
        self.output = output
        self.executionID = executionID
        self.executionTarget = executionTarget
        self.evidence = evidence
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try values.decode(AceHQTerminalOutcome.self, forKey: .outcome)
        verificationState = try values.decode(AceHQVerificationState.self, forKey: .verificationState)
        source = try values.decode(AceHQSourceTurnIdentity.self, forKey: .source)
        work = try values.decode(AceHQWorkCorrelation.self, forKey: .work)
        selectedSeat = try values.decode(AceHQSelectedSeat.self, forKey: .selectedSeat)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        acceptedEventID = try values.decode(String.self, forKey: .acceptedEventID)
        terminalEventID = try values.decode(String.self, forKey: .terminalEventID)
        terminalSequence = try values.decode(Int.self, forKey: .terminalSequence)
        providerEventID = try values.decodeIfPresent(String.self, forKey: .providerEventID)
        output = try values.decode(String.self, forKey: .output)
        executionID = try values.decodeIfPresent(String.self, forKey: .executionID)
        executionTarget = try values.decodeIfPresent(AceHQExecutionTarget.self, forKey: .executionTarget)
        evidence = try values.decodeIfPresent(
            [AceHQExecutionEvidence].self,
            forKey: .evidence
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(outcome, forKey: .outcome)
        try values.encode(verificationState, forKey: .verificationState)
        try values.encode(source, forKey: .source)
        try values.encode(work, forKey: .work)
        try values.encode(selectedSeat, forKey: .selectedSeat)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(acceptedEventID, forKey: .acceptedEventID)
        try values.encode(terminalEventID, forKey: .terminalEventID)
        try values.encode(terminalSequence, forKey: .terminalSequence)
        try values.encodeIfPresent(providerEventID, forKey: .providerEventID)
        try values.encode(output, forKey: .output)
        try values.encodeIfPresent(executionID, forKey: .executionID)
        try values.encodeIfPresent(executionTarget, forKey: .executionTarget)
        if !evidence.isEmpty {
            try values.encode(evidence, forKey: .evidence)
        }
    }
}

enum AceHQDispatchBlockCode: String, Codable, Equatable, Sendable {
    case hqUnavailable = "hq_unavailable"
    case hqRejected = "hq_rejected"
    case malformedResponse = "malformed_response"
    case invalidRequest = "invalid_request"
    case unmappedCapability = "unmapped_capability"
    case noEligibleActiveSeat = "no_eligible_active_seat"
    case receiptMismatch = "receipt_mismatch"
}

struct AceHQBlockedReceipt: Codable, Equatable, Sendable {
    let code: AceHQDispatchBlockCode
    let message: String
    let retryable: Bool
    let request: AceHQDispatchIntent
    let selectedSeat: AceHQSelectedSeat?

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case retryable
        case request
        case selectedSeat = "selected_seat"
    }
}

enum AceHQDispatchStartResult: Equatable, Sendable {
    case accepted(AceHQPendingDispatch)
    case blocked(AceHQBlockedReceipt)
}

enum AceHQDispatchReconciliation: Equatable, Sendable {
    case running(AceHQPendingDispatch)
    case succeeded(AceHQTerminalReceipt)
    case failed(AceHQTerminalReceipt)
    case blocked(AceHQBlockedReceipt)
}

enum AceHQClientConfigurationError: Error, Equatable, Sendable {
    case nonLoopbackEndpoint
}
