#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct AuthView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var creating = false
    @State private var email = ""
    @State private var pw = ""
    @State private var err = ""
    @State private var appear = false
    /// "Remember me" — default OFF, so unchecked launch behavior is unchanged. When ON and the
    /// buyer signs into a REAL identity, the session is persisted in the Keychain and auto-restored
    /// on next launch (see SessionStore + RootView.onAppear). Never set for guest/demo.
    @State private var rememberMe = false

    var body: some View {
        ZStack {
            // Living holographic background + drifting motes (the first impression).
            // Both are click-transparent (struct-level + here) so the sign-in controls always tap.
            AuroraBackdrop().ignoresSafeArea().allowsHitTesting(false)
            ParticleField().ignoresSafeArea().allowsHitTesting(false)

            #if os(iOS)
            // Compact phones: the card must compress and scroll — with the keyboard up the
            // Sign in / guest / demo buttons would otherwise be unreachable.
            ScrollView(showsIndicators: false) {
                authCard
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            #else
            authCard
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 640)
        #endif
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { appear = true }
        }
    }

    private var authCard: some View {
            VStack(spacing: 18) {
                Logo(size: 92)
                    .scaleEffect(appear ? 1 : 0.9)
                    .holoSheen()
                VStack(spacing: 5) {
                    FoilText(AppBrand.displayName, size: 26, weight: .heavy, serif: false)
                    Text(AppBrand.authSubtitle).font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 330)
                }
                HStack(spacing: 4) {
                    seg("Sign in", on: !creating) { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { creating = false }; err = "" }
                    seg("Create account", on: creating) { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { creating = true }; err = "" }
                }
                .padding(4).background(BLTheme.bg2).clipShape(Capsule()).overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))

                // Social sign-in (above email/password, like top apps).
                // BOTH buttons ALWAYS render — never hidden (owner requirement). Each is honest
                // about what it can do on THIS build:
                //   • Apple: native flow on a provisioned build; on adhoc the button still shows but
                //     tapping gives a clear, non-crash note (AppleSignInButton handles that split).
                //   • Google: real OAuth when a client ID is configured (Settings → Sign-in);
                //     otherwise tapping points the buyer to Settings — never a dead/no-op button.
                VStack(spacing: 10) {
                    AppleSignInButton(
                        onEmail: { e in session.email = e; err = ""; enter() },
                        onError: { m in withAnimation { err = m } }
                    )
                    Button(action: googleSignIn) {
                        HStack(spacing: 8) {
                            GoogleGlyph().frame(width: 16, height: 16)
                            Text("Sign in with Google").font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Color.white).clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(GoogleAuth.isConfigured
                          ? "Sign in with your Google account."
                          : "Add your Google client ID in Settings → Sign-in to enable this.")
                }
                .frame(maxWidth: 330)

                HStack(spacing: 8) {
                    Rectangle().fill(BLTheme.stroke).frame(height: 1)
                    Text("or").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    Rectangle().fill(BLTheme.stroke).frame(height: 1)
                }
                .frame(maxWidth: 330)

                VStack(spacing: 12) {
                    Field(title: "Email", text: $email, prompt: "you@company.com")
                    Field(title: "Password", text: $pw, prompt: "••••••••")
                    // "Remember me" — keeps you signed in across launches in Marketing's private
                    // on-device store with a 30-day expiry. Applies to real sign-ins, never guest.
                    Button { rememberMe.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: rememberMe ? "checkmark.square.fill" : "square")
                                .font(.system(size: 14, weight: .semibold)).foregroundColor(rememberMe ? BLTheme.gold : BLTheme.sub)
                            Text("Remember me on this device").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stay signed in across launches. Stored privately on this Mac for 30 days; turn off any time by signing out.")
                    GoldButton(label: creating ? "Create account" : "Sign in", fill: true, icon: "arrow.right") { submit() }
                        .holoSheen().glowPulse()
                    if !err.isEmpty {
                        Text(err).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.danger).multilineTextAlignment(.center)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    Button("Continue as guest") { session.email = "guest"; enter() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    #if os(macOS)
                    // §5.1: accounts here are a workspace label, not a lock. The workspace is
                    // device-scoped and opens identically for every sign-in — say so up front.
                    Text("Sign-in sets who you're working as. Your workspace lives on this Mac and opens the same for any sign-in here, including guest.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    #endif
                }
                .frame(maxWidth: 330)

                // Reviewer / buyer path: experience the FULL app with sample data and
                // ZERO external accounts. Seeds an isolated, clearly-labeled demo
                // workspace (separate store) and enters — no sign-in, no mailbox.
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Rectangle().fill(BLTheme.stroke).frame(height: 1)
                        Text("just looking?").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                        Rectangle().fill(BLTheme.stroke).frame(height: 1)
                    }
                    Button(action: exploreDemo) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").font(.system(size: 13, weight: .bold))
                            Text("Explore with sample data").font(.system(size: 14, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(BLTheme.gold)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(BLTheme.gold.opacity(0.10)).clipShape(Capsule())
                        .overlay(Capsule().stroke(BLTheme.gold.opacity(0.55), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                    .help("Tour the full app with clearly-labeled sample data — no account, no email, nothing sent.")
                    Text("No account needed · nothing is sent")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                .frame(maxWidth: 330)
            }
            .padding(38)
            #if os(macOS)
            .frame(width: 410)
            #else
            .frame(maxWidth: 410)
            #endif
            .holoCard(radius: 26, sweep: false)   // signature surface: iridescent border + glow + pointer tilt
            .scaleEffect(appear ? 1 : 0.96)
            .opacity(appear ? 1 : 0)
    }
    @ViewBuilder private func seg(_ l: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(l).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(on ? BLTheme.inkOnGold : BLTheme.sub)
                .padding(.vertical, 8).frame(maxWidth: .infinity)
                .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(Color.clear)).clipShape(Capsule())
                .shadow(color: on ? BLTheme.gold.opacity(0.3) : .clear, radius: 8, y: 2)
        }.buttonStyle(.plain)
    }
    private func submit() {
        let r = creating ? AccountStore.create(email, pw) : AccountStore.signIn(email, pw)
        switch r { case .success: session.email = email; enter(); case .failure(let e): withAnimation { err = e.rawValue } }
    }
    private func googleSignIn() {
        err = ""
        guard GoogleAuth.isConfigured else {
            withAnimation { err = "Add your Google client ID in Settings → Sign-in to enable Google sign-in." }
            return
        }
        GoogleAuth.shared.signIn { result in
            switch result {
            case .success(let email):
                session.email = email; enter()
            case .failure(let e):
                let msg: String
                switch e {
                case GoogleAuth.GoogleError.noClientID:
                    msg = "Add your Google client ID in Settings → Sign-in to enable Google sign-in."
                case GoogleAuth.GoogleError.cancelled:
                    msg = "Google sign-in was cancelled."
                default:
                    msg = "Google sign-in couldn't be completed. Please try again."
                }
                withAnimation { err = msg }
            }
        }
    }
    private func enter() {
        // Persist the session ONLY when "Remember me" is on AND this is a real identity
        // (SessionStore.remember itself refuses "guest"/"demo"). Otherwise make sure no stale
        // remembered session lingers — an unchecked sign-in should not be auto-restored later.
        if rememberMe { SessionStore.remember(email: session.email) } else { SessionStore.clear() }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { session.signedIn = true }
    }

    /// Enter reviewer/demo mode: seed an isolated, clearly-labeled sample workspace
    /// (separate on-disk store) and open the app fully populated — no external account.
    private func exploreDemo() {
        model.enterDemo(prefs: prefs)
        session.demoMode = true
        session.email = "demo"
        enter()
    }
}

/// A small, vector-drawn Google "G" mark (four brand quadrants + crossbar). Drawn entirely in
/// SwiftUI — no bundled image asset, no network — so the Google button reads as Google without
/// shipping any third-party artwork. Purely decorative.
struct GoogleGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let lw = s * 0.22
            ZStack {
                Circle().trim(from: 0.00, to: 0.25).stroke(Color(hex: 0xEA4335), style: .init(lineWidth: lw)) // red, top-right
                Circle().trim(from: 0.25, to: 0.50).stroke(Color(hex: 0xFBBC05), style: .init(lineWidth: lw)) // yellow, bottom-right
                Circle().trim(from: 0.50, to: 0.75).stroke(Color(hex: 0x34A853), style: .init(lineWidth: lw)) // green, bottom-left
                Circle().trim(from: 0.75, to: 1.00).stroke(Color(hex: 0x4285F4), style: .init(lineWidth: lw)) // blue, top-left
                // The signature crossbar of the "G".
                Rectangle().fill(Color(hex: 0x4285F4))
                    .frame(width: s * 0.5, height: lw)
                    .offset(x: s * 0.22, y: 0)
            }
            .frame(width: s, height: s)
            .rotationEffect(.degrees(-8))
        }
    }
}
#endif // circuit-convert
