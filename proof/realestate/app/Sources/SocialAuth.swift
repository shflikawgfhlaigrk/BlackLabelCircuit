// Black Label Real Estate — social sign-in (Apple + Google OAuth 2.0 / PKCE).
// Standalone, real flows. No third-party SDKs.
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
#if canImport(AuthenticationServices) && !CIRCUIT_WINDOWS_SIM
import AuthenticationServices
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif

// MARK: - Platform copy
// User-visible local-storage / persistence wording differs by platform so iOS reviewers never see
// "Mac". macOS keeps "Mac"; iOS (iPhone/iPad) says the neutral "device". Used in shared auth/settings
// copy that compiles into both targets.
#if os(iOS)
let kThisDeviceWord = "device"
#else
let kThisDeviceWord = "Mac"
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Google OAuth 2.0 + PKCE controller (real flow via ASWebAuthenticationSession)
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleAuth()

    private var session: ASWebAuthenticationSession?
    private let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private let userInfoEndpoint = "https://openidconnect.googleapis.com/v1/userinfo"
    private let redirectScheme = "com.blacklabel.realestate"
    private let redirectURI = "com.blacklabel.realestate:/oauth2redirect"

    static let clientIDDefaultsKey = "blre.googleClientID"

    var clientID: String {
        // User-provided override (Settings) wins, else the Info.plist value.
        if let saved = UserDefaults.standard.string(forKey: GoogleAuth.clientIDDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        return (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // PKCE helpers
    private func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Runs the full authorization-code-with-PKCE flow and returns the user's email.
    func signIn(completion: @escaping (Result<String, Error>) -> Void) {
        let cid = clientID
        guard !cid.isEmpty else {
            completion(.failure(SocialError.noGoogleClientID)); return
        }
        let verifier = randomURLSafe(64)
        let chal = challenge(for: verifier)
        let state = randomURLSafe(16)

        var comps = URLComponents(string: authEndpoint)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: cid),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: chal),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authURL = comps.url else { completion(.failure(SocialError.badURL)); return }

        let s = ASWebAuthenticationSession(url: authURL, callbackURLScheme: redirectScheme) { [weak self] callback, error in
            guard let self = self else { return }
            if let error = error {
                let ns = error as NSError
                if ns.domain == ASWebAuthenticationSessionError.errorDomain &&
                    ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    completion(.failure(SocialError.cancelled))
                } else {
                    completion(.failure(error))
                }
                return
            }
            guard let callback = callback,
                  let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
                completion(.failure(SocialError.noCode)); return
            }
            if let returnedState = items.first(where: { $0.name == "state" })?.value, returnedState != state {
                completion(.failure(SocialError.stateMismatch)); return
            }
            guard let code = items.first(where: { $0.name == "code" })?.value else {
                completion(.failure(SocialError.noCode)); return
            }
            self.exchange(code: code, verifier: verifier, clientID: cid, completion: completion)
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        self.session = s
        DispatchQueue.main.async { s.start() }
    }

    private func exchange(code: String, verifier: String, clientID: String,
                          completion: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
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
        req.httpBody = body.query?.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error { self.finish(.failure(error), completion); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.finish(.failure(SocialError.tokenExchange), completion); return
            }
            guard let accessToken = json["access_token"] as? String else {
                self.finish(.failure(SocialError.tokenExchange), completion); return
            }
            self.fetchUserInfo(accessToken: accessToken, completion: completion)
        }.resume()
    }

    private func fetchUserInfo(accessToken: String,
                               completion: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: URL(string: userInfoEndpoint)!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error { self.finish(.failure(error), completion); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = json["email"] as? String else {
                self.finish(.failure(SocialError.userInfo), completion); return
            }
            self.finish(.success(email), completion)
        }.resume()
    }

    private func finish(_ result: Result<String, Error>,
                        _ completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
#endif // circuit-convert

// MARK: - Apple sign-in availability
// Sign in with Apple needs the `com.apple.developer.applesignin` entitlement, which is only valid
// when the app is signed with a provisioning profile that carries it. The SHIPPING (archived /
// App Store) build HAS it: app.entitlements claims it, the App ID 745ZPGFRA5.com.blacklabel.realestate
// has the Sign in with Apple capability enabled, and the profile carries it (archive done with
// automatic signing + -allowProvisioningUpdates). So in the shipping build the button mounts the
// real native ASAuthorizationAppleIDButton and completes for real.
//
// We STILL detect the entitlement at runtime because the Developer-ID / adhoc lane signs WITHOUT it
// (build.command --devid uses Sources/app-devid.entitlements and embeds no provisioning profile, so
// claiming applesignin there would get the app AMFI-SIGKILLed at launch). In that build the Apple
// button is NOT rendered at all — see `AuthProviders.appleVisible`. It used to render with a note
// saying it "activates in the signed build", which offered a buyer a sign-in that could never
// complete on the artifact they downloaded. A control that cannot work does not ship visible.
enum AppleAuth {
    static var isAvailable: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.applesignin" as CFString, nil)
        if let arr = value as? [String], !arr.isEmpty { return true }
        if let s = value as? String, !s.isEmpty { return true }
        return false
        #else
        // iOS: SecTask entitlement introspection isn't available. The iOS target ships with the
        // Sign-in-with-Apple entitlement (Sources/app-iOS.entitlements) and the App ID carries the
        // capability, so the native SignInWithAppleButton mounts and completes for real. Return true
        // so AuthProviders.apple resolves to .live (the real native control) rather than a stub.
        return true
        #endif
    }
}

