// Black Label Marketing — Tier-2 / Tier-3 engines (all pure, all on the buyer's OWN data).
//
// This file adds, with ZERO fabrication:
//   • Landing-page A/B (variant manager + winner on operator-logged views/conversions).
//   • Unified KPI rollup (paid + owned + earned) — every figure traces to logged data.
//   • Attribution engine (first / last / linear / position-based) over the buyer's OWN
//     logged touchpoints. No paid feed, no invented conversions.
//   • Workflow / automation engine (trigger → condition → action) — a real rule graph the
//     buyer authors; the simulator decides deterministically which actions WOULD fire over
//     their own contacts. Nothing auto-sends without the buyer's explicit action.
//   • Deterministic lead scoring from owned engagement signals (recency, contactability,
//     touches) — transparent point math, never an opaque "AI score".
//
// The pure logic here is mirrored 1:1 by Tests/GrowthEngineTests.swift (re-runnable, no build).
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// ============================================================================
// MARK: - Landing-page A/B test (operator-logged views + conversions only)
// ============================================================================

/// One landing-page variant in an A/B test. `siteID` references a saved SiteProject
/// the buyer generated, so the variant is a REAL page they can deploy. Views &
/// conversions are operator-logged (what they saw in their own analytics) — never
/// auto-pulled or estimated.
struct LandingVariant: Identifiable, Codable, Hashable {
    var id = UUID()
    var label: String = "A"
    var siteID: UUID? = nil          // the generated page this variant points at
    var siteName: String = ""        // denormalized name for display
    var views: Int = 0               // operator-logged sessions
    var conversions: Int = 0         // operator-logged goal completions
    /// Real conversion rate from logged data (nil if no views — no fabrication).
    var conversionRate: Double? { views > 0 ? Double(conversions) / Double(views) : nil }
}

/// A landing-page A/B test: two-or-more variants of the buyer's own pages.
struct LandingTest: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var goal: String = "Form submit"     // what counts as a conversion (buyer's own definition)
    var variants: [LandingVariant] = []
    var created = Date()
}

enum LandingABEngine {
    /// Total logged views/conversions across all variants (real sums only).
    static func totalViews(_ t: LandingTest) -> Int { t.variants.reduce(0) { $0 + max(0, $1.views) } }
    static func totalConversions(_ t: LandingTest) -> Int { t.variants.reduce(0) { $0 + max(0, $1.conversions) } }

    /// The leading variant by conversion RATE. nil until at least one variant has
    /// views (we never crown a winner on zero data). Ties broken by raw conversions.
    static func leader(_ t: LandingTest) -> LandingVariant? {
        let eligible = t.variants.filter { $0.views > 0 }
        guard !eligible.isEmpty else { return nil }
        return eligible.max { a, b in
            let ra = a.conversionRate ?? 0, rb = b.conversionRate ?? 0
            if ra == rb { return a.conversions < b.conversions }
            return ra < rb
        }
    }

    /// Relative lift of the leader over the runner-up, as a fraction (0.25 = +25%).
    /// nil unless two variants both have views (no fabrication on thin data).
    static func leaderLift(_ t: LandingTest) -> Double? {
        let rated = t.variants.filter { $0.views > 0 }.compactMap { v -> Double? in v.conversionRate }
            .sorted(by: >)
        guard rated.count >= 2, rated[1] > 0 else { return nil }
        return (rated[0] - rated[1]) / rated[1]
    }

    /// Honest call on whether the result is trustworthy yet. This is a SAMPLE-SIZE
    /// guard, not a p-value claim: we require a minimum logged sample per variant and
    /// a meaningful gap. Below that -> "keep collecting data" (never a false winner).
    static func isConclusive(_ t: LandingTest, minPerVariant: Int = 100) -> Bool {
        let withViews = t.variants.filter { $0.views > 0 }
        guard withViews.count >= 2, withViews.allSatisfy({ $0.views >= minPerVariant }) else { return false }
        guard let lift = leaderLift(t) else { return false }
        return lift >= 0.10   // need a real, ≥10% relative gap before we call it
    }
}

// ============================================================================
// MARK: - Unified KPI rollup (paid + owned + earned, logged data only)
// ============================================================================

