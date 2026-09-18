// Black Label Marketing (lead engine, merged from Black Label Leads) — intelligence layer: lead scoring (fit + engagement), advanced boolean
// search (30+ filter predicate), saved searches with new-match detection, and account/ABM rollup.
//
// All pure, deterministic, on-device logic over the buyer's OWN saved leads. No network here,
// no fabricated data: every score and count is computed from real saved state. Starts empty.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Lead scoring (fit + engagement) — surfaces "hottest leads today"
//
// Fit  = how well the prospect matches an ideal-customer profile (completeness + deliverable
//        contact + targeted type/tags). Engagement = observed behavior signals from the real
//        activity ledger (sent / opened-proxy / replied / meeting / recency). Both 0–100.
// Honest: a brand-new prospect with no activity scores low on engagement (0), not a fake number.
struct LeadScore: Hashable {
    var fit: Int          // 0–100
    var engagement: Int   // 0–100
    /// Combined "heat" — weighted toward engagement (a warm reply outranks a perfect-fit cold lead).
    var total: Int { Int((Double(fit) * 0.45 + Double(engagement) * 0.55).rounded()) }
    var band: Band {
        switch total {
        case 75...: return .hot
        case 45..<75: return .warm
        default: return .cold
        }
    }
    enum Band: String { case hot = "Hot", warm = "Warm", cold = "Cold"
        var tint: Color { switch self { case .hot: return BLTheme.green; case .warm: return BLTheme.gold; case .cold: return BLTheme.sub } }
        var icon: String { switch self { case .hot: return "flame.fill"; case .warm: return "thermometer.medium"; case .cold: return "snowflake" } }
    }
}
#endif // circuit-convert

/// The buyer's ideal-customer profile — drives the FIT score. Fully customizable in Settings.
struct ICP: Codable, Hashable {
    /// Business types that count as a strong fit (empty = all types neutral).
    var targetTypes: Set<ProspectType> = []
    /// Tag keywords that boost fit (case-insensitive substring on a prospect's tags/notes).
    var boostTags: [String] = []
    /// Require a deliverable (non-role, syntactically valid) email for full fit credit.
    var requireEmail: Bool = true
    /// Require a phone for full fit credit (multichannel readiness).
    var valuePhone: Bool = true

