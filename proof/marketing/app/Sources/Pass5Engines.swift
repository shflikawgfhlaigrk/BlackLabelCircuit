// Black Label Marketing — PASS 5 engines (tier-3/4/5, all pure, all on the buyer's OWN data).
//
// Mirrored 1:1 by Tests/Pass5Tests.swift (re-runnable: `swift Tests/Pass5Tests.swift`).
// ZERO FABRICATION: every metric is a sum/ratio of OPERATOR-LOGGED values; an unknown
// is an honest empty state, never an invented number, audience, or result.
//
// Adds:
//   • Multichannel campaign object  (tier 3) — one campaign spanning email/social/ads/landing
//     with a shared window + a rollup of the buyer's own logged per-channel metrics.
//   • ABM playbook builder          (tier 3) — target accounts -> deterministic tier/priority
//     from entered firmographics + a per-account multichannel play.
//   • Lookalike modeling            (tier 3) — rank the buyer's own contacts by similarity to a
//     SEED set they choose (segment / hand-picked). Empty seed -> no audience.
//   • Referral-program builder      (tier 3) — reward rules + exact math on logged referrals.
//   • Strategy / roadmap planner    (tier 3) — quarter board with ICE leverage ordering.
//   • AEO AI-citation checker       (tier 4) — literal scan of an AI answer the buyer pastes
//     (or a fetched page) for brand/fact mentions. Never claims an AI "would" cite.
//   • Security audit log            (tier 4) — append-only, SHA-256 hash-chained, tamper-evident.
//   • AI Creative Ideation Engine   (tier 5 flagship) — on-device FoundationModels behind an
//     @available guard (no paid dep); honest deterministic fallback otherwise (Pass5AI, separate file).
import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif

// ============================================================================
// MARK: - Multichannel campaign object (tier 3)
// ============================================================================

enum MChannelKind: String, CaseIterable, Codable, Identifiable {
    case email = "Email", social = "Social", ads = "Ads", landing = "Landing page"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .email: return "envelope.fill"; case .social: return "person.2.fill"
        case .ads: return "megaphone.fill"; case .landing: return "globe"
        }
    }
}

/// One channel lane inside a multichannel campaign. Metrics are OPERATOR-LOGGED
/// (what the buyer saw in that channel's own dashboard) — never auto-pulled/invented.
struct MChannelEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: MChannelKind = .email
    var assetRef: String = ""          // free label: which post/site/ad this lane uses
    var planned: Int = 0               // planned units (posts/sends/ad sets) the buyer set
    var loggedReach: Int = 0
    var loggedClicks: Int = 0
    var loggedConversions: Int = 0
    var spend: Double = 0
    var note: String = ""
}

/// A campaign spanning multiple channels on a shared calendar window.
struct MCampaign: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var objective: String = "Awareness"
    var start: Date = Date()
    var end: Date = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    var entries: [MChannelEntry] = []
    var created = Date()
}

enum MCampaignEngine {
    static func reach(_ c: MCampaign) -> Int { c.entries.reduce(0) { $0 + max(0, $1.loggedReach) } }
    static func clicks(_ c: MCampaign) -> Int { c.entries.reduce(0) { $0 + max(0, $1.loggedClicks) } }
    static func conversions(_ c: MCampaign) -> Int { c.entries.reduce(0) { $0 + max(0, $1.loggedConversions) } }
    static func spend(_ c: MCampaign) -> Double { c.entries.reduce(0) { $0 + max(0, $1.spend) } }
    /// CTR over logged reach (nil when no reach — no fabrication).
    static func ctr(_ c: MCampaign) -> Double? { let r = reach(c); return r > 0 ? Double(clicks(c)) / Double(r) : nil }
    /// Cost per acquisition (nil when nothing converted/spent).
    static func cpa(_ c: MCampaign) -> Double? { let cv = conversions(c); let s = spend(c); return (cv > 0 && s > 0) ? s / Double(cv) : nil }
    static func status(_ c: MCampaign, now: Date = Date()) -> String {
        if now < c.start { return "Scheduled" }
        if now > c.end { return "Completed" }
        return "Live"
    }
    static func progress(_ c: MCampaign, now: Date = Date()) -> Double {
        let total = c.end.timeIntervalSince(c.start)
        guard total > 0 else { return now >= c.end ? 1 : 0 }
        return min(1, max(0, now.timeIntervalSince(c.start) / total))
    }
    static func hasAnyData(_ c: MCampaign) -> Bool { reach(c) > 0 || clicks(c) > 0 || conversions(c) > 0 || spend(c) > 0 }
}

