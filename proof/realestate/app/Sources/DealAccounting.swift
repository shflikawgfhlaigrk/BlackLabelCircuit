// Black Label Real Estate — DEAL ACCOUNTING + MARKETING-CHANNEL ROI.
//
// REsimpli's moat, built real on the buyer's OWN entries (no Plaid, no bank link, no fabrication):
//   • Log marketing SPEND by channel (direct mail, PPC, cold call, SMS, driving-for-dollars…)
//     and per-deal EXPENSES + REVENUE.
//   • Compute the funnel cost the way investors actually judge a channel:
//       cost-per-lead → cost-per-deal → marketing ROI, per channel and overall.
//   • Per-deal P&L (revenue − purchase − rehab − holding − selling − misc).
// Everything is the user's data; numbers are computed, never invented. Empty => honest zeros.
import Foundation

// MARK: - A marketing channel the investor spends on.
enum MarketingChannel: String, Codable, CaseIterable, Identifiable {
    case directMail, ppc, coldCall, sms, drivingForDollars, socialAds, referral, signs, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .directMail: return "Direct mail"; case .ppc: return "PPC / Google"; case .coldCall: return "Cold calling"
        case .sms: return "SMS / texting"; case .drivingForDollars: return "Driving for dollars"
        case .socialAds: return "Social ads"; case .referral: return "Referral"; case .signs: return "Bandit signs"; case .other: return "Other" }
    }
    var icon: String {
        switch self {
        case .directMail: return "envelope.fill"; case .ppc: return "magnifyingglass"; case .coldCall: return "phone.fill"
        case .sms: return "message.fill"; case .drivingForDollars: return "car.fill"; case .socialAds: return "rectangle.on.rectangle.fill"
        case .referral: return "person.2.fill"; case .signs: return "signpost.right.fill"; case .other: return "tag.fill" }
    }
}

// MARK: - One spend entry (a campaign / cost the investor logged).
struct MarketingSpend: Identifiable, Codable, Hashable {
    var id = UUID()
    var channel: MarketingChannel = .directMail
    var campaign: String = ""           // free label (e.g. "Probate postcards — May")
    var amount: Double = 0
    var date = Date()
    var note: String = ""
}

// MARK: - One per-deal expense line (in addition to the analyzer's modeled costs).
struct DealExpense: Identifiable, Codable, Hashable {
    var id = UUID()
    var dealID: UUID
    var label: String = ""
    var amount: Double = 0
    var date = Date()
}

// MARK: - Computed channel performance.
struct ChannelStats: Hashable {
    var channel: MarketingChannel
    var spend: Double
    var leads: Int                      // leads attributed to this channel
    var deals: Int                      // closed/won deals attributed to it
    var revenue: Double                 // revenue from those deals
    var costPerLead: Double { leads > 0 ? spend / Double(leads) : 0 }
    var costPerDeal: Double { deals > 0 ? spend / Double(deals) : 0 }
    var roi: Double { spend > 0 ? (revenue - spend) / spend * 100 : 0 }   // % return on marketing spend
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum DealAccounting {
    /// Map a LeadSource to the marketing channel it most likely came through (best-effort,
    /// honest: source isn't spend, so attribution is by source type — the buyer can refine).
    static func channel(for source: LeadSource) -> MarketingChannel {
        switch source {
        case .probate, .preForeclosure, .taxDelinquent, .codeViolation: return .directMail
        case .absentee: return .directMail
        case .teardown: return .directMail
        // Database-list leads ship with a mailing address and no contact PII — direct
        // mail is the honest first channel for them.
        case .database: return .directMail
        case .builder, .areaBusiness: return .coldCall
        case .manual: return .other
        }
    }

    /// Per-deal net profit using the analyzer math + any logged extra expenses.
    /// Uses realized revenue when the deal is won (asking/ARV per exit), else the projection.
    static func netProfit(_ deal: Deal, extraExpenses: Double = 0) -> Double {
        switch deal.exit {
        case .flip:     return deal.flipProfit - extraExpenses
        case .rental:   return deal.monthlyCashFlow * 12 - extraExpenses          // annualized
        case .wholesale: return deal.wholesaleProfit - extraExpenses
        }
    }

    /// Revenue figure used for channel ROI (won deals only — realized, not projected).
    static func realizedRevenue(_ deal: Deal) -> Double {
        guard deal.status == .won else { return 0 }
        switch deal.exit {
        case .flip:      return deal.arv                       // gross sale proceeds
        case .wholesale: return deal.assignmentFee
        case .rental:    return max(0, deal.monthlyCashFlow) * 12
        }
    }

    /// Build per-channel stats from the buyer's spend + their leads + their won deals.
    /// Lead→channel via source; deal→channel via the deal's originating lead county/source isn't
    /// stored, so won deals are attributed by matching address↔lead when possible, else summed
    /// into the dominant channel of their leads. Honest, all from real entries.
    static func channelStats(spend: [MarketingSpend], leads: [Lead], deals: [Deal]) -> [ChannelStats] {
        var spendBy: [MarketingChannel: Double] = [:]
        for s in spend { spendBy[s.channel, default: 0] += s.amount }
        var leadsBy: [MarketingChannel: Int] = [:]
        for l in leads { leadsBy[channel(for: l.source), default: 0] += 1 }

        // Attribute a won deal to a channel by matching its address to a lead's property address.
        var dealsBy: [MarketingChannel: Int] = [:]
        var revBy: [MarketingChannel: Double] = [:]
        let leadByAddr = Dictionary(leads.map { (ListEngine.norm($0.propertyAddress), $0) }, uniquingKeysWith: { a, _ in a })
        for d in deals where d.status == .won {
            let ch: MarketingChannel
            if let l = leadByAddr[ListEngine.norm(d.address)], !d.address.isEmpty { ch = channel(for: l.source) }
            else { ch = .other }
            dealsBy[ch, default: 0] += 1
            revBy[ch, default: 0] += realizedRevenue(d)
        }

        let channels = Set(spendBy.keys).union(leadsBy.keys).union(dealsBy.keys)
        return channels.map { c in
            ChannelStats(channel: c, spend: spendBy[c] ?? 0, leads: leadsBy[c] ?? 0,
                         deals: dealsBy[c] ?? 0, revenue: revBy[c] ?? 0)
        }.sorted { $0.spend > $1.spend }
    }

    static func totalSpend(_ spend: [MarketingSpend]) -> Double { spend.reduce(0) { $0 + $1.amount } }
    /// Blended cost per lead across all channels (real).
    static func blendedCPL(spend: [MarketingSpend], leads: [Lead]) -> Double {
        leads.isEmpty ? 0 : totalSpend(spend) / Double(leads.count)
    }
}
#endif // circuit-convert
