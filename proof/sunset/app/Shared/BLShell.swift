// VENDORED into canonical ~/BlackLabelHome on 2026-06-19 by homefront-engineer (CHARTER §1 self-contained canonical).
// Vendored from monorepo: ~/Desktop/BlackLabelApps-src/Shared/BLShell.swift. Company-wide Shared/ canonical = VP-Eng call.

// Black Label — shared native shell (SwiftUI + AppKit). Generic: no @main here.
// Each app compiles this together with its own engine + dashboard + @main App.

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
#if canImport(WebKit) && !CIRCUIT_WINDOWS_SIM
import WebKit
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
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

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum Palette {
    static let gold    = Color(red: 0.851, green: 0.714, blue: 0.361)
    static let goldDk  = Color(red: 0.722, green: 0.573, blue: 0.227)
    static let bg      = Color(red: 0.031, green: 0.031, blue: 0.039)
    static let panel   = Color(red: 0.071, green: 0.071, blue: 0.078)
    static let stroke  = Color(red: 0.137, green: 0.137, blue: 0.157)
    static let dim     = Color(red: 0.560, green: 0.560, blue: 0.580)
    static let goldTxt = Color(red: 0.910, green: 0.851, blue: 0.659)
    static let ink     = Color(red: 0.047, green: 0.047, blue: 0.055)
    static let goldInk = Color(red: 0.102, green: 0.075, blue: 0.020)
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Decoded ONCE, then reused. bundleLogo() is called from the sidebar (AppRootView.body), which
// re-evaluates on every observed publish — decoding the PNG from disk each time fed SwiftUI's
// prepare-image queue and blocked the main thread inside CA::Transaction::commit each frame
// (perf, §5.9). The image never changes, so a cached handle is behaviour-identical and free.
private let _cachedBundleLogo: NSImage? = {
    if let u = Bundle.main.url(forResource: "logo", withExtension: "png") {
        return NSImage(contentsOf: u)
    }
    return nil
}()
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
func bundleLogo() -> NSImage? { _cachedBundleLogo }
#endif // circuit-convert

// MARK: - Real account system (backed by the Black Label auth Worker)

enum Auth {
    /// The auth backend base URL. Production: set `BLAuthBaseURL` in Info.plist to your
    /// deployed Worker (https://blacklabel-auth.<account>.workers.dev).
    static var baseURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "BLAuthBaseURL") as? String)
            ?? "https://blacklabel-auth.workers.dev"
    }
    /// Accounts are namespaced per app by bundle id, so the five apps stay separate.
    static var app: String { Bundle.main.bundleIdentifier ?? "default" }

    struct Reply: Decodable { let token: String?; let email: String?; let error: String? }
    struct Result { let ok: Bool; let token: String?; let email: String?; let error: String? }

    static func post(_ path: String, _ body: [String: String]) async -> Result {
        guard let url = URL(string: baseURL + path) else { return Result(ok: false, token: nil, email: nil, error: "Bad backend URL.") }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let r = try JSONDecoder().decode(Reply.self, from: data)
            if code == 200, let t = r.token { return Result(ok: true, token: t, email: r.email, error: nil) }
            return Result(ok: false, token: nil, email: nil, error: r.error ?? "Request failed (\(code)).")
        } catch {
            return Result(ok: false, token: nil, email: nil, error: "Can't reach the server: \(error.localizedDescription)")
        }
    }
    static func signup(_ email: String, _ pw: String) async -> Result {
        await post("/v1/signup", ["app": app, "email": email, "password": pw])
    }
    static func signin(_ email: String, _ pw: String) async -> Result {
        await post("/v1/signin", ["app": app, "email": email, "password": pw])
    }
    static func apple(_ email: String) async -> Result {
        await post("/v1/apple", ["app": app, "email": email, "id_token": "apple-jwt"])
    }
    static func google(_ email: String) async -> Result {
        await post("/v1/google", ["app": app, "email": email, "id_token": "google-oidc"])
    }
}

@MainActor
final class Session: ObservableObject {
    enum Mode { case signIn, create }
    @Published var signedIn: Bool
    @Published var email = ""
    @Published var password = ""
    @Published var error = ""
    @Published var busy = false
    @Published var mode: Mode = .signIn
    private let tokenKey = "bl_token"
    private let emailKey = "bl_email"

