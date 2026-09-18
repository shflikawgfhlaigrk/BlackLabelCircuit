//
//  MeetingNotesResult.swift
//  Ace
//

import Foundation

enum MeetingNotesResultState: String, Codable, Equatable, Sendable {
    case recording
    case noTranscript
    case generationPending
    case reviewUnsaved
    case saved
    case cancelled
    case failed
}

struct MeetingNotesResult: Codable, Equatable, Sendable {
    let state: MeetingNotesResultState
    let title: String
    let detail: String
    let destinationPath: String?
    let folderPath: String

    static func recording(
        folderPath: String,
        sourceSummary: String
    ) -> MeetingNotesResult {
        MeetingNotesResult(
            state: .recording,
            title: "Taking Notes",
            detail:
                "\(sourceSummary) Nothing is saved until review and confirmation.",
            destinationPath: nil,
            folderPath: folderPath
        )
    }

    static func noTranscript(folderPath: String) -> MeetingNotesResult {
        MeetingNotesResult(
            state: .noTranscript,
            title: "No transcript",
            detail:
                "Capture stopped without readable words. No notes file was created.",
            destinationPath: nil,
            folderPath: folderPath
        )
    }

    static func generationPending(folderPath: String) -> MeetingNotesResult {
        MeetingNotesResult(
            state: .generationPending,
            title: "Retry Notes & Flashcards",
            detail:
                "The populated capture is held only in memory. Connect or "
                + "choose Codex or Claude, then retry the same Detailed notes "
                + "and Q/A Flashcards review. Nothing has been saved.",
            destinationPath: nil,
            folderPath: folderPath
        )
    }

    static func reviewUnsaved(
        destinationPath: String
    ) -> MeetingNotesResult {
        MeetingNotesResult(
            state: .reviewUnsaved,
            title: "Review unsaved",
            detail:
                "Review is open. This exact file does not exist until you approve Save.",
            destinationPath: destinationPath,
            folderPath: parentFolder(of: destinationPath)
        )
    }

    static func saved(destinationPath: String) -> MeetingNotesResult {
        MeetingNotesResult(
            state: .saved,
            title: "Saved",
            detail: "The reviewed notes were written to this exact file.",
            destinationPath: destinationPath,
            folderPath: parentFolder(of: destinationPath)
        )
    }

    static func cancelled(
        destinationPath: String
    ) -> MeetingNotesResult {
        MeetingNotesResult(
            state: .cancelled,
            title: "Review cancelled",
            detail: "No notes file was created.",
            destinationPath: destinationPath,
            folderPath: parentFolder(of: destinationPath)
        )
    }

    static func failed(
        folderPath: String,
        detail: String
    ) -> MeetingNotesResult {
        MeetingNotesResult(
            state: .failed,
            title: "Notes failed",
            detail: detail,
            destinationPath: nil,
            folderPath: folderPath
        )
    }

    private static func parentFolder(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
}
