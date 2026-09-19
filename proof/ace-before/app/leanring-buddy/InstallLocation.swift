//
//  InstallLocation.swift
//  Ace
//
//  Ace has one deliberately supported installed location:
//
//      /Applications/Ace.app
//
//  First-run completion and runtime identity both embed assumptions about that
//  stable path. Downloads, Desktop, mounted disk images, per-user
//  Applications folders, renamed bundles, nested folders, App Translocation,
//  and symlinked destinations are therefore setup blockers rather than
//  best-effort configurations.
//

#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// An unstable launch returns before the companion panel exists. Its recovery
/// cards therefore need their own nonmodal host; recording an inline failure
/// alone leaves a first-time buyer with a running process and no visible app.
@MainActor
private final class InstallRecoveryWindowController {
    private let panel: NSPanel

    init(reporter: FirstRunFailureReporter) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 310),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Install Ace"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior.insert([
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
        ])
        panel.setAccessibilityIdentifier("ace.install.recovery")
        panel.contentView = AceHostingView(
            rootView: InstallRecoveryView(reporter: reporter)
                .preferredColorScheme(.dark)
        )
        panel.center()
    }

    func show() {
        guard !StealthEntryLatch.shared.isRaised else { return }
        panel.level = .floating
        NSApp.unhide(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        _ = NSRunningApplication.current.activate(options: [
            .activateAllWindows,
            .activateIgnoringOtherApps,
        ])
    }

    func yieldToFinder() {
        // Keep the instructions available without covering the app folder or
        // the Finder destination the owner needs to drag it into.
        panel.level = .normal
        panel.orderBack(nil)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
private struct InstallRecoveryView: View {
    @ObservedObject var reporter: FirstRunFailureReporter
    @State private var finderStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Ace")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 28)
            ScrollView {
                FirstRunFailureRecoveryView(reporter: reporter)
            }
            if let finderStatus {
                Text(finderStatus)
                    .font(.callout)
                    .padding(.horizontal, 28)
                    .accessibilityIdentifier("ace.install.finder-status")
            }
            HStack {
                AceTrackedButton(StableInstallCoordinator.repairActionTitle) {
                    finderStatus = InstallLocation.showInstallerInFinder()
                        ? "Install folder sent to Finder. Open your original Ace download, drag Ace into the main Applications folder, then quit this copy and open the installed app."
                        : "Finder did not open. Open the downloaded disk image in Finder and drag Ace into Applications."
                }
                .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
                .accessibilityIdentifier("ace.install.show-in-finder")
                Spacer()
                AceTrackedButton("Quit Ace") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                .accessibilityIdentifier("ace.install.quit")
            }
            .padding(.horizontal, 28)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.surface1)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
private final class InstallProgressWindowController {
    private let panel: NSPanel
    private let previousActivationPolicy: NSApplication.ActivationPolicy
    private var promotedForPresentation = false

    init() {
        previousActivationPolicy = NSApp.activationPolicy()
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Installing Ace"
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.collectionBehavior.insert([
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
        ])
        panel.standardWindowButton(.closeButton)?.isEnabled = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .regular
        progress.startAnimation(nil)
        progress.setAccessibilityIdentifier("ace.install.progress")

        let title = NSTextField(labelWithString: "Installing Ace in Applications…")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        let detail = NSTextField(
            wrappingLabelWithString:
                "Copying and verifying the signed app. Ace will reopen from Applications when it is ready."
        )
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 2

        let stack = NSStackView(views: [progress, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: content.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor,
                constant: -24
            ),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content
        panel.center()
    }

    func show() {
        if previousActivationPolicy == .accessory {
            promotedForPresentation = NSApp.setActivationPolicy(.regular)
        }
        NSApp.unhide(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        _ = NSRunningApplication.current.activate(options: [
            .activateAllWindows,
            .activateIgnoringOtherApps,
        ])
    }

    func close() {
        panel.orderOut(nil)
        if promotedForPresentation {
            _ = NSApp.setActivationPolicy(previousActivationPolicy)
            promotedForPresentation = false
        }
    }
}
#endif // circuit-convert

enum InstallBulkIOError: Error {
    case cancelledForStealth
    case copyFailed(source: String, destination: String, code: Int32)
    case unreadablePath(String, code: Int32)
}

/// Both owner-facing sinks for an install failure render
/// `error.localizedDescription`. Without this conformance a Swift enum yields
/// "The operation couldn't be completed. (leanring_buddy.InstallBulkIOError
/// error 2.)" — so a full disk, a permission denial, and a quota failure were
/// all reported to the buyer as an error number that names no cause and
/// suggests no action, with the captured `errno` discarded at the point of
/// display.
extension InstallBulkIOError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cancelledForStealth:
            return "The move stopped because Private Mode became active."
        case let .copyFailed(source, destination, code):
            return "Ace could not copy \(source) to \(destination): "
                + Self.systemReason(for: code)
        case let .unreadablePath(path, code):
            return "Ace could not read \(path): "
                + Self.systemReason(for: code)
        }
    }

    private static func systemReason(for code: Int32) -> String {
        let systemText = String(cString: strerror(code))
        switch code {
        case ENOSPC:
            return "\(systemText). Free up space on your startup disk and "
                + "try again."
        case EACCES, EPERM:
            return "\(systemText). Your account may not be allowed to change "
                + "the Applications folder — sign in as an administrator, or "
                + "drag Ace into Applications with Finder."
        case EDQUOT:
            return "\(systemText). Your disk quota is full."
        case EROFS:
            return "\(systemText). The destination is read-only."
        default:
            return systemText
        }
    }
}

nonisolated final class InstallTransactionCommitBoundary:
    @unchecked Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case committed
    }

    enum StealthDisposition: Equatable, Sendable {
        case continueTransaction
        case rollbackAndStop
        case cleanupOnly
    }

    private let lock = NSLock()
    private let entryLatch: StealthEntryLatch
    private var phaseStorage: Phase = .preparing
    private var stealthEntryWasObserved = false
    private var previousAppWasBackedUpStorage = false

    init(entryLatch: StealthEntryLatch) {
        self.entryLatch = entryLatch
        self.stealthEntryWasObserved = entryLatch.isRaised
    }

    var phase: Phase {
        lock.withLock { phaseStorage }
    }

    var previousAppWasBackedUp: Bool {
        lock.withLock { previousAppWasBackedUpStorage }
    }

    var shouldCancelBulkIO: Bool {
        lock.withLock { stealthEntryWasObserved }
            || entryLatch.isRaised
    }

    var stealthDisposition: StealthDisposition {
        let state = lock.withLock {
            (phaseStorage, stealthEntryWasObserved)
        }
        guard state.1 || entryLatch.isRaised else {
            return .continueTransaction
        }
        return state.0 == .committed
            ? .cleanupOnly
            : .rollbackAndStop
    }

    func markStealthEntrySynchronously() {
        lock.withLock {
            stealthEntryWasObserved = true
        }
    }

    func markPreviousAppBackupReady() {
        lock.withLock {
            previousAppWasBackedUpStorage = true
        }
    }

    func checkpointBulkIO() throws {
        guard !shouldCancelBulkIO else {
            throw InstallBulkIOError.cancelledForStealth
        }
    }

    /// The same latch that raises on X owns the promotion commit point. X either
    /// wins first and no destination mutation starts, or the same-directory
    /// rename/replace finishes and the transaction becomes irrevocably committed
    /// before X can publish entry.
    func commitIfAllowed(
        _ commit: () throws -> Void
    ) rethrows -> Bool {
        let result: Bool? = try entryLatch.performUnlessRaised {
            guard !lock.withLock({ stealthEntryWasObserved }) else {
                return false
            }
            try commit()
            lock.withLock {
                phaseStorage = .committed
            }
            return true
        }
        return result == true
    }
}

