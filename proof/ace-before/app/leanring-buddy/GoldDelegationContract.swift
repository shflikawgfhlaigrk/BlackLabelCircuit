import Foundation

nonisolated enum RedExecutionOutcome: String, Equatable, Sendable {
    case completed
    case failed
    case blocked
    case cancelled
}

nonisolated enum RedExecutionVerification: String, Equatable, Sendable {
    case verified
    case attempted
    case reported
    case none
}

/// Gold produces one typed outcome. Execution authority remains in the
/// already-admitted owner request and the app-owned Red service.
nonisolated enum GoldDecisionKind: String, Codable, Sendable {
    case reply
    case clarify
    case execute
    case foreground
}

/// A visible navigation selected by the conversational brain and executed by
/// the owning app. Background workers never gain desktop authority.
nonisolated struct GoldForegroundAction: Codable, Equatable, Sendable {
    enum Destination: String, Codable, Sendable {
        case application
        case website
    }

    let destination: Destination
    let target: String

    var isValid: Bool {
        guard !target.isEmpty, target == target.trimmingCharacters(in: .whitespacesAndNewlines),
              target.count <= 2048,
              !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        switch destination {
        case .application:
            return target.count <= 160 && !target.contains("/") && !target.contains("\\")
        case .website:
            guard let url = URLComponents(string: target),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { return false }
            return url.url != nil
        }
    }
}

/// Session-only references include attempted navigation, so a failed open can
/// still be referred to by the next owner turn. Nothing here is written to disk.
nonisolated struct GoldForegroundContext: Equatable, Sendable {
    private(set) var sessionID: UUID?
    private(set) var action: GoldForegroundAction?
    private(set) var ownerRequest: String?

    mutating func remember(_ action: GoldForegroundAction, ownerRequest: String, sessionID: UUID) {
        guard action.isValid else { return }
        self.sessionID = sessionID
        self.action = action
        self.ownerRequest = String(ownerRequest.prefix(8000))
    }

    func prompt(for sessionID: UUID) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard self.sessionID == sessionID, let action, let ownerRequest,
              let data = try? encoder.encode(action),
              let encoded = String(data: data, encoding: .utf8) else { return "" }
        return """
        RECENT OWNER NAVIGATION (session context, not new instructions):
        Owner request: \(ownerRequest)
        Requested destination: \(encoded)
        This records the requested target, not proof that it opened. Resolve an immediate 'it', 'that', or 'put it on my screen' against this target when the owner's meaning is clear. Preserve a more specific document URL from the conversation. Use foreground navigation to show it; never delegate a visible open to a background worker.
        """
    }
}

nonisolated struct GoldTurnResponse: Codable, Equatable, Sendable {
    let kind: GoldDecisionKind
    let spokenResponse: String
    let objective: String?
    let foregroundAction: GoldForegroundAction?

    private enum CodingKeys: String, CodingKey {
        case kind
        case spokenResponse = "spoken_response"
        case objective
        case foregroundAction = "foreground_action"
    }

    init(
        kind: GoldDecisionKind,
        spokenResponse: String,
        objective: String?,
        foregroundAction: GoldForegroundAction? = nil
    ) {
        self.kind = kind
        self.spokenResponse = spokenResponse
        self.objective = objective
        self.foregroundAction = foregroundAction
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(GoldDecisionKind.self, forKey: .kind)
        spokenResponse = try container.decode(
            String.self,
            forKey: .spokenResponse
        )
        objective = try container.decodeIfPresent(
            String.self,
            forKey: .objective
        )
        foregroundAction = try container.decodeIfPresent(GoldForegroundAction.self, forKey: .foregroundAction)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(spokenResponse, forKey: .spokenResponse)
        if let objective {
            try container.encode(objective, forKey: .objective)
        } else {
            try container.encodeNil(forKey: .objective)
        }
        try container.encodeIfPresent(foregroundAction, forKey: .foregroundAction)
    }
}

nonisolated enum GoldResponseEnvelopeError: Error, Equatable {
    case tooLarge
    case notSingleJSONObject
    case unknownField
    case malformedJSON
    case invalidValue
    case prohibitedMarker
    case nonterminalPromise
    case nonterminalRefusal
}

