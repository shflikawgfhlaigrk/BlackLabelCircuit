import Foundation

enum BackgroundAgentTerminalKind: String, Equatable, Sendable {
    case completed
    case blocked
    case failed
    case cancelled
}

struct BackgroundAgentTerminalResult: Equatable, Sendable {
    let kind: BackgroundAgentTerminalKind
    let outcome: String
    let verification: String
    let reason: String
    let spokenSummary: String?
}

enum BackgroundAgentProcessFailure: Equatable, Sendable {
    case inputStaging
    case inputAdmissionRefused
    case launch
    case launchAdmissionRefused
    case signal(Int32)
}

/// Converts every Red Agent exit into one app-owned terminal receipt. Model
/// prose may describe work, but it cannot decide whether the run was blocked,
/// failed, cancelled, or completed.
enum BackgroundAgentDeliveryPolicy {
    private static let unsentMessagePattern =
        #"\b(?:email|message|draft|reply|submission|post) (?:(?:was|is|has been) )?not (?:sent|submitted|posted|published)\b"#

    static func terminalResult(
        rawOutput: String,
        timedOut: Bool,
        explicitlyCancelled: Bool,
        processExitStatus: Int32? = nil,
        processFailure: BackgroundAgentProcessFailure? = nil
    ) -> BackgroundAgentTerminalResult {
        if explicitlyCancelled {
            return BackgroundAgentTerminalResult(
                kind: .cancelled,
                outcome: "cancelled",
                verification: "none",
                reason: "The owner stopped the Red Agent run.",
                spokenSummary: nil
            )
        }
        let summary = rawOutput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if timedOut {
            let reason = "Red Agent reached the time limit before returning a result. The task may be incomplete; review its visible progress and artifacts."
            return failed(outcome: "failed.timeout", reason: reason)
        }
        if let processFailure {
            switch processFailure {
            case .inputStaging:
                return failed(
                    outcome: "failed.input-staging",
                    reason: "Red Agent could not stage private input for the customer CLI. No process started."
                )
            case .inputAdmissionRefused:
                return failed(
                    outcome: "failed.input-admission",
                    reason: "Red Agent input admission closed before the customer CLI started. No process started."
                )
            case .launch:
                return failed(
                    outcome: "failed.launch",
                    reason: "Red Agent could not launch the customer CLI. No process started."
                )
            case .launchAdmissionRefused:
                return failed(
                    outcome: "failed.launch-admission",
                    reason: "Red Agent launch admission closed before the customer CLI started. No process started."
                )
            case .signal(let signal):
                return failed(
                    outcome: "failed.signal-\(signal)",
                    reason: summary.isEmpty
                        ? "Red Agent's customer CLI stopped on signal \(signal) without a result. The task is not verified complete."
                        : "Red Agent's customer CLI stopped on signal \(signal). The task is not verified complete. Partial output: \(boundedPartialOutput(summary))"
                )
            }
        }
        if let processExitStatus,
           processExitStatus != 0 {
            return failed(
                outcome: "failed.process-exit-\(processExitStatus)",
                reason: summary.isEmpty
                    ? "Red Agent's customer CLI exited \(processExitStatus) without a result. The task is not verified complete."
                    : "Red Agent's customer CLI exited \(processExitStatus). The task is not verified complete. Partial output: \(boundedPartialOutput(summary))"
            )
        }
        if !summary.isEmpty,
           requiresOwnerInput(ownerFacingSummary(summary)) {
            return BackgroundAgentTerminalResult(
                kind: .blocked,
                outcome: "blocked.owner-input-required",
                verification: "none",
                reason: summary,
                spokenSummary: ownerFacingSummary(summary)
            )
        }
        if !summary.isEmpty,
           explicitlyReportsPendingResult(ownerFacingSummary(summary)) {
            return failed(
                outcome: "failed.unfinished-result",
                reason: "The agent stopped before confirming completion. Its last report was: "
                    + ownerFacingSummary(summary)
            )
        }
        if !summary.isEmpty,
           explicitlyReportsUnverifiedResult(summary) {
            return failed(
                outcome: "failed.unverified-result",
                reason: summary
            )
        }
        if !summary.isEmpty {
            return BackgroundAgentTerminalResult(
                kind: .completed,
                outcome: "completed",
                verification: "reported",
                reason: summary,
                spokenSummary: ownerFacingSummary(summary)
            )
        }
        return failed(
            outcome: "failed.empty-result",
            reason: "Red Agent returned no result. The task is not verified complete."
        )
    }

    static func blocked(
        outcome: String,
        reason: String
    ) -> BackgroundAgentTerminalResult {
        BackgroundAgentTerminalResult(
            kind: .blocked,
            outcome: outcome,
            verification: "none",
            reason: reason,
            spokenSummary: ownerFacingSummary(reason)
        )
    }

