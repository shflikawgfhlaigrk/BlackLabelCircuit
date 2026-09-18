// Black Label Marketing — unified lead domain (Leads merge, 2026-07).
// One Lead entity replaces the old CapturedLead (site-form capture) + ClientLead (finder hit)
// plus the Leads app's Prospect. CRM pipeline types (deals/Kanban, tasks, activity timeline,
// lists) and outreach-sequence types port from Black Label Leads with their on-wire field
// names UNCHANGED so a buyer's exported/migrated Leads data decodes without mapping.
// On-device, Codable snapshots, no network, no seeded data — starts empty.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Lead lifecycle / vertical / send-ledger enums

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum ProspectStatus: String, Codable, CaseIterable, Identifiable {
    case new, contacted, replied, won, dead
    var id: String { rawValue }
    var label: String {
        switch self {
        case .new: return "New"; case .contacted: return "Contacted"; case .replied: return "Replied"
        case .won: return "Won"; case .dead: return "Dead"
        }
    }
    var tint: Color {
        switch self {
        case .new: return BLTheme.gold; case .contacted: return .blue; case .replied: return .orange
        case .won: return BLTheme.green; case .dead: return BLTheme.red
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Outreach send log status — honest states only, grounded in real SMTP outcomes or manual logging.
enum SendStatus: String, Codable, CaseIterable, Identifiable {
    case notSent, sent, replied, bounced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .notSent: return "Not sent"; case .sent: return "Sent"; case .replied: return "Replied"; case .bounced: return "Bounced"
        }
    }
    var tint: Color {
        switch self {
        case .notSent: return BLTheme.sub; case .sent: return .blue; case .replied: return BLTheme.green; case .bounced: return BLTheme.red
        }
    }
    var icon: String {
        switch self {
        case .notSent: return "tray"; case .sent: return "paperplane.fill"; case .replied: return "arrowshape.turn.up.left.fill"; case .bounced: return "exclamationmark.arrow.circlepath"
        }
    }
}
#endif // circuit-convert

// Where a lead entered the workspace. Legacy records (pre-merge) default to the source
// implied by the collection they migrated from.
enum LeadSource: String, Codable, CaseIterable, Identifiable {
    case manual, siteForm, finder, database, imported
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: return "Manual"; case .siteForm: return "Site form"; case .finder: return "Find Clients"
        case .database: return "Lead Database"; case .imported: return "Imported"
        }
    }
}

