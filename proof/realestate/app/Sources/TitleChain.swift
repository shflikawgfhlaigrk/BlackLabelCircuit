// Black Label Real Estate — RE-22 title / lien & judgment chain (real county records, cited, honest).
//
// DataTree sells a "Title Chain & Lien" report — the recorded history on a parcel: deeds (who owned
// it and when), mortgages/deeds of trust, liens (mechanic's, HOA, tax), judgments/lis-pendens, and
// the releases that clear them. An investor reads that chain to know what encumbers a deal before
// making an offer. This module pulls that history from a county recorder's PUBLIC ArcGIS/feature
// endpoint when the county exposes one, classifies each recorded instrument, and cites the source +
// the date WE fetched it on every row. It NEVER fabricates a lien: when a county's recorder is not
// publicly queryable, or the endpoint returns nothing/an error, the UI shows an explicit honest empty
// ("this county's recorder is not publicly queryable — nothing was invented"), never an invented row.
//
// This reuses the SAME ArcGIS FeatureSet query + parse shape proven for the FEMA flood overlay
// (FloodOverlay.swift): an /query endpoint returning `features[].attributes`. The URL builder,
// classifier, and parser are PURE (no I/O) so the whole path is unit-tested with a canned response;
// only the transport is performed by the caller (TitleChainScreen), and the result is cached on the
// lead so a re-open is instant + free (cache-hit == zero network — same custody contract as skip-trace).
import Foundation

// MARK: - The kind of a recorded instrument (classified from the raw document type; pure).
enum TitleEventKind: String, Codable, Equatable {
    case deed         // ownership transfer — warranty/grant/quitclaim deed
    case mortgage     // mortgage / deed of trust (a lien securing a loan)
    case lien         // mechanic's / HOA / general / abstract-of-judgment lien
    case taxLien      // tax lien / certificate of delinquency
    case judgment     // court judgment / lis pendens / notice of pending action
    case foreclosure  // notice of default / trustee sale / lis pendens (foreclosure)
    case release      // satisfaction / reconveyance / lien release (CLEARS an encumbrance)
    case unknown      // a recorded instrument we won't guess the type of (shown raw, never invented)

    var label: String {
        switch self {
        case .deed: return "Deed / transfer"
        case .mortgage: return "Mortgage / deed of trust"
        case .lien: return "Lien"
        case .taxLien: return "Tax lien"
        case .judgment: return "Judgment / lis pendens"
        case .foreclosure: return "Foreclosure filing"
        case .release: return "Release / satisfaction"
        case .unknown: return "Recorded document"
        }
    }
    /// True for instruments that ENCUMBER title (what an investor is warned about). A release clears,
    /// a deed transfers — neither is an encumbrance.
    var isEncumbrance: Bool {
        switch self {
        case .mortgage, .lien, .taxLien, .judgment, .foreclosure: return true
        case .deed, .release, .unknown: return false
        }
    }
}

// MARK: - One recorded instrument in the chain (only fields the record actually carried; never invented).
struct TitleEvent: Codable, Hashable, Identifiable {
    var docNumber: String = ""       // recorder's document/instrument number
    var kind: TitleEventKind = .unknown
    var docType: String = ""         // the RAW recorded instrument type (shown verbatim for honesty)
    var recordedDate: String = ""    // as the recorder provided it (raw string — never reformatted-away)
    var party: String = ""           // grantor/grantee/creditor as provided ("" when the field is absent)
    var amount: Int? = nil           // recorded amount when present; nil = not provided (never a guess)
    var source: String = ""          // the county recorder / endpoint this row came from
    var fetchedDate: String = ""     // the date WE pulled it (provenance stamp on every row)

    // Identifiable — a stable id from the doc number, or a composite when the recorder omits it.
    var id: String { docNumber.isEmpty ? "\(kind.rawValue)|\(recordedDate)|\(docType)" : docNumber }
    var citation: String {
        let src = source.isEmpty ? "county recorder" : source
        return "Source: \(src) · fetched \(fetchedDate.isEmpty ? "—" : fetchedDate)"
    }
}

// MARK: - The parsed chain + provenance (never claims data it didn't receive).
struct TitleChainSet: Codable, Hashable {
    var events: [TitleEvent] = []
    var county: String = ""
    var source: String = ""
    var fetchedDate: String = ""
    /// TRUE when a `.parcelDeed` pull matched MORE THAN ONE parcel, so no chain can be rendered
    /// honestly (round 16 — see `parse`). The events are dropped, never shown: the sheet renders
    /// `TitleChainEngine.ambiguousJoinNote` instead. Codable-default false, so every cached chain
    /// written before round 16 decodes unchanged.
    var ambiguousJoin: Bool = false
    var isEmpty: Bool { events.isEmpty }
    var encumbrances: [TitleEvent] { events.filter { $0.kind.isEncumbrance } }
    var encumbranceCount: Int { encumbrances.count }
    /// Chain sorted newest-recorded-first when dates are ISO-comparable; otherwise input order is kept.
    var chronological: [TitleEvent] {
        events.enumerated().sorted { a, b in
            if a.element.recordedDate == b.element.recordedDate { return a.offset < b.offset }
            return a.element.recordedDate > b.element.recordedDate
        }.map { $0.element }
    }
}

// MARK: - Field map for a county recorder feature layer (defaults cover the common ArcGIS schema).
struct TitleFieldMap: Equatable {
    var docType = "DOC_TYPE"
    var recordedDate = "REC_DATE"
    var docNumber = "DOC_NUM"
    var party = "GRANTOR"
    var amount = "AMOUNT"
    /// Field names requested from the layer (outFields).
    var outFields: String { [docType, recordedDate, docNumber, party, amount].joined(separator: ",") }
}

enum TitleChainEngine {
    /// Build the ArcGIS attribute query against a county recorder feature layer's /query endpoint for a
    /// given parcel id. Mirrors the FEMA NFHL query shape (which is live-verified) — a `where` predicate
    /// on the parcel field, JSON out, capped record count. `endpoint` is the buyer's/county's PUBLIC
    /// feature-layer URL (…/FeatureServer/0 or …/MapServer/0); we never hardcode a fabricated source.
    static func queryURL(endpoint: String, parcelField: String, parcelId: String,
                         fields: TitleFieldMap = TitleFieldMap(), maxRecords: Int = 200) -> URL? {
        let base = endpoint.hasSuffix("/query") ? endpoint : endpoint + "/query"
        guard var c = URLComponents(string: base) else { return nil }
        // Escape single quotes in the parcel id so the SQL-ish where clause stays well-formed.
        let safeParcel = parcelId.replacingOccurrences(of: "'", with: "''")
        c.queryItems = [
            .init(name: "where", value: "\(parcelField)='\(safeParcel)'"),
            .init(name: "outFields", value: fields.outFields),
            .init(name: "returnGeometry", value: "false"),
            .init(name: "orderByFields", value: "\(fields.recordedDate) DESC"),
            .init(name: "resultRecordCount", value: String(maxRecords)),
            .init(name: "f", value: "json"),
        ]
        return c.url
    }

    /// Classify a raw recorded-instrument type into a chain event kind. Pure keyword mapping over the
    /// county's own DOC_TYPE string; anything unrecognized stays `.unknown` and is shown raw (§5.1 —
    /// we never upgrade an unknown instrument into a lien we can't prove).
    static func classify(_ rawType: String) -> TitleEventKind {
        let t = rawType.uppercased()
        // Releases first — "LIEN RELEASE" / "RELEASE OF LIEN" must clear, not read as a lien.
        if t.contains("RELEASE") || t.contains("SATISF") || t.contains("RECONVEY") || t.contains("DISCHARGE") { return .release }
        if t.contains("TAX LIEN") || t.contains("TAX CERTIFICATE") || t.contains("DELINQUEN") { return .taxLien }
        // Foreclosure — NC Register-of-Deeds/foreclosure feeds phrase the sale stages this way
        // ("Notice of Sale", "Upset Bid", "Substitute Trustee") in addition to the generic terms.
        if t.contains("NOTICE OF DEFAULT") || t.contains("TRUSTEE") || t.contains("FORECLOS")
            || t.contains("NOTICE OF SALE") || t.contains("UPSET BID") { return .foreclosure }
        if t.contains("LIS PENDENS") || t.contains("JUDG") || t.contains("ABSTRACT OF JUDG") { return .judgment }
        if t.contains("LIEN") { return .lien }
        if t.contains("MORTGAGE") || t.contains("DEED OF TRUST") || t.contains("DEED OF TR") { return .mortgage }
        if t.contains("DEED") || t.contains("CONVEYANCE") || t.contains("GRANT") { return .deed }
        return .unknown
    }

    /// ArcGIS returns dates as epoch MILLISECONDS (a number that can be negative for pre-1970 deeds).
    /// Format to a stable UTC `yyyy-MM-dd` string; a non-numeric value (or an already-formatted string)
    /// passes through trimmed, and anything else yields "" (never a fabricated date). Pure + locale-fixed.
    static func recordedDateString(_ raw: Any?) -> String {
        if let n = raw as? NSNumber {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            df.dateFormat = "yyyy-MM-dd"
            return df.string(from: Date(timeIntervalSince1970: n.doubleValue / 1000.0))
        }
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            // Some counties (Buncombe) record the deed date as an 8-digit YYYYMMDD STRING rather than
            // an epoch-ms date — normalize it to the same yyyy-MM-dd form. Only an exactly-8-digit
            // numeric string is reinterpreted; every other string (already-formatted dates, book/page
            // fragments) passes through verbatim, so nothing is ever reformatted-away or invented.
            if t.count == 8, t.allSatisfy({ $0.isNumber }) {
                return "\(t.prefix(4))-\(t.dropFirst(4).prefix(2))-\(t.suffix(2))"
            }
            return t
        }
        return ""
    }

    /// Normalize a PACKED YYYYMMDD value — as an integer OR a string — to a stable `yyyy-MM-dd`.
    /// Some counties (Alamance's Sales_History AMDTSL) record the sale date as an 8-digit integer
    /// like 20250722, NOT epoch milliseconds — feeding that to `recordedDateString` would misread it
    /// as ~1970 (20250722 ms ≈ Jan 1 1970). This reads it as a calendar date, but ONLY when the value
    /// is a sane 8-digit YYYYMMDD (year 1901–2999, month 01–12, day 01–31). Anything else — a 0/blank
    /// sentinel, a partial value, an out-of-range date — yields "" so the row is DROPPED, never a
    /// fabricated date. Pure + locale-free.
    static func packedYMDString(_ raw: Any?) -> String {
        var s = ""
        if let n = raw as? NSNumber { s = n.stringValue }
        else if let str = raw as? String { s = str.trimmingCharacters(in: .whitespaces) }
        guard s.count == 8, s.allSatisfy({ $0.isNumber }),
              let y = Int(s.prefix(4)), y > 1900, y < 3000,
              let m = Int(s.dropFirst(4).prefix(2)), m >= 1, m <= 12,
              let d = Int(s.suffix(2)), d >= 1, d <= 31 else { return "" }
        return "\(s.prefix(4))-\(s.dropFirst(4).prefix(2))-\(s.suffix(2))"
    }

    /// Parse an Oracle-style "DD-MON-YY" recorded date (Onslow's Tax_Data SALEDATE, e.g. "31-OCT-95") to
    /// (year, month, day) with an EXPLICIT, stable century pivot — deliberately NOT DateFormatter's "yy",
    /// whose pivot floats with the current date (non-deterministic; would reclassify the same deed year to
    /// year). YY 00–49 → 2000–2049, 50–99 → 1950–1999 (the recorded-deed era window). A blank, a bad month
    /// token, a non-2-digit year, or an out-of-range day yields nil → the row is DROPPED, never a fabricated
    /// date (§5.1). Pure + locale-free.
    static func oracleDMY(_ raw: Any?) -> (year: Int, month: Int, day: Int)? {
        let s = "\(raw ?? "")".trimmingCharacters(in: .whitespaces).uppercased()
        let parts = s.split(separator: "-").map(String.init)
        let months = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6,
                      "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]
        guard parts.count == 3,
              let d = Int(parts[0]), d >= 1, d <= 31,
              let m = months[parts[1]],
              parts[2].count == 2, let yy = Int(parts[2]) else { return nil }
        return (yy <= 49 ? 2000 + yy : 1900 + yy, m, d)
    }

    /// The `oracleDMY` date normalized to the stable `yyyy-MM-dd` form; an unparseable value → "" (dropped,
    /// never fabricated). Lets a county whose only conveyance date is an Oracle "DD-MON-YY" string sort
    /// chronologically instead of lexically (where "31-OCT-95" would falsely outrank "2026-02-27").
    static func oracleDMYString(_ raw: Any?) -> String {
        guard let (y, m, d) = oracleDMY(raw) else { return "" }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Parse an ArcGIS FeatureSet JSON into a title chain. Tolerant + HONEST (mirrors FloodOverlay):
    /// a non-JSON body, an ArcGIS error object, or an empty feature list yields an EMPTY chain — never
    /// a fabricated row. Every parsed row is stamped with the source + fetch date.
    static func parse(_ data: Data, county: String, source: String, fetchedDate: String,
                      fields: TitleFieldMap = TitleFieldMap()) -> TitleChainSet {
        var set = TitleChainSet(county: county, source: source, fetchedDate: fetchedDate)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return set }
        if root["error"] != nil { return set }              // ArcGIS surfaces query problems here — render nothing
        guard let features = root["features"] as? [[String: Any]] else { return set }
        for f in features {
            guard let attrs = f["attributes"] as? [String: Any] else { continue }
            func str(_ k: String) -> String {
                if let s = attrs[k] as? String { return s.trimmingCharacters(in: .whitespaces) }
                if let n = attrs[k] as? NSNumber { return n.stringValue }
                return ""
            }
            let rawType = str(fields.docType)
            var e = TitleEvent()
            e.docType = rawType
            e.kind = classify(rawType)
            e.recordedDate = str(fields.recordedDate)
            e.docNumber = str(fields.docNumber)
            e.party = str(fields.party)
            if let n = attrs[fields.amount] as? NSNumber, n.doubleValue > 0 { e.amount = n.intValue }
            e.source = source
            e.fetchedDate = fetchedDate
            // A row with no type AND no doc number AND no date carries no real content — skip it rather
            // than render an empty ghost row.
            if e.docType.isEmpty && e.docNumber.isEmpty && e.recordedDate.isEmpty { continue }
            set.events.append(e)
        }
        return set
    }

    /// Provenance line under the chain when it returned rows.
    static func sourceLine(county: String, count: Int, dateLabel: String) -> String {
        "Source: \(county.isEmpty ? "county recorder" : county) recorder · \(count) recorded document\(count == 1 ? "" : "s") · fetched \(dateLabel)"
    }
    /// Honest empty — the county recorder has no public endpoint configured for this parcel's county.
    static let unqueryableNote = "This county's recorder is not publicly queryable — nothing was invented. Connect the county's public recorder endpoint in Settings, or pull the chain from your own title provider."
    /// Honest empty — the endpoint responded but returned no recorded documents (or timed out).
    static let noRecordsNote = "No recorded liens, judgments, or transfers were returned for this parcel. Nothing was invented; the recorder endpoint may not index this parcel, or the public service timed out — retry to re-query."
    /// Honest FAILURE — the recorder was never reached (offline / DNS / transport error). A distinct
    /// state from `noRecordsNote`: nothing was queried, so this must never read as a clean-title
    /// signal on a due-diligence surface.
    static let unreachableNote = "Couldn't reach the county recorder — nothing was queried, so this says NOTHING about liens or transfers on this parcel. Check your connection and retry to re-query."
    /// Shown when a `.parcelDeed` pull matched MORE THAN ONE parcel (round 16). This is a DIFFERENT
    /// state from `noRecordsNote`: the recorder answered and the records are real, but the county's
    /// parcel id does not identify a single parcel (a building-level PIN shared by its condo units),
    /// so no chain can be attributed to THIS parcel without fabricating one. Says so plainly rather
    /// than reading as "no records", which would be a lie about the county's data.
    static let ambiguousJoinNote = "This county's parcel id matches more than one parcel (commonly a building-level PIN shared by its units), so the recorded deeds returned belong to several parcels — not to this one. A title chain is gated rather than guessed: nothing was invented. Use the county's unit-level id (e.g. its REID) if you have it, or pull the chain from your own title provider."
}

