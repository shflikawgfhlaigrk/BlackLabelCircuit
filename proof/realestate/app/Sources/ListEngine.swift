#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — LIST BUILDER (filters + saved smart lists + LIST STACKING).
//
// The category moat of PropStream / BatchLeads / REsimpli: build a targeted list from many
// property/owner filters, SAVE it as a reusable smart list, and STACK lists to find the most
// motivated sellers (owners who appear on 2+ distressed lists). This runs entirely on the
// buyer's OWN captured leads — no fabricated rows, no external data. Filters are honest: they
// only key on fields the lead actually has (source, county, assessed value, equity signals,
// absentee/ownership confidence, tasks, status). Missing data => the lead simply doesn't match
// a filter that needs it (never a faked value to make it match).
import Foundation

// MARK: - A single filter predicate over a Lead. All optional; nil = "don't filter on this".
struct LeadFilter: Codable, Hashable {
    // Source / pipeline
    var sources: Set<LeadSource> = []           // empty = any source
    var statuses: Set<LeadStatus> = []          // empty = any stage
    var counties: Set<String> = []              // empty = any county (case-insensitive match)

    // Value band (county-assessed). nil bound = open-ended.
    var minValue: Int? = nil
    var maxValue: Int? = nil

    // Owner / property signals
    var absenteeOnly = false                    // mailing != situs (the classic absentee tell)
    var hasPhone: Bool? = nil                   // true = must have a phone; false = must NOT; nil = any
    var hasEmail: Bool? = nil
    var hasMailingAddress: Bool? = nil          // direct-mail-ready
    var resolvedOnly = false                    // parcel-resolved (has a real situs address)
    var ownershipConfidence: Set<String> = []   // "high"/"medium"/"low"
    var hasOpenTasks: Bool? = nil

    // Free-text contains (name / address / notes)
    var text: String = ""

    /// Does this lead match every active criterion?
    func matches(_ l: Lead) -> Bool {
        if !sources.isEmpty, !sources.contains(l.source) { return false }
        if !statuses.isEmpty, !statuses.contains(l.status) { return false }
        if !counties.isEmpty, !counties.contains(where: { $0.caseInsensitiveCompare(l.county) == .orderedSame }) { return false }
        if let mn = minValue, l.assessedValue < mn { return false }
        if let mx = maxValue, (l.assessedValue == 0 || l.assessedValue > mx) { return false }
        if absenteeOnly, !l.isAbsentee { return false }
        if let p = hasPhone, l.phone.isEmpty == p { return false }
        if let e = hasEmail, l.email.isEmpty == e { return false }
        if let m = hasMailingAddress, l.mailingAddress.isEmpty == m { return false }
        if resolvedOnly, l.routableAddress == nil { return false }
        if !ownershipConfidence.isEmpty, !ownershipConfidence.contains(l.ownershipConfidence.lowercased()) { return false }
        if let t = hasOpenTasks, (l.openTasks > 0) != t { return false }
        if !text.isEmpty {
            let q = text.lowercased()
            let hay = [l.name, l.propertyAddress, l.mailingAddress, l.ownerName, l.notes, l.sourceDetail].joined(separator: " ").lowercased()
            if !hay.contains(q) { return false }
        }
        return true
    }

    /// Count of active (non-default) criteria — drives the "N filters" chip in the UI.
    var activeCount: Int {
        var n = 0
        if !sources.isEmpty { n += 1 }; if !statuses.isEmpty { n += 1 }; if !counties.isEmpty { n += 1 }
        if minValue != nil { n += 1 }; if maxValue != nil { n += 1 }
        if absenteeOnly { n += 1 }; if hasPhone != nil { n += 1 }; if hasEmail != nil { n += 1 }
        if hasMailingAddress != nil { n += 1 }; if resolvedOnly { n += 1 }
        if !ownershipConfidence.isEmpty { n += 1 }; if hasOpenTasks != nil { n += 1 }
        if !text.isEmpty { n += 1 }
        return n
    }
    var isEmpty: Bool { activeCount == 0 }
}

// MARK: - A saved, reusable smart list (a named filter). Persisted with the model.
// `memberIDs` is the set of lead IDs that matched at the last sync — the anchor that lets
// LIST AUTOMATION detect both NEW matches (auto-add) and DROPPED matches (auto-remove: a
// cured foreclosure, a sold home, a disqualified lead). `autoMaintain` opts the list into
// bidirectional automation; off = a plain saved filter.
struct SmartList: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var filter = LeadFilter()
    var created = Date()
    var autoMaintain = true                 // bidirectional add+remove on sync
    var memberIDs: Set<UUID> = []           // members at last sync (the diff anchor)
    var lastSynced: Date? = nil
}