/// A single channel-class KPI snapshot. EVERY number is a sum of operator-logged
/// values — nothing here is estimated, modeled, or pulled from a network.
struct KPIRollup {
    // Owned (UTM campaign links the buyer logged)
    var ownedClicks = 0
    var ownedConversions = 0
    // Paid (ad campaigns the buyer logged spend/clicks/conversions for)
    var paidSpend: Double = 0
    var paidClicks = 0
    var paidConversions = 0
    // Earned (organic post engagement the buyer logged)
    var earnedEngagement = 0
    var earnedPosts = 0
    // Email (campaigns built + audience reachable by email)
    var emailCampaigns = 0
    var emailReachable = 0
    // Library (assets created — proof of work, not reach)
    var reels = 0; var sites = 0; var captions = 0; var clients = 0; var crmLeads = 0   // clients = finder-sourced leads

    var totalClicks: Int { ownedClicks + paidClicks }
    var totalConversions: Int { ownedConversions + paidConversions }
    /// Blended conversion rate over CLICKS only (nil when no clicks — no fabrication).
    var blendedConvRate: Double? {
        totalClicks > 0 ? Double(totalConversions) / Double(totalClicks) : nil
    }
    /// Real cost per conversion from logged spend (nil when nothing converted/spent).
    var costPerConversion: Double? {
        paidConversions > 0 && paidSpend > 0 ? paidSpend / Double(paidConversions) : nil
    }
    /// Whether ANY measurable activity has been logged (drives empty-state vs widgets).
    var hasAnyData: Bool {
        totalClicks > 0 || totalConversions > 0 || paidSpend > 0 ||
        earnedEngagement > 0 || emailCampaigns > 0
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    /// Build the unified KPI rollup from REAL logged data across the whole studio.
    var kpiRollup: KPIRollup {
        var k = KPIRollup()
        k.ownedClicks = links.reduce(0) { $0 + max(0, $1.clicks) }
        k.ownedConversions = links.reduce(0) { $0 + max(0, $1.conversions) }
        k.paidSpend = adCampaigns.reduce(0) { $0 + max(0, $1.spent) }
        k.paidClicks = adCampaigns.reduce(0) { $0 + max(0, $1.loggedClicks) }
        k.paidConversions = adCampaigns.reduce(0) { $0 + max(0, $1.loggedConversions) }
        k.earnedEngagement = postStats.reduce(0) { $0 + max(0, $1.engagement) }
        k.earnedPosts = postStats.count
        k.emailCampaigns = campaigns.count
        k.emailReachable = allContacts.filter { !$0.email.isEmpty }.count
        k.reels = reels.count; k.sites = sites.count; k.captions = captions.count
        k.clients = leads.filter { $0.source == .finder }.count; k.crmLeads = leads.count
        return k
    }
}
#endif // circuit-convert

// ============================================================================
// MARK: - Attribution engine (first / last / linear / position-based)
// ============================================================================

/// One logged marketing touch on the path to a conversion. Channel + campaign come
/// from the buyer's OWN UTM links / ad campaigns / posts. `order` is the touch's
/// position in the journey (0 = first). Nothing here is inferred from a third party.
struct Touch: Identifiable, Hashable {
    let id = UUID()
    var channel: String      // e.g. "instagram", "google ads", "email"
    var campaign: String
    var order: Int           // position within the conversion path (0-based)
}

enum AttributionModel: String, CaseIterable, Identifiable, Codable {
    case firstTouch = "First touch", lastTouch = "Last touch",
         linear = "Linear", positionBased = "Position-based (40/20/40)",
         dataDriven = "Data-driven"
    var id: String { rawValue }
    var blurb: String {
        switch self {
        case .firstTouch:    return "100% credit to the channel that started the journey."
        case .lastTouch:     return "100% credit to the channel that closed the conversion."
        case .linear:        return "Credit split evenly across every touch."
        case .positionBased: return "40% first, 40% last, 20% split across the middle."
        case .dataDriven:    return "Credit weighted by how often each channel appears across all your converting paths — learned from your own data, not a fixed rule."
        }
    }
}

enum AttributionEngine {
    /// Distribute ONE conversion's credit across its ordered touches under a model.
    /// Returns channel -> fractional credit (sums to 1.0 for a non-empty path).
    /// Pure arithmetic on the buyer's own path — no modeling of unseen data.
    static func credit(for path: [Touch], model: AttributionModel) -> [String: Double] {
        let touches = path.sorted { $0.order < $1.order }
        guard !touches.isEmpty else { return [:] }
        var weights = [Double](repeating: 0, count: touches.count)
        switch model {
        case .firstTouch:
            weights[0] = 1
        case .lastTouch:
            weights[touches.count - 1] = 1
        case .linear:
            let w = 1.0 / Double(touches.count)
            for i in weights.indices { weights[i] = w }
        case .positionBased:
            if touches.count == 1 { weights[0] = 1 }
            else if touches.count == 2 { weights[0] = 0.5; weights[1] = 0.5 }
            else {
                weights[0] = 0.4
                weights[touches.count - 1] = 0.4
                let mid = 0.2 / Double(touches.count - 2)
                for i in 1..<(touches.count - 1) { weights[i] = mid }
            }
        case .dataDriven:
            // Single-path fallback (no cross-path data here) = even split; the real data-driven
            // weighting happens in attribute(), which sees the whole path set.
            let w = 1.0 / Double(touches.count)
            for i in weights.indices { weights[i] = w }
        }
        var out: [String: Double] = [:]
        for (i, t) in touches.enumerated() { out[t.channel, default: 0] += weights[i] }
        return out
    }

