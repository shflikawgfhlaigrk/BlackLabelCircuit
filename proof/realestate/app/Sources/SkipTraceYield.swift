// Black Label Real Estate — SKIP-TRACE YIELD (pre-charge transparency from the buyer's OWN history).
//
// RE-17 (FULL-STANDARD): before a buyer spends their skip-trace provider credits, show what THEIR OWN
// past traces on THIS Mac actually yielded — the right-party hit-rate and how many returned phones
// their Do-Not-Contact list scrubbed. This beats PropStream's opaque yield and BatchLeads' silent DNC
// scrub. The honesty rule (§5.1): every number is derived ONLY from the buyer's real local trace
// outcomes. With no history there is NO estimate — the UI shows "no trace history yet on this Mac".
// A percentage is never fabricated, seeded, or borrowed from a vendor benchmark.
import Foundation

// MARK: - One recorded trace outcome (all counts are real results of a trace the buyer actually ran).
struct SkipTraceOutcome: Codable, Hashable {
    var traced: Int          // owners/leads traced in this run (≥1)
    var rightPartyHits: Int  // of those, how many returned at least one phone OR email
    var phonesReturned: Int  // total phone numbers the provider returned
    var dncRemoved: Int      // of those phones, how many were on the buyer's own DNC/suppression list
}

// MARK: - Rolling local history (persisted on-device; the ONLY basis for a shown yield number).
struct SkipTraceHistory: Codable, Hashable {
    var traces = 0            // number of recorded trace runs
    var traced = 0           // total owners/leads traced
    var rightPartyHits = 0
    var phonesReturned = 0
    var dncRemoved = 0

    var hasHistory: Bool { traced > 0 }

    /// Right-party hit-rate (0…1) over the buyer's own traces, or nil when there's nothing to divide.
    var hitRate: Double? { traced > 0 ? Double(rightPartyHits) / Double(traced) : nil }
    /// Share of returned phones that were scrubbed by the buyer's DNC list (0…1), or nil if no phones yet.
    var dncRemovalRate: Double? { phonesReturned > 0 ? Double(dncRemoved) / Double(phonesReturned) : nil }
    /// Average phones returned per trace — used to project a DNC-removed COUNT for an upcoming batch.
    var phonesPerTrace: Double? { traced > 0 ? Double(phonesReturned) / Double(traced) : nil }

    /// Fold one real outcome in. Negative inputs are clamped (a count can't be negative), and
    /// rightPartyHits/dncRemoved can never exceed their parent totals (never over-count a yield).
    mutating func record(_ o: SkipTraceOutcome) {
        let t = max(0, o.traced)
        let hits = min(max(0, o.rightPartyHits), t)
        let phones = max(0, o.phonesReturned)
        let dnc = min(max(0, o.dncRemoved), phones)
        guard t > 0 else { return }   // a zero-lead trace isn't a data point
        traces += 1
        traced += t
        rightPartyHits += hits
        phonesReturned += phones
        dncRemoved += dnc
    }
}

// MARK: - What the pre-charge panel shows for an upcoming batch of `batchSize` traces.
struct SkipTraceYieldProjection: Hashable {
    var sampleTraces: Int        // how many prior traces the estimate rests on (shown for honesty)
    var batchSize: Int
    var hitRate: Double          // 0…1
    var expectedRightPartyHits: Int
    var dncRemovalRate: Double   // 0…1 (0 when no phones have been returned yet)
    var expectedDNCRemoved: Int

    static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    /// "≈62% return a right-party contact (based on your last 40 traces on this Mac)."
    var hitRateLine: String {
        "≈\(Self.pct(hitRate)) return a right-party contact (based on your last \(sampleTraces) trace\(sampleTraces == 1 ? "" : "s") on this \(kThisDeviceWord))."
    }
    /// "Tracing 12 → expect ≈7 with a phone or email."
    var batchLine: String {
        "Tracing \(batchSize) → expect ≈\(expectedRightPartyHits) with a phone or email."
    }
    /// DNC transparency: rate + projected removed count, or an honest "none scrubbed yet".
    var dncLine: String {
        guard dncRemovalRate > 0 || expectedDNCRemoved > 0 else {
            return "None of your returned phones have hit your DNC list yet — 0 expected to be removed."
        }
        return "≈\(Self.pct(dncRemovalRate)) of returned phones are on your DNC list — ≈\(expectedDNCRemoved) will be removed before you contact them."
    }
}

enum SkipTraceYield {
    /// The honest empty state — shown verbatim when the buyer has no local trace history.
    static let noHistoryNote =
        "No trace history yet on this \(kThisDeviceWord) — your right-party hit-rate and DNC-removed count appear here after your first trace. We never show an estimate you haven't earned."

    /// Project yield for an upcoming batch PURELY from the buyer's own history.
    /// Returns nil when there is no history (→ caller shows `noHistoryNote`), never a made-up rate.
    static func projection(history: SkipTraceHistory, batchSize: Int) -> SkipTraceYieldProjection? {
        guard history.hasHistory, let hitRate = history.hitRate else { return nil }
        let n = max(1, batchSize)
        let dncRate = history.dncRemovalRate ?? 0
        let expectedPhones = (history.phonesPerTrace ?? 0) * Double(n)
        return SkipTraceYieldProjection(
            sampleTraces: history.traced,
            batchSize: n,
            hitRate: hitRate,
            expectedRightPartyHits: Int((hitRate * Double(n)).rounded()),
            dncRemovalRate: dncRate,
            expectedDNCRemoved: Int((dncRate * expectedPhones).rounded()))
    }
}

// MARK: - On-device persistence for the history (never uploaded; scoped to the app's own defaults).
// Thin wrapper over UserDefaults so the pre-charge panel survives relaunch. The projection math above
// is pure and unit-tested independently of this store.
enum SkipTraceYieldStore {
    private static let key = "com.blacklabel.realestate.skiptrace.yield.v1"
    private static var defaults: UserDefaults { .standard }

    static func load() -> SkipTraceHistory {
        guard let data = defaults.data(forKey: key),
              let h = try? JSONDecoder().decode(SkipTraceHistory.self, from: data) else { return SkipTraceHistory() }
        return h
    }

    static func save(_ h: SkipTraceHistory) {
        if let data = try? JSONEncoder().encode(h) { defaults.set(data, forKey: key) }
    }

    /// Record one real trace outcome and return the updated history (for the caller to re-render).
    @discardableResult
    static func record(_ outcome: SkipTraceOutcome) -> SkipTraceHistory {
        var h = load()
        h.record(outcome)
        save(h)
        return h
    }

    static func reset() { defaults.removeObject(forKey: key) }
}