// MARK: - The result of reconciling a saved list against the current lead set.
// This is the heart of bidirectional list automation: which leads newly QUALIFY (added) and
// which NO LONGER qualify (removed) since the list last synced. Removals are the feature
// PropStream/BatchLeads gate behind their paid "list automation" — a lead whose foreclosure
// cured, whose home sold, or who was disqualified silently rots on a static list otherwise.
struct ListSyncResult: Hashable {
    var listID: UUID
    var added: [Lead] = []                  // newly match the filter (weren't members before)
    var removed: [Lead] = []                 // were members, no longer match (cured / sold / DQ'd)
    var stillMatching: Int = 0              // members that continue to qualify
    var hasChanges: Bool { !added.isEmpty || !removed.isEmpty }
}

// MARK: - Distressed lead-list TEMPLATES (the category's named motivated-seller lists).
// Modeled on PropStream's 20 lead lists, but each maps ONLY to signals this product can verify
// from the buyer's own captured leads + free county data — never a fabricated list. Where a list
// needs a data signal the free tier can't see (e.g. true equity %, MLS status, vacancy), the
// template is honestly labeled "needs <signal>" and filters on the closest real proxy, so the
// buyer knows what it can and can't prove. No faked rows, ever.
struct ListTemplate: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let blurb: String            // what this list targets + what real signal it keys on
    let needs: String            // honest note on any data the free tier can't fully verify ("" = fully supported)
    let filter: LeadFilter
}

enum ListTemplates {
    static let all: [ListTemplate] = [
        ListTemplate(name: "Probate / inherited", blurb: "Owners who inherited via probate — the warmest motivated-seller list.",
                     needs: "", filter: { var f = LeadFilter(); f.sources = [.probate]; return f }()),
        ListTemplate(name: "Pre-foreclosure", blurb: "Owners in default / notice-of-sale captured from legal notices.",
                     needs: "", filter: { var f = LeadFilter(); f.sources = [.preForeclosure]; return f }()),
        ListTemplate(name: "Tax delinquent", blurb: "Owners behind on property taxes (imported county rolls).",
                     needs: "", filter: { var f = LeadFilter(); f.sources = [.taxDelinquent]; return f }()),
        ListTemplate(name: "Code violations", blurb: "Properties with open code-enforcement cases (imported city data).",
                     needs: "", filter: { var f = LeadFilter(); f.sources = [.codeViolation]; return f }()),
        ListTemplate(name: "Absentee owners", blurb: "Owner mailing address differs from the property (classic absentee tell).",
                     needs: "", filter: { var f = LeadFilter(); f.absenteeOnly = true; f.resolvedOnly = true; return f }()),
        ListTemplate(name: "High-value (50%+ equity proxy)", blurb: "High assessed-value parcels — the equity proxy when no mortgage balance is published free.",
                     needs: "True equity % needs a mortgage-balance feed (gated). Filters on assessed value as the free proxy.",
                     filter: { var f = LeadFilter(); f.minValue = 250_000; return f }()),
        ListTemplate(name: "Vacant (needs USPS)", blurb: "Likely-vacant absentee owners — the 'zombie' overlap.",
                     needs: "USPS vacancy is a paid feed (gated). Approximated by absentee + probate; confirm vacancy before mailing.",
                     filter: { var f = LeadFilter(); f.absenteeOnly = true; f.sources = [.probate]; return f }()),
        ListTemplate(name: "New construction / builders", blurb: "Active builders & trades to source new-build deals and JV.",
                     needs: "", filter: { var f = LeadFilter(); f.sources = [.builder]; return f }()),
        ListTemplate(name: "Mail-ready (direct-mail)", blurb: "Leads with a resolved owner-mailing address — ready for a postcard drop.",
                     needs: "", filter: { var f = LeadFilter(); f.hasMailingAddress = true; return f }()),
        ListTemplate(name: "No contact yet", blurb: "Captured leads with no phone or email — send to skip trace next.",
                     needs: "", filter: { var f = LeadFilter(); f.hasPhone = false; f.hasEmail = false; return f }()),
        ListTemplate(name: "Working / has tasks", blurb: "Leads you're actively working (open follow-up tasks).",
                     needs: "", filter: { var f = LeadFilter(); f.hasOpenTasks = true; return f }()),
        ListTemplate(name: "High-confidence ownership", blurb: "Parcel match where the recorded owner strongly matches the lead — trust the address.",
                     needs: "", filter: { var f = LeadFilter(); f.ownershipConfidence = ["high"]; return f }()),
    ]
}

