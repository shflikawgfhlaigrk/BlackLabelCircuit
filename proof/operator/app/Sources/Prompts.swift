// Sovereign — Prompt Library. A persistent, searchable collection of reusable prompts the
// buyer can insert into a conversation with one click (or via ⌘K). This is the Raycast /
// ChatGPT "saved prompts & snippets" pattern, distinct from Skills: a Skill TRANSFORMS an
// input through a template; a Prompt is a reusable STARTING message you drop into the chat.
//
// Built-ins ship as TEMPLATES (plain text starters — no fabricated output, no personal data).
// The buyer adds, edits, deletes, and organizes their own. Every value persists on-device.
// Honest counts only; nothing is invented.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Categories (a small, neutral taxonomy the buyer can file prompts under)
enum PromptCategory: String, Codable, CaseIterable, Identifiable {
    case writing, coding, productivity, research, personal, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .writing: return "Writing"
        case .coding: return "Coding"
        case .productivity: return "Productivity"
        case .research: return "Research"
        case .personal: return "Personal"
        case .custom: return "Custom"
        }
    }
    var icon: String {
        switch self {
        case .writing: return "pencil.line"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .productivity: return "checklist"
        case .research: return "magnifyingglass"
        case .personal: return "person.fill"
        case .custom: return "star.fill"
        }
    }
}

// MARK: - A saved prompt
struct SavedPrompt: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var body: String = ""
    var category: PromptCategory = .custom
    var tags: [String] = []
    var builtIn: Bool = false
    var pinned: Bool = false
    var created = Date()
    var useCount: Int = 0
    var lastUsed: Date?

    var preview: String {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Empty prompt" : String(t.prefix(110))
    }

    /// True if this prompt matches a free-text query across title, body, and tags.
    /// Case-insensitive, whitespace-trimmed. An empty query matches everything — the
    /// caller decides whether to short-circuit. Pure so it is unit-testable off-actor.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if title.lowercased().contains(q) { return true }
        if body.lowercased().contains(q) { return true }
        return tags.contains { $0.lowercased().contains(q) }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - The library
@MainActor
final class PromptLibrary: ObservableObject {
    @Published var custom: [SavedPrompt] = [] { didSet { persist() } }
    private let d = UserDefaults.standard
    private let key = "com.blacklabel.sovereign.prompts.v1"
    /// Demo Mode: keep synthetic sample prompts in memory only, never in UserDefaults.
    private var demoEphemeral = false

    init() {
        if let data = d.data(forKey: key), let p = try? JSONDecoder().decode([SavedPrompt].self, from: data) { custom = p }
    }
    private func persist() {
        guard !demoEphemeral else { return }
        if let data = try? JSONEncoder().encode(custom) { d.set(data, forKey: key) }
    }

    /// Seed clearly-labeled SAMPLE custom prompts for Demo Mode — in memory only. Idempotent.
    func seedDemo() {
        demoEphemeral = true   // ephemeral first → real prompts in UserDefaults untouched; restored by endDemo()
        custom = DemoSeed.prompts
    }
    /// Leave Demo Mode: drop sample prompts, restore the buyer's real on-disk prompts, re-enable saves.
    func endDemo() {
        demoEphemeral = true
        if let data = d.data(forKey: key), let p = try? JSONDecoder().decode([SavedPrompt].self, from: data) { custom = p }
        else { custom = [] }
        demoEphemeral = false
    }

    /// Permanently erase ALL of the buyer's saved prompts — in memory and on disk
    /// (App Store Guideline 5.1.1(v)). Persistence is re-enabled so the empty state is written.
    func wipeAll() {
        demoEphemeral = false
        custom = []
    }

    // CRUD
    func add(_ p: SavedPrompt) { custom.insert(p, at: 0) }
    func update(_ p: SavedPrompt) { if let i = custom.firstIndex(where: { $0.id == p.id }) { custom[i] = p } }
    func delete(_ p: SavedPrompt) { custom.removeAll { $0.id == p.id } }
    func togglePin(_ p: SavedPrompt) {
        if let i = custom.firstIndex(where: { $0.id == p.id }) { custom[i].pinned.toggle() }
    }

