// Black Label Real Estate — Lead Database API client (the public-records query layer).
//
// Async URLSession client for the Cloudflare Worker at APIConfig.baseURL (~/BlackLabelRealEstateAPI,
// a Worker over the harvested public-records index; current counts are read live from /v1/stats).
//
// WHAT THIS IS (and isn't):
//   • It queries OUR harvested PUBLIC-RECORDS index by PUBLIC params only (state/county/owner/
//     address/city/zip/parcel). The data is public-records-PURE: owner name, situs + mailing
//     address, parcel id, assessed/land/improvement value, last sale price/date, lat/lng, source_url.
//     There is NO email / phone / skip-trace server-side — those never exist on a record here.
//   • It is LOCAL-FIRST safe: this client only ever SENDS public query params. A buyer's own CRM
//     leads / deals / PII are never serialized here and never POSTed. The only POST is CCPA-delete,
//     which sends just a requester + a match value the user typed.
//
// ZERO FABRICATION: every monetary / geo / date / text field on a record is OPTIONAL and decoded
// as-is. A missing field stays nil → the UI renders an honest empty/labeled state. On a network or
// decode failure the client THROWS (or returns an empty page for list calls) — it NEVER invents a
// record, a value, a coordinate, or a count.
//
// Auth: the Lead Database token (Keychain "blre.leadDBToken") is sent as `Authorization: Bearer`.
// No token = preview tier (25-row cap). The token only raises the row cap; it is never required.
//
// NAMING: the record type here is `PropertyRecord` — deliberately distinct from `ParcelRecord`
// (ParcelLookup.swift's live county-ArcGIS resolver result), which is a different shape/source.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Wire model (matches the Worker's record shape; ALL value fields optional)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// One property row from the Lead Database. Only `id` is treated as non-optional in practice;
/// every monetary / geo / date / text field is optional so a thin row decodes without fabrication.
struct PropertyRecord: Codable, Hashable, Identifiable {
    var id: String
    var source_id: String?
    var state: String?
    var county: String?
    var parcel_id: String?
    var owner_name: String?

    var situs_address: String?
    var situs_city: String?
    var situs_state: String?
    var situs_zip: String?

    var mailing_address: String?
    var mailing_city: String?
    var mailing_state: String?
    var mailing_zip: String?

    var assessed_value: Int?
    var land_value: Int?
    var improvement_value: Int?
    var last_sale_price: Int?
    var last_sale_date: String?

    var lat: Double?
    var lng: Double?

    var source_url: String?
    var harvested_at: String?

    // The Worker may return `id` as a number or a string, and money fields as number|string|null.
    // Decode tolerantly so a type wobble never drops a real row (and never fabricates one).
    enum CodingKeys: String, CodingKey {
        case id, source_id, state, county, parcel_id, owner_name
        case situs_address, situs_city, situs_state, situs_zip
        case mailing_address, mailing_city, mailing_state, mailing_zip
        case assessed_value, land_value, improvement_value, last_sale_price, last_sale_date
        case lat, lng, source_url, harvested_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = RealEstateAPI.decodeFlexString(c, .id) ?? ""
        source_id = RealEstateAPI.decodeFlexString(c, .source_id)
        state = RealEstateAPI.decodeFlexString(c, .state)
        county = RealEstateAPI.decodeFlexString(c, .county)
        parcel_id = RealEstateAPI.decodeFlexString(c, .parcel_id)
        owner_name = RealEstateAPI.decodeFlexString(c, .owner_name)
        situs_address = RealEstateAPI.decodeFlexString(c, .situs_address)
        situs_city = RealEstateAPI.decodeFlexString(c, .situs_city)
        situs_state = RealEstateAPI.decodeFlexString(c, .situs_state)
        situs_zip = RealEstateAPI.decodeFlexString(c, .situs_zip)
        mailing_address = RealEstateAPI.decodeFlexString(c, .mailing_address)
        mailing_city = RealEstateAPI.decodeFlexString(c, .mailing_city)
        mailing_state = RealEstateAPI.decodeFlexString(c, .mailing_state)
        mailing_zip = RealEstateAPI.decodeFlexString(c, .mailing_zip)
        assessed_value = RealEstateAPI.decodeFlexInt(c, .assessed_value)
        land_value = RealEstateAPI.decodeFlexInt(c, .land_value)
        improvement_value = RealEstateAPI.decodeFlexInt(c, .improvement_value)
        last_sale_price = RealEstateAPI.decodeFlexInt(c, .last_sale_price)
        last_sale_date = RealEstateAPI.decodeFlexString(c, .last_sale_date)
        lat = RealEstateAPI.decodeFlexDouble(c, .lat)
        lng = RealEstateAPI.decodeFlexDouble(c, .lng)
        source_url = RealEstateAPI.decodeFlexString(c, .source_url)
        harvested_at = RealEstateAPI.decodeFlexString(c, .harvested_at)
    }

