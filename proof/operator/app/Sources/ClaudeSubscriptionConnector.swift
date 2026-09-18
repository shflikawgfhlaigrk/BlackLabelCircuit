// Sovereign — CLAUDE-SUBSCRIPTION SIGN-IN. The buyer-own-client interactive "Sign in with Claude"
// that runs on the BUYER's own Claude subscription, built entirely on the shared OAuthCore engine
// (OAuthCore.swift): ONE PKCE impl, ONE discovery/DCR path, ONE token exchange, ONE web-auth
// presentation — no per-provider duplication of crypto or HTTP.
//
// WHY THIS EXISTS: ExternalAuth already SENDS an OAuth token as `Authorization: Bearer <token>` +
// `anthropic-beta: oauth-2025-04-20` (Brain.makeRequest, case .oauth). What was missing was the
// interactive flow that PRODUCES that token from the buyer's own Claude login. This connector is it.
//
// HONESTY (CHARTER §5.1 / §5.2 / §5.5):
//   • NO client_id and NO secret are bundled. The client_id is resolved at connect time — DCR
//     (RFC 7591 /register) when the authorization server advertises it, else the buyer pastes their
//     OWN public client_id (public, non-secret) from console.anthropic.com. Absent a resolved
//     client_id the flow throws `.clientIDRequired` and the UI stays an honest "not connected".
//   • The access token lands ONLY in ExternalAuth's single oauth Keychain slot (the same slot the
//     brain reads) — never on disk, never in UserDefaults, never logged.
//   • Nothing is "connected" until a REAL token exchange returns a REAL access_token. No faked grant.
//   • Runs on the buyer's OWN subscription (§5.5) — never a Black Label account or a paid backend.
import Foundation

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// The Claude-subscription sign-in, composed from the shared OAuthConnector. Stateless enum: all
/// durable state is the client_id (UserDefaults, non-secret, via OAuthClientStore) and the access
/// token (Keychain, via ExternalAuth). Nothing here holds a credential in memory beyond the exchange.
@MainActor
enum ClaudeSubscriptionConnector {
    /// Stable slug — the OAuthClientStore account for the buyer's (public, non-secret) client_id.
    static let connectorID = "claude-subscription"

    /// RFC 8707 resource / audience: the buyer's own inference API. Also the discovery base.
    static let resourceAPI = "https://api.anthropic.com"

    /// Anthropic's Claude-subscription OAuth 2.0 description. Endpoints are PUBLIC, non-secret (they are
    /// URLs, not credentials). `supportsDCR` lets the engine TRY RFC 7591 registration when the server
    /// advertises a registration endpoint; when it doesn't (Anthropic has no public DCR today) the flow
    /// falls back to the buyer's own pasted public client_id. PKCE (S256) keeps it secretless on desktop.
    /// The token exchange is RFC 6749 form-encoded (the shared postForm) — the standards-correct default.
    static let oauth = OAuthParams(
        authorizationEndpoint: "https://claude.ai/oauth/authorize",
        tokenEndpoint: "https://console.anthropic.com/v1/oauth/token",
        supportsDCR: true,
        clientIDRequired: true,            // fall back to a buyer-pasted public client_id when DCR is absent
        scopes: ["user:inference", "user:profile"],
        redirectScheme: "sovereign",
        redirectPath: "callback",
        redirectStyle: .staticScheme,
        usesPKCE: true,
        resourceIndicator: resourceAPI)

    /// The buyer's stored public client_id, if any (nil = must paste before signing in). No bundled id.
    static var storedClientID: String? { OAuthClientStore.clientID(connectorID) }

    /// True only when the single oauth Keychain slot holds a token — read live from ExternalAuth.
    static var isConnected: Bool { ExternalAuth.shared.connectedKind == .oauth }

    /// Persist the buyer's own public client_id (non-secret) on this device before the flow runs.
    static func setClientID(_ raw: String) {
        OAuthClientStore.setClientID(connectorID, raw)
    }

    /// Run the buyer-own-client interactive sign-in against the buyer's OWN Claude login. On success the
    /// access token is stored in ExternalAuth's single oauth slot (Bearer + oauth-beta already wired in
    /// Brain.makeRequest). Throws an honest OAuthError at every failure — never returns a faked grant.
    static func signIn() async throws {
        // 1. Discover endpoints (RFC 9728 → 8414), falling back to the static Anthropic endpoints.
        let ep = await OAuthConnector.discoverEndpoints(oauth: oauth, resource: resourceAPI)
        guard let authzEndpoint = ep.authorization, let tokenEndpoint = ep.token else {
            throw OAuthError.discoveryFailed
        }

        // 2. Resolve client_id: stored/pasted first, else DCR (RFC 7591) when advertised. NEVER bundled.
        var clientID = OAuthClientStore.clientID(connectorID)
        if clientID == nil, oauth.supportsDCR, let regEndpoint = ep.registration {
            let cid = try await OAuthConnector.registerClient(registrationEndpoint: regEndpoint,
                                                              redirectURI: oauth.redirectURI, scopes: oauth.scopes)
            OAuthClientStore.setClientID(connectorID, cid)
            clientID = cid
        }
        guard let cid = clientID, !cid.isEmpty else { throw OAuthError.clientIDRequired }

        // Persist the resolved token endpoint so a later refresh unit is self-contained (no re-discovery).
        OAuthClientStore.setTokenEndpoint(connectorID, tokenEndpoint)

        // 3. PKCE + authorize URL (response_type=code, S256, RFC 8707 resource).
        let verifier = PKCE.randomURLSafe(64)
        let challenge = PKCE.challengeS256(verifier)
        let state = PKCE.randomURLSafe(24)
        guard let authURL = OAuthConnector.authorizeURL(
                authorizationEndpoint: authzEndpoint, clientID: cid, redirectURI: oauth.redirectURI,
                scopes: oauth.scopes, codeChallenge: challenge, state: state,
                resource: resourceAPI, extra: oauth.extraAuthParams) else {
            throw OAuthError.badAuthorizeURL
        }

        // 4. Present the system sign-in sheet and capture the state-validated authorization code.
        let code = try await OAuthConnector.shared.presentAuthorizationCode(
            url: authURL, callbackScheme: oauth.redirectScheme, state: state)

        // 5. Exchange code → tokens.
        let tokens = try await OAuthConnector.exchangeCode(
            tokenEndpoint: tokenEndpoint, code: code, verifier: verifier,
            clientID: cid, redirectURI: oauth.redirectURI, resource: resourceAPI)

        // 6. Store the access token in the SINGLE oauth Keychain slot the brain reads. Keychain-only.
        ExternalAuth.shared.connectOAuthToken(tokens.accessToken)
    }

    /// Disconnect — wipe the oauth token from the Keychain and forget the on-device client id.
    static func disconnect() {
        ExternalAuth.shared.disconnect()
        OAuthClientStore.clear(connectorID)
    }
}
#endif // circuit-convert