// MARK: - The engine: apply filters, stack lists, export CSV.
enum ListEngine {
    static func norm(_ s: String) -> String {
        s.uppercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Apply one filter to a lead set.
    static func apply(_ filter: LeadFilter, to leads: [Lead]) -> [Lead] {
        leads.filter { filter.matches($0) }
    }

    /// Count how many leads match each of several filters in a SINGLE pass over the lead set.
    /// The List Builder shows a live count badge on every distressed-list template chip; doing one
    /// `apply` per chip is O(templates × leads) re-run on every render (and the screen re-renders on
    /// each keystroke in the text filter). This collapses it to one pass: each lead is tested against
    /// all filters once. Returns parallel-indexed counts for `filters`.
    static func counts(_ filters: [LeadFilter], over leads: [Lead]) -> [Int] {
        var out = [Int](repeating: 0, count: filters.count)
        for l in leads {
            for (i, f) in filters.enumerated() where f.matches(l) { out[i] += 1 }
        }
        return out
    }

    /// LIST STACKING — leads that appear in `minListCount`+ of the given saved lists.
    /// The motivation engine: an owner on probate AND tax-delinquent AND absentee is gold.
    /// Returns each qualifying lead with the count of lists it landed on (descending).
    static func stack(_ lists: [SmartList], over leads: [Lead], minListCount: Int = 2) -> [(Lead, Int)] {
        guard !lists.isEmpty else { return [] }
        var hits: [UUID: Int] = [:]
        for list in lists {
            for l in apply(list.filter, to: leads) { hits[l.id, default: 0] += 1 }
        }
        let byID = Dictionary(uniqueKeysWithValues: leads.map { ($0.id, $0) })
        return hits.filter { $0.value >= minListCount }
            .compactMap { id, n in byID[id].map { ($0, n) } }
            .sorted { ($0.1, $0.0.assessedValue) > ($1.1, $1.0.assessedValue) }
    }

    /// LIST AUTOMATION — reconcile a saved list against the current leads (bidirectional).
    /// Returns what newly qualifies (added) and what dropped out (removed: cured/sold/DQ'd),
    /// computed from the list's `memberIDs` anchor vs the live filter result. Pure: does not
    /// mutate the list — the caller decides whether to apply (so removals can be confirmed).
    static func sync(_ list: SmartList, against leads: [Lead]) -> ListSyncResult {
        let live = Set(apply(list.filter, to: leads).map { $0.id })
        let byID = Dictionary(uniqueKeysWithValues: leads.map { ($0.id, $0) })
        var r = ListSyncResult(listID: list.id)
        // Added: live members that weren't in the anchor.
        r.added = live.subtracting(list.memberIDs).compactMap { byID[$0] }
        // Removed: anchored members that no longer match (and still exist as leads).
        r.removed = list.memberIDs.subtracting(live).compactMap { byID[$0] }
        r.stillMatching = live.intersection(list.memberIDs).count
        return r
    }

    /// Apply a sync: return the list with its membership advanced to the current live set.
    /// (The removed leads are NOT deleted from the CRM — they simply leave this list.)
    static func applied(_ list: SmartList, against leads: [Lead]) -> SmartList {
        var l = list
        l.memberIDs = Set(apply(list.filter, to: leads).map { $0.id })
        l.lastSynced = Date()
        return l
    }

    /// Sync ALL auto-maintained lists at once; returns only the lists with real changes.
    static func syncAll(_ lists: [SmartList], against leads: [Lead]) -> [ListSyncResult] {
        lists.filter { $0.autoMaintain }.map { sync($0, against: leads) }.filter { $0.hasChanges }
    }

    /// CSV export of a lead set — the buyer's own data, the columns a mail house / dialer wants.
    static func csv(_ leads: [Lead]) -> String {
        let header = ["Name","Source","County","Property Address","Mailing Address","Owner","Assessed Value","Parcel","Phone","Email","Ownership Confidence","Stage","Open Tasks"]
        func esc(_ s: String) -> String {
            (s.contains(",") || s.contains("\"") || s.contains("\n"))
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var rows = [header.joined(separator: ",")]
        for l in leads {
            let cols = [l.name, l.source.label, l.county, l.propertyAddress, l.mailingAddress, l.ownerName,
                        l.assessedValue > 0 ? String(l.assessedValue) : "", l.parcel, l.phone, l.email,
                        l.ownershipConfidence, l.status.label, String(l.openTasks)]
            rows.append(cols.map(esc).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}
#endif // circuit-convert
