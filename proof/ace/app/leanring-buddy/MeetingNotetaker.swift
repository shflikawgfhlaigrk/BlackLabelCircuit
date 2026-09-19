//
//  MeetingNotetaker.swift
//  Black Label Assistant — the "join the meeting" notetaker.
//
//  Say "take notes" (or "join the meeting") and Ace captures BOTH sides of a
//  meeting: everyone else through system audio (ScreenCaptureKit — the same
//  Screen Recording permission the app already holds) and the user through the
//  microphone. The two streams are mixed into ONE audio stream and transcribed
//  on-device with Apple Speech — macOS allows only one on-device recognition
//  task per process (a second dies instantly with "No speech detected", proven
//  by isolation test 2026-07-17), so a single mixed stream is the design, not a
//  shortcut. On "stop taking notes" the transcript becomes structured notes via
//  the owner's Claude CLI, then appears in a complete review window. Nothing is
//  written to ~/Documents/Ace Meeting Notes/ until the owner
//  clicks the exact save button or says the exact save phrase. Audio capture and speech
//  recognition stay on the Mac; the resulting transcript goes directly through
//  the owner's Claude account for summarization. No bot joins the call
//  and Black Label receives no meeting content.
//

#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
@preconcurrency import AVFoundation
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
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(ScreenCaptureKit) && !CIRCUIT_WINDOWS_SIM
@preconcurrency import ScreenCaptureKit
#endif
#if canImport(Speech) && !CIRCUIT_WINDOWS_SIM
@preconcurrency import Speech
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
import CircuitPortKit

/// Off-MainActor admission wall for raw meeting audio.
///
/// The event-tap Private Mode entry invalidates the current generation synchronously.
/// Producers may finish a bounded conversion they began before that instant,
/// but every handoff revalidates the generation and the final Speech append is
/// serialized with this lock. Exact native AVAudioEngine/ScreenCaptureKit
/// resources register non-waiting cutoffs before start, so X also begins their
/// teardown without waiting for MainActor.
nonisolated final class MeetingAudioStealthBoundary: @unchecked Sendable {
    struct Admission: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private let lock = NSLock()
    private let entryLatch: StealthEntryLatch
    private var generation: UInt64 = 0
    private var acceptsAudio: Bool
    private var synchronousNativeCaptureCutoffs:
        [UUID: @Sendable () -> Void] = [:]

    init(entryLatch: StealthEntryLatch = .shared) {
        self.entryLatch = entryLatch
        self.acceptsAudio = !entryLatch.isRaised
    }

    var isCutOff: Bool {
        lock.withLock {
            !acceptsAudio || entryLatch.isRaised
        }
    }

    func beginAdmission() -> Admission? {
        lock.withLock {
            guard acceptsAudio, !entryLatch.isRaised else {
                invalidateLocked()
                return nil
            }
            return Admission(generation: generation)
        }
    }

    func isCurrent(_ admission: Admission) -> Bool {
        lock.withLock {
            acceptsAudio
                && admission.generation == generation
                && !entryLatch.isRaised
        }
    }

    /// Use only for one bounded local handoff, especially the final
    /// `SFSpeechAudioBufferRecognitionRequest.append`. X either invalidates the
    /// generation first or waits for that single in-process append to return.
    func performIfCurrent<T>(
        _ admission: Admission,
        _ body: () throws -> T
    ) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsAudio,
              admission.generation == generation,
              !entryLatch.isRaised else {
            invalidateLocked()
            return nil
        }
        return try body()
    }

    /// Registers the exact native resource before its start call. If X already
    /// won, the teardown is invoked immediately and the caller receives no
    /// admission. Otherwise X invokes it once without an actor or queue hop.
    func registerSynchronousNativeCaptureCutoff(
        _ cutoff: @escaping @Sendable () -> Void
    ) -> UUID? {
        let identifier = UUID()
        let admitted = lock.withLock {
            guard acceptsAudio, !entryLatch.isRaised else {
                invalidateLocked()
                return false
            }
            synchronousNativeCaptureCutoffs[identifier] = cutoff
            return true
        }
        guard admitted else {
            cutoff()
            return nil
        }
        return identifier
    }

    func unregisterSynchronousNativeCaptureCutoff(_ identifier: UUID?) {
        guard let identifier else { return }
        _ = lock.withLock {
            synchronousNativeCaptureCutoffs.removeValue(forKey: identifier)
        }
    }

    /// Registered directly with StealthEntryLatch. It advances the audio
    /// generation, then issues only bounded non-waiting native stop calls.
    func cutOffSynchronously() {
        let nativeCaptureCutoffs = lock.withLock {
            invalidateLocked()
            let cutoffs = Array(synchronousNativeCaptureCutoffs.values)
            synchronousNativeCaptureCutoffs.removeAll(keepingCapacity: false)
            return cutoffs
        }
        for nativeCaptureCutoff in nativeCaptureCutoffs {
            nativeCaptureCutoff()
        }
    }

    @discardableResult
    func resumeAfterVerifiedExit() -> Bool {
        lock.withLock {
            guard !entryLatch.isRaised else { return false }
            generation &+= 1
            acceptsAudio = true
            return true
        }
    }

    private func invalidateLocked() {
        if acceptsAudio {
            generation &+= 1
            acceptsAudio = false
        }
    }
}

// BEGIN MEETING_STEALTH_BOUNDARY_SUPPORT
/// Result of one small process-side commit ordered against the event-tap entry
/// latch. Callers use this only for bounded in-process publication or one
/// nonblocking pipe write; blocking work never holds the latch.
nonisolated enum MeetingProcessCommitOutcome<Value> {
    case committed(Value)
    case blockedByStealth
}

/// Bounded root/descendant cutoff used directly by event-tap Private Mode entry.
/// Every parent is frozen before its children are inspected, and discovery is
/// capped so this path never launches a helper, reads a pipe, or waits.
nonisolated private enum MeetingProcessTreeCutoff {
    private static let maximumProcessCount = 128

    static func freezeAndKillProcessTree(root: pid_t) {
        guard root > 1 else { return }
        _ = Darwin.kill(root, SIGSTOP)

        var frozenProcessIdentifiers: [pid_t] = [root]
        var inspectionIndex = 0
        while inspectionIndex < frozenProcessIdentifiers.count,
              frozenProcessIdentifiers.count < maximumProcessCount {
            let parentProcessIdentifier =
                frozenProcessIdentifiers[inspectionIndex]
            inspectionIndex += 1

            let remainingCapacity =
                maximumProcessCount - frozenProcessIdentifiers.count
            var childProcessIdentifiers = [pid_t](
                repeating: 0,
                count: remainingCapacity
            )
            let discoveredProcessCount =
                childProcessIdentifiers.withUnsafeMutableBytes {
                    buffer in
                    proc_listchildpids(
                        parentProcessIdentifier,
                        buffer.baseAddress,
                        Int32(buffer.count)
                    )
                }
            guard discoveredProcessCount > 0 else { continue }

            let boundedDiscoveredProcessCount = min(
                Int(discoveredProcessCount),
                remainingCapacity
            )
            for childProcessIdentifier in
                childProcessIdentifiers.prefix(
                    boundedDiscoveredProcessCount
                )
            where childProcessIdentifier > 1 {
                _ = Darwin.kill(childProcessIdentifier, SIGSTOP)
                frozenProcessIdentifiers.append(childProcessIdentifier)
            }
        }

        for processIdentifier in frozenProcessIdentifiers.reversed() {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}

/// Remembers X even when it arrives before `Process.run()` publishes a PID.
/// A late publication is cut off before it can be accepted by its owner.
nonisolated private final class MeetingProcessCutoffState:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let cutoffProcessTree: @Sendable (pid_t) -> Void
    private var publishedProcessIdentifier: pid_t?
    private var wasCutOff = false

    init(
        cutoffProcessTree: @escaping @Sendable (pid_t) -> Void
    ) {
        self.cutoffProcessTree = cutoffProcessTree
    }

    var isCutOff: Bool {
        lock.withLock { wasCutOff }
    }

    @discardableResult
    func publish(processIdentifier: pid_t) -> Bool {
        let shouldCutOff = lock.withLock {
            guard !wasCutOff else { return true }
            publishedProcessIdentifier = processIdentifier
            return false
        }
        if shouldCutOff {
            cutoffProcessTree(processIdentifier)
            return false
        }
        return true
    }

    func clear(processIdentifier: pid_t) {
        lock.withLock {
            if publishedProcessIdentifier == processIdentifier {
                publishedProcessIdentifier = nil
            }
        }
    }

    func cutOffSynchronously() {
        let processIdentifier = lock.withLock { () -> pid_t? in
            wasCutOff = true
            defer { publishedProcessIdentifier = nil }
            return publishedProcessIdentifier
        }
        if let processIdentifier {
            cutoffProcessTree(processIdentifier)
        }
    }
}

/// Per-process launch, publication, stdin, and result boundary for meeting
/// helpers. It registers before any queue hop. Launch and PID publication share
/// the entry latch; transcript input is sent as small nonblocking writes, each
/// independently ordered against that same latch.
nonisolated final class MeetingProcessStealthBoundary:
    @unchecked Sendable
{
    private enum StandardInputWriteOutcome {
        case wrote(Int)
        case retry
        case failed
    }

    private static let maximumStandardInputChunkSize = 4_096
    private static let writablePollMilliseconds: Int32 = 25

    private let entryLatch: StealthEntryLatch
    private let cutoffState: MeetingProcessCutoffState
    private var cutoffRegistration: UUID?

    init(
        entryLatch: StealthEntryLatch = .shared,
        cutoffProcessTree:
            (@Sendable (pid_t) -> Void)? = nil
    ) {
        self.entryLatch = entryLatch
        self.cutoffState = MeetingProcessCutoffState(
            cutoffProcessTree:
                cutoffProcessTree
                ?? { processIdentifier in
                    MeetingProcessTreeCutoff.freezeAndKillProcessTree(
                        root: processIdentifier
                    )
                }
        )
        let cutoffState = self.cutoffState
        cutoffRegistration =
            entryLatch.registerSynchronousEntryCutoff {
                [weak cutoffState] in
                cutoffState?.cutOffSynchronously()
            }
    }

    deinit {
        if let cutoffRegistration {
            entryLatch.unregisterSynchronousEntryCutoff(
                cutoffRegistration
            )
        }
    }

    var isCutOff: Bool {
        cutoffState.isCutOff || entryLatch.isRaised
    }

    /// Permanently closes this exact generation boundary. This is also safe
    /// before a child exists: a later launch attempt observes the cutoff and
    /// cannot publish or receive transcript input.
    func cutOffSynchronously() {
        cutoffState.cutOffSynchronously()
    }

    /// The returned Process must already have completed `run()`. PID
    /// publication and owner publication happen before the entry latch is released.
    func launchAndPublishIfAdmitted(
        launch: () throws -> Process,
        processIdentifier:
            (Process) -> pid_t = { $0.processIdentifier },
        publish: (Process) -> Void
    ) rethrows -> Bool {
        let didLaunchAndPublish =
            try entryLatch.performUnlessRaised {
                guard !cutoffState.isCutOff else { return false }
                let launchedProcess = try launch()
                let launchedProcessIdentifier =
                    processIdentifier(launchedProcess)
                guard cutoffState.publish(
                    processIdentifier: launchedProcessIdentifier
                ) else {
                    return false
                }
                publish(launchedProcess)
                return true
            }
        return didLaunchAndPublish == true
    }

    /// Use only for one bounded in-process commit. In particular, a pipe write
    /// must be nonblocking and no larger than one configured chunk.
    func performBoundedCommitIfAdmitted<Value>(
        _ body: () -> Value
    ) -> MeetingProcessCommitOutcome<Value> {
        entryLatch.performUnlessRaised {
            guard !cutoffState.isCutOff else {
                return .blockedByStealth
            }
            return .committed(body())
        } ?? .blockedByStealth
    }

    /// Writes a potentially large transcript without ever holding the entry latch
    /// across a blocking pipe operation. EAGAIN polling happens outside every
    /// admission; each admitted write is O_NONBLOCK and capped at 4 KiB.
    func writeStandardInputIfAdmitted(
        _ data: Data,
        to fileDescriptor: Int32
    ) -> Bool {
        guard fileDescriptor >= 0 else { return false }
        let originalFlags = fcntl(fileDescriptor, F_GETFL)
        guard originalFlags >= 0,
              fcntl(
                  fileDescriptor,
                  F_SETFL,
                  originalFlags | O_NONBLOCK
              ) == 0 else {
            return false
        }
        guard !data.isEmpty else {
            if case .committed =
                performBoundedCommitIfAdmitted({ true }) {
                return true
            }
            return false
        }

        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return false
            }
            var writtenByteCount = 0
            while writtenByteCount < rawBuffer.count {
                let remainingByteCount =
                    rawBuffer.count - writtenByteCount
                let currentChunkSize = min(
                    remainingByteCount,
                    Self.maximumStandardInputChunkSize
                )
                let outcome =
                    performBoundedCommitIfAdmitted {
                        let writeResult = Darwin.write(
                            fileDescriptor,
                            baseAddress.advanced(
                                by: writtenByteCount
                            ),
                            currentChunkSize
                        )
                        if writeResult > 0 {
                            return StandardInputWriteOutcome.wrote(
                                writeResult
                            )
                        }
                        if writeResult < 0,
                           errno == EAGAIN
                            || errno == EWOULDBLOCK
                            || errno == EINTR {
                            return .retry
                        }
                        return .failed
                    }
                switch outcome {
                case .blockedByStealth:
                    return false
                case .committed(.wrote(let byteCount)):
                    writtenByteCount += byteCount
                case .committed(.retry):
                    var writableDescriptor = pollfd(
                        fd: fileDescriptor,
                        events: Int16(POLLOUT),
                        revents: 0
                    )
                    let pollResult = Darwin.poll(
                        &writableDescriptor,
                        1,
                        Self.writablePollMilliseconds
                    )
                    if pollResult < 0, errno != EINTR {
                        return false
                    }
                case .committed(.failed):
                    return false
                }
            }
            return true
        }
    }

    func clearPublishedProcess(
        processIdentifier: pid_t
    ) {
        cutoffState.clear(
            processIdentifier: processIdentifier
        )
    }
}

/// Atomically publishes and presents the complete meeting-note review. X-first
/// invokes none of the closure; effect-first publishes all callbacks/state and
/// orders the window before the event-tap raise can return.
@MainActor
enum MeetingNotesReviewPresentationAdmission {
    static func commit(
        entryLatch: StealthEntryLatch = .shared,
        visibilityIsBlocked: () -> Bool,
        present: () -> Void
    ) -> Bool {
        guard !visibilityIsBlocked() else { return false }
        return entryLatch.performUnlessRaised {
            guard !visibilityIsBlocked() else { return false }
            present()
            return true
        } == true
    }
}
// END MEETING_STEALTH_BOUNDARY_SUPPORT

// BEGIN MEETING_NOTES_RETRY_BUFFER_SUPPORT
/// One populated capture retained only in process memory when the selected
/// notes provider cannot produce a validated review. It deliberately contains
/// no persistence or encoding API: app exit releases it, and neither defaults,
/// logs, nor a recovery file can receive the raw transcript.
struct PendingMeetingNotesRetryCapture: Equatable, Sendable {
    let identifier: UUID
    let retainedAt: Date
    let expiresAt: Date
    let privacyGeneration: UInt64
    let transcriptText: String
    let startedAt: Date
    let durationMinutes: Int
    let lineCount: Int
    let fileStamp: String
    let sessionIdentifier: String
    let captureGapDescriptions: [String]

    func isCurrent(at date: Date) -> Bool {
        date >= retainedAt && date <= expiresAt
    }
}

enum MeetingNotesRetryDiscardReason: String, Equatable, Sendable {
    case explicitOwnerDiscard
    case expired
    case stealth
    case appExit
    case validatedReviewProduced
}

/// Small value-semantic state machine for the raw, in-memory retry boundary.
/// Generation failure intentionally has no destructive transition. Only a
/// validated review or one of the explicit privacy/lifetime transitions clears
/// the capture.
struct MeetingNotesRetryBuffer: Sendable {
    private(set) var pending: PendingMeetingNotesRetryCapture?
    private(set) var lastDiscardReason: MeetingNotesRetryDiscardReason?
    private(set) var activeGenerationIdentifier: UUID?

    var hasPendingCapture: Bool { pending != nil }
    var generationIsActive: Bool { activeGenerationIdentifier != nil }
    var admitsNewCapture: Bool {
        pending == nil && activeGenerationIdentifier == nil
    }

    @discardableResult
    mutating func retain(_ capture: PendingMeetingNotesRetryCapture) -> Bool {
        guard pending == nil,
              activeGenerationIdentifier == nil else {
            return false
        }
        pending = capture
        lastDiscardReason = nil
        return true
    }

    /// Returns the same immutable session/file identity for every retry. An
    /// unavailable provider leaves the returned capture in `pending`.
    func captureForGeneration(
        expectedIdentifier: UUID? = nil,
        at date: Date
    ) -> PendingMeetingNotesRetryCapture? {
        guard let capture = pending,
              expectedIdentifier == nil
                || capture.identifier == expectedIdentifier else {
            return nil
        }
        guard capture.isCurrent(at: date) else { return nil }
        return capture
    }

    mutating func beginGeneration(
        expectedIdentifier: UUID,
        at date: Date
    ) -> PendingMeetingNotesRetryCapture? {
        guard activeGenerationIdentifier == nil,
              let capture = captureForGeneration(
                expectedIdentifier: expectedIdentifier,
                at: date
              ) else {
            return nil
        }
        activeGenerationIdentifier = capture.identifier
        return capture
    }

    @discardableResult
    mutating func finishGeneration(expectedIdentifier: UUID) -> Bool {
        guard activeGenerationIdentifier == expectedIdentifier else {
            return false
        }
        activeGenerationIdentifier = nil
        return true
    }

    mutating func forceClearGeneration() {
        activeGenerationIdentifier = nil
    }

    @discardableResult
    mutating func discard(
        expectedIdentifier: UUID? = nil,
        reason: MeetingNotesRetryDiscardReason
    ) -> Bool {
        guard let capture = pending,
              expectedIdentifier == nil
                || capture.identifier == expectedIdentifier else {
            return false
        }
        pending = nil
        lastDiscardReason = reason
        return true
    }
}

enum MeetingNotesRetryTerminalDisposition: Equatable, Sendable {
    case completedReview
    case pendingRetry
    case failed
}

