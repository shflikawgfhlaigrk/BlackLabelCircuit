// Sovereign — REAL local Files connector.
//
// The buyer EXPLICITLY grants a folder (via the native open panel). The app indexes the plain-text
// documents in that folder so the agent can search them and RAG can ground on them. This is the
// opposite of background mining: nothing is read until the buyer points at a folder, only text-like
// files are indexed, and the buyer can remove a source at any time. No Photos, no system scan, no
// audio, no continuous capture.
//
// SECURITY-SCOPED ACCESS: a sandbox-safe bookmark is stored so re-opening the app re-grants the
// same folder without re-prompting. Outside the sandbox (this adhoc build), the path is read
// directly; the bookmark path is still honored so the same code ships into a sandboxed build.
//
// HONESTY: file contents are read verbatim from disk. Counts (files indexed, words) are real.
// When a folder is empty of text files or can't be read, the source reports an honest empty state.
import Foundation

/// A buyer-granted folder source. Persists a security-scoped bookmark so access survives relaunch.
struct FileSource: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String                 // human-readable folder path (display + fallback access)
    var name: String                 // folder display name
    var bookmark: Data?              // security-scoped bookmark (sandbox-safe)
    var added = Date()
    var enabled = true               // included in RAG/agent search when on
    var fileCount = 0                // real count from the last index
    var wordCount = 0               // real total words from the last index
    var lastIndexed: Date?
}

/// One indexed file's text, chunked for retrieval (shares the RAG chunker shape with KnowledgeDoc).
struct IndexedFile: Identifiable, Hashable {
    let id = UUID()
    let sourceID: UUID
    let name: String        // file name (e.g. "notes.md")
    let relPath: String     // path relative to the granted folder
    let text: String

    /// Paragraph-ish ~600-char chunks (mirrors KnowledgeDoc.chunks for retrieval parity).
    func chunks() -> [String] { FileIndexer.chunk(text) }
}

