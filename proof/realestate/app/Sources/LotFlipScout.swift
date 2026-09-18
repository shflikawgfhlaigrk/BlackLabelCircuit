// Black Label Real Estate — the Lot-Flip Scout engine (the builder teardown play).
//
// THE PLAY (from the strategy video, operationalized on real data): builders buy old, cheap
// houses sitting on valuable land, tear them down, and put up $$$ new builds. The money is in
// finding those teardown lots BEFORE the builder does, locking the owner under contract, and
// assigning the lot to a builder for a spread. This engine finds the teardown lots and the
// owner to contact, on REAL county parcel records — no Zillow scraping, no paid API.
//
// HONESTY (ported from the proven Utah property resolver): only counties with an OPEN ArcGIS
// parcel layer are covered; every other county GATES honestly (it never fabricates a lead).
// Parcel layers don't publish "year built," so the teardown signal is the improvement-to-land
// value ratio where the county splits it (a cheap structure on dear land == teardown), and
// otherwise "assessed value far below the 3-mile area average" (an underbuilt lot in a pricier
// pocket). Spread is reported as an OPPORTUNITY GAP estimate, never a guaranteed profit.
//
// Pure Foundation only (no SwiftUI / no AppKit / no network types beyond URLSession) so the
// scoring is unit-testable offline by feeding parsed parcels straight into `score(...)`.
//
// UNIFICATION NOTE (was COLLISION NOTE): the flip lane used to carry its OWN hardcoded county list
// (`FlipParcelRegistry`, 7 GA counties), disjoint from the teardown lane's `ParcelRegistry`
// (ParcelLookup.swift). That divergent list is REMOVED. There is now ONE source of truth —
// `ParcelRegistry` — and both lanes (LotFlipScout + TeardownScout) cover the same counties, incl.
// the NC additions (Wake/Harnett/Davidson) and any buyer-added county. `CountyParcels` is now a thin
// PROJECTION of a `ParcelRegistry` `CountyParcelSource`; `FlipParcelRegistry` is retained only as a
// derived compatibility surface for `LotFlipScoutScreen` and holds no county data of its own.
//
// The remaining `Flip`/`flip` prefixes still avoid clashes with the full app's `Parcel`, `ScoutResult`,
// and `REMath.money` / `REMath.pct`. `LotFlipScout`, `FlipLead`, `CountyParcels`, `FlipTuning`,
// `CanvassStop`, `CanvassRoute`, `Canvasser`, and `CentralTeardownIndex` are this file's own names.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - County view (a thin projection of the single ParcelRegistry)

/// One county's open parcel layer as the flip lane reads it — a PROJECTION of a `CountyParcelSource`
/// from the single source of truth (`ParcelRegistry`, ParcelLookup.swift). It holds no county data of
/// its own. `CountyParcelSource` carries neither an acres field nor a display string, so `acresField`
/// is nil here (the parser probes the common acre columns) and `display` is built from the county key
/// plus an optional state hint for accurate geocoding of the county center.
struct CountyParcels {
    let key: String
    let display: String
    let url: String              // .../FeatureServer/N/query  or  .../MapServer/N/query
    let ownerField: String
    let addrField: String
    let acresField: String?
    let valueField: String?      // total assessed / fair-market value
    let landValueField: String?  // land-only value  — enables the true teardown ratio
    let imprValueField: String?  // improvement-only value

    /// True when this county exposes enough to score teardowns (any value signal).
    var canScore: Bool { valueField != nil || (landValueField != nil && imprValueField != nil) }
    /// True when the county splits land vs improvement (the strongest teardown signal).
    var hasSplit: Bool { landValueField != nil && imprValueField != nil }
}

extension CountyParcels {
    /// Project a `ParcelRegistry` entry (key + source) into the flip lane's view. State hint for the
    /// geocoder comes from `FlipGeo.stateHint`; acres are probed at parse time, never configured here.
    /// (Kept in an extension so the struct's memberwise init still exists for the synthetic
    /// central-index view in `CentralTeardownIndex`.)
    init(key: String, source: CountyParcelSource) {
        let pretty = key.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        let st = FlipGeo.stateHint[key]
        self.init(key: key,
                  display: st != nil ? "\(pretty) County, \(st!)" : "\(pretty) County",
                  url: source.url,
                  ownerField: source.ownerField,
                  addrField: source.addrField ?? "",     // pid-only counties have no situs field → empty (honest)
                  acresField: nil,                       // probed from common columns by parse(_:_:)
                  valueField: source.valueField,
                  landValueField: source.landField,
                  imprValueField: source.improvementField)
    }
}

/// Display/geocode hints for the built-in counties (a state suffix only — NOT a parcel registry).
/// The single registry of parcel SOURCES is `ParcelRegistry`; this map just disambiguates county
/// names like "Hall" (GA vs NE vs TX) so the screen geocodes the right county center. Buyer-added
/// counties carry no hint (the buyer can name the state in their county string if it's ambiguous).
enum FlipGeo {
    static let stateHint: [String: String] = [
        "harris": "GA", "houston": "GA", "bulloch": "GA", "effingham": "GA", "hall": "GA",
        "bryan": "GA", "forsyth": "GA", "wake": "NC", "harnett": "NC", "davidson": "NC",
    ]
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// The flip lane's county list — DERIVED from the single `ParcelRegistry` (built-in + buyer-added,
/// all states incl. NC). The old divergent hardcoded list is gone; this enum carries no county data,
/// it only projects `ParcelRegistry` for `LotFlipScoutScreen`.
enum FlipParcelRegistry {
    static var all: [CountyParcels] {
        ParcelRegistry.counties
            .map { CountyParcels(key: $0.key, source: $0.value) }
            .sorted { $0.key < $1.key }
    }

