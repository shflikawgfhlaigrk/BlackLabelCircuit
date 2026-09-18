#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing (lead engine, merged from Black Label Leads) — intelligence operations on AppModel: evaluate a LeadQuery over saved
// leads, compute per-prospect scores, roll leads up into ACCOUNTS (ABM), and manage
// saved searches + new-match detection. Every value is a real count/derivation — never fabricated.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Account (ABM): leads grouped by company/domain into one buyer organization
struct Account: Identifiable, Hashable {
    var id: String                  // normalized domain, else lowercased company
    var name: String                // best display name (company)
    var domain: String
    var leads: [Lead]
    var fitScore: Int               // best fit among contacts (account-level fit)
    var engagementScore: Int        // best engagement among contacts
    var totalDealValue: Double
    var openDeals: Int
    var repliedCount: Int

    var contactCount: Int { leads.count }
    var heat: Int { Int((Double(fitScore) * 0.45 + Double(engagementScore) * 0.55).rounded()) }
    /// The likely decision-maker contact: highest-scoring named contact with a deliverable email.
    var primaryContact: Lead? {
        leads.sorted { lhs, rhs in
            let lDeliv = !lhs.email.isEmpty && !Deliverability.isRoleAddress(lhs.email)
            let rDeliv = !rhs.email.isEmpty && !Deliverability.isRoleAddress(rhs.email)
            if lDeliv != rDeliv { return lDeliv }
            if (!lhs.name.isEmpty) != (!rhs.name.isEmpty) { return !lhs.name.isEmpty }
            return lhs.created < rhs.created
        }.first
    }
}

extension AppModel {
    // MARK: - scoring (uses the buyer's ICP from settings; activities pulled from the live ledger)
    /// Score one prospect directly (uncached). Used by the cache builder and by callers that pass a
    /// custom `now`/activity set. O(activities) because of timeline(for:) — do NOT call per-render over
    /// the whole list; use `cachedScore` for that.
    func score(_ p: Lead, icp: ICP, now: Date = Date()) -> LeadScore {
        LeadScorer.score(p, icp: icp, activities: timeline(for: p.id), now: now)
    }

    /// Memoized score for `p` under the buyer's ICP. The whole-list score map is rebuilt at most once
    /// per (scoreEpoch, icp) change — turning the per-render scoring cliff into a single O(N + activities)
    /// pass that's reused across every render until the data changes. This is what keeps Prospects,
    /// Search, and Accounts responsive after a large Lead-Database import.
    func cachedScore(_ p: Lead, icp: ICP) -> LeadScore {
        rebuildScoreCacheIfStale(icp: icp)
        if let s = scoreCacheStore[p.id] { return s }
        // A prospect not in the map (e.g. a transient row): score it on the fly without polluting the
        // cache, so a stale id can't return a wrong score.
        return score(p, icp: icp)
    }

    /// Rebuild the score map iff the cache is stale for this (epoch, icp). One pass: bucket activities
    /// by prospectID once (O(activities)), then score each prospect against its own bucket (O(N)) —
    /// instead of N× a full O(activities) timeline scan.
    func rebuildScoreCacheIfStale(icp: ICP, now: Date = Date()) {
        guard scoreCacheEpoch != scoreEpoch || scoreCacheICP != icp else { return }
        var byProspect: [UUID: [Activity]] = [:]
        byProspect.reserveCapacity(leads.count)
        for a in activities { byProspect[a.prospectID, default: []].append(a) }
        var map: [UUID: LeadScore] = [:]
        map.reserveCapacity(leads.count)
        for p in leads {
            map[p.id] = LeadScorer.score(p, icp: icp, activities: byProspect[p.id] ?? [], now: now)
        }
        scoreCacheStore = map
        scoreCacheEpoch = scoreEpoch
        scoreCacheICP = icp
    }

    /// Hottest leads right now (real heat, descending), limited. Uses the memoized cache.
    func hottest(icp: ICP, limit: Int = 5, now: Date = Date()) -> [(Lead, LeadScore)] {
        rebuildScoreCacheIfStale(icp: icp, now: now)
        return leads.map { ($0, scoreCacheStore[$0.id] ?? score($0, icp: icp, now: now)) }
            .sorted { $0.1.total > $1.1.total }
            .prefix(limit).map { $0 }
    }