// MARK: - On-device cache of a pulled chain, keyed to the parcel (cache-hit == ZERO network).
struct TitleChainCacheEntry: Codable, Hashable {
    var signature: String
    var events: [TitleEvent] = []
    var county: String = ""
    var source: String = ""
    var fetchedDate: String = ""
    var at: Date = Date()
    func chainSet() -> TitleChainSet {
        TitleChainSet(events: events, county: county, source: source, fetchedDate: fetchedDate)
    }
}

extension TitleChainEngine {
    /// The cache key for a parcel — case/whitespace-insensitive on parcel id + state so a trivial edit
    /// still hits the cache.
    static func signature(parcel: String, state: String) -> String {
        func norm(_ s: String) -> String {
            s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "-" }).joined()
        }
        return "\(norm(parcel))|\(norm(state))"
    }
    /// Reconstruct a chain from the lead's cache WITHOUT any network, IFF it was pulled for THIS parcel.
    /// Returns nil when there's no cache or the parcel changed (forcing a fresh pull). The cache-hit-
    /// means-no-network contract, identical to the skip-trace waterfall.
    static func cached(_ entry: TitleChainCacheEntry?, parcel: String, state: String) -> TitleChainSet? {
        guard let e = entry, e.signature == signature(parcel: parcel, state: state) else { return nil }
        var set = e.chainSet()
        // ROUND-16 STALE-CACHE QUARANTINE. The ambiguous-join gate lives in `parse()`, which only runs
        // on a LIVE pull — so a chain cached BEFORE round 16 still holds the fabricated multi-parcel
        // events, and the sheet renders cached chains with ZERO network. Without this, a buyer who
        // pulled a Durham condo PIN before the fix keeps seeing the fabricated 34-deed chain forever,
        // and the fix would look shipped while the lie stayed on screen. Re-apply the SAME shape rule
        // on the way out of the cache: a `.parcelDeed` county can cache at most ONE deed event.
        if let src = TitleRecorderRegistry.source(county: e.county, state: state),
           src.shape == .parcelDeed, set.events.count > 1 {
            set.events = []
            set.ambiguousJoin = true
        }
        return set
    }
    /// Build the record to persist on the lead from a freshly pulled (non-cache) chain.
    static func cacheEntry(_ set: TitleChainSet, parcel: String, state: String, at: Date = Date()) -> TitleChainCacheEntry {
        TitleChainCacheEntry(signature: signature(parcel: parcel, state: state),
                             events: set.events, county: set.county, source: set.source,
                             fetchedDate: set.fetchedDate, at: at)
    }
}

// MARK: - Built-in county recorder sources (LIVE-VERIFIED public endpoints; wired 2026-07-14).
//
// Unlike the buyer-configured single endpoint (RecorderConfigSheet), these are county
// recorder / Register-of-Deeds PUBLIC feature layers whose fields we verified by curl against the
// live server before wiring (fixtures in Tests/fixtures/recorder/). Each source names its OWN field
// vocabulary and its OWN row shape; a row is classified from the county's real values and an
// unrecognized instrument stays honest (§5.1 — never upgraded into a lien we can't prove). Every row
// is stamped with the source + the date WE fetched it. A county that proves un-queryable is simply
// absent from this registry (the honest empty state renders), never faked.
//
//   guilford    Foreclosure/ForeclosuresPublic  — recorded foreclosure filings (FLAG_TYPE/FLAG_STATUS)
//   mecklenburg TaxParcelSales                   — recorded property sales/deeds (grantor→grantee, book/page)
//   durham      PublicServices/Property Parcels  — the parcel's recorded deed (DEED_BOOK/PAGE, ROD doc id)
//   wake        Property/Parcels                 — the parcel's recorded deed (DEED_BOOK/PAGE/DATE, OWNER)
//   orange      WebParcelService Parcels         — the parcel's recorded deed (combined DEEDREF book/page,
//                                                   DATESOLD epoch-ms, OWNER1) — wired 2026-07-14 (round 3)
//   buncombe    property_bc_dis Property          — the parcel's recorded deed (DeedBook/Page, DeedDate
//                                                   YYYYMMDD string, owner) + recorded SalePrice — round 3
//   gaston      Parcels/GastonCountyParcels      — the parcel's recorded deed (DEED_BOOK/PAGE, DEEDTYPE,
//                                                   esri-date SALEDATE, CURR_NAME1) + recorded SALESAMT — round 4
//   cumberland  Tax/Parcels                      — the parcel's recorded deed (DEED_BOOK/PAGE, "yyyy-MM-dd"
//                                                   string DEED_DATE, OWNER) + recorded PKG_SALE_PRICE — round 4
//   rowan       Public/RowanTaxParcels           — the parcel's recorded deed (DEEDBOOK/PAGE, esri-date
//                                                   DATESOLD, OWNNAME) + recorded SALE_AMT — round 5
//   iredell     Data/TaxSQL_Parcels              — the parcel's recorded deed (DWBook/DWPage, Name) +
//                                                   recorded Sales_Price (deed date = Sale_Date; the layer's
//                                                   DeedDate is a data-refresh stamp, not the sale) — round 5
//   randolph    ParcelBasemap/5                  — the parcel's recorded deed (DOCUMENT_BOOK/PAGE, ACCT_NAME);
//                                                   NO recorded sale price/date → deed row carries book/page
//                                                   only (never a fabricated amount) — round 6
//   alamance    Tax/AlamanceParcels              — restored populated authoritative layer; deed
//                                                   AMDBOK/AMDPGE + OWNAM1 + AMSLAM + packed AMDTSL
//   pitt        PittOpenData/CadastralPitt       — the parcel's recorded deed (DeedBook/DeedPage, OwnerName) +
//                                                   recorded SalesPrice + esri-date DocumentDate (== the
//                                                   county's SalesMonthYear, a real conveyance date) — round 6
//
// Round-3 probe (2026-07-14) also live-checked New Hanover County, NC: its public GIS server exposes only
// parcel GEOMETRY + an owner/address layer (NHC_PropertiesAndBuildings) with NO recorded deed/date/sale
// column — so it has no public recorded-instrument feed and is HONESTLY ABSENT from this registry (like
// Forsyth). Nothing is faked to fill the gap; the honest empty state renders for New Hanover leads.
//
// Round-4 probe (2026-07-14) added Gaston + Cumberland (both GO — full recorded deed + sale, above) and
// re-checked three more candidates that are HONESTLY OMITTED (negative tests pin each):
//   • Union County, NC — Property_Tax_Live/Parcels + Assessed_Value expose parcel GEOMETRY, land-use and
//     assessed values ONLY (parcel_number/Address/market_*), with NO owner, deed, book/page, or sale
//     column on any public map layer. No recorded-instrument feed → absent, not fabricated.
//   • Forsyth County, NC — Public/Tax_Parcel (geo.forsythco.com) exposes assessment + owner-conveyance
//     name but NO DEED_BOOK/PAGE/DATE or sale column. Re-confirmed round 4: no recorded-instrument feed.
//   • New Hanover County, NC — re-confirmed round 4 (still owner/geometry only, per the round-3 note).
//
// Round-5 probe (2026-07-14) added Rowan + Iredell (both GO — full recorded deed + sale, above) and
// re-checked three more candidates that are HONESTLY OMITTED (negative tests pin each):
//   • New Hanover County, NC — re-confirmed AGAIN round 5: both Layers/IASTAX/0 and Thematic/TaxPublic
//     (Parcels) expose only geometry + PIN/PID/MAPID/ACRES — NO owner, deed, book/page, or sale column.
//     No recorded-instrument feed → still absent, not fabricated.
//   • Catawba County, NC — no publicly-queryable ArcGIS REST service was found: gis.catawbacountync.gov
//     serves only an ArcGIS Server manager HTML page (no open /rest/services), and no hosted parcel
//     FeatureServer with deed/sale fields was discoverable. Omitted this round, not fabricated.
//   • Cabarrus County, NC — the county GIS moved to location.cabarruscounty.us, which exposes no open
//     ArcGIS REST /services directory (no queryable parcel/recorder layer found). Omitted, not fabricated.
//
// Round-6 probe (2026-07-14) added Randolph + Alamance + Pitt (all GO — full recorded deed via the parcel
// layer, above; Randolph priced/dated-less but with real deed book/page) and OMITS two more (negative tests):
//   • Johnston County, NC — has NO open ArcGIS REST parcel/recorder /query feed. Its public GIS is a MapClick/
//     Spatialest viewer (mapclick8.johnstonnc.com, no /arcgis/rest), and gis.johnstonnc.com redirects to a
//     dead Google-Sites login. No queryable deed/owner/sale layer → honestly ABSENT, not fabricated.
//   • Onslow County, NC — a parcel layer WITH a full recorded-deed schema DOES exist (gismaps.onslowcountync.gov
//     …/WEB_PUBLICATIONS/County_Map_Layers/MapServer/0: OWNER1 + SALEBOOK/SALEPAGE + SALEDATE + SALEPRICE +
//     FINALFULLLANDVALUE/FINALFULLBUILDINGVALUE). BUT the host's TLS certificate is EXPIRED (Let's Encrypt
//     *.onslowcountync.gov, notAfter 2026-07-14 09:28:27 GMT; probed 09:46 GMT, ssl_verify_result=10), so the
//     shipped app's cert-validating URLSession CANNOT connect — wiring it would be fabricated coverage that
//     always gates. Honestly OMITTED this round; revisit when the cert renews (schema is recorder-ready).
//   • New Hanover County, NC — re-confirmed AGAIN round 6: still no exposed public recorded-instrument feed
//     (gis.nhcgov.com/arcgis/rest 404; no hosted parcel-with-deed/sale layer found). Still absent, not faked.
//
// Round-7 re-probe (2026-07-14) revisited Onslow (per round-6's own "revisit on cert renewal") and generalized
// the sales-roll shape:
//   • Onslow County, NC — cert STILL expired/invalid: gismaps.onslowcountync.gov returns HTTP 000
//     ssl_verify_result=10 (openssl: notAfter=Jul 14 09:28:27 2026 GMT — the Let's Encrypt cert lapsed TODAY
//     and has NOT renewed). The app's cert-validating URLSession still cannot connect → still honestly ABSENT
//     (negative test stands), NOT wired: no fabricated coverage. sources.count stays 13. Re-probe next round.
//   • Alamance Tax/Sales_History — the dedicated MULTI-ROW sales roll round 6 declined for the TITLE chain
//     (AS400-coded grantor/grantee) IS wired for COMPS this round (TitleRecorderRegistry.salesRollSources):
//     it publishes a real recorded AMSLAM + packed-YYYYMMDD AMDTSL per sale, fed through
//     CompsEngine.compsFromTitleChain. Live-verified PIN 152135 → 2 priced sales + 1 $0 row that drops.
//
// Round-9 probe (2026-07-14) added Craven + Moore (both GO — full recorded deed via the parcel layer,
// above) and OMITS three more (negative tests pin each), plus a parcel-resolution lesson on Moore:
//   • Craven County, NC — JustParcels/0 (gis.cravencountync.gov) carries the parcel's recorded deed
//     (PABOOK/PAPAGE + owner PANAME) AND a real recorded SALE_PRICE paired with an esri-date SALE_DATE
//     (epoch ms). Round-5 date discipline APPLIED: SALE_DATE 2026-06-10 EQUALS the county's own recording
//     stamp PRECYR/PRECMN/PRECDY (2026/6/10) to the day → it IS the real conveyance date, not a refresh
//     stamp. PID is unique per parcel (1 row). Live-verified 2026-07-14: PID '8-205-4 -021' → deed
//     3883/1511, SALE_DATE 2026-06-10, recorded sale $356,500 (CARTLAND, MARY C).
//   • Moore County, NC — Tax/Tax_Parcel/0 (gis.moorecountync.gov/server) carries DEED_BOOK/DEED_PAGE +
//     owner NAME + an esri-date TRANSDATE (== VALID_SALESDT to the day: a REAL conveyance date, NOT a
//     refresh stamp). PARCEL-RESOLUTION LESSON: the layer's PIN is NOT unique — one PIN (857318416504)
//     spans 47 distinct PARID parcels, so joining on PIN would fabricate a 47-deed "title chain" for one
//     parcel. PARID is the unique key (1 row) → Moore joins on PARID ONLY (parcelLookupField=PARID). No
//     clean recorded PRICE exists (STAMP_VAL is excise-tax stamps, NOT a sale price — deliberately not a
//     price field, §5.1, like Orange/Moore), so the deed row carries book/page + owner + real date and
//     honestly NO amount. Live-verified 2026-07-14: PARID 00041503172 → deed 6571/355, TRANSDATE
//     2026-06-25 (WELCH, LINDA M).
//   • Wayne County, NC — gis.waynegov.com refuses the TLS handshake ("Connection reset by peer",
//     ssl_verify_result=1, HTTP 000) on both /arcgis/rest and /server/rest; no reachable public REST
//     service. Like Onslow's expired-cert round, the app's cert-validating URLSession cannot connect →
//     honestly ABSENT (negative test), NOT wired: wiring it would be fabricated coverage that always gates.
//   • Brunswick County, NC — no public ArcGIS REST /services: gis.brunswickcountync.gov 404s and
//     gis.brunsco.net 302-redirects to an ArcGIS Experience app (a viewer, not a queryable feature
//     service). No queryable recorded-deed layer found → honestly ABSENT, not fabricated.
//   • Henderson County, NC — the county's ArcGIS Online org (services3.arcgis.com/hendersoncounty)
//     exposes an EMPTY public services list, and gis.hendersoncountync.gov does not resolve. No public
//     recorded-instrument feed → honestly ABSENT, not fabricated.
//   • Catawba + Cabarrus, NC — re-checked AGAIN round 9 (dispatch asked): still no open ArcGIS REST
//     parcel/recorder /services (gis.catawbacountync.gov 404, location.cabarruscounty.us 404). Still
//     absent, not fabricated.
// Round-9 sales-roll scout (2026-07-14): looked for one more dedicated MULTI-ROW sales roll (a Wake or
// Durham sales-history layer) for salesRollSources. None found as a clean single-endpoint per-parcel
// multi-sale feed: Wake Property/Parcels is a single layer with no related sales table; Durham
// OpenDataServices publishes only Finance_Assessments; Moore's Tax/Valid_Sales_By_Year is split into 14
// per-year layers carrying ONE most-recent sale per parcel (not an event-level roll); Craven JustParcels
// is one recorded deed per parcel. salesRollSources stays 1 (Alamance) — nothing fabricated to fill it.
//
// Every source's joinFields[0] is the field carrying the SAME value form ParcelLookup resolves for the
// county (parcelLookupField), so the built-in pull binds on the first predicate:
//   guilford PIN (ParcelLookup GISDV/Parcels.PIN) · durham PIN · wake PIN_NUM · mecklenburg parcelid
//   (ParcelLookup TaxParcel_Camaownershipvalues.pid — different column NAME, same value form; the
//    join `parcelid=<pid>` was live-verified: pid 00101102 returns 4 recorded sales, 2026-07-14) ·
//   rowan PIN (ParcelLookup RowanTaxParcels.PIN) · iredell PIN (ParcelLookup TaxSQL_Parcels.PIN).