/// Performs every recursive or byte-scanning install operation away from
/// MainActor. The copyfile callback and proof loop consult the same sticky
/// boundary X marks in its event-tap turn.
nonisolated final class InstallBulkIOWorker: @unchecked Sendable {
    private struct Entry {
        let url: URL
        let kind: mode_t
        let permissions: mode_t
        let size: off_t
    }

    private let boundary: InstallTransactionCommitBoundary

    init(boundary: InstallTransactionCommitBoundary) {
        self.boundary = boundary
    }

    func checkpoint() throws {
        try boundary.checkpointBulkIO()
    }

    func copyItem(from sourceURL: URL, to destinationURL: URL) throws {
        try checkpoint()
        guard let state = copyfile_state_alloc() else {
            throw InstallBulkIOError.copyFailed(
                source: sourceURL.path,
                destination: destinationURL.path,
                code: ENOMEM
            )
        }
        defer {
            copyfile_state_free(state)
        }

        let callback: copyfile_callback_t = {
            _, _, _, _, _, context in
            guard let context else { return COPYFILE_QUIT }
            let boundary =
                Unmanaged<InstallTransactionCommitBoundary>
                    .fromOpaque(context)
                    .takeUnretainedValue()
            return boundary.shouldCancelBulkIO
                ? COPYFILE_QUIT
                : COPYFILE_CONTINUE
        }
        let retainedBoundary = Unmanaged.passUnretained(boundary)
        let callbackPointer = unsafeBitCast(
            callback,
            to: UnsafeRawPointer.self
        )
        guard copyfile_state_set(
                  state,
                  UInt32(COPYFILE_STATE_STATUS_CB),
                  callbackPointer
              ) == 0,
              copyfile_state_set(
                  state,
                  UInt32(COPYFILE_STATE_STATUS_CTX),
                  retainedBoundary.toOpaque()
              ) == 0 else {
            throw InstallBulkIOError.copyFailed(
                source: sourceURL.path,
                destination: destinationURL.path,
                code: errno
            )
        }

        let flags = copyfile_flags_t(
            COPYFILE_ALL
                | COPYFILE_RECURSIVE
                | COPYFILE_EXCL
                | COPYFILE_NOFOLLOW
        )
        let result: Int32 = sourceURL.withUnsafeFileSystemRepresentation {
            sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation {
                destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return copyfile(
                    sourcePath,
                    destinationPath,
                    state,
                    flags
                )
            }
        }
        if boundary.shouldCancelBulkIO {
            throw InstallBulkIOError.cancelledForStealth
        }
        guard result == 0 else {
            throw InstallBulkIOError.copyFailed(
                source: sourceURL.path,
                destination: destinationURL.path,
                code: errno
            )
        }
        try checkpoint()
    }

    func contentsEqual(
        sourceRootURL: URL,
        copiedRootURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        try checkpoint()
        let sourceEntries = try entries(
            below: sourceRootURL,
            fileManager: fileManager
        )
        let copiedEntries = try entries(
            below: copiedRootURL,
            fileManager: fileManager
        )
        guard Set(sourceEntries.keys) == Set(copiedEntries.keys) else {
            return false
        }

        for relativePath in sourceEntries.keys.sorted() {
            try checkpoint()
            guard let sourceEntry = sourceEntries[relativePath],
                  let copiedEntry = copiedEntries[relativePath],
                  sourceEntry.kind == copiedEntry.kind,
                  sourceEntry.permissions == copiedEntry.permissions
            else {
                return false
            }
            switch sourceEntry.kind {
            case mode_t(S_IFREG):
                guard sourceEntry.size == copiedEntry.size,
                      try regularFilesEqual(
                          sourceEntry.url,
                          copiedEntry.url
                      ) else {
                    return false
                }
            case mode_t(S_IFLNK):
                guard try fileManager.destinationOfSymbolicLink(
                    atPath: sourceEntry.url.path
                ) == fileManager.destinationOfSymbolicLink(
                    atPath: copiedEntry.url.path
                ) else {
                    return false
                }
            case mode_t(S_IFDIR):
                break
            default:
                return false
            }
        }
        try checkpoint()
        return true
    }

    private func entries(
        below rootURL: URL,
        fileManager: FileManager
    ) throws -> [String: Entry] {
        try checkpoint()
        let rootPrefix = rootURL.path + "/"
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw InstallBulkIOError.unreadablePath(
                rootURL.path,
                code: errno
            )
        }
        var result: [String: Entry] = [:]
        while let itemURL = enumerator.nextObject() as? URL {
            try checkpoint()
            guard itemURL.path.hasPrefix(rootPrefix) else {
                throw InstallBulkIOError.unreadablePath(
                    itemURL.path,
                    code: EINVAL
                )
            }
            let relativePath = String(
                itemURL.path.dropFirst(rootPrefix.count)
            )
            let status = try fileStatus(at: itemURL)
            result[relativePath] = Entry(
                url: itemURL,
                kind: status.st_mode & mode_t(S_IFMT),
                permissions: status.st_mode & mode_t(0o7777),
                size: status.st_size
            )
        }
        if let enumerationError {
            throw enumerationError
        }
        return result
    }

    private func fileStatus(at url: URL) throws -> stat {
        var status = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation {
            path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else {
            throw InstallBulkIOError.unreadablePath(
                url.path,
                code: errno
            )
        }
        return status
    }

    private func regularFilesEqual(
        _ sourceURL: URL,
        _ copiedURL: URL
    ) throws -> Bool {
        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        let copiedHandle = try FileHandle(forReadingFrom: copiedURL)
        defer {
            try? sourceHandle.close()
            try? copiedHandle.close()
        }

        while true {
            try checkpoint()
            let sourceBytes = try sourceHandle.read(upToCount: 1_048_576)
                ?? Data()
            let copiedBytes = try copiedHandle.read(upToCount: 1_048_576)
                ?? Data()
            guard sourceBytes == copiedBytes else { return false }
            if sourceBytes.isEmpty {
                return true
            }
        }
    }
}