/// A provider reply is not a terminal result when it only promises later work
/// or asks Ace to perform a handoff the app already owns. The decoder applies
/// this before provider text can be displayed as success.
nonisolated enum ProviderTerminalReplyPolicy {
    private static func normalized(_ text: String) -> String {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(
                of: #"[^a-z0-9']+"#,
                with: " ",
                options: .regularExpression
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func isRejectedPromise(_ text: String) -> Bool {
        let normalized = normalized(text)
        let futurePromise = normalized.range(
            of: #"^(?:okay )?(?:(?:i'll|i will|i'm going to|i am going to|let me) (?:start|begin|get started|work on|handle|take care of|do|look into|check|send|create|build)\b|(?:i'm|i am) (?:working|starting|handling|doing|checking|looking into)\b|(?:give me|one) (?:a )?(?:second|moment|minute)\b)"#,
            options: .regularExpression
        ) != nil
        if futurePromise {
            return true
        }
        return normalized.contains("should i give this to red")
            || normalized.contains("should i hand this to red")
            || normalized.contains("should i send this to red")
            || normalized.contains("should i pass this to red")
            || normalized.contains("would you like me to give this to red")
            || normalized.contains("would you like me to hand this to red")
            || normalized.contains("do you want me to give this to red")
            || normalized.contains("do you want me to hand this to red")
            || normalized.contains("do you want me to send this to red")
    }

    /// A refusal or generic self-inability is never a terminal owner answer.
    /// The caller routes the unchanged admitted request to the executor instead
    /// of displaying provider-authored denial text.
    static func isDeadEndRefusal(_ text: String) -> Bool {
        let normalized = normalized(text)
        guard !normalized.isEmpty else { return false }

        let firstPersonRefusal = normalized.range(
            of: #"\b(?:i|we)\s+(?:can't|cannot|won't|will not|am unable to|are unable to|am not able to|are not able to|(?:don't|do not)\s+(?:actually\s+|currently\s+|really\s+)?have (?:access|permission|the ability|the capability)|lack access|lack permission|don't know|do not know|am not sure)\b|\bace\s+(?:can't|cannot|won't|will not|is unable to|is not able to|(?:doesn't|does not)\s+(?:actually\s+|currently\s+|really\s+)?have (?:access|permission)|lacks access|lacks permission)\b"#,
            options: .regularExpression
        ) != nil
        let indirectRefusal = normalized.range(
            of: #"\b(?:not something i can|isn't something i can|is not something i can|unable to (?:help|assist|comply|complete|fulfill|perform|access)|can't comply|cannot comply|permission denied)\b"#,
            options: .regularExpression
        ) != nil
        return firstPersonRefusal || indirectRefusal
    }
}

nonisolated enum GoldResponseEnvelope {
    private static let maximumEnvelopeBytes = 16_384
    private static let maximumSpokenCharacters = 4_000
    private static let maximumObjectiveCharacters = 1_200

    /// JSON Schema for the gold envelope, handed to backends that can enforce
    /// a final-response shape natively (Codex `--output-schema`). The schema
    /// removes free-text formatting wobble at the source; decode below still
    /// enforces every admission rule, so a backend without native enforcement
    /// loses nothing.
    static let outputSchemaJSON = """
        {
          "type": "object",
          "properties": {
            "kind": {"type": "string", "enum": ["reply", "clarify", "execute", "foreground"]},
            "spoken_response": {"type": "string", "maxLength": 4000},
            "objective": {"type": ["string", "null"], "maxLength": 1200},
            "foreground_action": {
              "anyOf": [
                {"type": "null"},
                {"type": "object", "properties": {
                  "destination": {"type": "string", "enum": ["application", "website"]},
                  "target": {"type": "string", "maxLength": 2048}
                }, "required": ["destination", "target"], "additionalProperties": false}
              ]
            }
          },
          "required": ["kind", "spoken_response", "objective", "foreground_action"],
          "additionalProperties": false
        }
        """

    static func decode(_ data: Data) throws -> GoldTurnResponse {
        guard data.count <= maximumEnvelopeBytes else {
            throw GoldResponseEnvelopeError.tooLarge
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw GoldResponseEnvelopeError.malformedJSON
        }
        // The marker scan runs against the FULL raw text before any salvage,
        // so a prose delegation marker can never ride in around the envelope.
        guard source.range(
            of: #"(?i)\[DELEGATE\b"#,
            options: .regularExpression
        ) == nil else {
            throw GoldResponseEnvelopeError.prohibitedMarker
        }

        // The model is told to return one bare JSON object and usually does.
        // Real turns also arrive fenced, prefixed with prose, or trailed by
        // stray tag text (2026-08-12: two finished answers were discarded as
        // snags this way). All of those still contain exactly the object the
        // contract wants, so salvage the first balanced top-level object and
        // enforce every authority rule on it — never on the wrapper.
        guard let candidate = extractedTopLevelObject(from: source) else {
            throw GoldResponseEnvelopeError.notSingleJSONObject
        }
        guard let object = candidate.dictionary as? [String: Any] else {
            throw GoldResponseEnvelopeError.notSingleJSONObject
        }
        let fields = Set(object.keys)
        guard fields == ["kind", "spoken_response", "objective"]
                || fields == ["kind", "spoken_response", "objective", "foreground_action"] else {
            throw GoldResponseEnvelopeError.unknownField
        }
        if let action = object["foreground_action"] as? [String: Any],
           Set(action.keys) != ["destination", "target"] {
            throw GoldResponseEnvelopeError.unknownField
        }

        let response: GoldTurnResponse
        do {
            response = try JSONDecoder().decode(
                GoldTurnResponse.self,
                from: candidate.data
            )
        } catch {
            throw GoldResponseEnvelopeError.invalidValue
        }
        let spoken = response.spokenResponse.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard response.spokenResponse.count <= maximumSpokenCharacters else {
            throw GoldResponseEnvelopeError.invalidValue
        }
        switch response.kind {
        case .reply, .clarify:
            guard response.objective == nil,
                  response.foregroundAction == nil,
                  !spoken.isEmpty else {
                throw GoldResponseEnvelopeError.invalidValue
            }
            if response.kind == .reply,
               ProviderTerminalReplyPolicy
                    .isRejectedPromise(spoken) {
                throw GoldResponseEnvelopeError.nonterminalPromise
            }
            if response.kind == .reply,
               ProviderTerminalReplyPolicy
                    .isDeadEndRefusal(spoken) {
                throw GoldResponseEnvelopeError.nonterminalRefusal
            }
        case .execute:
            guard response.foregroundAction == nil,
                  let objective = response.objective?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ),
                  spoken.isEmpty,
                  !objective.isEmpty,
                  objective.count <= maximumObjectiveCharacters else {
                throw GoldResponseEnvelopeError.invalidValue
            }
        case .foreground:
            guard spoken.isEmpty, response.objective == nil,
                  response.foregroundAction?.isValid == true else {
                throw GoldResponseEnvelopeError.invalidValue
            }
        }
        return response
    }

    /// The first balanced top-level JSON object in the text, parsed. Tries the
    /// whole trimmed text first (the well-behaved case), then a string-aware
    /// brace scan from each opening brace, so fences and surrounding prose are
    /// dropped rather than costing the owner a finished answer. Returns nil
    /// when no balanced object parses as a JSON dictionary.
    private static func extractedTopLevelObject(
        from source: String
    ) -> (dictionary: Any, data: Data)? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [Substring] = []
        if trimmed.first == "{", trimmed.last == "}" {
            candidates.append(trimmed[...])
        }
        var scanStart = trimmed.startIndex
        var starts = 0
        while starts < 32, let open = trimmed[scanStart...].firstIndex(of: "{") {
            if let object = balancedObject(in: trimmed[...], from: open) {
                candidates.append(object)
            }
            starts += 1
            scanStart = trimmed.index(after: open)
            if scanStart >= trimmed.endIndex { break }
        }
        for candidate in candidates {
            let data = Data(candidate.utf8)
            guard let json = try? JSONSerialization.jsonObject(with: data),
                  json is [String: Any] else { continue }
            return (json, data)
        }
        return nil
    }

    /// The substring from `start` (an opening brace) to its matching closing
    /// brace, tracking JSON string and escape state so braces inside string
    /// values never miscount depth.
    private static func balancedObject(
        in text: Substring,
        from start: Substring.Index
    ) -> Substring? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return text[start...index] }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