    /// Aggregate credit across MANY conversion paths under a model.
    /// channel -> total attributed conversions (real count, fractional credit summed).
    static func attribute(paths: [[Touch]], model: AttributionModel) -> [String: Double] {
        if model == .dataDriven { return dataDriven(paths: paths) }
        var out: [String: Double] = [:]
        for p in paths {
            for (ch, c) in credit(for: p, model: model) { out[ch, default: 0] += c }
        }
        return out
    }

    /// Data-driven attribution: each touch's share of its path's credit is proportional to how
    /// many of the buyer's converting paths that channel appears in (cross-path importance learned
    /// from real data). Deterministic; no modeling of unseen/non-converting journeys.
    static func dataDriven(paths: [[Touch]]) -> [String: Double] {
        // Channel importance = # of distinct paths it appears in (presence, not raw frequency).
        var presence: [String: Double] = [:]
        for p in paths { for ch in Set(p.map { $0.channel }) { presence[ch, default: 0] += 1 } }
        var out: [String: Double] = [:]
        for p in paths {
            let touches = p.sorted { $0.order < $1.order }
            guard !touches.isEmpty else { continue }
            let wsum = touches.reduce(0.0) { $0 + max(0.0001, presence[$1.channel] ?? 0) }
            for t in touches { out[t.channel, default: 0] += max(0.0001, presence[t.channel] ?? 0) / wsum }
        }
        return out
    }

    /// Rank channels by attributed credit (desc), for the report table.
    static func ranked(paths: [[Touch]], model: AttributionModel) -> [(channel: String, credit: Double)] {
        attribute(paths: paths, model: model).map { ($0.key, $0.value) }.sorted { $0.credit > $1.credit }
    }
}

// ============================================================================
// MARK: - Lead scoring (deterministic, from owned signals only)
// ============================================================================

/// Transparent lead-scoring weights the buyer can see (and, in the UI, tune).
/// Every point is justified by a REAL field on the contact — no opaque model.
struct LeadScoreWeights: Codable, Hashable {
    var hasEmail = 20          // contactable by email
    var hasPhone = 15          // contactable by phone
    var hasCompany = 10        // is a real business (B2B signal)
    var recentWithin7 = 25     // entered in the last 7 days (hot)
    var recentWithin30 = 10    // entered in the last 30 days (warm)
    var perLoggedTouch = 8     // each operator-logged engagement touch (capped)
    var touchCap = 32          // max points from touches
    static let `default` = LeadScoreWeights()
}

enum LeadGrade: String { case hot = "Hot", warm = "Warm", cool = "Cool", cold = "Cold" }

enum LeadScoreEngine {
    /// Score a contact 0–100 from REAL fields + the count of engagement touches
    /// the buyer logged for it. Deterministic; identical inputs -> identical score.
    static func score(_ c: Contact, touches: Int, w: LeadScoreWeights = .default) -> Int {
        var s = 0
        if !c.email.isEmpty { s += w.hasEmail }
        if !c.phone.isEmpty { s += w.hasPhone }
        if !c.company.isEmpty { s += w.hasCompany }
        let age = c.createdDaysAgo
        if age <= 7 { s += w.recentWithin7 }
        else if age <= 30 { s += w.recentWithin30 }
        if touches > 0 { s += min(w.touchCap, touches * w.perLoggedTouch) }
        return min(100, max(0, s))
    }
    static func grade(_ score: Int) -> LeadGrade {
        switch score {
        case 70...:  return .hot
        case 45..<70: return .warm
        case 20..<45: return .cool
        default:      return .cold
        }
    }
    /// Human-readable breakdown of why a contact scored what it did (full transparency).
    static func reasons(_ c: Contact, touches: Int, w: LeadScoreWeights = .default) -> [(String, Int)] {
        var r: [(String, Int)] = []
        if !c.email.isEmpty { r.append(("Has email", w.hasEmail)) }
        if !c.phone.isEmpty { r.append(("Has phone", w.hasPhone)) }
        if !c.company.isEmpty { r.append(("Is a business", w.hasCompany)) }
        let age = c.createdDaysAgo
        if age <= 7 { r.append(("Added in last 7 days", w.recentWithin7)) }
        else if age <= 30 { r.append(("Added in last 30 days", w.recentWithin30)) }
        if touches > 0 { r.append(("\(touches) logged touch\(touches == 1 ? "" : "es")", min(w.touchCap, touches * w.perLoggedTouch))) }
        return r
    }
}

// ============================================================================
// MARK: - Workflow / automation engine (trigger → condition → action)
// ============================================================================

enum WFTrigger: String, CaseIterable, Codable, Identifiable {
    case newLead = "New CRM lead", newClient = "New saved client",
         leadScoreAbove = "Lead score reaches", inSegment = "Enters a segment", manual = "Manual / on demand"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .newLead: return "person.badge.plus"
        case .newClient: return "building.2.fill"
        case .leadScoreAbove: return "flame.fill"
        case .inSegment: return "person.3.sequence.fill"
        case .manual: return "hand.tap.fill"
        }
    }
}

