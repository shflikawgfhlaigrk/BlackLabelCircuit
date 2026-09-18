import Foundation

/// Closed model selection for buyer Claude lanes. The panel picker persists
/// exactly these stored identifiers; every applicable argv builder takes the
/// selection as a typed parameter and maps it through this enum, so a UI
/// selection is an argv fact — never decoration — and an invalid stored
/// value falls back to Sonnet instead of silently running something else.
nonisolated enum AceClaudeModel: String, CaseIterable, Equatable, Sendable {
    case sonnet
    case opus

    /// The exact Claude CLI `--model` value for this selection.
    var argvValue: String { rawValue }

    /// The exact identifier the picker persists for this selection.
    var storedModelID: String {
        switch self {
        case .sonnet: return "claude-sonnet-4-6"
        case .opus: return "claude-opus-4-6"
        }
    }

    /// Where the picker's choice persists across launches.
    static let storedSelectionDefaultsKey = "selectedClaudeModel"

    /// Unknown, empty, or missing stored values fall back to Sonnet — the
    /// latency/accuracy balance point for spoken answers, and the only safe
    /// meaning for a value this build cannot represent.
    init(storedModelID: String?) {
        self = AceClaudeModel.allCases.first {
            $0.storedModelID == storedModelID
        } ?? .sonnet
    }

    /// The owner's current durable selection, for lanes that build argv
    /// outside the panel's live object graph (the Red background lane).
    static var currentSelection: AceClaudeModel {
        AceClaudeModel(
            storedModelID: UserDefaults.standard.string(
                forKey: storedSelectionDefaultsKey
            )
        )
    }
}
