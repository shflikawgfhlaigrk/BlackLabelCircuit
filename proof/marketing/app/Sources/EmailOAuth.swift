#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — interactive provider-API email OAuth + the network send executor.
//
// This is the "Connect" side of the real-API email path (pure builders live in EmailAPI.swift):
//   1. `EmailOAuth.connect(provider:)` runs a REAL ASWebAuthenticationSession against the buyer's
//      OWN provider consent screen (Google / Microsoft), captures the ?code on the app's custom
//      scheme, exchanges it for a token ON-DEVICE (PKCE, no client secret), then VALIDATES the token
//      with a real authenticated API call — returning the account address only after a 200. No token
//      is ever "connected" on a saved client-id alone.
//   2. `EmailAPISender.send(...)` delivers one message over the provider's real API using the stored
//      token (auto-refreshing an expired access token), so OutboundMailer can route an OAuth mailbox
//      to Gmail-API/Graph instead of SMTP.
import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#endif
#if canImport(AuthenticationServices) && !CIRCUIT_WINDOWS_SIM
import AuthenticationServices
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Interactive OAuth (Connect)

final class EmailOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = EmailOAuth()
    private var session: ASWebAuthenticationSession?

    /// App custom scheme the provider redirect bounces back to (declared in project.yml CFBundleURLSchemes).
    private static let scheme = "com.blacklabel.marketing"
    /// Per-provider redirect the buyer registers in their own OAuth client. Google desktop clients accept
    /// a custom-scheme loopback (`scheme:/path`); Microsoft public clients accept `scheme://path`.
    static func redirectURI(for provider: EmailAPIProvider) -> String {
        switch provider {
        case .gmail:     return "\(scheme):/oauth2redirect"
        case .microsoft: return "\(scheme)://oauth2redirect"
        }
    }

    enum OAuthError: LocalizedError {
        case noClientID(EmailAPIProvider), cancelled, badCallback, stateMismatch
        case exchange(String), validate(String), noAddress
        var errorDescription: String? {
            switch self {
            case .noClientID(let p): return "Add your \(p.displayName) OAuth client ID first."
            case .cancelled:         return "Sign-in was cancelled."
            case .badCallback:       return "The provider didn't return a valid response."
            case .stateMismatch:     return "Sign-in failed a security check — please try again."
            case .exchange(let m):   return "Couldn't complete sign-in: \(m)"
            case .validate(let m):   return "Connected, but the account couldn't be verified: \(m)"
            case .noAddress:         return "The provider didn't return an account email."
            }
        }
    }

    struct Connected { var provider: EmailAPIProvider; var address: String; var token: EmailOAuthToken }

    /// The buyer's own OAuth client id for a provider: a value saved from the Connectors UI takes
    /// precedence; Gmail falls back to the sign-in client id (they're often the same Google client).
    static func clientID(for provider: EmailAPIProvider) -> String {
        let saved = (UserDefaults.standard.string(forKey: provider.clientIDDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty { return saved }
        if provider == .gmail { return GoogleAuth.clientID }   // reuse the sign-in Google client if set
        return ""
    }
    static func isConfigured(_ provider: EmailAPIProvider) -> Bool { !clientID(for: provider).isEmpty }

    /// Run authorize → on-device exchange → real validate. Completion carries the connected account
    /// (and the stored token) ONLY after a genuine authenticated API call returned 200.
    func connect(provider: EmailAPIProvider, completion: @escaping (Result<Connected, Error>) -> Void) {
        let clientID = Self.clientID(for: provider)
        guard !clientID.isEmpty else { completion(.failure(OAuthError.noClientID(provider))); return }
        let redirect = Self.redirectURI(for: provider)
        let verifier = Self.makeVerifier()
        let challenge = Self.challenge(for: verifier)
        let state = Self.makeVerifier()
        guard let authURL = EmailAPI.authorizeURL(provider: provider, clientID: clientID, redirectURI: redirect,
                                                  state: state, codeChallenge: challenge) else {
            completion(.failure(OAuthError.noClientID(provider))); return
        }
        let s = ASWebAuthenticationSession(url: authURL, callbackURLScheme: Self.scheme) { [weak self] cb, err in
            guard let self = self else { return }
            if let err = err {
                let code = (err as NSError).code
                let e: Error = code == ASWebAuthenticationSessionError.canceledLogin.rawValue ? OAuthError.cancelled : err
                DispatchQueue.main.async { completion(.failure(e)) }; return
            }
            guard let cb = cb, let items = URLComponents(url: cb, resolvingAgainstBaseURL: false)?.queryItems else {
                DispatchQueue.main.async { completion(.failure(OAuthError.badCallback)) }; return
            }
            func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
            if let e = q("error") { DispatchQueue.main.async { completion(.failure(OAuthError.exchange(q("error_description") ?? e))) }; return }
            guard q("state") == state else { DispatchQueue.main.async { completion(.failure(OAuthError.stateMismatch)) }; return }
            guard let code = q("code") else { DispatchQueue.main.async { completion(.failure(OAuthError.badCallback)) }; return }
            self.exchange(provider: provider, clientID: clientID, redirect: redirect, code: code, verifier: verifier, completion: completion)
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false   // reuse the buyer's existing signed-in web session
        self.session = s
        DispatchQueue.main.async { s.start() }
    }

    private func exchange(provider: EmailAPIProvider, clientID: String, redirect: String, code: String,
                          verifier: String, completion: @escaping (Result<Connected, Error>) -> Void) {
        guard let req = EmailAPI.tokenRequest(provider: provider, clientID: clientID, redirectURI: redirect,
                                              code: code, codeVerifier: verifier) else {
            DispatchQueue.main.async { completion(.failure(OAuthError.exchange("couldn't build token request"))) }; return
        }
        // The code→token exchange rides the declared `oauthTokenExchange` lane of the egress
        // choke point: nothing but the OAuth code and client id leaves here.
        ConsentedEgress.sendUngated(req, lane: .oauthTokenExchange) { data, _, err in
            if let err = err { DispatchQueue.main.async { completion(.failure(err)) }; return }
            guard let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String, !access.isEmpty else {
                let msg = (try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any])?
                    .flatMap { ($0["error_description"] as? String) ?? ($0["error"] as? String) } ?? "no access token"
                DispatchQueue.main.async { completion(.failure(OAuthError.exchange(msg))) }; return
            }
            let refresh = json["refresh_token"] as? String
            let expiresAt = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
            // Validate the fresh token with a REAL authenticated API call before claiming connected.
            self.validate(provider: provider, accessToken: access) { result in
                switch result {
                case .failure(let e): DispatchQueue.main.async { completion(.failure(e)) }
                case .success(let address):
                    let token = EmailOAuthToken(provider: provider, address: address, accessToken: access,
                                                refreshToken: refresh, clientID: clientID, expiresAt: expiresAt)
                    EmailTokenStore.save(token)
                    DispatchQueue.main.async { completion(.success(Connected(provider: provider, address: address, token: token))) }
                }
            }
        }
    }

    private func validate(provider: EmailAPIProvider, accessToken: String,
                          completion: @escaping (Result<String, Error>) -> Void) {
        guard let req = EmailAPI.validateRequest(provider: provider, accessToken: accessToken) else {
            completion(.failure(OAuthError.validate("couldn't build validate request"))); return
        }
        // Reading the connected mailbox's own address from the buyer's own account.
        ConsentedEgress.sendUngated(req, lane: .ownAccountAPI) { data, resp, err in
            if let err = err { completion(.failure(OAuthError.validate(err.localizedDescription))); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(OAuthError.validate("HTTP \(status)"))); return
            }
            guard let email = EmailAPI.accountEmail(provider: provider, from: json) else {
                completion(.failure(OAuthError.noAddress)); return
            }
            completion(.success(email))
        }
    }

    // PKCE helpers
    private static func makeVerifier() -> String {
        var b = [UInt8](repeating: 0, count: 32); _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return base64URL(Data(b))
    }
    private static func challenge(for v: String) -> String { base64URL(Data(SHA256.hash(data: Data(v.utf8)))) }
    private static func base64URL(_ d: Data) -> String { EmailAPI.base64URL(d) }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        #endif
    }
}

