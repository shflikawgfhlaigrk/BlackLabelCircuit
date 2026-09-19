#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  MeetingNotesReviewView.swift
//  Ace
//

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct MeetingNotesReviewView: View {
    private let document: MeetingNotesReviewDocument

    init(notesMarkdown: String) {
        document = MeetingNotesReviewDocument.parse(
            notesMarkdown: notesMarkdown
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            meetingOverview
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(document.sections) { section in
                        MeetingNotesReviewSectionView(section: section)
                    }
                }
                .padding(22)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .textSelection(.enabled)
        .accessibilityIdentifier("ace.meeting.notes.formatted-review")
    }

    private var meetingOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(document.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
            if !document.metadata.isEmpty {
                MeetingNotesInlineMarkdownText(markdown: document.metadata)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                MeetingNotesMetricChip(
                    icon: "list.bullet",
                    value: document.section(titled: "Key bullet points")?
                        .bulletCount ?? 0,
                    label: "Key points"
                )
                MeetingNotesMetricChip(
                    icon: "checkmark.square",
                    value: document.section(
                        titled: "Actions, assignments, and deadlines"
                    )?
                        .actionItemCount ?? 0,
                    label: "Actions"
                )
                MeetingNotesMetricChip(
                    icon: "rectangle.stack",
                    value: document.section(titled: "Flashcards")?
                        .flashcardParse.flashcards.count ?? 0,
                    label: "Flashcards"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MeetingNotesMetricChip: View {
    let icon: String
    let value: Int
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(MeetingNotesReviewPalette.gold)
            Text("\(value) \(label)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Capsule()
                .stroke(MeetingNotesReviewPalette.gold.opacity(0.28))
        )
    }
}

private struct MeetingNotesReviewSectionView: View {
    let section: MeetingNotesReviewDocument.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(section.title, systemImage: sectionIcon)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            if section.title == "Flashcards" {
                flashcards
            } else {
                standardSectionLines
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(sectionAccessibilityIdentifier)
    }

    @ViewBuilder
    private var standardSectionLines: some View {
        ForEach(
            Array(section.nonemptyLines.enumerated()),
            id: \.offset
        ) { _, line in
            MeetingNotesReviewLineView(line: line)
        }
    }

    @ViewBuilder
    private var flashcards: some View {
        let flashcardParse = section.flashcardParse
        if flashcardParse.flashcards.isEmpty {
            ForEach(
                Array(section.nonemptyLines.enumerated()),
                id: \.offset
            ) { _, line in
                MeetingNotesReviewLineView(line: line)
            }
        } else {
            ForEach(
                Array(flashcardParse.flashcards.enumerated()),
                id: \.offset
            ) { flashcardIndex, flashcard in
                MeetingNotesFlashcardView(
                    number: flashcardIndex + 1,
                    flashcard: flashcard
                )
            }
            ForEach(
                Array(
                    flashcardParse.remainingLines
                        .filter {
                            !$0.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        }
                        .enumerated()
                ),
                id: \.offset
            ) { _, line in
                MeetingNotesReviewLineView(line: line)
            }
        }
    }

    private var sectionAccessibilityIdentifier: String {
        let normalizedTitle = section.title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "ace.meeting.notes.section.\(normalizedTitle)"
    }

    private var sectionIcon: String {
        switch section.title {
        case "Summary": return "doc.text"
        case "Key bullet points": return "list.bullet"
        case "Definitions and key terms": return "character.book.closed"
        case "Examples, evidence, and worked steps": return "list.number"
        case "Formulas, dates, names, and facts": return "function"
        case "Decisions": return "checkmark.seal"
        case "Actions, assignments, and deadlines": return "checkmark.square"
        case "Detailed notes": return "text.alignleft"
        case "Risks and blockers": return "exclamationmark.triangle"
        case "Open questions and follow-ups": return "questionmark.circle"
        case "Study guide": return "graduationcap"
        case "Flashcards": return "rectangle.stack"
        case "Details worth keeping": return "bookmark"
        default: return "doc.plaintext"
        }
    }
}

private struct MeetingNotesReviewLineView: View {
    let line: String

    var body: some View {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.hasPrefix("### ") {
            Text(String(trimmedLine.dropFirst(4)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MeetingNotesReviewPalette.gold)
                .padding(.top, 5)
        } else if trimmedLine.hasPrefix("- [ ] ") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "square")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(MeetingNotesReviewPalette.blue)
                MeetingNotesInlineMarkdownText(
                    markdown: String(trimmedLine.dropFirst(6))
                )
            }
        } else if trimmedLine.hasPrefix("- ") {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(MeetingNotesReviewPalette.gold)
                    .frame(width: 5, height: 5)
                    .padding(.top, 7)
                MeetingNotesInlineMarkdownText(
                    markdown: String(trimmedLine.dropFirst(2))
                )
            }
        } else {
            MeetingNotesInlineMarkdownText(markdown: trimmedLine)
        }
    }
}

private struct MeetingNotesFlashcardView: View {
    let number: Int
    let flashcard: MeetingNotesFlashcardParse.Flashcard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text("Q\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(MeetingNotesReviewPalette.gold)
                    )
                MeetingNotesInlineMarkdownText(
                    markdown: flashcard.question
                )
                .font(.system(size: 14, weight: .semibold))
            }
            Divider()
            HStack(alignment: .top, spacing: 10) {
                Text("A")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(MeetingNotesReviewPalette.blue)
                    )
                MeetingNotesInlineMarkdownText(markdown: flashcard.answer)
                    .font(.system(size: 14))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(MeetingNotesReviewPalette.gold.opacity(0.42))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Flashcard \(number). Question: \(flashcard.question). "
                + "Answer: \(flashcard.answer)"
        )
    }
}

private struct MeetingNotesInlineMarkdownText: View {
    let markdown: String

    var body: some View {
        if let attributedText = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attributedText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum MeetingNotesReviewPalette {
    static let gold = Color(red: 0.88, green: 0.68, blue: 0.22)
    static let blue = Color(red: 0.20, green: 0.50, blue: 0.92)
}
#endif // circuit-convert