/// Pure, testable indexing helpers — no SwiftUI, no actor.
enum FileIndexer {
    /// Text-like extensions the connector will read. Deliberately excludes binaries, images,
    /// audio, video — we never ingest media, only documents the buyer can already read as text.
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "text", "rtf", "csv", "tsv", "log",
        "json", "yaml", "yml", "xml", "html", "htm",
        "swift", "py", "js", "ts", "go", "rs", "java", "c", "h", "cpp", "rb", "sh", "sql"
    ]

    /// Skip noise/heavy dirs even if the buyer points at a parent folder.
    static let skipDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData", "venv", ".venv", "__pycache__", ".Trash"]

    /// Whether a file name should be indexed (text-like extension, not hidden).
    static func isIndexable(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return textExtensions.contains(ext)
    }

    /// Per-file size cap so one giant log can't blow the index (1 MB of text is plenty for RAG).
    static let maxFileBytes = 1_000_000
    /// Cap files per source so an enormous tree stays responsive + honest about what's indexed.
    static let maxFilesPerSource = 400

    /// ~600-char paragraph chunker (identical contract to KnowledgeDoc.chunks()).
    static func chunk(_ body: String) -> [String] {
        let paras = body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        var buf = ""
        for p in paras {
            if buf.count + p.count > 600 { if !buf.isEmpty { out.append(buf) }; buf = p }
            else { buf = buf.isEmpty ? p : buf + "\n\n" + p }
        }
        if !buf.isEmpty { out.append(buf) }
        // A single huge paragraph with no blank lines → hard-split so retrieval still works.
        if out.count == 1 && out[0].count > 1200 {
            return stride(from: 0, to: out[0].count, by: 600).map {
                let s = out[0]; let start = s.index(s.startIndex, offsetBy: $0)
                let end = s.index(start, offsetBy: 600, limitedBy: s.endIndex) ?? s.endIndex
                return String(s[start..<end])
            }
        }
        return out
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class FilesConnector: ObservableObject {
    @Published var sources: [FileSource] = [] { didSet { persist() } }
    /// In-memory index of file text, rebuilt on demand from the granted folders (never persisted —
    /// the buyer's file contents stay on disk, only a reference + counts are saved).
    @Published private(set) var indexed: [IndexedFile] = []
    @Published var indexing = false
    @Published var lastError: String?

    private let d = UserDefaults.standard
    private let key = "com.blacklabel.sovereign.filesources.v1"
    /// Optional ledger so granting/removing/toggling a folder writes a real proof-of-execution
    /// receipt at the moment the grant changes. Wired at app init.
    weak var activity: ActivityLog?

    init() {
        if let data = d.data(forKey: key), let s = try? JSONDecoder().decode([FileSource].self, from: data) { sources = s }
        // Re-index the persisted sources at launch so RAG/agent have the buyer's files immediately.
        reindexAll()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(sources) { d.set(data, forKey: key) }
    }

    /// Add a folder the buyer picked. Stores a security-scoped bookmark, then indexes it.
    func addFolder(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try? url.bookmarkData(options: URL.blSecurityScopeBookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        // De-dupe by path.
        if let i = sources.firstIndex(where: { $0.path == url.path }) {
            var s = sources[i]; s.bookmark = bookmark; s.enabled = true; sources[i] = s
        } else {
            sources.insert(FileSource(path: url.path, name: url.lastPathComponent, bookmark: bookmark), at: 0)
        }
        activity?.record(kind: .connector, title: "Files connector",
                         detail: "Granted folder “\(url.lastPathComponent)” (\(url.path)) — its text documents are now searchable by the assistant.",
                         outcome: .success)
        reindexAll()
    }

    func remove(_ s: FileSource) {
        sources.removeAll { $0.id == s.id }
        activity?.record(kind: .connector, title: "Files connector",
                         detail: "Removed folder “\(s.name)” — no longer searchable.", outcome: .info)
        reindexAll()
    }
    func toggle(_ s: FileSource) {
        if let i = sources.firstIndex(where: { $0.id == s.id }) {
            sources[i].enabled.toggle()
            let on = sources[i].enabled
            activity?.record(kind: .connector, title: "Files connector",
                             detail: "\(on ? "Enabled" : "Disabled") folder “\(s.name)” for assistant search.",
                             outcome: .info)
            reindexAll()
        }
    }

    /// Resolve a usable folder URL for a source (bookmark first, path fallback).
    private func resolve(_ s: FileSource) -> (URL, Bool)? {
        if let bm = s.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bm, options: URL.blSecurityScopeResolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale) {
                return (url, url.startAccessingSecurityScopedResource())
            }
        }
        let url = URL(fileURLWithPath: s.path)
        return (url, false)
    }

    /// Re-read every enabled source from disk. Real counts, honest errors. Runs on a background
    /// queue for IO then publishes on the main actor.
    func reindexAll() {
        let snapshot = sources
        indexing = true; lastError = nil
        Task.detached(priority: .utility) {
            var built: [IndexedFile] = []
            var counts: [UUID: (files: Int, words: Int)] = [:]
            var firstError: String?
            for s in snapshot where s.enabled {
                let resolved = await MainActor.run { self.resolve(s) }
                guard let (folder, accessing) = resolved else { continue }
                defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
                let (files, words, err) = Self.index(folder: folder, sourceID: s.id)
                built.append(contentsOf: files)
                counts[s.id] = (files.count, words)
                if let err, firstError == nil { firstError = err }
            }
            // Snapshot into immutable lets so the MainActor closure captures no mutable vars
            // (clean under Swift 6 concurrency checking).
            let result = built
            let finalCounts = counts
            let finalError = firstError
            await MainActor.run {
                self.indexed = result
                for i in self.sources.indices {
                    if let c = finalCounts[self.sources[i].id] {
                        self.sources[i].fileCount = c.files
                        self.sources[i].wordCount = c.words
                        self.sources[i].lastIndexed = Date()
                    }
                }
                self.lastError = finalError
                self.indexing = false
            }
        }
    }

    /// Pure IO index of one folder. Returns indexed files + total words + an honest error string.
    nonisolated static func index(folder: URL, sourceID: UUID) -> (files: [IndexedFile], words: Int, error: String?) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else {
            return ([], 0, "Couldn't read \(folder.lastPathComponent).")
        }
        var files: [IndexedFile] = []
        var totalWords = 0
        for case let url as URL in en {
            // Prune heavy/noise directories.
            if url.hasDirectoryPath {
                if skipDirsContains(url.lastPathComponent) { en.skipDescendants() }
                continue
            }
            guard files.count < FileIndexer.maxFilesPerSource else { break }
            let name = url.lastPathComponent
            guard FileIndexer.isIndexable(name) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= FileIndexer.maxFileBytes else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            let rel = url.path.replacingOccurrences(of: folder.path + "/", with: "")
            files.append(IndexedFile(sourceID: sourceID, name: name, relPath: rel, text: text))
            totalWords += FileIndexer.wordCount(text)
        }
        return (files, totalWords, files.isEmpty ? nil : nil)
    }
    private nonisolated static func skipDirsContains(_ name: String) -> Bool { FileIndexer.skipDirs.contains(name) }

    /// Whether any enabled source actually has indexed content (for honest UI / RAG gating).
    var hasContent: Bool { !indexed.isEmpty }
    var indexedFileCount: Int { indexed.count }
    var enabledSourceCount: Int { sources.filter { $0.enabled }.count }

    /// RAG docs from the indexed files (one Doc per file → citations name the file).
    func ragDocs() -> [SemanticRAG.Doc] {
        indexed.map { SemanticRAG.Doc(id: $0.id, name: $0.relPath.isEmpty ? $0.name : $0.relPath, chunks: $0.chunks()) }
    }

    /// Plain filename/keyword search across indexed files for the agent's search_files tool.
    /// Returns matching (file, snippet) pairs — real content only.
    func search(_ query: String, max: Int = 6) -> [(file: String, snippet: String)] {
        Self.search(indexed, query: query, max: max)
    }

    /// Pure search core — `nonisolated static` so it is unit-testable without the @MainActor
    /// store (mirrors `MemoryStore.search`). Snippet matching runs on the ORIGINAL `f.text`
    /// via `.caseInsensitive`, so the returned Range belongs to that text. Taking an index
    /// from a separate `.lowercased()` copy is undefined and TRAPS ("String index is out of
    /// bounds") when lowercasing changes UTF-8 length near the match (e.g. "İ" U+0130 -> "i̇")
    /// — a buyer's own file with such Unicode would crash the agent's search_files tool. `q`
    /// arrives lowercased; `.caseInsensitive` matches the same substrings, index-safely.
    nonisolated static func search(_ files: [IndexedFile], query: String, max: Int = 6) -> [(file: String, snippet: String)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }
        var hits: [(String, String)] = []
        for f in files {
            if f.relPath.range(of: q, options: .caseInsensitive) != nil {
                hits.append((f.relPath, String(f.text.prefix(200))))
            } else if let r = f.text.range(of: q, options: .caseInsensitive) {
                let start = f.text.index(r.lowerBound, offsetBy: -60, limitedBy: f.text.startIndex) ?? f.text.startIndex
                let end = f.text.index(r.upperBound, offsetBy: 100, limitedBy: f.text.endIndex) ?? f.text.endIndex
                hits.append((f.relPath, "…" + f.text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines) + "…"))
            }
            if hits.count >= max { break }
        }
        return hits
    }
}
#endif // circuit-convert
