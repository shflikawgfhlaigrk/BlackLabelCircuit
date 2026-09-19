import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol AceHQHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct AceHQURLSessionTransport: AceHQHTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(
            configuration: configuration,
            delegate: AceHQLoopbackRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AceHQClientFailure.malformed("HQ returned a non-HTTP response")
        }
        return (data, httpResponse)
    }
}

struct AceHQDispatchClient: Sendable {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8791")!

    private let baseURL: URL
    private let transport: any AceHQHTTPTransport
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL = AceHQDispatchClient.defaultBaseURL,
        transport: any AceHQHTTPTransport = AceHQURLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard Self.isLoopbackHTTPBaseURL(baseURL) else {
            throw AceHQClientConfigurationError.nonLoopbackEndpoint
        }
        self.baseURL = baseURL
        self.transport = transport
        self.now = now
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func start(
        _ intent: AceHQDispatchIntent,
        mapping: AceHQSeatMapping
    ) async -> AceHQDispatchStartResult {
        var selectedSeat: AceHQSelectedSeat?
        do {
            try validate(intent, at: now())
            try validate(
                mapping: mapping,
                capability: intent.requestedCapability
            )
            let registry = try await fetchRegistry()
            do {
                selectedSeat = try AceHQSeatSelector.select(
                    capability: intent.requestedCapability,
                    mapping: mapping,
                    registry: registry
                )
            } catch let error as AceHQSeatSelectionError {
                switch error {
                case .unmappedCapability:
                    return .blocked(blocked(
                        code: .unmappedCapability,
                        message: "No configured HQ seat mapping exists for \(intent.requestedCapability.rawValue).",
                        retryable: false,
                        intent: intent,
                        selectedSeat: nil
                    ))
                case .noEligibleActiveSeat:
                    return .blocked(blocked(
                        code: .noEligibleActiveSeat,
                        message: "No mapped canonical HQ seat is currently active, routed, and provider-ready.",
                        retryable: true,
                        intent: intent,
                        selectedSeat: nil
                    ))
                }
            }

            guard let selectedSeat else {
                throw AceHQClientFailure.mismatch("HQ seat selection did not produce a bound seat")
            }
            let envelope = intent.bound(to: selectedSeat)
            guard envelope.sessionIdempotencyKey.count <= 512,
                  envelope.turnIdempotencyKey.count <= 512 else {
                throw AceHQClientFailure.invalidRequest("Ace dispatch identity exceeds HQ's idempotency-key limit")
            }
            let prompt = try envelope.canonicalPrompt()
            let title = String(intent.resolvedRequest.prefix(240))

            let createInput = AceHQCreateSessionInput(
                providerID: selectedSeat.providerID,
                agentID: selectedSeat.seatID,
                workID: intent.work.hqWorkID,
                title: title,
                idempotencyKey: envelope.sessionIdempotencyKey
            )
            let create: AceHQCreateSessionResponse = try await send(
                method: "POST",
                pathComponents: ["api", "ai", "sessions"],
                body: try encoder.encode(createInput)
            )
            try validate(
                session: create.session,
                expectedSessionID: nil,
                envelope: envelope,
                allowedStatuses: ["waiting", "queued", "running"]
            )
            let sessionAcknowledgement = acknowledgement(for: create.session.status)

            let executionAuthorizationTicket: String?
            switch envelope.authority {
            case .planOnly:
                executionAuthorizationTicket = nil
            case .executeWhitelisted:
                guard let executionTarget = envelope.executionTarget else {
                    throw AceHQClientFailure.invalidRequest(
                        "Ace executable envelope omitted its canonical target"
                    )
                }
                let envelopeDigest = SHA256.hash(
                    data: Data(prompt.utf8)
                ).map { String(format: "%02x", $0) }.joined()
                let authorizationInput =
                    AceHQExecutionAuthorizationInput(
                        schemaVersion: 1,
                        envelopeDigest: envelopeDigest,
                        source: envelope.source,
                        work: envelope.work,
                        requestedCapability:
                            envelope.requestedCapability,
                        executionTarget: executionTarget,
                        selectedSeat: envelope.selectedSeat
                    )
                let authorization:
                    AceHQExecutionAuthorizationResponse = try await send(
                        method: "POST",
                        pathComponents: [
                            "api", "ai", "execution-authorizations",
                        ],
                        body: try encoder.encode(authorizationInput),
                        acceptedStatusCodes: [201]
                    )
                executionAuthorizationTicket = try validatedTicket(
                    authorization,
                    at: now()
                )
            }

            let turnInput = AceHQSendTurnInput(
                prompt: prompt,
                idempotencyKey: envelope.turnIdempotencyKey,
                executionAuthorizationTicket:
                    executionAuthorizationTicket
            )
            let turn: AceHQSendTurnResponse = try await send(
                method: "POST",
                pathComponents: ["api", "ai", "sessions", create.session.id, "turns"],
                body: try encoder.encode(turnInput)
            )
            guard turn.accepted else {
                throw AceHQClientFailure.mismatch("HQ did not accept the correlated Ace turn")
            }
            try validate(
                session: turn.session,
                expectedSessionID: create.session.id,
                envelope: envelope,
                allowedStatuses: ["waiting", "queued", "running"]
            )
            guard turn.event.sessionID == create.session.id,
                  turn.event.type == "turn.accepted",
                  turn.event.role == "user",
                  turn.event.content == prompt,
                  turn.event.sequence > 0,
                  !turn.event.id.isEmpty else {
                throw AceHQClientFailure.mismatch("HQ turn acknowledgement changed the session, prompt, role, or event identity")
            }

            let acknowledgements = AceHQDispatchAcknowledgements(
                session: sessionAcknowledgement,
                turn: acknowledgement(for: turn.session.status),
                sessionIdempotentReplay: create.idempotentReplay,
                turnIdempotentReplay: turn.idempotentReplay
            )
            return .accepted(AceHQPendingDispatch(
                envelope: envelope,
                sessionID: create.session.id,
                acceptedEventID: turn.event.id,
                nextEventSequence: turn.event.sequence,
                acknowledgements: acknowledgements
            ))
        } catch {
            return .blocked(blocked(for: error, intent: intent, selectedSeat: selectedSeat))
        }
    }

