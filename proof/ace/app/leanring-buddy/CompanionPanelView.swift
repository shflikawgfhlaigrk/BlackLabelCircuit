#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import Foundation
import CircuitPortKit
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(Speech) && !CIRCUIT_WINDOWS_SIM
import Speech
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

private final class AcePanelVisualTargetAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct AcePanelVisualTargetAnchor: NSViewRepresentable {
    let target: AcePanelVisualTarget
    let companionManager: CompanionManager

    func makeNSView(context: Context) -> NSView {
        let view = AcePanelVisualTargetAnchorView(frame: .zero)
        view.setAccessibilityElement(false)
        companionManager.registerPanelVisualTarget(target, view: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        companionManager.registerPanelVisualTarget(target, view: view)
    }
}

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AceMotionPolicy.preferenceKey) private var motionPreference = "cinematic"
    @AppStorage("ace.motion.landing-sound") private var landingSound = false
    @AppStorage(AceAppearancePreference.preferenceKey) private var appearancePreference = "system"
    @Namespace private var motionSelection

    // Observed so the panel re-renders on every licence verdict — the trial
    // line below reads trialEndsAt, which changes only when `state` does.
    @ObservedObject private var license = AceLicense.shared
    @State private var emailInput: String = ""
    @State private var privacyDashboardExpanded = false
    @State private var lockedRecoveryStatus: String?
    @State private var lockedRecoveryStatusIsFailure = false
    @State private var founderMessageStatus: String?
    @State private var confirmStopAndNotes = false
    @State private var savedContextReadIssue = AceConversationHistory.lastReadIssue()
    @State private var isCheckingSavedContext = false
    @State private var confirmQuitWithNotes = false
    @State private var providerReceiptRevision = 0
    @State private var capabilityGuideIsExpanded = false
    @State private var capabilityGuideQuery = ""
    @State private var buyerWorkReceiptsExpanded = false
    @StateObject private var buyerRecovery = AceBuyerRecoveryModel()
    @StateObject private var brainConnection = BrainConnectionModel()
    // Ace sends and drafts through the buyer's own Google account. Until they
    // hand over an app password there is nothing to send with, so the panel
    // asks for one instead of failing later at send time.
    @StateObject private var gmailAccount = GmailAccountController()
    @ObservedObject private var floatingInbox = FloatingInboxController.shared
    @State private var changingGmailAccount = false
    @State private var mailAccountHandoffStatus: String?
    @State private var gmailSetupHandoffStatus: String?
    @StateObject private var codexConnectionCoordinator =
        PermissionRepairCoordinator()
    @StateObject private var claudeConnectionCoordinator =
        PermissionRepairCoordinator()
    @StateObject private var qwenConnectionCoordinator =
        PermissionRepairCoordinator()
    @ObservedObject private var screenRecordingRepairCoordinator =
        WindowPositionManager.screenRecordingPermissionRepairCoordinator
    @ObservedObject private var accessibilityRepairCoordinator =
        WindowPositionManager.accessibilityPermissionRepairCoordinator
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
    @ObservedObject private var repairAllCoordinator =
        SetupControlCoordinatorBank.shared.panelRepairAll
    @ObservedObject private var findAppCoordinator =
        SetupControlCoordinatorBank.shared.panelAccessibilityFindApp
    @ObservedObject private var setupWindowCoordinator =
        SetupControlCoordinatorBank.shared.panelSetupWindow
    @ObservedObject private var setupRepairCoordinator =
        SetupControlCoordinatorBank.shared.panelSetupRepair

    @ViewBuilder
    var body: some View {
        Group {
            switch AceEntitlementPanelPolicy.presentation(state: license.state) {
            case .premium:
                premiumPanel
            case .locked(let message, _):
                lockedAccountPanel(message: message)
            }
        }
        .preferredColorScheme((AceAppearancePreference(rawValue: appearancePreference) ?? .system).colorScheme)
        .onAppear { (AceAppearancePreference(rawValue: appearancePreference) ?? .system).apply() }
        .onChange(of: appearancePreference) { value in
            (AceAppearancePreference(rawValue: value) ?? .system).apply()
        }
        .confirmationDialog("Quit Ace and discard unsaved notes?", isPresented: $confirmQuitWithNotes) {
            AceTrackedButton("Quit without saving notes", role: .destructive) {
                AceGuaranteedQuit.perform(reason: "reviewed panel quit", allowDiscardingNotes: true)
            }
            .accessibilityIdentifier("ace.quit.discard-notes")
            AceTrackedButton("Keep Ace open", role: .cancel) {}
                .accessibilityIdentifier("ace.quit.keep-open")
        } message: {
            Text("The current capture, notes being prepared, and unsaved review or retry are kept only while Ace stays open. Keep Ace open, then finish and save your notes to keep them.")
        }
        .onChange(of: companionManager.stealthActive) { _ in confirmQuitWithNotes = false }
        .onDisappear { confirmQuitWithNotes = false }
    }

    private func requestQuitFromPanel() {
        guard !companionManager.stealthActive,
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else { return }
        if companionManager.meetingNotetaker.hasUnsavedNotes {
            confirmQuitWithNotes = true
        } else {
            AceGuaranteedQuit.perform(reason: "panel quit")
        }
    }

    private var premiumPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            AceTrackedButton { floatingInbox.showSettings() } label: {
                Label("Email settings", systemImage: "envelope.badge")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered).pointerCursor()
            .accessibilityIdentifier("ace.email.settings")
            .padding(.horizontal, 16).padding(.bottom, 10)
            if let message = companionManager.dictationFailureMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "mic.slash")
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("ace.dictation-failure.message")
                    Spacer(minLength: 0)
                    AceTrackedButton("Dismiss") {
                        companionManager.dismissDictationFailure()
                    }
                    .buttonStyle(AceMotionButtonStyle())
                    .pointerCursor()
                    .accessibilityIdentifier("ace.dictation-failure.dismiss")
                }
                .padding(12)
                .background(DS.Colors.surface2)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FirstRunFailureRecoveryView(
                        reporter: FirstRunFailureReporter.shared,
                        compact: true
                    )

                    if let issue = savedContextReadIssue {
                        savedContextRecoverySection(issue)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }

                    motionControls
                        .padding(.top, 12)
                        .padding(.horizontal, 16)

                    showBlackLabelCursorToggleRow
                        .padding(.horizontal, 16)

                    permissionsCopySection
                        .padding(.top, 16)
                        .padding(.horizontal, 16)

                    AceLanguagePanel(companionManager: companionManager)
                        .padding(.top, 12)
                        .padding(.horizontal, 16)

                    if let trialStatusLine = trialStatusLine {
                        Spacer()
                            .frame(height: 8)

                        Text(trialStatusLine)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                    }

                    if !companionManager.buyerWorkReceipts.isEmpty {
                        Spacer()
                            .frame(height: 12)

                        buyerWorkReceiptsSection
                            .padding(.horizontal, 16)
                    }

                    Spacer()
                        .frame(height: 12)

                    AceStandingTasksPanel(runtime: companionManager.standingTaskRuntime)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)

                    capabilityGuideSection
                        .padding(.horizontal, 16)

                    Spacer()
                        .frame(height: 12)

                    buyerRecoverySection
                        .padding(.horizontal, 16)

                    if let review = companionManager.appActionReview {
                        Spacer()
                            .frame(height: 12)

                        appActionReviewSection(review)
                            .padding(.horizontal, 16)
                    }

                    if let selection = companionManager.appleMailSenderSelection {
                        Spacer()
                            .frame(height: 12)

                        appleMailSenderSelectionSection(selection)
                            .padding(.horizontal, 16)
                    }

                    if companionManager.appleMailNeedsConnection {
                        Spacer()
                            .frame(height: 12)

                        connectAppleMailSection
                            .padding(.horizontal, 16)
                    }

                    if !companionManager.visibleResponseText.isEmpty {
                        Spacer()
                            .frame(height: 12)

                        visibleResponseSection
                            .padding(.horizontal, 16)
                    }

                    Spacer()
                        .frame(height: 12)

                    AcademicSettingsView()
                        .padding(.horizontal, 16)

                    if let selection =
                            companionManager.appleMessagesRecipientSelection {
                        Spacer()
                            .frame(height: 12)

                        appleMessagesRecipientSelectionSection(selection)
                            .padding(.horizontal, 16)
                    }

                    if companionManager.appleMessagesNeedsSignIn
                        || companionManager.appleMessagesConnectionIsPending {
                        Spacer()
                            .frame(height: 12)

                        connectAppleMessagesSection(
                            isWaitingForConnection:
                                companionManager
                                    .appleMessagesConnectionIsPending
                        )
                            .padding(.horizontal, 16)
                    }

                    if let receipt =
                            companionManager.latestWorkflowArtifactReceipt {
                        Spacer()
                            .frame(height: 12)

                        artifactReceiptSection(receipt)
                            .padding(.horizontal, 16)
                    }

                    if let notesResult =
                            companionManager.latestMeetingNotesResult {
                        Spacer()
                            .frame(height: 12)

                        meetingNotesResultSection(notesResult)
                            .padding(.horizontal, 16)
                    }

                    Spacer()
                        .frame(height: 12)

                    tradingModeSection
                        .padding(.horizontal, 16)

                    if companionManager.panelPermissionsReady {
                        Spacer()
                            .frame(height: 12)

                        MeetingNotesPanelSection(
                            companionManager: companionManager,
                            meetingNotetaker:
                                companionManager.meetingNotetaker
                        )
                        .padding(.horizontal, 16)
                    }

                    if companionManager.hasCompletedOnboarding {
                        Spacer()
                            .frame(height: 12)

                        providerAccountsSection
                            .padding(.horizontal, 16)
                    }

                    if companionManager.hasCompletedOnboarding {
                        Spacer()
                            .frame(height: 12)

                        PartnerModePanel(
                            companionManager: companionManager
                        )
                        .padding(.horizontal, 16)
                    }

                    if companionManager.hasCompletedOnboarding
                        && companionManager.panelPermissionsReady {
                        Spacer()
                            .frame(height: 12)

                        MorningLinkBriefPanel(
                            runtime:
                                companionManager.morningLinkBriefRuntime
                        )
                        .padding(.horizontal, 16)

                        Spacer()
                            .frame(height: 12)

                        modelPickerRow
                            .padding(.horizontal, 16)

                        Spacer()
                            .frame(height: 14)

                        privateModeSection
                            .padding(.horizontal, 16)

                        Spacer()
                            .frame(height: 12)

                        privacyDashboardSection
                            .padding(.horizontal, 16)
                    }

                    if !companionManager.allPermissionsGranted
                        || panelPermissionRepairReceiptIsVisible {
                        Spacer()
                            .frame(height: 16)

                        settingsSection
                            .padding(.horizontal, 16)
                    }

                    if !companionManager.hasCompletedOnboarding
                        && companionManager.panelPermissionsReady {
                        Spacer()
                            .frame(height: 16)

                        startButton
                            .padding(.horizontal, 16)
                    }

                    Spacer()
                        .frame(height: 12)
                }
            }
            .frame(maxHeight: 520)
            .accessibilityLabel("Ace controls")

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
        .sheet(isPresented: $floatingInbox.settingsPresented) { emailSettingsPanel }
        .onAppear { refreshSavedContextNotice() }
        .onReceive(NotificationCenter.default.circuitCombine.publisher(
            for: AceConversationHistory.readIssueDidChangeNotification
        ).receive(on: DispatchQueue.main.circuitScheduler)) { _ in
            refreshSavedContextNotice()
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
        .onReceive(
            NotificationCenter.default.circuitCombine.publisher(
                for: .aceProviderInvocationReceiptDidChange
            )
        ) { _ in
            providerReceiptRevision &+= 1
        }
    }

    private func refreshSavedContextNotice() {
        guard !companionManager.stealthActive,
              !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else {
            savedContextReadIssue = nil
            return
        }
        savedContextReadIssue = AceConversationHistory.lastReadIssue()
    }

    private func savedContextRecoverySection(_ issue: AceConversationHistory.ReadIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Saved history needs attention", systemImage: "clock.badge.exclamationmark")
                .font(.system(size: 12, weight: .semibold))
            Text(issue.ownerMessage)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            AceTrackedButton(isCheckingSavedContext ? "Checking…" : "Check saved history") {
                guard !isCheckingSavedContext, !companionManager.stealthActive,
                      !StealthVisibilityGate.shared.isActive,
                      !StealthEntryLatch.shared.isRaised else { return }
                isCheckingSavedContext = true
                Task {
                    await Task.detached(priority: .utility) {
                        _ = AceConversationHistory.loadBundle(performUnlessRaised: { body in
                            StealthEntryLatch.shared.performUnlessRaised(body)
                        })
                    }.value
                    isCheckingSavedContext = false
                    refreshSavedContextNotice()
                }
            }
            .buttonStyle(AceMotionButtonStyle())
            .pointerCursor()
            .disabled(isCheckingSavedContext)
            .accessibilityIdentifier("ace.context.check-again")
        }
        .foregroundColor(DS.Colors.textSecondary)
        .padding(12)
        .background(DS.Colors.surface2)
        .accessibilityIdentifier("ace.context.recovery")
    }

    private func lockedAccountPanel(message: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            ScrollView {
              VStack(alignment: .leading, spacing: 12) {
                FirstRunFailureRecoveryView(
                    reporter: FirstRunFailureReporter.shared,
                    compact: true
                )
                Label("Account access required", systemImage: "lock.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    "Voice, Partner Mode, notes, workflows, app actions, dashboards, and background work are stopped until the server confirms access again."
                )
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                AceTrackedButton(license.isRefreshing ? "Checking…" : "Check again") {
                    Task { await license.refresh() }
                }
                .buttonStyle(AceMotionButtonStyle())
                .pointerCursor()
                .disabled(license.isRefreshing)
                .accessibilityIdentifier("ace.account.check-again")

                if let status = license.refreshStatus {
                    Text(status)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ace.account.check-status")
                }

                // Never disabled: while the flow is genuinely busy a click is a
                // harmless re-present, and once the busy state has wedged past
                // the recovery window a click restarts the flow. A disabled
                // button here left Build 61 with no recovery path at all.
                AceTrackedButton("Link this Mac") {
                    license.presentDeviceAuthorization()
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Colors.accent)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("ace.account.link-this-mac")

                if let linkStatus =
                        license.deviceAuthorizationState.ownerMessage {
                    HStack(alignment: .top, spacing: 7) {
                        if license.deviceAuthorizationState.isWorking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(
                                systemName:
                                    license.deviceAuthorizationState
                                        .messageIsFailure
                                    ? "exclamationmark.triangle.fill"
                                    : "checkmark.circle.fill"
                            )
                        }
                        Text(linkStatus)
                            .font(.system(size: 10, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(
                        license.deviceAuthorizationState.messageIsFailure
                            ? DS.Colors.destructiveText
                            : DS.Colors.textSecondary
                    )
                    .accessibilityIdentifier("ace.account.link-status")
                }

                AceTrackedButton("Use a licence key instead") {
                    license.presentKeyEntry()
                }
                .buttonStyle(AceMotionButtonStyle())
                .foregroundColor(DS.Colors.textSecondary)
                .accessibilityIdentifier("ace.account.use-license-key")

                HStack(spacing: 8) {
                    AceTrackedButton("Open Account") {
                        performLockedRecoveryOpen(
                            progress: "Opening your account…",
                            success: "The account page was requested in your browser.",
                            failure:
                                "Ace couldn't open the account page. Check your default browser and try again."
                        ) { completion in
                            license.openAccountPage(completion: completion)
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ace.account.open")

                    AceTrackedButton("Manage / Cancel") {
                        performLockedRecoveryOpen(
                            progress: "Opening subscription controls…",
                            success:
                                "Subscription controls were requested in your browser.",
                            failure:
                                "Ace couldn't open subscription controls. Open Account or contact support."
                        ) { completion in
                            license.openSubscriptionCancellation(completion: completion)
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ace.account.manage")
                }

                AceTrackedButton("Contact support") {
                    performLockedRecoveryOpen(
                        progress: "Opening Ace support…",
                        success:
                            "The purchase support page was requested in your browser.",
                        failure:
                            "Ace couldn't open support. Email hello@ace-bl.tech from any account."
                    ) { completion in
                        license.contactSupport(completion: completion)
                    }
                }
                .buttonStyle(AceMotionButtonStyle())
                .foregroundColor(DS.Colors.textSecondary)
                .accessibilityIdentifier("ace.account.support")

                if let lockedRecoveryStatus {
                    Text(lockedRecoveryStatus)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(
                            lockedRecoveryStatusIsFailure
                                ? DS.Colors.destructiveText
                                : DS.Colors.textSecondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "ace.account.external-status"
                        )
                }

                Divider()
                    .background(DS.Colors.borderSubtle)

                HStack {
                    AceTrackedButton("Quit Ace") {
                        requestQuitFromPanel()
                    }
                    .buttonStyle(AceMotionButtonStyle())
                    .foregroundColor(DS.Colors.textTertiary)
                    .accessibilityIdentifier("ace.account.quit")

                    Spacer()

                    AceTrackedButton("Close") {
                        // Direct call first — the notification alone proved
                        // losable in Build 61's dead Close button.
                        MenuBarPanelManager.shared?.hidePanelForUserClose()
                        NotificationCenter.default.post(
                            name: .blacklabelDismissPanel,
                            object: nil
                        )
                    }
                    .buttonStyle(AceMotionButtonStyle())
                    .foregroundColor(DS.Colors.textTertiary)
                    .accessibilityIdentifier("ace.account.close")
                }
            }
              .padding(16)
            }
            .frame(maxHeight: 520)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    private func performLockedRecoveryOpen(
        progress: String,
        success: String,
        failure: String,
        action: @MainActor (@escaping (Bool) -> Void) -> Bool
    ) {
        lockedRecoveryStatus = progress
        lockedRecoveryStatusIsFailure = false
        _ = action { didOpen in
            lockedRecoveryStatus = license.purchaseRecoveryStatus ?? (didOpen ? success : failure)
            lockedRecoveryStatusIsFailure = !didOpen
        }
    }

    private func artifactReceiptSection(
        _ receipt: ArtifactReceipt
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: artifactIconName(receipt.state))
                    .foregroundColor(artifactColor(receipt.state))
                Text(artifactTitle(receipt.state))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
            }

            Text(receipt.artifactPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let sha256 = receipt.sha256 {
                Text("SHA-256 \(sha256)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textSelection(.enabled)
            }

            if receipt.state == .done {
                HStack(spacing: 8) {
                    AceTrackedButton("Open Result") {
                        companionManager.openLatestWorkflowResult()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ace.workflow.open.action")

                    AceTrackedButton("Show in Finder") {
                        companionManager.showLatestWorkflowResultInFinder()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ace.workflow.reveal.action")
                }
                .font(.system(size: 10, weight: .semibold))

                controlOutcomeStatus(
                    companionManager.workflowOpenControlOutcome,
                    accessibilityIdentifier: "ace.workflow.open.outcome"
                )

                controlOutcomeStatus(
                    companionManager.workflowRevealControlOutcome,
                    accessibilityIdentifier: "ace.workflow.reveal.outcome"
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .fill(artifactColor(receipt.state).opacity(0.09))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .stroke(
                artifactColor(receipt.state).opacity(0.45),
                lineWidth: 0.8
            )
        )
    }

    private func meetingNotesResultSection(
        _ result: MeetingNotesResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: meetingNotesIcon(result.state))
                    .foregroundColor(meetingNotesColor(result.state))
                Text(result.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
            }

            Text(result.detail)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let destinationPath = result.destinationPath {
                Text(destinationPath)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(result.folderPath)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AceTrackedButton("Open Folder") {
                companionManager.openLatestMeetingNotesFolder()
            }
            .buttonStyle(.bordered)
            .font(.system(size: 10, weight: .semibold))
            .accessibilityIdentifier("ace.meeting-folder.open.action")

            controlOutcomeStatus(
                companionManager.meetingFolderControlOutcome,
                accessibilityIdentifier: "ace.meeting-folder.open.outcome"
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .fill(meetingNotesColor(result.state).opacity(0.09))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .stroke(
                meetingNotesColor(result.state).opacity(0.45),
                lineWidth: 0.8
            )
        )
    }

    private func meetingNotesIcon(
        _ state: MeetingNotesResultState
    ) -> String {
        switch state {
        case .recording: return "waveform"
        case .generationPending: return "arrow.clockwise.circle.fill"
        case .reviewUnsaved: return "doc.text.magnifyingglass"
        case .saved: return "checkmark.circle.fill"
        case .noTranscript, .cancelled: return "doc.badge.minus"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func meetingNotesColor(
        _ state: MeetingNotesResultState
    ) -> Color {
        switch state {
        case .recording: return Color.blue
        case .generationPending: return DS.Colors.warning
        case .reviewUnsaved: return DS.Colors.warning
        case .saved: return DS.Colors.success
        case .noTranscript, .cancelled: return DS.Colors.textTertiary
        case .failed: return Color(red: 0.92, green: 0.38, blue: 0.38)
        }
    }

    private var tradingModeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(
                        companionManager.tradingModeActive
                            ? DS.Colors.agentPurpleBright
                            : DS.Colors.textTertiary
                    )
                    .frame(width: 8, height: 8)
                Text("Trading Mode")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
            }
            Text(companionManager.tradingModeStatusLine)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Analysis only — Ace never places trades or bets. Current "
                    + "prices and indicators require one capture-bound chart "
                    + "read with a visible symbol and timeframe."
            )
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            AceTrackedButton(action: {
                companionManager.toggleTradingModeFromPanel()
            }) {
                HStack(spacing: 7) {
                    Image(
                        systemName:
                            companionManager.tradingModeActive
                            ? "stop.circle.fill"
                            : "chart.xyaxis.line"
                    )
                    Text(
                        companionManager.tradingModeActive
                            ? "Exit Trading Mode"
                            : "Enter Trading Mode"
                    )
                    .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(
                        cornerRadius: DS.CornerRadius.medium,
                        style: .continuous
                    )
                    .fill(DS.Colors.agentPurple)
                )
            }
            .buttonStyle(AceMotionButtonStyle())
            .pointerCursor()
            .accessibilityIdentifier("ace.trading-mode.toggle.action")
            .accessibilityValue(
                companionManager.tradingModeActive ? "active" : "off"
            )
            .background(
                AcePanelVisualTargetAnchor(
                    target: .tradingModeToggle,
                    companionManager: companionManager
                )
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .fill(DS.Colors.agentPurple.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .stroke(
                DS.Colors.agentPurpleBright.opacity(0.5),
                lineWidth: 0.8
            )
        )
    }

    private func artifactTitle(
        _ state: ArtifactReceiptState
    ) -> String {
        switch state {
        case .started:
            return "Workflow started"
        case let .step(current, total, title):
            return "Step \(current)/\(total): \(title)"
        case .done:
            return "Verified workflow result"
        case let .failed(reason):
            return "Workflow failed: \(reason)"
        }
    }

    private func artifactIconName(
        _ state: ArtifactReceiptState
    ) -> String {
        switch state {
        case .started, .step:
            return "hammer"
        case .done:
            return "checkmark.seal"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    private func artifactColor(
        _ state: ArtifactReceiptState
    ) -> Color {
        switch state {
        case .started, .step:
            return DS.Colors.warning
        case .done:
            return DS.Colors.success
        case .failed:
            return Color(red: 0.92, green: 0.38, blue: 0.38)
        }
    }

    private func appActionReviewSection(
        _ review: AppActionReviewState
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: reviewIconName(review.phase))
                    .foregroundColor(reviewColor(review.phase))
                Text(reviewTitle(review.phase))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
            }

            if !review.exactPreview.isEmpty {
                ScrollView {
                    Text(review.exactPreview)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 145)
            }

            reviewInstruction(review.phase)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(reviewColor(review.phase))
                .fixedSize(horizontal: false, vertical: true)

            if reviewIsNotArmed(review.phase) {
                // A blocked/informational card must dismiss in place —
                // cancelVisibleAppActionReview is deliberately a no-op for
                // .notArmed, and hiding the whole panel was the only way to
                // clear a stale "Nothing is armed" card.
                AceTrackedButton("Dismiss") {
                    companionManager.dismissVisibleAppActionReview()
                }
                .buttonStyle(.bordered)
                .font(.system(size: 10, weight: .semibold))
            } else {
                if case .ready = review.phase {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        AceTrackedButton(companionManager.preparedEmailReviewIsVisible ? "Send" : "Confirm") {
                            companionManager.confirmVisibleAppActionReview()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!reviewIsReady(review.phase, at: context.date))
                        .accessibilityIdentifier("ace.app-action.confirm")
                    }
                }
                AceTrackedButton("Cancel") {
                    companionManager.cancelVisibleAppActionReview()
                }
                .buttonStyle(.bordered)
                .font(.system(size: 10, weight: .semibold))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .fill(reviewColor(review.phase).opacity(0.09))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .stroke(reviewColor(review.phase).opacity(0.45), lineWidth: 0.8)
        )
    }

    private func appleMailSenderSelectionSection(
        _ selection: AppleMailSenderSelectionState
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose Apple Mail sender")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Choose the exact Apple Mail address for this unsent draft.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            ForEach(selection.senderAddresses, id: \.self) { sender in
                AceTrackedButton(sender) {
                    companionManager.selectAppleMailSenderFromUI(sender)
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityLabel("Use Apple Mail sender \(sender)")
            }

            AceTrackedButton("Cancel") {
                companionManager.cancelPendingAppleMailFromUI()
            }
            .buttonStyle(.bordered)
            .font(.system(size: 10, weight: .semibold))
        }
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .fill(DS.Colors.warning.opacity(0.09))
        )
    }

    private var emailSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Email settings").font(.title2.bold())
                Spacer()
                AceTrackedButton("Done") { floatingInbox.settingsPresented = false }
                    .keyboardShortcut(.cancelAction).pointerCursor()
                    .accessibilityIdentifier("ace.email.settings.done")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FloatingInboxSettingsView()
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Apple Mail accounts").font(.headline)
                        Text("Use Gmail, iCloud, Outlook, Yahoo, or another account already connected to Apple Mail. Choose Apple Mail accounts above to show their unread inbox messages.")
                            .font(.callout).foregroundStyle(.secondary)
                        AceTrackedButton("Connect another email in Mail") {
                            let submitted = commitVisibleEffect {
                                return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app"))
                            }
                            mailAccountHandoffStatus = submitted
                                ? "In Mail, choose Mail → Add Account. After signing in, return here and refresh the inbox."
                                : "Mail did not open. Open Mail from Applications, then choose Add Account."
                        }
                        .buttonStyle(.bordered).pointerCursor()
                        .accessibilityIdentifier("ace.email.connect-apple-mail")
                        if let mailAccountHandoffStatus {
                            Text(mailAccountHandoffStatus).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    gmailAccountSection
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20).frame(width: 440, height: 570)
        .onAppear { gmailAccount.refresh() }
        .onChange(of: gmailAccount.configuredAddress) { _ in changingGmailAccount = false }
        .onDisappear {
            gmailAccount.cancelVerification()
            changingGmailAccount = false
            mailAccountHandoffStatus = nil
        }
    }

    /// Asks for the Google app password, or shows which address Ace is set up
    /// with. Google refuses to issue an app password until 2-Step Verification
    /// is on, so both steps are numbered and linked; work/school accounts and
    /// Advanced Protection are called out because they can block it entirely.
    @ViewBuilder
    private var gmailAccountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let address = gmailAccount.configuredAddress {
                Text("Connected Gmail")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Ace drafts as \(address). Send reviewed drafts from Gmail.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                AceTrackedButton("Disconnect Gmail") {
                    gmailAccount.disconnect()
                }
                .buttonStyle(.bordered)
                .font(.system(size: 10, weight: .semibold))
                .accessibilityIdentifier("ace.gmail.disconnect")
                .pointerCursor()
                AceTrackedButton(changingGmailAccount ? "Cancel account change" : "Change Gmail account") {
                    changingGmailAccount.toggle()
                    gmailAccount.cancelVerification()
                }
                .buttonStyle(.bordered).pointerCursor()
                .accessibilityIdentifier("ace.gmail.change")
            }
            if gmailAccount.configuredAddress == nil || changingGmailAccount {
                Text(changingGmailAccount ? "Connect a different Gmail account" : "Connect Gmail directly")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)
                AceTrackedButton("Connect with Google") {
                    Task { await gmailAccount.connectWithGoogle() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(gmailAccount.status == .verifying)
                .accessibilityIdentifier("ace.gmail.google-connect")
                .pointerCursor()
                Text("Choose your Google account and allow Gmail access. Ace checks your inbox before saving the connection.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Use a Google app password instead") {
                Text("Ace needs a Google app password — a 16-character code you generate for Ace alone and can revoke any time. It is not your Google account password.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("1. Turn on 2-Step Verification in your Google account (Google requires it before it will issue an app password).\n2. Open the app passwords page, name it Ace, and copy the 16-character code Google shows you.\n3. Paste it below with your Gmail address. Spaces are fine.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("you@gmail.com", text: $gmailAccount.addressField)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("ace.gmail.address")
                SecureField(
                    "app password",
                    text: $gmailAccount.appPasswordField
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .accessibilityIdentifier("ace.gmail.app-password")

                HStack(spacing: 8) {
                    AceTrackedButton("1. Turn on 2-Step Verification") {
                        openGmailSetupPage(GmailAccountPolicy.twoStepVerificationURL)
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityIdentifier("ace.gmail.two-step")
                    .pointerCursor()

                    AceTrackedButton("2. Open app passwords") {
                        openGmailSetupPage(GmailAccountPolicy.appPasswordURL)
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityIdentifier("ace.gmail.app-passwords")
                    .pointerCursor()
                }

                Text(GmailAccountPolicy.appPasswordUnavailableHelp)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    AceTrackedButton("Save and check") {
                        Task { await gmailAccount.save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: 11, weight: .semibold))
                    .disabled(gmailAccount.status == .verifying)
                    .accessibilityIdentifier("ace.gmail.save")
                    .pointerCursor()
                }
            }
            }

            if let gmailSetupHandoffStatus {
                Text(gmailSetupHandoffStatus)
                    .font(.system(size: 10, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ace.gmail.browser.state")
            }
            switch gmailAccount.status {
            case .verifying:
                AceTrackedButton("Cancel connection") { gmailAccount.cancelVerification() }
                    .buttonStyle(.bordered).pointerCursor()
                    .accessibilityIdentifier("ace.gmail.cancel")
                Text("Connecting to Google and checking inbox access…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .accessibilityIdentifier("ace.gmail.status")
            case .failed(let message):
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ace.gmail.status")
            case .connected(let address):
                Text("Saved Gmail account: \(address). Ace checks access when you use this account.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .accessibilityIdentifier("ace.gmail.status")
            case .idle:
                EmptyView()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .fill(DS.Colors.warning.opacity(0.09))
        )
    }

    private func openGmailSetupPage(_ address: String) {
        guard let url = URL(string: address) else { return }
        let submitted = commitVisibleEffect { NSWorkspace.shared.open(url) }
        guard !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else { return }
        gmailSetupHandoffStatus = submitted
            ? "Google setup was handed to your browser. Complete that step there, then return to Ace."
            : "The browser did not open. Open \(address) in your browser."
    }

    private var connectAppleMailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Mail needs an enabled sender")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Connect an account in Apple Mail. Ace will resume this exact in-memory draft request when a sender becomes ready.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            AceTrackedButton("Connect Apple Mail") {
                companionManager.connectAppleMailFromUI()
            }
            .buttonStyle(.borderedProminent)
            .font(.system(size: 11, weight: .semibold))

            AceTrackedButton("Cancel pending draft") {
                companionManager.cancelPendingAppleMailFromUI()
            }
            .buttonStyle(.bordered)
            .font(.system(size: 10, weight: .semibold))
            .accessibilityIdentifier("ace.apple-mail.pending.cancel")

            controlOutcomeStatus(
                companionManager.appleMailControlOutcome,
                accessibilityIdentifier: "ace.apple-mail.open.outcome"
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .fill(DS.Colors.warning.opacity(0.09))
        )
    }

    private func appleMessagesRecipientSelectionSection(
        _ selection: AppleMessagesRecipientSelectionState
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose Messages recipient")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Choose the exact handle. Nothing sends until the existing exact confirmation review is completed.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            ForEach(
                Array(selection.recipientHandles.enumerated()),
                id: \.offset
            ) { index, handle in
                AceTrackedButton(handle) {
                    companionManager.selectAppleMessagesRecipientFromUI(
                        handle
                    )
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityLabel("Use Messages recipient \(handle)")
                .accessibilityIdentifier(
                    "ace.apple-messages.recipient.choice.\(index)"
                )
            }

            AceTrackedButton("Cancel pending message") {
                companionManager.cancelPendingAppleMessagesFromUI()
            }
            .buttonStyle(.bordered)
            .font(.system(size: 10, weight: .semibold))
            .accessibilityIdentifier(
                "ace.apple-messages.recipient.cancel"
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .fill(DS.Colors.warning.opacity(0.09))
        )
    }

    private func connectAppleMessagesSection(
        isWaitingForConnection: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                isWaitingForConnection
                    ? "Messages is reconnecting"
                    : "Messages needs iMessage sign-in"
            )
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
            Text(
                isWaitingForConnection
                    ? "The iMessage account is enabled but not connected. Ace keeps this exact request only in memory and resumes after Messages reconnects."
                    : "Sign in through Messages. Ace keeps this exact request only in memory and resumes after local readiness is observed."
            )
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            AceTrackedButton("Open Messages") {
                companionManager.connectAppleMessagesFromUI()
            }
            .buttonStyle(.borderedProminent)
            .font(.system(size: 11, weight: .semibold))
            .accessibilityIdentifier("ace.apple-messages.sign-in.open")

            AceTrackedButton("Cancel pending message") {
                companionManager.cancelPendingAppleMessagesFromUI()
            }
            .buttonStyle(.bordered)
            .font(.system(size: 10, weight: .semibold))
            .accessibilityIdentifier("ace.apple-messages.sign-in.cancel")

            controlOutcomeStatus(
                companionManager.appleMessagesControlOutcome,
                accessibilityIdentifier: "ace.apple-messages.open.outcome"
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .fill(DS.Colors.warning.opacity(0.09))
        )
    }

    private func reviewTitle(
        _ phase: AppActionReviewState.Phase
    ) -> String {
        switch phase {
        case .reading:
            return "Reviewing exact action"
        case .ready:
            return "Ready for exact confirmation"
        case .notArmed:
            return "Nothing is armed"
        }
    }

    private func reviewIconName(
        _ phase: AppActionReviewState.Phase
    ) -> String {
        switch phase {
        case .reading:
            return "speaker.wave.2"
        case .ready:
            return "checkmark.shield"
        case .notArmed:
            return "xmark.shield"
        }
    }

    private func reviewColor(
        _ phase: AppActionReviewState.Phase
    ) -> Color {
        switch phase {
        case .reading:
            return DS.Colors.warning
        case .ready:
            return DS.Colors.success
        case .notArmed:
            return Color(red: 0.92, green: 0.38, blue: 0.38)
        }
    }

    private func reviewIsReady(
        _ phase: AppActionReviewState.Phase,
        at date: Date = Date()
    ) -> Bool {
        if case .ready(let expiresAt) = phase {
            return expiresAt > date
        }
        return false
    }

    private func reviewIsNotArmed(
        _ phase: AppActionReviewState.Phase
    ) -> Bool {
        if case .notArmed = phase {
            return true
        }
        return false
    }

    @ViewBuilder
    private func reviewInstruction(
        _ phase: AppActionReviewState.Phase
    ) -> some View {
        switch phase {
        case .reading:
            Text("Listen through the final word. Talking now cancels this plan.")
        case .ready(let expiresAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining =
                    expiresAt.timeIntervalSince(context.date)
                if remaining < 0 {
                    Text(
                        "Expired. Ask again; confirmation will do nothing."
                    )
                } else {
                    let seconds = max(
                        0,
                        Int(remaining.rounded(.up))
                    )
                    Text(
                        seconds > 0
                            ? "Say only “confirm” within \(seconds) seconds."
                            : "Say only “confirm” now."
                    )
                }
            }
        case .notArmed(let reason):
            Text(reason)
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                BlackLabelGemCursor(bright: DS.Colors.agentGoldBright,
                    mid: DS.Colors.agentGold, deep: DS.Colors.agentGoldDeep, size: 23)
                    .frame(width: 25, height: 28)

                Text("Ace")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Menu {
                Picker("Appearance", selection: $appearancePreference) {
                    ForEach(AceAppearancePreference.allCases, id: \.rawValue) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                }
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Appearance: System, Light, or Dark")
            .accessibilityLabel("Appearance")
            .accessibilityIdentifier("ace.appearance")

            AceTrackedButton(action: {
                MenuBarPanelManager.shared?.hidePanelForUserClose()
                NotificationCenter.default.post(
                    name: .blacklabelDismissPanel,
                    object: nil
                )
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(DS.Colors.textPrimary.opacity(0.08))
                    )
            }
            .buttonStyle(AceMotionButtonStyle())
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding
            && companionManager.allPermissionsGranted {
            // Read the chord from the shortcut itself — this line said
            // "Control+Option" for weeks after the hotkey became cmd+shift
            // (founder ruling 2026-07-22), teaching every new owner the wrong
            // keys. A hardcoded chord in copy is a defect waiting to happen.
            Text("Hold \(BuddyPushToTalkShortcut.pushToTalkDisplayText) or ctrl + shift alone to talk. Adding another key cancels the voice hold.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Ace will not hide a failed grant. Every missing permission remains red below until macOS proves it works.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.panelPermissionsReady && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.panelPermissionsReady {
            Text("Setup is not finished. Hit Start to continue.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("This is Ace.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text(
                    AceBrainRoute.current == .customerOwned
                        ? "A private assistant with Codex and Claude included inside Ace. Sign in with your own account; no developer tools are required."
                        : "A private assistant using the founder-only hosted Ace brain. No developer tools are required on this Mac."
                )
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Ace captures a screen only for a request that needs it. Your selected brain processes the request; local actions still pass through Ace's native review and confirmation.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.panelPermissionsReady {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.textPrimary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    AceTrackedButton(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(AceMotionButtonStyle())
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                AceTrackedButton(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text(companionManager.isStartingFromPanel ? "Starting…" : "Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(AceMotionButtonStyle())
                .pointerCursor()
                .disabled(companionManager.isStartingFromPanel)
                .accessibilityIdentifier("ace.setup.start")
                finishSetupStatusNotice
                if companionManager.isStartingFromPanel {
                    AceTrackedButton(action: {
                        companionManager.cancelStartActivation()
                    }) {
                        Text("Cancel")
                    }
                    .buttonStyle(AceMotionButtonStyle())
                    .pointerCursor()
                    .accessibilityIdentifier("ace.setup.cancel-start")
                }
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            speechRecognitionPermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

            localMailAccessPermissionRow

            appAutomationPermissionRow

            if !companionManager.allPermissionsGranted {
                repairAllAccessButton
                    .padding(.top, 8)
            }

        }
        .onReceive(microphoneRepairCoordinator.$state) {
            refreshPermissionsAfterTerminal($0)
        }
        .onReceive(speechRepairCoordinator.$state) {
            refreshPermissionsAfterTerminal($0)
        }
        .onReceive(screenContentRepairCoordinator.$state) {
            refreshPermissionsAfterTerminal($0)
        }
        .onReceive(appAutomationRepairCoordinator.$state) {
            refreshPermissionsAfterTerminal($0)
        }
        .onAppear { localMailAccess.checkAgain() }
    }

    private func refreshPermissionsAfterTerminal(
        _ state: PermissionRepairState
    ) {
        guard state != .idle, !state.isRunning else { return }
        companionManager.refreshAllPermissions()
    }

    private var speechRecognitionPermissionRow: some View {
        permissionProofRow(
            label: "Speech Recognition",
            iconName: "waveform",
            isGranted: companionManager.isOnDeviceDictationReady,
            status: companionManager.isOnDeviceDictationReady
                ? "Granted"
                : companionManager.appleSpeechRecognitionReadiness.unavailableExplanation ?? "Needs approval",
            actionTitle: companionManager.hasSpeechRecognitionPermission ? "Open Dictation" : "Grant",
            accessibilityIdentifier: SetupControlID.panelSpeechRecognition,
            repairState: speechRepairCoordinator.state
        ) {
            let authorization = SFSpeechRecognizer.authorizationStatus()
            speechRepairCoordinator.start {
                if authorization == .restricted {
                    return .failed(
                        PermissionRepairFailure(
                            code: "speech_recognition.restricted",
                            message: "macOS reports Speech Recognition is restricted by device policy."
                        )
                    )
                }
                // ASK before sending anyone to Settings. An app that has never
                // requested Speech Recognition is NOT LISTED in that settings
                // pane, so on a clean Mac — where the status is always
                // .notDetermined — "Repair" sent the buyer to a list Ace does
                // not appear in and could never be granted from. There was no
                // .notDetermined branch at all: every non-restricted status
                // fell through to the settings hand-off.
                if authorization == .notDetermined {
                    let readiness = await AppleSpeechTranscriptionProvider
                        .requestAuthorizationIfNeeded()
                    if case .ready = readiness {
                        return .succeeded(
                            .verifiedOperation("speech_recognition_authorized")
                        )
                    }
                    // Consent was answered but dictation still is not ready
                    // (denied, or the on-device model is still resolving), so
                    // the settings hand-off below is now meaningful: Ace has
                    // asked, so it is listed and can be toggled.
                }
                return await WindowPositionManager
                    .openSettingsAndWaitForReadback(
                        authorization == .authorized
                            ? .dictation : .speechRecognition,
                        permission: .speechRecognition,
                        readback: {
                            companionManager.isOnDeviceDictationReady
                        }
                    )
            }
        }
    }

    private var appAutomationPermissionRow: some View {
        let warmup = companionManager.permissionWarmup
        let heading = (label: "App Automation", detail: "Optional per app")
        return VStack(alignment: .leading, spacing: 2) {
            Text(heading.label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.top, 5)
            Text(heading.detail)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            ForEach(PermissionAutomationTarget.allCases, id: \.self) {
                target in
                let presentation = PermissionWarmupProofPolicy.presentation(
                    for: warmup.automationStatus(for: target)
                )
                permissionProofRow(
                    label: target.ownerFacingName,
                    iconName: "gearshape.2",
                    isGranted: presentation.isGranted,
                    status: presentation.status,
                    actionTitle: presentation.actionTitle,
                    accessibilityIdentifier:
                        SetupControlID.panelAppAutomation + "." + target.rawValue,
                    repairState: .idle,
                    showsGrantedAction: true,
                    actionIsRunning: warmup.automationStatus(for: target) == .checking
                ) {
                    companionManager.requestAutomationTargetFromUI(target)
                }
                if let failure = warmup.automationFailures[target] {
                    Text(failure.message)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            SetupControlID.panelAppAutomation + "." + target.rawValue + ".detail"
                        )
                }
            }
        }
    }

    private var localMailAccessPermissionRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        localMailAccess.hasAccess
                            ? DS.Colors.textTertiary : DS.Colors.warning
                    )
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Local Mail Access")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(
                        localMailAccess.hasAccess
                            ? "Ready · optional"
                            : "Not ready · optional"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(
                        localMailAccess.hasAccess
                            ? DS.Colors.success : DS.Colors.warning
                    )
                    .accessibilityIdentifier(
                        SetupControlID.panelLocalMailAccess + ".status"
                    )
                    .accessibilityValue(
                        localMailAccess.hasAccess
                            ? "ready" : "not-ready;optional"
                    )
                }

                Spacer(minLength: 6)
            }

            Text(
                localMailAccess.hasAccess
                    ? "Ace can use the local Apple Mail index for reliable inbox reads."
                    : "Add accounts in Apple Mail. Full Disk Access is required for reliable inbox reads."
            )
            .font(.system(size: 10))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                compactLocalMailAccessButton(
                    title: "Open Apple Mail",
                    identifier:
                        SetupControlID.panelLocalMailOpenAppleMail
                ) {
                    localMailAccess.openAppleMail()
                }

                if !localMailAccess.hasAccess {
                    compactLocalMailAccessButton(
                        title: "Full Disk Access",
                        identifier:
                            SetupControlID.panelLocalMailAccess
                                + ".open-settings"
                    ) {
                        localMailAccess.openFullDiskAccessSettings()
                    }
                }

                compactLocalMailAccessButton(
                    title: "Check again",
                    identifier:
                        SetupControlID.panelLocalMailAccess + ".check-again"
                ) {
                    localMailAccess.checkAgain()
                }
            }

            if localMailAccess.didOpenFullDiskAccessSettings
                && !localMailAccess.hasAccess {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Turn on Ace, then return and Check again.")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            SetupControlID.panelLocalMailAccess + ".guidance"
                        )
                    Spacer(minLength: 4)
                    compactLocalMailAccessButton(
                        title: "Restart Ace",
                        identifier:
                            SetupControlID.panelLocalMailAccess + ".restart"
                    ) {
                        localMailAccess.restartAceAfterOwnerRequest()
                    }
                }
            }

            if let restartFailureMessage =
                localMailAccess.restartFailureMessage {
                Text(restartFailureMessage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.warningText)
                    .accessibilityIdentifier(
                        SetupControlID.panelLocalMailAccess + ".restart-state"
                    )
            }
        }
        .padding(.vertical, 6)
    }

    private func compactLocalMailAccessButton(
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        AceTrackedButton(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(DS.Colors.accent))
        }
        .buttonStyle(AceMotionButtonStyle())
        .pointerCursor()
        .accessibilityIdentifier(identifier)
    }

    private var repairAllAccessButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            AceTrackedButton(action: {
                repairAllCoordinator.start {
                return await SetupWalkthrough.shared.performExplicitRepair(
                    companionManager: companionManager,
                    successProof: .verifiedOperation(
                        "all_access_readback"
                    ),
                    isSatisfied: {
                        companionManager.allPermissionsGranted
                    },
                    incompleteFailure: PermissionRepairFailure(
                        code: "permissions.repair_incomplete",
                        message: "The guided repair ended with one or more permissions still unverified."
                    )
                )
                }
            }) {
                HStack(spacing: 7) {
                Image(systemName: "wrench.and.screwdriver.fill")
                Text("Repair all access")
                }
                .font(.system(size: 12, weight: .bold))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(
                    cornerRadius: DS.CornerRadius.medium,
                    style: .continuous
                )
                .fill(DS.Colors.accent)
            )
            }
            .buttonStyle(AceMotionButtonStyle())
            .pointerCursor()
            .disabled(repairAllCoordinator.state.isRunning)
            .accessibilityIdentifier(SetupControlID.panelRepairAll + ".action")
            .accessibilityValue(repairAllCoordinator.state.accessibilityValue)
            .help("Runs every missing permission in order and stops on the exact failed grant.")
            if let status = repairAllCoordinator.state.visibleStatus {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(repairAllCoordinator.state.proof == nil ? DS.Colors.warning : DS.Colors.success)
                    .accessibilityIdentifier(SetupControlID.panelRepairAll + ".state")
                    .accessibilityValue(repairAllCoordinator.state.accessibilityValue)
            }
        }
    }

    private func permissionProofRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        status: String,
        actionTitle: String,
        accessibilityIdentifier: String,
        repairState: PermissionRepairState,
        showsGrantedAction: Bool = false,
        actionIsRunning: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        isGranted
                            ? DS.Colors.textTertiary
                            : DS.Colors.warning
                    )
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(status)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(
                            isGranted
                                ? DS.Colors.success
                                : DS.Colors.warning
                        )
                    if let repairStatus = repairState.visibleStatus {
                        Text(repairStatus)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(repairState.proof == nil ? DS.Colors.warning : DS.Colors.success)
                            .accessibilityIdentifier(accessibilityIdentifier + ".state")
                            .accessibilityValue(repairState.accessibilityValue)
                    }
                }
            }

            Spacer()

            if isGranted {
                Circle()
                    .fill(DS.Colors.success)
                    .frame(width: 6, height: 6)
            }
            if !isGranted || showsGrantedAction {
                AceTrackedButton(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(AceMotionButtonStyle())
                .pointerCursor()
                .disabled(repairState.isRunning || actionIsRunning)
                .accessibilityIdentifier(accessibilityIdentifier + ".action")
                .accessibilityValue(repairState.accessibilityValue)
            }
        }
        .padding(.vertical, 6)
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    if let visibleRepairStatus =
                            accessibilityRepairCoordinator.state.visibleStatus {
                        Text(visibleRepairStatus)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(
                                accessibilityRepairCoordinator.state.proof == nil
                                    ? DS.Colors.warning
                                    : DS.Colors.success
                            )
                            .accessibilityIdentifier(
                                SetupControlID.panelAccessibility + ".state"
                            )
                            .accessibilityValue(
                                accessibilityRepairCoordinator.state
                                    .accessibilityValue
                            )
                    }
                    if let findStatus = findAppCoordinator.state.visibleStatus {
                        Text(findStatus)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.warning)
                            .accessibilityIdentifier(
                                SetupControlID.panelAccessibilityFindApp + ".state"
                            )
                            .accessibilityValue(findAppCoordinator.state.accessibilityValue)
                    }
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    AceTrackedButton(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager
                            .beginAccessibilityPermissionRepair()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(AceMotionButtonStyle())
                    .pointerCursor()
                    .disabled(
                        accessibilityRepairCoordinator.state.isRunning
                    )
                    .accessibilityIdentifier(
                        SetupControlID.panelAccessibility + ".action"
                    )
                    .accessibilityValue(
                        accessibilityRepairCoordinator.state
                            .accessibilityValue
                    )

                    AceTrackedButton(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        findAppCoordinator.start {
                            let finderResult = await WindowPositionManager
                                .revealAppInFinderForRepair()
                            _ = await WindowPositionManager
                                .openAndObserveSystemSettingsPane(.accessibility)
                            return finderResult
                        }
                    }) {
                        Text("Show in Finder")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(AceMotionButtonStyle())
                    .pointerCursor()
                    .disabled(findAppCoordinator.state.isRunning)
                    .accessibilityIdentifier(
                        SetupControlID.panelAccessibilityFindApp + ".action"
                    )
                    .accessibilityValue(findAppCoordinator.state.accessibilityValue)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Captures only for setup or a request that needs it"
                         : "Grant access, then quit and reopen Ace if macOS asks")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                    if let visibleRepairStatus =
                            screenRecordingRepairCoordinator.state.visibleStatus {
                        Text(visibleRepairStatus)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(
                                screenRecordingRepairCoordinator.state.proof == nil
                                    ? DS.Colors.warning
                                    : DS.Colors.success
                            )
                            .accessibilityIdentifier(
                                SetupControlID.panelScreenRecording + ".state"
                            )
                            .accessibilityValue(
                                screenRecordingRepairCoordinator.state
                                    .accessibilityValue
                            )
                    }
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                AceTrackedButton(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager
                        .beginScreenRecordingPermissionRepair()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(AceMotionButtonStyle())
                .pointerCursor()
                .disabled(
                    screenRecordingRepairCoordinator.state.isRunning
                )
                .accessibilityIdentifier(
                    SetupControlID.panelScreenRecording + ".action"
                )
                .accessibilityValue(
                    screenRecordingRepairCoordinator.state
                        .accessibilityValue
                )
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                        .frame(width: 16)

                    Text("Screen Content")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                if isGranted {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(DS.Colors.success)
                            .frame(width: 6, height: 6)
                        Text("Granted")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.success)
                    }
                } else {
                    AceTrackedButton(action: {
                        beginPanelScreenContentRepair()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(AceMotionButtonStyle())
                    .pointerCursor()
                    .disabled(screenContentRepairCoordinator.state.isRunning)
                    .accessibilityIdentifier(
                        SetupControlID.panelScreenContent + ".action"
                    )
                    .accessibilityValue(
                        screenContentRepairCoordinator.state.accessibilityValue
                    )
                }
            }

            controlOutcomeStatus(
                companionManager.screenContentControlOutcome,
                accessibilityIdentifier: "ace.screen-content.outcome"
            )
            if let status = screenContentRepairCoordinator.state.visibleStatus {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(screenContentRepairCoordinator.state.proof == nil ? DS.Colors.warning : DS.Colors.success)
                    .accessibilityIdentifier(SetupControlID.panelScreenContent + ".state")
                    .accessibilityValue(screenContentRepairCoordinator.state.accessibilityValue)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func controlOutcomeStatus(
        _ outcome: AceControlActionOutcome?,
        accessibilityIdentifier: String
    ) -> some View {
        if let outcome {
            let presentation = controlOutcomePresentation(outcome)
            HStack(alignment: .top, spacing: 6) {
                if presentation.isProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: presentation.iconName)
                        .foregroundColor(presentation.color)
                }

                Text(outcome.visibleMessage)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(presentation.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private func controlOutcomePresentation(
        _ outcome: AceControlActionOutcome
    ) -> (iconName: String, color: Color, isProgress: Bool) {
        switch outcome {
        case .started:
            return ("clock", DS.Colors.textSecondary, true)
        case .succeeded:
            return ("checkmark.circle.fill", DS.Colors.success, false)
        case .failed:
            return (
                "exclamationmark.triangle.fill",
                DS.Colors.destructiveText,
                false
            )
        }
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Microphone")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    if let status = microphoneRepairCoordinator.state.visibleStatus {
                        Text(status)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(microphoneRepairCoordinator.state.proof == nil ? DS.Colors.warning : DS.Colors.success)
                            .accessibilityIdentifier(SetupControlID.panelMicrophone + ".state")
                            .accessibilityValue(microphoneRepairCoordinator.state.accessibilityValue)
                    }
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                AceTrackedButton(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        microphoneRepairCoordinator.startPromptResolution(
                            permission: .microphone,
                            requestPrompt: {
                                return commitVisibleEffect {
                                    guard UserDefaultsPermissionPromptAttemptStore()
                                            .markAttempted(.microphone) else {
                                        return false
                                    }
                                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                                        LifecycleLog.append(
                                            "PERMISSION microphone prompt completed granted=\(granted)"
                                        )
                                    }
                                    return true
                                }
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
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(AceMotionButtonStyle())
                .pointerCursor()
                .disabled(microphoneRepairCoordinator.state.isRunning)
                .accessibilityIdentifier(SetupControlID.panelMicrophone + ".action")
                .accessibilityValue(microphoneRepairCoordinator.state.accessibilityValue)
            }
        }
        .padding(.vertical, 6)
    }

    private func beginPanelScreenContentRepair() {
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

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                AceTrackedButton(action: {
                    if let url = URL(string: settingsURL) {
                        _ = commitVisibleEffect {
                            return NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(AceMotionButtonStyle())
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Show BlackLabel Cursor Toggle

    private var showBlackLabelCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Assistant")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            AceTrackedToggle("", isOn: Binding(
                get: { companionManager.isBlackLabelCursorEnabled },
                set: { companionManager.setBlackLabelCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Show Assistant")
            .accessibilityIdentifier("ace.cursor.visible")
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var buyerWorkReceiptsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AceTrackedButton {
                withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) {
                    buyerWorkReceiptsExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("WORK RECEIPTS")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.agentGold)
                    Spacer()
                    Text("\(companionManager.buyerWorkReceipts.count) • Durable")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                    Image(
                        systemName: buyerWorkReceiptsExpanded
                            ? "chevron.up" : "chevron.down"
                    )
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(AceMotionButtonStyle())
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityIdentifier("ace.work-receipts.toggle")

            if buyerWorkReceiptsExpanded {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(companionManager.buyerWorkReceipts) { receipt in
                        buyerWorkReceiptCard(receipt)
                    }
                }
            } else if let latest =
                        companionManager.buyerWorkReceipts.first {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(latest.boundedTaskDescription)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(latest.phase.rawValue.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(
                            latest.phase == .failed
                                || latest.phase == .blocked
                                ? DS.Colors.destructiveText
                                : DS.Colors.agentGold
                        )
                }
                .accessibilityIdentifier("ace.work-receipts.latest-summary")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .fill(DS.Colors.surface2)
        )
    }

    private func buyerWorkReceiptCard(
        _ receipt: AceBuyerWorkReceipt
    ) -> some View {
        receiptClock(receipt) { date in
            let elapsed = receipt.elapsedSeconds(at: date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    receiptGlyph(receipt)
                    Text(receipt.boundedTaskDescription)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(receipt.phase.rawValue.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(
                            receipt.phase == .failed
                                || receipt.phase == .blocked
                                ? DS.Colors.destructiveText
                                : DS.Colors.agentGold
                        )
                }

                Text("Work ID  \(receipt.durableWorkID)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textSelection(.enabled)

                Text(
                    "Owner  \(receipt.owningLane.buyerLabel)  •  "
                        + "Phase  \(receipt.phase.rawValue)  •  "
                        + "Elapsed  \(elapsed)s"
                )
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

                Label(
                    receipt.mostRecentRealProgress,
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                if let terminal = receipt.terminalResult,
                   terminal != receipt.mostRecentRealProgress {
                    Text("Terminal: \(terminal)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let recovery = receipt.recoveryAction {
                    Text("Recovery: \(recovery)")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)

                    let retryRefusal = companionManager.buyerWorkReceiptRetryRefusal(receipt.id)
                    if let retryRefusal {
                        Text(retryRefusal)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    AceTrackedButton("Retry") {
                        companionManager.retryBuyerWorkReceipt(receipt.id)
                    }
                    .disabled(retryRefusal != nil)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier(
                        "ace.work-receipt.retry." + receipt.durableWorkID
                    )
                }
            }
            .padding(10)
            .textSelection(.enabled)
            .background(
                AceGlassSurface(cornerRadius: 12, accent: receiptAccent(receipt))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        DS.Colors.agentGold.opacity(0.22),
                        lineWidth: 0.7
                    )
                    .allowsHitTesting(false)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: receipt.phase)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
                "ace.work-receipt." + receipt.durableWorkID
            )
        }
    }

    @ViewBuilder
    private func receiptClock<Content: View>(_ receipt: AceBuyerWorkReceipt,
        @ViewBuilder content: @escaping (Date) -> Content) -> some View {
        if receipt.isTerminal { content(receipt.updatedAt) }
        else {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in content(timeline.date) }
        }
    }

    private func receiptAccent(_ receipt: AceBuyerWorkReceipt) -> Color {
        switch receipt.phase {
        case .failed, .blocked: return DS.Colors.agentAmberBright
        case .cancelled: return DS.Colors.agentSilver
        default: return DS.Colors.agentGold
        }
    }

    private func receiptGlyph(_ receipt: AceBuyerWorkReceipt) -> some View {
        let symbol: String
        let activity: AceMotionActivity
        switch receipt.phase {
        case .accepted: symbol = "sparkle"; activity = .working
        case .clarifying: symbol = "questionmark"; activity = .waiting
        case .processing, .executing: symbol = "sparkle"; activity = .working
        case .completed: symbol = "checkmark"; activity = .idle
        case .cancelled: symbol = "stop.fill"; activity = .idle
        case .blocked, .failed: symbol = "exclamationmark"; activity = .failed
        }
        return ZStack {
            Circle().fill(receiptAccent(receipt).opacity(0.12))
            AceActivityHalo(activity: activity, color: receiptAccent(receipt),
                intensity: .resolve(motionPreference), reduceMotion: reduceMotion)
                .scaleEffect(0.48)
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                .foregroundColor(receiptAccent(receipt))
        }
        .frame(width: 29, height: 29)
        .accessibilityHidden(true)
    }

    private struct CapabilityRecipe: Identifiable {
        let id: String
        let title: String
        let vocabulary: String
        let recipe: String
    }

    private var capabilityRecipes: [CapabilityRecipe] {
        [
            .init(id: "partner", title: "Partner", vocabulary: "Conversation",
                  recipe: "Turn on Partner, then speak naturally or paste text, HTTPS links, and documents into Message Partner. Voice and typed requests receive the same work receipt."),
            .init(id: "red", title: "Background work", vocabulary: "Red lane",
                  recipe: "Ask Ace to complete the task. Ace chooses background execution directly when action is needed; you never need to say use Red. Follow the durable Work Receipt until terminal."),
            .init(id: "stealth", title: "Stealth", vocabulary: "Privacy wall",
                  recipe: "Say exactly go stealth. Questions about Stealth only explain it. While sealed, use the exact exit-only recovery shown by Ace."),
            .init(id: "trading", title: "Trading", vocabulary: "Trading context",
                  recipe: "Open a readable chart, enable Trading, and ask about the visible symbol and timeframe. Ace refuses prices or chart claims without a current capture-bound chart read."),
            .init(id: "screen", title: "Screen context", vocabulary: "Selected visible context",
                  recipe: "Enable screen context for the current Partner session. Ace shows whether it is on; visual claims require a fresh capture."),
            .init(id: "quiz", title: "Universal test taker", vocabulary: "One visible question",
                  recipe: "Show one complete single-answer question, then use the Private Mode shortcut shown in the panel. Ace binds the exact visible answer control before clicking. Select-all, partial, duplicated, changed, or unbindable questions end with no click and an exact recovery."),
            .init(id: "homework", title: "Homework help", vocabulary: "Explain from current evidence",
                  recipe: "Ask naturally about the readable problem on screen or paste its text in Partner. Ace explains the work from the current problem and asks for missing evidence instead of inventing it."),
            .init(id: "notes", title: "Class and meeting notes", vocabulary: "Capture, review, then save",
                  recipe: "Say take notes or start Meeting Notes. Ace names unavailable audio sources, keeps capture running while other work continues, and marks any sleep or audio gap before presenting a review."),
            .init(id: "study", title: "Study materials", vocabulary: "Notes, bullets, and flashcards",
                  recipe: "Finish Meeting Notes to review the summary, key bullet points, detailed notes, action items, risks, questions, and deduplicated Q/A flashcards. Nothing is saved until you confirm."),
            .init(id: "syllabus", title: "Syllabus to Calendar", vocabulary: "Guided workflow",
                  recipe: "Attach a PDF or image, or explicitly select the visible syllabus. Extract, edit the preview, choose the exact calendar, review changes, then Create & Verify."),
            .init(id: "class-links", title: "Class links and morning brief", vocabulary: "Exact HTTPS sources",
                  recipe: "Paste three exact HTTPS links in Partner and ask for a daily briefing time. Ace shows the persisted sources and schedule, names login or fetch failures, and never labels a partial briefing complete."),
            .init(id: "permissions", title: "Permissions and audio recovery", vocabulary: "Screen, microphone, speech, and accessibility",
                  recipe: "Open the Ace panel to check permission and audio repair cards when capture, clicking, listening, or notes cannot start. Buyer Recovery shows running, installed and public app versions. The original Work Receipt remains available."),
            .init(id: "standing", title: "Standing tasks", vocabulary: "Scheduled work",
                  recipe: "Give Ace a bounded recurring schedule. The panel shows next run, last run, pause, edit, run now, and delete. A sleeping or closed Mac performs one catch-up after wake."),
            .init(id: "sleep", title: "Sleep and wake", vocabulary: "Local execution",
                  recipe: "A closed or sleeping Mac performs no local work. Ace checkpoints pending work and performs at most one timestamped bounded catch-up after wake or relaunch."),
            .init(id: "provider", title: "Provider selection", vocabulary: "Default brain",
                  recipe: "Connect and verify a provider, then Select it as the Default brain. Connected, Verified, Idle or Processing, and Last used are shown separately from actual invocation receipts."),
            .init(id: "updates", title: "Updates", vocabulary: "Installed vs public",
                  recipe: "Use the in-app update surface to compare /Applications/Ace.app with the matching public Full or Slim release. Every Mac checks at launch, hourly, after wake, and when Ace returns to the foreground."),
            .init(id: "account", title: "Account recovery", vocabulary: "Buyer recovery",
                  recipe: "Use Account and Purchase from the Ace panel for licence or download access, and Ace Support for help. Keep your original purchase receipt available."),
            .init(id: "support", title: "Ace Support", vocabulary: "Buyer help",
                  recipe: "Open Ace Support from Buyer Recovery. Ace routes to the authenticated support page and shows hello@ace-bl.tech as the fallback identity."),
        ]
    }

    private var filteredCapabilityRecipes: [CapabilityRecipe] {
        let query = capabilityGuideQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !query.isEmpty else { return capabilityRecipes }
        return capabilityRecipes.filter {
            ($0.title + " " + $0.vocabulary + " " + $0.recipe)
                .lowercased().contains(query)
        }
    }

    private var capabilityGuideSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AceTrackedButton {
                withAnimation(.easeInOut(duration: 0.18)) {
                    capabilityGuideIsExpanded.toggle()
                }
            } label: {
                HStack {
                    Label("What can Ace do?", systemImage: "questionmark.circle.fill")
                    Spacer()
                    Image(systemName: capabilityGuideIsExpanded
                        ? "chevron.up" : "chevron.down")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(AceMotionButtonStyle())
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityIdentifier("ace.capability-guide.toggle")

            if capabilityGuideIsExpanded {
                TextField("Search practical recipes", text: $capabilityGuideQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .accessibilityIdentifier("ace.capability-guide.search")

                ForEach(filteredCapabilityRecipes) { recipe in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recipe.title)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(DS.Colors.agentGold)
                        Text(recipe.vocabulary)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text(recipe.recipe)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(DS.Colors.textPrimary.opacity(0.045))
                    )
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .fill(DS.Colors.surface1.opacity(0.78))
        )
        .accessibilityIdentifier("ace.capability-guide")
    }

    private var buyerRecoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Buyer Recovery", systemImage: "lifepreserver.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                if buyerRecovery.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(buyerRecovery.runningIdentityLine)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ace.recovery.running-identity")

            if let difference = buyerRecovery.runtimeDifferenceLine {
                Text(difference)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ace.recovery.runtime-difference")
            }

            Text(buyerRecovery.installedIdentityLine)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ace.recovery.installed-identity")

            Text(buyerRecovery.publicReleaseLine)
                .font(.system(size: 10))
                .foregroundColor(
                    buyerRecovery.publicCheckFailed
                        ? DS.Colors.destructiveText
                        : DS.Colors.textTertiary
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ace.recovery.public-identity")

            if buyerRecovery.duplicateCount > 0 {
                Text(
                    "Detected \(buyerRecovery.duplicateCount) additional Ace "
                        + "installation\(buyerRecovery.duplicateCount == 1 ? "" : "s"). "
                        + "/Applications/Ace.app is authoritative."
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.destructiveText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ace.recovery.duplicate-summary")
            }

            ForEach(buyerRecovery.installations.filter { !$0.isAuthoritative }) { installation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        installation.isAuthoritative
                            ? "Authoritative"
                            : installation.isMountedInstallerCopy
                                ? "Mounted installer copy"
                                : "Duplicate copy"
                    )
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(
                        installation.isAuthoritative
                            ? DS.Colors.agentGold
                            : DS.Colors.destructiveText
                    )
                    Text(installation.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                    Text(
                        "Version \(installation.version) • Build \(installation.build)"
                    )
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: 7) {
                AceTrackedButton("Refresh") {
                    buyerRecovery.refresh()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("ace.recovery.refresh")

                AceTrackedButton("Account") {
                    _ = license.openAccountPage()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("ace.recovery.account")

                AceTrackedButton("Update & Restart") {
                    _ = AceUpdateCheck.shared
                        .openDownloadPageFromOwnerRequest()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("ace.recovery.update")
            }

            AceTrackedButton("Ace Support") {
                _ = license.contactSupport()
            }
            .buttonStyle(AceMotionButtonStyle())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(DS.Colors.textSecondary)
            .accessibilityIdentifier("ace.recovery.support")

            if let status = license.purchaseRecoveryStatus {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(license.purchaseRecoveryStatusIsFailure
                        ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ace.recovery.purchase-status")
            }
        }
        .textSelection(.enabled)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .fill(DS.Colors.surface1.opacity(0.78))
        )
        .onAppear {
            buyerRecovery.refresh()
        }
        .accessibilityIdentifier("ace.buyer-recovery")
    }

    private var providerAccountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Provider accounts")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Text("Private to Ace")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Text(
                "Check your saved account, or sign in through your browser to choose an account."
            )
            .font(.system(size: 10))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(BrainCLI.customerChoices) { cli in
                providerAccountRow(cli)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func providerAccountRow(_ cli: BrainCLI) -> some View {
        _ = providerReceiptRevision
        let coordinator = providerConnectionCoordinator(for: cli)
        let controlIdentifier = providerControlIdentifier(for: cli)
        let status = brainConnection.status(for: cli)
        let canSelect = status.isVerifiedConnected
            && brainConnection.canSelectConnectedProvider(cli)
        let isSelected = brainConnection.selectedBrain == cli

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: cli.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(
                        status.isVerifiedConnected
                            ? DS.Colors.success : DS.Colors.textSecondary
                    )
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(cli == .codex ? "ChatGPT" : (cli == .qwen ? "Qwen3 Abliterated" : cli.displayName))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(providerStatusLine(for: cli))
                        .font(.system(size: 9))
                        .foregroundColor(
                            status.state == .failed
                                ? DS.Colors.destructiveText
                                : DS.Colors.textTertiary
                        )
                        .lineLimit(2)
                        .accessibilityIdentifier(controlIdentifier + ".state")
                        .accessibilityValue(coordinator.state.accessibilityValue)

                    Text(providerActivityLine(for: cli))
                        .font(.system(size: 9))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .accessibilityIdentifier(
                            controlIdentifier + ".activity"
                        )

                }

                Spacer(minLength: 4)

                AceTrackedButton(providerActionTitle(for: cli)) {
                    if canSelect && !isSelected {
                        _ = brainConnection.selectBrain(cli)
                        return
                    }
                    guard !canSelect else { return }
                    coordinator.start {
                        let wasAdmitted =
                            brainConnection.connectProvider(cli)
                        guard wasAdmitted else {
                            return .failed(
                                PermissionRepairFailure(
                                    code: "provider.connect_not_admitted",
                                    message:
                                        "The provider account action was not admitted."
                                )
                            )
                        }
                        return await brainConnection
                            .waitForProviderRepairTerminal(cli)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    isSelected && canSelect
                        || coordinator.state.isRunning
                        || brainConnection.hasActiveProviderFlight
                )
                .accessibilityIdentifier(controlIdentifier + ".action")
                .accessibilityValue(coordinator.state.accessibilityValue)
            }
            if brainConnection.providerOnboardingState(for: cli) == .launchingOAuth
                || brainConnection.providerOnboardingState(for: cli) == .waitingForAuthentication {
                AceTrackedButton("Cancel") {
                    brainConnection.cancelProviderConnection(cli)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(controlIdentifier + ".cancel")
            } else if cli.requiresBrowserAuthentication {
                AceTrackedButton("Sign in through browser") {
                    coordinator.start {
                        guard brainConnection.reconnectProvider(cli) else {
                            return .failed(PermissionRepairFailure(
                                code: "provider.browser_signin_not_admitted",
                                message: "Finish or cancel the current connection attempt, then try again."
                            ))
                        }
                        return await brainConnection.waitForProviderRepairTerminal(cli)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(coordinator.state.isRunning || brainConnection.hasActiveProviderFlight)
                .accessibilityIdentifier(controlIdentifier + ".browser-signin")
                Text("Replaces Ace’s saved sign-in with the account you choose.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
            }

        }
        .padding(.vertical, 2)
    }

    private func providerConnectionCoordinator(
        for cli: BrainCLI
    ) -> PermissionRepairCoordinator {
        switch cli {
        case .codex: return codexConnectionCoordinator
        case .claude: return claudeConnectionCoordinator
        case .qwen: return qwenConnectionCoordinator
        }
    }

    private func providerControlIdentifier(for cli: BrainCLI) -> String {
        switch cli {
        case .codex: return SetupControlID.panelProviderConnectCodex
        case .claude: return SetupControlID.panelProviderConnectClaude
        case .qwen: return SetupControlID.panelProviderConnectQwen
        }
    }

    private func providerActionTitle(for cli: BrainCLI) -> String {
        if brainConnection.status(for: cli).isVerifiedConnected,
           brainConnection.canSelectConnectedProvider(cli) {
            if brainConnection.selectedBrain == cli {
                return "Selected"
            }
            return "Select"
        }
        if cli == .qwen { return "Verify & Use" }
        return brainConnection.canVerifyExistingAuthentication(for: cli)
            ? "Check account" : "Connect"
    }

    private func providerStatusLine(for cli: BrainCLI) -> String {
        let status = brainConnection.status(for: cli)
        if status.isVerifiedConnected {
            return "Verified this session • Default brain: "
                + (brainConnection.selectedBrain == cli ? "Yes" : "No")
        }
        switch brainConnection.providerOnboardingState(for: cli) {
        case .launchingOAuth, .waitingForAuthentication:
            if brainConnection.verifyingExistingAuthenticationFor == cli {
                return "Checking your saved account… No browser sign-in needed."
            }
            return cli.requiresBrowserAuthentication
                ? "Complete sign-in in your browser, then return here."
                : "Loading the local model and checking a real answer…"
        case .connected where status.isVerifiedConnected:
            return "Connected and verified this session."
        case .retryConnection:
            if status.state == .signedOut {
                return "\(cli.displayName) is signed out. Connect to sign in."
            }
            return status.isUsageLimited ? status.detail
                : "Couldn’t connect. Check your account again or sign in through your browser."
        case .readyToConnect, .connected:
            if status.state == .notInstalled {
                return cli == .qwen
                    ? "Embedded Qwen runtime or model missing. Reinstall Ace."
                    : "Bundled runtime missing. Reinstall Ace."
            }
            if brainConnection.canVerifyExistingAuthentication(for: cli) {
                return "Your sign-in is saved. Check your account to connect."
            }
            if status.state == .failed || status.state == .signedOut {
                return status.detail.isEmpty
                    ? "Not connected to Ace." : status.detail
            }
            return BrainConnectionProof.informationalReceipt(for: cli) != nil
                ? "Previously verified on this Mac."
                : "Not connected to Ace."
        }
    }

    private func providerActivityLine(for cli: BrainCLI) -> String {
        guard let receipt = AceProviderInvocationReceiptStore.receipt(
            for: cli
        ) else {
            return "Provider history on this Mac: No recorded activity"
        }
        let activity: String
        switch receipt.phase {
        case .processing: activity = "Request started"
        case .completed: activity = "Request completed"
        case .failed: activity = "Request failed"
        case .cancelled: activity = "Request cancelled"
        }
        return "Provider history on this Mac: \(activity) • "
            + receipt.updatedAt.formatted(
                date: .abbreviated,
                time: .shortened
            )
    }

    private var modelPickerRow: some View {
        HStack {
            Text("Brain")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            if brainConnection.selectedBrain == .codex {
                Text("Codex")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.textPrimary.opacity(0.1))
                    )
            } else if brainConnection.selectedBrain == .claude {
                HStack(spacing: 0) {
                    modelOptionButton(
                        label: "Sonnet",
                        modelID: "claude-sonnet-4-6"
                    )
                    modelOptionButton(
                        label: "Opus",
                        modelID: "claude-opus-4-6"
                    )
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DS.Colors.textPrimary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            } else {
                Text("Qwen3 Abliterated · 30B-A3B")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.textPrimary.opacity(0.1))
                    )
            }
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return AceTrackedButton(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? DS.Colors.textPrimary.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(AceMotionButtonStyle())
        .pointerCursor()
    }

    // MARK: - Feedback

    /// The founder feedback channel. Mail handlers can report success while
    /// showing no composer, so this control makes a deterministic owner-visible
    /// handoff: copy the exact founder address and say what happened.
    private var messageFounderButton: some View {
        AceTrackedButton(action: {
            // mthburnsbarber, not mtuburnsbarber — the typo'd address bounced,
            // so every buyer who used this button reached nobody.
            let founderEmailAddress = "mthburnsbarber@gmail.com"
            guard commitVisibleEffect({
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                return pasteboard.setString(
                    founderEmailAddress,
                    forType: .string
                )
            }) == true else {
                founderMessageStatus =
                    "Ace couldn't copy the founder email. Use mthburnsbarber@gmail.com."
                return
            }
            founderMessageStatus =
                "Founder email address copied. Paste it into any mail app."
        }) {
            HStack(spacing: 6) {
                Image(systemName: "envelope")
                    .font(.system(size: 11, weight: .medium))
                Text("Copy founder email")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(DS.Colors.textTertiary)
        }
        .buttonStyle(AceMotionButtonStyle())
        .pointerCursor()
    }

    // MARK: - Footer

    /// Reopens the full setup window. Hosted access or a developer CLI can need
    /// repair after onboarding, so the connection proof stays reachable.
    private var openSetupButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            AceTrackedButton(action: {
                guard !StealthEntryLatch.shared.isRaised,
                  !StealthVisibilityGate.shared.isActive else {
                    return
                }
                setupWindowCoordinator.start {
                    AceIntroWindowController.shared.present(
                        companionManager: companionManager
                    ) {
                        companionManager.refreshAllPermissions()
                        companionManager.triggerOnboarding()
                    }
                    return AceIntroWindowController.shared.isVisible
                        ? .succeeded(.verifiedOperation("setup_window_visible"))
                        : .failed(
                            PermissionRepairFailure(
                                code: "setup.window_not_visible",
                                message: "Ace did not observe its Setup window after the footer action."
                            )
                        )
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                    Text("Setup")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(AceMotionButtonStyle())
            .pointerCursor()
            .disabled(setupWindowCoordinator.state.isRunning)
            .accessibilityIdentifier(
                SetupControlID.panelSetupWindow + ".action"
            )
            .accessibilityValue(setupWindowCoordinator.state.accessibilityValue)
            if let status = setupWindowCoordinator.state.visibleStatus {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(setupWindowCoordinator.state.proof == nil ? DS.Colors.warning : DS.Colors.success)
                    .accessibilityIdentifier(
                        SetupControlID.panelSetupWindow + ".state"
                    )
                    .accessibilityValue(setupWindowCoordinator.state.accessibilityValue)
            }
        }
    }

    /// Repairs missing proof from an otherwise completed setup. This remains a
    /// separate control so the permanent Setup button always opens onboarding.
    private var repairSetupButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            AceTrackedButton(action: {
                guard !StealthEntryLatch.shared.isRaised,
                      !StealthVisibilityGate.shared.isActive else {
                    return
                }
                setupRepairCoordinator.start {
                    return await SetupWalkthrough.shared.performExplicitRepair(
                        companionManager: companionManager,
                        successProof: .verifiedOperation(
                            "current_setup_proofs"
                        ),
                        isSatisfied: {
                            companionManager.currentSetupProofsReady
                        },
                        incompleteFailure: PermissionRepairFailure(
                            code: "setup.repair_incomplete",
                            message: "Repair Ace ended with one or more setup proofs still unresolved."
                        )
                    )
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11, weight: .medium))
                    Text("Repair Ace")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(AceMotionButtonStyle())
            .pointerCursor()
            .disabled(setupRepairCoordinator.state.isRunning)
            .accessibilityIdentifier(
                SetupControlID.panelSetupRepair + ".action"
            )
            .accessibilityValue(setupRepairCoordinator.state.accessibilityValue)
            if let status = setupRepairCoordinator.state.visibleStatus {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(setupRepairCoordinator.state.proof == nil ? DS.Colors.warning : DS.Colors.success)
                    .accessibilityIdentifier(
                        SetupControlID.panelSetupRepair + ".state"
                    )
                    .accessibilityValue(setupRepairCoordinator.state.accessibilityValue)
            }
        }
    }

    private var panelPermissionRepairReceiptIsVisible: Bool {
        [
            microphoneRepairCoordinator.state,
            speechRepairCoordinator.state,
            screenRecordingRepairCoordinator.state,
            accessibilityRepairCoordinator.state,
            screenContentRepairCoordinator.state,
            appAutomationRepairCoordinator.state,
            repairAllCoordinator.state,
            findAppCoordinator.state,
        ].contains { $0 != .idle }
    }

    /// The text form of Ace's last completed answer ("the wordage"). Voice
    /// stays primary, but a failed, interrupted, or over-length speech run
    /// must never turn a finished brain or Red Agent result into silence —
    /// this is the reader for the channel `showVisibleResponse` writes. The
    /// gem overlay is deliberately forbidden from rendering a response card
    /// (script/test_partner_visual_contract.sh); the panel is the channel.
    @ViewBuilder
    private var visibleResponseSection: some View {
        if !companionManager.visibleResponseText.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(companionManager.visibleResponseText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(
                    cornerRadius: DS.CornerRadius.small,
                    style: .continuous
                )
                .fill(DS.Colors.surface2)
            )
        }
    }

    /// The one place setup can speak in writing.
    ///
    /// Nora says the rehearsal instruction once. If the owner misses it there
    /// is no second channel for setup — the gem overlay is deliberately
    /// forbidden from showing a floating response card
    /// (script/test_partner_visual_contract.sh). Rendering it here keeps it
    /// visible until the state changes, and inside the panel the owner already
    /// opens to press Finish Setup.
    @ViewBuilder
    private var finishSetupStatusNotice: some View {
        if !companionManager.finishSetupOwnerFacingStatus.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(companionManager.finishSetupOwnerFacingStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(
                    cornerRadius: DS.CornerRadius.small,
                    style: .continuous
                )
                .fill(DS.Colors.surface2)
            )
        }
    }

    private var footerSection: some View {
        VStack(spacing: 10) {
            if companionManager.hasCompletedOnboarding
                || !companionManager.panelPermissionsReady {
                finishSetupStatusNotice
            }
            HStack {
                messageFounderButton
                Spacer()
                openSetupButton
            }

            if AssistantAvailabilityPolicy.shouldOfferSetupRepair(
                hasCompletedOnboarding:
                    companionManager.hasCompletedOnboarding,
                currentSetupProofsReady:
                    companionManager.currentSetupProofsReady
            ) {
                HStack {
                    Spacer()
                    repairSetupButton
                }
            }

            if let status = companionManager.stopWorkStatusMessage {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ace.footer.stop-status")
            }

            if let founderMessageStatus {
                Text(founderMessageStatus)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ace.footer.founder-status")
            }

            HStack {
                AceTrackedButton(action: {
                    if companionManager.meetingNotetaker.isTakingNotes
                        || companionManager.meetingNotetaker.isStartingUp {
                        confirmStopAndNotes = true
                    } else {
                        companionManager.stopAllOwnerWork()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Stop Work")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(AceMotionButtonStyle())
                .pointerCursor()
                .accessibilityIdentifier("ace.footer.stop-work")
                .accessibilityCustomContent(LocalizedStringKey("Stop receipt"), companionManager.stopWorkReceipt)
                .confirmationDialog("Stop work and end the current notes capture?", isPresented: $confirmStopAndNotes) {
                    AceTrackedButton("Stop work and end notes", role: .destructive) {
                        companionManager.stopAllOwnerWork()
                    }
                    AceTrackedButton("Keep working", role: .cancel) {}
                }

                Spacer()

                AceTrackedButton(action: {
                    requestQuitFromPanel()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .medium))
                        Text("Quit Ace")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(AceMotionButtonStyle())
                .pointerCursor()
                .accessibilityIdentifier("ace.footer.quit")
            }

            if companionManager.hasCompletedOnboarding
                || companionManager.hasViewedFirstRunTour {
                AceTrackedButton(action: {
                        guard !StealthEntryLatch.shared.isRaised,
                              !StealthVisibilityGate.shared.isActive else {
                            return
                        }
                        // OverlayWindowManager total-orders each native
                        // orderFrontRegardless commit. Do not nest that gate
                        // inside this panel's nonrecursive global latch.
                        companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Replay Tour")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(AceMotionButtonStyle())
                .pointerCursor()
            }
        }
    }

    /// Every direct AppKit/Workspace commit in this panel is linearized with
    /// the event-tap Private Mode latch. The panel can already be queued on MainActor when
    /// the entry arrives, so checking only the later visibility wall is insufficient.
    @discardableResult
    private func commitVisibleEffect(
        _ effect: () -> Bool
    ) -> Bool {
        StealthVisibleEffectAdmission.commit(
            visibilityIsBlocked: {
                StealthVisibilityGate.shared.isActive
            },
            performUnlessRaised: { body in
                StealthEntryLatch.shared.performUnlessRaised(body)
            },
            effect: effect
        )
    }

    // MARK: - Universal Test Taker + Privacy Dashboard

    private var privateModeReadinessMessage: String? {
        _ = providerReceiptRevision
        return CompanionManager.privateModeReadinessMessage(
            isLicensed: license.admits(.privateModeEntry),
            shortcutIsActive: companionManager.privateModeShortcutMonitorIsActive,
            exitVoiceIsReady: companionManager.hasMicrophonePermission
                && companionManager.isOnDeviceDictationReady,
            screenIsReady: companionManager.hasScreenRecordingPermission
                && companionManager.hasScreenContentPermission,
            providerIsReady: brainConnection.status(for: brainConnection.selectedBrain).isVerifiedConnected
                && brainConnection.canSelectConnectedProvider(brainConnection.selectedBrain)
        )
    }

    private var privateModeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("UNIVERSAL TEST TAKER")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)

                Spacer()

                Text(privateModeReadinessMessage == nil ? "Ready" : "Setup needed")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(privateModeReadinessMessage == nil
                        ? DS.Colors.success : DS.Colors.textSecondary)
                    .accessibilityIdentifier("ace.private-mode.readiness")
            }

            Text("Say “go stealth” to hide Ace. With Caps Lock on, Shift + Z answers the current multiple-choice question.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            AceTrackedButton(action: {
                companionManager.enterPrivateModeFromPanel()
            }) {
                VStack(spacing: 3) {
                    Text("Go Stealth")
                        .font(.system(size: 13, weight: .semibold))
                    Text(
                        companionManager.privateModeShortcutMonitorIsActive
                            ? "Caps Lock on, then Shift + Z: enter & answer"
                            : "Retry keyboard shortcut"
                    )
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.accent)
                )
            }
            .buttonStyle(AceMotionButtonStyle())
            .pointerCursor()
            .accessibilityIdentifier("ace.private-mode.enter.action")
            .background(
                AcePanelVisualTargetAnchor(
                    target: .stealthEntry,
                    companionManager: companionManager
                )
            )

            if let message = privateModeReadinessMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ace.private-mode.setup-needed")
            }

            if !companionManager.privateModeActivityStatus.isEmpty {
                Text(companionManager.privateModeActivityStatus)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ace.private-mode.activity")
            }

            Text("Stealth hides Ace’s windows and menu icon. Ace remains visible to macOS process and security tools.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("To exit: hold Command + Shift (or Control + Shift) and say “\(AceLanguage.current.exitPhrase)”.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyDashboardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AceTrackedButton(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    privacyDashboardExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 12, weight: .medium))
                    Text("Privacy Dashboard")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: privacyDashboardExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textSecondary)
            }
            .buttonStyle(AceMotionButtonStyle())
            .pointerCursor()
            .accessibilityIdentifier("ace.privacy-dashboard.toggle")

            if privacyDashboardExpanded {
                VStack(spacing: 6) {
                    privacyStatusRow(
                        "ScreenCaptureKit",
                        status: companionManager.hasScreenRecordingPermission ? "Granted • local capture" : "Not granted",
                        lastUsed: companionManager.lastPrivateModeCaptureAt
                    )
                    privacyStatusRow(
                        "Screen selection",
                        status: companionManager.hasScreenContentPermission ? "Granted" : "Not granted"
                    )
                    privacyStatusRow(
                        "Accessibility",
                        status: companionManager.hasAccessibilityPermission ? "Granted" : "Not granted"
                    )
                    privacyStatusRow(
                        "Keyboard event tap",
                        status: companionManager.privateModeShortcutMonitorIsActive ? "Active" : "Inactive"
                    )
                    privacyStatusRow(
                        "Audio input",
                        status: companionManager.hasMicrophonePermission ? "Granted • local speech" : "Not granted"
                    )
                    privacyStatusRow(
                        "Network + AI",
                        status: "Encrypted • remote on request",
                        lastUsed: companionManager.lastPrivateModeRemoteProcessingAt
                    )
                    privacyStatusRow(
                        "Synthetic click",
                        status: "Local • one answer hotkey",
                        lastUsed: companionManager.lastPrivateModeSyntheticClickAt
                    )
                    // Storage rows must state exactly what the code guarantees
                    // (§5.1): normal conversations ARE kept — AceTranscript
                    // appends every exchange to transcript.md in Application
                    // Support — while Private Mode reads are never written
                    // (AceTranscript.stealthBlocksWriting fails closed on the
                    // stealth markers). One unscoped "Store nothing" row here
                    // read as an app-wide claim and was false app-wide.
                    privacyStatusRow(
                        "Conversations",
                        status: "Local plaintext • transcript.md"
                    )
                    privacyStatusRow(
                        "Explicit memory",
                        status: "Local plaintext • memory.md; clear keeps a recoverable backup"
                    )
                    privacyStatusRow(
                        "Gold + Partner context",
                        status: "Encrypted locally • separate from transcript and explicit memory"
                    )
                    privacyStatusRow(
                        "Private Mode reads",
                        status: "Never stored"
                    )
                }

                Text(companionManager.privateModeActivityStatus)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.textPrimary.opacity(0.05))
        )
    }

    private func privacyStatusRow(
        _ label: String,
        status: String,
        lastUsed: Date? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer()
            Text(lastUsed.map { "\(status) • \($0.formatted(date: .omitted, time: .shortened))" } ?? status)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        AceGlassSurface(cornerRadius: 16)
            .shadow(color: DS.Colors.agentGold.opacity(0.09), radius: 24, x: 0, y: 0)
    }

    private var motionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MOTION")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundColor(DS.Colors.agentGoldBright)
                Spacer()
                Text(reduceMotion ? "Reduced motion" : "Living gold")
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            HStack(spacing: 3) {
                ForEach(AceMotionIntensity.allCases) { intensity in
                    AceTrackedButton {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                            motionPreference = intensity.rawValue
                        }
                    } label: {
                        Text(intensity.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(motionPreference == intensity.rawValue
                                ? DS.Colors.agentGoldBright : DS.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background {
                                if motionPreference == intensity.rawValue {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(DS.Colors.agentGold.opacity(0.16))
                                        .matchedGeometryEffect(id: "motion-selection", in: motionSelection)
                                }
                            }
                    }
                    .buttonStyle(AceMotionButtonStyle())
                    .accessibilityLabel("Motion: " + intensity.title)
                    .disabled(reduceMotion)
                    .accessibilityValue(motionPreference == intensity.rawValue ? "Selected" : "Not selected")
                    .accessibilityIdentifier("ace.motion." + intensity.rawValue)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.22)))
            AceTrackedToggle(isOn: $landingSound) {
                Text("Landing sounds").font(.system(size: 10)).foregroundColor(DS.Colors.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(DS.Colors.agentGold)
            .accessibilityIdentifier("ace.motion.landing-sound")
            .disabled(reduceMotion)
            if reduceMotion {
                Text("Motion effects and landing sounds are paused by macOS Reduce Motion.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .padding(11)
        .background(AceGlassSurface(cornerRadius: 12))
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    /// "Trial — N days left" while the activation server's trial window is
    /// still ahead of now. Shown only for a live lease with a future
    /// trialEndsAt: once that date passes, the server's next daily verdict
    /// (converted or refused) is the truth, so no locally invented
    /// "trial ended" state is ever displayed.
    private var trialStatusLine: String? {
        guard license.allowsUse,
              let trialEndsAt = license.trialEndsAt else {
            return nil
        }
        let secondsRemaining = trialEndsAt.timeIntervalSinceNow
        guard secondsRemaining > 0 else { return nil }
        let daysRemaining = Int((secondsRemaining / 86_400).rounded(.up))
        return daysRemaining == 1
            ? "Trial — 1 day left"
            : "Trial — \(daysRemaining) days left"
    }

    /// The exact condition the footer uses to expose the Repair Ace control.
    /// The header must consult the same policy in the same render pass — a
    /// "Ready" header above a visible Repair offer is a false readiness claim.
    private var setupRepairIsOffered: Bool {
        AssistantAvailabilityPolicy.shouldOfferSetupRepair(
            hasCompletedOnboarding: companionManager.hasCompletedOnboarding,
            currentSetupProofsReady: companionManager.currentSetupProofsReady
        )
    }

    private var statusText: String {
        if !license.allowsUse {
            return "Locked"
        }
        if !companionManager.hasCompletedOnboarding || !companionManager.panelPermissionsReady {
            return "Setup"
        }
        // A live voice state below still reports honest current activity, but
        // idle with a failed setup proof must read as repairable, never Ready.
        if setupRepairIsOffered && companionManager.voiceState == .idle {
            return "Needs repair"
        }
        switch companionManager.voiceState {
        case .idle:
            return companionManager.isOverlayVisible ? "Active" : "Ready"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}

private struct MorningLinkBriefPanel: View {
    @ObservedObject var runtime: MorningLinkBriefRuntime
    @State private var source1 = ""
    @State private var source2 = ""
    @State private var source3 = ""
    @State private var runTime = Calendar.current.date(
        bySettingHour: 8,
        minute: 0,
        second: 0,
        of: Date()
    ) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MORNING BRIEFING")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.agentGold)
                Spacer()
                if runtime.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running")
                        .font(.system(size: 9, weight: .semibold))
                }
            }

            Text("Exactly three HTTPS sources. Ace names every failed source and marks any partial briefing incomplete.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            sourceField("HTTPS source 1", text: $source1)
            sourceField("HTTPS source 2", text: $source2)
            sourceField("HTTPS source 3", text: $source3)

            DatePicker(
                "Daily time",
                selection: $runTime,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.field)
            .font(.system(size: 10, weight: .medium))

            if let schedule = runtime.schedule {
                Text("Next run: \(schedule.nextRunAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Last run: \(schedule.lastRunAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                if let result = schedule.lastResult {
                    Text(result)
                        .font(.system(size: 9))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(4)
                }
                if schedule.deferredSpeech != nil {
                    Text("Speech retained until Meeting Notes releases audio.")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.agentGold)
                }
            }

            if let error = runtime.lastControlError {
                Text(error)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.destructiveText)
            }

            HStack(spacing: 6) {
                AceTrackedButton(runtime.schedule == nil ? "Save" : "Save changes") {
                    let components = Calendar.current.dateComponents(
                        [.hour, .minute],
                        from: runTime
                    )
                    _ = runtime.configure(
                        sourceStrings: [source1, source2, source3],
                        hour: components.hour ?? 8,
                        minute: components.minute ?? 0
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("ace.morning-brief.save-or-edit")

                if let schedule = runtime.schedule {
                    AceTrackedButton(schedule.isPaused ? "Resume" : "Pause") {
                        runtime.setPaused(!schedule.isPaused)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("ace.morning-brief.pause-or-resume")

                    AceTrackedButton("Run now") {
                        runtime.runNow()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(runtime.isRunning)
                    .accessibilityIdentifier("ace.morning-brief.run-now")

                    AceTrackedButton(role: .destructive) {
                        runtime.delete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Delete morning briefing")
                    .accessibilityIdentifier("ace.morning-brief.delete")
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large)
                .fill(DS.Colors.surface1.opacity(0.78))
        )
        .onAppear(perform: loadSchedule)
        .onChange(of: runtime.schedule?.id) { _ in loadSchedule() }
        .accessibilityIdentifier("ace.morning-link-brief.panel")
    }

    private func sourceField(
        _ title: String,
        text: Binding<String>
    ) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10))
    }

    private func loadSchedule() {
        guard let schedule = runtime.schedule else { return }
        source1 = schedule.sourceURLs.indices.contains(0)
            ? schedule.sourceURLs[0] : ""
        source2 = schedule.sourceURLs.indices.contains(1)
            ? schedule.sourceURLs[1] : ""
        source3 = schedule.sourceURLs.indices.contains(2)
            ? schedule.sourceURLs[2] : ""
        runTime = Calendar.current.date(
            bySettingHour: schedule.hour,
            minute: schedule.minute,
            second: 0,
            of: Date()
        ) ?? runTime
    }
}

private struct MeetingNotesPanelSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var meetingNotetaker: MeetingNotetaker

    private var isActive: Bool {
        meetingNotetaker.isTakingNotes || meetingNotetaker.isStartingUp
    }

    private var hasPendingRetry: Bool {
        meetingNotetaker.hasPendingMeetingNotesRetry
    }

    private var hasPendingReview: Bool {
        meetingNotetaker.hasPendingGeneratedNotesReview
    }

    private var isGenerating: Bool {
        meetingNotetaker.isWindingDown
            || meetingNotetaker.isRetryingMeetingNotes
    }

    private var captureFailure: MeetingNotesResult? {
        guard meetingNotetaker.result?.state == .failed else { return nil }
        return meetingNotetaker.result
    }

    private var statusLabel: String {
        if meetingNotetaker.isStartingUp { return "Starting" }
        if isGenerating { return "Generating" }
        if captureFailure != nil {
            return isActive ? "Capture interrupted" : "Needs attention"
        }
        if isActive { return "Recording" }
        if hasPendingRetry { return "Retry ready" }
        if hasPendingReview { return "Review pending" }
        if meetingNotetaker.result?.state == .noTranscript {
            return "No transcript"
        }
        return "Ready"
    }

    private var primaryActionLabel: String {
        if isGenerating { return "Preparing Notes & Flashcards" }
        if meetingNotetaker.isStartingUp { return "Cancel Startup" }
        if isActive { return "Finish & Review" }
        if hasPendingRetry { return "Retry Notes & Flashcards" }
        if hasPendingReview { return "Reopen Notes Review" }
        return "Start Meeting Notes"
    }

    private var primaryActionIcon: String {
        if isActive { return "stop.fill" }
        if hasPendingReview { return "doc.text.magnifyingglass" }
        return "waveform"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MEETING NOTES")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)

                Spacer()

                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(
                        captureFailure != nil
                            ? DS.Colors.warning
                            : isActive
                            ? .blue
                            : (isGenerating || hasPendingRetry || hasPendingReview
                                ? DS.Colors.warning
                                : DS.Colors.success)
                    )
            }

            Text(
                "Capture the meeting, then review organized notes before anything is saved."
            )
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if let captureFailure, !meetingNotetaker.isStartingUp,
               !isGenerating {
                Text(captureFailure.detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ace.meeting-notes.failure")
            }

            HStack(spacing: 6) {
                outcomeChip(icon: "doc.text", label: "Detailed notes")
                outcomeChip(icon: "list.bullet", label: "Bullet points")
                outcomeChip(icon: "rectangle.stack", label: "Q/A flashcards")
            }

            if isGenerating {
                Text(
                    "Preparing detailed notes and flashcards from your captured "
                        + "meeting. Nothing is saved until you review it."
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if hasPendingRetry {
                Text(
                    "The populated capture is held only in memory. Connect or "
                        + "choose Codex or Claude, then retry this same session. "
                        + "A new capture "
                        + "cannot replace this one."
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)

                if let expiresAt =
                    meetingNotetaker.pendingMeetingNotesRetryExpiresAt {
                    Text(
                        "In-memory retry expires at "
                            + expiresAt.formatted(
                                date: .omitted,
                                time: .shortened
                            )
                            + "."
                    )
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                }
            } else if hasPendingReview {
                Text(
                    "The generated Detailed notes and Q/A Flashcards are still "
                        + "waiting for review. Reopen the same frozen review; "
                        + "nothing is saved until you approve it."
                )
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
            }

            AceTrackedButton(action: {
                if isActive {
                    companionManager.stopMeetingNotesFromPanel()
                } else if hasPendingRetry {
                    companionManager.retryMeetingNotesFromPanel()
                } else if hasPendingReview {
                    companionManager.reopenMeetingNotesReviewFromPanel()
                } else {
                    companionManager.startMeetingNotesFromPanel()
                }
            }) {
                HStack(spacing: 7) {
                    Image(systemName: primaryActionIcon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(primaryActionLabel)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(
                        cornerRadius: DS.CornerRadius.large,
                        style: .continuous
                    )
                    .fill(
                        isActive
                            ? Color.blue
                            : (hasPendingRetry || hasPendingReview
                                ? DS.Colors.warning
                                : DS.Colors.accent)
                    )
                )
            }
            .buttonStyle(AceMotionButtonStyle())
            .pointerCursor()
            .disabled(isGenerating)
            .accessibilityIdentifier("ace.meeting-notes.toggle.action")
            .accessibilityValue(statusLabel)

            if hasPendingRetry {
                AceTrackedButton(action: {
                    companionManager
                        .discardPendingMeetingNotesRetryFromPanel()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Discard Pending Capture")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(
                            cornerRadius: DS.CornerRadius.medium,
                            style: .continuous
                        )
                        .stroke(
                            DS.Colors.textTertiary.opacity(0.45),
                            lineWidth: 0.8
                        )
                    )
                }
                .buttonStyle(AceMotionButtonStyle())
                .pointerCursor()
                .accessibilityIdentifier(
                    "ace.meeting-notes.retry.discard.action"
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .fill(Color.blue.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: DS.CornerRadius.medium,
                style: .continuous
            )
            .stroke(Color.blue.opacity(0.35), lineWidth: 0.8)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ace.meeting-notes.section")
    }

    private func outcomeChip(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundColor(DS.Colors.textSecondary)
        .frame(maxWidth: .infinity, minHeight: 42)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.72))
        )
        .accessibilityElement(children: .combine)
    }
}


@MainActor
private struct AceStandingTasksPanel: View {
    @ObservedObject var runtime: StandingTaskRuntime
    @State private var expanded = false
    @State private var editingID: String?
    @State private var editSentence = ""
    @State private var status: StandingTaskRuntime.ControlResult?

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if runtime.records.isEmpty {
                    Text("No standing tasks. Ask Ace for a reasoning task with an explicit schedule, such as: Explain one writing technique every day at 9 am.")
                        .font(.system(size: 11))
                }
                ForEach(runtime.records, id: \.id) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.actionInstruction).font(.system(size: 12, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text("\(record.spokenScheduleDescription) · \(record.status)")
                        Text("Next run: \(record.status == "scheduled" ? displayDate(record.nextFireAtISO) : "Not scheduled while " + record.status)")
                        Text("Last run: \(record.lastFiredAtISO.map(displayDate) ?? "Not run yet")")
                        if let result = record.lastResultSummary {
                            Text(result).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        HStack {
                            if record.status == "paused" {
                                taskButton("Resume", id: record.id, action: .resume)
                            } else if ["scheduled", "running"].contains(record.status) {
                                taskButton("Pause", id: record.id, action: .pause)
                            }
                            if record.status == "scheduled" {
                                taskButton("Run now", id: record.id, action: .runNow)
                            }
                            if ["scheduled", "paused"].contains(record.status) {
                                AceTrackedButton("Edit") {
                                    editingID = record.id
                                    editSentence = record.actionInstruction + " " + record.spokenScheduleDescription.replacingOccurrences(of: "once, ", with: "")
                                }
                                .buttonStyle(AceMotionButtonStyle()).pointerCursor()
                                .accessibilityIdentifier("ace.standing.edit." + record.id)
                            }
                            taskButton("Delete", id: record.id, action: .delete)
                                .disabled(record.status == "running")
                        }
                        if editingID == record.id {
                            TextField("Task and schedule", text: $editSentence, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("ace.standing.edit-text")
                            HStack {
                                AceTrackedButton("Save") {
                                    let outcome = runtime.manage(id: record.id, action: .edit(editSentence))
                                    status = outcome
                                    if outcome.succeeded { editingID = nil }
                                }
                                .accessibilityIdentifier("ace.standing.save")
                                AceTrackedButton("Cancel") { editingID = nil }
                                    .accessibilityIdentifier("ace.standing.cancel-edit")
                            }.buttonStyle(AceMotionButtonStyle()).pointerCursor()
                        }
                    }
                    .font(.system(size: 10))
                    .padding(10)
                    .background(DS.Colors.surface2)
                }
                if let status {
                    Text(status.message)
                        .font(.system(size: 11))
                        .foregroundColor(status.succeeded ? DS.Colors.textSecondary : DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ace.standing.control-status")
                }
            }.padding(.top, 8)
        } label: {
            Text("Standing tasks (\(runtime.records.count))")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(DS.Colors.textSecondary)
        .accessibilityIdentifier("ace.standing.tasks")
    }

    private func taskButton(_ title: String, id: String, action: StandingTaskRuntime.ControlAction) -> some View {
        AceTrackedButton(title) {
            status = runtime.manage(id: id, action: action)
            if status?.succeeded == true, case .delete = action, editingID == id { editingID = nil }
        }
        .buttonStyle(AceMotionButtonStyle()).pointerCursor()
        .accessibilityIdentifier("ace.standing." + title.lowercased().replacingOccurrences(of: " ", with: "-") + "." + id)
    }

    private func displayDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return "Unavailable" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
#endif // circuit-convert