// ============================================================================
// MARK: - ABM playbook builder (tier 3)
// ============================================================================

enum ABMTier: String, Codable { case strategic = "Strategic", target = "Target", nurture = "Nurture", unscored = "Unscored"
    var color: String { switch self { case .strategic: return "gold"; case .target: return "green"; case .nurture: return "blue"; case .unscored: return "gray" } }
}

/// A per-account multichannel play step (what to do, on which channel, in which week).
struct ABMPlayStep: Identifiable, Codable, Hashable {
    var id = UUID()
    var week: Int = 1
    var channel: MChannelKind = .email
    var action: String = ""
    var done: Bool = false
}

/// A target account in the ABM program. Firmographics are ENTERED by the buyer
/// (no enrichment vendor) — a blank account scores 0 (never an invented fit).
struct ABMAccount: Identifiable, Codable, Hashable {
    var id = UUID()
    var company: String = ""
    var website: String = ""
    var employees: Int = 0
    var revenueM: Double = 0           // $M annual revenue (entered)
    var industryFit: Int = 0           // 0..3 buyer-judged fit
    var contactsLinked: Int = 0        // contacts in their CRM tied to this account
    var hasChampion: Bool = false
    var notes: String = ""
    var plays: [ABMPlayStep] = []
    var created = Date()
}

enum ABMEngine {
    /// Deterministic priority 0..100 from ENTERED firmographics only. No data -> 0.
    static func priority(_ a: ABMAccount) -> Int {
        var s = 0
        if a.employees >= 1000 { s += 25 } else if a.employees >= 200 { s += 18 } else if a.employees >= 50 { s += 10 } else if a.employees > 0 { s += 4 }
        if a.revenueM >= 100 { s += 25 } else if a.revenueM >= 10 { s += 16 } else if a.revenueM >= 1 { s += 8 } else if a.revenueM > 0 { s += 3 }
        s += a.industryFit * 8
        if a.contactsLinked > 0 { s += min(15, a.contactsLinked * 3) }
        if a.hasChampion { s += 11 }
        return min(100, max(0, s))
    }
    static func tier(_ a: ABMAccount) -> ABMTier {
        if a.employees == 0 && a.revenueM == 0 && a.industryFit == 0 && a.contactsLinked == 0 && !a.hasChampion { return .unscored }
        switch priority(a) {
        case 70...: return .strategic
        case 40..<70: return .target
        default: return .nurture
        }
    }
    /// Reasons behind a priority (full transparency).
    static func reasons(_ a: ABMAccount) -> [(String, Int)] {
        var r: [(String, Int)] = []
        if a.employees >= 1000 { r.append(("1000+ employees", 25)) } else if a.employees >= 200 { r.append(("200+ employees", 18)) } else if a.employees >= 50 { r.append(("50+ employees", 10)) } else if a.employees > 0 { r.append(("Small team", 4)) }
        if a.revenueM >= 100 { r.append(("$100M+ revenue", 25)) } else if a.revenueM >= 10 { r.append(("$10M+ revenue", 16)) } else if a.revenueM >= 1 { r.append(("$1M+ revenue", 8)) } else if a.revenueM > 0 { r.append(("Has revenue", 3)) }
        if a.industryFit > 0 { r.append(("Industry fit \(a.industryFit)/3", a.industryFit * 8)) }
        if a.contactsLinked > 0 { r.append(("\(a.contactsLinked) linked contact\(a.contactsLinked == 1 ? "" : "s")", min(15, a.contactsLinked * 3))) }
        if a.hasChampion { r.append(("Has an internal champion", 11)) }
        return r
    }
    /// A starter 4-week multichannel play the buyer can edit (no fabricated results).
    static func starterPlays() -> [ABMPlayStep] {
        [ABMPlayStep(week: 1, channel: .landing, action: "Personalized landing page for the account"),
         ABMPlayStep(week: 1, channel: .email, action: "Intro email to the champion"),
         ABMPlayStep(week: 2, channel: .social, action: "Engage their decision-makers on social"),
         ABMPlayStep(week: 3, channel: .ads,    action: "Account-targeted retargeting ads"),
         ABMPlayStep(week: 4, channel: .email,  action: "Case-study follow-up + meeting ask")]
    }
}

