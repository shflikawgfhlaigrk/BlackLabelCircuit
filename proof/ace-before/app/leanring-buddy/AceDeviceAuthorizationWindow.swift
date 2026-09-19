#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// A real, floating setup window keeps browser approval visible and clickable
/// for Ace's LSUIElement process. It deliberately does not use `runModal()`;
/// presentation crosses the same guarded AppKit boundary as the main setup UI.
@MainActor
final class AceDeviceAuthorizationWindowController:
    NSObject,
    NSWindowDelegate
{
    static let shared = AceDeviceAuthorizationWindowController()

    private var window: NSWindow?
    private var stealthEntryCutoffIdentifier: UUID?

    private override init() {
        super.init()
        stealthEntryCutoffIdentifier =
            StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                [weak self] in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.close()
                    }
                }
            }
    }

    @discardableResult
    func present() -> Bool {
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else {
            return false
        }
        if let existingWindow = window {
            return SetupVisibleEffectAdmission.commit {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                existingWindow.makeKeyAndOrderFront(nil)
                existingWindow.orderFrontRegardless()
                return true
            }
        }

        let linkWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        linkWindow.title = "Link this Mac"
        linkWindow.titlebarAppearsTransparent = true
        linkWindow.titleVisibility = .hidden
        linkWindow.isMovableByWindowBackground = true
        linkWindow.isReleasedWhenClosed = false
        linkWindow.level = .floating
        linkWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
        ]
        linkWindow.backgroundColor = NSColor(DS.Colors.background)
        linkWindow.delegate = self
        linkWindow.contentView = AceHostingView(
            rootView: AceDeviceAuthorizationView(
                license: .shared,
                onHide: { [weak self] in self?.close() }
            )
        )
        linkWindow.center()

        let didPresent = SetupVisibleEffectAdmission.commit {
            window = linkWindow
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            linkWindow.makeKeyAndOrderFront(nil)
            linkWindow.orderFrontRegardless()
            return true
        }
        if !didPresent {
            linkWindow.delegate = nil
            linkWindow.close()
        }
        return didPresent
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct AceDeviceAuthorizationView: View {
    @ObservedObject var license: AceLicense
    let onHide: () -> Void

    /// One typed lifecycle for every primary click: Link this Mac, Open
    /// approval page, and Try again all admit through this single-flight
    /// coordinator and publish one generation-bound running/terminal receipt.
    @StateObject private var authorizationActionCoordinator =
        PermissionRepairCoordinator()

    private var state: AceDeviceAuthorizationState {
        license.deviceAuthorizationState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundColor(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Link this Mac")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Approve it with the Ace account that owns your purchase.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }

            Divider().overlay(DS.Colors.borderSubtle)

            if case let .awaitingApproval(
                userCode,
                verificationURL,
                _,
                _,
                _
            ) = state {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Browser code")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(userCode)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .textSelection(.enabled)
                    Text(verificationURL.absoluteString)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                if state.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 1)
                } else {
                    Image(
                        systemName: state == .idle ? "circle.dashed" : state.messageIsFailure
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .foregroundColor(
                        state == .idle ? DS.Colors.textSecondary : state.messageIsFailure
                            ? DS.Colors.destructiveText
                            : DS.Colors.success
                    )
                }
                Text(
                    state.ownerMessage
                        ?? "Ace will open a secure browser approval and finish automatically."
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(
                    state.messageIsFailure
                        ? DS.Colors.destructiveText
                        : DS.Colors.textSecondary
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ace.device-link.status")
            }

            Spacer(minLength: 0)

            // Never disabled: a wedged busy state must stay clickable so the
            // recovery path in presentDeviceAuthorization is reachable. The
            // coordinator's single-flight admission is what refuses duplicate
            // clicks while an admitted attempt is still running.
            AceTrackedButton(primaryTitle) {
                performPrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Colors.accent)
            .controlSize(.large)
            .accessibilityIdentifier("ace.device-link.primary.action")
            .accessibilityValue(
                authorizationActionCoordinator.state.accessibilityValue
            )

            if let visibleActionStatus =
                authorizationActionCoordinator.state.visibleStatus {
                Text(visibleActionStatus)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(
                        authorizationActionCoordinator.state.proof == nil
                            ? DS.Colors.warning
                            : DS.Colors.success
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ace.device-link.primary.state")
                    .accessibilityValue(
                        authorizationActionCoordinator.state.accessibilityValue
                    )
            }

            HStack {
                AceTrackedButton("Use a licence key instead") {
                    license.cancelDeviceAuthorization()
                    license.presentKeyEntry()
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textSecondary)
                .accessibilityIdentifier("ace.account.use-license-key")

                Spacer()

                AceTrackedButton("Hide") {
                    onHide()
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textTertiary)
                .accessibilityIdentifier("ace.device-link.hide")
            }
        }
        .padding(28)
        .frame(width: 520, height: 430)
        .background(DS.Colors.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ace.device-link.window")
    }

    private var primaryTitle: String {
        switch state {
        case .idle:
            return "Link this Mac"
        case .starting:
            return "Starting…"
        case .checkingLegacyKey:
            return "Checking…"
        case .awaitingApproval:
            return "Open approval page"
        case .linked:
            return "Done"
        case .failed:
            return "Try again"
        case .finishing:
            return "Verifying delivery…"
        }
    }

    private func performPrimaryAction() {
        switch state {
        case .idle, .failed:
            _ = authorizationActionCoordinator.start { [weak license] in
                guard let license else {
                    return .failed(
                        PermissionRepairFailure(
                            code: "device_link.owner_released",
                            message: "The licensing owner was released before this attempt ran."
                        )
                    )
                }
                license.startDeviceAuthorization()
                // The click is transport; the published licensing state is the
                // postcondition. Observe it within a bounded window so the
                // receipt reports what actually happened, never the click.
                return await PermissionRepairObservation.wait {
                    switch license.deviceAuthorizationState {
                    case .awaitingApproval:
                        return .succeeded(
                            .verifiedOperation("device_link_request_issued")
                        )
                    case .linked:
                        return .succeeded(
                            .verifiedOperation("device_link_completed")
                        )
                    case .failed(let message):
                        return .failed(
                            PermissionRepairFailure(
                                code: "device_link.start_failed",
                                message: message
                            )
                        )
                    case .idle, .starting, .checkingLegacyKey, .finishing:
                        return nil
                    }
                }
            }
        case .awaitingApproval:
            _ = authorizationActionCoordinator.start { [weak license] in
                guard let license else {
                    return .failed(
                        PermissionRepairFailure(
                            code: "device_link.owner_released",
                            message: "The licensing owner was released before this attempt ran."
                        )
                    )
                }
                // This proves the default-browser request was started. The
                // browser's acceptance and page rendering remain unverified.
                let browserAcceptedHandoff =
                    license.openDeviceAuthorizationPage()
                return browserAcceptedHandoff
                    ? .succeeded(
                        .verifiedOperation(
                            "device_link_approval_page_requested"
                        )
                    )
                    : .failed(
                        PermissionRepairFailure(
                            code: "device_link.browser_open_failed",
                            message: "macOS did not confirm that the approval page opened."
                        )
                    )
            }
        case .linked:
            onHide()
        case .starting, .checkingLegacyKey:
            // No-op while genuinely busy; restarts the flow once the busy
            // state has aged past the wedge-recovery window.
            license.presentDeviceAuthorization()
        case .finishing:
            // Delivery verification owns the flight; a click while it runs
            // must not open a second session. The wedge-recovery path in
            // presentDeviceAuthorization stays reachable.
            license.presentDeviceAuthorization()
        }
    }

    private var isAwaitingApproval: Bool {
        if case .awaitingApproval = state { return true }
        return false
    }
}
#endif // circuit-convert
