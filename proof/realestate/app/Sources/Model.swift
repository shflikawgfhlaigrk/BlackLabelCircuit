// Black Label Real Estate — backend: domain models, persistence, auth, and real estate math.
// Standalone. No network, no external deps. App Sandbox-safe (writes to the app container).
import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Domain models
enum DealStatus: String, Codable, CaseIterable, Identifiable {
    case lead, analyzing, offer, underContract, won, lost
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lead: return "Lead"; case .analyzing: return "Analyzing"; case .offer: return "Offer Out"
        case .underContract: return "Under Contract"; case .won: return "Closed / Won"; case .lost: return "Dead"
        }
    }
    var tint: Color {
        switch self {
        case .lead: return .gray; case .analyzing: return BLTheme.gold; case .offer: return .orange
        case .underContract: return .blue; case .won: return BLTheme.green; case .lost: return .red
        }
    }
}
#endif // circuit-convert

// Rehab condition presets drive the per-sqft rehab estimate (editable; the buyer can always
// override with an exact repairs figure). Honest: a *model*, clearly labeled an estimate.
enum RehabLevel: String, Codable, CaseIterable, Identifiable {
    case cosmetic, light, moderate, heavy, gut
    var id: String { rawValue }
    var label: String {
        switch self { case .cosmetic: return "Cosmetic"; case .light: return "Light"
        case .moderate: return "Moderate"; case .heavy: return "Heavy"; case .gut: return "Full gut" }
    }
    /// Typical $/sqft band midpoint (investor rule-of-thumb; fully overridable).
    var perSqft: Double {
        switch self { case .cosmetic: return 15; case .light: return 25
        case .moderate: return 40; case .heavy: return 65; case .gut: return 95 }
    }
    var hint: String {
        switch self {
        case .cosmetic: return "Paint, clean, minor fixes"
        case .light: return "Flooring, fixtures, paint"
        case .moderate: return "Kitchen/bath refresh + systems"
        case .heavy: return "Kitchen + baths + roof/HVAC"
        case .gut: return "Down to studs, full rebuild"
        }
    }
}

// Exit strategy changes which profit math leads.
enum ExitStrategy: String, Codable, CaseIterable, Identifiable {
    case flip, rental, wholesale
    var id: String { rawValue }
    var label: String { switch self { case .flip: return "Fix & Flip"; case .rental: return "Buy & Hold"; case .wholesale: return "Wholesale" } }
    var icon: String { switch self { case .flip: return "hammer.fill"; case .rental: return "key.fill"; case .wholesale: return "arrow.left.arrow.right" } }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct Deal: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Non-nil only for an in-memory Sample Mode fixture. It is a per-record provenance token,
    /// never a workspace-wide demo switch, so sample-only affordances cannot leak to real deals.
    var sampleFixtureID: String? = nil
    var address: String = ""
    var county: String = ""
    var parcel: String = ""             // subject parcel id (carried from the lead) — the join key that
                                        // lets the comps engine pull the parcel's own recorded sales roll.
                                        // Optional-by-default so pre-existing deals decode unchanged.
    var arv: Double = 0
    var repairs: Double = 0
    var asking: Double = 0
    var status: DealStatus = .lead
    var notes: String = ""
    var created = Date()
    // Last one-click verification packet. Optional fields keep every pre-dossier workspace readable;
    // the full text is evidence/provenance only, never a replacement for the editable deal inputs.
    var dossierSummary: String? = nil
    var dossierFetchedAt: Date? = nil

    // Deal-analyzer inputs (all editable; all optional — zero means "not set")
    var exit: ExitStrategy = .flip
    var sqft: Double = 0
    var rehabLevel: RehabLevel = .light
    var useRehabEstimate = false        // when true, repairs is computed from sqft × level
    var arvSource: String = ""          // honest label of where ARV came from (assessor / area avg / user)
    // Financing scenario
    var downPct: Double = 20
    var apr: Double = 7.5
    var loanYears: Double = 30
    var closingCostsPct: Double = 3
    var holdingMonths: Double = 5
    var monthlyCarry: Double = 0        // taxes+insurance+utilities while holding (flip)
    // Rental (buy & hold)
    var monthlyRent: Double = 0
    var monthlyOpEx: Double = 0         // taxes, insurance, mgmt, maintenance reserves
    // Wholesale
    var assignmentFee: Double = 0

    var lat: Double? = nil              // geocoded once (cached so the map needn't re-geocode);
    var lng: Double? = nil              // optional so pre-existing deals decode unchanged

    var mao: Double { mao(pct: 70) }                           // default 70% rule max allowable offer
    /// Max allowable offer at a configurable percent-of-ARV rule (Settings → Radius & valuation).
    func mao(pct: Double) -> Double { max(0, arv * (pct / 100) - repairsEffective) }
    var equityAtMAO: Double { max(0, arv - mao) }
    var spreadVsAsking: Double { mao - asking }

    /// Rehab from the per-sqft model when enabled, else the entered figure.
    var rehabEstimate: Double { sqft > 0 ? sqft * rehabLevel.perSqft : 0 }
    var repairsEffective: Double { useRehabEstimate && rehabEstimate > 0 ? rehabEstimate : repairs }

    // Cost stack
    var purchasePrice: Double { asking > 0 ? asking : mao }
    var closingCosts: Double { purchasePrice * closingCostsPct / 100 }
    var downPayment: Double { purchasePrice * downPct / 100 }
    var loanAmount: Double { max(0, purchasePrice - downPayment) }
    var holdingCosts: Double { monthlyCarry * holdingMonths }
    var totalAllIn: Double { purchasePrice + repairsEffective + closingCosts + holdingCosts }
    var cashInvested: Double { downPayment + repairsEffective + closingCosts + holdingCosts }

    // FLIP: sell at ARV, pay ~8% selling costs (agent + closing on the sale)
    var sellingCosts: Double { arv * 0.08 }
    var flipProfit: Double { max(-totalAllIn, arv - totalAllIn - sellingCosts) }
    var flipROI: Double { cashInvested > 0 ? flipProfit / cashInvested * 100 : 0 }

    // RENTAL: monthly cash flow after debt service + opex; cap rate; cash-on-cash
    var monthlyDebtService: Double { REMath.monthlyPI(principal: loanAmount, apr: apr, years: loanYears) }
    var monthlyCashFlow: Double { monthlyRent - monthlyOpEx - monthlyDebtService }
    var annualNOI: Double { (monthlyRent - monthlyOpEx) * 12 }
    var capRate: Double { arv > 0 ? annualNOI / arv * 100 : 0 }
    var cashOnCash: Double { cashInvested > 0 ? (monthlyCashFlow * 12) / cashInvested * 100 : 0 }

    // WHOLESALE: assign the contract; profit = assignment fee (your spread)
    var wholesaleProfit: Double { assignmentFee }