// MARK: - Network send executor (Gmail API / Microsoft Graph)

enum EmailAPISender {
    struct SendResult { var ok: Bool; var detail: String }

    /// Deliver one message over the provider's real API using the stored OAuth token for `mailbox`.
    /// Auto-refreshes an expired access token when a refresh token is present. Honest by construction:
    /// a missing token, a failed refresh, or a non-2xx API status returns ok=false with the reason —
    /// never a false "sent".
    static func send(mailbox: Mailbox, to recipient: String, subject: String, body: String,
                     extraHeaders: [(name: String, value: String)] = []) async -> SendResult {
        guard let provider = mailbox.authKind.provider else {
            return SendResult(ok: false, detail: "This mailbox isn't an API mailbox.")
        }
        guard var token = EmailTokenStore.load(provider: provider, address: mailbox.fromEmail) else {
            return SendResult(ok: false, detail: "Reconnect \(provider.displayName) for \(mailbox.fromEmail) in Connectors — no OAuth token stored.")
        }
        if token.isExpired, let refreshed = await refresh(token) { token = refreshed }

        // Gmail sends the full RFC-5322 blob, so List-Unsubscribe rides along; Microsoft Graph builds
        // its own JSON message and can't set standard List-* headers via its send API — those sends
        // still carry the compliant in-body CAN-SPAM footer + unsubscribe line.
        let rfc822 = SMTPClient.buildMessage(from: mailbox.fromEmail, fromName: mailbox.fromName,
                                             to: recipient, subject: subject, body: body, extraHeaders: extraHeaders)
        let request: URLRequest?
        switch provider {
        case .gmail:     request = EmailAPI.gmailSendRequest(accessToken: token.accessToken, rfc822: rfc822)
        case .microsoft: request = EmailAPI.graphSendRequest(accessToken: token.accessToken, to: recipient, subject: subject, body: body)
        }
        guard let req = request else { return SendResult(ok: false, detail: "Couldn't build the \(provider.displayName) send request.") }

        // One send; on a 401 (expired between refresh and call) try a single refresh + retry.
        let first = await perform(req, provider: provider)
        if first.status == 401, let refreshed = await refresh(token) {
            let retryReq: URLRequest?
            switch provider {
            case .gmail:     retryReq = EmailAPI.gmailSendRequest(accessToken: refreshed.accessToken, rfc822: rfc822)
            case .microsoft: retryReq = EmailAPI.graphSendRequest(accessToken: refreshed.accessToken, to: recipient, subject: subject, body: body)
            }
            if let rreq = retryReq {
                let second = await perform(rreq, provider: provider)
                return result(from: second, provider: provider, mailbox: mailbox)
            }
        }
        return result(from: first, provider: provider, mailbox: mailbox)
    }

