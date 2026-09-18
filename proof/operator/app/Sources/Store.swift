// Sovereign — expanded on-device data layer: conversations, knowledge documents (RAG),
// reminders, and automations. Everything is persisted as Codable JSON in the app's
// Application Support container. NO seed/sample/demo data — the app starts empty and
// every value traces to something the buyer created. Honest counts only.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Conversations (many named threads, searchable, exportable)
struct Conversation: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = "New conversation"
    var messages: [ChatMessage] = []
    var personaName = ""          // optional per-conversation persona override (by name)
    var created = Date()
    var updated = Date()
    var pinned = false

    var preview: String {
        if let last = messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) ?? messages.last {
            return String(last.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(90))
        }
        return "No messages yet"
    }
    /// Auto-title from the first user message if still default.
    mutating func autoTitleIfNeeded() {
        guard title == "New conversation" || title.isEmpty,
              let first = messages.first(where: { $0.role == .user })?.text else { return }
        let t = first.trimmingCharacters(in: .whitespacesAndNewlines)
        title = String(t.prefix(48)) + (t.count > 48 ? "…" : "")
    }
}

// MARK: - Knowledge documents (imported text → chunked for keyword-RAG grounding)
struct KnowledgeDoc: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = "Untitled"
    var kind = "text"             // text | markdown | imported | web
    var body = ""
    var created = Date()
    var enabled = true            // included in RAG grounding when on
    // Provenance for a page added via "Add URL" (multi-source web RAG). nil for local notes/
    // imports. Optional so existing persisted JSON (no key) decodes back to nil — backward-safe.
    // The buyer can open the original web source from the doc row.
    var sourceURL: String? = nil

    var wordCount: Int { body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
    var preview: String {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Empty document" : String(t.prefix(110))
    }
    /// Split into retrieval chunks (paragraph-ish, ~600 chars). Any single paragraph that alone
    /// exceeds the budget — a long unbroken note, a pasted transcript, minified JSON/CSV, or code
    /// with no blank lines — is hard-split FIRST, so RAG + the citation "Sources" bar stay at
    /// passage granularity instead of collapsing the whole document into one giant cited chunk.
    /// (FileIndexer.chunk already guards indexed files this way; this brings Knowledge docs in line.)
    func chunks() -> [String] {
        let budget = 600
        let paras = body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap { Self.hardSplit($0, budget: budget) }
        var out: [String] = []
        var buf = ""
        for p in paras {
            if buf.count + p.count > budget { if !buf.isEmpty { out.append(buf) }; buf = p }
            else { buf = buf.isEmpty ? p : buf + "\n\n" + p }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    /// Hard-split one oversized passage into <=budget-sized pieces, cutting on the last whitespace
    /// inside each window so words aren't severed (a whitespace-free blob like minified JSON is cut
    /// at the hard budget). Returns [s] unchanged when it already fits. nonisolated + static so the
    /// suite can lock it headless. Guarantees forward progress — `start` advances every iteration.
    nonisolated static func hardSplit(_ s: String, budget: Int) -> [String] {
        guard budget > 0, s.count > budget else { return [s] }
        var pieces: [String] = []
        var start = s.startIndex
        while start < s.endIndex {
            guard let hardEnd = s.index(start, offsetBy: budget, limitedBy: s.endIndex) else {
                let tail = s[start...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { pieces.append(tail) }
                break
            }
            let window = s[start..<hardEnd]
            let cut = window.lastIndex(where: { $0.isWhitespace }).map { s.index(after: $0) } ?? hardEnd
            let next = cut > start ? cut : hardEnd          // never stall on a leading boundary
            let piece = s[start..<next].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            start = next
        }
        return pieces.isEmpty ? [s] : pieces
    }
}

// MARK: - Reminders (one-off or recurring, fire while the app is running)
enum ReminderRepeat: String, Codable, CaseIterable, Identifiable {
    case once, hourly, daily, weekly
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
struct Reminder: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = ""
    var fireAt = Date().addingTimeInterval(3600)
    var repeats: ReminderRepeat = .once
    var done = false
    var created = Date()
    var lastFired: Date?
}

// MARK: - Automations (a saved instruction the brain runs on a schedule or on demand;
// the output is appended to a log. Honest: runs only while the app is open.)
struct Automation: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = "Untitled automation"
    var instruction = ""          // the prompt run against the on-device brain
    var schedule: ReminderRepeat = .daily
    var enabled = false
    var groundOnKnowledge = true  // include knowledge docs as context
    var created = Date()
    var lastRun: Date?
    var lastOutput = ""
    var runCount = 0
}

/// A store file that EXISTS but no longer decodes must never be silently replaced — the next
/// save() would atomically overwrite the only recoverable copy of the buyer's data. Move the
/// bytes aside (<name>.corrupt-<timestamp>) so recovery stays possible, and return the aside
/// filename for the caller to surface. Never throws; a failed rename leaves the original alone.
@discardableResult
func preserveCorruptBlob(at url: URL) -> String? {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let aside = url.deletingLastPathComponent()
        .appendingPathComponent(url.lastPathComponent + ".corrupt-" + stamp)
    do {
        try FileManager.default.moveItem(at: url, to: aside)
        return aside.lastPathComponent
    } catch { return nil }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - The expanded store
@MainActor
final class Store: ObservableObject {
    @Published var conversations: [Conversation] = [] { didSet { save() } }
    @Published var documents: [KnowledgeDoc] = [] { didSet { save() } }
    @Published var reminders: [Reminder] = [] { didSet { save() } }
    @Published var automations: [Automation] = [] { didSet { save() } }
    @Published var activeConversationID: UUID?
    /// Honest storage health for the Settings panel: set when the on-disk store couldn't be read
    /// (bytes preserved aside) or the last save failed. nil == healthy. Never persisted.
    @Published var dataHealthNote: String?

    private struct Box: Codable {
        var conversations: [Conversation]
        var documents: [KnowledgeDoc]
        var reminders: [Reminder]
        var automations: [Automation]
        var activeConversationID: UUID?
    }
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sovereign", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("store.json")
        load()
    }

    private func load() {
        loading = true; defer { loading = false }
        guard let data = try? Data(contentsOf: url) else { return }   // no file yet — fresh install
        guard let box = try? JSONDecoder().decode(Box.self, from: data) else {
            // Unreadable ≠ empty: park the bytes where a later save can't destroy them, and say so.
            let aside = preserveCorruptBlob(at: url)
            dataHealthNote = "The saved workspace file couldn't be read, so this session started empty."
                + (aside.map { " The unreadable file was preserved as \($0) in the app's data folder." } ?? "")
            return
        }
        conversations = box.conversations
        documents = box.documents
        reminders = box.reminders
        automations = box.automations
        activeConversationID = box.activeConversationID ?? conversations.first?.id
    }
    private var loading = false
    /// When true, ALL writes are kept in memory only — used by Demo Mode so synthetic sample
    /// data never touches the buyer's on-disk store (ship-no-data). Set once when demo is entered.
    private var demoEphemeral = false
    private func save() {
        guard !loading, !demoEphemeral else { return }
        let box = Box(conversations: conversations, documents: documents, reminders: reminders,
                      automations: automations, activeConversationID: activeConversationID)
        do {
            let data = try JSONEncoder().encode(box)
            try data.write(to: url, options: .atomic)
            if dataHealthNote?.hasPrefix("Saving failed") == true { dataHealthNote = nil }
        } catch {
            // A swallowed write failure would let the UI imply everything is saved while nothing is.
            dataHealthNote = "Saving failed — recent changes are not on disk: \(error.localizedDescription)"
        }
    }

    // MARK: Conversations
    var activeConversation: Conversation? {
        guard let id = activeConversationID else { return conversations.first }
        return conversations.first { $0.id == id }
    }
    var sortedConversations: [Conversation] {
        conversations.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updated > b.updated
        }
    }
    @discardableResult
    func newConversation(persona: String = "") -> Conversation {
        let c = Conversation(personaName: persona)
        conversations.insert(c, at: 0)
        activeConversationID = c.id
        return c
    }
    func ensureActiveConversation() {
        if activeConversation == nil { newConversation() }
    }
    func appendMessage(_ m: ChatMessage, to id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].messages.append(m)
        conversations[i].updated = Date()
        conversations[i].autoTitleIfNeeded()
    }
    func updateLastAssistant(_ text: String, in id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let j = conversations[i].messages.lastIndex(where: { $0.role == .assistant }) {
            conversations[i].messages[j].text = text
            conversations[i].updated = Date()
        }
    }
    func removeLastAssistant(in id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let j = conversations[i].messages.lastIndex(where: { $0.role == .assistant }) {
            conversations[i].messages.remove(at: j)
        }
    }
    /// The last user prompt (for "regenerate").
    func lastUserPrompt(in id: UUID) -> String? {
        conversations.first { $0.id == id }?.messages.last(where: { $0.role == .user })?.text
    }
    func renameConversation(_ id: UUID, to title: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[i].title = t.isEmpty ? "Untitled" : t
    }
    func togglePin(_ id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].pinned.toggle()
    }
    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if activeConversationID == id { activeConversationID = conversations.first?.id }
    }
    func clearActiveMessages() {
        guard let id = activeConversationID, let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].messages.removeAll()
    }

    // MARK: Documents
    func upsertDoc(_ d: KnowledgeDoc) {
        if let i = documents.firstIndex(where: { $0.id == d.id }) { documents[i] = d }
        else { documents.insert(d, at: 0) }
    }
    func deleteDoc(_ d: KnowledgeDoc) { documents.removeAll { $0.id == d.id } }

    // MARK: Reminders
    func upsertReminder(_ r: Reminder) {
        if let i = reminders.firstIndex(where: { $0.id == r.id }) { reminders[i] = r }
        else { reminders.append(r) }
    }
    func deleteReminder(_ r: Reminder) { reminders.removeAll { $0.id == r.id } }
    var upcomingReminders: [Reminder] {
        reminders.filter { !$0.done }.sorted { $0.fireAt < $1.fireAt }
    }

    // MARK: Automations
    func upsertAutomation(_ a: Automation) {
        if let i = automations.firstIndex(where: { $0.id == a.id }) { automations[i] = a }
        else { automations.insert(a, at: 0) }
    }
    func deleteAutomation(_ a: Automation) { automations.removeAll { $0.id == a.id } }
    func recordAutomationRun(_ id: UUID, output: String) {
        guard let i = automations.firstIndex(where: { $0.id == id }) else { return }
        automations[i].lastRun = Date()
        automations[i].lastOutput = output
        automations[i].runCount += 1
    }

    // MARK: RAG grounding from enabled documents (semantic embedding retrieval, on-device)
    nonisolated static let docChunkCap = 6

    /// MULTI-SOURCE RAG: the Files connector is an optional second retrieval source. The Store
    /// holds a weak reference so `retrieve(includeFiles:)` can merge the buyer's indexed files
    /// with their Knowledge docs in one unified ranking. Set in RootView wiring.
    weak var files: FilesConnector?

    /// Retrieve the top relevant chunks (with citation indices) across enabled docs — and, when
    /// `includeFiles` is true, the buyer's connected files too (unified multi-source ranking).
    /// Semantic when `useSemantic` is true and on-device embeddings exist; keyword fallback otherwise.
    /// Honest: returns [] when nothing is enabled or nothing clears the relevance floor.
    func retrieve(for query: String, max: Int = Store.docChunkCap, useSemantic: Bool = true,
                  includeFiles: Bool = false) -> [RetrievedChunk] {
        var docs = documents.filter { $0.enabled && !$0.body.isEmpty }
            .map { SemanticRAG.Doc(id: $0.id, name: $0.name, chunks: $0.chunks()) }
        if includeFiles { docs.append(contentsOf: files?.ragDocs() ?? []) }
        guard !docs.isEmpty else { return [] }
        return SemanticRAG.retrieve(query: query, docs: docs, max: max, useSemantic: useSemantic)
    }

    /// Returns the grounding text block (with [n] citation tags) for `query`, or "" when none.
    func documentGrounding(for query: String, max: Int = Store.docChunkCap, useSemantic: Bool = true,
                           includeFiles: Bool = false) -> String {
        SemanticRAG.groundingText(retrieve(for: query, max: max, useSemantic: useSemantic, includeFiles: includeFiles))
    }
    /// How many enabled documents actually feed retrieval (for honest UI counts).
    var groundedDocCount: Int { documents.filter { $0.enabled && !$0.body.isEmpty }.count }

    private func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    // MARK: Global search across conversations + documents
    struct SearchHit: Identifiable, Hashable {
        let id = UUID()
        let kind: String     // "Conversation" | "Document" | "Reminder" | "Automation"
        let title: String
        let snippet: String
        let conversationID: UUID?
        let documentID: UUID?
    }
    func search(_ raw: String) -> [SearchHit] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }
        var hits: [SearchHit] = []
        for c in conversations {
            if c.title.range(of: q, options: .caseInsensitive) != nil {
                hits.append(SearchHit(kind: "Conversation", title: c.title, snippet: c.preview, conversationID: c.id, documentID: nil))
            } else if let m = c.messages.first(where: { $0.text.range(of: q, options: .caseInsensitive) != nil }) {
                hits.append(SearchHit(kind: "Conversation", title: c.title, snippet: snippet(m.text, around: q), conversationID: c.id, documentID: nil))
            }
        }
        for d in documents where d.name.range(of: q, options: .caseInsensitive) != nil || d.body.range(of: q, options: .caseInsensitive) != nil {
            hits.append(SearchHit(kind: "Document", title: d.name, snippet: snippet(d.body, around: q), conversationID: nil, documentID: d.id))
        }
        for r in reminders where r.title.range(of: q, options: .caseInsensitive) != nil {
            hits.append(SearchHit(kind: "Reminder", title: r.title, snippet: r.fireAt.formatted(), conversationID: nil, documentID: nil))
        }
        for a in automations where a.name.range(of: q, options: .caseInsensitive) != nil || a.instruction.range(of: q, options: .caseInsensitive) != nil {
            hits.append(SearchHit(kind: "Automation", title: a.name, snippet: a.instruction, conversationID: nil, documentID: nil))
        }
        return hits
    }
    private func snippet(_ text: String, around q: String) -> String {
        // Search on `text` itself (case-insensitive) so the returned Range belongs to `text`.
        // Using an index from a separate `.lowercased()` copy is undefined and TRAPS ("String
        // index is out of bounds") when lowercasing changes UTF-8 length near the match
        // (e.g. "İ" -> "i̇"). q arrives already lowercased; .caseInsensitive matches regardless.
        guard let r = text.range(of: q, options: .caseInsensitive) else { return String(text.prefix(90)) }
        let start = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex
        return "…" + text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    // MARK: Aggregate honest counts for the dashboard
    var totalMessages: Int { conversations.reduce(0) { $0 + $1.messages.count } }
    var totalKnowledgeWords: Int { documents.reduce(0) { $0 + $1.wordCount } }

    // MARK: - Demo Mode seeding (synthetic, in-memory only — see DemoMode.swift)
    /// Replace live state with clearly-labeled SAMPLE data for the reviewer/sample experience.
    /// Marks the store ephemeral first so NONE of this is ever persisted to disk. Idempotent.
    func seedDemo() {
        // Mark ephemeral FIRST so the assignments below can never persist; the buyer's real data
        // stays safe on disk and is restored verbatim by endDemo(). We replace the in-memory view
        // unconditionally so a reviewer always sees a fully-populated app, even on a machine that
        // happens to have leftover real data in this session.
        demoEphemeral = true
        conversations = DemoSeed.conversations
        documents = DemoSeed.documents
        reminders = DemoSeed.reminders
        automations = DemoSeed.automations
        activeConversationID = conversations.first?.id
    }
    /// Leave Demo Mode: drop the in-memory sample data and re-enable persistence, restoring the
    /// buyer's real (on-disk) state. So a real user can demo then sign back in without losing saves.
    func endDemo() {
        loading = true
        conversations = []; documents = []; reminders = []; automations = []; activeConversationID = nil
        load()
        loading = false
        demoEphemeral = false
    }

    /// Permanently erase ALL conversations, knowledge docs, reminders, and automations — in memory
    /// and on disk (App Store Guideline 5.1.1(v) "delete account and all data"). Leaves Demo Mode
    /// ephemerality off so the empty state persists.
    func wipeAll() {
        demoEphemeral = false
        conversations = []; documents = []; reminders = []; automations = []; activeConversationID = nil
        save()
    }
}
#endif // circuit-convert
