import Foundation

/// Compatible review envelope; new reviews run locally without an authorship score.
nonisolated struct AcademicDetectorResult: Codable, Sendable {
    var status: String
    var provider: String = "Ace on-device review"
    var checkedAt: String?
    var submittedTextSHA256: String?
    var documentSHA256: String
    var completelyGeneratedProbability: Double? = nil
    var wordCount: Int
    var paragraphCount: Int
    var repeatedParagraphCount: Int
    var longSentenceCount: Int
    var findings: [String]
    var message: String
}

nonisolated enum AcademicDetector {
    static func check(text: String, documentSHA256: String) async -> AcademicDetectorResult {
        let paragraphs = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        var seen: Set<String> = []
        let repeats = paragraphs.filter { !seen.insert(AcademicDocument.normalize($0).lowercased()).inserted }.count
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        let longSentences = sentences.filter { $0.split(whereSeparator: \.isWhitespace).count > 40 }.count
        var findings: [String] = []
        if wordCount == 0 { findings.append("The essay body is empty.") }
        if repeats > 0 { findings.append("\(repeats) repeated paragraph(s): review for accidental duplication.") }
        if longSentences > 0 { findings.append("\(longSentences) sentence(s) exceed 40 words: review readability.") }
        let lowered = text.lowercased()
        if ["[insert", "[todo", "[citation needed]", "lorem ipsum"].contains(where: lowered.contains) {
            findings.append("Draft placeholders remain in the essay.")
        }
        return AcademicDetectorResult(
            status: findings.isEmpty ? "checked" : "needs review",
            checkedAt: ISO8601DateFormatter().string(from: Date()),
            submittedTextSHA256: AcademicDocument.sha256(Data(text.utf8)), documentSHA256: documentSHA256,
            wordCount: wordCount, paragraphCount: paragraphs.count, repeatedParagraphCount: repeats,
            longSentenceCount: longSentences, findings: findings,
            message: "Ace checked this exact essay locally for duplicate paragraphs, long sentences and draft placeholders. Citation and quotation checks are recorded separately. Authorship and factual accuracy require review."
        )
    }
}
