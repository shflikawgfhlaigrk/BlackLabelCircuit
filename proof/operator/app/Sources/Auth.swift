#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AuthenticationServices) && !CIRCUIT_WINDOWS_SIM
import AuthenticationServices
#endif

struct AuthView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var settings: AppSettings
    @State private var creating = false
    @State private var email = ""
    @State private var pw = ""
    @State private var err = ""
    @State private var appear = false
    @State private var note = ""               // inline, non-error guidance (e.g. Apple/Google setup)
    @State private var showGoogleField = false  // reveal the inline client-id field on demand
    @State private var rememberMe = false       // persist non-secret identity metadata across cold starts

    var body: some View {
        ZStack {
            // Living holographic first impression: aurora + drifting motes (theme-driven).
            AuroraBackdrop()
            ParticleField().allowsHitTesting(false)

            // The card's natural height can exceed the app's own minimum window height (680pt), which
            // clipped the logo and pushed the bottom sample-data/reviewer path off-screen with no way to
            // reach it. It must scroll; when the window is tall enough, minHeight keeps it centered.
            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 20) {
                        Logo(size: 96)
                            .scaleEffect(appear ? 1 : 0.85).opacity(appear ? 1 : 0)
                            .shadow(color: BLTheme.gold.opacity(0.4), radius: 30, y: 8)
                        VStack(spacing: 6) {
                            ShimmerText(text: settings.assistantName.isEmpty ? "Sovereign" : settings.assistantName, size: 40)
                            Text("Your assistant workspace — empty, inspectable, and yours.").font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                        }

                        // PRIMARY PATH: no Sovereign account is required. Storage is local; the disclosure
                        // below separately names the context sent when the buyer selects an external brain.
                        VStack(spacing: 6) {
                            GoldButton(label: "Start with my workspace", fill: true, icon: "bolt.fill") { enterLocal() }
                            Text("No Sovereign account is required. " + DataHandlingCopy.storageAndExternal)
                                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 330)

                        // Optional account block (demoted) — clearly secondary to the on-device primary above.
                        Text("Prefer an account? Sign in or create one — optional.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.sub).multilineTextAlignment(.center)

                        HStack(spacing: 4) {
                            seg("Sign in", on: !creating) { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { creating = false; err = "" } }
                            seg("Create account", on: creating) { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { creating = true; err = "" } }
                        }
                        .padding(4).background(BLTheme.bg2).clipShape(Capsule()).overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))

                        // Social sign-in — BOTH providers ALWAYS render (like top apps). Apple runs the
                        // native flow only on a provisioned build; Google runs once a client ID is set.
                        // Neither is ever a dead/no-op button: an unavailable provider explains itself inline.
                        VStack(spacing: 10) {
                            appleButton
                            googleButton

                            // Inline, non-error guidance (Apple-needs-signed-build / Google-needs-client-id).
                            if !note.isEmpty {
                                Text(note)
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                    .foregroundColor(BLTheme.champagne)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            // Reveal an inline client-id field so Google works the instant a Desktop client id
                            // is pasted — no need to sign in first to reach Settings.
                            if showGoogleField {
                                VStack(spacing: 8) {
                                    Field(title: "Google OAuth client ID", text: $settings.googleClientID,
                                          prompt: "your-id.apps.googleusercontent.com")
                                    Text("Use a Desktop/Installed-App OAuth client (public client id — no secret). Saved to this device; also editable later in Settings → Connectors.")
                                        .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.top, 2)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .frame(maxWidth: 330)

                        HStack(spacing: 10) {
                            Rectangle().fill(BLTheme.stroke).frame(height: 1)
                            Text("or").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                            Rectangle().fill(BLTheme.stroke).frame(height: 1)
                        }.frame(maxWidth: 330)

                        VStack(spacing: 13) {
                            Field(title: "Email", text: $email, prompt: "you@company.com")
                            Field(title: "Password", text: $pw, prompt: "••••••••", secure: true)
                            // Remember me — persists only the normalized identity in local metadata so you skip the
                            // sign-in wall next launch. Unchecked = signed out on next cold start (default off
                            // behavior). Never stores your password — only your account identity.
                            Button { rememberMe.toggle() } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: rememberMe ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(rememberMe ? BLTheme.gold : BLTheme.sub)
                                    Text("Remember me on this device")
                                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remember me on this device")
                            .accessibilityHint("Stay signed in across app launches. Stores only your account identity; never your password.")
                            Button {
                                if RememberedSession.recoverLegacy(), let recovered = RememberedSession.restore() {
                                    session.email = recovered
                                    session.signedIn = true
                                } else {
                                    note = "No readable remembered session was recovered. The older Keychain item, if any, was left untouched."
                                }
                            } label: {
                                Text("Recover remembered session from an older build")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundColor(BLTheme.gold)
                            }
                            .buttonStyle(.plain)
                            // Demoted (fill:false) so the account path reads as secondary to the on-device
                            // primary at the top — the buyer is never pushed toward creating an account.
                            GoldButton(label: creating ? "Create account" : "Sign in", fill: false, icon: "arrow.right") { submit() }
                            if !err.isEmpty {
                                Text(err).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.danger)
                                    .multilineTextAlignment(.center).transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .frame(maxWidth: 330)

                        // REVIEWER / SAMPLE PATH — experience the FULL app with NO account.
                        // App Store Guideline 2.1: the real app runs on the buyer's own brain (on-device
                        // or their own External login), so an empty fresh install can't be exercised by a
                        // reviewer. This loads clearly-labeled SAMPLE data (in memory only) so every screen
                        // is populated and demonstrable without any sign-in. Nothing here is persisted.
                        VStack(spacing: 7) {
                            Divider().frame(maxWidth: 330).overlay(BLTheme.stroke)
                            Button { enterDemo() } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles").font(.system(size: 13, weight: .bold))
                                    Text("Explore with sample data").font(.system(size: 13.5, weight: .bold, design: .rounded))
                                }
                                .foregroundColor(BLTheme.gold)
                                .frame(maxWidth: 330).frame(height: 44)
                                .background(BLTheme.gold.opacity(0.10)).clipShape(Capsule())
                                .overlay(Capsule().stroke(BLTheme.gold.opacity(0.55), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Try the full app with synthetic sample data — no account required")
                            Text("No sign-in. Try every feature with a guided demo — synthetic sample data, nothing saved.")
                                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .responsiveWidth(414)
                    .holoCard(cornerRadius: 28, padding: 40, sheen: true)   // pointer-tilt + iridescent rim + sheen sweep
                    .responsiveWidth(480)                                   // give the tilt room to breathe
                    .scaleEffect(appear ? 1 : 0.96).opacity(appear ? 1 : 0)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 820, minHeight: 640)
        #endif
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) { appear = true } }
    }

    // MARK: - Apple button (always visible; native only on a provisioned build)
    @ViewBuilder private var appleButton: some View {
        if AppleSignInCapability.isAvailable {
            // Provisioned build: the entitlement is present, so the native flow can actually complete.
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                switch result {
                case .success(let auth):
                    if let cred = auth.credential as? ASAuthorizationAppleIDCredential {
                        session.email = cred.email ?? "apple-user"
                        enter()
                    } else {
                        withAnimation { err = "Apple sign-in returned an unexpected response. Please try again." }
                    }
                case .failure:
                    withAnimation { err = "Apple sign-in didn't complete. Please try again." }
                }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 44)
            .clipShape(Capsule())
        } else {
            // Adhoc/Developer-ID build: the applesignin entitlement is NOT in the signature (the
            // Dev-ID distribution lane never carries it, and an adhoc build would AMFI-SIGKILL with
            // it). Rather than show a button with misleading "activates in the signed build" copy —
            // the Dev-ID build the buyer downloads IS signed but still can't run the native flow — we
            // HIDE the Apple button entirely here. Google + email + the on-device primary remain.
            // (App Store Guideline 4.8's native-Apple requirement applies to the App Store/iOS build,
            // where AppleSignInCapability.isAvailable is true and the real button above mounts.)
            EmptyView()
        }
    }

    // MARK: - Google button (always visible; runs the real PKCE flow once a client id is set)
    @ViewBuilder private var googleButton: some View {
        Button {
            if googleConfigured {
                googleSignIn()
            } else {
                // Not a dead button: reveal the inline client-id field + point to Settings.
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    err = ""
                    showGoogleField = true
                    note = "Paste a Google Desktop OAuth client ID below (or set it in Settings → Connectors) to enable Google sign-in."
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 13, weight: .bold))
                Text("Sign in with Google").font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundColor(BLTheme.text)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(BLTheme.bg2).clipShape(Capsule())
            .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func seg(_ l: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(l).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(on ? BLTheme.ink : BLTheme.sub)
                .padding(.vertical, 8).frame(maxWidth: .infinity)
                .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(Color.clear)).clipShape(Capsule())
                .shadow(color: on ? BLTheme.gold.opacity(0.35) : .clear, radius: 8, y: 2)
        }.buttonStyle(.plain)
    }
    /// True only when the buyer has configured a real Google client ID (Settings or Info.plist) —
    /// gates the Google button so a dead option is never shown.
    private var googleConfigured: Bool {
        let runtime = settings.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !runtime.isEmpty { return true }
        return !((Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func submit() {
        let r = creating ? AccountStore.create(email, pw) : AccountStore.signIn(email, pw)
        // Set the session identity to the SAME canonical key the credential is stored under,
        // never the raw typed input — so "Signed in as" and delete/sign-in all agree.
        switch r { case .success: session.email = AccountStore.normalize(email); enter(); case .failure(let e): withAnimation { err = e.rawValue } }
    }
    /// PRIMARY on-device entry: start using Sovereign on this Mac with NO account. Enters as a
    /// local ("guest") identity on the buyer's OWN empty data — nothing seeded, nothing sent off
    /// device. This is the default path a first-time buyer should take; the account block is optional.
    private func enterLocal() { session.email = "guest"; enter() }

    private func enter() {
        // Honor "Remember me": persist the real account identity so the next launch auto-restores.
        // RememberedSession.remember() itself refuses guest/demo, so an unchecked box or a guest
        // login leaves no trace. Unchecking clears any prior remembered session.
        if rememberMe { RememberedSession.remember(email: session.email) }
        else { RememberedSession.forget() }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { session.signedIn = true }
    }

    /// Enter the reviewer/sample experience: flip Demo Mode on (RootView seeds the synthetic data
    /// in memory only) and drop straight into the populated app as a guest. Onboarding is skipped
    /// so a reviewer immediately sees the full, populated product.
    private func enterDemo() {
        DemoMode.shared.enter()
        session.email = "demo"
        enter()
    }

    private func googleSignIn() {
        err = ""; note = ""
        GoogleSignIn.shared.runtimeClientID = settings.googleClientID
        GoogleSignIn.shared.start(
            onSuccess: { mail in session.email = mail; enter() },
            onError: { message in withAnimation { err = message } }
        )
    }
}
#endif // circuit-convert
