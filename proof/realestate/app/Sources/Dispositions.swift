// Black Label Real Estate — DISPOSITIONS ENGINE: buy-box auto-match + proof-of-funds gating.
//
// Investorlift's moat, built real on the buyer's OWN cash-buyer list (no marketplace, no paid
// network, no fabricated buyers):
//   • AUTO-MATCH a deal to the buyers whose structured buy-box fits — price band, exit strategy,
//     and market/county. Each match shows WHY it matched and HOW STRONG (so the buyer knows who
//     to call first), and is honest about unknowns (a buyer with no price band simply isn't
//     excluded on price — never a faked "100% match").
//   • PROOF-OF-FUNDS GATE before the address reveal: an unverified buyer sees the deal teaser
//     (numbers, county, blurred address) but NOT the exact property until the investor marks them
//     POF-verified. This is the dispositions discipline that stops address-shopping/daisy-chains.
//     The app never fabricates verification — the human flips the flag after reviewing real POF.
import Foundation

// MARK: - One buyer's fit for a specific deal.
struct BuyerMatch: Hashable, Identifiable {
    var id: UUID { buyer.id }
    let buyer: CashBuyer
    let score: Int                  // 0…100 fit
    let reasons: [String]           // why it matched (price, strategy, market)
    let misses: [String]            // why points were withheld (out of price band, wrong market…)
    var strong: Bool { score >= 70 }
    /// POF gate: only a verified buyer may see the exact address.
    var canSeeAddress: Bool { buyer.pofVerified }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum Dispositions {
    /// Normalize a free-text market/county token for loose matching.
    static func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }

    /// Does any of the buyer's market/county tokens overlap the deal's county/address?
    static func marketHit(_ b: CashBuyer, deal: Deal) -> Bool {
        let hay = norm(deal.county) + " " + norm(deal.address)
        guard !hay.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let tokens = (b.counties + b.markets.components(separatedBy: CharacterSet(charactersIn: ",;/")))
            .map(norm).filter { $0.count >= 3 }
        return tokens.contains { hay.contains($0) }
    }

    /// Score one buyer's fit for a deal. Honest: an unspecified buy-box dimension neither
    /// rewards nor penalizes beyond its weight — it just can't earn that dimension's points.
    static func match(_ b: CashBuyer, to deal: Deal) -> BuyerMatch {
        var score = 0; var reasons: [String] = []; var misses: [String] = []
        let dealPrice = deal.asking > 0 ? deal.asking : deal.mao

        // Price band (max 40) — only scorable when the buyer set a band AND the deal has a price.
        if (b.minPrice > 0 || b.maxPrice > 0), dealPrice > 0 {
            let aboveMin = b.minPrice == 0 || dealPrice >= b.minPrice
            let belowMax = b.maxPrice == 0 || dealPrice <= b.maxPrice
            if aboveMin && belowMax { score += 40; reasons.append("In price band (\(REMath.money(dealPrice)))") }
            else { misses.append("Outside price band") }
        } else { misses.append("No price band set — price not scored") }

        // Strategy (max 30)
        if !b.strategies.isEmpty {
            if b.strategies.contains(deal.exit) { score += 30; reasons.append("Buys \(deal.exit.label)") }
            else { misses.append("Wants \(b.strategies.map { $0.label }.joined(separator: "/")), deal is \(deal.exit.label)") }
        } else { score += 10; reasons.append("Buys any strategy") }

        // Market / county (max 30)
        if marketHit(b, deal: deal) { score += 30; reasons.append("Buys this market") }
        else if (b.counties.isEmpty && b.markets.isEmpty) { score += 8; reasons.append("No market filter (open)") }
        else { misses.append("Outside their markets") }

        return BuyerMatch(buyer: b, score: min(100, score), reasons: reasons, misses: misses)
    }

    /// All buyers ranked for a deal (best fit first). Verified buyers tie-break ahead.
    static func matches(for deal: Deal, buyers: [CashBuyer], minScore: Int = 1) -> [BuyerMatch] {
        buyers.map { match($0, to: deal) }
            .filter { $0.score >= minScore }
            .sorted { ($0.score, $0.buyer.pofVerified ? 1 : 0) > ($1.score, $1.buyer.pofVerified ? 1 : 0) }
    }

    /// POF-GATED address: the exact address only when the buyer is verified; otherwise a teaser
    /// that reveals the county + a partial (street type / area) but never the house number.
    static func gatedAddress(_ deal: Deal, for buyer: CashBuyer) -> String {
        if buyer.pofVerified { return deal.address.isEmpty ? "(no address on deal)" : deal.address }
        return teaser(deal.address, county: deal.county)
    }

    /// Build the blurred teaser shown to an unverified buyer. Strips the house number, keeps the
    /// general area so they can self-qualify, and labels it as POF-gated.
    static func teaser(_ address: String, county: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return county.isEmpty ? "Address available after POF verification." : "\(county.capitalized) County — exact address after POF." }
        // Drop a leading house number, keep the rest (street/city/state).
        let parts = trimmed.split(separator: " ")
        let rest = (parts.first.map { Int($0.filter(\.isNumber)) != nil && !$0.isEmpty } == true)
            ? parts.dropFirst().joined(separator: " ") : trimmed
        let area = rest.isEmpty ? (county.isEmpty ? "this area" : "\(county.capitalized) County") : "▮▮▮ \(rest)"
        return "\(area) — exact address after POF verification."
    }
}
#endif // circuit-convert
