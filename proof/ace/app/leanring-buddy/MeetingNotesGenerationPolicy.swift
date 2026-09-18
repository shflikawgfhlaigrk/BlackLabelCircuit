//
//  MeetingNotesGenerationPolicy.swift
//  Ace
//
//  Deterministic boundary between an untrusted no-tool model response and the
//  native meeting-notes review. A failed or malformed summary never becomes a
//  saveable raw-transcript fallback.
//

import Foundation

struct GeneratedMeetingNotes: Equatable, Sendable {
    let spokenLine: String
    let notesMarkdown: String
}

enum MeetingNotesGenerationPolicy {
    /// App-observed interruptions remain in the exact reviewed/saved document
    /// even when the summarizer omits them. They never depend on model recall.
    static func reviewMarkdown(
        _ notes: GeneratedMeetingNotes,
        captureGapDescriptions: [String]
    ) -> String {
        guard !captureGapDescriptions.isEmpty else { return notes.notesMarkdown }
        return notes.notesMarkdown
            + "\n\n## Capture interruptions recorded by Ace\n"
            + captureGapDescriptions.map { "- " + $0 }.joined(separator: "\n")
    }

    private static let requiredHeadings = [
        "\n## Summary",
        "\n## Key bullet points",
        "\n## Detailed notes",
        "\n## Definitions and key terms",
        "\n## Examples, evidence, and worked steps",
        "\n## Formulas, dates, names, and facts",
        "\n## Decisions",
        "\n## Actions, assignments, and deadlines",
        "\n## Risks and blockers",
        "\n## Open questions and follow-ups",
        "\n## Study guide",
        "\n## Flashcards",
        "\n## Details worth keeping",
    ]

    static func minimumNotesCharacterCount(
        forTranscriptCharacterCount transcriptCharacterCount: Int
    ) -> Int {
        guard transcriptCharacterCount >= 800 else { return 0 }
        return min(60_000, max(1_500, transcriptCharacterCount / 3))
    }

    static func decode(
        _ modelOutput: String,
        transcriptCharacterCount: Int? = nil
    ) -> GeneratedMeetingNotes? {
        let trimmed = modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\r"),
              let firstLineBreak = trimmed.firstIndex(of: "\n"),
              trimmed.hasPrefix("SPOKEN:") else {
            return nil
        }

        let spokenStart = trimmed.index(
            trimmed.startIndex,
            offsetBy: "SPOKEN:".count
        )
        let spokenLine = trimmed[spokenStart..<firstLineBreak]
            .trimmingCharacters(in: .whitespaces)
        let notesStart = trimmed.index(after: firstLineBreak)
        let notesMarkdown = trimmed[notesStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !spokenLine.isEmpty,
              spokenLine.count <= 220,
              spokenLine.split(whereSeparator: \.isWhitespace).count <= 22,
              !spokenLine.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              notesMarkdown.hasPrefix("# "),
              notesMarkdown.count <= 120_000,
              !notesMarkdown.unicodeScalars.contains(where: { $0.value == 0 }),
              notesMarkdown.range(
                  of: #"(?mi)^\s*\[\d{1,2}:\d{2}(?::\d{2})?\]\s+"#,
                  options: .regularExpression
              ) == nil,
              notesMarkdown.range(
                  of: #"(?i)(?:^|\n)#{0,3}\s*raw\s+transcript\b|\braw\s+transcript\s+below\b"#,
                  options: .regularExpression
              ) == nil else {
            return nil
        }

        if let transcriptCharacterCount {
            let minimumNotesCharacterCount = minimumNotesCharacterCount(
                forTranscriptCharacterCount: transcriptCharacterCount
            )
            guard notesMarkdown.count >= minimumNotesCharacterCount else {
                return nil
            }
        }

        var searchStart = notesMarkdown.startIndex
        for heading in requiredHeadings {
            guard let range = notesMarkdown.range(
                of: heading,
                range: searchStart..<notesMarkdown.endIndex
            ) else {
                return nil
            }
            searchStart = range.upperBound
        }


        guard let detailedNotesRange = notesMarkdown.range(
            of: "\n## Detailed notes"
        ),
              let definitionsRange = notesMarkdown.range(
                of: "\n## Definitions and key terms",
                range: detailedNotesRange.upperBound..<notesMarkdown.endIndex
              ),
              notesMarkdown.range(
                of: "\n### ",
                range: detailedNotesRange.upperBound..<definitionsRange.lowerBound
              ) != nil else {
            return nil
        }

        return GeneratedMeetingNotes(
            spokenLine: spokenLine,
            notesMarkdown: notesMarkdown
        )
    }
}
