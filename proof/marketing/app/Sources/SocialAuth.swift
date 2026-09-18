// Black Label Marketing — social sign-in.
// Sign in with Apple (AuthenticationServices) + real Google OAuth 2.0 + PKCE
// via ASWebAuthenticationSession. No third-party SDKs.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AuthenticationServices) && !CIRCUIT_WINDOWS_SIM
import AuthenticationServices
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#endif

// MARK: - Restricted-entitlement gate (adhoc builds must not show a dead Apple button)

enum AppleSignInGate {
    /// Whether the RUNNING binary actually carries `com.apple.developer.applesignin`.
    /// Adhoc/local-run builds are signed with a run-only entitlement set (sandbox +
    /// network only), so Apple Sign-In is NOT present and the button would no-op/fail.
    /// We only show the Apple button when the entitlement is really there — never a
    /// dead control, never a SIGKILL (provisioning/Developer-ID builds carry it).
    static let isAvailable: Bool = {
#if os(macOS)
        // SecTask* entitlement-introspection is macOS-only. On macOS we gate the Apple button on
        // the running binary actually carrying the applesignin entitlement (adhoc builds don't).
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.applesignin" as CFString, &error)
        if error != nil { return false }
        if let arr = value as? [Any], !arr.isEmpty { return true }
        if let b = value as? Bool { return b }
        return value != nil
#else
        // iOS: no SecTask introspection. The native Sign in with Apple button is supported by the
        // OS regardless of an adhoc local entitlement set, so present it. TODO(iOS): when shipping
        // a provisioned iOS build, this stays true; the simulator simply surfaces the system flow.
        return true
#endif
    }()
}

// MARK: - Sign in with Apple button (SwiftUI, macOS 11+)
//
// The Apple button ALWAYS renders on the sign-in screen (owner requirement — it must never be
// hidden). Behavior splits on whether the RUNNING binary actually carries the applesignin
// entitlement (AppleSignInGate.isAvailable):
//   • Provisioned / Developer-ID build (entitlement present) → the REAL native
//     `SignInWithAppleButton` runs the system flow.
//   • Adhoc / dev build (entitlement absent) → a look-alike Apple button that, when tapped,
//     surfaces a clear NON-CRASH message via `onError`. It deliberately does NOT invoke the
//     native flow, because doing so on a binary without the entitlement AMFI-SIGKILLs the app.
//
// Either way the user sees an Apple button; the adhoc path is honest about needing the signed build.

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct AppleSignInButton: View {
    /// Called with the resolved email (or "apple-user" when hidden) on success.
    let onEmail: (String) -> Void
    /// Called with a friendly message on failure / when Apple can't run on this build.
    let onError: (String) -> Void

    var body: some View {
        if AppleSignInGate.isAvailable {
            nativeButton
        } else {
            inertButton
        }
    }

    /// The genuine system button — only mounted when the entitlement is present, so it never
    /// triggers the AMFI SIGKILL path on adhoc builds.
    private var nativeButton: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            switch result {
            case .success(let auth):
                if let cred = auth.credential as? ASAuthorizationAppleIDCredential {
                    let email = cred.email?.trimmingCharacters(in: .whitespaces)
                    onEmail(email?.isEmpty == false ? email! : "apple-user")
                } else {
                    onEmail("apple-user")
                }
            case .failure(let error):
                if (error as NSError).code == ASAuthorizationError.canceled.rawValue {
                    onError("Apple sign-in was cancelled.")
                } else {
                    onError("Apple sign-in couldn't be completed. Please try again.")
                }
            }
        }
        .signInWithAppleButtonStyle(.white)
        // Guideline 4.8: keep the native Apple option visually equivalent to the
        // Google option below it. Without maxWidth the AppKit-backed native control
        // shrinks to its intrinsic width in the 330pt sign-in column.
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .clipShape(Capsule())
    }

    /// Adhoc/dev fallback: visually a white "Sign in with Apple" button, but tapping shows a clear
    /// message instead of invoking the native flow (which would crash an unentitled binary).
    private var inertButton: some View {
        Button {
            onError("Apple Sign-In activates in the signed build.")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo").font(.system(size: 15, weight: .medium))
                Text("Sign in with Apple").font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(Color.white).clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Apple Sign-In activates in the provisioned (signed) build of this app.")
    }
}
#endif // circuit-convert