    func reconcile(
        _ pending: AceHQPendingDispatch,
        pageLimit: Int = 100
    ) async -> AceHQDispatchReconciliation {
        guard (1...1000).contains(pageLimit) else {
            return .blocked(blocked(
                code: .receiptMismatch,
                message: "HQ event page limit is outside the accepted range.",
                retryable: false,
                intent: pending.intent,
                selectedSeat: pending.envelope.selectedSeat
            ))
        }

        do {
            var cursor = pending.nextEventSequence
            var pageCount = 0
            var observedExecutionID = pending.executionID
            var observedExecutionPhase = pending.executionPhase
            while pageCount < 1_000 {
                pageCount += 1
                let page: AceHQEventsResponse = try await send(
                    method: "GET",
                    pathComponents: ["api", "ai", "sessions", pending.sessionID, "events"],
                    queryItems: [
                        URLQueryItem(name: "after", value: String(cursor)),
                        URLQueryItem(name: "limit", value: String(pageLimit)),
                    ]
                )
                guard page.cursor.after == cursor,
                      page.cursor.limit == pageLimit,
                      page.next == page.cursor.next else {
                    throw AceHQClientFailure.mismatch("HQ event cursor does not match the requested Ace receipt cursor")
                }

                var expectedSequence = cursor + 1
                var terminal: AceHQEventRecord?
                for event in page.events {
                    guard event.sessionID == pending.sessionID,
                          event.sequence == expectedSequence else {
                        throw AceHQClientFailure.mismatch("HQ returned a stale, skipped, or wrong-session receipt event")
                    }
                    expectedSequence += 1
                    if pending.envelope.authority == .executeWhitelisted,
                       event.type.hasPrefix("execution.") {
                        let executionState = try validateExecutionEvent(
                            event,
                            pending: pending,
                            currentExecutionID: observedExecutionID,
                            currentPhase: observedExecutionPhase
                        )
                        observedExecutionID = executionState.id
                        observedExecutionPhase = executionState.phase
                    }
                    let isTerminal: Bool
                    switch pending.envelope.authority {
                    case .planOnly:
                        isTerminal = event.type == "assistant.completed"
                            || event.type == "provider.failed"
                    case .executeWhitelisted:
                        isTerminal = event.type == "execution.terminal"
                    }
                    if isTerminal {
                        guard terminal == nil else {
                            throw AceHQClientFailure.mismatch("HQ returned more than one terminal event for one Ace turn")
                        }
                        terminal = event
                    }
                }

                let observedNext = page.events.last?.sequence ?? cursor
                guard page.next == observedNext else {
                    throw AceHQClientFailure.mismatch("HQ event cursor advanced without matching receipt events")
                }
                if let terminal {
                    guard !page.cursor.hasMore,
                          terminal.id == page.events.last?.id else {
                        throw AceHQClientFailure.mismatch("HQ terminal receipt is incomplete or followed by unrelated work")
                    }
                    if pending.envelope.authority == .executeWhitelisted {
                        guard observedExecutionID
                                == terminal.executionReceipt?
                                    .executionID,
                              observedExecutionPhase == .terminal else {
                            throw AceHQClientFailure.mismatch(
                                "HQ execution terminal was not the final typed lifecycle state"
                            )
                        }
                        return try terminalExecutionResult(
                            terminal,
                            pending: pending
                        )
                    }
                    guard let output = terminal.content, !output.isEmpty else {
                        throw AceHQClientFailure.mismatch("HQ planning terminal receipt has no output")
                    }
                    let outcome: AceHQTerminalOutcome
                    switch terminal.type {
                    case "assistant.completed":
                        guard terminal.role == "assistant" else {
                            throw AceHQClientFailure.mismatch("HQ success receipt has the wrong role")
                        }
                        outcome = .succeeded
                    case "provider.failed":
                        guard terminal.role == "system" else {
                            throw AceHQClientFailure.mismatch("HQ failure receipt has the wrong role")
                        }
                        outcome = .failed
                    default:
                        throw AceHQClientFailure.mismatch("HQ returned an unknown terminal receipt")
                    }
                    let receipt = AceHQTerminalReceipt(
                        outcome: outcome,
                        verificationState: .reported,
                        source: pending.envelope.source,
                        work: pending.envelope.work,
                        selectedSeat: pending.envelope.selectedSeat,
                        sessionID: pending.sessionID,
                        acceptedEventID: pending.acceptedEventID,
                        terminalEventID: terminal.id,
                        terminalSequence: terminal.sequence,
                        providerEventID: terminal.providerEventID,
                        output: output
                    )
                    return outcome == .succeeded ? .succeeded(receipt) : .failed(receipt)
                }

                cursor = page.next
                if !page.cursor.hasMore {
                    return .running(pending.advancing(
                        to: cursor,
                        executionID: observedExecutionID,
                        executionPhase: observedExecutionPhase
                    ))
                }
                guard !page.events.isEmpty else {
                    throw AceHQClientFailure.mismatch("HQ claimed more events without advancing the receipt cursor")
                }
            }
            throw AceHQClientFailure.mismatch("HQ event pagination exceeded the bounded reconciliation limit")
        } catch {
            return .blocked(blocked(
                for: error,
                intent: pending.intent,
                selectedSeat: pending.envelope.selectedSeat
            ))
        }
    }

