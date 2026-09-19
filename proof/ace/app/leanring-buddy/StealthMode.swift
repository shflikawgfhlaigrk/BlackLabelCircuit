//
//  StealthMode.swift
//  Black Label Assistant — the ghost. (Ported from the Utah multi-lane fork.)
//
//  Stealth is not a lane — it is the exclusive mode. "Ace, go stealth" kills
//  every lane, hides the gem and the cursor, and silences the voice, so Ace can
//  sit quietly in a library or during a practice test. Passive listening and
//  normal dictation are disabled while the wall is up. One explicit normal PTT
//  hold may open only the local Apple-on-device exit recognizer; it cannot route
//  speech anywhere else.
//
//  One explicit operation remains available. Each event-tap-observed
//  Caps Lock on, then Shift+Z captures only the verified focused window, identifies one
//  multiple-choice answer, and performs at most one target-bound revalidated
//  click in the same task. There is no passive capture while the wall is up.
//

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
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import CircuitPortKit

/// The first, process-wide Stealth boundary.
///
/// The keyboard event tap raises this before it queues any MainActor work.
/// Effect-producing subsystems can therefore stop synchronously without
/// waiting for `StealthMode.isActive` or the controller transition. The same
/// raise also publishes a fixed-name external receipt through a directory
/// descriptor prepared before the event tap is installed.
///
/// The callback path is deliberately tiny: one lock, an `openat` rooted in a
/// preverified parent, one bounded write, and `close`. If the named support
/// directory was renamed, it binds the receipt to the replacement currently
/// visible to detached wrappers instead of writing through a stale child fd.
/// It never resolves a broad path, waits on another process, or calls `fsync`.
/// The later durable transition supplies the crash-durable receipt and sync.
nonisolated final class StealthEntryLatch: @unchecked Sendable {
    static let shared = StealthEntryLatch()

    private let lock = NSLock()
    private var raisedStorage = false
    private var externalAdmissionCheck: (@Sendable () -> Bool)?
    private var preparedParentDirectoryDescriptor: Int32 = -1
    private var preparedSupportDirectoryName = ""
    private var preparedDirectoryURL: URL?
    private var activeReceiptPublishers = 0
    private var retiredReceiptDescriptors: [Int32] = []
    private var synchronousEntryCutoffs:
        [UUID: @Sendable () -> Void] = [:]

    var isRaised: Bool {
        let state = lock.withLock { (raisedStorage, externalAdmissionCheck) }
        return state.0 || !(state.1?() ?? true)
    }

    /// Used only by the one-request native child before starting its executor.
    /// The file-backed parent grant is never read while the entry lock is held.
    @discardableResult
    func requireExternalAdmission(_ check: @escaping @Sendable () -> Bool) -> Bool {
        lock.withLock {
            guard externalAdmissionCheck == nil, !raisedStorage else { return false }
            externalAdmissionCheck = check
            return true
        }
    }

    /// Atomically admits one small, non-waiting effect invocation or rejects
    /// it. The body may perform exactly the synchronous kickoff/commit whose
    /// ordering matters — for example a suspended URLSession task's `resume`,
    /// a process spawn (never its wait), one LaunchServices open submission,
    /// one ServiceManagement registration mutation, one AppKit visibility
    /// mutation, or one local rename/receipt commit. Any effect that outlives
    /// that call must pre-register a synchronous cutoff or have narrow cleanup
    /// (the visibility wall for windows) before admission.
    ///
    /// Never put a modal loop, AppleScript/Apple Event round trip, process
    /// wait, pipe read, network response wait, subprocess discovery, recursive
    /// filesystem work, or other unbounded operation here. The Private Mode event tap
    /// raises through this same lock, so either the one invocation returns
    /// first or the owner request wins first.
    func performUnlessRaised<T>(
        _ body: () throws -> T
    ) rethrows -> T? {
        let externalCheck = lock.withLock { externalAdmissionCheck }
        guard externalCheck?() ?? true else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !raisedStorage else { return nil }
        return try body()
    }

    /// Registers one bounded, non-MainActor cutoff for an effect that must stop
    /// in the event-tap turn. Registration is race-safe with entry: either the
    /// callback is present in the raise snapshot, or registration observes the
    /// already-raised wall and invokes it before returning.
    ///
    /// Cutoffs run outside this latch's lock so they may safely consult the
    /// latch and use their own small synchronization boundary. They must never
    /// wait for a process, actor, filesystem operation, or network response.
    @discardableResult
    func registerSynchronousEntryCutoff(
        _ cutoff: @escaping @Sendable () -> Void
    ) -> UUID {
        let identifier = UUID()
        let invokeImmediately = lock.withLock {
            synchronousEntryCutoffs[identifier] = cutoff
            return raisedStorage
        }
        if invokeImmediately {
            cutoff()
        }
        return identifier
    }

    /// A callback already copied by a concurrent raise may still run once after
    /// removal. Owners should therefore capture their cutoff boundary weakly and
    /// make the cutoff itself idempotent.
    func unregisterSynchronousEntryCutoff(_ identifier: UUID) {
        _ = lock.withLock {
            synchronousEntryCutoffs.removeValue(forKey: identifier)
        }
    }

    /// Performs all path discovery and directory creation outside the keyboard
    /// callback. A failed preparation means the Private Mode event tap must not be
    /// installed: accepting the chord without an external boundary would let
    /// an already-running wrapper mutate after the owner's request.
    @discardableResult
    func prepareExternalReceipt(
        inDirectory directoryURL: URL? = StealthDurableIntent.defaultDirectoryURL
    ) -> Bool {
        guard let directoryURL,
              let preparedLocation =
                StealthDurableIntent.prepareExternalReceiptLocation(
                  directoryURL,
                  createIfMissing: true
              ) else {
            return false
        }

        let descriptorToClose = lock.withLock { () -> Int32? in
            let replacedDescriptor =
                preparedParentDirectoryDescriptor >= 0
                    ? preparedParentDirectoryDescriptor
                    : nil
            preparedParentDirectoryDescriptor =
                preparedLocation.parentDirectoryDescriptor
            preparedSupportDirectoryName =
                preparedLocation.supportDirectoryName
            preparedDirectoryURL = directoryURL.standardizedFileURL
            guard let replacedDescriptor else { return nil }
            if activeReceiptPublishers > 0 {
                retiredReceiptDescriptors.append(replacedDescriptor)
                return nil
            }
            return replacedDescriptor
        }
        if let descriptorToClose {
            close(descriptorToClose)
        }
        return true
    }

    /// Called directly on the CGEvent tap thread. Presence of the entry receipt
    /// is the signal; even a partial write remains fail-closed to wrappers.
    @discardableResult
    func raiseSynchronously(
        preparedPublisher:
            ((Int32, String) -> Bool)? = nil,
        fallbackPublisher:
            ((URL) -> Bool)? = nil
    ) -> Bool {
        let snapshot = lock.withLock { () -> (
            descriptor: Int32,
            directoryName: String,
            directoryURL: URL?,
            cutoffs: [@Sendable () -> Void]
        ) in
            raisedStorage = true
            activeReceiptPublishers += 1
            return (
                preparedParentDirectoryDescriptor,
                preparedSupportDirectoryName,
                preparedDirectoryURL,
                Array(synchronousEntryCutoffs.values)
            )
        }
        // Publish the privacy cutoff before touching the filesystem. Both the
        // cutoffs and receipt I/O run outside the latch, so readers/effects see
        // raised immediately and entry never queues behind open/write/close.
        for cutoff in snapshot.cutoffs {
            cutoff()
        }
        let publishPrepared = preparedPublisher ?? {
            descriptor, directoryName in
            StealthDurableIntent.publishEntryRequest(
                inPreparedParentDirectoryDescriptor: descriptor,
                supportDirectoryName: directoryName
            )
        }
        let publishFallback = fallbackPublisher ?? { directoryURL in
            StealthDurableIntent.publishEntryRequest(
                inDirectory: directoryURL
            )
        }
        var didPublishReceipt = snapshot.descriptor >= 0
            && publishPrepared(
                snapshot.descriptor,
                snapshot.directoryName
            )
        if !didPublishReceipt, let directoryURL = snapshot.directoryURL {
            didPublishReceipt = publishFallback(directoryURL)
        }
        let descriptorsToClose = lock.withLock { () -> [Int32] in
            activeReceiptPublishers = max(0, activeReceiptPublishers - 1)
            guard activeReceiptPublishers == 0 else { return [] }
            let descriptors = retiredReceiptDescriptors
            retiredReceiptDescriptors.removeAll(keepingCapacity: false)
            return descriptors
        }
        for descriptor in descriptorsToClose {
            close(descriptor)
        }
        return didPublishReceipt
    }

    func raiseInProcess() {
        let cutoffs = lock.withLock {
            raisedStorage = true
            return Array(synchronousEntryCutoffs.values)
        }
        for cutoff in cutoffs {
            cutoff()
        }
    }

    fileprivate func lowerAfterVerifiedExternalClear() {
        lock.withLock {
            raisedStorage = false
        }
    }

    /// Test-only state isolation for policy tests that invoke the event-tap
    /// registration method directly without installing a real event tap.
    func resetInProcessStateForTesting() {
        precondition(
            ProcessInfo.processInfo.environment[
                "XCTestConfigurationFilePath"
            ] != nil
        )
        lock.withLock {
            raisedStorage = false
        }
    }

    deinit {
        if preparedParentDirectoryDescriptor >= 0 {
            close(preparedParentDirectoryDescriptor)
        }
        for descriptor in retiredReceiptDescriptors {
            close(descriptor)
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// A modal return is only an action when it is the exact button response and
/// the post-modal Stealth gate is still open. `NSApp.abortModal()` therefore
/// cannot be confused with Unlock/Open/Skip when Private Mode entry tears a nested modal loop
/// down.
nonisolated enum StealthModalActionPolicy {
    static func accepts(
        _ response: NSApplication.ModalResponse,
        expected: NSApplication.ModalResponse,
        effectsAreAllowed: Bool
    ) -> Bool {
        effectsAreAllowed && response == expected
    }
}
#endif // circuit-convert

/// Durable owner intent is deliberately separate from the live-PID helper
/// marker. The PID marker answers "is this exact Ace process alive?" for
/// detached tools; this receipt answers "did the owner explicitly leave
/// Stealth?" across a crash or relaunch.
///
/// Every operation anchors itself to an opened, non-symlink support directory
/// and uses `openat`/`renameat`/`unlinkat` with `O_NOFOLLOW`. A planted symlink
/// is rejected rather than followed or replaced.
nonisolated enum StealthDurableIntent {
    enum RestorationState: String, Equatable, Sendable {
        case absent
        case present
        case unsafeOrUnreadable = "unsafe-or-unreadable"

        var requiresHiddenLaunch: Bool {
            self != .absent
        }
    }

    private enum MarkerState: Equatable {
        case absent
        case present
        case unsafeOrUnreadable
    }

    private enum MarkerContentsPolicy {
        case exact
        case prefix
    }

    static let fileName = "stealth-intent-v1"
    static let entryRequestFileName = "stealth-entry-request-v1"
    private static let contents = Data("STEALTH-INTENT-V1\n".utf8)
    private static let supportDirectoryPermissions = mode_t(0o700)
    fileprivate static let markerPermissions = mode_t(0o600)

    static var defaultDirectoryURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true)
    }

    @discardableResult
    static func record() -> Bool {
        guard let directoryURL = defaultDirectoryURL else { return false }
        StealthEntryLatch.shared.raiseInProcess()
        guard publishEntryRequest(inDirectory: directoryURL) else {
            return false
        }
        return record(inDirectory: directoryURL)
    }

    /// The launch authority is deliberately tri-state. Only a path proven not
    /// to exist, or a safely opened support directory in which both fixed
    /// receipts are proven absent, may admit the visible runtime. Any object
    /// that cannot be safely classified keeps the process hidden.
    static func restorationState() -> RestorationState {
        guard let directoryURL = defaultDirectoryURL else {
            StealthEntryLatch.shared.raiseInProcess()
            return .unsafeOrUnreadable
        }
        let state = restorationState(inDirectory: directoryURL)
        if state.requiresHiddenLaunch {
            StealthEntryLatch.shared.raiseInProcess()
        }
        return state
    }

    static func restorationState(
        inDirectory directoryURL: URL
    ) -> RestorationState {
        // Verify every parent component before deciding that a missing final
        // name means "absent". A whole-path lstat can return ENOENT through an
        // intermediate symlink and would otherwise admit a redirected path.
        guard let location = openSupportParentLocation(directoryURL) else {
            return .unsafeOrUnreadable
        }
        defer { close(location.parentDirectoryDescriptor) }

        var pathStatus = stat()
        if fstatat(
            location.parentDirectoryDescriptor,
            location.supportDirectoryName,
            &pathStatus,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            return errno == ENOENT ? .absent : .unsafeOrUnreadable
        }

        guard let directoryDescriptor = openSupportDirectory(
            inParentDirectoryDescriptor:
                location.parentDirectoryDescriptor,
            supportDirectoryName: location.supportDirectoryName,
            createIfMissing: false
        ) else {
            return .unsafeOrUnreadable
        }
        defer { close(directoryDescriptor) }

        let intentState = markerState(
            named: fileName,
            inDirectoryDescriptor: directoryDescriptor,
            contentsPolicy: .exact
        )
        let entryState = markerState(
            named: entryRequestFileName,
            inDirectoryDescriptor: directoryDescriptor,
            contentsPolicy: .prefix
        )

        if intentState == .unsafeOrUnreadable
            || entryState == .unsafeOrUnreadable {
            return .unsafeOrUnreadable
        }
        if intentState == .present || entryState == .present {
            return .present
        }
        return .absent
    }

    static func isRecorded() -> Bool {
        guard let directoryURL = defaultDirectoryURL else { return false }
        return isRecorded(inDirectory: directoryURL)
    }

    @discardableResult
    static func clear() -> Bool {
        StealthExitBoundary.completeVerifiedExit(
            entryLatch: .shared,
            clearExternalIntent: clearExternalReceipts
        )
    }

    /// Removes both durable external entry receipts without changing the
    /// in-process wall. Only `StealthExitBoundary` may lower that wall.
    @discardableResult
    static func clearExternalReceipts() -> Bool {
        guard let directoryURL = defaultDirectoryURL else { return false }
        guard clear(inDirectory: directoryURL),
              clearEntryRequest(inDirectory: directoryURL) else {
            return false
        }
        return true
    }

    @discardableResult
    static func record(inDirectory directoryURL: URL) -> Bool {
        guard let directoryDescriptor = openSupportDirectory(
            directoryURL,
            createIfMissing: true
        ) else {
            return false
        }
        defer { close(directoryDescriptor) }

        var existingStatus = stat()
        if fstatat(
            directoryDescriptor,
            fileName,
            &existingStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard (existingStatus.st_mode & S_IFMT) == S_IFREG else {
                return false
            }
        } else if errno != ENOENT {
            return false
        }

        let temporaryName =
            ".\(fileName).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        let temporaryDescriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            markerPermissions
        )
        guard temporaryDescriptor >= 0 else { return false }

        var shouldRemoveTemporaryFile = true
        defer {
            close(temporaryDescriptor)
            if shouldRemoveTemporaryFile {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        guard secureOwnedRegularFile(
                  temporaryDescriptor,
                  expectedDirectoryStatus: nil
              ),
              writeAll(contents, to: temporaryDescriptor),
              fsync(temporaryDescriptor) == 0,
              renameat(
                  directoryDescriptor,
                  temporaryName,
                  directoryDescriptor,
                  fileName
              ) == 0 else {
            return false
        }
        shouldRemoveTemporaryFile = false
        guard fsync(directoryDescriptor) == 0 else { return false }
        return markerState(
            named: fileName,
            inDirectoryDescriptor: directoryDescriptor,
            contentsPolicy: .exact
        ) == .present
    }

    static func isRecorded(inDirectory directoryURL: URL) -> Bool {
        guard let directoryDescriptor = openSupportDirectory(
            directoryURL,
            createIfMissing: false
        ) else {
            return false
        }
        defer { close(directoryDescriptor) }
        return markerState(
            named: fileName,
            inDirectoryDescriptor: directoryDescriptor,
            contentsPolicy: .exact
        ) == .present
    }

    @discardableResult
    static func clear(
        inDirectory directoryURL: URL,
        syncDirectory: (Int32) -> Int32 = { fsync($0) }
    ) -> Bool {
        guard let directoryDescriptor = openSupportDirectory(
            directoryURL,
            createIfMissing: false
        ) else {
            // Clearing an intent that was never recorded is idempotent.
            return supportDirectoryIsVerifiedAbsent(directoryURL)
        }
        defer { close(directoryDescriptor) }

        var status = stat()
        if fstatat(
            directoryDescriptor,
            fileName,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            return errno == ENOENT
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        guard unlinkat(directoryDescriptor, fileName, 0) == 0 else {
            return false
        }
        // Namespace removal is the exit commit point. If directory fsync fails,
        // a crash can only resurrect the old marker (fail hidden) or preserve
        // the owner's completed removal. Reporting "blocked" after the name is
        // already gone would create the dangerous absent-on-failed-exit state.
        _ = syncDirectory(directoryDescriptor)
        return true
    }

    /// Publishes the fast receipt without following a planted link. Wrappers
    /// treat the mere existence of this fixed name as active, so a conflicting
    /// filesystem object fails closed rather than creating a bypass.
    @discardableResult
    static func publishEntryRequest(inDirectory directoryURL: URL) -> Bool {
        guard let directoryDescriptor = openSupportDirectory(
            directoryURL,
            createIfMissing: true
        ) else {
            return false
        }
        defer { close(directoryDescriptor) }
        return publishEntryRequest(
            inDirectoryDescriptor: directoryDescriptor
        )
    }

    /// Event-tap path. Resolve the support directory name afresh beneath the
    /// pre-opened parent so a rename/replacement cannot split the receipt from
    /// the canonical path detached wrappers inspect.
    @discardableResult
    fileprivate static func publishEntryRequest(
        inPreparedParentDirectoryDescriptor parentDirectoryDescriptor: Int32,
        supportDirectoryName: String
    ) -> Bool {
        guard let directoryDescriptor = openSupportDirectory(
            inParentDirectoryDescriptor: parentDirectoryDescriptor,
            supportDirectoryName: supportDirectoryName,
            createIfMissing: true
        ) else {
            return false
        }
        defer { close(directoryDescriptor) }
        return publishEntryRequest(
            inDirectoryDescriptor: directoryDescriptor
        )
    }

    @discardableResult
    fileprivate static func publishEntryRequest(
        inDirectoryDescriptor directoryDescriptor: Int32
    ) -> Bool {
        var existingStatus = stat()
        if fstatat(
            directoryDescriptor,
            entryRequestFileName,
            &existingStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            // Presence is the fast fail-closed signal used by detached tools.
            // An unsafe object (including a symlink) is therefore already an
            // effective boundary: report success without opening, chmodding,
            // following, or replacing it. The launch tri-state separately
            // classifies that object as unsafe and keeps the app hidden.
            guard (existingStatus.st_mode & S_IFMT) == S_IFREG,
                  existingStatus.st_uid == geteuid(),
                  existingStatus.st_nlink == 1 else {
                return true
            }
            let existingDescriptor = openat(
                directoryDescriptor,
                entryRequestFileName,
                O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            )
            guard existingDescriptor >= 0 else {
                return entryRequestExists(
                    inDirectoryDescriptor: directoryDescriptor
                )
            }
            defer { close(existingDescriptor) }
            if secureOwnedRegularFile(
                existingDescriptor,
                expectedDirectoryStatus: existingStatus
            ) {
                return true
            }
            return entryRequestExists(
                inDirectoryDescriptor: directoryDescriptor
            )
        }
        guard errno == ENOENT else { return false }

        let newDescriptor = openat(
            directoryDescriptor,
            entryRequestFileName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            markerPermissions
        )
        guard newDescriptor >= 0 else { return false }
        defer { close(newDescriptor) }
        guard secureOwnedRegularFile(
            newDescriptor,
            expectedDirectoryStatus: nil
        ) else { return false }

        // Exactly one bounded write. File existence already blocks effects, so
        // a short write is still safe; the durable record repairs persistence.
        _ = contents.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return Darwin.write(newDescriptor, baseAddress, buffer.count)
        }
        return true
    }

    @discardableResult
    static func clearEntryRequest(
        inDirectory directoryURL: URL,
        syncDirectory: (Int32) -> Int32 = { fsync($0) }
    ) -> Bool {
        guard let directoryDescriptor = openSupportDirectory(
            directoryURL,
            createIfMissing: false
        ) else {
            return supportDirectoryIsVerifiedAbsent(directoryURL)
        }
        defer { close(directoryDescriptor) }

        var status = stat()
        if fstatat(
            directoryDescriptor,
            entryRequestFileName,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            return errno == ENOENT
        }
        // `unlinkat(..., 0)` removes a symlink itself, never its target. A
        // directory at the fixed filename is rejected and keeps Stealth raised.
        guard (status.st_mode & S_IFMT) != S_IFDIR,
              unlinkat(directoryDescriptor, entryRequestFileName, 0) == 0 else {
            return false
        }
        // This is the final namespace commit for exit. See clear(inDirectory:):
        // a failed sync may restore a fail-hidden marker after a crash, but it
        // must not turn a completed owner exit into a false "blocked" result.
        _ = syncDirectory(directoryDescriptor)
        return true
    }

    static func entryRequestExists(inDirectory directoryURL: URL) -> Bool {
        guard let directoryDescriptor = openSupportDirectory(
            directoryURL,
            createIfMissing: false
        ) else {
            return false
        }
        defer { close(directoryDescriptor) }
        return entryRequestExists(
            inDirectoryDescriptor: directoryDescriptor
        )
    }

    private static func entryRequestExists(
        inDirectoryDescriptor directoryDescriptor: Int32
    ) -> Bool {
        var status = stat()
        // Any object at the fixed name is active. In particular, a planted or
        // broken symlink cannot turn an entry request into an allow result.
        return fstatat(
            directoryDescriptor,
            entryRequestFileName,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0
    }

    private static func markerState(
        named name: String,
        inDirectoryDescriptor directoryDescriptor: Int32,
        contentsPolicy: MarkerContentsPolicy
    ) -> MarkerState {
        var directoryStatus = stat()
        if fstatat(
            directoryDescriptor,
            name,
            &directoryStatus,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            return errno == ENOENT ? .absent : .unsafeOrUnreadable
        }
        guard (directoryStatus.st_mode & S_IFMT) == S_IFREG,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_nlink == 1 else {
            return .unsafeOrUnreadable
        }

        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else { return .unsafeOrUnreadable }
        defer { close(descriptor) }

        guard secureOwnedRegularFile(
            descriptor,
            expectedDirectoryStatus: directoryStatus
        ) else {
            return .unsafeOrUnreadable
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_size >= 0 else {
            return .unsafeOrUnreadable
        }

        let expectedSize: Int
        switch contentsPolicy {
        case .exact:
            guard status.st_size == off_t(contents.count) else {
                return .unsafeOrUnreadable
            }
            expectedSize = contents.count
        case .prefix:
            guard status.st_size <= off_t(contents.count) else {
                return .unsafeOrUnreadable
            }
            expectedSize = Int(status.st_size)
        }

        var data = Data(count: expectedSize)
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            var total = 0
            while total < buffer.count {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: total),
                    buffer.count - total
                )
                if result > 0 {
                    total += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return -1
                }
            }
            return total
        }
        guard bytesRead == expectedSize else {
            return .unsafeOrUnreadable
        }

        var finalStatus = stat()
        var finalDirectoryStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
              finalStatus.st_dev == status.st_dev,
              finalStatus.st_ino == status.st_ino,
              finalStatus.st_size == status.st_size,
              fstatat(
                  directoryDescriptor,
                  name,
                  &finalDirectoryStatus,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              (finalDirectoryStatus.st_mode & S_IFMT) == S_IFREG,
              finalDirectoryStatus.st_dev == finalStatus.st_dev,
              finalDirectoryStatus.st_ino == finalStatus.st_ino else {
            return .unsafeOrUnreadable
        }

        switch contentsPolicy {
        case .exact:
            return data == contents ? .present : .unsafeOrUnreadable
        case .prefix:
            return contents.prefix(data.count).elementsEqual(data)
                ? .present
                : .unsafeOrUnreadable
        }
    }

    fileprivate struct PreparedExternalReceiptLocation {
        let parentDirectoryDescriptor: Int32
        let supportDirectoryName: String
    }

    /// Performs path traversal and any initial directory creation before the
    /// event tap is installed. Every path component is opened with O_NOFOLLOW;
    /// the returned parent fd lets the callback bind the fixed child name again
    /// on every entry request instead of trusting a stale support-directory inode.
    fileprivate static func prepareExternalReceiptLocation(
        _ directoryURL: URL,
        createIfMissing: Bool
    ) -> PreparedExternalReceiptLocation? {
        guard let location = openSupportParentLocation(directoryURL) else {
            return nil
        }
        guard let supportDescriptor = openSupportDirectory(
            inParentDirectoryDescriptor:
                location.parentDirectoryDescriptor,
            supportDirectoryName: location.supportDirectoryName,
            createIfMissing: createIfMissing
        ) else {
            close(location.parentDirectoryDescriptor)
            return nil
        }
        close(supportDescriptor)
        return location
    }

    fileprivate static func openSupportDirectory(
        _ directoryURL: URL,
        createIfMissing: Bool
    ) -> Int32? {
        guard let location = openSupportParentLocation(directoryURL) else {
            return nil
        }
        defer { close(location.parentDirectoryDescriptor) }
        return openSupportDirectory(
            inParentDirectoryDescriptor:
                location.parentDirectoryDescriptor,
            supportDirectoryName: location.supportDirectoryName,
            createIfMissing: createIfMissing
        )
    }

    private static func openSupportParentLocation(
        _ directoryURL: URL
    ) -> PreparedExternalReceiptLocation? {
        guard directoryURL.isFileURL else { return nil }
        let standardizedURL = directoryURL.standardizedFileURL
        let supportDirectoryName = standardizedURL.lastPathComponent
        guard !supportDirectoryName.isEmpty,
              supportDirectoryName != ".",
              supportDirectoryName != "..",
              !supportDirectoryName.contains("/") else {
            return nil
        }
        let parentURL = standardizedURL.deletingLastPathComponent()
        guard let parentDirectoryDescriptor =
                openDirectoryWithoutFollowingComponents(parentURL) else {
            return nil
        }
        return PreparedExternalReceiptLocation(
            parentDirectoryDescriptor: parentDirectoryDescriptor,
            supportDirectoryName: supportDirectoryName
        )
    }

    private static func openSupportDirectory(
        inParentDirectoryDescriptor parentDirectoryDescriptor: Int32,
        supportDirectoryName: String,
        createIfMissing: Bool
    ) -> Int32? {
        guard !supportDirectoryName.isEmpty,
              supportDirectoryName != ".",
              supportDirectoryName != "..",
              !supportDirectoryName.contains("/") else {
            return nil
        }

        var pathStatus = stat()
        if fstatat(
            parentDirectoryDescriptor,
            supportDirectoryName,
            &pathStatus,
            AT_SYMLINK_NOFOLLOW
        ) != 0 {
            guard createIfMissing, errno == ENOENT else { return nil }
            guard mkdirat(
                parentDirectoryDescriptor,
                supportDirectoryName,
                supportDirectoryPermissions
            ) == 0 || errno == EEXIST else {
                return nil
            }
            guard fstatat(
                parentDirectoryDescriptor,
                supportDirectoryName,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                return nil
            }
        }
        guard (pathStatus.st_mode & S_IFMT) == S_IFDIR,
              pathStatus.st_uid == geteuid() else {
            return nil
        }

        let descriptor = openat(
            parentDirectoryDescriptor,
            supportDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              (openedStatus.st_mode & S_IFMT) == S_IFDIR,
              openedStatus.st_uid == geteuid(),
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino,
              fchmod(descriptor, supportDirectoryPermissions) == 0,
              fstat(descriptor, &openedStatus) == 0,
              (openedStatus.st_mode & mode_t(0o7777))
                  == supportDirectoryPermissions,
              directoryHasNoExtendedACL(descriptor) else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Opens `/a/b/c` one component at a time from `/`; O_NOFOLLOW applies at
    /// every hop, so an intermediate symlink cannot redirect the security
    /// boundary into another owner-controlled tree.
    private static func openDirectoryWithoutFollowingComponents(
        _ directoryURL: URL
    ) -> Int32? {
        guard directoryURL.isFileURL else { return nil }
        var normalizedPath = directoryURL.standardizedFileURL.path
        // macOS exposes these two root-owned compatibility links on every
        // install. Canonicalize only those fixed system aliases; arbitrary
        // intermediate links remain rejected component by component.
        if normalizedPath == "/var" || normalizedPath.hasPrefix("/var/") {
            normalizedPath = "/private" + normalizedPath
        } else if normalizedPath == "/tmp"
                    || normalizedPath.hasPrefix("/tmp/") {
            normalizedPath = "/private" + normalizedPath
        }
        let components = URL(
            fileURLWithPath: normalizedPath,
            isDirectory: true
        ).pathComponents
        guard components.first == "/" else { return nil }

        var currentDescriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard currentDescriptor >= 0 else { return nil }

        for component in components.dropFirst() where component != "/" {
            let nextDescriptor = openat(
                currentDescriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard nextDescriptor >= 0 else {
                close(currentDescriptor)
                return nil
            }
            var status = stat()
            guard fstat(nextDescriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == 0 || status.st_uid == geteuid() else {
                close(nextDescriptor)
                close(currentDescriptor)
                return nil
            }
            close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    private static func directoryHasNoExtendedACL(
        _ descriptor: Int32
    ) -> Bool {
        guard let acl = acl_get_fd_np(
            descriptor,
            ACL_TYPE_EXTENDED
        ) else {
            return errno == ENOENT
        }
        _ = acl_free(UnsafeMutableRawPointer(acl))
        // A nonnil extended ACL is itself unsafe. `acl_get_entry == 0`
        // means an entry was found; treating that as "no ACL" inverted the
        // security predicate and admitted delegated access.
        return false
    }

    fileprivate static func secureOwnedRegularFile(
        _ descriptor: Int32,
        expectedDirectoryStatus: stat?
    ) -> Bool {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            return false
        }
        if let expectedDirectoryStatus {
            guard status.st_dev == expectedDirectoryStatus.st_dev,
                  status.st_ino == expectedDirectoryStatus.st_ino else {
                return false
            }
        }
        guard fchmod(descriptor, markerPermissions) == 0,
              fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              (status.st_mode & mode_t(0o7777)) == markerPermissions else {
            return false
        }
        return true
    }

    fileprivate static func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return data.isEmpty
            }
            var total = 0
            while total < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: total),
                    buffer.count - total
                )
                if result > 0 {
                    total += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func supportDirectoryIsVerifiedAbsent(
        _ directoryURL: URL
    ) -> Bool {
        var status = stat()
        return lstat(directoryURL.standardizedFileURL.path, &status) != 0
            && errno == ENOENT
    }
}

/// The only valid Stealth exit commit: detached wrappers first lose both
/// durable receipts, then the in-process latch is lowered. A failed cleanup
/// leaves the process wall raised and prevents stale provider work resuming.
nonisolated enum StealthExitBoundary {
    @discardableResult
    static func completeVerifiedExit(
        entryLatch: StealthEntryLatch,
        clearExternalIntent: () -> Bool
    ) -> Bool {
        guard clearExternalIntent() else { return false }
        entryLatch.lowerAfterVerifiedExternalClear()
        return true
    }
}

/// Cross-process normal-runtime lease.
///
/// macOS normally coalesces app launches, but recovery deliberately creates a
/// new instance and installers/updaters can overlap processes. Exactly one
/// process may therefore own normal UI/services. A second process stays hidden
/// instead of relying on a finite series of durable-receipt snapshots that can
/// always race a privacy-wall entry in the older process.
nonisolated final class AceRuntimeInstanceLock: @unchecked Sendable {
    static let shared = AceRuntimeInstanceLock()

    private let lock = NSLock()
    private var descriptor: Int32 = -1

    @discardableResult
    func acquire(
        inDirectory directoryURL: URL? =
            StealthDurableIntent.defaultDirectoryURL
    ) -> Bool {
        guard let directoryURL else { return false }
        return lock.withLock {
            if descriptor >= 0 {
                return true
            }
            // Lock the already-verified parent inode, not a file inside the
            // replaceable support child. The entry publisher deliberately
            // tolerates BlackLabel being renamed/recreated; the singleton
            // lease must survive that same replacement without letting a
            // second process lock the new child.
            guard let location =
                    StealthDurableIntent.prepareExternalReceiptLocation(
                        directoryURL,
                        createIfMissing: false
                    ) else {
                return false
            }
            let candidateDescriptor =
                location.parentDirectoryDescriptor
            guard flock(candidateDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(candidateDescriptor)
                return false
            }

            descriptor = candidateDescriptor
            return true
        }
    }

    func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        release()
    }
}

/// The explicit Private Mode recovery process may start while the prior
/// fail-safe Ace process still owns the singleton lease. That hidden process
/// continuously repairs the durable receipts, so clearing them first only
/// creates a short race before Private Mode reappears. Retire only the exact
/// canonical peer that was already hidden, then clear the receipts and let the
/// recovery process acquire the normal-runtime lease.
nonisolated enum ExplicitStealthRestoreRuntimePolicy {
    static func shouldRetire(
        durableStealthWasPresent: Bool,
        candidateProcessIdentifier: Int32,
        currentProcessIdentifier: Int32,
        candidateBundlePath: String?,
        canonicalBundlePath: String,
        candidateIsTerminated: Bool
    ) -> Bool {
        durableStealthWasPresent
            && !candidateIsTerminated
            && candidateProcessIdentifier != currentProcessIdentifier
            && candidateBundlePath == canonicalBundlePath
    }

    static func allPeersHaveExited(
        _ processIdentifiers: [Int32],
        processIsAlive: (Int32) -> Bool
    ) -> Bool {
        processIdentifiers.allSatisfy { !processIsAlive($0) }
    }
}

enum StealthExternalBoundaryFailure: String, Equatable {
    case localWallInactive
    case supportDirectoryUnavailable
    case effectLockUnavailable
    case markerPublicationFailed
}

enum StealthExternalBoundaryStatus: Equatable {
    case inactive
    case pending
    case secured
    case degraded(StealthExternalBoundaryFailure)

    var isSecured: Bool {
        self == .secured
    }
}

/// Deterministic fail-closed transition used when a recovered Stealth process
/// cannot launch its normal replacement. The runtime lease is reacquired
/// before either receipt is republished, so a retiring process never overwrites
/// state owned by another active Ace instance.
nonisolated enum RecoveredStealthRelaunchFailureRecovery {
    enum Outcome: Equatable {
        case anotherRuntimeOwnsLease
        case restored(
            durableIntentRecorded: Bool,
            externalBoundary: StealthExternalBoundaryStatus
        )
    }

    static func restore(
        acquireRuntimeLease: () -> Bool,
        recordDurableIntent: () -> Bool,
        secureExternalBoundary: () -> StealthExternalBoundaryStatus
    ) -> Outcome {
        guard acquireRuntimeLease() else {
            return .anotherRuntimeOwnsLease
        }
        let durableIntentRecorded = recordDurableIntent()
        let externalBoundary = secureExternalBoundary()
        return .restored(
            durableIntentRecorded: durableIntentRecorded,
            externalBoundary: externalBoundary
        )
    }
}

/// Small, deterministic seam around AppKit's window-server operation. The
/// hosted Xcode runner on macOS 27 can crash while releasing a synthetic
/// `NSWindow`; keeping the policy independent lets the fail-closed behavior be
/// exercised without weakening the production AppKit boundary.
@MainActor
protocol StealthVisibilityWindow: AnyObject {
    var isVisible: Bool { get }
    func orderOut(_ sender: Any?)
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension NSWindow: StealthVisibilityWindow {}
#endif // circuit-convert

@MainActor
enum StealthVisibilityWallPolicy {
    static func hideVisibleWindows<Windows: Sequence>(_ windows: Windows)
    where Windows.Element: StealthVisibilityWindow {
        for window in windows where window.isVisible {
            window.orderOut(nil)
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Process-wide visibility wall for UI that is not owned by CompanionManager
/// (update alerts, first-run failures, setup, and other delayed presenters).
/// Main-actor isolation keeps the check and every AppKit presentation ordered.
@MainActor
final class StealthVisibilityGate {
    static let shared = StealthVisibilityGate()

    private(set) var isActive = false
    private(set) var externalBoundaryStatus: StealthExternalBoundaryStatus = .inactive
    private var visibilityObservers: [NSObjectProtocol] = []
    private var ownsExternalEffectLock = false

    private init() {}

    /// The in-process gate is also published for detached helper tools (timers
    /// and notifications) that can outlive the request which launched them.
    /// The file contains this process's PID, so a crash cannot leave stealth
    /// stuck on: helpers additionally prove the PID is still alive.
    private var externalMarkerURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true)
            .appendingPathComponent("stealth-active", isDirectory: false)
    }

    private var externalEffectLockURL: URL? {
        externalMarkerURL?.deletingLastPathComponent()
            .appendingPathComponent("visible-effect.lock", isDirectory: true)
    }

    /// Phase one of entry. This operation performs no filesystem I/O, takes no
    /// cross-process lock, and cannot fail: current windows are removed before
    /// any worker teardown or detached-helper coordination is attempted.
    func activateLocalWall() {
        guard !isActive else {
            enforceVisibilityWall()
            return
        }
        isActive = true
        externalBoundaryStatus = .pending
        NotificationCenter.default.post(name: Notification.Name("AcePrivacyWallRaised"), object: nil)
        installVisibilityObserver()
        enforceVisibilityWall()
    }

    /// Compatibility surface while callers migrate to the explicit two-phase
    /// API. It raises the non-failable local wall first, then makes the bounded
    /// external attempt. It returns true even when that attempt is degraded so
    /// legacy `guard` callers can never lower privacy or resume work on failure.
    @discardableResult
    func activate() -> Bool {
        activateLocalWall()
        _ = secureExternalBoundary()
        return true
    }

    /// Phase two of entry. The local wall must already be active and remains
    /// active on every failure. The caller may log `.degraded`, retry later, or
    /// terminate the app, but must never resume visible/audio/capture work.
    ///
    /// The timeout is monotonic and clamped to two seconds so this API cannot
    /// turn a privacy transition into an unbounded main-thread wait.
    @discardableResult
    func secureExternalBoundary(
        timeout: TimeInterval = 2
    ) -> StealthExternalBoundaryStatus {
        guard isActive else {
            let status: StealthExternalBoundaryStatus =
                .degraded(.localWallInactive)
            externalBoundaryStatus = status
            return status
        }
        guard !isHostedTest else {
            externalBoundaryStatus = .secured
            return .secured
        }
        guard prepareExternalSupportDirectory() else {
            let status: StealthExternalBoundaryStatus =
                .degraded(.supportDirectoryUnavailable)
            externalBoundaryStatus = status
            return status
        }
        guard acquireExternalEffectLock(timeout: timeout) else {
            let status: StealthExternalBoundaryStatus =
                .degraded(.effectLockUnavailable)
            externalBoundaryStatus = status
            return status
        }
        defer { releaseExternalEffectLock() }
        guard publishExternalMarker() else {
            clearExternalMarkerOwnedByThisProcess()
            let status: StealthExternalBoundaryStatus =
                .degraded(.markerPublicationFailed)
            externalBoundaryStatus = status
            return status
        }
        externalBoundaryStatus = .secured
        return .secured
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        externalBoundaryStatus = .inactive
        for observer in visibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        visibilityObservers.removeAll()
        clearExternalMarkerOwnedByThisProcess()
        NotificationCenter.default.post(name: Notification.Name("AcePrivacyWallLowered"), object: nil)
    }

    /// A final containment boundary for new or delayed UI. Feature-level guards
    /// still avoid doing needless work; this observer makes an omitted guard
    /// fail closed by immediately removing the resulting Ace window.
    private func installVisibilityObserver() {
        guard visibilityObservers.isEmpty else { return }
        let visibilityNotifications: [Notification.Name] = [
            NSWindow.didExposeNotification,
            NSWindow.didUpdateNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
        ]
        visibilityObservers = visibilityNotifications.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                // `queue: .main` is a runtime guarantee that this notification
                // executes on the MainActor's executor. Hiding in the same turn
                // prevents a delayed non-key window from flashing for one frame.
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.isActive, window.isVisible else { return }
                    if NSApp.modalWindow === window {
                        NSApp.abortModal()
                    }
                    window.orderOut(nil)
                }
            }
        }
        // AppKit has no public "did order on screen" notification. Its
        // application update notification is the final catch-all after a
        // delayed orderFront/orderWindow call, including non-key windows that
        // never emit didBecomeKey/didBecomeMain.
        visibilityObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didUpdateNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { [weak self] in
                    self?.enforceVisibilityWall()
                }
            }
        )
    }

    private func enforceVisibilityWall() {
        guard isActive else { return }
        if NSApp.modalWindow != nil {
            NSApp.abortModal()
        }
        StealthVisibilityWallPolicy.hideVisibleWindows(NSApp.windows)
    }

    private func publishExternalMarker() -> Bool {
        // Hosted tests activate this singleton too; they must never overwrite
        // the marker owned by a separately running installed Ace.
        guard !isHostedTest else { return true }
        guard let markerURL = externalMarkerURL else { return false }
        guard let directoryDescriptor =
            StealthDurableIntent.openSupportDirectory(
                markerURL.deletingLastPathComponent(),
                createIfMissing: true
            ) else {
            return false
        }
        defer { close(directoryDescriptor) }

        let markerName = markerURL.lastPathComponent
        var existingStatus = stat()
        if fstatat(
            directoryDescriptor,
            markerName,
            &existingStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard (existingStatus.st_mode & S_IFMT) == S_IFREG,
                  existingStatus.st_uid == geteuid(),
                  existingStatus.st_nlink == 1 else {
                return false
            }
        } else if errno != ENOENT {
            return false
        }

        let temporaryName =
            ".\(markerName).\(ProcessInfo.processInfo.processIdentifier)"
                + ".\(UUID().uuidString)"
        let temporaryDescriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            StealthDurableIntent.markerPermissions
        )
        guard temporaryDescriptor >= 0 else { return false }

        var shouldRemoveTemporaryFile = true
        defer {
            close(temporaryDescriptor)
            if shouldRemoveTemporaryFile {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        let ownerReceipt = Data(
            "\(ProcessInfo.processInfo.processIdentifier)\n".utf8
        )
        guard StealthDurableIntent.secureOwnedRegularFile(
                  temporaryDescriptor,
                  expectedDirectoryStatus: nil
              ),
              StealthDurableIntent.writeAll(
                  ownerReceipt,
                  to: temporaryDescriptor
              ),
              fsync(temporaryDescriptor) == 0,
              renameat(
                  directoryDescriptor,
                  temporaryName,
                  directoryDescriptor,
                  markerName
              ) == 0 else {
            return false
        }
        shouldRemoveTemporaryFile = false
        guard fsync(directoryDescriptor) == 0 else { return false }
        return Self.readExternalMarker(
            named: markerName,
            inDirectoryDescriptor: directoryDescriptor
        ) == ownerReceipt
    }

    private func prepareExternalSupportDirectory() -> Bool {
        guard let markerURL = externalMarkerURL else { return false }
        guard let descriptor = StealthDurableIntent.openSupportDirectory(
            markerURL.deletingLastPathComponent(),
            createIfMissing: true
        ) else { return false }
        close(descriptor)
        return true
    }

    private func clearExternalMarkerOwnedByThisProcess() {
        _ = retireExternalMarkerForProcessExit()
    }

    /// Recovery relaunch keeps the local visibility wall raised until this
    /// process terminates, but its detached-helper receipt must be retired
    /// before a normal replacement starts.
    @discardableResult
    func retireExternalMarkerForProcessExit() -> Bool {
        guard !isHostedTest else { return true }
        let lockWasAlreadyOwned = ownsExternalEffectLock
        if !lockWasAlreadyOwned {
            guard acquireExternalEffectLock(timeout: 2) else { return false }
        }
        defer {
            if !lockWasAlreadyOwned {
                releaseExternalEffectLock()
            }
        }
        guard let markerURL = externalMarkerURL else { return false }
        return Self.retireExternalMarker(
            inDirectory: markerURL.deletingLastPathComponent(),
            retiringProcessIdentifier:
                ProcessInfo.processInfo.processIdentifier
        )
    }

    /// Removes the fixed live-PID receipt only when its safely opened contents
    /// still name the process that is retiring. A recovered Stealth process can
    /// therefore clean up before relaunch without deleting a marker already
    /// published by a replacement or overlapping active Ace process.
    @discardableResult
    nonisolated static func retireExternalMarker(
        inDirectory directoryURL: URL,
        retiringProcessIdentifier: Int32
    ) -> Bool {
        guard retiringProcessIdentifier > 0,
              let directoryDescriptor =
                StealthDurableIntent.openSupportDirectory(
                    directoryURL,
                    createIfMissing: false
                ) else {
            return false
        }
        defer { close(directoryDescriptor) }

        let markerName = "stealth-active"
        let expectedOwner = Data(
            "\(retiringProcessIdentifier)\n".utf8
        )
        guard readExternalMarker(
                  named: markerName,
                  inDirectoryDescriptor: directoryDescriptor
              ) == expectedOwner,
              unlinkat(directoryDescriptor, markerName, 0) == 0 else {
            return false
        }
        _ = fsync(directoryDescriptor)
        return true
    }

    nonisolated private static func readExternalMarker(
        named markerName: String,
        inDirectoryDescriptor directoryDescriptor: Int32
    ) -> Data? {
        var directoryStatus = stat()
        guard fstatat(
                  directoryDescriptor,
                  markerName,
                  &directoryStatus,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              (directoryStatus.st_mode & S_IFMT) == S_IFREG,
              directoryStatus.st_uid == geteuid(),
              directoryStatus.st_nlink == 1 else {
            return nil
        }

        let descriptor = openat(
            directoryDescriptor,
            markerName,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard StealthDurableIntent.secureOwnedRegularFile(
            descriptor,
            expectedDirectoryStatus: directoryStatus
        ) else {
            return nil
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_size > 0,
              status.st_size <= 32 else {
            return nil
        }
        var data = Data(count: Int(status.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            var total = 0
            while total < buffer.count {
                let result = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: total),
                    buffer.count - total
                )
                if result > 0 {
                    total += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return -1
                }
            }
            return total
        }
        guard bytesRead == data.count else { return nil }

        var finalStatus = stat()
        var finalDirectoryStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
              finalStatus.st_dev == status.st_dev,
              finalStatus.st_ino == status.st_ino,
              finalStatus.st_size == status.st_size,
              fstatat(
                  directoryDescriptor,
                  markerName,
                  &finalDirectoryStatus,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              (finalDirectoryStatus.st_mode & S_IFMT) == S_IFREG,
              finalDirectoryStatus.st_dev == finalStatus.st_dev,
              finalDirectoryStatus.st_ino == finalStatus.st_ino else {
            return nil
        }
        return data
    }

    /// Serializes detached helper effects (timer banners, notifications) with
    /// Stealth activation. A helper that got the lock first completes before
    /// the mode becomes active; a helper that gets it second sees the marker and
    /// suppresses itself. This removes the check-then-notify race.
    private func acquireExternalEffectLock(timeout: TimeInterval) -> Bool {
        guard !isHostedTest else { return true }
        guard let lockURL = externalEffectLockURL else { return false }
        let ownerURL = lockURL.appendingPathComponent("owner", isDirectory: false)
        let boundedTimeout = min(max(timeout, 0), 2)
        let deadline = ProcessInfo.processInfo.systemUptime + boundedTimeout

        repeat {
            do {
                try FileManager.default.createDirectory(
                    at: lockURL,
                    withIntermediateDirectories: false
                )
                try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
                    .write(to: ownerURL, options: .atomic)
                ownsExternalEffectLock = true
                return true
            } catch {
                guard FileManager.default.fileExists(atPath: lockURL.path) else {
                    return false
                }
                if externalEffectLockIsStale(lockURL: lockURL, ownerURL: ownerURL) {
                    try? FileManager.default.removeItem(at: lockURL)
                    continue
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func externalEffectLockIsStale(lockURL: URL, ownerURL: URL) -> Bool {
        if let rawOwner = try? String(contentsOf: ownerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let ownerProcessIdentifier = Int32(rawOwner),
           ownerProcessIdentifier > 0 {
            return kill(ownerProcessIdentifier, 0) != 0
        }

        let modificationDate = try? lockURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        return modificationDate.map { Date().timeIntervalSince($0) > 5 } ?? false
    }

    private func releaseExternalEffectLock() {
        guard !isHostedTest, ownsExternalEffectLock,
              let lockURL = externalEffectLockURL else { return }
        ownsExternalEffectLock = false
        try? FileManager.default.removeItem(at: lockURL)
    }

    private var isHostedTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
#endif // circuit-convert

nonisolated enum StealthTransitionState: Equatable, Sendable {
    case inactive
    case entering(UUID)
    case active(UUID)
    case exiting(UUID)
}

nonisolated enum StealthVoiceFragmentDecision: Equatable, Sendable {
    case hold
    case route(String)
}

/// Repairs observed Apple Speech tails on the microphone path without
/// broadening Stealth's exact command parser. The on-device recognizer can
/// append “to”, duplicate “steal”, or merge “go stealth” into “ghost”.
/// Only observed whole microphone transcripts are repaired; typed commands,
/// questions, and utterances containing an exit/stop word stay unchanged.
nonisolated enum StealthMicrophoneTranscriptRepair {
    static func canonicalized(_ utterance: String) -> String {
        let normalized = utterance
            .folding(options: [.diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9\s]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "go stealth to", "go stealth steal", "ghost", "ghost style", "ghost up":
            return "go stealth"
        default:
            return utterance
        }
    }
}

/// Recovers a privacy command when push-to-talk or on-device recognition splits
/// “go stealth” across two rapid final transcripts. Only the harmless lead word
/// is held; an unrelated continuation passes through unchanged.
nonisolated struct StealthVoiceFragmentAssembler: Sendable {
    static let maximumGapSeconds: TimeInterval = 4

    private struct Pending: Sendable {
        let original: String
        let admittedAt: TimeInterval
    }

    private var pending: Pending?

    mutating func ingest(
        _ utterance: String,
        at now: TimeInterval
    ) -> StealthVoiceFragmentDecision {
        let original = utterance.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalized = Self.normalized(original)

        if let pending,
           now - pending.admittedAt <= Self.maximumGapSeconds,
           let command = Self.completedCommand(for: normalized) {
            self.pending = nil
            return .route(command)
        }

        pending = nil
        if normalized == "go" {
            pending = Pending(original: original, admittedAt: now)
            return .hold
        }
        return .route(original)
    }

    mutating func takeExpired(at now: TimeInterval) -> String? {
        guard let pending,
              now - pending.admittedAt > Self.maximumGapSeconds else {
            return nil
        }
        self.pending = nil
        return pending.original
    }

    mutating func reset() {
        pending = nil
    }

    private static func completedCommand(
        for fragment: String
    ) -> String? {
        fragment == "stealth" ? "go stealth" : nil
    }

    private static func normalized(_ utterance: String) -> String {
        utterance
            .folding(options: [.diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9\s]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class StealthMode: ObservableObject {

    @Published private(set) var isActive = false
    @Published private(set) var transitionState:
        StealthTransitionState = .inactive
    /// Normal dictation remains closed behind the wall. The explicit exit-only
    /// recognizer is owned separately and never consults this admission bit.
    var allowsMicrophoneCapture: Bool { !isActive }

    @discardableResult
    func beginEntry() -> UUID? {
        guard transitionState == .inactive else { return nil }
        let epoch = UUID()
        transitionState = .entering(epoch)
        isActive = true
        return epoch
    }

    @discardableResult
    func completeEntry(epoch: UUID) -> Bool {
        guard transitionState == .entering(epoch) else { return false }
        transitionState = .active(epoch)
        return true
    }

    @discardableResult
    func beginExit() -> UUID? {
        guard case .active = transitionState else { return nil }
        let epoch = UUID()
        transitionState = .exiting(epoch)
        return epoch
    }

    @discardableResult
    func cancelExit(epoch: UUID) -> Bool {
        guard transitionState == .exiting(epoch) else { return false }
        transitionState = .active(UUID())
        isActive = true
        return true
    }

    @discardableResult
    func completeExit(epoch: UUID) -> Bool {
        guard transitionState == .exiting(epoch) else { return false }
        transitionState = .inactive
        isActive = false
        return true
    }

    func activate() {
        guard let epoch = beginEntry() else { return }
        _ = completeEntry(epoch: epoch)
    }

    func deactivate() {
        guard let epoch = beginExit() else { return }
        _ = completeExit(epoch: epoch)
    }

    // MARK: - Triggers

    @inline(__always)
    private static func normalized(_ utterance: String) -> String {
        let lowered = utterance
            .folding(options: [.diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = lowered.replacingOccurrences(
            of: #"[^a-z0-9\s]"#,
            with: " ",
            options: .regularExpression
        )
        return cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Entry and exit are both whole-command recognizers. A question that
    /// mentions an exit phrase is ordinary conversation and cannot mutate the
    /// privacy wall, microphone, visibility, or work state.
    func isExitTrigger(_ utterance: String) -> Bool {
        StealthExitOnlyPolicy.classify(utterance) == .allowed
    }

    func isEnterTrigger(_ utterance: String) -> Bool {
        let normalizedUtterance = Self.normalized(utterance)
        guard !isExitTrigger(normalizedUtterance) else { return false }
        return normalizedUtterance == "go stealth"
    }
}
