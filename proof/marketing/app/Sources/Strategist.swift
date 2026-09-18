// Black Label Marketing — AI strategist: brand-strategy audit + CMO advisor.
// Scores positioning / messaging / visual identity from the buyer's OWN brand kit, and recommends
// the next move from the buyer's OWN data (leads, campaigns, links, journeys, attribution). Every
// score and recommendation traces to a real field/metric — never invented. Pure + unit-tested.
import Foundation

// MARK: - Brand strategy audit (positioning / messaging / visual identity)

struct BrandAxis: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var score: Int                 // 0..100
    var wins: [String]             // concrete quick wins for what's missing
}

struct BrandStrategyInput {
    var brandName = "", tagline = "", vertical = "", market = "", hashtag = ""
    var senderName = "", senderEmail = ""
    var hasLogo = false
    var hasCustomColor = false
    var extractedColors = 0
}

enum BrandStrategyEngine {
    /// Score each axis from real brand-kit completeness/clarity. Each present, specific field earns
    /// points; each gap becomes a named quick win. Deterministic — identical input → identical score.
    static func audit(_ b: BrandStrategyInput) -> [BrandAxis] {
        func nonEmpty(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespaces).isEmpty }

        // Positioning: who you are, who you serve, where, in a sentence.
        var posScore = 0; var posWins: [String] = []
        if nonEmpty(b.brandName) { posScore += 25 } else { posWins.append("Set your brand name — every output leads with it.") }
        if nonEmpty(b.vertical)  { posScore += 25 } else { posWins.append("Name your industry/vertical so copy speaks to the right buyer.") }
        if nonEmpty(b.market)    { posScore += 25 } else { posWins.append("Add your market/city to localize positioning.") }
        if nonEmpty(b.tagline)   { posScore += 25 } else { posWins.append("Write a one-line value proposition (tagline).") }

        // Messaging: a consistent voice + reachable, branded sender + a hashtag handle.
        var msgScore = 0; var msgWins: [String] = []
        if nonEmpty(b.tagline)    { msgScore += 30 } else { msgWins.append("A tagline anchors a consistent message across channels.") }
        if nonEmpty(b.hashtag)    { msgScore += 20 } else { msgWins.append("Add a brand hashtag for social consistency.") }
        if nonEmpty(b.senderName) { msgScore += 25 } else { msgWins.append("Set a sender name so email reads as you, not a system.") }
        if nonEmpty(b.senderEmail){ msgScore += 25 } else { msgWins.append("Add a reply-to email so recipients can reach you.") }

        // Visual identity: logo + a deliberate brand color (custom or extracted).
        var visScore = 0; var visWins: [String] = []
        if b.hasLogo            { visScore += 45 } else { visWins.append("Add your logo — it carries into reels, sites, and the app.") }
        if b.hasCustomColor     { visScore += 35 } else { visWins.append("Pick a custom brand color (or extract one from your logo/site).") }
        if b.extractedColors > 0 { visScore += 20 } else { visWins.append("Profile your site or logo to build a real brand palette.") }

        return [
            BrandAxis(name: "Positioning", score: min(100, posScore), wins: posWins),
            BrandAxis(name: "Messaging", score: min(100, msgScore), wins: msgWins),
            BrandAxis(name: "Visual identity", score: min(100, visScore), wins: visWins),
        ]
    }

    static func overall(_ axes: [BrandAxis]) -> Int {
        guard !axes.isEmpty else { return 0 }
        return axes.reduce(0) { $0 + $1.score } / axes.count
    }
}

// MARK: - CMO advisor (next move from the buyer's own data)

struct Recommendation: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var reasoning: String          // why — references the real metric
    var confidence: Int            // 0..100
    var backing: String            // the metric behind it (e.g. "42 leads, 0 active journeys")
}

struct AdvisorInput {
    var contacts = 0
    var leadsLast7 = 0
    var activeJourneys = 0
    var loggedClicks = 0
    var loggedConversions = 0
    var spotlightsSent = 0
    var contentItems = 0
    var topChannel: String? = nil
    var segments = 0
}

enum AdvisorEngine {
    /// Minimum real signal before the advisor will recommend a move (honesty floor).
    static let minContacts = 5

    /// Analyze the buyer's own data and return ranked recommendations. With too little data it
    /// returns a single honest "not enough data yet" item — it never invents a move.
    static func analyze(_ d: AdvisorInput) -> [Recommendation] {
        if d.contacts < minContacts {
            return [Recommendation(
                title: "Add your contacts to unlock advice",
                reasoning: "The advisor recommends moves from your real pipeline. With \(d.contacts) contact\(d.contacts == 1 ? "" : "s") there isn't enough signal yet.",
                confidence: 100,
                backing: "\(d.contacts)/\(minContacts) contacts")]
        }
        var recs: [Recommendation] = []

        if d.activeJourneys == 0 {
            recs.append(Recommendation(
                title: "Turn on a welcome journey",
                reasoning: "You have \(d.contacts) contacts but no active drip journey — new leads aren't being nurtured automatically.",
                confidence: 90, backing: "\(d.contacts) contacts · 0 active journeys"))
        }
        if d.loggedClicks > 0 && d.loggedConversions == 0 {
            recs.append(Recommendation(
                title: "Fix the offer or landing page",
                reasoning: "Your links logged \(d.loggedClicks) clicks but 0 conversions — traffic is arriving and not converting.",
                confidence: 80, backing: "\(d.loggedClicks) clicks · 0 conversions"))
        }
        if let ch = d.topChannel, d.loggedConversions > 0 {
            recs.append(Recommendation(
                title: "Double down on \(ch.capitalized)",
                reasoning: "\(ch.capitalized) carries the most attributed conversions in your data — shift more effort there.",
                confidence: 75, backing: "top attributed channel: \(ch)"))
        }
        if d.contentItems == 0 {
            recs.append(Recommendation(
                title: "Generate this week's content",
                reasoning: "Your content library is empty — repurpose one idea into the 7 lanes to stay visible.",
                confidence: 70, backing: "0 saved content items"))
        }
        if d.leadsLast7 == 0 {
            recs.append(Recommendation(
                title: "Refill the top of funnel",
                reasoning: "No new leads in the last 7 days — run outreach or a campaign to add supply.",
                confidence: 65, backing: "0 leads in 7 days"))
        }
        if recs.isEmpty {
            recs.append(Recommendation(
                title: "You're on track — keep the cadence",
                reasoning: "Active journeys, recent leads, and logged conversions are all present. Maintain your weekly content + send rhythm.",
                confidence: 60, backing: "\(d.contacts) contacts · \(d.activeJourneys) active journeys · \(d.loggedConversions) conversions"))
        }
        return recs.sorted { $0.confidence > $1.confidence }
    }
}
