// Black Label Real Estate — HEURISTIC LEAD / MOTIVATION SCORING.
//
// A real, transparent motivation score computed ENTIRELY from signals the buyer already owns on
// each lead — no paid provider, no AI black box, no fabricated inputs. Every point is explained:
// the score returns its own breakdown so the buyer sees exactly WHY a lead ranks where it does
// (the thing PropStream/BatchLeads charge for and never show their work on). Where a signal needs
// data the free tier can't see (true equity %, real DOM), the factor is honestly omitted — it
// never invents a value to inflate a score.
//
// Signals (all derived from Lead fields the app captures for free):
//   • Distress source weight — probate / pre-foreclosure / tax-delinquent / code-violation are
//     the warmest motivated-seller lists; manual/area are coldest.
//   • Absentee owner — mailing address ≠ situs (the classic "out-of-area, easier to sell" tell).
//   • Free-and-clear / high-equity proxy — high assessed value with the absentee tell (no published
//     mortgage balance for free, so this is labeled a PROXY, never claimed as true equity %).
//   • Reachability — a resolved mailing address (mailable today) and/or phone/email on file.
//   • Ownership confidence — a high-confidence parcel match means the address is trustworthy.
//   • Stacking / engagement — already worked (open tasks, contacted) nudges priority.
import Foundation

// MARK: - One scored factor (name, points awarded, max possible, an honest explanation).
struct ScoreFactor: Hashable, Identifiable {
    var id: String { name }
    let name: String
    let points: Int
    let max: Int
    let detail: String          // why these points (or why 0 / why omitted)
    var hit: Bool { points > 0 }
}

// MARK: - The full motivation score for one lead.
struct LeadScore: Hashable {
    var total: Int              // 0…100
    var factors: [ScoreFactor]
    /// Tier label + color key the UI maps to a pill.
    var tier: ScoreTier { ScoreTier.from(total) }
    /// Highest-value missing signal the buyer could close to raise the score (actionable).
    var nextBestAction: String
}

enum ScoreTier: String, Hashable {
    case hot, warm, cool, cold
    static func from(_ s: Int) -> ScoreTier {
        switch s { case 75...: return .hot; case 50..<75: return .warm; case 25..<50: return .cool; default: return .cold }
    }
    var label: String { switch self { case .hot: return "Hot"; case .warm: return "Warm"; case .cool: return "Cool"; case .cold: return "Cold" } }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum LeadScoring {
    // Per-source distress weight (max 35). Probate is the product's warmest native list.
    static func sourceWeight(_ s: LeadSource) -> (Int, String) {
        switch s {
        case .probate:        return (35, "Probate / inherited — the warmest motivated-seller signal.")
        case .preForeclosure: return (33, "Pre-foreclosure — owner in default, strong urgency.")
        case .taxDelinquent:  return (28, "Tax-delinquent — financial pressure to sell.")
        case .codeViolation:  return (24, "Code violation — carrying-cost / compliance pressure.")
        case .absentee:       return (20, "Absentee owner — out-of-area, lower attachment.")
        case .teardown:       return (26, "Teardown / lot-flip — structure adds little vs the land, strong builder-disposition signal.")
        case .builder:        return (10, "Builder / new-construction — a sourcing relationship, not a distressed seller.")
        case .areaBusiness:   return (6,  "Area source — a referral contact, not a property owner.")
        case .manual:         return (8,  "Manually added — no distress signal inferred.")
        // Database leads inherit their real signal from the list category when known;
        // the base weight stays neutral (the category chip, not the source, is the signal).
        // This base only applies when the category is absent or has no equivalent —
        // `databaseCategoryWeight` below is what actually makes that sentence true.
        case .database:       return (14, "Public-records database lead — no list category recorded, so only the base public-records weight applies.")
        }
    }

    /// Distress weight for a public-records lead, read from the SERVER CATEGORY the list actually
    /// queried (`Lead.dbCategory` — the whitelisted predicate name, e.g. "estate_owner", not a UI
    /// label). Fixed 2026-08-03: every index-saved lead is forced to `.source = .database`
    /// (DatabaseListEngine.lead(from:)), so before this the whole database corpus scored a flat 14
    /// and a probate parcel could never out-rank an area referral — the comment above promised a
    /// rise that no code performed, and 60/100 was a database lead's arithmetic ceiling (below the
    /// 75 `.hot` threshold).
    ///
    /// Every weight here is an EXISTING `LeadSource` weight reused for the equivalent signal — no
    /// new number is invented for a category, and a category with no honest equivalent returns nil
    /// so the neutral base stands rather than a made-up figure. Categories are the ones the Worker
    /// whitelists (`DatabaseListType.apiCategory` + `LotFlipScout.LotSignal.apiCategory`); free-text
    /// map filters and future server categories fall through to nil by design.
    static func databaseCategoryWeight(_ category: String?) -> (Int, String)? {
        guard let raw = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "estate_owner":
            // Estate-style recorded owner (ESTATE OF / EXECUTOR / HEIRS) straight off the county
            // roll — the same signal `.probate` scores, asserted by the county, not by us.
            return (sourceWeight(.probate).0, "Estate-style recorded owner on the county roll — the public-records probate signal.")
        case "teardown":
            return (sourceWeight(.teardown).0, "Assessor's own improvement-to-land split flags a teardown — structure adds little vs the dirt.")
        case "absentee":
            return (sourceWeight(.absentee).0, "County record shows the owner mails elsewhere than the property — absentee.")
        case "absentee_long_hold":
            // Absentee is the scoreable half. The long-hold half is a TENURE proxy with no
            // LeadSource equivalent, so it adds nothing here rather than an invented bonus.
            return (sourceWeight(.absentee).0, "County record shows an absentee owner (the long-tenure half is a proxy and is not scored here).")
        case "entity_owner":
            // The cash-buyer list. A corporate owner is a DISPOSITION relationship, not a
            // motivated seller — scored like `.builder`, and deliberately BELOW the neutral base.
            return (sourceWeight(.builder).0, "Entity/corporate owner — a cash-buyer disposition contact, not a distressed seller.")
        default:
            // "value_spread", "vacant_land", "long_hold" and anything the server adds later are
            // real published signals but NOT owner-distress tells, and none maps to an existing
            // LeadSource weight. They keep the neutral base instead of a fabricated one.
            return nil
        }
    }