enum TitleRecorderShape: String, Codable, Equatable {
    case foreclosureFiling   // one row = one recorded foreclosure filing (an encumbrance)
    case saleRecords         // one row = one recorded sale / deed transfer
    case parcelDeed          // one parcel row carries its most-recent recorded deed
}

struct TitleRecorderSource: Equatable {
    var county: String            // normalized county key ("guilford")
    var displayName: String       // "Guilford County, NC"
    var state: String             // "NC"
    var shape: TitleRecorderShape
    var endpoint: String          // full, LIVE-VERIFIED …/query endpoint
    var joinFields: [String]      // parcel-id fields the layer exposes (OR-matched, so a resolved id joins).
                                  // joinFields[0] is the field carrying the SAME value form ParcelLookup
                                  // resolves for this county (`parcelLookupField`) — so the built-in pull
                                  // binds on the FIRST predicate (live-verified by curl, fixtures below).
    var outFields: [String]       // the exact fields this shape's parser reads
    var orderBy: String           // server-side sort (newest recorded first when the layer supports it)
    // The ParcelLookup registry FIELD whose resolved value this recorder joins on. It names the form
    // (ParcelRegistry.builtIn[county].parcelField) so the two registries can't silently drift — a test
    // pins `parcelLookupField == ParcelRegistry.builtIn[county].parcelField` for every county in both.
    // The recorder's own field name for that value may differ (Mecklenburg: ParcelLookup `pid` → the
    // recorder's `parcelid`); the VALUE form is what binds, proven by the live-curl fixtures.
    var parcelLookupField: String
    var sourceLabel: String       // provenance shown on every row

    // Per-source field vocabulary for the `.parcelDeed` shape. Defaults are the Durham/Wake schema
    // (DEED_BOOK/DEED_PAGE/DEED_DATE + PROPERTY_OWNER→OWNER + PKG_SALE_PRICE→TOTSALPRICE), so the
    // counties wired before this expansion are byte-for-byte unchanged. Counties whose parcel layer
    // names the recorded-deed columns differently override these — Orange carries a COMBINED book/page
    // in `DEEDREF` and its sale date in `DATESOLD`; Buncombe names them `DeedBook`/`DeedPage`/`DeedDate`
    // and carries a real recorded `SalePrice`. A row is never fabricated — a field the layer doesn't
    // publish simply stays empty/nil.
    var deedBookField: String = "DEED_BOOK"
    var deedPageField: String = "DEED_PAGE"
    var deedRefField: String? = nil            // a COMBINED "book/page" column (Orange DEEDREF), used when set
    var deedDateField: String = "DEED_DATE"
    var deedRodDocField: String = "MAP_ROD_DOC_ID"
    var deedOwnerFields: [String] = ["PROPERTY_OWNER", "OWNER"]  // first non-empty wins
    var deedPriceFields: [String] = ["PKG_SALE_PRICE", "TOTSALPRICE"]  // recorded price ONLY; never derived
    var deedDateIsOracleDMY: Bool = false      // true → deedDateField is an Oracle "DD-MON-YY" string (Onslow SALEDATE)
    var deedPackedYMDDate: Bool = false        // true → deedDateField is packed YYYYMMDD (Alamance AMDTSL)

    // Per-source field vocabulary for the `.saleRecords` shape (one row = one recorded sale/deed transfer,
    // and a parcel can carry MANY — a dedicated multi-row sales roll). Defaults are Mecklenburg's
    // TaxParcelSales schema, so the counties wired before this generalization stay byte-for-byte unchanged.
    // A county whose sales roll names the columns differently overrides these — Alamance's Tax/Sales_History
    // carries the sale amount in AMSLAM, a PACKED-YYYYMMDD date in AMDTSL (integer 20250722, NOT epoch ms),
    // the deed book/page split across AMDBOK/AMDPGE, the coded instrument type in AMSALI, and the grantee
    // (buyer) in OWNAM1. A field the roll doesn't publish simply stays empty; a row is never fabricated.
    var saleDescField: String = "deeddescription"      // raw recorded instrument type (shown verbatim)
    var saleRefField: String = "legalreference"        // a single book/page or legal-reference column
    var saleBookField: String? = nil                   // when the roll splits book/page (Alamance AMDBOK)…
    var salePageField: String? = nil                   // …+ AMDPGE — combined into the doc number
    var saleGrantorField: String = "grantor"
    var saleGranteeField: String = "grantee"
    var saleDateField: String = "saledate"
    var salePriceField: String = "saleprice"
    var salePackedYMDDate: Bool = false                // true → saleDateField is a packed YYYYMMDD integer

    /// Build the ArcGIS attribute query for this source. The parcel id is matched against EACH of the
    /// layer's join fields (OR) so a resolved id — whether it's the short parcel id, the PIN, or the
    /// REID — still joins. Single quotes are SQL-escaped so the where clause stays well-formed.
    func queryURL(parcelId: String, maxRecords: Int = 200) -> URL? {
        guard var c = URLComponents(string: endpoint) else { return nil }
        let safe = parcelId.replacingOccurrences(of: "'", with: "''")
        let clause = joinFields.map { "\($0)='\(safe)'" }.joined(separator: " OR ")
        c.queryItems = [
            .init(name: "where", value: joinFields.count > 1 ? "(\(clause))" : clause),
            .init(name: "outFields", value: outFields.joined(separator: ",")),
            .init(name: "returnGeometry", value: "false"),
            .init(name: "orderByFields", value: orderBy),
            .init(name: "resultRecordCount", value: String(maxRecords)),
            .init(name: "f", value: "json"),
        ]
        return c.url
    }

