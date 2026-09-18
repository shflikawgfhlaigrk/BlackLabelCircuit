// Black Label Marketing — live Google Search Console performance connector.
//
// Totals are queried without dimensions so a ranked top-query/page response is never mislabeled
// as the property's complete total. Ranked rows remain visibly bounded and source-dated.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct SearchConsoleSite: Codable, Equatable, Identifiable {
    var siteURL: String
    var permissionLevel: String
    var id: String { siteURL }
}

struct SearchConsoleMetricRow: Codable, Equatable, Identifiable {
    var key: String
    var clicks: Double
    var impressions: Double
    var ctr: Double
    var position: Double
    var id: String { key }
}

struct SearchConsoleAnalyticsResult: Codable, Equatable {
    var siteURL: String
    var clicks: Double
    var impressions: Double
    var ctr: Double
    var position: Double
    var queries: [SearchConsoleMetricRow]
    var pages: [SearchConsoleMetricRow]
    var startDate: String
    var endDate: String
    var fetchedAt: Date
}

struct SearchConsoleAnalyticsComparison: Codable, Equatable {
    var current: SearchConsoleAnalyticsResult
    var previous: SearchConsoleAnalyticsResult
    var window: GA4ReportingWindow

    static func percentChange(current: Double, previous: Double) -> Double? {
        guard current.isFinite, previous.isFinite, previous > 0 else { return nil }
        return (current - previous) / previous
    }

    var clicksChange: Double? { Self.percentChange(current: current.clicks, previous: previous.clicks) }
    var impressionsChange: Double? { Self.percentChange(current: current.impressions, previous: previous.impressions) }
    var ctrChange: Double? { Self.percentChange(current: current.ctr, previous: previous.ctr) }
    var positionChange: Double? {
        guard current.position.isFinite, previous.position.isFinite, previous.position > 0 else { return nil }
        // Lower average position is an improvement, so positive means better throughout the UI.
        return (previous.position - current.position) / previous.position
    }
}

struct SearchConsoleDateRange: Equatable {
    var currentStart: String
    var currentEnd: String
    var previousStart: String
    var previousEnd: String
}

enum SearchConsoleAnalyticsError: LocalizedError, Equatable {
    case invalidProperty
    case missingScope
    case requestBuild
    case transport(String)
    case http(Int, String)
    case response(String)
    /// The buyer has not allowed Google Search Console to receive data (or withdrew it, or the
    /// disclosure changed). Its own case so a refusal is never shown or retried as an outage.
    case consentRequired(String)

    var errorDescription: String? {
        switch self {
        case .invalidProperty:
            return "Choose an exact Search Console property (https://… URL-prefix or sc-domain:example.com)."
        case .missingScope:
            return "Reconnect Google to add Search Console read-only access."
        case .requestBuild:
            return "The Search Console request could not be built."
        case .transport(let detail):
            return "Could not reach Search Console (\(detail))."
        case .consentRequired(let refusal):
            return refusal
        case .http(let status, let detail):
            if status == 401 { return "Search Console authorization expired or was revoked. Reconnect Google, then refresh." }
            if status == 403 {
                return detail.isEmpty
                    ? "Google denied this read. Confirm this account can open the selected Search Console property."
                    : "Google denied this Search Console read: \(detail)"
            }
            return detail.isEmpty ? "Search Console returned HTTP \(status)." : detail
        case .response(let detail):
            return detail
        }
    }
}

enum SearchConsoleAnalyticsConfig {
    static let lastComparisonKey = "searchConsole.analytics.lastComparison"

    static func save(_ comparison: SearchConsoleAnalyticsComparison) {
        if let data = try? JSONEncoder().encode(comparison) {
            UserDefaults.standard.set(data, forKey: lastComparisonKey)
        }
    }

    static var lastComparison: SearchConsoleAnalyticsComparison? {
        guard let data = UserDefaults.standard.data(forKey: lastComparisonKey) else { return nil }
        return try? JSONDecoder().decode(SearchConsoleAnalyticsComparison.self, from: data)
    }

