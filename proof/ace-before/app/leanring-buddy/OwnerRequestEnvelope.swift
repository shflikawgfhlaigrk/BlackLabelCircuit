//
//  OwnerRequestEnvelope.swift
//  Ace
//
//  One immutable owner request and the only text normalization shared by the
//  immediate native resolver and Gold. This boundary never selects a route.
//

import Foundation

nonisolated enum OwnerRequestOrigin: String, Codable, Sendable {
    case microphone
    case panel
    case directControl
}

nonisolated struct OwnerRequestEnvelope: Equatable, Sendable {
    let sessionID: UUID
    let turnID: UUID
    let correlationID: UUID
    let origin: OwnerRequestOrigin
    let exactTranscript: String
    let normalizedRequest: String
    let admittedAt: Date
}

nonisolated enum OwnerRequestNormalizer {
    private static let maximumRecentTargetCharacters = 512

    static func makeEnvelope(
        sessionID: UUID,
        turnID: UUID,
        correlationID: UUID,
        origin: OwnerRequestOrigin,
        exactTranscript: String,
        admittedAt: Date,
        recentExactTarget: String?
    ) -> OwnerRequestEnvelope {
        OwnerRequestEnvelope(
            sessionID: sessionID,
            turnID: turnID,
            correlationID: correlationID,
            origin: origin,
            exactTranscript: exactTranscript,
            normalizedRequest: normalize(
                exactTranscript,
                recentExactTarget: recentExactTarget
            ),
            admittedAt: admittedAt
        )
    }

    private static func normalize(
        _ exactTranscript: String,
        recentExactTarget: String?
    ) -> String {
        var request = exactTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        request = removingOnePrefix(
            from: request,
            pattern:
                #"(?i)^\s*(?:(?:(?:hey|hi|okay|ok)[\s,]+)?ace)[\s,]+"#
        )
        request = removingOnePrefix(
            from: request,
            pattern:
                #"(?i)^\s*(?:please|(?:can|could|would|will)\s+you(?:\s+please)?|i\s+(?:want|need)\s+you\s+to|go\s+ahead\s+and)\s+"#
        )

        // Bind only a complete app-navigation continuation. Replacing a
        // conversational "this" with the last app name can turn "This is a
        // memory test" into "Google Chrome is a memory test", which the web
        // router then treats as an unintended Google-search imperative.
        guard let target = boundedRecentTarget(recentExactTarget),
              let expression = try? NSRegularExpression(
                pattern: #"(?i)^\s*(?:open|launch|switch\s+to|go\s+to)\s+(it|that|this)(?:\s+again)?\s*[.!?]*\s*$"#
              ),
              let match = expression.firstMatch(
                in: request,
                range: NSRange(request.startIndex..., in: request)
              ),
              let range = Range(match.range(at: 1), in: request) else {
            return request
        }
        request.replaceSubrange(range, with: target)
        return request
    }

    private static func removingOnePrefix(
        from value: String,
        pattern: String
    ) -> String {
        value.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression,
            range: value.startIndex..<value.endIndex
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundedRecentTarget(_ value: String?) -> String? {
        guard let value else { return nil }
        let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty,
              target.count <= maximumRecentTargetCharacters,
              !target.contains("\n"),
              !target.contains("\r") else {
            return nil
        }
        return target
    }
}
