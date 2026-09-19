// DNAProfile.swift — the Reference-DNA library: named, persisted reference fingerprints.
//
// SS-24. A DNA profile is a reference's captured `ReferenceDNA` (tonal fingerprint +
// loudness/peak/width stats) under a user-given name. Profiles are saved to a local JSON
// file, renamed, deleted, and re-applied across single masters AND batch masters — so a
// buyer can capture "my label's sound" from ONE reference they imported and stamp it on
// every future track without re-loading the file.
//
// SHIPS EMPTY (H1): there are no bundled profiles. Every profile derives only from a
// reference file the buyer imported; a clean install has an empty library. No audio is
// stored — only the derived DNA numbers.

import Foundation

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// One named, persistable reference-DNA profile.
struct DNAProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    var dna: ReferenceDNA

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), dna: ReferenceDNA) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.dna = dna
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Foundation-only persistence for the DNA library: a single local JSON file, atomically
/// written. No audio, no network — the profiles never leave this Mac. Deterministic and
/// headless-testable (point `fileURL` at a temp file).
final class DNAProfileStore {
    let fileURL: URL

    /// Default store location: ~/Library/Application Support/Sunset/dna_profiles.json.
    /// Pass an explicit `fileURL` (e.g. a temp file) for tests.
    init(fileURL: URL? = nil) {
        if let fileURL = fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = base.appendingPathComponent("Sunset", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("dna_profiles.json")
        }
    }

    /// Load all saved profiles (newest first). A missing/empty/corrupt file → an empty library.
    func load() -> [DNAProfile] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        let decoded = (try? JSONDecoder().decode([DNAProfile].self, from: data)) ?? []
        return decoded.sorted { $0.createdAt > $1.createdAt }
    }

    /// Persist the full library atomically. Throws on a real write failure so the UI can report it.
    func save(_ profiles: [DNAProfile]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(profiles)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
#endif // circuit-convert