// MARK: - Provider button state (pure, unit-tested)
// The sign-in screen shows a provider button ONLY when that provider can actually complete a
// sign-in on THIS artifact. This pure model decides, from the two runtime inputs (is the applesignin
// entitlement present? is a Google client ID configured?), whether each button shows and what it
// does when tapped. Keeping the logic data-only makes the contract testable without any UI.

/// What the Apple button should do when tapped.
enum AppleButtonState: Equatable {
    /// Provisioned build (entitlement present) — the native Sign in with Apple flow runs for real.
    case live
    /// No `com.apple.developer.applesignin` entitlement on this build. The button is not rendered at
    /// all (`AuthProviders.appleVisible` is false); the native control is never instantiated either,
    /// so an unprovisioned build can neither promise nor attempt a flow it cannot finish.
    case unavailableNoEntitlement
}

/// What the Google button should do when tapped.
enum GoogleButtonState: Equatable {
    /// A client ID is configured — tapping runs the real PKCE loopback/custom-scheme flow.
    case live
    /// No client ID yet — button still shows; tapping shows an inline note pointing to Settings → Sign-in.
    case needsClientID
    /// Inline note shown when the user taps a `needsClientID` button (points to where to paste the ID).
    static let needsClientIDNote = "Add a Google client ID in Settings → Google sign-in to enable this. (Use a Desktop OAuth client ID — a Web client won't work for the native flow.)"
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Pure decision layer the AuthView reads: which social buttons show, and what they do when tapped.
struct AuthProviders {
    let appleEntitled: Bool
    let googleClientID: String

    var apple: AppleButtonState { appleEntitled ? .live : .unavailableNoEntitlement }
    var google: GoogleButtonState {
        googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .needsClientID : .live
    }

    /// Whether to SHOW the Apple button at all. Without the applesignin entitlement the native flow
    /// cannot run on this artifact, so the button is hidden rather than shown with a "turns on in
    /// the signed build" note — the buyer of a Developer-ID download can never reach that build.
    /// The App Store / iOS lanes DO carry the entitlement (Sources/app-mas.entitlements,
    /// Sources/app-iOS.entitlements), so the real native button appears there automatically.
    var appleVisible: Bool { appleEntitled }

    /// Whether to SHOW the Google button at all. When no client ID is configured the button would be
    /// dead (tapping only points to Settings), so we hide it on the sign-in screen — reviewers then
    /// see only working sign-in options. It reappears automatically once a client ID is saved.
    var googleVisible: Bool {
        !googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when at least one social button is on screen — the "or" divider above email/password is
    /// only meaningful when something sits above it.
    var anySocialVisible: Bool { appleVisible || googleVisible }

    /// Live snapshot from the running app (entitlement check + configured Google client ID).
    static var live: AuthProviders {
        AuthProviders(appleEntitled: AppleAuth.isAvailable, googleClientID: GoogleAuth.shared.clientID)
    }
}
#endif // circuit-convert

enum SocialError: LocalizedError {
    case noGoogleClientID, badURL, cancelled, noCode, stateMismatch, tokenExchange, userInfo
    var errorDescription: String? {
        switch self {
        case .noGoogleClientID: return "Add your Google client ID in settings to enable Google sign-in."
        case .badURL: return "Couldn't build the Google sign-in request."
        case .cancelled: return "Google sign-in was cancelled."
        case .noCode: return "Google didn't return an authorization code. Try again."
        case .stateMismatch: return "Google sign-in failed a security check. Try again."
        case .tokenExchange: return "Couldn't complete Google sign-in (token exchange failed)."
        case .userInfo: return "Signed in, but couldn't read your Google email. Try again."
        }
    }
}