enum WFCondField: String, CaseIterable, Codable, Identifiable {
    case hasEmail = "Has email", hasPhone = "Has phone", scoreAtLeast = "Score ≥",
         industryContains = "Industry contains", cityContains = "City contains", always = "Always (no condition)"
    var id: String { rawValue }
    var needsValue: Bool { self == .scoreAtLeast || self == .industryContains || self == .cityContains }
}

enum WFAction: String, CaseIterable, Codable, Identifiable {
    case composeEmail = "Compose email (mailto)", enrollJourney = "Enroll in journey",
         addTag = "Add tag", flagForReview = "Flag for review", notify = "Show me a reminder"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .composeEmail: return "envelope.fill"
        case .enrollJourney: return "arrow.triangle.branch"
        case .addTag: return "tag.fill"
        case .flagForReview: return "flag.fill"
        case .notify: return "bell.fill"
        }
    }
    /// HONEST capability note: which actions actually execute vs. are queued for the
    /// buyer to confirm. Nothing auto-sends silently.
    var honestNote: String {
        switch self {
        case .composeEmail: return "Opens a personalized draft in your mail app — you press send."
        case .enrollJourney: return "Adds the contact to a journey you've built."
        case .addTag: return "Tags the contact in your CRM."
        case .flagForReview: return "Marks the contact for you to look at."
        case .notify: return "Surfaces a reminder in the app."
        }
    }
}

struct Workflow: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var enabled: Bool = false           // ships OFF; the buyer arms it explicitly
    var trigger: WFTrigger = .newLead
    var triggerThreshold: Int = 70      // for .leadScoreAbove
    var triggerSegmentID: UUID? = nil   // for .inSegment
    var condField: WFCondField = .always
    var condValue: String = ""
    var action: WFAction = .composeEmail
    var actionValue: String = ""        // tag name / journey name / message
    var created = Date()
}

/// Result of evaluating a workflow against one contact (what WOULD happen — the
/// buyer still confirms side-effects). Deterministic, no fabricated outcomes.
struct WFMatch: Equatable { var matched: Bool; var reason: String }

enum WorkflowEngine {
    /// Does `contact` (with its computed `score`) satisfy the workflow's condition?
    static func conditionMet(_ wf: Workflow, contact c: Contact, score: Int) -> Bool {
        switch wf.condField {
        case .always:          return true
        case .hasEmail:        return !c.email.isEmpty
        case .hasPhone:        return !c.phone.isEmpty
        case .scoreAtLeast:    return score >= (Int(wf.condValue) ?? wf.triggerThreshold)
        case .industryContains:
            let v = wf.condValue.lowercased().trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? true : c.industry.lowercased().contains(v)
        case .cityContains:
            let v = wf.condValue.lowercased().trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? true : c.city.lowercased().contains(v)
        }
    }