// ============================================================================
// MARK: - Lookalike modeling (tier 3, on the buyer's OWN contacts)
// ============================================================================

enum LookalikeEngine {
    /// Similarity 0..1 of a candidate to a seed described by its industry/city sets +
    /// contactability. Pure, deterministic, on the buyer's OWN fields.
    static func similarity(industry: String, city: String, hasEmail: Bool, hasPhone: Bool,
                           seedIndustry: Set<String>, seedCity: Set<String>) -> Double {
        var score = 0.0, maxScore = 0.0
        maxScore += 0.5; if !industry.isEmpty && seedIndustry.contains(industry.lowercased()) { score += 0.5 }
        maxScore += 0.3; if !city.isEmpty && seedCity.contains(city.lowercased()) { score += 0.3 }
        maxScore += 0.2; if hasEmail { score += 0.12 }; if hasPhone { score += 0.08 }
        return maxScore > 0 ? score / maxScore : 0
    }
    /// Rank candidate contacts by similarity to a seed pool. Empty/signal-less seed
    /// -> empty result (we never fabricate a lookalike audience).
    static func rank(seed: [Contact], candidates: [Contact]) -> [(contact: Contact, score: Double)] {
        guard !seed.isEmpty else { return [] }
        let sIndustry = Set(seed.map { $0.industry.lowercased() }.filter { !$0.isEmpty })
        let sCity = Set(seed.map { $0.city.lowercased() }.filter { !$0.isEmpty })
        guard !sIndustry.isEmpty || !sCity.isEmpty else { return [] }
        let seedIDs = Set(seed.map { $0.id })
        return candidates.filter { !seedIDs.contains($0.id) }
            .map { c in (c, similarity(industry: c.industry, city: c.city,
                                       hasEmail: !c.email.isEmpty, hasPhone: !c.phone.isEmpty,
                                       seedIndustry: sIndustry, seedCity: sCity)) }
            .sorted { $0.1 > $1.1 }
    }
}

// ============================================================================
// MARK: - Referral-program builder (tier 3)
// ============================================================================

enum ReferralReward: String, CaseIterable, Codable, Identifiable {
    case cash = "Cash", credit = "Account credit", discount = "Discount", gift = "Gift"
    var id: String { rawValue }
}

/// One referrer's logged performance. referrals/qualified/converted are OPERATOR-LOGGED.
struct ReferralRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var advocate: String = ""          // who's referring (from the buyer's contacts)
    var referrals: Int = 0
    var qualified: Int = 0
    var converted: Int = 0
    var note: String = ""
    var created = Date()
}

/// A referral program definition + its logged advocates.
struct ReferralProgram: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var rewardType: ReferralReward = .credit
    var rewardPerConversion: Double = 0
    var advocateMessage: String = "Love working with us? Refer a friend and you both get a reward."
    var records: [ReferralRecord] = []
    var created = Date()
}

enum ReferralEngine {
    static func totalReferrals(_ rs: [ReferralRecord]) -> Int { rs.reduce(0) { $0 + max(0, $1.referrals) } }
    static func totalQualified(_ rs: [ReferralRecord]) -> Int { rs.reduce(0) { $0 + max(0, $1.qualified) } }
    static func totalConverted(_ rs: [ReferralRecord]) -> Int { rs.reduce(0) { $0 + max(0, $1.converted) } }
    /// Real conversion rate of referrals (nil when no referrals — never an estimate).
    static func conversionRate(_ rs: [ReferralRecord]) -> Double? {
        let r = totalReferrals(rs); return r > 0 ? Double(totalConverted(rs)) / Double(r) : nil
    }
    static func rewardOwed(_ rs: [ReferralRecord], perConversion: Double) -> Double {
        Double(totalConverted(rs)) * max(0, perConversion)
    }
}

// ============================================================================
// MARK: - Strategy / roadmap planner (tier 3)
// ============================================================================

struct RoadItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var detail: String = ""
    var quarter: Int = 1               // 1..4
    var impact: Int = 5                // 0..10
    var effort: Int = 3                // 1..10
    var done: Bool = false
    var channels: [String] = []        // channel-aware: which lanes this launch touches
    var launchWeek: Int? = nil         // optional target week within the quarter
    var created = Date()
}

