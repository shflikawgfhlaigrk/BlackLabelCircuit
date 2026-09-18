#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing (lead engine, merged from Black Label Leads) — CRM operations + grounded analytics on AppModel.
// Deals/stages, tasks, activity timeline, lists, sequence enrollment + the daily-send ledger.
// Every metric here is a real count over saved data — never fabricated.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

extension AppModel {
    // MARK: - activity timeline
    func log(_ prospectID: UUID, _ kind: Activity.Kind, _ detail: String = "") {
        activities.insert(Activity(prospectID: prospectID, kind: kind, detail: detail), at: 0)
        if activities.count > 5000 { activities = Array(activities.prefix(5000)) }   // bound the on-device log
    }
    func timeline(for prospectID: UUID) -> [Activity] {
        activities.filter { $0.prospectID == prospectID }.sorted { $0.at > $1.at }
    }
    func prospect(_ id: UUID?) -> Lead? { id.flatMap { pid in leads.first { $0.id == pid } } }

    // MARK: - deals / pipeline (Kanban)
    func deal(for prospectID: UUID) -> Deal? { deals.first { $0.prospectID == prospectID } }
    func deals(in stageID: UUID) -> [Deal] {
        deals.filter { $0.stageID == stageID }.sorted { $0.sort < $1.sort }
    }
    /// Ensure a deal exists for a prospect (created in the first stage). Returns it.
    @discardableResult
    func ensureDeal(for p: Lead, stages: [DealStage]) -> Deal {
        if let d = deal(for: p.id) { return d }
        let first = stages.first?.id ?? UUID()
        let d = Deal(prospectID: p.id, title: p.displayName, stageID: first,
                     sort: (deals.map { $0.sort }.max() ?? 0) + 1)
        deals.append(d)
        return d
    }

    /// Give every prospect that lacks a deal one, in a SINGLE batched mutation.
    ///
    /// IMPORTANT: do NOT loop calling `ensureDeal` for this — `deals` has `didSet { save() }`,
    /// so a per-prospect append triggers one full-store JSON encode PER prospect. On a large
    /// pipeline that is O(n²) (n appends × full-store encode each) and pegs the main thread at
    /// 100% CPU for minutes — the app appears to hang/crash. Here we build all the missing deals
    /// first (O(1) membership via a Set, sort computed once) and append them in ONE mutation, so
    /// `save()` runs exactly once. Idempotent: a no-op (no save) when every prospect already has a deal.
    @discardableResult
    func backfillMissingDeals(stages: [DealStage]) -> Int {
        let haveDeal = Set(deals.map { $0.prospectID })
        let firstStage = stages.first?.id ?? UUID()
        var nextSort = (deals.map { $0.sort }.max() ?? 0) + 1
        var created: [Deal] = []
        for p in leads where !haveDeal.contains(p.id) {
            created.append(Deal(prospectID: p.id, title: p.displayName, stageID: firstStage, sort: nextSort))
            nextSort += 1
        }
        guard !created.isEmpty else { return 0 }   // nothing to do → no save churn
        deals.append(contentsOf: created)          // single didSet → single save()
        return created.count
    }
    func moveDeal(_ deal: Deal, to stageID: UUID, stages: [DealStage]) {
        guard let i = deals.firstIndex(where: { $0.id == deal.id }) else { return }
        let oldStage = stages.first { $0.id == deals[i].stageID }?.name ?? "?"
        let newStage = stages.first { $0.id == stageID }?.name ?? "?"
        deals[i].stageID = stageID
        deals[i].updated = Date()
        deals[i].sort = (deals(in: stageID).map { $0.sort }.max() ?? 0) + 1
        log(deals[i].prospectID, .stage_changed, "\(oldStage) → \(newStage)")
        // Reflect terminal stages onto the prospect status for a single source of truth.
        if let term = stages.first(where: { $0.id == stageID })?.terminal,
           let pi = leads.firstIndex(where: { $0.id == deals[i].prospectID }) {
            switch term {
            case .won:  leads[pi].status = .won
            case .lost: leads[pi].status = .dead
            case .open: break
            }
        }
    }
    func updateDeal(_ d: Deal) {
        if let i = deals.firstIndex(where: { $0.id == d.id }) { deals[i] = d; deals[i].updated = Date() }
    }
    /// Total value across all deals (open + closed). Real sum, never fabricated.
    var totalDealValue: Double { deals.reduce(0) { $0 + $1.value } }