    /// Evaluate the full trigger→condition for one contact. `triggerFired` is decided
    /// by the caller (it knows the event context, e.g. "this is a new lead"); here we
    /// AND it with the condition and report a transparent reason.
    static func evaluate(_ wf: Workflow, contact c: Contact, score: Int, triggerFired: Bool) -> WFMatch {
        guard wf.enabled else { return WFMatch(matched: false, reason: "Workflow is off") }
        guard triggerFired else { return WFMatch(matched: false, reason: "Trigger didn't fire for this contact") }
        guard conditionMet(wf, contact: c, score: score) else {
            return WFMatch(matched: false, reason: "Condition not met: \(wf.condField.rawValue)")
        }
        return WFMatch(matched: true, reason: "Would \(wf.action.rawValue.lowercased())")
    }

    /// Count of contacts a workflow WOULD act on right now (for the UI preview).
    /// Treats the trigger as satisfied for everyone in scope (the buyer is asking
    /// "if I ran this now, how many?"), then applies the condition. Real count only.
    static func wouldAct(_ wf: Workflow, over scored: [(contact: Contact, score: Int)]) -> Int {
        guard wf.enabled else { return 0 }
        return scored.reduce(0) { acc, item in
            acc + (conditionMet(wf, contact: item.contact, score: item.score) ? 1 : 0)
        }
    }
}

// ============================================================================
// MARK: - Persistence (landing tests, workflows, lead-score weights)
// ============================================================================

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    func upsertLandingTest(_ t: LandingTest) {
        if let i = landingTests.firstIndex(where: { $0.id == t.id }) { landingTests[i] = t } else { landingTests.insert(t, at: 0) }
    }
    func deleteLandingTest(_ t: LandingTest) { landingTests.removeAll { $0.id == t.id } }

    func upsertWorkflow(_ w: Workflow) {
        if let i = workflows.firstIndex(where: { $0.id == w.id }) { workflows[i] = w } else { workflows.insert(w, at: 0) }
    }
    func deleteWorkflow(_ w: Workflow) { workflows.removeAll { $0.id == w.id } }

    /// Touch count for a contact = engagement rows the buyer logged whose channel/
    /// campaign references that contact's source. We use the contact's source label as
    /// the join key (real, operator-set) — unknown -> 0 touches (never invented).
    ///
    /// Still a substring match (so a source can match several channels), but the channel
    /// list is lowercased once via the cache below instead of per call.
    func loggedTouchCount(for c: Contact) -> Int {
        let src = c.source.lowercased().trimmingCharacters(in: .whitespaces)
        guard !src.isEmpty else { return 0 }
        return touchChannelsLowered().reduce(0) { $0 + ($1.contains(src) ? 1 : 0) }
    }

    /// Memoized lower-cased channel list (rebuilt only when postStats/contacts change).
    fileprivate func touchChannelsLowered() -> [String] {
        if _touchIndexGen == contactsGeneration, let cached = _touchChannelsLowered { return cached }
        let lowered = postStats.map { $0.channel.lowercased() }
        _touchChannelsLowered = lowered
        _touchIndexGen = contactsGeneration
        return lowered
    }

    /// Scored contacts (real fields + real touch counts), newest first. Builds the touch
    /// index ONCE, then scores each contact against it — O(contacts × distinctSources) rather
    /// than O(contacts × postStats) re-filtered per contact.
    func scoredContacts(_ w: LeadScoreWeights = .default) -> [(contact: Contact, score: Int)] {
        let channels = touchChannelsLowered()
        var touchBySource: [String: Int] = [:]   // memoize per distinct source within this call
        func touches(_ src0: String) -> Int {
            let src = src0.lowercased().trimmingCharacters(in: .whitespaces)
            guard !src.isEmpty else { return 0 }
            if let n = touchBySource[src] { return n }
            let n = channels.reduce(0) { $0 + ($1.contains(src) ? 1 : 0) }
            touchBySource[src] = n
            return n
        }
        return allContacts.map { c in (c, LeadScoreEngine.score(c, touches: touches(c.source), w: w)) }
    }
}
#endif // circuit-convert