    /// Match a county string ("Hall County", "Hall", "hall county, ga") to the single ParcelRegistry.
    /// nil when the county isn't wired as a live ArcGIS layer → triggers the central-index fallback.
    static func match(_ raw: String?) -> CountyParcels? {
        let k = LotFlipScout.cleanCountyName(raw ?? "")
        guard !k.isEmpty, let src = ParcelRegistry.source(for: k) else { return nil }
        return CountyParcels(key: k, source: src)
    }

    static var coveredDisplay: String { all.map { $0.display }.joined(separator: ", ") }
}
#endif // circuit-convert

// MARK: - Models

/// A raw parcel pulled from the county layer (before scoring).
struct FlipParcel {
    var owner: String
    var address: String
    var mailing: String
    var acres: Double?
    var value: Int?          // total assessed (or land+impr when the county splits it)
    var landValue: Int?
    var imprValue: Int?
    var lat: Double?
    var lng: Double?
}

/// A scored teardown lead — a deal to work.
struct FlipLead: Identifiable {
    let id = UUID()
    var owner: String
    var address: String
    var mailing: String
    var acres: Double?
    var value: Int?
    var landValue: Int?
    var imprValue: Int?
    var lat: Double?
    var lng: Double?
    var score: Double        // 0…1, higher = riper teardown
    var reason: String       // honest, grounded explanation
    var estGap: Int?         // opportunity gap = area ceiling − this parcel's value (estimate)
}

/// The scout output for one area.
struct FlipScoutResult {
    var county: String
    var supported: Bool
    var scored: Bool
    var note: String
    var parcelsScanned: Int = 0
    var areaAvgValue: Int? = nil
    var ceilingValue: Int? = nil      // top new-build comp ≈ the builder's exit
    var leads: [FlipLead] = []
}

// MARK: - Tunables

enum FlipTuning {
    static let radiusMeters: Double = 4828        // ~3 miles
    static let maxParcels = 2000                  // hard cap on a single area query
    static let maxLeads = 30
    /// Hall-style: a structure worth ≤ this share of total value is a teardown.
    static let teardownImprShare = 0.35
    /// Don't flag slivers/throwaway parcels — the land must be worth at least this.
    static let minLandValue = 40_000
    /// Value-county path: a parcel this far (fraction) below the area average is a teardown lead.
    static let belowAvgTrigger = 0.30
    /// Ignore parcels already at/above the area average (nothing to gain rebuilding them).
    static let scoreFloor = 0.45
}

// MARK: - Numeric coercion (ArcGIS fields arrive as String OR Number, per county)

func flipMoney(_ v: Any?) -> Int? {
    if let i = v as? Int { return i > 0 ? i : nil }
    if let d = v as? Double { return d > 0 ? Int(d) : nil }
    if let s = v as? String {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        if let d = Double(cleaned), d > 0 { return Int(d) }
    }
    return nil
}

func flipDouble(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
    return nil
}

func flipString(_ v: Any?) -> String {
    guard let v = v, !(v is NSNull) else { return "" }
    let s = "\(v)".trimmingCharacters(in: .whitespaces)
    return s.lowercased() == "null" ? "" : s
}

// MARK: - Query + parse (pure)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum LotFlipScout {
    /// Build the exact ArcGIS envelope-query URL the scout runs for an area.
    /// `includeRecordCount` gates the `resultRecordCount` cap: layers with supportsPagination=false
    /// reject it with an HTTP-200 error envelope, so the scout retries with this false (see `scout`).
    static func queryURL(_ reg: CountyParcels, lat: Double, lng: Double,
                         radiusMeters: Double = FlipTuning.radiusMeters,
                         includeRecordCount: Bool = true) -> URL? {
        let dlat = radiusMeters / 111_320.0
        let dlng = radiusMeters / (111_320.0 * max(0.1, cos(lat * .pi / 180)))
        let env = "\(lng - dlng),\(lat - dlat),\(lng + dlng),\(lat + dlat)"
        var c = URLComponents(string: reg.url)
        var items: [URLQueryItem] = [
            .init(name: "where", value: "1=1"),
            .init(name: "geometry", value: env),
            .init(name: "geometryType", value: "esriGeometryEnvelope"),
            .init(name: "inSR", value: "4326"),
            .init(name: "outSR", value: "4326"),
            .init(name: "spatialRel", value: "esriSpatialRelIntersects"),
            // outFields=* — requesting specific fields breaks on counties that lack a mailing
            // column ("Failed to execute query"); * is robust and the parser reads by name.
            .init(name: "outFields", value: "*"),
            // returnCentroid, NOT full polygon rings: we only need each parcel's center point for
            // distance ranking. Full geometry on up to maxParcels dense urban parcels is a
            // multi-hundred-MB JSON tree that JSONSerialization boxes into Foundation objects ->
            // memory thrash / near-crash. Centroids are a few bytes each. Falls back gracefully on
            // any server that ignores returnCentroid (parcels still score; they just lack a pin).
            .init(name: "returnGeometry", value: "false"),
            .init(name: "returnCentroid", value: "true"),
        ]
        if includeRecordCount { items.append(.init(name: "resultRecordCount", value: "\(FlipTuning.maxParcels)")) }
        items.append(.init(name: "f", value: "json"))
        c?.queryItems = items
        return c?.url
    }

    /// Centroid of an ArcGIS geometry (polygon rings → average of the outer ring; point → x/y).
    static func centroid(_ geom: [String: Any]?) -> (Double, Double)? {
        guard let geom = geom else { return nil }
        if let y = flipDouble(geom["y"]), let x = flipDouble(geom["x"]) { return (y, x) }
        if let rings = geom["rings"] as? [[[Double]]], let ring = rings.first, !ring.isEmpty {
            var sx = 0.0, sy = 0.0
            for p in ring where p.count >= 2 { sx += p[0]; sy += p[1] }
            return (sy / Double(ring.count), sx / Double(ring.count))
        }
        return nil
    }

