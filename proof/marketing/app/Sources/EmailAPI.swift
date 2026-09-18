// Black Label Marketing — REAL provider-API email transport (Gmail API + Microsoft Graph).
//
// Founder directive (2026-07-03): "ONLY use API, no backends — you make our backend work to
// whatever API they put in", and "Google done right is OAuth, not a pasted client-id bootstrap."
// So a buyer clicks Connect, authorizes at the provider's OWN consent screen, and every send then
// calls the provider's REAL API with the returned OAuth token:
//
//   • Gmail / Google Workspace → Gmail API `users.messages.send` (scope gmail.send), the message
//     is an RFC-5322 blob (built by the SHIPPED SMTPClient.buildMessage) base64url-encoded as `raw`.
//   • Outlook / Microsoft 365   → Microsoft Graph `me/sendMail` (scope Mail.Send), a JSON message.
//
// No app-passwords, no shared/bootstrap credentials, no Black Label server in the path. The buyer
// supplies their OWN OAuth client id per provider ("whatever API they put in"); the code→token
// exchange and every API call run on-device with the buyer's own token. SMTP is retained as an
// explicit fallback (OutboundMailer picks the API when the mailbox is OAuth-connected, else SMTP).
//
// EVERYTHING in this file is pure + Foundation-only so the request builders (endpoints, scopes,
// base64url message, JSON body) and the honest "connected only after a real 200" status logic are
// unit-tested headlessly in Tests/EmailAPITests.swift. The network execution + the interactive
// ASWebAuthenticationSession OAuth live in EmailOAuth.swift (which imports this).
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Provider

/// The two real provider APIs this app sends over. `.none` == this mailbox uses SMTP (the fallback).
enum EmailAuthKind: String, Codable, Hashable {
    case smtp, gmailAPI, graphAPI

    /// Honest transport label surfaced in the Connectors UI ("Connected via Gmail API", etc.).
    var transportLabel: String {
        switch self {
        case .smtp:     return "SMTP"
        case .gmailAPI: return "Gmail API"
        case .graphAPI: return "Microsoft Graph"
        }
    }
    /// The provider whose OAuth + API this mailbox uses (nil for SMTP).
    var provider: EmailAPIProvider? {
        switch self {
        case .smtp:     return nil
        case .gmailAPI: return .gmail
        case .graphAPI: return .microsoft
        }
    }
}

/// One provider's OAuth + API shape. Endpoints verified against live provider docs (2025/2026).
/// Both providers here are PUBLIC clients that authorize with PKCE and NO client secret — a native
/// desktop app is not a confidential client, and the buyer registers a redirect for a public client.
enum EmailAPIProvider: String, Codable, CaseIterable, Identifiable {
    case gmail, microsoft
    var id: String { rawValue }

    var displayName: String { self == .gmail ? "Gmail / Google Workspace" : "Outlook / Microsoft 365" }
    var authKind: EmailAuthKind { self == .gmail ? .gmailAPI : .graphAPI }

