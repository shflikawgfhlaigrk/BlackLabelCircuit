#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  AceIntroWindow.swift
//  Ace
//
//  The first thing a buyer sees after dragging Ace out of the DMG.
//
//  Before this existed, first run was a 320pt menu-bar popover asking for four
//  permissions — and nothing anywhere told the new owner that Ace's packaged
//  brain still has to be signed in with their own account. They'd grant
//  everything, hold the hotkey, and get silence. This window is that missing
//  step: a real onboarding surface that walks someone from "downloaded" to
//  "asked Ace a question and got an answer", with the CLI connection proved
//  live (BrainConnection.swift) instead of assumed.
//
//  It is deliberately not the menu-bar panel: setup needs room, and it stays
//  visible alongside browser sign-in and System Settings.
//

import Foundation
import CircuitPortKit
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(ApplicationServices) && !CIRCUIT_WINDOWS_SIM
import ApplicationServices
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
#if canImport(Speech) && !CIRCUIT_WINDOWS_SIM
import Speech
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// The three examples shown on the last setup screen are live controls, not
/// decorative copy. Keeping their exact utterances in one testable type makes
/// it impossible for the UI label and the native routing input to drift apart.
nonisolated enum SetupCapabilityTryout: CaseIterable, Hashable, Sendable {
    case screenQuestion
    case meetingNotes
    case openEmail

    var label: String {
        switch self {
        case .screenQuestion: return "What does this error mean?"
        case .meetingNotes: return "Take notes on this meeting."
        case .openEmail: return "Check my email."
        }
    }

    var utterance: String {
        switch self {
        case .screenQuestion: return "what does this error mean?"
        case .meetingNotes: return "take notes on this meeting"
        case .openEmail: return "check my email"
        }
    }
}

// MARK: - Window controller

@MainActor
final class AceIntroWindowController: NSObject, NSWindowDelegate {
    static let shared = AceIntroWindowController()

    private var window: NSWindow?
    private var stealthEntryCutoffIdentifier: UUID?

    private override init() {
        super.init()
        stealthEntryCutoffIdentifier =
            StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                [weak self] in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        // Stealth owns a hard setup lifetime boundary. Closing
                        // unmounts AceIntroView, whose onDisappear cancels and
                        // resets every provider flight before a later reopen.
                        self?.close()
                    }
                }
            }
    }

    /// True while setup is on screen. `FirstRunFailureReporter` checks this so
    /// it does not stack a modal alert on top of a window that is already
    /// explaining the same problem in context.
    var isVisible: Bool { window?.isVisible == true }

    /// Opens the intro (or brings it forward if already open). `onFinish` runs
    /// only when the user completes the last step — closing the window is a
    /// "later", not a completion, so an interrupted setup is offered again next
    /// launch rather than being silently marked done.
    func present(companionManager: CompanionManager, onFinish: @escaping () -> Void) {
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else { return }
        if let existingWindow = window {
            _ = SetupVisibleEffectAdmission.commit {
                NSApp.activate(ignoringOtherApps: true)
                existingWindow.makeKeyAndOrderFront(nil)
                return true
            }
            return
        }

        let introWindow = NSWindow(
            // Must match the SwiftUI frame below, or the hosting view is
            // clipped by the window itself and the taller frame buys nothing.
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        introWindow.contentMinSize = NSSize(width: 600, height: 400)
        introWindow.titlebarAppearsTransparent = true
        introWindow.titleVisibility = .hidden
        introWindow.isMovableByWindowBackground = true
        introWindow.backgroundColor = NSColor(DS.Colors.background)
        introWindow.hasShadow = true
        introWindow.isReleasedWhenClosed = false
        // A normal-level window would vanish behind the browser or System
        // Settings at the exact moment its instructions are needed.
        introWindow.level = .floating
        // Follow the user to whatever Space is in front, including over a
        // full-screen app. Without this the setup window sat, correctly opened
        // and invisible, on the desktop Space while the owner was in
        // full-screen Finder — indistinguishable from "it never opened".
        introWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        introWindow.delegate = self

        let rootView = AceIntroView(
            companionManager: companionManager,
            onFinish: { [weak self] in
                onFinish()
                self?.close()
            },
            onDismiss: { [weak self] in
                self?.close()
            }
        )
        introWindow.contentView = AceHostingView(rootView: rootView)
        // NOT `center()`: that centers on the "main" screen, which for a
        // menu-bar app with no key window is whichever display macOS picks —
        // it put the setup window half off the bottom of one monitor and half
        // onto another, with the Dock over the buttons. Centre it in the
        // VISIBLE frame (menu bar and Dock excluded) of the screen the mouse
        // is on, which is the screen the person is actually looking at.
        let mouseLocation = NSEvent.mouseLocation
        // Filming override (dev Macs): `defaults write com.blacklabel.assistant
        // StageScreenHint "LG"` pins the whole first run to a named display —
        // the mouse rule is right for buyers but loses to a hand on the mouse.
        let stageHint = UserDefaults.standard.string(forKey: "StageScreenHint")
        let hintedScreen = stageHint.flatMap { hint in
            NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains(hint) }
        }
        let targetScreen = hintedScreen
            ?? NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.screens.first
        if let visibleFrame = targetScreen?.visibleFrame {
            let size = NSSize(
                width: min(introWindow.frame.width, visibleFrame.width - 24),
                height: min(introWindow.frame.height, visibleFrame.height - 24)
            )
            introWindow.setFrame(NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2,
                width: size.width, height: size.height
            ), display: false)
        } else {
            introWindow.center()
        }

        let didPresent = SetupVisibleEffectAdmission.commit {
            window = introWindow
            NSApp.activate(ignoringOtherApps: true)
            introWindow.makeKeyAndOrderFront(nil)
            return true
        }
        if !didPresent {
            introWindow.delegate = nil
            introWindow.close()
        }
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Root view

struct AceIntroView: View {
    @ObservedObject var companionManager: CompanionManager
    let onFinish: () -> Void
    let onDismiss: () -> Void

    @StateObject private var brainConnection = BrainConnectionModel()
    @State private var step: IntroStep

    init(
        companionManager: CompanionManager,
        onFinish: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.companionManager = companionManager
        self.onFinish = onFinish
        self.onDismiss = onDismiss
        _step = State(initialValue:
            companionManager.hasCompletedOnboarding
                || BrainConnectionModel.isSimulatingBrainStates
                ? .brain
                : .welcome
        )
    }

