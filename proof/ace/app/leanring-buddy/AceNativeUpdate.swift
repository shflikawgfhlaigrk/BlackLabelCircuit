#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
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
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CircuitPortKit

enum AceNativeUpdateOutcome {
    case updated
    case current
    case cancelled
    case failed(String)
}

@MainActor
final class AceNativeUpdate: ObservableObject {
    static let shared = AceNativeUpdate()
    @Published private(set) var detail = "Checking for updates…"
    @Published private(set) var fraction: Double?
    @Published private(set) var isWorking = false
    @Published private(set) var canCancel = false
    private var task: Task<Void, Never>?
    private var panel: NSPanel?
    private var boundary: InstallTransactionCommitBoundary?
    private var committed = false
    private var operation: UUID?
    private var receivingDownload = false
    private var completions: [(AceNativeUpdateOutcome) -> Void] = []

    @discardableResult
    func startFromOwnerRequest(completion: ((AceNativeUpdateOutcome) -> Void)? = nil) -> Bool {
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised,
              !AceIntroWindowController.shared.isVisible else { return false }
        if let completion { completions.append(completion) }
        if isWorking { show(); return true }
        let id = UUID()
        operation = id
        committed = false
        receivingDownload = false
        isWorking = true
        canCancel = true
        fraction = nil
        detail = "Checking for updates…"
        show()
        task = Task { @MainActor in await self.perform(id: id) }
        return true
    }

    func cancelOrClose() {
        if isWorking {
            guard canCancel, !committed else { return }
            boundary?.markStealthEntrySynchronously()
            task?.cancel()
            canCancel = false
            detail = "Cancelling update…"
        } else { panel?.orderOut(nil) }
    }

