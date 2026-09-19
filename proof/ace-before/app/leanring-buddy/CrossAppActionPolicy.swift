//
//  CrossAppActionPolicy.swift
//  Ace
//
//  Deterministic safety rules for actions that can change another app.
//

import Foundation

struct PendingAgentAction: Equatable {
    let instruction: String
    let requestedAt: Date

    func isCurrent(
        at date: Date,
        lifetime: TimeInterval = CrossAppActionPolicy.confirmationLifetime
    ) -> Bool {
        let age = date.timeIntervalSince(requestedAt)
        return age >= 0 && age <= lifetime
    }
}

enum CrossAppActionPolicy {
    /// Apple Speech has emitted these complete read-only requests with "of"
    /// in place of "at". Restrict recovery to an explicit visual noun.
    static func canonicalizedMicrophonePointRequest(_ utterance: String) -> String {
        let pattern = #"(?i)^\s*(?:please\s+)?(?:look\s+at\s+the\s+current\s+(?:page|screen)\s+and\s+)?point\s+of\s+(?![^.!?]*\b(?:and|then)\b)(?:(?:the|a)\s+)?(?:[\p{L}\p{N}'’ -]+\s+)?(?:heading|button|link|field|menu|tab|label|text)\s*[.!?]*\s*$"#
        guard utterance.range(of: pattern, options: .regularExpression) != nil else {
            return utterance
        }
        return utterance.replacingOccurrences(
            of: #"(?i)\bpoint\s+of\s+"#, with: "point at ",
            options: .regularExpression
        )
    }

    enum EmailReadRoutingDecision: Equatable {
        case notReadRequest
        case unifiedAppleMail
        case gmail
        case unsupportedAccount(String)
    }

    /// A stray "yes" minutes later must never approve an old app mutation.
    static let confirmationLifetime: TimeInterval = 30

    private static let emailNounPattern =
        #"(?i)\b(email|emails|e-?mail|mail|inbox|gmail|google\s+mail|outlook|hotmail|yahoo\s+mail|icloud\s+mail|exchange|microsoft\s+365|office\s+365|fastmail|proton\s*mail|aol\s+mail)\b"#

    // Genuine mail mutations only. Generic verbs (make/add/set/change/…)
    // vetoed reads like "check my inbox and make sure nothing's on fire",
    // which then fell through to the Red Agent instead of the deterministic
    // email-read wrapper.
    private static let emailMutationPattern =
        #"(?i)\b(send|reply|forward|compose|draft|write|delete|remove|archive|move|mark|flag)\b"#

    private static let emailReadVerbPattern =
        #"(?i)\b(check|read|look\s+at|go\s+through|show|scan|summarize|review|tell\s+me\s+about|do\s+i\s+have|have\s+i\s+got|any\s+new|what'?s\s+(?:in|new)|catch\s+me\s+up)\b"#

    private static let webResearchPattern =
        #"(?i)\b(research|google\s+(it|that|this|him|her|them|for)|look\s+(it|that|this)\s+up|look\s+up\s+\w+|search\s+the\s+web|search\s+online|search\s+it\s+up|find\s+out|check\s+(online|the\s+web))\b"#

    /// Every self-contained web lookup grammar freezes one exact query at
    /// admission. Pronoun-only follow-ups stay in the contextual resolver.
    private static let directWebSearchCapturePatterns = [
        #"(?is)^\s*(?:hey[\s,]+)?(?:ace[\s,]+)?(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?search(?:\s+(?:the\s+)?(?:web|internet|google)|\s+online)?(?:\s+for)?\s+(.+?)\s*[.!?]*\s*$"#,
        #"(?is)^\s*(?:hey[\s,]+)?(?:ace[\s,]+)?(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?(?:do\s+a\s+)?web\s+search(?:\s+for)?\s+(.+?)\s*[.!?]*\s*$"#,
        #"(?is)^\s*(?:hey[\s,]+)?(?:ace[\s,]+)?(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?google(?:\s+for)?\s+(.+?)\s*[.!?]*\s*$"#,
        #"(?is)^\s*(?:hey[\s,]+)?(?:ace[\s,]+)?(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?look\s+up\s+(.+?)\s*[.!?]*\s*$"#,
        #"(?is)^\s*(?:hey[\s,]+)?(?:ace[\s,]+)?(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?look\s+(.+?)\s+up\s*[.!?]*\s*$"#,
        #"(?is)^\s*(?:hey[\s,]+)?(?:ace[\s,]+)?(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?research\s+(.+?)\s*[.!?]*\s*$"#,
        #"(?is)^\s*(?:hey[\s,]+)?(?:ace[\s,]+)?(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?(?:check|look)(?:\s+(?:on|at))?\s+(?:the\s+)?(?:web|internet|online)(?:\s+for)?\s+(.+?)\s*[.!?]*\s*$"#,
        #"(?is)^\s*(?:hey[\s,]+)?(?:ace[\s,]+)?(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?find\s+out\s+(.+?)\s+(?:online|on\s+(?:the\s+)?(?:web|internet)|using\s+google)\s*[.!?]*\s*$"#,
        #"(?is)^\s*(?:hey[\s,]+)?(?:ace[\s,]+)?(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?find\s+out\s+(?:online|on\s+(?:the\s+)?(?:web|internet))\s+(?:about\s+)?(.+?)\s*[.!?]*\s*$"#,
    ]