    /// Score ONE lead from its own captured fields. Pure, deterministic, explainable.
    static func score(_ l: Lead) -> LeadScore {
        var factors: [ScoreFactor] = []

        // 1) Distress source weight (max 35). A public-records lead is scored on the list category
        //    it was actually saved from; every other source is the source itself.
        let (sw, sd) = (l.source == .database ? databaseCategoryWeight(l.dbCategory) : nil) ?? sourceWeight(l.source)
        factors.append(ScoreFactor(name: "Distress source", points: sw, max: 35, detail: sd))

        // 2) Absentee owner (max 18) — canonical data-derived tell (mailing ≠ situs, both present).
        let mail = ListEngine.norm(l.mailingAddress)   // kept for the "no mailing yet" detail message
        let absentee = l.isAbsentee
        factors.append(ScoreFactor(
            name: "Absentee owner", points: absentee ? 18 : 0, max: 18,
            detail: absentee ? "Owner mails elsewhere than the property — classic absentee tell."
                : (mail.isEmpty ? "No owner-mailing address yet — run skip trace to check absentee." : "Owner-occupied (mailing = property).")))

        // 3) Equity / value PROXY (max 15) — high assessed value (true equity % needs a gated feed)
        let v = l.assessedValue
        let vp = v >= 350_000 ? 15 : v >= 200_000 ? 11 : v >= 100_000 ? 7 : v > 0 ? 3 : 0
        factors.append(ScoreFactor(
            name: "Equity proxy (value)", points: vp, max: 15,
            detail: v > 0 ? "Assessed \(REMath.money(Double(v))) — value proxy (true equity % needs a mortgage feed; not faked)."
                : "No assessed value yet — resolve the parcel to score equity proxy."))

        // 4) Reachability (max 20): mailable (8) + phone (7) + email (5)
        var reach = 0; var rdet: [String] = []
        if !l.mailingAddress.isEmpty { reach += 8; rdet.append("mailable") }
        if !l.phone.isEmpty { reach += 7; rdet.append("phone") }
        if !l.email.isEmpty { reach += 5; rdet.append("email") }
        factors.append(ScoreFactor(
            name: "Reachability", points: reach, max: 20,
            detail: reach > 0 ? "On file: \(rdet.joined(separator: ", "))." : "No contact on file — skip trace to reach this owner."))

        // 5) Ownership confidence (max 7) — trust the resolved parcel/address
        let conf = l.ownershipConfidence.lowercased()
        let cp = conf == "high" ? 7 : conf == "medium" ? 4 : conf == "low" ? 1 : 0
        // A 0 here means the confidence is ABSENT, not that a match was attempted and failed —
        // so a public-records lead whose county row was too thin to cite says exactly that
        // rather than accusing the county row of being unmatched (§5.1).
        factors.append(ScoreFactor(
            name: "Ownership confidence", points: cp, max: 7,
            detail: cp > 0 ? "Parcel match confidence: \(conf)."
                : (l.isDatabaseLead ? "This county row did not publish enough to cite a parcel match — no confidence claimed."
                                    : "Owner not yet parcel-matched.")))

        // 6) Engagement (max 5) — already being worked = momentum
        let working = l.openTasks > 0 || l.status == .contacted || l.status == .appointment || l.status == .negotiating
        factors.append(ScoreFactor(
            name: "Engagement", points: working ? 5 : 0, max: 5,
            detail: working ? "Already in motion (open tasks / past first contact)." : "Not worked yet."))

        let total = min(100, factors.reduce(0) { $0 + $1.points })

        // Next-best-action: the biggest gap the buyer can actually close.
        let gaps = factors.filter { $0.points < $0.max }.sorted { ($0.max - $0.points) > ($1.max - $1.points) }
        let nba: String
        if let g = gaps.first(where: { $0.name == "Reachability" && $0.points < 8 }) { _ = g; nba = "Skip trace to add contact info (+\(20 - reach) reachability)." }
        else if vp == 0 && l.assessedValue == 0 { nba = "Resolve the parcel to set assessed value." }
        else if !absentee && mail.isEmpty { nba = "Run skip trace to confirm absentee status." }
        else if let g = gaps.first { nba = "Improve \(g.name.lowercased()) (+\(g.max - g.points) possible)." }
        else { nba = "Fully scored — work this lead." }

        return LeadScore(total: total, factors: factors, nextBestAction: nba)
    }

    /// Score + rank a whole set (descending). The motivated-seller work queue.
    static func rank(_ leads: [Lead]) -> [(Lead, LeadScore)] {
        leads.map { ($0, score($0)) }.sorted { $0.1.total > $1.1.total }
    }

    /// Distribution by tier for an analytics rollup (real counts).
    static func tierCounts(_ leads: [Lead]) -> [(ScoreTier, Int)] {
        var m: [ScoreTier: Int] = [:]
        for l in leads { m[score(l).tier, default: 0] += 1 }
        return [.hot, .warm, .cool, .cold].map { ($0, m[$0] ?? 0) }
    }
}
#endif // circuit-convert
