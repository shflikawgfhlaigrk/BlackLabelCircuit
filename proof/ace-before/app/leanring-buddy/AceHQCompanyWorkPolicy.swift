import Foundation

/// App-owned admission for spoken Black Label company work. The model may
/// describe work, but it never chooses a seat or supplies an executable HQ
/// envelope.
nonisolated enum AceHQCompanyWorkPolicy {
    static let seatMapping = AceHQSeatMapping(routes: Dictionary(
        uniqueKeysWithValues: AceHQRequestedCapability.allCases.map {
            ($0, $0.authorizedSeatIDs)
        }
    ))

    /// Prefer the app-resolved owner work for a specific capability, while
    /// retaining an anchored explicit-agent command as bounded HQ admission
    /// when the referenced prior wording is otherwise generic.
    static func capability(
        for request: ContextualOwnerRequest
    ) -> AceHQRequestedCapability? {
        capability(for: request.resolvedRequest)
            ?? capability(for: request.originalOwnerTranscript)
    }

    static func capability(
        for request: String
    ) -> AceHQRequestedCapability? {
        let text = normalized(request)
        if text.contains("the agent"),
           isNegatedHistoricalOrQuestionAgentPhrase(text) {
            return nil
        }
        guard !isGenericQuestionOrHistory(text),
              !isHistoricalCompletionPhrase(text) else { return nil }
        guard !["tell me ", "explain ", "what is ", "what are ", "how does "]
            .contains(where: { text.hasPrefix($0) }) else {
            return nil
        }
        if isAnchoredSingularAgentInstruction(text) {
            return .companyCoordination
        }
        guard containsCompanyWorkAction(text) else { return nil }

        if containsAny(text, [
            "website", "web site", "homepage", "storefront",
            "ace-bl.tech", "blacklabelbots.com",
        ]) {
            return .websiteProduction
        }
        if containsAny(text, [
            "qa", "quality assurance", "verify", "verification", "test",
            "audit", "regression", "clean install",
        ]) && containsAny(text, productTerms) {
            return .qualityAssurance
        }
        if containsAny(text, [
            "release", "notarize", "notarise", "code sign", "codesign",
            "dmg", "pkg", "app store submission", "ship the build",
            "clean mac install",
        ]) && containsAny(text, [
            "package", "build", "ship", "release", "notarize", "notarise",
            "sign", "submit", "install", "deliver",
        ]) {
            return .releaseBuild
        }
        if containsAny(text, ["team", "company", "agents", "agent team"]),
           containsAny(text, [
               "task", "assign", "coordinate", "run", "dispatch", "organize",
               "organise", "have", "get",
           ]) {
            return .companyCoordination
        }
        if containsAny(text, productTerms),
           containsAny(text, [
               "fix", "build", "implement", "change", "update", "repair",
               "correct", "add", "remove", "refactor", "make",
           ]) {
            return .appEngineering
        }
        return nil
    }

    static func isExactRetryRequest(_ request: String) -> Bool {
        switch normalized(request) {
        case "retry that", "retry it", "try that again", "try it again",
             "retry the last company task", "retry the company task":
            return true
        default:
            return false
        }
    }

    /// Converts admitted owner work to one app-owned canonical identity. An
    /// arbitrary path, URL, title, repository name, or model-selected target
    /// is never accepted as execution authority.
    static func executionTarget(
        for request: ContextualOwnerRequest,
        capability: AceHQRequestedCapability
    ) -> AceHQExecutionTarget? {
        executionTarget(
            for: request.resolvedRequest,
            capability: capability
        ) ?? executionTarget(
            for: request.originalOwnerTranscript,
            capability: capability
        )
    }

    static func makeExecutableIntent(
        request: ContextualOwnerRequest,
        capability: AceHQRequestedCapability,
        durableConsent: AceHQDurableCapabilityConsent,
        consentValidatedAt: Date,
        exactExecutionConfirmedAt: Date
    ) -> AceHQDispatchIntent? {
        guard exactExecutionConfirmedAt == consentValidatedAt,
              let target = executionTarget(
                  for: request,
                  capability: capability
              ) else {
            return nil
        }
        let base = makeIntent(
            request: request,
            capability: capability,
            authorizationRequirement: .nonconsequentialPlan,
            durableConsent: durableConsent,
            consentValidatedAt: consentValidatedAt,
            exactPlanConfirmedAt: nil
        )
        let confirmationMilliseconds = Int64(
            (exactExecutionConfirmedAt.timeIntervalSince1970 * 1_000)
                .rounded(.down)
        )
        let executionConfirmation = AceHQAuthorizationEvidence
            .exactExecutionConfirmation(
                AceHQExactExecutionConfirmationEvidence(
                    evidenceID:
                        "ace-exact-execution-confirmation-\(base.source.correlationID)-\(confirmationMilliseconds)",
                    exactInstruction: base.executionInstruction,
                    executionTarget: target,
                    requestedCapability: capability,
                    source: base.source,
                    workCorrelationID: base.work.correlationID,
                    confirmedAt: exactExecutionConfirmedAt
                )
            )
        return AceHQDispatchIntent(
            source: base.source,
            work: base.work,
            exactOwnerTranscript: base.exactOwnerTranscript,
            resolvedRequest: base.resolvedRequest,
            executionInstruction: base.executionInstruction,
            correctionContext: base.correctionContext,
            requestedCapability: base.requestedCapability,
            executionTarget: target,
            authorization: AceHQAuthorizationBundle(
                requirement: .consequentialExecution,
                evidence: base.authorization.evidence
                    + [executionConfirmation]
            ),
            verificationRequest: base.verificationRequest
        )
    }

    static func makeIntent(
        request: ContextualOwnerRequest,
        capability: AceHQRequestedCapability,
        authorizationRequirement: AceHQAuthorizationRequirement,
        durableConsent: AceHQDurableCapabilityConsent,
        consentValidatedAt: Date,
        exactPlanConfirmedAt: Date?
    ) -> AceHQDispatchIntent {
        let sourceCorrelation = request.sourceCorrelationIdentifier
            .uuidString.lowercased()
        let source = AceHQSourceTurnIdentity(
            sessionID: request.sourceSessionIdentifier
                .uuidString.lowercased(),
            turnID: request.sourceTurnIdentifier.uuidString.lowercased(),
            correlationID: sourceCorrelation
        )
        let work = AceHQWorkCorrelation(
            correlationID: request.childWorkCorrelationIdentifier
                .uuidString.lowercased(),
            parentCorrelationID:
                request.parentWorkCorrelationIdentifier?
                    .uuidString.lowercased(),
            hqWorkID: nil
        )
        let correctionContext = request.correctionContext.map {
            AceHQCorrectionContext(
                kind: $0.kind == .retry ? .retry : .amendment,
                ownerCorrection: $0.ownerCorrection,
                priorTerminalOutcome: $0.priorTerminalOutcome,
                priorTerminalVerification:
                    $0.priorTerminalVerification,
                priorTerminalReason: $0.priorTerminalReason
            )
        }
        let executionInstruction = correctionContext?
            .executionInstruction(objective: request.resolvedRequest)
            ?? request.resolvedRequest
        let validationMilliseconds = Int64(
            (consentValidatedAt.timeIntervalSince1970 * 1_000)
                .rounded(.down)
        )
        var authorizationEvidence: [AceHQAuthorizationEvidence] = [
            .capabilityConsent(AceHQCapabilityConsentEvidence(
                evidenceID:
                    "ace-capability-consent-\(sourceCorrelation)-\(validationMilliseconds)",
                receiptReference: durableConsent.receiptReference,
                receiptSchemaVersion: durableConsent.receiptSchemaVersion,
                approvedScopes: durableConsent.approvedScopes.sorted(),
                approvedWorkspaceRoots:
                    durableConsent.approvedWorkspaceRoots.sorted(),
                approvedAt: durableConsent.approvedAt,
                validatedAt: consentValidatedAt,
                source: source,
                workCorrelationID: work.correlationID
            )),
        ]
        if let exactPlanConfirmedAt {
            let confirmationMilliseconds = Int64(
                (exactPlanConfirmedAt.timeIntervalSince1970 * 1_000)
                    .rounded(.down)
            )
            authorizationEvidence.append(
                .exactPlanConfirmation(
                    AceHQExactPlanConfirmationEvidence(
                        evidenceID:
                            "ace-exact-plan-confirmation-\(sourceCorrelation)-\(confirmationMilliseconds)",
                        exactPlan: executionInstruction,
                        requestedCapability: capability,
                        source: source,
                        workCorrelationID: work.correlationID,
                        confirmedAt: exactPlanConfirmedAt
                    )
                )
            )
        }
        return AceHQDispatchIntent(
            source: source,
            work: work,
            exactOwnerTranscript: request.originalOwnerTranscript,
            resolvedRequest: request.resolvedRequest,
            executionInstruction: executionInstruction,
            correctionContext: correctionContext,
            requestedCapability: capability,
            authorization: AceHQAuthorizationBundle(
                requirement: authorizationRequirement,
                evidence: authorizationEvidence
            ),
            verificationRequest: AceHQVerificationRequest(
                required: true,
                acceptanceCriteria: acceptanceCriteria(for: capability),
                verifierSeatID: nil
            )
        )
    }

    private static let productTerms = [
        "ace", "sovereign", "leads", "trading", "homefront", "home front",
        "real estate", "marketing app", "black label app", "mac app",
    ]

    private static func executionTarget(
        for request: String,
        capability: AceHQRequestedCapability
    ) -> AceHQExecutionTarget? {
        let text = normalized(request)
        let targetID: AceHQExecutionTargetID?
        switch capability {
        case .websiteProduction:
            let namesAceWebsite = containsAny(
                text,
                ["ace-bl.tech", "ace website", "ace site"]
            )
            let namesBlackLabelWebsite = containsAny(text, [
                "blacklabelbots.com", "black label website",
                "black label site", "black label storefront",
            ])
            if namesAceWebsite && namesBlackLabelWebsite {
                targetID = nil
            } else if namesAceWebsite {
                targetID = .aceWebsite
            } else if namesBlackLabelWebsite {
                targetID = .blackLabelWebsite
            } else {
                targetID = nil
            }
        case .releaseBuild, .appEngineering, .qualityAssurance:
            let matches: [AceHQExecutionTargetID] = [
                containsAny(text, ["real estate", "realestate"])
                    ? .realEstateProduct : nil,
                text.contains("sovereign") ? .sovereignProduct : nil,
                containsAny(text, ["homefront", "home front"])
                    ? .homefrontProduct : nil,
                text.contains("trading") ? .tradingProduct : nil,
                text.contains("leads") ? .leadsProduct : nil,
                text.contains("marketing app") ? .marketingProduct : nil,
                text.contains("ace") ? .aceProduct : nil,
            ].compactMap { $0 }
            targetID = matches.count == 1 ? matches[0] : nil
        case .companyCoordination:
            targetID = containsAny(text, [
                "black label", "company", "team", "agents", "agent team",
            ]) ? .blackLabelCompany : nil
        }
        guard let targetID,
              hasOnlyCanonicalExecutionLocators(
                  request,
                  targetID: targetID
              ) else { return nil }
        return AceHQExecutionTarget(
            kind: .canonicalResource,
            id: targetID
        )
    }

    private static func hasOnlyCanonicalExecutionLocators(
        _ request: String,
        targetID: AceHQExecutionTargetID
    ) -> Bool {
        if request.range(
            of: #"(?:^|\s)/(?:Users|tmp|private|var|etc|Applications|Volumes)(?:/|\s|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil || containsAny(normalized(request), [
            "working directory", "current directory", "cwd",
        ]) {
            return false
        }
        let allowedHost: String?
        switch targetID {
        case .aceWebsite: allowedHost = "ace-bl.tech"
        case .blackLabelWebsite: allowedHost = "blacklabelbots.com"
        default: allowedHost = nil
        }
        guard let expression = try? NSRegularExpression(
            pattern: #"https?://[^\s]+"#,
            options: [.caseInsensitive]
        ) else { return false }
        let range = NSRange(request.startIndex..., in: request)
        let urls = expression.matches(in: request, range: range).compactMap {
            Range($0.range, in: request).map { String(request[$0]) }
        }
        return urls.allSatisfy { rawURL in
            guard let allowedHost,
                  let components = URLComponents(string: rawURL),
                  components.user == nil,
                  components.password == nil,
                  components.host?.lowercased() == allowedHost else {
                return false
            }
            return true
        }
    }

    private static let singularAgentInstructionPattern =
        #"^(?:please )?(?:task|assign|ask|request|have) the agent(?: (?:to )?.+)?$"#

    private static let nonInstructionAgentPrefixPattern =
        #"^(?:(?:please )?(?:do not|don t|never)|(?:i|we|you|he|she|they) (?:do not|don t|did not|didn t|never|asked|assigned|tasked|requested|had)|(?:did|why|what|when|where|who|how|is|are|was|were|should|would|could|can)\b)"#

    private static let genericQuestionOrHistoryPattern =
        #"^(?:did|why|what|when|where|who|how|is|are|was|were|should|would|could|can)\b"#

    private static func isNegatedHistoricalOrQuestionAgentPhrase(
        _ text: String
    ) -> Bool {
        text.range(
            of: nonInstructionAgentPrefixPattern,
            options: .regularExpression
        ) != nil
    }

    private static func isGenericQuestionOrHistory(_ text: String) -> Bool {
        text.range(
            of: genericQuestionOrHistoryPattern,
            options: .regularExpression
        ) != nil
    }

    private static func isHistoricalCompletionPhrase(_ text: String) -> Bool {
        guard text.range(
            of: #"^(?:i|we|you|he|she|they)\s+(?:already\s+)?"#,
            options: .regularExpression
        ) != nil else {
            return false
        }
        return text.range(
            of: #"\b(?:fixed|built|implemented|changed|updated|repaired|corrected|added|removed|refactored|made|deployed|published|packaged|shipped|released|notarized|signed|submitted|verified|tested|audited|assigned|tasked|coordinated|dispatched|ran)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func isAnchoredSingularAgentInstruction(
        _ text: String
    ) -> Bool {
        text.range(
            of: singularAgentInstructionPattern,
            options: .regularExpression
        ) != nil
    }

    private static func containsCompanyWorkAction(_ text: String) -> Bool {
        text.range(
            of: #"\b(?:fix|fixed|build|built|implement|implemented|change|changed|update|updated|repair|repaired|correct|corrected|clean up|add|added|remove|removed|refactor|refactored|make|made|deploy|deployed|publish|published|package|packaged|ship|shipped|release|released|notarize|notarized|notarise|notarised|sign|signed|submit|submitted|verify|verified|test|tested|audit|audited|task|tasked|assign|assigned|coordinate|coordinated|dispatch|dispatched|run|ran)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func acceptanceCriteria(
        for capability: AceHQRequestedCapability
    ) -> [String] {
        switch capability {
        case .websiteProduction:
            return ["Report the changed site artifact and live verification state."]
        case .releaseBuild:
            return ["Report the exact artifact identity and release verification state."]
        case .appEngineering:
            return ["Report the source change and focused verification result."]
        case .qualityAssurance:
            return ["Report a reproducible pass or fail receipt with evidence."]
        case .companyCoordination:
            return ["Report the canonical assignment and accountable seat."]
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9.$ -]+",
                with: " ",
                options: .regularExpression
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func containsAny(
        _ text: String,
        _ candidates: [String]
    ) -> Bool {
        candidates.contains { text.contains($0) }
    }
}
