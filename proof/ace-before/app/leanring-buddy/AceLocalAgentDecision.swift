import Foundation

/// The local Qwen tool loop has one typed decision per inference turn. The
/// unused field is intentionally optional on the wire: local models commonly
/// omit an empty `command` on a reply or an empty `text` on a shell call even
/// when the prompt's JSON schema marks both fields required. Ace owns that
/// harmless normalization while still rejecting an empty active payload.
nonisolated struct AceLocalAgentDecision: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case reply
        case shell
    }

    let kind: Kind
    let text: String
    let command: String

    static func decode(from rawValue: String) -> AceLocalAgentDecision? {
        guard let data = rawValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let rawKind = dictionary["kind"] as? String,
              let kind = Kind(rawValue: rawKind.lowercased()) else {
            return nil
        }
        let text = (dictionary["text"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let command = (dictionary["command"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .reply:
            guard !text.isEmpty else { return nil }
        case .shell:
            guard !command.isEmpty else { return nil }
        }
        return AceLocalAgentDecision(
            kind: kind,
            text: text,
            command: command
        )
    }
}