    /// OAuth 2.0 authorization endpoint (the buyer's OWN consent screen).
    var authorizeEndpoint: String {
        switch self {
        case .gmail:     return "https://accounts.google.com/o/oauth2/v2/auth"
        case .microsoft: return "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        }
    }
    /// OAuth 2.0 token endpoint (on-device code→token exchange).
    var tokenEndpoint: String {
        switch self {
        case .gmail:     return "https://oauth2.googleapis.com/token"
        case .microsoft: return "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        }
    }
    /// The exact scopes requested. `gmail.send` / `Mail.Send` are the minimum send scopes; `offline_access`
    /// (MS) / `access_type=offline` (Google) yields a refresh token so a connected mailbox keeps sending.
    var scopes: [String] {
        switch self {
        case .gmail:     return ["openid", "email", "https://www.googleapis.com/auth/gmail.send"]
        case .microsoft: return ["openid", "email", "offline_access", "https://graph.microsoft.com/Mail.Send"]
        }
    }
    /// The REST endpoint a send is POSTed to.
    var sendEndpoint: String {
        switch self {
        case .gmail:     return "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"
        case .microsoft: return "https://graph.microsoft.com/v1.0/me/sendMail"
        }
    }
    /// A cheap authenticated GET that returns 200 + the account address — used to VALIDATE a fresh
    /// token so the connector chip goes green only after a real API call succeeds.
    var validateEndpoint: String {
        switch self {
        case .gmail:     return "https://gmail.googleapis.com/gmail/v1/users/me/profile"
        case .microsoft: return "https://graph.microsoft.com/v1.0/me"
        }
    }
    /// HTTP status the provider returns on an ACCEPTED send (Gmail 200, Graph 202).
    func isSendSuccess(_ status: Int) -> Bool {
        switch self {
        case .gmail:     return status == 200
        case .microsoft: return status == 202 || status == 200
        }
    }
    /// Where the buyer registers their own OAuth client (shown in the connect UI).
    var consoleURL: String {
        switch self {
        case .gmail:     return "https://console.cloud.google.com/apis/credentials"
        case .microsoft: return "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"
        }
    }
    /// The UserDefaults key the buyer's own client id is saved under (per provider).
    var clientIDDefaultsKey: String {
        switch self {
        case .gmail:     return "GmailAPIClientID"      // distinct from sign-in's GoogleClientID (may differ / same)
        case .microsoft: return "MicrosoftGraphClientID"
        }
    }
}

// MARK: - Pure request builders (unit-tested)

enum EmailAPI {

    /// RFC 4648 §5 base64url WITHOUT padding — the encoding Gmail's `raw` field requires.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: send

    /// Gmail API `users.messages.send`. `rfc822` is the full RFC-5322 message (headers + body) —
    /// build it with the SHIPPED `SMTPClient.buildMessage` so the API path and SMTP path produce the
    /// exact same message. The body is `{"raw": base64url(rfc822)}`, Bearer-authenticated.
    static func gmailSendRequest(accessToken: String, rfc822: String) -> URLRequest? {
        let tok = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tok.isEmpty, !rfc822.isEmpty, let url = URL(string: EmailAPIProvider.gmail.sendEndpoint) else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        r.httpMethod = "POST"
        r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["raw": base64URL(Data(rfc822.utf8))]
        r.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return r
    }

    /// The Microsoft Graph `sendMail` message object (pure — asserted in tests). Plain-text body.
    static func graphMessageJSON(to: String, subject: String, body: String, saveToSent: Bool = true) -> [String: Any] {
        [
            "message": [
                "subject": subject,
                "body": ["contentType": "Text", "content": body],
                "toRecipients": [["emailAddress": ["address": to]]]
            ],
            "saveToSentItems": saveToSent
        ]
    }

    /// Microsoft Graph `me/sendMail`, Bearer-authenticated JSON.
    static func graphSendRequest(accessToken: String, to: String, subject: String, body: String) -> URLRequest? {
        let tok = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let rcpt = to.trimmingCharacters(in: .whitespaces)
        guard !tok.isEmpty, rcpt.contains("@"), let url = URL(string: EmailAPIProvider.microsoft.sendEndpoint) else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        r.httpMethod = "POST"
        r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: graphMessageJSON(to: rcpt, subject: subject, body: body))
        return r
    }

    // MARK: validate (token round-trip that proves the connection is real)

    /// An authenticated GET that returns 200 + the account address for a valid token.
    static func validateRequest(provider: EmailAPIProvider, accessToken: String) -> URLRequest? {
        let tok = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tok.isEmpty, let url = URL(string: provider.validateEndpoint) else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        r.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// Extract the account email from a validate response body (Gmail `emailAddress`, Graph `mail`/`userPrincipalName`).
    static func accountEmail(provider: EmailAPIProvider, from json: [String: Any]) -> String? {
        switch provider {
        case .gmail:
            return (json["emailAddress"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty
        case .microsoft:
            let mail = (json["mail"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty
            return mail ?? (json["userPrincipalName"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty
        }
    }

    // MARK: OAuth authorize + token exchange builders

    /// The buyer's OWN authorization URL (their consent screen). PKCE S256; `access_type=offline` +
    /// `prompt=consent` (Google) / `offline_access` scope (MS) so a refresh token is issued.
    static func authorizeURL(provider: EmailAPIProvider, clientID: String, redirectURI: String,
                             state: String, codeChallenge: String, loginHint: String? = nil) -> URL? {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        var items = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: provider.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        switch provider {
        case .gmail:
            items.append(URLQueryItem(name: "access_type", value: "offline"))
            items.append(URLQueryItem(name: "prompt", value: "consent"))
        case .microsoft:
            items.append(URLQueryItem(name: "response_mode", value: "query"))
            items.append(URLQueryItem(name: "prompt", value: "select_account"))
        }
        if let h = loginHint?.trimmingCharacters(in: .whitespaces), !h.isEmpty {
            items.append(URLQueryItem(name: "login_hint", value: h))
        }
        var c = URLComponents(string: provider.authorizeEndpoint)
        c?.queryItems = items
        return c?.url
    }

    /// The on-device code→token exchange request (public client → PKCE verifier, NO client secret).
    static func tokenRequest(provider: EmailAPIProvider, clientID: String, redirectURI: String,
                             code: String, codeVerifier: String) -> URLRequest? {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !code.isEmpty, let url = URL(string: provider.tokenEndpoint) else { return nil }
        let form = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ]
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = formEncode(form).data(using: .utf8)
        return r
    }

    /// The refresh-token grant (used when a stored access token has expired).
    static func refreshRequest(provider: EmailAPIProvider, clientID: String, refreshToken: String) -> URLRequest? {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        let rt = refreshToken.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !rt.isEmpty, let url = URL(string: provider.tokenEndpoint) else { return nil }
        var form = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: rt)
        ]
        if provider == .microsoft {
            form.append(URLQueryItem(name: "scope", value: provider.scopes.joined(separator: " ")))
        }
        var r = URLRequest(url: url)
        r.timeoutInterval = 20
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = formEncode(form).data(using: .utf8)
        return r
    }

    /// Percent-encode a form body (spaces as %20, provider-safe).
    static func formEncode(_ items: [URLQueryItem]) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return items.map { i in
            let k = i.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? i.name
            let v = (i.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}

// MARK: - Honest connector status (green ONLY after a real 200)

/// A mailbox connected via a provider API is "connected" only once a real validate/send round-trip
/// has returned success. A stored token that has never been validated reads as `.off` (not a green
/// claim); a token whose last real call failed (revoked/expired, no refresh) reads as `.error`.
enum EmailAPIStatus {
    static func state(hasToken: Bool, lastCallOK: Bool?) -> ConnectorState {
        guard hasToken else { return .off }
        switch lastCallOK {
        case .some(true):  return .connected
        case .some(false): return .error
        case .none:        return .unverified
        }
    }
}

// MARK: - Token storage (data-protection Keychain, on-device only)

/// One provider OAuth token set for one connected mailbox address. Persisted as JSON in the
/// data-protection Keychain via `MarketingKeychain` (stable across ad-hoc re-signs). NEVER written to
/// the workspace JSON backup, NEVER synced to iCloud. `clientID` is stored so a refresh can run later.
struct EmailOAuthToken: Codable {
    var provider: EmailAPIProvider
    var address: String
    var accessToken: String
    var refreshToken: String?
    var clientID: String
    var expiresAt: Date?          // nil == unknown; treat as needs-refresh-on-401

    var isExpired: Bool {
        guard let e = expiresAt else { return false }
        return Date() >= e.addingTimeInterval(-60)   // 60s skew
    }
}

/// Keychain-backed store for provider OAuth tokens, keyed by `provider|address`. Mirrors the routing
/// and device-only protection class of `SocialCredentialStore` / `SendKeychain`.
enum EmailTokenStore {
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").emailapi"
    }

    private static func account(provider: EmailAPIProvider, address: String) -> String {
        "\(provider.rawValue)|\(address.trimmingCharacters(in: .whitespaces).lowercased())"
    }
    private static func base(provider: EmailAPIProvider, address: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(provider: provider, address: address)
        ]
    }

    static func save(_ token: EmailOAuthToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        MarketingKeychain.set(base(provider: token.provider, address: token.address),
                              data: data, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    static func load(provider: EmailAPIProvider, address: String) -> EmailOAuthToken? {
        guard let data = MarketingKeychain.copy(base(provider: provider, address: address),
                                                accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                allowAuthenticationUI: false),
              let t = try? JSONDecoder().decode(EmailOAuthToken.self, from: data) else { return nil }
        return t
    }

    static func hasToken(provider: EmailAPIProvider, address: String) -> Bool {
        load(provider: provider, address: address) != nil
    }

    static func delete(provider: EmailAPIProvider, address: String) {
        MarketingKeychain.delete(base(provider: provider, address: address))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