    // Default member-wise init so callers/tests can build a record directly.
    init(id: String, source_id: String? = nil, state: String? = nil, county: String? = nil,
         parcel_id: String? = nil, owner_name: String? = nil,
         situs_address: String? = nil, situs_city: String? = nil, situs_state: String? = nil, situs_zip: String? = nil,
         mailing_address: String? = nil, mailing_city: String? = nil, mailing_state: String? = nil, mailing_zip: String? = nil,
         assessed_value: Int? = nil, land_value: Int? = nil, improvement_value: Int? = nil,
         last_sale_price: Int? = nil, last_sale_date: String? = nil,
         lat: Double? = nil, lng: Double? = nil, source_url: String? = nil, harvested_at: String? = nil) {
        self.id = id; self.source_id = source_id; self.state = state; self.county = county
        self.parcel_id = parcel_id; self.owner_name = owner_name
        self.situs_address = situs_address; self.situs_city = situs_city; self.situs_state = situs_state; self.situs_zip = situs_zip
        self.mailing_address = mailing_address; self.mailing_city = mailing_city; self.mailing_state = mailing_state; self.mailing_zip = mailing_zip
        self.assessed_value = assessed_value; self.land_value = land_value; self.improvement_value = improvement_value
        self.last_sale_price = last_sale_price; self.last_sale_date = last_sale_date
        self.lat = lat; self.lng = lng; self.source_url = source_url; self.harvested_at = harvested_at
    }

    var hasUsablePublicIdentity: Bool {
        let hasIdentity = [parcel_id, owner_name, situs_address, mailing_address].contains { field in
            field?.trimmedNonEmpty != nil
        }
        return !id.isEmpty &&
               hasIdentity &&
               state?.usableStateCode != nil &&
               county?.usableCountyName != nil
    }
}
#endif // circuit-convert

// MARK: - Endpoint envelopes (only the fields we read; tolerant of extras)

struct HealthResult: Codable, Hashable {
    var ok: Bool?
    var service: String?
    var properties: Int?
}

struct StatsResult: Codable, Hashable {
    var total_properties: Int?
    var suppressed: Int?
    var states: Int?
    var counties: Int?
}

struct CoverageEntry: Codable, Hashable, Identifiable {
    var state: String
    var counties: Int?
    var properties: Int?
    var id: String { state }
}
struct CoverageResult: Codable, Hashable {
    var states_covered: Int?
    var coverage: [CoverageEntry]
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// A paged result from /v1/search, /v1/parcel, /v1/owner — total/page/tier honestly surfaced.
struct PropertyPage: Codable, Hashable {
    var tier: String?
    var total: Int?
    var page: Int?
    var per_page: Int?
    var count: Int?
    var masked: Bool?
    var results: [PropertyRecord]

    static let empty = PropertyPage(tier: nil, total: 0, page: 1, per_page: 0, count: 0, masked: nil, results: [])

    enum CodingKeys: String, CodingKey {
        case tier, total, page, per_page, count, masked, results
    }

