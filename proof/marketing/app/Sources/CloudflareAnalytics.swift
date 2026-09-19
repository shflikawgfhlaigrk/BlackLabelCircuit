// Black Label Marketing — Cloudflare Analytics connector (own-it, no paid analytics service).
//
// Founder directive (2026-07-03): the Analytics connector must PULL REAL traffic data from the
// buyer's OWN Cloudflare account — HTTP requests + page views — not just store an ID and display a
// stub. This is the app side of that: it resolves the buyer's zone, then POSTs to the Cloudflare
// GraphQL Analytics API (https://api.cloudflare.com/client/v4/graphql) for
//   • zone HTTP requests  → viewer.zones[].httpRequests1dGroups.sum.requests
//   • page views          → viewer.accounts[].rumPageloadEventsAdaptiveGroups.count  (Web Analytics)
//
// SHIP-NO-DATA / OWN-IT: the API token, Account ID, Zone (domain), and Web Analytics site tag ALL
// ship EMPTY. The buyer pastes their own scoped token (Analytics:Read) + IDs in Connectors →
// Analytics. The token lives ONLY in the data-protection Keychain, never in JSON, never in the
// shipped bundle. Real token = real numbers; when Web Analytics isn't enabled we surface an honest
// "enable Web Analytics for page views" state — we NEVER fabricate a request or page-view count.
//
// The networking is a thin async shell over PURE, unit-tested functions: the GraphQL query builder,
// the request builder, the zones-response zone-tag resolver, and the response parser (Tests/
// CloudflareAnalyticsTests.swift compiles this file and exercises those directly — no socket).
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - the pulled result (Codable so the dashboard can show the last real pull)

struct CFAnalyticsResult: Codable, Equatable {
    /// Honest page-view provenance — page views come ONLY from Web Analytics (RUM). If the buyer
    /// hasn't added a site tag, or Web Analytics returns nothing, we say so instead of inventing 0.
    enum PageViewsState: String, Codable { case value, noSiteTag, notAvailable }

    var requests: Int?          // total HTTP requests over the range; nil = not fetched / failed
    var pageViews: Int?         // total Web Analytics page views over the range; nil unless .value
    var pageViewsState: PageViewsState
    var rangeStart: String      // yyyy-MM-dd (inclusive)
    var rangeEnd: String        // yyyy-MM-dd (inclusive)
    var fetchedAt: Date
    var ok: Bool                // true only on a real 200 with a parseable zones payload
    var detail: String          // human status / the server's own error reason

    static func failure(_ detail: String, start: String, end: String) -> CFAnalyticsResult {
        CFAnalyticsResult(requests: nil, pageViews: nil, pageViewsState: .notAvailable,
                          rangeStart: start, rangeEnd: end, fetchedAt: Date(), ok: false, detail: detail)
    }
}

// MARK: - config (all fields ship EMPTY; buyer fills them in Connectors → Analytics)

enum CloudflareAnalyticsConfig {
    // UserDefaults keys (device-local, non-secret).
    static let accountIDKey = "cf.analytics.accountId"   // 32-hex Account ID
    static let zoneKey      = "cf.analytics.zone"        // the domain, e.g. acme.com (resolved → zoneTag)
    static let siteTagKey   = "cf.analytics.siteTag"     // Web Analytics site tag (optional; for page views)
    static let lastResultKey = "cf.analytics.lastResult" // cached JSON of the last successful pull

    // Keychain (the scoped API token; Bearer for the GraphQL + zones REST calls).
    private static var keychainService: String {
        "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").cfanalytics"
    }
    private static let keychainAccount = "graphql"
    private static var keychainBase: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    static var accountID: String {
        get { (UserDefaults.standard.string(forKey: accountIDKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: accountIDKey) }
            else { UserDefaults.standard.set(v, forKey: accountIDKey) }
        }
    }
    static var zone: String {
        get { (UserDefaults.standard.string(forKey: zoneKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces).lowercased()
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: zoneKey) }
            else { UserDefaults.standard.set(v, forKey: zoneKey) }
        }
    }
    static var siteTag: String {
        get { (UserDefaults.standard.string(forKey: siteTagKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: siteTagKey) }
            else { UserDefaults.standard.set(v, forKey: siteTagKey) }
        }
    }

    // MARK: the API token (Keychain, data-protection, on-device only)
    static func setToken(_ token: String) {
        let t = token.trimmingCharacters(in: .whitespaces)
        let base = keychainBase
        if t.isEmpty { MarketingKeychain.delete(base); return }
        MarketingKeychain.set(base, data: Data(t.utf8), accessible: kSecAttrAccessibleWhenUnlocked)
    }
    static var token: String? {
        let base = keychainBase
        guard let data = MarketingKeychain.copy(base, accessible: kSecAttrAccessibleWhenUnlocked,
                                                allowAuthenticationUI: false),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
    static var hasToken: Bool { token != nil }
    static var hasSavedTokenItem: Bool { MarketingKeychain.exists(keychainBase) }
    static var tokenNeedsReconnect: Bool { !hasToken && hasSavedTokenItem }
    static func migrateSavedToken() -> Bool {
        MarketingKeychain.migrate(keychainBase, accessible: kSecAttrAccessibleWhenUnlocked)
    }

    /// True only when every field needed for a real requests pull is present (page views also need a
    /// site tag, handled separately so its absence is an honest state, not a hard failure). Pure over
    /// its inputs so the UI chip and the pull agree.
    static func isConfigured(accountID: String, zone: String, hasToken: Bool) -> Bool {
        !accountID.trimmingCharacters(in: .whitespaces).isEmpty
            && !zone.trimmingCharacters(in: .whitespaces).isEmpty
            && hasToken
    }
    static var isConfigured: Bool { isConfigured(accountID: accountID, zone: zone, hasToken: hasToken) }

    // MARK: cache of the last successful pull (non-secret; lets the dashboard show real numbers)
    static func saveResult(_ r: CFAnalyticsResult) {
        if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: lastResultKey) }
    }
    static var lastResult: CFAnalyticsResult? {
        guard let d = UserDefaults.standard.data(forKey: lastResultKey) else { return nil }
        return try? JSONDecoder().decode(CFAnalyticsResult.self, from: d)
    }
    static func clearResult() { UserDefaults.standard.removeObject(forKey: lastResultKey) }
}