    private func validateExecutionEvent(
        _ event: AceHQEventRecord,
        pending: AceHQPendingDispatch,
        currentExecutionID: String?,
        currentPhase: AceHQExecutionPhase?
    ) throws -> (id: String, phase: AceHQExecutionPhase) {
        guard event.role == "system",
              let receipt = event.executionReceipt,
              receipt.source == pending.envelope.source,
              receipt.work == pending.envelope.work,
              receipt.selectedSeat == pending.envelope.selectedSeat,
              receipt.executionTarget == pending.envelope.executionTarget,
              !receipt.executionID.isEmpty,
              receipt.executionID.count <= 512,
              currentExecutionID == nil
                || currentExecutionID == receipt.executionID else {
            throw AceHQClientFailure.mismatch(
                "HQ execution lifecycle changed its identity, target, seat, or correlation"
            )
        }
        let expectedPhase: AceHQExecutionPhase
        switch event.type {
        case "execution.accepted": expectedPhase = .accepted
        case "execution.executing": expectedPhase = .executing
        case "execution.progress": expectedPhase = .progress
        case "execution.terminal": expectedPhase = .terminal
        default:
            throw AceHQClientFailure.mismatch(
                "HQ returned an unknown typed execution lifecycle event"
            )
        }
        guard receipt.phase == expectedPhase else {
            throw AceHQClientFailure.mismatch(
                "HQ execution event type and receipt phase disagree"
            )
        }
        let validTransition: Bool
        switch (currentPhase, receipt.phase) {
        case (nil, .accepted):
            validTransition = true
        case (.accepted, .executing), (.accepted, .terminal):
            validTransition = true
        case (.executing, .progress), (.executing, .terminal):
            validTransition = true
        case (.progress, .progress), (.progress, .terminal):
            validTransition = true
        default:
            validTransition = false
        }
        guard validTransition else {
            throw AceHQClientFailure.mismatch(
                "HQ execution lifecycle skipped, repeated, or reversed a typed phase"
            )
        }
        if receipt.phase != .terminal {
            guard receipt.outcome == nil,
                  receipt.verificationState == nil,
                  receipt.evidence.isEmpty else {
                throw AceHQClientFailure.mismatch(
                    "Nonterminal HQ execution receipt claimed a terminal outcome or evidence"
                )
            }
        }
        return (receipt.executionID, receipt.phase)
    }