    static func clearResult() { UserDefaults.standard.removeObject(forKey: lastComparisonKey) }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum SearchConsoleAnalytics {
    static let readonlyScope = "https://www.googleapis.com/auth/webmasters.readonly"
    static let endpointRoot = "https://www.googleapis.com/webmasters/v3"
    static let topRowLimit = 10

    static func hasRequiredScope(_ credential: GA4OAuthCredential?) -> Bool {
        guard let credential else { return false }
        return Set(credential.scope.split(whereSeparator: \ .isWhitespace).map(String.init)).contains(readonlyScope)
    }

    static func normalizeProperty(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return nil }
        if value.hasPrefix("sc-domain:") {
            let domain = String(value.dropFirst("sc-domain:".count))
            return domain.contains(".") && !domain.contains("/") ? value : nil
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return value
    }

    static func encodedPropertyPath(_ raw: String) -> String? {
        guard let property = normalizeProperty(raw) else { return nil }
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return property.addingPercentEncoding(withAllowedCharacters: unreserved)
    }

    static func reportingRange(window: GA4ReportingWindow, now: Date = Date()) -> SearchConsoleDateRange {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = calendar.startOfDay(for: now)
        let currentEnd = calendar.date(byAdding: .day, value: -3, to: today)!
        let currentStart = calendar.date(byAdding: .day, value: -(window.rawValue - 1), to: currentEnd)!
        let previousEnd = calendar.date(byAdding: .day, value: -1, to: currentStart)!
        let previousStart = calendar.date(byAdding: .day, value: -(window.rawValue - 1), to: previousEnd)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return .init(currentStart: formatter.string(from: currentStart),
                     currentEnd: formatter.string(from: currentEnd),
                     previousStart: formatter.string(from: previousStart),
                     previousEnd: formatter.string(from: previousEnd))
    }

    static func listSitesRequest(token rawToken: String) throws -> URLRequest {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GA4AnalyticsError.missingToken }
        guard let url = URL(string: "\(endpointRoot)/sites") else { throw SearchConsoleAnalyticsError.requestBuild }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func queryRequest(siteURL rawSiteURL: String, token rawToken: String,
                             startDate: String, endDate: String,
                             dimension: String? = nil, rowLimit: Int = topRowLimit) throws -> URLRequest {
        guard let encoded = encodedPropertyPath(rawSiteURL), !startDate.isEmpty, !endDate.isEmpty else {
            throw SearchConsoleAnalyticsError.invalidProperty
        }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GA4AnalyticsError.missingToken }
        guard let url = URL(string: "\(endpointRoot)/sites/\(encoded)/searchAnalytics/query") else {
            throw SearchConsoleAnalyticsError.requestBuild
        }
        var body: [String: Any] = [
            "startDate": startDate,
            "endDate": endDate,
            "type": "web",
            "dataState": "final",
            "rowLimit": max(1, min(rowLimit, 25_000))
        ]
        if let dimension { body["dimensions"] = [dimension] }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw SearchConsoleAnalyticsError.requestBuild
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        return request
    }