    // MARK: - tasks
    func addTask(_ t: LeadTask) {
        tasks.insert(t, at: 0)
        if let pid = t.prospectID { log(pid, .task_added, t.title) }
    }
    func toggleTask(_ t: LeadTask) {
        guard let i = tasks.firstIndex(where: { $0.id == t.id }) else { return }
        tasks[i].done.toggle()
        if tasks[i].done, let pid = tasks[i].prospectID { log(pid, .task_done, tasks[i].title) }
    }
    func deleteTask(_ t: LeadTask) { tasks.removeAll { $0.id == t.id } }
    func tasks(for prospectID: UUID) -> [LeadTask] { tasks.filter { $0.prospectID == prospectID } }
    var openTasks: [LeadTask] { tasks.filter { !$0.done }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }
    var overdueCount: Int { tasks.filter { $0.overdue }.count }

    // MARK: - lists / segments
    func addList(_ name: String) { lists.append(LeadList(name: name)) }
    func add(_ prospectIDs: [UUID], to listID: UUID) {
        guard let i = lists.firstIndex(where: { $0.id == listID }) else { return }
        // Bulk path: collapse N per-append `lists` didSet → one coalesced save (no per-row re-render churn).
        batch {
            var seen = Set(lists[i].prospectIDs)
            for pid in prospectIDs where seen.insert(pid).inserted { lists[i].prospectIDs.append(pid) }
        }
    }
    func remove(_ prospectID: UUID, from listID: UUID) {
        guard let i = lists.firstIndex(where: { $0.id == listID }) else { return }
        lists[i].prospectIDs.removeAll { $0 == prospectID }
    }
    func deleteList(_ l: LeadList) { lists.removeAll { $0.id == l.id } }
    func leads(in list: LeadList) -> [Lead] {
        list.prospectIDs.compactMap { pid in leads.first { $0.id == pid } }
    }

    // MARK: - tags / bulk
    func addTag(_ tag: String, to prospectID: UUID) {
        guard let i = leads.firstIndex(where: { $0.id == prospectID }), !tag.isEmpty,
              !leads[i].tags.contains(tag) else { return }
        leads[i].tags.append(tag)
    }
    func removeTag(_ tag: String, from prospectID: UUID) {
        guard let i = leads.firstIndex(where: { $0.id == prospectID }) else { return }
        leads[i].tags.removeAll { $0 == tag }
    }
    var allTags: [String] { Array(Set(leads.flatMap { $0.tags })).sorted() }
    func bulkSetStatus(_ ids: Set<UUID>, _ status: ProspectStatus) {
        // Bulk path: each `leads[i].status =` + `log()` would fire two saves PER row; batch → one.
        batch {
            for i in leads.indices where ids.contains(leads[i].id) {
                if leads[i].status != status { leads[i].status = status; log(leads[i].id, .status_changed, status.label) }
            }
        }
    }
    func bulkDelete(_ ids: Set<UUID>) {
        // Bulk path: `delete()` mutates 7 @Published arrays per row; batch the whole sweep → one save.
        batch { for p in leads.filter({ ids.contains($0.id) }) { delete(p) } }
    }

    // MARK: - sequences / enrollment
    func upsertSequence(_ s: OutreachSequence) {
        if let i = sequences.firstIndex(where: { $0.id == s.id }) { sequences[i] = s } else { sequences.append(s) }
    }
    func deleteSequence(_ s: OutreachSequence) {
        sequences.removeAll { $0.id == s.id }
        enrollments.removeAll { $0.sequenceID == s.id }
    }
    func enrollment(for prospectID: UUID) -> Enrollment? {
        enrollments.first { $0.prospectID == prospectID && $0.status.isOpen }
    }
    func enroll(_ prospectIDs: [UUID], in sequence: OutreachSequence, mailboxID: UUID?) -> Int {
        var added = 0
        // Bulk path: collapse N per-append `enrollments` didSet → one coalesced save.
        batch {
            for pid in prospectIDs {
                guard enrollment(for: pid) == nil, sequence.active, !sequence.steps.isEmpty else { continue }
                let firstDelay = sequence.steps.first?.delayDays ?? 0
                let due = Calendar.current.date(byAdding: .day, value: firstDelay, to: Date()) ?? Date()
                enrollments.append(Enrollment(prospectID: pid, sequenceID: sequence.id, mailboxID: mailboxID, nextDue: due))
                added += 1
            }
        }
        return added
    }
    func unenroll(_ prospectID: UUID) {
        for i in enrollments.indices where enrollments[i].prospectID == prospectID && enrollments[i].status.isOpen {
            enrollments[i].status = .stopped_manual
        }
    }
    func sequence(_ id: UUID) -> OutreachSequence? { sequences.first { $0.id == id } }
    func activeEnrollments(of sequenceID: UUID) -> Int {
        enrollments.filter { $0.sequenceID == sequenceID && $0.status.isOpen }.count
    }