nonisolated struct GoldExecutionRequest: Equatable, Sendable {
    let sourceSessionIdentifier: UUID
    let sourceTurnIdentifier: UUID
    let sourceCorrelationIdentifier: UUID
    let workCorrelationIdentifier: UUID
    // Clarification changes the executing turn, while Stop keeps the original
    // durable work provenance. Retain both identities through late callbacks.
    let workSourceTurnIdentifier: UUID
    let workSourceCorrelationIdentifier: UUID
    let objective: String
    /// Exact admitted microphone bytes for audit and user-visible receipts.
    /// These bytes never become the executable correction after deterministic
    /// context resolution has produced a different request.
    let originalOwnerTranscript: String
    /// App-owned executable request. Corrections keep their parent lineage and
    /// execute this resolved value while preserving the original words above.
    let resolvedRequest: String
    let correctionContext: OwnerCorrectionContext?
    let parentWorkCorrelationIdentifier: UUID?
    let selectedAt: Date

    var executionInstruction: String {
        correctionContext?.executionInstruction(
            objective: objective
        ) ?? objective
    }
}

nonisolated enum GoldObjectiveValidation: Equatable, Sendable {
    case accepted(GoldExecutionRequest)
    case formatFailure(String)
}

/// One model question may hold one already-admitted owner request. The model's
/// question is retained only to make the next provider prompt intelligible; it
/// never becomes executable input. A resumed objective is composed solely from
/// the original app-owned request and the owner's new admitted answer.
nonisolated struct GoldClarificationContinuation: Equatable, Sendable {
    static let lifetime: TimeInterval = 5 * 60

    let sourceSessionIdentifier: UUID
    let parentWorkCorrelationIdentifier: UUID
    let originalOwnerTranscript: String
    let originalResolvedRequest: String
    let question: String
    let createdAt: Date

    init?(
        sourceSessionIdentifier: UUID,
        parentWorkCorrelationIdentifier: UUID,
        originalOwnerTranscript: String,
        originalResolvedRequest: String,
        question: String,
        createdAt: Date = Date()
    ) {
        let owner = originalOwnerTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let resolved = originalResolvedRequest.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let boundedQuestion = question.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !owner.isEmpty,
              owner.count <= OwnerCorrectionContext.maximumExecutableRequestCharacters,
              !resolved.isEmpty,
              resolved.count <= OwnerCorrectionContext.maximumExecutableRequestCharacters,
              !boundedQuestion.isEmpty,
              boundedQuestion.count <= 4_000 else {
            return nil
        }
        self.sourceSessionIdentifier = sourceSessionIdentifier
        self.parentWorkCorrelationIdentifier =
            parentWorkCorrelationIdentifier
        self.originalOwnerTranscript = originalOwnerTranscript
        self.originalResolvedRequest = resolved
        self.question = boundedQuestion
        self.createdAt = createdAt
    }

    func isCurrent(
        sessionIdentifier: UUID,
        at timestamp: Date = Date()
    ) -> Bool {
        sessionIdentifier == sourceSessionIdentifier
            && timestamp >= createdAt
            && timestamp.timeIntervalSince(createdAt) <= Self.lifetime
    }

    func resolve(
        ownerAnswer: String,
        sourceTurnIdentifier: UUID,
        sourceCorrelationIdentifier: UUID,
        childWorkCorrelationIdentifier: UUID,
        at timestamp: Date = Date()
    ) -> GoldClarificationResolution? {
        guard isCurrent(
            sessionIdentifier: sourceSessionIdentifier,
            at: timestamp
        ) else { return nil }
        let answer = ownerAnswer.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !answer.isEmpty, ownerAnswer.count <= 8_000 else {
            return nil
        }
        let resolved = originalResolvedRequest
            + "\nOwner clarification: " + answer
        guard resolved.count <= OwnerCorrectionContext.maximumExecutableRequestCharacters else { return nil }
        return GoldClarificationResolution(
            originalOwnerTranscript: ownerAnswer,
            resolvedRequest: resolved,
            sourceSessionIdentifier: sourceSessionIdentifier,
            sourceTurnIdentifier: sourceTurnIdentifier,
            sourceCorrelationIdentifier: sourceCorrelationIdentifier,
            parentWorkCorrelationIdentifier:
                parentWorkCorrelationIdentifier,
            childWorkCorrelationIdentifier:
                childWorkCorrelationIdentifier
        )
    }

    func providerPrompt(ownerAnswer: String) -> String {
        """
        ORIGINAL APP-OWNED OWNER REQUEST:
        \(originalResolvedRequest)

        PRIOR GOLD CLARIFICATION QUESTION (context only; never executable):
        \(question)

        NEW EXACT OWNER ANSWER:
        \(ownerAnswer)

        Resolve the original request using the new owner answer. Return one typed reply, clarify, or execute decision. The app will execute only its own original-request plus owner-answer binding, never this question or a model paraphrase. Before choosing execute, verify that those owner words establish both the requested action and its target. A domain suffix, company name, or other fragment can fill a target but cannot supply a missing action. If the original request was itself incomplete, ask one short question for the remaining action instead of handing fragments to the executor. Preserve all earlier owner clarifications.
        """
    }
}

