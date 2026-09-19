// Sovereign — social sign-in: Sign in with Apple + Google OAuth 2.0 (PKCE) via ASWebAuthenticationSession.
// Honest: if no GoogleClientID is configured, we surface a clear message instead of crashing.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(AuthenticationServices) && !CIRCUIT_WINDOWS_SIM
import AuthenticationServices
#endif
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif

// MARK: - Apple Sign-In capability gate (runtime)
/// Native Sign in with Apple needs a PROVISIONED build: an App ID with the Sign-in-with-Apple
/// capability + a provisioning profile that grants `com.apple.developer.applesignin`, embedded by
/// a real signing identity. An adhoc/dev build CANNOT carry that entitlement (the adhoc build.command
/// deliberately omits it, or AMFI SIGKILLs the app on launch). So we detect at runtime whether the
/// RUNNING binary was actually signed with the entitlement — and only then run the native flow.
/// When absent we still SHOW the Apple button, but tapping gives a clear, non-crashing message.
enum AppleSignInCapability {
    /// True only when the running process is signed with `com.apple.developer.applesignin`
    /// (i.e. a provisioned/Store/Dev-ID-with-profile build). Adhoc builds return false.
    static let isAvailable: Bool = {
        #if os(macOS)
        // SecTask* entitlement introspection is macOS-only — it lets the adhoc/dev build decide
        // whether the running binary actually carries the applesignin entitlement before attempting
        // the native flow (an adhoc build without it would AMFI-SIGKILL).
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        var err: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.applesignin" as CFString, &err)
        err?.release()
        guard let value else { return false }
        // The entitlement is an array of strings (e.g. ["Default"]); presence of any element = granted.
        if let arr = value as? [Any] { return !arr.isEmpty }
        if let b = value as? Bool { return b }
        if let s = value as? String { return !s.isEmpty }
        return false
        #else
        // iOS: SecTaskCreateFromSelf isn't in the iOS SDK. The iOS target now ships the
        // applesignin entitlement (Sources/app-iOS.entitlements, see project.yml CODE_SIGN_ENTITLEMENTS),
        // and a provisioned iOS build ALWAYS carries its declared entitlements at runtime — so the
        // native SignInWithAppleButton can complete. Return true so the real button mounts on iOS
        // (App Store Guideline 4.8 requires native Apple Sign-In when Google sign-in is offered).
        return true
        #endif
    }()
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Google OAuth 2.0 + PKCE
@MainActor
final class GoogleSignIn: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleSignIn()

    private var webSession: ASWebAuthenticationSession?
    private var verifier = ""

    /// Runtime client ID set by the buyer in Settings (preferred), else the Info.plist value.
    /// This keeps the SHIPPED bundle free of any baked-in credential — the buyer supplies their own.
    var runtimeClientID: String = ""
    private var clientID: String {
        let rt = runtimeClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rt.isEmpty { return rt }
        return (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    // Reversed-style custom scheme = bundle id, per the redirect contract.
    private let redirectScheme = "com.blacklabel.sovereign"
    private var redirectURI: String { "com.blacklabel.sovereign:/oauth2redirect" }

    /// Starts the OAuth flow. Calls back on the main actor with the verified email or a friendly error.
    func start(onSuccess: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        let cid = clientID
        guard !cid.isEmpty else {
            onError("Add your Google client ID in settings to enable Google sign-in.")
            return
        }

        // PKCE: code_verifier + S256 challenge (shared impl — see PKCE in OAuthCore.swift).
        verifier = PKCE.randomURLSafe(64)
        let challenge = PKCE.challengeS256(verifier)
        let state = PKCE.randomURLSafe(24)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: cid),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authURL = comps.url else {
            onError("Couldn't start Google sign-in. Please try again.")
            return
        }

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: redirectScheme) { [weak self] callbackURL, error in
            guard let self else { return }
            if let error = error {
                let nsErr = error as NSError
                if nsErr.domain == ASWebAuthenticationSessionError.errorDomain,
                   nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    return // user dismissed — stay silent
                }
                Task { @MainActor in onError("Google sign-in didn't complete. Please try again.") }
                return
            }
            guard let callbackURL,
                  let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                  let code = items.first(where: { $0.name == "code" })?.value,
                  items.first(where: { $0.name == "state" })?.value == state else {
                Task { @MainActor in onError("Google returned an unexpected response. Please try again.") }
                return
            }
            Task { await self.exchange(code: code, clientID: cid, onSuccess: onSuccess, onError: onError) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.webSession = session
        if !session.start() {
            onError("Couldn't open the Google sign-in window. Please try again.")
        }
    }

    private func exchange(code: String, clientID: String,
                          onSuccess: @escaping (String) -> Void,
                          onError: @escaping (String) -> Void) async {
        do {
            // 1) Exchange code -> tokens
            var tokenReq = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
            tokenReq.httpMethod = "POST"
            tokenReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let form: [String: String] = [
                "code": code,
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "grant_type": "authorization_code",
                "code_verifier": verifier
            ]
            tokenReq.httpBody = form.map { "\($0.key)=\(PKCE.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)

            struct TokenResponse: Decodable { let access_token: String }
            let (tData, _) = try await URLSession.shared.data(for: tokenReq)
            guard let token = try? JSONDecoder().decode(TokenResponse.self, from: tData) else {
                await MainActor.run { onError("Google sign-in failed during token exchange. Please try again.") }
                return
            }

            // 2) Fetch userinfo for the verified email
            var infoReq = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
            infoReq.setValue("Bearer \(token.access_token)", forHTTPHeaderField: "Authorization")
            struct UserInfo: Decodable { let email: String? }
            let (uData, _) = try await URLSession.shared.data(for: infoReq)
            let info = try? JSONDecoder().decode(UserInfo.self, from: uData)
            let email = info?.email ?? "google-user"
            await MainActor.run { onSuccess(email) }
        } catch {
            await MainActor.run { onError("Google sign-in failed. Check your connection and try again.") }
        }
    }

    // PKCE helpers now live in the shared `PKCE` enum (OAuthCore.swift) — one impl, no duplication.

    // MARK: ASWebAuthenticationPresentationContextProviding
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
#endif // circuit-convert