// MARK: - the GraphQL Analytics API (pure builders + parser + async transport)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum CloudflareAnalytics {
    static let graphQLEndpoint = "https://api.cloudflare.com/client/v4/graphql"

    /// Inclusive yyyy-MM-dd range ending today (UTC), spanning `days` days. Pure over `now`.
    static func dateRange(days: Int, now: Date = Date()) -> (start: String, end: String) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        let end = cal.startOfDay(for: now)
        let start = cal.date(byAdding: .day, value: -(max(1, days) - 1), to: end) ?? end
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return (f.string(from: start), f.string(from: end))
    }

    /// The GraphQL query text. Dates are self-generated (yyyy-MM-dd) so they're inlined safely; the
    /// zone/account/site tags are proper `$variables`. When `includePageViews` is false the page-view
    /// block AND its variables are omitted so the query stays valid (GraphQL forbids unused vars).
    static func graphQLQuery(includePageViews: Bool, start: String, end: String) -> String {
        let vars = includePageViews
            ? "$zoneTag: String!, $accountTag: String!, $siteTag: String!"
            : "$zoneTag: String!"
        var body = """
        query(\(vars)) {
          viewer {
            zones(filter: { zoneTag: $zoneTag }) {
              httpRequests1dGroups(limit: 366, filter: { date_geq: "\(start)", date_leq: "\(end)" }, orderBy: [date_ASC]) {
                dimensions { date }
                sum { requests }
              }
            }
        """
        if includePageViews {
            body += """

            accounts(filter: { accountTag: $accountTag }) {
              rumPageloadEventsAdaptiveGroups(limit: 366, filter: { date_geq: "\(start)", date_leq: "\(end)", siteTag: $siteTag }) {
                count
              }
            }
        """
        }
        body += "\n  }\n}"
        return body
    }

    /// Build the signed POST to the GraphQL endpoint. Returns nil only if the JSON body can't encode.
    static func buildRequest(token: String, query: String, variables: [String: String]) -> URLRequest? {
        guard let url = URL(string: graphQLEndpoint) else { return nil }
        let payload: [String: Any] = ["query": query, "variables": variables]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        req.timeoutInterval = 30
        return req
    }

    /// The REST endpoint that resolves a domain → zone id (the `zoneTag` the GraphQL API needs).
    static func zonesEndpoint(domain: String) -> URL? {
        let d = domain.trimmingCharacters(in: .whitespaces).lowercased()
        guard !d.isEmpty,
              let enc = d.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) else { return nil }
        return URL(string: "https://api.cloudflare.com/client/v4/zones?name=\(enc)&status=active")
    }

    /// Parse the zones REST response → the first zone id. Honest nil when the token can't see the
    /// zone or the domain isn't on this account (so the UI says "zone not found", never guesses).
    static func zoneTag(fromZonesJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["success"] as? Bool) == true,
              let result = obj["result"] as? [[String: Any]],
              let first = result.first,
              let id = first["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Parse the GraphQL Analytics response into a real, sourced result. Sums requests across the
    /// day-groups and page views across the RUM groups. Any GraphQL `errors`, or a missing zone,
    /// yields ok=false with the server's own reason — never a fabricated number.
    static func parse(_ data: Data, start: String, end: String,
                      requestedPageViews: Bool, now: Date = Date()) -> CFAnalyticsResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("Cloudflare returned an unreadable response.", start: start, end: end)
        }
        // GraphQL transport-level errors (bad token, bad query) come back in `errors`.
        if let errors = obj["errors"] as? [[String: Any]], !errors.isEmpty {
            let msg = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
            return .failure(msg.isEmpty ? "Cloudflare rejected the request." : msg, start: start, end: end)
        }
        guard let dataObj = obj["data"] as? [String: Any],
              let viewer = dataObj["viewer"] as? [String: Any] else {
            return .failure("Cloudflare returned no analytics data.", start: start, end: end)
        }
        guard let zones = viewer["zones"] as? [[String: Any]], let zone = zones.first else {
            return .failure("That token can't see this zone — check the Zone domain and the token's zone scope.",
                            start: start, end: end)
        }
        let groups = zone["httpRequests1dGroups"] as? [[String: Any]] ?? []
        let requests = groups.reduce(0) { acc, g in
            acc + ((g["sum"] as? [String: Any])?["requests"] as? Int ?? 0)
        }

        // Page views come only from Web Analytics (RUM). Absent block / no site tag = honest state.
        var pv: Int? = nil
        var pvState: CFAnalyticsResult.PageViewsState = .noSiteTag
        if requestedPageViews {
            if let accounts = viewer["accounts"] as? [[String: Any]], let acct = accounts.first,
               let rum = acct["rumPageloadEventsAdaptiveGroups"] as? [[String: Any]] {
                pv = rum.reduce(0) { $0 + (($1["count"] as? Int) ?? 0) }
                pvState = .value
            } else {
                pvState = .notAvailable   // token lacks account analytics, or Web Analytics not enabled
            }
        }

        return CFAnalyticsResult(requests: requests, pageViews: pv, pageViewsState: pvState,
                                 rangeStart: start, rangeEnd: end, fetchedAt: now, ok: true,
                                 detail: "Pulled from Cloudflare GraphQL Analytics.")
    }

    // MARK: async transport

    /// Resolve the buyer's domain to its zone id using their token.
    static func resolveZoneTag(token: String, domain: String) async -> String? {
        guard let url = zonesEndpoint(domain: domain) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        guard let (data, _) = try? await ConsentedEgress.sendUngated(req, lane: .ownAccountAPI) else { return nil }
        return zoneTag(fromZonesJSON: data)
    }

    /// One real pull: resolve zone → POST GraphQL → parse. `days` is the lookback window.
    /// Reads config for account/zone/site tag; the token is passed in (already read from Keychain).
    static func pull(token: String, accountID: String, zone: String, siteTag: String,
                     days: Int = 30) async -> CFAnalyticsResult {
        let (start, end) = dateRange(days: days)
        let t = token.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return .failure("Add your Cloudflare API token first.", start: start, end: end) }
        guard !zone.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure("Add your Zone (domain) first.", start: start, end: end)
        }
        guard let zoneTag = await resolveZoneTag(token: t, domain: zone) else {
            return .failure("Couldn't find zone “\(zone)” with this token — check the domain and that the token has Zone Analytics: Read.",
                            start: start, end: end)
        }
        let wantPV = !siteTag.trimmingCharacters(in: .whitespaces).isEmpty
        let query = graphQLQuery(includePageViews: wantPV, start: start, end: end)
        var vars = ["zoneTag": zoneTag]
        if wantPV { vars["accountTag"] = accountID; vars["siteTag"] = siteTag }
        guard let req = buildRequest(token: t, query: query, variables: vars) else {
            return .failure("Couldn't build the analytics request.", start: start, end: end)
        }
        guard let (data, resp) = try? await ConsentedEgress.sendUngated(req, lane: .ownAccountAPI) else {
            return .failure("Network error reaching Cloudflare.", start: start, end: end)
        }
        var result = parse(data, start: start, end: end, requestedPageViews: wantPV)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200, result.ok {
            result = .failure("Cloudflare returned HTTP \(http.statusCode).", start: start, end: end)
        }
        return result
    }

    /// Convenience: read the saved config + Keychain token, pull, and cache on success. Returns the
    /// result so the caller can chip/refresh the UI. Never caches a failure (keeps last-real-numbers).
    static func refresh(days: Int = 30) async -> CFAnalyticsResult {
        let r = await pull(token: CloudflareAnalyticsConfig.token ?? "",
                           accountID: CloudflareAnalyticsConfig.accountID,
                           zone: CloudflareAnalyticsConfig.zone,
                           siteTag: CloudflareAnalyticsConfig.siteTag,
                           days: days)
        if r.ok { CloudflareAnalyticsConfig.saveResult(r) }
        return r
    }
}
#endif // circuit-convert

private extension CharacterSet {
    /// URL-query-value-safe set (drops '&', '=', '+', etc. that would break the query string).
    static let urlQueryValueAllowed: CharacterSet = {
        var s = CharacterSet.urlQueryAllowed
        s.remove(charactersIn: "&=?+/ ")
        return s
    }()
}