    /// Headline profit for the chosen exit.
    var projectedProfit: Double {
        switch exit {
        case .flip: return max(0, flipProfit)
        case .rental: return max(0, monthlyCashFlow * 12)
        case .wholesale: return wholesaleProfit
        }
    }
    var profitLabel: String {
        switch exit { case .flip: return "flip profit"; case .rental: return "annual cash flow"; case .wholesale: return "assignment fee" }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// CRM pipeline stages — a Kanban lane each. Ordered.
enum LeadStatus: String, Codable, CaseIterable, Identifiable {
    case new, contacted, appointment, negotiating, won, dead
    var id: String { rawValue }
    var label: String {
        switch self { case .new: return "New"; case .contacted: return "Contacted"
        case .appointment: return "Appointment"; case .negotiating: return "Negotiating"
        case .won: return "Won"; case .dead: return "Dead" }
    }
    var tint: Color {
        switch self { case .new: return BLTheme.gold; case .contacted: return .blue
        case .appointment: return BLTheme.green; case .negotiating: return .orange
        case .won: return BLTheme.green; case .dead: return .red }
    }
    /// Kanban lanes shown on the pipeline board (Dead is hidden by default, shown via a filter).
    static var board: [LeadStatus] { [.new, .contacted, .appointment, .negotiating, .won] }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// The free public/county source a lead came from. Each maps to a real discovery path or an
// honest "configure a source" empty state — never fabricated records.
enum LeadSource: String, Codable, CaseIterable, Identifiable {
    case probate, builder, teardown, taxDelinquent, absentee, codeViolation, preForeclosure, areaBusiness, manual, database
    var id: String { rawValue }
    // Tolerant decode: a pre-existing workspace snapshot may have stored `source` as a free string ("Probate
    // notice", "Area · …"). Map legacy strings to the closest case instead of throwing — never
    // lose a saved lead on upgrade.
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "manual"
        if let exact = LeadSource(rawValue: raw) { self = exact; return }
        let l = raw.lowercased()
        if l.contains("probate") { self = .probate }
        else if l.contains("teardown") || l.contains("lot-flip") || l.contains("lot flip") { self = .teardown }
        else if l.contains("builder") || l.contains("construction") { self = .builder }
        else if l.contains("area") || l.contains("estate") || l.contains("attorney") { self = .areaBusiness }
        else if l.contains("tax") { self = .taxDelinquent }
        else if l.contains("absentee") { self = .absentee }
        else if l.contains("foreclos") { self = .preForeclosure }
        else { self = .manual }
    }
    var label: String {
        switch self {
        case .probate: return "Probate"; case .builder: return "Builders"
        case .teardown: return "Lot flip"
        case .taxDelinquent: return "Tax delinquent"; case .absentee: return "Absentee owner"
        case .codeViolation: return "Code violation"; case .preForeclosure: return "Pre-foreclosure"
        case .areaBusiness: return "Area source"; case .manual: return "Manual"
        case .database: return "Database"
        }
    }
    var icon: String {
        switch self {
        case .probate: return "doc.text.magnifyingglass"; case .builder: return "hammer.fill"
        case .teardown: return "house.lodge.fill"
        case .taxDelinquent: return "exclamationmark.triangle.fill"; case .absentee: return "airplane"
        case .codeViolation: return "shield.lefthalf.filled"; case .preForeclosure: return "house.and.flag.fill"
        case .areaBusiness: return "building.2.fill"; case .manual: return "square.and.pencil"
        case .database: return "building.columns.fill"
        }
    }
    /// Map-pin / legend color for this source (a stable visual key, not data).
    var tint: Color {
        switch self {
        case .probate: return BLTheme.gold; case .builder: return .orange
        case .teardown: return .pink
        case .taxDelinquent: return .red; case .absentee: return .blue
        case .codeViolation: return .purple; case .preForeclosure: return .pink
        case .areaBusiness: return .teal; case .manual: return BLTheme.sub
        case .database: return .cyan
        }
    }
}
#endif // circuit-convert

// A note/task on a lead (CRM follow-up). dueDate optional; done toggles.
struct LeadTask: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String = ""
    var due: Date? = nil
    var done = false
    var created = Date()
    var completedAt: Date? = nil
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Activity timeline
// A single, append-only event on a lead's history. Kinds map to real user actions — a status
// move, a logged call/text/mail-touch, a note, a parcel resolve, a skip-trace, an assignment.
// Nothing is synthesized: every event is written when the action actually happens, and the
// unified timeline (ActivityLog) also FOLDS IN derived events (task added/done, mail drops)
// so the detail view shows one chronological story. Never fabricated.
enum ActivityKind: String, Codable, CaseIterable, Hashable {
    case created, statusChange, note, task, taskDone, call, text, email, mail, parcel, skiptrace, assignment, promoted
    var icon: String {
        switch self {
        case .created: return "sparkles"; case .statusChange: return "arrow.triangle.swap"
        case .note: return "text.bubble.fill"; case .task: return "checklist"; case .taskDone: return "checkmark.circle.fill"
        case .call: return "phone.fill"; case .text: return "message.fill"; case .email: return "envelope.fill"
        case .mail: return "envelope.open.fill"; case .parcel: return "scope"; case .skiptrace: return "person.crop.circle.badge.questionmark"
        case .assignment: return "person.fill.badge.plus"; case .promoted: return "house.fill"
        }
    }
    var tint: Color {
        switch self {
        case .created: return BLTheme.gold; case .statusChange: return .blue; case .note: return BLTheme.sub
        case .task: return BLTheme.gold; case .taskDone: return BLTheme.green; case .call, .text: return .blue
        case .email, .mail: return BLTheme.gold; case .parcel, .skiptrace: return BLTheme.green
        case .assignment: return .orange; case .promoted: return BLTheme.green
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct ActivityEvent: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: ActivityKind = .note
    var detail: String = ""          // human description ("New → Contacted", "Called — left VM")
    var at = Date()
    var actor: String = ""           // team member who did it (empty = system / unattributed)
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct Lead: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var county: String = ""
    var source: LeadSource = .probate
    var sourceDetail: String = ""        // free label (e.g. "Probate notice", vertical name)
    var phone: String = ""
    var email: String = ""
    var propertyAddress: String = ""     // the subject property (situs)
    var mailingAddress: String = ""      // owner mailing — skip-trace direct-mail target
    var ownerName: String = ""           // recorded owner (may differ from decedent)
    var assessedValue: Int = 0           // county-assessed value when resolved (0 = unknown)
    var landValue: Int = 0               // assessor LAND value (teardown/lot-flip scout; 0 = unknown)
    var parcel: String = ""
    var ownershipConfidence: String = "" // high/medium/low when parcel-resolved
    var status: LeadStatus = .new
    var notes: String = ""
    var tasks: [LeadTask] = []
    var activity: [ActivityEvent] = []   // append-only history (timeline)
    var assignedTo: UUID? = nil          // team member id (nil = unassigned)
    var lat: Double? = nil               // geocoded once (cached so the map needn't re-geocode)
    var lng: Double? = nil
    var created = Date()

    // Database provenance (set only when the lead was saved from the public-records
    // index; all optional so pre-existing workspaces decode unchanged). Contact fields
    // stay empty on these leads — public records carry no email/phone, none is invented.
    var dbOrigin: String? = nil          // "database_list" | "map" | "lotflip" | "property_index"
    var dbCategory: String? = nil        // the honest server category the list queried
    var dbCriteria: String? = nil        // human criteria summary at save time
    var dbSavedAt: Date? = nil
    var dbSourceURL: String? = nil       // the county source URL on the public record
    var dbRecordID: String? = nil        // index row id (audit trail)
    var dbState: String? = nil           // exact state code (dedupe key component)

    // RE-15 waterfall skip-trace cache (on-device). Records the last chain's outcome keyed to the
    // traced name+address so a re-trace of an unchanged lead is instant + FREE (no provider re-bill).
    // Optional so pre-existing workspaces decode unchanged; holds only what a real trace returned.
    var skipTraceCache: SkipTraceCacheEntry? = nil

    // RE-22 title/lien chain cache (on-device). The last recorder pull for THIS parcel so re-opening a
    // lead's title chain is instant + free (cache-hit == zero network). Optional so pre-existing
    // workspaces decode unchanged; holds only recorded documents an endpoint actually returned.
    var titleChainCache: TitleChainCacheEntry? = nil

    /// True when this lead came from the public-records database (drives the
    /// "not skip-traced yet" labeling on empty contact fields).
    var isDatabaseLead: Bool { dbOrigin != nil }

    /// True if this lead can be routed / mapped (has a geocodable property address).
    var routableAddress: String? {
        let a = propertyAddress.trimmingCharacters(in: .whitespaces)
        return a.range(of: #"\d"#, options: .regularExpression) != nil ? a : nil
    }
    var openTasks: Int { tasks.filter { !$0.done }.count }

    /// Data-derived absentee tell: the owner's mailing address differs from the property (situs),
    /// both present, compared under the same normalization the List Builder uses. Single source of
    /// truth for the ListEngine `absenteeOnly` filter AND the LeadScoring signal — derived from the
    /// GIS/skip-trace data actually on file, never the `.absentee` source string alone (a probate or
    /// tax-delinquent lead can also be absentee once its mailing resolves). Empty either side → false
    /// (unknown, not absentee — we never guess).
    var isAbsentee: Bool {
        let mail = ListEngine.norm(mailingAddress), situs = ListEngine.norm(propertyAddress)
        return !mail.isEmpty && !situs.isEmpty && mail != situs
    }

    /// Append an event to this lead's history (mutating; caller persists via model.upsert).
    mutating func log(_ kind: ActivityKind, _ detail: String, actor: String = "") {
        activity.append(ActivityEvent(kind: kind, detail: detail, at: Date(), actor: actor))
    }
}
#endif // circuit-convert

// MARK: - Team / assignment
// A team member the buyer adds (acquisitions reps, dispo, VAs). Single-user installs simply have
// one member (or none → "Unassigned"). Real, persisted, no fabricated roster.
struct TeamMember: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var email: String = ""
    var role: String = "Acquisitions"
    var active = true                    // round-robin only assigns to active members
    var created = Date()
    var initials: String {
        let parts = name.split(separator: " ").prefix(2).map { String($0.prefix(1)) }
        return parts.isEmpty ? "?" : parts.joined().uppercased()
    }
}

// How new leads get an owner. Manual = the user picks; round-robin = even distribution across
// active members; firstActive = a single default owner. Pure logic — see LeadRouting.
enum AssignStrategy: String, Codable, CaseIterable, Identifiable {
    case manual, roundRobin, firstActive
    var id: String { rawValue }
    var label: String {
        switch self { case .manual: return "Manual (assign by hand)"
        case .roundRobin: return "Round-robin (even split)"; case .firstActive: return "Single owner" }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Lead-routing engine: decides who the next lead goes to. Pure + deterministic so it's testable.
// Round-robin counts EXISTING assignments per active member and gives the next lead to whoever
// currently has the fewest (ties broken by team order) — true even distribution, not random.
enum LeadRouting {
    /// The active members, in stable order.
    static func active(_ team: [TeamMember]) -> [TeamMember] { team.filter { $0.active } }

    /// Pick the next assignee id for a new lead given the strategy, the team, and the current
    /// assignment counts across existing leads. Returns nil when nobody can be assigned.
    static func nextAssignee(strategy: AssignStrategy, team: [TeamMember], existing: [Lead]) -> UUID? {
        let pool = active(team)
        guard !pool.isEmpty else { return nil }
        switch strategy {
        case .manual: return nil
        case .firstActive: return pool.first?.id
        case .roundRobin:
            var counts: [UUID: Int] = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, 0) })
            for l in existing { if let a = l.assignedTo, counts[a] != nil { counts[a, default: 0] += 1 } }
            // fewest first; stable tiebreak by team order
            return pool.min { (counts[$0.id] ?? 0, idx($0.id, pool)) < (counts[$1.id] ?? 0, idx($1.id, pool)) }?.id
        }
    }
    private static func idx(_ id: UUID, _ pool: [TeamMember]) -> Int { pool.firstIndex { $0.id == id } ?? .max }

    /// Distribute a batch of NEW leads across the team per the strategy, returning the leads with
    /// `assignedTo` filled. Round-robin keeps running counts so a batch splits evenly too.
    static func distribute(_ leads: [Lead], strategy: AssignStrategy, team: [TeamMember], existing: [Lead]) -> [Lead] {
        guard strategy != .manual else { return leads }
        let pool = active(team)
        guard !pool.isEmpty else { return leads }
        var counts: [UUID: Int] = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, 0) })
        for l in existing { if let a = l.assignedTo, counts[a] != nil { counts[a, default: 0] += 1 } }
        return leads.map { lead in
            var x = lead
            let id: UUID?
            switch strategy {
            case .manual: id = nil
            case .firstActive: id = pool.first?.id
            case .roundRobin:
                id = pool.min { (counts[$0.id] ?? 0, idx($0.id, pool)) < (counts[$1.id] ?? 0, idx($1.id, pool)) }?.id
                if let id { counts[id, default: 0] += 1 }
            }
            if let id { x.assignedTo = id }
            return x
        }
    }
}
#endif // circuit-convert