    /// Parse an ArcGIS FeatureSet from THIS source into a title chain, dispatching on the row shape.
    /// Tolerant + HONEST (mirrors TitleChainEngine.parse): non-JSON, an ArcGIS error envelope, or an
    /// empty feature list all yield an empty chain — never a fabricated row.
    func parse(_ data: Data, county leadCounty: String, fetchedDate: String) -> TitleChainSet {
        let countyName = leadCounty.isEmpty ? displayName : leadCounty
        var set = TitleChainSet(county: countyName, source: sourceLabel, fetchedDate: fetchedDate)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return set }
        if root["error"] != nil { return set }
        guard let features = root["features"] as? [[String: Any]] else { return set }
        // A recorder layer can return BYTE-IDENTICAL duplicate rows for one parcel — Cleveland's
        // Vacant_ImprovedLot_Sales republishes the same recorded deed once per tax-year snapshot
        // (live-verified round 11: Parcel_Number 60930 → 8 rows, but only 3 distinct recorded sales;
        // the 2022 deed 1862/1400 $399,000 repeats 6×). Rendering an identical deed N times would
        // FABRICATE a multiplicity of sales that the register never recorded (§5.1) — and inflate a
        // comps median. So an event whose ENTIRE displayed identity (kind, doc type, recorded date,
        // doc number, party, amount) exactly matches one already parsed is dropped as a re-print, not
        // a second sale. This is a strict exact-match collapse: two genuinely distinct recordings
        // always differ in at least one displayed field, so no real event is ever lost — verified
        // to be a no-op on every county fixture wired before round 11 (each is already all-distinct).
        var seen = Set<String>()
        for f in features {
            guard let attrs = f["attributes"] as? [String: Any] else { continue }
            let event: TitleEvent?
            switch shape {
            case .foreclosureFiling: event = TitleRecorderSource.foreclosureEvent(attrs, source: sourceLabel, fetchedDate: fetchedDate)
            case .saleRecords:       event = saleRecordEvent(attrs, fetchedDate: fetchedDate)
            case .parcelDeed:        event = parcelDeedEvent(attrs, fetchedDate: fetchedDate)
            }
            guard let e = event else { continue }
            let identity = "\(e.kind.rawValue)|\(e.docType)|\(e.recordedDate)|\(e.docNumber)|\(e.party)|\(e.amount.map(String.init) ?? "")"
            if seen.insert(identity).inserted { set.events.append(e) }
        }
        // ── ROUND-16 AMBIGUOUS-JOIN GATE (the Moore fabrication, caught at RUNTIME) ──────────────
        // A `.parcelDeed` layer's own contract is "ONE parcel row carries its most-recent recorded
        // deed" — so a parcel can contribute AT MOST ONE deed event. If a pull yields two or more
        // DISTINCT events (identical rows already collapsed above), the join predicate necessarily
        // matched MULTIPLE PARCELS, and rendering them in sequence would fabricate a "title chain"
        // of conveyances the register never recorded for this parcel (§5.1).
        //
        // This is NOT hypothetical — it shipped. Round-16 enumeration (docs/COUNTY-KEY-AUDIT.md)
        // PROVED it against the live counties: Durham PIN 0821898044 returns 34 rows carrying 34
        // DISTINCT REIDs (REID is the layer's proven-unique key: 133,231 distinct == 133,231 rows)
        // and 34 distinct OBJECTID_1 — i.e. 34 separate condo parcels sharing one building-level
        // PIN, each with its own owner/deed/price ($725,000 KOCH · $459,000 JDS HUANG LLC · …).
        // The app OR-joins `PIN='X' OR REID='X'`, so it collected all 34 and drew a 34-deed chain
        // for ONE unit. `where REID='104855'` returns exactly 1 row — the honest join.
        //
        // The gate is per-PARCEL, not per-county (the round-15 "gate the FEATURE, not the county"
        // rule): a Durham parcel whose PIN is unique still renders its real chain; only the parcels
        // whose key genuinely collides go honest-empty. Counties whose collisions are all
        // BYTE-IDENTICAL (Haywood 935/935, Cumberland 867/867, Surry 59/59, Pender 174/174,
        // Burke 91/91) collapse to 1 event above and are UNAFFECTED by this gate.
        //
        // Deliberately scoped to `.parcelDeed`: `.saleRecords` (Mecklenburg/Alamance/Cleveland) and
        // `.foreclosureFiling` (Guilford) are event-level rolls where MANY rows per parcel is the
        // layer's correct semantic — a real recorded history, not a collision.
        if shape == .parcelDeed && set.events.count > 1 {
            set.events = []
            set.ambiguousJoin = true
        }
        return set
    }

    // MARK: shape adapters (pure; unit-tested against the captured live fixtures)

    private static func str(_ attrs: [String: Any], _ k: String) -> String {
        if let s = attrs[k] as? String { return s.trimmingCharacters(in: .whitespaces) }
        if let n = attrs[k] as? NSNumber { return n.stringValue }
        return ""
    }
    private static func posMoney(_ attrs: [String: Any], _ k: String) -> Int? {
        if let n = attrs[k] as? NSNumber, n.doubleValue > 0 { return n.intValue }
        return nil
    }

    /// Guilford — the Foreclosure/ForeclosuresPublic layer. EVERY row is a recorded foreclosure filing,
    /// so the kind is `.foreclosure` (the layer's own semantic; never a lien we can't prove). The raw
    /// FLAG_TYPE + FLAG_STATUS are preserved verbatim as the shown doc type. The recorded date is the
    /// auction date when set, else the underlying deed date; the doc number is the Deed book/page.
    static func foreclosureEvent(_ attrs: [String: Any], source: String, fetchedDate: String) -> TitleEvent? {
        let flagType = str(attrs, "FLAG_TYPE"), flagStatus = str(attrs, "FLAG_STATUS")
        let deed = str(attrs, "Deed")
        let auction = TitleChainEngine.recordedDateString(attrs["AuctionDate"])
        let deedDate = TitleChainEngine.recordedDateString(attrs["DEED_DATE"])
        let rawType = [flagType, flagStatus].filter { !$0.isEmpty }.joined(separator: " · ")
        if rawType.isEmpty && deed.isEmpty && auction.isEmpty && deedDate.isEmpty { return nil }
        var e = TitleEvent()
        e.docType = rawType.isEmpty ? "Foreclosure filing" : "Foreclosure filing — \(rawType)"
        // The kind is `.foreclosure` for every row: this is the county's dedicated foreclosure feed
        // (a documented, source-scoped fact), and a foreclosure filing is never an invented lien. The
        // status vocabulary itself classifies to `.foreclosure` too — asserted in the engine tests.
        e.kind = .foreclosure
        e.recordedDate = auction.isEmpty ? deedDate : auction
        e.docNumber = deed
        e.party = str(attrs, "Owner")
        e.source = source
        e.fetchedDate = fetchedDate
        return e
    }

    /// The `.saleRecords` shape — a recorded-sales roll where EACH row is one recorded sale (a deed
    /// transfer), and a parcel can carry MANY (Mecklenburg's TaxParcelSales; Alamance's multi-row
    /// Tax/Sales_History). Fields are read from this source's OWN `sale*` vocabulary (defaulting to the
    /// Mecklenburg schema, so Mecklenburg is byte-for-byte unchanged). The kind is classified from the
    /// county's own instrument description; when blank/unrecognized it stays `.deed` because the row
    /// comes from a recorded-SALES layer (a transfer, never an encumbrance — this fallback can never
    /// manufacture a lien). Party = grantor → grantee (or the roll's buyer/owner column when that's all
    /// it publishes); amount = sale price ONLY when > 0; doc number = a single legal-reference column OR
    /// a combined book/page. The date is epoch-ms by default, or a packed YYYYMMDD integer when the
    /// source sets `salePackedYMDDate` — a 0/blank/garbage date yields "" so the row's date is honest.
    func saleRecordEvent(_ attrs: [String: Any], fetchedDate: String) -> TitleEvent? {
        let desc = TitleRecorderSource.str(attrs, saleDescField)
        let legal = TitleRecorderSource.str(attrs, saleRefField)
        let book = saleBookField.map { TitleRecorderSource.str(attrs, $0) } ?? ""
        let page = salePageField.map { TitleRecorderSource.str(attrs, $0) } ?? ""
        let bookPage = (book.isEmpty && page.isEmpty) ? "" : "\(book)-\(page)"
        let docNum = !legal.isEmpty ? legal : bookPage
        let date = salePackedYMDDate ? TitleChainEngine.packedYMDString(attrs[saleDateField])
                                     : TitleChainEngine.recordedDateString(attrs[saleDateField])
        let grantor = TitleRecorderSource.str(attrs, saleGrantorField)
        let grantee = TitleRecorderSource.str(attrs, saleGranteeField)
        if desc.isEmpty && docNum.isEmpty && date.isEmpty && grantor.isEmpty && grantee.isEmpty { return nil }
        var e = TitleEvent()
        e.docType = desc.isEmpty ? "Recorded sale" : desc
        let k = TitleChainEngine.classify(desc)
        e.kind = k == .unknown ? .deed : k
        e.recordedDate = date
        e.docNumber = docNum
        e.party = [grantor, grantee].filter { !$0.isEmpty }.joined(separator: " → ")
        e.amount = TitleRecorderSource.posMoney(attrs, salePriceField)
        e.source = sourceLabel
        e.fetchedDate = fetchedDate
        return e
    }

    /// Durham + Wake + Orange + Buncombe — a tax Parcels layer that carries the parcel's recorded deed
    /// straight from the Register of Deeds. One parcel row → one recorded deed event. Counties name the
    /// columns differently, so the fields are read from this source's OWN `deed*` vocabulary (defaulting
    /// to the Durham/Wake schema): separate book/page (Durham/Wake DEED_BOOK/DEED_PAGE) OR a combined
    /// book/page column (Orange DEEDREF); an epoch-ms OR YYYYMMDD-string date; the owner via a
    /// first-non-empty fallback (Durham PROPERTY_OWNER → Wake OWNER → Orange OWNER1 → Buncombe owner);
    /// the amount from a recorded-sale-price fallback. Amount is a recorded sale price ONLY when the
    /// layer publishes one (> 0); we NEVER derive a price from revenue/excise stamps (a guess, §5.1) —
    /// Orange's STAMPVALUE and Durham's REVENUE_STAMPS are deliberately not in `deedPriceFields`.
    func parcelDeedEvent(_ attrs: [String: Any], fetchedDate: String) -> TitleEvent? {
        let book = TitleRecorderSource.str(attrs, deedBookField)
        let page = TitleRecorderSource.str(attrs, deedPageField)
        let combined = deedRefField.map { TitleRecorderSource.str(attrs, $0) } ?? ""
        let rod = TitleRecorderSource.str(attrs, deedRodDocField)
        let date = deedPackedYMDDate ? TitleChainEngine.packedYMDString(attrs[deedDateField])
            : (deedDateIsOracleDMY ? TitleChainEngine.oracleDMYString(attrs[deedDateField])
                                   : TitleChainEngine.recordedDateString(attrs[deedDateField]))
        let bookPage = !combined.isEmpty ? combined
            : ((book.isEmpty && page.isEmpty) ? "" : "\(book)-\(page)")
        let docNum = !rod.isEmpty ? rod : bookPage
        if docNum.isEmpty && date.isEmpty { return nil }
        var e = TitleEvent()
        e.docType = bookPage.isEmpty ? "Recorded deed (Register of Deeds)" : "Recorded deed — book/page \(bookPage)"
        e.kind = .deed
        e.recordedDate = date
        e.docNumber = docNum
        e.party = deedOwnerFields.lazy.map { TitleRecorderSource.str(attrs, $0) }.first { !$0.isEmpty } ?? ""
        e.amount = deedPriceFields.lazy.compactMap { TitleRecorderSource.posMoney(attrs, $0) }.first
        e.source = sourceLabel
        e.fetchedDate = fetchedDate
        return e
    }
}

