// Black Label Marketing — Email Journeys (drip automation) — Tier 2.
// A visual automation: an ordered list of steps (trigger → wait → send → branch).
// The simulator walks the journey deterministically over the buyer's OWN contacts —
// computing the day each email would fire — with NO fabricated opens/clicks/delivery.
// Actual sending reuses the honest mailto compose path the Email Builder already uses.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

enum JourneyStepKind: String, CaseIterable, Codable, Identifiable {
    case trigger, wait, send, branch
    var id: String { rawValue }
    var label: String {
        switch self {
        case .trigger: return "Trigger"; case .wait: return "Wait"; case .send: return "Send"; case .branch: return "Branch if tag"
        }
    }
    var icon: String {
        switch self {
        case .trigger: return "bolt.fill"; case .wait: return "hourglass"; case .send: return "paperplane.fill"; case .branch: return "arrow.triangle.branch"
        }
    }
}

struct JourneyStep: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: JourneyStepKind = .send
    var waitDays: Int = 1              // for .wait
    var campaignID: UUID? = nil        // for .send — references an EmailCampaign
    var campaignName: String = ""      // denormalized label for display/simulation
    var branchTag: String = ""         // for .branch — contacts WITHOUT this tag skip downstream sends
    var note: String = ""              // for .trigger — what kicks off the journey (e.g. "New lead")
    /// Which channel a `.send` step delivers over. OPTIONAL on the wire (added 2026-08 with the
    /// Sendblue messaging lane) so every journey saved by an earlier build decodes unchanged and
    /// keeps sending email. Read it through `resolvedChannel`.
    var channel: OutreachChannel? = nil
    var resolvedChannel: OutreachChannel { channel ?? .email }
}

extension JourneyStepKind {
    /// The channels a step kind can carry. Only `.send` has one — waits and branches are
    /// channel-agnostic, so the UI must not offer a channel picker on them.
    var supportsChannel: Bool { self == .send }
}

struct Journey: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var enabled: Bool = false          // ships OFF; the buyer turns it on explicitly
    var segmentID: UUID? = nil         // who enters (a saved Segment), nil = all contacts
    var senderID: UUID? = nil          // which SenderIdentity sends this journey (distinct senders)
    var steps: [JourneyStep] = []
    var created = Date()
}

struct JourneyEvent: Equatable { var day: Int; var campaign: String }

enum JourneyEngine {
    /// Walk the journey for one contact: accumulate SEND events with the cumulative
    /// day they fire (sum of preceding waits). A branch step gates downstream sends:
    /// if the contact lacks the branch tag, subsequent sends are skipped until the
    /// next branch. Deterministic — no randomness, no fabricated engagement.
    static func simulate(_ steps: [JourneyStep], contactTags: [String]) -> [JourneyEvent] {
        var day = 0, gated = false
        var out: [JourneyEvent] = []
        for s in steps {
            switch s.kind {
            case .trigger: break
            case .wait: day += max(0, s.waitDays)
            case .branch: gated = !contactTags.contains(s.branchTag)
            case .send: if !gated { out.append(JourneyEvent(day: day, campaign: s.campaignName)) }
            }
        }
        return out
    }
    static func span(_ steps: [JourneyStep]) -> Int { steps.filter { $0.kind == .wait }.reduce(0) { $0 + max(0, $1.waitDays) } }
    static func sendCount(_ steps: [JourneyStep]) -> Int { steps.filter { $0.kind == .send }.count }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    func upsertJourney(_ j: Journey) {
        if let i = journeys.firstIndex(where: { $0.id == j.id }) { journeys[i] = j } else { journeys.insert(j, at: 0) }
    }
    func deleteJourney(_ j: Journey) {
        journeys.removeAll { $0.id == j.id }
        journeyRuns.removeAll { $0.journeyID == j.id }
    }

    // Sender identities (distinct "from" addresses) + newsletters
    func addSender(_ s: SenderIdentity) { senders.append(s) }
    func deleteSender(_ s: SenderIdentity) { senders.removeAll { $0.id == s.id } }
    func upsertNewsletter(_ n: Newsletter) {
        if let i = newsletters.firstIndex(where: { $0.id == n.id }) { newsletters[i] = n } else { newsletters.insert(n, at: 0) }
    }
    func deleteNewsletter(_ n: Newsletter) { newsletters.removeAll { $0.id == n.id } }

    /// The contacts that enter a journey: its saved segment, or the whole clean pool.
    func contactsForJourney(_ j: Journey) -> [Contact] {
        let pool = allContacts
        guard let sid = j.segmentID, let seg = segments.first(where: { $0.id == sid }) else { return pool }
        return pool.filter { SegEngine.matches(seg, $0) }
    }

    /// Enroll not-yet-enrolled contacts without moving any delivery cursor.
    @discardableResult
    func enrollJourneyContacts(now: Date) -> Int {
        var enrolled = 0
        for j in journeys where j.enabled {
            for c in contactsForJourney(j) where EmailValidator.isValid(c.email) {
                let key = c.email.lowercased()
                if !journeyRuns.contains(where: { $0.journeyID == j.id && $0.contactEmail.lowercased() == key }) {
                    journeyRuns.append(JourneyRun(journeyID: j.id, contactEmail: c.email, enrolledAt: now))
                    enrolled += 1
                }
            }
        }
        return enrolled
    }

    /// Preview the currently due sends. Kept for non-network callers; it deliberately does not move
    /// cursors. The real UI uses `JourneyExecutor.runDue`, which commits each cursor only after the
    /// shared transport reports a landed delivery.
    @discardableResult
    func runJourneys(now: Date, warmup: WarmupSchedule) -> [DueSend] {
        enrollJourneyContacts(now: now)
        let cap = warmup.cap(onDay: 0)
        let label: (UUID) -> String = { [weak self] jid in
            guard let self = self, let j = self.journeys.first(where: { $0.id == jid }),
                  let sid = j.senderID, let s = self.senders.first(where: { $0.id == sid }) else { return "your mailbox" }
            return s.label
        }
        let (due, _) = JourneyExecutor.tick(journeys: journeys, runs: journeyRuns, now: now, dailyCap: cap, senderLabel: label)
        return due
    }
}
#endif // circuit-convert
