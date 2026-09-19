//
//  AceTranscript.swift
//  Ace
//
//  The owner's conversation, kept on disk, in their own words and Ace's.
//
//  HISTORY (why this file exists):
//  Ace had durable conversation history from 2026-07-17 (`history.json`), added
//  by a commit whose message called out the exact problem it solved: "Ace
//  previously claimed persistent memory while holding a RAM array." On
//  2026-08-04, commit 4ec70d12 removed the four cloud brain backends and the
//  conversation persistence went out entangled with them — 255 files,
//  +65,907/−7,183, so the loss was invisible. The same commit rewrote AGENTS.md
//  to describe the absence as the design ("kept only in memory for the current
//  launch") under the subject "doc truth", and every agent afterwards read that
//  line and repeated it back to the founder as intentional. It never was.
//
//  So: verbatim, timestamped, append-only, and the owner's to read.
//
//  THREE RULES THIS FILE MUST NOT BREAK
//  1. Stealth wins. Private Mode exists for the library and the lecture hall;
//     "no model prompt, screen content, transcript, or private answer in logs"
//     is a founder rule and it outranks this file completely. The check here is
//     the SAME on-disk boundary tools/effect-guard.sh trusts, because these
//     writes happen on a detached IO worker where the @MainActor
//     StealthVisibilityGate cannot be read. Fail closed: anything unparseable
//     at the marker paths means do not write.
//  2. Never truncate. A transcript that deletes the owner's history to stay
//     small is the bug it was written to fix. Roll to a dated file instead.
//  3. Never block the answer. Every failure here is silent to the product: the
//     owner's question gets answered even if the record cannot be written.
//

import Foundation

enum AceTranscriptRole: String {
    case you
    case ace
}

enum AceTranscript {
    static let fileName = "transcript.md"
    /// Roll — not truncate — once the live file passes this size.
    static let rollAtBytes = 5_000_000

    // MARK: - Pure

    /// One rendered entry. Pure so the format is testable without a filesystem.
    /// The text is verbatim: a transcript that edits the owner is not a record.
    nonisolated static func entry(
        role: AceTranscriptRole,
        text: String,
        at date: Date
    ) -> String {
        let stamp = Self.stampFormatter.string(from: date)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "## \(stamp)  \(role.rawValue)\n\(body)\n\n"
    }

    nonisolated static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - The stealth boundary

    /// Mirrors `ace_effect_guard_stealth_is_active` in tools/effect-guard.sh.
    /// Presence of ANY marker — including a symlink or malformed file at the
    /// fixed name — blocks the write. A planted object must fail closed rather
    /// than open a hole into the owner's private session.
    nonisolated static func stealthBlocksWriting(
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        for markerName in ["stealth-entry-request-v1", "stealth-intent-v1"] {
            let marker = supportDirectory.appendingPathComponent(markerName)
            if fileManager.fileExists(atPath: marker.path) { return true }
            // A broken symlink does not "exist" by the check above.
            if (try? fileManager.attributesOfItem(atPath: marker.path)) != nil { return true }
        }

        // The live marker holds a PID. Only a RUNNING process means stealth; a
        // crash must not leave the owner's transcript permanently disabled.
        let liveMarker = supportDirectory.appendingPathComponent("stealth-active")
        guard let raw = try? String(contentsOf: liveMarker, encoding: .utf8) else {
            return false
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(trimmed) else {
            // Present but unparseable — fail closed.
            return true
        }
        return kill(pid, 0) == 0
    }

    // MARK: - Writing

    /// `ACE_TRANSCRIPT_DIRECTORY` redirects the record, and exists for exactly
    /// one reason: the offline battery constructs a REAL VoiceQueue, so without
    /// it every test run would append its fixture lines ("must be invalidated")
    /// into the owner's actual transcript. A test must never be able to write
    /// into the owner's conversation.
    nonisolated static func supportDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["ACE_TRANSCRIPT_DIRECTORY"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true)
    }

    /// Append one turn. Silent on every failure — the answer matters more than
    /// the record of it.
    nonisolated static func record(
        role: AceTranscriptRole,
        text: String,
        persistLogs: Bool = true,
        directory: URL? = nil,
        now: Date = Date()
    ) {
        guard persistLogs else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let directory = directory ?? supportDirectory() else { return }
        guard (try? PrivateSupportDirectory.ensure(at: directory)) != nil else { return }
        guard !stealthBlocksWriting(supportDirectory: directory) else { return }

        let fileURL = directory.appendingPathComponent(fileName)
        rollIfOversized(fileURL: fileURL, now: now)

        guard let data = entry(role: role, text: text, at: now).data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
    }

    /// Move the live file aside once it grows past the roll threshold. The
    /// owner keeps every word; only the file being appended to is new.
    nonisolated static func rollIfOversized(fileURL: URL, now: Date) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size]
            as? Int, size > rollAtBytes else { return }
        let stamp = Self.stampFormatter.string(from: now)
            .replacingOccurrences(of: ":", with: ".")
        let archived = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("transcript \(stamp).md")
        try? FileManager.default.moveItem(at: fileURL, to: archived)
    }
}
