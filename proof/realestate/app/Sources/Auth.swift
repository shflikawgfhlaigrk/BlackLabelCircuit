#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AuthenticationServices) && !CIRCUIT_WINDOWS_SIM
import AuthenticationServices
#endif

// The desktop sign-in card is a fixed 414-pt panel inside a spacious 820×640 window; phones are
// 375–393 pt wide, so those fixed frames clipped the first screen a new iOS user ever sees.
// On iOS the card hugs the screen width instead.
private extension View {
    @ViewBuilder func authCardFrame() -> some View {
        #if os(iOS)
        self.blScreenPadding(28).frame(maxWidth: 414)
        #else
        self.padding(40).frame(width: 414)
        #endif
    }
    @ViewBuilder func authScreenFrame() -> some View {
        #if os(iOS)
        self
        #else
        self.frame(minWidth: 820, minHeight: 640)
        #endif
    }
    /// The sign-in card is taller than a 667-pt iPhone SE screen, so on iOS it scrolls inside the
    /// safe area instead of clipping the logo off the top and the guest button off the bottom.
    /// `.basedOnSize` keeps it rock-still on tall phones where it already fits.
    @ViewBuilder func authScrollable() -> some View {
        #if os(iOS)
        ScrollView(.vertical, showsIndicators: false) {
            self.padding(.vertical, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        #else
        self
        #endif
    }
}

struct AuthView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var model: AppModel
    @State private var creating = false
    @State private var email = ""
    @State private var pw = ""
    @State private var err = ""
    @State private var appear = false
    @State private var working = false
    /// A real sign-in is remembered for 30 days by default. The buyer can turn it off before
    /// signing in; guest/demo paths never persist a session.
    @State private var rememberMe = true
    @State private var recoveringLegacy = false
    @State private var legacyRecoveryNote = ""
    /// Guest-path guard: when a saved workspace exists, the guest button opens this chooser
    /// instead of wiping — resume the saved book, or explicitly erase and start empty.
    @State private var guestChoice = false

    var body: some View {
        ZStack {
            // Living holographic backdrop + capped gold motes — the first impression.
            AuroraBackdrop()
            ParticleField()

            VStack(spacing: BLScale.gap(20)) {
                Logo(size: BLScale.isCompact ? 68 : 96)
                    .scaleEffect(appear ? 1 : 0.85)
                    .opacity(appear ? 1 : 0)
                    .glowPulse()
                VStack(spacing: 6) {
                    FoilText(settings.data.workspaceName, size: 28, weight: .semibold)
                        .multilineTextAlignment(.center)
                    Text(settings.data.tagline)
                        .font(BLFont.body(13, .medium))
                        .foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                }
                HStack(spacing: 4) {
                    seg("Sign in", on: !creating) { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { creating = false; err = "" } }
                    seg("Create account", on: creating) { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { creating = true; err = "" } }
                }
                .padding(4).background(BLTheme.bg2).clipShape(Capsule()).overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))

                VStack(spacing: 13) {
                    // Social sign-in — above email/password, like top apps. A provider button renders
                    // ONLY when it can actually complete on this artifact; `AuthProviders` owns that
                    // decision (and the tap behavior) as pure, unit-tested data.
                    let providers = AuthProviders.live

                    // APPLE — shown only when this build carries the applesignin entitlement, i.e. the
                    // App Store / iOS lanes. The Developer-ID and adhoc lanes sign without it, so the
                    // native flow cannot run there and the button is hidden instead of advertising a
                    // sign-in the buyer's download can never finish.
                    if providers.appleVisible {
                        appleButton(providers.apple)
                    }

                    // GOOGLE — shown only when a client ID is configured (otherwise the button would be
                    // dead: tapping just points to Settings). Hiding it leaves reviewers with only
                    // working sign-in options; it reappears once a client ID is saved.
                    if providers.googleVisible {
                        Button(action: { handleGoogleTap(providers.google) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "globe").font(.blSystem(size: 13, weight: .bold))
                                Text("Sign in with Google")
                            }
                            .font(.blSystem(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(BLTheme.text)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(BLTheme.bg2).clipShape(Capsule())
                            .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain).disabled(working)
                    }

                    // "or" divider — only when a social button is actually above it, otherwise it
                    // would separate email/password from nothing.
                    if providers.anySocialVisible {
                        HStack(spacing: 10) {
                            Rectangle().fill(BLTheme.stroke).frame(height: 1)
                            Text("or").font(.blSystem(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                            Rectangle().fill(BLTheme.stroke).frame(height: 1)
                        }.padding(.vertical, 2)
                    }

                    Field(title: "Email", text: $email, prompt: "you@company.com")
                    Field(title: "Password", text: $pw, prompt: "••••••••", secure: true)
                    // Remember me — private prompt-free persistence (auto-restore next launch).
                    Button(action: { rememberMe.toggle() }) {
                        HStack(spacing: 8) {
                            Image(systemName: rememberMe ? "checkmark.square.fill" : "square")
                                .font(.blSystem(size: 14, weight: .semibold))
                                .foregroundColor(rememberMe ? BLTheme.gold : BLTheme.sub)
                            Text("Remember me on this \(kThisDeviceWord)")
                                .font(.blSystem(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(BLTheme.sub)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Keep me signed in for 30 days. Your session is stored privately on this \(kThisDeviceWord) and never uploaded.")
                    GoldButton(label: creating ? "Create account" : "Sign in", fill: true, icon: "arrow.right") { submit() }
                        .holoSheen()
                    // Honest expired-session notice (set when a remembered session was found but lapsed).
                    if session.expiredNotice && err.isEmpty {
                        Text("Your saved session expired — please sign in again.")
                            .font(.blSystem(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.gold).multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                    if let notice = session.storageNotice, err.isEmpty {
                        Text(notice)
                            .font(.blSystem(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundColor(Color(hex: 0xFF6B6B)).multilineTextAlignment(.center)
                    }
                    if !err.isEmpty {
                        Text(err).font(.blSystem(size: 12, weight: .medium, design: .rounded)).foregroundColor(Color(hex: 0xFF6B6B))
                            .multilineTextAlignment(.center).transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    Button(action: recoverLegacyCredentials) {
                        HStack(spacing: 7) {
                            Image(systemName: "key.viewfinder")
                            Text(recoveringLegacy ? "Checking macOS Keychain…" : "Recover saved credentials from macOS Keychain…")
                        }
                        .font(.blSystem(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.sub)
                    }
                    .buttonStyle(.plain)
                    .disabled(recoveringLegacy)
                    .help("One-time recovery for credentials saved by an earlier build. macOS may ask you to authorize access. Original Keychain items are not changed.")
                    if !legacyRecoveryNote.isEmpty {
                        Text(legacyRecoveryNote)
                            .font(.blSystem(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                    }
                    // REVIEWER / BUYER demo path — no account needed. Loads clearly-labeled synthetic
                    // sample data so the whole app is exercisable. Prominent because an App Store
                    // reviewer must be able to reach a fully-populated app with zero external login.
                    if DemoData.isAvailable {
                        HStack(spacing: 10) {
                            Rectangle().fill(BLTheme.stroke).frame(height: 1)
                            Text("just exploring?").font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                            Rectangle().fill(BLTheme.stroke).frame(height: 1)
                        }.padding(.top, 2)
                        Button(action: { enterDemo() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles").font(.blSystem(size: 13, weight: .bold))
                                Text("Explore with sample data")
                            }
                            .font(.blSystem(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(BLTheme.text)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(BLTheme.bg2).clipShape(Capsule())
                            .overlay(Capsule().stroke(BLTheme.gold.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Try the full app instantly with synthetic, clearly-labeled demo data — no account required. Nothing is saved.")
                        Text("No account needed. Synthetic demo data — nothing is saved.")
                            .font(.blSystem(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                    }

                    // PROMINENT guest path (RE-03) — a real, full-width button, not a buried link. This
                    // is the "use it now" promise the README makes. When a saved workspace already
                    // exists on this device (guest work persists; a signed-out account's book lives
                    // in the same store), it NEVER silently erases it — the user chooses resume vs
                    // start-fresh in a confirmation dialog.
                    Button(action: {
                        if model.hasSavedWork {
                            guestChoice = true
                        } else {
                            model.startEmptyGuestWorkspace()
                            withAnimation { session.email = "guest"; session.demoMode = false }
                            enter()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill").font(.blSystem(size: 13, weight: .bold))
                            Text(Onboarding.guestCTA)
                        }
                        .font(.blSystem(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(BLTheme.ink)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(BLTheme.goldGrad).clipShape(Capsule())
                        .shadow(color: BLTheme.gold.opacity(0.3), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Start using the app immediately with an empty on-device workspace — no account, no access key.")
                    .confirmationDialog("You have saved work on this \(kThisDeviceWord)",
                                        isPresented: $guestChoice, titleVisibility: .visible) {
                        Button("Resume saved workspace") {
                            model.resumeGuestWorkspace()
                            withAnimation { session.email = "guest"; session.demoMode = false }
                            enter()
                        }
                        Button("Erase it and start empty", role: .destructive) {
                            model.startEmptyGuestWorkspace()
                            withAnimation { session.email = "guest"; session.demoMode = false }
                            enter()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Leads, deals, and lists saved on this \(kThisDeviceWord) will be kept if you resume. Erasing permanently deletes them.")
                    }
                    Text(Onboarding.guestSubnote)
                        .font(.blSystem(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(BLTheme.sub).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 330)
            }
            .authCardFrame()
            // The signature holographic card — pointer 3D tilt + iridescent sweep on the login panel.
            .holoCard(radius: 28)
            .scaleEffect(appear ? 1 : 0.96)
            .opacity(appear ? 1 : 0)
            .authScrollable()
        }
        .authScreenFrame()
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) { appear = true }
        }
    }
    @ViewBuilder private func seg(_ l: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(l).font(.blSystem(size: 13, weight: .bold, design: .rounded)).foregroundColor(on ? BLTheme.ink : BLTheme.sub)
                .padding(.vertical, 8).frame(maxWidth: .infinity)
                .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(Color.clear)).clipShape(Capsule())
                .shadow(color: on ? BLTheme.gold.opacity(0.35) : .clear, radius: 8, y: 2)
        }.buttonStyle(.plain)
    }
    /// App Review demo credentials, published in App Store Connect → App Review Information.
    /// Accounts are created locally on-device, so no pre-existing account can be provisioned for a
    /// reviewer's machine — these credentials instead open the same clearly-labeled sample-data
    /// session as "Explore with sample data" (works on both the Sign in and Create account tabs).
    private static let reviewDemoEmail = "reviewer@blbestate.com"
    private static let reviewDemoPassword = "Parcel-Demo-2026"

    private func submit() {
        if email.trimmingCharacters(in: .whitespaces).lowercased() == Self.reviewDemoEmail,
           pw == Self.reviewDemoPassword {
            enterDemo(); return
        }
        let r = creating ? AccountStore.create(email, pw) : AccountStore.signIn(email, pw)
        switch r {
        case .success: session.email = email; enterReal(email)
        case .failure(let e): withAnimation { err = e.rawValue }
        }
    }
    /// Enter for a REAL account. A storage failure never masquerades as a remembered session.
    private func enterReal(_ mail: String) {
        session.expiredNotice = false
        session.storageNotice = nil
        let result = rememberMe ? SessionStore.remember(email: mail) : SessionStore.clear()
        switch result {
        case .success:
            enter()
        case .failure(let error):
            withAnimation { err = error.localizedDescription }
        }
    }
    private func enter() { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { session.signedIn = true } }

    /// Enter the app in DEMO mode: load synthetic sample data into memory (never persisted) and flip
    /// the session flag that shows the SAMPLE-DATA banner. The reviewer/buyer path — no account.
    private func enterDemo() {
        model.loadDemo()
        session.email = "demo"
        session.demoMode = true
        enter()
    }

    /// Explicit foreground bridge from rows owned by earlier builds. Passive launch/status paths
    /// never touch Security.framework; this action may present macOS authorization UI and leaves
    /// every legacy row unchanged.
    private func recoverLegacyCredentials() {
        recoveringLegacy = true
        legacyRecoveryNote = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let report = Keychain.recoverKnownLegacyAccounts()
            DispatchQueue.main.async {
                recoveringLegacy = false
                legacyRecoveryNote = report.summary
                session.restoreRememberedAsync()
            }
        }
    }

    // MARK: - Apple button (rendered only when this build carries the applesignin entitlement)
    @ViewBuilder private func appleButton(_ state: AppleButtonState) -> some View {
        switch state {
        case .live:
            // Provisioned build — the real, native Sign in with Apple control.
            SignInWithAppleButton(.signIn,
                onRequest: { req in req.requestedScopes = [.fullName, .email] },
                onCompletion: handleApple)
                .signInWithAppleButtonStyle(.white)
                .frame(height: 44)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        case .unavailableNoEntitlement:
            // No applesignin entitlement on this artifact — nothing is drawn. The caller already
            // gates on `providers.appleVisible`; this arm keeps the promise even if it ever doesn't,
            // and it never instantiates the native control (which would be invalid unentitled).
            EmptyView()
        }
    }

    private func handleGoogleTap(_ state: GoogleButtonState) {
        switch state {
        case .live: handleGoogle()
        case .needsClientID: withAnimation { err = GoogleButtonState.needsClientIDNote }
        }
    }

    // MARK: - Social handlers
    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            if let cred = auth.credential as? ASAuthorizationAppleIDCredential {
                let mail = cred.email ?? "apple-user"
                withAnimation { session.email = mail }
                enterReal(mail)
            } else {
                withAnimation { err = "Apple sign-in returned an unexpected response. Try again." }
            }
        case .failure:
            withAnimation { err = "Apple sign-in didn't complete. Try again." }
        }
    }

    private func handleGoogle() {
        err = ""; working = true
        GoogleAuth.shared.signIn { result in
            working = false
            switch result {
            case .success(let mail):
                withAnimation { session.email = mail }
                enterReal(mail)
            case .failure(let e):
                withAnimation { err = (e as? LocalizedError)?.errorDescription ?? "Google sign-in failed. Try again." }
            }
        }
    }
}
#endif // circuit-convert
