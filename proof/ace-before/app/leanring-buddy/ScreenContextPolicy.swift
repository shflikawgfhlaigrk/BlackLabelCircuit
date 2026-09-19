import Foundation

enum ScreenContextScope: Equatable, Sendable {
    case none
    case relevantDisplay
    case allDisplays
}

/// Decides how much of the owner's screen an interactive Gold request needs.
/// Explicit visual wording receives the cursor display, explicit cross-monitor
/// wording receives every display, and nonvisual questions/actions avoid image
/// upload entirely. Explicitly ambiguous or deictic wording fails toward one
/// display so Ace does not silently answer a visual request blind.
enum ScreenContextPolicy {
    /// Partner's JSON envelope cannot carry the coordinate-bound `[POINT:…]`
    /// receipt that drives Ace's gem. Keep explicit pointing requests on the
    /// Gold visual-answer path even while Partner Mode is open; that path owns
    /// fresh capture, coordinate parsing, and the rendered pointer animation.
    static func requiresGoldPointerRoute(for utterance: String) -> Bool {
        let normalized = normalize(utterance)
        return matches(
            #"\b(?:show me where|point (?:to|at))\b"#,
            in: normalized
        )
    }

    static func scope(for utterance: String) -> ScreenContextScope {
        let normalized = normalize(utterance)

        if matches(
            #"^(?:(?:please|can you|could you) )?(?:sign (?:in|into)|log (?:in|into)|switch (?:the |my )?account|choose (?:the |an? )?account)\b"#,
            in: normalized
        ) {
            return .relevantDisplay
        }

        if matches(
            #"\b(?:all|every|both|each) (?:my )?(?:monitors?|screens?|displays?)\b|\bacross (?:all )?(?:my )?(?:monitors?|screens?|displays?)\b|\b(?:other|second|third|fourth|another|external|primary|main|(?:left|right)(?: hand)?) (?:monitor|screen|display)\b"#,
            in: normalized
        ) {
            return .allDisplays
        }

        // A submission follow-up refers to the editor Ace just used. Gold
        // needs the current screen to bind that target before planning work.
        if matches(
            #"^(?:please )?(?:send|submit) (?:it|the (?:message|prompt|chat)|(?:a |the )?(?:message|prompt|chat) (?:you|we|i) (?:just )?(?:typed|wrote|drafted)(?: in .+)?)$"#,
            in: normalized
        ) {
            return .relevantDisplay
        }

        if matches(
            #"\b(?:screen|display|monitor|window|page|chart|button|cursor|image|picture|photo|visible|selected|highlighted|error|warning|alert|dialog|notification)\b|\bwhat (?:do|can) you see\b|\b(?:describe|tell me) what you see\b|\bwhat(?: is| s) this\b|\bwhat(?: is| s) happening here\b|\bwhat am i looking at\b|\b(?:show me where|point (?:to|at)|read this|help me with this|explain this problem)\b|^(?:please )?(?:click|tap|press)\b"#,
            in: normalized
        ) {
            return .relevantDisplay
        }

        // A question about the currently shown exercise needs pixels even
        // when it starts with "what", "why", or "explain". Resolve these
        // references before the general text-only question grammar.
        if matches(
            #"\b(?:this|that|these|those|here)\b|\bwhich (?:one|answer|option|choice)\b|\b(?:answer|solve|explain|check|help me (?:with|answer|solve)) (?:the )?(?:(?:question|problem|number) [0-9]+|(?:first|second|third|next|last|current) (?:question|problem))\b|^(?:(?:what (?:is|s)|tell me|give me|show me) )?(?:the )?(?:(?:right|correct|best) )?answer(?: (?:to|for) (?:question|problem|number) [0-9]+)?$"#,
            in: normalized
        ) {
            return .relevantDisplay
        }

        if matches(
            #"^(?:hey )?(?:wyd|what you|what are you doing|what do you do|who are you|how are you|tell me a short joke)$|^(?:what|who) (?:is|are|was|were|does|do|did|can)\b|^(?:explain|define|summarize)\b|^tell me (?:about|a)\b|^(?:how|why) (?:do|does|did|can|is|are|was|were)\b"#,
            in: normalized
        ) {
            return .none
        }

        if normalized.isEmpty || matches(
            #"^(?:help|can you handle it|handle it|do this|fix this|take care of (?:it|this)|what now)$|\b(?:this|that|these|those|here)\b"#,
            in: normalized
        ) {
            return .relevantDisplay
        }

        return .none
    }

    private static func normalize(_ utterance: String) -> String {
        utterance
            .folding(options: [.diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9\s]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The scope used when Ace starts up and needs its bearings before the
    /// owner has said anything at all.
    static var launchBearingsScope: ScreenContextScope {
        .allDisplays
    }

    private static func matches(
        _ pattern: String,
        in value: String
    ) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