// MARK: - the unified Lead

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct Lead: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var company: String = ""
    var domain: String = ""
    var email: String = ""
    var status: ProspectStatus = .new
    var notes: String = ""
    var created = Date()
    // Type-aware drafting + grounded send ledger.
    var type: ProspectType = .other
    var draft: String = ""
    var sendStatus: SendStatus = .notSent
    var lastSent: Date? = nil
    // CRM fields
    var tags: [String] = []
    var phone: String = ""
    var address: String = ""
    // Unified-domain fields (absorbed from CapturedLead / ClientLead)
    var source: LeadSource = .manual
    var message: String = ""            // site-form message body, if captured from a form
    var sourceCampaign: String = ""     // which campaign/site captured it
    var industry: String = ""           // free-text industry from the finder (type is the enum)
    // In-house pattern-GUESS lane — kept SEPARATE from `email` on purpose. A best-effort address
    // derived from name+domain, ALWAYS unverified; never a confirmed email, never silently promoted
    // into `email`. Resolved for display through LeadEmailDisplay so it can't render as green/verified.
    var guessedEmail: String = ""       // e.g. first.last@domain — an unverified pattern candidate
    var guessedEmailPattern: String = ""// which pattern produced it (e.g. "first.last@")
    // MK-17 waterfall enrichment cache — the outcome of the last provider-chain run for THIS lead's
    // exact name+domain, stored locally so a re-enrichment is instant and free (no network re-hit).
    // A cache HIT that carried a confirmed address already lives in `email`; this is the audit record
    // (which vendor won, per-provider outcomes) and the no-network re-run key. Never a fabricated field.
    var enrichmentCache: EnrichmentCacheEntry? = nil

    /// Best human label for the lead (name → company → email → fallback).
    var displayName: String {
        if !name.isEmpty { return name }
        if !company.isEmpty { return company }
        if !email.isEmpty { return email }
        return "(unnamed)"
    }

    // Resilient decode so legacy data (Leads-app Prospect exports and pre-merge records)
    // still loads. Field names match the Leads app's Prospect on the wire.
    init(id: UUID = UUID(), name: String = "", company: String = "", domain: String = "",
         email: String = "", status: ProspectStatus = .new, notes: String = "", created: Date = Date(),
         type: ProspectType = .other, draft: String = "", sendStatus: SendStatus = .notSent,
         lastSent: Date? = nil, tags: [String] = [], phone: String = "", address: String = "",
         source: LeadSource = .manual, message: String = "", sourceCampaign: String = "", industry: String = "",
         guessedEmail: String = "", guessedEmailPattern: String = "", enrichmentCache: EnrichmentCacheEntry? = nil) {
        self.id = id; self.name = name; self.company = company; self.domain = domain; self.email = email
        self.status = status; self.notes = notes; self.created = created; self.type = type
        self.draft = draft; self.sendStatus = sendStatus; self.lastSent = lastSent
        self.tags = tags; self.phone = phone; self.address = address
        self.source = source; self.message = message; self.sourceCampaign = sourceCampaign; self.industry = industry
        self.guessedEmail = guessedEmail; self.guessedEmailPattern = guessedEmailPattern
        self.enrichmentCache = enrichmentCache
    }
    enum CodingKeys: String, CodingKey {
        case id, name, company, domain, email, status, notes, created, type, draft, sendStatus, lastSent, tags, phone, address
        case source, message, sourceCampaign, industry, guessedEmail, guessedEmailPattern, enrichmentCache
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        company = (try? c.decode(String.self, forKey: .company)) ?? ""
        domain = (try? c.decode(String.self, forKey: .domain)) ?? ""
        email = (try? c.decode(String.self, forKey: .email)) ?? ""
        status = (try? c.decode(ProspectStatus.self, forKey: .status)) ?? .new
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
        type = (try? c.decode(ProspectType.self, forKey: .type)) ?? .other
        draft = (try? c.decode(String.self, forKey: .draft)) ?? ""
        sendStatus = (try? c.decode(SendStatus.self, forKey: .sendStatus)) ?? .notSent
        lastSent = try? c.decode(Date.self, forKey: .lastSent)
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        phone = (try? c.decode(String.self, forKey: .phone)) ?? ""
        address = (try? c.decode(String.self, forKey: .address)) ?? ""
        source = (try? c.decode(LeadSource.self, forKey: .source)) ?? .manual
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        sourceCampaign = (try? c.decode(String.self, forKey: .sourceCampaign)) ?? ""
        industry = (try? c.decode(String.self, forKey: .industry)) ?? ""
        guessedEmail = (try? c.decode(String.self, forKey: .guessedEmail)) ?? ""
        guessedEmailPattern = (try? c.decode(String.self, forKey: .guessedEmailPattern)) ?? ""
        enrichmentCache = try? c.decode(EnrichmentCacheEntry.self, forKey: .enrichmentCache)
    }
}
#endif // circuit-convert