    init(tier: String?, total: Int?, page: Int?, per_page: Int?, count: Int?, masked: Bool?, results: [PropertyRecord]) {
        self.tier = tier
        self.total = total
        self.page = page
        self.per_page = per_page
        self.count = count
        self.masked = masked
        self.results = results.filter(\.hasUsablePublicIdentity)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        total = try c.decodeIfPresent(Int.self, forKey: .total)
        page = try c.decodeIfPresent(Int.self, forKey: .page)
        per_page = try c.decodeIfPresent(Int.self, forKey: .per_page)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        masked = try c.decodeIfPresent(Bool.self, forKey: .masked)
        results = (try c.decodeIfPresent([PropertyRecord].self, forKey: .results) ?? [])
            .filter(\.hasUsablePublicIdentity)
    }
}
#endif // circuit-convert

struct PropertyMapBounds: Hashable {
    var north: Double
    var south: Double
    var east: Double
    var west: Double
}

struct CCPADeleteResult: Codable, Hashable {
    var ok: Bool?
    var request_id: String?
    var status: String?
}

struct WorkspaceBlobEnvelope: Codable, Hashable {
    var name: String?
    var payload_base64: String?
    var updated_at: String?
}

struct WorkspaceWriteResult: Codable, Hashable {
    var ok: Bool?
    var name: String?
    var updated_at: String?
    var deleted: Int?
}

// MARK: - Errors

enum RealEstateAPIError: LocalizedError {
    case badURL
    case transport(String)
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad request URL."
        case .transport(let m): return "Couldn't reach the property database (\(m)). Nothing was invented."
        case .http(let code, let body):
            // A 4xx means the database answered and rejected the *query* (not a connectivity
            // problem). Surface the server's plain-English reason, never the raw JSON envelope.
            if (400...499).contains(code), let msg = Self.serverMessage(body) {
                return msg
            }
            if (500...599).contains(code) {
                return "The property database had a temporary problem (HTTP \(code)). Please try again in a moment."
            }
            return "The property database couldn't run that request (HTTP \(code))."
        case .decode(let m): return "The property database response wasn't understood (\(m))."
        }
    }

    /// A transport failure — the database was unreachable (offline, DNS, timeout). Distinct from a
    /// query the server understood and rejected, so the UI can show the right recovery.
    var isConnectivity: Bool { if case .transport = self { return true }; return false }

    /// A 4xx — the query itself was rejected (e.g. a filter needs a location). The buyer should
    /// adjust their inputs, not check their connection.
    var isBadRequest: Bool { if case .http(let code, _) = self { return (400...499).contains(code) }; return false }

    /// Pull the human `message` out of the Worker's `{"error":"…","message":"…"}` body. Falls back
    /// to a bare non-JSON body, else nil. Keeps raw JSON off the buyer's screen.
    private static func serverMessage(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let m = (obj["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
                return m.prefix(1).uppercased() + m.dropFirst()
            }
            if let e = (obj["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
                return e.replacingOccurrences(of: "_", with: " ").capitalized
            }
            return nil
        }
        // Non-JSON body — show it only if it reads like a sentence, not markup.
        return trimmed.first == "<" ? nil : String(trimmed.prefix(160))
    }
}