    private func terminalExecutionResult(
        _ event: AceHQEventRecord,
        pending: AceHQPendingDispatch
    ) throws -> AceHQDispatchReconciliation {
        guard event.type == "execution.terminal",
              event.role == "system",
              let execution = event.executionReceipt,
              execution.phase == .terminal,
              execution.source == pending.envelope.source,
              execution.work == pending.envelope.work,
              execution.selectedSeat == pending.envelope.selectedSeat,
              execution.executionTarget == pending.envelope.executionTarget,
              !execution.executionID.isEmpty,
              execution.executionID.count <= 512,
              let outcome = execution.outcome,
              let verificationState = execution.verificationState,
              let output = execution.output,
              !output.isEmpty else {
            throw AceHQClientFailure.mismatch(
                "HQ execution terminal changed identity or omitted its typed outcome"
            )
        }
        try validateExecutionEvidence(
            execution.evidence,
            outcome: outcome,
            verificationState: verificationState,
            target: execution.executionTarget
        )
        let receipt = AceHQTerminalReceipt(
            outcome: outcome,
            verificationState: verificationState,
            source: execution.source,
            work: execution.work,
            selectedSeat: execution.selectedSeat,
            sessionID: pending.sessionID,
            acceptedEventID: pending.acceptedEventID,
            terminalEventID: event.id,
            terminalSequence: event.sequence,
            providerEventID: event.providerEventID,
            output: output,
            executionID: execution.executionID,
            executionTarget: execution.executionTarget,
            evidence: execution.evidence
        )
        return outcome == .succeeded ? .succeeded(receipt) : .failed(receipt)
    }

    private func validateExecutionEvidence(
        _ evidence: [AceHQExecutionEvidence],
        outcome: AceHQTerminalOutcome,
        verificationState: AceHQVerificationState,
        target: AceHQExecutionTarget
    ) throws {
        guard evidence.allSatisfy({
            !$0.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.reference.count <= 4_096
        }) else {
            throw AceHQClientFailure.mismatch(
                "HQ execution receipt contains invalid evidence references"
            )
        }
        if outcome == .succeeded {
            let kinds = evidence.map(\.kind)
            let expected = Set(AceHQExecutionEvidenceKind.allCases)
            let sourceEvidence = evidence.first { $0.kind == .source }
            let deployEvidence = evidence.first { $0.kind == .deploy }
            guard verificationState == .verified,
                  evidence.count == expected.count,
                  Set(kinds) == expected,
                  sourceEvidence?.reference.hasPrefix("git:") == true,
                  deployEvidence?.reference.hasPrefix("cloudflare:")
                    == true,
                  evidence.allSatisfy({ item in
                      switch item.kind {
                      case .source, .deploy:
                          return item.observedAt == nil
                              && item.sha256?.range(
                                  of: #"^[a-f0-9]{64}$"#,
                                  options: .regularExpression
                              ) != nil
                      case .live:
                          guard item.sha256 == nil,
                                item.observedAt != nil else { return false }
                          let requiredHost: String?
                          switch target.id {
                          case .aceWebsite:
                              requiredHost = "ace-bl.tech"
                          case .blackLabelWebsite:
                              requiredHost = "blacklabelbots.com"
                          default:
                              requiredHost = nil
                          }
                          guard let requiredHost else { return true }
                          guard let components = URLComponents(
                              string: item.reference
                          ) else { return false }
                          return components.scheme?.lowercased() == "https"
                              && components.user == nil
                              && components.password == nil
                              && (components.port == nil
                                  || components.port == 443)
                              && components.host?.lowercased()
                                  == requiredHost
                      }
                  }) else {
                throw AceHQClientFailure.mismatch(
                    "HQ executable success lacks verified source, deploy, and live evidence"
                )
            }
        } else if verificationState == .verified {
            throw AceHQClientFailure.mismatch(
                "HQ execution failure cannot claim verified success state"
            )
        }
    }

