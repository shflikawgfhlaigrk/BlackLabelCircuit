// Black Label Real Estate — DEAL SCORECARD (the "should I buy this?" verdict).
//
// Every deal calculator already computes the pieces — ARV, MAO, all-in cost, flip profit/ROI,
// cap rate, cash-on-cash. What no screen did was SYNTHESIZE them into one trustworthy verdict.
// This engine does, the way an investor actually judges a deal, and it SHOWS ITS WORK:
//   • GO / CAUTION / PASS / NEEDS-INPUT, with a 0–100 score and a per-factor breakdown (points,
//     max, and an honest one-line reason for each — the thing PropStream/DealMachine never show).
//   • Exit-aware: a flip is judged on margin + ROI, a rental on cash flow + cap + cash-on-cash, a
//     wholesale on the assignable spread — never one-size-fits-all.
//
// HONEST BY CONSTRUCTION (CHARTER §5.1): every input is the buyer's OWN number or a value the app
// pulled from real public records. It NEVER invents an ARV, comp, rent, or cost. Two hard rails
// keep the verdict from over-claiming:
//   1. NEEDS-INPUT gate — no ARV (or, for a rental, no rent) ⇒ it returns `.incomplete` and tells
//      the buyer what to add, instead of printing a confident verdict on a missing anchor.
//   2. ARV-confidence cap — when ARV is only a LABELED ESTIMATE (county-assessed / area read, "not
//      sold comps") a GO is downgraded to CAUTION. A confident GO is never printed on an unverified
//      after-repair value. Sold-comp ARV is uncapped; a user's own figure is flagged, not capped.
//
// Pure Foundation so it is unit-testable offline: feed a Deal + MAO% straight into `DealScoring.score`.
// `ScoreFactor` is shared with LeadScoring (same explainable-breakdown shape).
import Foundation

// MARK: - Verdict

/// The one-glance answer an investor actually wants.
enum DealVerdict: String, Hashable {
    case go, caution, pass, incomplete

    var label: String {
        switch self {
        case .go:         return "GO"
        case .caution:    return "CAUTION"
        case .pass:       return "PASS"
        case .incomplete: return "NEEDS INPUT"
        }
    }
    var title: String {
        switch self {
        case .go:         return "This deal pencils"
        case .caution:    return "Pencils — with caveats"
        case .pass:       return "Doesn't pencil"
        case .incomplete: return "Not enough to judge yet"
        }
    }
    var icon: String {
        switch self {
        case .go:         return "checkmark.seal.fill"
        case .caution:    return "exclamationmark.triangle.fill"
        case .pass:       return "xmark.seal.fill"
        case .incomplete: return "questionmark.circle.fill"
        }
    }
}

// MARK: - ARV provenance (drives the honesty cap)

/// How trustworthy the ARV anchoring the whole score is — read from the deal's honest `arvSource`
/// label (set by the comps engine or typed by the buyer). Only a labeled *estimate* caps the verdict.
enum ARVConfidence: String, Hashable {
    case soldComps      // real recorded arm's-length sales — the strongest basis (uncapped)
    case estimate       // labeled county-assessed / area estimate — explicitly NOT sold comps (caps GO→CAUTION)
    case userEntered    // the buyer's own figure — flagged, not capped
    case none           // no ARV at all — the deal can't be scored

    /// True when this basis must not be allowed to print a confident GO.
    var capsVerdict: Bool { self == .estimate }

    var short: String {
        switch self {
        case .soldComps:   return "sold comps"
        case .estimate:    return "assessed estimate"
        case .userEntered: return "your estimate"
        case .none:        return "no ARV"
        }
    }
}

// MARK: - Result

struct DealScore: Hashable {
    var verdict: DealVerdict
    var score: Int                 // 0…100 (0 when incomplete)
    var factors: [ScoreFactor]     // the transparent breakdown (shared shape with LeadScoring)
    var arvConfidence: ARVConfidence
    var headline: String           // one-line verdict summary with the key number
    var reason: String             // the primary driver of the verdict
    var topRisk: String            // the single biggest concern ("" when nothing material)
    var keyMetricLabel: String     // exit-specific headline metric (label)
    var keyMetricValue: String     // exit-specific headline metric (value)
    var capped: Bool               // true when an estimate-only ARV held the verdict below GO
}