// MARK: - MK-17 waterfall enrichment cache (persisted on a Lead; audit record, no fabricated data)
// The stored outcome of the last provider-chain run for a lead's exact name+domain. Re-enrichment that
// finds a matching `signature` returns from here with ZERO network — instant and free. `winner`/`email`
// are empty when the waterfall ran but found nothing (honest exhausted-miss), so a re-run doesn't re-hit
// every provider only to discover the same nothing.
struct EnrichmentCacheEntry: Codable, Hashable {
    var signature: String            // normalized "name|domain" the outcome was computed for
    var winner: String = ""          // EnrichmentVendor.rawValue that produced the hit ("" if none)
    var email: String = ""           // the confirmed address the winner returned ("" if exhausted-miss)
    var confidence: Int? = nil       // provider-reported confidence, if any (nil otherwise)
    var at: Date = Date()            // when the run completed
    var attemptsSummary: [String] = []  // per-provider outcome record, e.g. ["hunter:noMatch","apollo:hit"]
    var isHit: Bool { !email.isEmpty }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Converters from the two legacy Marketing collections (used once by the Box upgrade
// and by any lingering import path; the legacy types remain decode-only).
extension Lead {
    init(legacy c: CapturedLead) {
        self.init(id: c.id, name: c.name, email: c.email, tags: [], phone: c.phone,
                  source: .siteForm, message: c.message, sourceCampaign: c.sourceCampaign)
        self.created = c.created
    }
    init(legacy c: ClientLead) {
        // A finder hit is a business, not a person — its name IS the company.
        self.init(id: c.id, company: c.name, domain: c.domain, email: c.email,
                  phone: c.phone, address: c.address, source: .finder, industry: c.industry)
        self.created = c.created
    }
}
#endif // circuit-convert

// MARK: - daily send record (real warmup pacing — counts actual SMTP-accepted sends per mailbox per day)
struct SendDay: Codable, Hashable {
    var mailboxID: UUID
    var day: String          // "yyyy-MM-dd"
    var count: Int
    var lastSentAt: Date? = nil  // durable per-mailbox pacing across app restarts
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Pipeline stages (Kanban columns). Buyer-orderable, with sensible defaults.
struct DealStage: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorHex: UInt32
    /// `won`/`lost` are terminal stages used for win-rate math; normal stages are open.
    var terminal: TerminalKind = .open
    enum TerminalKind: String, Codable { case open, won, lost }
    var color: Color { Color(hex: colorHex) }

    static let defaults: [DealStage] = [
        DealStage(name: "Lead",        colorHex: 0xC9A961, terminal: .open),
        DealStage(name: "Contacted",   colorHex: 0x4FD7FF, terminal: .open),
        DealStage(name: "Replied",     colorHex: 0xE8B04B, terminal: .open),
        DealStage(name: "Meeting Set", colorHex: 0xB066FF, terminal: .open),
        DealStage(name: "Proposal",    colorHex: 0xF9E27D, terminal: .open),
        DealStage(name: "Won",         colorHex: 0x4FD8A6, terminal: .won),
        DealStage(name: "Lost",        colorHex: 0xE56B6B, terminal: .lost),
    ]
}
#endif // circuit-convert

// MARK: - Deal (a tracked opportunity attached to a lead)
struct Deal: Identifiable, Codable, Hashable {
    var id = UUID()
    var prospectID: UUID            // on-wire name kept for Leads-app data compatibility
    var title: String = ""
    var stageID: UUID
    var value: Double = 0            // estimated/closed deal value in the buyer's currency
    var created = Date()
    var updated = Date()
    /// Manual ordering within a stage column (lower = higher in the column).
    var sort: Double = 0
}

// MARK: - Task / reminder (attached to a lead, optionally a deal)
struct LeadTask: Identifiable, Codable, Hashable {
    var id = UUID()
    var prospectID: UUID?
    var title: String = ""
    var due: Date? = nil
    var done: Bool = false
    var created = Date()

    var overdue: Bool { !done && (due.map { $0 < Date() } ?? false) }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Activity timeline entry (every meaningful event on a lead)
struct Activity: Identifiable, Codable, Hashable {
    var id = UUID()
    var prospectID: UUID
    var kind: Kind
    var detail: String = ""
    var at = Date()

    enum Kind: String, Codable, CaseIterable {
        case created, note, email_sent, email_replied, email_bounced
        case stage_changed, task_added, task_done, meeting_booked, imported, status_changed
        case call_logged, enriched, verified
        // Messaging channel (iMessage / RCS / SMS via the buyer's own Sendblue account, 2026-08).
        // `message_blocked` is first-class on purpose: a text the TCPA gate refused is a real event
        // the buyer must be able to see, not a silent no-op.
        case message_sent, message_received, message_blocked
        var label: String {
            switch self {
            case .created: return "Created"; case .note: return "Note"
            case .email_sent: return "Email sent"; case .email_replied: return "Reply received"
            case .email_bounced: return "Bounced"; case .stage_changed: return "Stage changed"
            case .task_added: return "Task added"; case .task_done: return "Task completed"
            case .meeting_booked: return "Meeting booked"; case .imported: return "Imported"
            case .status_changed: return "Status changed"
            case .call_logged: return "Call logged"; case .enriched: return "Enriched"; case .verified: return "Email verified"
            case .message_sent: return "Message sent"; case .message_received: return "Message received"
            case .message_blocked: return "Message blocked"
            }
        }
        var icon: String {
            switch self {
            case .created: return "sparkles"; case .note: return "text.bubble.fill"
            case .email_sent: return "paperplane.fill"; case .email_replied: return "arrowshape.turn.up.left.fill"
            case .email_bounced: return "exclamationmark.arrow.circlepath"; case .stage_changed: return "arrow.right.circle.fill"
            case .task_added: return "checklist"; case .task_done: return "checkmark.circle.fill"
            case .meeting_booked: return "calendar.badge.checkmark"; case .imported: return "tray.and.arrow.down.fill"
            case .status_changed: return "flag.fill"
            case .call_logged: return "phone.fill"; case .enriched: return "wand.and.stars"; case .verified: return "checkmark.shield.fill"
            case .message_sent: return "message.fill"; case .message_received: return "bubble.left.fill"
            case .message_blocked: return "hand.raised.fill"
            }
        }
        var tint: Color {
            switch self {
            case .email_replied, .task_done, .meeting_booked, .message_received: return BLTheme.green
            case .email_bounced, .message_blocked: return BLTheme.red
            case .email_sent, .message_sent: return .blue
            case .call_logged: return Color(hex: 0xB066FF)
            case .enriched, .verified: return BLTheme.gold
            case .stage_changed, .status_changed: return BLTheme.gold
            default: return BLTheme.sub
            }
        }
    }
}
#endif // circuit-convert

// MARK: - List / segment (a named, saved collection of leads)
struct LeadList: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var prospectIDs: [UUID] = []
    var created = Date()
}

// MARK: - Outreach sequences / cadences
// Multi-step (email + delay), per-step token templates, A/B subject testing, auto-stop on
// reply/bounce. The send path (SMTP) performs the real delivery; nothing here fabricates sends.

// The channel one cadence step delivers over. Added 2026-08 with the Sendblue messaging lane;
// it is OPTIONAL on the wire so every cadence saved before this build decodes unchanged and keeps
// behaving as email. Read it through `resolvedChannel`, never as a bare non-nil assumption.
enum OutreachChannel: String, Codable, CaseIterable, Identifiable {
    case email, message
    var id: String { rawValue }
    var label: String { self == .email ? "Email" : "Message (iMessage/SMS)" }
    var icon: String { self == .email ? "envelope.fill" : "message.fill" }
}

struct SequenceStep: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Days to wait AFTER the previous step (step 0 uses this as the delay from enrollment).
    var delayDays: Int = 0
    /// Primary subject. If `subjectB` is non-empty, the sequence A/B-tests the two.
    var subject: String = "Quick idea for {{company}}"
    var subjectB: String = ""
    var body: String = ""
    var enabled: Bool = true
    /// nil (the shipped default and every legacy record) == email. Never write a non-nil value
    /// unless the buyer explicitly chose the channel.
    var channel: OutreachChannel? = nil
    var resolvedChannel: OutreachChannel { channel ?? .email }

    /// Pick A or B deterministically per lead so the same lead always gets the same arm,
    /// and the split is ~50/50 across a list. Empty B → always A.
    func subject(for prospectID: UUID, salt: Int) -> (text: String, arm: String) {
        guard !subjectB.isEmpty else { return (subject, "A") }
        var h = Hasher(); h.combine(prospectID); h.combine(salt)
        return (h.finalize() & 1 == 0) ? (subject, "A") : (subjectB, "B")
    }
}

// A saved cadence. (Named OutreachSequence in the merged module so the Swift stdlib's
// Sequence protocol keeps its name; on-wire encoding is unchanged.)
struct OutreachSequence: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = "New Sequence"
    var steps: [SequenceStep] = []
    var stopOnReply: Bool = true
    var stopOnBounce: Bool = true
    var created = Date()
    var active: Bool = true

