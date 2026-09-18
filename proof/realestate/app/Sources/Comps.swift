// Black Label Real Estate — SOLD-COMPS + ARV engine (real recorded sales, honest fallbacks).
//
// THE GAP THIS CLOSES: until now ARV was a county-ASSESSED proxy (the 3-mile average assessed
// value), and every deal calculator (MAO, flip, BRRRR, cap rate) consumes `arv` — so assessed ≠
// after-repair market value made the whole deal-analysis spine soft. This engine derives ARV from
// REAL recorded arm's-length SALES near the subject, where the county's open ArcGIS layer publishes
// the deed's sale price + date (+ living area). No Zillow scrape, no paid AVM, no fabrication.
//
// HONESTY LADDER (never a faked comp):
//   1. SOLD COMPS  — county publishes sale price/date → pull recent nearby sales, derive ARV from
//                    the median $/sqft (when subject sqft is known) or the median sale price. The
//                    actual comp set (real addresses, real prices, real dates) is surfaced so the
//                    buyer sees the basis.
//   2. AVM ESTIMATE — county publishes assessed value but NO sale price → ARV = 3-mile average
//                    assessed value, clearly LABELED "estimate (county-assessed), not sold comps".
//   3. GATE         — neither available → honest "connect a comps source" state. Nothing invented.
//
// OUTLIER DISCIPLINE (this is comp methodology, not fabrication): county sale rolls contain
// multi-parcel/bulk deeds and non-arm's-length transfers (e.g. a $7.2M price attached to a $190k
// parcel). We resist them: drop sales far outside a sane band vs the area's typical sale, use the
// MEDIAN not the mean, and require a minimum comp count before trusting a $/sqft figure.
//
// Pure Foundation (no SwiftUI / AppKit) so parse + derive are unit-testable offline by feeding a
// captured ArcGIS JSON straight into `parseSales` / `derive`.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Models

/// One real recorded sale near the subject (from the county's own deed roll).
struct SaleComp: Identifiable, Hashable {
    let id = UUID()
    var address: String
    var salePrice: Int
    var saleYear: Int
    var saleMonth: Int?       // nil when the county only publishes a year
    var sqft: Double?         // heated/living area, when published
    var distanceMiles: Double?
    var assessedValue: Int?

    /// $/sqft for this comp, when both are known and sane.
    var pricePerSqft: Double? {
        guard let s = sqft, s >= 200 else { return nil }   // ignore garbage tiny/zero areas
        return Double(salePrice) / s
    }
    var dateLabel: String {
        if let m = saleMonth, m >= 1, m <= 12 {
            let months = ["", "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
            return "\(months[m]) \(saleYear)"
        }
        return "\(saleYear)"
    }
}

/// How the ARV was arrived at — drives the honest label the buyer reads in the deal screen.
enum ARVBasis: String, Hashable {
    case soldCompsPerSqft     // median $/sqft of nearby sales × subject sqft
    case soldCompsMedian      // median nearby sale price (no subject sqft to scale by)
    case sampleEstimate       // synthetic Sample Mode workflow preview; never a sale/verification claim
    case parcelOwnSaleAnchor  // the subject parcel's OWN recorded sale(s) — real recorded, but NOT a
                              // neighborhood ring (all distanceMiles==0). A labeled anchor at the
                              // assessedAVM confidence tier (isComp==false), never a green-seal comp —
                              // a parcel's own past sale is a weak ARV basis (standing rule 17).
    case assessedAVM          // labeled estimate from the single 3-mile county-assessed average
    case assessedAreaEstimate // labeled estimate from a ZIP/area read of the public-records index (NOT sold comps)
    case none                 // gated — no source

    var label: String {
        switch self {
        case .soldCompsPerSqft:     return "Sold comps ($/sqft median)"
        case .soldCompsMedian:      return "Sold comps (median sale)"
        case .sampleEstimate:       return "Sample estimate — not verified"
        case .parcelOwnSaleAnchor:  return "Anchor — parcel's own recorded sale (not neighborhood comps)"
        case .assessedAVM:          return "Estimate — county-assessed (not sold comps)"
        case .assessedAreaEstimate: return "Assessed-value estimate (area read, not sold comps)"
        case .none:                 return "No comps source"
        }
    }
    /// True ONLY for real recorded arm's-length NEIGHBORHOOD sales. Assessed estimates and a parcel's
    /// OWN recorded sale (an anchor, not a neighborhood ring — rule 17) are never green-seal comps.
    var isComp: Bool { self == .soldCompsPerSqft || self == .soldCompsMedian }
}

/// Where the comps/estimate came from — carried so the buyer (and QA) can trace provenance and
/// nothing is presented as more than it is. Distinct from ARVBasis (which is the *method*).
enum CompsSource: String, Hashable {
    case countyArcGIS    // the county's own open deed roll (live ArcGIS sale fields)
    case leadDatabase    // our harvested public-records index via RealEstateAPI (/v1/search)
    case countyAssessed  // the single 3-mile county-assessed average supplied by the caller
    case sample          // synthetic Sample Mode comparables; never presented as live/public records
    case none            // gated — no source produced a figure