enum RoadmapEngine {
    /// ICE-style leverage (impact / effort); effort floored at 1 (no div-by-zero).
    static func score(_ i: RoadItem) -> Double { Double(max(0, i.impact)) / Double(max(1, i.effort)) }
    /// Items bucketed by quarter, priority-ordered within each.
    static func byQuarter(_ items: [RoadItem]) -> [Int: [RoadItem]] {
        var out: [Int: [RoadItem]] = [:]
        for q in 1...4 { out[q] = items.filter { $0.quarter == q }.sorted { score($0) > score($1) } }
        return out
    }
    static func topPick(_ items: [RoadItem]) -> RoadItem? { items.filter { !$0.done }.max { score($0) < score($1) } }
}

// ============================================================================
// MARK: - AEO AI-citation checker (tier 4; pure substring layer)
// ============================================================================

enum AEOEngine {
    /// Literal, case-insensitive substring — NEVER a guess about whether an AI "would" cite.
    static func mentions(_ haystack: String, _ needle: String) -> Bool {
        let h = haystack.lowercased(); let n = needle.lowercased().trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && h.contains(n)
    }
    /// Of N supplied facts, how many literally appear in the text. Real count only.
    static func coverage(text: String, facts: [String]) -> Int { facts.filter { mentions(text, $0) }.count }
    /// Per-fact found/not-found breakdown for the UI.
    static func breakdown(text: String, facts: [String]) -> [(fact: String, found: Bool)] {
        facts.map { ($0, mentions(text, $0)) }
    }
}

// ============================================================================
// MARK: - Security audit log (tier 4; append-only, hash-chained)
// ============================================================================

struct AuditEvent: Identifiable, Codable, Hashable {
    var id = UUID()
    var action: String = ""
    var detail: String = ""
    var ts: Double = 0
    var prevHash: String = ""
    var hash: String = ""
    var date: Date { Date(timeIntervalSince1970: ts) }
}

enum SecurityLog {
    static func hash(action: String, detail: String, ts: Double, prev: String) -> String {
        let s = "\(prev)|\(ts)|\(action)|\(detail)"
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func append(_ chain: [AuditEvent], action: String, detail: String, ts: Double = Date().timeIntervalSince1970) -> [AuditEvent] {
        let prev = chain.last?.hash ?? "genesis"
        let h = hash(action: action, detail: detail, ts: ts, prev: prev)
        return chain + [AuditEvent(action: action, detail: detail, ts: ts, prevHash: prev, hash: h)]
    }
    static func verify(_ chain: [AuditEvent]) -> Bool {
        var prev = "genesis"
        for e in chain {
            if e.prevHash != prev { return false }
            if e.hash != hash(action: e.action, detail: e.detail, ts: e.ts, prev: prev) { return false }
            prev = e.hash
        }
        return true
    }
}

// ============================================================================
// MARK: - AppModel integration (persistence + real-data joins)
// ============================================================================

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    // Multichannel campaigns
    func upsertMCampaign(_ c: MCampaign) {
        if let i = mcampaigns.firstIndex(where: { $0.id == c.id }) { mcampaigns[i] = c } else { mcampaigns.insert(c, at: 0) }
    }
    func deleteMCampaign(_ c: MCampaign) { mcampaigns.removeAll { $0.id == c.id } }

    // ABM accounts
    func upsertABM(_ a: ABMAccount) {
        if let i = abmAccounts.firstIndex(where: { $0.id == a.id }) { abmAccounts[i] = a } else { abmAccounts.insert(a, at: 0) }
    }
    func deleteABM(_ a: ABMAccount) { abmAccounts.removeAll { $0.id == a.id } }

    // Referral programs
    func upsertReferral(_ p: ReferralProgram) {
        if let i = referralPrograms.firstIndex(where: { $0.id == p.id }) { referralPrograms[i] = p } else { referralPrograms.insert(p, at: 0) }
    }
    func deleteReferral(_ p: ReferralProgram) { referralPrograms.removeAll { $0.id == p.id } }

    // Roadmap items
    func upsertRoadItem(_ i: RoadItem) {
        if let idx = roadItems.firstIndex(where: { $0.id == i.id }) { roadItems[idx] = i } else { roadItems.append(i) }
    }
    func deleteRoadItem(_ i: RoadItem) { roadItems.removeAll { $0.id == i.id } }

    /// Append a security-audit event (hash-chained, tamper-evident). Used for the
    /// sensitive actions a premium app must record (sign-in, export, delete-account).
    func logSecurity(_ action: String, _ detail: String = "") {
        auditLog = SecurityLog.append(auditLog, action: action, detail: detail)
    }
}
#endif // circuit-convert
