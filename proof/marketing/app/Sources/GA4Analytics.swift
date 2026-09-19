// Black Label Marketing — live Google Analytics 4 Data API connector.
//
// This is a real reporting path, not an account-ID placeholder. The buyer supplies their own GA4
// numeric Property ID and authorizes with Google's desktop OAuth flow. Access + refresh credentials
// stay in the data-protection Keychain; report values are cached only after a successful API response.
// Every number is decoded from properties.runReport and retains its date range + channel source.
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GA4ChannelMetric: Codable, Equatable, Identifiable {
    var channel: String
    var sessions: Int?
    var users: Int?
    var keyEvents: Double?
    var pageViews: Int?
    var id: String { channel }
}

struct GA4AnalyticsResult: Codable, Equatable {
    var propertyID: String
    var sessions: Int?
    var users: Int?
    var keyEvents: Double?
    var pageViews: Int?
    var channels: [GA4ChannelMetric]
    var startDate: String
    var endDate: String
    var fetchedAt: Date
}

enum GA4ReportingWindow: Int, CaseIterable, Codable, Identifiable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }
    var label: String { "\(rawValue) days" }
    var currentStartDate: String { "\(rawValue)daysAgo" }
    var currentEndDate: String { "yesterday" }
    var previousStartDate: String { "\(rawValue * 2)daysAgo" }
    var previousEndDate: String { "\(rawValue + 1)daysAgo" }
}

struct GA4AnalyticsComparison: Codable, Equatable {
    var current: GA4AnalyticsResult
    var previous: GA4AnalyticsResult
    var window: GA4ReportingWindow

    static func percentChange(current: Double?, previous: Double?) -> Double? {
        guard let current, let previous, current.isFinite, previous.isFinite, previous > 0 else { return nil }
        return (current - previous) / previous
    }

    func percentChange(current: Int?, previous: Int?) -> Double? {
        Self.percentChange(current: current.map(Double.init), previous: previous.map(Double.init))
    }

    var sessionsChange: Double? { percentChange(current: current.sessions, previous: previous.sessions) }
    var usersChange: Double? { percentChange(current: current.users, previous: previous.users) }
    var keyEventsChange: Double? { Self.percentChange(current: current.keyEvents, previous: previous.keyEvents) }
    var pageViewsChange: Double? { percentChange(current: current.pageViews, previous: previous.pageViews) }

    func sessionsChange(for channel: String) -> Double? {
        let now = current.channels.first { $0.channel.caseInsensitiveCompare(channel) == .orderedSame }?.sessions
        let before = previous.channels.first { $0.channel.caseInsensitiveCompare(channel) == .orderedSame }?.sessions
        return percentChange(current: now, previous: before)
    }
}

/// Durable Google authorization created by the native desktop PKCE flow. The refresh token is never
/// written to UserDefaults or bundled into the app; the whole value lives in the Keychain.
struct GA4OAuthCredential: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var clientID: String
    var expiresAt: Date?
    var scope: String

    func needsRefresh(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }
}

enum GA4AnalyticsError: LocalizedError, Equatable {
    case invalidPropertyID
    case missingToken
    case missingClientID
    case refreshUnavailable
    case requestBuild
    case transport(String)
    case http(Int, String)
    case response(String)

    var errorDescription: String? {
        switch self {
        case .invalidPropertyID:
            return "Enter the numeric GA4 Property ID (for example 123456789), not the G- measurement ID."
        case .missingToken:
            return "Connect Google Analytics, or add an access token in Advanced setup."
        case .missingClientID:
            return "Add the Desktop app OAuth client ID from your Google Cloud project."
        case .refreshUnavailable:
            return "Google Analytics needs to reconnect because this authorization cannot be refreshed."
        case .requestBuild:
            return "The GA4 report request could not be built."
        case .transport(let detail):
            return "Could not reach Google Analytics (\(detail))."
        case .http(let status, let detail):
            if status == 401 { return "Google Analytics authorization expired or was revoked. Reconnect Google, then refresh." }
            if status == 403 {
                return detail.isEmpty
                    ? "Google denied this read. Confirm the token has analytics.readonly access and can open this GA4 property."
                    : "Google denied this read: \(detail)"
            }
            return detail.isEmpty ? "Google Analytics returned HTTP \(status)." : detail
        case .response(let detail):
            return detail
        }
    }
}