    private static let openTopWebResultTailPattern =
        #"(?i)\s*(?:,?\s*(?:and|then)\s+)?(?:open|visit|take\s+me\s+to)\s+(?:it|that|there|the\s+(?:top\s+)?(?:result|site|website))\s*[.!?]*\s*$"#

    private static let directWebOpenPrefixPattern =
        #"(?i)^\s*(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?(?:open|visit|go\s+to|take\s+me\s+to)\s+"#

    /// Consequential actions always require a second, separate utterance.
    private static let consequentialPattern =
        #"(?i)\b(delete|deleting|remove|removing|erase|wipe|uninstall|empty|trash|send|sending|email|emailing|reply|replying|forward|forwarding|message|text|post|posting|publish|unpublish|tweet|buy|buying|purchase|pay|paying|charge|transfer|withdraw|overwrite|replace|reset|format|drop\s+table|git\s+push|deploy|deploying|revoke|revoking|close|closing|quit|quitting|exit\s+out|clean\s*up|tidy\s*up|declutter|submit|submitting|book|booking|order|ordering|create|creating|make|making|add|adding|schedule|scheduling|set|setting|change|changing|move|moving|rename|renaming|enable|enabling|disable|disabling|toggle|toggling|mute|unmute|pause|skip|play|playing|rewind|fast\s*-?\s*forward|capture|screenshot|record|copy|cut|paste|clear|notify|notification|wallpaper|turn(?:ing)?\b[^.!?]{0,40}\b(?:on|off)|power\s+(?:on|off)|next\s+(?:track|song)|previous\s+(?:track|song)|shortcut)\b"#

    static func requiresConfirmation(_ instruction: String) -> Bool {
        let hasMailNoun = instruction.range(
            of: emailNounPattern,
            options: .regularExpression
        ) != nil
        let hasReadVerb = instruction.range(
            of: emailReadVerbPattern,
            options: .regularExpression
        ) != nil
        let hasMailMutation = instruction.range(
            of: emailMutationPattern,
            options: .regularExpression
        ) != nil
        if hasMailNoun && hasReadVerb && !hasMailMutation {
            return false
        }
        return instruction.range(
            of: consequentialPattern,
            options: .regularExpression
        ) != nil
    }

    static func makePending(
        instruction: String,
        now: Date = Date()
    ) -> PendingAgentAction {
        PendingAgentAction(
            instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
            requestedAt: now
        )
    }

    /// Consequential confirmation is one unique whole utterance. Generic
    /// agreement ("yes", "go ahead", "do it") is ordinary conversation and
    /// never inherits authority for a stored action.
    static func isExplicitConfirmation(_ utterance: String) -> Bool {
        utterance.range(
            of: #"(?i)^\s*confirm\s*[.!?]*\s*$"#,
            options: .regularExpression
        ) != nil
    }

    static func isExplicitCancellation(_ utterance: String) -> Bool {
        utterance.range(
            of: #"(?i)^\s*(?:no|cancel|stop|never\s+mind|don'?t|do\s+not)\s*[.!?]*\s*$"#,
            options: .regularExpression
        ) != nil
    }

