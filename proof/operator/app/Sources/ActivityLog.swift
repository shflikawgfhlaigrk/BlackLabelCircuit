// Sovereign — Activity Log: a persisted, app-wide PROOF-OF-EXECUTION ledger.
//
// Every autonomous or assistant action the operator actually performs writes ONE real
// receipt here: automation runs, multi-step agent runs, skill runs, reminder fires, and
// connector grants. This is the differentiator the FULL STANDARD calls "true
// proof-of-execution" + the enterprise "audit log": no narrated fake work — a row exists
// ONLY because something real happened, with a real timestamp, real status, and the real
// output/error it produced. Reviewable, searchable, filterable, and exportable by the buyer.
//
// ZERO FABRICATION: this store is never seeded. It starts empty and only the live runtime,
// agent, skills, and reminder paths append to it. Persisted as Codable JSON in the app's
// Application Support container, on the buyer's machine only.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// What kind of action a receipt records. Each maps to a real execution surface.
enum ActivityKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case automation     // a scheduled/triggered automation ran against the brain
    case agent          // a multi-step agent run completed
    case skill          // a skill was run over text/a document
    case reminder       // a reminder fired (notification)
    case connector      // a connector was granted/toggled (calendar, files, External)
    case crm            // a client/deal pipeline change was recorded
    var id: String { rawValue }

    var label: String {
        switch self {
        case .automation: return "Automation"
        case .agent:      return "Agent"
        case .skill:      return "Skill"
        case .reminder:   return "Reminder"
        case .connector:  return "Connector"
        case .crm:        return "CRM"
        }
    }
    var icon: String {
        switch self {
        case .automation: return "gearshape.2.fill"
        case .agent:      return "point.3.connected.trianglepath.dotted"
        case .skill:      return "wand.and.stars"
        case .reminder:   return "bell.fill"
        case .connector:  return "puzzlepiece.extension.fill"
        case .crm:        return "person.crop.rectangle.stack.fill"
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Whether the recorded action succeeded. `info` is for non-pass/fail facts (a reminder fired,
/// a connector granted) so the UI never has to pretend a notification "passed" a test.
enum ActivityOutcome: String, Codable, Hashable {
    case success, failure, info
    var tint: Color {
        switch self {
        case .success: return BLTheme.green
        case .failure: return .orange
        case .info:    return BLTheme.champagne
        }
    }
    var label: String {
        switch self {
        case .success: return "Success"
        case .failure: return "Failed"
        case .info:    return "Logged"
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// One immutable receipt. `detail` holds the real output or error the action produced.
struct ActivityEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: ActivityKind
    var title: String                 // what ran (e.g. the automation/skill/agent name)
    var detail: String                // the REAL output or error produced (may be long)
    var outcome: ActivityOutcome
    var at = Date()
    var durationMS: Int? = nil         // wall-clock duration when the caller measured it
    var stepCount: Int? = nil         // for agent runs: how many real receipt steps it took
    /// When this receipt is a STEP inside a multi-step agent run, this is the id of that run's
    /// terminal (head) receipt. nil = a top-level run/event. This is what lets the full agent
    /// trace survive the run: every tool-call step is its own real receipt, linked to its parent.
    var parentID: UUID? = nil
    /// True only for agent step receipts (a tool call + its real observation). Lets the UI fold
    /// steps under their parent run and keep the top-level ledger clean.
    var isStep: Bool { parentID != nil }
    /// SV-19: set true only on the single "assign-and-walk-away" ping written when an UNATTENDED
    /// scheduled run completes — the one reviewable item the buyer sees when they return. Optional
    /// so it decodes tolerantly (older ledgers lack the key → nil → not flagged; no data loss).
    var needsReview: Bool? = nil

    var snippet: String {
        let t = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(no output)" : String(t.prefix(160))
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class ActivityLog: ObservableObject {
    /// Newest first. Capped so the ledger can't grow unbounded on a long-running machine.
    @Published private(set) var entries: [ActivityEntry] = [] { didSet { save() } }

    static let cap = 1000
    private let url: URL
    private var loading = false
    /// Demo Mode: keep synthetic sample receipts in memory only, never on the buyer's disk.
    private var demoEphemeral = false

    init(filename: String = "activity.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sovereign", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(filename)
        load()
    }

    private func load() {
        loading = true; defer { loading = false }
        guard let data = try? Data(contentsOf: url) else { return }   // no file yet — fresh install
        guard let rows = try? JSONDecoder().decode([ActivityEntry].self, from: data) else {
            // Unreadable ≠ empty: park the bytes where the next save can't destroy them.
            preserveCorruptBlob(at: url)
            return
        }
        entries = rows
    }
    private func save() {
        guard !loading, !demoEphemeral else { return }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }

    /// Seed clearly-labeled SAMPLE proof-of-execution receipts for Demo Mode — in memory only.
    /// Idempotent; never stacks on real receipts.
    func seedDemo() {
        demoEphemeral = true   // ephemeral first → real ledger on disk untouched; restored by endDemo()
        entries = DemoSeed.activity
    }
    /// Leave Demo Mode: drop sample receipts, restore the buyer's real on-disk ledger, re-enable saves.
    func endDemo() {
        loading = true
        entries = []
        load()
        loading = false
        demoEphemeral = false
    }

    /// Permanently erase the entire proof-of-execution ledger — in memory and on disk
    /// (App Store Guideline 5.1.1(v)). Persistence is re-enabled so the empty state is written.
    func wipeAll() {
        demoEphemeral = false
        loading = false
        entries = []
    }

    // MARK: Recording (the ONLY way rows appear — always a real action)

    /// Record a receipt. Returns the stored entry. Trims to the cap (oldest dropped).
    @discardableResult
    func record(_ entry: ActivityEntry) -> ActivityEntry {
        entries.insert(entry, at: 0)
        if entries.count > Self.cap { entries = Array(entries.prefix(Self.cap)) }
        return entry
    }

    func record(kind: ActivityKind, title: String, detail: String, outcome: ActivityOutcome,
                durationMS: Int? = nil, stepCount: Int? = nil, parentID: UUID? = nil) {
        record(ActivityEntry(kind: kind, title: title, detail: detail, outcome: outcome,
                             durationMS: durationMS, stepCount: stepCount, parentID: parentID))
    }

    /// Record a single STEP inside an agent run. Returns the stored step (so the caller can
    /// keep its id if needed). Linked to its parent run via `parentID`.
    @discardableResult
    func recordStep(parentID: UUID, title: String, detail: String, outcome: ActivityOutcome) -> ActivityEntry {
        record(ActivityEntry(kind: .agent, title: title, detail: detail, outcome: outcome,
                             parentID: parentID))
    }

    /// SV-19 — record the SINGLE "assign-and-walk-away" review ping for a completed UNATTENDED run.
    /// This is the one reviewable receipt the buyer sees when they come back; the run's own
    /// execution receipt(s) are separate. Flagged `needsReview` so it surfaces in the review inbox.
    @discardableResult
    func recordReviewPing(kind: ActivityKind = .automation, title: String, detail: String,
                          outcome: ActivityOutcome) -> ActivityEntry {
        record(ActivityEntry(kind: kind, title: title, detail: detail, outcome: outcome, needsReview: true))
    }

    /// The buyer's review inbox: completed unattended runs still awaiting a look, newest first.
    var reviewInbox: [ActivityEntry] { entries.filter { $0.needsReview == true } }
    var pendingReviewCount: Int { reviewInbox.count }

    /// Mark a walk-away ping as seen — drops it from the inbox but KEEPS the receipt (proof stays).
    func markReviewed(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries[i]; e.needsReview = false; entries[i] = e
    }

    func clear() { entries.removeAll() }
    func delete(_ id: UUID) { entries.removeAll { $0.id == id } }

    // MARK: Querying (for the screen + global search + dashboard counts)

    /// Top-level receipts only (a run head or a standalone event) — agent STEP receipts are
    /// folded under their parent and excluded here so the main ledger + counts stay clean.
    var topLevel: [ActivityEntry] { entries.filter { !$0.isStep } }

    var isEmpty: Bool { entries.isEmpty }
    var successCount: Int { topLevel.filter { $0.outcome == .success }.count }
    var failureCount: Int { topLevel.filter { $0.outcome == .failure }.count }
    func count(of kind: ActivityKind) -> Int { topLevel.filter { $0.kind == kind }.count }

    /// The real per-step receipts recorded during a given agent run, oldest first (the order they
    /// actually executed). Drives the expandable agent trace in the UI.
    func steps(of parentID: UUID) -> [ActivityEntry] {
        entries.filter { $0.parentID == parentID }.sorted { $0.at < $1.at }
    }

    /// A named, inclusive date window for filtering/export. nil bound = open-ended.
    struct DateRange: Equatable { var start: Date?; var end: Date?
        func contains(_ d: Date) -> Bool {
            if let s = start, d < s { return false }
            if let e = end, d > e { return false }
            return true
        }
        var isOpen: Bool { start == nil && end == nil }
    }

    /// Filtered + free-text searched, newest first. Operates on top-level receipts; an optional
    /// date range scopes by receipt timestamp.
    func filtered(kind: ActivityKind?, outcome: ActivityOutcome?, query: String,
                  range: DateRange = DateRange()) -> [ActivityEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return topLevel.filter { e in
            if let k = kind, e.kind != k { return false }
            if let o = outcome, e.outcome != o { return false }
            if !range.contains(e.at) { return false }
            if q.count >= 2, !(e.title.range(of: q, options: .caseInsensitive) != nil || e.detail.range(of: q, options: .caseInsensitive) != nil) { return false }
            return true
        }
    }

    /// Plain free-text search across the ledger (used by the global ⌘K search merge). Returns
    /// top-level receipts (so a ⌘K hit deep-links to a real row, not a folded sub-step).
    func search(_ raw: String) -> [ActivityEntry] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }
        return topLevel.filter { $0.title.range(of: q, options: .caseInsensitive) != nil || $0.detail.range(of: q, options: .caseInsensitive) != nil }
    }

    // MARK: Export (Markdown — a real, portable proof-of-execution report)

    /// Export the WHOLE top-level ledger.
    func exportMarkdown() -> String { exportMarkdown(topLevel, scopeNote: nil) }

    /// Export an explicit, already-filtered set of top-level receipts (scoped export). Each agent
    /// run carries its real per-step trace so the proof is complete. `scopeNote` documents the
    /// filter that produced this subset (date range, kind/outcome) so the report is self-describing.
    func exportMarkdown(_ rows: [ActivityEntry], scopeNote: String?) -> String {
        let heads = rows.filter { !$0.isStep }
        let succeeded = heads.filter { $0.outcome == .success }.count
        let failed = heads.filter { $0.outcome == .failure }.count
        var out = "# Sovereign — Activity Log\n\n"
        out += "Exported \(Date().formatted(date: .abbreviated, time: .shortened)) · "
        out += "\(heads.count) receipt\(heads.count == 1 ? "" : "s") · "
        out += "\(succeeded) succeeded · \(failed) failed\n"
        if let note = scopeNote, !note.isEmpty { out += "Scope: \(note)\n" }
        out += "\n"
        if heads.isEmpty {
            out += scopeNote == nil ? "_No activity recorded yet._\n" : "_No receipts match this scope._\n"
            return out
        }
        let fmt: (Date) -> String = { $0.formatted(date: .abbreviated, time: .standard) }
        for e in heads {
            out += "## \(e.kind.label) · \(e.title)\n"
            out += "- When: \(fmt(e.at))\n"
            out += "- Outcome: \(e.outcome.label)\n"
            if let ms = e.durationMS { out += "- Duration: \(ms) ms\n" }
            if let n = e.stepCount { out += "- Steps: \(n)\n" }
            let body = e.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { out += "\n\(body)\n" }
            // Inline the real agent step trace, if any.
            let runSteps = steps(of: e.id)
            if !runSteps.isEmpty {
                out += "\n### Trace\n"
                for (i, s) in runSteps.enumerated() {
                    out += "\(i + 1). **\(s.title)** — \(s.outcome.label)\n"
                    let sb = s.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sb.isEmpty { out += "   \(sb.replacingOccurrences(of: "\n", with: "\n   "))\n" }
                }
            }
            out += "\n---\n\n"
        }
        return out
    }
}
#endif // circuit-convert
