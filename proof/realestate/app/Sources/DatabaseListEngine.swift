// Black Label Real Estate — DATABASE LIST ENGINE.
//
// The guided List Builder's brain: buyer-facing list types (absentee, probate,
// vacant, high-equity, …) mapped onto the Worker's whitelisted HONEST category
// predicates over real public-record columns (mailing-vs-situs mismatch, the
// assessor's land/improvement split, recorded owner names, recorded sale dates).
//
// ZERO FABRICATION CONTRACT:
//   • A list type either maps to a real server predicate (`apiCategory`) or is
//     honestly NOT derivable from the public index today (`indexedToday == false`
//     → the UI says the index is still building that category and offers real
//     adjacent lists instead — never fake rows, never a paste demand).
//   • Every filter param sent is a public query param (state/county/city/zip/
//     bounds/value band/sale dates). A buyer's own CRM data never leaves the device.
import Foundation

// MARK: - Buyer-facing list types (Step 1 of the guided builder)

enum DatabaseListType: String, CaseIterable, Codable, Identifiable {
    case investor, absentee, probate, distressed, vacant, teardown, highEquity
    case taxDelinquent, preForeclosure, cashBuyers, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .investor: return "Investor leads"
        case .absentee: return "Absentee owners"
        case .probate: return "Probate"
        case .distressed: return "Distressed"
        case .vacant: return "Vacant land"
        case .teardown: return "Teardown lots"
        case .highEquity: return "High equity"
        case .taxDelinquent: return "Tax delinquent"
        case .preForeclosure: return "Pre-foreclosure"
        case .cashBuyers: return "Cash buyers"
        case .custom: return "Custom criteria"
        }
    }

    var icon: String {
        switch self {
        case .investor: return "chart.line.uptrend.xyaxis"
        case .absentee: return "envelope.arrow.triangle.branch"
        case .probate: return "doc.text.magnifyingglass"
        case .distressed: return "arrow.down.right.circle"
        case .vacant: return "square.dashed"
        case .teardown: return "hammer"
        case .highEquity: return "banknote"
        case .taxDelinquent: return "exclamationmark.triangle"
        case .preForeclosure: return "clock.badge.exclamationmark"
        case .cashBuyers: return "building.2"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// The Worker's whitelisted category this type queries. nil = no category predicate
    /// (custom) or the signal is not in the public index yet (tax delinquent / pre-foreclosure).
    var apiCategory: String? {
        switch self {
        case .investor: return "absentee_long_hold"
        case .absentee: return "absentee"
        case .probate: return "estate_owner"
        case .distressed: return "value_spread"
        case .vacant: return "vacant_land"
        case .teardown: return "teardown"
        case .highEquity: return "long_hold"
        case .cashBuyers: return "entity_owner"
        case .taxDelinquent, .preForeclosure, .custom: return nil
        }
    }

    /// True when the national index can serve this list TODAY from real columns.
    var indexedToday: Bool {
        switch self {
        case .taxDelinquent, .preForeclosure: return false
        default: return true
        }
    }

    /// Honest one-line description of the REAL signal behind the list.
    var signalBlurb: String {
        switch self {
        case .investor: return "Absentee owners with 10+ years since the last recorded sale — the classic motivated-seller cut."
        case .absentee: return "Owner's mailing address differs from the property address in the county record."
        case .probate: return "Estate-style recorded owner names (ESTATE OF / EXECUTOR / HEIRS) straight from county rolls."
        case .distressed: return "Last recorded sale sits 25%+ below the current assessed value — a public-record value spread."
        case .vacant: return "The assessor carries land value with zero improvement value — vacant land parcels."
        case .teardown: return "Structure worth far less than the dirt under it — the assessor's own improvement-to-land split, the classic scrape-and-build target."
        case .highEquity: return "10+ years since the last recorded sale — the public-record long-tenure equity proxy."
        case .taxDelinquent: return "County delinquency rolls publish per county; the national index is still integrating them."
        case .preForeclosure: return "Lis pendens / notices record at the county clerk; the national index is still integrating them."
        case .cashBuyers: return "Entity-recorded owners (LLC / trust / corp) — parcels bought and held by investors."
        case .custom: return "Start from the whole index for an area, then narrow with your own filters."
        }
    }

    /// For non-indexed types: the honest coverage message shown instead of results.
    var coverageNote: String? {
        guard !indexedToday else { return nil }
        let name = label.lowercased()
        return "The national index doesn't carry \(name) flags yet — those publish county-by-county and are still being indexed. No placeholder rows will ever stand in for them. Meanwhile these database-backed lists cover the same area right now:"
    }

    /// Real, indexed alternatives offered when this type is still being indexed.
    var fallbackTypes: [DatabaseListType] {
        indexedToday ? [] : [.absentee, .vacant, .highEquity]
    }
}

// MARK: - Where (Step 2)

struct DatabaseListArea: Codable, Hashable {
    var state = ""
    var county = ""
    var city = ""
    var zip = ""
    // Optional viewport (from the Property Map's current view).
    var north: Double? = nil
    var south: Double? = nil
    var east: Double? = nil
    var west: Double? = nil

    var hasViewport: Bool { north != nil && south != nil && east != nil && west != nil }

    var hasLocation: Bool {
        hasViewport ||
        ![state, county, city, zip].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The exact `state` value the index understands (USPS code): "Georgia" → "GA", "ga" → "GA".
    /// An unrecognized entry falls through to its uppercased raw form (honest zero, never dropped).
    var canonicalState: String { USStates.queryState(from: state) }

    /// The exact `county` value the index understands (bare name): "Bibb County" → "Bibb".
    var canonicalCounty: String { USStates.normalizedCounty(county) }

    /// "Fulton County, GA" / "30312" / "Map viewport" — for headlines + saved-list rows.
    /// Uses the canonical (index-format) state/county so the buyer sees what will actually be
    /// searched ("GA", "Bibb County"), not the raw string they typed.
    var summary: String {
        var parts: [String] = []
        let ci = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let co = canonicalCounty
        let st = canonicalState
        let zp = zip.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ci.isEmpty { parts.append(ci) }
        if !co.isEmpty { parts.append(co.lowercased().hasSuffix("county") ? co : "\(co) County") }
        if !st.isEmpty { parts.append(st) }
        if !zp.isEmpty { parts.append(zp) }
        if parts.isEmpty && hasViewport { return "Map viewport" }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Full criteria (Steps 1–3)

struct DatabaseListCriteria: Codable, Hashable {
    var type: DatabaseListType = .absentee
    var area = DatabaseListArea()
    // Optional filters (Step 3) — only fields the index REALLY has.
    var minValue: Int? = nil            // assessed_value >=
    var maxValue: Int? = nil            // assessed_value <=
    var soldAfter = ""                  // YYYY-MM-DD (last_sale_date >=)
    var soldBefore = ""                 // YYYY-MM-DD (last_sale_date <=)
    var absenteeOnly = false            // mailing != situs toggle (composable with type)
    var ownerOccupiedOnly = false       // mailing == situs toggle
    /// Direct server category override (whitelisted Worker predicate). Used by tools
    /// like the Lot-Flip scout for categories without a buyer-facing list type
    /// (e.g. "teardown"). When set, it wins over `type.apiCategory`.
    var categoryOverride: String? = nil

    var summary: String {
        var bits = [categoryOverride.map(Self.humanCategory) ?? type.label]
        let a = area.summary
        if !a.isEmpty { bits.append(a) }
        if let mn = minValue { bits.append("≥ $\(mn)") }
        if let mx = maxValue { bits.append("≤ $\(mx)") }
        if !soldAfter.isEmpty { bits.append("sold after \(soldAfter)") }
        if !soldBefore.isEmpty { bits.append("sold before \(soldBefore)") }
        if absenteeOnly { bits.append("absentee") }
        if ownerOccupiedOnly { bits.append("owner-occupied") }
        return bits.joined(separator: " · ")
    }

    /// The exact public query params sent to /v1/search + /v1/map. Pure + unit-tested:
    /// this is the contract that keeps the guided builder database-backed and honest.
    func queryItems(page: Int? = nil, perPage: Int? = nil) -> [URLQueryItem] {
        var q: [URLQueryItem] = []
        func add(_ name: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { q.append(URLQueryItem(name: name, value: v)) }
        }
        // Normalize to the index's storage format so a buyer's natural spelling still matches:
        // "Georgia" → "GA", "Bibb County" → "Bibb". (USStates; unrecognized values pass through.)
        add("state", area.canonicalState)
        add("county", area.canonicalCounty)
        add("city", area.city)
        add("zip", area.zip)
        if area.hasViewport, let n = area.north, let s = area.south, let e = area.east, let w = area.west {
            add("north", String(n)); add("south", String(s)); add("east", String(e)); add("west", String(w))
        }
        if let cat = categoryOverride ?? type.apiCategory { add("category", cat) }
        if let mn = minValue, mn > 0 { add("min_value", String(mn)) }
        if let mx = maxValue, mx > 0 { add("max_value", String(mx)) }
        add("sold_after", Self.validDay(soldAfter) ?? "")
        add("sold_before", Self.validDay(soldBefore) ?? "")
        if absenteeOnly { add("absentee", "1") }
        if ownerOccupiedOnly { add("owner_occupied", "1") }
        if let p = page { add("page", String(max(1, p))) }
        if let pp = perPage { add("per_page", String(max(1, pp))) }
        return q
    }

    /// Human name for a raw server category ("vacant_land" → "Vacant land").
    static func humanCategory(_ c: String) -> String {
        let words = c.split(separator: "_").map(String.init)
        guard let first = words.first else { return c }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }

    /// Strict YYYY-MM-DD or nil — a malformed date is dropped client-side (the Worker
    /// would 400 it anyway; never silently reinterpreted).
    static func validDay(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 10 else { return nil }
        let parts = t.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return t
    }
}

// MARK: - Saved database lists (persisted with the workspace)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct SavedDatabaseList: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var criteria = DatabaseListCriteria()
    var created = Date()
    var lastTotal: Int? = nil           // count at last run — a dated snapshot, never a promise
    var lastRunAt: Date? = nil
    // v2 (all optional so pre-v2 saved workspaces decode unchanged):
    var updatedAt: Date? = nil          // last refresh (count or preview)
    var lastPreview: [PropertyRecord]? = nil   // up to 25 real rows from the last run
    var lastTier: String? = nil         // tier the last run answered with ("preview"/"pro"/"founder")
    var lastPerPage: Int? = nil         // rows-per-page cap the last run was served under

    /// Honest cap line for the detail screen: full count vs what this tier can page/export.
    func capSummary() -> String {
        let total = lastTotal.map(SavedDatabaseList.grouped) ?? "—"
        let per = lastPerPage.map(String.init) ?? "25"
        let tier = (lastTier ?? "preview").capitalized
        return "Full count \(total) · \(tier) tier pages \(per) rows at a time"
    }

    /// Grouped count ("20,601") — engine-local so pure-logic targets need no UI files.
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
#endif // circuit-convert

// MARK: - Database → CRM lead pipeline (dedupe + provenance)

/// Which database surface a saved lead came from. Raw values are the provenance
/// contract ("database_list" | "map" | "lotflip" | "property_index").
enum DatabaseLeadOrigin: String, Codable, CaseIterable {
    case databaseList = "database_list"
    case map = "map"
    case lotflip = "lotflip"
    case propertyIndex = "property_index"

    var label: String {
        switch self {
        case .databaseList: return "Database list"
        case .map: return "Property Map"
        case .lotflip: return "Lot-Flip Scout"
        case .propertyIndex: return "Property Index"
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum DatabaseLeadImport {
    /// Dedupe identity for a public-record lead: state + parcel_id + owner_name.
    /// When the record has no parcel id, the normalized situs address stands in for
    /// it (same-key = same real-world identity; never dedupe on empty everything).
    static func dedupeKey(state: String?, parcel: String?, owner: String?, situs: String?) -> String? {
        func norm(_ s: String?) -> String {
            (s ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let st = norm(state), pc = norm(parcel), ow = norm(owner), ad = norm(situs)
        let identity = pc.isEmpty ? (ad.isEmpty ? "" : "addr\(ad)") : pc
        guard !identity.isEmpty || !ow.isEmpty else { return nil }
        return [st, identity, ow].joined(separator: "|")
    }

    static func dedupeKey(for record: PropertyRecord) -> String? {
        dedupeKey(state: record.state, parcel: record.parcel_id,
                  owner: record.owner_name, situs: record.situs_address)
    }

    static func dedupeKey(for lead: Lead) -> String? {
        // dbState is exact for database-saved leads; older CRM leads fall back to a
        // state token embedded in the county field ("Fulton, GA") when present.
        let state = lead.dbState ?? Self.stateToken(in: lead.county)
        return dedupeKey(state: state, parcel: lead.parcel, owner: lead.ownerName,
                         situs: lead.propertyAddress)
    }

    static func stateToken(in county: String) -> String? {
        let tail = county.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return (tail.count == 2 && tail.allSatisfy(\.isLetter)) ? tail.uppercased() : nil
    }

    /// Convert one public record into a CRM lead with full provenance. Contact fields
    /// stay EMPTY — public records carry no email/phone and none is ever invented;
    /// the UI labels them "not skip-traced yet".
    static func lead(from record: PropertyRecord,
                     origin: DatabaseLeadOrigin,
                     apiCategory: String?,
                     criteriaSummary: String,
                     savedAt: Date = Date()) -> Lead {
        var lead = Lead()
        let situs = [record.situs_address, record.situs_city, record.situs_state ?? record.state, record.situs_zip]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let owner = record.owner_name ?? ""
        lead.name = owner.isEmpty ? (situs.isEmpty ? "Parcel \(record.parcel_id ?? record.id)" : situs) : owner
        lead.ownerName = owner
        lead.source = .database
        lead.sourceDetail = criteriaSummary.isEmpty ? origin.label : criteriaSummary
        lead.propertyAddress = situs
        lead.mailingAddress = [record.mailing_address, record.mailing_city, record.mailing_state, record.mailing_zip]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let county = record.county ?? ""
        let state = (record.state ?? "").uppercased()
        lead.county = county.isEmpty ? state : (state.isEmpty ? county : "\(county), \(state)")
        lead.parcel = record.parcel_id ?? ""
        // Ownership confidence — set ONLY from what the county row itself asserts. When one public
        // record carries a parcel id, a situs address AND an owner name together, the county has
        // already tied those three to each other; recording "high" states the county's own claim,
        // it does not invent a match (contrast ParcelCandidate.apply, where the buyer picks one of
        // N name-search rows and the county disambiguated nothing — that one stays blank).
        // Anything thinner stays "" = ABSENT, never a filler "medium" (§5.1). Added 2026-08-03:
        // this field was previously never set on index-saved leads, so the scorer's Ownership
        // factor was a permanent 0/7 for the entire public-records corpus.
        if !lead.parcel.isEmpty, !situs.isEmpty, !owner.isEmpty { lead.ownershipConfidence = "high" }
        lead.assessedValue = record.assessed_value ?? 0
        lead.landValue = record.land_value ?? 0
        lead.lat = record.lat
        lead.lng = record.lng
        // Provenance — the audit trail from CRM lead back to the public record.
        lead.dbOrigin = origin.rawValue
        lead.dbCategory = apiCategory
        lead.dbCriteria = criteriaSummary
        lead.dbSavedAt = savedAt
        lead.dbSourceURL = record.source_url
        lead.dbRecordID = record.id
        lead.dbState = state.isEmpty ? nil : state
        lead.log(.created, "Saved from \(origin.label)\(criteriaSummary.isEmpty ? "" : " — \(criteriaSummary)")")
        return lead
    }

    /// Merge records into an existing lead set: returns only the leads that are NEW by
    /// dedupe key (state+parcel+owner), plus the duplicate count. Pure — testable.
    static func merge(_ records: [PropertyRecord],
                      into existing: [Lead],
                      origin: DatabaseLeadOrigin,
                      apiCategory: String?,
                      criteriaSummary: String) -> (new: [Lead], duplicates: Int) {
        var seen = Set(existing.compactMap { dedupeKey(for: $0) })
        var fresh: [Lead] = []
        var dupes = 0
        for record in records {
            guard let key = dedupeKey(for: record) else { dupes += 1; continue }
            if seen.contains(key) { dupes += 1; continue }
            seen.insert(key)
            fresh.append(lead(from: record, origin: origin, apiCategory: apiCategory, criteriaSummary: criteriaSummary))
        }
        return (fresh, dupes)
    }
}
#endif // circuit-convert

// MARK: - Export

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum DatabaseListEngine {
    /// CSV of public-record rows (public fields only — there is no PII to export).
    static func csv(_ records: [PropertyRecord]) -> String {
        var out = "state,county,parcel_id,owner_name,situs_address,situs_city,situs_zip,mailing_address,mailing_city,mailing_state,mailing_zip,assessed_value,land_value,improvement_value,last_sale_price,last_sale_date,lat,lng\n"
        for r in records {
            let cells: [String] = [
                r.state ?? "", r.county ?? "", r.parcel_id ?? "", r.owner_name ?? "",
                r.situs_address ?? "", r.situs_city ?? "", r.situs_zip ?? "",
                r.mailing_address ?? "", r.mailing_city ?? "", r.mailing_state ?? "", r.mailing_zip ?? "",
                r.assessed_value.map(String.init) ?? "", r.land_value.map(String.init) ?? "",
                r.improvement_value.map(String.init) ?? "", r.last_sale_price.map(String.init) ?? "",
                r.last_sale_date ?? "",
                r.lat.map { String($0) } ?? "", r.lng.map { String($0) } ?? "",
            ]
            out += cells.map { cell in
                cell.contains(",") || cell.contains("\"") || cell.contains("\n")
                    ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    : cell
            }.joined(separator: ",") + "\n"
        }
        return out
    }
}
#endif // circuit-convert
