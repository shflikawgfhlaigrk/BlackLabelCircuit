import Foundation

enum LocalIntent: Equatable, Sendable {
    case presence
    case workStatus
    case capabilities
    case stealthHelp
    case installedIdentity
    case updateDownload
    case explicitMemory
    case workflow
}

enum ExplicitMemoryIntent: Equatable, Sendable {
    case remember(String)
    case recall
    case forgetLast
    case clear
}

/// Fast, value-only routing for commands whose answer is entirely local. It
/// strips address/filler prefixes before classification so “Ace”, “agent”, and
/// “Red Agent” cannot push an otherwise deterministic request into a model lane.
enum LocalIntentPolicy {
    /// Immutable ICU expressions are compiled once and shared across turns.
    /// An invalid source pattern keeps the previous no-match behavior.
    private struct RoutingExpression: Sendable {
        private let expression: NSRegularExpression?

        init(_ pattern: String) {
            expression = try? NSRegularExpression(pattern: pattern)
        }

        func range(in text: String) -> Range<String.Index>? {
            guard let match = expression?.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)
            ) else { return nil }
            return Range(match.range, in: text)
        }
    }

    private static let addressPrefixPattern =
        RoutingExpression(#"(?i)^\s*(?:(?:hey|hi|okay|ok|so)\b[\s,.:;-]*)?(?:(?:red\s+)?agent|ace)\b[\s,.:;-]*"#)
    private static let politePrefixPattern =
        RoutingExpression(#"(?i)^\s*(?:so\b[\s,.:;-]*|please\b[\s,.:;-]*)+"#)
    private static let capabilityPatterns = [
        #"(?i)^what\s+do\s+you\s+do$"#,
        #"(?i)^what\s+(?:all\s+|exactly\s+)?can\s+(?:you|ace)\s+do(?:\s+and\s+what\s+can\s+(?:you|ace)\s+not\s+do)?$"#,
        #"(?i)^is\s+there\s+anything\s+(?:you|ace)\s+(?:cannot|can'?t)\s+do(?:\s+on\s+my\s+computer)?$"#,
        #"(?i)^can\s+(?:you|ace)\s+access\s+my\s+mail,?\s+calendar,?\s+notes,?\s+reminders,?\s+and\s+files$"#,
        #"(?i)^what\s+(?:are\s+you|is\s+ace)\s+able\s+to\s+help(?:\s+me)?\s+with$"#,
        #"(?i)^what\s+(?:all\s+|exactly\s+)?can\s+(?:you|ace)\s+help(?:\s+me)?\s+with$"#,
        #"(?i)^what\s+are\s+you\s+capable\s+of$"#,
        #"(?i)^(?:tell|show)\s+me\s+what\s+(?:you|ace)\s+can\s+do$"#,
        #"(?i)^how\s+(?:can\s+you|are\s+you\s+able\s+to)\s+help(?:\s+me)?$"#,
        #"(?i)^what\s+does\s+ace\s+do$"#,
    ].map(RoutingExpression.init)
    private static let presencePatterns = [
        #"(?i)^(?:hey[\s,]+)?(?:who\s+are\s+you|how\s+are\s+you|are\s+you\s+there|you\s+there)$"#,
    ].map(RoutingExpression.init)
    /// Stealth is an app-owned mode with one exact entry command. Questions
    /// about it must never pay provider latency or alter the privacy latch,
    /// microphone, visibility, or the work already in flight.
    private static let stealthHelpPatterns = [
        #"(?i)^(?:how|what|why|when|where|who|would|could|can|should|is|does|do|did|will)\b.*\b(?:stealth|private|ghost)(?:\s+mode)?\b.*$"#,
        #"(?i)^(?:explain|tell\s+me|show\s+me|teach\s+me)\b.*\b(?:stealth|private|ghost)(?:\s+mode)?\b.*$"#,
        // Apple Speech can drop the low-energy word "stealth" from both
        // halves of Major's paired question. This exact question-only shape
        // remains non-destructive; it must never become an entry command.
        #"(?i)^how\s+do\s+i\s+put\s+you\s+(?:in|into)(?:\s*\?\s*|\s+)how\s+do\s+i\s+get\s+you\s+out$"#,
    ].map(RoutingExpression.init)
    private static let workStatusPatterns = [
        #"(?i)^(?:hey[\s,]+)?(?:wyd|what\s+you|what\s+(?:are\s+)?you\s+doing|what\s+have\s+you\s+been\s+doing)$"#,
        #"(?i)^what\s+(?:are\s+you|is\s+(?:ace|red|partner))\s+working\s+on$"#,
        #"(?i)^what(?:'?s|\s+is)\s+(?:still\s+)?running$"#,
        #"(?i)^are\s+you\s+(?:still\s+)?working\s+on\s+(?:what\s+i\s+just\s+told\s+you|that|it|the\s+last\s+thing)$"#,
        #"(?i)^are\s+you\s+(?:still\s+)?working\s+on\s+(?:my\s+request|the\s+(?:request|task)|the\s+thing\s+i\s+asked\s+you\s+to\s+do)$"#,
        #"(?i)^(?:what(?:'?s|\s+is)\s+the\s+status|give\s+me\s+(?:a\s+)?status)(?:\s+of\s+(?:that|the\s+last\s+thing))?$"#,
        #"(?i)^(?:how(?:'?s|\s+is)\s+that\s+going|where\s+are\s+you\s+at\s+with\s+that|is\s+that\s+still\s+running)$"#,
        #"(?i)^(?:did\s+(?:that|it|the\s+last\s+thing)\s+finish|what\s+happened\s+(?:with|to)\s+(?:that|the\s+last\s+thing))$"#,
    ].map(RoutingExpression.init)
    /// Ace's own installed identity is sealed into the running bundle. Direct
    /// questions about that identity must not reach a provider that cannot
    /// inspect the app and may guess or report that the value is unavailable.
    private static let installedIdentityPatterns = [
        #"(?i)^(?:what|which)\s+(?:ace\s+)?(?:version|build)(?:\s+of\s+ace)?\s+(?:are\s+you|is\s+ace)\s+(?:currently\s+)?(?:running|using)(?:\s+(?:right\s+now|on\s+this\s+mac))?(?:\s+(?:answer\s+directly|do\s+not\s+use\s+red))*$"#,
        #"(?i)^(?:what|which)\s+(?:ace\s+)?(?:version|build)\s+do\s+i\s+have(?:\s+on\s+this\s+mac)?(?:\s+(?:answer\s+directly|do\s+not\s+use\s+red))*$"#,
        #"(?i)^(?:what|which)\s+(?:ace\s+)?(?:version|build)\s+is\s+installed(?:\s+on\s+this\s+mac)?(?:\s+(?:answer\s+directly|do\s+not\s+use\s+red))*$"#,
        #"(?i)^(?:what|which)\s+(?:ace\s+)?(?:version|build)\s+am\s+i\s+(?:running|using)(?:\s+(?:answer\s+directly|do\s+not\s+use\s+red))*$"#,
        #"(?i)^(?:what|which)\s+(?:version|build)\s+of\s+ace\s+(?:do\s+i\s+have|is\s+installed|am\s+i\s+(?:running|using))(?:\s+on\s+this\s+mac)?(?:\s+(?:answer\s+directly|do\s+not\s+use\s+red))*$"#,
    ].map(RoutingExpression.init)
    /// Updating Ace is a product-owned action. It must never pay provider
    /// latency. Explicit page navigation is distinguished from installation at
    /// execution, so "open my account" can never replace the running app.
    private static let updatePagePattern = RoutingExpression(
        #"(?i)^(?:open|show|take\s+me\s+to)\s+(?:the\s+)?(?:ace\s+)?(?:account|download|update)(?:\s+page)?$"#
    )
    static func requestsUpdateBrowserPage(_ utterance: String) -> Bool {
        updatePagePattern.range(in: normalizedRoutingText(utterance)) != nil
    }

    private static let updateDownloadPatterns = [
        #"(?i)^(?:open|show|take\s+me\s+to)\s+(?:the\s+)?(?:ace\s+)?(?:account|download|update)(?:\s+page)?$"#,
        #"(?i)^(?:download|get|install)\s+(?:me\s+)?(?:the\s+)?(?:latest|newest|current|\d+(?:\.\d+){1,3})\s+(?:ace\s+)?(?:version|build|update)$"#,
        #"(?i)^(?:download|get|install)\s+(?:the\s+)?(?:latest|newest|current)\s+(?:version|build|update)\s+of\s+ace$"#,
        #"(?i)^(?:download|get|install)\s+ace(?:\s+(?:version\s+)?\d+(?:\.\d+){1,3})?$"#,
        #"(?i)^(?:update|upgrade)\s+ace(?:\s+to\s+(?:the\s+)?(?:latest|newest|current|version\s+\d+(?:\.\d+){1,3}|\d+(?:\.\d+){1,3}))?$"#,
    ].map(RoutingExpression.init)
    private static let disqualifyingWorkflowPattern =
        RoutingExpression(#"(?i)^(?:don'?t|do\s+not|never|how\s+(?:do|would|can|should)|what\s+(?:if|would|happens)|why|when|where|who|which|did\s+you|have\s+you|are\s+you|should\s+i|is\s+it)\b"#)
    private static let workflowOpenerPattern =
        RoutingExpression(#"(?i)^(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:build|make|create|put\s+together|set\s+up|generate|design|code|write)\b"#)
    private static let workflowDeliverablePattern =
        RoutingExpression(#"(?i)\b(dashboard|tracker|app|site|website|web\s*page|webpage|page|tool|report|planner|board|panel|visuali[sz]ation|chart|graph|spreadsheet|script|widget|portal|hub|overview|summary\s+page|landing\s+page|project)\b"#)
    private static let singleEffectPattern =
        RoutingExpression(#"(?i)\b(note|email|e-?mail|draft|reminder|event|meeting|timer|screenshot|playlist|contact)\b"#)

    static let capabilityVisibleResponse = """
    Ace can operate this Mac with the logged-in user's authority. That includes apps, websites, files, Mail, Calendar, Reminders, Notes, system controls, and the ability to click, type, write, search, build, install, and run work. A specific action can still depend on a live macOS permission, account connection, network service, target, or provider session.
    """

    static let capabilitySpokenResponse = """
    i can operate this mac with the logged-in user's authority, including apps, websites, files, mail, calendar, reminders, notes, system controls, and the ability to click, type, write, search, build, install, and run work. a specific action can still depend on a live mac os permission, account connection, network service, target, or provider session.
    """

    static let presenceSpokenResponse =
        "i'm here, awake, and ready for your next request."

    static let stealthHelpResponse = """
    Stealth is Ace's hidden multiple-choice mode. To enter, say “go stealth” exactly. With Caps Lock on, press Shift + Z to answer the visible multiple-choice question while Ace stays hidden. To return, hold Command + Shift and say “exit stealth.” Questions about Stealth only explain it; they never change visibility, the microphone, or current work.
    """

    static func classify(_ utterance: String) -> LocalIntent? {
        let normalized = normalizedRoutingText(utterance)
        if explicitMemoryIntent(utterance) != nil {
            return .explicitMemory
        }
        if presencePatterns.contains(where: {
            $0.range(in: normalized) != nil
        }) {
            return .presence
        }
        if workStatusPatterns.contains(where: {
            $0.range(in: normalized) != nil
        }) {
            return .workStatus
        }
        if capabilityPatterns.contains(where: {
            $0.range(in: normalized) != nil
        }) {
            return .capabilities
        }
        if stealthHelpPatterns.contains(where: {
            $0.range(in: normalized) != nil
        }) {
            return .stealthHelp
        }
        let punctuationFolded = normalized
            .replacingOccurrences(
                of: #"[^a-zA-Z0-9\s]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if installedIdentityPatterns.contains(where: {
            $0.range(in: punctuationFolded) != nil
        }) {
            return .installedIdentity
        }
        if updateDownloadPatterns.contains(where: {
            $0.range(in: normalized) != nil
        }) {
            return .updateDownload
        }
        if isWorkflowRequest(normalized) {
            return .workflow
        }
        return nil
    }

    static func normalizedWorkflowRequest(
        _ utterance: String
    ) -> String? {
        let normalized = normalizedRoutingText(utterance)
        return isWorkflowRequest(normalized) ? normalized : nil
    }

    static func shouldIncludeRecentTerminal(_ utterance: String) -> Bool {
        guard classify(utterance) == .workStatus else { return false }
        let normalized = normalizedRoutingText(utterance).lowercased()
        return normalized.contains("have you been doing")
            || normalized.hasPrefix("did ")
            || normalized.hasPrefix("what happened ")
    }

    static func explicitMemoryIntent(_ utterance: String) -> ExplicitMemoryIntent? {
        let input = normalizedRoutingText(utterance, preservingContent: true)
        let recall = #"(?i)^(?:what\s+do\s+you\s+remember(?:\s+about\s+me)?|what\s+have\s+i\s+asked\s+you\s+to\s+remember|what(?:['’]s|\s+is)\s+in\s+your\s+memory|what\s+do\s+you\s+know\s+about\s+me)[.!?]*$"#
        if input.range(of: recall, options: .regularExpression) != nil { return .recall }
        if input.range(of: #"(?i)^forget\s+(?:that|the\s+last\s+(?:thing|one))[.!?]*$"#, options: .regularExpression) != nil { return .forgetLast }
        if input.range(of: #"(?i)^forget\s+everything(?:\s+you\s+(?:remember|know))?[.!?]*$"#, options: .regularExpression) != nil { return .clear }
        let prefix = #"(?i)^(?:(?:(?:can|could|would|will)\s+you(?:\s+please)?|i\s+(?:want|need)\s+you\s+to|go\s+ahead\s+and)\s+)?remember\s+(?:that\s+)?(?!when\b|what\b|how\b|where\b|who\b|why\b|if\b|me\b|us\b|anything\b)"#
        guard let range = input.range(of: prefix, options: .regularExpression) else { return nil }
        let content = String(input[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.count >= 3 ? .remember(content) : nil
    }

    static func normalizedRoutingText(_ utterance: String, preservingContent: Bool = false) -> String {
        var normalized = utterance
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !preservingContent { normalized = normalized.replacingOccurrences(of: "’", with: "'") }

        // “please, Ace” and “Ace, please” are both ordinary speech. Iterate
        // because stripping one prefix can expose the other.
        for _ in 0..<3 {
            let before = normalized
            normalized = removingPrefix(
                politePrefixPattern,
                from: normalized
            )
            normalized = removingPrefix(
                addressPrefixPattern,
                from: normalized
            )
            if normalized == before { break }
        }

        if preservingContent { return normalized.trimmingCharacters(in: .whitespacesAndNewlines) }

        normalized = normalized
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(
                    CharacterSet(charactersIn: ".!?"))
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
        return normalized
    }

    private static func isWorkflowRequest(
        _ normalized: String
    ) -> Bool {
        guard disqualifyingWorkflowPattern.range(in: normalized) == nil else {
            return false
        }
        guard workflowOpenerPattern.range(in: normalized) != nil,
        let deliverableRange = workflowDeliverablePattern.range(in: normalized) else {
            return false
        }
        if let singleEffectRange = singleEffectPattern.range(in: normalized), singleEffectRange.lowerBound < deliverableRange.lowerBound {
            return false
        }
        return true
    }

    private static func removingPrefix(
        _ pattern: RoutingExpression,
        from text: String
    ) -> String {
        guard let range = pattern.range(in: text) else {
            return text
        }
        return String(text[range.upperBound...])
    }
}