    static func failed(
        outcome: String,
        reason: String
    ) -> BackgroundAgentTerminalResult {
        let summary = ownerFacingSummary(reason)
        // An OWNER success claim cannot override contradictory evidence.
        let spokenSummary = outcome == "failed.unverified-result"
            && !explicitlyReportsUnverifiedResult(summary)
            ? "The requested action is unverified."
            : summary
        return BackgroundAgentTerminalResult(
            kind: .failed,
            outcome: outcome,
            verification: "none",
            reason: reason,
            spokenSummary: spokenSummary
        )
    }

    static func cancelled(
        reason: String = "The Red Agent run was interrupted before completion."
    ) -> BackgroundAgentTerminalResult {
        BackgroundAgentTerminalResult(
            kind: .cancelled,
            outcome: "cancelled",
            verification: "none",
            reason: reason,
            spokenSummary: nil
        )
    }

    static func processFailure(
        watchdogFired: Bool,
        terminationReason: Process.TerminationReason,
        exitStatus: Int32
    ) -> BackgroundAgentProcessFailure? {
        guard terminationReason == .uncaughtSignal else { return nil }
        return watchdogFired ? nil : .signal(exitStatus)
    }

    private static func boundedPartialOutput(_ value: String) -> String {
        let singleLine = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard singleLine.count > 500 else { return singleLine }
        return String(singleLine.prefix(499)) + "…"
    }

    /// Red keeps its complete evidence in `reason`, while speech and the
    /// immediate visible answer use only the OWNER line. Legacy providers may
    /// omit the two-line envelope, so the fallback stops before receipt lists
    /// and caps the first useful sentence instead of reading an audit dump.
    private static func ownerFacingSummary(_ value: String) -> String {
        let lines = value.components(separatedBy: .newlines)
        if let ownerLine = lines.first(where: {
            $0.range(
                of: #"(?i)^\s*OWNER\s*:"#,
                options: .regularExpression
            ) != nil
        }) {
            let owner = ownerLine.replacingOccurrences(
                of: #"(?i)^\s*OWNER\s*:\s*"#,
                with: "",
                options: .regularExpression
            )
            return boundedOwnerSentence(withoutReceiptDetails(owner))
        }

        let legacy = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return boundedOwnerSentence(withoutReceiptDetails(legacy))
    }

    private static func withoutReceiptDetails(_ value: String) -> String {
        guard let range = value.range(
            of: #"(?i)(?:^|\s+)(?:[—-]\s*)?(?:receipt\s*:|evidence\s*:|sha[- ]?256\s*[:=]?)"#,
            options: .regularExpression
        ) else { return value }
        return String(value[..<range.lowerBound])
    }

