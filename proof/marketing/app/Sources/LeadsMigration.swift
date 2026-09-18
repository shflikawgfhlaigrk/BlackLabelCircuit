// Black Label Marketing — one-shot migration importer from the retired Black Label Leads app.
//
// Black Label Leads folded into Marketing (2026-07). A buyer who used the standalone Leads app
// has a data container at ~/Library/Application Support/BlackLabelLeads/. On first launch of the
// merged app we import it ONCE (idempotent, guarded by a UserDefaults flag): the CRM pool,
// pipeline, sequences, inbox, and RBAC team, plus the sending/targeting settings and the Lead
// Database access token. SMTP app-passwords migrate transparently via SendKeychain's legacy-read.
//
// On-wire compatibility: the Leads app encoded Prospect, Deal, Sequence, etc. with the same field
// names the merged domain uses (that was deliberate in the merge), so the Leads blobs decode
// directly into the unified types — a decode, not a hand-written field map.
//
// Sandbox note: the shipped/updatable build is Developer-ID + NON-sandboxed (see marketing.toml),
// so it can read the sibling container directly. A sandboxed App Store build can't; there the
// buyer imports a Leads workspace-backup file via the normal import picker instead.
import Foundation

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// A Codable mirror of the Leads app's persisted appData "Box" — every collection decodes into
/// the merged domain's types. Missing keys tolerate older Leads data.
private struct LeadsAppDataBox: Codable {
    var prospects: [Lead] = []
    var deals: [Deal] = []
    var tasks: [LeadTask] = []
    var activities: [Activity] = []
    var lists: [LeadList] = []
    var sequences: [OutreachSequence] = []
    var enrollments: [Enrollment] = []
    var sendDays: [SendDay] = []
    var savedSearches: [SavedSearch] = []
    var inbox: [InboxMessage] = []
    var callLogs: [CallLog] = []
    var workflows: [WorkflowRule] = []

    enum CodingKeys: String, CodingKey {
        case prospects, deals, tasks, activities, lists, sequences, enrollments, sendDays, savedSearches, inbox, callLogs, workflows
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        prospects = (try? c.decode([Lead].self, forKey: .prospects)) ?? []
        deals = (try? c.decode([Deal].self, forKey: .deals)) ?? []
        tasks = (try? c.decode([LeadTask].self, forKey: .tasks)) ?? []
        activities = (try? c.decode([Activity].self, forKey: .activities)) ?? []
        lists = (try? c.decode([LeadList].self, forKey: .lists)) ?? []
        sequences = (try? c.decode([OutreachSequence].self, forKey: .sequences)) ?? []
        enrollments = (try? c.decode([Enrollment].self, forKey: .enrollments)) ?? []
        sendDays = (try? c.decode([SendDay].self, forKey: .sendDays)) ?? []
        savedSearches = (try? c.decode([SavedSearch].self, forKey: .savedSearches)) ?? []
        inbox = (try? c.decode([InboxMessage].self, forKey: .inbox)) ?? []
        callLogs = (try? c.decode([CallLog].self, forKey: .callLogs)) ?? []
        workflows = (try? c.decode([WorkflowRule].self, forKey: .workflows)) ?? []
    }
    var isEmpty: Bool {
        prospects.isEmpty && deals.isEmpty && tasks.isEmpty && activities.isEmpty && lists.isEmpty
            && sequences.isEmpty && enrollments.isEmpty && inbox.isEmpty && callLogs.isEmpty && workflows.isEmpty
    }
}
#endif // circuit-convert

struct LeadsMigrationReport {
    var ran = false
    var leads = 0, deals = 0, sequences = 0, enrollments = 0, inbox = 0
    var importedSettings = false, importedTeam = false, importedDBToken = false
    var summary: String {
        guard ran else { return "No Black Label Leads data to import." }
        var parts = ["Imported \(leads) lead\(leads == 1 ? "" : "s")"]
        if deals > 0 { parts.append("\(deals) deals") }
        if sequences > 0 { parts.append("\(sequences) sequences") }
        if inbox > 0 { parts.append("\(inbox) inbox messages") }
        if importedSettings { parts.append("sending settings") }
        if importedTeam { parts.append("team") }
        if importedDBToken { parts.append("Lead Database key") }
        return "Migrated from Black Label Leads: " + parts.joined(separator: ", ") + "."
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
enum LeadsMigration {
    private static let doneFlag = "com.blacklabel.marketing.leadsMigrationDone.v1"

    /// The retired Leads app's Application Support container.
    private static var leadsContainerURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabelLeads", isDirectory: true)
    }

    /// True if there is anything to migrate and we haven't already done it.
    static var isPending: Bool {
        guard !UserDefaults.standard.bool(forKey: doneFlag) else { return false }
        guard let base = leadsContainerURL else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: base.appendingPathComponent("workspace.sqlite3").path)
            || fm.fileExists(atPath: base.appendingPathComponent("data.json").path)
    }