    // MARK: - call logging (click-to-call disposition → real activity)
    /// Record a placed/logged call. Writes a CallLog, logs a `.call_logged` activity, and advances the
    /// prospect status on a positive disposition (a connected call moves a new lead to contacted).
    func logCall(_ call: CallLog) {
        callLogs.insert(call, at: 0)
        if callLogs.count > 5000 { callLogs = Array(callLogs.prefix(5000)) }
        let detail = call.disposition.label + (call.durationSec > 0 ? " · \(call.durationSec)s" : "") + (call.notes.isEmpty ? "" : " · \(call.notes)")
        log(call.prospectID, .call_logged, detail)
        guard let i = leads.firstIndex(where: { $0.id == call.prospectID }) else { return }
        if call.disposition == .meetingBooked { log(call.prospectID, .meeting_booked, "via call") }
        if call.disposition.positive, leads[i].status == .new { leads[i].status = .contacted }
        if call.disposition == .wrongNumber { /* leave status; the buyer decides */ }
    }
    func calls(for prospectID: UUID) -> [CallLog] {
        callLogs.filter { $0.prospectID == prospectID }.sorted { $0.at > $1.at }
    }
    var callsTodayTotal: Int {
        let key = Self.dayKey(); return callLogs.filter { Self.dayKey($0.at) == key }.count
    }

    // MARK: - in-house pattern-GUESS lane (honest; NEVER writes the confirmed `email` field)
    /// Generate an in-house pattern guess for ONE lead that has a name + domain but no confirmed
    /// email. The guess is stored in the SEPARATE `guessedEmail` field (never in `email`), so it can
    /// never render as a verified address. Opt-in per lead (the buyer taps this on a single row) and
    /// logged as provenance. Returns true when a guess was written.
    @discardableResult
    func guessEmail(for id: UUID) -> Bool {
        guard let i = leads.firstIndex(where: { $0.id == id }) else { return false }
        guard leads[i].email.trimmingCharacters(in: .whitespaces).isEmpty else { return false } // never touch a real email
        guard let g = EmailGuessEngine.topGuess(name: leads[i].name, domain: leads[i].domain) else { return false }
        leads[i].guessedEmail = g.address
        leads[i].guessedEmailPattern = g.pattern
        log(id, .enriched, "Guessed \(g.address) (\(g.pattern)) — unverified pattern candidate, not a confirmed address")
        return true
    }
    /// Clear a lead's pattern guess (the buyer rejects it). Leaves the confirmed `email` untouched.
    func clearGuess(for id: UUID) {
        guard let i = leads.firstIndex(where: { $0.id == id }), !leads[i].guessedEmail.isEmpty else { return }
        let old = leads[i].guessedEmail
        leads[i].guessedEmail = ""; leads[i].guessedEmailPattern = ""
        log(id, .enriched, "Cleared email guess \(old)")
    }
    /// Record a bulk-verification verdict on the timeline (no field change — informational).
    func recordVerification(_ r: VerificationResult) {
        log(r.id, .verified, "\(r.verdict.label): \(r.note)")
    }