    private struct HTTPOutcome { var status: Int; var bodyMessage: String? }

    private static func perform(_ req: URLRequest, provider: EmailAPIProvider) async -> HTTPOutcome {
        do {
            // Sending the buyer's own mail through the account they connected.
            let (data, resp) = try await ConsentedEgress.sendUngated(req, lane: .ownAccountAPI)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var msg: String? = nil
            if !provider.isSendSuccess(status),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let err = json["error"]
                msg = (err as? [String: Any])?["message"] as? String
                    ?? (err as? String)
                    ?? (json["error_description"] as? String)
            }
            return HTTPOutcome(status: status, bodyMessage: msg)
        } catch {
            return HTTPOutcome(status: 0, bodyMessage: error.localizedDescription)
        }
    }

    private static func result(from o: HTTPOutcome, provider: EmailAPIProvider, mailbox: Mailbox) -> SendResult {
        if provider.isSendSuccess(o.status) {
            return SendResult(ok: true, detail: "Sent from \(mailbox.fromEmail) via \(provider.authKind.transportLabel)")
        }
        let reason = o.bodyMessage.map { " — \($0)" } ?? ""
        return SendResult(ok: false, detail: "\(provider.displayName) send failed (HTTP \(o.status))\(reason)")
    }

    /// Refresh an access token from its refresh token, persist, and return the updated token (or nil).
    static func refresh(_ token: EmailOAuthToken) async -> EmailOAuthToken? {
        guard let rt = token.refreshToken, !rt.isEmpty,
              let req = EmailAPI.refreshRequest(provider: token.provider, clientID: token.clientID, refreshToken: rt) else { return nil }
        do {
            let (data, resp) = try await ConsentedEgress.sendUngated(req, lane: .oauthTokenExchange)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String, !access.isEmpty else { return nil }
            var updated = token
            updated.accessToken = access
            if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty { updated.refreshToken = newRefresh }
            if let expiresIn = json["expires_in"] as? Double { updated.expiresAt = Date().addingTimeInterval(expiresIn) }
            EmailTokenStore.save(updated)
            return updated
        } catch { return nil }
    }
}
#endif // circuit-convert