    var stepCount: Int { steps.filter { $0.enabled }.count }
    /// Total span in days from enrollment to the last enabled step.
    var spanDays: Int { steps.filter { $0.enabled }.reduce(0) { $0 + $1.delayDays } }

    static func starter() -> OutreachSequence {
        OutreachSequence(name: "3-Touch Cold Outreach", steps: [
            SequenceStep(delayDays: 0, subject: "Quick idea for {{company}}",
                         body: "Hi {{first}},\n\nI had one specific idea for {{company}} — worth a two-minute read?\n\n— {{sender}}"),
            SequenceStep(delayDays: 3, subject: "Re: Quick idea for {{company}}",
                         subjectB: "Following up, {{first}}",
                         body: "Hi {{first}},\n\nFloating this back to the top of your inbox. Happy to send the short breakdown if it's useful.\n\n— {{sender}}"),
            SequenceStep(delayDays: 4, subject: "Last note, {{first}}",
                         body: "Hi {{first}},\n\nI'll close the loop here — if the timing's ever right for {{company}}, just reply and I'll pick it back up.\n\n— {{sender}}"),
        ])
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - enrollment: a lead's live position in a sequence
struct Enrollment: Identifiable, Codable, Hashable {
    var id = UUID()
    var prospectID: UUID
    var sequenceID: UUID
    var mailboxID: UUID?          // which sending identity (nil = default)
    var stepIndex: Int = 0        // next step to send
    var enrolledAt = Date()
    var nextDue: Date             // when the next step is eligible to send
    var status: Status = .active
    /// per-step send log (stepIndex -> outcome) so analytics + auto-stop are grounded.
    var sends: [StepSend] = []

    enum Status: String, Codable {
        case active, completed, stopped_reply, stopped_bounce, stopped_manual, failed
        var label: String {
            switch self {
            case .active: return "Active"; case .completed: return "Completed"
            case .stopped_reply: return "Stopped — replied"; case .stopped_bounce: return "Stopped — bounced"
            case .stopped_manual: return "Paused"; case .failed: return "Failed"
            }
        }
        var tint: Color {
            switch self {
            case .active: return .blue; case .completed: return BLTheme.sub
            case .stopped_reply: return BLTheme.green; case .stopped_bounce: return BLTheme.red
            case .stopped_manual: return BLTheme.gold; case .failed: return BLTheme.red
            }
        }
        var isOpen: Bool { self == .active }
    }
}
#endif // circuit-convert

struct StepSend: Codable, Hashable {
    var stepIndex: Int
    var at: Date
    var subjectArm: String       // "A" / "B"
    var sent: Bool               // true if SMTP accepted; false if gate/transport blocked
    var detail: String = ""
}