// MARK: - Google OAuth 2.0 + PKCE via ASWebAuthenticationSession

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {

    enum GoogleError: Error { case noClientID, badResponse, cancelled, exchange }

    static let shared = GoogleAuth()
    private var session: ASWebAuthenticationSession?

    /// UserDefaults key the Settings screen writes the buyer's own Google OAuth client ID to.
    static let clientIDDefaultsKey = "GoogleClientID"

    /// The active Google OAuth client ID. Resolved at runtime so the buyer can enable
    /// Google sign-in from Settings without rebuilding: a value saved in UserDefaults
    /// (Settings → Sign-in) takes precedence; otherwise we fall back to any value baked
    /// into Info.plist at build time. Ships empty, so Google stays hidden until configured.
    static var clientID: String {
        let saved = (UserDefaults.standard.string(forKey: clientIDDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty { return saved }
        return (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String) ?? ""
    }
    static var isConfigured: Bool { !clientID.trimmingCharacters(in: .whitespaces).isEmpty }

    // bundle id reversed-style custom scheme
    private let redirectScheme = "com.blacklabel.marketing"
    private var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    /// Runs the full code -> token -> userinfo flow and returns the email.
    func signIn(completion: @escaping (Result<String, Error>) -> Void) {
        let clientID = GoogleAuth.clientID.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else { completion(.failure(GoogleError.noClientID)); return }

        // PKCE
        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.makeCodeVerifier()

        var comp = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comp.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authURL = comp.url else { completion(.failure(GoogleError.badResponse)); return }

        let s = ASWebAuthenticationSession(url: authURL, callbackURLScheme: redirectScheme) { [weak self] callback, error in
            guard let self = self else { return }
            if let error = error {
                if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    DispatchQueue.main.async { completion(.failure(GoogleError.cancelled)) }
                } else {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
                return
            }
            guard let callback = callback,
                  let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                  let code = items.first(where: { $0.name == "code" })?.value,
                  items.first(where: { $0.name == "state" })?.value == state else {
                DispatchQueue.main.async { completion(.failure(GoogleError.badResponse)) }
                return
            }
            self.exchange(code: code, verifier: verifier, clientID: clientID, completion: completion)
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = true
        self.session = s
        DispatchQueue.main.async { s.start() }
    }

    private func exchange(code: String, verifier: String, clientID: String,
                          completion: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.timeoutInterval = 20
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        // Google's own token endpoint — the declared `oauthTokenExchange` lane.
        ConsentedEgress.sendUngated(req, lane: .oauthTokenExchange) { [weak self] data, _, error in
            if let error = error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else {
                DispatchQueue.main.async { completion(.failure(GoogleError.exchange)) }
                return
            }
            self?.userInfo(accessToken: token, completion: completion)
        }
    }

    private func userInfo(accessToken: String,
                          completion: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // Google's OpenID userinfo endpoint, read once to name the account just connected.
        ConsentedEgress.sendUngated(req, lane: .oauthTokenExchange) { data, _, error in
            if let error = error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = json["email"] as? String, !email.isEmpty else {
                DispatchQueue.main.async { completion(.failure(GoogleError.badResponse)) }
                return
            }
            DispatchQueue.main.async { completion(.success(email)) }
        }
    }

    // MARK: PKCE helpers
    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }
    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Presentation context
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Own-it social OAuth session (all networks; redirect hosted by us, token minted on-device)
//
// Generalizes the Google flow above to every supported network. "Link" runs a real
// ASWebAuthenticationSession against the buyer's OWN provider app; the provider redirects to OUR
// hosted bounce (SocialOAuth.redirectURI), which forwards the ?code to this app's custom scheme,
// which the session captures — so the buyer NEVER pastes a token and NEVER hosts a redirect. The
// code→token exchange then runs HERE, on the buyer's device, with the buyer's own client secret
// (confidential providers) and/or PKCE verifier — the token is never seen by our servers.
final class SocialOAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum OAuthError: LocalizedError {
        case noAppID, cancelled, badCallback, stateMismatch, exchange(String), badToken
        var errorDescription: String? {
            switch self {
            case .noAppID:        return "Enter your own App ID first."
            case .cancelled:      return "Sign-in was cancelled."
            case .badCallback:    return "The sign-in didn't return a valid response."
            case .stateMismatch:  return "Sign-in response failed a security check — please try again."
            case .exchange(let m): return "Couldn't complete sign-in: \(m)"
            case .badToken:       return "The provider didn't return an access token."
            }
        }
    }

    struct Token { var accessToken: String; var refreshToken: String?; var raw: [String: Any] }

    static let shared = SocialOAuthSession()
    private var session: ASWebAuthenticationSession?

    /// Run the full authorize → bounce → on-device exchange flow. `appSecret` is required only for
    /// confidential providers (IG/Threads/Facebook/LinkedIn/YouTube — secret in the form body;
    /// Pinterest — secret as HTTP Basic client auth, built by SocialOAuth.tokenRequest); X uses
    /// PKCE alone (no secret). Pinterest also sends PKCE alongside its secret.
    func connect(platform: SocialPlatform, appID: String, appSecret: String?,
                 completion: @escaping (Result<Token, Error>) -> Void) {
        let id = appID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, let prov = SocialOAuth.provider(for: platform) else {
            completion(.failure(OAuthError.noAppID)); return
        }
        let state = SocialOAuth.makeState()
        let verifier = prov.usesPKCE ? SocialOAuth.makeCodeVerifier() : nil
        let challenge = verifier.map { SocialOAuth.codeChallenge(for: $0) }
        guard let authURL = SocialOAuth.authorizeURL(platform: platform, appID: id, state: state, codeChallenge: challenge) else {
            completion(.failure(OAuthError.noAppID)); return
        }
        let s = ASWebAuthenticationSession(url: authURL, callbackURLScheme: SocialOAuth.callbackScheme) { [weak self] cb, err in
            guard let self = self else { return }
            if let err = err {
                let code = (err as NSError).code
                if code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    DispatchQueue.main.async { completion(.failure(OAuthError.cancelled)) }
                } else {
                    DispatchQueue.main.async { completion(.failure(err)) }
                }
                return
            }
            guard let cb = cb, let items = URLComponents(url: cb, resolvingAgainstBaseURL: false)?.queryItems else {
                DispatchQueue.main.async { completion(.failure(OAuthError.badCallback)) }; return
            }
            func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
            if let e = q("error") {
                DispatchQueue.main.async { completion(.failure(OAuthError.exchange(q("error_description") ?? e))) }; return
            }
            guard q("state") == state else { DispatchQueue.main.async { completion(.failure(OAuthError.stateMismatch)) }; return }
            guard let code = q("code") else { DispatchQueue.main.async { completion(.failure(OAuthError.badCallback)) }; return }
            self.exchange(platform: platform, appID: id, appSecret: appSecret, code: code, verifier: verifier, completion: completion)
        }
        s.presentationContextProvider = self
        // Use the buyer's existing logged-in web session so they don't have to re-enter credentials.
        s.prefersEphemeralWebBrowserSession = false
        self.session = s
        DispatchQueue.main.async { s.start() }
    }

    private func exchange(platform: SocialPlatform, appID: String, appSecret: String?, code: String,
                          verifier: String?, completion: @escaping (Result<Token, Error>) -> Void) {
        guard let req = SocialOAuth.tokenRequest(platform: platform, appID: appID, appSecret: appSecret,
                                                 code: code, codeVerifier: verifier) else {
            DispatchQueue.main.async { completion(.failure(OAuthError.exchange("couldn't build the token request"))) }; return
        }
        // The social platform's own token endpoint — declared `oauthTokenExchange` lane. What the
        // token is then used FOR (publishing, insights) goes through the CONSENT door.
        ConsentedEgress.sendUngated(req, lane: .oauthTokenExchange) { data, _, err in
            if let err = err { DispatchQueue.main.async { completion(.failure(err)) }; return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(.failure(OAuthError.exchange("no response"))) }; return
            }
            if let token = json["access_token"] as? String, !token.isEmpty {
                let t = Token(accessToken: token, refreshToken: json["refresh_token"] as? String, raw: json)
                DispatchQueue.main.async { completion(.success(t)) }
            } else {
                let msg = (json["error_description"] as? String) ?? (json["error"] as? String)
                    ?? ((json["error"] as? [String: Any])?["message"] as? String) ?? "no access token"
                DispatchQueue.main.async { completion(.failure(OAuthError.exchange(msg))) }
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        #endif
    }
}
#endif // circuit-convert
