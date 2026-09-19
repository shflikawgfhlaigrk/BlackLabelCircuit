import Foundation

/// Voice admission for the one visible, pending meeting-notes review.
///
/// The review itself binds the referent, so definite phrases such as "save the
/// note" are unambiguous while it is on screen. Generic assent and compound
/// requests remain excluded: neither "yes" nor "save and email" can write it.
enum MeetingNotesReviewIntentPolicy {
    private static let explicitSavePhrases: Set<String> = [
        "save meeting notes",
        "save my meeting notes",
        "save the meeting note",
        "save the meeting notes",
        "save the note",
        "save the notes",
        "save these meeting notes",
        "save these notes",
        "save this meeting note",
        "save this meeting notes",
        "save this note",
        "save this notes",
    ]

    static func isExplicitSave(_ utterance: String) -> Bool {
        explicitSavePhrases.contains(normalized(utterance))
    }

    private static func normalized(_ utterance: String) -> String {
        var normalized = utterance
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        while let last = normalized.last,
              last == "." || last == "!" || last == "?" {
            normalized.removeLast()
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