    private func fetchRegistry() async throws -> AceHQDispatchRegistry {
        let agents: AceHQAgentsResponse = try await send(
            method: "GET",
            pathComponents: ["api", "agents"]
        )
        let capabilities: AceHQCapabilitiesResponse = try await send(
            method: "GET",
            pathComponents: ["api", "capabilities"]
        )
        let providers: AceHQProvidersResponse = try await send(
            method: "GET",
            pathComponents: ["api", "ai", "providers"]
        )
        return AceHQDispatchRegistry(
            agents: agents.agents,
            capabilities: capabilities.capabilities,
            providers: providers.providers
        )
    }

    private func send<Response: Decodable>(
        method: String,
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        acceptedStatusCodes: Set<Int>? = nil
    ) async throws -> Response {
        var url = baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        if !queryItems.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw AceHQClientFailure.malformed("HQ request URL could not be constructed")
            }
            components.queryItems = queryItems
            guard let queryURL = components.url else {
                throw AceHQClientFailure.malformed("HQ request query could not be constructed")
            }
            url = queryURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let failure as AceHQClientFailure {
            throw failure
        } catch {
            throw AceHQClientFailure.unavailable("Black Label HQ is unavailable on the local loopback endpoint")
        }

        guard let responseURL = response.url,
              Self.isLoopbackHTTPURL(responseURL) else {
            throw AceHQClientFailure.rejected("Black Label HQ attempted to leave the local loopback boundary")
        }
        let statusAccepted = acceptedStatusCodes?
            .contains(response.statusCode)
            ?? (200...299).contains(response.statusCode)
        guard statusAccepted else {
            if [502, 503, 504].contains(response.statusCode) {
                throw AceHQClientFailure.unavailable("Black Label HQ returned HTTP \(response.statusCode)")
            }
            throw AceHQClientFailure.rejected("Black Label HQ rejected the request with HTTP \(response.statusCode)")
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw AceHQClientFailure.malformed("Black Label HQ returned a malformed typed response")
        }
    }

    private func validate(
        _ intent: AceHQDispatchIntent,
        at validationTime: Date
    ) throws {
        let criteria = intent.verificationRequest.acceptanceCriteria
        guard Self.isCanonicalUUID(intent.source.sessionID),
              Self.isCanonicalUUID(intent.source.turnID),
              Self.isCanonicalUUID(intent.source.correlationID),
              Self.isCanonicalUUID(intent.work.correlationID),
              intent.work.parentCorrelationID.map(Self.isCanonicalUUID)
                ?? true,
              intent.work.hqWorkID.map(Self.isSafeIdentifier) ?? true,
              !intent.exactOwnerTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              intent.exactOwnerTranscript.count <= 200_000,
              !intent.resolvedRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              intent.resolvedRequest.count <= 200_000,
              !intent.executionInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              intent.executionInstruction.count <= 200_000,
              intent.verificationRequest.required,
              !criteria.isEmpty,
              criteria.count == Set(criteria).count,
              criteria.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.count <= 4_096
              }),
              intent.verificationRequest.verifierSeatID
                .map(Self.isSafeIdentifier) ?? true else {
            throw AceHQClientFailure.invalidRequest("Ace HQ dispatch intent is incomplete")
        }

        if let correction = intent.correctionContext {
            let correctionFields = [
                correction.ownerCorrection,
                correction.priorTerminalOutcome,
                correction.priorTerminalVerification,
                correction.priorTerminalReason,
            ]
            guard intent.work.parentCorrelationID != nil,
                  intent.work.parentCorrelationID
                    != intent.work.correlationID,
                  !correction.ownerCorrection.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  correctionFields.allSatisfy({
                      ($0?.count ?? 0) <= 1_200
                  }),
                  intent.executionInstruction
                    == correction.executionInstruction(
                        objective: intent.resolvedRequest
                    ) else {
                throw AceHQClientFailure.invalidRequest(
                    "Ace HQ correction context is incomplete, mismatched, or missing parent lineage"
                )
            }
        } else if intent.executionInstruction != intent.resolvedRequest {
            throw AceHQClientFailure.invalidRequest(
                "Ace HQ execution instruction is not bound to the resolved owner request"
            )
        }

        let evidence = intent.authorization.evidence
        let evidenceIDs = evidence.map(\.evidenceID)
        guard evidenceIDs.allSatisfy(Self.isSafeIdentifier),
              Set(evidenceIDs).count == evidenceIDs.count else {
            throw AceHQClientFailure.invalidRequest(
                "Ace HQ authorization evidence is missing an identity or contains a duplicate"
            )
        }

        var capabilityConsents: [AceHQCapabilityConsentEvidence] = []
        var exactPlanConfirmations: [AceHQExactPlanConfirmationEvidence] = []
        var exactExecutionConfirmations:
            [AceHQExactExecutionConfirmationEvidence] = []
        for item in evidence {
            switch item {
            case .capabilityConsent(let consent):
                capabilityConsents.append(consent)
            case .exactPlanConfirmation(let confirmation):
                exactPlanConfirmations.append(confirmation)
            case .exactExecutionConfirmation(let confirmation):
                exactExecutionConfirmations.append(confirmation)
            }
        }

        guard capabilityConsents.count == 1 else {
            throw AceHQClientFailure.invalidRequest(
                "Ace HQ dispatch requires exactly one durable capability-consent receipt"
            )
        }
        switch intent.authorization.requirement {
        case .nonconsequentialPlan:
            guard exactPlanConfirmations.isEmpty,
                  exactExecutionConfirmations.isEmpty,
                  intent.executionTarget == nil else {
                throw AceHQClientFailure.invalidRequest(
                    "Nonconsequential HQ planning contains execution authority or an unexpected confirmation"
                )
            }
        case .consequentialPlan:
            guard exactPlanConfirmations.count == 1,
                  exactExecutionConfirmations.isEmpty,
                  intent.executionTarget == nil else {
                throw AceHQClientFailure.invalidRequest(
                    "Consequential HQ planning requires exactly one fresh exact-plan confirmation"
                )
            }
        case .consequentialExecution:
            guard exactPlanConfirmations.isEmpty,
                  exactExecutionConfirmations.count == 1,
                  intent.executionTarget?.isAuthorized(
                      for: intent.requestedCapability
                  ) == true else {
                throw AceHQClientFailure.invalidRequest(
                    "HQ execution requires one canonical target and one fresh exact-execution confirmation"
                )
            }
        }

        let consent = capabilityConsents[0]
        let approvedScopeIDs = Set(consent.approvedScopes)
        let consentAge = validationTime.timeIntervalSince(consent.validatedAt)
        guard consent.receiptReference
                == AceHQCapabilityConsentEvidence.durableReceiptReference,
              consent.receiptSchemaVersion
                == AceHQCapabilityConsentEvidence.currentReceiptSchemaVersion,
              approvedScopeIDs
                == AceHQCapabilityConsentEvidence.completeScopeIDs,
              consent.approvedScopes.count == approvedScopeIDs.count,
              consent.approvedWorkspaceRoots == ["/"],
              consent.approvedAt <= consent.validatedAt,
              consent.approvedAt <= validationTime,
              consentAge >= 0,
              consentAge <= Self.authorizationEvidenceLifetime,
              consent.source == intent.source,
              consent.workCorrelationID == intent.work.correlationID else {
            throw AceHQClientFailure.invalidRequest(
                "Ace HQ durable capability consent is stale, partial, mismatched, or bound to the wrong request"
            )
        }

        if let confirmation = exactPlanConfirmations.first {
            let confirmationAge = validationTime.timeIntervalSince(
                confirmation.confirmedAt
            )
            guard confirmation.exactPlan == intent.executionInstruction,
                  confirmation.requestedCapability
                    == intent.requestedCapability,
                  confirmation.source == intent.source,
                  confirmation.workCorrelationID
                    == intent.work.correlationID,
                  confirmation.confirmedAt == consent.validatedAt,
                  confirmationAge >= 0,
                  confirmationAge <= Self.authorizationEvidenceLifetime else {
                throw AceHQClientFailure.invalidRequest(
                    "Ace HQ exact-plan confirmation is stale, mismatched, or bound to the wrong scope or correlation"
                )
            }
        }
        if let confirmation = exactExecutionConfirmations.first {
            let confirmationAge = validationTime.timeIntervalSince(
                confirmation.confirmedAt
            )
            guard confirmation.exactInstruction
                    == intent.executionInstruction,
                  confirmation.executionTarget
                    == intent.executionTarget,
                  confirmation.requestedCapability
                    == intent.requestedCapability,
                  confirmation.source == intent.source,
                  confirmation.workCorrelationID
                    == intent.work.correlationID,
                  confirmation.confirmedAt == consent.validatedAt,
                  confirmationAge >= 0,
                  confirmationAge <= Self.authorizationEvidenceLifetime else {
                throw AceHQClientFailure.invalidRequest(
                    "Ace HQ exact-execution confirmation is stale, mismatched, or bound to the wrong target or correlation"
                )
            }
        }
    }

    private func validate(
        mapping: AceHQSeatMapping,
        capability: AceHQRequestedCapability
    ) throws {
        guard let mappedSeatIDs = mapping.routes[capability] else {
            return
        }
        let authorizedSeatIDs = Set(capability.authorizedSeatIDs)
        guard !mappedSeatIDs.isEmpty,
              mappedSeatIDs.count == Set(mappedSeatIDs).count,
              mappedSeatIDs.allSatisfy({
                  Self.isSafeIdentifier($0)
                      && authorizedSeatIDs.contains($0)
              }) else {
            throw AceHQClientFailure.invalidRequest(
                "Ace HQ seat mapping is duplicated or not authorized for the requested capability"
            )
        }
    }

    private static let authorizationEvidenceLifetime: TimeInterval = 30

    private func validatedTicket(
        _ response: AceHQExecutionAuthorizationResponse,
        at validationTime: Date
    ) throws -> String {
        guard response.executionAuthorizationTicket.range(
            of: #"^[A-Za-z0-9_-]{32,512}$"#,
            options: .regularExpression
        ) != nil,
        let expiresAt = Self.executionAuthorizationDate(
            from: response.expiresAt
        ) else {
            throw AceHQClientFailure.mismatch(
                "HQ execution authorization omitted a valid opaque ticket or expiry"
            )
        }
        let remainingLifetime = expiresAt.timeIntervalSince(validationTime)
        guard remainingLifetime > 0,
              remainingLifetime <= Self.authorizationEvidenceLifetime else {
            throw AceHQClientFailure.mismatch(
                "HQ execution authorization ticket is expired or exceeds its thirty-second lifetime"
            )
        }
        return response.executionAuthorizationTicket
    }

    private static func executionAuthorizationDate(
        from value: String
    ) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        if let date = fractional.date(from: value) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,511}$"#,
            options: .regularExpression
        ) != nil
    }

    private func validate(
        session: AceHQSessionRecord,
        expectedSessionID: String?,
        envelope: AceHQDispatchEnvelope,
        allowedStatuses: Set<String>
    ) throws {
        guard !session.id.isEmpty,
              expectedSessionID == nil || session.id == expectedSessionID,
              session.providerID == envelope.selectedSeat.providerID,
              session.agentID == envelope.selectedSeat.seatID,
              session.workID == envelope.work.hqWorkID,
              allowedStatuses.contains(session.status) else {
            throw AceHQClientFailure.mismatch("HQ session acknowledgement changed the session, work, seat, provider, or lifecycle identity")
        }
    }

    private func acknowledgement(for status: String) -> AceHQAcknowledgementState {
        status == "running" ? .running : .queued
    }

    private func blocked(
        for error: Error,
        intent: AceHQDispatchIntent,
        selectedSeat: AceHQSelectedSeat?
    ) -> AceHQBlockedReceipt {
        switch error {
        case let failure as AceHQClientFailure:
            switch failure {
            case .unavailable(let message):
                return blocked(code: .hqUnavailable, message: message, retryable: true, intent: intent, selectedSeat: selectedSeat)
            case .rejected(let message):
                return blocked(code: .hqRejected, message: message, retryable: false, intent: intent, selectedSeat: selectedSeat)
            case .malformed(let message):
                return blocked(code: .malformedResponse, message: message, retryable: true, intent: intent, selectedSeat: selectedSeat)
            case .mismatch(let message):
                return blocked(code: .receiptMismatch, message: message, retryable: false, intent: intent, selectedSeat: selectedSeat)
            case .invalidRequest(let message):
                return blocked(code: .invalidRequest, message: message, retryable: false, intent: intent, selectedSeat: selectedSeat)
            }
        default:
            return blocked(
                code: .malformedResponse,
                message: "Ace could not encode or decode the typed HQ dispatch contract.",
                retryable: false,
                intent: intent,
                selectedSeat: selectedSeat
            )
        }
    }

    private func blocked(
        code: AceHQDispatchBlockCode,
        message: String,
        retryable: Bool,
        intent: AceHQDispatchIntent,
        selectedSeat: AceHQSelectedSeat?
    ) -> AceHQBlockedReceipt {
        AceHQBlockedReceipt(
            code: code,
            message: message,
            retryable: retryable,
            request: intent,
            selectedSeat: selectedSeat
        )
    }

    private static func isLoopbackHTTPBaseURL(_ url: URL) -> Bool {
        guard isLoopbackHTTPURL(url),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            return false
        }
        return true
    }

    private static func isLoopbackHTTPURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

