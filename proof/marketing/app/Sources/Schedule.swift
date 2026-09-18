// Black Label Marketing — Scheduler calendar + best-time-to-post + Influencer CRM (Tier 2).
// Standalone. Best-time is derived ONLY from the buyer's OWN logged post engagement —
// an honest empty state when there's no data (never a fabricated "best time"). The
// influencer CRM scores fit from facts the buyer ENTERED — unknown followers/engagement
// contribute nothing; we never invent a follower count.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Best time to post (from the buyer's own logged engagement)

/// One past post the buyer logged real engagement for. weekday: 1=Sun…7=Sat (Calendar).
struct PostEngagement: Identifiable, Codable, Hashable {
    var id = UUID()
    var weekday: Int
    var hour: Int
    var engagement: Int       // real, operator-logged (likes+comments+shares they observed)
    var channel: String = ""
    var loggedAt = Date()
}

enum BestTimeEngine {
    static let weekdayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static func weekdayName(_ w: Int) -> String { (1...7).contains(w) ? weekdayNames[w] : "—" }
    static func hourLabel(_ h: Int) -> String {
        let ampm = h < 12 ? "AM" : "PM"; let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12) \(ampm)"
    }

    /// Highest-total-engagement (weekday, hour) bucket, or nil when no data exists.
    static func best(_ stats: [PostEngagement]) -> (weekday: Int, hour: Int, total: Int)? {
        guard !stats.isEmpty else { return nil }
        var bucket: [String: Int] = [:]
        for s in stats { bucket["\(s.weekday)-\(s.hour)", default: 0] += max(0, s.engagement) }
        guard let top = bucket.filter({ $0.value > 0 }).max(by: { $0.value < $1.value }) else { return nil }
        let parts = top.key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1], top.value)
    }
    /// Top N hours by engagement, honest empty when no data.
    static func topHours(_ stats: [PostEngagement], n: Int = 3) -> [(hour: Int, total: Int)] {
        guard !stats.isEmpty else { return [] }
        var byHour: [Int: Int] = [:]
        for s in stats { byHour[s.hour, default: 0] += max(0, s.engagement) }
        return byHour.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
    }
}

// MARK: - Calendar grouping for the scheduler view

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum SchedulerCalendar {
    /// Group scheduled posts by the day-of-month they fall on, for a given month.
    static func postsByDay(_ posts: [ScheduledPost], month: Date, calendar: Calendar = .current) -> [Int: [ScheduledPost]] {
        let comps = calendar.dateComponents([.year, .month], from: month)
        var out: [Int: [ScheduledPost]] = [:]
        for p in posts {
            let pc = calendar.dateComponents([.year, .month, .day], from: p.scheduledAt)
            if pc.year == comps.year && pc.month == comps.month, let d = pc.day { out[d, default: []].append(p) }
        }
        return out
    }
    /// Number of leading blank cells before day 1 (weekday offset) for a month grid.
    static func leadingBlankCount(month: Date, calendar: Calendar = .current) -> Int {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else { return 0 }
        return calendar.component(.weekday, from: first) - 1   // 0 = Sunday-first grid
    }
    static func daysInMonth(_ month: Date, calendar: Calendar = .current) -> Int {
        calendar.range(of: .day, in: .month, for: month)?.count ?? 30
    }
}
#endif // circuit-convert

// MARK: - Influencer CRM (facts the buyer entered only)

struct Influencer: Identifiable, Codable, Hashable {
    var id = UUID()
    var handle: String = ""
    var platform: String = "Instagram"
    var niche: String = ""
    var followers: Int = 0            // operator-entered; 0 = unknown (never invented)
    var engagementRatePct: Double = 0 // operator-entered; 0 = unknown
    var email: String = ""
    var status: String = "Prospect"   // Prospect / Contacted / Negotiating / Partnered / Passed
    var notes: String = ""
    var created = Date()
}

enum InfluencerEngine {
    static let statuses = ["Prospect", "Contacted", "Negotiating", "Partnered", "Passed"]
    /// Transparent fit score from ENTERED facts. Unknown (0) metrics contribute 0.
    static func fit(_ i: Influencer, targetNiche: String) -> Int {
        var score = 0
        if !targetNiche.isEmpty, i.niche.lowercased().contains(targetNiche.lowercased()) { score += 40 }
        score += min(35, Int(i.engagementRatePct * 3.5))
        switch i.followers {
        case 5_000...100_000: score += 25
        case 100_001...1_000_000: score += 15
        case 1...4_999: score += 12
        case 1_000_001...: score += 10
        default: break
        }
        return min(100, score)
    }
}

// MARK: - Persistence

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    func logEngagement(_ e: PostEngagement) { postStats.insert(e, at: 0) }
    func deleteEngagement(_ e: PostEngagement) { postStats.removeAll { $0.id == e.id } }
    func upsertInfluencer(_ i: Influencer) {
        if let idx = influencers.firstIndex(where: { $0.id == i.id }) { influencers[idx] = i } else { influencers.insert(i, at: 0) }
    }
    func deleteInfluencer(_ i: Influencer) { influencers.removeAll { $0.id == i.id } }
}
#endif // circuit-convert
