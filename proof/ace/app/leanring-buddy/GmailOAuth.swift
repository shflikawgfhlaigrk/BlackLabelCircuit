#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(AuthenticationServices) && !CIRCUIT_WINDOWS_SIM
import AuthenticationServices
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum GmailOAuthError: Error, LocalizedError {
    case cancelled, invalidCallback, unavailable, denied, missingPermission, reconnect, accountChanged
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Google sign-in was cancelled. Your existing email account is unchanged."
        case .invalidCallback: return "Google sign-in returned to a different connection attempt. Try Connect with Google again."
        case .unavailable: return "Google connection did not finish. Check your internet connection and try again."
        case .denied: return "Google did not allow this Gmail connection. Your Google account or administrator may need to allow Ace."
        case .missingPermission: return "Allow Gmail access on Google's consent screen so Ace can read your inbox and save drafts."
        case .reconnect: return "Google needs you to reconnect this Gmail account in Email settings."
        case .accountChanged: return "The email account changed while connecting. Your current account was preserved."
        }
    }
}

enum GmailOAuthPolicy {
    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GmailOAuthError.unavailable }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func startURL(nonce: String, verifier: String) -> URL {
        var components = URLComponents(string: "https://ace-bl.tech/api/gmail/start")!
        components.queryItems = [URLQueryItem(name: "nonce", value: nonce), URLQueryItem(name: "challenge", value: challenge(verifier))]
        return components.url!
    }
    static func exchangeValues(callback: URL, nonce: String, verifier: String, now: Date = Date()) throws -> [String: String] {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == "ace-gmail", components.host == "oauth", components.path == "/callback",
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil else { throw GmailOAuthError.invalidCallback }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              let state = items.first(where: { $0.name == "state" })?.value else { throw GmailOAuthError.invalidCallback }
        let parts = state.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "gm1", state.utf8.count <= 2048 else { throw GmailOAuthError.invalidCallback }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              claims["n"] as? String == nonce, claims["c"] as? String == challenge(verifier),
              let expires = claims["exp"] as? Double,
              expires >= now.timeIntervalSince1970, expires <= now.timeIntervalSince1970 + 600 else { throw GmailOAuthError.invalidCallback }
        if let error = items.first(where: { $0.name == "error" })?.value { throw error == "cancelled" ? GmailOAuthError.cancelled : GmailOAuthError.denied }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.utf8.count <= 8192 else { throw GmailOAuthError.invalidCallback }
        return ["code": code, "state": state, "verifier": verifier]
    }
}

enum GmailOAuthAPI {
    private struct TokenResponse: Decodable { let address: String; let accessToken: String; let refreshToken: String; let expiresIn: Double }
    static func request(_ operation: String, body: [String: String]) async throws -> GmailAccountCredential {
        guard operation == "exchange" || operation == "refresh" else { throw GmailOAuthError.unavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://ace-bl.tech/api/gmail/" + operation)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard data.count <= 32768, let http = response as? HTTPURLResponse else { throw GmailOAuthError.unavailable }
        guard http.statusCode == 200 else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            switch reason {
            case "gmail_permission", "offline_permission": throw GmailOAuthError.missingPermission
            case "reconnect": throw GmailOAuthError.reconnect
            default: throw GmailOAuthError.unavailable
            }
        }
        let value = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard case .success(let address) = GmailAccountPolicy.normalizedAddress(value.address),
              address == value.address, value.expiresIn >= 60, value.expiresIn <= 86400,
              [value.accessToken, value.refreshToken].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 && !$0.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) }) else { throw GmailOAuthError.unavailable }
        return GmailAccountCredential(address: address, appPassword: "", oauth: GmailOAuthCredential(accessToken: value.accessToken, refreshToken: value.refreshToken, expiresAt: Date().addingTimeInterval(value.expiresIn)))
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}

@MainActor protocol GmailGoogleConnecting: AnyObject {
    func connect() async throws -> GmailAccountCredential
    func cancel()
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor final class GmailGoogleConnection: NSObject, GmailGoogleConnecting, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var anchor: NSWindow?
    private var attempt: UUID?

    func connect() async throws -> GmailAccountCredential {
        cancel()
        guard !StealthVisibilityGate.shared.isActive, !StealthEntryLatch.shared.isRaised,
              let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { throw GmailOAuthError.unavailable }
        anchor = window
        let attempt = UUID()
        self.attempt = attempt
        let nonce = try GmailOAuthPolicy.randomValue(), verifier = try GmailOAuthPolicy.randomValue()
        let callback: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: GmailOAuthPolicy.startURL(nonce: nonce, verifier: verifier), callbackURLScheme: "ace-gmail") { [weak self] url, error in
                    Task { @MainActor in
                        guard self?.attempt == attempt else { return }
                        if let url { self?.finish(.success(url)) }
                        else { self?.finish(.failure((error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? GmailOAuthError.cancelled : GmailOAuthError.unavailable)) }
                    }
                }
                self.session = session
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                if !session.start() { finish(.failure(GmailOAuthError.unavailable)); return }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(600)) } catch { return }
                    guard self?.attempt == attempt else { return }
                    self?.cancel()
                }
            }
        } onCancel: { Task { @MainActor [weak self] in
            guard self?.attempt == attempt else { return }; self?.cancel()
        } }
        try Task.checkCancellation()
        return try await GmailOAuthAPI.request("exchange", body: GmailOAuthPolicy.exchangeValues(callback: callback, nonce: nonce, verifier: verifier))
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor! }
    func cancel() {
        let current = session
        finish(.failure(GmailOAuthError.cancelled))
        current?.cancel()
    }
    private func finish(_ result: Result<URL, Error>) {
        let pending = continuation
        continuation = nil; session = nil; attempt = nil
        timeout?.cancel(); timeout = nil
        pending?.resume(with: result)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension GmailAccountStore {
    @MainActor func loadUsableCredential() async throws -> GmailAccountCredential? {
        guard !StealthVisibilityGate.shared.isActive, !StealthEntryLatch.shared.isRaised else { throw CancellationError() }
        guard let saved = try loadCredential() else { return nil }
        guard let oauth = saved.oauth, oauth.expiresAt <= Date().addingTimeInterval(90) else { return saved }
        let refreshed = try await GmailOAuthAPI.request("refresh", body: ["refreshToken": oauth.refreshToken])
        try Task.checkCancellation()
        guard !StealthVisibilityGate.shared.isActive, !StealthEntryLatch.shared.isRaised else { throw CancellationError() }
        guard try loadCredential() == saved, refreshed.address == saved.address else { throw GmailOAuthError.accountChanged }
        try save(refreshed)
        return refreshed
    }
}
#endif // circuit-convert
