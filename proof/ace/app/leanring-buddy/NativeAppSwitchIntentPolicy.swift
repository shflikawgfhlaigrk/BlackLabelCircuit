//
//  NativeAppSwitchIntentPolicy.swift
//  Ace
//
//  Pure admission grammar shared by the immutable turn resolver and the
//  AppKit executor. A route accepted here can therefore never be orphaned by
//  a different late parser.
//

import Foundation

nonisolated enum NativeAppSwitchIntentPolicy {
    static func displayQualifiedRequest(from utterance: String) -> (application: String, display: String)? {
        let pattern = #"(?i)^\s*(?:please\s+)?(?:open|launch|switch\s+to|move|put|place)\s+(.+?)(?:\s+and\s+(?:put|move|place)\s+(?:it|its\s+window))?\s+(?:on|to)\s+(?:the\s+|my\s+)?([a-z0-9][a-z0-9 +_-]{0,60}?)\s+(?:monitor|screen|display)\s*[.!?]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: utterance, range: NSRange(utterance.startIndex..., in: utterance)),
              let appRange = Range(match.range(at: 1), in: utterance),
              let displayRange = Range(match.range(at: 2), in: utterance),
              let application = candidate(from: "open " + utterance[appRange]) else { return nil }
        let display = String(utterance[displayRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard display.range(of: #"(?i)\b(?:and|then|but|except)\b"#, options: .regularExpression) == nil else { return nil }
        return (application, display)
    }

    static func displayName(_ name: String, matches query: String) -> Bool {
        func words(_ value: String) -> [String] {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let wanted = words(query), available = words(name)
        return !wanted.isEmpty && wanted.allSatisfy { available.contains($0) }
    }

    static func isAcePanelCandidate(_ candidate: String) -> Bool {
        ["ace", "black label assistant"].contains(
            normalizeCandidate(candidate).lowercased()
        )
    }

    private static let navigationPattern =
        #"(?i)^\s*(?:hey[,\s]+)?(?:ace[,\s]+)?(?:please\s+)?(?:can\s+you\s+)?(?:go\s+to|switch\s+to|switch\s+over\s+to|bring\s+up|pull\s+up|take\s+me\s+to|focus\s+on|open\s+up|open|launch|start|show\s+me)\s+(?:the\s+|my\s+)?(?:app(?:lication)?\s+)?(.+?)[\s.!?]*$"#

    static func candidate(from utterance: String) -> String? {
        guard NativeWebNavigationIntentPolicy.exactURLString(
            from: utterance
        ) == nil,
        !NativeWebNavigationIntentPolicy.explicitlyNamesWebsite(
            utterance
        ) else {
            return nil
        }
        guard let regex = try? NSRegularExpression(
            pattern: navigationPattern
        ), let result = regex.firstMatch(
            in: utterance,
            range: NSRange(utterance.startIndex..., in: utterance)
        ), let candidateRange = Range(
            result.range(at: 1),
            in: utterance
        ) else {
            return nil
        }
        let capturedCandidate = String(utterance[candidateRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = normalizeCandidate(capturedCandidate)
        guard candidate.count >= 2 else { return nil }
        guard candidate.range(
            of: #"(?i)\b(?:page|webpage|web\s*page)\s*$"#,
            options: .regularExpression
        ) == nil else {
            return nil
        }
        let pronounOnly = [
            "it", "that", "this", "that one", "him", "her", "them",
        ]
        guard !pronounOnly.contains(candidate.lowercased()) else {
            return nil
        }
        let boundedCandidate = " " + candidate.lowercased() + " "
        for connective in [
            " in ", " on ", " with ", " and ", " then ", " for ",
            " to ", " from ",
        ] where boundedCandidate.contains(connective) {
            return nil
        }
        return candidate
    }

    /// Speech naturally adds category and urgency words that are not part of
    /// the bundle name: "Safari browser", "Notes app", "Safari right now".
    /// Freeze only the actual application name at admission. A one-word app
    /// literally named Browser remains Browser because suffix removal requires
    /// a preceding name.
    private static func normalizeCandidate(_ rawCandidate: String) -> String {
        var candidate = rawCandidate.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        candidate = candidate.replacingOccurrences(
            of: #"(?i)^(?:(?:the|my|fucking|damn|goddamn)\s+)+"#,
            with: "",
            options: .regularExpression
        )
        var previous = ""
        while previous != candidate {
            previous = candidate
            candidate = candidate.replacingOccurrences(
                of: #"(?i)\s+(?:right\s+now|now|please)\s*$"#,
                with: "",
                options: .regularExpression
            )
            candidate = candidate.replacingOccurrences(
                of: #"(?i)\s+(?:app|application|browser|window)\s*$"#,
                with: "",
                options: .regularExpression
            )
            candidate = candidate.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }
        return candidate
    }
}
