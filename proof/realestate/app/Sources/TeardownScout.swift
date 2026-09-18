#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — Teardown / Lot-Flip Scout.
//
// The builder/flipper play: find parcels where the LAND is worth far more than the structure on
// it. A low improvement-to-land ratio is the assessor's own signal that the building adds little
// value relative to the dirt — the classic teardown / lot-flip / scrape-and-build target. This is
// FULL-STANDARD #5 (distress-score differentiator) computed ENTIRELY from real county assessor
// fields (LAND_VALUE + IMPROVEMENT_VALUE), never fabricated.
//
// Data honesty: only counties that publish BOTH a land and an improvement value field can be
// scouted (ParcelRegistry.supportsTeardownScout). Every other county returns a clean honest gate.
// No ratio is ever invented; a parcel with no land value is dropped, not faked.
import Foundation

// MARK: - One scouted teardown candidate (all values are real assessor fields)
struct TeardownCandidate: Identifiable, Hashable {
    let id = UUID()
    var owner: String
    var address: String
    var parcel: String
    var landValue: Int
    var improvementValue: Int
    var totalValue: Int
    var acres: Double?
    var yearBuilt: Int?
    var lat: Double?
    var lng: Double?

    /// improvement ÷ land. Lower = more teardown-like (structure adds little vs the dirt).
    /// Guarded: land must be > 0 (caller filters; this never divides by zero).
    var ratio: Double { landValue > 0 ? Double(improvementValue) / Double(landValue) : .infinity }

    /// Transparent 0–100 teardown score. Higher = stronger lot-flip candidate.
    /// Derived ONLY from real fields: the ratio (dominant) + a land-value floor (a lot has to be
    /// worth building on) + a small bonus for raw acreage when published.
    var teardownScore: Int { TeardownScout.score(ratio: ratio, land: landValue, acres: acres) }

    var scoreTier: String { TeardownScout.tier(for: teardownScore) }

    /// Plain-English why-line the buyer sees (no jargon, traceable to the numbers).
    var rationale: String {
        let r = String(format: "%.0f%%", ratio * 100)
        if ratio <= 0.15 { return "Structure is only \(r) of land value — near-vacant lot, prime scrape." }
        if ratio <= 0.5 { return "Structure \(r) of land value — tired building on valuable dirt." }
        return "Structure \(r) of land value — modest teardown upside."
    }
}

enum TeardownScout {
    /// Score weights: the ratio carries the signal (max 80), a land-value floor proves the lot is
    /// worth building on (max 12), acreage is a small kicker (max 8). All inputs are real.
    static func score(ratio: Double, land: Int, acres: Double?) -> Int {
        guard land > 0, ratio.isFinite else { return 0 }
        // Ratio: 0.0 → 80 pts, 1.0+ → 0 pts (linear, clamped). The lower the structure value the better.
        let ratioPts = max(0.0, min(80.0, (1.0 - min(ratio, 1.0)) * 80.0))
        // Land floor: a lot has to be worth enough to make a build pencil. $25k → start, $150k+ → full 12.
        let landPts = max(0.0, min(12.0, (Double(land) - 25_000.0) / (150_000.0 - 25_000.0) * 12.0))
        // Acreage kicker (only when published): 0.25ac → start, 2ac+ → full 10.
        let acrePts: Double = {
            guard let a = acres, a > 0 else { return 0 }
            return max(0.0, min(8.0, (a - 0.25) / (2.0 - 0.25) * 8.0))
        }()
        return Int((ratioPts + landPts + acrePts).rounded())
    }

    /// Named tier for a 0–100 teardown/redevelopment score. Shared so the Lot-Flip lists, the
    /// candidate rows, AND the Property Map heat legend all read the same bands.
    static func tier(for score: Int) -> String {
        switch score {
        case 80...: return "Prime"
        case 60..<80: return "Strong"
        case 40..<60: return "Watch"
        default: return "Marginal"
        }
    }

