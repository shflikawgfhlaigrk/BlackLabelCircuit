// VENDORED into canonical ~/BlackLabelHome on 2026-06-19 by homefront-engineer (CHARTER §1 self-contained canonical).
// Vendored from monorepo: ~/Desktop/BlackLabelApps-src/Shared/BLShell.swift. Company-wide Shared/ canonical = VP-Eng call.

// Black Label — shared native shell (SwiftUI + AppKit). Generic: no @main here.
// Each app compiles this together with its own engine + dashboard + @main App.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(WebKit) && !CIRCUIT_WINDOWS_SIM
import WebKit
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif

// VIGIL-LOCAL DIVERGENCE (2026-08-03) — the shared shell's ACCOUNT SYSTEM has been
// removed from this vendored copy. See the "Account system" note below and
// tests/test_privacy_credential_contract.py. CryptoKit / AuthenticationServices /
// Security are no longer imported because nothing here uses them any more.

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

// MARK: - Account system: DELIBERATELY ABSENT from Vigil (§5.1 truthfulness)
//
// The upstream shared shell carried a real account system here: `Auth` (POSTed
// {app, email, password} to https://blacklabel-auth.<account>.workers.dev),
// `BLKeychain`, `Session`, `OpenerView`, and `DashHeader`.
//
// It was REMOVED from this vendored copy on 2026-08-03. Rationale:
//   * Vigil has NO sign-in surface. Nothing in the macOS target ever instantiated
//     `Session`, so not one byte was ever transmitted by it — but the code was
//     compiled into the shipping binary, one `@StateObject var s = Session()`
//     away from being live.
//   * PrivacyInfo.xcprivacy declares NSPrivacyCollectedDataTypes = [] ("collects
//     nothing"). The moment that dormant code gained a caller, the manifest would
//     have become false, and false in the worst possible way: an undeclared
//     transmission of an email address and a password to a developer-owned server.
//   * A privacy manifest must describe what the code CAN do, not what today's call
//     graph happens to avoid. Deleting the capability is the only fix that cannot
//     silently rot; "currently unreachable" is not a guarantee.
//
// Buy → access / account wiring for Vigil is an owner-only founder gate. If it is
// ever built, it must be declared in PrivacyInfo.xcprivacy IN THE SAME CHANGE.
// tests/test_privacy_credential_contract.py fails the gate if credential-carrying
// network code reappears in the macOS target while the manifest still claims
// nothing is collected.

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

// `OpenerView` (the email + password sign-in screen) and `DashHeader` (its "Sign out"
// affordance) were removed together with `Session` on 2026-08-03 — see the account-system
// note above. They were the UI half of the same dormant credential path: OpenerView bound
// `SecureField` straight to `Session.password` and drove `Auth.signup`/`Auth.signin`.
// Vigil renders its own dashboard chrome (HomeViews.swift) and has no sign-in screen.