    // MARK: - MK-17 buyer-key WATERFALL enrichment (chained providers, locally cached, no PII egress)
    /// Run the buyer's ORDERED provider chain for ONE lead until the first confirmed hit. Cache-first:
    /// a prior run for this exact name+domain returns instantly with ZERO network. A confirmed hit lands
    /// in the CONFIRMED `email` lane (via EnrichmentProviderClient.attach) — never the guessed lane; an
    /// exhausted chain invents nothing. Keys are read from the Keychain per vendor; a lead's PII is only
    /// ever sent to the buyer's own provider host (the find() host invariant enforces this).
    @discardableResult
    func enrichWaterfall(for id: UUID, chain: [EnrichmentVendor],
                         send: @escaping EnrichmentProviderClient.Send = EnrichmentProviderClient.liveSend) async -> WaterfallResult {
        guard let lead = leads.first(where: { $0.id == id }) else { return WaterfallResult() }
        // Instant + free re-run: serve an unchanged lead straight from the local cache, no provider call.
        if let hit = EnrichmentWaterfall.cached(lead.enrichmentCache, name: lead.name, domain: lead.domain) {
            return hit
        }
        let result = await EnrichmentWaterfall.run(name: lead.name, domain: lead.domain, chain: chain,
                                                   keyFor: { EnrichmentKeychain.get($0) }, send: send)
        await MainActor.run { self.cacheEnrichment(result, to: id) }
        return result
    }

    /// Persist a completed waterfall run on the lead (the local cache) and, on a confirmed hit, fill the
    /// blank `email` with an on-device provenance note. Synchronous, main-actor mutation. Renders no
    /// fabricated field — a miss only writes the honest audit record.
    func cacheEnrichment(_ result: WaterfallResult, to id: UUID) {
        guard let i = leads.firstIndex(where: { $0.id == id }) else { return }
        leads[i].enrichmentCache = EnrichmentWaterfall.cacheEntry(name: leads[i].name, domain: leads[i].domain, result: result)
        if result.isHit {
            let er = EnrichmentResult(email: result.email, confidence: result.confidence, vendorLabel: result.winner?.label ?? "")
            let (updated, filled) = EnrichmentProviderClient.attach(er, to: leads[i])
            if filled {
                leads[i] = updated
                log(id, .enriched, "Waterfall hit via \(result.winner?.label ?? "your provider") — confirmed email attached (stored locally only).")
            }
        } else {
            log(id, .enriched, "Waterfall ran \(result.ranCount) provider(s), no confirmed email found. Nothing was invented.")
        }
    }

    /// Per-provider yield over the buyer's REAL cached results (never estimated) — how many confirmed
    /// hits each vendor won across every enriched lead. Powers the honest per-provider yield panel.
    var enrichmentProviderYield: [(vendor: String, hits: Int)] {
        EnrichmentWaterfall.providerYield(leads.compactMap { $0.enrichmentCache })
    }

    // MARK: - daily send ledger (real warmup pacing)
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func dayKey(_ d: Date = Date()) -> String { dayFmt.string(from: d) }
    func sentToday(mailboxID: UUID) -> Int {
        let key = Self.dayKey()
        return sendDays.first { $0.mailboxID == mailboxID && $0.day == key }?.count ?? 0
    }
    func recordSend(mailboxID: UUID, at: Date = Date()) {
        let key = Self.dayKey(at)
        if let i = sendDays.firstIndex(where: { $0.mailboxID == mailboxID && $0.day == key }) {
            sendDays[i].count += 1
            sendDays[i].lastSentAt = at
        } else {
            sendDays.append(SendDay(mailboxID: mailboxID, day: key, count: 1, lastSentAt: at))
        }
    }
    func lastSentAt(mailboxID: UUID) -> Date? {
        sendDays.filter { $0.mailboxID == mailboxID }.compactMap(\.lastSentAt).max()
    }
    var sentTodayTotal: Int {
        let key = Self.dayKey(); return sendDays.filter { $0.day == key }.reduce(0) { $0 + $1.count }
    }
}

// MARK: - grounded analytics (real counts only, never fabricated)
struct CampaignMetrics {
    var sequenceName: String
    var enrolled: Int
    var sent: Int
    var replied: Int
    var bounced: Int
    var active: Int
    var completed: Int
    var replyRate: Double { sent > 0 ? Double(replied) / Double(sent) * 100 : 0 }
    var bounceRate: Double { sent > 0 ? Double(bounced) / Double(sent) * 100 : 0 }
}