    /// First non-empty owner mailing line across the common county conventions.
    static func mailing(_ a: [String: Any], situs: String) -> String {
        for k in ["MAILADDRESS", "MailAddress", "MAIL_ADDR", "OWNERADD", "PSTLADDRESS"] {
            let v = flipString(a[k]); if !v.isEmpty { return v }
        }
        let lines = ["ADDRESS1", "ADDRESS2", "ADDRESS3"].map { flipString(a[$0]) }.filter { !$0.isEmpty }
        if !lines.isEmpty {
            let cityLine = ["CITY", "STATE", "ZIP"].map { flipString(a[$0]) }.filter { !$0.isEmpty }.joined(separator: " ")
            return (lines + (cityLine.isEmpty ? [] : [cityLine])).joined(separator: ", ")
        }
        return situs   // fall back to the property itself (a county-recorded address)
    }

    /// Parse an ArcGIS `{features:[...]}` response into raw parcels (pure; no network).
    static func parse(_ json: [String: Any], _ reg: CountyParcels) -> [FlipParcel] {
        guard let feats = json["features"] as? [[String: Any]] else { return [] }
        var out: [FlipParcel] = []
        for f in feats {
            let a = f["attributes"] as? [String: Any] ?? [:]
            let situs = flipString(a[reg.addrField])
            let land = reg.landValueField.flatMap { flipMoney(a[$0]) }
            let impr = reg.imprValueField.flatMap { flipMoney(a[$0]) }
            var value = reg.valueField.flatMap { flipMoney(a[$0]) }
            if value == nil, let l = land { value = l + (impr ?? 0) }   // synthesize total from split
            let c = centroid((f["centroid"] as? [String: Any]) ?? (f["geometry"] as? [String: Any]))
            // Acres: the configured field if any, else probe the common county acre columns (the
            // projected CountyParcels has no acresField, so this is the live recovery path). Real
            // columns only — a missing acreage stays nil, never a fabricated 0.
            let acres = reg.acresField.flatMap { flipDouble(a[$0]) }
                ?? flipDouble(a["ACRES"]) ?? flipDouble(a["TOTALACRES"]) ?? flipDouble(a["CALC_ACRE"])
                ?? flipDouble(a["DEED_ACRE"]) ?? flipDouble(a["DEED_ACRES"]) ?? flipDouble(a["totalacres"])
                ?? flipDouble(a["GIS_ACRES"])
            out.append(FlipParcel(owner: flipString(a[reg.ownerField]), address: situs,
                                  mailing: mailing(a, situs: situs),
                                  acres: acres,
                                  value: value, landValue: land, imprValue: impr,
                                  lat: c?.0, lng: c?.1))
        }
        return out
    }

