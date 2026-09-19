import Foundation

nonisolated enum PartnerDecisionKind: String, Codable, Equatable, Sendable {
    case reply
    case clarify
    case execute
}

nonisolated struct PartnerTurnResponse:
    Codable,
    Equatable,
    Sendable
{
    let kind: PartnerDecisionKind
    let spokenResponse: String
    let objective: String?
    let memoryMutations: [PartnerMemoryMutation]
    let screenContextNeeded: Bool
    let sessionSummaryDelta: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case spokenResponse = "spoken_response"
        case objective
        case memoryMutations = "memory_mutations"
        case screenContextNeeded = "screen_context_needed"
        case sessionSummaryDelta = "session_summary_delta"
    }
}

extension PartnerTurnResponse {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(
            keyedBy: CodingKeys.self
        )
        kind = try values.decode(
            PartnerDecisionKind.self,
            forKey: .kind
        )
        spokenResponse = try values.decode(
            String.self,
            forKey: .spokenResponse
        )
        objective = try values.decodeIfPresent(
            String.self,
            forKey: .objective
        )
        memoryMutations =
            try values.decodeIfPresent(
                [PartnerMemoryMutation].self,
                forKey: .memoryMutations
            ) ?? []
        screenContextNeeded =
            try values.decodeIfPresent(
                Bool.self,
                forKey: .screenContextNeeded
            ) ?? false
        sessionSummaryDelta =
            try values.decodeIfPresent(
                String.self,
                forKey: .sessionSummaryDelta
            ) ?? ""
    }
}

nonisolated enum PartnerResponseEnvelopeError:
    Error,
    Equatable
{
    case tooLarge
    case notSingleJSONObject
    case unknownField
    case malformedJSON
    case invalidValue
    case prohibitedCapabilityContent
    case nonterminalPromise
}

nonisolated struct PartnerResponseEnvelope {
    private static let maximumEnvelopeBytes = 65_536
    private static let maximumSpokenCharacters = 4_000
    private static let maximumObjectiveCharacters = 1_200
    private static let maximumSummaryCharacters = 1_200

    static func decode(_ data: Data) throws -> PartnerTurnResponse {
        guard data.count <= maximumEnvelopeBytes else {
            throw PartnerResponseEnvelopeError.tooLarge
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw PartnerResponseEnvelopeError.malformedJSON
        }
        let trimmedSource = source.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmedSource.first == "{",
              trimmedSource.last == "}" else {
            throw PartnerResponseEnvelopeError.notSingleJSONObject
        }

        let jsonValue: Any
        do {
            jsonValue = try JSONSerialization.jsonObject(
                with: Data(trimmedSource.utf8),
                options: []
            )
        } catch {
            throw PartnerResponseEnvelopeError.malformedJSON
        }
        guard let topLevelObject =
                jsonValue as? [String: Any] else {
            throw PartnerResponseEnvelopeError.notSingleJSONObject
        }
        try validateKnownFields(in: topLevelObject)
        if containsProhibitedCapabilityContent(trimmedSource) {
            throw PartnerResponseEnvelopeError
                .prohibitedCapabilityContent
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response: PartnerTurnResponse
        do {
            response = try decoder.decode(
                PartnerTurnResponse.self,
                from: Data(trimmedSource.utf8)
            )
        } catch {
            throw PartnerResponseEnvelopeError.invalidValue
        }
        try validate(response)
        return normalizeQuestionOnlyReply(response)
    }

    /// A provider occasionally emits one required-value question as `reply`
    /// even though the same bytes are a clarification in the buyer contract.
    /// Keep answered replies terminal, but retain a single standalone question
    /// under the admitted work ID so the owner's next short answer can resume
    /// it. Promise-only Red questions are rejected by `validate` before this
    /// normalization runs.
    private static func normalizeQuestionOnlyReply(
        _ response: PartnerTurnResponse
    ) -> PartnerTurnResponse {
        guard response.kind == .reply else { return response }
        let spoken = response.spokenResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard spoken.hasSuffix("?"),
              spoken.filter({ $0 == "?" }).count == 1 else {
            return response
        }
        let body = String(spoken.dropLast())
        guard !body.contains("."), !body.contains("!"),
              body.range(
                  of:
                    #"(?i)^(?:what|which|who|where|when|why|how|can you|could you|would you|do you|does |did |is |are |should |please (?:tell|choose|select)|tell me|choose |select )"#,
                  options: .regularExpression
              ) != nil else {
            return response
        }
        return PartnerTurnResponse(
            kind: .clarify,
            spokenResponse: response.spokenResponse,
            objective: nil,
            memoryMutations: response.memoryMutations,
            screenContextNeeded: response.screenContextNeeded,
            sessionSummaryDelta: response.sessionSummaryDelta
        )
    }

    private static func validateKnownFields(
        in topLevelObject: [String: Any]
    ) throws {
        try requireOnlyKeys(
            in: topLevelObject,
            allowedKeys: [
                "kind",
                "spoken_response",
                "objective",
                "memory_mutations",
                "screen_context_needed",
                "session_summary_delta",
            ]
        )
        if let mutations =
                topLevelObject["memory_mutations"]
                    as? [[String: Any]] {
            for mutation in mutations {
                try requireOnlyKeys(
                    in: mutation,
                    allowedKeys: [
                        "operation",
                        "domain",
                        "stable_key",
                        "normalized_content",
                        "user_visible_wording",
                        "confidence",
                        "confirmation_state",
                        "linked_record_identifiers",
                    ]
                )
            }
        }
    }

    private static func requireOnlyKeys(
        in object: [String: Any],
        allowedKeys: Set<String>
    ) throws {
        guard Set(object.keys).isSubset(of: allowedKeys) else {
            throw PartnerResponseEnvelopeError.unknownField
        }
    }

    private static func validate(
        _ response: PartnerTurnResponse
    ) throws {
        let spokenResponse = response.spokenResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard response.spokenResponse.count <= maximumSpokenCharacters,
              response.memoryMutations.count <= 12,
              response.sessionSummaryDelta.count
                <= maximumSummaryCharacters else {
            throw PartnerResponseEnvelopeError.invalidValue
        }
        switch response.kind {
        case .reply, .clarify:
            guard !spokenResponse.isEmpty,
                  response.objective == nil else {
                throw PartnerResponseEnvelopeError.invalidValue
            }
            if response.kind == .reply,
               ProviderTerminalReplyPolicy
                    .isRejectedPromise(spokenResponse) {
                throw PartnerResponseEnvelopeError.nonterminalPromise
            }
        case .execute:
            let objective = response.objective?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard spokenResponse.isEmpty,
                  let objective,
                  !objective.isEmpty,
                  objective.count <= maximumObjectiveCharacters else {
                throw PartnerResponseEnvelopeError.invalidValue
            }
        }
        for mutation in response.memoryMutations {
            guard mutation.confidence.isFinite,
                  (0...1).contains(mutation.confidence),
                  !mutation.stableKey.isEmpty,
                  !mutation.normalizedContent.isEmpty,
                  !mutation.userVisibleWording.isEmpty else {
                throw PartnerResponseEnvelopeError.invalidValue
            }
        }
    }

    private static func containsProhibitedCapabilityContent(
        _ source: String
    ) -> Bool {
        source.range(
            of:
                #"(?i)(?:/bin/|/usr/bin/|[a-z]:\\|\.exe\b|approval[_ -]?token|tool[_ -]?name|executable[_ -]?path)"#,
            options: .regularExpression
        ) != nil
    }
}