    /// RedevelopmentScore for a public-record parcel row, computed from the SAME land/improvement
    /// ratio the county + central scouts use. Returns nil — an honest "not scorable" — whenever the
    /// assessor split needed to score it isn't on the record (no land value, or no improvement value):
    /// a parcel is never assigned a fabricated score to fill the map. `land` must be > 0 to divide.
    static func redevelopmentScore(for record: PropertyRecord) -> Int? {
        guard let land = record.land_value, land > 0,
              let imp = record.improvement_value else { return nil }
        return score(ratio: Double(imp) / Double(land), land: land, acres: nil)
    }

    /// Counties that can be scouted right now (publish the land/improvement split). Honest list.
    static var scoutableCounties: [String] {
        ParcelRegistry.counties.filter { $0.value.supportsTeardownScout }.keys
            .map { $0.capitalized }.sorted()
    }

    static func canScout(_ county: String) -> Bool {
        ParcelRegistry.source(for: county)?.supportsTeardownScout ?? false
    }

    /// Result of a scout run — either real candidates or an honest reason there are none.
    struct ScoutResult {
        var available: Bool
        var candidates: [TeardownCandidate]
        var county: String
        var scanned: Int          // how many real parcels the server returned for the filter
        var note: String          // honest explanation when empty / gated
    }

    /// Pull real low-ratio parcels for a county and rank them by teardown score.
    /// `maxRatio` is the assessor improvement/land cutoff (default 0.5 = structure ≤ half the dirt).
    /// `minLand` keeps out worthless lots. Injectable fetch for offline tests.
    ///
    /// When the county isn't a live-ArcGIS registry county at all, fall back to the central
    /// public-records index (RealEstateAPI), computing the same improvement:land ratio app-side from
    /// real DB rows. A registry county that simply lacks the land/improvement split is still gated
    /// honestly (its live layer can't score teardowns) — only fully-unwired counties use the index.
    static func scout(county: String,
                      maxRatio: Double = 0.5,
                      minLand: Int = 40_000,
                      limit: Int = 250,
                      state: String? = nil,
                      fetch: ParcelLookup.Fetch = ParcelLookup.liveFetch,
                      allowAPIFallback: Bool = true,
                      apiSearch: CentralTeardownIndex.Search = CentralTeardownIndex.liveSearch) async -> ScoutResult {
        let cty = county.trimmingCharacters(in: .whitespaces).lowercased()
        guard let reg = ParcelRegistry.source(for: cty) else {
            // No live-ArcGIS layer wired → central-index fallback (real DB ratio, honest gate if empty).
            if allowAPIFallback {
                return await CentralTeardownIndex.teardownScout(county: county, state: state,
                    maxRatio: maxRatio, minLand: minLand, limit: limit, search: apiSearch)
            }
            return ScoutResult(available: false, candidates: [], county: cty, scanned: 0,
                               note: "No open parcel source for \(county.capitalized) County — gated, not faked.")
        }
        guard let lf = reg.landField, let impf = reg.improvementField else {
            return ScoutResult(available: false, candidates: [], county: cty, scanned: 0,
                               note: "\(county.capitalized) County doesn't publish a land/improvement split — teardown scout is gated here, not faked.")
        }
        // WHERE: real land floor + a positive structure value (excludes truly vacant land which is a
        // different play). The ratio filter is applied client-side because ArcGIS can't divide fields.
        let where_ = "\(lf) >= \(minLand) AND \(impf) > 0"
        // Request ALL fields (*) — county layers vary in which acre/year columns exist, and naming a
        // missing outField makes ArcGIS 400 the whole query. * is safe; the coercion below reads
        // whatever real columns are present and never invents a missing one.
        let params = ["where": where_, "outFields": "*", "returnGeometry": "true",
                      "outSR": "4326", "resultRecordCount": "\(min(limit * 4, 2000))", "f": "json"]
        guard let json = await fetch(reg.url, params) else {
            return ScoutResult(available: false, candidates: [], county: cty, scanned: 0,
                               note: "\(county.capitalized) County GIS server didn't respond — try again. Nothing was invented.")
        }
        let feats = json["features"] as? [[String: Any]] ?? []
        var out: [TeardownCandidate] = []
        for f in feats {
            guard let a = f["attributes"] as? [String: Any] else { continue }
            guard let land = ParcelLookup.toMoney(a[lf]), land >= minLand else { continue }
            guard let imp = ParcelLookup.toMoney(a[impf]) else { continue }
            let ratio = Double(imp) / Double(land)
            guard ratio <= maxRatio else { continue }      // client-side ratio gate (real numbers only)
            let geom = f["geometry"] as? [String: Any]
            let total = reg.valueField.flatMap { ParcelLookup.toMoney(a[$0]) } ?? (land + imp)
            out.append(TeardownCandidate(
                owner: str(a[reg.ownerField]),
                address: reg.addrField.map { str(a[$0]) } ?? "",
                parcel: str(a[reg.parcelField]),
                landValue: land, improvementValue: imp, totalValue: total,
                acres: dbl(a["ACRES"]) ?? dbl(a["TOTALACRES"]) ?? dbl(a["CALC_ACRE"]) ?? dbl(a["DEED_ACRE"])
                       ?? dbl(a["DEED_ACRES"]) ?? dbl(a["totalacres"]) ?? dbl(a["GIS_ACRES"]),
                yearBuilt: intYear(a["YEAR_BUILT"]) ?? intYear(a["YEARBUILT"]) ?? intYear(a["ActualYearBuilt"]) ?? intYear(a["yr_built"]),
                lat: geom?["y"] as? Double, lng: geom?["x"] as? Double))
        }
        out.sort { $0.teardownScore > $1.teardownScore }
        if out.count > limit { out = Array(out.prefix(limit)) }
        let note = out.isEmpty
            ? "No parcels in \(county.capitalized) County matched the teardown filter (structure ≤ \(Int(maxRatio*100))% of land, land ≥ \(REMath.money(Double(minLand)))) — nothing invented."
            : ""
        return ScoutResult(available: true, candidates: out, county: cty, scanned: feats.count, note: note)
    }