nonisolated final class InstallLaunchEffectBoundary:
    @unchecked Sendable {
    typealias CutoffPrimitive = @Sendable (pid_t) -> Void

    private let lock = NSLock()
    private let entryLatch: StealthEntryLatch
    private let cutoffPrimitive: CutoffPrimitive
    private var isCutOffStorage: Bool
    private var trackedProcessIdentifiers: Set<pid_t> = []

    init(
        entryLatch: StealthEntryLatch,
        cutoffPrimitive: CutoffPrimitive? = nil
    ) {
        self.entryLatch = entryLatch
        self.cutoffPrimitive = cutoffPrimitive ?? { processIdentifier in
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        self.isCutOffStorage = entryLatch.isRaised
    }

    var isCutOff: Bool {
        entryLatch.isRaised
            || lock.withLock { isCutOffStorage }
    }

    func launchProcessIfAllowed(
        _ launch: () throws -> pid_t
    ) rethrows -> Bool {
        let didLaunch: Bool? = try entryLatch.performUnlessRaised {
            try lock.withLock {
                guard !isCutOffStorage else { return false }
                let processIdentifier = try launch()
                guard processIdentifier > 0 else { return false }
                trackedProcessIdentifiers.insert(processIdentifier)
                return true
            }
        }
        if didLaunch == nil {
            lock.withLock {
                isCutOffStorage = true
            }
        }
        return didLaunch == true
    }

    @discardableResult
    func trackProcessIdentifierIfAllowed(
        _ processIdentifier: pid_t
    ) -> Bool {
        guard processIdentifier > 0 else { return false }
        let didTrack: Bool? = entryLatch.performUnlessRaised {
            lock.withLock {
                guard !isCutOffStorage else { return false }
                trackedProcessIdentifiers.insert(processIdentifier)
                return true
            }
        }
        guard didTrack == true else {
            lock.withLock {
                isCutOffStorage = true
            }
            cutoffPrimitive(processIdentifier)
            return false
        }
        return true
    }

    func processDidExit(_ processIdentifier: pid_t) {
        _ = lock.withLock {
            trackedProcessIdentifiers.remove(processIdentifier)
        }
    }

    func cutOffSynchronously() {
        let processIdentifiers = lock.withLock {
            isCutOffStorage = true
            let snapshot = trackedProcessIdentifiers
            trackedProcessIdentifiers.removeAll()
            return snapshot
        }
        for processIdentifier in processIdentifiers {
            cutoffPrimitive(processIdentifier)
        }
    }

    func releaseWithoutCutoff() {
        lock.withLock {
            trackedProcessIdentifiers.removeAll()
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
enum InstallLocation {

    private static let releaseCodeSigningRequirement =
        "identifier \"com.blacklabel.assistant\" and anchor apple generic "
        + "and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
        + "and certificate leaf[subject.OU] = \"745ZPGFRA5\""

    enum LocationKind: Equatable {
        case allowedStableApplicationsLocation
        case appTranslocation
        case mountedVolume
        case downloads
        case symbolicLinkOrReadOnlyVolume
        case otherUnsupportedLocation
    }

    struct TransactionPaths: Equatable, Sendable {
        let destinationURL: URL
        let stagedBundleURL: URL
        let backupBundleURL: URL
        let failedReplacementURL: URL
    }

    struct RunningApplicationSnapshot: Equatable {
        let processIdentifier: pid_t
        let bundlePath: String?
        let resolvedBundlePath: String?
        let isTerminated: Bool
        let isFinishedLaunching: Bool
    }

    enum ExistingPeerDisposition: Equatable {
        case ignore
        case retireBeforeReplacement
        case refuseUntrustedCanonicalPeer
    }

    private enum InstallError: LocalizedError {
        case applicationsDirectoryUnavailable
        case symbolicLinkDestination(String)
        case stagedCopyDidNotMatchSource
        case invalidBundle(String)
        case replacementDidNotCreateBackup
        case existingRuntimeCouldNotExit
        case untrustedCanonicalRuntime
        case launchFailed(String)
        case launchCouldNotBeConfirmed
        case resumeStateFailed
        case stealthInterrupted

        var errorDescription: String? {
            switch self {
            case .applicationsDirectoryUnavailable:
                return "Your Applications folder is unavailable or read-only."
            case .symbolicLinkDestination(let path):
                return "The install destination is a symbolic link: \(path)"
            case .stagedCopyDidNotMatchSource:
                return "The staged app did not exactly match the running app."
            case .invalidBundle(let detail):
                return "The staged app failed validation: \(detail)"
            case .replacementDidNotCreateBackup:
                return "macOS did not preserve the existing app backup."
            case .existingRuntimeCouldNotExit:
                return "The currently installed Ace did not quit for the upgrade."
            case .untrustedCanonicalRuntime:
                return "The app currently using /Applications/Ace.app is not a trusted Black Label release."
            case .launchFailed(let detail):
                return "The installed copy could not launch: \(detail)"
            case .launchCouldNotBeConfirmed:
                return "The installed copy did not stay running."
            case .resumeStateFailed:
                return "Ace could not preserve your setup step for relaunch."
            case .stealthInterrupted:
                return "Private Mode interrupted the install transaction."
            }
        }
    }

    static let allowedBundlePath = "/Applications/Ace.app"
    static let manualInstallInstructions =
        StableInstallCoordinator.repairInstruction

    /// The remedy for a move that FAILED. It must never name the repair button:
    /// `install.moveFailed` is reported with `repairButtonTitle: nil`, so its
    /// alert carries only "Later". Build 64 reused
    /// `StableInstallCoordinator.repairInstruction` here — "Click Install Ace
    /// to copy it there" — pointing the owner at a control that was not on the
    /// screen, and on that launch no panel or intro window exists to carry one.
    /// These are steps an owner can actually follow with no Ace UI at all.
    static let manualFinderInstallInstructions =
        "Use Finder: drag Ace into your Applications folder, then open it "
        + "from there."

    private static var isInstallInProgress = false
    /// The install transaction runs as a task, so its real terminal outcome
    /// must be recorded somewhere the repair receipt can read. Build 64 threw
    /// it away and always reported "attestation pending" — success and total
    /// failure were indistinguishable to the owner.
    enum InstallTerminalOutcome: Equatable {
        case committedAndRelaunching
        case failed(String)
        case interruptedByPrivateMode
    }
    private static var lastInstallOutcome: InstallTerminalOutcome?
    private static var installProgressWindowController:
        InstallProgressWindowController?
    private static var installRecoveryWindowController:
        InstallRecoveryWindowController?
    private static let canonicalLaunchConfirmationTimeout:
        Duration = .seconds(90)

    static var allowedBundleURL: URL {
        URL(fileURLWithPath: allowedBundlePath, isDirectory: true)
    }

    static var defaultRepairBundleURL: URL {
        allowedBundleURL
    }

    static func locationKind(forBundlePath bundlePath: String) -> LocationKind {
        if isAllowedStableBundlePath(bundlePath) {
            return .allowedStableApplicationsLocation
        }
        let assessment = StableInstallCoordinator.assess(
            StableInstallSnapshot(
                launchBundleURL: URL(
                    fileURLWithPath: bundlePath,
                    isDirectory: true
                ),
                resolvedBundleURL: URL(
                    fileURLWithPath: bundlePath,
                    isDirectory: true
                ),
                homeDirectoryURL:
                    FileManager.default.homeDirectoryForCurrentUser,
                isSymbolicLink: false,
                isVolumeReadOnly: false
            )
        )
        switch assessment.rejection {
        case .appTranslocated:
            return .appTranslocation
        case .diskImage:
            return .mountedVolume
        case .downloads:
            return .downloads
        case .symlink, .readOnlyVolume:
            return .symbolicLinkOrReadOnlyVolume
        case .unsupportedLocation, .none:
            return .otherUnsupportedLocation
        }
    }

    /// Pure string admission is retained for transaction tests and process
    /// snapshots. Live admission additionally proves symlink and volume facts.
    static func isAllowedStableBundlePath(_ bundlePath: String) -> Bool {
        bundlePath == allowedBundlePath
    }

    static func newlyLaunchedCanonicalProcessIdentifier(
        in snapshots: [RunningApplicationSnapshot],
        excluding preexistingProcessIdentifiers: Set<pid_t>,
        currentProcessIdentifier: pid_t,
        requiredBundlePath: String? = nil
    ) -> pid_t? {
        snapshots
            .filter { snapshot in
                let pathIsCanonical: Bool
                if let requiredBundlePath {
                    pathIsCanonical =
                        snapshot.bundlePath == requiredBundlePath
                            && snapshot.resolvedBundlePath
                                == requiredBundlePath
                } else {
                    pathIsCanonical =
                        snapshot.bundlePath
                            == snapshot.resolvedBundlePath
                            && snapshot.bundlePath.map(
                                isAllowedStableBundlePath
                            ) == true
                }
                return snapshot.processIdentifier > 0
                    && snapshot.processIdentifier != currentProcessIdentifier
                    && !preexistingProcessIdentifiers.contains(
                        snapshot.processIdentifier
                    )
                    && !snapshot.isTerminated
                    && snapshot.isFinishedLaunching
                    && pathIsCanonical
            }
            .map(\.processIdentifier)
            .min()
    }

    static func existingPeerDisposition(
        snapshot: RunningApplicationSnapshot,
        currentProcessIdentifier: pid_t,
        identityIsTrusted: Bool
    ) -> ExistingPeerDisposition {
        guard snapshot.processIdentifier > 0,
              snapshot.processIdentifier != currentProcessIdentifier,
              !snapshot.isTerminated,
              snapshot.bundlePath == allowedBundlePath,
              snapshot.resolvedBundlePath == allowedBundlePath else {
            return .ignore
        }
        return identityIsTrusted
            ? .retireBeforeReplacement
            : .refuseUntrustedCanonicalPeer
    }

    static var isRunningFromAllowedStableLocation: Bool {
        StableInstallCoordinator.liveAssessment().isAccepted
    }

    /// Every durable service that records the executable path shares the same
    /// strict predicate as onboarding completion.
    static var isSafeToRegisterPathDependentServices: Bool {
        isRunningFromAllowedStableLocation
    }

    static func transactionPaths(
        identifier: UUID,
        destinationURL requestedDestinationURL: URL? = nil
    ) -> TransactionPaths {
        let destinationURL = requestedDestinationURL
            ?? URL(
                fileURLWithPath: "/Applications/Ace.app",
                isDirectory: true
            )
        let applicationsDirectory =
            destinationURL.deletingLastPathComponent()
        let identifierText = identifier.uuidString.lowercased()
        return TransactionPaths(
            destinationURL: destinationURL,
            stagedBundleURL: applicationsDirectory.appendingPathComponent(
                ".Ace.installing-\(identifierText).app",
                isDirectory: true
            ),
            backupBundleURL: applicationsDirectory.appendingPathComponent(
                ".Ace.backup-\(identifierText).app",
                isDirectory: true
            ),
            failedReplacementURL: applicationsDirectory.appendingPathComponent(
                ".Ace.failed-\(identifierText).app",
                isDirectory: true
            )
        )
    }

    /// Called before any first-run UI. An owner may defer the repair, but setup
    /// and login-item registration remain blocked until the exact path is true.
    static func offerMoveIfNeeded() {
        let assessment = StableInstallCoordinator.liveAssessment()
        guard !assessment.isAccepted else {
            FirstRunFailureReporter.shared.clear(identifier: "install.unsupportedLocation")
            return
        }

        let runningPath = Bundle.main.bundleURL.path
        let summary: String
        switch locationKind(forBundlePath: runningPath) {
        case .allowedStableApplicationsLocation:
            // The exact string matched but runtime symlink checks failed.
            summary = "Ace in Applications is a shortcut, not the real app."
        case .appTranslocation:
            summary = "macOS opened a protected temporary copy of Ace. Open the original download from Downloads to install it."
        case .mountedVolume:
            summary = "Ace is still running from the disk image."
        case .downloads:
            summary = "Ace is still running from Downloads."
        case .symbolicLinkOrReadOnlyVolume:
            summary = "This copy of Ace is not a writable, stable app."
        case .otherUnsupportedLocation:
            summary = "Ace must be named Ace.app in the main Applications folder."
        }

        FirstRunFailureReporter.shared.report(
            FirstRunFailure(
                id: "install.unsupportedLocation",
                summary: summary,
                remedy: manualInstallInstructions,
                repairButtonTitle: nil
            ),
            interrupt: true
        )
        if installRecoveryWindowController == nil {
            installRecoveryWindowController = InstallRecoveryWindowController(
                reporter: FirstRunFailureReporter.shared
            )
        }
        installRecoveryWindowController?.show()
    }

    /// Only Finder's user-directed move reliably clears the state that causes
    /// App Translocation. A programmatic copy can launch another installer and
    /// loop, even though the signed bytes are already in /Applications. Reveal
    /// its containing folder and preserve Gatekeeper/quarantine unchanged.
    @discardableResult
    static func showInstallerInFinder() -> Bool {
        guard !StealthEntryLatch.shared.isRaised else { return false }
        // Selecting the bundle itself requests an App Management extension on
        // macOS 15 even though no modification is intended. Opening only the
        // containing directory avoids that unrelated permission request.
        let folderURL = StableInstallCoordinator.finderDirectory(
            for: Bundle.main.bundleURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let opened = NSWorkspace.shared.open(folderURL)
        LifecycleLog.append(
            "INSTALL Finder reveal \(opened ? "accepted" : "failed"); manual copy pending"
        )
        if opened {
            installRecoveryWindowController?.yieldToFinder()
        }
        return opened
    }

    /// Copies into a hidden sibling first, proves the copy, atomically replaces
    /// an existing Ace while retaining a hidden backup, launches and confirms
    /// the new process, then removes the backup. A failure restores the previous
    /// app and leaves this running process alive.
    @discardableResult
    static func installInApplicationsAndRelaunch() -> Bool {
        guard !isInstallInProgress,
              !StealthEntryLatch.shared.isRaised else {
            return false
        }
        let transactionBoundary = InstallTransactionCommitBoundary(
            entryLatch: StealthEntryLatch.shared
        )
        let transactionCutoffIdentifier =
            StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                transactionBoundary.markStealthEntrySynchronously()
            }
        isInstallInProgress = true
        lastInstallOutcome = nil
        let progressWindowController = InstallProgressWindowController()
        installProgressWindowController = progressWindowController
        progressWindowController.show()

        Task { @MainActor in
            defer {
                progressWindowController.close()
                installProgressWindowController = nil
                isInstallInProgress = false
            }
            await performTransactionalInstallAndRelaunch(
                transactionBoundary: transactionBoundary,
                transactionCutoffIdentifier:
                    transactionCutoffIdentifier
            )
        }
        return true
    }

    /// The native updater has already verified and mounted an immutable DMG.
    /// Reuse the byte-for-byte stage, backup and rollback transaction, keeping
    /// this runtime alive until a new, exact signed process is confirmed.
    static func installUpdate(
        from source: URL,
        release: AceValidatedPublicRelease,
        boundary: InstallTransactionCommitBoundary,
        onCommit: @escaping () -> Void
    ) async -> InstallTerminalOutcome {
        guard !isInstallInProgress, isRunningFromAllowedStableLocation,
              !StealthEntryLatch.shared.isRaised else {
            return .failed("Open Ace from Applications and try again after the current installation finishes.")
        }
        isInstallInProgress = true
        lastInstallOutcome = nil
        defer { isInstallInProgress = false }
        let token = StealthEntryLatch.shared.registerSynchronousEntryCutoff {
            boundary.markStealthEntrySynchronously()
        }
        await performTransactionalInstallAndRelaunch(
            transactionBoundary: boundary,
            transactionCutoffIdentifier: token,
            updateSource: source,
            updateRelease: release,
            onUpdateCommit: onCommit
        )
        return lastInstallOutcome ?? .failed("The update did not produce an installation receipt.")
    }

    private static func performTransactionalInstallAndRelaunch(
        transactionBoundary: InstallTransactionCommitBoundary,
        transactionCutoffIdentifier: UUID,
        updateSource: URL? = nil,
        updateRelease: AceValidatedPublicRelease? = nil,
        onUpdateCommit: (() -> Void)? = nil
    ) async {
        let fileManager = FileManager.default
        let sourceBundleURL = updateSource ?? Bundle.main.bundleURL
        var runtimeLockWasReleased = false
        let transactionPaths = transactionPaths(
            identifier: UUID(),
            destinationURL: defaultRepairBundleURL
        )
        let destinationParentURL =
            transactionPaths.destinationURL.deletingLastPathComponent()
        let destinationExistedBeforeInstall = fileManager.fileExists(
            atPath: transactionPaths.destinationURL.path
        )
        let bulkIOWorker = InstallBulkIOWorker(
            boundary: transactionBoundary
        )
        var launchBoundary: InstallLaunchEffectBoundary?
        var launchCutoffIdentifier: UUID?
        defer {
            if let launchCutoffIdentifier {
                StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(
                    launchCutoffIdentifier
                )
            }
            if runtimeLockWasReleased,
               lastInstallOutcome != .committedAndRelaunching {
                // The failed candidate has been retired before rollback. Keep
                // the old process as the sole runtime after a failed update.
                if !CompanionAppDelegate.acquireRuntimeInstanceLockAcrossHandoff() {
                    NSApp.terminate(nil)
                }
            }
            launchBoundary?.releaseWithoutCutoff()
            StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(
                transactionCutoffIdentifier
            )
        }

        do {
            guard transactionBoundary.stealthDisposition
                    == .continueTransaction else {
                throw InstallError.stealthInterrupted
            }
            try await retireTrustedCanonicalRuntimeBeforeReplacement()
            guard transactionBoundary.stealthDisposition
                    == .continueTransaction else {
                throw InstallError.stealthInterrupted
            }
            try await Task.detached(priority: .userInitiated) {
                try prepareTransaction(
                    sourceBundleURL: sourceBundleURL,
                    transactionPaths: transactionPaths,
                    destinationParentURL: destinationParentURL,
                    destinationExistedBeforeInstall:
                        destinationExistedBeforeInstall,
                    transactionBoundary: transactionBoundary,
                    bulkIOWorker: bulkIOWorker
                )
                if let updateRelease {
                    try AceNativeUpdateArtifact.verifyBundle(
                        transactionPaths.stagedBundleURL, release: updateRelease
                    )
                }
            }.value
            guard transactionBoundary.stealthDisposition
                    == .continueTransaction else {
                throw InstallError.stealthInterrupted
            }
            LifecycleLog.append(
                "INSTALL staged and proven at \(transactionPaths.stagedBundleURL.path)")

            let didCommit = try transactionBoundary.commitIfAllowed {
                onUpdateCommit?()
                if destinationExistedBeforeInstall {
                    _ = try fileManager.replaceItemAt(
                        transactionPaths.destinationURL,
                        withItemAt: transactionPaths.stagedBundleURL,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try fileManager.moveItem(
                        at: transactionPaths.stagedBundleURL,
                        to: transactionPaths.destinationURL
                    )
                }
            }
            guard didCommit else {
                throw InstallError.stealthInterrupted
            }
            guard transactionBoundary.stealthDisposition
                    == .continueTransaction else {
                throw InstallError.stealthInterrupted
            }

            try await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager()
                try proveBundleCopy(
                    sourceBundleURL: sourceBundleURL,
                    copiedBundleURL:
                        transactionPaths.destinationURL,
                    fileManager: fileManager,
                    bulkIOWorker: bulkIOWorker
                )
                if let updateRelease {
                    try AceNativeUpdateArtifact.verifyBundle(
                        transactionPaths.destinationURL, release: updateRelease
                    )
                }
            }.value
            guard transactionBoundary.stealthDisposition
                    == .continueTransaction else {
                throw InstallError.stealthInterrupted
            }

            do {
                if updateSource == nil {
                try StableInstallResumeStore().write(
                    stage: "onboarding"
                )
                }
            } catch {
                throw InstallError.resumeStateFailed
            }

            let activeLaunchBoundary = InstallLaunchEffectBoundary(
                entryLatch: StealthEntryLatch.shared
            )
            launchBoundary = activeLaunchBoundary
            let activeLaunchCutoffIdentifier =
                StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                    activeLaunchBoundary.cutOffSynchronously()
                }
            launchCutoffIdentifier = activeLaunchCutoffIdentifier
            if updateSource != nil {
                AceRuntimeInstanceLock.shared.release()
                runtimeLockWasReleased = true
            }
            try await launchAndConfirmInstalledCopy(
                at: transactionPaths.destinationURL,
                launchBoundary: activeLaunchBoundary,
                expectedRelease: updateRelease
            )
            guard transactionBoundary.stealthDisposition
                    == .continueTransaction,
                  !activeLaunchBoundary.isCutOff else {
                throw InstallError.stealthInterrupted
            }

            if transactionBoundary.previousAppWasBackedUp {
                let cleanupFailure = await Task.detached {
                    let fileManager = FileManager()
                    do {
                        try fileManager.removeItem(
                            at: transactionPaths.backupBundleURL
                        )
                        return nil as String?
                    } catch {
                        return String(describing: error)
                    }
                }.value
                if let cleanupFailure {
                    LifecycleLog.append(
                        "INSTALL succeeded; old hidden backup cleanup failed: \(cleanupFailure)")
                }
            }
            guard transactionBoundary.stealthDisposition
                    == .continueTransaction,
                  !activeLaunchBoundary.isCutOff else {
                throw InstallError.stealthInterrupted
            }
            LifecycleLog.append(
                "INSTALL transaction committed at "
                    + transactionPaths.destinationURL.path
                    + "; relaunch confirmed"
            )
            lastInstallOutcome = .committedAndRelaunching
            if updateSource != nil {
                // Let the updater detach its private mount before terminating
                // the outgoing runtime. The new exact process owns the lock.
                activeLaunchBoundary.releaseWithoutCutoff()
                return
            }
            let didRequestTermination = requestTerminationIfAllowed(
                entryLatch: StealthEntryLatch.shared
            ) {
                activeLaunchBoundary.releaseWithoutCutoff()
                NSApp.terminate(nil)
            }
            guard didRequestTermination else {
                throw InstallError.stealthInterrupted
            }
        } catch {
            // A failed launch can leave a live candidate. Retire only the
            // exact processes created/tracked by this transaction before any
            // rollback or runtime-lock reacquisition.
            launchBoundary?.cutOffSynchronously()
            let stealthDisposition =
                transactionBoundary.stealthDisposition
            let previousAppWasBackedUp =
                transactionBoundary.previousAppWasBackedUp
            if stealthDisposition != .continueTransaction {
                launchBoundary?.cutOffSynchronously()
                let rollbackMessage = await Task.detached {
                    let fileManager = FileManager()
                    var rollbackMessage: String?
                    if stealthDisposition == .rollbackAndStop,
                       previousAppWasBackedUp {
                        rollbackMessage = rollbackPreviousAppIfNeeded(
                            transactionPaths: transactionPaths,
                            fileManager: fileManager
                        )
                    }
                    cleanupTransactionArtifacts(
                        transactionPaths: transactionPaths,
                        removeBackup:
                            (stealthDisposition == .cleanupOnly && updateSource == nil)
                            || !previousAppWasBackedUp,
                        fileManager: fileManager
                    )
                    return rollbackMessage
                }.value
                if let rollbackMessage {
                    LifecycleLog.append(rollbackMessage)
                }
                lastInstallOutcome = .interruptedByPrivateMode
                return
            }

            LifecycleLog.append("INSTALL transaction failed: \(error)")
            lastInstallOutcome = .failed(error.localizedDescription)

            let rollbackMessage = await Task.detached {
                let fileManager = FileManager()
                var rollbackMessage: String?
                if previousAppWasBackedUp {
                    rollbackMessage = rollbackPreviousAppIfNeeded(
                        transactionPaths: transactionPaths,
                        fileManager: fileManager
                    )
                }

                cleanupTransactionArtifacts(
                    transactionPaths: transactionPaths,
                    removeBackup: !previousAppWasBackedUp,
                    fileManager: fileManager
                )
                return rollbackMessage
            }.value
            if let rollbackMessage {
                LifecycleLog.append(rollbackMessage)
            }
            if updateSource != nil { return }
            guard transactionBoundary.stealthDisposition
                    == .continueTransaction else {
                return
            }

            // With no previous app, a fully proven promoted copy remains in
            // Applications even if LaunchServices failed. Removing it would
            // turn a launch failure into loss of the only stable installed copy.
            // Gate on what the transaction ACTUALLY committed, never on whether
            // an app happened to be there first. Build 64 keyed this on
            // `destinationExistedBeforeInstall`, so on a fresh Mac EVERY
            // pre-commit failure — unwritable /Applications on a standard
            // (non-admin) account, a full disk, an invalid bundle, a refused
            // replacement — told the owner "Ace was copied safely to
            // /Applications/Ace.app" moments after cleanup deleted the staged
            // copy and while that folder was empty. Only a committed
            // transaction may claim the copy is there.
            let transactionDidCommit = transactionBoundary.phase == .committed
            let fallbackInstruction =
                transactionDidCommit
                ? "Ace was copied safely to "
                    + transactionPaths.destinationURL.path
                    + ", but macOS did not open it. Quit this copy, then "
                    + "double-click Ace in your Applications folder."
                : manualFinderInstallInstructions
            _ = SetupVisibleEffectAdmission.commit {
                reportMoveFailure(
                    detail: error.localizedDescription,
                    instruction: fallbackInstruction
                )
                return true
            }
        }
    }

    private nonisolated static func prepareTransaction(
        sourceBundleURL: URL,
        transactionPaths: TransactionPaths,
        destinationParentURL: URL,
        destinationExistedBeforeInstall: Bool,
        transactionBoundary: InstallTransactionCommitBoundary,
        bulkIOWorker: InstallBulkIOWorker
    ) throws {
        let fileManager = FileManager()
        try bulkIOWorker.checkpoint()
        guard bundleSatisfiesReleaseRequirement(sourceBundleURL) else {
            throw InstallError.invalidBundle(
                "the running app is not an intact Black Label release"
            )
        }
        if !fileManager.fileExists(
            atPath: destinationParentURL.path
        ) {
            try fileManager.createDirectory(
                at: destinationParentURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        }
        try validateApplicationsDestination(
            destinationParentURL: destinationParentURL,
            destinationURL: transactionPaths.destinationURL,
            fileManager: fileManager
        )

        try bulkIOWorker.copyItem(
            from: sourceBundleURL,
            to: transactionPaths.stagedBundleURL
        )
        try proveBundleCopy(
            sourceBundleURL: sourceBundleURL,
            copiedBundleURL: transactionPaths.stagedBundleURL,
            fileManager: fileManager,
            bulkIOWorker: bulkIOWorker
        )
        try bulkIOWorker.checkpoint()

        if destinationExistedBeforeInstall {
            try bulkIOWorker.copyItem(
                from: transactionPaths.destinationURL,
                to: transactionPaths.backupBundleURL
            )
            try proveBundleCopy(
                sourceBundleURL: transactionPaths.destinationURL,
                copiedBundleURL: transactionPaths.backupBundleURL,
                fileManager: fileManager,
                bulkIOWorker: bulkIOWorker
            )
            guard !isSymbolicLink(
                at: transactionPaths.backupBundleURL
            ) else {
                throw InstallError.replacementDidNotCreateBackup
            }
            transactionBoundary.markPreviousAppBackupReady()
        }
        try bulkIOWorker.checkpoint()
    }

    static func requestTerminationIfAllowed(
        entryLatch: StealthEntryLatch,
        requestTermination: () -> Void
    ) -> Bool {
        let requestWasAdmitted: Bool? =
            entryLatch.performUnlessRaised {
                requestTermination()
                return true
            }
        return requestWasAdmitted == true
    }

    private nonisolated static func cleanupTransactionArtifacts(
        transactionPaths: TransactionPaths,
        removeBackup: Bool,
        fileManager: FileManager
    ) {
        let removableURLs = [
            transactionPaths.stagedBundleURL,
        ] + (removeBackup ? [transactionPaths.backupBundleURL] : [])
        for removableURL in removableURLs
        where fileManager.fileExists(atPath: removableURL.path) {
            try? fileManager.removeItem(at: removableURL)
        }
    }

    private nonisolated static func rollbackPreviousAppIfNeeded(
        transactionPaths: TransactionPaths,
        fileManager: FileManager
    ) -> String {
        do {
            let destinationExists = fileManager.fileExists(
                atPath: transactionPaths.destinationURL.path
            )
            if destinationExists,
               fileManager.contentsEqual(
                atPath: transactionPaths.destinationURL.path,
                andPath: transactionPaths.backupBundleURL.path
               ) {
                try? fileManager.removeItem(
                    at: transactionPaths.backupBundleURL
                )
                return "INSTALL rollback not needed — previous app remained in place"
            }

            if destinationExists {
                _ = try fileManager.replaceItemAt(
                    transactionPaths.destinationURL,
                    withItemAt: transactionPaths.backupBundleURL,
                    backupItemName:
                        transactionPaths.failedReplacementURL
                            .lastPathComponent,
                    options: [.withoutDeletingBackupItem]
                )
            } else {
                try fileManager.moveItem(
                    at: transactionPaths.backupBundleURL,
                    to: transactionPaths.destinationURL
                )
            }
            try proveBundleExistsAtDestination(
                transactionPaths.destinationURL,
                fileManager: fileManager
            )
            let result =
                "INSTALL rollback restored previous "
                    + transactionPaths.destinationURL.path
            if fileManager.fileExists(
                atPath: transactionPaths.failedReplacementURL.path
            ) {
                try? fileManager.removeItem(
                    at: transactionPaths.failedReplacementURL
                )
            }
            return result
        } catch {
            // On rollback failure, never delete either candidate. The current
            // process remains alive, the promoted copy stays at the canonical
            // path when present, and the previous app remains in its hidden
            // backup for manual recovery.
            return "INSTALL rollback could not complete: \(error)"
        }
    }

    private nonisolated static func validateApplicationsDestination(
        destinationParentURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: destinationParentURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue,
              fileManager.isWritableFile(
                  atPath: destinationParentURL.path
              ) else {
            throw InstallError.applicationsDirectoryUnavailable
        }
        guard destinationParentURL.resolvingSymlinksInPath().path
                == destinationParentURL.path,
              !isSymbolicLink(at: destinationParentURL) else {
            throw InstallError.symbolicLinkDestination(
                destinationParentURL.path
            )
        }
        if fileManager.fileExists(atPath: destinationURL.path),
           isSymbolicLink(at: destinationURL) {
            throw InstallError.symbolicLinkDestination(destinationURL.path)
        }
    }

    private nonisolated static func proveBundleCopy(
        sourceBundleURL: URL,
        copiedBundleURL: URL,
        fileManager: FileManager,
        bulkIOWorker: InstallBulkIOWorker
    ) throws {
        try bulkIOWorker.checkpoint()
        guard !isSymbolicLink(at: copiedBundleURL) else {
            throw InstallError.symbolicLinkDestination(copiedBundleURL.path)
        }
        try proveBundleExistsAtDestination(
            copiedBundleURL,
            fileManager: fileManager
        )

        let sourceIdentity = try bundleIdentity(
            at: sourceBundleURL,
            fileManager: fileManager
        )
        try bulkIOWorker.checkpoint()
        let copiedIdentity = try bundleIdentity(
            at: copiedBundleURL,
            fileManager: fileManager
        )
        guard sourceIdentity == copiedIdentity,
              try bulkIOWorker.contentsEqual(
                  sourceRootURL: sourceBundleURL,
                  copiedRootURL: copiedBundleURL,
                  fileManager: fileManager
              ) else {
            throw InstallError.stagedCopyDidNotMatchSource
        }
    }

    private nonisolated static func proveBundleExistsAtDestination(
        _ bundleURL: URL,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: bundleURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw InstallError.invalidBundle("the app directory is missing")
        }
    }

    private nonisolated static func bundleIdentity(
        at bundleURL: URL,
        fileManager: FileManager
    ) throws -> [String] {
        let infoPropertyListURL = bundleURL.appendingPathComponent(
            "Contents/Info.plist",
            isDirectory: false
        )
        let infoPropertyListData = try Data(contentsOf: infoPropertyListURL)
        guard let infoPropertyList = try PropertyListSerialization.propertyList(
            from: infoPropertyListData,
            options: [],
            format: nil
        ) as? [String: Any],
              let bundleIdentifier =
                infoPropertyList["CFBundleIdentifier"] as? String,
              let executableName =
                infoPropertyList["CFBundleExecutable"] as? String,
              let bundleVersion =
                infoPropertyList["CFBundleVersion"] as? String,
              let shortVersion =
                infoPropertyList["CFBundleShortVersionString"] as? String else {
            throw InstallError.invalidBundle("Info.plist identity is incomplete")
        }

        let executableURL = bundleURL.appendingPathComponent(
            "Contents/MacOS/\(executableName)",
            isDirectory: false
        )
        let executableValues = try executableURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard executableValues.isRegularFile == true,
              executableValues.isSymbolicLink != true,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw InstallError.invalidBundle(
                "Contents/MacOS/\(executableName) is not a regular executable"
            )
        }

        return [
            bundleIdentifier,
            executableName,
            bundleVersion,
            shortVersion,
        ]
    }

    private static func launchAndConfirmInstalledCopy(
        at installedBundleURL: URL,
        launchBoundary: InstallLaunchEffectBoundary,
        expectedRelease: AceValidatedPublicRelease? = nil
    ) async throws {
        guard !launchBoundary.isCutOff else {
            throw InstallError.stealthInterrupted
        }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw InstallError.launchFailed("the current bundle identifier is missing")
        }
        let processesPresentBeforeLaunch = Set(
            runningApplicationSnapshots(
                bundleIdentifier: bundleIdentifier
            )
            .filter {
                !$0.isTerminated
                    && $0.bundlePath == installedBundleURL.path
                    && $0.resolvedBundlePath
                        == installedBundleURL.path
            }
            .map(\.processIdentifier)
        )

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-n", installedBundleURL.path]
        do {
            let didLaunch = try launchBoundary.launchProcessIfAllowed {
                try launcher.run()
                return launcher.processIdentifier
            }
            guard didLaunch else {
                throw InstallError.stealthInterrupted
            }
        } catch {
            if launchBoundary.isCutOff {
                throw InstallError.stealthInterrupted
            }
            throw InstallError.launchFailed(error.localizedDescription)
        }
        let launcherProcessIdentifier = launcher.processIdentifier
        let launcherClock = ContinuousClock()
        let launcherDeadline =
            launcherClock.now.advanced(
                by: canonicalLaunchConfirmationTimeout
            )
        while launcher.isRunning, launcherClock.now < launcherDeadline {
            guard !launchBoundary.isCutOff else {
                RunningProcessBox.terminateProcessTree(launcher)
                launchBoundary.processDidExit(launcherProcessIdentifier)
                throw InstallError.stealthInterrupted
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                RunningProcessBox.terminateProcessTree(launcher)
                launchBoundary.processDidExit(launcherProcessIdentifier)
                if launchBoundary.isCutOff {
                    throw InstallError.stealthInterrupted
                }
                throw InstallError.launchCouldNotBeConfirmed
            }
        }
        guard !launcher.isRunning else {
            RunningProcessBox.terminateProcessTree(launcher)
            launchBoundary.processDidExit(launcherProcessIdentifier)
            throw InstallError.launchFailed("/usr/bin/open timed out")
        }
        launchBoundary.processDidExit(launcherProcessIdentifier)
        guard !launchBoundary.isCutOff else {
            throw InstallError.stealthInterrupted
        }
        guard launcher.terminationStatus == 0 else {
            throw InstallError.launchFailed(
                "/usr/bin/open exited \(launcher.terminationStatus)"
            )
        }

        let currentProcessIdentifier =
            ProcessInfo.processInfo.processIdentifier
        let clock = ContinuousClock()
        let confirmationDeadline = clock.now.advanced(
            by: canonicalLaunchConfirmationTimeout
        )
        var candidateProcessIdentifier: pid_t?
        var candidateStableUntil: ContinuousClock.Instant?
        while clock.now < confirmationDeadline {
            guard !launchBoundary.isCutOff else {
                throw InstallError.stealthInterrupted
            }
            let observedProcessIdentifier =
                newlyLaunchedCanonicalProcessIdentifier(
                    in: runningApplicationSnapshots(
                        bundleIdentifier: bundleIdentifier
                    ),
                    excluding: processesPresentBeforeLaunch,
                    currentProcessIdentifier: currentProcessIdentifier,
                    requiredBundlePath: installedBundleURL.path
                )

            if let processIdentifier = observedProcessIdentifier {
                if candidateProcessIdentifier != processIdentifier {
                    guard launchBoundary.trackProcessIdentifierIfAllowed(
                        processIdentifier
                    ) else {
                        throw InstallError.stealthInterrupted
                    }
                    candidateProcessIdentifier = processIdentifier
                    candidateStableUntil =
                        clock.now.advanced(by: .seconds(2))
                } else if let candidateStableUntil,
                          clock.now >= candidateStableUntil {
                    if let expectedRelease {
                        guard runningProcessMatchesRelease(
                            processIdentifier, release: expectedRelease
                        ) else {
                            throw InstallError.launchFailed("the running update does not match the release receipt")
                        }
                    }
                    // Do not commit on a one-poll LaunchServices appearance. The
                    // returned process must finish launching and stay alive from
                    // the exact canonical path before the old backup is deleted.
                    return
                }
            } else {
                candidateProcessIdentifier = nil
                candidateStableUntil = nil
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                if launchBoundary.isCutOff {
                    throw InstallError.stealthInterrupted
                }
                throw InstallError.launchCouldNotBeConfirmed
            }
        }
        throw InstallError.launchCouldNotBeConfirmed
    }

    private static func runningApplicationSnapshots(
        bundleIdentifier: String
    ) -> [RunningApplicationSnapshot] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).map { runningApplication in
            let bundleURL = runningApplication.bundleURL
            return RunningApplicationSnapshot(
                processIdentifier: runningApplication.processIdentifier,
                bundlePath: bundleURL?.path,
                resolvedBundlePath:
                    bundleURL?.resolvingSymlinksInPath().path,
                isTerminated: runningApplication.isTerminated,
                isFinishedLaunching:
                    runningApplication.isFinishedLaunching
            )
        }
    }

    /// A running Build 45/60 process can still own Ace's singleton even after
    /// its bundle is replaced on disk. Retire only a process whose live code
    /// object satisfies the pinned Developer ID requirement, and do so before
    /// the first copy or rename. An unknown lookalike at the canonical path is
    /// a hard stop rather than a process Ace is allowed to kill.
    private static func retireTrustedCanonicalRuntimeBeforeReplacement()
        async throws {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw InstallError.invalidBundle(
                "the current bundle identifier is missing"
            )
        }
        let currentProcessIdentifier =
            ProcessInfo.processInfo.processIdentifier
        let candidates = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        var trustedPeers: [NSRunningApplication] = []

        for application in candidates {
            let bundleURL = application.bundleURL
            let snapshot = RunningApplicationSnapshot(
                processIdentifier: application.processIdentifier,
                bundlePath: bundleURL?.standardizedFileURL.path,
                resolvedBundlePath:
                    bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path,
                isTerminated: application.isTerminated,
                isFinishedLaunching: application.isFinishedLaunching
            )
            switch existingPeerDisposition(
                snapshot: snapshot,
                currentProcessIdentifier: currentProcessIdentifier,
                identityIsTrusted: runningProcessSatisfiesReleaseRequirement(
                    processIdentifier: application.processIdentifier
                )
            ) {
            case .ignore:
                continue
            case .retireBeforeReplacement:
                trustedPeers.append(application)
            case .refuseUntrustedCanonicalPeer:
                throw InstallError.untrustedCanonicalRuntime
            }
        }

        guard !trustedPeers.isEmpty else { return }
        for application in trustedPeers where !application.isTerminated {
            _ = application.terminate()
        }
        let gracefulDeadline = ContinuousClock.now.advanced(
            by: .seconds(4)
        )
        while trustedPeers.contains(where: { !$0.isTerminated }),
              ContinuousClock.now < gracefulDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        for application in trustedPeers where !application.isTerminated {
            guard runningProcessSatisfiesReleaseRequirement(
                processIdentifier: application.processIdentifier
            ) else {
                throw InstallError.untrustedCanonicalRuntime
            }
            _ = application.forceTerminate()
        }
        let forcedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while trustedPeers.contains(where: { !$0.isTerminated }),
              ContinuousClock.now < forcedDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard trustedPeers.allSatisfy(\.isTerminated) else {
            throw InstallError.existingRuntimeCouldNotExit
        }
    }

    private nonisolated static func runningProcessSatisfiesReleaseRequirement(
        processIdentifier: pid_t
    ) -> Bool {
        guard processIdentifier > 0 else { return false }
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: processIdentifier),
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &code
        ) == errSecSuccess,
        let code else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            releaseCodeSigningRequirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement else {
            return false
        }
        return SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)),
            requirement
        ) == errSecSuccess
    }

    private nonisolated static func runningProcessMatchesRelease(
        _ processIdentifier: pid_t, release: AceValidatedPublicRelease
    ) -> Bool {
        guard runningProcessSatisfiesReleaseRequirement(processIdentifier: processIdentifier) else { return false }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil,
            [kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary,
            [], &code) == errSecSuccess, let code else { return false }
        #if arch(arm64)
        let expected = release.appCdhashArm64
        #else
        let expected = release.appCdhashX86_64
        #endif
        guard expected.count == 40,
              expected.allSatisfy({ $0.isHexDigit }) else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            (releaseCodeSigningRequirement + " and cdhash H\"\(expected)\"") as CFString,
            [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code,
            SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)), requirement) == errSecSuccess
    }

    private nonisolated static func bundleSatisfiesReleaseRequirement(
        _ bundleURL: URL
    ) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            releaseCodeSigningRequirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement else {
            return false
        }
        let flags = SecCSFlags(
            rawValue: UInt32(
                kSecCSCheckAllArchitectures
                    | kSecCSCheckNestedCode
                    | kSecCSStrictValidate
            )
        )
        return SecStaticCodeCheckValidity(
            staticCode,
            flags,
            requirement
        ) == errSecSuccess
    }

    private nonisolated static func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) == true
    }

    private static func reportMoveFailure(
        detail: String,
        instruction: String
    ) {
        FirstRunFailureReporter.shared.report(
            FirstRunFailure(
                id: "install.moveFailed",
                summary: "Ace could not finish moving into Applications.",
                remedy: "\(detail)\n\n\(instruction)",
                repairButtonTitle: nil
            ),
            interrupt: true
        )
    }
}
#endif // circuit-convert