    // MARK: - query evaluation (the advanced-search engine)
    /// Returns leads matching the query, sorted per the query's sort key. `stages`/`settings`
    /// supply context (stage names, ICP) when the query references them.
    func evaluate(_ q: LeadQuery, icp: ICP, now: Date = Date()) -> [Lead] {
        // Use the model-wide memoized cache (rebuilt once per data change) rather than a fresh
        // per-call score map — so re-evaluating the same query on every body render is cheap.
        rebuildScoreCacheIfStale(icp: icp, now: now)
        func sc(_ p: Lead) -> LeadScore { scoreCacheStore[p.id] ?? score(p, icp: icp, now: now) }
        let matched = leads.filter { matches($0, q, score: sc($0), now: now) }
        return sort(matched, by: q, score: { sc($0) })
    }

    /// Does one prospect satisfy every active constraint in the query? (AND across fields.)
    func matches(_ p: Lead, _ q: LeadQuery, score s: LeadScore, now: Date = Date()) -> Bool {
        // --- text ---
        if !q.keyword.isEmpty {
            let hay = [p.name, p.company, p.email, p.domain, p.notes, p.phone, p.address, p.tags.joined(separator: " ")]
                .joined(separator: " ").lowercased()
            let terms = q.keyword.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter { !$0.isEmpty }
            switch q.keywordMode {
            case .any:   if !terms.isEmpty && !terms.contains(where: { hay.contains($0) }) { return false }
            case .all:   if !terms.allSatisfy({ hay.contains($0) }) { return false }
            case .exact: if !hay.contains(q.keyword.lowercased().trimmingCharacters(in: .whitespaces)) { return false }
            }
        }
        if !q.excludeKeyword.isEmpty {
            let hay = [p.name, p.company, p.email, p.domain, p.notes, p.tags.joined(separator: " ")].joined(separator: " ").lowercased()
            let nots = q.excludeKeyword.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter { !$0.isEmpty }
            if nots.contains(where: { hay.contains($0) }) { return false }
        }
        if !q.titleKeyword.isEmpty, !p.name.lowercased().contains(q.titleKeyword.lowercased()) { return false }
        if !q.companyKeyword.isEmpty, !p.company.lowercased().contains(q.companyKeyword.lowercased()) { return false }
        if !q.domainKeyword.isEmpty, !p.domain.lowercased().contains(q.domainKeyword.lowercased()) { return false }

        // --- facets ---
        if !q.types.isEmpty, !q.types.contains(p.type) { return false }
        if !q.statuses.isEmpty, !q.statuses.contains(p.status) { return false }
        if !q.sendStatuses.isEmpty, !q.sendStatuses.contains(p.sendStatus) { return false }
        if !q.tagsAny.isEmpty {
            let pt = Set(p.tags.map { $0.lowercased() })
            if !q.tagsAny.contains(where: { pt.contains($0.lowercased()) }) { return false }
        }
        if !q.tagsAll.isEmpty {
            let pt = Set(p.tags.map { $0.lowercased() })
            if !q.tagsAll.allSatisfy({ pt.contains($0.lowercased()) }) { return false }
        }
        if let lid = q.listID, !(lists.first { $0.id == lid }?.prospectIDs.contains(p.id) ?? false) { return false }
        if let sid = q.stageID, deal(for: p.id)?.stageID != sid { return false }

        // --- presence toggles ---
        func req(_ flag: Bool?, _ actual: Bool) -> Bool { flag == nil || flag == actual }
        if !req(q.hasEmail, !p.email.isEmpty) { return false }
        if !req(q.hasPhone, !p.phone.isEmpty) { return false }
        if !req(q.hasDomain, !p.domain.isEmpty) { return false }
        if !req(q.hasAddress, !p.address.isEmpty) { return false }
        let deliverable = !p.email.isEmpty && Deliverability.validSyntax(p.email) && !Deliverability.isRoleAddress(p.email)
        if !req(q.deliverableEmail, deliverable) { return false }
        if !req(q.roleEmail, !p.email.isEmpty && Deliverability.isRoleAddress(p.email)) { return false }
        if !req(q.enrolled, enrollment(for: p.id) != nil) { return false }
        if !req(q.inAnyList, lists.contains { $0.prospectIDs.contains(p.id) }) { return false }
        if !req(q.hasOpenTask, tasks.contains { $0.prospectID == p.id && !$0.done }) { return false }
        if !req(q.hasDeal, deal(for: p.id) != nil) { return false }
        if !req(q.replied, p.sendStatus == .replied) { return false }
        if !req(q.bounced, p.sendStatus == .bounced) { return false }

        // --- ranges ---
        if let mn = q.minScore, s.total < mn { return false }
        if let mx = q.maxScore, s.total > mx { return false }
        if let mn = q.minFit, s.fit < mn { return false }
        if let mn = q.minEngagement, s.engagement < mn { return false }
        if !q.scoreBands.isEmpty, !q.scoreBands.contains(s.band.rawValue) { return false }
        if let d = q.createdWithinDays {
            let cutoff = now.addingTimeInterval(-Double(d) * 86_400)
            if p.created < cutoff { return false }
        }
        if let d = q.notContactedDays {
            // matches leads NOT contacted in the last d days (never-sent counts as not-contacted)
            let cutoff = now.addingTimeInterval(-Double(d) * 86_400)
            if let last = p.lastSent, last >= cutoff { return false }
        }
        if let tcm = q.tagCountMin, p.tags.count < tcm { return false }
        if let mn = q.minDealValue, (deal(for: p.id)?.value ?? 0) < mn { return false }
        if let mx = q.maxDealValue, (deal(for: p.id)?.value ?? 0) > mx { return false }
        return true
    }