enum MeetingNotesRetryTerminalPolicy {
    static func disposition(
        hasGeneratedReview: Bool,
        hasPendingRetry: Bool
    ) -> MeetingNotesRetryTerminalDisposition {
        if hasGeneratedReview { return .completedReview }
        if hasPendingRetry { return .pendingRetry }
        return .failed
    }
}
// END MEETING_NOTES_RETRY_BUFFER_SUPPORT

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated private final class MeetingMicrophoneCutoffBox:
    @unchecked Sendable
{
    private let audioEngine: AVAudioEngine

    init(_ audioEngine: AVAudioEngine) {
        self.audioEngine = audioEngine
    }

    func cutOffSynchronously() {
        audioEngine.stop()
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated private final class MeetingSystemAudioCutoffBox:
    @unchecked Sendable
{
    private let stream: SCStream

    init(_ stream: SCStream) {
        self.stream = stream
    }

    /// The callback form begins teardown and returns immediately. Audio delivery
    /// is independently generation-gated, so no event-tap wait is necessary.
    func cutOffSynchronously() {
        stream.stopCapture(completionHandler: nil)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class MeetingNotetaker: ObservableObject {
    /// True while a meeting is being captured — CompanionManager mirrors this
    /// into the red gem so there is always a visible "Ace is in the meeting" cue.
    @Published private(set) var isTakingNotes = false

    /// Folder for the in-flight session, so an unexpected capture stop can
    /// publish a failure that still points the owner at the right place.
    private var activeNotesFolderPath: String = ""

    /// ScreenCaptureKit ended system-audio capture without us asking. Tell the
    /// owner immediately instead of leaving a panel that claims it is still
    /// recording — the mic half may still be live, so this reports degraded
    /// capture rather than silently continuing to promise both sources.
    func systemAudioCaptureStoppedUnexpectedly(_ error: Error?) {
        guard captureSourceGaps.recordLoss(.systemAudio) else { return }
        let reason = error?.localizedDescription
            ?? "macOS stopped the system-audio capture."
        LifecycleLog.append("NOTES system-audio capture lost — \(reason)")
        result = MeetingNotesResult(
            state: .failed,
            title: "Meeting audio stopped",
            detail: "macOS ended system-audio capture. Sound from other apps "
                + "may be missing from the notes. \(reason) "
                + "Say stop taking notes to review what was captured, then "
                + "start again. The final notes will name this interruption.",
            destinationPath: nil,
            folderPath: activeNotesFolderPath
        )
    }
    @Published private(set) var audioPreflightResult:
        MeetingAudioPreflightResult?
    @Published private(set) var result: MeetingNotesResult?
    private(set) var startFailureMessage: String?
    private(set) var noteTakingStartedAt: Date?

    /// Assigned by CompanionManager so the safety auto-stop can speak its result.
    var speak: ((String) async -> Void)?

    /// Assigned by CompanionManager. Fired ONCE (on the main actor) the moment the
    /// on-device recognizer has refused enough times in a row to be provably deaf —
    /// Siri/Dictation switched off in System Settings, or the speech service wedged —
    /// rather than merely hearing silence. This is the hook that turns the STT
    /// refusal storm (which the brake already collapsed to backoff) into a signal
    /// the founder can perceive: a spoken line + the amber gem cue. It ONLY reports
    /// the condition; it never changes any system setting.
    var onDeafnessDetected: (() -> Void)?

    /// Assigned by CompanionManager. Fired (on the main actor) when a recognizer
    /// that had gone deaf produces real text again — hearing recovered, so the
    /// amber gem cue can drop. Only fires if onDeafnessDetected fired first.
    var onHearingRecovered: (() -> Void)?

    /// Guards the async start window: isTakingNotes only flips true at the END of
    /// start() (after two awaits), so without this a second "take notes" that
    /// arrives during that window would spin up a duplicate capture stack.
    @Published private(set) var isStartingUp = false
    /// Incremented synchronously on every Stealth entry. Async start/stop work
    /// captures the current value and must match it after every suspension
    /// point; lowering the Stealth latch cannot revive work from an older
    /// privacy generation.
    private var privacyGeneration: UInt64 = 0

    struct TranscriptLine {
        let spokenAt: Date
        let text: String
    }
    private var transcriptLines: [TranscriptLine] = []
    private var captureGapDescriptions: [String] = []
    private var captureSourceGaps = MeetingCaptureSourceGaps()
    private var sleepBeganAt: Date?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private var systemAudioStream: SCStream?
    private var systemAudioStreamOutput: SystemAudioStreamOutput?
    private var microphoneEngine: AVAudioEngine?
    /// Resources opened before start() reaches its final commit. They must be
    /// visible to the synchronous Stealth boundary while start() is suspended
    /// in ScreenCaptureKit authorization/discovery/startCapture awaits.
    private var startupSystemAudioStream: SCStream?
    private var startupSystemAudioStreamOutput: SystemAudioStreamOutput?
    private var startupMicrophoneEngine: AVAudioEngine?
    private var microphoneNativeCutoffRegistration: UUID?
    private var systemAudioNativeCutoffRegistration: UUID?
    /// Observes AVAudioEngineConfigurationChange on the mic engine so the tap is
    /// restarted when the audio route/device/format shifts mid-session (otherwise
    /// the mic goes silent for the rest of the meeting — see the handler).
    private var microphoneConfigurationChangeObserver: NSObjectProtocol?
    private var microphoneWasSuspendedForPushToTalk = false
    private var audioMixer: MeetingAudioMixer?
    private var transcriber: ContinuousTranscriber?
    private let audioStealthBoundary: MeetingAudioStealthBoundary
    private var audioStealthCutoffRegistration: UUID?
    /// Hard ceiling so a forgotten notetaker can never record forever.
    private var safetyStopTask: Task<Void, Never>?
    private static let safetyStopSeconds: TimeInterval = 3 * 60 * 60

    var intendedNotesFolderPath: String {
        Self.defaultNotesFolderURL.path
    }

    private static var defaultNotesFolderURL: URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return documents.appendingPathComponent(
            "Ace Meeting Notes",
            isDirectory: true
        )
    }

    private let systemAudioSampleQueue = DispatchQueue(label: "com.blacklabel.assistant.meeting-system-audio")
    private let notesBrainProcess = RunningProcessBox()
    private var nextNotesBrainGeneration: UInt64 = 0
    private var activeNotesBrainGeneration: UInt64?
    private var activeNotesGenerationTask:
        Task<GeneratedMeetingNotes?, Never>?
    private var activeNotesGenerationTaskIdentifier: UUID?
    private var activeNotesGenerationStealthBoundary:
        (identifier: UUID, boundary: MeetingProcessStealthBoundary)?
    private lazy var notesReviewWindow = MeetingNotesReviewWindowController(
        premiumAdmissionIsOpen: premiumAdmissionIsOpen
    )
    private var pendingGeneratedNotesSave: PendingGeneratedNotesSave? {
        didSet {
            hasPendingGeneratedNotesReview = pendingGeneratedNotesSave != nil
        }
    }
    @Published private(set) var hasPendingGeneratedNotesReview = false
    private var pendingGeneratedNotesExpiryTask: Task<Void, Never>?
    private var pendingMeetingNotesRetryBuffer = MeetingNotesRetryBuffer()
    @Published private(set) var hasPendingMeetingNotesRetry = false
    @Published private(set) var pendingMeetingNotesRetryExpiresAt: Date?
    @Published private(set) var isRetryingMeetingNotes = false
    var hasUnsavedNotes: Bool {
        isTakingNotes || isStartingUp || isWindingDown
            || hasPendingGeneratedNotesReview || hasPendingMeetingNotesRetry
            || isRetryingMeetingNotes || activeNotesGenerationTask != nil
    }
    private var pendingMeetingNotesRetryExpiryTask: Task<Void, Never>?
    private let audioSessionCoordinator: AudioSessionCoordinator?
    private let premiumAdmissionIsOpen: @MainActor () -> Bool
    nonisolated private static let pendingGeneratedNotesLifetime: TimeInterval = 5 * 60
    nonisolated private static let pendingMeetingNotesRetryLifetime: TimeInterval =
        30 * 60

    init(
        audioSessionCoordinator: AudioSessionCoordinator? = nil,
        premiumAdmissionIsOpen: @escaping @MainActor () -> Bool = {
            AceEntitlementRuntimeAdmissionGate.shared.admits(.meetingNotes)
        }
    ) {
        self.audioSessionCoordinator = audioSessionCoordinator
        self.premiumAdmissionIsOpen = premiumAdmissionIsOpen
        let boundary = MeetingAudioStealthBoundary()
        audioStealthBoundary = boundary
        audioStealthCutoffRegistration =
            StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                [weak boundary] in
                boundary?.cutOffSynchronously()
            }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recordSystemSleepStarted() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recordSystemWake() }
        }
    }

    deinit {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                sleepObserver
            )
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                wakeObserver
            )
        }
        if let audioStealthCutoffRegistration {
            StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(
                audioStealthCutoffRegistration
            )
        }
        pendingMeetingNotesRetryExpiryTask?.cancel()
        _ = pendingMeetingNotesRetryBuffer.discard(reason: .appExit)
        audioStealthBoundary.cutOffSynchronously()
    }

    private func recordSystemSleepStarted(now: Date = Date()) {
        guard isTakingNotes || isStartingUp else { return }
        if sleepBeganAt == nil { sleepBeganAt = now }
        Self.appendNotesLog(
            "NOTES capture paused — Mac entered sleep"
        )
    }

    private func recordSystemWake(now: Date = Date()) {
        guard let started = sleepBeganAt else { return }
        sleepBeganAt = nil
        let seconds = max(0, Int(now.timeIntervalSince(started)))
        let description =
            "Ace captured no meeting audio while this Mac slept for approximately \(seconds) seconds."
        captureGapDescriptions.append(description)
        Self.appendNotesLog(
            "NOTES capture gap after wake seconds=\(seconds)"
        )
        if isTakingNotes {
            result = MeetingNotesResult(
                state: .failed,
                title: "Meeting capture has a sleep gap",
                detail: description
                    + " Stop and restart Meeting Notes if the meeting is still running; the final review will name this gap.",
                destinationPath: nil,
                folderPath: activeNotesFolderPath
            )
            handleMicrophoneConfigurationChange()
        }
    }

    private struct PendingGeneratedNotesSave {
        let identifier: UUID
        let requestedAt: Date
        let privacyGeneration: UInt64
        let notesMarkdown: String
        let notesFileURL: URL
        let notesFolderURL: URL
        let noteTitle: String
        let spokenLine: String
        let lineCount: Int
        let durationMinutes: Int

        func isCurrent(at date: Date) -> Bool {
            let age = date.timeIntervalSince(requestedAt)
            return age >= 0 && age <= MeetingNotetaker.pendingGeneratedNotesLifetime
        }
    }

    private func canContinueIgnoringEntryLatch(
        privateGeneration: UInt64
    ) -> Bool {
        privacyGeneration == privateGeneration
            && !stealthModeActive
            && !StealthVisibilityGate.shared.isActive
            && premiumAdmissionIsOpen()
    }

    private func canContinue(privateGeneration: UInt64) -> Bool {
        canContinueIgnoringEntryLatch(privateGeneration: privateGeneration)
            && !StealthEntryLatch.shared.isRaised
    }

    private static func shareableContentForMeetingIfAdmitted()
        async throws -> SCShareableContent
    {
        try await withCheckedThrowingContinuation { continuation in
            let didInvoke = StealthEntryLatch.shared.performUnlessRaised {
                SCShareableContent.getExcludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                ) { shareableContent, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let shareableContent {
                        continuation.resume(returning: shareableContent)
                    } else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "MeetingNotetaker",
                                code: -2,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "ScreenCaptureKit returned no shareable content."
                                ]
                            )
                        )
                    }
                }
                return true
            }
            if didInvoke != true {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private static func startCaptureIfAdmitted(_ stream: SCStream)
        async throws
    {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let didInvoke = StealthEntryLatch.shared.performUnlessRaised {
                stream.startCapture { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
                return true
            }
            if didInvoke != true {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    // MARK: - Start

    /// Starts capturing, preserving the actual refusal for the panel and receipt.
    func start() async -> Bool {
        startFailureMessage = nil
        defer {
            if !isTakingNotes,
               !isStartingUp,
               pendingGeneratedNotesSave == nil,
               !hasPendingMeetingNotesRetry,
               let startFailureMessage {
                result = .failed(
                    folderPath: intendedNotesFolderPath,
                    detail: startFailureMessage
                )
            }
        }
        guard premiumAdmissionIsOpen() else {
            startFailureMessage = "Meeting Notes needs an active Ace account. Open Account to check activation."
            Self.appendNotesLog("NOTES start refused (activation required)")
            return false
        }
        // CompanionManager can queue this call and enter stealth before the task
        // receives MainActor time. The persistent latch is the authority at the
        // capture boundary: a queued start must not raise Speech/Screen Recording
        // consent or open either audio source after Ace has disappeared.
        guard !StealthEntryLatch.shared.isRaised,
              !stealthModeActive,
              !StealthVisibilityGate.shared.isActive else {
            startFailureMessage = "Exit Private Mode before starting Meeting Notes."
            Self.appendNotesLog("NOTES start refused (stealth)")
            return false
        }
        let startPrivacyGeneration = privacyGeneration
        // isTakingNotes flips true only at the very end of this method, after two
        // MainActor-releasing awaits. Both this guard and the caller's read it
        // while it is still false, so a second concurrent "take notes" would run
        // start() to completion too — spinning up a second SCStream + engine +
        // transcriber and orphaning the first. isStartingUp closes that window
        // synchronously (this class is @MainActor, so check+set is atomic).
        guard !isTakingNotes,
              !isStartingUp,
              !isWindingDown,
              pendingGeneratedNotesSave == nil,
              pendingMeetingNotesRetryBuffer.admitsNewCapture else {
            startFailureMessage = isWindingDown
                ? "The previous notes session is still wrapping up."
                : "Review or retry the previous meeting notes before starting another capture."
            Self.appendNotesLog(
                "NOTES start refused (taking=\(isTakingNotes) starting=\(isStartingUp) "
                    + "stopping=\(isWindingDown) "
                    + "pendingReview=\(pendingGeneratedNotesSave != nil) "
                    + "pendingRetry=\(pendingMeetingNotesRetryBuffer.hasPendingCapture) "
                    + "retrying=\(pendingMeetingNotesRetryBuffer.generationIsActive))")
            // A start already in flight WILL succeed — report true so the
            // caller doesn't speak a false "couldn't start" over it.
            return isTakingNotes || isStartingUp
        }
        audioPreflightResult = nil
        if let visibleFailure = audioSessionCoordinator?
            .acquireCapture(.meetingNotes).visibleFailure {
            startFailureMessage = visibleFailure
            Self.appendNotesLog(
                "NOTES start refused by audio owner — "
                    + Self.logSafe(visibleFailure)
            )
            return false
        }
        var keepsAudioClaim = false
        defer {
            if !keepsAudioClaim {
                _ = audioSessionCoordinator?
                    .withdrawCapture(.meetingNotes)
            }
        }
        isStartingUp = true
        defer { isStartingUp = false }

        let speechAuthorization = SFSpeechRecognizer.authorizationStatus()
        if speechAuthorization == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let didRequest = StealthEntryLatch.shared
                    .performUnlessRaised {
                        SFSpeechRecognizer.requestAuthorization { _resolvedStatus in
                            continuation.resume()
                        }
                        return true
                    }
                if didRequest != true {
                    continuation.resume()
                }
            }
        }
        guard canContinue(privateGeneration: startPrivacyGeneration),
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            startFailureMessage = canContinue(privateGeneration: startPrivacyGeneration)
                ? "Allow Speech Recognition for Ace in System Settings, then start Meeting Notes again."
                : "Meeting Notes startup was cancelled."
            Self.appendNotesLog("START refused — speech recognition not authorized")
            return false
        }

        transcriptLines = []
        captureGapDescriptions = []
        captureSourceGaps.discard()
        sleepBeganAt = nil
        let audioBoundary = audioStealthBoundary
        let newTranscriber = ContinuousTranscriber(
            audioStealthBoundary: audioBoundary
        ) { [weak self] text, spokenAt in
            Task { @MainActor in
                guard let self,
                      self.canContinue(privateGeneration: startPrivacyGeneration),
                      self.isTakingNotes || self.isWindingDown else { return }
                self.transcriptLines.append(TranscriptLine(spokenAt: spokenAt, text: text))
            }
        }
        // Bridge the transcriber's refusal-streak signals (raised on its own work
        // queue) up to the main actor, where CompanionManager owns the spoken line
        // and the gem. Both are one-shot per streak inside the transcriber.
        newTranscriber.onDeafnessStreakDetected = { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.canContinue(privateGeneration: startPrivacyGeneration),
                      self.isTakingNotes else { return }
                self.onDeafnessDetected?()
            }
        }
        newTranscriber.onHearingRecovered = { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.canContinue(privateGeneration: startPrivacyGeneration),
                      self.isTakingNotes else { return }
                self.onHearingRecovered?()
            }
        }

        // Everyone else's side, from system audio. Video is captured at the
        // cheapest possible setting because SCK requires it; only the audio
        // output is consumed. (Never set backgroundColor here — it crashes.)
        //
        // Preflight the Screen Recording grant the way the rest of the app
        // does. Without it a TCC denial arrived as a generic SCK throw and was
        // written to notes.log as one line, indistinguishable from "no display
        // available" — so the session continued on the owner's mic alone and
        // nobody else on the call was recorded, with no prompt, no Settings
        // link, and no way to fix it mid-meeting.
        let screenRecordingIsAuthorized = CGPreflightScreenCaptureAccess()
        if !screenRecordingIsAuthorized {
            Self.appendNotesLog(
                "SYSTEM-AUDIO unavailable — Screen Recording is not granted"
            )
            LifecycleLog.append(
                "NOTES Screen Recording not granted — other participants will "
                + "not be recorded"
            )
        }
        var systemAudioStarted = false
        var stagedStream: SCStream?
        var stagedStreamOutput: SystemAudioStreamOutput?
        var stagedSystemAudioNativeCutoffRegistration: UUID?
        do {
            guard screenRecordingIsAuthorized else {
                throw NSError(
                    domain: "MeetingNotetaker",
                    code: -2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Screen Recording is not granted, so system audio "
                            + "cannot be captured",
                    ]
                )
            }
            let shareableContent =
                try await Self.shareableContentForMeetingIfAdmitted()
            guard canContinue(privateGeneration: startPrivacyGeneration) else {
                throw CancellationError()
            }
            guard let display = shareableContent.displays.first else {
                throw NSError(domain: "MeetingNotetaker", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "no display available for system-audio capture"])
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            let streamOutput = SystemAudioStreamOutput(
                audioStealthBoundary: audioBoundary
            )
            // Wire the delegate. `delegate: nil` meant a stream macOS stopped
            // was never reported, so a dead capture looked identical to a
            // healthy one for the rest of the meeting.
            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: streamOutput
            )
            try stream.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: systemAudioSampleQueue)
            // A screen output must be attached too — without one, some macOS
            // versions never deliver audio buffers. The handler drops the frames.
            try stream.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: systemAudioSampleQueue)
            stagedStream = stream
            stagedStreamOutput = streamOutput
            startupSystemAudioStream = stream
            startupSystemAudioStreamOutput = streamOutput
            let streamCutoffBox = MeetingSystemAudioCutoffBox(stream)
            guard let cutoffRegistration =
                audioBoundary.registerSynchronousNativeCaptureCutoff({
                    streamCutoffBox.cutOffSynchronously()
                }) else {
                throw CancellationError()
            }
            stagedSystemAudioNativeCutoffRegistration =
                cutoffRegistration
            guard canContinue(privateGeneration: startPrivacyGeneration) else {
                throw CancellationError()
            }
            try await Self.startCaptureIfAdmitted(stream)
            guard canContinue(privateGeneration: startPrivacyGeneration) else {
                try? await stream.stopCapture()
                throw CancellationError()
            }
            systemAudioStarted = true
        } catch {
            Self.appendNotesLog("ERROR system-audio capture failed: \(error.localizedDescription)")
            if let stream = stagedStream {
                try? await stream.stopCapture()
            }
            stagedStream = nil
            stagedStreamOutput = nil
            startupSystemAudioStream = nil
            startupSystemAudioStreamOutput = nil
            audioBoundary.unregisterSynchronousNativeCaptureCutoff(
                stagedSystemAudioNativeCutoffRegistration
            )
            stagedSystemAudioNativeCutoffRegistration = nil
        }

        // ScreenCaptureKit can switch Bluetooth into its low-rate input route.
        // Create the microphone graph only AFTER that asynchronous transition;
        // the pre-capture format becomes stale across startCapture.
        // The user's side, from the microphone. A separate engine from the
        // push-to-talk one — macOS allows multiple readers on the input device,
        // so hold-to-talk keeps working mid-meeting.
        var microphoneStarted = false
        // Ask macOS for the microphone grant BEFORE staging an engine. This
        // path never checked it, unlike every other capture surface in the app.
        // With the mic denied, `engine.start()` still succeeds and the tap
        // delivers pure silence, so `microphoneStarted` went true, the peak
        // read 0, preflight called it "silent" rather than unavailable, and Ace
        // announced "Taking notes." while capturing nothing from the owner. Pair
        // that with Screen Recording denied and a whole meeting records with
        // BOTH sources dead while the panel says it is working.
        let microphoneAuthorization =
            AVCaptureDevice.authorizationStatus(for: .audio)
        let microphoneIsAuthorized = microphoneAuthorization == .authorized
        if !microphoneIsAuthorized {
            Self.appendNotesLog(
                "MIC unavailable for meeting notes — authorization="
                + "\(microphoneAuthorization.rawValue)"
            )
            LifecycleLog.append(
                "NOTES microphone not authorized — your side will not be recorded"
            )
        }
        let engine = AVAudioEngine()
        let microphoneFormat = engine.inputNode.outputFormat(forBus: 0)
        var stagedMicrophoneEngine: AVAudioEngine?
        var stagedMicrophoneNativeCutoffRegistration: UUID?
        if microphoneIsAuthorized,
           microphoneFormat.sampleRate > 0, microphoneFormat.channelCount > 0 {
            let microphoneCutoffBox = MeetingMicrophoneCutoffBox(engine)
            if let cutoffRegistration =
                audioBoundary.registerSynchronousNativeCaptureCutoff({
                    microphoneCutoffBox.cutOffSynchronously()
                }) {
                stagedMicrophoneNativeCutoffRegistration =
                    cutoffRegistration
                stagedMicrophoneEngine = engine
                startupMicrophoneEngine = engine
                do {
                    let didStart = try StealthEntryLatch.shared
                        .performUnlessRaised {
                            engine.prepare()
                            try engine.start()
                            return true
                        }
                    guard didStart == true,
                          canContinue(
                            privateGeneration: startPrivacyGeneration
                          ) else {
                        throw CancellationError()
                    }
                    microphoneStarted = true
                } catch {
                    engine.stop()
                    audioBoundary
                        .unregisterSynchronousNativeCaptureCutoff(
                            stagedMicrophoneNativeCutoffRegistration
                        )
                    stagedMicrophoneNativeCutoffRegistration = nil
                    stagedMicrophoneEngine = nil
                    startupMicrophoneEngine = nil
                    Self.appendNotesLog(
                        "ERROR microphone engine failed: "
                            + error.localizedDescription
                    )
                }
            }
        } else {
            Self.appendNotesLog("ERROR no usable microphone input format")
        }

        guard canContinue(privateGeneration: startPrivacyGeneration),
              microphoneStarted || systemAudioStarted else {
            if !canContinue(privateGeneration: startPrivacyGeneration) {
                startFailureMessage = "Meeting Notes startup was cancelled."
            } else if !microphoneIsAuthorized && !screenRecordingIsAuthorized {
                startFailureMessage = "Allow Microphone or Screen Recording for Ace, then start Meeting Notes again."
            } else {
                startFailureMessage = "The available audio sources did not start. Check your microphone connection and audio device, then retry Meeting Notes."
            }
            if let engine = stagedMicrophoneEngine { engine.stop() }
            if let stream = stagedStream { try? await stream.stopCapture() }
            audioBoundary.unregisterSynchronousNativeCaptureCutoff(
                stagedMicrophoneNativeCutoffRegistration
            )
            audioBoundary.unregisterSynchronousNativeCaptureCutoff(
                stagedSystemAudioNativeCutoffRegistration
            )
            newTranscriber.cancelAndDiscardSynchronously()
            startupMicrophoneEngine = nil
            startupSystemAudioStream = nil
            startupSystemAudioStreamOutput = nil
            return false
        }

        // One mixed stream feeds ONE recognition task (see header). The mixer
        // pairs both sources sample-for-sample and hands mixed buffers on.
        let mixerMode: MeetingAudioMixer.Mode = (microphoneStarted && systemAudioStarted)
            ? .both : (microphoneStarted ? .microphoneOnly : .systemOnly)
        let mixer = MeetingAudioMixer(
            mode: mixerMode,
            audioStealthBoundary: audioBoundary
        ) { mixedBuffer in
            newTranscriber.append(mixedBuffer)
        }
        let microphoneLevelMeter = MeetingAudioLevelMeter()
        let systemAudioLevelMeter = MeetingAudioLevelMeter()
        stagedStreamOutput?.onMonoSamples = { samples in
            systemAudioLevelMeter.observe(samples)
            mixer.pushSystem(samples)
        }
        // Surface a stream macOS killed. Logging it is not enough: the owner is
        // looking at a panel that says "Taking Notes" and has no reason to
        // suspect the room stopped being recorded.
        stagedStreamOutput?.onStreamStopped = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.isTakingNotes else { return }
                self.systemAudioCaptureStoppedUnexpectedly(error)
            }
        }
        if microphoneStarted, let engine = stagedMicrophoneEngine {
            // nil asks Core Audio to use the input bus's current format.
            // Passing a cached format throws an Objective-C exception when a
            // Bluetooth route changes; Swift do/catch cannot catch that.
            let didInstallMicrophoneTap =
                StealthEntryLatch.shared.performUnlessRaised {
                    engine.inputNode.installTap(
                        onBus: 0,
                        bufferSize: 4096,
                        format: nil
                    ) { buffer, _ in
                        guard let admission =
                                audioBoundary.beginAdmission(),
                              let samples = monoSamples(
                                from: buffer,
                                resampledTo:
                                    MeetingAudioMixer.mixSampleRate
                              ),
                              audioBoundary.isCurrent(admission) else {
                            return
                        }
                        microphoneLevelMeter.observe(samples)
                        mixer.pushMicrophone(samples)
                    }
                    return true
                }
            if didInstallMicrophoneTap == true,
               canContinue(
                privateGeneration: startPrivacyGeneration
               ) {
                microphoneConfigurationChangeObserver =
                    NotificationCenter.default.addObserver(
                        forName: .AVAudioEngineConfigurationChange,
                        object: engine,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in
                            self?.handleMicrophoneConfigurationChange()
                        }
                    }
            }
        }

        // Do not claim recording is live until both native sources have had a
        // bounded chance to produce real levels. Silence is allowed, but it is
        // surfaced by source instead of being mistaken for a healthy signal.
        try? await Task.sleep(for: .milliseconds(650))
        guard canContinue(privateGeneration: startPrivacyGeneration) else {
            startFailureMessage = "Meeting Notes startup was cancelled."
            if let engine = stagedMicrophoneEngine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            if let stream = stagedStream {
                try? await stream.stopCapture()
            }
            newTranscriber.cancelAndDiscardSynchronously()
            return false
        }
        let preflight = MeetingAudioPreflight.evaluate(
            microphoneAvailable: microphoneStarted,
            microphonePeak: microphoneLevelMeter.peak,
            systemAudioAvailable: systemAudioStarted,
            systemAudioPeak: systemAudioLevelMeter.peak
        )
        guard preflight.canStart else {
            startFailureMessage = preflight.summary
            return false
        }
        audioPreflightResult = preflight
        result = .recording(
            folderPath: intendedNotesFolderPath,
            sourceSummary: preflight.summary
        )
        activeNotesFolderPath = intendedNotesFolderPath

        let didCommit = StealthEntryLatch.shared.performUnlessRaised {
            microphoneEngine = stagedMicrophoneEngine
            systemAudioStream = stagedStream
            systemAudioStreamOutput = stagedStreamOutput
            microphoneNativeCutoffRegistration =
                stagedMicrophoneNativeCutoffRegistration
            systemAudioNativeCutoffRegistration =
                stagedSystemAudioNativeCutoffRegistration
            startupMicrophoneEngine = nil
            startupSystemAudioStream = nil
            startupSystemAudioStreamOutput = nil
            audioMixer = mixer
            transcriber = newTranscriber
            noteTakingStartedAt = Date()
            isTakingNotes = true
            return true
        }
        guard didCommit == true else {
            startFailureMessage = "Meeting Notes startup was cancelled."
            if let observer = microphoneConfigurationChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                microphoneConfigurationChangeObserver = nil
            }
            if let engine = stagedMicrophoneEngine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            if let stream = stagedStream {
                try? await stream.stopCapture()
            }
            audioBoundary.unregisterSynchronousNativeCaptureCutoff(
                stagedMicrophoneNativeCutoffRegistration
            )
            audioBoundary.unregisterSynchronousNativeCaptureCutoff(
                stagedSystemAudioNativeCutoffRegistration
            )
            startupMicrophoneEngine = nil
            startupSystemAudioStream = nil
            startupSystemAudioStreamOutput = nil
            newTranscriber.cancelAndDiscardSynchronously()
            return false
        }
        keepsAudioClaim = true
        Self.appendNotesLog("NOTES START mic=\(microphoneStarted) system=\(systemAudioStarted) mode=\(mixerMode)")

        // A stop arrived while we were still coming up — honor it now rather
        // than leaving a session running that the user already ended.
        if stopRequestedDuringStartup {
            stopRequestedDuringStartup = false
            Self.appendNotesLog("NOTES START honoring stop-requested-during-startup — tearing down")
            Task { _ = await self.stopAndProduceNotes() }
            return true
        }

        safetyStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.safetyStopSeconds))
            guard let self,
                  !Task.isCancelled,
                  self.canContinue(privateGeneration: startPrivacyGeneration),
                  self.isTakingNotes else { return }
            Self.appendNotesLog("SAFETY auto-stop after \(Int(Self.safetyStopSeconds))s")
            let spokenSummary = await self.stopAndProduceNotes()
            guard !Task.isCancelled,
                  self.canContinue(privateGeneration: startPrivacyGeneration),
                  !spokenSummary.isEmpty else { return }
            await self.speak?("that meeting ran three hours, so i wrapped up the notes. \(spokenSummary)")
        }
        return true
    }

    // MARK: - Push-to-talk coexistence

    /// macOS allows exactly ONE on-device recognition task per process. The
    /// notetaker holds one continuously; a push-to-talk press would start a
    /// second, and the two kill each other ("No speech detected"), dropping both
    /// the meeting words and the user's command. While the user holds the hotkey
    /// mid-meeting, hand the single recognition slot to dictation: end the
    /// notetaker's request and stop feeding it audio. The mixer keeps buffering,
    /// and the transcriber retains a bounded system-audio window during the hold,
    /// so asking Ace a question does not erase what the other participants said.
    func pauseRecognitionForPushToTalk() {
        transcriber?.pauseForPushToTalk()
        guard let engine = microphoneEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        microphoneWasSuspendedForPushToTalk = true
        Self.appendNotesLog(
            "MIC suspended — Push to Talk owns the shared audio session"
        )
    }

    /// Push-to-talk finished: the notetaker reclaims the recognition slot. The
    /// next voiced buffer spins up a fresh generation (same path as a natural
    /// pause). A no-op when not taking notes.
    func resumeRecognitionAfterPushToTalk() {
        transcriber?.resumeAfterPushToTalk()
        guard microphoneWasSuspendedForPushToTalk else { return }
        microphoneWasSuspendedForPushToTalk = false
        guard audioSessionCoordinator?.snapshot.captureOwner
                == .meetingNotes || audioSessionCoordinator == nil else {
            Self.appendNotesLog(
                "MIC resume refused — Meeting Notes does not own audio"
            )
            return
        }
        handleMicrophoneConfigurationChange()
    }

    // MARK: - Audio configuration changes

    /// The mic AVAudioEngine stopped delivering because the audio configuration
    /// changed (default input device switched, a device connected/disconnected, or
    /// the hardware sample rate shifted). Reinstall the tap with the CURRENT input
    /// format and restart the engine so the microphone keeps feeding the mixer for
    /// the rest of the meeting. A no-op when not taking notes.
    private func handleMicrophoneConfigurationChange() {
        guard isTakingNotes,
              !microphoneWasSuspendedForPushToTalk,
              audioSessionCoordinator == nil
                || audioSessionCoordinator?.snapshot.captureOwner == .meetingNotes,
              !StealthEntryLatch.shared.isRaised,
              !audioStealthBoundary.isCutOff,
              microphoneNativeCutoffRegistration != nil,
              let engine = microphoneEngine,
              let mixer = audioMixer else { return }
        let currentMicrophoneFormat = engine.inputNode.outputFormat(forBus: 0)
        guard currentMicrophoneFormat.sampleRate > 0, currentMicrophoneFormat.channelCount > 0 else {
            Self.appendNotesLog("MIC config-change — no usable input format, mic capture paused until it returns")
            recordMicrophoneCaptureFailure("The microphone has no usable input format.")
            return
        }
        let audioBoundary = audioStealthBoundary
        guard let restartAdmission = audioBoundary.beginAdmission() else {
            return
        }
        do {
            let didRestart = try StealthEntryLatch.shared
                .performUnlessRaised {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.inputNode.installTap(
                        onBus: 0,
                        bufferSize: 4096,
                        format: nil
                    ) { buffer, _ in
                        guard let admission = audioBoundary.beginAdmission(),
                              let samples = monoSamples(
                                from: buffer,
                                resampledTo:
                                    MeetingAudioMixer.mixSampleRate
                              ),
                              audioBoundary.isCurrent(admission) else {
                            return
                        }
                        mixer.pushMicrophone(samples)
                    }
                    if !engine.isRunning {
                        engine.prepare()
                        try engine.start()
                    }
                    return true
                }
            guard didRestart == true,
                  audioBoundary.isCurrent(restartAdmission) else {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                return
            }
        } catch {
            Self.appendNotesLog(
                "MIC config-change restart FAILED: "
                + error.localizedDescription
            )
            recordMicrophoneCaptureFailure(error.localizedDescription)
            return
        }
        captureSourceGaps.recordRecovery(.microphone)
        Self.appendNotesLog("MIC config-change — engine restarted, tap reinstalled (rate=\(Int(currentMicrophoneFormat.sampleRate)) ch=\(currentMicrophoneFormat.channelCount))")
    }

    private func recordMicrophoneCaptureFailure(_ reason: String) {
        guard captureSourceGaps.recordLoss(.microphone) else { return }
        result = MeetingNotesResult(
            state: .failed,
            title: "Meeting microphone interrupted",
            detail: "Microphone capture stopped. \(reason) Check the microphone "
                + "connection or select an available input device. Say stop taking "
                + "notes to review what was captured. The final notes will name "
                + "this interruption.",
            destinationPath: nil,
            folderPath: activeNotesFolderPath
        )
    }

    // MARK: - Stop → notes

    /// True while stopAndProduceNotes is mid-teardown. start() must refuse during
    /// this window: on 2026-07-17 a stop and a delegate-intercept start
    /// interleaved — stop flipped isTakingNotes false, the start saw "idle" and
    /// spun up a SECOND capture session that then ran unattended.
    @Published private(set) var isWindingDown = false

    /// True while start() is mid-flight (SCK + engines coming up, several
    /// seconds). Routes read this so a stop that lands DURING startup isn't
    /// treated as "not taking notes" and lost — the session would then run
    /// orphaned with no voice able to stop it.
    /// True while a stop is mid-teardown — a start request in this window is
    /// deferred with an honest "still wrapping up" rather than the misleading
    /// "couldn't start, check permissions" (observed battery3, 23:17:41Z).
    /// Set by the routes when the user says stop while start() is still
    /// mid-flight. start() honors it as its last step: the freshly started
    /// session is immediately torn down instead of running orphaned.
    var stopRequestedDuringStartup = false

    /// Stops capture, generates a validated in-memory review, and returns the
    /// sentence to speak. Persistence requires a later exact owner confirmation.
    func stopAndProduceNotes() async -> String {
        guard isTakingNotes,
              !stealthModeActive,
              !StealthVisibilityGate.shared.isActive else {
            return stealthModeActive || StealthVisibilityGate.shared.isActive
                ? "" : "i wasn't taking notes."
        }
        let stopPrivacyGeneration = privacyGeneration
        isTakingNotes = false
        _ = audioSessionCoordinator?.withdrawCapture(.meetingNotes)
        isWindingDown = true
        defer { isWindingDown = false }
        // Logged BEFORE the async teardown awaits so a hang between here and
        // the NOTES STOP line is visible in the log instead of a silent gap.
        Self.appendNotesLog("NOTES STOPPING")
        safetyStopTask?.cancel()
        safetyStopTask = nil
        let startedAt = noteTakingStartedAt ?? Date()
        noteTakingStartedAt = nil

        if let observer = microphoneConfigurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            microphoneConfigurationChangeObserver = nil
        }
        if let engine = microphoneEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        microphoneEngine = nil
        microphoneWasSuspendedForPushToTalk = false
        audioStealthBoundary.unregisterSynchronousNativeCaptureCutoff(
            microphoneNativeCutoffRegistration
        )
        microphoneNativeCutoffRegistration = nil
        if let stream = systemAudioStream {
            try? await stream.stopCapture()
        }
        systemAudioStream = nil
        systemAudioStreamOutput = nil
        audioStealthBoundary.unregisterSynchronousNativeCaptureCutoff(
            systemAudioNativeCutoffRegistration
        )
        systemAudioNativeCutoffRegistration = nil
        guard canContinue(privateGeneration: stopPrivacyGeneration) else {
            transcriptLines = []
            return ""
        }
        // Await the flush so its tail buffer is enqueued onto the transcriber's
        // workQueue BEFORE finish() enqueues isStopped=true. finish() posts
        // directly to that queue while flush hops mixer.queue → transcriber, so
        // without awaiting, isStopped wins the race and append() drops the tail
        // (the flush was effectively dead — the meeting's last sliver was lost).
        if let mixer = audioMixer {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                mixer.flush { continuation.resume() }
            }
        }
        audioMixer = nil
        guard canContinue(privateGeneration: stopPrivacyGeneration) else {
            transcriptLines = []
            return ""
        }

        // Let the recognizer deliver its final chunk before reading the lines.
        await transcriber?.finish()
        transcriber = nil
        try? await Task.sleep(for: .seconds(0.3))
        guard canContinue(privateGeneration: stopPrivacyGeneration) else {
            transcriptLines = []
            return ""
        }

        let orderedLines = transcriptLines.sorted { $0.spokenAt < $1.spokenAt }
        transcriptLines = []
        if let sleepBeganAt {
            let seconds = max(
                0,
                Int(Date().timeIntervalSince(sleepBeganAt))
            )
            captureGapDescriptions.append(
                "Ace captured no meeting audio while this Mac slept for approximately \(seconds) seconds."
            )
            self.sleepBeganAt = nil
        }
        let captureGapContext = captureGapDescriptions + captureSourceGaps.descriptions
        captureGapDescriptions = []
        captureSourceGaps.discard()
        guard !orderedLines.isEmpty else {
            Self.appendNotesLog("NOTES STOP — transcript empty")
            result = .noTranscript(
                folderPath: intendedNotesFolderPath
            )
            return "i was listening, but i didn't catch any words to write down."
        }

        let durationMinutes = max(1, Int(Date().timeIntervalSince(startedAt) / 60))
        var transcriptText = orderedLines
            .map { "[\(Self.clockTimeFormatter.string(from: $0.spokenAt))] \($0.text)" }
            .joined(separator: "\n")
        if !captureGapContext.isEmpty {
            transcriptText += "\n\nSYSTEM CAPTURE GAPS (app-observed; not spoken meeting content):\n"
                + captureGapContext.map { "[ACE CAPTURE GAP] " + $0 }
                    .joined(separator: "\n")
        }

        let notesFolder = Self.defaultNotesFolderURL
        let sessionIdentifier = UUID().uuidString.lowercased()
        let fileStamp = Self.fileStampFormatter.string(from: startedAt)
            + " " + String(sessionIdentifier.prefix(8))
        let retainedAt = Date()
        let retryCapture = PendingMeetingNotesRetryCapture(
            identifier: UUID(),
            retainedAt: retainedAt,
            expiresAt: retainedAt.addingTimeInterval(
                Self.pendingMeetingNotesRetryLifetime
            ),
            privacyGeneration: stopPrivacyGeneration,
            transcriptText: transcriptText,
            startedAt: startedAt,
            durationMinutes: durationMinutes,
            lineCount: orderedLines.count,
            fileStamp: fileStamp,
            sessionIdentifier: sessionIdentifier,
            captureGapDescriptions: captureGapContext
        )
        guard retainPendingMeetingNotesRetry(retryCapture) else {
            Self.appendNotesLog(
                "NOTES RETRY retain refused — an earlier capture is pending"
            )
            return "the previous meeting capture is still waiting for a notes retry."
        }
        return await produceValidatedReviewFromPendingMeetingNotesRetry(
            expectedIdentifier: retryCapture.identifier
        )
    }

    // MARK: - Raw capture retry boundary

    private func retainPendingMeetingNotesRetry(
        _ capture: PendingMeetingNotesRetryCapture
    ) -> Bool {
        guard pendingMeetingNotesRetryBuffer.retain(capture) else {
            return false
        }
        publishPendingMeetingNotesRetryState()
        schedulePendingMeetingNotesRetryExpiry(for: capture)
        Self.appendNotesLog(
            "NOTES RETRY retained in-memory lines=\(capture.lineCount) "
                + "duration=\(capture.durationMinutes)m"
        )
        return true
    }

    private func publishPendingMeetingNotesRetryState() {
        hasPendingMeetingNotesRetry =
            pendingMeetingNotesRetryBuffer.hasPendingCapture
        pendingMeetingNotesRetryExpiresAt =
            pendingMeetingNotesRetryBuffer.pending?.expiresAt
        isRetryingMeetingNotes =
            pendingMeetingNotesRetryBuffer.generationIsActive
    }

    private func schedulePendingMeetingNotesRetryExpiry(
        for capture: PendingMeetingNotesRetryCapture
    ) {
        pendingMeetingNotesRetryExpiryTask?.cancel()
        let pendingIdentifier = capture.identifier
        let secondsUntilExpiry = max(
            0,
            capture.expiresAt.timeIntervalSinceNow
        )
        pendingMeetingNotesRetryExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(secondsUntilExpiry))
            guard let self, !Task.isCancelled else { return }
            self.discardPendingMeetingNotesRetry(
                expectedIdentifier: pendingIdentifier,
                reason: .expired
            )
        }
    }

    private func pendingRetryInstruction() -> String {
        "i stopped listening and kept the captured meeting only in memory. "
            + "connect or choose Codex or Claude, then click retry notes and "
            + "flashcards or say retry notes and flashcards. no file was created."
    }

    private func qwenNotIncludedRetryInstruction() -> String {
        "Qwen is not included in Build 101; choose Codex or Claude, then retry Notes & Flashcards."
    }

    private func publishPendingRetryResult() {
        guard pendingMeetingNotesRetryBuffer.hasPendingCapture else { return }
        result = .generationPending(
            folderPath: intendedNotesFolderPath
        )
    }

    @discardableResult
    private func expirePendingMeetingNotesRetryIfNeeded(
        at date: Date
    ) -> Bool {
        guard let pending = pendingMeetingNotesRetryBuffer.pending,
              !pending.isCurrent(at: date) else {
            return false
        }
        discardPendingMeetingNotesRetry(
            expectedIdentifier: pending.identifier,
            reason: .expired
        )
        return true
    }

    private func missingPendingRetryInstruction() -> String {
        switch pendingMeetingNotesRetryBuffer.lastDiscardReason {
        case .expired:
            return "that in-memory meeting capture expired. no file was created."
        case .explicitOwnerDiscard, .stealth, .appExit,
             .validatedReviewProduced:
            return ""
        case nil:
            return "there is no captured meeting waiting for a notes retry."
        }
    }

    func retryPendingMeetingNotes() async -> String {
        guard premiumAdmissionIsOpen(),
              !StealthEntryLatch.shared.isRaised,
              !stealthModeActive,
              !StealthVisibilityGate.shared.isActive else {
            return ""
        }
        guard let identifier = pendingMeetingNotesRetryBuffer.pending?
            .identifier else {
            return "there is no captured meeting waiting for a notes retry."
        }
        guard pendingGeneratedNotesSave == nil else {
            return "review the generated meeting notes before retrying another capture."
        }
        return await produceValidatedReviewFromPendingMeetingNotesRetry(
            expectedIdentifier: identifier
        )
    }

    @discardableResult
    func discardPendingMeetingNotesRetryFromOwner() -> Bool {
        discardPendingMeetingNotesRetry(
            expectedIdentifier: nil,
            reason: .explicitOwnerDiscard
        )
    }

    static func isPendingMeetingNotesRetryVoiceRequest(
        _ utterance: String
    ) -> Bool {
        let phrases: Set<String> = [
            "retry notes and flashcards",
            "retry meeting notes",
            "retry the meeting notes",
            "retry my meeting notes",
            "retry the notes and flashcards",
        ]
        return phrases.contains(normalizedPendingRetryUtterance(utterance))
    }

    static func isPendingMeetingNotesDiscardVoiceRequest(
        _ utterance: String
    ) -> Bool {
        let phrases: Set<String> = [
            "discard pending meeting capture",
            "discard the pending meeting capture",
            "discard meeting notes retry",
            "discard the meeting notes retry",
            "discard captured meeting",
            "discard the captured meeting",
        ]
        return phrases.contains(normalizedPendingRetryUtterance(utterance))
    }

    private static func normalizedPendingRetryUtterance(
        _ utterance: String
    ) -> String {
        var normalized = utterance
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        while let last = normalized.last,
              last == "." || last == "!" || last == "?" {
            normalized.removeLast()
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func discardPendingMeetingNotesRetry(
        expectedIdentifier: UUID?,
        reason: MeetingNotesRetryDiscardReason
    ) -> Bool {
        guard pendingMeetingNotesRetryBuffer.discard(
            expectedIdentifier: expectedIdentifier,
            reason: reason
        ) else {
            return false
        }
        pendingMeetingNotesRetryExpiryTask?.cancel()
        pendingMeetingNotesRetryExpiryTask = nil
        publishPendingMeetingNotesRetryState()
        if reason != .validatedReviewProduced {
            cancelActiveNotesGeneration()
            let didExpire = reason == .expired
            result = MeetingNotesResult(
                state: didExpire ? .failed : .cancelled,
                title: didExpire
                    ? "Meeting capture expired"
                    : "Pending capture discarded",
                detail: didExpire
                    ? "The in-memory retry window ended. No file was created."
                    : "The in-memory meeting capture was discarded. No file was created.",
                destinationPath: nil,
                folderPath: intendedNotesFolderPath
            )
        }
        Self.appendNotesLog(
            "NOTES RETRY cleared reason=\(reason.rawValue)"
        )
        return true
    }

    private func cancelActiveNotesGeneration() {
        if let activeBoundary = activeNotesGenerationStealthBoundary {
            activeBoundary.boundary.cutOffSynchronously()
            activeNotesGenerationStealthBoundary = nil
        }
        activeNotesGenerationTask?.cancel()
        activeNotesGenerationTask = nil
        activeNotesGenerationTaskIdentifier = nil
        if let processGeneration = activeNotesBrainGeneration {
            activeNotesBrainGeneration = nil
            notesBrainProcess.terminate(generation: processGeneration)
        }
    }

    private func produceValidatedReviewFromPendingMeetingNotesRetry(
        expectedIdentifier: UUID
    ) async -> String {
        guard !isRetryingMeetingNotes else {
            return "notes and flashcards generation is already running."
        }
        if expirePendingMeetingNotesRetryIfNeeded(at: Date()) {
            return missingPendingRetryInstruction()
        }
        guard let retryCapture = pendingMeetingNotesRetryBuffer
            .beginGeneration(
                expectedIdentifier: expectedIdentifier,
                at: Date()
            ) else {
            publishPendingMeetingNotesRetryState()
            return missingPendingRetryInstruction()
        }
        publishPendingMeetingNotesRetryState()
        defer {
            _ = pendingMeetingNotesRetryBuffer.finishGeneration(
                expectedIdentifier: retryCapture.identifier
            )
            publishPendingMeetingNotesRetryState()
        }

        if BrainBackend.selectedCLI == .qwen {
            publishPendingRetryResult()
            Self.appendNotesLog(
                "NOTES RETRY blocked; Qwen is not included in Build 101"
            )
            return qwenNotIncludedRetryInstruction()
        }

        nextNotesBrainGeneration &+= 1
        let notesBrainGeneration = nextNotesBrainGeneration
        activeNotesBrainGeneration = notesBrainGeneration
        let notesBrainStealthBoundary = MeetingProcessStealthBoundary()
        let notesBrainProcessBox = notesBrainProcess
        let generationTaskIdentifier = retryCapture.identifier
        activeNotesGenerationStealthBoundary = (
            identifier: generationTaskIdentifier,
            boundary: notesBrainStealthBoundary
        )
        let generationTask = Task {
            await Self.generateNotes(
                transcriptText: retryCapture.transcriptText,
                startedAt: retryCapture.startedAt,
                durationMinutes: retryCapture.durationMinutes,
                processBox: notesBrainProcessBox,
                processGeneration: notesBrainGeneration,
                processStealthBoundary: notesBrainStealthBoundary
            )
        }
        activeNotesGenerationTask = generationTask
        activeNotesGenerationTaskIdentifier = generationTaskIdentifier
        let generatedNotes = await generationTask.value
        if activeNotesGenerationTaskIdentifier == generationTaskIdentifier {
            activeNotesGenerationTask = nil
            activeNotesGenerationTaskIdentifier = nil
            if activeNotesGenerationStealthBoundary?.identifier
                == generationTaskIdentifier {
                activeNotesGenerationStealthBoundary = nil
            }
        }
        if activeNotesBrainGeneration == notesBrainGeneration {
            activeNotesBrainGeneration = nil
        }

        guard privacyGeneration == retryCapture.privacyGeneration,
              !StealthEntryLatch.shared.isRaised,
              !stealthModeActive,
              !StealthVisibilityGate.shared.isActive else {
            return ""
        }
        guard premiumAdmissionIsOpen() else {
            publishPendingRetryResult()
            return pendingRetryInstruction()
        }
        if expirePendingMeetingNotesRetryIfNeeded(at: Date()) {
            return missingPendingRetryInstruction()
        }
        guard pendingMeetingNotesRetryBuffer.captureForGeneration(
            expectedIdentifier: expectedIdentifier,
            at: Date()
        ) != nil else {
            publishPendingMeetingNotesRetryState()
            return missingPendingRetryInstruction()
        }
        guard let generatedNotes else {
            publishPendingRetryResult()
            Self.appendNotesLog(
                "NOTES RETRY generation unavailable; in-memory capture retained"
            )
            return pendingRetryInstruction()
        }

        let notesFolder = Self.defaultNotesFolderURL
        let notesFileURL = notesFolder.appendingPathComponent(
            "\(retryCapture.fileStamp) notes.md"
        )
        let noteTitle =
            "Notes — \(Self.displayStampFormatter.string(from: retryCapture.startedAt))"
            + " — \(String(retryCapture.sessionIdentifier.prefix(8)))"
        let pendingIdentifier = UUID()
        let reviewMarkdown = MeetingNotesGenerationPolicy.reviewMarkdown(
            generatedNotes,
            captureGapDescriptions: retryCapture.captureGapDescriptions
        )
        let pending = PendingGeneratedNotesSave(
            identifier: pendingIdentifier,
            requestedAt: Date(),
            privacyGeneration: retryCapture.privacyGeneration,
            notesMarkdown: reviewMarkdown,
            notesFileURL: notesFileURL,
            notesFolderURL: notesFolder,
            noteTitle: noteTitle,
            spokenLine: generatedNotes.spokenLine,
            lineCount: retryCapture.lineCount,
            durationMinutes: retryCapture.durationMinutes
        )
        let didPresentReview = notesReviewWindow.present(
            title: noteTitle,
            notesMarkdown: reviewMarkdown,
            destinationPath: notesFileURL.path,
            expiresAt: pending.requestedAt.addingTimeInterval(
                Self.pendingGeneratedNotesLifetime
            ),
            onAdmitted: {
                self.pendingGeneratedNotesSave = pending
                self.discardPendingMeetingNotesRetry(
                    expectedIdentifier: retryCapture.identifier,
                    reason: .validatedReviewProduced
                )
            },
            onSave: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    let result = await self.savePendingGeneratedNotes(
                        expectedIdentifier: pendingIdentifier
                    )
                    if !result.isEmpty {
                        await self.speak?(result)
                    }
                }
            },
            onCancel: { [weak self] in
                self?.discardPendingGeneratedNotes(
                    expectedIdentifier: pendingIdentifier,
                    reason: "explicit review cancellation"
                )
            },
            onClose: {
                Self.appendNotesLog(
                    "NOTES REVIEW window hidden; pending retained"
                )
            }
        )
        guard didPresentReview else {
            if pendingMeetingNotesRetryBuffer.hasPendingCapture {
                publishPendingRetryResult()
                Self.appendNotesLog(
                    "NOTES REVIEW presentation unavailable; retry retained"
                )
                return pendingRetryInstruction()
            }
            return ""
        }
        result = .reviewUnsaved(destinationPath: notesFileURL.path)
        guard canContinue(
            privateGeneration: retryCapture.privacyGeneration
        ) else {
            discardPendingGeneratedNotes(
                expectedIdentifier: pendingIdentifier,
                reason: "stealth entered after review admission"
            )
            return ""
        }
        pendingGeneratedNotesExpiryTask?.cancel()
        pendingGeneratedNotesExpiryTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(Self.pendingGeneratedNotesLifetime)
            )
            guard let self, !Task.isCancelled else { return }
            self.discardPendingGeneratedNotes(
                expectedIdentifier: pendingIdentifier,
                reason: "review expired"
            )
        }
        Self.appendNotesLog(
            "NOTES REVIEW staged lines=\(retryCapture.lineCount) "
                + "duration=\(retryCapture.durationMinutes)m "
                + "contentChars=\(generatedNotes.notesMarkdown.count)"
        )
        return generatedNotes.spokenLine
            + " i opened the complete review. nothing has been saved yet. "
            + "read it, then click save these notes, or say save the "
            + "notes within five minutes. the exact local "
            + "destination is shown in the review."
    }

    // MARK: - Generated-notes review boundary

    /// A model can propose meeting-note text, but it cannot choose the fixed
    /// local persistence sink. The pending value stays only in memory and is cleared
    /// by expiry, cancellation, a replacement meeting, or Stealth.
    /// Deliberately narrower than generic confirmation grammar. A stray "yes"
    /// cannot save a transcript, but the visible pending review gives definite
    /// phrases such as "save the note" an exact referent.
    static func isGeneratedNotesSaveConfirmation(_ utterance: String) -> Bool {
        MeetingNotesReviewIntentPolicy.isExplicitSave(utterance)
    }

    func discardPendingGeneratedNotesReview(reason: String) {
        discardPendingGeneratedNotes(
            expectedIdentifier: pendingGeneratedNotesSave?.identifier,
            reason: reason
        )
    }

    func savePendingGeneratedNotesAfterExactVoiceConfirmation() async -> String {
        guard premiumAdmissionIsOpen(),
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else {
            return ""
        }
        guard let identifier = pendingGeneratedNotesSave?.identifier else {
            return "there are no meeting notes waiting to be saved."
        }
        return await savePendingGeneratedNotes(expectedIdentifier: identifier)
    }

    @discardableResult
    func reopenPendingGeneratedNotesReview() -> Bool {
        guard premiumAdmissionIsOpen(),
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive,
              let pending = pendingGeneratedNotesSave else {
            return false
        }
        guard pending.isCurrent(at: Date()) else {
            discardPendingGeneratedNotes(
                expectedIdentifier: pending.identifier,
                reason: "review expired before reopen"
            )
            return false
        }
        let pendingIdentifier = pending.identifier
        return notesReviewWindow.present(
            title: pending.noteTitle,
            notesMarkdown: pending.notesMarkdown,
            destinationPath: pending.notesFileURL.path,
            expiresAt: pending.requestedAt.addingTimeInterval(
                Self.pendingGeneratedNotesLifetime
            ),
            onAdmitted: {
                self.pendingGeneratedNotesSave = pending
            },
            onSave: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    let result = await self.savePendingGeneratedNotes(
                        expectedIdentifier: pendingIdentifier
                    )
                    if !result.isEmpty {
                        await self.speak?(result)
                    }
                }
            },
            onCancel: { [weak self] in
                self?.discardPendingGeneratedNotes(
                    expectedIdentifier: pendingIdentifier,
                    reason: "explicit review cancellation"
                )
            },
            onClose: {
                Self.appendNotesLog(
                    "NOTES REVIEW window hidden; pending retained"
                )
            }
        )
    }

    private func discardPendingGeneratedNotes(
        expectedIdentifier: UUID?,
        reason: String
    ) {
        guard let pending = pendingGeneratedNotesSave,
              expectedIdentifier == nil || pending.identifier == expectedIdentifier else {
            return
        }
        pendingGeneratedNotesSave = nil
        pendingGeneratedNotesExpiryTask?.cancel()
        pendingGeneratedNotesExpiryTask = nil
        notesReviewWindow.dismiss()
        result = .cancelled(
            destinationPath: pending.notesFileURL.path
        )
        Self.appendNotesLog(
            "NOTES REVIEW discarded reason=\(Self.logSafe(reason))")
    }

    private func savePendingGeneratedNotes(
        expectedIdentifier: UUID
    ) async -> String {
        guard let pending = pendingGeneratedNotesSave,
              pending.identifier == expectedIdentifier else {
            return "those meeting notes are no longer waiting to be saved."
        }
        guard canContinue(privateGeneration: pending.privacyGeneration) else {
            Self.appendNotesLog(
                "NOTES REVIEW save refused — Stealth entry or privacy generation changed")
            return ""
        }

        // Consume before the first effect. A duplicated voice transcript or
        // double-click cannot replay the local write.
        pendingGeneratedNotesSave = nil
        pendingGeneratedNotesExpiryTask?.cancel()
        pendingGeneratedNotesExpiryTask = nil
        notesReviewWindow.dismiss()

        guard pending.isCurrent(at: Date()) else {
            Self.appendNotesLog("NOTES REVIEW save refused — expired")
            return "that meeting-notes review expired. nothing was saved."
        }
        var localNotesSaved = false
        do {
            // Directory creation and the whole-note write can block on the
            // filesystem, so they must never hold the event-tap entry latch. Stage a
            // private same-directory inode first; the disclosed destination
            // remains absent until the final atomic no-overwrite rename.
            guard canContinue(privateGeneration: pending.privacyGeneration) else {
                return ""
            }
            try FileManager.default.createDirectory(
                at: pending.notesFolderURL,
                withIntermediateDirectories: true
            )
            guard canContinue(privateGeneration: pending.privacyGeneration) else {
                return ""
            }
            let preparedFile =
                try MeetingReviewedNotesFileWriter.prepareNewFile(
                    Data(pending.notesMarkdown.utf8),
                    to: pending.notesFileURL,
                    in: pending.notesFolderURL
                )
            guard canContinue(privateGeneration: pending.privacyGeneration) else {
                return ""
            }

            // The event-tap-observed Private Mode press raises this latch on the tap thread.
            // Only the bounded rename is serialized with it: either the reviewed
            // destination exists before X, or X wins and the staged inode is
            // removed without ever appearing at the disclosed path.
            let committed = try StealthEntryLatch.shared.performUnlessRaised {
                guard canContinueIgnoringEntryLatch(
                    privateGeneration: pending.privacyGeneration
                ) else {
                    return false
                }
                return try preparedFile.commitNewFile(ifAdmitted: {
                    self.canContinueIgnoringEntryLatch(
                        privateGeneration: pending.privacyGeneration
                    )
                })
            }
            localNotesSaved = committed == true
        } catch {
            Self.appendNotesLog(
                "ERROR reviewed meeting-notes commit failed: "
                    + Self.logSafe(error.localizedDescription))
        }

        guard canContinue(privateGeneration: pending.privacyGeneration) else {
            return ""
        }

        // The pending review is consumed before the first effect, deliberately,
        // so a duplicate transcript or double-click cannot replay the write.
        // That also means this markdown exists NOWHERE else once we leave this
        // scope — so a failed commit used to destroy the meeting outright, and
        // the owner was told only that it could not be verified. Replay
        // protection is worth keeping; losing hours of capture to a transient
        // filesystem error is not. Stage a recovery copy beside the logs, which
        // are already proven writable, so a failure costs a move and not the
        // meeting. This runs after the privacy guard above, so Stealth still
        // suppresses it.
        var recoveryPath: String?
        if !localNotesSaved,
           let supportDirectory = AceTranscript.supportDirectory() {
            let recoveryURL = supportDirectory.appendingPathComponent(
                "unsaved-meeting-notes-\(pending.identifier.uuidString).md"
            )
            do {
                try Data(pending.notesMarkdown.utf8).write(
                    to: recoveryURL, options: [.atomic]
                )
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: recoveryURL.path
                )
                recoveryPath = recoveryURL.path
                Self.appendNotesLog(
                    "NOTES RECOVERY staged after failed commit")
            } catch {
                Self.appendNotesLog(
                    "ERROR meeting-notes recovery copy failed: "
                        + Self.logSafe(error.localizedDescription))
            }
        }

        Self.appendNotesLog(
            "NOTES SAVED lines=\(pending.lineCount) "
                + "duration=\(pending.durationMinutes)m "
                + "localFileSaved=\(localNotesSaved)")

        result = localNotesSaved
            ? .saved(destinationPath: pending.notesFileURL.path)
            : .failed(
                folderPath: pending.notesFolderURL.path,
                detail: recoveryPath.map {
                    "The reviewed note could not be verified on disk. No saved-file claim was made. An unsaved copy is at \($0)."
                } ?? "The reviewed note could not be verified on disk. No saved-file claim was made, and no recovery copy could be written."
            )

        let savedLocations: String
        if localNotesSaved {
            savedLocations =
                "the reviewed notes are saved at \(pending.notesFileURL.path)."
        } else if let recoveryPath {
            savedLocations =
                "i could not verify the local file, so i am not claiming the notes were stored — but i kept an unsaved copy at \(recoveryPath)."
        } else {
            savedLocations =
                "i could not verify the local file, so i am not claiming the notes were stored."
        }
        return pending.spokenLine + " " + savedLocations
    }

    // MARK: - Notes generation (isolated selected brain)

    nonisolated static func resolvedCodexArguments(
        executablePath: String,
        resolveCodexModel:
            @escaping @Sendable (String) async throws -> String = {
                try await BrainBackend.resolveCodexModel(
                    executablePath: $0
                )
            }
    ) async throws -> [String] {
        let resolvedModel = try await resolveCodexModel(executablePath)
        var arguments = BrainBackend.codexSandboxedArguments(
            resolvedModel: resolvedModel
        )
        // A read-only sandbox still permits tool discovery and extra model
        // turns. Notes only transforms the supplied capture, so give it the
        // same tool isolation as an answer and an explicit summary budget.
        arguments.removeLast()
        arguments += InteractiveProviderLatencyPolicy
            .codexAnswerDisabledFeatures.flatMap { ["--disable", $0] }
        arguments += [
            "-c", "web_search=\"disabled\"",
            "-c", "model_reasoning_effort=\"medium\"",
            "-",
        ]
        return arguments
    }

    /// Returns only structurally valid, transcript-grounded notes. The caller
    /// owns the raw in-memory retry buffer across provider/auth failure; this
    /// generator never persists it or turns it into a saveable fallback document.
    private static func generateNotes(
        transcriptText: String,
        startedAt: Date,
        durationMinutes: Int,
        processBox: RunningProcessBox,
        processGeneration: UInt64,
        processStealthBoundary:
            MeetingProcessStealthBoundary
    ) async -> GeneratedMeetingNotes? {
        guard !Task.isCancelled,
              !processStealthBoundary.isCutOff else {
            return nil
        }
        // Pure text summarization gets no model tools. Missing, failed, or
        // malformed output fails closed without minting a persistence path.
        let selectedCLI = BrainBackend.selectedCLI
        let brainExecutablePath = AceBrainRoute.current == .customerOwned
            ? BrainBackend.resolveExecutable(for: selectedCLI)
            : nil
        if AceBrainRoute.current == .customerOwned,
           brainExecutablePath == nil {
            appendNotesLog("ERROR selected brain unavailable for notes generation")
            return nil
        }

        let minimumNotesCharacterCount =
            MeetingNotesGenerationPolicy.minimumNotesCharacterCount(
                forTranscriptCharacterCount: transcriptText.count
            )
        let prompt = """
        \(AceLanguage.current.responseInstruction)
        Retain the exact required section headings below; write the section contents in the chosen language.

        You are a meticulous class and meeting notetaker. Turn the transcript below into complete notes that are genuinely useful after a lecture, lesson, workshop, interview, or meeting.

        The transcript is ONE mixed stream of everyone in the meeting, including the user, in spoken order — speaker labels are not available, so infer who said what from context only when it's obvious. Ignore lines that are clearly the assistant itself speaking — it is called Ace and says things like "on it", "i'm taking notes", or "ace, online".

        Rules: never invent facts, names, numbers, decisions, or action items that are not in the transcript. Mark unresolved or ambiguous points as unclear instead of silently dropping substantive discussion. Speech-to-text noise is normal — read through it. Never reproduce the raw transcript or any timestamped transcript lines. Lines beginning [ACE CAPTURE GAP] are app-observed missing-audio intervals, not speech; name every one under Risks and blockers and never imply the missing interval was captured.

        Thoroughness requirements:
        - First determine whether the capture is primarily a lecture/lesson or a meeting/discussion. Write the capture type in the metadata.
        - For a lecture or lesson, write study-ready notes that teach the material back to the reader. State the actual concepts and explanations instead of repeatedly saying that "the speaker discussed" them.
        - Preserve the lecture's topic order, definitions, relationships between ideas, reasoning steps, instructor emphasis, contrasts, examples, evidence, equations, variable meanings, units, dates, names, references, assignments, deadlines, and likely testable points whenever supported.
        - For a meeting, capture every substantive topic, decision, proposal, objection, rationale, example, constraint, dependency, risk, question, and commitment supported by the transcript.
        - Scale the detail to the capture. A long or dense lecture needs correspondingly long notes, not an executive recap. For this transcript the full markdown note must contain at least \(minimumNotesCharacterCount) characters unless the transcript genuinely contains less supported information.
        - Separate explicit decisions from ideas that were only proposed or discussed. Preserve dissent, tradeoffs, and the reason for a decision when stated.
        - Include every action item, assignment, reading, due date, and follow-up. Name the owner, deadline, dependency, and success condition only when each is stated or unambiguous.
        - Attribute statements only when the speaker is clear from context. Otherwise describe the point without guessing a speaker.
        - Remove repetition and filler, but preserve all concrete context and technical detail needed to understand, study, recall, or execute the material.
        - Never use vague bullets such as "the topic was explained" when the transcript contains the explanation. Put the explanation itself in Detailed notes.

        Output EXACTLY this shape:
        Line 1:  SPOKEN: <one conversational sentence, at most 22 words, written for text-to-speech, saying the complete notes are ready>
        Then a blank line, then markdown notes:
        # <specific title inferred from the content>
        **When:** \(displayStampFormatter.string(from: startedAt)) · **Duration:** \(durationMinutes) min · **Capture type:** <Lecture, Lesson, Workshop, Interview, Meeting, or Discussion>
        ## Summary
        - a concise overview of what was taught, established, decided, or left unresolved
        ## Key bullet points
        - the most important concepts and takeaways in scannable form; use as many bullets as the material requires
        ## Detailed notes
        ### <topic>
        - complete explanations in the original topic order, including reasoning, relationships, mechanisms, context, examples, objections, and conclusions
        - create a separate ### subsection for every substantive topic or topic shift
        ## Definitions and key terms
        - **<term>:** <precise transcript-supported meaning and why it matters>, or "- none captured"
        ## Examples, evidence, and worked steps
        ### <example, case, demonstration, argument, or process>
        - preserve the setup, steps, result, and point of the example; use "- none captured" only when absent
        ## Formulas, dates, names, and facts
        - preserve each equation or formula exactly enough to study it, define variables and units when stated, and retain all concrete dates, people, sources, quantities, and factual claims
        - use "- none captured" only when absent
        ## Decisions
        - every explicit decision, including rationale and tradeoffs when stated, or "- none captured"
        ## Actions, assignments, and deadlines
        - [ ] <who if clear>: <specific action, assignment, reading, deliverable, or study task> — <deadline, dependency, or success condition if stated>, or "- none captured"
        ## Risks and blockers
        - each capture gap, uncertainty, risk, blocker, dependency, or concern, or "- none captured"
        ## Open questions and follow-ups
        - each unanswered learner question, unresolved issue, deferred choice, or required follow-up, or "- none captured"
        ## Study guide
        - organize the material into what the reader should understand, remember, be able to explain, and be able to do
        - include supported comparisons, cause-and-effect chains, step sequences, and likely review targets; never invent exam claims
        ## Flashcards
        - **Q:** <specific recall or understanding question based only on the transcript>
          **A:** <concise supported answer>
        - create enough flashcards to cover the important facts, concepts, definitions, processes, formulas, decisions, and terminology; use "- none captured" only when the transcript has no learnable content
        ## Details worth keeping
        - any remaining concrete wording, names, numbers, dates, links, terminology, requirements, examples, and technical details not already preserved above

        Transcript:
        \(transcriptText)
        """

        let rawResult: String
        if AceBrainRoute.current == .customerOwned {
            guard let brainExecutablePath else { return nil }
            let brainArguments: [String]
            switch selectedCLI {
            case .codex:
                do {
                    brainArguments = try await Self
                        .resolvedCodexArguments(
                            executablePath: brainExecutablePath
                        )
                    guard !Task.isCancelled,
                          !processStealthBoundary.isCutOff else {
                        return nil
                    }
                } catch {
                    appendNotesLog(
                        "ERROR Codex capability unavailable for notes generation"
                    )
                    return nil
                }
            case .claude:
                brainArguments =
                    // The isolated meeting summarizer answers the owner too — it
                    // follows the same picker selection as every answer lane.
                    BrainBackend.isolatedZeroToolClaudeArguments(
                        model: AceClaudeModel.currentSelection
                    )
                    + ["--max-turns", "1"]
            case .qwen:
                // The current local-model adapter stages userPrompt in a named
                // file. A populated meeting transcript is memory-only, so fail
                // closed and retain it for retry until a volatile stdin route
                // exists.
                appendNotesLog(
                    "ERROR Qwen has no volatile notes input route"
                )
                return nil
            }
            guard !Task.isCancelled,
                  !processStealthBoundary.isCutOff else {
                return nil
            }
            rawResult = await runProcess(
                executablePath: brainExecutablePath,
                arguments: brainArguments,
                standardInput: prompt,
                timeout: 240,
                environment: BrainBackend.processEnvironment(
                    claudeExecutablePath: brainExecutablePath
                ),
                processBox: processBox,
                processGeneration: processGeneration,
                processStealthBoundary:
                    processStealthBoundary
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard !Task.isCancelled,
                  !processStealthBoundary.isCutOff else {
                return nil
            }
            do {
                rawResult = try await HostedBrainClient.complete(
                    kind: .meetingSummary,
                    prompt: prompt
                )
            } catch {
                appendNotesLog("ERROR HQ CLI unavailable for notes generation")
                return nil
            }
        }
        guard !Task.isCancelled,
              !processStealthBoundary.isCutOff,
              !rawResult.isEmpty else {
            appendNotesLog("ERROR selected brain produced no notes")
            return nil
        }

        guard let generatedNotes = MeetingNotesGenerationPolicy.decode(
            rawResult,
            transcriptCharacterCount: transcriptText.count
        ) else {
            appendNotesLog(
                "ERROR selected brain notes failed detail or privacy validation")
            return nil
        }
        return generatedNotes
    }

    // MARK: - Meeting-app watcher (auto-offer)

    /// Bundle ids that mean a meeting app is running. Google Meet lives in the
    /// browser and can't be detected without touching the user's tabs — skipped.
    private static let meetingAppBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
    ]
    private struct MeetingOfferNotificationProcess {
        let process: Process
        let stealthBoundary:
            MeetingProcessStealthBoundary
    }
    private var meetingAppsAlreadyOffered: Set<String> = []
    private var meetingOfferNotificationProcesses:
        [String: MeetingOfferNotificationProcess] = [:]
    private var meetingWatchTimer: Timer?
    private var stealthModeActive = false

    /// Compatibility entry point for CompanionManager. Stealth entry delegates
    /// to the hard synchronous suspension boundary; exit only lowers this
    /// component's latch and resumes meeting-app discovery.
    func setStealthModeActive(_ isActive: Bool) {
        if isActive {
            suspendSynchronouslyForStealth()
            return
        }
        resumeAfterStealth()
    }

    /// Clean application termination owns an explicit synchronous boundary;
    /// deinit is not sufficient because an in-flight async generator retains
    /// this object. This is idempotent and never persists captured words.
    func shutdownSynchronouslyForAppExit() {
        privacyGeneration &+= 1
        audioStealthBoundary.cutOffSynchronously()
        audioStealthBoundary.unregisterSynchronousNativeCaptureCutoff(
            microphoneNativeCutoffRegistration
        )
        audioStealthBoundary.unregisterSynchronousNativeCaptureCutoff(
            systemAudioNativeCutoffRegistration
        )
        microphoneNativeCutoffRegistration = nil
        systemAudioNativeCutoffRegistration = nil

        isTakingNotes = false
        isStartingUp = false
        isWindingDown = false
        _ = audioSessionCoordinator?.withdrawCapture(.meetingNotes)
        noteTakingStartedAt = nil
        stopRequestedDuringStartup = false
        safetyStopTask?.cancel()
        safetyStopTask = nil

        pendingGeneratedNotesExpiryTask?.cancel()
        pendingGeneratedNotesExpiryTask = nil
        pendingGeneratedNotesSave = nil
        notesReviewWindow.dismiss()
        discardPendingMeetingNotesRetry(
            expectedIdentifier: nil,
            reason: .appExit
        )

        cancelActiveNotesGeneration()
        pendingMeetingNotesRetryBuffer.forceClearGeneration()
        publishPendingMeetingNotesRetryState()

        if let observer = microphoneConfigurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            microphoneConfigurationChangeObserver = nil
        }
        let mixerToDiscard = audioMixer
        audioMixer = nil
        mixerToDiscard?.suspendAndDiscardSynchronously()
        let transcriberToDiscard = transcriber
        transcriber = nil
        transcriberToDiscard?.cancelAndDiscardSynchronously()
        transcriptLines.removeAll(keepingCapacity: false)
        captureGapDescriptions.removeAll(keepingCapacity: false)
        captureSourceGaps.discard()
        sleepBeganAt = nil

        let committedMicrophone = microphoneEngine
        microphoneEngine = nil
        if let committedMicrophone {
            committedMicrophone.inputNode.removeTap(onBus: 0)
            committedMicrophone.stop()
        }
        let stagedMicrophone = startupMicrophoneEngine
        startupMicrophoneEngine = nil
        if let stagedMicrophone, stagedMicrophone !== committedMicrophone {
            stagedMicrophone.stop()
        }

        let committedOutput = systemAudioStreamOutput
        let stagedOutput = startupSystemAudioStreamOutput
        let committedStream = systemAudioStream
        let stagedStream = startupSystemAudioStream
        systemAudioStream = nil
        systemAudioStreamOutput = nil
        startupSystemAudioStream = nil
        startupSystemAudioStreamOutput = nil
        stopSystemAudioStreamSynchronously(
            committedStream,
            output: committedOutput
        )
        if stagedStream !== committedStream {
            stopSystemAudioStreamSynchronously(
                stagedStream,
                output: stagedOutput
            )
        }
        Self.appendNotesLog("NOTES shutdown completed reason=appExit")
    }

    /// The physical privacy chord calls this synchronously on the main actor.
    /// It does not await graceful finalization: delivery gates close first,
    /// queued mixer/transcriber work is drained into discard barriers, native
    /// capture is stopped, unsaved text is destroyed, and every notes-related
    /// child process tree is force-terminated before this method returns.
    ///
    /// Repeated calls are intentionally not a no-op. A second privacy signal
    /// re-runs every boundary and advances the generation again, so a resource
    /// published by an async race cannot survive merely because the latch was
    /// already true.
    func suspendSynchronouslyForStealth() {
        CodexModelCapabilityPreflight.shared.invalidate(
            reason: .privateMode
        )
        // The event-tap cutoff normally closed this before MainActor delivery.
        // Repeat it here so direct/test entry paths have the same hard boundary.
        audioStealthBoundary.cutOffSynchronously()
        audioStealthBoundary.unregisterSynchronousNativeCaptureCutoff(
            microphoneNativeCutoffRegistration
        )
        audioStealthBoundary.unregisterSynchronousNativeCaptureCutoff(
            systemAudioNativeCutoffRegistration
        )
        microphoneNativeCutoffRegistration = nil
        systemAudioNativeCutoffRegistration = nil
        privacyGeneration &+= 1
        stealthModeActive = true
        isTakingNotes = false
        audioPreflightResult = nil
        _ = audioSessionCoordinator?.withdrawCapture(.meetingNotes)
        noteTakingStartedAt = nil
        stopRequestedDuringStartup = false
        pendingGeneratedNotesExpiryTask?.cancel()
        pendingGeneratedNotesExpiryTask = nil
        if pendingGeneratedNotesSave != nil {
            pendingGeneratedNotesSave = nil
            Self.appendNotesLog(
                "NOTES REVIEW discarded — stealth entered")
        }
        discardPendingMeetingNotesRetry(
            expectedIdentifier: nil,
            reason: .stealth
        )
        pendingMeetingNotesRetryBuffer.forceClearGeneration()
        publishPendingMeetingNotesRetryState()
        notesReviewWindow.dismiss()

        meetingWatchTimer?.invalidate()
        meetingWatchTimer = nil

        safetyStopTask?.cancel()
        safetyStopTask = nil

        if let observer = microphoneConfigurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            microphoneConfigurationChangeObserver = nil
        }

        let committedOutput = systemAudioStreamOutput
        let stagedOutput = startupSystemAudioStreamOutput
        committedOutput?.suspendDeliverySynchronously()
        if stagedOutput !== committedOutput {
            stagedOutput?.suspendDeliverySynchronously()
        }

        let mixerToDiscard = audioMixer
        audioMixer = nil
        mixerToDiscard?.suspendAndDiscardSynchronously()

        let committedMicrophone = microphoneEngine
        microphoneEngine = nil
        if let committedMicrophone {
            committedMicrophone.inputNode.removeTap(onBus: 0)
            committedMicrophone.stop()
        }
        let stagedMicrophone = startupMicrophoneEngine
        startupMicrophoneEngine = nil
        if let stagedMicrophone, stagedMicrophone !== committedMicrophone {
            stagedMicrophone.stop()
        }

        let transcriberToDiscard = transcriber
        transcriber = nil
        transcriberToDiscard?.cancelAndDiscardSynchronously()
        transcriptLines.removeAll(keepingCapacity: false)
        captureGapDescriptions.removeAll(keepingCapacity: false)
        captureSourceGaps.discard()
        sleepBeganAt = nil

        let committedStream = systemAudioStream
        let stagedStream = startupSystemAudioStream
        systemAudioStream = nil
        systemAudioStreamOutput = nil
        startupSystemAudioStream = nil
        startupSystemAudioStreamOutput = nil
        stopSystemAudioStreamSynchronously(
            committedStream,
            output: committedOutput
        )
        if stagedStream !== committedStream {
            stopSystemAudioStreamSynchronously(
                stagedStream,
                output: stagedOutput
            )
        }

        cancelActiveNotesGeneration()

        let pendingOffers = meetingOfferNotificationProcesses
        meetingOfferNotificationProcesses.removeAll()
        for (meetingApp, pendingOffer) in pendingOffers {
            meetingAppsAlreadyOffered.remove(meetingApp)
            let process = pendingOffer.process
            if process.isRunning {
                RunningProcessBox.terminateProcessTree(process)
                Self.appendNotesLog("OFFER process tree cancelled for \(meetingApp) — stealth entered")
            }
        }
        Self.appendNotesLog("NOTES synchronously suspended and unsaved transcript discarded")
    }

    /// Call only after the process-wide StealthVisibilityGate has been lowered.
    /// Old async capture/save work remains invalid because privacyGeneration is
    /// never decremented; only the watcher is resumed for future sessions.
    func resumeAfterStealth() {
        guard stealthModeActive else { return }
        guard audioStealthBoundary.resumeAfterVerifiedExit() else {
            Self.appendNotesLog(
                "NOTES resume refused — process-wide Stealth latch is still raised"
            )
            return
        }
        stealthModeActive = false
        startMeetingAppWatcher()
        // A meeting app discovered while stealth was up was never marked as
        // offered, so this retries immediately instead of waiting up to 30s.
        checkForMeetingApps()
    }

    /// Reopens only the watcher for a newly entitled session. The prior
    /// capture, transcript, review, writer generation, and process tree were
    /// synchronously discarded before the lease state closed.
    func resumeNewWorkAfterEntitlementRestored() {
        resumeAfterStealth()
    }

    private func stopSystemAudioStreamSynchronously(
        _ stream: SCStream?,
        output: SystemAudioStreamOutput?
    ) {
        guard let stream else { return }
        if let output {
            try? stream.removeStreamOutput(output, type: .audio)
            try? stream.removeStreamOutput(output, type: .screen)
        }
        // ScreenCaptureKit's callback form starts native teardown before this
        // method returns. Delivery is already synchronously nilled above, so an
        // in-flight startCapture cannot leak a late audio buffer while teardown
        // finishes inside the framework.
        stream.stopCapture { error in
            if let error {
                blNotesLog(
                    "SCK synchronous suspension stop returned: \(error.localizedDescription)")
            }
        }
    }

    /// Polls for meeting apps and posts ONE quiet notification per app launch
    /// offering to take notes. A notification, never a voice interruption — Ace
    /// must not talk over the start of a real meeting.
    func startMeetingAppWatcher() {
        guard AceEntitlementRuntimeAdmissionGate.shared.admits(
            .meetingNotes
        ) else {
            return
        }
        guard meetingWatchTimer == nil else { return }
        meetingWatchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForMeetingApps() }
        }
    }

    private func checkForMeetingApps() {
        guard AceEntitlementRuntimeAdmissionGate.shared.admits(
            .meetingNotes
        ) else {
            return
        }
        let runningBundleIdentifiers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let runningMeetingApps = runningBundleIdentifiers.intersection(Self.meetingAppBundleIdentifiers)
        // Forget apps that quit so the next launch gets a fresh offer.
        meetingAppsAlreadyOffered.formIntersection(runningMeetingApps)
        guard !isTakingNotes,
              !stealthModeActive,
              !StealthVisibilityGate.shared.isActive else { return }
        for meetingApp in runningMeetingApps where !meetingAppsAlreadyOffered.contains(meetingApp) {
            guard postMeetingOfferNotification(
                for: meetingApp,
                title: "Ace",
                message: "In a meeting? Hold Command+Shift and say \"take notes\" — I'll write everything down."
            ) else { continue }
            meetingAppsAlreadyOffered.insert(meetingApp)
            Self.appendNotesLog("OFFER posted for \(meetingApp)")
        }
    }

    // MARK: - Helpers

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        standardInput: String,
        timeout timeoutSeconds: TimeInterval,
        environment: [String: String]? = nil,
        processBox: RunningProcessBox,
        processGeneration: UInt64,
        processStealthBoundary:
            MeetingProcessStealthBoundary
    ) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                process.environment = environment
                    ?? BrainBackend.processEnvironment(
                        claudeExecutablePath: executablePath
                    )
                let inputPipe = Pipe(), outputPipe = Pipe()
                process.standardInput = inputPipe
                // Generated notes remain memory-only until the owner reviews
                // and confirms them. Capturing stdout in a pipe avoids a crash-
                // persistent temporary file before that authority boundary.
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice
                let didLaunchAndPublish: Bool
                do {
                    didLaunchAndPublish =
                        try processStealthBoundary
                            .launchAndPublishIfAdmitted(
                                launch: {
                                    try process.run()
                                    return process
                                },
                                publish: {
                                    launchedProcess in
                                    let processIdentifier =
                                        launchedProcess
                                            .processIdentifier
                                    launchedProcess
                                        .terminationHandler = {
                                            [weak processStealthBoundary]
                                            terminatedProcess in
                                            processStealthBoundary?
                                                .clearPublishedProcess(
                                                    processIdentifier:
                                                        terminatedProcess
                                                            .processIdentifier
                                                )
                                        }
                                    processBox.register(
                                        launchedProcess,
                                        generation:
                                            processGeneration
                                    )
                                    if !launchedProcess.isRunning {
                                        processStealthBoundary
                                            .clearPublishedProcess(
                                                processIdentifier:
                                                    processIdentifier
                                            )
                                    }
                                }
                            )
                } catch {
                    processBox.clear(generation: processGeneration)
                    blNotesLog("ERROR brain launch failed: \(error.localizedDescription)")
                    continuation.resume(returning: "")
                    return
                }
                guard didLaunchAndPublish else {
                    processBox.clear(
                        generation: processGeneration
                    )
                    continuation.resume(returning: "")
                    return
                }

                let providerStartedAt = Date()
                appendNotesLog(
                    "NOTES PROVIDER started pid=\(process.processIdentifier) "
                        + "timeoutSeconds=\(Int(timeoutSeconds))"
                )
                let inputData = Data(standardInput.utf8)
                let didWriteStandardInput =
                    processStealthBoundary
                        .writeStandardInputIfAdmitted(
                            inputData,
                            to: inputPipe
                                .fileHandleForWriting
                                .fileDescriptor
                        )
                inputPipe.fileHandleForWriting.closeFile()
                if !didWriteStandardInput {
                    // This runs on the worker queue, never on the event-tap
                    // callback. Full async cleanup may therefore use the
                    // existing process box after the bounded libproc cutoff.
                    processBox.terminate(
                        generation: processGeneration
                    )
                }
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        RunningProcessBox.terminateProcessTree(process)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)
                let outputData =
                    outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                appendNotesLog(
                    "NOTES PROVIDER ended status=\(process.terminationStatus) "
                        + "seconds=\(Int(Date().timeIntervalSince(providerStartedAt))) "
                        + "outputBytes=\(outputData.count)"
                )
                processStealthBoundary.clearPublishedProcess(
                    processIdentifier:
                        process.processIdentifier
                )
                processBox.clear(generation: processGeneration)
                let output = didWriteStandardInput
                    ? String(
                        data: outputData,
                        encoding: .utf8
                    ) ?? ""
                    : ""
                switch processStealthBoundary
                    .performBoundedCommitIfAdmitted({
                        continuation.resume(
                            returning: output
                        )
                    }) {
                case .committed:
                    break
                case .blockedByStealth:
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// Launches and retains the meeting-offer osascript so stealth entry can
    /// terminate the tiny pre-notification window. The caller marks the app as
    /// offered only after this returns true.
    private func postMeetingOfferNotification(
        for meetingApp: String,
        title: String,
        message: String
    ) -> Bool {
        guard !StealthEntryLatch.shared.isRaised,
              !stealthModeActive,
              !StealthVisibilityGate.shared.isActive else {
            return false
        }

        let processStealthBoundary =
            MeetingProcessStealthBoundary()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
            "-e", "end run",
            title, message,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            return try processStealthBoundary
                .launchAndPublishIfAdmitted(
                    launch: {
                        try process.run()
                        return process
                    },
                    publish: {
                        launchedProcess in
                        let launchedProcessIdentifier =
                            launchedProcess.processIdentifier
                        launchedProcess.terminationHandler = {
                            [weak self, weak processStealthBoundary]
                            terminatedProcess in
                            processStealthBoundary?
                                .clearPublishedProcess(
                                    processIdentifier:
                                        terminatedProcess
                                            .processIdentifier
                                )
                            Task { @MainActor in
                                guard let self,
                                      let trackedProcess =
                                        self
                                            .meetingOfferNotificationProcesses[
                                                meetingApp
                                            ],
                                      trackedProcess.process
                                        === terminatedProcess else {
                                    return
                                }
                                if trackedProcess
                                    .stealthBoundary
                                    .isCutOff {
                                    self
                                        .meetingAppsAlreadyOffered
                                        .remove(meetingApp)
                                }
                                self
                                    .meetingOfferNotificationProcesses
                                    .removeValue(
                                        forKey: meetingApp
                                    )
                            }
                        }
                        meetingOfferNotificationProcesses[
                            meetingApp
                        ] = MeetingOfferNotificationProcess(
                            process: launchedProcess,
                            stealthBoundary:
                                processStealthBoundary
                        )
                        if !launchedProcess.isRunning {
                            processStealthBoundary
                                .clearPublishedProcess(
                                    processIdentifier:
                                        launchedProcessIdentifier
                                )
                        }
                    }
                )
        } catch {
            Self.appendNotesLog("OFFER launch failed for \(meetingApp): \(error.localizedDescription)")
            return false
        }
    }

    private static let clockTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
    private static let displayStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    private static func logSafe(_ value: String) -> String {
        String(
            value.unicodeScalars.map { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    ? Character(" ") : Character(scalar)
            }
        )
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    fileprivate static func appendNotesLog(_ message: String) { blNotesLog(message) }
}
#endif // circuit-convert

