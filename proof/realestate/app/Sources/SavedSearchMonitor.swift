// Black Label Real Estate — RE-21 saved-search monitors (real deltas, un-metered).
//
// PropertyRadar sells an alert engine that pings you when a NEW property matches a saved search.
// This is the honest, un-metered version: each buyer-triggered check ("Check all now" — no
// background scheduler exists in this build) re-runs the SAME database query, and we fire a native
// notification ONLY when a genuinely NEW parcel appears in the result set — a parcel present now
// that was absent the last time we looked. The "new" set is derived PURELY from the delta of two
// real /v1/search result sets; we NEVER synthesize a match.
//
// Two honesty rules are baked into the pure diff below:
//   1. The FIRST observation of a saved search BASELINES SILENTLY — it records the current result
//      keys and fires nothing (otherwise every new saved search would notify for its whole result
//      set, a notification storm on data that isn't actually new to the world).
//   2. A row that DISAPPEARS from the results (sold, de-listed, re-categorized) drops out of the
//      baseline and is never later re-flagged as "new" — removal is not a new match.
//
// The diff, keying, and notification copy are PURE (no I/O, no UserNotifications), so the whole
// decision path is unit-tested. SavedSearchMonitorScreen.swift performs the live re-run + posts the
// UNUserNotificationCenter notification and deep-links the tap back into the List Builder.
import Foundation

// MARK: - A saved search that is monitored across index refreshes (persisted on-device).
struct SavedSearch: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var criteria: DatabaseListCriteria = DatabaseListCriteria()  // the exact query we re-run each cycle
    /// The parcel keys observed on the LAST successful run. Empty + `baselined == false` until the
    /// first observation. This is the "what did we already know about" set the delta subtracts.
    var baselineKeys: Set<String> = []
    /// False until the first result set has been observed. Guards the silent-baseline rule.
    var baselined: Bool = false
    var enabled: Bool = true
    var createdAt = Date()
    var lastCheckedAt: Date? = nil
    var lastNewCount: Int = 0

    var areaLabel: String {
        let a = criteria.area.summary
        return a.isEmpty ? "your saved area" : a
    }
    /// Short line for the monitor list ("Absentee owners · Fulton County, GA").
    var summary: String { criteria.summary }
}

// MARK: - The result of observing one fresh result set against a saved search's baseline.
struct SavedSearchDelta: Equatable {
    /// Parcel keys present NOW that were absent from the baseline — the genuinely new matches.
    var newKeys: [String] = []
    /// True when this run was the silent first baseline (no notification is ever fired for it).
    var wasBaselinedThisRun: Bool = false
    /// Total matches in the current result set (for the "N total, M new" line).
    var totalNow: Int = 0
    var newCount: Int { newKeys.count }
    /// A notification fires ONLY on a real, non-baseline delta with at least one new parcel.
    var shouldNotify: Bool { !wasBaselinedThisRun && newCount > 0 }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum SavedSearchMonitorEngine {
    /// The stable identity of a property row across refreshes. Reuses the same dedupe key the List
    /// Builder uses so "the same parcel" is judged identically to import de-duplication; falls back to
    /// the index row id when a record has no parcel/owner identity yet.
    static func matchKey(for record: PropertyRecord) -> String {
        DatabaseLeadImport.dedupeKey(for: record) ?? record.id
    }
    static func matchKeys(_ records: [PropertyRecord]) -> Set<String> {
        Set(records.map(matchKey))
    }

    /// PURE diff: given a saved search's stored baseline and the fresh result keys, compute what's new.
    /// First observation (`baselined == false`) baselines silently — no keys are ever reported new, so
    /// a freshly-saved search can't storm the buyer with its entire result set.
    static func delta(baseline: Set<String>, baselined: Bool, current: Set<String>) -> SavedSearchDelta {
        var d = SavedSearchDelta()
        d.totalNow = current.count
        guard baselined else {
            d.wasBaselinedThisRun = true   // silent baseline — nothing is "new" the first time we look
            return d
        }
        // Genuinely new = present now, absent before. Sorted for deterministic notification copy/tests.
        d.newKeys = current.subtracting(baseline).sorted()
        return d
    }

    /// Observe a fresh result set for a saved search: returns the delta AND the search with its
    /// baseline advanced to the current set. The baseline is REPLACED (not unioned), so removed rows
    /// drop out and are never re-flagged as new on a later run, and a re-run with no change is a no-op.
    static func observe(_ search: SavedSearch, current: [PropertyRecord], at: Date = Date()) -> (SavedSearch, SavedSearchDelta) {
        let keys = matchKeys(current)
        let d = delta(baseline: search.baselineKeys, baselined: search.baselined, current: keys)
        var s = search
        s.baselineKeys = keys
        s.baselined = true
        s.lastCheckedAt = at
        s.lastNewCount = d.newCount
        return (s, d)
    }

    // MARK: Notification content (pure copy the notifier hands to UNUserNotificationCenter).
    static func notificationTitle(_ search: SavedSearch) -> String {
        "New match — \(search.name.isEmpty ? "Saved search" : search.name)"
    }
    static func notificationBody(_ search: SavedSearch, newCount: Int) -> String {
        let noun = newCount == 1 ? "property" : "properties"
        return "\(newCount) new \(noun) match \"\(search.name)\" in \(search.areaLabel). Open the List Builder to review."
    }
    /// Deep link the notification tap resolves — routes back into the List Builder for this search.
    static let deepLinkScheme = "blre"
    static func deepLink(_ search: SavedSearch) -> String {
        "\(deepLinkScheme)://listbuilder?saved=\(search.id.uuidString)"
    }
    /// Parse a saved-search id back out of a deep link (nil if it isn't one of ours).
    static func savedSearchID(fromDeepLink link: String) -> UUID? {
        guard let c = URLComponents(string: link), c.scheme == deepLinkScheme, c.host == "listbuilder",
              let raw = c.queryItems?.first(where: { $0.name == "saved" })?.value else { return nil }
        return UUID(uuidString: raw)
    }
    /// Honest empty-state copy for the monitor list before any search is saved.
    static let emptyNote = "No saved-search monitors yet. Save a List-Builder search here and every Check all now re-runs it, notifying you only when a genuinely new parcel appears — nothing is invented, and there's no per-alert charge."
}
#endif // circuit-convert

// MARK: - On-device persistence for the buyer's saved-search monitors (JSON in UserDefaults).
// Local custody: the monitor set never leaves this Mac; it only stores query criteria + parcel keys.
struct SavedSearchStore {
    private let key = "bl.realestate.saved_searches.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [SavedSearch] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return [] }
        return list
    }
    func save(_ list: [SavedSearch]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
    }
    /// Insert or replace a search by id, persist, and return the updated list.
    @discardableResult
    func upsert(_ search: SavedSearch) -> [SavedSearch] {
        var list = load()
        if let i = list.firstIndex(where: { $0.id == search.id }) { list[i] = search } else { list.append(search) }
        save(list)
        return list
    }
    @discardableResult
    func remove(_ id: UUID) -> [SavedSearch] {
        let list = load().filter { $0.id != id }
        save(list)
        return list
    }
}