enum TitleRecorderRegistry {
    /// LIVE-VERIFIED 2026-07-14 (curl fixtures in Tests/fixtures/recorder/). Adding a county here is
    /// how recorder coverage grows — each entry is a real endpoint whose fields were confirmed, not a
    /// placeholder.
    static let sources: [TitleRecorderSource] = [
        TitleRecorderSource(
            county: "guilford", displayName: "Guilford County, NC", state: "NC",
            shape: .foreclosureFiling,
            endpoint: "https://gcgis.guilfordcountync.gov/arcgis/rest/services/Foreclosure/ForeclosuresPublic/MapServer/0/query",
            // ParcelLookup resolves Guilford's PIN (GISDV/Parcels.PIN); the foreclosure layer's PIN
            // carries the same 10-digit form → bind first-try. Live-verified: PIN 8835527028 → 1 filing.
            joinFields: ["PIN", "PARCEL_ID", "REID"],
            outFields: ["PARCEL_ID", "PIN", "REID", "FLAG_TYPE", "FLAG_STATUS", "Owner", "Deed", "DEED_DATE", "AuctionDate"],
            orderBy: "AuctionDate DESC",
            parcelLookupField: "PIN",
            sourceLabel: "Guilford County, NC Register of Deeds — foreclosure filings"),
        TitleRecorderSource(
            county: "mecklenburg", displayName: "Mecklenburg County, NC", state: "NC",
            shape: .saleRecords,
            endpoint: "https://meckgis.mecklenburgcountync.gov/server/rest/services/TaxParcelSales/MapServer/0/query",
            // ParcelLookup resolves Mecklenburg's `pid` (TaxParcel_Camaownershipvalues.pid); the sales
            // layer's `parcelid` carries the same value form → bind first-try. Live-verified 2026-07-14:
            // pid 00101102 → 4 recorded sales.
            joinFields: ["parcelid"],
            outFields: ["parcelid", "saleprice", "saledate", "grantor", "grantee", "deeddescription", "legalreference"],
            orderBy: "saledate DESC",
            parcelLookupField: "pid",
            sourceLabel: "Mecklenburg County, NC — recorded property sales (Register of Deeds)"),
        TitleRecorderSource(
            county: "durham", displayName: "Durham County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://webgis2.durhamnc.gov/server/rest/services/PublicServices/Property/MapServer/4/query",
            // ROUND 17 (2026-07-15) — joins on REID ONLY. This is the county that PROVED the round-16
            // fabrication, and the re-key is what converts the honest-empty gate back into a real chain.
            //
            // Live-enumerated on THIS recorder layer (2026-07-15), 133,231 rows:
            //   REID: max 1 row per value · 0 nulls · count(REID) == 133,231  ⇒ BIJECTIVE — the honest join
            //   PIN : max 321 rows for one value (PIN 0823507508) · 0 nulls   ⇒ a BUILDING key, not identity
            // That worst PIN carries 321 distinct REIDs and 20 DISTINCT deed events (MRP NORTH POINTE LLC
            // $42,100,000 · GEP X BROAD OWNER LP · … one row even prices at $645,018,252,700) — b40
            // rendered those 20 conveyances as ONE unit's title history. `where REID='104855'` → 1 row.
            //
            // PIN is REMOVED from joinFields, not merely deprioritised: the predicate OR-matches, so
            // leaving PIN in would re-collect all 321 rows the moment a PIN-form value reached it. The
            // round-16 runtime gate still stands behind this as defence-in-depth (it is what keeps a
            // NEW non-unique key honest-empty rather than fabricating), but a gate that fires is a
            // FEATURE OFF — the re-key is what gives Durham buyers their real deed back.
            joinFields: ["REID"],
            outFields: ["REID", "PIN", "PROPERTY_OWNER", "DEED_DATE", "DEED_BOOK", "DEED_PAGE", "MAP_ROD_DOC_ID", "PKG_SALE_PRICE"],
            orderBy: "DEED_DATE DESC",
            parcelLookupField: "REID",
            sourceLabel: "Durham County, NC — recorded deed (Register of Deeds, via tax parcel)"),
        TitleRecorderSource(
            county: "wake", displayName: "Wake County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://maps.wake.gov/arcgis/rest/services/Property/Parcels/MapServer/0/query",
            // ParcelLookup resolves Wake's PIN_NUM (Property/Parcels.PIN_NUM); the recorder query hits
            // the SAME parcel layer, which carries the recorded deed (DEED_BOOK/PAGE/DATE + OWNER) →
            // bind first-try. Live-verified 2026-07-14: PIN_NUM 0695327712 → deed book 019788 pg 00619.
            joinFields: ["PIN_NUM", "REID"],
            outFields: ["PIN_NUM", "REID", "OWNER", "DEED_BOOK", "DEED_PAGE", "DEED_DATE", "SALE_DATE"],
            orderBy: "DEED_DATE DESC",
            parcelLookupField: "PIN_NUM",
            sourceLabel: "Wake County, NC — recorded deed (Register of Deeds, via tax parcel)"),
        TitleRecorderSource(
            county: "orange", displayName: "Orange County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.orangecountync.gov/arcgis/rest/services/WebParcelService/MapServer/0/query",
            // ParcelLookup resolves Orange's PIN (WebParcelService/Parcels.PIN); the recorder query hits
            // the SAME parcel layer, which carries the recorded deed (combined DEEDREF book/page + DATESOLD
            // + OWNER1) → bind first-try. Live-verified 2026-07-14: PIN 0801034359 → deed 6784/2278.
            joinFields: ["PIN"],
            outFields: ["PIN", "OWNER1", "DEEDREF", "DATESOLD"],
            orderBy: "DATESOLD DESC",
            parcelLookupField: "PIN",
            sourceLabel: "Orange County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedRefField: "DEEDREF", deedDateField: "DATESOLD", deedOwnerFields: ["OWNER1"],
            // STAMPVALUE is excise-tax stamps, NOT a sale price — deliberately not a price field (§5.1).
            deedPriceFields: []),
        TitleRecorderSource(
            county: "buncombe", displayName: "Buncombe County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.buncombecounty.org/arcgis/rest/services/opendata/FeatureServer/1/query",
            // ParcelLookup resolves Buncombe's pinnum (property_bc_dis/Property.pinnum); the recorder query
            // hits the SAME layer, which carries the recorded deed (DeedBook/DeedPage + DeedDate YYYYMMDD
            // string + owner) AND a real recorded SalePrice → bind first-try.
            //
            // ROUND 18 (2026-07-15) RE-KEY: pin → pinnum, and `pin` DROPPED from the join predicate.
            // Round 16 proved `pin` fabricates (it is a BUILDING key condo units share) and gated the
            // county; round 17 suspected pinnum was the honest key but could not prove it, because the
            // layer silently ignores resultRecordCount (a capped query returns an HTTP-200 envelope with
            // ZERO features, which reads exactly like "no collisions") and 500s on ~1 in 3 IDENTICAL
            // queries, so no single negative meant anything. Proven this round by an EXHAUSTIVE
            // enumeration — retry-with-backoff (8 tries), NO resultRecordCount anywhere, and a
            // `having COUNT(OBJECTID) > 1` groupBy that returns every colliding group UNCAPPED:
            //   · 134,921 rows total (returnCountOnly), count(pinnum) = 134,921 → 0 nulls; pinnum='' → 0.
            //   · Only FIVE pinnum values collide at all, each exactly 4 rows (20 rows). Every one of the
            //     five is 4 BYTE-IDENTICAL prints of ONE parcel (1 distinct pin, 1 distinct deed identity
            //     — e.g. 965345320700000 → TOLL MICHAEL PATRICK, 6594/0049, $132,000, 107 EDGEWOOD CT),
            //     so the exact-match collapse in parse() reduces each to ONE real event. None reaches the
            //     ambiguous-join gate. Reconciles: 134,921 − 20 + 5 = 134,906 distinct pinnum.
            //   · pinnum is the UNIT-level identity, Durham's REID pattern exactly: the round-16 landmine
            //     pin '9627023924' (226 rows / 224 distinct deeds) carries 226 DISTINCT pinnum —
            //     '962702392400000' for the common area (BILTMORE COMMONS UNIT OWNERS) plus per-unit
            //     'C0101', 'C0102', 'C3302', … So pinnum is NOT merely pin+'00000'; were it that, all 226
            //     rows would share one pinnum and it would be exactly as bad as pin.
            //   · The honest join now RENDERS what round 16 could only blank: pinnum='9627023924C0101'
            //     returns exactly ONE row — SEWELL FAMILY TRUST, 101 ROUGH POINT CT, deed 6346/1934,
            //     recorded $345,000 (2023-08-31).
            // `pin` is dropped from the PREDICATE (not from outFields — it is the county's real published
            // column) for the round-17 Pitt reason: a pinnum-shaped value can't match a 10-digit pin
            // today, but "inert today" is not a safety property.
            joinFields: ["PIN"],
            outFields: ["PIN", "Owner", "Address", "DeedBook", "DeedPage", "DeedDate", "SalePrice"],
            orderBy: "DeedDate DESC",
            parcelLookupField: "PIN",
            sourceLabel: "Buncombe County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DeedBook", deedPageField: "DeedPage", deedDateField: "DeedDate",
            deedOwnerFields: ["Owner"], deedPriceFields: ["SalePrice"]),
        TitleRecorderSource(
            county: "gaston", displayName: "Gaston County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://cogserver.gastonianc.gov/serverweb/rest/services/Parcels/GastonCountyParcels/MapServer/0/query",
            // ParcelLookup resolves Gaston's AKPAR (Parcels/GastonCountyParcels.AKPAR); the recorder query
            // hits the SAME layer, which carries the recorded deed (DEED_BOOK/DEED_PAGE + esri-date SALEDATE
            // + CURR_NAME1) AND a real recorded SALESAMT → bind first-try.
            //
            // ROUND 22 (2026-07-15) RE-KEY: PIN → AKPAR, and PIN *and* PID DROPPED from the join predicate.
            // Round 16 gated this county (PIN: 11 colliding values, 6 DIFFERING); round 17 refused the PID
            // re-key but recorded a reason that is REFUTED — it claimed PIN's collisions were all multipart
            // geometry that collapse and "render the real deed today". Only 5 of 11 do. The other SIX are
            // two DIFFERENT parcels under one PIN (full evidence in the ParcelRegistry entry): the landmine
            // PIN returns 2 rows / 2 DISTINCT deeds — NC DEPT OF TRANSPORTATION (3696/0894, $312,000) and
            // GREENWOOD MANAGEMENT LLC (5533/1481). b40 gated those; it never rendered them. Every PIN is
            // named in docs/COUNTY-KEY-AUDIT.md (round 22) + Tests/fixtures/recorder/ — not here, because
            // the Sources placeholder-token guard substring-bans the classic fake-phone exchange and these
            // real county PINs contain those digits.
            //
            // AKPAR is the honest key: 115,066 rows, 0 nulls, 0 empties, and only 3 colliding values — all
            // byte-identical sibling prints of ONE parcel (1 distinct rendered deed each) that parse()'s
            // exact-match collapse folds to one event, so none reaches the ambiguous-join gate. The re-key
            // RENDERS what the gate could only blank: each of the 6 fabricating PIN groups splits into 2
            // distinct AKPARs, and every one returns EXACTLY ONE row (6/6 live-proven) —
            // AKPAR='105508' → NC DEPT OF TRANSPORTATION, deed 3696/0894, recorded $312,000.
            //
            // Both old keys are removed from the PREDICATE (not from outFields — they are the county's real
            // published columns) per the round-17 Pitt rule. Unlike harnett's `ROW` sentinel, Gaston's OR is
            // INERT TODAY and is dropped as a LATENT hazard, not a live defect: AKPAR is 6 digits and PIN is
            // 10, disjoint across a 2,000-row sample, so no AKPAR value can match a PIN today. "Inert today"
            // is not a safety property — one county reformat that widens AKPAR re-admits all 6 fabrications.
            joinFields: ["AKPAR"],
            outFields: ["AKPAR", "PIN", "PID", "CURR_NAME1", "DEED_BOOK", "DEED_PAGE", "DEEDTYPE", "SALEDATE", "SALESAMT"],
            orderBy: "SALEDATE DESC",
            parcelLookupField: "AKPAR",
            sourceLabel: "Gaston County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DEED_BOOK", deedPageField: "DEED_PAGE", deedDateField: "SALEDATE",
            deedOwnerFields: ["CURR_NAME1"], deedPriceFields: ["SALESAMT"]),
        TitleRecorderSource(
            county: "cumberland", displayName: "Cumberland County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.co.cumberland.nc.us/server/rest/services/Tax/Parcels/MapServer/0/query",
            // ParcelLookup resolves Cumberland's PIN (Tax/Parcels.PIN, dashed "0466-96-7734"); the recorder
            // query hits the SAME layer, which carries the recorded deed (DEED_BOOK/DEED_PAGE + "yyyy-MM-dd"
            // string DEED_DATE + OWNER) AND a recorded PKG_SALE_PRICE → bind first-try on the Durham/Wake
            // default vocabulary (DEED_BOOK/DEED_PAGE/DEED_DATE + PROPERTY_OWNER→OWNER + PKG_SALE_PRICE).
            // Live-verified 2026-07-14: PIN 0466-96-7734 → deed 12567/0160, recorded sale $340,500.
            joinFields: ["PIN", "REID"],
            outFields: ["PIN", "REID", "OWNER", "DEED_BOOK", "DEED_PAGE", "DEED_DATE", "PKG_SALE_PRICE"],
            orderBy: "DEED_DATE DESC",
            parcelLookupField: "PIN",
            sourceLabel: "Cumberland County, NC — recorded deed (Register of Deeds, via tax parcel)"),
        TitleRecorderSource(
            county: "rowan", displayName: "Rowan County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.rowancountync.gov/arcgis/rest/services/Public/RowanTaxParcels/MapServer/0/query",
            // ParcelLookup resolves Rowan's PARCEL_ID (RowanTaxParcels.PARCEL_ID, "067 198"); the recorder
            // query hits the SAME tax parcel layer, which carries the recorded deed (DEEDBOOK/DEEDPAGE + an
            // esri-date DATESOLD (epoch ms) + OWNNAME) AND a real recorded SALE_AMT → bind first-try.
            //
            // ROUND 21 — RE-KEYED PIN → PARCEL_ID in lockstep with the ParcelLookup registry (see the
            // evidence there: PIN has 44 live groups whose rows are DIFFERENT parcels, PARCEL_ID only 2,
            // and 40 of the 44 are rescued). PIN is DROPPED FROM THE PREDICATE and kept only in
            // outFields — the round-17 Pitt rule: an OR join `PIN='X' OR PARCEL_ID='X'` re-admits every
            // collision the re-key just removed, so a proven key must be joined ALONE.
            joinFields: ["PARCEL_ID"],
            outFields: ["PIN", "PARCEL_ID", "OWNNAME", "DEEDBOOK", "DEEDPAGE", "DATESOLD", "SALE_AMT", "SALEINST"],
            orderBy: "DATESOLD DESC",
            parcelLookupField: "PARCEL_ID",
            sourceLabel: "Rowan County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DEEDBOOK", deedPageField: "DEEDPAGE", deedDateField: "DATESOLD",
            deedOwnerFields: ["OWNNAME"], deedPriceFields: ["SALE_AMT"]),
        TitleRecorderSource(
            county: "iredell", displayName: "Iredell County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://maps.iredellcountync.gov/server/rest/services/Data/TaxSQL_Parcels/MapServer/0/query",
            // ParcelLookup resolves Iredell's PIN (TaxSQL_Parcels.PIN, "4659165906.000"); the recorder query
            // hits the SAME layer, which carries the recorded deed (DWBook/DWPage + Name) AND a recorded
            // Sales_Price → bind first-try. The deed date shown is the real conveyance date Sale_Date
            // ("MM/DD/YYYY", passed through verbatim) — NOT the layer's `DeedDate`, which is a data-refresh
            // timestamp (see the ParcelRegistry note). Live-verified 2026-07-14: PIN 4659165906.000 → deed
            // 3043/1783, sale $232,500.
            joinFields: ["PIN"],
            outFields: ["PIN", "Name", "DWBook", "DWPage", "Sale_Date", "Sale_Yr", "Sales_Price"],
            orderBy: "Sale_Yr DESC",
            parcelLookupField: "PIN",
            sourceLabel: "Iredell County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DWBook", deedPageField: "DWPage", deedDateField: "Sale_Date",
            deedOwnerFields: ["Name"], deedPriceFields: ["Sales_Price"]),
        TitleRecorderSource(
            county: "randolph", displayName: "Randolph County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.randolphcountync.gov/arcgis/rest/services/ParcelBasemap/MapServer/5/query",
            // ParcelLookup resolves Randolph's PIN (ParcelBasemap/5.PIN); the recorder query hits the SAME
            // parcel layer, which carries the recorded deed (DOCUMENT_BOOK/DOCUMENT_PAGE + owner ACCT_NAME) →
            // bind first-try. The layer publishes NO recorded sale PRICE and NO conveyance DATE (DATESTAMP/
            // REFRESHDATE are refresh stamps, never a sale), so the deed row carries book/page as its doc
            // number and honestly no amount/date (like Guilford's non-priced feed). Live-verified 2026-07-14:
            // PIN 6687457058 → deed 002062/01984 (SMITH, WILLIAM FRANKLIN III).
            joinFields: ["PIN", "REID"],
            outFields: ["PIN", "REID", "ACCT_NAME", "DOCUMENT_BOOK", "DOCUMENT_PAGE", "DEED_BK_PG"],
            orderBy: "DOCUMENT_BOOK DESC",
            parcelLookupField: "PIN",
            sourceLabel: "Randolph County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DOCUMENT_BOOK", deedPageField: "DOCUMENT_PAGE",
            deedOwnerFields: ["ACCT_NAME"], deedPriceFields: []),   // no recorded sale price → never fabricated
        TitleRecorderSource(
            county: "alamance", displayName: "Alamance County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://apps.alamance-nc.com/arcgis/rest/services/Tax/AlamanceParcels/MapServer/0/query",
            // A transient zero-count response recovered during the b49 live re-probe: this authoritative
            // county parcel/deed layer is populated again (79,606 rows) and carries the richer situs/full
            // co-owner record. The resolved AKPAR_ joins first-try and AMDTSL is explicitly decoded as packed
            // YYYYMMDD, not epoch milliseconds. Live-verified 2026-08-02: AKPAR_ 171622 → deed 4798/0276,
            // AMDTSL 20251209, AMSLAM $475,000, SMITH MICHAEL C & CRYSTAL D SMITH.
            joinFields: ["AKPAR_"],
            outFields: ["AKPAR_", "OWNAM1", "AMDBOK", "AMDPGE", "AMDTSL", "AMSLAM", "AMSALI"],
            orderBy: "AMDTSL DESC",
            parcelLookupField: "AKPAR_",
            sourceLabel: "Alamance County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "AMDBOK", deedPageField: "AMDPGE", deedDateField: "AMDTSL",
            deedOwnerFields: ["OWNAM1"], deedPriceFields: ["AMSLAM"], deedPackedYMDDate: true),
        TitleRecorderSource(
            county: "pitt", displayName: "Pitt County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.pittcountync.gov/gis/rest/services/PittOpenData/CadastralPitt/MapServer/0/query",
            // ParcelLookup resolves Pitt's PARCELNUMBER (CadastralPitt/0.PARCELNUMBER); the recorder query hits
            // the SAME parcel layer, which carries the recorded deed (DeedBook/DeedPage + owner OwnerName) AND a
            // real recorded SalesPrice paired with an esri-date DocumentDate (epoch ms, whose value matches the
            // county's SalesMonthYear — a REAL conveyance date, NOT a refresh stamp) → bind first-try.
            // Live-verified 2026-07-14: PARCELNUMBER 90616 → deed 004790/00393, DocumentDate 2026-06-01,
            // recorded sale $229,000 (SMITH REMEDEAS).
            //
            // ROUND 17 (2026-07-15) — NCPIN REMOVED from joinFields. Live-enumerated on this layer
            // (81,209 rows): NCPIN's worst value (4688309333) holds 156 rows, vs a max of 2 for both
            // PARCELNUMBER and REID (whose 2-row collisions are one parcel's duplicate geometry —
            // 1 distinct REID, 1 distinct deed event — so they collapse and render the real deed).
            //
            // NCPIN is currently UNREACHABLE rather than actively fabricating: the resolved value is a
            // PARCELNUMBER, and the value forms do not overlap (sampled 2,000 rows: PARCELNUMBER is
            // 5 digits, NCPIN 10, REID 6; zero PARCELNUMBER values exist as an NCPIN). It is removed
            // anyway — an OR-predicate naming a 156-row key is a fabrication waiting for the first
            // county reformat that widens PARCELNUMBER, and "inert today" is not a safety property.
            joinFields: ["PARCELNUMBER", "REID"],
            outFields: ["PARCELNUMBER", "NCPIN", "REID", "OwnerName", "DeedBook", "DeedPage", "DocumentDate", "SalesPrice"],
            orderBy: "DocumentDate DESC",
            parcelLookupField: "PARCELNUMBER",
            sourceLabel: "Pitt County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DeedBook", deedPageField: "DeedPage", deedDateField: "DocumentDate",
            deedOwnerFields: ["OwnerName"], deedPriceFields: ["SalesPrice"]),
        TitleRecorderSource(
            county: "harnett", displayName: "Harnett County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.harnett.org/arcgis/rest/services/Tax/Parcels/MapServer/0/query",
            // ParcelLookup resolves Harnett's PIN (Tax/Parcels/0.PIN, dashed "0630-23-2398.000"); the recorder
            // query hits the SAME tax parcel layer, which carries the recorded deed (DeedBook/DeedPage + an
            // esri-date DeedDate (epoch ms, whose value 2026-02-27 matches the county's SaleMonth=2/SaleYear=2026
            // — a REAL conveyance date, NOT a refresh stamp like DateLastModified/LastEditDate) + owner Owner1)
            // AND a real recorded SalePrice → bind first-try. REID is a status column ("Retired"), NOT a parcel
            // id, so it is deliberately NOT a join field. Live-verified 2026-07-14: PIN 0630-23-2398.000 → deed
            // 4328/1959, DeedDate 2026-02-27, recorded sale $415,000 (RADER CHELSIE, SW instrument).
            //
            // ROUND 21 — PID DROPPED FROM THE PREDICATE (round-17 Pitt rule). No re-key was needed: PIN
            // is PROVEN-UNIQUE live 2026-07-15 — 85,464 rows, 0 null, 0 empty, and ZERO values held by
            // more than one row. That zero is proven NOT vacuous: the same groupBy at `having
            // COUNT(OBJECTID) >= 1` returns 2,000 groups (exceededTransferLimit), and on the sibling
            // field PID it finds real collisions — so the query runs and can detect collisions; PIN
            // simply has none. (Round 16 measured 1 differing PIN group against 89,460 rows; the layer
            // has since been refreshed to 85,464 and that collision is gone from the county's own data.)
            // The OR was the live defect: PID carries ROW/status sentinels, and `PIN='ROW Street' OR
            // PID='ROW Street'` returns 2,943 rows where PIN alone returns 0 — an OR re-admits every
            // collision the proven key excludes. Joined alone, a real PIN returns exactly 1 row.
            // Also re-confirmed: REID is the literal string "Retired" on ALL 85,464 rows — a column can
            // be 100% non-null AND 100% non-empty and still carry ZERO information, which no null/empty
            // guard can see.
            joinFields: ["PIN"],
            outFields: ["PIN", "PID", "REID", "Owner1", "DeedBook", "DeedPage", "DeedDate", "SalePrice", "InstrumentType"],
            orderBy: "DeedDate DESC",
            parcelLookupField: "PIN",
            sourceLabel: "Harnett County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DeedBook", deedPageField: "DeedPage", deedDateField: "DeedDate",
            deedOwnerFields: ["Owner1"], deedPriceFields: ["SalePrice"]),
        TitleRecorderSource(
            county: "davidson", displayName: "Davidson County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://webgis.co.davidson.nc.us/arcgis/rest/services/OpenGov/OpenGov/MapServer/6/query",
            // ParcelLookup resolves Davidson's PIN (OpenGov/6 TaxParcels.PIN, dashed "6852-01-08-6950"); the
            // recorder query hits the SAME parcel layer, which carries the most-recent recorded deed as top-level
            // DeedBook/DeedPage + a "MM/DD/YYYY"-string DeedDate (the real conveyance date, matching the newest of
            // the layer's inline DeedBook1..5/SaleYear1..5 sales — NOT a refresh stamp) + owner Name1 → bind
            // first-try. The layer publishes NO top-level recorded sale PRICE cleanly paired to the top deed (only
            // per-sale SalePrice1..5 columns whose ordering doesn't track the top deed), so — like Orange/Randolph —
            // the deed row carries book/page + real date and honestly NO amount (never a mis-paired price, §5.1).
            // Live-verified 2026-07-14: PIN 6852-01-08-6950 → deed 2763/0188, DeedDate 06/22/2026 (STEWART JOSHUA, WD).
            //
            // ROUND 20 (2026-07-15) RE-KEY: PIN → PARCEL_ID; PIN *and* PinNumber DROPPED from the join.
            // Round 16 proved BOTH fabricate — PIN 115 colliding values / 109 differing, PinNumber 134 /
            // 104 — and gated the county at runtime. PARCEL_ID is the UNIT-level identity (full live
            // enumeration in the ParcelRegistry entry: 98,879 rows, 21 colliding values, all 21
            // byte-identical siblings that parse() collapses, so none reaches the ambiguous-join gate).
            // The landmine: PIN '6891-01-08-0544' returns 13 rows / 13 distinct PARCEL_IDs / 13 DISTINCT
            // deeds — b40 rendered that as one unit's 13-deed chain. The honest join
            // PARCEL_ID='01008K0050001' returns exactly ONE row: JOHN KAVANAGH COMPANY, 1781/1857,
            // 04/24/2007 (WD) — the real deed round 16 could only blank.
            //
            // Both old keys are removed from the PREDICATE (not from outFields — they are the county's
            // real published columns) for the round-17 Pitt reason: the predicate OR-matches, so leaving
            // either in would re-collect all 13 rows the moment a PIN-form value reached it. "Inert
            // today" is not a safety property. The round-16 runtime gate still stands behind this as
            // defence-in-depth — but a gate that fires is a feature OFF; the re-key is what gives
            // Davidson buyers their real deed back.
            joinFields: ["PARCEL_ID"],
            outFields: ["PARCEL_ID", "PIN", "PinNumber", "Name1", "DeedBook", "DeedPage", "DeedDate", "InstrumentType"],
            orderBy: "DeedDate DESC",
            parcelLookupField: "PARCEL_ID",
            sourceLabel: "Davidson County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DeedBook", deedPageField: "DeedPage", deedDateField: "DeedDate",
            deedOwnerFields: ["Name1"], deedPriceFields: []),
        TitleRecorderSource(
            county: "onslow", displayName: "Onslow County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gismaps.onslowcountync.gov/arcgis/rest/services/WEB_PUBLICATIONS/Tax_Data/MapServer/0/query",
            // ParcelLookup resolves Onslow's PIN (Tax_Data/0.PIN, 12-digit "429913122812"); the SAME reval
            // layer carries the recorded conveyance — SALEBOOK/SALEPAGE + owner OWNER1 + a real recorded
            // SALEPRICE — paired with an Oracle "DD-MON-YY" SALEDATE. Iredell lesson APPLIED: SALEDATE is the
            // REAL conveyance date, not a reval/edit stamp — its SALEBOOK/SALEPAGE (1270/825) EQUALS the
            // parcel's current-deed BOOK/PAGE, so the sale deed IS the conveyance on title. Round-6/7 the
            // host's Let's Encrypt cert was EXPIRED (notAfter Jul 14 09:28 GMT); it RENEWED that same day
            // (notAfter Sep 13 2026, ssl_verify_result=0) so the app's cert-validating URLSession now
            // connects → wired round 8. Live-verified 2026-07-14: PIN 429913122812 → deed 1270/825, SALEDATE
            // 31-OCT-95 → 1995-10-31, recorded sale $104,500 (MITCHUM JUDITH W). The DD-MON-YY date is
            // normalized (deedDateIsOracleDMY) so it sorts chronologically, never lexically.
            //
            // ROUND 21 — RE-KEYED PIN → PARID in lockstep with the ParcelLookup registry (see the
            // evidence there: PIN has 50 live groups whose rows are DIFFERENT parcels; PARID has ZERO —
            // all 40 of its collisions are byte-identical siblings the parser already collapses — and
            // 48 of the 50 are rescued). PARID is joined ALONE (the round-17 Pitt rule); PIN stays in
            // outFields so the parcel still displays the id a buyer recognises.
            joinFields: ["PARID"],
            outFields: ["PIN", "PARID", "OWNER1", "SALEBOOK", "SALEPAGE", "SALEDATE", "SALECODE", "SALEPRICE"],
            orderBy: "SALEDATE DESC",
            parcelLookupField: "PARID",
            sourceLabel: "Onslow County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "SALEBOOK", deedPageField: "SALEPAGE", deedDateField: "SALEDATE",
            deedOwnerFields: ["OWNER1"], deedPriceFields: ["SALEPRICE"],
            deedDateIsOracleDMY: true),
        TitleRecorderSource(
            county: "craven", displayName: "Craven County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.cravencountync.gov/arcgis/rest/services/JustParcels/MapServer/0/query",
            // ParcelLookup resolves Craven's PID (JustParcels/0.PID, "8-205-4 -021"); the recorder query
            // hits the SAME parcel layer, which carries the recorded deed (PABOOK/PAPAGE + owner PANAME) AND
            // a real recorded SALE_PRICE paired with an esri-date SALE_DATE (epoch ms). SALE_DATE is the REAL
            // conveyance date — it EQUALS the county's own recording stamp PRECYR/PRECMN/PRECDY to the day
            // (round-5 date discipline) — NOT a refresh stamp. PID is unique (1 row) → bind first-try.
            // Live-verified 2026-07-14: PID '8-205-4 -021' → deed 3883/1511, SALE_DATE 2026-06-10, recorded
            // sale $356,500 (CARTLAND, MARY C).
            joinFields: ["PID"],
            outFields: ["PID", "PANAME", "PABOOK", "PAPAGE", "SALE_DATE", "SALE_PRICE", "SELLER1", "BUYER1"],
            orderBy: "SALE_DATE DESC",
            parcelLookupField: "PID",
            sourceLabel: "Craven County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "PABOOK", deedPageField: "PAPAGE", deedDateField: "SALE_DATE",
            deedOwnerFields: ["PANAME"], deedPriceFields: ["SALE_PRICE"]),
        TitleRecorderSource(
            county: "moore", displayName: "Moore County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.moorecountync.gov/server/rest/services/Tax/Tax_Parcel/MapServer/0/query",
            // ParcelLookup resolves Moore's PARID (Tax_Parcel/0.PARID, "00041503172"); the recorder query
            // hits the SAME parcel layer, which carries the recorded deed (DEED_BOOK/DEED_PAGE + owner NAME
            // + an esri-date TRANSDATE == VALID_SALESDT: a REAL conveyance date, NOT a refresh stamp). The
            // layer's PIN is NOT unique (one PIN spans 47 distinct PARID parcels), so Moore joins on PARID
            // ONLY — joining on PIN would fabricate a 47-deed chain for one parcel. NO clean recorded PRICE
            // exists (STAMP_VAL is excise-tax stamps, NOT a sale price — deliberately not a price field,
            // §5.1), so the deed row carries book/page + owner + real date and honestly NO amount (like
            // Orange/Randolph/Davidson). Live-verified 2026-07-14: PARID 00041503172 → deed 6571/355,
            // TRANSDATE 2026-06-25 (WELCH, LINDA M).
            joinFields: ["PARID"],
            outFields: ["PARID", "PIN", "NAME", "DEED_BOOK", "DEED_PAGE", "TRANSDATE", "STAMP_VAL"],
            orderBy: "TRANSDATE DESC",
            parcelLookupField: "PARID",
            sourceLabel: "Moore County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DEED_BOOK", deedPageField: "DEED_PAGE", deedDateField: "TRANSDATE",
            deedOwnerFields: ["NAME"], deedPriceFields: []),   // STAMP_VAL is excise stamps, never a price
        TitleRecorderSource(
            county: "wilson", displayName: "Wilson County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.wilson-co.com/arcgis/rest/services/Tax/Taxparcels/FeatureServer/0/query",
            // ParcelLookup resolves Wilson's PIN (Tax/Taxparcels.PIN, dashed "3668-52-8580.000"); the recorder
            // query hits the SAME parcel layer, which carries the recorded deed (DeedBook/DeedPage + owner Name1)
            // AND a real recorded SalesAmount → bind first-try (PIN is unique — live-verified: 1 row). PIN is the
            // ONLY join field: ParcelNumber is a different value form ("3668528580.000", no dashes) that a
            // resolved PIN would not match, so it is deliberately not an OR-predicate.
            // DATE-DISCIPLINE TRAP (round 10, worse than Iredell's refresh-stamp): Wilson's conveyance date is
            // CORRUPT — the packed-YYYYMMDD DateSold and its computed esri-date SaleDate carry impossible future
            // years for REAL recent sales (live-verified: PIN 3668-52-8580.000, a 2025 WARRANTY DEED for
            // $285,500, has DateSold 24001202 → year 2400; a sibling row 2657-98-1283.000 reads a clean 20200814,
            // so the field is unreliable PER ROW, not fixably filtered in a pure parser). DeedYear is only a year
            // and is a +1 tax-year offset. So the deed row carries book/page + owner + the REAL recorded price and
            // honestly OMITS the date (deedDateField "" → no date parsed) — a fabricated year-2400 conveyance
            // would be a §5.1 violation; like Randolph/Moore/Davidson, an absent-but-untrustworthy field stays
            // empty, never invented. Live-verified 2026-07-14: PIN 3668-52-8580.000 → deed 3093/230, recorded
            // sale $285,500 (PURSER CLAUDIA, WARRANTY DEED).
            joinFields: ["PIN"],
            outFields: ["PIN", "Name1", "DeedBook", "DeedPage", "SalesAmount", "SalesInstrumentDesc", "DeedYear"],
            orderBy: "DeedYear DESC",   // one row per parcel; DeedYear (a sane year) — never the corrupt SaleDate
            parcelLookupField: "PIN",
            sourceLabel: "Wilson County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DeedBook", deedPageField: "DeedPage",
            deedDateField: "",   // conveyance date CORRUPT (future years) → honestly omitted, never a fabricated date
            deedOwnerFields: ["Name1"], deedPriceFields: ["SalesAmount"]),
        TitleRecorderSource(
            county: "cleveland", displayName: "Cleveland County, NC", state: "NC",
            shape: .saleRecords,
            endpoint: "https://gis.clevelandcounty.com/arcgis/rest/services/Tax/Vacant_ImprovedLot_Sales/MapServer/0/query",
            // ROUND 11 — a TRUE multi-row event-level sales roll, the second beyond Alamance. Round 10
            // declined Cleveland twice: (1) its parcel layer (Tax/Tax "Parcel Area") carries GIS_Owner1 +
            // GIS_DeedBook_Page but NO situs address and NO assessed value, and the only address layer
            // (Planning/AddressPoints_AGOL) publishes FullAddress with NO parcel id — so there is no
            // attribute-join key and ParcelLookup still cannot bind Cleveland (re-pinned NEGATIVE); and
            // (2) it read Vacant_ImprovedLot_Sales as "one-row-per-parcel (496/500 distinct)". That was a
            // 500-row SAMPLING ARTIFACT: the full layer is 2,765 rows and 181 parcels carry >1 sale (live-
            // verified round 11 via a groupBy-count query — Parcel_Number 60930 has 8 rows, 26168 has 4
            // distinct recorded deeds). This roll joins on Parcel_Number (the SAME value form the Tax/Tax
            // Parcel Area GIS_PID publishes — 26168 → SHELBY HOSPITALITY PARTNERS LLC, deed 1950-2795), so a
            // Cleveland lead that carries a parcel id (manual/CSV, since ParcelLookup can't resolve one) gets
            // its real recorded sales chain. The layer has NO grantor/grantee columns → party stays honestly
            // empty. Sales_Amount is the REAL recorded price; Deed_Stamp_Amount is the NC excise stamp
            // (price × $2/$1000) and is DELIBERATELY not read (excise ≠ price, §5.1 — verified: $2,309,500 →
            // stamp $4,619; $399,000 → $798). DATE: the epoch-ms DateSold is clean and sane (live min 2022-
            // 01-01 / max 2025-12-31 across the whole layer — NO Wilson-style year-2400 corruption), so it is
            // read; the sibling string DateSold_YYYYMMDD is null on newer rows and is not used. The layer
            // republishes an identical deed once per tax-year snapshot (60930's 2022 deed repeats 6×), which
            // parse()'s exact-identity collapse drops (8 rows → 3 distinct sales) so no fabricated multiplicity
            // ships. Live-verified 2026-07-14: Parcel_Number 60930 → 8 rows → 3 recorded sales ($2,309,500 ×2
            // distinct deeds + $399,000).
            joinFields: ["Parcel_Number"],
            outFields: ["Parcel_Number", "Deed_Book", "Deed_Page", "DateSold", "Sales_Amount"],
            orderBy: "DateSold DESC",
            parcelLookupField: "GIS_PID",   // ROUND 12: Cleveland now enters ParcelRegistry as a pid-only county
                                            // (parcelField GIS_PID). Like Mecklenburg (ParcelLookup `pid` → recorder
                                            // column `parcelid`), the recorder joins its OWN column `Parcel_Number`
                                            // (joinFields) whose VALUE form equals the resolved GIS_PID — live-
                                            // verified: GIS_PID 60930 (SC HOMES LP, deed 1943-74) == the roll's
                                            // Parcel_Number 60930 (deed 1943-0074 $2,309,500). parcelLookupField
                                            // names the ParcelRegistry field so the two registries can't drift.
            sourceLabel: "Cleveland County, NC — recorded lot sales (Register of Deeds)",
            saleDescField: "", saleRefField: "",
            saleBookField: "Deed_Book", salePageField: "Deed_Page",
            saleGrantorField: "", saleGranteeField: "",   // layer publishes no party columns → party honestly empty
            saleDateField: "DateSold", salePriceField: "Sales_Amount", salePackedYMDDate: false),
        TitleRecorderSource(
            county: "haywood", displayName: "Haywood County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://maps.haywoodcountync.gov/arcgis/rest/services/Land_Records/Qualified_Sales/MapServer/2/query",
            // ROUND 14. County-OWNED host (maps.haywoodcountync.gov) — authoritative, unlike the round-14
            // Stanly/Watauga candidates that were declined on provenance (personal/university AGOL uploads).
            // The deed reference is COMBINED "book/page" in LegalRef_1 (like Orange's DEEDREF) → deedRefField.
            // Carries a REAL recorded Sale_Price and an epoch-ms Sale_Date.
            //
            // NON-UNIQUE-JOIN TRAP (the Moore lesson) — CLEARED BY EXHAUSTIVE ENUMERATION.
            //
            // ⚠️ ROUND 15 CORRECTION — the round-14 proof that stood here was INVALID and is retained below
            // only as a warning. It claimed: "distinct ALPHA (45,342) == distinct OBJECTID (45,342) ⇒ ALPHA→
            // OBJECTID is a bijection ⇒ ALPHA is unique". That reasoning is CIRCULAR on this layer. The count
            // identity technique is only meaningful when the right-hand column is the ROW IDENTITY, and here it
            // is not: this layer's `objectIdField` is NULL and it carries TWO oid-ish columns — a plain
            // `OBJECTID`, which is itself a PARCEL-level attribute that co-varies with ALPHA (hence the
            // identical 45,342 — comparing ALPHA to a second copy of ALPHA), and `OBJECTID_1`, the actual row
            // identity. Measured against the REAL oid the equality FAILS: OBJECTID_1 has 46,603 distinct values
            // == 46,603 total rows, against only 45,342 distinct ALPHA — 1,261 excess rows. Round 14's own note
            // contained the refutation and misread it: "14 rows all carrying OBJECTID 26114109" — a column that
            // repeats across 14 rows CANNOT be an object id, which is precisely why that equality proved
            // nothing. Anyone re-running the round-14 verify command gets a FALSE GREEN.
            //
            // The real proof is the enumeration the shortcut was standing in for, re-run round 15 over the full
            // 46,603-row roll: ALPHA collides on 935 values (1,261 excess rows), and for ALL 935 the rows are
            // byte-identical on every displayed field — Owner_1, Prop_Addr, Land_Value, Bldg_Value, Assd_Value,
            // Sale_Price, Sale_Date, Heated_Area, LegalRef_1 all disagree on ZERO colliding ALPHAs. So the
            // excess rows are exact multipart re-prints, parse()'s exact-identity pass folds them to one event
            // (fixture: 14 rows → 1 event), and no Moore-style chain of foreign parcels can be fabricated. The
            // round-14 CONCLUSION (wire Haywood on ALPHA) therefore stands — but on evidence, not on the
            // bijection it asserted. Had any collision differed, Haywood would have been pinned NEGATIVE.
            // Rows carrying a NULL ALPHA simply never join — honest, never guessed.
            //
            // DATE-DISCIPLINE (the Wilson trap, deliberately NOT triggered): Sale_Date's range is 1814-12-24 →
            // 2026-10-25, and that max is ~3 months in the FUTURE of the 2026-07-14 pull. Wilson's date was
            // OMITTED because it was IMPOSSIBLE (year 2400) and self-contradicting for a known-2025 deed. Here
            // only 2 rows of 46,548 (= ONE parcel, multipart-duplicated) are future-dated, 7 predate 1900, and
            // the epoch Sale_Date AGREES with the layer's INDEPENDENT Sale_Date_String column ('10 25 2026'),
            // so the field is the county's own corroborated record, not corruption. We publish what the county
            // recorded, verbatim — omitting a real date would be as dishonest as inventing one.
            joinFields: ["ALPHA"],
            outFields: ["ALPHA", "Owner_1", "Prop_Addr", "LegalRef_1", "Sale_Date", "Sale_Price"],
            orderBy: "Sale_Date DESC",
            parcelLookupField: "ALPHA",
            sourceLabel: "Haywood County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedRefField: "LegalRef_1",       // COMBINED "926/615" book/page (Orange DEEDREF shape)
            deedDateField: "Sale_Date",
            deedOwnerFields: ["Owner_1"], deedPriceFields: ["Sale_Price"]),
        TitleRecorderSource(
            county: "surry", displayName: "Surry County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.co.surry.nc.us/arcgis/rest/services/Parcels/MapServer/0/query",
            // ROUND 14. County-OWNED host (gis.co.surry.nc.us). Split DeedBook/DeedPage + owner Name1.
            //
            // NON-UNIQUE-JOIN TRAP — CLEARED BY EXHAUSTIVE CHECK, and here the count identity FAILS where
            // Haywood's held: 44,433 rows / 44,345 distinct Parcel / 44,431 distinct OBJECTID. Distinct
            // OBJECTID > distinct Parcel, so a Parcel value DOES span multiple distinct rows — the exact
            // precondition of the Moore fabrication. So the bijection shortcut is unavailable and every
            // collision was enumerated instead: 59 Parcel values appear >1×, and for ALL 59 the rows are
            // byte-identical on every displayed field (owner, address, deed book/page, assessed value) —
            // e.g. Parcel 499900039456 → 4 rows (OBJECTIDs 43898-43901), all JOHNSON RITA JOAN, deed
            // 00594/0680. They are multipart polygon parts that were each assigned their own OBJECTID, NOT
            // distinct parcels. So parse()'s exact-identity collapse yields exactly ONE deed event per
            // Parcel and no multiplicity is fabricated (fixture: 4 rows → 1 event). Had ANY collision
            // differed, Surry would have been pinned NEGATIVE rather than joined on a lying key.
            //
            // The layer publishes NO conveyance date and NO sale price — so, like Randolph/Moore/Davidson,
            // the deed row carries book/page + owner and honestly omits both. An absent field stays empty,
            // never invented (§5.1). Live-verified 2026-07-14: Parcel 501100289629 → deed 01822/0782
            // (MONTGOMERY CAMPBELL GRANT).
            joinFields: ["Parcel"],
            outFields: ["Parcel", "Name1", "DeedBook", "DeedPage"],
            orderBy: "DeedBook DESC",   // one row per parcel; the layer exposes no date to sort on
            parcelLookupField: "Parcel",
            sourceLabel: "Surry County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DeedBook", deedPageField: "DeedPage",
            deedDateField: "",            // no conveyance date published → honestly omitted
            deedOwnerFields: ["Name1"], deedPriceFields: []),   // no recorded price published → honestly absent
        TitleRecorderSource(
            county: "pender", displayName: "Pender County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.pendercountync.gov/arcgis/rest/services/Layers/MapServer/4/query",
            // ROUND 14. County-OWNED host (gis.pendercountync.gov). DEED_BOOK/DEED_PAGE + owner NAME + a real
            // recorded SALE_PRICE + an epoch-ms conveyance date.
            //
            // NON-UNIQUE-JOIN TRAP — CLEARED BY EXHAUSTIVE CHECK (same posture as Surry): 55,215 rows /
            // 53,625 distinct PIN / 53,877 distinct OBJECTID, so PIN spans multiple rows and the bijection
            // shortcut does NOT apply. All 174 duplicated PINs were enumerated (a groupBy ordered by count
            // DESC — the 175th group has n=1, so the 174 are exhaustive, not a sample): every one is
            // byte-identical across its rows on owner/deed/date/price. Multipart re-prints again → the
            // exact-identity collapse yields exactly one deed event per PIN.
            //
            // RESERVED-WORD TRAP: this layer names its conveyance date column `DATE` — a SQL reserved word.
            // `outStatistics` over it 500s, which is what a naive schema probe hits. The RECORDER's own query
            // shape (where=PIN='…' + orderByFields=DATE DESC) was live-curled and returns 200 with real rows,
            // so `orderBy: "DATE DESC"` is proven against the endpoint the app actually calls, not assumed.
            //
            // One recorded deed can convey MANY parcels — PIN 2223-78-7833-0000, 2223-79-4191-0000 and
            // 2224-70-3123-0000 all carry deed 4780/244 for $3,446,000 (IVY LODGE TIMBER LLC). That is the
            // register's own truth and each PIN joins to its OWN row; nothing is duplicated across parcels.
            // 13,133 of 55,215 rows carry a NULL PROPERTY_ADDRESS — irrelevant to the deed chain (address is
            // not read here) and never fabricated. Live-verified 2026-07-14: PIN 2223-78-7833-0000 → deed
            // 4780/244, 2022-02-18, $3,446,000.
            joinFields: ["PIN"],
            outFields: ["PIN", "NAME", "DEED_BOOK", "DEED_PAGE", "DATE", "SALE_PRICE"],
            orderBy: "DATE DESC",
            parcelLookupField: "PIN",
            sourceLabel: "Pender County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DEED_BOOK", deedPageField: "DEED_PAGE", deedDateField: "DATE",
            deedOwnerFields: ["NAME"], deedPriceFields: ["SALE_PRICE"]),
        TitleRecorderSource(
            county: "yadkin", displayName: "Yadkin County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.yadkincountync.gov/arcgis/rest/services/BASIC_LOOKUP2/MapServer/2/query",
            // ROUND 15. County-OWNED host (gis.yadkincountync.gov). The tax_view_fc warehouse layer carries
            // split DEED_BOOK/DEED_PAGE, an epoch-ms DEED_DATE, owner NAME1 and a real recorded SALES_AMT.
            //
            // NON-UNIQUE-JOIN TRAP — the obvious key LIES here and the county is saved by a SECOND key, which
            // is why the key choice was proven rather than assumed. `PIN` is NOT unique: 28,169 distinct over
            // 28,341 rows, and all 139 colliding PINs DISAGREE on owner, situs, land/bldg value, sale amount
            // AND deed book/page/date — joining on PIN would attach a foreign parcel's deed, the exact Moore
            // fabrication. `PARCEL_NO` is a PROVEN BIJECTION over the full roll: 28,303 rows / 28,303 distinct
            // PARCEL_NO / ZERO collisions (enumerated, not spot-checked). So the recorder joins on PARCEL_NO
            // ONLY — PIN is deliberately NOT an OR-predicate, because a resolved PARCEL_NO must never fall
            // through to a key that collides.
            //
            // PAGING TRAP (worth recording — it nearly produced a false clean): this server caps a page at
            // 1,000 rows while advertising no maxRecordCount, so a pager that stops when it receives fewer
            // rows than its requested page size (2,000) silently reads only the FIRST 1,000 and "proves"
            // uniqueness over 3.5% of the roll. The enumeration above pages until EMPTY and reconciles to the
            // server's own distinct-OBJECTID count (28,341) before drawing any conclusion.
            // Live-verified 2026-07-14: PARCEL_NO 112794 (BLAKE FARMS OF NC LLC) deed 1054/0199,
            // 2012-07-05, $517,500.
            joinFields: ["PARCEL_NO"],
            outFields: ["PARCEL_NO", "NAME1", "DEED_BOOK", "DEED_PAGE", "DEED_DATE", "SALES_AMT"],
            orderBy: "DEED_DATE DESC",
            parcelLookupField: "PARCEL_NO",
            sourceLabel: "Yadkin County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DEED_BOOK", deedPageField: "DEED_PAGE", deedDateField: "DEED_DATE",
            deedOwnerFields: ["NAME1"], deedPriceFields: ["SALES_AMT"]),
        TitleRecorderSource(
            county: "burke", displayName: "Burke County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.burkenc.org/arcgis/rest/services/Parcels_VIEWER_MapImage_v3/MapServer/1/query",
            // ROUND 15. County-OWNED host (gis.burkenc.org). Split DEED_BOOK/DEED_PAGE + an epoch-ms
            // DEED_DATE + owner PROPERTY_OWNER. The layer publishes NO recorded sale price → deedPriceFields
            // is empty and the amount stays nil (honestly absent, never derived from the assessed value).
            //
            // NON-UNIQUE-JOIN TRAP — the KEY CHOICE is the whole decision: `PIN` collides on 174 values of
            // which 172 DISAGREE on owner/address/value/deed (a PIN join fabricates), while `REID` — the
            // county's own real-estate account id — collides on only 91 values and ALL 91 are byte-identical
            // across their rows on every displayed field (0 differing). So REID is joined and its multipart
            // re-prints collapse in parse()'s exact-identity pass; PIN is deliberately NOT an OR-predicate.
            // Live-verified 2026-07-14: REID 62 (SMITH, SHERRY LYNN PARLIER, 2640 BYRD RD).
            joinFields: ["REID"],
            outFields: ["REID", "PROPERTY_OWNER", "DEED_BOOK", "DEED_PAGE", "DEED_DATE"],
            orderBy: "DEED_DATE DESC",
            parcelLookupField: "REID",
            sourceLabel: "Burke County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DEED_BOOK", deedPageField: "DEED_PAGE", deedDateField: "DEED_DATE",
            deedOwnerFields: ["PROPERTY_OWNER"], deedPriceFields: []),   // no recorded price published
        TitleRecorderSource(
            county: "caldwell", displayName: "Caldwell County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.caldwellcountync.org/arcgis/rest/services/OpenGov/OpenGov/MapServer/1/query",
            // ROUND 15. County-OWNED host (gis.caldwellcountync.org), the same OpenGov shape Davidson uses.
            // Split DeedBook/DeedPage + owner AcctName1.
            //
            // DATE-DISCIPLINE (the Wilson precedent, applied): this layer publishes NO conveyance-date column
            // AT ALL — the TaxParcels schema carries DeedBook/DeedPage but nothing dated. So deedDateField is
            // EMPTY and the recorded date is honestly OMITTED rather than back-filled from an unrelated column
            // (the assessor's PlatBook/appraisal fields are NOT the deed date). A deed row with a real
            // book/page and no date is the truth here; inventing the date would be the fabrication.
            // Likewise no recorded price column → deedPriceFields empty, amount nil.
            //
            // NON-UNIQUE-JOIN TRAP — cleared by exhaustive enumeration: PID collides on 49 values over 52,756
            // rows (52,700 distinct) and for ALL 49 the rows are byte-identical on every displayed field
            // (owner, situs, market/land/building value, deed book/page) — 0 differing → identity collapse
            // yields one deed event per PID.
            //
            // CLOUDFLARE TRAP: this host sits behind Cloudflare and 403s a bare urllib/default User-Agent
            // while serving curl fine — a probe that reads that 403 as "no public feed" would refuse a
            // perfectly good county. The enumeration above sends a real browser UA.
            // Live-verified 2026-07-14: PID '04 9W159  8' (SMITH JENI B, 2193 PLAYMORE BEACH RD).
            joinFields: ["PID"],
            outFields: ["PID", "AcctName1", "DeedBook", "DeedPage"],
            orderBy: "PID ASC",              // no date column to order by → stable key order
            parcelLookupField: "PID",
            sourceLabel: "Caldwell County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedBookField: "DeedBook", deedPageField: "DeedPage",
            deedDateField: "",               // NO date published — honestly omitted (Wilson precedent)
            deedOwnerFields: ["AcctName1"], deedPriceFields: []),   // no recorded price published
        TitleRecorderSource(
            county: "jackson", displayName: "Jackson County, NC", state: "NC",
            shape: .parcelDeed,
            endpoint: "https://gis.jacksonnc.org/jcgis/rest/services/Tax_Admin/Parcels_Cached/FeatureServer/2/query",
            // ROUND 16 — the county round 15 pinned NEGATIVE on a WRONG REASON. It is not a dead backend:
            // round 15 probed the county's CMS host (jacksonnc.org/jcgis/, which 301s to www and answers
            // every path with homepage HTML). The county's OWN opendata DCAT names the real GIS host,
            // gis.jacksonnc.org — ArcGIS 10.81, valid cert, county-owned (the round-14 authoritative-host
            // rule is satisfied: this is the county's own domain, not an anonymous AGOL upload).
            //
            // ParcelLookup resolves Jackson's PIN (Tax_Admin/Parcels_Cached/2.PIN, dashed "7553-72-2318");
            // the recorder query hits the SAME parcel layer, which carries the recorded deed as a COMBINED
            // "book/page" TransferringRef (e.g. "2423/1464" — read via deedRefField like Orange's DEEDREF,
            // not the split DEED_BOOK/DEED_PAGE default) + owner CurrentOwner1 + a real recorded SalePrice
            // + an epoch-ms SaleDate.
            //
            // DATE DISCIPLINE (round-14 rule = "is there a SECOND, independent column that agrees?"):
            // SaleDate is a REAL conveyance date, corroborated by the layer's independent SaleDate_UTC —
            // they agree row-for-row (2016-08-17 ↔ 1471449600000). It is NOT a refresh stamp (Iredell) and
            // NOT corrupt (Wilson): the newest SaleDate across the roll is 2026-07-10, days before this
            // wiring — no impossible future years.
            //
            // NON-UNIQUE-JOIN TRAP — cleared by ENUMERATION, and notably this is the FIRST wired layer whose
            // objectIdField is non-null AND passes the oid sanity check (41,424 distinct OBJECTID == 41,424
            // rows), so the count-identity shortcut is legitimately available here. It was still not leaned
            // on: PIN is NOT a bijection (41,345 distinct / 41,424 rows), so all 27 colliding PINs were
            // enumerated — every one byte-identical on the displayed fields, 0 differing → the parser's
            // identity collapse yields exactly one deed event.
            // Live-verified 2026-07-15: PIN 7553-72-2318 → deed 2423/1464, sold $1,100,000 (CHAMBLISS, SCOTT A).
            joinFields: ["PIN"],
            outFields: ["PIN", "CurrentOwner1", "PropAddr", "TransferringRef", "SaleDate", "SalePrice",
                        "TotLandValue", "TotBldgValue", "TaxableValue"],
            orderBy: "SaleDate DESC",
            parcelLookupField: "PIN",
            sourceLabel: "Jackson County, NC — recorded deed (Register of Deeds, via tax parcel)",
            deedRefField: "TransferringRef", deedDateField: "SaleDate",
            deedOwnerFields: ["CurrentOwner1"], deedPriceFields: ["SalePrice"]),
    ]