private final class AceHQLoopbackRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private enum AceHQClientFailure: Error {
    case unavailable(String)
    case rejected(String)
    case malformed(String)
    case mismatch(String)
    case invalidRequest(String)
}

private struct AceHQAgentsResponse: Decodable {
    let agents: [AceHQAgentRecord]
}

private struct AceHQCapabilitiesResponse: Decodable {
    let capabilities: [AceHQCapabilityRecord]
}

private struct AceHQProvidersResponse: Decodable {
    let providers: [AceHQProviderRecord]
}

private struct AceHQCreateSessionInput: Encodable {
    let providerID: String
    let agentID: String
    let workID: String?
    let title: String
    let idempotencyKey: String

    private enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case agentID = "agent_id"
        case workID = "work_id"
        case title
        case idempotencyKey = "idempotency_key"
    }
}

private struct AceHQExecutionAuthorizationInput: Encodable {
    let schemaVersion: Int
    let envelopeDigest: String
    let source: AceHQSourceTurnIdentity
    let work: AceHQWorkCorrelation
    let requestedCapability: AceHQRequestedCapability
    let executionTarget: AceHQExecutionTarget
    let selectedSeat: AceHQSelectedSeat

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case envelopeDigest = "envelope_digest"
        case source
        case work
        case requestedCapability = "requested_capability"
        case executionTarget = "execution_target"
        case selectedSeat = "selected_seat"
    }
}