enum GA4AnalyticsConfig {
    static let lastResultKey = "ga4.analytics.lastResult"
    static let lastComparisonKey = "ga4.analytics.lastComparison"
    static let clientIDKey = "ga4.analytics.oauthClientID"
    private static var keychainBase: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").ga4",
            kSecAttrAccount as String: "analytics.readonly"
        ]
    }
    private static var oauthKeychainBase: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").ga4",
            kSecAttrAccount as String: "analytics.readonly.oauth"
        ]
    }

    static var clientID: String {
        get {
            let saved = UserDefaults.standard.string(forKey: clientIDKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !saved.isEmpty { return saved }
            let gmail = UserDefaults.standard.string(forKey: "GmailAPIClientID")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !gmail.isEmpty { return gmail }
            return (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { UserDefaults.standard.removeObject(forKey: clientIDKey) }
            else { UserDefaults.standard.set(value, forKey: clientIDKey) }
        }
    }

    static func setToken(_ raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { MarketingKeychain.delete(keychainBase) }
        else { MarketingKeychain.set(keychainBase, data: Data(token.utf8), accessible: kSecAttrAccessibleWhenUnlocked) }
    }

    static var manualToken: String? {
        guard let data = MarketingKeychain.copy(keychainBase, accessible: kSecAttrAccessibleWhenUnlocked,
                                                allowAuthenticationUI: false),
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }
    static var credential: GA4OAuthCredential? {
        guard let data = MarketingKeychain.copy(oauthKeychainBase, accessible: kSecAttrAccessibleWhenUnlocked,
                                                allowAuthenticationUI: false) else { return nil }
        return try? JSONDecoder().decode(GA4OAuthCredential.self, from: data)
    }
    static func saveCredential(_ credential: GA4OAuthCredential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        MarketingKeychain.set(oauthKeychainBase, data: data, accessible: kSecAttrAccessibleWhenUnlocked)
        clientID = credential.clientID
    }
    static var token: String? { credential?.accessToken ?? manualToken }
    static var hasRefreshableCredential: Bool {
        guard let credential, let refresh = credential.refreshToken else { return false }
        return !refresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static var hasToken: Bool { token != nil }

    static func disconnect() {
        MarketingKeychain.delete(oauthKeychainBase)
        MarketingKeychain.delete(keychainBase)
    }

    static func save(_ result: GA4AnalyticsResult) {
        if let data = try? JSONEncoder().encode(result) { UserDefaults.standard.set(data, forKey: lastResultKey) }
    }
    static var lastResult: GA4AnalyticsResult? {
        guard let data = UserDefaults.standard.data(forKey: lastResultKey) else { return nil }
        return try? JSONDecoder().decode(GA4AnalyticsResult.self, from: data)
    }
    static func save(_ comparison: GA4AnalyticsComparison) {
        if let data = try? JSONEncoder().encode(comparison) {
            UserDefaults.standard.set(data, forKey: lastComparisonKey)
            save(comparison.current)
        }
    }
    static var lastComparison: GA4AnalyticsComparison? {
        guard let data = UserDefaults.standard.data(forKey: lastComparisonKey) else { return nil }
        return try? JSONDecoder().decode(GA4AnalyticsComparison.self, from: data)
    }
    static func clearResult() {
        UserDefaults.standard.removeObject(forKey: lastResultKey)
        UserDefaults.standard.removeObject(forKey: lastComparisonKey)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum GA4Analytics {
    static let endpointRoot = "https://analyticsdata.googleapis.com/v1beta/properties"
    static let metricNames = ["sessions", "totalUsers", "keyEvents", "screenPageViews"]
    static let readonlyScope = "https://www.googleapis.com/auth/analytics.readonly"
    static let googleReadScopes = [readonlyScope, SearchConsoleAnalytics.readonlyScope]
    static var authorizationScope: String { googleReadScopes.joined(separator: " ") }
    static let authorizeEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    static func authorizeURL(clientID rawClientID: String, redirectURI: String,
                             state: String, codeChallenge: String) -> URL? {
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !redirectURI.isEmpty, !state.isEmpty, !codeChallenge.isEmpty else { return nil }
        var components = URLComponents(string: authorizeEndpoint)
        components?.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: authorizationScope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "include_granted_scopes", value: "true")
        ]
        return components?.url
    }

    static func tokenRequest(clientID rawClientID: String, redirectURI: String,
                             code: String, codeVerifier: String) -> URLRequest? {
        formRequest([
            .init(name: "client_id", value: rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code", value: code),
            .init(name: "code_verifier", value: codeVerifier),
            .init(name: "grant_type", value: "authorization_code")
        ])
    }

    static func refreshRequest(clientID rawClientID: String, refreshToken rawRefreshToken: String) -> URLRequest? {
        formRequest([
            .init(name: "client_id", value: rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)),
            .init(name: "refresh_token", value: rawRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)),
            .init(name: "grant_type", value: "refresh_token")
        ])
    }

    private static func formRequest(_ items: [URLQueryItem]) -> URLRequest? {
        guard items.allSatisfy({ !($0.value ?? "").isEmpty }), let url = URL(string: tokenEndpoint) else { return nil }
        var components = URLComponents(); components.queryItems = items
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    static func parseCredential(_ data: Data, clientID: String,
                                preservingRefreshToken: String? = nil,
                                preservingScope: String? = nil,
                                now: Date = Date()) throws -> GA4OAuthCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GA4AnalyticsError.response("Google returned an unreadable authorization response.")
        }
        if let message = root["error_description"] as? String ?? root["error"] as? String {
            throw GA4AnalyticsError.response(message)
        }
        guard let access = root["access_token"] as? String, !access.isEmpty else {
            throw GA4AnalyticsError.response("Google did not return an access token.")
        }
        let refresh = (root["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiresIn: Double? = (root["expires_in"] as? NSNumber)?.doubleValue
            ?? (root["expires_in"] as? String).flatMap(Double.init)
        return GA4OAuthCredential(accessToken: access,
                                  refreshToken: refresh?.isEmpty == false ? refresh : preservingRefreshToken,
                                  clientID: clientID,
                                  expiresAt: expiresIn.map { now.addingTimeInterval($0) },
                                  scope: (root["scope"] as? String) ?? preservingScope ?? authorizationScope)
    }

    static func refreshCredential(_ credential: GA4OAuthCredential,
                                  transport: OutboundTransport? = nil) async throws -> GA4OAuthCredential {
        guard let refresh = credential.refreshToken,
              let request = refreshRequest(clientID: credential.clientID, refreshToken: refresh) else {
            throw GA4AnalyticsError.refreshUnavailable
        }
        let data: Data; let response: URLResponse
        // Refreshing an access token talks to Google's token endpoint only, on the declared
        // `oauthTokenExchange` lane of the egress choke point.
        do { (data, response) = try await ConsentedEgress.sendUngated(request, lane: .oauthTokenExchange,
                                                                      via: transport) }
        catch { throw GA4AnalyticsError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else {
            throw GA4AnalyticsError.response("Google returned no authorization response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error_description"] as? String) ?? ($0["error"] as? String) } ?? ""
            throw GA4AnalyticsError.http(http.statusCode, detail)
        }
        let updated = try parseCredential(data, clientID: credential.clientID,
                                          preservingRefreshToken: refresh,
                                          preservingScope: credential.scope)
        GA4AnalyticsConfig.saveCredential(updated)
        return updated
    }

    static func authorizedToken(forceRefresh: Bool = false,
                                transport: OutboundTransport? = nil) async throws -> String {
        if let credential = GA4AnalyticsConfig.credential {
            if forceRefresh || credential.needsRefresh() {
                return try await refreshCredential(credential, transport: transport).accessToken
            }
            return credential.accessToken
        }
        guard let manual = GA4AnalyticsConfig.manualToken else { throw GA4AnalyticsError.missingToken }
        if forceRefresh { throw GA4AnalyticsError.refreshUnavailable }
        return manual
    }

    static func normalizePropertyID(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("properties/") { value.removeFirst("properties/".count) }
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    static func buildRequest(propertyID rawPropertyID: String, token rawToken: String,
                             startDate: String = "30daysAgo", endDate: String = "yesterday") throws -> URLRequest {
        guard let propertyID = normalizePropertyID(rawPropertyID) else { throw GA4AnalyticsError.invalidPropertyID }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GA4AnalyticsError.missingToken }
        guard let url = URL(string: "\(endpointRoot)/\(propertyID):runReport") else {
            throw GA4AnalyticsError.requestBuild
        }
        let body: [String: Any] = [
            "dateRanges": [["startDate": startDate, "endDate": endDate]],
            "dimensions": [["name": "sessionDefaultChannelGroup"]],
            "metrics": metricNames.map { ["name": $0] },
            "metricAggregations": ["TOTAL"],
            "orderBys": [["metric": ["metricName": "sessions"], "desc": true]],
            "limit": "12",
            "keepEmptyRows": false
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw GA4AnalyticsError.requestBuild
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = 30
        return request
    }

    static func parse(_ data: Data, propertyID rawPropertyID: String,
                      startDate: String, endDate: String, now: Date = Date()) throws -> GA4AnalyticsResult {
        guard let propertyID = normalizePropertyID(rawPropertyID) else { throw GA4AnalyticsError.invalidPropertyID }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GA4AnalyticsError.response("Google Analytics returned an unreadable response.")
        }
        if let error = root["error"] as? [String: Any] {
            let message = (error["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GA4AnalyticsError.response(message?.isEmpty == false ? message! : "Google Analytics rejected the report request.")
        }
        let headers = (root["metricHeaders"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        guard !headers.isEmpty else { throw GA4AnalyticsError.response("Google Analytics returned no metric headers.") }

        func values(_ object: [String: Any]) -> [String: Double] {
            let metricValues = object["metricValues"] as? [[String: Any]] ?? []
            var result: [String: Double] = [:]
            for (index, header) in headers.enumerated() where index < metricValues.count {
                if let raw = metricValues[index]["value"] as? String, let number = Double(raw), number.isFinite, number >= 0 {
                    result[header] = number
                }
            }
            return result
        }
        func integer(_ value: Double?) -> Int? {
            guard let value, value.isFinite, value >= 0, value <= Double(Int.max) else { return nil }
            return Int(value.rounded())
        }

        let totalValues = (root["totals"] as? [[String: Any]]).flatMap(\.first).map(values) ?? [:]
        let rows = root["rows"] as? [[String: Any]] ?? []
        let channels: [GA4ChannelMetric] = rows.compactMap { row in
            let dimensionValues = row["dimensionValues"] as? [[String: Any]] ?? []
            let rawChannel = (dimensionValues.first?["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rawChannel.isEmpty, rawChannel.uppercased() != "RESERVED_TOTAL" else { return nil }
            let rowValues = values(row)
            return GA4ChannelMetric(channel: rawChannel,
                                    sessions: integer(rowValues["sessions"]),
                                    users: integer(rowValues["totalUsers"]),
                                    keyEvents: rowValues["keyEvents"],
                                    pageViews: integer(rowValues["screenPageViews"]))
        }
        return GA4AnalyticsResult(propertyID: propertyID,
                                  sessions: integer(totalValues["sessions"]),
                                  users: integer(totalValues["totalUsers"]),
                                  keyEvents: totalValues["keyEvents"],
                                  pageViews: integer(totalValues["screenPageViews"]),
                                  channels: channels,
                                  startDate: startDate, endDate: endDate, fetchedAt: now)
    }

    static func pull(propertyID rawPropertyID: String, token: String,
                     startDate: String = "30daysAgo", endDate: String = "yesterday",
                     transport: OutboundTransport? = nil) async throws -> GA4AnalyticsResult {
        let result = try await performPull(propertyID: rawPropertyID, token: token,
                                           startDate: startDate, endDate: endDate, transport: transport)
        GA4AnalyticsConfig.save(result)
        return result
    }

    static func pullComparison(propertyID: String, token: String, window: GA4ReportingWindow,
                               transport: OutboundTransport? = nil) async throws -> GA4AnalyticsComparison {
        // Keep these sequential: a failed comparison never replaces the last complete comparison.
        let current = try await performPull(propertyID: propertyID, token: token,
                                            startDate: window.currentStartDate,
                                            endDate: window.currentEndDate, transport: transport)
        let previous = try await performPull(propertyID: propertyID, token: token,
                                             startDate: window.previousStartDate,
                                             endDate: window.previousEndDate, transport: transport)
        let comparison = GA4AnalyticsComparison(current: current, previous: previous, window: window)
        GA4AnalyticsConfig.save(comparison)
        return comparison
    }

    /// Refreshable connection path used by the app. A 401 triggers one refresh + one retry; a failed
    /// retry stays failed and never replaces the last verified comparison.
    static func pullComparison(propertyID: String, window: GA4ReportingWindow,
                               transport: OutboundTransport? = nil) async throws -> GA4AnalyticsComparison {
        let token = try await authorizedToken(transport: transport)
        do {
            return try await pullComparison(propertyID: propertyID, token: token, window: window, transport: transport)
        } catch GA4AnalyticsError.http(let status, _) where status == 401 && GA4AnalyticsConfig.hasRefreshableCredential {
            let refreshed = try await authorizedToken(forceRefresh: true, transport: transport)
            return try await pullComparison(propertyID: propertyID, token: refreshed, window: window, transport: transport)
        }
    }

    private static func performPull(propertyID rawPropertyID: String, token: String,
                                    startDate: String, endDate: String,
                                    transport: OutboundTransport?) async throws -> GA4AnalyticsResult {
        let request = try buildRequest(propertyID: rawPropertyID, token: token,
                                       startDate: startDate, endDate: endDate)
        let data: Data
        let response: URLResponse
        // The buyer's OWN Analytics property, read with the credential they connected — the
        // declared `ownAccountAPI` lane of the egress choke point.
        do { (data, response) = try await ConsentedEgress.sendUngated(request, lane: .ownAccountAPI,
                                                                      via: transport) }
        catch { throw GA4AnalyticsError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else {
            throw GA4AnalyticsError.response("Google Analytics returned no HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail: String = {
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let error = root["error"] as? [String: Any],
                      let message = error["message"] as? String else { return "" }
                return message
            }()
            throw GA4AnalyticsError.http(http.statusCode, detail)
        }
        return try parse(data, propertyID: rawPropertyID, startDate: startDate, endDate: endDate)
    }
}
#endif // circuit-convert