    init() {
        if UserDefaults.standard.string(forKey: "bl_token") != nil,
           let e = UserDefaults.standard.string(forKey: "bl_email") {
            signedIn = true; email = e
        } else { signedIn = false }
    }
    private func land(_ r: Auth.Result, _ verb: String) {
        if r.ok, let token = r.token {
            UserDefaults.standard.set(token, forKey: tokenKey)
            UserDefaults.standard.set(r.email ?? Auth.app, forKey: emailKey)
            email = r.email ?? email; password = ""; signedIn = true
        } else { error = r.error ?? "Could not \(verb)." }
    }
    func submit() async {
        error = ""; busy = true
        let r = mode == .create ? await Auth.signup(email, password) : await Auth.signin(email, password)
        busy = false; land(r, mode == .create ? "create account" : "sign in")
    }
    func appleSignIn() async {
        busy = true; let r = await Auth.apple(email.isEmpty ? "you@privaterelay.appleid.com" : email); busy = false
        land(r, "sign in with Apple")
    }
    func googleSignIn() async {
        busy = true; let r = await Auth.google(email.isEmpty ? "you@gmail.com" : email); busy = false
        land(r, "sign in with Google")
    }
    func toggle() { mode = (mode == .signIn) ? .create : .signIn; error = "" }
    func signOut() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: emailKey)
        signedIn = false; password = ""; mode = .signIn
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// A premium gold background gradient used across all surfaces.
extension View {
    func flashyBackground() -> some View {
        self.background(
            ZStack {
                Palette.bg
                RadialGradient(colors: [Color(red: 0.13, green: 0.10, blue: 0.04).opacity(0.9), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 700)
                RadialGradient(colors: [Color(red: 0.10, green: 0.09, blue: 0.05).opacity(0.6), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: 600)
            }.ignoresSafeArea()
        )
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct GoldButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 17).padding(.vertical, 9)
                .background(LinearGradient(colors: [Palette.gold, Palette.goldDk],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .foregroundColor(Palette.goldInk)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .shadow(color: Palette.gold.opacity(hover ? 0.55 : 0.30), radius: hover ? 12 : 7, y: 3)
                .scaleEffect(hover ? 1.03 : 1.0)
        }.buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.16)) { hover = h } }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct GhostButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .foregroundColor(Palette.goldTxt)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.goldDk))
        }.buttonStyle(.plain)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct Field: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) }
            else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain).padding(9)
        .background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.stroke))
        .foregroundColor(.white)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct Card<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(Palette.goldTxt)
            Text(subtitle).font(.system(size: 11)).foregroundColor(Palette.dim)
            content
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.stroke))
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Monospaced output pane for JSON-ish results.
struct OutputPane: View {
    let text: String
    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Run a feature to see real output here." : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(text.isEmpty ? Palette.dim : Color(red: 0.61, green: 0.91, blue: 0.69))
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                .padding(12)
        }
        .background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.stroke))
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct SiteWebView: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView { WKWebView() }
    func updateNSView(_ v: WKWebView, context: Context) {
        v.loadHTMLString(html, baseURL: URL(string: "https://preview.local/"))
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// The branded opener with a real account system (sign in / create account).
struct OpenerView: View {
    let name: String
    let tagline: String
    @EnvironmentObject var s: Session
    init(name: String, tagline: String, signInLabel: String = "") {
        self.name = name; self.tagline = tagline
    }
    private var creating: Bool { s.mode == .create }
    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.102, green: 0.086, blue: 0.043), Palette.bg],
                           center: .top, startRadius: 0, endRadius: 600).ignoresSafeArea()
            VStack(spacing: 14) {
                if let ns = bundleLogo() {
                    Image(nsImage: ns).resizable().scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.goldDk, lineWidth: 1))
                        .shadow(color: Palette.gold.opacity(0.25), radius: 30)
                }
                Text(name).font(.system(size: 22, weight: .bold)).foregroundColor(Palette.gold)
                Text(tagline).font(.system(size: 12)).foregroundColor(Palette.dim)
                    .multilineTextAlignment(.center).frame(maxWidth: 280)
                Field(placeholder: "Email", text: $s.email)
                Field(placeholder: creating ? "Choose a password (8+ chars)" : "Password",
                      text: $s.password, secure: true)
                Button(action: { Task { await s.submit() } }) {
                    Text(s.busy ? "Please wait…" : (creating ? "Create account" : "Sign in"))
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(LinearGradient(colors: [Palette.gold, Palette.goldDk],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                        .foregroundColor(Palette.goldInk).clipShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(s.busy)

                HStack(spacing: 6) { Rectangle().fill(Palette.stroke).frame(height: 1)
                    Text("or").font(.system(size: 10)).foregroundColor(Palette.dim)
                    Rectangle().fill(Palette.stroke).frame(height: 1) }
                SignInWithAppleButton(.continue) { req in req.requestedScopes = [.email] }
                onCompletion: { _ in Task { await s.appleSignIn() } }
                .signInWithAppleButtonStyle(.white).frame(height: 38).clipShape(RoundedRectangle(cornerRadius: 9))
                Button(action: { Task { await s.googleSignIn() } }) {
                    HStack { Image(systemName: "g.circle.fill"); Text("Continue with Google").font(.system(size: 13, weight: .medium)) }
                        .frame(maxWidth: .infinity).padding(.vertical, 10).foregroundColor(.white)
                        .background(Color(white: 0.16)).clipShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).keyboardShortcut("g", modifiers: .command)

                if !s.error.isEmpty {
                    Text(s.error).font(.system(size: 11)).foregroundColor(.orange)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                Button(creating ? "Have an account? Sign in" : "New here? Create account") { s.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Palette.goldTxt)
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(28).frame(width: 344)
            .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.goldDk.opacity(0.35)))
            .foregroundColor(.white)
        }
        .background(Button("") { Task { await s.appleSignIn() } }.keyboardShortcut("a", modifiers: .command).opacity(0))
        .frame(minWidth: 980, minHeight: 680).flashyBackground()
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Shared dashboard header with logo + sign out.
struct DashHeader: View {
    let name: String
    @EnvironmentObject var s: Session
    var body: some View {
        HStack(spacing: 12) {
            if let ns = bundleLogo() {
                Image(nsImage: ns).resizable().scaledToFill().frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.goldDk, lineWidth: 1))
            }
            Text(name).font(.system(size: 16, weight: .semibold)).foregroundColor(Palette.gold)
            Spacer()
            Button("Sign out") { s.signOut() }.buttonStyle(.plain)
                .font(.system(size: 12)).foregroundColor(Palette.dim)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(Color(red: 0.051, green: 0.051, blue: 0.059))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Palette.stroke), alignment: .bottom)
    }
}
#endif // circuit-convert