extension AppModel {
    /// Per-sequence campaign metrics, computed live from enrollment send logs + prospect reply state.
    func metrics(for sequence: OutreachSequence) -> CampaignMetrics {
        let enr = enrollments.filter { $0.sequenceID == sequence.id }
        let sent = enr.reduce(0) { $0 + $1.sends.filter { $0.sent }.count }
        let replied = enr.filter { $0.status == .stopped_reply }.count
        let bounced = enr.filter { $0.status == .stopped_bounce }.count
        let active = enr.filter { $0.status.isOpen }.count
        let completed = enr.filter { $0.status == .completed }.count
        return CampaignMetrics(sequenceName: sequence.name, enrolled: enr.count,
                               sent: sent, replied: replied, bounced: bounced, active: active, completed: completed)
    }
    /// Overall deliverability health from the real send ledger over the last `days`.
    func deliverabilitySummary(days: Int = 7) -> (sent: Int, replied: Int, bounced: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        var sent = 0
        for e in enrollments { sent += e.sends.filter { $0.sent && $0.at >= cutoff }.count }
        // manual ledger sends counted via prospect.lastSent
        sent += leads.filter { ($0.lastSent ?? .distantPast) >= cutoff && $0.sendStatus != .notSent }.count
        let replied = leads.filter { $0.sendStatus == .replied }.count
        let bounced = leads.filter { $0.sendStatus == .bounced }.count
        return (sent, replied, bounced)
    }
}

// MARK: - Lead CRUD + send ledger + funnel rollups (ported from the Leads app's AppModel core)
extension AppModel {
    // Prospects CRUD
    func upsert(_ p: Lead) {
        if let i = leads.firstIndex(where: { $0.id == p.id }) { leads[i] = p }
        else { leads.insert(p, at: 0); log(p.id, .created, "Added \(p.displayName)") }
    }
    func delete(_ p: Lead) {
        leads.removeAll { $0.id == p.id }
        deals.removeAll { $0.prospectID == p.id }
        tasks.removeAll { $0.prospectID == p.id }
        activities.removeAll { $0.prospectID == p.id }
        enrollments.removeAll { $0.prospectID == p.id }
        callLogs.removeAll { $0.prospectID == p.id }
        for i in lists.indices { lists[i].prospectIDs.removeAll { $0 == p.id } }
    }
    func deleteAll() {
        leads.removeAll(); deals.removeAll(); tasks.removeAll(); activities.removeAll()
        lists.removeAll(); enrollments.removeAll(); sendDays.removeAll()
        savedSearches.removeAll(); inbox.removeAll(); callLogs.removeAll()
        // sequences are templates (buyer config), keep them
    }

    // Outreach send ledger (website: "logs every send", reply/bounce). Honest manual on-device logging.
    func mark(_ p: Lead, send: SendStatus) {
        guard let i = leads.firstIndex(where: { $0.id == p.id }) else { return }
        var updated = leads[i]
        updated.sendStatus = send
        switch send {
        case .sent:
            updated.lastSent = Date()
            if updated.status == .new { updated.status = .contacted }
            log(p.id, .email_sent, "Marked sent")
        case .replied:
            if updated.status == .new || updated.status == .contacted { updated.status = .replied }
            log(p.id, .email_replied, "Reply logged")
        case .bounced:
            updated.status = .dead
            log(p.id, .email_bounced, "Bounce logged")
        case .notSent:
            break
        }
        leads[i] = updated
    }

    // Rollups (real, computed from saved data)
    func count(_ s: ProspectStatus) -> Int { leads.filter { $0.status == s }.count }
    func sendCount(_ s: SendStatus) -> Int { leads.filter { $0.sendStatus == s }.count }
    var withEmail: Int { leads.filter { !$0.email.isEmpty }.count }
    var withDraft: Int { leads.filter { !$0.draft.isEmpty }.count }
    // Counted pipeline (website: "counted pipeline, not another empty CRM").
    var sentTotal: Int { leads.filter { $0.sendStatus != .notSent }.count }
    var replyRate: Double {
        let delivered = leads.filter { $0.sendStatus == .sent || $0.sendStatus == .replied }.count
        guard delivered > 0 else { return 0 }
        return Double(sendCount(.replied)) / Double(delivered) * 100
    }
    var bounceRate: Double {
        guard sentTotal > 0 else { return 0 }
        return Double(sendCount(.bounced)) / Double(sentTotal) * 100
    }
    var winRate: Double {
        let closeable = leads.filter { $0.status == .won || $0.status == .dead }.count
        guard closeable > 0 else { return 0 }
        return Double(count(.won)) / Double(closeable) * 100
    }
}
#endif // circuit-convert