    private func show() {
        _ = SetupVisibleEffectAdmission.commit {
            if panel == nil {
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 210),
                                    styleMask: [.titled], backing: .buffered, defer: false)
                panel.title = "Update & Restart"
                panel.isReleasedWhenClosed = false
                panel.hidesOnDeactivate = false
                panel.setAccessibilityIdentifier("ace.update.progress-window")
                panel.contentView = AceHostingView(rootView: AceNativeUpdateView(updater: self))
                panel.center()
                self.panel = panel
            }
            panel?.makeKeyAndOrderFront(nil)
            return true
        }
    }

    private func checkpoint() throws {
        try Task.checkCancellation()
        guard !StealthEntryLatch.shared.isRaised else { throw CancellationError() }
    }

    private func perform(id: UUID) async {
        let transactionBoundary = InstallTransactionCommitBoundary(entryLatch: .shared)
        boundary = transactionBoundary
        let cutoff = StealthEntryLatch.shared.registerSynchronousEntryCutoff {
            transactionBoundary.markStealthEntrySynchronously()
        }
        var workspace: URL?
        var mount: URL?
        var attemptedMount = false
        var outcome: InstallLocation.InstallTerminalOutcome?
        var errorMessage: String?
        var terminal = AceNativeUpdateOutcome.cancelled
        defer {
            StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(cutoff)
            InstallReadinessCoordinator.shared.nativeUpdateHandoffIsActive = false
            boundary = nil
            task = nil
            isWorking = false
            canCancel = false
            fraction = nil
            receivingDownload = false
            if StealthEntryLatch.shared.isRaised { panel?.orderOut(nil) }
            let callbacks = completions
            completions.removeAll()
            callbacks.forEach { $0(terminal) }
            if case .updated = terminal, !StealthEntryLatch.shared.isRaised {
                NSApp.terminate(nil)
            }
        }
        do {
            try checkpoint()
            guard InstallLocation.isRunningFromAllowedStableLocation else {
                throw AceNativeUpdateError.rejected("Open Ace from Applications before updating.")
            }
            var request = URLRequest(url: URL(string: "https://ace-bl.tech/api/ace/version")!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
            request.timeoutInterval = 20
            let (data, response) = try await StealthURLSessionRequest().perform(request)
            try checkpoint()
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 64 * 1024 else {
                throw AceNativeUpdateError.rejected("Ace could not retrieve the current release. Check your connection and try again.")
            }
            let release: AceValidatedPublicRelease
            switch AceUpdateManifestPolicy.evaluate(installed: AceUpdateCheck.currentInstalledIdentity(),
                                                    manifestData: data) {
            case .current:
                detail = "No newer verified release is available for this copy of Ace."
                terminal = .current
                return
            case .update(let available): release = available
            case .installedIdentityInvalid:
                throw AceNativeUpdateError.rejected("This copy's release identity is incomplete. Reinstall from the private download in your original purchase receipt.")
            case .manifestUnavailable:
                throw AceNativeUpdateError.rejected("The release information could not be verified. Try again later.")
            }
            let licensedRequest = try AceLicense.shared.nativeUpdateRequest(for: release)
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("AceUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            workspace = root
            receivingDownload = true
            let download = AceNativeUpdateDownload(release: release,
                destination: root.appendingPathComponent("Ace.dmg")) { [weak self] received, total in
                Task { @MainActor [weak self] in
                    guard let self, self.operation == id, self.isWorking, self.receivingDownload,
                          !StealthEntryLatch.shared.isRaised else { return }
                    self.fraction = Double(received) / Double(total)
                    self.detail = "Downloading Ace \(release.version) (\(Int(self.fraction! * 100))%)…"
                }
            }
            detail = "Authorizing download with your existing licence…"
            let dmg = try await download.perform(licensedRequest)
            receivingDownload = false
            try checkpoint()
            fraction = nil
            detail = "Verifying the downloaded package…"
            try await Task.detached(priority: .userInitiated) {
                try AceNativeUpdateArtifact.verifyDownload(dmg, release: release) {
                    try transactionBoundary.checkpointBulkIO()
                }
            }.value
            try checkpoint()
            let mountURL = root.appendingPathComponent("Volume", isDirectory: true)
            try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            mount = mountURL
            attemptedMount = true
            let mounted = try await AceNativeUpdateCommand.run("/usr/bin/hdiutil",
                ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountURL.path, "-plist", dmg.path],
                directory: root)
            try checkpoint()
            guard let plist = try PropertyListSerialization.propertyList(from: mounted, format: nil) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]],
                  entities.filter({ $0["mount-point"] as? String == mountURL.path }).count == 1 else {
                throw AceNativeUpdateError.rejected("The update disk image did not mount at its private destination.")
            }
            let source = mountURL.appendingPathComponent("Ace.app", isDirectory: true)
            try await Task.detached(priority: .userInitiated) {
                try transactionBoundary.checkpointBulkIO()
                try AceNativeUpdateArtifact.verifyBundle(source, release: release)
            }.value
            try checkpoint()
            _ = try await AceNativeUpdateCommand.run("/usr/sbin/spctl",
                ["--assess", "--type", "execute", source.path], directory: root)
            try checkpoint()
            // A long download may outlive the selected release. Do not install
            // obsolete replacement bytes even if they still have a valid seal.
            let (freshData, freshResponse) = try await StealthURLSessionRequest().perform(request)
            try checkpoint()
            guard (freshResponse as? HTTPURLResponse)?.statusCode == 200,
                  freshData.count <= 64 * 1024,
                  AceUpdateManifestPolicy.validatedPublicRelease(
                    installed: AceUpdateCheck.currentInstalledIdentity(),
                    manifestData: freshData) == release else {
                throw AceNativeUpdateError.rejected("The release changed while preparing the update. Check Again to get the current version.")
            }
            // Read current runtime state, including unsaved meeting notes.
            // Poll state while leaving the owner a working Cancel control.
            while true {
                try checkpoint()
                (NSApp.delegate as? CompanionAppDelegate)?.activeCompanionManager?
                    .refreshInstallReadinessSnapshot()
                let activities = InstallReadinessCoordinator.shared.snapshot.activeActivities
                    .filter { $0 != .visiblePanel }
                if activities.isEmpty { break }
                detail = "Waiting for Ace's active work to finish. Save meeting notes and end Partner Mode to continue, or Cancel."
                try await Task.sleep(for: .milliseconds(500))
            }
            InstallReadinessCoordinator.shared.nativeUpdateHandoffIsActive = true
            detail = "Preparing and verifying the replacement. You can still cancel."
            outcome = await InstallLocation.installUpdate(from: source, release: release,
                boundary: transactionBoundary) {
                    self.committed = true
                    self.canCancel = false
                    self.detail = "Installing and verifying Ace's restart…"
                }
        } catch {
            errorMessage = (error is CancellationError || Task.isCancelled)
                ? "Update cancelled."
                : error.localizedDescription
        }

        // Detach is cleanup, including after privacy/cancellation. Never remove
        // a directory recursively while it could still contain a mounted disk.
        if let workspace {
            let mountToDetach = attemptedMount ? mount : nil
            await Task.detached {
                var mayRemove = mountToDetach == nil
                if let mountToDetach {
                    do {
                        _ = try await AceNativeUpdateCommand.run("/usr/bin/hdiutil",
                            ["detach", mountToDetach.path], directory: workspace,
                            timeout: 30, cleanupOnly: true)
                        mayRemove = true
                    } catch { /* Preserve the private mount for later recovery. */ }
                }
                if mayRemove { try? FileManager.default.removeItem(at: workspace) }
            }.value
        }
        guard !StealthEntryLatch.shared.isRaised else { return }
        switch outcome {
        case .committedAndRelaunching:
            detail = "The updated Ace is running."
            LifecycleLog.append("UPDATE exact installed runtime confirmed; outgoing runtime exiting")
            terminal = .updated
        case .failed(let reason):
            detail = reason
            terminal = .failed(reason)
        case .interruptedByPrivateMode:
            detail = "Update cancelled."
            terminal = .cancelled
        case nil:
            detail = errorMessage ?? "The update did not finish. Try again."
            terminal = Task.isCancelled ? .cancelled : .failed(detail)
        }
    }
}

private struct AceNativeUpdateView: View {
    @ObservedObject var updater: AceNativeUpdate
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update & Restart").font(.headline)
            Text(updater.detail).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ace.update.progress-detail")
            if updater.isWorking {
                if let fraction = updater.fraction { ProgressView(value: fraction) }
                else { ProgressView().controlSize(.small) }
            }
            HStack {
                Spacer()
                if !updater.isWorking {
                    AceTrackedButton("Check Again") { updater.startFromOwnerRequest() }
                        .accessibilityIdentifier("ace.update.retry")
                }
                AceTrackedButton(updater.isWorking ? "Cancel" : "Close") { updater.cancelOrClose() }
                    .disabled(updater.isWorking && !updater.canCancel)
                    .accessibilityIdentifier("ace.update.cancel-or-close")
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif // circuit-convert
