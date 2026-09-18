//
//  HomeworkScreenEvidence.swift
//  Ace
//

import Foundation

struct HomeworkCaptureContext: Equatable, Sendable {
    let generation: UUID
    let displayID: UInt32
}

enum HomeworkProblemVisibility: String, Equatable, Sendable {
    case listOnly = "list-only"
    case obscured
    case ambiguous
}

enum HomeworkScreenDecoding: Equatable, Sendable {
    case clear(spokenText: String, problemFingerprint: String)
    case notReadable(visibility: HomeworkProblemVisibility)
    case rejected(reason: String)
}

enum HomeworkScreenEvidence {
    private static let clearPattern =
        #"\[HOMEWORK:status=clear;capture=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12});display=([0-9]+);problem=([^\]\r\n]{1,160})\]"#
    private static let notReadablePattern =
        #"\[HOMEWORK:status=(list-only|obscured|ambiguous)\]"#

    static func requiresReadableProblem(_ utterance: String) -> Bool {
        // A complaint about Ace's preceding answer is conversational context,
        // not a request to solve a visible assignment.
        guard utterance.range(
            of: #"(?i)\b(?:why|how come)\s+(?:(?:can['’]t|won['’]t)\s+you|(?:did|do|can|could|would|will)(?:n['’]?t|\s+not)?\s+you|you\b)|\byou\s+(?:(?:did|have|do|can|could|would)(?:n['’]?t|\s+not)|never)\s+(?:answer|respond|explain)\b|\bi\s+asked\s+you\b"#,
            options: .regularExpression
        ) == nil else { return false }
        return utterance.range(
            of: #"(?i)\b(?:explain|solve|answer|do|walk\s+me\s+through|help\s+(?:me\s+)?with|pick|select|choose)\b[^.]{0,100}\b(?:this|problem|question|assignment|homework|worksheet|answer|option)\b|\b(?:this|problem|question|assignment|homework|worksheet)\b[^.]{0,100}\b(?:explain|solve|answer|help|do)\b|\bwhich\s+(?:one|answer|option)\s+is\s+(?:right|correct)\b|\bwhat(?:'?s|\s+is)\s+the\s+(?:right|correct)\s+answer\b"#,
            options: .regularExpression
        ) != nil
    }

    static func decode(
        _ response: String,
        captures: [HomeworkCaptureContext]
    ) -> HomeworkScreenDecoding {
        if let match = firstMatch(notReadablePattern, in: response),
           let stateText = capture(1, match, response),
           let visibility = HomeworkProblemVisibility(
                rawValue: stateText
           ) {
            return .notReadable(visibility: visibility)
        }

        guard let match = firstMatch(clearPattern, in: response),
              let tagRange = Range(match.range, in: response),
              let generationText = capture(1, match, response),
              let generation = UUID(uuidString: generationText),
              let displayText = capture(2, match, response),
              let displayID = UInt32(displayText),
              let fingerprint = capture(3, match, response)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !fingerprint.isEmpty else {
            return .rejected(
                reason:
                    "No readable assignment problem was bound to a current screen capture."
            )
        }
        let matches = captures.filter {
            $0.generation == generation && $0.displayID == displayID
        }
        guard matches.count == 1 else {
            return .rejected(
                reason:
                    "The assignment evidence referenced a stale or unknown display."
            )
        }
        var spoken = response
        spoken.removeSubrange(tagRange)
        return .clear(
            spokenText: spoken,
            problemFingerprint: fingerprint
        )
    }

    private static func firstMatch(
        _ pattern: String,
        in value: String
    ) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern
        ) else { return nil }
        return expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
    }

    private static func capture(
        _ index: Int,
        _ match: NSTextCheckingResult,
        _ value: String
    ) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: value) else {
            return nil
        }
        return String(value[range])
    }
}