    /// Import once. Safe to call every launch — it no-ops after the first successful run (and marks
    /// done even when there was nothing to import, so a fresh buyer never pays the check twice).
    /// Merged data is APPENDED (deduped by id) so a buyer who already added leads keeps them.
    @discardableResult
    static func runIfNeeded(model: AppModel, leadEngine: LeadEngineStore, team: TeamStore, demoMode: Bool) -> LeadsMigrationReport {
        var report = LeadsMigrationReport()
        // Never migrate into a demo/guest session — that store is synthetic and in-memory.
        guard !demoMode, isPending, let base = leadsContainerURL else {
            if !demoMode { UserDefaults.standard.set(true, forKey: doneFlag) }
            return report
        }

        let box = loadAppData(base)
        if let box, !box.isEmpty {
            model.batch {
                mergeByID(&model.leads, box.prospects)
                mergeByID(&model.deals, box.deals)
                mergeByID(&model.tasks, box.tasks)
                mergeByID(&model.activities, box.activities)
                mergeByID(&model.lists, box.lists)
                mergeByID(&model.sequences, box.sequences)
                mergeByID(&model.enrollments, box.enrollments)
                mergeByID(&model.savedSearches, box.savedSearches)
                mergeByID(&model.workflowRules, box.workflows)
                mergeInbox(&model.inbox, box.inbox)
                model.sendDays.append(contentsOf: box.sendDays)   // additive daily counters
            }
            report.ran = true
            report.leads = box.prospects.count; report.deals = box.deals.count
            report.sequences = box.sequences.count; report.enrollments = box.enrollments.count
            report.inbox = box.inbox.count
        }

        // Sending / targeting settings (decode straight into LeadEngineSettings; appearance keys ignored).
        if let data = readBlob(base, "settings") ?? readJSON(base, "settings.json"),
           let s = try? JSONDecoder().decode(LeadEngineSettings.self, from: data) {
            leadEngine.settings = s
            report.importedSettings = true
            report.ran = true
        }

        // RBAC team.
        if let data = readBlob(base, "workspace") ?? readJSON(base, "workspace.json"),
           let ws = try? JSONDecoder().decode(Workspace.self, from: data), !ws.members.isEmpty {
            team.workspace = ws
            report.importedTeam = true
            report.ran = true
        }

        // Lead Database access token lived in the Leads app's OWN UserDefaults domain; carry it
        // over so the buyer's subscriber export/API keeps working without re-entry.
        // The retired app's copy is read from ITS OWN defaults domain (unavoidable — that is
        // where it lives); the imported value is written to OUR Keychain, never back into a plist.
        if let tok = LeadsTokenMigration.tokenToImport(
            current: LeadDBCredential.token,
            legacy: LeadsTokenMigration.legacyToken(tokenKey: LeadDB.tokenKey)) {
            LeadDBCredential.save(tok)
            report.importedDBToken = true
            report.ran = true
        }

        UserDefaults.standard.set(true, forKey: doneFlag)
        return report
    }

    // MARK: - reads

    private static func loadAppData(_ base: URL) -> LeadsAppDataBox? {
        if let data = readBlob(base, "appData"), let box = try? JSONDecoder().decode(LeadsAppDataBox.self, from: data) {
            return box
        }
        if let data = readJSON(base, "data.json"), let box = try? JSONDecoder().decode(LeadsAppDataBox.self, from: data) {
            return box
        }
        return nil
    }

    /// Read a named blob from the Leads app's SQLite workspace store (reuses WorkspaceDatabase,
    /// which is a generic name→payload store, pointed at the sibling app's file).
    private static func readBlob(_ base: URL, _ name: String) -> Data? {
        let url = base.appendingPathComponent("workspace.sqlite3")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? WorkspaceDatabase(url: url).readBlob(named: name).flatMap { $0.isEmpty ? nil : $0 }
    }
    private static func readJSON(_ base: URL, _ file: String) -> Data? {
        try? Data(contentsOf: base.appendingPathComponent(file))
    }

    // MARK: - merges (append, dedupe by id — never clobber the buyer's existing rows)

    private static func mergeByID<T: Identifiable>(_ dst: inout [T], _ src: [T]) where T.ID == UUID {
        let existing = Set(dst.map(\.id))
        dst.append(contentsOf: src.filter { !existing.contains($0.id) })
    }
    private static func mergeInbox(_ dst: inout [InboxMessage], _ src: [InboxMessage]) {
        let existing = Set(dst.map(\.id))   // InboxMessage.id is a String ("<folder>:<uid>")
        dst.append(contentsOf: src.filter { !existing.contains($0.id) })
    }
}
#endif // circuit-convert
