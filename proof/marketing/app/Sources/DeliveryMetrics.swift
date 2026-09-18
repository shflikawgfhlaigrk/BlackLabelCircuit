// Black Label Marketing — DeliveryMetrics (MK-21).
//
// The honest-metrics engine behind the Delivery dashboard. EVERY number it reports is a real COUNT
// over the on-device activity log (the send-of-record: `.email_sent` is written by SequenceRunner
// after a real SMTP/API accept; `.email_replied` / `.email_bounced` are written from the buyer's own
// mailbox events). Nothing is estimated, sampled, or projected.
//
// Deliberately absent: an "open rate". Marketing carries NO open/click pixel tracking (the MK-14
// floor) — so opens are not a number we can honestly show. `opensTracked` is false and the dashboard
// says so in plain language rather than painting a fabricated open-rate.
//
// Pure value type — Foundation only, computed from `[Activity]` — so it is unit-testable headlessly
// and the "no number renders without a backing event" invariant is proven, not asserted.
import Foundation

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct DeliveryMetrics: Equatable {
    /// Emails actually sent (count of `.email_sent` events — one per real send).
    var sends: Int
    /// Replies received (count of `.email_replied` events).
    var replies: Int
    /// Bounces (count of `.email_bounced` events).
    var bounces: Int
    /// Distinct prospects we actually emailed (unique prospectID over `.email_sent`).
    var contactsEmailed: Int
    /// Opens are NOT tracked (no pixel tracking — MK-14). Always false; the UI shows an honest note.
    var opensTracked: Bool { false }

    static let empty = DeliveryMetrics(sends: 0, replies: 0, bounces: 0, contactsEmailed: 0)

    /// Compute the metrics from the real activity log. Only the send-of-record kinds count.
    static func from(activities: [Activity]) -> DeliveryMetrics {
        var sends = 0, replies = 0, bounces = 0
        var sentProspects = Set<UUID>()
        for a in activities {
            switch a.kind {
            case .email_sent:    sends += 1; sentProspects.insert(a.prospectID)
            case .email_replied: replies += 1
            case .email_bounced: bounces += 1
            default: break
            }
        }
        return DeliveryMetrics(sends: sends, replies: replies, bounces: bounces,
                               contactsEmailed: sentProspects.count)
    }

    /// True when NOTHING has actually been sent — the dashboard shows an honest empty state, not zeros
    /// dressed up as performance.
    var isEmpty: Bool { sends == 0 && replies == 0 && bounces == 0 }

    /// Reply rate — ONLY defined when we've actually sent something (nil otherwise, so no rate renders
    /// off a zero denominator). A real fraction over real sends.
    var replyRate: Double? { sends > 0 ? Double(replies) / Double(sends) : nil }

    /// Bounce rate — same honest gating: nil until there is a real send to divide by.
    var bounceRate: Double? { sends > 0 ? Double(bounces) / Double(sends) : nil }

    /// The display rows the dashboard renders. A row exists ONLY for a metric with a backing event
    /// (or, for rates, a real denominator) — so the UI can never show a number that isn't real.
    /// This is the enforcement point behind "no number renders without a backing event".
    var rows: [Row] {
        var out: [Row] = []
        if sends > 0 { out.append(Row(key: "sends", label: "Emails sent", value: "\(sends)")) }
        if contactsEmailed > 0 { out.append(Row(key: "contacts", label: "People emailed", value: "\(contactsEmailed)")) }
        if replies > 0 { out.append(Row(key: "replies", label: "Replies", value: "\(replies)")) }
        if bounces > 0 { out.append(Row(key: "bounces", label: "Bounces", value: "\(bounces)")) }
        if let r = replyRate, replies > 0 { out.append(Row(key: "replyRate", label: "Reply rate", value: percent(r))) }
        if let b = bounceRate, bounces > 0 { out.append(Row(key: "bounceRate", label: "Bounce rate", value: percent(b))) }
        return out
    }

    struct Row: Equatable, Identifiable {
        var key: String
        var label: String
        var value: String
        var id: String { key }
    }

    private func percent(_ x: Double) -> String { String(format: "%.0f%%", (x * 100).rounded()) }
}
#endif // circuit-convert