/// Two-phase no-follow, no-overwrite writer for the exact local destination
/// disclosed in the review. Slow directory and whole-note I/O happens while
/// staging. The only operation callers need to serialize with Stealth entry is
/// `PreparedFile.commitNewFile()`, one same-directory atomic rename.
enum MeetingReviewedNotesFileWriter {
    final class PreparedFile {
        private let directoryDescriptor: Int32
        private let temporaryName: String
        private let destinationName: String
        private var stagedFileExists = true

        fileprivate init(
            directoryDescriptor: Int32,
            temporaryName: String,
            destinationName: String
        ) {
            self.directoryDescriptor = directoryDescriptor
            self.temporaryName = temporaryName
            self.destinationName = destinationName
        }

        deinit {
            if stagedFileExists {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
            close(directoryDescriptor)
        }

        /// This is deliberately one metadata operation. The staged inode was
        /// already written and verified, and `RENAME_EXCL` atomically refuses
        /// an existing destination rather than replacing reviewed content.
        func commitNewFile(
            ifAdmitted admission: () -> Bool
        ) throws -> Bool {
            guard stagedFileExists else {
                throw MeetingReviewedNotesFileWriter.failure(
                    "the reviewed note was already committed"
                )
            }
            guard admission() else { return false }
            let renameResult = renameatx_np(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                destinationName,
                UInt32(RENAME_EXCL)
            )
            guard renameResult == 0 else {
                let renameError = errno
                throw MeetingReviewedNotesFileWriter.failure(
                    renameError == EEXIST
                        ? "the reviewed filename already exists"
                        : "the reviewed note could not be committed"
                )
            }
            stagedFileExists = false
            return true
        }
    }