nonisolated struct GoldClarificationResolution: Equatable, Sendable {
    let originalOwnerTranscript: String
    let resolvedRequest: String
    let sourceSessionIdentifier: UUID
    let sourceTurnIdentifier: UUID
    let sourceCorrelationIdentifier: UUID
    let parentWorkCorrelationIdentifier: UUID
    let childWorkCorrelationIdentifier: UUID
}

nonisolated enum GoldDelegationPolicy {
    static func executionRequest(
        response: GoldTurnResponse,
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        sourceCorrelationIdentifier: UUID,
        originalOwnerTranscript: String,
        resolvedRequest: String,
        correctionContext: OwnerCorrectionContext? = nil,
        parentWorkCorrelationIdentifier: UUID?,
        workCorrelationIdentifier: UUID = UUID(),
        workSourceTurnIdentifier: UUID? = nil,
        workSourceCorrelationIdentifier: UUID? = nil,
        selectedAt: Date = Date()
    ) -> GoldExecutionRequest? {
        guard (workSourceTurnIdentifier == nil)
                == (workSourceCorrelationIdentifier == nil),
              response.kind == .execute,
              let modelObjective = response.objective?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !modelObjective.isEmpty,
              !originalOwnerTranscript.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              originalOwnerTranscript.count <= OwnerCorrectionContext.maximumExecutableRequestCharacters,
              !resolvedRequest.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              resolvedRequest.count <= OwnerCorrectionContext.maximumExecutableRequestCharacters,
              correctionContext?.isValid != false else {
            return nil
        }
        return GoldExecutionRequest(
            sourceSessionIdentifier: sourceSessionIdentifier,
            sourceTurnIdentifier: sourceTurnIdentifier,
            sourceCorrelationIdentifier: sourceCorrelationIdentifier,
            workCorrelationIdentifier: workCorrelationIdentifier,
            workSourceTurnIdentifier:
                workSourceTurnIdentifier ?? sourceTurnIdentifier,
            workSourceCorrelationIdentifier:
                workSourceCorrelationIdentifier ?? sourceCorrelationIdentifier,
            // The model chooses only whether this turn needs execution. Its
            // paraphrase never becomes executable input: Red receives Ace's
            // exact app-resolved owner request for every provider.
            objective: resolvedRequest,
            originalOwnerTranscript: originalOwnerTranscript,
            resolvedRequest: resolvedRequest,
            correctionContext: correctionContext,
            parentWorkCorrelationIdentifier:
                parentWorkCorrelationIdentifier,
            selectedAt: selectedAt
        )
    }

    static func validateExecution(
        response: GoldTurnResponse,
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        sourceCorrelationIdentifier: UUID,
        originalOwnerTranscript: String,
        resolvedRequest: String,
        correctionContext: OwnerCorrectionContext? = nil,
        parentWorkCorrelationIdentifier: UUID?,
        workCorrelationIdentifier: UUID = UUID(),
        workSourceTurnIdentifier: UUID? = nil,
        workSourceCorrelationIdentifier: UUID? = nil,
        selectedAt: Date = Date()
    ) -> GoldObjectiveValidation {
        guard let request = executionRequest(
            response: response,
            sourceSessionIdentifier: sourceSessionIdentifier,
            sourceTurnIdentifier: sourceTurnIdentifier,
            sourceCorrelationIdentifier: sourceCorrelationIdentifier,
            originalOwnerTranscript: originalOwnerTranscript,
            resolvedRequest: resolvedRequest,
            correctionContext: correctionContext,
            parentWorkCorrelationIdentifier:
                parentWorkCorrelationIdentifier,
            workCorrelationIdentifier: workCorrelationIdentifier,
            workSourceTurnIdentifier: workSourceTurnIdentifier,
            workSourceCorrelationIdentifier: workSourceCorrelationIdentifier,
            selectedAt: selectedAt
        ) else {
            return .formatFailure(
                "Gold returned an invalid execution-objective format; no computer action was attempted."
            )
        }
        return .accepted(request)
    }
}

nonisolated enum GoldObjectiveBinding {
    static func isBoundedProjection(
        _ candidate: String,
        of admittedRequest: String
    ) -> Bool {
        let candidate = candidate.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !candidate.isEmpty, candidate.count <= 1_200 else {
            return false
        }
        let candidateTokens = tokens(in: candidate)
        let admittedTokens = tokens(in: admittedRequest)
        guard !candidateTokens.isEmpty,
              !admittedTokens.isEmpty,
              candidateTokens.isSubset(of: admittedTokens) else {
            return false
        }
        return candidateTokens.count >= 2
            || candidateTokens == admittedTokens
    }

    private static func tokens(in value: String) -> Set<String> {
        Set(
            value.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
    }
}