    static func parseSites(_ data: Data) throws -> [SearchConsoleSite] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchConsoleAnalyticsError.response("Search Console returned an unreadable site list.")
        }
        try throwAPIError(root)
        return (root["siteEntry"] as? [[String: Any]] ?? []).compactMap { item in
            guard let raw = item["siteUrl"] as? String, let siteURL = normalizeProperty(raw) else { return nil }
            return SearchConsoleSite(siteURL: siteURL,
                                     permissionLevel: (item["permissionLevel"] as? String) ?? "unknown")
        }.sorted { $0.siteURL.localizedCaseInsensitiveCompare($1.siteURL) == .orderedAscending }
    }

    static func parseRows(_ data: Data) throws -> [SearchConsoleMetricRow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchConsoleAnalyticsError.response("Search Console returned unreadable performance data.")
        }
        try throwAPIError(root)
        return try (root["rows"] as? [[String: Any]] ?? []).map(parseRow)
    }

    private static func parseRow(_ row: [String: Any]) throws -> SearchConsoleMetricRow {
        func number(_ key: String) -> Double? {
            if let value = row[key] as? NSNumber { return value.doubleValue }
            if let value = row[key] as? String { return Double(value) }
            return nil
        }
        guard let clicks = number("clicks"), let impressions = number("impressions"),
              let ctr = number("ctr"), let position = number("position"),
              [clicks, impressions, ctr, position].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw SearchConsoleAnalyticsError.response("Search Console returned an invalid performance row.")
        }
        let key = (row["keys"] as? [String])?.first ?? "Total"
        return .init(key: key, clicks: clicks, impressions: impressions, ctr: ctr, position: position)
    }

    static func listSites(token: String, transport: OutboundTransport? = nil) async throws -> [SearchConsoleSite] {
        try await perform(request: listSitesRequest(token: token), transport: transport, parser: parseSites)
    }

    static func listSites(transport: OutboundTransport? = nil) async throws -> [SearchConsoleSite] {
        if let credential = GA4AnalyticsConfig.credential, !hasRequiredScope(credential) {
            throw SearchConsoleAnalyticsError.missingScope
        }
        let token = try await GA4Analytics.authorizedToken(transport: transport)
        do { return try await listSites(token: token, transport: transport) }
        catch SearchConsoleAnalyticsError.http(let status, _) where status == 401 && GA4AnalyticsConfig.hasRefreshableCredential {
            let refreshed = try await GA4Analytics.authorizedToken(forceRefresh: true, transport: transport)
            return try await listSites(token: refreshed, transport: transport)
        }
    }

    static func pullComparison(siteURL: String, window: GA4ReportingWindow,
                               now: Date = Date(), transport: OutboundTransport? = nil) async throws -> SearchConsoleAnalyticsComparison {
        if let credential = GA4AnalyticsConfig.credential, !hasRequiredScope(credential) {
            throw SearchConsoleAnalyticsError.missingScope
        }
        let token = try await GA4Analytics.authorizedToken(transport: transport)
        do { return try await pullComparison(siteURL: siteURL, token: token, window: window, now: now, transport: transport) }
        catch SearchConsoleAnalyticsError.http(let status, _) where status == 401 && GA4AnalyticsConfig.hasRefreshableCredential {
            let refreshed = try await GA4Analytics.authorizedToken(forceRefresh: true, transport: transport)
            return try await pullComparison(siteURL: siteURL, token: refreshed, window: window, now: now, transport: transport)
        }
    }

    static func pullComparison(siteURL rawSiteURL: String, token: String, window: GA4ReportingWindow,
                               now: Date = Date(), transport: OutboundTransport? = nil) async throws -> SearchConsoleAnalyticsComparison {
        guard let siteURL = normalizeProperty(rawSiteURL) else { throw SearchConsoleAnalyticsError.invalidProperty }
        let range = reportingRange(window: window, now: now)
        let current = try await pullPeriod(siteURL: siteURL, token: token, startDate: range.currentStart,
                                           endDate: range.currentEnd, now: now, transport: transport)
        let previous = try await pullPeriod(siteURL: siteURL, token: token, startDate: range.previousStart,
                                            endDate: range.previousEnd, now: now, transport: transport)
        let comparison = SearchConsoleAnalyticsComparison(current: current, previous: previous, window: window)
        SearchConsoleAnalyticsConfig.save(comparison)
        return comparison
    }

    private static func pullPeriod(siteURL: String, token: String, startDate: String, endDate: String,
                                   now: Date, transport: OutboundTransport?) async throws -> SearchConsoleAnalyticsResult {
        async let totalRows = fetchRows(siteURL: siteURL, token: token, startDate: startDate,
                                        endDate: endDate, dimension: nil, rowLimit: 1, transport: transport)
        async let queryRows = fetchRows(siteURL: siteURL, token: token, startDate: startDate,
                                        endDate: endDate, dimension: "query", rowLimit: topRowLimit, transport: transport)
        async let pageRows = fetchRows(siteURL: siteURL, token: token, startDate: startDate,
                                       endDate: endDate, dimension: "page", rowLimit: topRowLimit, transport: transport)
        let (totals, queries, pages) = try await (totalRows, queryRows, pageRows)
        let total = totals.first ?? .init(key: "Total", clicks: 0, impressions: 0, ctr: 0, position: 0)
        return .init(siteURL: siteURL, clicks: total.clicks, impressions: total.impressions,
                     ctr: total.ctr, position: total.position, queries: queries, pages: pages,
                     startDate: startDate, endDate: endDate, fetchedAt: now)
    }

    private static func fetchRows(siteURL: String, token: String, startDate: String, endDate: String,
                                  dimension: String?, rowLimit: Int, transport: OutboundTransport?) async throws -> [SearchConsoleMetricRow] {
        let request = try queryRequest(siteURL: siteURL, token: token, startDate: startDate,
                                       endDate: endDate, dimension: dimension, rowLimit: rowLimit)
        return try await perform(request: request, transport: transport, parser: parseRows)
    }

    private static func perform<T>(request: URLRequest, transport: OutboundTransport?,
                                   parser: (Data) throws -> T) async throws -> T {
        let data: Data; let response: URLResponse
        // Search Console reads carry the buyer's property name and their Google access token to
        // www.googleapis.com, so they leave through the egress choke point like every other
        // consent-requiring lane. `transport` stays injectable for tests.
        do { (data, response) = try await ConsentedEgress.send(request, to: .searchConsole,
                                                               via: transport) }
        catch let refusal as ConsentedEgressError { throw SearchConsoleAnalyticsError.consentRequired(refusal.errorDescription ?? "Nothing was sent.") }
        catch { throw SearchConsoleAnalyticsError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else {
            throw SearchConsoleAnalyticsError.response("Search Console returned no HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SearchConsoleAnalyticsError.http(http.statusCode, apiMessage(data))
        }
        return try parser(data)
    }

    private static func throwAPIError(_ root: [String: Any]) throws {
        if let error = root["error"] as? [String: Any] {
            let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SearchConsoleAnalyticsError.response(message?.isEmpty == false ? message! : "Search Console rejected the request.")
        }
    }

    private static func apiMessage(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any], let message = error["message"] as? String else { return "" }
        return message
    }
}
#endif // circuit-convert