    static func prepareNewFile(
        _ data: Data,
        to fileURL: URL,
        in folderURL: URL
    ) throws -> PreparedFile {
        let standardizedFolder = folderURL.standardizedFileURL
        guard fileURL.deletingLastPathComponent().standardizedFileURL
                == standardizedFolder else {
            throw failure("the reviewed file is outside its disclosed folder")
        }

        var pathStatus = stat()
        guard lstat(standardizedFolder.path, &pathStatus) == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw failure("the reviewed-notes folder is not a regular directory")
        }

        let directoryDescriptor = open(
            standardizedFolder.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw failure("the reviewed-notes folder could not be opened safely")
        }
        var shouldCloseDirectoryDescriptor = true
        defer {
            if shouldCloseDirectoryDescriptor {
                close(directoryDescriptor)
            }
        }

        var openedStatus = stat()
        guard fstat(directoryDescriptor, &openedStatus) == 0,
              (openedStatus.st_mode & S_IFMT) == S_IFDIR,
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino else {
            throw failure("the reviewed-notes folder changed before the save")
        }

        let destinationName = fileURL.lastPathComponent
        guard !destinationName.isEmpty,
              destinationName != ".",
              destinationName != "..",
              !destinationName.contains("/") else {
            throw failure("the reviewed filename is invalid")
        }