private struct AceHQExecutionAuthorizationResponse: Decodable {
    let executionAuthorizationTicket: String
    let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case executionAuthorizationTicket =
            "execution_authorization_ticket"
        case expiresAt = "expires_at"
    }
}

private struct AceHQSendTurnInput: Encodable {
    let prompt: String
    let idempotencyKey: String
    let executionAuthorizationTicket: String?

    private enum CodingKeys: String, CodingKey {
        case prompt
        case idempotencyKey = "idempotency_key"
        case executionAuthorizationTicket =
            "execution_authorization_ticket"
    }
}

private struct AceHQCreateSessionResponse: Decodable {
    let session: AceHQSessionRecord
    let idempotentReplay: Bool

    private enum CodingKeys: String, CodingKey {
        case session
        case idempotentReplay = "idempotent_replay"
    }
}

private struct AceHQSendTurnResponse: Decodable {
    let accepted: Bool
    let event: AceHQEventRecord
    let session: AceHQSessionRecord
    let idempotentReplay: Bool

    private enum CodingKeys: String, CodingKey {
        case accepted
        case event
        case session
        case idempotentReplay = "idempotent_replay"
    }
}

private struct AceHQSessionRecord: Decodable {
    let id: String
    let providerID: String
    let agentID: String?
    let workID: String?
    let status: String

    private enum CodingKeys: String, CodingKey {
        case id
        case providerID = "provider_id"
        case agentID = "agent_id"
        case workID = "work_id"
        case status
    }
}

private struct AceHQEventRecord: Decodable {
    let id: String
    let sessionID: String
    let sequence: Int
    let type: String
    let role: String
    let content: String?
    let providerEventID: String?
    let executionReceipt: AceHQExecutionReceipt?

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case sequence
        case type
        case role
        case content
        case providerEventID = "provider_event_id"
        case executionReceipt = "execution_receipt"
    }
}

private struct AceHQEventsResponse: Decodable {
    let events: [AceHQEventRecord]
    let next: Int
    let cursor: AceHQEventCursor
}

private struct AceHQEventCursor: Decodable {
    let after: Int
    let next: Int
    let limit: Int
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case after
        case next
        case limit
        case hasMore = "has_more"
    }
}