// MARK: - Engine

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum DealScoring {
    // Verdict thresholds on the 0–100 score.
    static let goThreshold = 70
    static let cautionThreshold = 45

    // Factor weights (sum = 100): the return is the crux, MAO discipline protects the buy box,
    // rehab is the execution risk, ARV confidence is how much to trust the anchor.
    static let maxReturn = 45
    static let maxMAO = 25
    static let maxRehab = 15
    static let maxARV = 15

    private static func money(_ v: Double) -> String { REMath.money(v) }
    private static func pct(_ v: Double) -> String { REMath.pct(v) }

    /// Read ARV trust from the deal's honest `arvSource` label (case-insensitive substrings the
    /// comps engine actually emits). Never guesses beyond what the label says.
    static func arvConfidence(_ deal: Deal) -> ARVConfidence {
        guard deal.arv > 0 else { return .none }
        let s = deal.arvSource.lowercased()
        // Estimate markers are checked FIRST on purpose: the app's estimate labels literally read
        // "(not sold comps)", which CONTAINS the substring "sold comp" — a naive sold-comp check
        // would misclassify a labeled estimate as verified comps and wrongly hand it a GO.
        if s.contains("assessed") || s.contains("estimate") || s.contains("area read") || s.contains("avm") {
            return .estimate
        }
        if s.contains("sold comp") || s.contains("comps") { return .soldComps }
        return .userEntered
    }

    /// Score a deal. Pure + deterministic. `maoPct` mirrors Settings → Radius & valuation (default 70).
    static func score(_ deal: Deal, maoPct: Double = 70) -> DealScore {
        let conf = arvConfidence(deal)

        // ---- NEEDS-INPUT gates: never a fake verdict on a missing anchor ----
        if deal.arv <= 0 {
            return incomplete(deal, conf,
                reason: "Enter or pull an ARV — the after-repair value anchors every number here.")
        }
        if deal.exit == .rental && deal.monthlyRent <= 0 {
            return incomplete(deal, conf,
                reason: "Enter the monthly rent to judge this buy-and-hold.")
        }
        if deal.exit == .wholesale && deal.assignmentFee <= 0 {
            return incomplete(deal, conf,
                reason: "Enter your assignment fee (your spread) to judge the wholesale.")
        }

        // ---- Factors ----
        let (retPts, retDetail, retZero) = returnFactor(deal)
        let factors: [ScoreFactor] = [
            ScoreFactor(name: "Return", points: retPts, max: maxReturn, detail: retDetail),
            maoFactor(deal, maoPct: maoPct),
            rehabFactor(deal),
            arvFactor(deal, conf: conf),
        ]

        let raw = factors.reduce(0) { $0 + $1.points }
        let score = max(0, min(100, raw))

        // ---- Verdict from score, with a hard PASS when the deal loses money / bleeds ----
        var verdict: DealVerdict
        if retZero { verdict = .pass }
        else if score >= goThreshold { verdict = .go }
        else if score >= cautionThreshold { verdict = .caution }
        else { verdict = .pass }

        // Honesty cap: a labeled estimate ARV can never earn a confident GO.
        var capped = false
        if verdict == .go && conf.capsVerdict { verdict = .caution; capped = true }

        // ---- Exit-specific headline metric ----
        let (kLabel, kValue) = keyMetric(deal)

        // ---- topRisk = the biggest material gap (return shortfalls count too) ----
        let gaps = factors.filter { $0.points < $0.max }
            .sorted { ($0.max - $0.points) > ($1.max - $1.points) }
        let topRisk = gaps.first.map { "\($0.name): \($0.detail)" } ?? ""

        // ---- reason (verdict driver) + headline ----
        let reason: String
        switch verdict {
        case .go:
            reason = "Clears your buy box — \(kLabel.lowercased()) \(kValue), and the ARV is backed by sold comps."
        case .caution:
            reason = capped
                ? "The numbers score \(score)/100, but the ARV is a labeled estimate (not sold comps) — verify before you offer."
                : (topRisk.isEmpty ? "Marginal — \(kLabel.lowercased()) \(kValue)." : "Watch — \(topRisk)")
        case .pass:
            reason = retZero ? retDetail
                             : (topRisk.isEmpty ? "Doesn't clear the bar at these numbers." : "Doesn't clear the bar — \(topRisk)")
        case .incomplete:
            reason = ""   // unreachable (handled above)
        }

        let headline: String
        switch verdict {
        case .go:         headline = "GO · score \(score)/100 · \(kLabel.lowercased()) \(kValue)"
        case .caution:    headline = "CAUTION · score \(score)/100 · \(kLabel.lowercased()) \(kValue)"
        case .pass:       headline = "PASS · score \(score)/100 · \(kLabel.lowercased()) \(kValue)"
        case .incomplete: headline = ""
        }

        return DealScore(verdict: verdict, score: score, factors: factors, arvConfidence: conf,
                         headline: headline, reason: reason, topRisk: topRisk,
                         keyMetricLabel: kLabel, keyMetricValue: kValue, capped: capped)
    }

    // MARK: Factors

    /// (points 0…maxReturn, detail, isZero) — isZero forces a PASS (loses money / bleeds / no spread).
    private static func returnFactor(_ deal: Deal) -> (Int, String, Bool) {
        switch deal.exit {
        case .flip:
            let profit = deal.flipProfit
            if profit <= 0 {
                return (0, "Projected flip loses \(money(abs(profit))) — ARV \(money(deal.arv)) can't cover all-in \(money(deal.totalAllIn)) + selling costs.", true)
            }
            let margin = deal.arv > 0 ? profit / deal.arv : 0     // profit as a share of resale
            let pts: Int
            switch margin {
            case 0.20...:     pts = maxReturn
            case 0.15..<0.20: pts = 37
            case 0.10..<0.15: pts = 26
            case 0.05..<0.10: pts = 14
            default:          pts = 5
            }
            return (pts, "Flip profit \(money(profit)) — \(pct(margin * 100)) of ARV, \(pct(deal.flipROI)) cash-on-cash ROI.", false)

        case .rental:
            let cf = deal.monthlyCashFlow
            if cf <= 0 {
                return (0, "Negative cash flow \(money(cf))/mo — this rental bleeds every month at these terms.", true)
            }
            let coc = deal.cashOnCash
            let pts: Int
            switch coc {
            case 12...:   pts = maxReturn
            case 8..<12:  pts = 34
            case 5..<8:   pts = 22
            case 2..<5:   pts = 12
            default:      pts = 6
            }
            return (pts, "Cash flow \(money(cf))/mo · \(pct(deal.capRate)) cap · \(pct(coc)) cash-on-cash.", false)

        case .wholesale:
            let fee = deal.assignmentFee
            if fee <= 0 {
                return (0, "No assignment fee set — enter your spread to judge the wholesale.", true)
            }
            // Room left for the end-buyer after your fee, using MAO as their buy box.
            let room = deal.mao - (deal.purchasePrice + fee)
            let base: Int
            switch fee {
            case 15000...:      base = maxReturn
            case 10000..<15000: base = 38
            case 5000..<10000:  base = 28
            default:            base = 16
            }
            if room < 0 {
                return (max(6, base - 18),
                        "Fee \(money(fee)), but it pushes the end-buyer \(money(abs(room))) past their MAO — the spread may be too thin to assign.", false)
            }
            return (base, "Assignment fee \(money(fee)); \(money(room)) of equity still left for the end-buyer under MAO.", false)
        }
    }

    /// MAO discipline (max 25): is the price at/below your % -of-ARV buy box?
    private static func maoFactor(_ deal: Deal, maoPct: Double) -> ScoreFactor {
        let mao = deal.mao(pct: maoPct)
        let ask = deal.asking
        let p = Int(maoPct)
        if ask <= 0 {
            return ScoreFactor(name: "MAO discipline", points: 8, max: maxMAO,
                detail: "No price entered — your \(p)% MAO is \(money(mao)). Enter the asking/purchase price to test the buy box.")
        }
        if ask <= mao {
            return ScoreFactor(name: "MAO discipline", points: maxMAO, max: maxMAO,
                detail: "Price \(money(ask)) is at/below your \(p)% MAO \(money(mao)) — \(money(mao - ask)) of built-in room.")
        }
        let over = ask - mao
        let ratio = ask / max(mao, 1)
        switch ratio {
        case ..<1.10:
            return ScoreFactor(name: "MAO discipline", points: 15, max: maxMAO,
                detail: "Price \(money(ask)) is \(money(over)) over your \(p)% MAO \(money(mao)) — negotiate down to hit the buy box.")
        case ..<1.25:
            return ScoreFactor(name: "MAO discipline", points: 7, max: maxMAO,
                detail: "Price \(money(ask)) exceeds MAO \(money(mao)) by \(money(over)) — thin; only at a discount.")
        default:
            return ScoreFactor(name: "MAO discipline", points: 0, max: maxMAO,
                detail: "Price \(money(ask)) blows past your \(p)% MAO \(money(mao)) by \(money(over)) — breaks the rule.")
        }
    }

    /// Rehab risk (max 15): rehab as a share of ARV = execution/overrun risk.
    private static func rehabFactor(_ deal: Deal) -> ScoreFactor {
        let rehab = deal.repairsEffective
        if rehab <= 0 {
            return ScoreFactor(name: "Rehab risk", points: 8, max: maxRehab,
                detail: "No rehab budgeted — confirm the property truly needs none; a $0 rehab on a distressed buy is a red flag.")
        }
        let ratio = deal.arv > 0 ? rehab / deal.arv : 0
        switch ratio {
        case ..<0.10:
            return ScoreFactor(name: "Rehab risk", points: maxRehab, max: maxRehab,
                detail: "Light rehab \(money(rehab)) — \(pct(ratio * 100)) of ARV; low execution risk.")
        case ..<0.20:
            return ScoreFactor(name: "Rehab risk", points: 11, max: maxRehab,
                detail: "Moderate rehab \(money(rehab)) — \(pct(ratio * 100)) of ARV.")
        case ..<0.35:
            return ScoreFactor(name: "Rehab risk", points: 6, max: maxRehab,
                detail: "Heavy rehab \(money(rehab)) — \(pct(ratio * 100)) of ARV; pad your budget and timeline.")
        default:
            return ScoreFactor(name: "Rehab risk", points: 2, max: maxRehab,
                detail: "Very heavy rehab \(money(rehab)) — \(pct(ratio * 100)) of ARV; high overrun risk.")
        }
    }

    /// ARV confidence (max 15): how much to trust the anchor. Only a labeled estimate caps the verdict.
    private static func arvFactor(_ deal: Deal, conf: ARVConfidence) -> ScoreFactor {
        switch conf {
        case .soldComps:
            return ScoreFactor(name: "ARV confidence", points: maxARV, max: maxARV,
                detail: "ARV \(money(deal.arv)) from sold comps — the strongest basis.")
        case .estimate:
            return ScoreFactor(name: "ARV confidence", points: 6, max: maxARV,
                detail: "ARV \(money(deal.arv)) is a LABELED estimate (county-assessed / area read), not sold comps — verify with recent sales before you offer.")
        case .userEntered:
            return ScoreFactor(name: "ARV confidence", points: 9, max: maxARV,
                detail: "ARV \(money(deal.arv)) is your own figure — confirm it against recent comps to trust this verdict.")
        case .none:
            return ScoreFactor(name: "ARV confidence", points: 0, max: maxARV, detail: "No ARV set.")
        }
    }

    // MARK: Helpers

    private static func keyMetric(_ deal: Deal) -> (String, String) {
        switch deal.exit {
        case .flip:      return ("Projected flip profit", money(deal.flipProfit))
        case .rental:    return ("Monthly cash flow", money(deal.monthlyCashFlow))
        case .wholesale: return ("Assignment fee", money(deal.assignmentFee))
        }
    }

    private static func incomplete(_ deal: Deal, _ conf: ARVConfidence, reason: String) -> DealScore {
        let (kLabel, kValue) = keyMetric(deal)
        return DealScore(verdict: .incomplete, score: 0, factors: [], arvConfidence: conf,
                         headline: "", reason: reason, topRisk: "",
                         keyMetricLabel: kLabel, keyMetricValue: kValue, capped: false)
    }
}
#endif // circuit-convert