        let temporaryName =
            ".meeting-review.\(ProcessInfo.processInfo.processIdentifier)."
            + UUID().uuidString
        let temporaryDescriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard temporaryDescriptor >= 0 else {
            throw failure("the reviewed note could not stage a local file")
        }

        var temporaryFileExists = true
        defer {
            close(temporaryDescriptor)
            if temporaryFileExists {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        guard fchmod(
            temporaryDescriptor,
            mode_t(S_IRUSR | S_IWUSR)
        ) == 0,
              writeAll(data, to: temporaryDescriptor) else {
            throw failure("the reviewed note could not be written completely")
        }

        var stagedStatus = stat()
        guard fstat(temporaryDescriptor, &stagedStatus) == 0,
              (stagedStatus.st_mode & S_IFMT) == S_IFREG,
              stagedStatus.st_size == data.count,
              (stagedStatus.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw failure("the reviewed local file could not be staged safely")
        }

        let preparedFile = PreparedFile(
            directoryDescriptor: directoryDescriptor,
            temporaryName: temporaryName,
            destinationName: destinationName
        )
        temporaryFileExists = false
        shouldCloseDirectoryDescriptor = false
        return preparedFile
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
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

    private static func failure(_ description: String) -> NSError {
        NSError(
            domain: "MeetingNotetaker",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

/// Full, plain-text, app-owned review surface for generated meeting notes. The
/// model controls only the inert NSTextView contents; fixed native controls own
/// save/cancel authority. Closing the window only hides it; the frozen pending
/// review remains voice-saveable until its disclosed five-minute expiry.
enum MeetingNotesReviewCopy {
    static func instruction(
        destinationPath: String,
        expiresAt: Date
    ) -> String {
        let expirationFormatter = DateFormatter()
        expirationFormatter.timeStyle = .short
        expirationFormatter.dateStyle = .none
        return "The complete generated note is below. Nothing has been "
            + "written yet. Saving writes only this exact local file:\n"
            + "\(destinationPath)\n\nReview every line, "
            + "then click “Save these notes” or hold Command–Shift "
            + "and say “save the notes.” This review "
            + "expires at \(expirationFormatter.string(from: expiresAt)). "
            + "Closing this window only hides it until that deadline. "
            + "Ace will not choose an Apple Notes account or folder."
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
private final class MeetingNotesReviewWindowController: NSObject, NSWindowDelegate {
    private let premiumAdmissionIsOpen: @MainActor () -> Bool
    private var window: NSWindow?
    private var onSave: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var onClose: (() -> Void)?
    private var isProgrammaticDismissal = false
    private var destinationFolderURL: URL?
    private weak var openFolderStatusLabel: NSTextField?

    init(
        premiumAdmissionIsOpen: @escaping @MainActor () -> Bool
    ) {
        self.premiumAdmissionIsOpen = premiumAdmissionIsOpen
        super.init()
    }

    func present(
        title: String,
        notesMarkdown: String,
        destinationPath: String,
        expiresAt: Date,
        onAdmitted: () -> Void,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> Bool {
        dismiss()
        guard premiumAdmissionIsOpen(),
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else {
            return false
        }

        let reviewWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        reviewWindow.title = "Ace — Review Notes"
        reviewWindow.isReleasedWhenClosed = false
        reviewWindow.level = .floating
        reviewWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        reviewWindow.delegate = self
        reviewWindow.minSize = NSSize(width: 700, height: 520)

        let content = NSView()
        reviewWindow.contentView = content

        let heading = NSTextField(
            labelWithString: "Review before Ace saves anything"
        )
        heading.font = .systemFont(ofSize: 22, weight: .semibold)

        let noteTitle = NSTextField(labelWithString: title)
        noteTitle.font = .systemFont(ofSize: 13, weight: .medium)
        noteTitle.textColor = .secondaryLabelColor

        let instruction = NSTextField(
            wrappingLabelWithString:
                MeetingNotesReviewCopy.instruction(
                    destinationPath: destinationPath,
                    expiresAt: expiresAt
                )
        )
        instruction.font = .systemFont(ofSize: 13)
        instruction.textColor = .secondaryLabelColor

        let formattedNotesReview = AceHostingView(
            rootView: MeetingNotesReviewView(
                notesMarkdown: notesMarkdown
            )
        )

        let cancelButton = NSButton(
            title: "Cancel — save nothing",
            target: self,
            action: #selector(cancelPressed)
        )
        cancelButton.bezelStyle = .rounded

        let saveButton = NSButton(
            title: "Save these notes",
            target: self,
            action: #selector(savePressed)
        )
        saveButton.bezelStyle = .rounded

        let openFolderButton = NSButton(
            title: "Open Folder",
            target: self,
            action: #selector(openFolderPressed)
        )
        openFolderButton.bezelStyle = .rounded
        openFolderButton.identifier = NSUserInterfaceItemIdentifier(
            "ace.meeting.open-folder"
        )

        let openFolderStatus = NSTextField(
            wrappingLabelWithString: ""
        )
        openFolderStatus.font = .systemFont(ofSize: 11, weight: .medium)
        openFolderStatus.textColor = .secondaryLabelColor
        openFolderStatus.isHidden = true
        openFolderStatus.identifier = NSUserInterfaceItemIdentifier(
            "ace.meeting.open-folder.status"
        )

        for view in [
            heading, noteTitle, instruction, formattedNotesReview, cancelButton,
            openFolderStatus, openFolderButton, saveButton,
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            noteTitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 7),
            noteTitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            noteTitle.trailingAnchor.constraint(equalTo: heading.trailingAnchor),

            instruction.topAnchor.constraint(equalTo: noteTitle.bottomAnchor, constant: 12),
            instruction.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            instruction.trailingAnchor.constraint(equalTo: heading.trailingAnchor),

            formattedNotesReview.topAnchor.constraint(
                equalTo: instruction.bottomAnchor,
                constant: 16
            ),
            formattedNotesReview.leadingAnchor.constraint(
                equalTo: heading.leadingAnchor
            ),
            formattedNotesReview.trailingAnchor.constraint(
                equalTo: heading.trailingAnchor
            ),
            formattedNotesReview.bottomAnchor.constraint(
                equalTo: openFolderStatus.topAnchor,
                constant: -10
            ),

            openFolderStatus.leadingAnchor.constraint(
                equalTo: heading.leadingAnchor
            ),
            openFolderStatus.trailingAnchor.constraint(
                equalTo: heading.trailingAnchor
            ),
            openFolderStatus.bottomAnchor.constraint(
                equalTo: saveButton.topAnchor,
                constant: -8
            ),

            cancelButton.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),

            openFolderButton.leadingAnchor.constraint(
                equalTo: cancelButton.trailingAnchor,
                constant: 12
            ),
            openFolderButton.bottomAnchor.constraint(
                equalTo: cancelButton.bottomAnchor
            ),

            saveButton.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            saveButton.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor),
        ])

        let didPresent =
            MeetingNotesReviewPresentationAdmission.commit(
                visibilityIsBlocked: {
                    StealthVisibilityGate.shared.isActive
                        || !self.premiumAdmissionIsOpen()
                },
                present: {
                    onAdmitted()
                    self.onSave = onSave
                    self.onCancel = onCancel
                    self.onClose = onClose
                    self.destinationFolderURL = URL(
                        fileURLWithPath: destinationPath
                    ).deletingLastPathComponent()
                    self.openFolderStatusLabel = openFolderStatus
                    self.window = reviewWindow
                    reviewWindow.center()
                    NSApp.activate(
                        ignoringOtherApps: true
                    )
                    reviewWindow.makeKeyAndOrderFront(nil)
                }
            )
        guard didPresent else {
            reviewWindow.delegate = nil
            reviewWindow.close()
            window = nil
            self.onSave = nil
            self.onCancel = nil
            self.onClose = nil
            self.destinationFolderURL = nil
            self.openFolderStatusLabel = nil
            return false
        }
        return true
    }

    func dismiss() {
        guard let reviewWindow = window else {
            onSave = nil
            onCancel = nil
            onClose = nil
            destinationFolderURL = nil
            openFolderStatusLabel = nil
            return
        }
        isProgrammaticDismissal = true
        reviewWindow.close()
        isProgrammaticDismissal = false
        window = nil
        onSave = nil
        onCancel = nil
        onClose = nil
        destinationFolderURL = nil
        openFolderStatusLabel = nil
    }

    @objc private func savePressed() {
        guard premiumAdmissionIsOpen(),
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else {
            let callback = onCancel
            dismiss()
            callback?()
            return
        }
        let callback = onSave
        dismiss()
        callback?()
    }

    @objc private func cancelPressed() {
        let callback = onCancel
        dismiss()
        callback?()
    }

    @objc private func openFolderPressed() {
        let outcome = openDestinationFolder()
        openFolderStatusLabel?.stringValue = outcome.visibleMessage
        openFolderStatusLabel?.textColor = {
            if case .failed = outcome {
                return .systemRed
            }
            return .systemGreen
        }()
        openFolderStatusLabel?.isHidden = false
    }

    @discardableResult
    private func openDestinationFolder() -> AceControlActionOutcome {
        guard premiumAdmissionIsOpen(),
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else {
            return .failed(
                AceActionFailure(
                    code: "meeting_notes.open_blocked",
                    message:
                        "Meeting Notes access is not available right now.",
                    recoveryTitle: "Exit Private Mode and try again",
                    recovery: .retry
                )
            )
        }
        guard let destinationFolderURL else {
            return .failed(
                AceActionFailure(
                    code: "meeting_notes.folder_unavailable",
                    message:
                        "The Meeting Notes destination is no longer available.",
                    recoveryTitle: "Generate the notes again",
                    recovery: .retry
                )
            )
        }
        return AceWorkspaceOpenAction.perform(
            target: destinationFolderURL,
            copy: AceWorkspaceOpenCopy(
                successMessage: "Opened the Meeting Notes folder.",
                failureCode: "meeting_notes.folder_open_failed",
                failureMessage:
                    "Ace could not open the Meeting Notes folder.",
                recoveryTitle: "Try again",
                recovery: .retry
            ),
            prepare: {
                try FileManager.default.createDirectory(
                    at: destinationFolderURL,
                    withIntermediateDirectories: true
                )
            }
        )
    }

    func windowWillClose(_ notification: Notification) {
        let callback = isProgrammaticDismissal ? nil : onClose
        window = nil
        onSave = nil
        onCancel = nil
        onClose = nil
        destinationFolderURL = nil
        openFolderStatusLabel = nil
        callback?()
    }
}
#endif // circuit-convert

/// Durable proof channel, same idiom as brain.log / agent.log. Free function so
/// the capture and transcription helpers in this file can log too.
nonisolated private func blNotesLog(_ message: String) {
    guard let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("BlackLabel", isDirectory: true) else { return }
    // 0700 or the bundled tools all fail closed — see LifecycleLog.append.
    try? PrivateSupportDirectory.ensure(at: directory)
    let safeMessage = String(
        message.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                ? Character(" ") : Character(scalar)
        }
    )
    .components(separatedBy: .whitespacesAndNewlines)
    .filter { !$0.isEmpty }
    .joined(separator: " ")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(safeMessage)\n"
    let fileURL = directory.appendingPathComponent("notes.log")
    if let handle = try? FileHandle(forWritingTo: fileURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: fileURL, options: .atomic)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Peak sample level — content proof in logs and the voice-activity gate.
nonisolated private func peakAmplitude(
    of buffer: AVAudioPCMBuffer
) -> Float {
    guard let channelData = buffer.floatChannelData else { return -1 }
    var peak: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        let samples = channelData[channel]
        for frame in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(samples[frame]))
        }
    }
    return peak
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Downmixes any float PCM buffer to mono samples, optionally resampling
/// (nearest-neighbor — fine for speech) so every source enters the mixer at the
/// same rate. Handles interleaved and deinterleaved layouts explicitly.
nonisolated private func monoSamples(
    from buffer: AVAudioPCMBuffer,
    resampledTo targetRate: Double
) -> [Float]? {
    guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else { return nil }
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    var mono = [Float](repeating: 0, count: frameCount)
    if buffer.format.isInterleaved {
        let interleaved = channelData[0]
        for frame in 0..<frameCount {
            var mixedSample: Float = 0
            for channel in 0..<channelCount { mixedSample += interleaved[frame * channelCount + channel] }
            mono[frame] = mixedSample / Float(channelCount)
        }
    } else {
        for frame in 0..<frameCount {
            var mixedSample: Float = 0
            for channel in 0..<channelCount { mixedSample += channelData[channel][frame] }
            mono[frame] = mixedSample / Float(channelCount)
        }
    }
    let sourceRate = buffer.format.sampleRate
    if abs(sourceRate - targetRate) < 1 { return mono }
    let outputCount = Int(Double(frameCount) * targetRate / sourceRate)
    guard outputCount > 0 else { return nil }
    var resampled = [Float](repeating: 0, count: outputCount)
    for outputIndex in 0..<outputCount {
        let sourceIndex = min(frameCount - 1, Int(Double(outputIndex) * sourceRate / targetRate))
        resampled[outputIndex] = mono[sourceIndex]
    }
    return resampled
}
#endif // circuit-convert

// MARK: - System-audio stream output

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Receives SCK sample buffers on a background queue, converts audio ones to
/// mono samples, and forwards them. Kept outside the MainActor class because
/// SCStreamOutput calls back on its handler queue. Screen frames are dropped.
nonisolated private final class SystemAudioStreamOutput:
    NSObject,
    SCStreamOutput,
    SCStreamDelegate,
    @unchecked Sendable {
    /// Called when ScreenCaptureKit stops the stream on its own.
    ///
    /// The stream was created with `delegate: nil`, so a stop was completely
    /// invisible: `isTakingNotes` stayed true, the lane gem stayed lit, and the
    /// panel kept showing "Taking Notes" while nothing was being captured. Lid
    /// close, display sleep, a display reconfiguration, or Screen Recording
    /// revoked mid-call all end the stream this way — and the owner discovers
    /// it an hour later as notes that contain none of the meeting.
    private let stopLock = NSLock()
    private var streamStopHandler: ((Error?) -> Void)?
    var onStreamStopped: ((Error?) -> Void)? {
        get {
            stopLock.lock()
            defer { stopLock.unlock() }
            return streamStopHandler
        }
        set {
            stopLock.lock()
            streamStopHandler = newValue
            stopLock.unlock()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        LifecycleLog.append(
            "NOTES system-audio stream stopped: \(error.localizedDescription)"
        )
        onStreamStopped?(error)
    }

    private let audioStealthBoundary: MeetingAudioStealthBoundary
    /// Set after capture starts; called on the sample-handler queue.
    private let deliveryLock = NSLock()
    private var monoSampleDelivery: (([Float]) -> Void)?
    var onMonoSamples: (([Float]) -> Void)? {
        get {
            deliveryLock.lock()
            defer { deliveryLock.unlock() }
            return monoSampleDelivery
        }
        set {
            deliveryLock.lock()
            monoSampleDelivery = newValue
            deliveryLock.unlock()
        }
    }
    private var deliveredBufferCount = 0

    init(audioStealthBoundary: MeetingAudioStealthBoundary) {
        self.audioStealthBoundary = audioStealthBoundary
        super.init()
    }

    /// Clears the callback under the same lock held while invoking it. On return
    /// no in-flight ScreenCaptureKit callback can still enqueue system audio.
    func suspendDeliverySynchronously() {
        deliveryLock.lock()
        monoSampleDelivery = nil
        deliveryLock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let admission = audioStealthBoundary.beginAdmission(),
              type == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pcmBuffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        deliveredBufferCount += 1
        if deliveredBufferCount == 1 || deliveredBufferCount % 500 == 0 {
            blNotesLog("SCK audio buffers=\(deliveredBufferCount) peak=\(String(format: "%.4f", peakAmplitude(of: pcmBuffer))) format=\(pcmBuffer.format)")
        }
        guard let samples = monoSamples(
                  from: pcmBuffer,
                  resampledTo: MeetingAudioMixer.mixSampleRate
              ),
              audioStealthBoundary.isCurrent(admission) else { return }
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard audioStealthBoundary.isCurrent(admission) else { return }
        // The mixer performs its own fresh synchronous admission, closing the
        // small revalidation-to-callback gap here.
        monoSampleDelivery?(samples)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcmBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }
        return pcmBuffer
    }
}
#endif // circuit-convert

// MARK: - Two-source mixdown

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Sums the microphone and system-audio streams into one mono stream so a
/// single recognition task can hear the whole meeting. Both sources push mono
/// samples at the mix rate; when both are live the mixer pairs them
/// sample-for-sample (both are continuous real-time streams, so the FIFOs stay
/// balanced), and a runaway guard drains a source alone if the other dies.
nonisolated private final class MeetingAudioMixer: @unchecked Sendable {
    nonisolated enum Mode { case both, microphoneOnly, systemOnly }
    static let mixSampleRate: Double = 48000

    private let mode: Mode
    private let onMixedBuffer: (AVAudioPCMBuffer) -> Void
    private let audioStealthBoundary: MeetingAudioStealthBoundary
    private let queue = DispatchQueue(label: "com.blacklabel.assistant.meeting-mixer")
    private let deliveryLock = NSLock()
    private var acceptsAudio = true
    private var samplePairer = MeetingAudioSamplePairer(
        emitFrameCount: 4096,
        maximumPairingSkewFrameCount: 8192
    )
    private var microphoneSelfVoiceSuppression =
        MeetingMicrophoneSelfVoiceSuppression(
            tailSeconds: AceSelfVoiceSuppressionWindow.tailSeconds
        )
    /// Count of mic pushes, for the periodic MIC-level log line. The mic side had
    /// no instrumentation, so a stalled mic tap (peak → 0 / count frozen) was
    /// indistinguishable in the log from a wedged recognizer. This line, paired
    /// with the SCK line, makes that call: if MIC buffers keep advancing with
    /// peak>0 while STT still reports "No speech detected", the recognizer — not
    /// the mic — is the problem.
    private var microphoneDeliveredBufferCount = 0
    private static let mixFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: mixSampleRate, channels: 1, interleaved: false
    )!

    init(
        mode: Mode,
        audioStealthBoundary: MeetingAudioStealthBoundary,
        onMixedBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) {
        self.mode = mode
        self.audioStealthBoundary = audioStealthBoundary
        self.onMixedBuffer = onMixedBuffer
    }

    private func isAcceptingAudio() -> Bool {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        return acceptsAudio
    }

    /// Closes the producer gate before placing a synchronous queue barrier.
    /// Blocks already executing mixer callbacks, clears both FIFOs, and ensures
    /// every callback queued after the barrier observes discard mode.
    func suspendAndDiscardSynchronously() {
        deliveryLock.lock()
        acceptsAudio = false
        deliveryLock.unlock()
        queue.sync { [self] in
            samplePairer.discard()
        }
    }

    func pushMicrophone(_ samples: [Float]) {
        guard let admission = audioStealthBoundary.beginAdmission() else {
            return
        }
        let speechActivity = (
            isSpeaking: NoraSpeechActivityLatch.shared.isSpeaking,
            endedAt: NoraSpeechActivityLatch.shared.speechEndedAt
        )
        let capturedAt = Date()
        queue.async { [self] in
            var shouldLogLevel = false
            var loggedBufferCount = 0
            let outputBatches = audioStealthBoundary.performIfCurrent(
                admission
            ) { () -> [[Float]] in
                guard isAcceptingAudio() else { return [] }
                microphoneDeliveredBufferCount += 1
                loggedBufferCount = microphoneDeliveredBufferCount
                shouldLogLevel =
                    microphoneDeliveredBufferCount == 1
                    || microphoneDeliveredBufferCount % 200 == 0
                microphoneSelfVoiceSuppression.observeAceSpeech(
                    isActive: speechActivity.isSpeaking,
                    now: capturedAt
                )
                if !speechActivity.isSpeaking {
                    microphoneSelfVoiceSuppression.observeAceSpeechEnded(
                        at: speechActivity.endedAt
                    )
                }
                let suppressMicrophone =
                    microphoneSelfVoiceSuppression
                        .shouldSuppressMicrophone(at: capturedAt)
                if mode == .microphoneOnly {
                    return [
                        suppressMicrophone
                            ? Array(repeating: 0, count: samples.count)
                            : samples
                    ]
                }
                guard mode == .both else { return [] }
                return samplePairer.appendMicrophone(
                    samples,
                    suppressForSelfVoice: suppressMicrophone
                )
            } ?? []
            if shouldLogLevel {
                let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                blNotesLog(
                    "MIC audio buffers=\(loggedBufferCount) "
                        + "peak=\(String(format: "%.4f", peak))"
                )
            }
            for outputSamples in outputBatches {
                emit(outputSamples, admittedBy: admission)
            }
        }
    }

    func pushSystem(_ samples: [Float]) {
        guard let admission = audioStealthBoundary.beginAdmission() else {
            return
        }
        queue.async { [self] in
            let outputBatches = audioStealthBoundary.performIfCurrent(
                admission
            ) { () -> [[Float]] in
                guard isAcceptingAudio() else { return [] }
                if mode == .systemOnly { return [samples] }
                guard mode == .both else { return [] }
                return samplePairer.appendSystem(samples)
            } ?? []
            for outputSamples in outputBatches {
                emit(outputSamples, admittedBy: admission)
            }
        }
    }

    /// Emits whatever is still buffered (unpaired tails included) — called once
    /// at stop so the last words aren't stranded in a FIFO. `completion` fires
    /// AFTER the tail has been emitted (which enqueues it onto the transcriber's
    /// workQueue), so the caller can wait and only then call finish() — otherwise
    /// finish()'s isStopped flag races ahead and the tail append is dropped.
    func flush(completion: @escaping @Sendable () -> Void = {}) {
        guard let admission = audioStealthBoundary.beginAdmission() else {
            completion()
            return
        }
        queue.async { [self] in
            defer { completion() }
            let outputBatches = audioStealthBoundary.performIfCurrent(
                admission
            ) { () -> [[Float]] in
                guard isAcceptingAudio() else {
                    samplePairer.discard()
                    return []
                }
                return samplePairer.flush()
            } ?? []
            for outputSamples in outputBatches {
                emit(outputSamples, admittedBy: admission)
            }
        }
    }

    private func emit(
        _ samples: [Float],
        admittedBy admission: MeetingAudioStealthBoundary.Admission
    ) {
        guard audioStealthBoundary.isCurrent(admission),
              isAcceptingAudio(),
              !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.mixFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let bufferData = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in 0..<samples.count { bufferData[0][index] = samples[index] }
        guard audioStealthBoundary.isCurrent(admission) else { return }
        // ContinuousTranscriber performs a fresh admission synchronously, so
        // an X racing this call either invalidates here or is rejected there.
        onMixedBuffer(buffer)
    }
}
#endif // circuit-convert

// MARK: - Continuous on-device transcription

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Long-form transcription on top of SFSpeechRecognizer, which is built for
/// short utterances: audio is fed into a recognition request that is rotated
/// every ~40 seconds (endAudio → final result → fresh request), so a meeting of
/// any length becomes a stream of finalized text chunks. On-device only, and
/// strictly ONE task at a time — macOS kills concurrent on-device tasks.
nonisolated private final class ContinuousTranscriber: @unchecked Sendable {
    private let onFinalizedText: (_ text: String, _ chunkStartedAt: Date) -> Void
    private let audioStealthBoundary: MeetingAudioStealthBoundary
    private let workQueue = DispatchQueue(label: "com.blacklabel.assistant.meeting-stt")
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    /// Same recognizer selection as the app's proven push-to-talk provider.
    private let speechRecognizer: SFSpeechRecognizer? =
        AppleSpeechTranscriptionProvider.makeSelectedOnDeviceRecognizer()

    /// One rotation's worth of state. The recognition task's result handler
    /// captures its own generation, so a late final from a rotated-out request
    /// still lands (exactly once) in the right chunk.
    nonisolated private final class Generation: @unchecked Sendable {
        let startedAt = Date()
        /// Completed utterances within this generation. The recognizer segments a
        /// long stream into utterances and RESETS bestTranscription at each one,
        /// so completed segments must be banked or everything before the last
        /// segment is lost (that bug shipped the "default pencil" transcript).
        var bankedText = ""
        /// The in-progress utterance.
        var latestText = ""
        var hasDelivered = false
        var hasLoggedFirstPartial = false
        var task: SFSpeechRecognitionTask?

        var fullText: String {
            if bankedText.isEmpty { return latestText }
            if latestText.isEmpty { return bankedText }
            return bankedText + " " + latestText
        }

        func bankCompletedUtterance(_ utteranceText: String) {
            guard !utteranceText.isEmpty else { return }
            bankedText = bankedText.isEmpty ? utteranceText : bankedText + " " + utteranceText
        }
    }

    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var currentGeneration: Generation?
    /// Rotated-out generations kept alive until their final result arrives.
    private var pendingGenerations: [Generation] = []
    /// Buffers that arrived while the recognition task was being created on the
    /// main thread — flushed into the request the moment it exists, so the first
    /// word of a chunk isn't clipped.
    private var buffersAwaitingRequest: [AVAudioPCMBuffer] = []
    private var isCreatingGeneration = false
    private var isStopped = false
    private var hasLoggedUnavailable = false
    /// Consecutive generations that died with an error, instantly, having produced
    /// no text — the signature of a recognizer that is REFUSING (system Siri and
    /// Dictation switched off mid-meeting, speech service wedged) rather than one
    /// that heard silence. Without a brake, the next voiced buffer starts another
    /// one immediately: on 2026-07-22 that ran 1,551 restarts in 169 seconds
    /// (3,134 log lines) while the meeting produced nothing.
    private var consecutiveInstantFailures = 0
    /// Fired ONCE per refusal streak — the moment consecutiveInstantFailures first
    /// crosses deafnessSignalThreshold, i.e. the recognizer is provably deaf, not
    /// hearing silence. MeetingNotetaker hops this to the main actor so
    /// CompanionManager can surface the spoken + gem deafness signal. Assigned by
    /// MeetingNotetaker at construction.
    var onDeafnessStreakDetected: (() -> Void)?
    /// Fired when a streak that had crossed the deafness threshold clears (real text
    /// arrived again) — hearing recovered, so the gem cue can drop.
    var onHearingRecovered: (() -> Void)?
    /// True once the deafness signal has fired for the CURRENT streak, so a storm of
    /// hundreds of refusals produces exactly one spoken line and one gem cue rather
    /// than one per attempt. Reset when the streak clears.
    private var hasSignaledDeafnessForCurrentStreak = false
    /// How many consecutive instant refusals earn the deafness signal. The brake's
    /// backoff is 1s,2s,4s,… so the 4th refusal lands ~7s into a genuine outage —
    /// long enough to be sure it is a refusal storm and not a one-off task death,
    /// short enough that the founder is not left in unexplained silence.
    private static let deafnessSignalThreshold = 4
    /// No new generation before this time — the backoff the failure streak earned.
    private var nextGenerationAllowedAt = Date.distantPast
    /// The failure text already written to the log for the current streak; repeats
    /// are counted into one periodic line instead of one line per attempt.
    private var loggedInstantFailureDescription: String?
    /// True while push-to-talk owns the single on-device recognition slot — the
    /// notetaker's task is torn down for the hold so the two never collide.
    private var isPausedForPushToTalk = false
    private var pausedAudioBuffers =
        MeetingPausedAudioQueue<AVAudioPCMBuffer>(maximumCount: 200)

    private static let generationSeconds: TimeInterval = 25
    /// A generation only STARTS on a buffer with at least this much signal, so
    /// silence never spins up recognition tasks. Once a generation is running,
    /// every buffer is appended — pauses included.
    private static let voiceActivityPeakThreshold: Float = 0.008
    /// A generation that errored within this long of being created never listened —
    /// the observed refusal storm created and killed tasks inside the same logged
    /// second, while genuine "no speech detected" chunks ran for seconds first.
    private static let instantFailureLifetimeSeconds: TimeInterval = 1.5

    init(
        audioStealthBoundary: MeetingAudioStealthBoundary,
        onFinalizedText: @escaping (
            _ text: String,
            _ chunkStartedAt: Date
        ) -> Void
    ) {
        self.audioStealthBoundary = audioStealthBoundary
        self.onFinalizedText = onFinalizedText
    }

    private func hasCancellationRequest() -> Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationRequested
    }