    static func explicitAgentTask(_ text: String) -> String? {
        let directTrigger = text.range(
            of: #"(?i)^\s*(?:hey\s+)?(?:agent|worker|red\s+agent|background\s+agent|black\s+label)[\s,:]+"#,
            options: .regularExpression
        )
        let assignmentTrigger = text.range(
            of: #"(?i)\b(?:(?:assign|send)\s+(?:the\s+)?(?:red\s+agent|background\s+agent|worker)\s+to|use\s+(?:the\s+)?(?:red\s+agent|background\s+agent|worker)(?:\s+to)?)\s+"#,
            options: .regularExpression
        )

        let trigger: Range<String.Index>
        if let directTrigger {
            trigger = directTrigger
        } else if let assignmentTrigger {
            let prefix = String(text[..<assignmentTrigger.lowerBound])
            let isNegated = prefix.range(
                of: #"(?i)\b(?:don['’]?t|do\s+not|never|not\s+to)\b[^.!?]{0,80}$"#,
                options: .regularExpression
            ) != nil
            let isHistoryQuestion = prefix.range(
                of: #"(?i)^\s*(?:(?:why|when|where)\s+)?(?:did|do|does|has|have|had|was|were)\s+(?:i|you|we|they|he|she|it)\b[^.!?]*$|^\s*how\s+(?:do|does|did|can|could|would|should)\s+(?:i|you|we|they|he|she|it)\b[^.!?]*$"#,
                options: .regularExpression
            ) != nil
            guard !isNegated, !isHistoryQuestion else { return nil }
            trigger = assignmentTrigger
        } else {
            return nil
        }
        let task = text[trigger.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return task.isEmpty ? nil : task
    }

    /// Read back enough to identify the target without making a long dictated
    /// body monopolize the voice lane.
    static func spokenPreview(_ instruction: String, limit: Int = 140) -> String {
        let singleLine = instruction
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(max(1, limit - 1))) + "…"
    }

    /// Effectful software fast paths use positive, whole-request grammar.
    /// Searching for keywords anywhere made questions and negations execute.
    static func isUnambiguousNotesStartRequest(_ text: String) -> Bool {
        let request = text.replacingOccurrences(
            of: #"(?i)^\s*hey(?:[,!]\s*|\s+)"#,
            with: "",
            options: .regularExpression
        )
        return request.range(
            of: #"(?i)^\s*(?:please\s+)?(?:(?:can|could|would)\s+you\s+(?:please\s+)?)?(?:(?:take|keep)\s+(?:some\s+)?notes?|(?:start|begin|keep)\s+(?:(?:taking\s+)?notes?|(?:the\s+)?note[ -]?tak(?:er|ing))|join\s+(?:(?:this|the|my|our|a)\s+)?(?:meeting|call)|transcribe\s+(?:(?:this|the|my|our|a)\s+)?(?:meeting|call)|transcribe\s+this)(?:\s+(?:for|during|on)\s+(?:(?:this|the|my|our|a)\s+)?(?:meeting|call|conversation|lecture|class))?(?:\s+for\s+me)?(?:\s+(?:now|please))?\s*[.!?]*\s*$"#,
            options: .regularExpression
        ) != nil
    }

    /// Whole-request meeting-capture stops stay separate from the global
    /// silence command and from app switching. Questions, negations, and
    /// commands for other apps therefore cannot end an active capture.
    static func isUnambiguousNotesStopRequest(
        _ text: String,
        captureIsActive: Bool = false
    ) -> Bool {
        if captureIsActive,
           text.range(
               of: #"(?i)^\s*(?:note|notes|no|not|taking\s+notes?)\s*[.!?]*\s*$"#,
               options: .regularExpression
           ) != nil {
            return true
        }
        return text.range(
            of: #"(?i)^\s*(?:please\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:stop|end|finish|wrap(?:\s+up)?)\s+(?:(?:the\s+)?(?:meeting|call)\s+notes?|(?:taking|keeping)\s+notes?|notes?|note ?-?taking|note ?-?taker|notetaking|transcribing(?:\s+(?:this|the\s+)?(?:meeting|call))?)(?:\s+(?:(?:taking|keeping)\s+)?notes?)?[.!?]*\s*$"#,
            options: .regularExpression
        ) != nil
    }

    static func isTestEmailSendRequest(_ text: String) -> Bool {
        text.range(
            of: #"(?i)^\s*(?:please\s+)?(?:(?:can|could|would)\s+you\s+)?(?:send|shoot|fire\s+off)\s+(?:me\s+)?(?:a\s+)?test(?:ing)?\s+e-?mail(?:\s+(?:now|please))?\s*[.!?]*\s*$"#,
            options: .regularExpression
        ) != nil
    }