    /// The OWNER line is spoken aloud. A worker that pasted a fetched page,
    /// a Markdown table, or code must not have that read to the owner; keep
    /// the words and drop the markup (2026-09-14 weather-page incident).
    static func spokenPlainText(_ value: String) -> String {
        var text = value
        for (pattern, replacement) in [
            (#"<[^>\n]{1,200}>"#, " "),                       // HTML/XML tags
            (#"```[\s\S]*?```"#, " "),                         // fenced code
            (#"`([^`\n]*)`"#, "$1"),                            // inline code
            (#"!\[[^\]]*\]\([^)]*\)"#, " "),                 // images
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),               // links keep the text
            (#"(?m)^\s{0,3}#{1,6}\s*"#, ""),                   // headings
            (#"(?m)^\s*[-*_]{3,}\s*$"#, " "),                  // rules
            (#"(?m)^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#, " "), // table separators
            (#"[|│┃║╎┆┊┌┐└┘├┤┬┴┼─━═╔╗╚╝╠╣╦╩╬╭╮╯╰▏▕]+"#, " "),   // table and box drawing
            (#"(?<!\w)[*_]{1,3}(?=\S)|(?<=\S)[*_]{1,3}(?!\w)"#, ""), // emphasis
            (#"&nbsp;|&#160;"#, " "),
            (#"&amp;"#, "&"), (#"&lt;"#, "<"), (#"&gt;"#, ">"), (#"&quot;"#, "\""),
        ] {
            text = text.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression
            )
        }
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(
                of: #"\s+([,.;:!?])(?=\s|$)"#, with: "$1", options: .regularExpression
            )
    }

    private static func boundedOwnerSentence(_ value: String) -> String {
        var sentence = spokenPlainText(value).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !sentence.isEmpty else { return "The task returned no readable result." }
        if sentence.count > 700 {
            let bounded = String(sentence.prefix(700))
            if let end = bounded.lastIndex(where: { ".!?".contains($0) }),
               bounded.distance(from: bounded.startIndex, to: end) >= 80 {
                sentence = String(bounded[...end])
            } else if let space = bounded.lastIndex(where: \.isWhitespace) {
                sentence = String(bounded[..<space]) + "…"
            } else {
                sentence = bounded + "…"
            }
        }
        if sentence.last.map({ ".!?".contains($0) }) != true,
           !sentence.hasSuffix("…") {
            sentence += "."
        }
        return sentence
    }

    /// Customer CLIs commonly exit zero after honestly reporting that no work
    /// was proved. Exit zero means the reasoning process finished; it does not
    /// mean the owner's task did. Keep those explicit negative summaries out
    /// of the completed receipt stream.
    private static func requiresOwnerInput(_ value: String) -> Bool {
        // A worker can finish normally while the requested send never starts.
        // Preserve the missing-input state instead of reporting completion.
        if value.range(of: "(?i)" + unsentMessagePattern, options: .regularExpression) != nil,
           value.range(
            of: #"(?i)\b(?:approval|confirmation|authorization|permission|sender|recipient|subject|body)\b[^.!?\n]{0,80}\b(?:missing|required|needed)\b|\b(?:awaiting|waiting for|requires?)\b[^.!?\n]{0,80}\b(?:approval|confirmation|authorization|permission)\b"#,
            options: .regularExpression
           ) != nil {
            return true
        }
        let patterns = [
            #"(?i)^(?:okay[, .]+)?(?:i|we) (?:still )?need (?:the|an?|your|you to)\b"#,
            #"(?i)^(?:please )?(?:tell me|provide|specify|choose|select|confirm)\b[^.!?]{0,240}[?](?:\s|$)"#,
            #"(?i)^(?:which|what)\b[^.!?]{0,240}\b(?:account|service|website|site|file|folder|app|destination|recipient)\b[^.!?]{0,240}[?](?:\s|$)"#,
        ]
        return patterns.contains {
            value.range(of: $0, options: .regularExpression) != nil
        }
    }

    private static func explicitlyReportsPendingResult(_ value: String) -> Bool {
        let normalized = value.lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let patterns = [
            #"\b(?:i(?:'ll| will)|we(?:'ll| will)) (?:wait for|await) (?:the |a |this )?(?:background )?(?:task|job|process|operation)(?:'s)? (?:completion|result|notification)\b"#,
            #"^(?:(?:i am|i'm|we are|we're) )?waiting for (?:the |a |this )?(?:background )?(?:task|job|process|operation)(?:'s)? (?:completion|result|notification)\b"#,
        ]
        return patterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }

    private static func explicitlyReportsUnverifiedResult(
        _ value: String
    ) -> Bool {
        let normalized = value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .replacingOccurrences(of: "’", with: "'")
        let ownerResult = ownerFacingSummary(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
        let terminalFailurePatterns = [
            unsentMessagePattern,
            #"\b(?:review|summary|summarization|inbox check|email check) (?:is |was |remains )?(?:blocked|incomplete|unverified)\b"#,
            #"\b(?:could not|couldn't|cannot|can't|unable to|did not|didn't) (?:read|review|summarize)\b"#,
            #"\b(?:could not|couldn't|cannot|can't|unable to|did not|didn't) (?:produce|provide|generate)\b[^.!?\n]{0,100}\b(?:summary|review|report)\b"#,
            #"\bfailed to (?:close|open|read|categorize|label|complete|finish|perform|execute)\b"#,
            #"\b(?:could not|couldn't|cannot|can't|unable to|did not|didn't) (?:close|categorize|label)\b"#,
            #"\b(?:categorization|window closing|labeling) (?:is |was |remains )?(?:blocked|incomplete|unverified)\b"#,
            #"\b(?:could not|couldn't|cannot|can't|unable to|did not|didn't) (?:send|submit|post|publish)\b"#,
            #"\b(?:requested (?:outcome|task|action)|task|execution|operation) (?:has |had )?failed\b"#,
            #"\bno actionable (?:task|request|instruction)\b"#,
            #"\b(?:could not|couldn't|cannot|can't|unable to) (?:complete|finish|perform|execute|verify|confirm)\b"#,
            #"\b(?:task|action|outcome|operation) (?:is |was |remains )?(?:blocked|incomplete|unverified)\b"#,
        ]
        if terminalFailurePatterns.contains(where: {
            ownerResult.range(of: $0, options: .regularExpression) != nil
        }) {
            return true
        }
        let patterns = [
            #"\bno verified (?:receipt|evidence|result)\b"#,
            #"\bcould not be (?:confirmed|verified|proved)\b"#,
            #"\bcan(?:not|'t) claim\b"#,
            #"\b(?:was|were|is|are) not (?:completed|confirmed|verified|proved)\b"#,
            #"\bi (?:could not|couldn't|did not|didn't|failed to) (?:complete|finish|create|perform|execute|verify|confirm)\b"#,
        ]
        return patterns.contains { pattern in
            normalized.range(
                of: pattern,
                options: .regularExpression
            ) != nil
        }
    }
}