    /// Record a use. Built-ins are immutable templates, so a built-in's usage is tracked by
    /// promoting a lightweight copy into `custom` only if the buyer has already saved it;
    /// otherwise the built-in stat is ephemeral (we never mutate the static template list).
    func recordUse(_ p: SavedPrompt) {
        if let i = custom.firstIndex(where: { $0.id == p.id }) {
            custom[i].useCount += 1
            custom[i].lastUsed = Date()
        }
    }

    /// All prompts = built-ins + the buyer's own. Built-ins first only when unsorted.
    var all: [SavedPrompt] { Self.builtIns + custom }

    /// Filtered + sorted view for the UI. Pinned first, then most-recently-used, then
    /// the rest. Pure-ish (reads `all`); the heavy lifting is the static `filter` below.
    func view(query: String, category: PromptCategory?) -> [SavedPrompt] {
        Self.filter(all, query: query, category: category)
    }

    var categoriesInUse: [PromptCategory] {
        let used = Set(all.map { $0.category })
        return PromptCategory.allCases.filter { used.contains($0) }
    }

    /// Static, pure filter+sort so it can be unit-tested without the main actor.
    /// - pinned prompts float to the top
    /// - then sorted by useCount desc, then title
    nonisolated static func filter(_ prompts: [SavedPrompt], query: String, category: PromptCategory?) -> [SavedPrompt] {
        prompts
            .filter { category == nil || $0.category == category }
            .filter { $0.matches(query) }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                if a.useCount != b.useCount { return a.useCount > b.useCount }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
    }

    // MARK: - Built-in starter prompts (plain reusable starters — no fabricated output,
    // no personal data, no Utah data). These teach the surface and give immediate value.
    static let builtIns: [SavedPrompt] = [
        SavedPrompt(title: "Summarize my day", body: "Help me summarize what I accomplished today and what's still open. Ask me for the details you need, then organize it into Done / In progress / Blocked.", category: .productivity, tags: ["summary", "standup"], builtIn: true),
        SavedPrompt(title: "Draft a professional email", body: "Draft a clear, courteous email. I'll give you the recipient, the goal, and any key points. Keep it concise and professional, and offer a subject line.", category: .writing, tags: ["email", "writing"], builtIn: true),
        SavedPrompt(title: "Explain like I'm smart but new", body: "Explain the following concept to me clearly and accurately — assume I'm intelligent but new to the topic. Use a concrete example. Concept:", category: .research, tags: ["learn", "explain"], builtIn: true),
        SavedPrompt(title: "Plan a project", body: "Help me break a project into a realistic plan. Ask me for the goal and deadline, then propose milestones, tasks, and an order to tackle them.", category: .productivity, tags: ["plan", "project"], builtIn: true),
        SavedPrompt(title: "Code review this snippet", body: "Review this code for real bugs, edge cases, and concrete improvements. Be specific and don't invent APIs. Code:", category: .coding, tags: ["code", "review"], builtIn: true),
        SavedPrompt(title: "Write a function", body: "Write a well-documented function for the following. State assumptions, handle edge cases, and explain your approach briefly. Task:", category: .coding, tags: ["code", "write"], builtIn: true),
        SavedPrompt(title: "Brainstorm ideas", body: "Brainstorm a focused, practical set of ideas for the following. Give me distinct directions, not variations of one. Topic:", category: .writing, tags: ["ideas", "brainstorm"], builtIn: true),
        SavedPrompt(title: "Turn notes into action items", body: "Read these notes and pull out concrete action items with an owner where one is named. Keep only tasks the text actually implies. Notes:", category: .productivity, tags: ["tasks", "notes"], builtIn: true),
        SavedPrompt(title: "Compare options", body: "Help me compare a few options. I'll list them and what matters to me; give me an honest pros/cons table and a recommendation with the reasoning.", category: .research, tags: ["decision", "compare"], builtIn: true),
        SavedPrompt(title: "Daily intention", body: "Ask me three short questions to set a focused intention for today, then reflect it back as one clear sentence I can keep in mind.", category: .personal, tags: ["focus", "reflection"], builtIn: true)
    ]
}
#endif // circuit-convert