// A disposition cash buyer (the buyer's own list — built by hand or imported). Real, persisted.
// The structured buy-box fields drive AUTO-MATCHING a deal to the buyers it fits (Investorlift's
// moat), and `proofOfFunds` gates the address reveal — a verified buyer sees the address; an
// unverified one gets the blurred teaser until they upload POF (no fabricated verification).
struct CashBuyer: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var email: String = ""
    var phone: String = ""
    var markets: String = ""            // areas they buy (free text — county/metro keywords)
    var criteria: String = ""           // free-text notes (strategy, condition prefs)
    var created = Date()

    // Structured BUY-BOX (drives auto-match; all optional, 0 = "no bound")
    var minPrice: Double = 0
    var maxPrice: Double = 0
    var strategies: Set<ExitStrategy> = []   // empty = buys any exit
    var counties: [String] = []              // structured county list (in addition to free `markets`)

    // PROOF OF FUNDS — gates the address reveal. The buyer (investor) marks a cash-buyer verified
    // after reviewing POF they were sent; the app stores ONLY the verified flag + a label/date,
    // never a fabricated "verified ✓" and never the document itself.
    var pofVerified = false
    var pofLabel: String = ""                // e.g. "Bank letter 6/2026", "Hard-money POF"
    var pofVerifiedDate: Date? = nil
}

// A saved outreach draft — real on-device content the investor writes for a lead/deal.
// Drafts are stored locally and can be copied / exported to a .txt to send through the
// buyer's own channel. In-app automated sending is honestly labeled "Coming soon".
struct OutreachDraft: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var audience: String = "Probate leads"
    var body: String = ""
    var created = Date()
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// An offer / Letter of Intent tied to a deal. Generates a real LOI document the buyer
// can copy/export; tracks the offer's status. No e-signature claim — honest.
enum OfferStatus: String, Codable, CaseIterable, Identifiable {
    case draft, sent, countered, accepted, rejected
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var tint: Color {
        switch self { case .draft: return .gray; case .sent: return BLTheme.gold
        case .countered: return .orange; case .accepted: return BLTheme.green; case .rejected: return .red }
    }
}
#endif // circuit-convert
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct Offer: Identifiable, Codable, Hashable {
    var id = UUID()
    var dealID: UUID
    /// Matches the linked synthetic Deal's fixture token only in Sample Mode. Optional keeps
    /// pre-existing workspaces decodable and lets export policy prove the exact fixture pair.
    var sampleFixtureID: String? = nil
    var propertyAddress: String = ""
    var buyerName: String = ""           // your entity
    var sellerName: String = ""
    var amount: Double = 0
    var earnestMoney: Double = 1000
    var closingDays: Int = 30
    var inspectionDays: Int = 10
    var contingencies: String = "Inspection, clear title, financing"
    var status: OfferStatus = .draft
    var created = Date()

    /// A real, fillable LOI body generated from the fields above (buyer copies/exports + sends).
    func loiText(now: Date = Date()) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = 0
        let money: (Double) -> String = { f.string(from: NSNumber(value: $0)) ?? "$0" }
        let d = DateFormatter(); d.dateStyle = .long
        return """
        LETTER OF INTENT TO PURCHASE REAL ESTATE

        Date: \(d.string(from: now))

        Property: \(propertyAddress.isEmpty ? "[property address]" : propertyAddress)
        Buyer: \(buyerName.isEmpty ? "[buyer / entity]" : buyerName)
        Seller: \(sellerName.isEmpty ? "[seller / estate]" : sellerName)

        The Buyer hereby submits this non-binding Letter of Intent to purchase the above
        property on the following principal terms:

        • Purchase Price: \(money(amount))
        • Earnest Money Deposit: \(money(earnestMoney)), due upon mutual execution of a
          definitive purchase agreement.
        • Closing: on or before \(closingDays) days from the effective date of a definitive
          agreement.
        • Inspection / Due-Diligence Period: \(inspectionDays) days.
        • Contingencies: \(contingencies).
        • Purchase to be all-cash / as-is unless otherwise agreed.

        This Letter of Intent is non-binding and is intended solely to outline the basic terms
        for a potential transaction. A binding obligation will arise only upon the execution of
        a definitive written purchase and sale agreement by both parties.

        Sincerely,
        \(buyerName.isEmpty ? "[buyer / entity]" : buyerName)
        """
    }
}
#endif // circuit-convert

extension Notification.Name {
    /// Posted by Settings when the Lead Database key is saved or cleared — live list
    /// screens re-run their current query so the new tier cap applies immediately.
    static let blreLeadDBTokenChanged = Notification.Name("blre.leadDBTokenChanged")
}

struct PropertyMapLaunchRequest: Equatable {
    let id = UUID()
    var query: String = ""
    var state: String = ""
    var county: String = ""
    var city: String = ""
    var zip: String = ""
    // Guided-list passthrough: when a built list opens in the map, its pins are the
    // list's own records (the Worker applies the same honest category predicate).
    var category: String = ""
    var minValue: Int? = nil
    var maxValue: Int? = nil
    var soldAfter: String = ""
    var soldBefore: String = ""
    var listLabel: String = ""
    /// The list's full database count at launch time (drives the map's List-context
    /// drawer). nil = not run yet; never estimated.
    var total: Int? = nil

