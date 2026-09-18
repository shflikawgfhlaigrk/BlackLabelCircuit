//
//  StealthExitOnlyPolicy.swift
//  Ace
//
//  Pure admission boundary for the one microphone exception allowed while
//  Stealth is active. The recognized text exists only long enough to classify
//  one exact local phrase; every observable receipt contains only a reason.
//

import Foundation

enum StealthExitOnlyPhraseClassification: Equatable, Sendable {
    case allowed
    case empty
    case extraWords
    case nearMatch
    case notAllowed
}

enum StealthExitOnlyRejectionReason: String, Equatable, Sendable {
    case inactive = "inactive"
    case captureAlreadyActive = "capture-already-active"
    case staleGeneration = "stale-generation"
    case empty = "empty"
    case extraWords = "extra-words"
    case nearMatch = "near-match"
    case notAllowed = "not-allowed"
    case permissionUnavailable = "permission-unavailable"
    case onDeviceRecognizerUnavailable = "on-device-recognizer-unavailable"
    case audioUnavailable = "audio-unavailable"
    case recognitionFailed = "recognition-failed"
    case cancelled = "cancelled"
}

enum StealthExitOnlyCompletion: Equatable, Sendable {
    case exit
    case rejected(StealthExitOnlyRejectionReason)

    var contentFreeReceipt: String {
        switch self {
        case .exit:
            return "accepted reason=exact-allowlist-match"
        case let .rejected(reason):
            return "rejected reason=\(reason.rawValue)"
        }
    }
}

enum StealthExitOnlyPolicy {
    /// This is the single source of truth for both the normal route's legacy
    /// explicit-exit grammar and Stealth's stricter exit-only recognizer.
    /// The normal route may find a phrase within a conversational utterance;
    /// the Stealth exception accepts only a normalized whole-string match.
    static let allowedPhrases = [
        "come back",
        "come out",
        "come out now",
        "reappear",
        "back to normal",
        "show yourself",
        "unhide",
        "come on back",
        "exit stealth",
        "leave stealth",
        "stop stealth",
        "end stealth",
        "stealth off",
        "turn off stealth",
        "disable stealth",
        "unstealth",
        "un stealth",
        "exit private mode",
        "leave private mode",
        "stop private mode",
        "end private mode",
        "private mode off",
        "turn private mode off",
        "disable private mode",
        "wake up",
        "wake me up",
        "get me back",
        "exit steal",
        "leave steal",
        "stop steal",
        "end steal",
        "steal off",
        "exit steel",
        "steel off",
    ] + AceLanguage.allCases.filter { $0 != .system && $0 != .english }
        .map { normalized($0.exitPhrase) }

    static func classify(
        _ recognizedText: String
    ) -> StealthExitOnlyPhraseClassification {
        let candidate = normalized(recognizedText)
        guard !candidate.isEmpty else { return .empty }
        if allowedPhrases.contains(candidate) {
            return .allowed
        }
        if allowedPhrases.contains(where: {
            phraseIsPresent($0, in: candidate)
        }) {
            return .extraWords
        }
        if allowedPhrases.contains(where: {
            isNearMatch(candidate, allowedPhrase: $0)
        }) {
            return .nearMatch
        }
        return .notAllowed
    }

    /// Compatibility grammar for a final that entered the normal route before
    /// the Stealth wall rose. This intentionally retains its prior phrase-
    /// present behavior; only the active-Stealth recognizer is exact-match.
    static func containsAllowedPhrase(_ utterance: String) -> Bool {
        let candidate = normalized(utterance)
        return allowedPhrases.contains(where: {
            phraseIsPresent($0, in: candidate)
        })
    }

    static func normalized(_ utterance: String) -> String {
        let lowered = utterance
            .folding(
                options: [.diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = lowered.replacingOccurrences(
            of: #"[^\p{L}\p{M}0-9\s]"#,
            with: " ",
            options: .regularExpression
        )
        return cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func phraseIsPresent(
        _ phrase: String,
        in utterance: String
    ) -> Bool {
        utterance == phrase
            || utterance.hasPrefix("\(phrase) ")
            || utterance.hasSuffix(" \(phrase)")
            || utterance.contains(" \(phrase) ")
    }

    private static func isNearMatch(
        _ candidate: String,
        allowedPhrase: String
    ) -> Bool {
        // Never make a short ordinary word into an exit. Every allowlisted
        // phrase is at least seven characters, and the threshold stays bounded
        // at two edits even for the longest command.
        guard candidate.count >= 6 else { return false }
        let threshold = allowedPhrase.count >= 12 ? 2 : 1
        return editDistance(candidate, allowedPhrase, limit: threshold)
            <= threshold
    }

    /// Bounded Levenshtein distance with row-minimum early termination. The
    /// strings are tiny voice commands, but the bound prevents arbitrary STT
    /// output from turning this privacy predicate into unbounded work.
    private static func editDistance(
        _ lhs: String,
        _ rhs: String,
        limit: Int
    ) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= limit else {
            return limit + 1
        }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            var rowMinimum = current[0]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = previous[rightIndex]
                    + (leftCharacter == rightCharacter ? 0 : 1)
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                current[rightIndex + 1] = min(
                    substitution,
                    insertion,
                    deletion
                )
                rowMinimum = min(rowMinimum, current[rightIndex + 1])
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }
        return previous[right.count]
    }
}

/// Generation/epoch seal around the classifier. Only a capture begun after the
/// current Stealth entry can lower the wall, and a completion is consumed before
/// classification so duplicate Apple callbacks cannot exit twice.
struct StealthExitOnlyCoordinator: Sendable {
    private var stealthEpoch: UUID?
    private var activeGeneration: UUID?

    mutating func enterStealth(epoch: UUID) {
        stealthEpoch = epoch
        activeGeneration = nil
    }

    mutating func leaveStealth() {
        stealthEpoch = nil
        activeGeneration = nil
    }

    mutating func beginPushToTalk(generation: UUID) -> Bool {
        guard stealthEpoch != nil, activeGeneration == nil else {
            return false
        }
        activeGeneration = generation
        return true
    }

    mutating func cancel(generation: UUID? = nil) {
        if let generation, generation != activeGeneration { return }
        activeGeneration = nil
    }

    mutating func complete(
        generation: UUID,
        finalTranscript: String,
        stealthIsActive: Bool
    ) -> StealthExitOnlyCompletion {
        guard stealthIsActive, stealthEpoch != nil else {
            return .rejected(.inactive)
        }
        guard generation == activeGeneration else {
            return .rejected(.staleGeneration)
        }
        // Consume before inspecting the text. Re-entrant or duplicate finals
        // see a stale generation and cannot lower the wall twice.
        activeGeneration = nil
        switch StealthExitOnlyPolicy.classify(finalTranscript) {
        case .allowed:
            return .exit
        case .empty:
            return .rejected(.empty)
        case .extraWords:
            return .rejected(.extraWords)
        case .nearMatch:
            return .rejected(.nearMatch)
        case .notAllowed:
            return .rejected(.notAllowed)
        }
    }
}
