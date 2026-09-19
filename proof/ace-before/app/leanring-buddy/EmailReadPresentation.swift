import Foundation

/// Local extractive summaries retain source wording. Mail content is never
/// submitted as instructions to a provider or persisted as conversation memory.
nonisolated enum EmailReadPresentation {
    static func wantsSummary(_ request: String) -> Bool {
        request.range(of: #"(?i)\b(summari[sz]e|summary|important|highlights|shorter|catch\s+me\s+up)\b"#, options: .regularExpression) != nil
    }

    static func summary(of output: String) -> String {
        let blocks = output.components(separatedBy: "\n\n")
        guard let coverage = blocks.first, blocks.count > 1 else { return output }
        struct Item {
            let index: Int
            let sender: String
            let subject: String
            let preview: String
            let priority: Int
        }
        let items: [Item] = blocks.dropFirst().enumerated().compactMap { index, block in
            let lines = block.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.count >= 3, lines[1].lowercased().hasPrefix("from: "),
                  lines[2].lowercased().hasPrefix("subject: ") else { return nil }
            let sender = String(lines[1].dropFirst(6)).components(separatedBy: " <").first ?? "Sender"
            let subject = String(lines[2].dropFirst(9))
            let preview = lines.dropFirst(3).joined(separator: " ")
            let text = subject + " " + preview
            let priority = [#"\b(action required|deadline|overdue|due today|due tomorrow|urgent)\b"#,
                            #"\b(please (?:confirm|review|respond)|appointment|meeting|invoice|payment|interview)\b"#]
                .enumerated().reduce(0) { score, pattern in
                    score + (text.range(of: pattern.element, options: [.regularExpression, .caseInsensitive]) == nil ? 0 : 2 - pattern.offset)
                }
            return Item(index: index, sender: sender, subject: subject, preview: preview, priority: priority)
        }
        guard !items.isEmpty else { return output }
        let ranked = items.sorted { $0.priority == $1.priority ? $0.index < $1.index : $0.priority > $1.priority }
        var lines = [coverage.trimmingCharacters(in: CharacterSet(charactersIn: ":")) + "."]
        if let counts = try? NSRegularExpression(pattern: #"(?i)(\d+) of (\d+)"#),
           let match = counts.firstMatch(in: coverage, range: NSRange(coverage.startIndex..., in: coverage)),
           let first = Range(match.range(at: 1), in: coverage), let second = Range(match.range(at: 2), in: coverage),
           let shown = Int(coverage[first]), let total = Int(coverage[second]), shown < total {
            lines.append("This covers only those \(shown) previews; \(total - shown) more messages are outside this read.")
        }
        lines.append(ranked[0].priority > 0 ? "These previews mention possible follow-ups:" : "Here are the latest highlights:")
        for item in ranked.prefix(3) {
            let preview = String(item.preview.prefix(150))
            lines.append("\(item.sender): \(item.subject)." + (preview.isEmpty ? "" : " \(preview)\(item.preview.count > 150 ? "…" : "")"))
        }
        if items.count > 3 { lines.append("\(items.count - 3) other previews are available in this read.") }
        return lines.joined(separator: "\n")
    }
}

nonisolated struct RecentEmailRead {
    let sourceIdentity: String
    let usesGmail: Bool
    let arguments: [String]
    let output: String
    let receivedAt: Date

    func isUsable(sourceIdentity: String, now: Date = Date()) -> Bool {
        self.sourceIdentity == sourceIdentity && now >= receivedAt && now.timeIntervalSince(receivedAt) <= 300
    }
}