    /// Build the launch request for a guided database list.
    static func forList(_ criteria: DatabaseListCriteria, total: Int? = nil) -> PropertyMapLaunchRequest {
        PropertyMapLaunchRequest(query: "",
                                 state: criteria.area.canonicalState,
                                 county: criteria.area.canonicalCounty,
                                 city: criteria.area.city,
                                 zip: criteria.area.zip,
                                 category: criteria.categoryOverride ?? criteria.type.apiCategory ?? "",
                                 minValue: criteria.minValue,
                                 maxValue: criteria.maxValue,
                                 soldAfter: DatabaseListCriteria.validDay(criteria.soldAfter) ?? "",
                                 soldBefore: DatabaseListCriteria.validDay(criteria.soldBefore) ?? "",
                                 listLabel: criteria.summary,
                                 total: total)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Persistence (real backend — Postgres via BlackLabelRealEstateAPI)
final class AppModel: ObservableObject {
    @Published var deals: [Deal] = [] { didSet { save() } }
    @Published var leads: [Lead] = [] { didSet { save() } }
    @Published var drafts: [OutreachDraft] = [] { didSet { save() } }
    @Published var buyers: [CashBuyer] = [] { didSet { save() } }
    @Published var offers: [Offer] = [] { didSet { save() } }
    @Published var smartLists: [SmartList] = [] { didSet { save() } }
    @Published var databaseLists: [SavedDatabaseList] = [] { didSet { save() } }
    @Published var suppression = Suppression() { didSet { save() } }
    @Published var spend: [MarketingSpend] = [] { didSet { save() } }
    @Published var expenses: [DealExpense] = [] { didSet { save() } }
    @Published var mailSequences: [MailSequence] = [] { didSet { save() } }
    @Published var enrollments: [MailEnrollment] = [] { didSet { save() } }
    @Published var phoneProvider = PhoneProvider() { didSet { save() } }
    @Published var team: [TeamMember] = [] { didSet { save() } }
    @Published var assignStrategy: AssignStrategy = .manual { didSet { save() } }
    @Published var pendingPropertyMapRequest: PropertyMapLaunchRequest?
    /// The Property Map's last viewport (not persisted) — lets the List Builder offer
    /// an honest "current map view" area without re-opening the map.
    @Published var lastMapBounds: PropertyMapBounds?

    private struct Box: Codable {
        var deals: [Deal]; var leads: [Lead]
        var drafts: [OutreachDraft]? = []
        var buyers: [CashBuyer]? = []
        var offers: [Offer]? = []
        var smartLists: [SmartList]? = []
        var databaseLists: [SavedDatabaseList]? = []
        var suppression: Suppression? = nil
        var spend: [MarketingSpend]? = []
        var expenses: [DealExpense]? = []
        var mailSequences: [MailSequence]? = []
        var enrollments: [MailEnrollment]? = []
        var phoneProvider: PhoneProvider? = nil
        var team: [TeamMember]? = []
        var assignStrategy: AssignStrategy? = nil
    }
    private let database: RealEstateLocalDatabase

    // MARK: Save coalescing (the dense-county responsiveness fix)
    // Every @Published array `didSet`s into `save()`. A naive synchronous full-dataset encode+write
    // on EACH mutation makes a bulk op (CSV import / batch parcel-resolve of a covered county) O(n²)
    // main-thread work — N appended leads = N full re-encodes of the whole Box, all blocking the UI.
    // That is the same memory/perf cliff class as the LotFlipScout near-crash. Fix:
    //   • `save()` only marks dirty + schedules ONE debounced flush (0.4s) on the main run loop, so a
    //     burst of mutations collapses into a single write.
    //   • the encode+write runs on a background serial queue (off the main thread), so even the one
    //     write never janks the UI.
    //   • `batch { … }` suspends scheduling during a bulk mutation and flushes exactly once at the end
    //     (synchronously) for immediate durability — used by import / batch-resolve.
    private let writeQueue = DispatchQueue(label: "com.blacklabel.realestate.persist", qos: .utility)
    private var saveScheduled = false
    private var batchDepth = 0

    /// When true, the `@Published` `didSet` saves are NO-OPs. Demo mode flips this on so the synthetic
    /// dataset lives ONLY in memory and never touches the Postgres workspace — preserving ship-no-data. A
    /// real install (suppressSave == false) persists the buyer's own data exactly as before.
    private(set) var suppressSave = false
    /// True once demo data has been loaded into this in-memory model (drives the SAMPLE-DATA banner).
    @Published private(set) var isDemo = false

    /// One-shot honest storage warning (corrupt workspace preserved aside, or a failing disk
    /// write). nil in every healthy session; RootView presents it once and clears it. The UI must
    /// never imply an edit is saved when the store said otherwise.
    @Published var storageNotice: String?
    /// True after a flush failure has been reported this session — the debounced writer retries
    /// every 0.4s while typing continues, and one alert per failure episode is signal, a stream of
    /// them is noise. Reset by the next successful write.
    private var writeFailureReported = false

    /// True only while `load()` is hydrating from disk — suppresses the redundant save that each
    /// `@Published` assignment would otherwise schedule (we just read this exact state from disk).
    private var loading = false

    init() {
        database = RealEstateLocalDatabase()
        load()
        #if os(macOS)
        // Flush any pending debounced write before the app quits so the last 0.4s of edits are durable.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.flushNow() }
        #elseif canImport(UIKit)
        // iOS never gets a reliable willTerminate: backgrounding is the durability point. A process
        // suspended inside the 0.4s debounce window can be jetsammed with the write never fired, so
        // the pending edits must hit disk the moment the app leaves the foreground.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.flushNow() }
        #endif
    }

    private func load() {
        loading = true
        defer { loading = false }
        let read: Data?
        do { read = try database.readBlob(named: RealEstateLocalDatabase.appData) }
        catch {
            // The store exists but could not be READ (permissions / I/O). There are no bytes to
            // rescue, so pausing saves is the only way to guarantee this session's near-empty
            // workspace never atomically overwrites the unreadable original.
            suppressSave = true
            storageNotice = "The saved workspace could not be read (\(error.localizedDescription)). Saving is paused for this session so the file is not overwritten."
            return
        }
        guard let data = read else { return }   // genuinely fresh install — no blob on disk
        if let box = try? JSONDecoder().decode(Box.self, from: data) {
            apply(box)
            return
        }
        // The blob exists but does not decode. Starting empty over it silently would let the very
        // first edit atomically overwrite the only copy of a recoverable workspace — preserve the
        // undecodable bytes aside FIRST, and only keep saves enabled once that rescue copy is on
        // disk. The notice is surfaced once at launch (RootView alert); nothing is fabricated.
        let stamp = Self.rescueStamp()
        let rescueName = "appData.corrupt-\(stamp)"
        do {
            try database.writeBlob(data, named: rescueName)
            storageNotice = "The saved workspace file could not be read, so this launch starts empty. The unreadable file was preserved as \(rescueName).blob.json in the app's data folder for recovery."
        } catch {
            suppressSave = true
            storageNotice = "The saved workspace file could not be read, and preserving a rescue copy also failed (\(error.localizedDescription)). Saving is paused for this session so the file is not overwritten."
        }
    }

    /// Filesystem-safe timestamp for the corrupt-blob rescue name (blob names reject "/" etc.).
    private static func rescueStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private func apply(_ box: Box) {
        deals = box.deals; leads = box.leads; drafts = box.drafts ?? []
        buyers = box.buyers ?? []; offers = box.offers ?? []
        smartLists = box.smartLists ?? []; databaseLists = box.databaseLists ?? []
        suppression = box.suppression ?? Suppression()
        spend = box.spend ?? []; expenses = box.expenses ?? []
        mailSequences = box.mailSequences ?? []; enrollments = box.enrollments ?? []
        phoneProvider = box.phoneProvider ?? PhoneProvider()
        team = box.team ?? []; assignStrategy = box.assignStrategy ?? .manual
    }

    private func clearWorkspaceInMemory() {
        deals = []; leads = []; drafts = []; buyers = []; offers = []
        smartLists = []; databaseLists = []; suppression = Suppression(); spend = []; expenses = []
        mailSequences = []; enrollments = []; phoneProvider = PhoneProvider()
        team = []; assignStrategy = .manual
    }
    /// Called from every @Published `didSet`. Coalesces a burst of mutations into ONE debounced,
    /// off-main-thread write instead of a synchronous full-dataset encode per mutation. While a
    /// `batch { }` is open, scheduling is suspended (the batch flushes once at the end).
    private func save() {
        guard !suppressSave else { return }   // demo mode: in-memory only, never persist synthetic data
        guard !loading else { return }        // hydrating from disk — don't re-write what we just read
        guard batchDepth == 0 else { return } // inside a bulk op — one flush happens at batch end
        scheduleFlush()
    }

    /// Debounce on the main run loop: collapse rapid mutations into a single delayed flush.
    private func scheduleFlush(after delay: TimeInterval = 0.4) {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.flush()
        }
    }

    /// Snapshot the current model on the main thread (cheap, value types), then encode + write
    /// atomically on a background serial queue so the disk I/O never janks the UI.
    private func flush(sync: Bool = false) {
        guard !suppressSave else { return }
        let box = Box(deals: deals, leads: leads, drafts: drafts, buyers: buyers, offers: offers,
                      smartLists: smartLists, databaseLists: databaseLists,
                      suppression: suppression, spend: spend, expenses: expenses,
                      mailSequences: mailSequences, enrollments: enrollments, phoneProvider: phoneProvider,
                      team: team, assignStrategy: assignStrategy)
        let database = database
        let write = { [weak self] in
            // A swallowed write failure here is silent data loss (disk full, permissions): the UI
            // keeps implying "saved" while nothing hits disk. Surface the first failure per
            // episode; a later success clears the episode so a new fault reports again.
            do {
                let data = try JSONEncoder().encode(box)
                try database.writeBlob(data, named: RealEstateLocalDatabase.appData)
                DispatchQueue.main.async {
                    guard let self, self.writeFailureReported else { return }
                    self.writeFailureReported = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, !self.writeFailureReported else { return }
                    self.writeFailureReported = true
                    self.storageNotice = "Saving your workspace failed: \(error.localizedDescription). Recent edits may not be on disk — free up space or fix the store folder, then edit again to retry."
                }
            }
        }
        if sync { writeQueue.sync(execute: write) } else { writeQueue.async(execute: write) }
    }

    /// Run a bulk mutation (CSV import, batch parcel-resolve, multi-lead routing) with persistence
    /// SUSPENDED, then persist exactly once. Turns N synchronous full-dataset writes into 1 — the
    /// single biggest responsiveness win on a dense county. Re-entrant (nested batches flush once).
    func batch(_ work: () -> Void) {
        batchDepth += 1
        work()
        batchDepth -= 1
        if batchDepth == 0 { save() }
    }

    /// Force any pending debounced write to disk immediately (e.g. before the app would terminate or
    /// hand off). Safe to call any time; a no-op in demo mode.
    func flushNow() {
        guard !suppressSave else { return }
        saveScheduled = false
        flush(sync: true)
    }

    /// True when the hydrated workspace holds ANY user work. The auth screen consults this before
    /// the guest path so "Continue as guest" can never silently erase a saved book of business —
    /// the one-blob store is shared by guest and account sessions alike.
    var hasSavedWork: Bool {
        !(deals.isEmpty && leads.isEmpty && drafts.isEmpty && buyers.isEmpty && offers.isEmpty
          && smartLists.isEmpty && databaseLists.isEmpty && mailSequences.isEmpty && enrollments.isEmpty)
    }

    /// Guest entry that KEEPS the saved workspace already hydrated at launch. Used when the user
    /// explicitly chooses "Resume saved workspace" on the guest path. No wipe, no re-read; the
    /// normal debounced persistence keeps running.
    func resumeGuestWorkspace() {
        isDemo = false
    }

    /// The auth screen's "start empty" guest path must be truly empty. It clears the
    /// workspace blob when one exists and otherwise remains in memory only, so stale
    /// contacts from this Mac cannot look like shipped app data. DESTRUCTIVE — callers must
    /// confirm with the user first when `hasSavedWork` (see AuthView's guest dialog).
    func startEmptyGuestWorkspace() {
        suppressSave = true
        clearWorkspaceInMemory()
        isDemo = false
        saveScheduled = false
        try? database.deleteBlob(named: RealEstateLocalDatabase.appData)
        suppressSave = false
        flushNow()
    }

    /// DEV-ONLY (BLRE_GUEST=1 smoke): the same EMPTY guest workspace in memory, but with
    /// persistence fully suppressed and NOTHING deleted — proves the fresh-real-account
    /// experience without touching any real saved workspace on this machine.
    func startSmokeGuestWorkspace() {
        suppressSave = true
        clearWorkspaceInMemory()
        isDemo = false
        saveScheduled = false
    }

    /// Load the synthetic REVIEWER/BUYER demo dataset into memory only. Persistence is suppressed for
    /// the lifetime of this model instance, so nothing demo is ever written to Postgres and a fresh
    /// real sign-in still starts empty. Idempotent.
    func loadDemo() {
        guard !isDemo else { return }
        suppressSave = true                 // from here on, no @Published didSet writes to disk
        let t = DemoData.team
        let ls = DemoData.leads(team: t)
        let ds = DemoData.deals()
        let seq = DemoData.mailSequence()
        team = t
        assignStrategy = .roundRobin
        leads = ls
        deals = ds
        buyers = DemoData.buyers()
        offers = DemoData.offers(for: ds)
        smartLists = DemoData.smartLists(from: ls)
        mailSequences = [seq]
        enrollments = DemoData.enrollments(sequence: seq, leads: ls)
        spend = DemoData.spend()
        expenses = DemoData.expenses(for: ds)
        isDemo = true
    }

    /// Leave demo mode and hand the user a clean, EMPTY real workspace — the "Connect your own & go
    /// live" path. Every synthetic record is dropped from memory and persistence is re-enabled so the
    /// buyer's real data (which they're about to add / import / sign in to) is the only thing that
    /// ever reaches Postgres. Because demo never persisted (suppressSave was on), there is nothing
    /// demo to delete — but we still reload the Postgres workspace to restore any pre-existing real
    /// data the buyer had before they tapped "Explore with sample data". Idempotent.
    func exitDemo() {
        guard isDemo else { return }
        // IMPORTANT: clear the synthetic set while persistence is STILL suppressed, so wiping the
        // in-memory demo arrays can never write empty/synthetic data over the buyer's real workspace.
        clearWorkspaceInMemory()
        // Now re-enable real persistence and reload whatever real data was on disk (usually empty for
        // a fresh install — the buyer is about to sign in and start on their own data).
        suppressSave = false
        load()
        isDemo = false
    }

    // Smart lists CRUD (List Builder)
    func upsert(_ s: SmartList) { if let i = smartLists.firstIndex(where: { $0.id == s.id }) { smartLists[i] = s } else { smartLists.insert(s, at: 0) } }
    func deleteList(_ s: SmartList) { smartLists.removeAll { $0.id == s.id } }
    func upsert(_ s: SavedDatabaseList) { if let i = databaseLists.firstIndex(where: { $0.id == s.id }) { databaseLists[i] = s } else { databaseLists.insert(s, at: 0) } }
    func deleteDatabaseList(_ s: SavedDatabaseList) { databaseLists.removeAll { $0.id == s.id } }

    // List automation: advance every auto-maintained list's membership to the current leads,
    // and report what changed (added / removed). Removals leave the LIST only — never the CRM.
    @discardableResult
    func syncLists() -> [ListSyncResult] {
        let results = ListEngine.syncAll(smartLists, against: leads)
        smartLists = smartLists.map { $0.autoMaintain ? ListEngine.applied($0, against: leads) : $0 }
        return results
    }
    func syncResults() -> [ListSyncResult] { ListEngine.syncAll(smartLists, against: leads) }

    // Direct-mail sequences + enrollments CRUD
    func upsert(_ s: MailSequence) { if let i = mailSequences.firstIndex(where: { $0.id == s.id }) { mailSequences[i] = s } else { mailSequences.insert(s, at: 0) } }
    func deleteSequence(_ s: MailSequence) { mailSequences.removeAll { $0.id == s.id }; enrollments.removeAll { $0.sequenceID == s.id } }
    func enroll(_ lead: Lead, in seq: MailSequence) {
        guard !enrollments.contains(where: { $0.leadID == lead.id && $0.sequenceID == seq.id }) else { return }
        enrollments.insert(MailEnrollment(leadID: lead.id, sequenceID: seq.id), at: 0)
    }
    func unenroll(_ e: MailEnrollment) { enrollments.removeAll { $0.id == e.id } }
    func toggleTouch(_ e: MailEnrollment, touchID: UUID) {
        guard let i = enrollments.firstIndex(where: { $0.id == e.id }) else { return }
        if enrollments[i].completedTouchIDs.contains(touchID) { enrollments[i].completedTouchIDs.remove(touchID) }
        else { enrollments[i].completedTouchIDs.insert(touchID) }
    }
    func sequence(_ id: UUID) -> MailSequence? { mailSequences.first { $0.id == id } }
    func lead(_ id: UUID) -> Lead? { leads.first { $0.id == id } }
    /// Every mail piece due to drop now across all enrollments (the "mail to send" queue).
    func dueMailPieces(asOf: Date = Date()) -> [ScheduledMailPiece] {
        enrollments.flatMap { e -> [ScheduledMailPiece] in
            guard let seq = sequence(e.sequenceID), let l = lead(e.leadID) else { return [] }
            return MailMerge.due(MailMerge.schedule(e, sequence: seq, lead: l), asOf: asOf)
        }.sorted { $0.dropDate < $1.dropDate }
    }
    /// A mail-house-ready export packet for due pieces. It never marks anything sent; rows with
    /// missing addresses or unresolved placeholders are flagged `NEEDS_REVIEW` instead.
    func dueMailDropPacket(asOf: Date = Date()) -> MailDropExportPacket {
        MailDropExport.build(enrollments: enrollments, sequences: mailSequences, leads: leads, asOf: asOf)
    }

    // Marketing spend CRUD (Deal Accounting)
    func upsert(_ s: MarketingSpend) { if let i = spend.firstIndex(where: { $0.id == s.id }) { spend[i] = s } else { spend.insert(s, at: 0) } }
    func deleteSpend(_ s: MarketingSpend) { spend.removeAll { $0.id == s.id } }

    // Per-deal expenses
    func expenses(for dealID: UUID) -> [DealExpense] { expenses.filter { $0.dealID == dealID } }
    func addExpense(_ e: DealExpense) { expenses.insert(e, at: 0) }
    func deleteExpense(_ e: DealExpense) { expenses.removeAll { $0.id == e.id } }

    // Suppression / opt-out (Compliance)
    func suppress(phone: String = "", email: String = "") {
        if !phone.isEmpty { suppression.add(phone: phone) }
        if !email.isEmpty { suppression.add(email: email) }
    }
    func unsuppress(phone: String = "", email: String = "") {
        if !phone.isEmpty { suppression.remove(phone: phone) }
        if !email.isEmpty { suppression.remove(email: email) }
    }

    // Outreach drafts CRUD
    func upsert(_ d: OutreachDraft) {
        if let i = drafts.firstIndex(where: { $0.id == d.id }) { drafts[i] = d } else { drafts.insert(d, at: 0) }
    }
    func deleteDraft(_ d: OutreachDraft) { drafts.removeAll { $0.id == d.id } }

    // Deals CRUD
    func upsert(_ d: Deal) {
        if let i = deals.firstIndex(where: { $0.id == d.id }) { deals[i] = d } else { deals.insert(d, at: 0) }
    }
    func deleteDeal(_ d: Deal) { deals.removeAll { $0.id == d.id } }

    /// Save public-record rows into My Leads with database dedupe (state + parcel_id +
    /// owner_name) and full provenance. Returns honest counts — duplicates are reported,
    /// never silently re-added. Contact fields stay empty (labeled "not skip-traced yet").
    @discardableResult
    func saveDatabaseRecords(_ records: [PropertyRecord],
                             origin: DatabaseLeadOrigin,
                             apiCategory: String?,
                             criteriaSummary: String) -> (added: Int, duplicates: Int) {
        let converted = records.map {
            DatabaseLeadImport.lead(from: $0, origin: origin, apiCategory: apiCategory, criteriaSummary: criteriaSummary)
        }
        return addDatabaseLeads(converted)
    }

    /// Insert pre-built database-provenance leads (e.g. Lot-Flip candidates with their
    /// rich scoring notes) using the SAME dedupe identity: state + parcel_id + owner_name.
    @discardableResult
    func addDatabaseLeads(_ new: [Lead]) -> (added: Int, duplicates: Int) {
        var seen = Set(leads.compactMap { DatabaseLeadImport.dedupeKey(for: $0) })
        var fresh: [Lead] = []
        var duplicates = 0
        for l in new {
            guard let key = DatabaseLeadImport.dedupeKey(for: l) else { duplicates += 1; continue }
            if seen.insert(key).inserted { fresh.append(l) } else { duplicates += 1 }
        }
        guard !fresh.isEmpty else { return (0, duplicates) }
        let routed = LeadRouting.distribute(fresh, strategy: assignStrategy, team: team, existing: leads)
        batch {
            var staged: [Lead] = []
            staged.reserveCapacity(routed.count)
            for var l in routed {
                if let a = l.assignedTo, let m = member(a) {
                    l.activity.append(ActivityEvent(kind: .assignment, detail: "Assigned to \(m.name)", actor: m.name))
                }
                staged.append(l)
            }
            leads.insert(contentsOf: staged, at: 0)
        }
        return (fresh.count, duplicates)
    }

    // Leads CRUD
    func addLeads(_ new: [Lead]) {
        // de-dupe against existing (name+county), then auto-assign via the routing strategy and
        // stamp a `created` activity event. No fabricated owners — these are caller-built leads.
        // De-dupe against existing in O(new + existing) via a name+county key set (was an O(new ×
        // existing) nested `contains` — a real cliff when importing thousands into a dense county).
        var seen = Set(leads.map { "\($0.name.lowercased())|\($0.county)" })
        var fresh: [Lead] = []
        for l in new {
            let key = "\(l.name.lowercased())|\(l.county)"
            if seen.insert(key).inserted { fresh.append(l) }
        }
        guard !fresh.isEmpty else { return }
        let routed = LeadRouting.distribute(fresh, strategy: assignStrategy, team: team, existing: leads)
        // ONE coalesced save for the whole import, not one full-dataset write per inserted lead.
        batch {
            var staged: [Lead] = []
            staged.reserveCapacity(routed.count)
            for var l in routed {
                l.activity.append(ActivityEvent(kind: .created, detail: "Added from \(l.source.label)\(l.county.isEmpty ? "" : " · \(l.county)")"))
                if let a = l.assignedTo, let m = member(a) { l.activity.append(ActivityEvent(kind: .assignment, detail: "Assigned to \(m.name)", actor: m.name)) }
                staged.append(l)
            }
            // Single array mutation = single didSet, instead of one per lead.
            leads.insert(contentsOf: staged, at: 0)
        }
    }
    func upsert(_ l: Lead) {
        if let i = leads.firstIndex(where: { $0.id == l.id }) { leads[i] = l } else { leads.insert(l, at: 0) }
    }
    func deleteLead(_ l: Lead) { leads.removeAll { $0.id == l.id } }
    func setLeadStatus(_ l: Lead, _ s: LeadStatus) {
        guard l.status != s else { return }
        var x = l; x.log(.statusChange, "\(l.status.label) → \(s.label)"); x.status = s; upsert(x)
    }
    /// Assign (or unassign) a lead and log it.
    func assign(_ l: Lead, to memberID: UUID?) {
        var x = l; x.assignedTo = memberID
        x.log(.assignment, memberID.flatMap { member($0)?.name }.map { "Assigned to \($0)" } ?? "Unassigned",
              actor: memberID.flatMap { member($0)?.name } ?? "")
        upsert(x)
    }

    // Team CRUD + lookup (lead routing / assignment)
    func member(_ id: UUID) -> TeamMember? { team.first { $0.id == id } }
    func upsert(_ m: TeamMember) { if let i = team.firstIndex(where: { $0.id == m.id }) { team[i] = m } else { team.append(m) } }
    func deleteMember(_ m: TeamMember) {
        team.removeAll { $0.id == m.id }
        // unassign any leads that pointed at the removed member (never leave a dangling owner)
        for i in leads.indices where leads[i].assignedTo == m.id { leads[i].assignedTo = nil }
    }
    func leadCount(assignedTo id: UUID) -> Int { leads.filter { $0.assignedTo == id }.count }

    // Cash buyers CRUD (dispositions)
    func upsert(_ b: CashBuyer) {
        if let i = buyers.firstIndex(where: { $0.id == b.id }) { buyers[i] = b } else { buyers.insert(b, at: 0) }
    }
    func deleteBuyer(_ b: CashBuyer) { buyers.removeAll { $0.id == b.id } }

    // Offers / LOI CRUD
    func upsert(_ o: Offer) {
        if let i = offers.firstIndex(where: { $0.id == o.id }) { offers[i] = o } else { offers.insert(o, at: 0) }
    }
    func deleteOffer(_ o: Offer) { offers.removeAll { $0.id == o.id } }
    func offers(for dealID: UUID) -> [Offer] { offers.filter { $0.dealID == dealID } }

    /// Unified, chronological activity timeline for a lead. Merges the lead's own append-only
    /// `activity` events with DERIVED events that live elsewhere — follow-up tasks (added/done)
    /// and any direct-mail touches already dropped via enrollments — into one sorted story.
    /// Pure read; fabricates nothing (every entry traces to a real record).
    func timeline(for lead: Lead) -> [ActivityEvent] {
        var events = lead.activity
        // a `created` anchor even for legacy leads saved before the timeline existed
        if !events.contains(where: { $0.kind == .created }) {
            events.append(ActivityEvent(kind: .created, detail: "Lead created", at: lead.created))
        }
        // Tasks stay task-only. Completing "Call owner" must not read like a logged call.
        for t in lead.tasks {
            events.append(ActivityEvent(kind: .task, detail: "Task: \(t.text)", at: t.created))
            if t.done {
                events.append(ActivityEvent(kind: .taskDone,
                                            detail: "Task completed: \(t.text)",
                                            at: t.completedAt ?? t.created))
            }
        }
        // completed direct-mail touches for this lead (real drops the user marked done)
        for e in enrollments where e.leadID == lead.id {
            guard let seq = sequence(e.sequenceID) else { continue }
            for piece in MailMerge.schedule(e, sequence: seq, lead: lead) where piece.done {
                events.append(ActivityEvent(kind: .mail, detail: "Mail sent: \(piece.kind.label) (\(seq.name))", at: piece.dropDate))
            }
        }
        return events.sorted { $0.at > $1.at }   // newest first
    }

    /// Promote a lead with a resolved property + value into a deal (real, no fabrication).
    /// For a TEARDOWN lead the value driver is the LAND (the structure gets scraped), so the
    /// assessor LAND value seeds ARV when present — the honest post-scrape lot value, labelled as
    /// such. Every figure traces to a real assessor field; nothing is estimated.
    func dealFromLead(_ l: Lead) -> Deal {
        var d = Deal()
        d.address = l.propertyAddress.isEmpty ? l.name : l.propertyAddress
        d.county = l.county
        d.parcel = l.parcel             // carry the resolved parcel id so comps can pull its sales roll
        if l.source == .teardown, l.landValue > 0 {
            d.arv = Double(l.landValue); d.arvSource = "Assessor land value (teardown / lot ARV)"
        } else if l.assessedValue > 0 {
            d.arv = Double(l.assessedValue); d.arvSource = "County-assessed (parcel)"
        }
        d.notes = "From lead: \(l.name)\(l.ownerName.isEmpty ? "" : " · owner \(l.ownerName)")"
        return d
    }

    // NOTE: No sample/seed/demo data is bundled. The app ships empty and only ever
    // contains the end user's own deals/leads/drafts, entered at runtime or pulled
    // live from open data (OpenStreetMap) and pasted public notices. App Store
    // Guideline + ship-no-data rule: zero baked-in records.

    // Portfolio rollups (real, computed from saved data)
    var activeDeals: [Deal] { deals.filter { $0.status != .lost } }
    var pipelineProfit: Double { activeDeals.reduce(0) { $0 + $1.projectedProfit } }
    func count(_ s: DealStatus) -> Int { deals.filter { $0.status == s }.count }
    func leadCount(_ s: LeadStatus) -> Int { leads.filter { $0.status == s }.count }
    func leadCount(source s: LeadSource) -> Int { leads.filter { $0.source == s }.count }

    // Market analytics (all real, from saved deals)
    var avgARV: Double { let a = deals.filter { $0.arv > 0 }; return a.isEmpty ? 0 : a.reduce(0) { $0 + $1.arv } / Double(a.count) }
    var avgRehab: Double { let a = deals.filter { $0.repairsEffective > 0 }; return a.isEmpty ? 0 : a.reduce(0) { $0 + $1.repairsEffective } / Double(a.count) }
    var wonCount: Int { count(.won) }
    var closeRate: Double { deals.isEmpty ? 0 : Double(wonCount) / Double(deals.count) * 100 }
    var totalEquityAtMAO: Double { activeDeals.reduce(0) { $0 + $1.equityAtMAO } }
    /// County → number of leads, descending. Real distribution for the analytics dashboard.
    var leadsByCounty: [(String, Int)] {
        Dictionary(grouping: leads.filter { !$0.county.isEmpty }, by: { $0.county })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
    }
    var leadsBySource: [(LeadSource, Int)] {
        LeadSource.allCases.map { s in (s, leadCount(source: s)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Real estate math
enum REMath {
    static func monthlyPI(principal: Double, apr: Double, years: Double) -> Double {
        let n = years * 12; guard principal > 0, n > 0 else { return 0 }
        let r = apr / 100 / 12
        return r == 0 ? principal / n : principal * (r * pow(1 + r, n)) / (pow(1 + r, n) - 1)
    }
    static func capRate(noi: Double, price: Double) -> Double { price > 0 ? noi / price * 100 : 0 }
    static func cashOnCash(annualCashFlow: Double, cashInvested: Double) -> Double {
        cashInvested > 0 ? annualCashFlow / cashInvested * 100 : 0
    }
    static func money(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "$0"
    }
    static func pct(_ v: Double) -> String { String(format: "%.1f%%", v) }

    /// Parse decedents + counties from pasted public-notice text (real regex).
    static func parseProbate(_ text: String) -> [Lead] {
        var out: [Lead] = []; var seen = Set<String>()
        let namePats = [
            #"(?i)estate of\s+([A-Z][A-Za-z.'\-]+(?:\s+[A-Z][A-Za-z.'\-]+){1,3})"#,
            #"([A-Z][A-Za-z.'\-]+(?:\s+[A-Z][A-Za-z.'\-]+){1,3})\s*,?\s+(?i:deceased|dec'd|late of)"#
        ]
        let countyRe = try? NSRegularExpression(pattern: #"(?i)([A-Z][a-z]+)\s+County"#)
        for line in text.components(separatedBy: .newlines) {
            let rng = NSRange(line.startIndex..., in: line)
            var county = ""
            if let m = countyRe?.firstMatch(in: line, range: rng), let r = Range(m.range(at: 1), in: line) {
                county = String(line[r]).capitalized
            }
            for pat in namePats {
                guard let re = try? NSRegularExpression(pattern: pat) else { continue }
                for m in re.matches(in: line, range: rng) {
                    if let r = Range(m.range(at: 1), in: line) {
                        let name = String(line[r]).trimmingCharacters(in: .whitespaces)
                        let key = name.lowercased()
                        if name.count > 4, !seen.contains(key) {
                            seen.insert(key)
                            out.append(Lead(name: name, county: county, source: .probate, sourceDetail: "Probate notice"))
                        }
                    }
                }
            }
        }
        return out
    }
}
#endif // circuit-convert

// MARK: - Area lead discovery BY AREA (real OpenStreetMap Overpass API — free, keyless, open data, no SDK)
// Honest: owner records aren't in any free API, so this finds the real, probate-relevant BUSINESSES in a
// market — estate agents, probate attorneys, property managers, notaries, estate-sale/auction houses —
// the warm sources investors actually work to source distressed/probate deals. Returns real listings only.
struct REMetro: Identifiable, Hashable {
    let id = UUID(); let city: String; let state: String; let lat: Double; let lon: Double
    var label: String { "\(city), \(state)" }
}
enum REMarkets {
    static let all: [REMetro] = [
        .init(city: "Atlanta", state: "GA", lat: 33.7490, lon: -84.3880), .init(city: "New York", state: "NY", lat: 40.7128, lon: -74.0060),
        .init(city: "Los Angeles", state: "CA", lat: 34.0522, lon: -118.2437), .init(city: "Chicago", state: "IL", lat: 41.8781, lon: -87.6298),
        .init(city: "Houston", state: "TX", lat: 29.7604, lon: -95.3698), .init(city: "Phoenix", state: "AZ", lat: 33.4484, lon: -112.0740),
        .init(city: "Dallas", state: "TX", lat: 32.7767, lon: -96.7970), .init(city: "Miami", state: "FL", lat: 25.7617, lon: -80.1918),
        .init(city: "Tampa", state: "FL", lat: 27.9506, lon: -82.4572), .init(city: "Charlotte", state: "NC", lat: 35.2271, lon: -80.8431),
        .init(city: "Nashville", state: "TN", lat: 36.1627, lon: -86.7816), .init(city: "Austin", state: "TX", lat: 30.2672, lon: -97.7431),
        .init(city: "Denver", state: "CO", lat: 39.7392, lon: -104.9903), .init(city: "Las Vegas", state: "NV", lat: 36.1699, lon: -115.1398),
        .init(city: "Jacksonville", state: "FL", lat: 30.3322, lon: -81.6557), .init(city: "Columbus", state: "OH", lat: 39.9612, lon: -82.9988),
        .init(city: "Indianapolis", state: "IN", lat: 39.7684, lon: -86.1581), .init(city: "San Antonio", state: "TX", lat: 29.4241, lon: -98.4936),
        .init(city: "Orlando", state: "FL", lat: 28.5383, lon: -81.3792), .init(city: "Kansas City", state: "MO", lat: 39.0997, lon: -94.5786),
        .init(city: "Memphis", state: "TN", lat: 35.1495, lon: -90.0490), .init(city: "Birmingham", state: "AL", lat: 33.5186, lon: -86.8104)
    ]
}
enum REVertical: String, CaseIterable, Identifiable {
    case estateAgents = "Estate / real-estate agents", probateAttorneys = "Probate attorneys"
    case propertyMgmt = "Property managers", auctions = "Estate-sale / auction"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .estateAgents: return "house.fill"; case .probateAttorneys: return "building.columns.fill"
        case .propertyMgmt: return "key.fill"; case .auctions: return "hammer.fill"
        }
    }
    var filters: [String] {
        switch self {
        case .estateAgents:    return ["node[\"office\"=\"estate_agent\"]", "node[\"shop\"=\"estate_agent\"]"]
        case .probateAttorneys: return ["node[\"office\"=\"lawyer\"]"]
        case .propertyMgmt:    return ["node[\"office\"=\"property_management\"]", "node[\"office\"=\"estate_agent\"]"]
        case .auctions:        return ["node[\"shop\"=\"auction_house\"]", "node[\"amenity\"=\"auction_house\"]"]
        }
    }
}
struct AreaResult: Identifiable, Hashable {
    let id = UUID(); var name: String; var phone: String; var website: String; var address: String; var vertical: REVertical
    /// Clean domain from the listed website (empty if none).
    var domain: String {
        var d = website.lowercased().trimmingCharacters(in: .whitespaces)
        for p in ["https://", "http://", "www."] { d = d.replacingOccurrences(of: p, with: "") }
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        return d
    }
}
enum AreaFinderError: LocalizedError {
    case badResponse, http(Int), noResults, network(String)
    var errorDescription: String? {
        switch self {
        case .badResponse: return "The source returned data we couldn't read. Please try again."
        case .http(let c): return "The source is busy (HTTP \(c)). Wait a moment and try again."
        case .noResults:   return "No listed \("businesses") found for that area. Try a nearby major metro."
        case .network(let m): return m
        }
    }
}
enum AreaFinder {
    static func query(vertical: REVertical, metro: REMetro) -> String {
        let d = 0.18
        let bbox = String(format: "(%.4f,%.4f,%.4f,%.4f)", metro.lat - d, metro.lon - d, metro.lat + d, metro.lon + d)
        let body = vertical.filters.map { "  \($0)\(bbox);" }.joined(separator: "\n")
        return "[out:json][timeout:25];\n(\n\(body)\n);\nout body 80;"
    }
    static func search(vertical: REVertical, metro: REMetro) async throws -> [AreaResult] {
        let ql = query(vertical: vertical, metro: metro)
        var req = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("BlackLabelRealEstate/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.httpBody = "data=\(ql.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ql)".data(using: .utf8)
        req.timeoutInterval = 30
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw AreaFinderError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw AreaFinderError.badResponse }
        guard http.statusCode == 200 else { throw AreaFinderError.http(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { throw AreaFinderError.badResponse }
        var seen = Set<String>(); var out: [AreaResult] = []
        for el in elements {
            guard let tags = el["tags"] as? [String: Any],
                  let name = (tags["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let website = ((tags["website"] as? String) ?? (tags["contact:website"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let phone = ((tags["phone"] as? String) ?? (tags["contact:phone"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let street = [tags["addr:housenumber"] as? String, tags["addr:street"] as? String].compactMap { $0 }.joined(separator: " ")
            let address = [street, (tags["addr:city"] as? String) ?? metro.city].filter { !$0.isEmpty }.joined(separator: ", ")
            let key = name.lowercased()
            if seen.contains(key) { continue }; seen.insert(key)
            out.append(AreaResult(name: name, phone: phone, website: website, address: address, vertical: vertical))
        }
        guard !out.isEmpty else { throw AreaFinderError.noResults }
        out.sort { (($0.phone.isEmpty ? 0:1) + ($0.website.isEmpty ?0:1)) > (($1.phone.isEmpty ?0:1) + ($1.website.isEmpty ?0:1)) }
        return out
    }
}
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    /// Save a discovered area business as a probate-source lead.
    func saveArea(_ r: AreaResult, metro: REMetro) {
        let note = [r.address, r.website].filter { !$0.isEmpty }.joined(separator: " · ")
        var l = Lead(name: r.name, county: metro.city, source: .areaBusiness, sourceDetail: r.vertical.rawValue,
                     phone: r.phone, notes: note)
        l.propertyAddress = r.address
        addLeads([l])
    }
}
#endif // circuit-convert

// MARK: - Local accounts (on-device, App Store 5.1.1(v) deletion supported)
enum AuthError: String, Error {
    case badEmail = "Enter a valid email address."
    case weakPw = "Password must be at least 6 characters."
    case exists = "An account with that email already exists — sign in instead."
    case noAccount = "No account found for that email — create one first."
    case wrongPw = "Incorrect password. Try again."
}
enum AccountStore {
    static let key = "blre.accounts"
    static func load() -> [String: String] { (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }
    static func save(_ d: [String: String]) { UserDefaults.standard.set(d, forKey: key) }
    static func hash(_ e: String, _ p: String) -> String {
        SHA256.hash(data: Data((e.lowercased() + "::" + p).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func create(_ email: String, _ pw: String) -> Result<Void, AuthError> {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard e.contains("@"), e.contains(".") else { return .failure(.badEmail) }
        guard pw.count >= 6 else { return .failure(.weakPw) }
        var a = load(); if a[e] != nil { return .failure(.exists) }
        a[e] = hash(e, pw); save(a); return .success(())
    }
    static func signIn(_ email: String, _ pw: String) -> Result<Void, AuthError> {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased(); let a = load()
        guard let h = a[e] else { return .failure(.noAccount) }
        return h == hash(e, pw) ? .success(()) : .failure(.wrongPw)
    }
    static func delete(_ email: String) { var a = load(); a[email.trimmingCharacters(in: .whitespaces).lowercased()] = nil; save(a) }
}

// MARK: - Remembered session ("Remember me" — private local persistence, never bundled)
// A small token holding ONLY the user's own email + issue/expiry timestamps, stored in the private
// prompt-free Application Support store (never written into the app bundle — §5.2 ship-no-data
// holds: nothing here ships, it is created on THIS device at sign-in). On a cold start
// the app restores a non-expired token so the user isn't re-authing every launch; an expired token
// is cleared and the user is told honestly. Remember Me defaults on and states its 30-day lifetime.
struct RememberedSession: Codable {
    var email: String
    var issued: Date
    var expires: Date
    var isValid: Bool { expires > Date() && !email.isEmpty }
}

enum SessionStoreError: LocalizedError {
    case storage(SecretStoreError)
    case encode
    case corrupt

    var errorDescription: String? {
        switch self {
        case .storage(let error): return error.localizedDescription
        case .encode: return "The remembered session could not be encoded."
        case .corrupt: return "The remembered session is unreadable and was preserved unchanged."
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum SessionStore {
    static let account = "blre.session.remembered"
    /// How long a remembered session stays valid. Re-auth required after this — honest, bounded.
    static let lifetime: TimeInterval = 60 * 60 * 24 * 30   // 30 days

    @discardableResult
    static func remember(email: String, now: Date = Date(),
                         store: RealEstateSecretStore? = nil) -> Result<Void, SessionStoreError> {
        let tok = RememberedSession(email: email, issued: now, expires: now.addingTimeInterval(lifetime))
        guard let d = try? JSONEncoder().encode(tok), let s = String(data: d, encoding: .utf8) else {
            return .failure(.encode)
        }
        let result = store?.set(s, account: account) ?? Keychain.set(s, account: account)
        return result.mapError(SessionStoreError.storage)
    }
    /// The stored token, if any (valid OR expired — caller decides). nil = nothing remembered.
    static func storedResult(store: RealEstateSecretStore? = nil) -> Result<RememberedSession?, SessionStoreError> {
        let result = store?.value(account: account) ?? Keychain.getResult(account: account)
        switch result {
        case .failure(let error): return .failure(.storage(error))
        case .success(nil): return .success(nil)
        case .success(let value):
            guard let value, let data = value.data(using: .utf8),
                  let token = try? JSONDecoder().decode(RememberedSession.self, from: data) else {
                return .failure(.corrupt)
            }
            return .success(token)
        }
    }
    static func stored() -> RememberedSession? {
        guard case .success(let token) = storedResult() else { return nil }
        return token
    }
    @discardableResult
    static func clear(store: RealEstateSecretStore? = nil) -> Result<Void, SessionStoreError> {
        let result = store?.delete(account: account) ?? Keychain.delete(account: account)
        return result.mapError(SessionStoreError.storage)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
final class Session: ObservableObject {
    @Published var signedIn = false
    @Published var email = ""
    /// True when the user entered via "Explore with sample data" (the no-account reviewer path).
    /// Drives the persistent SAMPLE-DATA banner and the in-memory-only demo dataset. Never set for
    /// a real sign-in, so real accounts always start empty on the buyer's own data.
    @Published var demoMode = false
    /// Set on launch when a remembered session was found but had EXPIRED — drives an honest one-line
    /// "your saved session expired, please sign in again" note on the auth screen (never a silent fail).
    @Published var expiredNotice = false
    /// Honest storage failure surfaced on the auth screen. It contains no credential value.
    @Published var storageNotice: String? = nil

    /// Try to restore a remembered ("Remember me") session at cold start. Returns true and signs the
    /// user in when a non-expired token exists; clears + flags an expired one; no-ops otherwise.
    /// Never auto-restores demo/guest — only a real remembered email.
    @discardableResult
    func restoreRemembered() -> Bool {
        let token: RememberedSession?
        switch SessionStore.storedResult() {
        case .success(let stored): token = stored
        case .failure(let error): storageNotice = error.localizedDescription; return false
        }
        guard let tok = token else { return false }
        guard tok.isValid else {
            if case .failure(let error) = SessionStore.clear() { storageNotice = error.localizedDescription }
            expiredNotice = true
            return false
        }
        email = tok.email
        demoMode = false
        signedIn = true
        return true
    }

    /// Off-main-thread session restore. The prompt-free file read is normally immediate, but keeping
    /// disk I/O off the initial SwiftUI layout preserves the invisible-window regression fix.
    func restoreRememberedAsync() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SessionStore.storedResult()
            DispatchQueue.main.async {
                guard !self.signedIn else { return }
                let tok: RememberedSession?
                switch result {
                case .success(let stored): tok = stored
                case .failure(let error): self.storageNotice = error.localizedDescription; return
                }
                guard let tok else { return }
                guard tok.isValid else {
                    if case .failure(let error) = SessionStore.clear() {
                        self.storageNotice = error.localizedDescription
                    }
                    self.expiredNotice = true
                    return
                }
                self.email = tok.email
                self.demoMode = false
                withAnimation { self.signedIn = true }
            }
        }
    }

    /// Sign out and forget any remembered session (so a deliberate sign-out doesn't auto-restore).
    func signOut() {
        if case .failure(let error) = SessionStore.clear() { storageNotice = error.localizedDescription }
        email = ""; demoMode = false; signedIn = false
    }
}
#endif // circuit-convert
