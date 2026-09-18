import Foundation

/// Grammar and admission for "put something on the projector" — sending media
/// to a second display.
///
/// Two rules make this honest rather than impressive:
///
/// 1. **A projector that isn't there is said out loud.** The failure this
///    prevents is the worst kind on a stage: Ace cheerfully says "of course"
///    while nothing appears behind you. If there is no second display, Ace says
///    so instead of pretending.
/// 2. **Ace never picks the content.** "Put something on" is not a mandate to
///    choose media on the owner's behalf and start playing it in a room. An
///    unqualified request asks what to play; a named one plays that.
nonisolated enum SecondDisplayMediaPolicy {

    /// Anchored request grammar. Destination words are required — this must
    /// never capture ordinary "play some music".
    private static let requestPattern =
        // Spoken requests open with connectors far more often than written
        // ones: the founder's own line is "also — can you put something on…".
        #"(?i)^\s*(?:(?:also|and|so|then|oh|okay|ok|alright)\b[\s,—-]*)*"#
        + #"(?:(?:hey\s+)?ace[\s,]+)?(?:please\s+)?(?:(?:can|could|would)\s+you(?:\s+please)?\s+)?"#
        + #"(?:put|throw|cast|show|play|start)\s+"#
        + #"(?:(.+?)\s+)?"#
        + #"(?:up\s+)?(?:on|onto|to|up\s+on)\s+"#
        + #"(?:the\s+|my\s+|our\s+)?"#
        + #"(?:projector|big\s+screen|second\s+screen|second\s+display|other\s+screen|other\s+display|tv)"#
        + #"(?:\s+in\s+the\s+background)?\s*[?.!]?\s*$"#

    private static let questionPattern =
        #"(?i)^\s*(?:how|why|what|when|where|who|does|did|is|are|should)\b"#

    /// Returns the requested content when this is a second-display request.
    /// An empty string means the owner did not name anything.
    static func requestedContent(_ text: String) -> String? {
        guard text.range(
            of: questionPattern,
            options: .regularExpression
        ) == nil else { return nil }
        guard let expression = try? NSRegularExpression(
            pattern: requestPattern
        ) else { return nil }
        let nsText = text as NSString
        guard let result = expression.firstMatch(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ) else { return nil }
        let contentRange = result.range(at: 1)
        guard contentRange.location != NSNotFound else { return "" }
        let content = nsText.substring(with: contentRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return namedContent(from: content)
    }

    /// Separates a real title from conversational filler.
    ///
    /// Caught by test 2026-08-07 on the founder's own line — "can you put
    /// something on in the background on the projector?" — which parsed as the
    /// title "something on in the background". Ace would then have gone looking
    /// for media by that name instead of asking what to play.
    static func namedContent(from rawContent: String) -> String {
        var value = rawContent.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Trailing conversational filler carries no title.
        for suffix in [
            "on in the background", "in the background", "up in the background",
            "on in back", "playing", "going", "up", "on",
        ] {
            if value == suffix { return "" }
            if value.hasSuffix(" " + suffix) {
                value = String(value.dropLast(suffix.count + 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let placeholders: Set<String> = [
            "something", "anything", "some music", "music", "a movie",
            "a show", "it", "that", "some background", "background",
        ]
        guard !placeholders.contains(value), !value.isEmpty else { return "" }

        // Preserve the owner's original casing for anything that survives.
        let originalTrimmed = rawContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard originalTrimmed.lowercased().hasPrefix(value) else { return value }
        return String(originalTrimmed.prefix(value.count))
    }

    enum Admission: Equatable, Sendable {
        /// A second display exists and the owner named content.
        case play(String)
        /// A second display exists but nothing was named — ASK, don't choose.
        case askWhatToPlay
        /// No second display: say so rather than pretending.
        case noSecondDisplay
    }

    static func admit(
        requestedContent: String,
        attachedDisplayCount: Int
    ) -> Admission {
        guard attachedDisplayCount >= 2 else { return .noSecondDisplay }
        let trimmed = requestedContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .askWhatToPlay : .play(trimmed)
    }

    static let spokenNoSecondDisplay =
        "i don't see a second display connected, so there's nothing to put it on."

    static let spokenAskWhatToPlay =
        "what should i put on? name it and i'll send it to the second screen."

    static func spokenSending(_ content: String) -> String {
        "putting \(content.lowercased()) on the second screen."
    }
}
