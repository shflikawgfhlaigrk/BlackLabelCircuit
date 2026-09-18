// Black Label Marketing — Journey execution + deliverability discipline.
//
// Makes drip journeys actually RUN (not just simulate): contacts enroll, advance through waits over
// real calendar time, and their next email becomes DUE — queued within a daily warmup cap, sent from
// a chosen sender identity, on validated/clean addresses. The shared transport commits progress only
// after provider acceptance. Pure scheduling/cursor logic here is deterministic and unit-tested.
import Foundation

// MARK: - Distinct senders (per-journey "from" identity)

struct SenderIdentity: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var email: String = ""
    var label: String { name.isEmpty ? email : "\(name) <\(email)>" }
}

// MARK: - Warmup pacing

struct WarmupSchedule: Codable, Hashable {
    var enabled: Bool = true
    var startCap: Int = 20         // emails/day on day 1
    var dailyIncrease: Int = 10    // +N per day
    var maxCap: Int = 200          // ceiling
    static let `default` = WarmupSchedule()

    /// The send cap for a sender on a given warmup day (day 0 = first day).
    func cap(onDay day: Int) -> Int {
        guard enabled else { return maxCap }
        return min(maxCap, startCap + max(0, day) * dailyIncrease)
    }
}

// MARK: - Clean lists (email validation)

enum EmailValidator {
    /// Pragmatic RFC-5322-ish validation: local@domain.tld, no spaces, sane characters, a dotted
    /// domain. Deterministic; rejects the obviously-undeliverable so warmup/lists stay clean.
    static func isValid(_ raw: String) -> Bool {
        let e = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard e.count >= 6, e.count <= 254, !e.contains(" ") else { return false }
        let pattern = #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#
        return e.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Filter a list to deliverable, de-duplicated (case-insensitive) addresses.
    static func clean(_ emails: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for e in emails {
            let t = e.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = t.lowercased()
            guard isValid(t), !seen.contains(key) else { continue }
            seen.insert(key); out.append(t)
        }
        return out
    }
}

// MARK: - Journey run state (one enrolled contact's progress)

struct JourneyRun: Identifiable, Codable, Hashable {
    var id = UUID()
    var journeyID: UUID
    var contactEmail: String       // stable contact identity
    var enrolledAt: Date
    var sendsCompleted: Int = 0    // how many of the journey's sends have fired
    var lastActionAt: Date?
    var done: Bool = false
}

/// A queued, due email the executor produced for the operator to send (via their own mailbox).
struct DueSend: Identifiable, Hashable {
    var runID: UUID
    var id: UUID { runID }
    var journeyID: UUID
    var journeyName: String
    var contactEmail: String
    var campaignName: String
    var senderLabel: String
    var expectedSendIndex: Int
    var completesRun: Bool
}

enum JourneyExecutor {
    /// The ordered send schedule of a journey: each send's cumulative day-offset from enrollment
    /// (sum of preceding waits). Branch steps are ignored here (per-contact tag gating happens at
    /// enrollment); deterministic.
    static func schedule(_ steps: [JourneyStep]) -> [(dayOffset: Int, campaign: String)] {
        var day = 0; var out: [(Int, String)] = []
        for s in steps {
            switch s.kind {
            case .wait: day += max(0, s.waitDays)
            case .send: out.append((day, s.campaignName))
            case .trigger, .branch: break
            }
        }
        return out
    }

    /// Days between two dates (calendar days, floored at 0).
    static func daysBetween(_ from: Date, _ to: Date) -> Int {
        max(0, Int(to.timeIntervalSince(from) / 86_400))
    }

    /// Inspect runs at `now`. For each active run whose next scheduled send's day-offset has elapsed,
    /// emit that send as DUE without moving its cursor. Cursor movement is a separate landed-delivery
    /// commit below; a preview, blocked transport, or process interruption therefore stays due.
    /// Returns the due sends plus runs normalized only for already-exhausted schedules.
    static func tick(journeys: [Journey], runs: [JourneyRun], now: Date,
                     dailyCap: Int, senderLabel: (UUID) -> String) -> (due: [DueSend], runs: [JourneyRun]) {
        let byID = Dictionary(uniqueKeysWithValues: journeys.map { ($0.id, $0) })
        var updated = runs
        var due: [DueSend] = []
        for i in updated.indices {
            if due.count >= dailyCap { break }
            var run = updated[i]
            guard !run.done, let j = byID[run.journeyID], j.enabled else { continue }
            let sched = schedule(j.steps)
            guard run.sendsCompleted < sched.count else { run.done = true; updated[i] = run; continue }
            let next = sched[run.sendsCompleted]
            if daysBetween(run.enrolledAt, now) >= next.dayOffset {
                due.append(DueSend(runID: run.id, journeyID: j.id, journeyName: j.name,
                                   contactEmail: run.contactEmail, campaignName: next.campaign,
                                   senderLabel: senderLabel(j.id), expectedSendIndex: run.sendsCompleted,
                                   completesRun: run.sendsCompleted + 1 >= sched.count))
            }
        }
        return (due, updated)
    }

    /// Commit exactly one provider-confirmed due send. The expected index makes retries idempotent:
    /// replaying a result after the cursor already moved is a no-op.
    @discardableResult
    static func markLanded(_ send: DueSend, runs: inout [JourneyRun], at: Date) -> Bool {
        guard let i = runs.firstIndex(where: { $0.id == send.runID }),
              !runs[i].done, runs[i].sendsCompleted == send.expectedSendIndex else { return false }
        runs[i].sendsCompleted += 1
        runs[i].lastActionAt = at
        if send.completesRun { runs[i].done = true }
        return true
    }
}

// MARK: - Newsletters (recurring broadcast on the buyer's own list)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct Newsletter: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var subject: String = ""
    var body: String = ""
    var segmentID: UUID? = nil
    var cadenceDays: Int = 7        // recurring cadence
    var lastSentAt: Date? = nil
    var deliveryProgress: NewsletterDeliveryProgress? = nil
    var created = Date()

    /// Is this newsletter due to go out again, given `now`?
    func isDue(now: Date) -> Bool {
        if deliveryProgress != nil { return true }
        guard let last = lastSentAt else { return true }
        return JourneyExecutor.daysBetween(last, now) >= max(1, cadenceDays)
    }
}
#endif // circuit-convert