    static func isRepeatResponseRequest(_ text: String) -> Bool {
        text.range(
            of: #"(?i)^\s*(?:please\s+)?(?:(?:can|could|would)\s+you\s+)?(?:say\s+(?:that|it)(?:\s+(?:again|one\s+more\s+time))|repeat\s+(?:that|it|your\s+(?:last\s+)?(?:answer|response)|what\s+you\s+(?:just\s+)?said)|what\s+did\s+you\s+(?:just\s+)?say)(?:\s+please)?\s*[.!?]*\s*$"#,
            options: .regularExpression
        ) != nil
    }

    static func isEmailReadRequest(_ text: String) -> Bool {
        guard text.range(
            of: emailNounPattern,
            options: .regularExpression
        ) != nil else { return false }
        guard text.range(
            of: emailMutationPattern,
            options: .regularExpression
        ) == nil else { return false }
        guard text.range(
            of: #"(?i)^\s*(?:don'?t|do\s+not|how\s+(?:do|can|would)|did\s+you|have\s+you|why\s+(?:did|would)|what\s+happens\s+if)\b"#,
            options: .regularExpression
        ) == nil else { return false }
        return text.range(
            of: emailReadVerbPattern,
            options: .regularExpression
        ) != nil
    }

    /// A named provider must retain its account boundary through execution.
    static func emailReadRoutingDecision(
        _ text: String
    ) -> EmailReadRoutingDecision {
        guard isEmailReadRequest(text) else { return .notReadRequest }
        if let account = explicitlyNamedEmailAccount(in: text) {
            if account == "Gmail", text.range(of: #"(?i)\b(outlook|hotmail|yahoo|icloud|exchange|office\s+365|microsoft\s+365|fastmail|proton|aol|apple\s+mail)\b"#, options: .regularExpression) == nil {
                return .gmail
            }
            return .unsupportedAccount(account)
        }
        if text.range(of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+"#, options: .regularExpression) != nil {
            return .gmail
        }
        return .unifiedAppleMail
    }