    enum IntroStep: Int, CaseIterable {
        case welcome, brain, permissions, ready

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .brain: return "Brain"
            case .permissions: return "Permissions"
            case .ready: return "Finish"
            }
        }
    }

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: 0) {
                header
                Divider().background(DS.Colors.borderSubtle.opacity(0.5))

                // Bounded and scrollable. These cards stack one per active
                // failure with no height cap, inside a hard 940×660 window, and
                // every text run refuses compression. On a fresh Mac
                // install.unsupportedLocation, license.notActive, the voice
                // cards can all be live at once — enough to push the step body's own Continue
                // and Back controls past the bottom edge with nothing to
                // scroll, stranding the owner on the setup screen that exists
                // to unstick them. The panel mount already wraps this view in a
                // ScrollView; the setup window did not.
                ScrollView {
                    FirstRunFailureRecoveryView(
                        reporter: FirstRunFailureReporter.shared
                    )
                }
                .frame(maxHeight: 120)

                Group {
                    switch step {
                    case .welcome:
                        WelcomeStepView(onBegin: { advance(to: .brain) })
                    case .brain:
                        BrainStepView(
                            brainConnection: brainConnection,
                            companionManager: companionManager,
                            onContinue: { advance(to: .permissions) },
                            onBack: { advance(to: .welcome) }
                        )
                    case .permissions:
                        PermissionsStepView(
                            companionManager: companionManager,
                            onContinue: { advance(to: .ready) },
                            onBack: { advance(to: .brain) }
                        )
                    case .ready:
                        ReadyStepView(
                            brainConnection: brainConnection,
                            companionManager: companionManager,
                            onFinish: finishSetup,
                            onBack: { advance(to: .permissions) }
                        )
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Step content scrolls while navigation remains reachable on smaller
        // displays and when the owner resizes the setup window.
        .frame(minWidth: 600, idealWidth: 940, maxWidth: .infinity,
               minHeight: 400, idealHeight: 720, maxHeight: .infinity)
        .background(DS.Colors.background)
        .onAppear {
            brainConnection.handleProbeRequest(.setupAppearance)
            narrate(step)
        }
        .onDisappear {
            // Setup owns its installer, live brain probes, and sign-in polling.
            // Closing the window is a hard lifetime boundary: none of that work
            // may finish later and surface while Ace is in Private Mode.
            brainConnection.cancelAllWork()
        }
        .onChange(of: step) { newStep in
            narrate(newStep)
        }
    }

    /// Ace reads every step out loud. Speaking needs no permission — only
    /// listening does — so the voice the buyer is about to depend on introduces
    /// itself before the microphone has even been granted, and setup can be
    /// completed by someone who can't comfortably read the screen.
    private func narrate(_ introStep: IntroStep) {
        // The script never says the product's own name — the wordmark on screen
        // already does (founder ruling 2026-07-26: "i'm ace / ace online" is
        // self-announcing noise). Every line is about the OWNER's machine and
        // what happens next, in as few words as it takes.
        //
        // Each line is guidance for something NOT DONE YET, spoken at most once
        // per half hour. Build 63's founder test relaunched Ace three times in
        // four minutes and heard the full four-line script every time — a step
        // the owner already finished must never be narrated at them again
        // (founder ruling 2026-08-15: repeated "you got connected" narration).
        switch introStep {
        case .brain:
            guard !brainConnection.hasAnsweredRealProbeThisSession else { return }
        case .permissions:
            guard !companionManager.allPermissionsGranted else { return }
        case .welcome, .ready:
            break
        }
        let narratedStampKey = "ace.intro.narrated.\(introStep)"
        if let lastNarrated = UserDefaults.standard.object(
            forKey: narratedStampKey
        ) as? Date, Date().timeIntervalSince(lastNarrated) < 30 * 60 {
            return
        }
        let line: String
        switch introStep {
        case .welcome:
            line = "two minutes of setup. after that, you just talk to your mac."
        case .brain:
            line = AceBrainRoute.current == .customerOwned
                ? (BrainCLI.includesQwen
                    ? "first, a brain. choose Codex, Claude Code, or local Qwen3 Abliterated."
                    : "first, a brain. choose Codex or Claude Code.")
                : "first, a brain. your private founder access uses Black Label's hosted Codex brain."
        case .permissions:
            line = "now, eyes and ears. macos asks one at a time. "
                + "i only look while you're holding the keys."
        case .ready:
            line = "last pass. i'll prove anything still missing, then show you the desktop."
        }
        UserDefaults.standard.set(Date(), forKey: narratedStampKey)
        companionManager.speakSetupNarration(line)
    }

    private func advance(to newStep: IntroStep) {
        // Permissions and Ready are downstream of a working brain. Keeping the
        // gate here, rather than only disabling one button, also protects
        // notification-driven/dev navigation and future call sites.
        let requiresAnsweredBrain = newStep == .permissions || newStep == .ready
        guard !requiresAnsweredBrain
            || brainConnection.hasAnsweredRealProbeThisSession else {
            brainConnection.handleProbeRequest(.navigationGuard)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                step = .brain
            }
            return
        }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            step = newStep
        }
    }

    private func finishSetup() -> Bool {
        // `onFinish` is the callback that marks first run complete. Never call
        // it from an unverified state, even if a future view accidentally
        // exposes another route around the step gate.
        guard brainConnection.hasAnsweredRealProbeThisSession else {
            advance(to: .brain)
            return false
        }
        guard companionManager.firstRunSetupPrerequisitesReady else {
            advance(to: .permissions)
            return false
        }
        onFinish()
        return true
    }

    private var header: some View {
        HStack(spacing: 14) {
            AceGem(size: 22, isActive: true)

            Text("Ace")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textPrimary)

            Text("setup")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Spacer()

            StepRail(current: step)

            Spacer()

            AceImmediateButton(
                accessibilityIdentifier: "ace.intro.later",
                action: onDismiss
            ) {
                Text("Later")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    let onBegin: () -> Void
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            AceGem(size: 96, isActive: true)
                .scaleEffect(hasAppeared ? 1 : 0.6)
                .opacity(hasAppeared ? 1 : 0)

            Spacer().frame(height: 34)

            Text("Ace")
                .font(.system(size: 58, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [DS.Colors.textPrimary, DS.Colors.agentGoldBright, DS.Colors.textPrimary],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 14)

            Spacer().frame(height: 12)

            Text("A voice companion that can see your screen.")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 12)

            Spacer().frame(height: 40)

            HStack(spacing: 14) {
                FeatureChip(symbol: "waveform", title: "Hold to talk", detail: "Ask about anything on screen")
                FeatureChip(symbol: "text.badge.checkmark", title: "Meeting notes", detail: "Transcribed on device")
                FeatureChip(symbol: "bolt.horizontal", title: "Background work", detail: "Runs tasks while you keep going")
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 18)

            Spacer().frame(height: 44)

            AceImmediateButton(
                accessibilityIdentifier: "ace.intro.begin",
                action: onBegin
            ) {
                PrimaryButtonLabel(
                    title: "Set up Ace",
                    symbol: "arrow.right"
                )
            }
                .opacity(hasAppeared ? 1 : 0)

            Spacer().frame(height: 14)

            Text(AceBrainRoute.current == .founderHosted
                ? "Founder-hosted brain connected privately."
                : (BrainCLI.includesQwen
                    ? "Choose Codex, Claude Code, or local Qwen3 Abliterated."
                    : "Choose Codex or Claude Code."))
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .opacity(hasAppeared ? 1 : 0)

            Spacer()
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.75).delay(0.05)) {
                hasAppeared = true
            }
        }
    }
}