    // MARK: small attribute coercion (mirrors ParcelLookup's honesty rules)
    private static func str(_ v: Any?) -> String {
        let s = "\(v ?? "")".trimmingCharacters(in: .whitespaces)
        return (s.lowercased() == "<null>") ? "" : s
    }
    private static func dbl(_ v: Any?) -> Double? {
        guard let v = v else { return nil }
        if let d = v as? Double { return d > 0 ? d : nil }
        let d = Double("\(v)".replacingOccurrences(of: ",", with: ""))
        return (d ?? 0) > 0 ? d : nil
    }
    private static func intYear(_ v: Any?) -> Int? {
        guard let v = v else { return nil }
        let n = Int(Double("\(v)".replacingOccurrences(of: ",", with: "")) ?? 0)
        return (1700...2100).contains(n) ? n : nil   // a real build year, or nil — never a junk 0
    }
}

// MARK: - Convert a scouted candidate into a saved Lead (real fields only)
extension TeardownCandidate {
    func asLead(county: String) -> Lead {
        var l = Lead()
        l.name = owner.isEmpty ? (address.isEmpty ? "Unknown owner" : address) : owner
        l.ownerName = owner
        l.county = county.capitalized
        l.source = .teardown
        l.sourceDetail = "Teardown · score \(teardownScore) (\(scoreTier))"
        l.propertyAddress = address
        l.parcel = parcel
        l.assessedValue = totalValue
        l.landValue = landValue          // carried so the deal analyzer can value the lot post-scrape
        l.lat = lat; l.lng = lng
        l.notes = rationale
        return l
    }
}
#endif // circuit-convert