    /// Privacy teardown is deliberately different from finish(): no partial
    /// text may finalize. The lock closes main-queue generation creation first,
    /// then a synchronous work-queue barrier cancels every known recognition
    /// task and destroys all buffered or recognized text before returning.
    func cancelAndDiscardSynchronously() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
        workQueue.sync { [self] in
            isStopped = true
            currentRequest?.endAudio()
            currentGeneration?.task?.cancel()
            for generation in pendingGenerations {
                generation.task?.cancel()
                generation.bankedText = ""
                generation.latestText = ""
                generation.hasDelivered = true
            }
            currentGeneration?.bankedText = ""
            currentGeneration?.latestText = ""
            currentGeneration?.hasDelivered = true
            currentRequest = nil
            currentGeneration = nil
            pendingGenerations.removeAll(keepingCapacity: false)
            buffersAwaitingRequest.removeAll(keepingCapacity: false)
            pausedAudioBuffers.discard()
            isCreatingGeneration = false
            onDeafnessStreakDetected = nil
            onHearingRecovered = nil
        }
    }

    /// Feed mono float audio, from any queue.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let admission = audioStealthBoundary.beginAdmission() else {
            return
        }
        workQueue.async { [self] in
            guard audioStealthBoundary.isCurrent(admission),
                  !isStopped,
                  !hasCancellationRequest() else { return }
            if isPausedForPushToTalk {
                pausedAudioBuffers.append(buffer)
                return
            }
            appendToRecognitionOnWorkQueue(
                buffer,
                admittedBy: admission
            )
        }
    }

    private func appendToRecognitionOnWorkQueue(
        _ buffer: AVAudioPCMBuffer,
        admittedBy admission: MeetingAudioStealthBoundary.Admission
    ) {
        guard audioStealthBoundary.isCurrent(admission),
              !isStopped,
              !hasCancellationRequest() else { return }
        if isCreatingGeneration {
            _ = audioStealthBoundary.performIfCurrent(admission) {
                buffersAwaitingRequest.append(buffer)
                if buffersAwaitingRequest.count > 200 {
                    buffersAwaitingRequest.removeFirst()
                }
            }
            return
        }
        if currentRequest == nil {
            // A refusing recognizer has earned a wait — audio keeps flowing to
            // the mixer, we just stop re-creating a task that dies on arrival.
            guard Date() >= nextGenerationAllowedAt else { return }
            guard peakAmplitude(of: buffer) >= Self.voiceActivityPeakThreshold else { return }
            guard audioStealthBoundary.performIfCurrent(
                admission,
                {
                    buffersAwaitingRequest = [buffer]
                    return true
                }
            ) == true else { return }
            startGeneration()
            return
        }
        guard audioStealthBoundary.performIfCurrent(
            admission,
            {
                currentRequest?.append(buffer)
                return true
            }
        ) == true else { return }
        if let generation = currentGeneration,
           Date().timeIntervalSince(generation.startedAt) > Self.generationSeconds {
            rotateGeneration()
        }
    }

    /// Stops accepting audio, asks the in-flight request to finalize, and waits
    /// briefly so the last words make it into the transcript.
    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let admission =
                    audioStealthBoundary.beginAdmission() else {
                continuation.resume()
                return
            }
            workQueue.async { [self] in
                guard audioStealthBoundary.isCurrent(admission) else {
                    continuation.resume()
                    return
                }
                isStopped = true
                pausedAudioBuffers.discard()
                blNotesLog("STT finish current=\(currentGeneration != nil) pending=\(pendingGenerations.count) chars=\(currentGeneration?.fullText.count ?? -1) creating=\(isCreatingGeneration)")
                currentRequest?.endAudio()
                if let finalGeneration = currentGeneration { pendingGenerations.append(finalGeneration) }
                currentRequest = nil
                currentGeneration = nil
                // If the final result hasn't arrived in 2.5s, deliver the best partial.
                workQueue.asyncAfter(deadline: .now() + 2.5) { [self] in
                    guard audioStealthBoundary.isCurrent(admission) else {
                        pendingGenerations = []
                        continuation.resume()
                        return
                    }
                    for generation in pendingGenerations {
                        deliver(generation)
                    }
                    pendingGenerations = []
                    continuation.resume()
                }
            }
        }
    }

    /// Push-to-talk is claiming the single on-device recognition slot: end the
    /// in-flight request (its banked/partial text finalizes and is delivered via
    /// pendingGenerations) and stop accepting audio until resume. Idempotent.
    func pauseForPushToTalk() {
        guard let admission = audioStealthBoundary.beginAdmission() else {
            return
        }
        workQueue.async { [self] in
            guard audioStealthBoundary.isCurrent(admission),
                  !hasCancellationRequest(),
                  !isPausedForPushToTalk else { return }
            isPausedForPushToTalk = true
            currentRequest?.endAudio()
            if let generation = currentGeneration { pendingGenerations.append(generation) }
            currentRequest = nil
            currentGeneration = nil
            buffersAwaitingRequest = []
            pausedAudioBuffers.discard()
            blNotesLog("STT paused for push-to-talk")
        }
    }

    /// Push-to-talk finished: drain the bounded meeting-audio window into a new
    /// recognition generation, then accept live audio again. Idempotent.
    func resumeAfterPushToTalk() {
        guard let admission = audioStealthBoundary.beginAdmission() else {
            return
        }
        workQueue.async { [self] in
            guard audioStealthBoundary.isCurrent(admission),
                  !hasCancellationRequest(),
                  isPausedForPushToTalk else { return }
            isPausedForPushToTalk = false
            let bufferedAudio = pausedAudioBuffers.drain()
            for buffer in bufferedAudio {
                appendToRecognitionOnWorkQueue(
                    buffer,
                    admittedBy: admission
                )
            }
            blNotesLog(
                "STT resumed after push-to-talk buffered="
                    + "\(bufferedAudio.count)"
            )
        }
    }

    // MARK: workQueue-only internals

    /// Creates the recognition request + task ON THE MAIN THREAD — the same
    /// thread the app's working push-to-talk provider uses.
    private func startGeneration() {
        guard let generationAdmission =
                audioStealthBoundary.beginAdmission(),
              !hasCancellationRequest() else {
            buffersAwaitingRequest = []
            return
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            if !hasLoggedUnavailable {
                hasLoggedUnavailable = true
                blNotesLog("STT recognizer unavailable (nil=\(speechRecognizer == nil))")
            }
            buffersAwaitingRequest = []
            return
        }
        // Fail closed on the on-device guarantee, mirroring the push-to-talk
        // provider: never let a Mac without on-device support fall back to
        // Apple's speech SERVERS — meeting audio must stay on this machine. If
        // unsupported, don't start a task (transcription off, not leaked).
        guard speechRecognizer.supportsOnDeviceRecognition else {
            if !hasLoggedUnavailable {
                hasLoggedUnavailable = true
                blNotesLog("STT on-device unavailable — refusing server fallback, transcription off")
                // This path returns before any recognition task exists, so the
                // instant-failure streak never increments and the deafness
                // signal below could NEVER fire here. The result was the worst
                // possible shape: the panel says "Taking Notes" for the whole
                // meeting, nothing is transcribed, and the only evidence is one
                // line in notes.log. Refusing the server fallback is correct —
                // meeting audio stays on this machine — but it has to be said
                // out loud, through the same spoken + gem surface the wedged-
                // recognizer case already uses.
                onDeafnessStreakDetected?()
            }
            buffersAwaitingRequest = []
            return
        }
        isCreatingGeneration = true
        DispatchQueue.main.async { [self] in
            guard audioStealthBoundary.isCurrent(generationAdmission),
                  !hasCancellationRequest() else {
                workQueue.async { [self] in
                    isCreatingGeneration = false
                    buffersAwaitingRequest = []
                }
                return
            }
            let generation = Generation()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.addsPunctuation = true
            // On-device support is guaranteed by the fail-closed guard above.
            request.requiresOnDeviceRecognition = true
            generation.task = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                guard let resultAdmission =
                        self.audioStealthBoundary.beginAdmission() else {
                    generation.task?.cancel()
                    return
                }
                self.workQueue.async {
                    guard self.audioStealthBoundary.isCurrent(
                              resultAdmission
                          ),
                          !self.hasCancellationRequest() else {
                        generation.task?.cancel()
                        return
                    }
                    if let result {
                        let newText = result.bestTranscription.formattedString
                        // A result carrying speechRecognitionMetadata is a COMPLETED
                        // utterance; the next partial starts a fresh utterance.
                        let utteranceCompleted = result.speechRecognitionMetadata != nil
                        if !newText.isEmpty {
                            if utteranceCompleted {
                                generation.bankCompletedUtterance(newText)
                                generation.latestText = ""
                            } else {
                                // Fallback reset detector: a hard shrink means the
                                // recognizer silently moved to a new utterance —
                                // bank what the previous one had.
                                if newText.count + 10 < generation.latestText.count {
                                    generation.bankCompletedUtterance(generation.latestText)
                                }
                                generation.latestText = newText
                            }
                        }
                        // NOTE: an EMPTY final after a long stream is normal
                        // (macOS 26/27) — fullText keeps the banked/partial text.
                        if !generation.fullText.isEmpty {
                            // Real text means the recognizer is working — a later
                            // failure starts a fresh streak, not a longer wait.
                            self.clearGenerationFailureStreak()
                        }
                        if !generation.hasLoggedFirstPartial, !generation.fullText.isEmpty {
                            generation.hasLoggedFirstPartial = true
                            blNotesLog(
                                "STT first partial observed "
                                    + "chars=\(generation.fullText.count)")
                        }
                        if result.isFinal {
                            blNotesLog("STT FINAL event chars=\(newText.count) kept=\(generation.fullText.count)")
                            self.deliver(generation)
                        }
                    }
                    if let error {
                        // "No speech detected" on a silent chunk lands here — deliver
                        // whatever text exists (possibly nothing).
                        if generation.fullText.isEmpty {
                            self.recordGenerationFailure(error, lifetime: Date().timeIntervalSince(generation.startedAt))
                        }
                        self.deliver(generation)
                    }
                    // A task that finalized or errored is DEAD — audio appended to
                    // its request goes nowhere. Clear it so the next voiced buffer
                    // starts a fresh generation; without this, one early "no speech
                    // detected" (or a natural mid-meeting final on a pause)
                    // silently ends transcription for the rest of the meeting.
                    if (result?.isFinal == true || error != nil), self.currentRequest === request {
                        self.currentRequest = nil
                        self.currentGeneration = nil
                    }
                }
            }
            workQueue.async { [self] in
                isCreatingGeneration = false
                // Don't install a task that was created just before a stop OR a
                // push-to-talk pause — installing it would revive a second
                // on-device task during the hold.
                guard audioStealthBoundary.isCurrent(
                          generationAdmission
                      ),
                      !hasCancellationRequest(),
                      !isStopped,
                      !isPausedForPushToTalk else {
                    generation.task?.cancel()
                    request.endAudio()
                    buffersAwaitingRequest = []
                    return
                }
                blNotesLog("STT generation start onDevice=\(request.requiresOnDeviceRecognition) backlog=\(buffersAwaitingRequest.count)")
                currentRequest = request
                currentGeneration = generation
                for bufferedAudio in buffersAwaitingRequest {
                    guard audioStealthBoundary.performIfCurrent(
                        generationAdmission,
                        {
                            request.append(bufferedAudio)
                            return true
                        }
                    ) == true else {
                        generation.task?.cancel()
                        request.endAudio()
                        currentRequest = nil
                        currentGeneration = nil
                        break
                    }
                }
                buffersAwaitingRequest = []
            }
        }
    }

    /// A generation ended in an error with nothing transcribed. Two very different
    /// things land here and they must not be treated alike:
    ///
    /// - The recognizer listened and heard nothing ("No speech detected" on noise
    ///   or music). That takes seconds of audio and is completely normal — the next
    ///   voiced buffer must start a new generation immediately or meeting speech is
    ///   lost, so this case never backs off.
    /// - The recognizer refused before listening (Siri and Dictation switched off in
    ///   System Settings, service wedged). It dies in the same instant it was
    ///   created, so restarting on the next buffer means hundreds of dead tasks a
    ///   minute against a system that is not going to answer.
    ///
    /// Lifetime is the discriminator: a refusal is over almost as soon as it began.
    private func recordGenerationFailure(_ error: Error, lifetime: TimeInterval) {
        let description = error.localizedDescription
        guard lifetime < Self.instantFailureLifetimeSeconds else {
            clearGenerationFailureStreak()
            blNotesLog("STT ended with error, no text: \(description)")
            return
        }
        consecutiveInstantFailures += 1
        // 1s, 2s, 4s, 8s, 16s, then 30s — a refusing recognizer is retried twice a
        // minute instead of eight times a second, and one good result clears it.
        let backoffSeconds = min(30, pow(2, Double(consecutiveInstantFailures - 1)))
        nextGenerationAllowedAt = Date().addingTimeInterval(backoffSeconds)
        // Deafness surface: once the streak proves the recognizer is deaf (not just
        // hearing silence), signal it ONCE. The brake stops the log storm; this
        // stops the SILENT storm — a founder pressing the hotkey into a wedged
        // recognizer now gets a spoken line and an amber gem instead of nothing.
        if consecutiveInstantFailures >= Self.deafnessSignalThreshold, !hasSignaledDeafnessForCurrentStreak {
            hasSignaledDeafnessForCurrentStreak = true
            blNotesLog("STT DEAFNESS — \(consecutiveInstantFailures) instant refusals (\(description)); surfacing spoken + gem signal (Siri/Dictation likely off)")
            onDeafnessStreakDetected?()
        }
        if description != loggedInstantFailureDescription {
            loggedInstantFailureDescription = description
            blNotesLog("STT ended with error, no text: \(description)")
        } else if consecutiveInstantFailures % 10 == 0 {
            blNotesLog("STT still refusing after \(consecutiveInstantFailures) attempts (\(description)) — next try in \(Int(backoffSeconds))s")
        }
    }

    private func clearGenerationFailureStreak() {
        // Only announce recovery if we had actually surfaced deafness — real text
        // arrives constantly, so an unconditional call would spam the recovery hook.
        let wasDeaf = hasSignaledDeafnessForCurrentStreak
        consecutiveInstantFailures = 0
        nextGenerationAllowedAt = .distantPast
        loggedInstantFailureDescription = nil
        hasSignaledDeafnessForCurrentStreak = false
        if wasDeaf {
            blNotesLog("STT DEAFNESS cleared — hearing recovered after refusal streak")
            onHearingRecovered?()
        }
    }

    private func rotateGeneration() {
        currentRequest?.endAudio()
        if let generation = currentGeneration { pendingGenerations.append(generation) }
        currentRequest = nil
        currentGeneration = nil
        if pendingGenerations.count > 8 {
            // Backstop: a recognizer that never finalizes must not grow memory.
            for generation in pendingGenerations.prefix(pendingGenerations.count - 8) { deliver(generation) }
            pendingGenerations.removeFirst(pendingGenerations.count - 8)
        }
    }

    private func deliver(_ generation: Generation) {
        guard let admission = audioStealthBoundary.beginAdmission(),
              !hasCancellationRequest() else { return }
        var text = ""
        guard audioStealthBoundary.performIfCurrent(
            admission,
            {
                guard !generation.hasDelivered else { return false }
                generation.hasDelivered = true
                pendingGenerations.removeAll { $0 === generation }
                text = generation.fullText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                return !text.isEmpty
            }
        ) == true else { return }
        blNotesLog("STT delivered \(text.count) chars")
        _ = audioStealthBoundary.performIfCurrent(admission) {
            onFinalizedText(text, generation.startedAt)
        }
    }
}
#endif // circuit-convert