// MARK: - Client

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum RealEstateAPI {

    // The shared session; short timeout so the UI never hangs forever on an unreachable worker.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: Public endpoints

    /// GET /v1/health → {ok, service, properties}. Used by Settings "Test connection".
    static func health() async throws -> HealthResult {
        try await getJSON("/v1/health", query: [])
    }

    /// GET /v1/stats → {total_properties, suppressed, states, counties}.
    static func stats() async throws -> StatsResult {
        try await getJSON("/v1/stats", query: [])
    }

    /// GET /v1/coverage → {states_covered, coverage:[{state,counties,properties}]}.
    static func coverage() async throws -> CoverageResult {
        try await getJSON("/v1/coverage", query: [])
    }

    /// GET /v1/parcel?parcel_id=&state= → a page (usually 1 record). Honest empty page on failure.
    static func parcel(parcelId: String, state: String? = nil) async -> PropertyPage {
        var q = [URLQueryItem(name: "parcel_id", value: parcelId)]
        if let s = state?.trimmedNonEmpty { q.append(URLQueryItem(name: "state", value: s)) }
        return (try? await getJSON("/v1/parcel", query: q)) ?? .empty
    }

    /// GET /v1/search — any combination of public params. Honest empty page on failure (never fabricated).
    /// `query` is the free-text `q=`; the rest map to owner_name/address/city/zip/state/county filters.
    static func search(query: String? = nil, ownerName: String? = nil, address: String? = nil,
                       city: String? = nil, zip: String? = nil, state: String? = nil, county: String? = nil,
                       page: Int = 1, perPage: Int = 25) async -> PropertyPage {
        (try? await searchOrThrow(query: query, ownerName: ownerName, address: address,
                                  city: city, zip: zip, state: state, county: county,
                                  page: page, perPage: perPage)) ?? .empty
    }

    /// Throwing variant used by UI screens that must distinguish "no rows" from
    /// "database/API failed to load" instead of collapsing both into an empty page.
    static func searchOrThrow(query: String? = nil, ownerName: String? = nil, address: String? = nil,
                              city: String? = nil, zip: String? = nil, state: String? = nil, county: String? = nil,
                              page: Int = 1, perPage: Int = 25) async throws -> PropertyPage {
        var q: [URLQueryItem] = []
        if let v = query?.trimmedNonEmpty { q.append(.init(name: "q", value: v)) }
        if let v = ownerName?.trimmedNonEmpty { q.append(.init(name: "owner_name", value: v)) }
        if let v = address?.trimmedNonEmpty { q.append(.init(name: "address", value: v)) }
        if let v = city?.trimmedNonEmpty { q.append(.init(name: "city", value: v)) }
        if let v = zip?.trimmedNonEmpty { q.append(.init(name: "zip", value: v)) }
        if let v = state?.trimmedNonEmpty { q.append(.init(name: "state", value: v)) }
        if let v = county?.trimmedNonEmpty { q.append(.init(name: "county", value: v)) }
        q.append(.init(name: "page", value: String(max(1, page))))
        q.append(.init(name: "per_page", value: String(max(1, perPage))))
        return try await getJSON("/v1/search", query: q)
    }

    /// GET /v1/map — public-record map pins with real source lat/lng only.
    /// Optional viewport bounds keep the result scoped to the visible map; no
    /// coordinate is invented client- or server-side. `category` is one of the
    /// Worker's whitelisted honest list predicates (absentee / vacant_land / …)
    /// so a built list's pins are the SAME records the list counted.
    static func mapRecords(bounds: PropertyMapBounds? = nil, query: String? = nil,
                           state: String? = nil, county: String? = nil,
                           city: String? = nil, zip: String? = nil,
                           category: String? = nil,
                           minValue: Int? = nil, maxValue: Int? = nil,
                           soldAfter: String? = nil, soldBefore: String? = nil,
                           perPage: Int = 250) async throws -> PropertyPage {
        var q: [URLQueryItem] = []
        if let bounds {
            q.append(.init(name: "north", value: String(bounds.north)))
            q.append(.init(name: "south", value: String(bounds.south)))
            q.append(.init(name: "east", value: String(bounds.east)))
            q.append(.init(name: "west", value: String(bounds.west)))
        }
        if let v = query?.trimmedNonEmpty { q.append(.init(name: "q", value: v)) }
        if let v = state?.trimmedNonEmpty { q.append(.init(name: "state", value: v)) }
        if let v = county?.trimmedNonEmpty { q.append(.init(name: "county", value: v)) }
        if let v = city?.trimmedNonEmpty { q.append(.init(name: "city", value: v)) }
        if let v = zip?.trimmedNonEmpty { q.append(.init(name: "zip", value: v)) }
        if let v = category?.trimmedNonEmpty { q.append(.init(name: "category", value: v)) }
        if let mn = minValue, mn > 0 { q.append(.init(name: "min_value", value: String(mn))) }
        if let mx = maxValue, mx > 0 { q.append(.init(name: "max_value", value: String(mx))) }
        if let v = soldAfter?.trimmedNonEmpty { q.append(.init(name: "sold_after", value: v)) }
        if let v = soldBefore?.trimmedNonEmpty { q.append(.init(name: "sold_before", value: v)) }
        q.append(.init(name: "limit", value: String(max(1, perPage))))
        return try await getJSON("/v1/map", query: q)
    }

    /// GET /v1/search driven by a guided-list criteria's exact query items (the
    /// database-backed List Builder / Lot-Flip path). Throws so the UI can tell
    /// "no rows" from "the index is unreachable" — never collapses the two.
    static func listSearch(_ criteria: DatabaseListCriteria, page: Int = 1, perPage: Int = 25) async throws -> PropertyPage {
        try await getJSON("/v1/search", query: criteria.queryItems(page: page, perPage: perPage))
    }

    /// GET /v1/map for the same criteria — the list's pins are the list's records.
    static func listMap(_ criteria: DatabaseListCriteria, perPage: Int = 250) async throws -> PropertyPage {
        var q = criteria.queryItems()
        q.append(.init(name: "limit", value: String(max(1, perPage))))
        return try await getJSON("/v1/map", query: q)
    }

    /// GET /v1/owner?owner_name=&state= → the owner's full parcel portfolio. Honest empty on failure.
    static func owner(name: String, state: String? = nil) async -> PropertyPage {
        var q = [URLQueryItem(name: "owner_name", value: name)]
        if let s = state?.trimmedNonEmpty { q.append(URLQueryItem(name: "state", value: s)) }
        return (try? await getJSON("/v1/owner", query: q)) ?? .empty
    }

    /// POST /v1/ccpa-delete {requester, match_value}. Sends only the two fields the user typed.
    static func ccpaDelete(requester: String, matchValue: String) async throws -> CCPADeleteResult {
        try await postJSON("/v1/ccpa-delete", body: ["requester": requester, "match_value": matchValue])
    }

    // MARK: Subscriber workspace bridge — BUILT, AUTHENTICATED, AND DELIBERATELY UNWIRED
    //
    // 🚨 DO NOT WIRE `writeWorkspaceBlob` UP. It PUTs the buyer's workspace blob to /v1/workspace
    // under their `Authorization: Bearer` key, i.e. it uploads their CRM to a Black Label server.
    // Today it has ZERO callers anywhere in Sources/, which is the ONLY reason these two shipped
    // claims are true:
    //   • the buyer-facing copy in TrialGate.swift / REStore.swift / Screens.swift —
    //     "Your workspace is never uploaded to Black Label"
    //   • Sources/PrivacyInfo.xcprivacy, which declares no workspace/CRM transfer
    // The first call site turns both into a lie and the app into a mis-declared App Store binary.
    //
    // This is not an honour-system comment: `testNoWorkspaceUploadClaimGuard()` in
    // Tests/EngineTests.swift fails RED if `writeWorkspaceBlob` gains a caller (or if any file
    // outside this one hand-rolls a /v1/workspace request) while the never-uploaded copy still
    // ships. To legitimately enable workspace sync you must, in the same change: delete/replace
    // that copy, declare the transfer in the privacy manifest, and update that guard test.
    /// Subscriber workspace blob stored in Postgres by the API. Requires a Lead Database token.
    /// READ-side only download; see the DO-NOT-WIRE note above before adding any caller.
    static func readWorkspaceBlob(named name: String) async throws -> Data? {
        do {
            let envelope: WorkspaceBlobEnvelope = try await getJSON("/v1/workspace/\(workspacePathName(name))", query: [])
            guard let raw = envelope.payload_base64 else { return nil }
            return Data(base64Encoded: raw)
        } catch RealEstateAPIError.http(let code, _) where code == 404 {
            return nil
        }
    }

    /// 🚨 THE UPLOAD. Callers: NONE, by contract — see the DO-NOT-WIRE note above and
    /// `testNoWorkspaceUploadClaimGuard()`.
    static func writeWorkspaceBlob(_ data: Data, named name: String) async throws {
        let _: WorkspaceWriteResult = try await postJSON("/v1/workspace/\(workspacePathName(name))",
                                                         method: "PUT",
                                                         body: ["payload_base64": data.base64EncodedString()])
    }

    static func deleteWorkspaceBlob(named name: String) async throws {
        let _: WorkspaceWriteResult = try await deleteJSON("/v1/workspace/\(workspacePathName(name))")
    }

    // MARK: Transport

    private static func makeURL(_ path: String, query: [URLQueryItem]) -> URL? {
        guard var comps = URLComponents(url: APIConfig.baseURL.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        return comps.url
    }

    private static func authorize(_ req: inout URLRequest) {
        req.setValue("BlackLabelRealEstate/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = Keychain.leadDBToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func getJSON<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        guard let url = makeURL(path, query: query) else { throw RealEstateAPIError.badURL }
        var req = URLRequest(url: url); req.httpMethod = "GET"; authorize(&req)
        return try await run(req)
    }

    private static func postJSON<T: Decodable>(_ path: String, method: String = "POST", body: [String: String]) async throws -> T {
        guard let url = makeURL(path, query: []) else { throw RealEstateAPIError.badURL }
        var req = URLRequest(url: url); req.httpMethod = method; authorize(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return try await run(req)
    }

    private static func deleteJSON<T: Decodable>(_ path: String) async throws -> T {
        guard let url = makeURL(path, query: []) else { throw RealEstateAPIError.badURL }
        var req = URLRequest(url: url); req.httpMethod = "DELETE"; authorize(&req)
        return try await run(req)
    }

    private static func workspacePathName(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
    }

    private static func run<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw RealEstateAPIError.transport(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw RealEstateAPIError.transport("no response") }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RealEstateAPIError.http(http.statusCode, String(body.prefix(200)))
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw RealEstateAPIError.decode(error.localizedDescription) }
    }

    // MARK: Flexible decode helpers (number-or-string-or-null from the Worker)

    static func decodeFlexString(_ c: KeyedDecodingContainer<PropertyRecord.CodingKeys>,
                                 _ key: PropertyRecord.CodingKeys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s.trimmedNonEmpty }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }
    static func decodeFlexInt(_ c: KeyedDecodingContainer<PropertyRecord.CodingKeys>,
                              _ key: PropertyRecord.CodingKeys) -> Int? {
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i > 0 ? i : (i == 0 ? nil : i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { let n = Int(d); return n > 0 ? n : nil }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            let cleaned = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
            if let d = Double(cleaned) { let n = Int(d); return n > 0 ? n : nil }
        }
        return nil
    }
    static func decodeFlexDouble(_ c: KeyedDecodingContainer<PropertyRecord.CodingKeys>,
                                 _ key: PropertyRecord.CodingKeys) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return Double(i) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key), let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
        return nil
    }
}
#endif // circuit-convert

private extension String {
    /// Trimmed, or nil if the trimmed string is empty / a NULL sentinel — so blanks never masquerade as data.
    var trimmedNonEmpty: String? {
        var t = replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        while t.count >= 2 && t.first == "\"" && t.last == "\"" {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        t = t.replacingOccurrences(of: "\"", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        while t.last == "," { t = String(t.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        let invalid = ["", "0", "null", "<null>", "n/a", "na", "unknown", "undefined"]
        let lower = t.lowercased()
        let alphaNum = lower.filter { $0.isLetter || $0.isNumber }
        if ["confidential", "redacted", "withheld", "ownernamewithheld"].contains(alphaNum) { return nil }
        if invalid.contains(lower) { return nil }
        return t
    }

    var usableStateCode: String? {
        guard let t = trimmedNonEmpty?.uppercased(), t.count == 2, t.allSatisfy({ $0.isLetter }) else { return nil }
        return t
    }

    var usableCountyName: String? {
        guard let t = trimmedNonEmpty, !t.allSatisfy({ $0.isNumber }) else { return nil }
        return t
    }
}