    var label: String {
        switch self {
        case .countyArcGIS:   return "County deed roll (ArcGIS)"
        case .leadDatabase:   return "Public-records index"
        case .countyAssessed: return "County-assessed (3-mi avg)"
        case .sample:         return "Synthetic Sample Mode comparables"
        case .none:           return "No source"
        }
    }
}

/// The comps result handed to the deal screen. `arv` is nil only when fully gated.
struct CompsResult: Hashable {
    var available: Bool
    var basis: ARVBasis
    var arv: Int?
    var perSqft: Double?            // median $/sqft used (when basis == soldCompsPerSqft)
    var comps: [SaleComp]          // the real comp set (empty for AVM / gate)
    var radiusMiles: Double
    var note: String               // honest one-liner the UI surfaces
    var source: CompsSource = .none // provenance (defaulted so existing callers/tests are unaffected)

    /// True when this estimate came from a ZIP/area read rather than a precise radius — drives the
    /// UI's "area read" wording so we never imply a fake 3-mile ring when lat/lng were sparse.
    var isAreaRead: Bool = false

    /// True ONLY when the comps came from the SUBJECT PARCEL'S OWN recorded sales roll (the compsRoll
    /// path) rather than a neighborhood ring or a labeled AVM. Drives the CompsResultView BASIS label so
    /// the buyer reads "this parcel's own recorded sales history" — never an unlabeled number (§5.1).
    /// Defaulted false so every existing caller/test is byte-for-byte unaffected.
    var fromParcelOwnHistory: Bool = false

    static func gated(_ note: String, radius: Double) -> CompsResult {
        CompsResult(available: false, basis: .none, arv: nil, perSqft: nil, comps: [], radiusMiles: radius, note: note)
    }
}

/// Source-aware trust classification. A sold-comps method is not self-authenticating: it receives
/// verified treatment only when actual rows accompany an authoritative county/index provenance.
/// Synthetic Sample Mode is an explicit estimate class even when it carries illustrative rows.
enum CompsEvidenceKind: Hashable {
    case verifiedSoldComps
    case sampleEstimate
    case unverifiedEstimate
    case unavailable
    case invalid
}

enum CompsTruthPolicy {
    static func kind(_ result: CompsResult) -> CompsEvidenceKind {
        guard result.available, result.arv != nil else { return .unavailable }
        if result.source == .sample { return .sampleEstimate }
        if result.basis.isComp {
            let authoritative = result.source == .countyArcGIS || result.source == .leadDatabase
            return authoritative && !result.comps.isEmpty ? .verifiedSoldComps : .invalid
        }
        return .unverifiedEstimate
    }