    /// Dedicated MULTI-ROW sales/deed rolls (the `.saleRecords` shape) — a SEPARATE feed from `sources`
    /// above (which carry ONE most-recent recorded deed per parcel for the title chain). A sales roll
    /// returns EVERY recorded sale of a parcel over time, so its rows feed COMPS (real recorded price +
    /// date), fed through `CompsEngine.compsFromTitleChain`. Kept separate so the title-recorder count
    /// (19, above) stays a clean "counties with a recorded-deed title source", not conflated with comps.
    /// LIVE-VERIFIED 2026-07-14 (fixture Tests/fixtures/recorder/alamance_sales_history.json).
    ///
    /// ⚠️ ROUND 23 (2026-07-15) — **THIS LAYER IS NOT AN EVENT-LEVEL ROLL, AND JOINING IT ON `PIN`
    /// FABRICATED A PRICE.** Kept and RE-KEYED rather than deleted (evidence below), but the "sales
    /// history" name is the county's, not a description of the shape. See the round-23 audit section.
    static let salesRollSources: [TitleRecorderSource] = [
        TitleRecorderSource(
            county: "alamance", displayName: "Alamance County, NC", state: "NC",
            shape: .saleRecords,
            endpoint: "https://apps.alamance-nc.com/arcgis/rest/services/Tax/Sales_History/MapServer/0/query",
            // ROUND 23 RE-KEY: PIN → AKPAR_, and PIN *and* PID DROPPED from the predicate.
            //
            // THE DEFECT THIS FIXES IS A FABRICATED ARV — the number a buyer makes an offer on. The round-16
            // ambiguous-join gate is deliberately `.parcelDeed`-only, exempting `.saleRecords` because "many
            // rows per parcel is the layer's CORRECT semantic". That premise is FALSE for this layer, so the
            // exemption held the gate OPEN over a real §5.1 violation. The county's own server, live
            // 2026-07-15: 79,578 rows carrying 78,790 distinct AKPAR_ over 78,846 non-null — 99.93% of
            // accounts hold EXACTLY ONE row, and the row count matches the parcel layer's (79,580) to within
            // two. It is one row per parcel ACCOUNT, publishing the same AMDBOK/AMDPGE/AMSLAM/OWNAM1 columns
            // the parcel layer already carries. Its apparent multi-sale "history" WAS the PIN collision:
            //
            //   PIN 152135 →  AKPAR_ 152135  QUANDARY TRL      DESCO GC INVEST LLC            $0   (subject)
            //                 AKPAR_ 180784  1967 MALVINA CT   BATTLE DWIGHT & VICKIE BATTLE  $318,000
            //                 AKPAR_ 180954  2517 TREVANA WAY  BENNETT CHRISTOPHER JOHN       $331,000
            //
            // Three DIFFERENT PROPERTIES the county never re-PINed. CompsEngine drew ARV = median($318k,
            // $331k) = $324,500 and labelled it "the parcel's own recorded" history — two strangers' houses.
            // The subject's only recorded amount is $0. A test ASSERTED that $324,500 as "never fabricated";
            // the test was the bug, not the evidence.
            //
            // The re-key is PROVEN SAFE on this layer by the round-18/20/21 method: AKPAR_ has 52 colliding
            // groups and **0 DIFFERING** on the exact fields parse() renders (OWNAM1|AMSLAM|AMDTSL|AMDBOK|
            // AMDPGE|AMSALI), OID sanity checked (OBJECTID_1 non-null on all 79,578). Under AKPAR_ the
            // subject returns its OWN single row ($0 → DROPS → honest empty comps), never the neighbours'.
            //
            // ⚠️ RESIDUAL — CLOSED by STANDING RULE 17 (2026-07-15): because this layer is one-row-per-account,
            // a re-keyed pull can contribute AT MOST the parcel's OWN recorded sale — so a median over it is a
            // median of one. That is real, county-published, honestly-labelled data, and it can no longer
            // borrow anyone else's price; but a parcel's own past sale is a weak ARV basis. The genuine comps
            // basis for this county is the ordinary step-1 3-mi ring. Rule 17 answers "should an own-sale drive
            // ARV at all": CompsEngine.comps now (a) PREFERS the step-3 3-mi assessed AVM over a median-of-one,
            // and (b) otherwise DEMOTES the own-history figure from a green-seal `.soldCompsMedian` to a labeled
            // `.parcelOwnSaleAnchor` (isComp==false) — real recorded, but never worn as a neighborhood sold
            // comp. See CompsEngine step 1b + testRule17OwnHistoryAnchorDemotion.
            joinFields: ["AKPAR_"],
            outFields: ["AKPAR_", "PIN", "PID", "OWNAM1", "AMSLAM", "AMDTSL", "AMDBOK", "AMDPGE", "AMSALI"],
            orderBy: "AMDTSL DESC",
            parcelLookupField: "AKPAR_",
            sourceLabel: "Alamance County, NC — recorded sales history (Register of Deeds)",
            saleDescField: "AMSALI", saleRefField: "",
            saleBookField: "AMDBOK", salePageField: "AMDPGE",
            saleGrantorField: "", saleGranteeField: "OWNAM1",
            saleDateField: "AMDTSL", salePriceField: "AMSLAM", salePackedYMDDate: true),
    ]

