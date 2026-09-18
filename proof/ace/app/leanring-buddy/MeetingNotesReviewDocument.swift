//
//  MeetingNotesReviewDocument.swift
//  Ace
//

import Foundation

struct MeetingNotesReviewDocument: Equatable, Sendable {
    struct Section: Equatable, Identifiable, Sendable {
        let title: String
        let lines: [String]

        var id: String { title.lowercased() }

        var nonemptyLines: [String] {
            lines.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        var bulletCount: Int {
            nonemptyLines.filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
            }.count
        }

        var actionItemCount: Int {
            nonemptyLines.filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ] ")
            }.count
        }

        var flashcardParse: MeetingNotesFlashcardParse {
            MeetingNotesFlashcardParser.parse(lines: lines)
        }
    }

    let title: String
    let metadata: String
    let sections: [Section]
    let exactMarkdown: String

    static func parse(notesMarkdown: String) -> MeetingNotesReviewDocument {
        let lines = notesMarkdown.components(separatedBy: "\n")
        var title = "Notes"
        var metadataLines: [String] = []
        var sections: [Section] = []
        var currentSectionTitle: String?
        var currentSectionLines: [String] = []

        func finishCurrentSection() {
            guard let currentSectionTitle else { return }
            sections.append(
                Section(
                    title: currentSectionTitle,
                    lines: currentSectionLines
                )
            )
            currentSectionLines = []
        }

        for line in lines {
            if line.hasPrefix("# "), currentSectionTitle == nil {
                title = String(line.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("## ") {
                finishCurrentSection()
                currentSectionTitle = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            if currentSectionTitle == nil {
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    metadataLines.append(line)
                }
            } else {
                currentSectionLines.append(line)
            }
        }
        finishCurrentSection()

        return MeetingNotesReviewDocument(
            title: title.isEmpty ? "Notes" : title,
            metadata: metadataLines.joined(separator: "\n"),
            sections: sections,
            exactMarkdown: notesMarkdown
        )
    }

    func section(titled title: String) -> Section? {
        sections.first { $0.title == title }
    }
}

struct MeetingNotesFlashcardParse: Equatable, Sendable {
    struct Flashcard: Equatable, Identifiable, Sendable {
        let question: String
        let answer: String

        var id: String { question + "\n" + answer }
    }

    let flashcards: [Flashcard]
    let remainingLines: [String]
}

enum MeetingNotesFlashcardParser {
    static func parse(lines: [String]) -> MeetingNotesFlashcardParse {
        var flashcards: [MeetingNotesFlashcardParse.Flashcard] = []
        var observedCards = Set<String>()
        var consumedLineIndexes = Set<Int>()

        for questionLineIndex in lines.indices {
            let questionLine = lines[questionLineIndex]
                .trimmingCharacters(in: .whitespaces)
            guard questionLine.hasPrefix("- **Q:**") else { continue }

            let answerLineIndex = lines.index(after: questionLineIndex)
            guard answerLineIndex < lines.endIndex else { continue }
            let answerLine = lines[answerLineIndex]
                .trimmingCharacters(in: .whitespaces)
            guard answerLine.hasPrefix("**A:**") else { continue }

            let question = String(questionLine.dropFirst("- **Q:**".count))
                .trimmingCharacters(in: .whitespaces)
            let answer = String(answerLine.dropFirst("**A:**".count))
                .trimmingCharacters(in: .whitespaces)
            guard !question.isEmpty, !answer.isEmpty else { continue }

            let cardKey = question.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n"
                + answer.lowercased()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            guard observedCards.insert(cardKey).inserted else {
                consumedLineIndexes.insert(questionLineIndex)
                consumedLineIndexes.insert(answerLineIndex)
                continue
            }

            flashcards.append(
                MeetingNotesFlashcardParse.Flashcard(
                    question: question,
                    answer: answer
                )
            )
            consumedLineIndexes.insert(questionLineIndex)
            consumedLineIndexes.insert(answerLineIndex)
        }

        let remainingLines = lines.enumerated().compactMap {
            lineIndex, line -> String? in
            consumedLineIndexes.contains(lineIndex) ? nil : line
        }
        return MeetingNotesFlashcardParse(
            flashcards: flashcards,
            remainingLines: remainingLines
        )
    }
}
