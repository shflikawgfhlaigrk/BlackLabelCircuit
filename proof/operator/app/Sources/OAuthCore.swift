// Sovereign — SHARED OAuth 2.0 sign-in core (Authorization Code + PKCE, RFC-compliant remote-MCP
// connect). This is the one engine every OAuth connector reuses (Linear, then Slack / Google / OneDrive
// in later units): there is ONE flow, ONE token store, ONE PKCE impl — no per-provider duplication.
//
// WHY ASWebAuthenticationSession (not a loopback listener): the Mac App Store build is app-sandboxed
// and has NO `network.server` entitlement, so it cannot open a loopback socket to catch the redirect.
// ASWebAuthenticationSession registers the app's custom URL scheme with the system and hands the
// redirect back directly — it works in BOTH the sandboxed App Store build and the Developer-ID build.
//
// HONESTY (CHARTER §5.1 / §5.2):
//   • Ships EMPTY. No client_id, no token, no secret is bundled. A connector is "connected" only after
//     a REAL token exchange returns a REAL access_token and a REAL tools/list round-trip succeeds.
//   • The access_token + refresh_token live ONLY in Sovereign's private credential store (OAuthTokenStore, via
//     ConnectorSecrets) — never on disk, never in mcp.json, never logged.
//   • The client_id (public, non-secret — DCR-registered or buyer-pasted) lives in UserDefaults
//     (OAuthClientStore), alongside the discovered token endpoint so a refresh is self-contained.
import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(AuthenticationServices) && !CIRCUIT_WINDOWS_SIM
import AuthenticationServices
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OAuthParams — the per-connector OAuth description carried on a ConnectorEntry

/// How a connector forms its OAuth redirect_uri. Most providers (Linear, Slack) register a single
/// static custom scheme (`sovereign://callback`). Google's native/installed-app flow instead requires
/// the redirect to be the buyer's REVERSED client-id custom scheme, derived per-connection from the
/// resolved client_id — so it can't be a fixed string. ASWebAuthenticationSession registers whichever
/// scheme we hand it transiently, so no Info.plist entry is needed for the dynamic Google scheme.
enum RedirectStyle: String, Hashable, Codable {
    case staticScheme            // Linear / Slack — use redirectScheme + redirectPath verbatim
    case googleReversedClientID  // Google — derive the scheme + redirect_uri from the client_id
}

/// Pure DATA describing how one provider does OAuth. Static endpoints are a FALLBACK; when the server
/// advertises RFC 9728 protected-resource metadata + RFC 8414 authorization-server metadata, those are
/// discovered live and win. `resourceIndicator` (RFC 8707) scopes the token to the MCP endpoint.
struct OAuthParams: Hashable, Codable {
    var authorizationEndpoint: String? = nil          // static fallback if discovery 404s
    var tokenEndpoint: String? = nil                  // static fallback if discovery 404s
    var asMetadataURL: String? = nil                  // explicit RFC 8414 metadata URL (else derived)
    var protectedResourceMetadataURL: String? = nil   // explicit RFC 9728 metadata URL (else derived)
    var registrationEndpoint: String? = nil           // static RFC 7591 /register (else discovered)
    var supportsDCR: Bool = false                     // server does RFC 7591 dynamic client registration
    var clientIDRequired: Bool = true                 // buyer must paste a client_id (false when DCR)
    var scopes: [String] = []
    var redirectScheme: String = "sovereign"          // custom URL scheme registered in Info.plist
    var redirectPath: String = "callback"             // -> redirect_uri "<scheme>://<path>"
    var redirectStyle: RedirectStyle = .staticScheme  // how redirect_uri is formed (Google derives it)
    var usesPKCE: Bool = true
    var extraAuthParams: [String: String] = [:]       // provider-specific authorize-URL params
    var resourceIndicator: String? = nil              // RFC 8707 — usually == the MCP endpointURL

    /// The redirect_uri this connector hands the authorization server, e.g. "sovereign://callback".
    var redirectURI: String { "\(redirectScheme)://\(redirectPath)" }
}

// MARK: - PKCE — the single Proof-Key-for-Code-Exchange impl (factored out of GoogleSignIn)