    private func sort(_ list: [Lead], by q: LeadQuery, score: (Lead) -> LeadScore) -> [Lead] {
        let asc = q.ascending
        func cmp<T: Comparable>(_ a: T, _ b: T) -> Bool { asc ? a < b : a > b }
        switch q.sort {
        case .score:        return list.sorted { cmp(score($0).total, score($1).total) }
        case .fit:          return list.sorted { cmp(score($0).fit, score($1).fit) }
        case .engagement:   return list.sorted { cmp(score($0).engagement, score($1).engagement) }
        case .created:      return list.sorted { cmp($0.created, $1.created) }
        case .name:         return list.sorted { cmp($0.displayName.lowercased(), $1.displayName.lowercased()) }
        case .company:      return list.sorted { cmp($0.company.lowercased(), $1.company.lowercased()) }
        case .lastContacted:return list.sorted { cmp($0.lastSent ?? .distantPast, $1.lastSent ?? .distantPast) }
        case .dealValue:    return list.sorted { cmp(deal(for: $0.id)?.value ?? 0, deal(for: $1.id)?.value ?? 0) }
        }
    }

    // MARK: - accounts (ABM rollup)
    /// Group leads into accounts by domain (preferred) or company name. Account scores are the
    /// BEST contact score (an org is as hot as its hottest known contact). Real, derived from saved data.
    func accounts(icp: ICP, now: Date = Date()) -> [Account] {
        rebuildScoreCacheIfStale(icp: icp, now: now)
        var buckets: [String: [Lead]] = [:]
        for p in leads {
            let key = !p.domain.isEmpty ? p.domain.lowercased()
                    : (!p.company.isEmpty ? p.company.lowercased() : "ungrouped:\(p.id)")
            buckets[key, default: []].append(p)
        }
        return buckets.map { (key, ps) -> Account in
            let name = ps.first { !$0.company.isEmpty }?.company ?? ps.first?.displayName ?? key
            let domain = ps.first { !$0.domain.isEmpty }?.domain ?? ""
            let scores = ps.map { scoreCacheStore[$0.id] ?? score($0, icp: icp, now: now) }
            let fit = scores.map { $0.fit }.max() ?? 0
            let eng = scores.map { $0.engagement }.max() ?? 0
            let dealVal = ps.reduce(0.0) { $0 + (deal(for: $1.id)?.value ?? 0) }
            let open = ps.filter { p in deal(for: p.id) != nil && p.status != .won && p.status != .dead }.count
            let replied = ps.filter { $0.sendStatus == .replied }.count
            return Account(id: key, name: name, domain: domain, leads: ps,
                           fitScore: fit, engagementScore: eng, totalDealValue: dealVal,
                           openDeals: open, repliedCount: replied)
        }.sorted { $0.heat > $1.heat }
    }