    /// The fixed reader defaults to five messages, or up to 100 for a week.
    /// Only count, unread and validated date boundaries cross into the tool.
    /// No mailbox text is ever interpreted as another action.
    static func emailReadArguments(for utterance: String, now: Date = Date(), calendar: Calendar = .current) -> [String] {
        let window = EmailReadWindow.requested(in: utterance, now: now, calendar: calendar)
        let lowercased = utterance.lowercased().replacingOccurrences(
            of: EmailReadWindow.phrasePattern, with: "", options: .regularExpression
        )
        var requestedCount: Int?
        var invalidExplicitCount = false

        if let regex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])(-?[0-9]+)\b"#
        ), let match = regex.firstMatch(
            in: lowercased,
            range: NSRange(lowercased.startIndex..., in: lowercased)
        ), let captureRange = Range(
            match.range(at: 1),
            in: lowercased
        ) {
            if let parsedCount = Int(lowercased[captureRange]),
               (1...20).contains(parsedCount) {
                requestedCount = parsedCount
            } else {
                invalidExplicitCount = true
            }
        }

        // Do not reinterpret an out-of-range compound such as "twenty one"
        // as the valid prefix "twenty". It uses the safe newest-five default,
        // matching the numeric out-of-range behavior and the Windows parser.
        if lowercased.range(
            of: #"\btwenty(?:[\s-]+(?:one|two|three|four|five|six|seven|eight|nine))\b"#,
            options: .regularExpression
        ) != nil {
            invalidExplicitCount = true
        }

        if requestedCount == nil, !invalidExplicitCount {
            let numberWords: [(String, Int)] = [
                ("twenty", 20), ("nineteen", 19), ("eighteen", 18),
                ("seventeen", 17), ("sixteen", 16), ("fifteen", 15),
                ("fourteen", 14), ("thirteen", 13), ("twelve", 12),
                ("eleven", 11), ("ten", 10), ("nine", 9), ("eight", 8),
                ("seven", 7), ("six", 6), ("five", 5), ("four", 4),
                ("three", 3), ("two", 2), ("one", 1),
            ]
            requestedCount = numberWords.first { word, _ in
                lowercased.range(
                    of: #"\b\#(word)\b"#,
                    options: .regularExpression
                ) != nil
            }?.1
        }

        if requestedCount == nil,
           !invalidExplicitCount,
           lowercased.range(
               of: #"\b(?:latest|last|newest)\s+(?:email|message)\b"#,
               options: .regularExpression
           ) != nil {
            requestedCount = 1
        }

        let unreadOnly = lowercased.range(
            of: #"\b(?:unread|new)\b"#,
            options: .regularExpression
        ) != nil
        var arguments: [String]
        if let requestedCount {
            arguments = unreadOnly
                ? [String(requestedCount), "unread"]
                : [String(requestedCount)]
        } else if window != nil {
            arguments = unreadOnly ? ["100", "unread"] : ["100"]
        } else {
            arguments = unreadOnly ? ["unread"] : []
        }
        return arguments + (window?.arguments ?? [])
    }

    static func isEmailSummaryFollowUp(_ text: String) -> Bool {
        if text.range(of: #"(?i)^\s*(?:no[,\s]+)?(?:i\s+)?(?:just\s+)?(?:need|want)\s+(?:what\s+is\s+important\s+(?:for|from)\s+last\s+week|(?:a\s+)?summary\s+of\s+(?:that|those|them|last\s+week))(?:[,\s]+just\s+(?:a\s+)?summary)?(?:[,.\s]+you\s+don['’]?t\s+need\s+to\s+say\s+everything)?\s*[.!?]*\s*$"#, options: .regularExpression) != nil { return true }
        return text.range(of: #"(?i)^\s*(?:please\s+)?(?:just\s+)?(?:a\s+)?(?:summary(?:\s+of\s+(?:that|those|them|last\s+week|the\s+(?:last|past)\s+week))?|summari[sz]e\s+(?:that|those|them)|what(?:'s|\s+is)\s+important(?:\s+(?:there|in\s+(?:that|those|them)))?|make\s+(?:that|it)\s+shorter|(?:just\s+)?the\s+highlights)\s*[.!?]*\s*$"#, options: .regularExpression) != nil
    }

    private static func explicitlyNamedEmailAccount(
        in text: String
    ) -> String? {
        let namedAccounts: [(label: String, pattern: String)] = [
            ("Gmail", #"(?i)\b(?:gmail|google\s+mail)\b"#),
            ("Outlook", #"(?i)\b(?:outlook|hotmail|microsoft\s+365|office\s+365)\b"#),
            ("Yahoo Mail", #"(?i)\byahoo(?:\s+mail)?\b"#),
            ("iCloud Mail", #"(?i)\bicloud(?:\s+mail)?\b"#),
            ("Exchange", #"(?i)\bexchange\b"#),
            ("Fastmail", #"(?i)\bfastmail\b"#),
            ("Proton Mail", #"(?i)\bproton\s*mail\b"#),
            ("AOL Mail", #"(?i)\baol\s+mail\b"#),
            (
                "the named work or personal account",
                #"(?i)\b(?:work|personal|business|company|school)\s+(?:email|e-?mail|mail|inbox)\b"#
            ),
        ]
        return namedAccounts.first { account in
            text.range(
                of: account.pattern,
                options: .regularExpression
            ) != nil
        }?.label
    }

    /// Positive compose/reply/forward grammar is a deterministic planner
    /// route even when the owner omits the word "email" ("reply to Pat").
    /// Questions, history checks, and negations never become action requests.
    static func isExplicitEmailAuthoringRequest(_ text: String) -> Bool {
        text.range(
            of: #"(?i)^\s*(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?(?:reply\s+to\b|(?:reply|forward|compose)\b[^.!?]*\b(?:e-?mail|message|thread|inbox|sender|recipient)\b|forward\s+(?:this|that|it)\s+to\b)"#,
            options: .regularExpression
        ) != nil
    }

    static func isOutboundEmailRequest(_ text: String) -> Bool {
        // The question veto is anchored to the utterance start; a mid-sentence
        // "how" clause only vetoes when it directly governs a mail verb
        // ("tell me how to send an email"), never when it merely describes
        // content ("send Pat an email showing how to reset the password").
        guard text.range(
            of: #"(?i)^\s*(?:don'?t|do\s+not|how|why|when|where|who|which|what|did|have|do\s+you|are\s+you)\b|\bhow\s+(?:to|do\s+i|can\s+i|should\s+i|would\s+i)\s+(?:send|email|e-?mail|reply|forward|compose|draft|write)\b"#,
            options: .regularExpression
        ) == nil else {
            return false
        }
        if isExplicitEmailAuthoringRequest(text) {
            return true
        }
        let hasMailNoun = text.range(
            of: emailNounPattern,
            options: .regularExpression
        ) != nil
        let hasOutboundVerb = text.range(
            of: #"(?i)\b(send|email|reply|forward|compose|draft|write)\b"#,
            options: .regularExpression
        ) != nil
        return hasMailNoun && hasOutboundVerb && !isEmailReadRequest(text)
    }

    static func isPermissionWarmupRequest(_ text: String) -> Bool {
        text.range(
            of: #"(?i)^\s*(?:please\s+)?(?:(?:(?:can|could|would)\s+you\s+)?(?:(?:grant|give)\s+(?:yourself\s+|ace\s+)?(?:full\s+)?(?:access|permissions?)|(?:run|start|do)\s+(?:the\s+)?permission\s+(?:setup|check|warm ?-?up)|warm ?-?up\s+(?:your\s+)?(?:permissions?|access)|set\s+yourself\s+up|authorize\s+(?:yourself|everything)))\s*[.!?]*\s*$"#,
            options: .regularExpression
        ) != nil
    }

    /// Direct "search …" imperatives and explicit research phrases enter the
    /// native web planner. Questions, history checks, and negations never do.
    static func isWebResearchCommand(_ text: String) -> Bool {
        if directWebSearchActionArguments(text) != nil {
            return true
        }
        guard text.range(
            of: #"(?i)^\s*(?:don'?t|do\s+not|how|why|when|where|who|which|what|did|have|are\s+you|do\s+you)\b"#,
            options: .regularExpression
        ) == nil else {
            return false
        }
        return text.range(
            of: webResearchPattern,
            options: .regularExpression
        ) != nil
    }

    /// Self-contained searches do not need a model round trip. Return the
    /// exact arguments for the existing web-search wrapper; unresolved
    /// references and compound questions remain contextual.
    static func directWebSearchActionArguments(
        _ text: String
    ) -> [String]? {
        guard let captured = firstDirectWebSearchQuery(in: text) else {
            return nil
        }
        var query = captured
        let opensTopResult = query.range(
            of: openTopWebResultTailPattern,
            options: .regularExpression
        ) != nil
        query = query.replacingOccurrences(
            of: openTopWebResultTailPattern,
            with: "",
            options: .regularExpression
        ).replacingOccurrences(
            of: #"\s*[.!?]+\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let unresolvedReference = query.range(
            of: #"(?i)^(?:it|that|this|him|her|them)(?:\s+(?:on|using)\s+(?:google|(?:the\s+)?(?:web|internet)))?$"#,
            options: .regularExpression
        ) != nil
        guard !query.isEmpty,
              query.count <= 1_000,
              !unresolvedReference,
              query.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }
        return opensTopResult
            ? ["--open-first", query]
            : [query]
    }

    private static func firstDirectWebSearchQuery(
        in text: String
    ) -> String? {
        for pattern in directWebSearchCapturePatterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern
            ), let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ), match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            return String(text[range]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }
        return nil
    }

    /// Exact public URL imperatives bypass language-model planning. A bare
    /// domain is normalized to HTTPS; app names and prose cannot pass as URLs.
    static func directWebOpenActionArguments(
        _ text: String
    ) -> [String]? {
        if let exactURL = NativeWebNavigationIntentPolicy.exactURLString(
            from: text
        ) {
            return ["--open", exactURL]
        }
        guard text.range(
            of: #"(?i)^\s*(?:don'?t|do\s+not)\b"#,
            options: .regularExpression
        ) == nil,
        let prefixRange = text.range(
            of: directWebOpenPrefixPattern,
            options: .regularExpression
        ) else {
            return nil
        }

        var candidate = String(text[prefixRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        candidate = candidate.replacingOccurrences(
            of: #"[.!]+\s*$"#,
            with: "",
            options: .regularExpression
        )
        guard !candidate.isEmpty,
              candidate.rangeOfCharacter(
                from: .whitespacesAndNewlines
              ) == nil else {
            return nil
        }

        let suppliedScheme =
            candidate.range(
                of: #"(?i)^https?://"#,
                options: .regularExpression
            ) != nil
        let normalized = suppliedScheme
            ? candidate
            : "https://\(candidate)"
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              suppliedScheme || host.contains(".") else {
            return nil
        }
        return ["--open", normalized]
    }
}
