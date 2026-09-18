// Black Label Marketing — MK-23 fused ⌘K COMMAND BAR over leads + mailbox, with on-device triage.
//
// The parity gap this closes: the ⌘K search already spans the buyer's projects and lead DB, but not the
// MAILBOX — and it carries no triage. This is the fused bar: one sub-second, on-device full-text search
// over BOTH the whole lead DB AND the buyer's own Inbox, where every result carries a REPLY/BOUNCE
// triage tag derived STRICTLY from the real activity log (.email_replied / .email_bounced) and the
// inbox's own classification. There is NO fabricated classification confidence — a tag exists only
// because a real event was logged / a real message was classified. Honest empty states, no seeded data.
//
// Pure Foundation (no SwiftUI, no AppModel, no network) so the ranking + triage logic is unit-tested
// with zero UI. The View layer (GlobalSearchView) maps tags to tint and routes a hit to its lead/inbox.
import Foundation

// MARK: - triage tag (derived from REAL events only — never a scored/estimated classification)
enum TriageTag: String, Equatable {
    case replied      // the lead has a real .email_replied event / the message classified as a reply
    case bounced      // the lead has a real .email_bounced event / the message classified as a bounce
    case sent         // contacted (a real .email_sent event) but no reply/bounce yet
    var label: String {
        switch self { case .replied: return "Replied"; case .bounced: return "Bounced"; case .sent: return "Sent" }
    }
    var systemImage: String {
        switch self {
        case .replied: return "arrowshape.turn.up.left.fill"
        case .bounced: return "exclamationmark.arrow.circlepath"
        case .sent: return "paperplane.fill"
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - triage derivation from the on-device activity log (honest presence/absence)
enum CommandTriage {
    /// Tags for a lead from the REAL activity log. A tag is present ONLY because a matching event was
    /// logged — there is no confidence score to fabricate. Reply and bounce can co-exist; `.sent` is a
    /// fallback shown only when the lead was contacted but has neither replied nor bounced.
    static func tags(prospectID: UUID, activities: [Activity]) -> [TriageTag] {
        var kinds = Set<Activity.Kind>()
        for a in activities where a.prospectID == prospectID { kinds.insert(a.kind) }
        var out: [TriageTag] = []
        if kinds.contains(.email_replied) { out.append(.replied) }
        if kinds.contains(.email_bounced) { out.append(.bounced) }
        if out.isEmpty && kinds.contains(.email_sent) { out.append(.sent) }
        return out
    }
}
#endif // circuit-convert

// MARK: - a unified hit over BOTH the lead DB and the mailbox
struct CommandHit: Identifiable, Equatable {
    enum Kind: Equatable { case lead, message }
    let id: String                 // "lead:<uuid>" / "msg:<inbox-id>"
    var kind: Kind
    var title: String
    var subtitle: String
    var tags: [TriageTag]
    var leadID: UUID?              // set for a lead hit, and for a message matched to a saved lead
    var messageID: String?        // set for a mailbox hit
    var score: Int                // match strength for ranking (NOT a relevance % shown to the user)
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - the fused search (sub-second, in-memory, deterministic)
enum CommandBar {
    /// Tokenize a query into lowercased terms (space/tab separated).
    static func terms(_ q: String) -> [String] {
        q.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
    }

    /// AND-match: EVERY term must appear in the haystack, else no match (nil). Returns a small ranking
    /// score with prefix / word-boundary boosts. Not surfaced as a number — purely for ordering.
    static func score(_ haystack: String, terms: [String]) -> Int? {
        guard !terms.isEmpty else { return nil }
        let h = haystack.lowercased()
        var s = 0
        for t in terms {
            guard h.range(of: t) != nil else { return nil }
            s += 2
            if h.hasPrefix(t) { s += 4 }                       // whole-field prefix — strongest signal
            else if h.range(of: " \(t)") != nil { s += 2 }     // word-boundary match
        }
        return s
    }

    /// The dataset the bar searches — the whole lead DB, the whole inbox, and the activity log for triage.
    struct Dataset {
        var leads: [Lead]
        var inbox: [InboxMessage]
        var activities: [Activity]
    }

    /// Run the fused search. Empty query → no data hits (the UI shows navigation shortcuts instead).
    /// A triage tag rides every hit, derived from real events only. Ranked; capped at `limit`.
    static func search(_ query: String, in data: Dataset, limit: Int = 40) -> [CommandHit] {
        let ts = terms(query)
        guard !ts.isEmpty else { return [] }
        var hits: [CommandHit] = []

        // Leads — search the whole record; triage from the activity log.
        for l in data.leads {
            let hay = [l.name, l.company, l.email, l.domain, l.phone, l.industry, l.sourceCampaign,
                       l.tags.joined(separator: " ")].joined(separator: " ")
            guard let sc = score(hay, terms: ts) else { continue }
            let tags = CommandTriage.tags(prospectID: l.id, activities: data.activities)
            hits.append(CommandHit(id: "lead:\(l.id.uuidString)", kind: .lead, title: l.displayName,
                                   subtitle: leadSubtitle(l), tags: tags, leadID: l.id, messageID: nil,
                                   score: sc + tagBoost(tags)))
        }
        // Mailbox — search sender + subject + snippet; triage from the message's own classification.
        for m in data.inbox {
            let hay = [m.fromName, m.fromEmail, m.subject, m.snippet].joined(separator: " ")
            guard let sc = score(hay, terms: ts) else { continue }
            var tags: [TriageTag] = []
            switch m.classification {
            case .reply: tags = [.replied]
            case .bounce: tags = [.bounced]
            case .autoReply, .other: tags = []
            }
            hits.append(CommandHit(id: "msg:\(m.id)", kind: .message,
                                   title: m.subject.isEmpty ? (m.fromName.isEmpty ? m.fromEmail : m.fromName) : m.subject,
                                   subtitle: "\(m.fromEmail) · \(m.classification.label)", tags: tags,
                                   leadID: m.matchedProspectID, messageID: m.id, score: sc))
        }
        return Array(hits.sorted { $0.score == $1.score ? $0.title.lowercased() < $1.title.lowercased() : $0.score > $1.score }.prefix(limit))
    }

    /// Filter to only the mailbox hits carrying a given triage tag (reply/bounce inbox triage view).
    static func triaged(_ hits: [CommandHit], tag: TriageTag) -> [CommandHit] {
        hits.filter { $0.tags.contains(tag) }
    }

    // A hit whose lead already replied/bounced is more actionable — nudge it up (deterministic, small).
    private static func tagBoost(_ tags: [TriageTag]) -> Int {
        if tags.contains(.replied) { return 3 }
        if tags.contains(.bounced) { return 2 }
        return 0
    }
    private static func leadSubtitle(_ l: Lead) -> String {
        let email = l.email.isEmpty ? (l.company.isEmpty ? "CRM lead" : l.company) : l.email
        return l.company.isEmpty || l.email.isEmpty ? email : "\(l.company) · \(l.email)"
    }
}
#endif // circuit-convert