    // MARK: - bulk import from the live Lead Database
    /// Add many live LeadRecords to the CRM in ONE batched mutation, deduped against the store by
    /// email (preferred) then company. Mirrors the CSV importer's O(1)-dedup discipline so a 5,000-row
    /// bulk add stays a single coalesced save, not N synchronous full-store encodes. Returns count added.
    @discardableResult
    func bulkImportLeadRecords(_ records: [LeadRecord]) -> Int {
        guard !records.isEmpty else { return 0 }
        var seenEmails = Set(leads.compactMap { $0.email.isEmpty ? nil : $0.email.lowercased() })
        var seenCompanies = Set(leads.compactMap { $0.company.isEmpty ? nil : $0.company.lowercased() })
        var toAdd: [Lead] = []
        for r in records {
            let email = (r.email ?? "").trimmingCharacters(in: .whitespaces)
            let company = (r.name ?? "").trimmingCharacters(in: .whitespaces)
            // A masked/blurred preview email ("i•••@…") must never be imported as a real contact.
            let realEmail = email.contains("•") ? "" : email
            guard !realEmail.isEmpty || !company.isEmpty else { continue }
            let emailKey = realEmail.lowercased(), companyKey = company.lowercased()
            if (!emailKey.isEmpty && seenEmails.contains(emailKey)) ||
               (emailKey.isEmpty && !companyKey.isEmpty && seenCompanies.contains(companyKey)) { continue }
            if !emailKey.isEmpty { seenEmails.insert(emailKey) }
            if !companyKey.isEmpty { seenCompanies.insert(companyKey) }
            let domain = (r.website ?? "")
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "")
            let p = Lead(name: company, company: company, domain: EmailEngine.normalizeDomain(domain),
                             email: realEmail, type: .other,
                             tags: [r.category, r.deliv_tier].compactMap { $0 },
                             phone: (r.phone ?? "").contains("•") ? "" : (r.phone ?? ""),
                             address: [r.city, r.state].compactMap { $0 }.joined(separator: ", "))
            toAdd.append(p)
        }
        guard !toAdd.isEmpty else { return 0 }
        batch {
            leads.insert(contentsOf: toAdd, at: 0)
            for p in toAdd { log(p.id, .imported, "Imported from Lead Database") }
        }
        return toAdd.count
    }

    // MARK: - saved searches + new-match detection
    func saveSearch(_ q: LeadQuery, icp: ICP) {
        var query = q
        if query.name.isEmpty { query.name = "Search \(savedSearches.count + 1)" }
        let matchIDs = Set(evaluate(query, icp: icp).map { $0.id })
        let ss = SavedSearch(query: query, seenMatchIDs: matchIDs, lastViewed: Date())
        savedSearches.insert(ss, at: 0)
    }
    func deleteSavedSearch(_ id: UUID) { savedSearches.removeAll { $0.id == id } }
    /// New matches since the search was last viewed = current matches minus the baseline seen-set.
    func newMatches(for ss: SavedSearch, icp: ICP) -> [Lead] {
        let current = evaluate(ss.query, icp: icp)
        return current.filter { !ss.seenMatchIDs.contains($0.id) }
    }
    func newMatchCount(for ss: SavedSearch, icp: ICP) -> Int { newMatches(for: ss, icp: icp).count }
    /// Mark a saved search viewed — folds current matches into the baseline (clears the "new" badge).
    func markSearchViewed(_ id: UUID, icp: ICP) {
        guard let i = savedSearches.firstIndex(where: { $0.id == id }) else { return }
        savedSearches[i].seenMatchIDs = Set(evaluate(savedSearches[i].query, icp: icp).map { $0.id })
        savedSearches[i].lastViewed = Date()
    }
    /// Total new matches across all alert-enabled saved searches — drives the sidebar badge.
    func totalNewMatches(icp: ICP) -> Int {
        savedSearches.filter { $0.alertsOn }.reduce(0) { $0 + newMatchCount(for: $1, icp: icp) }
    }
}
#endif // circuit-convert