    /// The built-in multi-row sales roll for a lead's county (state-guarded), or nil for none.
    static func salesRoll(county: String, state: String) -> TitleRecorderSource? {
        let key = normalize(county), st = state.uppercased()
        return salesRollSources.first { $0.county == key && (st.isEmpty || $0.state == st) }
    }

    /// A recorded multi-row sales roll usable for COMPS for this county — any `.saleRecords`-shape feed
    /// where each row is one recorded sale, so its priced+dated rows drive sold-comp ARV through
    /// `CompsEngine.compsFromTitleChain`. Drawn from BOTH the dedicated `salesRollSources` (Alamance's
    /// Tax/Sales_History) AND the `.saleRecords` entries already in `sources` (Cleveland's multi-row
    /// Vacant_ImprovedLot_Sales, Mecklenburg's TaxParcelSales) — the ONLY shape whose rows are an
    /// event-level sale HISTORY rather than one most-recent deed per parcel. A `.parcelDeed`/
    /// `.foreclosureFiling` source is never returned (a single deed per parcel isn't a comp set). nil =
    /// the county has no multi-row roll → the comps engine falls through to its other honest bases.
    static func compsRoll(county: String, state: String) -> TitleRecorderSource? {
        if let roll = salesRoll(county: county, state: state) { return roll }
        if let s = source(county: county, state: state), s.shape == .saleRecords { return s }
        return nil
    }

    /// Normalize a county name to its registry key: lowercased, "county" suffix + whitespace stripped
    /// (so "Guilford", "Guilford County", "  guilford  " all match one entry).
    static func normalize(_ county: String) -> String {
        var s = county.lowercased().trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(" county") { s = String(s.dropLast(" county".count)) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The built-in recorder source for a lead's county (state-guarded so a same-named county in
    /// another state never mis-binds). nil = no built-in coverage → honest empty / buyer-configured.
    static func source(county: String, state: String) -> TitleRecorderSource? {
        let key = normalize(county), st = state.uppercased()
        return sources.first { $0.county == key && (st.isEmpty || $0.state == st) }
    }
}
