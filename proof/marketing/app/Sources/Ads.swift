// Black Label Marketing — Ad-campaign builder + budget tracker (Tier 1).
// Standalone. The buyer builds a campaign object (objective, budget, dates) and
// the app auto-wires a UTM-tagged destination link. Connecting an ad account
// (Google/Meta) is an HONEST "connect a provider" state — we never fabricate spend,
// impressions, clicks, or conversions. Spend is OPERATOR-LOGGED only; pacing math
// is computed purely from that logged spend vs the budget/dates the buyer set.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Ad providers (honest connect state)

enum AdProvider: String, CaseIterable, Identifiable, Codable {
    case google = "Google Ads", meta = "Meta Ads", tiktok = "TikTok Ads", linkedin = "LinkedIn Ads", microsoft = "Microsoft Ads"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .google: return "g.circle.fill"
        case .meta: return "infinity"
        case .tiktok: return "music.note"
        case .linkedin: return "briefcase.fill"
        case .microsoft: return "m.square.fill"
        }
    }
    var devPortal: String {
        switch self {
        case .google: return "ads.google.com"
        case .meta: return "business.facebook.com"
        case .tiktok: return "business-api.tiktok.com"
        case .linkedin: return "linkedin.com/campaignmanager"
        case .microsoft: return "ads.microsoft.com"
        }
    }

    /// The EXACT page where this network's API access lives — not the bare portal domain, which
    /// answers with a "start advertising" splash that never mentions API credentials. Verified
    /// 2026-08-12: each resolves to the access surface or its sign-in with a return link.
    var credentialURL: URL {
        switch self {
        // The developer token is issued in the Google Ads API Center, not in the ads dashboard.
        case .google:    return URL(string: "https://ads.google.com/aw/apicenter")!
        case .meta:      return URL(string: "https://business.facebook.com/settings")!
        // ads.tiktok.com/marketing_api/homepage forwards here — link the destination directly.
        case .tiktok:    return URL(string: "https://business-api.tiktok.com/portal")!
        case .linkedin:  return URL(string: "https://www.linkedin.com/campaignmanager")!
        case .microsoft: return URL(string: "https://ads.microsoft.com")!
        }
    }
}

enum AdObjective: String, CaseIterable, Identifiable, Codable {
    case traffic = "Traffic", leads = "Leads", sales = "Sales", awareness = "Awareness", engagement = "Engagement"
    var id: String { rawValue }
    /// UTM medium convention for this objective.
    var utmMedium: String {
        switch self {
        case .traffic, .awareness, .engagement: return "cpc"
        case .leads: return "paid_lead"
        case .sales: return "paid_sales"
        }
    }
}

// MARK: - Campaign

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct AdCampaign: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var provider: AdProvider = .google
    var objective: AdObjective = .traffic
    var destinationURL: String = ""    // where ads point (the buyer's own URL)
    var totalBudget: Double = 0        // the buyer's planned budget
    var spent: Double = 0              // OPERATOR-LOGGED actual spend (never fabricated)
    // Operator-logged real results from the ad account dashboard. Never auto-pulled/invented.
    var loggedClicks: Int = 0
    var loggedConversions: Int = 0
    var startDate: Date = Date()
    var endDate: Date = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    var created = Date()

    /// Auto-built UTM-tagged destination from the campaign's own fields.
    var taggedURL: String? {
        Studio.buildUTM(base: destinationURL, source: provider.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"),
                        medium: objective.utmMedium, campaign: name)
    }
    /// Real cost-per-click from logged data (nil if no clicks logged — no fabrication).
    var costPerClick: Double? { loggedClicks > 0 ? spent / Double(loggedClicks) : nil }
    var costPerConversion: Double? { loggedConversions > 0 ? spent / Double(loggedConversions) : nil }
}
#endif // circuit-convert

// MARK: - Budget pacing (pure, from operator-logged spend only)

struct AdPacing {
    let totalBudget: Double
    let spent: Double
    let startsInDaysAgo: Int   // days elapsed since start (>=0, clamped)
    let totalDays: Int         // campaign length in days
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum AdEngine {
    static func remaining(_ p: AdPacing) -> Double { max(0, p.totalBudget - p.spent) }
    static func daysLeft(_ p: AdPacing) -> Int { max(0, p.totalDays - p.startsInDaysAgo) }
    static func dailyBudget(_ p: AdPacing) -> Double { p.totalDays > 0 ? p.totalBudget / Double(p.totalDays) : 0 }
    /// What you SHOULD have spent by now at an even pace.
    static func expectedSpend(_ p: AdPacing) -> Double {
        guard p.totalDays > 0 else { return 0 }
        return p.totalBudget * Double(min(p.startsInDaysAgo, p.totalDays)) / Double(p.totalDays)
    }
    /// >1 over-pace, <1 under-pace, nil when there's no elapsed time yet (no fabrication).
    static func paceRatio(_ p: AdPacing) -> Double? {
        let exp = expectedSpend(p); guard exp > 0 else { return nil }; return p.spent / exp
    }
    static func budgetClamped(_ p: AdPacing) -> Bool { p.totalBudget > 0 && p.spent >= p.totalBudget }

    /// Build a pacing snapshot from a campaign + the calendar.
    static func pacing(for c: AdCampaign, now: Date = Date()) -> AdPacing {
        let cal = Calendar.current
        let elapsed = max(0, cal.dateComponents([.day], from: c.startDate, to: now).day ?? 0)
        let total = max(1, cal.dateComponents([.day], from: c.startDate, to: c.endDate).day ?? 1)
        return AdPacing(totalBudget: c.totalBudget, spent: c.spent, startsInDaysAgo: elapsed, totalDays: total)
    }
}
#endif // circuit-convert

// MARK: - Persistence

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    func upsertAd(_ c: AdCampaign) {
        if let i = adCampaigns.firstIndex(where: { $0.id == c.id }) { adCampaigns[i] = c } else { adCampaigns.insert(c, at: 0) }
    }
    func deleteAd(_ c: AdCampaign) { adCampaigns.removeAll { $0.id == c.id } }
    /// Total budget across campaigns (real, from the buyer's own plans).
    var totalAdBudget: Double { adCampaigns.reduce(0) { $0 + $1.totalBudget } }
    var totalAdSpend: Double { adCampaigns.reduce(0) { $0 + $1.spent } }
}
#endif // circuit-convert
