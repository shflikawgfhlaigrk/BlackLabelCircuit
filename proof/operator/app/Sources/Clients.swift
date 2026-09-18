// Sovereign — STRUCTURED CRM RECORDS: clients (contact history) + deals (pipeline).
//
// The website promises the memory vault "stores and retrieves client history and deal pipeline."
// Memory.swift holds free-text standing facts; this adds the STRUCTURED layer that claim implies:
// real Client records (name, org, contacts, notes) and Deal records linked to a client, each moving
// through an explicit pipeline (lead → qualified → proposal → won/lost) with a real history of every
// stage change. Persisted as Codable JSON in the app's Application Support container, exactly like
// Store.swift and ActivityLog.swift — pure local storage, no subprocess, no socket, no network.
//
// HONESTY (same bar as every other store):
//  - Ships EMPTY. No bundled clients or deals — every record is one the BUYER entered or the agent
//    saved on their instruction. Demo Mode shows clearly-labeled SAMPLE records, in memory only.
//  - Nothing is enriched or invented: no auto-pulled company data, no fabricated contacts, no made-up
//    pipeline value. A record holds exactly what was typed.
//  - Retrieval returns only real stored records, or an honest empty result.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Client (a contact / account the buyer is working)
struct Client: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var org: String = ""
    var email: String = ""
    var phone: String = ""
    var notes: String = ""
    var created = Date()
    var updated = Date()

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedOrg: String { org.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { !trimmedName.isEmpty }

    /// Display label: "Name — Org" when both present, else whichever exists.
    var displayName: String {
        let n = trimmedName, o = trimmedOrg
        if n.isEmpty { return o.isEmpty ? "Untitled contact" : o }
        return o.isEmpty ? n : "\(n) — \(o)"
    }

    /// True when this record is referenced by free text `prompt` (the buyer naming the client in
    /// chat, or a query naming it). Conservative: a full name/org substring match (≥3 chars), OR a
    /// name/org WORD of length ≥4 appearing as a standalone token in the text. Pure + nonisolated so
    /// it unit-tests off the main actor and never confabulates a match.
    func referenced(by prompt: String) -> Bool {
        let hay = prompt.lowercased()
        guard !hay.isEmpty else { return false }
        let n = trimmedName.lowercased(), o = trimmedOrg.lowercased()
        if n.count >= 3, hay.contains(n) { return true }
        if o.count >= 3, hay.contains(o) { return true }
        let words = Set(hay.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let tokens = (n + " " + o).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for tok in tokens where tok.count >= 4 { if words.contains(tok) { return true } }
        return false
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Deal stage (the pipeline)
enum DealStage: String, Codable, CaseIterable, Identifiable, Hashable {
    case lead, qualified, proposal, won, lost
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lead:      return "Lead"
        case .qualified: return "Qualified"
        case .proposal:  return "Proposal"
        case .won:       return "Won"
        case .lost:      return "Lost"
        }
    }
    /// Board ordering — open stages first, terminal (won/lost) last.
    var order: Int {
        switch self {
        case .lead:      return 0
        case .qualified: return 1
        case .proposal:  return 2
        case .won:       return 3
        case .lost:      return 4
        }
    }
    /// Still in motion — counts toward the open-pipeline value.
    var isOpen: Bool { self == .lead || self == .qualified || self == .proposal }
    var isWon: Bool { self == .won }
    /// The canonical "advance" stage (the next open stage; closing/reopening is always allowed in
    /// the UI). nil once terminal. Pure → testable.
    var nextOpen: DealStage? {
        switch self {
        case .lead:      return .qualified
        case .qualified: return .proposal
        case .proposal:  return .won
        case .won, .lost: return nil
        }
    }
    var tint: Color {
        switch self {
        case .lead:      return BLTheme.sub
        case .qualified: return BLTheme.champagne
        case .proposal:  return BLTheme.gold
        case .won:       return BLTheme.green
        case .lost:      return BLTheme.danger
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - A single stage transition (the deal's real, append-only history)
struct StageChange: Codable, Hashable {
    var from: DealStage?     // nil for the initial stage recorded at creation
    var to: DealStage
    var at = Date()
    var note: String = ""
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Deal (a pipeline opportunity linked to a client)
struct Deal: Identifiable, Codable, Hashable {
    var id = UUID()
    var clientID: UUID
    var title: String = ""
    var stage: DealStage = .lead
    var value: Double = 0           // amount in the buyer's own currency (0 = unset)
    var nextAction: String = ""
    var history: [StageChange] = []
    var created = Date()
    var updated = Date()

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var displayTitle: String { trimmedTitle.isEmpty ? "Untitled deal" : trimmedTitle }
    var isValid: Bool { !trimmedTitle.isEmpty }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - The CRM store (clients + deals), persisted on the buyer's machine only
@MainActor
final class ClientStore: ObservableObject {
    @Published var clients: [Client] = [] { didSet { save() } }
    @Published var deals: [Deal] = [] { didSet { save() } }

    /// Proof-of-execution: stage changes write a real receipt here (set in RootView wiring).
    weak var activity: ActivityLog?

    private struct Box: Codable { var clients: [Client]; var deals: [Deal] }
    private let url: URL
    private var loading = false
    /// Demo Mode: keep synthetic sample records in memory only, never on the buyer's disk.
    private var demoEphemeral = false

    init(filename: String = "crm.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sovereign", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(filename)
        load()
    }

    private func load() {
        loading = true; defer { loading = false }
        guard let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder().decode(Box.self, from: data) else { return }
        clients = box.clients
        deals = box.deals
    }
    private func save() {
        guard !loading, !demoEphemeral else { return }
        let box = Box(clients: clients, deals: deals)
        if let data = try? JSONEncoder().encode(box) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Clients (CRUD)
    func upsertClient(_ c: Client) {
        var c = c; c.updated = Date()
        if let i = clients.firstIndex(where: { $0.id == c.id }) { clients[i] = c }
        else { clients.insert(c, at: 0) }
    }
    /// Delete a client AND cascade-delete its deals so no orphan pipeline rows survive.
    func deleteClient(_ c: Client) {
        clients.removeAll { $0.id == c.id }
        deals.removeAll { $0.clientID == c.id }
    }
    func client(id: UUID) -> Client? { clients.first { $0.id == id } }

    // MARK: Deals (CRUD + stage movement)
    /// Insert or update a deal. A brand-new deal seeds its history with the opening stage so the
    /// pipeline trail is complete from creation.
    func upsertDeal(_ d: Deal) {
        var d = d; d.updated = Date()
        if d.history.isEmpty { d.history = [StageChange(from: nil, to: d.stage)] }
        if let i = deals.firstIndex(where: { $0.id == d.id }) { deals[i] = d }
        else { deals.insert(d, at: 0) }
    }
    func deleteDeal(_ d: Deal) { deals.removeAll { $0.id == d.id } }

    func deals(for clientID: UUID) -> [Deal] {
        deals.filter { $0.clientID == clientID }.sorted { $0.stage.order < $1.stage.order }
    }

    /// Move a deal to a new stage: append a real StageChange to its history and write an audit
    /// receipt into the proof-of-execution ledger. No-op when the stage is unchanged.
    func move(_ deal: Deal, to stage: DealStage, note: String = "") {
        guard let i = deals.firstIndex(where: { $0.id == deal.id }), deals[i].stage != stage else { return }
        let from = deals[i].stage
        deals[i].stage = stage
        deals[i].updated = Date()
        deals[i].history.append(StageChange(from: from, to: stage, note: note))
        let who = client(id: deals[i].clientID)?.displayName ?? "—"
        activity?.record(kind: .crm, title: "Deal moved · \(deals[i].displayTitle)",
                         detail: "\(who): \(from.label) → \(stage.label)" + (note.isEmpty ? "" : "\n\(note)"),
                         outcome: stage.isWon ? .success : .info)
    }

    // MARK: Honest counts
    var openDealCount: Int { deals.filter { $0.stage.isOpen }.count }
    var openPipelineValue: Double { deals.filter { $0.stage.isOpen }.reduce(0) { $0 + $1.value } }
    func count(in stage: DealStage) -> Int { deals.filter { $0.stage == stage }.count }

    // MARK: Retrieval — the "retrieves client history and deal pipeline" claim

    /// Instance grounding for a chat prompt: injects matched clients' history + pipeline.
    func grounding(for prompt: String) -> String { Self.grounding(clients: clients, deals: deals, for: prompt) }

    /// Agent-tool lookup: a client name/company → that client's history + pipeline; empty query →
    /// the whole pipeline summary. Returns honest empty text when nothing is stored / matched.
    func lookup(query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            guard !clients.isEmpty || !deals.isEmpty else { return "No clients or deals are saved yet." }
            return Self.pipelineReport(clients, deals: deals)
        }
        let matched = Self.match(clients, query: q)
        guard !matched.isEmpty else { return "No client matches \u{201C}\(q)\u{201D} in the user's records." }
        return matched.map { c in Self.clientReport(c, deals: deals.filter { $0.clientID == c.id }) }
            .joined(separator: "\n\n")
    }

    // MARK: Pure, nonisolated builders (unit-testable off the main actor)

    /// Find clients a free-text query references (name/org substring either direction, or a token
    /// match). 2-char floor mirrors the other searches. Pure → testable.
    nonisolated static func match(_ clients: [Client], query: String) -> [Client] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        return clients.filter { c in
            c.referenced(by: q)
            || c.trimmedName.range(of: q, options: .caseInsensitive) != nil
            || c.trimmedOrg.range(of: q, options: .caseInsensitive) != nil
        }
    }

    /// A full text report of ONE client: profile + their deal pipeline + most-recent stage change.
    /// `deals` should already be scoped to this client. Pure → testable.
    nonisolated static func clientReport(_ c: Client, deals: [Deal]) -> String {
        var lines: [String] = ["Client: \(c.displayName)"]
        var contact: [String] = []
        if !c.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { contact.append("email \(c.email.trimmingCharacters(in: .whitespacesAndNewlines))") }
        if !c.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { contact.append("phone \(c.phone.trimmingCharacters(in: .whitespacesAndNewlines))") }
        if !contact.isEmpty { lines.append("Contact: " + contact.joined(separator: ", ")) }
        let notes = c.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { lines.append("Notes: \(notes)") }
        let ds = deals.sorted { $0.stage.order < $1.stage.order }
        if ds.isEmpty {
            lines.append("Deals: none recorded.")
        } else {
            lines.append("Deal pipeline (\(ds.count)):")
            for d in ds {
                var parts = ["• \(d.displayTitle) — \(d.stage.label)"]
                if d.value > 0 { parts.append(formatValue(d.value)) }
                let na = d.nextAction.trimmingCharacters(in: .whitespacesAndNewlines)
                if !na.isEmpty { parts.append("next: \(na)") }
                lines.append(parts.joined(separator: " · "))
                if let last = d.history.last, let from = last.from {
                    lines.append("    stage history: \(from.label) → \(last.to.label) on \(shortDate(last.at))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A whole-pipeline summary grouped by stage with open + won totals. Pure → testable.
    nonisolated static func pipelineReport(_ clients: [Client], deals: [Deal]) -> String {
        guard !clients.isEmpty || !deals.isEmpty else { return "No clients or deals are saved yet." }
        var lines: [String] = []
        lines.append("Client pipeline summary — \(clients.count) client\(clients.count == 1 ? "" : "s"), \(deals.count) deal\(deals.count == 1 ? "" : "s").")
        let open = deals.filter { $0.stage.isOpen }
        let openValue = open.reduce(0) { $0 + $1.value }
        let wonValue = deals.filter { $0.stage.isWon }.reduce(0) { $0 + $1.value }
        lines.append("Open: \(open.count) deal\(open.count == 1 ? "" : "s") worth \(formatValue(openValue)) · Won: \(formatValue(wonValue)).")
        for stage in DealStage.allCases.sorted(by: { $0.order < $1.order }) {
            let inStage = deals.filter { $0.stage == stage }
            guard !inStage.isEmpty else { continue }
            lines.append("\(stage.label) (\(inStage.count)):")
            for d in inStage {
                let who = clients.first { $0.id == d.clientID }?.displayName ?? "—"
                var p = ["  • \(d.displayTitle) [\(who)]"]
                if d.value > 0 { p.append(formatValue(d.value)) }
                lines.append(p.joined(separator: " · "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Grounding block injected into a CHAT prompt when the buyer names a stored client — so ANY
    /// brain (even text-only on-device) can answer "what's the status of <client>?" from REAL
    /// records. Returns "" when the prompt references no stored client (never invents). Pure → testable.
    nonisolated static func grounding(clients: [Client], deals: [Deal], for prompt: String, max: Int = 3) -> String {
        let matched = clients.filter { $0.referenced(by: prompt) }.prefix(max)
        guard !matched.isEmpty else { return "" }
        let blocks = matched.map { c in clientReport(c, deals: deals.filter { $0.clientID == c.id }) }
        return "From the user's own client records (their CRM — real stored data; answer from it, never invent beyond it):\n\n" + blocks.joined(separator: "\n\n")
    }

    /// Locale-grouped value, "$1,500". Pure → testable.
    nonisolated static func formatValue(_ v: Double) -> String {
        let n = NumberFormatter(); n.numberStyle = .decimal; n.maximumFractionDigits = 0
        return "$" + (n.string(from: NSNumber(value: v)) ?? String(Int(v)))
    }
    nonisolated static func shortDate(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }

    // MARK: Demo Mode (synthetic SAMPLE records, in memory only)
    func seedDemo() {
        demoEphemeral = true   // ephemeral first → real records on disk untouched; restored by endDemo()
        let crm = DemoSeed.crm
        clients = crm.clients
        deals = crm.deals
    }
    func endDemo() {
        loading = true
        clients = []; deals = []
        load()
        loading = false
        demoEphemeral = false
    }

    /// Permanently erase ALL clients + deals — in memory and on disk (App Store Guideline 5.1.1(v)).
    func wipeAll() {
        demoEphemeral = false
        clients = []; deals = []
        save()
    }
}
#endif // circuit-convert