/// RFC 7636 PKCE helpers + x-www-form-urlencoded encoding. ONE implementation the whole app shares:
/// GoogleSignIn and OAuthConnector both call these (no duplicated crypto). codeChallenge = base64url(
/// SHA256(verifier)), method S256.
enum PKCE {
    /// A cryptographically-random URL-safe string (base64url, no padding). Used for the code_verifier
    /// (43–128 chars per RFC 7636 — 64 random bytes → 86 chars, all in the allowed set) and for state.
    static func randomURLSafe(_ count: Int = 64) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    /// S256 code challenge: base64url(SHA256(verifier)), no padding.
    static func challengeS256(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// base64 → base64url, padding stripped (`+`→`-`, `/`→`_`, drop `=`).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Percent-encode one form value for application/x-www-form-urlencoded.
    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Encode a full form body (sorted for determinism → unit-testable).
    static func formBody(_ params: [String: String]) -> Data {
        params.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}

// MARK: - Token + client stores

/// The OAuth sidecar persisted next to the access token (refresh token + expiry + scope), private-store only.
struct OAuthTokens: Codable, Equatable {
    var refreshToken: String?
    var expiresAt: Date?
    var scope: String?
    var tokenType: String?
}

/// Prompt-free OAuth token store, layered on ConnectorSecrets so the SAME `resolvedHeaders()` path
/// the token connectors use sends `Bearer <access_token>` UNCHANGED. The bare access_token is stored
/// under private-store account `<id>` (what MCPServerConfig.resolvedHeaders reads); the refresh sidecar lives
/// under `<id>.oauth`. Nothing here is ever written to disk or mcp.json.
enum OAuthTokenStore {
    /// Private-store account holding the OAuth sidecar (refresh token + expiry) for a connector.
    static func sidecarAccount(_ connectorID: String) -> String { "\(connectorID).oauth" }

    /// Persist a freshly-exchanged (or refreshed) token set: access under `<id>`, sidecar under `<id>.oauth`.
    @discardableResult
    static func save(connectorID: String, accessToken: String, refreshToken: String?,
                     expiresIn: Int?, scope: String?, tokenType: String?) -> Bool {
        let previousAccess = ConnectorSecrets.token(forAccount: connectorID)
        let sidecarID = sidecarAccount(connectorID)
        let previousSidecar = ConnectorSecrets.token(forAccount: sidecarID)
        let sidecar = OAuthTokens(refreshToken: refreshToken,
                                  expiresAt: expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                                  scope: scope, tokenType: tokenType)
        guard let data = try? JSONEncoder().encode(sidecar),
              let encodedSidecar = String(data: data, encoding: .utf8),
              ConnectorSecrets.store(account: connectorID, token: accessToken),
              ConnectorSecrets.token(forAccount: connectorID) == accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
              ConnectorSecrets.store(account: sidecarID, token: encodedSidecar),
              ConnectorSecrets.token(forAccount: sidecarID) == encodedSidecar else {
            // Transactional rollback: a failed two-file update never discards the previous usable set.
            if let previousAccess { _ = ConnectorSecrets.store(account: connectorID, token: previousAccess) }
            else { ConnectorSecrets.delete(account: connectorID) }
            if let previousSidecar { _ = ConnectorSecrets.store(account: sidecarID, token: previousSidecar) }
            else { ConnectorSecrets.delete(account: sidecarID) }
            return false
        }
        return true
    }

    static func accessToken(connectorID: String) -> String? { ConnectorSecrets.token(forAccount: connectorID) }

    static func sidecar(connectorID: String) -> OAuthTokens? {
        guard let s = ConnectorSecrets.token(forAccount: sidecarAccount(connectorID)),
              let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    static func refreshToken(connectorID: String) -> String? { sidecar(connectorID: connectorID)?.refreshToken }

    /// Remove both the access token and the refresh sidecar (disconnect).
    static func delete(connectorID: String) {
        ConnectorSecrets.delete(account: connectorID)
        ConnectorSecrets.delete(account: sidecarAccount(connectorID))
    }
}

/// Non-secret OAuth client state in UserDefaults: the client_id (public — DCR-registered or buyer-pasted)
/// and the discovered token endpoint (so refresh is self-contained without re-running discovery).
/// Mirrors Settings.googleClientID's "the buyer's own non-secret client id lives on-device" pattern.
enum OAuthClientStore {
    private static var d: UserDefaults { .standard }
    static let keyPrefix = "com.blacklabel.sovereign.oauth."
    private static let settingsKey = "com.blacklabel.sovereign.settings.v1"
    private static let googleConnectorIDs: Set<String> = ["gmail", "gdrive", "gcal"]

    private static func key(_ id: String, _ field: String) -> String { "\(keyPrefix)\(id).\(field)" }

    static func clientID(_ id: String) -> String? {
        let v = (d.string(forKey: key(id, "client_id")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { return v }
        return googleClientIDFallback(for: id)
    }

    private static func googleClientIDFallback(for id: String) -> String? {
        guard googleConnectorIDs.contains(id) else { return nil }

        if let fromSettings = googleClientIDFromSovereignSettings() { return fromSettings }

        if let fromOwnDefaults = validGoogleClientID(d.string(forKey: "GoogleClientID") ?? "") {
            return fromOwnDefaults
        }

        let bundleValue = (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String) ?? ""
        if let cleaned = validGoogleClientID(bundleValue) { return cleaned }

        // No cross-product suite fallback: borrowing another app's client id only ever "worked" on
        // the dev machine, and it masks ships-empty verification. A buyer pastes their own id.
        return nil
    }

    private struct SovereignSettingsOAuthSnapshot: Decodable {
        var googleClientID: String?
    }

    private static func googleClientIDFromSovereignSettings() -> String? {
        guard let data = d.data(forKey: settingsKey),
              let snapshot = try? JSONDecoder().decode(SovereignSettingsOAuthSnapshot.self, from: data) else {
            return nil
        }
        return validGoogleClientID(snapshot.googleClientID ?? "")
    }

    private static func validGoogleClientID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(".apps.googleusercontent.com"),
              trimmed.count > ".apps.googleusercontent.com".count else {
            return nil
        }
        return trimmed
    }

    static func setClientID(_ id: String, _ clientID: String) {
        d.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key(id, "client_id"))
    }
    static func tokenEndpoint(_ id: String) -> String? {
        let v = (d.string(forKey: key(id, "token_endpoint")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
    static func setTokenEndpoint(_ id: String, _ url: String) {
        d.set(url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key(id, "token_endpoint"))
    }

    /// Forget one connector's client state (disconnect).
    static func clear(_ id: String) {
        d.removeObject(forKey: key(id, "client_id"))
        d.removeObject(forKey: key(id, "token_endpoint"))
    }

    /// Forget EVERY connector's OAuth client state (delete-all). Scans the defaults for the prefix so a
    /// new connector never has to be hand-registered in a wipe list.
    static func wipeAll() {
        for k in d.dictionaryRepresentation().keys where k.hasPrefix(keyPrefix) {
            d.removeObject(forKey: k)
        }
    }
}

// MARK: - The OAuth flow engine

enum OAuthError: Error, LocalizedError {
    case notConfigured
    case discoveryFailed
    case clientIDRequired
    case registrationFailed(String)
    case badAuthorizeURL
    case userCancelled
    case badRedirect
    case cannotPresent
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:           return "This connector isn't configured for OAuth."
        case .discoveryFailed:         return "Couldn't discover this provider's OAuth endpoints. Check your connection and try again."
        case .clientIDRequired:        return "This provider needs a client ID. Paste the one from your provider app."
        case .registrationFailed(let m): return "Couldn't register with the provider: \(m)"
        case .badAuthorizeURL:         return "Couldn't build the sign-in URL."
        case .userCancelled:           return "Sign-in was cancelled."
        case .badRedirect:             return "The provider returned an unexpected sign-in response. Please try again."
        case .cannotPresent:           return "Couldn't open the sign-in window. Please try again."
        case .tokenExchangeFailed(let m): return "Sign-in didn't complete: \(m)"
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Drives the Authorization-Code-with-PKCE flow for a catalog connector and persists the result. The
/// interactive `connect` runs on the main actor (it presents a system web-auth window); `refresh` is
/// nonisolated so the MCP I/O layer (a value-type struct, off the main actor) can renew a token on a 401.
@MainActor
final class OAuthConnector: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    // nonisolated so the off-main-actor MCP I/O layer can reach `.shared.refresh(...)` on a 401.
    // The compiler can prove this is safe (no `unsafe` needed): the type is Sendable — a `@MainActor`
    // class — and `shared` is an immutable `let`, so a nonisolated read carries no data race. The
    // singleton holds no mutable shared state read off the main actor (refresh touches only the
    // nonisolated private-file/UserDefaults stores + the network).
    nonisolated static let shared = OAuthConnector()

    private var webSession: ASWebAuthenticationSession?

    nonisolated override init() { super.init() }

    // MARK: Interactive connect (main actor — presents the system sign-in sheet)

    /// Run the full flow for `entry` and return the access_token (also persisted privately).
    /// Throws an honest OAuthError at every failure point — never returns a faked "connected".
    func connect(_ entry: ConnectorEntry) async throws -> String {
        guard let oauth = entry.oauth, let endpoint = entry.endpointURL, !endpoint.isEmpty else {
            throw OAuthError.notConfigured
        }
        let resource = oauth.resourceIndicator ?? endpoint

        // 1. Discover endpoints (RFC 9728 → 8414), falling back to the static OAuthParams on 404.
        let ep = await Self.discoverEndpoints(oauth: oauth, resource: resource)
        guard let authzEndpoint = ep.authorization, let tokenEndpoint = ep.token else {
            throw OAuthError.discoveryFailed
        }

        // 2. Resolve client_id: stored/pasted first, else DCR (RFC 7591) when the server supports it.
        var clientID = OAuthClientStore.clientID(entry.id)
        if clientID == nil, oauth.supportsDCR, let regEndpoint = ep.registration {
            let cid = try await Self.registerClient(registrationEndpoint: regEndpoint,
                                                    redirectURI: oauth.redirectURI, scopes: oauth.scopes)
            OAuthClientStore.setClientID(entry.id, cid)
            clientID = cid
        }
        guard let cid = clientID, !cid.isEmpty else { throw OAuthError.clientIDRequired }

        // Resolve the redirect_uri + callback scheme for THIS connection. Linear/Slack use the static
        // `sovereign://callback`; Google derives the reversed-client-id scheme from the resolved
        // client_id (its installed-app flow rejects a generic redirect). ASWebAuthenticationSession
        // registers whichever scheme we hand it transiently — no Info.plist entry for the Google scheme.
        let redirect: (scheme: String, uri: String)
        switch oauth.redirectStyle {
        case .staticScheme:
            redirect = (oauth.redirectScheme, oauth.redirectURI)
        case .googleReversedClientID:
            guard let g = Self.googleRedirect(clientID: cid) else { throw OAuthError.clientIDRequired }
            redirect = (g.scheme, g.redirectURI)
        }

        // Persist the resolved token endpoint so a later refresh is self-contained (no re-discovery).
        OAuthClientStore.setTokenEndpoint(entry.id, tokenEndpoint)

        // 3. PKCE.
        let verifier = PKCE.randomURLSafe(64)
        let challenge = PKCE.challengeS256(verifier)
        let state = PKCE.randomURLSafe(24)

        // 4. Build the authorize URL.
        guard let authURL = Self.authorizeURL(authorizationEndpoint: authzEndpoint, clientID: cid,
                                              redirectURI: redirect.uri, scopes: oauth.scopes,
                                              codeChallenge: challenge, state: state,
                                              resource: resource, extra: oauth.extraAuthParams) else {
            throw OAuthError.badAuthorizeURL
        }

        // 5. Present the system sign-in sheet and capture the authorization code (state-validated).
        let code = try await authorize(url: authURL, callbackScheme: redirect.scheme, state: state)

        // 6. Exchange code → tokens.
        let tokens = try await Self.exchangeCode(tokenEndpoint: tokenEndpoint, code: code, verifier: verifier,
                                                 clientID: cid, redirectURI: redirect.uri, resource: resource)

        // 7. Persist in the private credential store and return the access_token to the caller.
        guard OAuthTokenStore.save(connectorID: entry.id, accessToken: tokens.accessToken,
                                   refreshToken: tokens.refreshToken, expiresIn: tokens.expiresIn,
                                   scope: tokens.scope, tokenType: tokens.tokenType) else {
            throw OAuthError.tokenExchangeFailed("Sovereign could not save the OAuth session in its private credential store.")
        }
        return tokens.accessToken
    }

    /// Present ASWebAuthenticationSession and resolve with the `code` query item (mirrors GoogleSignIn).
    private func authorize(url: URL, callbackScheme: String, state: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error = error {
                    let nsErr = error as NSError
                    if nsErr.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        cont.resume(throwing: OAuthError.userCancelled); return
                    }
                    cont.resume(throwing: OAuthError.tokenExchangeFailed(error.localizedDescription)); return
                }
                guard let callbackURL,
                      let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                      let code = items.first(where: { $0.name == "code" })?.value,
                      items.first(where: { $0.name == "state" })?.value == state else {
                    cont.resume(throwing: OAuthError.badRedirect); return
                }
                cont.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            if !session.start() { cont.resume(throwing: OAuthError.cannotPresent) }
        }
    }

    /// Reusable interactive authorization step for a flow that is NOT a catalog MCP connector.
    /// It has no MCP endpointURL, so it cannot call `connect(entry:)`; instead it composes the SAME
    /// helpers (discovery, DCR, PKCE, authorizeURL, exchangeCode) and hands the built authorize URL
    /// here to reuse the ONE ASWebAuthenticationSession presentation + state-validated code capture.
    func presentAuthorizationCode(url: URL, callbackScheme: String, state: String) async throws -> String {
        try await authorize(url: url, callbackScheme: callbackScheme, state: state)
    }

    // MARK: Refresh-on-401 (nonisolated — callable from the MCP I/O layer)

    /// Renew the access token with the stored refresh token. Returns true and re-persists on success;
    /// false (no fabricated success) when there's no refresh token / client / endpoint or the call fails.
    nonisolated func refresh(connectorID: String) async -> Bool {
        guard let refreshToken = OAuthTokenStore.refreshToken(connectorID: connectorID),
              let tokenEndpoint = OAuthClientStore.tokenEndpoint(connectorID),
              let clientID = OAuthClientStore.clientID(connectorID) else { return false }
        var form: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ]
        if let entry = ConnectorCatalog.entry(connectorID),
           let resource = entry.oauth?.resourceIndicator ?? entry.endpointURL {
            form["resource"] = resource
        }
        guard let tokens = try? await Self.postForm(tokenEndpoint, form: form) else { return false }
        return OAuthTokenStore.save(connectorID: connectorID, accessToken: tokens.accessToken,
                                    refreshToken: tokens.refreshToken ?? refreshToken, expiresIn: tokens.expiresIn,
                                    scope: tokens.scope, tokenType: tokens.tokenType)
    }

    // MARK: - Pure helpers (no I/O — unit-tested)

    /// RFC 9728 §3.1 — protected-resource metadata URL(s) for an MCP resource endpoint, priority order:
    /// path-aware (`/.well-known/oauth-protected-resource<path>`) first, then the origin root.
    nonisolated static func protectedResourceMetadataURLs(forResource resource: String) -> [String] {
        wellKnownURLs(base: resource, suffix: "oauth-protected-resource", includeOIDC: false)
    }

    /// RFC 8414 §3 — authorization-server metadata URL(s) for an issuer, priority order: path-aware,
    /// origin root, then the OIDC discovery fallback (`/.well-known/openid-configuration`).
    nonisolated static func authServerMetadataURLs(forIssuer issuer: String) -> [String] {
        wellKnownURLs(base: issuer, suffix: "oauth-authorization-server", includeOIDC: true)
    }

    nonisolated private static func wellKnownURLs(base: String, suffix: String, includeOIDC: Bool) -> [String] {
        guard let comps = URLComponents(string: base), let scheme = comps.scheme, let host = comps.host else { return [] }
        var origin = "\(scheme)://\(host)"
        if let port = comps.port { origin += ":\(port)" }
        let path = comps.path == "/" ? "" : comps.path
        var out: [String] = []
        if !path.isEmpty { out.append("\(origin)/.well-known/\(suffix)\(path)") }
        out.append("\(origin)/.well-known/\(suffix)")
        if includeOIDC {
            if !path.isEmpty { out.append("\(origin)/.well-known/openid-configuration\(path)") }
            out.append("\(origin)/.well-known/openid-configuration")
        }
        return out
    }

    /// RFC 7591 dynamic-client-registration request body for a PKCE public client (no client secret).
    nonisolated static func dynamicRegistrationBody(redirectURI: String, scopes: [String],
                                                    clientName: String = "Black Label Sovereign") -> [String: Any] {
        [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": scopes.joined(separator: " ")
        ]
    }

    /// Build the authorize URL (response_type=code + PKCE S256 + RFC 8707 resource + provider extras).
    nonisolated static func authorizeURL(authorizationEndpoint: String, clientID: String, redirectURI: String,
                                         scopes: [String], codeChallenge: String, state: String,
                                         resource: String?, extra: [String: String]) -> URL? {
        guard var comps = URLComponents(string: authorizationEndpoint) else { return nil }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        if !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " "))) }
        if let resource, !resource.isEmpty { items.append(URLQueryItem(name: "resource", value: resource)) }
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        return comps.url
    }

    /// Google native/installed-app reversed-client-ID redirect. Google's authorization server requires a
    /// desktop/native client's redirect to be its OWN client-id reversed into a custom scheme — NOT a
    /// generic app scheme. For client_id `NNNN-xxxx.apps.googleusercontent.com` the scheme is
    /// `com.googleusercontent.apps.NNNN-xxxx` and the redirect_uri is `<scheme>:/oauth2redirect`
    /// (matching Sources/Social.swift's existing Google flow). Returns nil for any id that isn't a Google
    /// `.apps.googleusercontent.com` client id (honest — a malformed paste can't form a redirect, never
    /// a faked one). Pure → unit-tested.
    nonisolated static func googleRedirect(clientID: String) -> (scheme: String, redirectURI: String)? {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".apps.googleusercontent.com"
        guard trimmed.hasSuffix(suffix) else { return nil }
        let prefix = String(trimmed.dropLast(suffix.count))   // e.g. "NNNN-xxxx"
        guard !prefix.isEmpty else { return nil }
        let scheme = "com.googleusercontent.apps.\(prefix)"
        return (scheme, "\(scheme):/oauth2redirect")
    }

    // MARK: - I/O (nonisolated — discovery, registration, token exchange)

    struct ResolvedEndpoints { var authorization: String?; var token: String?; var registration: String? }
    struct TokenResult { var accessToken: String; var refreshToken: String?; var expiresIn: Int?; var scope: String?; var tokenType: String? }

    nonisolated static func discoverEndpoints(oauth: OAuthParams, resource: String) async -> ResolvedEndpoints {
        var result = ResolvedEndpoints(authorization: oauth.authorizationEndpoint,
                                       token: oauth.tokenEndpoint,
                                       registration: oauth.registrationEndpoint)
        // RFC 9728: protected-resource metadata → authorization_servers[0] (the issuer).
        let prmURLs = oauth.protectedResourceMetadataURL.map { [$0] } ?? protectedResourceMetadataURLs(forResource: resource)
        var issuer: String? = nil
        for u in prmURLs {
            if let json = await getJSON(u),
               let servers = json["authorization_servers"] as? [String], let first = servers.first {
                issuer = first; break
            }
        }
        // RFC 8414: authorization-server metadata for that issuer.
        let asURLs: [String]
        if let staticAS = oauth.asMetadataURL { asURLs = [staticAS] }
        else if let iss = issuer { asURLs = authServerMetadataURLs(forIssuer: iss) }
        else { asURLs = [] }
        for u in asURLs {
            if let json = await getJSON(u) {
                if let a = json["authorization_endpoint"] as? String { result.authorization = a }
                if let t = json["token_endpoint"] as? String { result.token = t }
                if let r = json["registration_endpoint"] as? String { result.registration = r }
                break
            }
        }
        return result
    }

    nonisolated static func registerClient(registrationEndpoint: String, redirectURI: String, scopes: [String]) async throws -> String {
        guard let url = URL(string: registrationEndpoint) else { throw OAuthError.registrationFailed("bad registration endpoint") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try? JSONSerialization.data(withJSONObject: dynamicRegistrationBody(redirectURI: redirectURI, scopes: scopes))
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw OAuthError.registrationFailed(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = json["client_id"] as? String, !clientID.isEmpty else {
            throw OAuthError.registrationFailed("registration response had no client_id")
        }
        return clientID
    }

    nonisolated static func exchangeCode(tokenEndpoint: String, code: String, verifier: String,
                                         clientID: String, redirectURI: String, resource: String?) async throws -> TokenResult {
        var form: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "client_id": clientID,
            "redirect_uri": redirectURI
        ]
        if let resource, !resource.isEmpty { form["resource"] = resource }
        return try await postForm(tokenEndpoint, form: form)
    }

    /// POST an x-www-form-urlencoded body to a token endpoint and parse the OAuth token response.
    nonisolated static func postForm(_ endpoint: String, form: [String: String]) async throws -> TokenResult {
        guard let url = URL(string: endpoint) else { throw OAuthError.tokenExchangeFailed("bad token endpoint") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = PKCE.formBody(form)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw OAuthError.tokenExchangeFailed(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) \(body.prefix(160))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw OAuthError.tokenExchangeFailed("token response had no access_token")
        }
        return TokenResult(accessToken: access,
                           refreshToken: json["refresh_token"] as? String,
                           expiresIn: json["expires_in"] as? Int,
                           scope: json["scope"] as? String,
                           tokenType: json["token_type"] as? String)
    }

    /// GET a JSON document, returning the parsed object or nil on any non-2xx / parse failure (so the
    /// discovery loop can fall through to the next candidate URL or the static fallback honestly).
    nonisolated static func getJSON(_ urlString: String) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    // MARK: ASWebAuthenticationPresentationContextProviding
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(AppKit)
        return NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif // circuit-convert