    /// Score parcels into teardown leads + comps (pure; no network). This is the heart of the play.
    static func score(_ parcels: [FlipParcel], _ reg: CountyParcels) -> FlipScoutResult {
        var r = FlipScoutResult(county: reg.display, supported: true, scored: reg.canScore,
                                note: "", parcelsScanned: parcels.count)
        let values = parcels.compactMap { $0.value }.filter { $0 > 0 }
        if !values.isEmpty {
            r.areaAvgValue = values.reduce(0, +) / values.count
            let sorted = values.sorted()
            r.ceilingValue = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]  // ~90th pct new-build comp
        }
        guard reg.canScore else {
            r.note = "\(reg.display) publishes parcels + owners but no assessed-value layer — "
                   + "teardown scoring isn't available here yet. \(parcels.count) parcels mapped."
            return r
        }
        let avg = r.areaAvgValue ?? 0
        var leads: [FlipLead] = []
        for p in parcels {
            var score = 0.0, reason = ""
            if reg.hasSplit, let land = p.landValue, let impr = p.imprValue, land >= FlipTuning.minLandValue {
                let total = land + impr
                let imprShare = total > 0 ? Double(impr) / Double(total) : 1
                if imprShare <= FlipTuning.teardownImprShare {
                    score = min(1, 1 - imprShare)
                    reason = impr <= 5_000
                        ? "Minimal/placeholder structure value ($\(flipMoneyFmt(impr))) on $\(flipMoneyFmt(land)) of land — teardown or vacant lot, builder-ready."
                        : "Teardown: structure is only \(flipPct(imprShare)) of value (building $\(flipMoneyFmt(impr)) on $\(flipMoneyFmt(land)) of land)."
                }
            } else if !reg.hasSplit, let v = p.value, v > 0, avg > 0, v < avg {
                let below = Double(avg - v) / Double(avg)
                if below >= FlipTuning.belowAvgTrigger {
                    score = min(1, below)
                    reason = "Assessed $\(flipMoneyFmt(v)) is \(flipPct(below)) below the 3-mile average $\(flipMoneyFmt(avg)) — underbuilt lot in a pricier pocket."
                }
            }
            guard score >= FlipTuning.scoreFloor, !reason.isEmpty else { continue }
            if let ac = p.acres, ac >= 0.10 { reason += " ~\(String(format: "%.2f", ac)) ac." }
            let ceiling = r.ceilingValue ?? avg
            let gap = (ceiling > 0 && (p.value ?? 0) > 0) ? max(0, ceiling - (p.value ?? 0)) : nil
            leads.append(FlipLead(owner: p.owner.isEmpty ? "(owner on record)" : p.owner,
                                  address: p.address, mailing: p.mailing, acres: p.acres,
                                  value: p.value, landValue: p.landValue, imprValue: p.imprValue,
                                  lat: p.lat, lng: p.lng, score: score, reason: reason, estGap: gap))
        }
        leads.sort { ($0.estGap ?? 0, $0.score) > ($1.estGap ?? 0, $1.score) }
        r.leads = Array(leads.prefix(FlipTuning.maxLeads))
        r.note = r.leads.isEmpty
            ? "Scanned \(parcels.count) parcels in \(reg.display) — no teardown lots cleared the bar in this ring."
            : "\(r.leads.count) teardown lead\(r.leads.count == 1 ? "" : "s") from \(parcels.count) parcels in \(reg.display)."
        return r
    }

    /// Bare county name (no "County"/state suffix) for DB search + registry lookups.
    static func cleanCountyName(_ raw: String) -> String {
        var k = raw.lowercased()
        for junk in [", nc", ",nc", ", ga", ",ga", ", sc", ",sc", ", fl", ",fl",
                     ", ny", ",ny", ", wi", ",wi", ", tx", ",tx", " county", " co.", " co"] {
            k = k.replacingOccurrences(of: junk, with: "")
        }
        return k.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Human county display ("Hall County, GA" when a state is known) for a fallback result header.
    static func displayName(countyRaw: String, state: String?) -> String {
        let bare = cleanCountyName(countyRaw)
        let pretty = bare.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        let st = (state?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
                ?? FlipGeo.stateHint[bare]
        return st != nil ? "\(pretty) County, \(st!)" : "\(pretty) County"
    }

    /// Full scout for an area: county → live ArcGIS query → parse → score. When the county isn't a
    /// live-ArcGIS registry county, fall back to the central public-records index (RealEstateAPI),
    /// computing the teardown ratio app-side from real DB land/improvement values. Honest gate when
    /// neither the layer nor the index has anything; never fabricates a lead.
    static func scout(lat: Double, lng: Double, countyRaw: String,
                      radiusMeters: Double = FlipTuning.radiusMeters,
                      state: String? = nil,
                      allowAPIFallback: Bool = true,
                      apiSearch: CentralTeardownIndex.Search = CentralTeardownIndex.liveSearch,
                      session: URLSession = .shared) async -> FlipScoutResult {
        guard let reg = FlipParcelRegistry.match(countyRaw) else {
            // Not a live-ArcGIS registry county → central-index fallback (real DB ratio, no fabrication).
            if allowAPIFallback,
               let fb = await CentralTeardownIndex.flipScout(countyRaw: countyRaw, state: state, search: apiSearch) {
                return fb
            }
            return FlipScoutResult(county: countyRaw.isEmpty ? "this area" : countyRaw, supported: false,
                scored: false,
                note: "No open parcel source wired for \(countyRaw.isEmpty ? "this county" : countyRaw) yet, "
                    + "and the central index has no land/improvement data there. "
                    + "Covered today: \(FlipParcelRegistry.coveredDisplay).")
        }
        guard queryURL(reg, lat: lat, lng: lng, radiusMeters: radiusMeters) != nil else {
            return FlipScoutResult(county: reg.display, supported: true, scored: false, note: "Could not build the parcel query URL.")
        }
        do {
            // One labeled fetch attempt → (HTTP code, tolerantly-parsed JSON). Uses the shared
            // ParcelLookup.parseJSON so a county's malformed escapes don't drop the whole response.
            func attempt(includeRecordCount: Bool) async throws -> (Int, [String: Any]?) {
                guard let url = queryURL(reg, lat: lat, lng: lng, radiusMeters: radiusMeters,
                                         includeRecordCount: includeRecordCount) else { return (0, nil) }
                var req = URLRequest(url: url); req.timeoutInterval = 30
                req.setValue("BlackLabelRealEstate/0.1 lotflip", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                return (code, code == 200 ? ParcelLookup.parseJSON(data) : nil)
            }
            var (code, json) = try await attempt(includeRecordCount: true)
            // Pagination-tolerant retry: a MapServer with supportsPagination=false answers the
            // resultRecordCount cap with an HTTP-200 error envelope (no features). Drop the cap and
            // try ONCE more — the general fix, not a per-county flag.
            if json == nil || ParcelLookup.isArcGISError(json!) {
                (code, json) = try await attempt(includeRecordCount: false)
            }
            guard let json else {
                return FlipScoutResult(county: reg.display, supported: true, scored: false,
                    note: "\(reg.display) parcel server returned HTTP \(code). Try again shortly.")
            }
            if ParcelLookup.isArcGISError(json) {
                let err = json["error"] as? [String: Any] ?? [:]
                return FlipScoutResult(county: reg.display, supported: true, scored: false,
                    note: "\(reg.display) parcel server error: \(flipString(err["message"])).")
            }
            return score(parse(json, reg), reg)
        } catch {
            return FlipScoutResult(county: reg.display, supported: true, scored: false,
                note: "Couldn't reach the \(reg.display) parcel server: \(error.localizedDescription)")
        }
    }
}
#endif // circuit-convert

// MARK: - Canvass route (pure, free, unit-testable — nearest-neighbor over the scored leads)

/// One stop on a canvassing route: the lead plus its leg distance from the previous stop.
struct CanvassStop: Identifiable {
    let id: UUID
    let lead: FlipLead
    let legMiles: Double       // miles from the previous stop (0 for the first)
    let cumulativeMiles: Double
}

struct CanvassRoute {
    var stops: [CanvassStop] = []
    var totalMiles: Double = 0
    var startName: String = "Search center"
}

enum Canvasser {
    /// Great-circle distance in miles between two coordinates.
    static func haversineMiles(_ aLat: Double, _ aLng: Double, _ bLat: Double, _ bLng: Double) -> Double {
        let R = 3958.7613                       // mean Earth radius, miles
        let dLat = (bLat - aLat) * .pi / 180
        let dLng = (bLng - aLng) * .pi / 180
        let s1 = sin(dLat / 2), s2 = sin(dLng / 2)
        let h = s1 * s1 + cos(aLat * .pi / 180) * cos(bLat * .pi / 180) * s2 * s2
        return 2 * R * asin(min(1, sqrt(h)))
    }

    /// Order the leads into a nearest-neighbor canvassing run starting from the search center.
    /// Leads with no coordinate are dropped (can't be driven to). Pure — no network.
    static func route(from centerLat: Double, _ centerLng: Double, leads: [FlipLead]) -> CanvassRoute {
        var remaining = leads.filter { $0.lat != nil && $0.lng != nil }
        var route = CanvassRoute()
        var curLat = centerLat, curLng = centerLng
        var cumulative = 0.0
        while !remaining.isEmpty {
            var bestIdx = 0
            var bestDist = Double.greatestFiniteMagnitude
            for (i, l) in remaining.enumerated() {
                let d = haversineMiles(curLat, curLng, l.lat!, l.lng!)
                if d < bestDist { bestDist = d; bestIdx = i }
            }
            let next = remaining.remove(at: bestIdx)
            cumulative += bestDist
            route.stops.append(CanvassStop(id: next.id, lead: next,
                                           legMiles: bestDist, cumulativeMiles: cumulative))
            curLat = next.lat!; curLng = next.lng!
        }
        route.totalMiles = cumulative
        return route
    }
}

// MARK: - Small formatters

func flipMoneyFmt(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}
func flipPct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Central-index teardown fallback (RealEstateAPI / our public-records DB) -----------------
//
// Used when a county isn't a live-ArcGIS registry county. The teardown improvement:land ratio is
// computed ENTIRELY app-side from real DB rows (RealEstateAPI.search → PropertyRecord.land_value /
// .improvement_value). HONESTY (the binding that bites here):
//   • A record is gated (dropped) ONLY when it has NEITHER a land nor an improvement value — nothing
//     is fabricated and no missing value is invented.
//   • The DB decoder maps 0/blank money → nil, so a record with a real land value but no improvement
//     value reads as a $0 / near-vacant structure (the strongest teardown signal) and is labeled as
//     such by the existing score(...) reason text. Land is NEVER fabricated.
//   • Only PUBLIC query params (county/state) leave the device — no buyer PII is ever POSTed.
//   • The API call is injectable (`Search`) so offline unit tests never touch the network.
enum CentralTeardownIndex {
    /// Injectable seam: (county, state, perPage) → real PropertyRecords. Default hits the live API.
    typealias Search = (_ county: String?, _ state: String?, _ perPage: Int) async -> [PropertyRecord]

    static let liveSearch: Search = { county, state, perPage in
        await RealEstateAPI.search(state: state, county: county, perPage: perPage).results
    }

    /// Records we can HONESTLY assess: at least one of land/improvement value present.
    /// Both-nil rows are the only ones gated out here (can't compute a ratio, won't fake one).
    static func assessable(county: String?, state: String?, perPage: Int, search: Search) async -> [PropertyRecord] {
        await search(county, state, perPage).filter { $0.land_value != nil || $0.improvement_value != nil }
    }

    /// Owner mailing line composed from the record's real mailing_* fields (empty if none on record).
    static func mailing(_ r: PropertyRecord) -> String {
        let street = r.mailing_address ?? ""
        let cityLine = [r.mailing_city, r.mailing_state, r.mailing_zip]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return [street, cityLine].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// LotFlipScout fallback: DB rows → FlipParcels → the SAME `score(...)` the live lane runs.
    /// Returns nil when the index has no assessable rows here (caller then emits the honest gate).
    static func flipScout(countyRaw: String, state: String?, perPage: Int = 500,
                          search: Search = liveSearch) async -> FlipScoutResult? {
        let human = LotFlipScout.displayName(countyRaw: countyRaw, state: state)
        let recs = await assessable(county: LotFlipScout.cleanCountyName(countyRaw),
                                    state: state, perPage: perPage, search: search)
        guard !recs.isEmpty else { return nil }
        let parcels: [FlipParcel] = recs.map { r in
            let land = r.land_value
            let impr = r.improvement_value
            // Land present but no improvement value on record → $0 / vacant structure (decoder maps
            // 0/blank → nil): the strongest teardown signal. Without a land value we leave impr as-is
            // (no dirt value to compare → not a ratio candidate); never fabricate the missing field.
            let imprForScore: Int? = (land != nil) ? (impr ?? 0) : impr
            let value = r.assessed_value ?? land.map { $0 + (impr ?? 0) }
            return FlipParcel(owner: r.owner_name ?? "", address: r.situs_address ?? "",
                              mailing: mailing(r), acres: nil,
                              value: value, landValue: land, imprValue: imprForScore,
                              lat: r.lat, lng: r.lng)
        }
        // Synthetic county view: hasSplit=true (placeholder field names) so score uses the real
        // land/improvement ratio path. score reads p.landValue/p.imprValue directly, not these names.
        let synth = CountyParcels(key: LotFlipScout.cleanCountyName(countyRaw), display: human,
                                  url: "", ownerField: "", addrField: "", acresField: nil,
                                  valueField: "_assessed", landValueField: "_land", imprValueField: "_impr")
        var r = LotFlipScout.score(parcels, synth)
        r.note = "No live county parcel layer wired here — scored \(recs.count) parcel"
               + "\(recs.count == 1 ? "" : "s") from the central public-records index "
               + "(improvement-to-land ratio, real DB fields). " + r.note
        return r
    }

    /// TeardownScout fallback: DB rows → TeardownCandidates. Mirrors the live lane's "tired building on
    /// valuable dirt" play (requires a real land floor AND a positive structure value — vacant land is
    /// a different play), and applies the same client-side ratio gate on real numbers only.
    static func teardownScout(county: String, state: String?, maxRatio: Double, minLand: Int,
                              limit: Int, perPage: Int = 500,
                              search: Search = liveSearch) async -> TeardownScout.ScoutResult {
        let cty = county.trimmingCharacters(in: .whitespaces).lowercased()
        let recs = await assessable(county: LotFlipScout.cleanCountyName(county), state: state,
                                    perPage: perPage, search: search)
        guard !recs.isEmpty else {
            return TeardownScout.ScoutResult(available: false, candidates: [], county: cty, scanned: 0,
                note: "No open parcel source for \(county.capitalized) County, and the central index has "
                    + "no land/improvement data there yet — gated, not faked.")
        }
        var out: [TeardownCandidate] = []
        for r in recs {
            guard let land = r.land_value, land >= minLand else { continue }   // real dirt value floor
            guard let imp = r.improvement_value, imp > 0 else { continue }      // tired structure, not vacant
            let ratio = Double(imp) / Double(land)
            guard ratio <= maxRatio else { continue }                          // real-number ratio gate
            let total = r.assessed_value ?? (land + imp)
            out.append(TeardownCandidate(owner: r.owner_name ?? "", address: r.situs_address ?? "",
                                         parcel: r.parcel_id ?? "", landValue: land,
                                         improvementValue: imp, totalValue: total, acres: nil,
                                         yearBuilt: nil, lat: r.lat, lng: r.lng))
        }
        out.sort { $0.teardownScore > $1.teardownScore }
        if out.count > limit { out = Array(out.prefix(limit)) }
        let note = out.isEmpty
            ? "Central index had no parcels in \(county.capitalized) County matching the teardown filter "
              + "(structure ≤ \(Int(maxRatio * 100))% of land, land ≥ \(REMath.money(Double(minLand)))) — nothing invented."
            : "No live county layer wired — \(out.count) teardown candidate\(out.count == 1 ? "" : "s") "
              + "from the central public-records index (\(recs.count) rows scanned)."
        return TeardownScout.ScoutResult(available: true, candidates: out, county: cty,
                                         scanned: recs.count, note: note)
    }
}
#endif // circuit-convert

// MARK: - Full Lead Database good-deal scout -----------------------------------------------
//
// The county scouts above answer "what can this one county source score?" This scanner answers the
// owner-database question: walk the Lead Database page by page, score every returned public-record row
// with conservative deal signals, and keep only properties with a real economics reason. It never
// invents an asking price, ARV, contact data, or value field.

struct DatabaseDealReason: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var detail: String
    var points: Int
    var isEconomic: Bool
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct DatabaseDealCandidate: Identifiable, Hashable {
    var record: PropertyRecord
    var score: Int
    var tier: String
    var headline: String
    var summary: String
    var reasons: [DatabaseDealReason]
    var risks: [String]
    var nextSteps: [String]

    var id: String { record.id }

    var displayAddress: String {
        DatabaseDealScout.situsLine(record).isEmpty ? "(address on record)" : DatabaseDealScout.situsLine(record)
    }

    var displayOwner: String {
        record.owner_name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? record.owner_name!
            : "(owner on record)"
    }

    func asLead(area: DatabaseListArea? = nil, signal: DatabaseDealScout.LotSignal? = nil) -> Lead {
        var lead = Lead()
        let address = DatabaseDealScout.situsLine(record)
        let owner = record.owner_name ?? ""
        lead.name = address.isEmpty ? (owner.isEmpty ? "Full database deal \(record.id)" : owner) : "\(address) - \(owner.isEmpty ? "owner on record" : owner)"
        lead.ownerName = owner
        lead.county = DatabaseDealScout.marketLine(record)
        lead.source = .teardown
        lead.sourceDetail = "Full database deal scout - score \(score) (\(tier))"
        lead.propertyAddress = address
        lead.mailingAddress = DatabaseDealScout.mailingLine(record)
        lead.parcel = record.parcel_id ?? ""
        lead.assessedValue = record.assessed_value ?? 0
        lead.landValue = record.land_value ?? 0
        lead.lat = record.lat
        lead.lng = record.lng
        lead.notes = ([summary] + reasons.map { "Why: \($0.title) - \($0.detail)" } + risks.map { "Risk: \($0)" } + nextSteps.map { "Next: \($0)" })
            .joined(separator: "\n")
        // Database provenance — the audit trail back to the public record. Contact
        // fields stay empty (no PII on public records; labeled "not skip-traced yet").
        lead.dbOrigin = DatabaseLeadOrigin.lotflip.rawValue
        lead.dbCategory = signal?.apiCategory
        lead.dbCriteria = [signal?.rawValue, area?.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        lead.dbSavedAt = Date()
        lead.dbSourceURL = record.source_url
        lead.dbRecordID = record.id
        lead.dbState = record.state?.uppercased()
        return lead
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct DatabaseDealScanPage {
    var page: Int
    var perPage: Int
    var total: Int?
    var tier: String?
    var masked: Bool
    var scannedRows: Int
    var candidates: [DatabaseDealCandidate]
    var isFinalPage: Bool
    var note: String
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum DatabaseDealScout {
    typealias PageLoader = (_ page: Int, _ perPage: Int) async throws -> PropertyPage

    static let defaultPerPage = 250
    static let defaultMinimumScore = 70

    /// Candidate signal the buyer scopes the database scan to. Every case maps to a
    /// REAL server-side predicate (see the Worker's CATEGORY_PREDICATES) or to an
    /// unscoped area scan — never a fabricated flag.
    enum LotSignal: String, CaseIterable, Identifiable {
        case teardown = "Teardown ratio"
        case vacantLand = "Vacant land"
        case valueSpread = "Value spread"
        case all = "All signals"
        var id: String { rawValue }
        var apiCategory: String? {
            switch self {
            case .teardown: return "teardown"
            case .vacantLand: return "vacant_land"
            case .valueSpread: return "value_spread"
            case .all: return nil
            }
        }
        var blurb: String {
            switch self {
            case .teardown: return "Cheap structure on dear land — the assessor's own improvement-to-land split."
            case .vacantLand: return "Land value with zero improvement value — buildable dirt."
            case .valueSpread: return "Last recorded sale far below assessed value."
            case .all: return "Every parcel in the area, scored for any deal signal."
            }
        }
    }

    /// Build the criteria for a scoped lot scan: the chosen area + the signal's server
    /// category (an honest whitelisted predicate). "All signals" = the whole area,
    /// scored client-side; a specific signal pre-filters pages server-side so even a
    /// preview-tier 25-row page is dense with relevant parcels.
    static func criteria(area: DatabaseListArea, signal: LotSignal) -> DatabaseListCriteria {
        var c = DatabaseListCriteria()
        c.type = .custom
        c.area = area
        c.categoryOverride = signal.apiCategory
        return c
    }

    /// The live page loader for a scoped scan.
    static func liveLoader(area: DatabaseListArea, signal: LotSignal) -> PageLoader {
        { page, perPage in
            try await RealEstateAPI.listSearch(criteria(area: area, signal: signal), page: page, perPage: perPage)
        }
    }

    static func scanPage(page: Int,
                         perPage: Int = defaultPerPage,
                         minimumScore: Int = defaultMinimumScore,
                         loader: PageLoader) async throws -> DatabaseDealScanPage {
        let requestedPage = max(1, page)
        let requestedPerPage = max(1, perPage)
        let loaded = try await loader(requestedPage, requestedPerPage)
        let actualPage = loaded.page ?? requestedPage
        let actualPerPage = max(1, loaded.per_page ?? requestedPerPage)
        let rows = loaded.results
        let scannedCount = loaded.count ?? rows.count
        let candidates = rows.compactMap { evaluate($0, minimumScore: minimumScore) }
            .sorted { ($0.score, $0.record.assessed_value ?? 0) > ($1.score, $1.record.assessed_value ?? 0) }
        let masked = loaded.masked == true || (loaded.tier ?? "").lowercased().contains("preview")
        let total = loaded.total
        let scannedThrough = actualPage * actualPerPage
        let finalByTotal = total.map { scannedThrough >= $0 } ?? false
        let finalByShortPage = total == nil && scannedCount < actualPerPage
        let final = masked || finalByTotal || finalByShortPage
        let note: String
        if masked {
            note = "Lead Database returned preview/masked rows, so the scan stopped at the accessible page. Add the owned database token in Settings to scan every row."
        } else if candidates.isEmpty {
            note = "Page \(actualPage) scanned \(scannedCount) database row\(scannedCount == 1 ? "" : "s"); no property cleared the good-deal threshold on this page."
        } else {
            note = "Page \(actualPage) scanned \(scannedCount) database row\(scannedCount == 1 ? "" : "s") and found \(candidates.count) qualified deal\(candidates.count == 1 ? "" : "s")."
        }
        return DatabaseDealScanPage(page: actualPage,
                                    perPage: actualPerPage,
                                    total: total,
                                    tier: loaded.tier,
                                    masked: masked,
                                    scannedRows: scannedCount,
                                    candidates: candidates,
                                    isFinalPage: final,
                                    note: note)
    }

    static func evaluate(_ record: PropertyRecord, minimumScore: Int = defaultMinimumScore) -> DatabaseDealCandidate? {
        var reasons: [DatabaseDealReason] = []
        var risks: [String] = []
        var score = 0

        if let land = record.land_value, let improvement = record.improvement_value, land >= 40_000 {
            let ratio = Double(improvement) / Double(max(1, land))
            if ratio <= 0.35 {
                let pts = ratio <= 0.12 ? 58 : (ratio <= 0.22 ? 52 : 44)
                score += pts
                reasons.append(DatabaseDealReason(
                    title: "Teardown economics",
                    detail: "Improvement value is \(flipPct(ratio)) of land value (\(REMath.money(Double(improvement))) building on \(REMath.money(Double(land))) land).",
                    points: pts,
                    isEconomic: true))
            } else if ratio <= 0.50 {
                let pts = 28
                score += pts
                reasons.append(DatabaseDealReason(
                    title: "Tired structure signal",
                    detail: "Improvement value is \(flipPct(ratio)) of land value; useful, but weaker than a scrape-ready lot.",
                    points: pts,
                    isEconomic: true))
            }
        } else if record.land_value != nil || record.improvement_value != nil {
            risks.append("The row has only part of the land/improvement split, so the teardown ratio is not counted.")
        } else {
            risks.append("No land/improvement split returned on this row.")
        }

        if let assessed = record.assessed_value, let land = record.land_value, assessed > 0, land > 0 {
            let share = Double(land) / Double(assessed)
            if share >= 0.62 {
                let pts = share >= 0.78 ? 20 : 14
                score += pts
                reasons.append(DatabaseDealReason(
                    title: "Land-heavy assessed value",
                    detail: "Land is \(flipPct(share)) of assessed value (\(REMath.money(Double(land))) of \(REMath.money(Double(assessed)))).",
                    points: pts,
                    isEconomic: true))
            }
        }

        if let land = record.land_value, land >= 40_000 {
            let pts = land >= 150_000 ? 12 : (land >= 80_000 ? 9 : 5)
            score += pts
            reasons.append(DatabaseDealReason(
                title: "Buildable land floor",
                detail: "Assessor land value is \(REMath.money(Double(land))), high enough to be worth builder disposition work.",
                points: pts,
                isEconomic: true))
        }

        if let assessed = record.assessed_value, let sale = record.last_sale_price, assessed >= 50_000, sale > 0, sale < assessed {
            let gap = assessed - sale
            let discount = Double(gap) / Double(assessed)
            if discount >= 0.25 {
                let pts = discount >= 0.45 ? 50 : (discount >= 0.35 ? 42 : 32)
                score += pts
                reasons.append(DatabaseDealReason(
                    title: "Recorded-sale value spread",
                    detail: "Last sale \(REMath.money(Double(sale))) sits \(flipPct(discount)) below assessed value \(REMath.money(Double(assessed)))\(record.last_sale_date.map { " on \($0)" } ?? "").",
                    points: pts,
                    isEconomic: true))
                if gap >= 75_000 {
                    score += 14
                    reasons.append(DatabaseDealReason(
                        title: "Large public-record gap",
                        detail: "Assessed value exceeds last sale by \(REMath.money(Double(gap))).",
                        points: 14,
                        isEconomic: true))
                } else if gap >= 30_000 {
                    score += 8
                    reasons.append(DatabaseDealReason(
                        title: "Usable public-record gap",
                        detail: "Assessed value exceeds last sale by \(REMath.money(Double(gap))).",
                        points: 8,
                        isEconomic: true))
                }
            }
        }

        if isAbsentee(record) {
            score += 8
            reasons.append(DatabaseDealReason(
                title: "Absentee-owner lead path",
                detail: "Mailing address differs from the situs address, so direct mail has a separate owner destination.",
                points: 8,
                isEconomic: false))
        }
        if !mailingLine(record).isEmpty {
            score += 5
            reasons.append(DatabaseDealReason(
                title: "Mailable public record",
                detail: "Owner mailing address is present in the database row.",
                points: 5,
                isEconomic: false))
        } else {
            risks.append("No owner mailing address came back with this record.")
        }
        if record.owner_name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            score += 3
        } else {
            risks.append("Owner name is missing or masked on this row.")
        }
        if record.source_url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            score += 2
        }

        score = min(100, score)
        let economics = reasons.filter(\.isEconomic)
        guard score >= minimumScore, !economics.isEmpty else { return nil }

        risks.append("Public-record math does not prove ARV, title, access, taxes, or seller motivation.")
        if record.assessed_value == nil { risks.append("No assessed value returned; the scout did not infer ARV.") }
        if record.last_sale_price == nil { risks.append("No last-sale price returned; sale-discount math is unavailable.") }
        if record.lat == nil || record.lng == nil { risks.append("No database coordinate returned; map routing may need address geocoding.") }

        let tier: String
        switch score {
        case 88...: tier = "Prime"
        case 78..<88: tier = "Strong"
        default: tier = "Qualified"
        }
        let leadReason = economics.max { $0.points < $1.points }?.title ?? "Public-record deal signal"
        let headline = "\(tier) full-database deal - \(score)/100"
        let values = valueSummary(record)
        let summary = "Why this is a deal: \(leadReason). \(values.isEmpty ? "The property cleared the score threshold from real public-record fields." : values) Work it as a lot-flip/discount-lead candidate, then verify ARV, title, access, taxes, and owner motivation before writing an offer."
        let next = [
            "Open the parcel/source record and confirm the assessor values still match.",
            "Run comps or local builder resale checks before setting MAO.",
            mailingLine(record).isEmpty ? "Find a compliant owner contact path before outreach." : "Send owner mail or skip-trace from the recorded mailing address."
        ]
        return DatabaseDealCandidate(record: record,
                                     score: score,
                                     tier: tier,
                                     headline: headline,
                                     summary: summary,
                                     reasons: reasons.sorted { $0.points > $1.points },
                                     risks: risks,
                                     nextSteps: next)
    }

    static func situsLine(_ r: PropertyRecord) -> String {
        let street = r.situs_address ?? ""
        let city = [r.situs_city, r.situs_state, r.situs_zip]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [street, city].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func mailingLine(_ r: PropertyRecord) -> String {
        let street = r.mailing_address ?? ""
        let city = [r.mailing_city, r.mailing_state, r.mailing_zip]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [street, city].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func marketLine(_ r: PropertyRecord) -> String {
        let county = r.county?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = r.state?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        if county.isEmpty { return state }
        return state.isEmpty ? county : "\(county), \(state)"
    }

    static func isAbsentee(_ r: PropertyRecord) -> Bool {
        let situs = normalizedAddress([r.situs_address, r.situs_city, r.situs_state, r.situs_zip])
        let mailing = normalizedAddress([r.mailing_address, r.mailing_city, r.mailing_state, r.mailing_zip])
        return !situs.isEmpty && !mailing.isEmpty && situs != mailing
    }

    private static func normalizedAddress(_ parts: [String?]) -> String {
        parts.compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func valueSummary(_ r: PropertyRecord) -> String {
        var bits: [String] = []
        if let assessed = r.assessed_value { bits.append("assessed \(REMath.money(Double(assessed)))") }
        if let land = r.land_value { bits.append("land \(REMath.money(Double(land)))") }
        if let improvement = r.improvement_value { bits.append("improvement \(REMath.money(Double(improvement)))") }
        if let sale = r.last_sale_price { bits.append("last sale \(REMath.money(Double(sale)))") }
        return bits.isEmpty ? "" : "Public values: " + bits.joined(separator: ", ") + "."
    }
}
#endif // circuit-convert