    static func isVerifiedSoldComps(_ result: CompsResult) -> Bool {
        kind(result) == .verifiedSoldComps
    }
}

// MARK: - Engine

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum CompsEngine {
    static let defaultRadiusMeters = 4828          // ~3 miles (same ring as the area-value pull)
    static let maxComps = 400                      // hard cap on the sale query (bounded payload)
    static let lookbackMonths = 36                 // recent sales only — older deeds drift from market
    static let minCompsForPerSqft = 4              // need a few real comps before trusting $/sqft
    static let sqftSimilarityBand = 0.40           // $/sqft comps must be within ±40% of subject GLA (appraisal norm)

    // MARK: numeric coercion (ArcGIS fields arrive String OR Number per county)
    static func money(_ v: Any?) -> Int? {
        if let i = v as? Int { return i > 0 ? i : nil }
        if let d = v as? Double { return d > 0 ? Int(d) : nil }
        if let s = v as? String {
            let c = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
            if let d = Double(c), d > 0 { return Int(d) }
        }
        return nil
    }
    static func dbl(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
        return nil
    }
    static func intVal(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        return nil
    }

    /// Parse a STRING recorded-sale date into (year, month?). Handles a packed 8-digit "YYYYMMDD"
    /// (Buncombe DeedDate, e.g. "20200619") and a delimited "yyyy-MM-dd" / "yyyy/MM/dd" (Cumberland
    /// DEED_DATE, e.g. "2026-07-02"). Positional/locale-free — no DateFormatter. Returns nil when no sane
    /// 4-digit year is present (a NULL sentinel, book/page fragment, or blank), so a sale whose date won't
    /// parse is DROPPED by the caller and never dated or treated as recent — never a fabricated date.
    static func stringSaleYearMonth(_ raw: Any?) -> (year: Int, month: Int?)? {
        let s = "\(raw ?? "")".trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // Packed YYYYMMDD (exactly 8 digits, all numeric) → split positionally.
        if s.count == 8, s.allSatisfy({ $0.isNumber }) {
            guard let y = Int(s.prefix(4)), y > 1900, y < 3000 else { return nil }
            let m = Int(s.dropFirst(4).prefix(2)) ?? 0
            return (y, (m >= 1 && m <= 12) ? m : nil)
        }
        // Delimited: the first 4-digit run is the year, an immediately-following 1–2 digit run the month.
        let parts = s.split(whereSeparator: { !$0.isNumber }).map(String.init)
        if let first = parts.first, first.count == 4, let y = Int(first), y > 1900, y < 3000 {
            var month: Int? = nil
            if parts.count >= 2, let m = Int(parts[1]), m >= 1, m <= 12 { month = m }
            return (y, month)
        }
        // Oracle "DD-MON-YY" (Onslow SALEDATE, e.g. "31-OCT-95") — reuse the recorder's stable-pivot parser
        // so a county whose only recency signal is an Oracle date still drives REAL sold comps.
        if let (y, m, _) = TitleChainEngine.oracleDMY(s) { return (y, m) }
        return nil
    }

    /// Great-circle miles between two coordinates (self-contained so Comps has no UI/engine deps).
    static func haversineMiles(_ aLat: Double, _ aLng: Double, _ bLat: Double, _ bLng: Double) -> Double {
        let R = 3958.7613
        let dLat = (bLat - aLat) * .pi / 180, dLng = (bLng - aLng) * .pi / 180
        let s1 = sin(dLat / 2), s2 = sin(dLng / 2)
        let h = s1 * s1 + cos(aLat * .pi / 180) * cos(bLat * .pi / 180) * s2 * s2
        return 2 * R * asin(min(1, sqrt(h)))
    }

    /// Median of a sorted-or-unsorted Int set (nil for empty).
    static func median(_ xs: [Int]) -> Int? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2
    }
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2
    }

    /// (year, month) cutoff `lookbackMonths` before now — a recent-sales gate the county query and
    /// the parser both use. Pure (injectable `now` for tests).
    static func cutoff(monthsBack: Int = lookbackMonths, now: Date = Date()) -> (year: Int, month: Int) {
        let cal = Calendar(identifier: .gregorian)
        let then = cal.date(byAdding: .month, value: -monthsBack, to: now) ?? now
        let c = cal.dateComponents([.year, .month], from: then)
        return (c.year ?? 2000, c.month ?? 1)
    }

    /// Parse an ArcGIS `{features:[...]}` sales response into recent, sane SaleComps (pure; no net).
    /// Drops sales with no price, sales older than the lookback window, and obvious bulk/garbage rows.
    static func parseSales(_ json: [String: Any], _ reg: CountyParcelSource,
                           subjectLat: Double? = nil, subjectLng: Double? = nil,
                           now: Date = Date()) -> [SaleComp] {
        guard let priceF = reg.salePriceField, let feats = json["features"] as? [[String: Any]] else { return [] }
        let cut = cutoff(now: now)
        var out: [SaleComp] = []
        for f in feats {
            let a = f["attributes"] as? [String: Any] ?? [:]
            guard let price = money(a[priceF]), price >= 10_000 else { continue }   // skip $0/$1 transfers
            // Sale recency — an epoch-ms date, a parseable string date, or split year/month integers.
            var year = 0, month: Int? = nil
            if let df = reg.saleDateField, let ms = dbl(a[df]) {
                let d = Date(timeIntervalSince1970: ms / 1000.0)
                let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: d)
                year = c.year ?? 0; month = c.month
            } else if let sf = reg.saleDateStringField, let ym = stringSaleYearMonth(a[sf]) {
                year = ym.year; month = ym.month
            } else if let yf = reg.saleYearField, let y = intVal(a[yf]) {
                year = y
                if let mf = reg.saleMonthField { month = intVal(a[mf]) }
            }
            guard year > 0 else { continue }   // no parseable date (incl. a garbage/missing string) → dropped
            // Recent only: year after cutoff year, or same year at/after cutoff month.
            let recent = year > cut.year || (year == cut.year && (month ?? 12) >= cut.month)
            guard recent else { continue }
            let sqft = reg.sqftField.flatMap { dbl(a[$0]) }
            let addr = reg.addrField.map { "\(a[$0] ?? "")".trimmingCharacters(in: .whitespaces) } ?? ""
            var dist: Double? = nil
            if let sLat = subjectLat, let sLng = subjectLng {
                let g = f["geometry"] as? [String: Any] ?? f["centroid"] as? [String: Any]
                if let gy = dbl(g?["y"]), let gx = dbl(g?["x"]) {
                    dist = haversineMiles(sLat, sLng, gy, gx)
                }
            }
            out.append(SaleComp(address: addr.isEmpty ? "(address on record)" : addr,
                                salePrice: price, saleYear: year, saleMonth: month,
                                sqft: (sqft ?? 0) > 0 ? sqft : nil, distanceMiles: dist,
                                assessedValue: reg.valueField.flatMap { money(a[$0]) }))
        }
        return out
    }

    /// Derive ARV + the comp set from parsed sales (pure). Outlier-resistant: trims sales far outside
    /// the area's interquartile-ish band before taking the median, so a bulk/non-arm's-length deed
    /// can't inflate ARV. `subjectSqft` scales a $/sqft figure into the subject's ARV when known.
    static func derive(_ sales: [SaleComp], subjectSqft: Double?, radiusMiles: Double) -> CompsResult {
        guard !sales.isEmpty else {
            return CompsResult(available: false, basis: .none, arv: nil, perSqft: nil, comps: [],
                               radiusMiles: radiusMiles,
                               note: "No recent recorded sales near this address in the county roll.")
        }
        // Trim price outliers vs the area median (resist multi-parcel / non-arm's-length deeds).
        let prices = sales.map { $0.salePrice }
        let med = median(prices) ?? 0
        let band = sales.filter { med == 0 ? true : (Double($0.salePrice) >= Double(med) * 0.25 && Double($0.salePrice) <= Double(med) * 4.0) }
        let comps = band.isEmpty ? sales : band
        // Closest comps first (when we have distances), then most recent — the set the buyer reads.
        let ordered = comps.sorted {
            let da = $0.distanceMiles ?? .greatestFiniteMagnitude, db = $1.distanceMiles ?? .greatestFiniteMagnitude
            if da != db { return da < db }
            return ($0.saleYear, $0.saleMonth ?? 0) > ($1.saleYear, $1.saleMonth ?? 0)
        }
        let shown = Array(ordered.prefix(25))

        // Prefer $/sqft when we have the subject's sqft AND enough comps that carry sqft.
        // Appraisal discipline: when the subject size is known, weight the $/sqft basis toward
        // SIZE-SIMILAR sales (within ±sqftSimilarityBand of the subject GLA) so a much larger or
        // smaller home's $/sqft can't skew the subject's ARV — the price-band trim alone doesn't
        // catch a big house whose total price is in-band but whose $/sqft is off. Only narrow when
        // enough similar comps survive; otherwise fall back to the full $/sqft set rather than
        // over-filter into no-data (honesty ladder — never invent a number).
        if let subj = subjectSqft, subj >= 200 {
            let sqftComps = comps.filter { let p = $0.pricePerSqft ?? 0; return p > 5 && p < 2000 }
            let lo = subj * (1 - sqftSimilarityBand), hi = subj * (1 + sqftSimilarityBand)
            let similar = sqftComps.filter { let s = $0.sqft ?? 0; return s >= lo && s <= hi }
            let sizeMatched = similar.count >= minCompsForPerSqft
            let used = sizeMatched ? similar : sqftComps
            let perSqftVals = used.compactMap { $0.pricePerSqft }
            if perSqftVals.count >= minCompsForPerSqft, let mps = median(perSqftVals) {
                let arv = Int((mps * subj).rounded())
                let sizeNote = (sizeMatched && similar.count < sqftComps.count)
                    ? ", size-matched within ±\(Int(sqftSimilarityBand * 100))% of \(Int(subj)) sqft"
                    : ""
                return CompsResult(available: true, basis: .soldCompsPerSqft, arv: arv, perSqft: mps,
                                   comps: shown, radiusMiles: radiusMiles,
                                   note: "ARV from the median $\(Int(mps))/sqft of \(perSqftVals.count) recent nearby sales\(sizeNote) × \(Int(subj)) sqft.")
            }
        }
        // Else median recent sale price (a real comp figure, just not sqft-scaled).
        if let medSale = median(comps.map { $0.salePrice }) {
            return CompsResult(available: true, basis: .soldCompsMedian, arv: medSale, perSqft: nil,
                               comps: shown, radiusMiles: radiusMiles,
                               note: "ARV from the median of \(comps.count) recent nearby recorded sales (no subject sqft to scale by $/sqft).")
        }
        return CompsResult.gated("Recent sales found but no usable price — nothing invented.", radius: radiusMiles)
    }

    /// Bridge a recorded-sales `TitleChainSet` (the `.saleRecords` shape — e.g. Alamance's multi-row
    /// Tax/Sales_History roll) into `SaleComp`s: EVERY sale/deed event that carries a real recorded
    /// price (≥ $10k, so $0/$1 non-arm's-length transfers drop) AND a parseable recorded date becomes
    /// one comp. A row missing EITHER is DROPPED — never a fabricated comp. These are the subject
    /// parcel's own recorded sale history (same address, so distance 0 and sqft unknown/nil), used as a
    /// real-recorded-sale ARV anchor when no neighborhood sold-comp layer is available. Pure; no net.
    static func compsFromTitleChain(_ set: TitleChainSet) -> [SaleComp] {
        var out: [SaleComp] = []
        for e in set.events {
            guard e.kind == .deed, let price = e.amount, price >= 10_000 else { continue }
            guard let ym = stringSaleYearMonth(e.recordedDate) else { continue }
            out.append(SaleComp(address: e.party.isEmpty ? "(recorded sale)" : e.party,
                                salePrice: price, saleYear: ym.year, saleMonth: ym.month,
                                sqft: nil, distanceMiles: 0, assessedValue: nil))
        }
        return out
    }

    // MARK: - Live query (network; honest fallbacks)

    /// Build the sold-comps query for a county layer around a point. Recent sales only, bounded count,
    /// centroid-not-polygon geometry (so a dense ring isn't a multi-hundred-MB JSON tree — same memory
    /// discipline as the LotFlip scout). Returns nil when the county doesn't publish sales.
    static func queryParams(_ reg: CountyParcelSource, lat: Double, lng: Double,
                            radiusM: Int, now: Date = Date()) -> [String: String]? {
        guard let priceF = reg.salePriceField, reg.supportsComps else { return nil }
        let cut = cutoff(now: now)
        // WHERE: positive sale price + recent. Date vs split-year/month per county.
        var whereClauses = [reg.salePricePredicate ?? "\(priceF) > 10000"]
        if reg.saleDateField != nil || reg.saleDateStringField != nil {
            // epoch-ms OR string date — recency is enforced client-side in parseSales (date math /
            // string comparison in WHERE is brittle across servers); keep the WHERE to price + let
            // parse drop old sales.
        } else if let yf = reg.saleYearField {
            whereClauses.append("\(yf) >= \(cut.year - 1)")   // coarse year gate; parse refines by month
        }
        let dlat = Double(radiusM) / 111_320.0
        let dlng = Double(radiusM) / (111_320.0 * max(0.1, cos(lat * .pi / 180)))
        let env = "\(lng - dlng),\(lat - dlat),\(lng + dlng),\(lat + dlat)"
        var outFields = [priceF, reg.parcelField]
        if let af = reg.addrField { outFields.append(af) }
        if let s = reg.sqftField { outFields.append(s) }
        if let d = reg.saleDateField { outFields.append(d) }
        if let ds = reg.saleDateStringField { outFields.append(ds) }
        if let y = reg.saleYearField { outFields.append(y) }
        if let m = reg.saleMonthField { outFields.append(m) }
        if let v = reg.valueField { outFields.append(v) }
        return [
            "where": whereClauses.joined(separator: " AND "),
            "geometry": env, "geometryType": "esriGeometryEnvelope", "inSR": "4326", "outSR": "4326",
            "spatialRel": "esriSpatialRelIntersects",
            "outFields": outFields.joined(separator: ","),
            "returnGeometry": "false", "returnCentroid": "true",
            "resultRecordCount": "\(maxComps)", "f": "json",
        ]
    }

    /// Full comps pull for a subject. Honesty ladder, in order:
    ///   1. SOLD COMPS  — the county's own open deed roll (live ArcGIS sale fields), where it has them.
    ///   2. PUBLIC-RECORDS READ — when the county lacks live ArcGIS sales, query our harvested
    ///      public-records index (RealEstateAPI.search by ZIP/state). If that returns real recorded
    ///      sales (the rare ~1.9% with a recent last_sale_price) → SOLD COMPS; otherwise aggregate
    ///      assessed_value into a clearly-LABELED "assessed-value estimate (not sold comps)".
    ///   3. AVM         — the single 3-mile county-assessed average the caller already pulled.
    ///   4. GATE        — nothing real available; honest connect-a-source state. Never fabricated.
    /// `assessedAVM` is supplied by the caller (it already pulls `areaValueAvg`); we never re-invent it.
    static func comps(county: String, lat: Double, lng: Double, subjectSqft: Double?,
                      zip: String? = nil, state: String? = nil, parcelId: String? = nil,
                      radiusM: Int = defaultRadiusMeters, fetch: ParcelLookup.Fetch = ParcelLookup.liveFetch,
                      apiSearch: APISearch = liveAPISearch, rollFetch: RollFetch = liveRollFetch,
                      assessedAVM: Int? = nil, now: Date = Date()) async -> CompsResult {
        let radiusMiles = Double(radiusM) / 1609.344
        let reg = ParcelRegistry.source(for: county)

        // 1) County open deed roll (live ArcGIS sale fields) — the strongest, most-local basis.
        if let reg = reg, reg.supportsComps, let params = queryParams(reg, lat: lat, lng: lng, radiusM: radiusM, now: now) {
            if let json = await fetch(reg.url, params), json["error"] == nil {
                let sales = parseSales(json, reg, subjectLat: lat, subjectLng: lng, now: now)
                var r = derive(sales, subjectSqft: subjectSqft, radiusMiles: radiusMiles)
                if r.available { r.source = .countyArcGIS; return r }
                // no recent county sales — fall through to the roll / public-records read
            }
        }

        // 1b) The subject parcel's OWN recorded sales ROLL — a `.saleRecords` multi-row deed feed
        //     (Alamance's Tax/Sales_History, Cleveland's Vacant_ImprovedLot_Sales). When the lead
        //     carries a parcel id and the county has such a roll, its real recorded priced+dated sales
        //     become sold comps via `compsFromTitleChain` (a $0/undated row DROPS — never fabricated).
        //     This is the subject's own recorded history — a real-recorded-sale ARV anchor for a county
        //     with no neighborhood sold-comp layer (step 1 produced nothing). Only runs when a parcel id
        //     is supplied, so every existing comps flow (no parcel id) is byte-for-byte unchanged.
        if let pid = parcelId?.trimmedNonEmpty,
           let roll = TitleRecorderRegistry.compsRoll(county: county, state: state ?? ""),
           let url = roll.queryURL(parcelId: pid)?.absoluteString,
           let data = await rollFetch(url) {
            let set = roll.parse(data, county: county, fetchedDate: "")
            let sales = compsFromTitleChain(set)
            let r = derive(sales, subjectSqft: subjectSqft, radiusMiles: radiusMiles)
            if r.available {
                // STANDING RULE 17: `compsFromTitleChain` can only ever yield the SUBJECT parcel's OWN
                // recorded sales (every comp is built with distanceMiles==0 — no neighborhood ring). Such
                // a figure is real and county-published, but a parcel's own past sale is a WEAK ARV basis
                // — at worst a median of one. So:
                //   (a) prefer the step-3 3-mi assessed AVM over a median-of-one (fall through when we
                //       have a real AVM to use — a broader basis than a single own-sale), and
                //   (b) otherwise DEMOTE the result from a green-seal sold-comp median to a labeled anchor
                //       at the assessedAVM confidence tier (isComp==false) — real recorded, but never
                //       presented with the green comp seal.
                let ownHistory = !r.comps.isEmpty && r.comps.allSatisfy { ($0.distanceMiles ?? 0) == 0 }
                if ownHistory {
                    let medianOfOne = r.comps.count <= 1
                    if medianOfOne, let avm = assessedAVM, avm > 0 {
                        // (a) fall through to the labeled 3-mile assessed AVM — broader than one sale.
                    } else {
                        // (b) demote to the parcel's-own-sale anchor (real recorded, not a comp).
                        var anchor = r
                        anchor.basis = .parcelOwnSaleAnchor
                        anchor.source = .countyArcGIS
                        anchor.fromParcelOwnHistory = true
                        let n = anchor.comps.count
                        anchor.note = "ARV anchored to \(n) of the subject parcel's own recorded \(n == 1 ? "sale" : "sales") in the \(county.capitalized) County deed roll — a real recorded figure, labeled as the parcel's own history (not a neighborhood ring, so not a green-seal sold comp). A parcel's own past sale is a weak ARV basis — treat it as an anchor and verify against recent nearby sales."
                        return anchor
                    }
                } else {
                    // Defensive: a roll that somehow carried genuine neighborhood distances keeps its seal.
                    var r = r
                    r.source = .countyArcGIS
                    r.fromParcelOwnHistory = true
                    r.note = "ARV from \(sales.count) of the subject parcel's own recorded \(sales.count == 1 ? "sale" : "sales") in the \(county.capitalized) County deed roll — real recorded prices, the parcel's own history (not a neighborhood ring)."
                    return r
                }
            }
            // roll had no priced+dated sales (or a median-of-one preferred to the AVM) — fall through.
        }

        // 2) Public-records index read (only with a real ZIP or state to scope it — never a blind pull).
        if zip?.trimmedNonEmpty != nil || state?.trimmedNonEmpty != nil {
            let page = await apiSearch(zip?.trimmedNonEmpty, state?.trimmedNonEmpty)
            let r = deriveFromAPI(page, subjectSqft: subjectSqft, subjectLat: lat, subjectLng: lng,
                                  zip: zip, state: state, radiusMiles: radiusMiles, now: now)
            if r.available { return r }
            // index returned nothing usable — fall through to the single-number AVM
        }

        // 3) AVM fallback (a single labeled estimate, not a comp).
        if let avm = assessedAVM, avm > 0 {
            let supportsComps = reg?.supportsComps ?? false
            return CompsResult(available: true, basis: .assessedAVM, arv: avm, perSqft: nil, comps: [],
                               radiusMiles: radiusMiles,
                               note: supportsComps
                                   ? "No recent sold comps near this address — using the 3-mile county-assessed average as a labeled estimate."
                                   : "\(county.capitalized) County publishes no recorded sale prices — using the 3-mile county-assessed average as a labeled estimate, not sold comps.",
                               source: .countyAssessed)
        }

        // 4) Gate — honest connect-a-source state.
        if reg == nil {
            return CompsResult.gated("No open parcel/comps source for \(county.capitalized) County yet, and no public-records match for this area — gated, not faked. Enter ARV manually.", radius: radiusMiles)
        }
        return CompsResult.gated(reg?.supportsComps == true
            ? "No recent sold comps and no assessed value for this area — connect a comps source or enter ARV manually."
            : "\(county.capitalized) County's open layer publishes no sale prices — comps are gated. Enter ARV manually or connect a comps provider.",
            radius: radiusMiles)
    }

    // MARK: - Public-records index read (RealEstateAPI fallback; honest labels, real provenance)

    /// Inject-able search hook so `deriveFromAPI`/`comps` are testable offline by feeding a captured
    /// `PropertyPage`. The live default queries OUR harvested public-records index by PUBLIC params only
    /// (ZIP + state) — no PII/leads ever sent (see RealEstateAPI). `perPage` is wide enough to read a
    /// neighborhood; the server caps by tier, so we honestly aggregate whatever it returns.
    typealias APISearch = (_ zip: String?, _ state: String?) async -> PropertyPage
    static let liveAPISearch: APISearch = { zip, state in
        await RealEstateAPI.search(zip: zip, state: state, perPage: 500)
    }

    /// Inject-able fetch for a recorded-sales ROLL (a `.saleRecords` recorder layer). Returns raw Data
    /// so `TitleRecorderSource.parse` can build the chain; the live default is a plain keyless GET (the
    /// roll query URL already carries the parcel-id WHERE + outFields). nil on any non-200 / transport
    /// error → the caller falls through to its other honest bases (never a fabricated comp).
    typealias RollFetch = (_ url: String) async -> Data?
    static let liveRollFetch: RollFetch = { url in
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.setValue("BlackLabelRealEstate/1.0 (macOS comps)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 22
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
    static let minAPISales = 3          // need a few real recorded sales before calling it "sold comps"
    static let minAreaAssessed = 3      // need a few assessed values before trusting an area estimate

    /// Tolerant year/month parse of the index's `last_sale_date` (a String: "2023-05-10", "2023/05",
    /// "2023", or an epoch-ms number-as-string). Returns nil when no 4-digit year is present — so a
    /// sale with an unknown date is never silently treated as recent.
    static func apiSaleYearMonth(_ s: String?) -> (year: Int, month: Int?)? {
        guard let raw = s?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        // epoch-ms (e.g. "1683676800000") → convert.
        if raw.count >= 12, let ms = Double(raw) {
            let d = Date(timeIntervalSince1970: ms / 1000.0)
            let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: d)
            if let y = c.year, y > 1900 { return (y, c.month) }
        }
        // First 4-digit run = year; an immediately-following 1–2 digit group = month.
        let digits = raw.replacingOccurrences(of: "T", with: "-")
        let parts = digits.split(whereSeparator: { !$0.isNumber }).map(String.init)
        if let first = parts.first, first.count == 4, let y = Int(first), y > 1900, y < 3000 {
            var month: Int? = nil
            if parts.count >= 2, let m = Int(parts[1]), m >= 1, m <= 12 { month = m }
            return (y, month)
        }
        return nil
    }

    /// Extract REAL recorded sales from an index page: rows with a positive `last_sale_price` AND a
    /// recent `last_sale_date`. Distances are filled only where both subject and row carry lat/lng
    /// (lat/lng is ~45% filled), and absence is left nil — never a fabricated distance.
    static func apiSaleComps(from page: PropertyPage,
                             subjectLat: Double? = nil, subjectLng: Double? = nil,
                             now: Date = Date()) -> [SaleComp] {
        let cut = cutoff(now: now)
        var out: [SaleComp] = []
        for rec in page.results {
            guard let price = rec.last_sale_price, price >= 10_000 else { continue }
            guard let ym = apiSaleYearMonth(rec.last_sale_date) else { continue }   // unknown date ⇒ not a recent comp
            let recent = ym.year > cut.year || (ym.year == cut.year && (ym.month ?? 12) >= cut.month)
            guard recent else { continue }
            var dist: Double? = nil
            if let sLat = subjectLat, let sLng = subjectLng, let ry = rec.lat, let rx = rec.lng {
                dist = haversineMiles(sLat, sLng, ry, rx)
            }
            let addr = (rec.situs_address ?? rec.mailing_address)?.trimmingCharacters(in: .whitespaces)
            out.append(SaleComp(address: (addr?.isEmpty == false ? addr! : "(address on record)"),
                                salePrice: price, saleYear: ym.year, saleMonth: ym.month,
                                sqft: nil,                       // the index carries no living-area field
                                distanceMiles: dist,
                                assessedValue: rec.assessed_value))
        }
        return out
    }

    /// Median assessed value across an index page (the neighborhood assessed read) + the count used.
    /// Only positive assessed values count; nothing is imputed for blanks.
    static func areaAssessedEstimate(from page: PropertyPage) -> (median: Int?, count: Int) {
        let vals = page.results.compactMap { $0.assessed_value }.filter { $0 > 0 }
        return (median(vals), vals.count)
    }

    /// Turn an index page into a CompsResult (pure given the page). Real recorded sales → sold comps;
    /// otherwise a clearly-labeled assessed-value AREA estimate; otherwise unavailable (caller gates).
    /// CRITICAL HONESTY: assessed aggregation is NEVER presented as sold comps, and because the read is
    /// keyed by ZIP/area (not a precise radius) it is labeled an "area read", never a fake 3-mile ring.
    static func deriveFromAPI(_ page: PropertyPage, subjectSqft: Double?,
                              subjectLat: Double? = nil, subjectLng: Double? = nil,
                              zip: String? = nil, state: String? = nil,
                              radiusMiles: Double, now: Date = Date()) -> CompsResult {
        let scope = zip?.trimmedNonEmpty.map { "ZIP \($0)" } ?? state?.trimmedNonEmpty.map { "\($0)" } ?? "this area"

        // 2a) Real recorded sales from public records → genuine sold comps (provenance = index).
        let sales = apiSaleComps(from: page, subjectLat: subjectLat, subjectLng: subjectLng, now: now)
        if sales.count >= minAPISales {
            var r = derive(sales, subjectSqft: subjectSqft, radiusMiles: radiusMiles)
            if r.available {
                r.source = .leadDatabase
                r.isAreaRead = true
                let perSqftBit = r.basis == .soldCompsPerSqft && r.perSqft != nil ? " (median $\(Int(r.perSqft!))/sqft)" : ""
                r.note = "ARV from \(sales.count) real recorded public-record sales in \(scope)\(perSqftBit) — an area read of the public-records index, not a precise 3-mile ring."
                return r
            }
        }

        // 2b) No usable recorded sales → labeled assessed-value AREA estimate (NEVER sold comps).
        let est = areaAssessedEstimate(from: page)
        if let med = est.median, est.count >= minAreaAssessed {
            let saleNote = sales.isEmpty ? "no recorded sales" : "\(sales.count) recorded sale(s) — too few to comp"
            return CompsResult(available: true, basis: .assessedAreaEstimate, arv: med, perSqft: nil,
                               comps: [], radiusMiles: radiusMiles,
                               note: "Assessed-value estimate: median of \(est.count) assessed values in \(scope) (\(saleNote)). An area read of the public-records index — a labeled estimate, NOT sold comps.",
                               source: .leadDatabase, isAreaRead: true)
        }

        // Nothing usable in the index for this scope — let the caller fall through to AVM/gate.
        return CompsResult(available: false, basis: .none, arv: nil, perSqft: nil, comps: [],
                           radiusMiles: radiusMiles,
                           note: "No recorded sales or assessed values for \(scope) in the public-records index.",
                           source: .leadDatabase, isAreaRead: true)
    }
}
#endif // circuit-convert

// trimmedNonEmpty mirror (RealEstateAPI defines a private one in its own file; comps needs its own
// so ZIP/state scoping treats blanks/NULL sentinels as absent without reaching across files).
private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.lowercased() == "null" || t == "<null>" { return nil }
        return t
    }
}