    init() {}
    enum CodingKeys: String, CodingKey { case targetTypes, boostTags, requireEmail, valuePhone }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        targetTypes = Set((try? c.decode([ProspectType].self, forKey: .targetTypes)) ?? [])
        boostTags = (try? c.decode([String].self, forKey: .boostTags)) ?? []
        requireEmail = (try? c.decode(Bool.self, forKey: .requireEmail)) ?? true
        valuePhone = (try? c.decode(Bool.self, forKey: .valuePhone)) ?? true
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(Array(targetTypes), forKey: .targetTypes)
        try c.encode(boostTags, forKey: .boostTags)
        try c.encode(requireEmail, forKey: .requireEmail)
        try c.encode(valuePhone, forKey: .valuePhone)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum LeadScorer {
    /// FIT: profile-completeness + ICP match. Deterministic, 0–100.
    static func fit(_ p: Lead, icp: ICP) -> Int {
        var s = 0
        // Deliverable email (the single most important fit signal for an outbound tool).
        let emailDeliverable = !p.email.isEmpty && Deliverability.validSyntax(p.email) && !Deliverability.isRoleAddress(p.email)
        if emailDeliverable { s += 30 } else if !p.email.isEmpty { s += 12 }   // role/invalid email = partial
        if icp.requireEmail && p.email.isEmpty { s -= 5 }
        // Identity completeness.
        if !p.name.isEmpty { s += 12 }
        if !p.company.isEmpty { s += 10 }
        if !p.domain.isEmpty { s += 8 }
        // Multichannel readiness.
        if icp.valuePhone && !p.phone.isEmpty { s += 10 }
        if !p.address.isEmpty { s += 5 }
        // ICP type match.
        if icp.targetTypes.isEmpty {
            if p.type != .other { s += 8 }              // any chosen vertical beats "other"
        } else if icp.targetTypes.contains(p.type) {
            s += 18
        }
        // Tag boosts.
        let hay = (p.tags.joined(separator: " ") + " " + p.notes).lowercased()
        for t in icp.boostTags where !t.isEmpty && hay.contains(t.lowercased()) { s += 6 }
        return min(100, max(0, s))
    }

    /// ENGAGEMENT: real behavioral signals from the prospect's send/reply state + activity timeline.
    /// `activities` are this prospect's events (newest-first not required). 0–100, honest 0 for cold.
    static func engagement(_ p: Lead, activities: [Activity], now: Date = Date()) -> Int {
        var s = 0
        switch p.sendStatus {
        case .replied: s += 55           // a real reply is the strongest signal
        case .sent:    s += 18
        case .bounced: s -= 25           // bounced = bad contact, drags heat down
        case .notSent: break
        }
        switch p.status {
        case .won:     s += 20
        case .replied: s += 25
        case .contacted: s += 8
        case .dead:    s -= 30
        case .new:     break
        }
        // Distinct meaningful interactions logged (capped so a noisy log can't inflate).
        // NB: `.created` (logged automatically when a prospect is added) is deliberately NOT a
        // meaningful signal — a brand-new, untouched lead must score 0 engagement, never a fake number.
        let meaningfulKinds: Set<Activity.Kind> = [.email_sent, .email_replied, .email_bounced, .meeting_booked, .note, .task_done]
        let meaningful = activities.filter { meaningfulKinds.contains($0.kind) }
        s += min(20, meaningful.count * 5)
        // Recency: a REAL touch in the last 7 days keeps it warm; stale leads decay. Only meaningful
        // touches + actual sends count — the automatic creation timestamp does not.
        if let last = (meaningful.map { $0.at } + [p.lastSent].compactMap { $0 }).max() {
            let days = now.timeIntervalSince(last) / 86_400
            if days <= 7 { s += 10 } else if days <= 30 { s += 4 } else if days > 90 { s -= 8 }
        }
        return min(100, max(0, s))
    }

    static func score(_ p: Lead, icp: ICP, activities: [Activity], now: Date = Date()) -> LeadScore {
        LeadScore(fit: fit(p, icp: icp), engagement: engagement(p, activities: activities, now: now))
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Advanced boolean search (30+ filters) — the Sales-Navigator-class query
//
// A single Codable predicate the buyer composes in the UI and can SAVE. Evaluated locally over
// the prospect set + each prospect's live score. Every field is optional; an empty filter matches all.
struct LeadQuery: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String = ""                    // set when saved

    // Text
    var keyword: String = ""                 // free-text across name/company/email/domain/notes/tags
    var keywordMode: MatchMode = .any        // any / all / exact (phrase)
    var excludeKeyword: String = ""          // NOT terms (space/comma separated)
    var titleKeyword: String = ""            // matches the prospect name (contact title/name field)
    var companyKeyword: String = ""
    var domainKeyword: String = ""

    // Facets (sets — empty = no constraint)
    var types: Set<ProspectType> = []
    var statuses: Set<ProspectStatus> = []
    var sendStatuses: Set<SendStatus> = []
    var tagsAny: [String] = []               // has ANY of these tags
    var tagsAll: [String] = []               // has ALL of these tags
    var listID: UUID? = nil                  // member of a saved list
    var stageID: UUID? = nil                 // deal in this pipeline stage

    // Presence toggles (nil = don't care, true = must have, false = must NOT have)
    var hasEmail: Bool? = nil
    var hasPhone: Bool? = nil
    var hasDomain: Bool? = nil
    var hasAddress: Bool? = nil
    var deliverableEmail: Bool? = nil        // valid-syntax, non-role
    var roleEmail: Bool? = nil               // is/ isn't a role address
    var enrolled: Bool? = nil                // in an active sequence
    var inAnyList: Bool? = nil
    var hasOpenTask: Bool? = nil
    var hasDeal: Bool? = nil
    var replied: Bool? = nil
    var bounced: Bool? = nil

    // Ranges
    var minScore: Int? = nil                 // total heat ≥
    var maxScore: Int? = nil
    var minFit: Int? = nil
    var minEngagement: Int? = nil
    var scoreBands: Set<String> = []         // "Hot"/"Warm"/"Cold"
    var createdWithinDays: Int? = nil        // added in the last N days
    var notContactedDays: Int? = nil         // no send in the last N days (re-engagement)
    var minDealValue: Double? = nil
    var maxDealValue: Double? = nil
    var tagCountMin: Int? = nil

    // Sort
    var sort: SortKey = .score
    var ascending: Bool = false

    enum MatchMode: String, Codable, CaseIterable { case any = "Any word", all = "All words", exact = "Exact phrase" }
    enum SortKey: String, Codable, CaseIterable {
        case score = "Heat score", fit = "Fit", engagement = "Engagement", created = "Date added",
             name = "Name", company = "Company", lastContacted = "Last contacted", dealValue = "Deal value"
    }

    init(id: UUID = UUID(), name: String = "") { self.id = id; self.name = name }

    /// Count of active (non-default) constraints — shown as a chip count in the UI.
    var activeFilterCount: Int {
        var n = 0
        if !keyword.isEmpty { n += 1 }; if !excludeKeyword.isEmpty { n += 1 }
        if !titleKeyword.isEmpty { n += 1 }; if !companyKeyword.isEmpty { n += 1 }; if !domainKeyword.isEmpty { n += 1 }
        if !types.isEmpty { n += 1 }; if !statuses.isEmpty { n += 1 }; if !sendStatuses.isEmpty { n += 1 }
        if !tagsAny.isEmpty { n += 1 }; if !tagsAll.isEmpty { n += 1 }
        if listID != nil { n += 1 }; if stageID != nil { n += 1 }
        for b in [hasEmail, hasPhone, hasDomain, hasAddress, deliverableEmail, roleEmail, enrolled, inAnyList, hasOpenTask, hasDeal, replied, bounced] where b != nil { n += 1 }
        for r in [minScore, maxScore, minFit, minEngagement, createdWithinDays, notContactedDays, tagCountMin] where r != nil { n += 1 }
        if minDealValue != nil { n += 1 }; if maxDealValue != nil { n += 1 }
        if !scoreBands.isEmpty { n += 1 }
        return n
    }
    var isEmpty: Bool { activeFilterCount == 0 }

    // Resilient decode (new fields tolerate older saved JSON).
    enum CodingKeys: String, CodingKey {
        case id, name, keyword, keywordMode, excludeKeyword, titleKeyword, companyKeyword, domainKeyword
        case types, statuses, sendStatuses, tagsAny, tagsAll, listID, stageID
        case hasEmail, hasPhone, hasDomain, hasAddress, deliverableEmail, roleEmail, enrolled, inAnyList, hasOpenTask, hasDeal, replied, bounced
        case minScore, maxScore, minFit, minEngagement, scoreBands, createdWithinDays, notContactedDays, minDealValue, maxDealValue, tagCountMin
        case sort, ascending
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        keyword = (try? c.decode(String.self, forKey: .keyword)) ?? ""
        keywordMode = (try? c.decode(MatchMode.self, forKey: .keywordMode)) ?? .any
        excludeKeyword = (try? c.decode(String.self, forKey: .excludeKeyword)) ?? ""
        titleKeyword = (try? c.decode(String.self, forKey: .titleKeyword)) ?? ""
        companyKeyword = (try? c.decode(String.self, forKey: .companyKeyword)) ?? ""
        domainKeyword = (try? c.decode(String.self, forKey: .domainKeyword)) ?? ""
        types = Set((try? c.decode([ProspectType].self, forKey: .types)) ?? [])
        statuses = Set((try? c.decode([ProspectStatus].self, forKey: .statuses)) ?? [])
        sendStatuses = Set((try? c.decode([SendStatus].self, forKey: .sendStatuses)) ?? [])
        tagsAny = (try? c.decode([String].self, forKey: .tagsAny)) ?? []
        tagsAll = (try? c.decode([String].self, forKey: .tagsAll)) ?? []
        listID = try? c.decode(UUID.self, forKey: .listID)
        stageID = try? c.decode(UUID.self, forKey: .stageID)
        hasEmail = try? c.decode(Bool.self, forKey: .hasEmail)
        hasPhone = try? c.decode(Bool.self, forKey: .hasPhone)
        hasDomain = try? c.decode(Bool.self, forKey: .hasDomain)
        hasAddress = try? c.decode(Bool.self, forKey: .hasAddress)
        deliverableEmail = try? c.decode(Bool.self, forKey: .deliverableEmail)
        roleEmail = try? c.decode(Bool.self, forKey: .roleEmail)
        enrolled = try? c.decode(Bool.self, forKey: .enrolled)
        inAnyList = try? c.decode(Bool.self, forKey: .inAnyList)
        hasOpenTask = try? c.decode(Bool.self, forKey: .hasOpenTask)
        hasDeal = try? c.decode(Bool.self, forKey: .hasDeal)
        replied = try? c.decode(Bool.self, forKey: .replied)
        bounced = try? c.decode(Bool.self, forKey: .bounced)
        minScore = try? c.decode(Int.self, forKey: .minScore)
        maxScore = try? c.decode(Int.self, forKey: .maxScore)
        minFit = try? c.decode(Int.self, forKey: .minFit)
        minEngagement = try? c.decode(Int.self, forKey: .minEngagement)
        scoreBands = Set((try? c.decode([String].self, forKey: .scoreBands)) ?? [])
        createdWithinDays = try? c.decode(Int.self, forKey: .createdWithinDays)
        notContactedDays = try? c.decode(Int.self, forKey: .notContactedDays)
        minDealValue = try? c.decode(Double.self, forKey: .minDealValue)
        maxDealValue = try? c.decode(Double.self, forKey: .maxDealValue)
        tagCountMin = try? c.decode(Int.self, forKey: .tagCountMin)
        sort = (try? c.decode(SortKey.self, forKey: .sort)) ?? .score
        ascending = (try? c.decode(Bool.self, forKey: .ascending)) ?? false
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - a SAVED search with new-match alerting
struct SavedSearch: Codable, Hashable, Identifiable {
    var id = UUID()
    var query: LeadQuery
    var created = Date()
    /// Lead IDs that matched the last time the buyer viewed this search — the baseline for
    /// "new matches since you last looked." Grounded: a new match is a real prospect not seen before.
    var seenMatchIDs: Set<UUID> = []
    var lastViewed: Date? = nil
    var alertsOn: Bool = true

    var name: String { query.name.isEmpty ? "Untitled search" : query.name }
}
#endif // circuit-convert