// MARK: - Step 2: Brain

enum BrainSetupCopy {
    static var customerOwnedSubtitle: String {
        customerOwnedSubtitle(includesQwen: BrainCLI.includesQwen)
    }

    static func customerOwnedSubtitle(includesQwen: Bool) -> String {
        if includesQwen {
            return "Codex and Claude Code use your account. Qwen3 Abliterated and its "
                + "runtime are embedded in Ace. Ace accepts a brain only after a real test answer."
        }
        return "Codex and Claude Code use your account. Ace accepts a brain "
            + "only after a real test answer."
    }
}

private struct BrainStepView: View {
    @ObservedObject var brainConnection: BrainConnectionModel
    /// Needed only so the connector can speak install and sign-in hand-offs.
    @ObservedObject var companionManager: CompanionManager
    let onContinue: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                eyebrow: "Step 2 of 4",
                title: "Give Ace a brain",
                subtitle: AceBrainRoute.current == .customerOwned
                    ? BrainSetupCopy.customerOwnedSubtitle
                    : "Your private founder access uses Black Label's hosted Codex brain."
            )

            Spacer().frame(height: 22)

            Group {
                if AceBrainRoute.current == .customerOwned {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(BrainCLI.customerChoices) { cli in
                            BrainCard(
                                cli: cli,
                                brainConnection: brainConnection
                            )
                        }
                    }
                } else {
                    HostedBrainCard(brainConnection: brainConnection)
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            HStack(spacing: 12) {
                AceImmediateButton(
                    accessibilityIdentifier: "ace.intro.brain.back",
                    action: onBack
                ) {
                    SecondaryButtonLabel(title: "Back")
                }

                Spacer()

                if !brainConnection.hasAnsweredRealProbeThisSession {
                    Text("Connect one brain to continue. Choose Later above if you want to finish setup another time.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(maxWidth: 320, alignment: .trailing)
                }

                AceImmediateButton(
                    accessibilityIdentifier: "ace.intro.brain.continue",
                    action: onContinue
                ) {
                    PrimaryButtonLabel(
                        title:
                            brainConnection.hasAnsweredRealProbeThisSession
                            ? "Continue"
                            : "Connect a brain to continue",
                        symbol: "arrow.right",
                        isProminent:
                            brainConnection.hasAnsweredRealProbeThisSession,
                        isEnabled:
                            brainConnection.hasAnsweredRealProbeThisSession
                    )
                }
                .disabled(
                    !brainConnection.hasAnsweredRealProbeThisSession
                )
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .onChange(of: brainConnection.hasAnsweredRealProbeThisSession) { hasBrain in
            guard hasBrain else { return }
            companionManager.speakSetupNarration(
                "that's it — i just asked it a question and it answered. we're connected.")
        }
    }
}

private struct HostedBrainCard: View {
    @ObservedObject var brainConnection: BrainConnectionModel
    @ObservedObject private var license = AceLicense.shared

    private var status: BrainConnectionStatus {
        brainConnection.hostedStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(
                        status.isConnected
                            ? DS.Colors.success
                            : DS.Colors.textSecondary
                    )
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DS.Colors.surface3))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ace's isolated Codex CLI")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Included with this Ace access")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                StatusChip(status: status)
            }

            Text("Ace queues only the current request and the screen images you asked it to inspect for Ace's isolated Codex CLI. The CLI has no shell, filesystem, browser, app credentials, or direct control of your Mac.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(DS.Colors.borderSubtle)

            if status.isConnected {
                Label(
                    "Live model answer verified. Local actions still require Ace's native review and confirmation.",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.success)
            } else {
                Text(status.detail.isEmpty
                    ? "Link this Mac with your Ace account, then check the connection."
                    : status.detail)
                    .font(.system(size: 12))
                    .foregroundColor(
                        status.state == .failed
                            ? DS.Colors.destructiveText
                            : DS.Colors.textSecondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                if license.hostedBrainCredentials == nil {
                    ActionButton(
                        title: "Link this Mac",
                        symbol: "laptopcomputer.and.arrow.down",
                        isDisabled: linkActionIsBusy,
                        action: {
                            license.presentDeviceAuthorization {
                                brainConnection.userRequestedRefreshAll()
                            }
                        }
                    )
                    .accessibilityIdentifier("ace.intro.link-this-mac")

                    if let linkStatus =
                            license.deviceAuthorizationState.ownerMessage {
                        Text(linkStatus)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(
                                license.deviceAuthorizationState
                                    .messageIsFailure
                                    ? DS.Colors.destructiveText
                                    : DS.Colors.textSecondary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(
                                "ace.intro.link-status"
                            )
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 620, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(DS.Colors.surface1.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
        )
    }

    private var linkActionIsBusy: Bool {
        switch license.deviceAuthorizationState {
        case .starting, .checkingLegacyKey, .finishing:
            return true
        case .idle, .awaitingApproval, .linked, .failed:
            return false
        }
    }
}

private struct BrainCard: View {
    let cli: BrainCLI
    @ObservedObject var brainConnection: BrainConnectionModel
    @StateObject private var retryCoordinator = PermissionRepairCoordinator()
    @State private var activeProviderControlIdentifier: String?

    private var retryControlIdentifier: String {
        switch cli {
        case .codex: return SetupControlID.introProviderRetryCodex
        case .claude: return SetupControlID.introProviderRetryClaude
        case .qwen: return SetupControlID.introProviderRetryQwen
        }
    }

    private var connectControlIdentifier: String {
        switch cli {
        case .codex: return SetupControlID.introProviderConnectCodex
        case .claude: return SetupControlID.introProviderConnectClaude
        case .qwen: return SetupControlID.introProviderConnectQwen
        }
    }

    private var status: BrainConnectionStatus { brainConnection.status(for: cli) }
    private var onboardingState: BrainConnectionProviderOnboardingState {
        brainConnection.providerOnboardingState(for: cli)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: cli.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(status.isConnected ? DS.Colors.success : DS.Colors.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(DS.Colors.surface3))

                VStack(alignment: .leading, spacing: 2) {
                    Text(cli == .codex ? "ChatGPT" : cli.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(cli.vendorLine)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                StatusChip(status: status)
            }

            Spacer().frame(height: 16)

            instructionSection

            repairStatus(
                retryCoordinator.state,
                identifier: activeProviderControlIdentifier
                    ?? retryControlIdentifier
            )

            Spacer(minLength: 12)

        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    brainConnection.selectedBrain == cli && status.isVerifiedConnected
                        ? DS.Colors.success.opacity(0.55) : DS.Colors.borderSubtle,
                    lineWidth: brainConnection.selectedBrain == cli
                        && status.isVerifiedConnected ? 1.5 : 1
                )
        )
        .animation(.easeOut(duration: 0.25), value: status.state)
    }

    @ViewBuilder
    private var instructionSection: some View {
        if status.state == .notInstalled {
            VStack(alignment: .leading, spacing: 12) {
                Text(cli.missingRuntimeTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                Text("Reinstall Ace from the original download, then reopen it. Your account remains yours; Ace restores every bundled runtime and embedded model.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            providerInstructionSection
        }
    }

    @ViewBuilder
    private var providerInstructionSection: some View {
        switch onboardingState {
        case .launchingOAuth, .waitingForAuthentication:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                    Text(brainConnection.verifyingExistingAuthenticationFor == cli
                        ? "Checking your saved account…"
                        : (cli.requiresBrowserAuthentication
                            ? "Complete sign-in in your browser…"
                            : "Loading Qwen3 Abliterated locally…"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                }
                Text(brainConnection.verifyingExistingAuthenticationFor == cli
                    ? "Ace is testing your saved sign-in. You do not need to open a browser."
                    : cli.signInHint)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(brainConnection.verifyingExistingAuthenticationFor == cli
                    ? "The result will appear here."
                    : "Return here after signing in. Ace will check the connection.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                ActionButton(title: "Cancel", symbol: "xmark", action: {
                    brainConnection.cancelProviderConnection(cli)
                })
            }

        case .retryConnection:
            VStack(alignment: .leading, spacing: 12) {
                Text(status.isUsageLimited
                    ? status.detail
                    : "Ace couldn’t connect. Try again, or sign in through your browser.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                if !status.detail.isEmpty && !status.isUsageLimited {
                    DisclosureGroup("Connection details") {
                        Text(status.detail)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ActionButton(
                    title: "Retry connection",
                    symbol: "arrow.clockwise",
                    isDisabled: retryCoordinator.state.isRunning,
                    action: {
                        activeProviderControlIdentifier =
                            retryControlIdentifier
                        retryCoordinator.start {
                            guard brainConnection.connectProvider(cli) else {
                                return .failed(
                                    PermissionRepairFailure(
                                        code: "provider.retry_not_admitted",
                                        message: "The provider check was not admitted."
                                    )
                                )
                            }
                            return await brainConnection
                                .waitForProviderRepairTerminal(cli)
                        }
                    }
                )
                .accessibilityIdentifier(
                    retryControlIdentifier + ".action"
                )
                .accessibilityValue(retryCoordinator.state.accessibilityValue)
                if cli.requiresBrowserAuthentication {
                    browserSignInButton
                }
            }

        // Require the SAME proof that gates Continue. `isVerifiedConnected` is
        // in-memory and never expires, but `hasAnsweredRealProbe` lapses after
        // 15 minutes — so a buyer who connected, read the screen, and came back
        // hit a card still claiming "Answered a test question" with Continue
        // disabled, the hint saying "Connect one brain to continue", and NO
        // Connect and NO Retry button anywhere: step 1 of 3 unfinishable, only
        // escapable by quitting the app, with nothing telling them that.
        // Falling through to the branch below restores the Connect button.
        case .connected where status.isVerifiedConnected
            && BrainConnectionProof.hasAnsweredRealProbe(for: cli):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    brainConnection.selectedBrain == cli
                        ? "Answered a test question and selected as your brain."
                        : "Answered a test question.",
                    systemImage: "checkmark.seal.fill"
                )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.success)
                if !status.detail.isEmpty {
                    Text(status.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

        case .connected, .readyToConnect:
            VStack(alignment: .leading, spacing: 12) {
                Text(status.detail.isEmpty
                    ? "Connect your account to continue."
                    : status.detail)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ActionButton(
                    title: brainConnection.canVerifyExistingAuthentication(for: cli)
                        ? "Check saved account"
                        : (cli == .codex
                        ? "Connect ChatGPT"
                        : (cli == .claude
                            ? "Connect Claude"
                            : "Verify & Use Qwen")),
                    symbol: cli == .qwen
                        ? "cpu" : "person.badge.key.fill",
                    isDisabled: status.isChecking
                        || retryCoordinator.state.isRunning
                        || brainConnection.hasActiveProviderFlight,
                    action: {
                        activeProviderControlIdentifier =
                            connectControlIdentifier
                        retryCoordinator.start {
                            guard brainConnection.connectProvider(cli) else {
                                return .failed(
                                    PermissionRepairFailure(
                                        code: "provider.connect_not_admitted",
                                        message: "Another provider flight is active or this connection was not admitted."
                                    )
                                )
                            }
                            return await brainConnection
                                .waitForProviderRepairTerminal(cli)
                        }
                    }
                )
                .accessibilityIdentifier(
                    connectControlIdentifier + ".action"
                )
                .accessibilityValue(
                    retryCoordinator.state.accessibilityValue
                )
                if cli.requiresBrowserAuthentication
                    && brainConnection.hasPrivateAuthenticationState(for: cli) {
                    browserSignInButton
                }
                Text(brainConnection.canVerifyExistingAuthentication(for: cli)
                    ? "Check your saved account, or sign in again to choose an account in your browser."
                    : "Complete sign-in in your browser, then return to Ace.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var browserSignInButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            ActionButton(
                title: cli == .codex ? "Sign in to ChatGPT in browser" : "Sign in to Claude in browser",
                symbol: "safari",
                isDisabled: retryCoordinator.state.isRunning || brainConnection.hasActiveProviderFlight,
                action: {
                    activeProviderControlIdentifier = connectControlIdentifier
                    retryCoordinator.start {
                        guard brainConnection.reconnectProvider(cli) else {
                            return .failed(PermissionRepairFailure(
                                code: "provider.browser_signin_not_admitted",
                                message: "Finish or cancel the current connection attempt, then try again."
                            ))
                        }
                        return await brainConnection.waitForProviderRepairTerminal(cli)
                    }
                }
            )
            .accessibilityIdentifier(connectControlIdentifier + ".browser-signin")
            Text("This replaces Ace’s saved sign-in with the account you choose.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    @ViewBuilder
    private func repairStatus(
        _ state: PermissionRepairState,
        identifier: String
    ) -> some View {
        if let status = state.visibleStatus {
            Text(status)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(state.proof == nil ? DS.Colors.warning : DS.Colors.success)
                .accessibilityIdentifier(identifier + ".state")
                .accessibilityValue(state.accessibilityValue)
        }
    }

}

// MARK: - Step 3: Permissions

private struct PermissionsStepView: View {
    @ObservedObject var companionManager: CompanionManager
    /// Ace's voice is not a permission. It is packaged inside the signed app,
    /// and this row proves the real engine/model/playback path.
    @ObservedObject private var voiceReadiness = VoiceReadiness.shared
    @ObservedObject private var screenRecordingRepairCoordinator =
        WindowPositionManager.screenRecordingPermissionRepairCoordinator
    @ObservedObject private var accessibilityRepairCoordinator =
        WindowPositionManager.accessibilityPermissionRepairCoordinator
    @ObservedObject private var voiceRepairCoordinator =
        SetupControlCoordinatorBank.shared.voice
    @ObservedObject private var microphoneRepairCoordinator =
        SetupControlCoordinatorBank.shared.microphone
    @ObservedObject private var speechRepairCoordinator =
        SetupControlCoordinatorBank.shared.speechRecognition
    @ObservedObject private var screenContentRepairCoordinator =
        SetupControlCoordinatorBank.shared.screenContent
    @ObservedObject private var localMailAccess =
        LocalMailAccessController.shared
    @ObservedObject private var appAutomationRepairCoordinator =
        SetupControlCoordinatorBank.shared.appAutomation
    let onContinue: () -> Void
    let onBack: () -> Void

    /// Says what is actually wrong, never a generic "unavailable".
    private var voiceDetailText: String {
        switch voiceReadiness.state {
        case .ready:
            return "Ace Voice is built in and ready."
        case .unknown:
            return voiceReadiness.provenHostExecutablePath == nil
                ? "Checking Ace's bundled voice engine and model…"
                : "Starting Ace Voice…"
        case .voiceAssetMissing:
            return "Ace's bundled voice model is missing. Reinstall this Ace package."
        case .voiceHostUnavailable, .voiceCheckFailed:
            return voiceReadiness.state.ownerFacingRemedy
                ?? voiceReadiness.state.ownerFacingSummary
        }
    }

    private var canContinue: Bool {
        voiceReadiness.state == .ready
            && companionManager.allPermissionsGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                eyebrow: "Step 3 of 4",
                title: "Let Ace see, hear, and speak",
                subtitle: "macOS asks for each of these separately. Screen and microphone access stay tied to your "
                    + "hotkey or meeting notes; app access runs only after an explicit task."
            )

            Spacer().frame(height: 20)

            // Seven permission rows need more height than the fixed,
            // non-resizable 940x660 window gives this step; without a scroll
            // container the centered overflow clipped the Back/Continue footer
            // at the window edge. Rows scroll — heading and footer stay put.
            ScrollView {
                VStack(spacing: 10) {
                    PermissionRow(
                        symbol: "speaker.wave.2.fill",
                        title: "Voice",
                        detail: voiceDetailText,
                        isGranted: voiceReadiness.state.canSpeak,
                        actionTitle: "Check again",
                        accessibilityIdentifier: SetupControlID.introVoice,
                        repairState: voiceRepairCoordinator.state,
                        grant: {
                            voiceRepairCoordinator.start {
                                let verdict = await voiceReadiness
                                    .probeAndWaitForFullVerdict(
                                        requiresFreshDaemonVerdict: true
                                    )
                                return verdict == .ready
                                    ? .succeeded(.permissionReadback(permission: .voice))
                                    : .failed(
                                        PermissionRepairFailure(
                                            code: "voice.readiness_not_verified",
                                            message: verdict.ownerFacingSummary
                                        )
                                    )
                            }
                        }
                    )

                    PermissionRow(
                        symbol: "mic.fill",
                        title: "Microphone",
                        detail: "Hears you while you hold the hotkey.",
                        isGranted: companionManager.hasMicrophonePermission,
                        accessibilityIdentifier: SetupControlID.introMicrophone,
                        repairState: microphoneRepairCoordinator.state,
                        grant: {
                            let status = AVCaptureDevice.authorizationStatus(for: .audio)
                            if status == .notDetermined {
                                microphoneRepairCoordinator.startPromptResolution(
                                    permission: .microphone,
                                    requestPrompt: {
                                        let boundary = SetupPermissionPromptStealthBoundary()
                                        var durableAttemptRecorded = false
                                        let admitted = boundary.invokeIfAdmitted {
                                            durableAttemptRecorded =
                                                UserDefaultsPermissionPromptAttemptStore()
                                                    .markAttempted(.microphone)
                                            guard durableAttemptRecorded else { return }
                                            AVCaptureDevice.requestAccess(for: .audio) { granted in
                                                LifecycleLog.append(
                                                    "PERMISSION microphone prompt completed granted=\(granted)"
                                                )
                                            }
                                        }
                                        return admitted && durableAttemptRecorded
                                    },
                                    readback: {
                                        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                                    }
                                )
                            } else if status == .restricted {
                                microphoneRepairCoordinator.start {
                                    .failed(
                                        PermissionRepairFailure(
                                            code: "microphone.restricted",
                                            message: "macOS reports Microphone access is restricted by device policy."
                                        )
                                    )
                                }
                            } else {
                                microphoneRepairCoordinator.start {
                                    await WindowPositionManager
                                        .openSettingsAndWaitForReadback(
                                            .microphone,
                                            permission: .microphone,
                                            readback: {
                                                AVCaptureDevice.authorizationStatus(
                                                    for: .audio
                                                ) == .authorized
                                            }
                                        )
                                }
                            }
                        }
                    )

                    PermissionRow(
                        symbol: "waveform.badge.mic",
                        title: "Speech Recognition",
                        detail: companionManager
                            .appleSpeechRecognitionReadiness
                            .unavailableExplanation
                            ?? "Turns your spoken request into words on this Mac.",
                        isGranted:
                            companionManager.isOnDeviceDictationReady,
                        actionTitle:
                            companionManager.hasSpeechRecognitionPermission
                                ? "Open Dictation"
                                : "Grant",
                        accessibilityIdentifier:
                            SetupControlID.introSpeechRecognition,
                        repairState: speechRepairCoordinator.state,
                        grant: {
                            let authorization =
                                SFSpeechRecognizer.authorizationStatus()
                            if authorization == .notDetermined {
                                speechRepairCoordinator.startPromptResolution(
                                    permission: .speechRecognition,
                                    requestPrompt: {
                                        let boundary = SetupPermissionPromptStealthBoundary()
                                        var durableAttemptRecorded = false
                                        let admitted = boundary.invokeIfAdmitted {
                                            durableAttemptRecorded =
                                                UserDefaultsPermissionPromptAttemptStore()
                                                    .markAttempted(.speechRecognition)
                                            guard durableAttemptRecorded else { return }
                                            SFSpeechRecognizer.requestAuthorization { authorization in
                                                LifecycleLog.append(
                                                    "PERMISSION speech prompt completed status=\(authorization.rawValue)"
                                                )
                                            }
                                        }
                                        return admitted && durableAttemptRecorded
                                    },
                                    readback: {
                                        companionManager.isOnDeviceDictationReady
                                    }
                                )
                            } else if authorization == .restricted {
                                speechRepairCoordinator.start {
                                    .failed(
                                        PermissionRepairFailure(
                                            code: "speech_recognition.restricted",
                                            message: "macOS reports Speech Recognition is restricted by device policy."
                                        )
                                    )
                                }
                            } else {
                                speechRepairCoordinator.start {
                                    await WindowPositionManager
                                        .openSettingsAndWaitForReadback(
                                            authorization == .authorized
                                                ? .dictation
                                                : .speechRecognition,
                                            permission: .speechRecognition,
                                            readback: {
                                                companionManager
                                                    .isOnDeviceDictationReady
                                            }
                                        )
                                }
                            }
                        }
                    )

                    PermissionRow(
                        symbol: "rectangle.on.rectangle",
                        title: "Screen Recording",
                        detail: "Takes the screenshot Ace looks at when you ask a question.",
                        isGranted: companionManager.hasScreenRecordingPermission,
                        accessibilityIdentifier:
                            SetupControlID.introScreenRecording,
                        repairState:
                            screenRecordingRepairCoordinator.state,
                        grant: {
                            WindowPositionManager
                                .beginScreenRecordingPermissionRepair()
                        }
                    )

                    PermissionRow(
                        symbol: "accessibility",
                        title: "Accessibility",
                        detail: "Reads the push-to-talk keys and points at things on screen.",
                        isGranted: companionManager.hasAccessibilityPermission,
                        accessibilityIdentifier:
                            SetupControlID.introAccessibility,
                        repairState: accessibilityRepairCoordinator.state,
                        grant: {
                            WindowPositionManager
                                .beginAccessibilityPermissionRepair()
                        }
                    )

                    PermissionRow(
                        symbol: "eye",
                        title: "Screen Content",
                        detail: "Your one-time OK for Ace to read what's on the screenshot.",
                        isGranted: companionManager.hasScreenContentPermission,
                        accessibilityIdentifier: SetupControlID.introScreenContent,
                        repairState: screenContentRepairCoordinator.state,
                        grant: { beginScreenContentRepair() }
                    )

                    LocalMailAccessPermissionRow(
                        controller: localMailAccess,
                        accessibilityIdentifier:
                            SetupControlID.introLocalMailAccess
                    )

                    AppAutomationPermissionRow(
                        permissionWarmup: companionManager.permissionWarmup,
                        repairCoordinator: appAutomationRepairCoordinator
                    )
                }
                .padding(.horizontal, 40)
            }

            Spacer()

            HStack(spacing: 12) {
                AceImmediateButton(
                    accessibilityIdentifier: "ace.intro.permissions.back",
                    action: onBack
                ) {
                    SecondaryButtonLabel(title: "Back")
                }
                Spacer()
                if !canContinue {
                    Text("Continue requires Voice and the five core checks. App Automation can finish later.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warningText)
                } else if !companionManager.permissionWarmup.hasProvenAppAutomation || !localMailAccess.hasAccess {
                    Text("Core access is ready. App Automation or Local Mail Access still needs setup above before those features work.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warningText)
                        .accessibilityIdentifier("ace.intro.permissions.remaining-access")
                }
                AceImmediateButton(
                    accessibilityIdentifier:
                        "ace.intro.permissions.continue",
                    action: onContinue
                ) {
                    PrimaryButtonLabel(
                        title: "Continue",
                        symbol: "arrow.right",
                        isProminent: canContinue,
                        isEnabled: canContinue
                    )
                }
                .disabled(!canContinue)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .onAppear {
            companionManager.refreshAllPermissions()
            localMailAccess.checkAgain()
        }
        .onReceive(screenRecordingRepairCoordinator.$state) {
            repairState in
            guard repairState != .idle,
                  !repairState.isRunning else { return }
            companionManager.refreshAllPermissions()
        }
        .onReceive(accessibilityRepairCoordinator.$state) {
            repairState in
            guard repairState != .idle,
                  !repairState.isRunning else { return }
            companionManager.refreshAllPermissions()
        }
        .onReceive(voiceRepairCoordinator.$state) { refreshAfterTerminal($0) }
        .onReceive(microphoneRepairCoordinator.$state) { refreshAfterTerminal($0) }
        .onReceive(speechRepairCoordinator.$state) { refreshAfterTerminal($0) }
        .onReceive(screenContentRepairCoordinator.$state) { refreshAfterTerminal($0) }
        .onReceive(appAutomationRepairCoordinator.$state) { refreshAfterTerminal($0) }
    }

    private func refreshAfterTerminal(_ state: PermissionRepairState) {
        guard state != .idle, !state.isRunning else { return }
        companionManager.refreshAllPermissions()
    }

    private func beginScreenContentRepair() {
        screenContentRepairCoordinator.start {
            let initial = companionManager.requestScreenContentPermission()
            if case let .failed(failure) = initial {
                return .failed(
                    PermissionRepairFailure(code: failure.code, message: failure.message)
                )
            }
            return await PermissionRepairObservation.wait {
                if companionManager.hasScreenContentPermission {
                    guard let proof = companionManager.screenContentRepairProof
                    else {
                        return .failed(
                            PermissionRepairFailure(
                                code: "screen_content.proof_missing",
                                message: "Screen Content became ready without a capture-dimension receipt."
                            )
                        )
                    }
                    return .succeeded(proof)
                }
                guard !companionManager.isRequestingScreenContent else { return nil }
                if case let .failed(failure)? = companionManager.screenContentControlOutcome {
                    return .failed(
                        PermissionRepairFailure(code: failure.code, message: failure.message)
                    )
                }
                return nil
            }
        }
    }
}

private struct AppAutomationPermissionRow: View {
    @ObservedObject var permissionWarmup: PermissionWarmup
    @ObservedObject var repairCoordinator: PermissionRepairCoordinator

    private var progressDetail: String {
        let progress = PermissionWarmupProgressPolicy.detail(
            isRunning: permissionWarmup.isRunning,
            currentTarget: permissionWarmup.currentAutomationTarget,
            completedTargetCount:
                permissionWarmup.completedAutomationTargetCount,
            totalTargetCount: PermissionAutomationTarget.allCases.count
        )
        return progress
            + " Optional: an unavailable app affects only that app; Ace still continues."
    }

    var body: some View {
        PermissionRow(
            symbol: "app.badge.checkmark",
            title: "App Automation (optional)",
            detail: progressDetail,
            isGranted: permissionWarmup.hasProvenAppAutomation,
            accessibilityIdentifier: SetupControlID.introAppAutomation,
            repairState: repairCoordinator.state,
            grant: {
                repairCoordinator.start {
                    // The coordinator's task begins after SwiftUI finishes the
                    // button transaction, eliminating the old 50 ms admission gap.
                    _ = await permissionWarmup.run()
                    if permissionWarmup.hasProvenAppAutomation {
                        return .succeeded(
                            .permissionReadback(permission: .appAutomation)
                        )
                    }
                    let crashed = permissionWarmup
                        .lastCrashedApplications.first
                    return .failed(
                        PermissionRepairFailure(
                            code: crashed.map {
                                "automation.target_crashed.\($0)"
                            } ?? "automation.grants_incomplete",
                            message: permissionWarmup.failureSummary
                        )
                    )
                }
            }
        )
    }
}

private struct LocalMailAccessPermissionRow: View {
    @ObservedObject var controller: LocalMailAccessController
    let accessibilityIdentifier: String

    private var detail: String {
        if controller.hasAccess {
            return "Apple Mail's local index is accessible. Connected Gmail uses its own account connection."
        }
        return "Required for local Apple Mail inbox reads: add an account in Mail and grant Ace Full Disk Access. Connected Gmail works without it."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(
                    controller.hasAccess
                        ? DS.Colors.success : DS.Colors.warning
                )
                .frame(width: 34, height: 34)
                .background(Circle().fill(DS.Colors.surface2))

            VStack(alignment: .leading, spacing: 4) {
                Text("Local Mail Access (optional)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if controller.didOpenFullDiskAccessSettings
                    && !controller.hasAccess {
                    Text("Turn on Ace, then return and Check again. If macOS still shows Not ready, restart Ace once.")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            accessibilityIdentifier + ".guidance"
                        )
                }

                if let launchFailureMessage = controller.launchFailureMessage {
                    Text(launchFailureMessage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(accessibilityIdentifier + ".launch-state")
                }

                if let restartFailureMessage =
                    controller.restartFailureMessage {
                    Text(restartFailureMessage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.warningText)
                        .accessibilityIdentifier(
                            accessibilityIdentifier + ".restart-state"
                        )
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text(controller.hasAccess ? "Ready" : "Not ready")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(
                        controller.hasAccess
                            ? DS.Colors.success : DS.Colors.warning
                    )
                    .accessibilityIdentifier(
                        accessibilityIdentifier + ".status"
                    )
                    .accessibilityValue(
                        controller.hasAccess ? "ready" : "not-ready;optional"
                    )

                LocalMailAccessButton(
                    title: "Open Apple Mail",
                    accessibilityIdentifier:
                        SetupControlID.introLocalMailOpenAppleMail,
                    action: { controller.openAppleMail() }
                )

                if !controller.hasAccess {
                    LocalMailAccessButton(
                        title: "Open Full Disk Access",
                        accessibilityIdentifier:
                            accessibilityIdentifier + ".open-settings",
                        action: {
                            controller.openFullDiskAccessSettings()
                        }
                    )
                }

                LocalMailAccessButton(
                    title: "Check again",
                    accessibilityIdentifier:
                        accessibilityIdentifier + ".check-again",
                    action: { controller.checkAgain() }
                )

                if controller.didOpenFullDiskAccessSettings
                    && !controller.hasAccess {
                    LocalMailAccessButton(
                        title: "Restart Ace",
                        accessibilityIdentifier:
                            accessibilityIdentifier + ".restart",
                        action: {
                            controller.restartAceAfterOwnerRequest()
                        }
                    )
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct LocalMailAccessButton: View {
    let title: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        AceTrackedButton(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(DS.Colors.accent))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isGranted: Bool
    var actionTitle = "Grant"
    var isActionInProgress = false
    let accessibilityIdentifier: String
    var repairState: PermissionRepairState = .idle
    let grant: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isGranted ? DS.Colors.success : DS.Colors.warning)
                .frame(width: 34, height: 34)
                .background(Circle().fill(DS.Colors.surface2))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                if let visibleRepairStatus = repairState.visibleStatus {
                    Text(visibleRepairStatus)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(
                            repairState.proof == nil
                                ? DS.Colors.warning
                                : DS.Colors.success
                        )
                        .accessibilityIdentifier(
                            accessibilityIdentifier + ".state"
                        )
                        .accessibilityValue(
                            repairState.accessibilityValue
                        )
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text("Granted")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.success)
            } else if isActionInProgress || repairState.isRunning {
                ProgressView()
                    .controlSize(.small)
                .foregroundColor(DS.Colors.textSecondary)
                .accessibilityHidden(true)
            } else {
                AceTrackedButton(action: grant) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityIdentifier(
                    accessibilityIdentifier + ".action"
                )
                .accessibilityValue(
                    repairState.accessibilityValue
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Step 4: Ready

private struct ReadyStepView: View {
    @ObservedObject var brainConnection: BrainConnectionModel
    @ObservedObject var companionManager: CompanionManager
    let onFinish: () -> Bool
    let onBack: () -> Void

    @State private var isPulsing = false
    @StateObject private var finishActionModel = AceActionModel()

    private var chordLabels: [String] {
        BuddyPushToTalkShortcut.currentShortcutOption.keyCapsuleLabels
    }

    private var setupProofsReady: Bool {
        brainConnection.hasAnsweredRealProbeThisSession
            && companionManager.firstRunSetupPrerequisitesReady
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            AceGem(size: 68, isActive: true)

            Spacer().frame(height: 26)

            Text("Hold to talk")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer().frame(height: 18)

            HStack(spacing: 10) {
                ForEach(Array(chordLabels.enumerated()), id: \.offset) { index, label in
                    if index > 0 {
                        Text("+")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    KeyCapsule(label: label, isGlowing: isPulsing)
                }
            }

            Spacer().frame(height: 22)

            Text("Hold both keys, ask your question out loud, let go — or click a live test below.")
                .font(.system(size: 14))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            Spacer().frame(height: 30)

            HStack(spacing: 10) {
                ForEach(SetupCapabilityTryout.allCases, id: \.self) { tryout in
                    ExamplePrompt(
                        text: tryout.label,
                        isEnabled: setupProofsReady,
                        action: {
                            guard setupProofsReady else { return }
                            // A physical click in Ace's own setup window. Owner
                            // authority, attested by the click — and labeled so
                            // no receipt can present it as speech.
                            companionManager.ingestOwnerUtterance(
                                tryout.utterance,
                                origin: .directHumanUIAction
                            )
                        }
                    )
                }
            }

            if !setupProofsReady {
                Text("Live tests stay locked until the brain, voice, permissions, and app controls are all proven.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.warningText)
                    .padding(.top, 10)
            }

            Spacer().frame(height: 30)

            summaryLine

            Spacer()

            HStack(spacing: 12) {
                AceImmediateButton(
                    accessibilityIdentifier: "ace.intro.ready.back",
                    action: onBack
                ) {
                    SecondaryButtonLabel(title: "Back")
                }
                Spacer()
                AcePrimaryActionButton(
                    actionModel: finishActionModel,
                    id: AceActionID(rawValue: "intro.finish"),
                    title: "Finish setup",
                    symbol: "checkmark",
                    blockedReason: setupProofsReady
                        ? nil
                        : "Finish unlocks after every setup proof passes."
                ) {
                    guard onFinish() else {
                        throw AceActionFailure(
                            code: "setup.proof_changed",
                            message: "A setup check needs attention. Complete the highlighted step, then finish setup again.",
                            recoveryTitle: "Check setup", recovery: .retry
                        )
                    }
                    return AceActionSuccess(
                        message: "Ace setup is complete."
                    )
                }
                .accessibilityIdentifier("ace.intro.finish")

                if case let .succeeded(success) = finishActionModel.phase(
                    for: AceActionID(rawValue: "intro.finish")
                ) {
                    Text(success.message)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                        .accessibilityIdentifier(
                            "ace.intro.finish.success"
                        )
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    /// One honest line about what is and isn't wired up, so nobody leaves setup
    /// believing they have a brain they don't have.
    private var summaryLine: some View {
        let connectedBrainName = AceBrainRoute.current == .customerOwned
            ? BrainBackend.selectedCLI.displayName
            : "Black Label hosted Codex"
        let brainText: String = brainConnection.hasAnsweredRealProbeThisSession
            ? "Brain: \(connectedBrainName) connected"
            : "Brain: not connected yet — reopen setup from the menu bar to finish"
        let permissionText: String = setupProofsReady
            ? "all setup proofs passed"
            : "setup proof missing — go back and repair it"

        return HStack(spacing: 8) {
            Image(systemName: setupProofsReady
                ? "checkmark.circle.fill"
                : "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(setupProofsReady
                    ? DS.Colors.success
                    : DS.Colors.warning)
            Text("\(brainText) · \(permissionText)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(DS.Colors.surface1.opacity(0.85)))
    }
}

// MARK: - Shared pieces

private struct StepHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundColor(DS.Colors.accentText)
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(DS.Colors.textPrimary)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.top, 24)
    }
}

private struct StatusChip: View {
    let status: BrainConnectionStatus

    var body: some View {
        HStack(spacing: 6) {
            if status.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .shadow(color: color.opacity(0.7), radius: 4)
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private var label: String {
        if status.isChecking { return "Checking" }
        switch status.state {
        case .connected: return "Connected"
        case .signedOut: return "Sign in"
        case .notInstalled: return "Not installed"
        case .failed: return status.isUsageLimited ? "Usage limit" : "Error"
        case .unknown: return "Unknown"
        }
    }

    private var color: Color {
        if status.isChecking { return DS.Colors.textTertiary }
        switch status.state {
        case .connected: return DS.Colors.success
        case .signedOut: return DS.Colors.warningText
        case .notInstalled: return DS.Colors.textTertiary
        case .failed: return DS.Colors.destructiveText
        case .unknown: return DS.Colors.textTertiary
        }
    }
}

private struct InstructionLine: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(DS.Colors.surface3))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ActionButton: View {
    let title: String
    var symbol: String? = nil
    var isDisabled: Bool = false
    let handler: () -> Void

    @State private var isHovering = false

    init(
        title: String,
        symbol: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.isDisabled = isDisabled
        handler = action
    }

    var body: some View {
        AceTrackedButton(action: handler) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(isHovering && !isDisabled ? DS.Colors.accentHover : DS.Colors.accent)
            )
            .opacity(isDisabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: !isDisabled)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
    }
}

private struct FeatureChip: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DS.Colors.agentGold)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 176, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }
}

private struct ExamplePrompt: View {
    let text: String
    let isEnabled: Bool
    let handler: () -> Void

    @State private var isHovering = false

    init(
        text: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) {
        self.text = text
        self.isEnabled = isEnabled
        handler = action
    }

    var body: some View {
        AceTrackedButton(action: handler) {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(text)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(
                isEnabled ? DS.Colors.textPrimary : DS.Colors.textTertiary
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(
                    isHovering && isEnabled
                        ? DS.Colors.surface3
                        : DS.Colors.surface2.opacity(0.9)
                )
            )
            .overlay(
                Capsule().stroke(
                    isEnabled ? DS.Colors.agentGold : DS.Colors.borderSubtle,
                    lineWidth: 1
                )
            )
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
        .onHover { isHovering = isEnabled && $0 }
    }
}

private struct KeyCapsule: View {
    let label: String
    let isGlowing: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(minWidth: 74)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Colors.surface3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DS.Colors.agentGold.opacity(isGlowing ? 0.9 : 0.25), lineWidth: 1.5)
            )
            .shadow(color: DS.Colors.agentGold.opacity(isGlowing ? 0.35 : 0), radius: 12)
    }
}

private struct StepRail: View {
    let current: AceIntroView.IntroStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AceIntroView.IntroStep.allCases, id: \.rawValue) { step in
                let isDone = step.rawValue < current.rawValue
                let isCurrent = step == current
                HStack(spacing: 6) {
                    Circle()
                        .fill(isCurrent ? DS.Colors.agentGold : (isDone ? DS.Colors.success : DS.Colors.surface4))
                        .frame(width: 6, height: 6)
                    Text(step.title)
                        .font(.system(size: 11, weight: isCurrent ? .semibold : .medium))
                        .foregroundColor(isCurrent ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                }
                if step != AceIntroView.IntroStep.allCases.last {
                    Rectangle()
                        .fill(DS.Colors.borderSubtle)
                        .frame(width: 16, height: 1)
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: current)
    }
}

private struct PrimaryButtonLabel: View {
    let title: String
    var symbol: String? = nil
    var isProminent: Bool = true
    var isEnabled: Bool = true

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .foregroundColor(
            isProminent ? DS.Colors.textOnAccent : DS.Colors.textPrimary
        )
        .opacity(isEnabled ? 1 : 0.48)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(
            Capsule().fill(
                isProminent
                    ? (isHovering ? DS.Colors.accentHover : DS.Colors.accent)
                    : DS.Colors.surface3
            )
        )
        .shadow(
            color: isProminent && isEnabled
                ? DS.Colors.accent.opacity(isHovering ? 0.45 : 0.25)
                : .clear,
            radius: 14,
            y: 4
        )
        .scaleEffect(isHovering ? 1.03 : 1)
        .onHover { isHovering = isEnabled && $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

private struct SecondaryButtonLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }
}

// MARK: - Motion

/// The gold gem, the same shape the overlay cursor uses, breathing.
private struct AceGem: View {
    let size: CGFloat
    let isActive: Bool

    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [DS.Colors.agentGoldBright.opacity(0.55), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.95
                    )
                )
                .scaleEffect(1 + phase * 0.22)
                .opacity(0.85 - phase * 0.3)

            // Same cut stone the tour flies around the desktop, so the mark in
            // the header and the thing that greets them are one object.
            TimelineView(.animation) { timeline in
                AceCutGem(
                    accent: .gold,
                    animationTime: timeline.date.timeIntervalSinceReferenceDate
                )
                .frame(width: size * 1.9, height: size * 1.9)
            }
            .shadow(color: DS.Colors.agentGold.opacity(0.55), radius: size * 0.18)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard isActive else { return }
            withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }
}

/// Slow-drifting colour fields behind the whole window. Three blurred blobs on
/// long, offset cycles — enough motion to feel alive, cheap enough that setup
/// never spins a fan.
private struct AuroraBackground: View {
    @State private var drift: CGFloat = 0

    var body: some View {
        ZStack {
            DS.Colors.background

            blob(DS.Colors.agentGold.opacity(0.20), size: 520)
                .offset(x: -260 + drift * 70, y: -190 + drift * 40)
            blob(DS.Colors.agentBlue.opacity(0.22), size: 460)
                .offset(x: 300 - drift * 60, y: -120 + drift * 70)
            blob(DS.Colors.agentPurple.opacity(0.16), size: 560)
                .offset(x: 120 + drift * 40, y: 250 - drift * 60)

            // Keeps text legible over the blobs no matter where they drift.
            LinearGradient(
                colors: [DS.Colors.background.opacity(0.25), DS.Colors.background.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) {
                drift = 1
            }
        }
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: 90)
    }
}
#endif // circuit-convert
