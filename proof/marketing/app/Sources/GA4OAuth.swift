// Black Label Marketing — native Google Analytics desktop OAuth.
//
// Google recommends a loopback-IP redirect for macOS Desktop app OAuth clients. This implementation
// opens Google's consent page in the buyer's browser, receives the one-time code on 127.0.0.1, checks
// state + PKCE, exchanges on-device, and stores the resulting refreshable credential in Keychain.
// Loopback (127.0.0.1) Google OAuth. Requires com.apple.security.network.server, which the
// Mac App Store slice does not ship (App Review 2.4.5(i)) — so this whole flow compiles only
// into the direct-distribution lane. The store build connects GA4 with a pasted access token.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CircuitPortKit
#if os(macOS) && DIRECT_DISTRIBUTION
import AppKit
import CryptoKit
import Foundation
import Security

final class GA4OAuth {
    static let shared = GA4OAuth()

    enum OAuthError: LocalizedError {
        case missingClientID
        case listener(String)
        case browser
        case cancelled(String)
        case stateMismatch
        case badCallback
        case exchange(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .missingClientID: return GA4AnalyticsError.missingClientID.localizedDescription
            case .listener(let detail): return "Could not start the private Google callback (\(detail))."
            case .browser: return "Could not open Google's authorization page."
            case .cancelled(let detail): return detail.isEmpty ? "Google authorization was cancelled." : detail
            case .stateMismatch: return "Google authorization failed its security check. Try again."
            case .badCallback: return "Google did not return a valid authorization code."
            case .exchange(let detail): return "Google authorization could not finish: \(detail)"
            case .timeout: return "Google authorization timed out. Start Connect Google again."
            }
        }
    }

    private var listener: LoopbackCallbackListener?
    private var state = ""
    private var verifier = ""
    private var clientID = ""
    private var redirectURI = ""
    private var completion: ((Result<GA4OAuthCredential, Error>) -> Void)?
    private var timeout: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.blacklabel.marketing.ga4-oauth")

    func connect(clientID rawClientID: String,
                 completion: @escaping (Result<GA4OAuthCredential, Error>) -> Void) {
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { completion(.failure(OAuthError.missingClientID)); return }
        cancelCurrent()
        self.clientID = clientID
        self.state = Self.randomToken()
        self.verifier = Self.randomToken()
        self.completion = completion

        do {
            // The loopback callback socket is OWNED BY THE CHOKE POINT (Sources/ConsentedEgress.swift),
            // on the declared `loopbackOAuthCallback` lane. It binds 127.0.0.1 only, so it cannot
            // accept traffic from the network while consent is open, and nothing leaves through it.
            let listener = try ConsentedEgress.openLoopbackCallbackListener(
                label: "com.blacklabel.marketing.ga4-oauth.callback")
            self.listener = listener
            listener.onReady = { [weak self] port in self?.openConsent(port: port) }
            listener.onFailure = { [weak self] detail in self?.finish(.failure(OAuthError.listener(detail))) }
            listener.onCallback = { [weak self] callback in
                self?.handleCallback(callback) ?? Self.callbackPage(success: false)
            }
            listener.start()
            let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(OAuthError.timeout)) }
            self.timeout = timeout
            queue.asyncAfter(deadline: .now() + 300, execute: timeout)
        } catch {
            finish(.failure(OAuthError.listener(error.localizedDescription)))
        }
    }

    private func openConsent(port: UInt16) {
        redirectURI = "http://127.0.0.1:\(port)"
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        guard let url = GA4Analytics.authorizeURL(clientID: clientID, redirectURI: redirectURI,
                                                  state: state, codeChallenge: challenge) else {
            finish(.failure(OAuthError.missingClientID)); return
        }
        DispatchQueue.main.async {
            if !NSWorkspace.shared.open(url) { self.finish(.failure(OAuthError.browser)) }
        }
    }

    /// The browser's redirect arrived. Returns the page body to answer with; the token exchange
    /// continues asynchronously. Every failure path answers the browser AND finishes the flow.
    private func handleCallback(_ callback: URL) -> String {
        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            finish(.failure(OAuthError.badCallback)); return Self.callbackPage(success: false)
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            finish(.failure(OAuthError.cancelled(value("error_description") ?? error)))
            return Self.callbackPage(success: false)
        }
        guard value("state") == self.state else {
            finish(.failure(OAuthError.stateMismatch)); return Self.callbackPage(success: false)
        }
        guard let code = value("code"), !code.isEmpty else {
            finish(.failure(OAuthError.badCallback)); return Self.callbackPage(success: false)
        }
        exchange(code: code)
        return Self.callbackPage(success: true)
    }

    /// The browser only proves that the authorization callback arrived. The app still has to
    /// exchange the code and complete a live GA4 read before it may claim "connected."
    private static func callbackPage(success: Bool) -> String {
        let title = success ? "Google authorization received" : "Google Analytics was not connected"
        return "<!doctype html><meta charset=utf-8><title>\(title)</title>"
            + "<style>body{font:16px -apple-system;margin:64px;max-width:560px}h1{font-size:28px}</style>"
            + "<h1>\(title)</h1><p>\(success ? "Return to Black Label Marketing. Token exchange and live verification are running now." : "Return to Black Label Marketing and try again.")</p>"
    }

    private func exchange(code: String) {
        guard let request = GA4Analytics.tokenRequest(clientID: clientID, redirectURI: redirectURI,
                                                      code: code, codeVerifier: verifier) else {
            finish(.failure(OAuthError.exchange("could not build token exchange"))); return
        }
        // Code→token exchange with Google's own token endpoint, on the declared
        // `oauthTokenExchange` lane of the egress choke point.
        ConsentedEgress.sendUngated(request, lane: .oauthTokenExchange) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.finish(.failure(OAuthError.exchange(error.localizedDescription))); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200...299).contains(status) else {
                let detail = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .flatMap { ($0["error_description"] as? String) ?? ($0["error"] as? String) }
                    ?? "HTTP \(status)"
                self.finish(.failure(OAuthError.exchange(detail))); return
            }
            do {
                let credential = try GA4Analytics.parseCredential(data, clientID: self.clientID)
                GA4AnalyticsConfig.saveCredential(credential)
                self.finish(.success(credential))
            } catch { self.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<GA4OAuthCredential, Error>) {
        queue.async { [weak self] in
            guard let self, let completion = self.completion else { return }
            self.completion = nil
            self.timeout?.cancel(); self.timeout = nil
            self.listener?.cancel(); self.listener = nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func cancelCurrent() {
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        completion = nil
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
#endif
