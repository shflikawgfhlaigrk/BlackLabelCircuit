//
//  NoraVoice.swift
//  leanring-buddy
//
//  Self-contained text-to-speech for Ace. The signed app carries the universal
//  inference engine, English model, voice profile, and streaming audio daemon.
//  No Apple optional voice, Siri setting, account, download, API key, or cloud
//  voice service participates at runtime.
//
//  ONE PERSISTENT DAEMON. It loads the model once and streams generated PCM to
//  Core Audio while keeping the established SAY/STOP and BEGAN/DONE receipt
//  protocol used by the one-mouth queue and Stealth cutoff boundary.
//

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Pure launch contract for Ace's bundled persistent voice daemon.
nonisolated struct NoraVoiceDaemonLaunchPlan: Equatable, Sendable {
    static let runtimeDirectoryName = "ace-voice"
    static let executableRelativePath = "bin/ace-voice-daemon"
    static let modelRelativePath = "model"
    static let voiceIdentifier = "ace.voice.kokoro.v0_19.sid3"
    static let maximumCommandByteCount = 16_384

    static var bundledRuntimeRootURL: URL {
        let resourceRoot = Bundle.main.resourceURL
            ?? URL(fileURLWithPath: Bundle.main.bundlePath)
        return resourceRoot.appendingPathComponent(
            runtimeDirectoryName,
            isDirectory: true
        )
    }

    static var bundledExecutablePath: String {
        bundledRuntimeRootURL
            .appendingPathComponent(executableRelativePath)
            .path
    }

    static var bundledModelPath: String {
        bundledRuntimeRootURL
            .appendingPathComponent(modelRelativePath, isDirectory: true)
            .path
    }

    let executablePath: String
    let arguments: [String]

    init(
        supportDirectoryPath: String,
        preferredVoiceIdentifiers: [String] = [
            Self.voiceIdentifier
        ],
        speakingRate: Double = 0.48
    ) {
        self.init(
            supportDirectoryPath: supportDirectoryPath,
            runtimeRootPath: Self.bundledRuntimeRootURL.path,
            preferredVoiceIdentifiers: preferredVoiceIdentifiers,
            speakingRate: speakingRate
        )
    }

    init(
        supportDirectoryPath: String,
        runtimeRootPath: String,
        preferredVoiceIdentifiers: [String] = [
            Self.voiceIdentifier
        ],
        speakingRate: Double = 0.48
    ) {
        let approvedIdentifiers = preferredVoiceIdentifiers.filter {
            PartnerVoiceConfiguration.allowedVoiceIdentifiers.contains($0)
        }
        let selectedIdentifier = approvedIdentifiers.isEmpty
            ? Self.voiceIdentifier
            : approvedIdentifiers[0]
        let runtimeRoot = URL(
            fileURLWithPath: runtimeRootPath,
            isDirectory: true
        )
        executablePath = runtimeRoot
            .appendingPathComponent(Self.executableRelativePath)
            .path
        arguments = [
            supportDirectoryPath,
            runtimeRoot
                .appendingPathComponent(
                    AceLanguage.multilingualVoiceIdentifiers.contains(selectedIdentifier)
                        ? "model-multilingual" : Self.modelRelativePath,
                    isDirectory: true
                )
                .path,
            String(
                format: "%.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                min(max(speakingRate, 0.35), 0.65)
            ),
            selectedIdentifier,
        ]
    }

    static func isCanonicalRequestID(_ candidate: String) -> Bool {
        guard candidate == candidate.lowercased(),
              let uuid = UUID(uuidString: candidate) else {
            return false
        }
        return uuid.uuidString.lowercased() == candidate
    }

    static func sayCommandData(
        requestID: String,
        text: String
    ) -> Data? {
        guard isCanonicalRequestID(requestID),
              !text.isEmpty else {
            return nil
        }
        let payload = Data(text.utf8).base64EncodedString()
        let commandData = Data(
            "SAY \(requestID) \(payload)\n".utf8
        )
        guard commandData.count <= maximumCommandByteCount else {
            return nil
        }
        return commandData
    }

}

/// Pure ownership policy for the daemon and its bounded cold-start verdict
/// probe. Generation and object identity are both required: an object address
/// can be reused after retirement, and callbacks from the retired generation
/// must not be allowed to clear the newer launch.
nonisolated struct NoraVoiceDaemonProbeToken: Equatable, Sendable {
    let generation: UInt64
    let processIdentity: ObjectIdentifier
}

nonisolated struct NoraVoiceDaemonProbeTracker {
    private(set) var generation: UInt64 = 0
    private(set) var currentDaemon: NoraVoiceDaemonProbeToken?
    private(set) var activeVerdictProbe: NoraVoiceDaemonProbeToken?
    private(set) var daemonStartsAreSuppressed = false
    private(set) var isShutDown = false

    var canStartDaemon: Bool {
        !daemonStartsAreSuppressed && !isShutDown
    }

    /// A setup refresh may restart only after the current daemon has either
    /// produced a verdict or exhausted its full 30-second verdict window.
    var shouldRestartDaemonForSetup: Bool {
        canStartDaemon && activeVerdictProbe == nil
    }

    mutating func beginDaemon(for process: AnyObject) -> NoraVoiceDaemonProbeToken? {
        guard canStartDaemon else { return nil }
        generation &+= 1
        let token = NoraVoiceDaemonProbeToken(
            generation: generation,
            processIdentity: ObjectIdentifier(process)
        )
        currentDaemon = token
        activeVerdictProbe = token
        return token
    }

    func ownsCurrentDaemon(_ token: NoraVoiceDaemonProbeToken) -> Bool {
        currentDaemon == token
    }

    func ownsActiveVerdictProbe(_ token: NoraVoiceDaemonProbeToken) -> Bool {
        currentDaemon == token && activeVerdictProbe == token
    }

    @discardableResult
    mutating func finishVerdictProbe(
        ownedBy token: NoraVoiceDaemonProbeToken
    ) -> Bool {
        guard activeVerdictProbe == token else { return false }
        activeVerdictProbe = nil
        return true
    }

    @discardableResult
    mutating func retireDaemon(
        ownedBy token: NoraVoiceDaemonProbeToken
    ) -> Bool {
        guard currentDaemon == token else { return false }
        currentDaemon = nil
        if activeVerdictProbe == token {
            activeVerdictProbe = nil
        }
        return true
    }

    /// Raises the restart wall and invalidates every callback token before the
    /// owning NoraVoice touches the sound-producing process.
    mutating func suspendForStealth() {
        if !daemonStartsAreSuppressed {
            generation &+= 1
        }
        daemonStartsAreSuppressed = true
        currentDaemon = nil
        activeVerdictProbe = nil
    }

    /// Permanently closes daemon admission for the owning NoraVoice instance.
    /// Unlike Stealth suspension, termination can never be resumed by a late
    /// exit callback.
    mutating func shutdown() {
        if !daemonStartsAreSuppressed {
            generation &+= 1
        }
        isShutDown = true
        daemonStartsAreSuppressed = true
        currentDaemon = nil
        activeVerdictProbe = nil
    }

    /// Drops only the restart wall. No daemon is created here; the next explicit
    /// speak/warm-up/setup operation may start one lazily.
    mutating func resumeAfterStealth() {
        guard !isShutDown else { return }
        daemonStartsAreSuppressed = false
    }
}

nonisolated struct NoraVoiceDaemonEndpoint: Equatable, Sendable {
    let token: NoraVoiceDaemonProbeToken
    let processIdentifier: pid_t
    /// A descriptor duplicated exclusively for the Stealth cutoff. Normal
    /// daemon retirement and MainActor state cleanup cannot close it out from
    /// under the event-tap callback.
    let cutoffControlDescriptor: Int32
}

/// The off-MainActor sound boundary. It serializes daemon launch and command
/// admission against the process-wide Private Mode entry latch, and owns the
/// one nonblocking
/// primitive that can silence an already-playing daemon in the event-tap turn.
///
/// MainActor state remains the source of truth for normal queue semantics. This
/// boundary only answers the narrower safety question: can sound still begin or
/// continue after the owner has requested Stealth?
/// Process-wide, lock-guarded "Nora is speaking right now" flag.
///
/// Build 62's `VoiceReadiness` re-probed the voice on every app activation and
/// demanded a FRESH daemon, which retired the running one — and a retired daemon
/// takes the in-flight utterance with it. That produced VOICE-PLAYBACK BEGAN
/// lines with no DONE (137 BEGAN vs 114 DONE in one session, 8 of them killed by
/// a restart on the very next log line). A cut readback is not merely cosmetic:
/// the app-action and full-access consent cards refuse to arm until Nora reports
/// the exact untruncated readback finished, so every killed utterance silently
/// disarmed the buyer's approval and the same review reappeared forever.
///
/// Activation no longer retires a proven daemon at all (issue #21 — ONE
/// persistent daemon; see `VoiceActivationRefreshPolicy`). The latch still
/// guards every remaining fresh-daemon path: the failed-proof retry on
/// activation, the explicit voice repair, and setup's slow-cadence recheck.
///
/// `VoiceReadiness` cannot hold a `NoraVoice` reference (it is constructed inside
/// `CompanionManager`), so the two communicate through this latch exactly as the
/// Stealth wall does.
nonisolated final class NoraSpeechActivityLatch: @unchecked Sendable {
    static let shared = NoraSpeechActivityLatch()

    private let lock = NSLock()
    private var speakingStorage = false
    private var speechEndedAtStorage = Date.distantPast

    /// True from the moment an utterance is sent until the daemon reports it
    /// finished, stopped, or blocked.
    var isSpeaking: Bool {
        lock.withLock { speakingStorage }
    }

    /// When Ace's mouth last closed. `distantPast` until Ace has spoken once.
    ///
    /// Read by `AceSelfVoiceCaptureGate` on the audio thread: the instant the
    /// daemon reports DONE the room has NOT gone quiet, so the capture boundary
    /// needs the end timestamp, not just the boolean, to hold a short acoustic
    /// tail. Without it the last syllable of Ace's own sentence lands in the
    /// recognizer and comes back as an owner command.
    var speechEndedAt: Date {
        lock.withLock { speechEndedAtStorage }
    }

    func markSpeaking() {
        lock.withLock { speakingStorage = true }
    }

    func markNotSpeaking() {
        lock.withLock {
            // Only a real speaking→silent transition moves the tail forward.
            // The stop paths call this defensively more than once, and a
            // repeated stamp would extend suppression past the tail every time.
            if speakingStorage { speechEndedAtStorage = Date() }
            speakingStorage = false
        }
    }
}

nonisolated final class NoraVoiceStealthBoundary: @unchecked Sendable {
    typealias CutoffPrimitive =
        @Sendable (NoraVoiceDaemonEndpoint) -> Void

    private let lock = NSLock()
    private let entryLatch: StealthEntryLatch
    private let cutoffPrimitive: CutoffPrimitive
    private var isCutOffStorage: Bool
    private var activeDaemon: NoraVoiceDaemonEndpoint?

    init(
        entryLatch: StealthEntryLatch,
        cutoffPrimitive: CutoffPrimitive? = nil
    ) {
        self.entryLatch = entryLatch
        let defaultCutoffPrimitive: CutoffPrimitive = { endpoint in
            NoraVoiceStealthBoundary.stopAndTerminateDaemon(endpoint)
        }
        self.cutoffPrimitive =
            cutoffPrimitive ?? defaultCutoffPrimitive
        self.isCutOffStorage = entryLatch.isRaised
    }

    var isCutOff: Bool {
        lock.withLock {
            isCutOffStorage || entryLatch.isRaised
        }
    }

    /// Holds only this small boundary while `Process.run()` performs its bounded
    /// launch syscall. If X wins first, launch is rejected. If X arrives during
    /// launch, the post-launch latch check terminates the child before this
    /// method returns and before any SAY command can be admitted.
    func launchDaemonIfAllowed(
        token: NoraVoiceDaemonProbeToken,
        controlDescriptor: Int32,
        launch: () throws -> pid_t
    ) rethrows -> Bool {
        lock.lock()
        guard !isCutOffStorage, !entryLatch.isRaised else {
            isCutOffStorage = true
            lock.unlock()
            return false
        }

        let originalFlags = fcntl(controlDescriptor, F_GETFL)
        guard originalFlags >= 0,
              fcntl(
                  controlDescriptor,
                  F_SETFL,
                  originalFlags | O_NONBLOCK
              ) == 0 else {
            lock.unlock()
            return false
        }
        let cutoffControlDescriptor = dup(controlDescriptor)
        guard cutoffControlDescriptor >= 0,
              fcntl(
                  cutoffControlDescriptor,
                  F_SETFD,
                  FD_CLOEXEC
              ) == 0 else {
            if cutoffControlDescriptor >= 0 {
                close(cutoffControlDescriptor)
            }
            lock.unlock()
            return false
        }

        let processIdentifier: pid_t
        do {
            processIdentifier = try launch()
        } catch {
            close(cutoffControlDescriptor)
            lock.unlock()
            throw error
        }

        let endpoint = NoraVoiceDaemonEndpoint(
            token: token,
            processIdentifier: processIdentifier,
            cutoffControlDescriptor: cutoffControlDescriptor
        )
        if isCutOffStorage || entryLatch.isRaised {
            isCutOffStorage = true
            // X may already be waiting in cutOffSynchronously() for this
            // boundary lock. Complete the just-launched endpoint's cutoff
            // before releasing that lock; otherwise X's callback can acquire
            // it first, observe no activeDaemon, return, and let
            // raiseInProcess() finish a few instructions before this cutoff.
            cutoffPrimitive(endpoint)
            lock.unlock()
            return false
        } else {
            activeDaemon = endpoint
        }
        lock.unlock()
        return true
    }

    /// One nonblocking pipe write serialized with X admission. Normal voice/UI
    /// work may never wait behind an in-flight daemon launch: if this boundary
    /// is busy, the command fails closed and its caller can recover without
    /// freezing Ace's MainActor. Private entry uses `cutOffSynchronously()` and
    /// still waits for the launch boundary before it returns. A short write or
    /// EAGAIN is fail-closed: the daemon is terminated so it cannot interpret a
    /// truncated SAY as a later request.
    func sendCommandIfAllowed(
        _ commandData: Data,
        through controlDescriptor: Int32
    ) -> Bool {
        var endpointToCutOff: NoraVoiceDaemonEndpoint?

        guard lock.try() else {
            return false
        }
        guard !isCutOffStorage, !entryLatch.isRaised else {
            isCutOffStorage = true
            endpointToCutOff = activeDaemon
            activeDaemon = nil
            lock.unlock()
            if let endpointToCutOff {
                cutoffPrimitive(endpointToCutOff)
            }
            return false
        }

        let writtenByteCount = commandData.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return Darwin.write(
                controlDescriptor,
                baseAddress,
                bytes.count
            )
        }
        let didWriteWholeCommand =
            writtenByteCount == commandData.count
        if !didWriteWholeCommand {
            endpointToCutOff = activeDaemon
            activeDaemon = nil
        }
        lock.unlock()

        if let endpointToCutOff {
            cutoffPrimitive(endpointToCutOff)
        }
        return didWriteWholeCommand
    }

    /// Invoked directly by `StealthEntryLatch`, never by MainActor dispatch.
    /// State is cut off before the descriptor/PID snapshot is released.
    func cutOffSynchronously() {
        let endpointToCutOff = lock.withLock {
            isCutOffStorage = true
            let endpointToCutOff = activeDaemon
            activeDaemon = nil
            return endpointToCutOff
        }
        if let endpointToCutOff {
            cutoffPrimitive(endpointToCutOff)
        }
    }

    /// A termination callback retires ownership off-main before it queues any
    /// MainActor cleanup, preventing PID/descriptor reuse during an actor stall.
    func retireDaemon(ownedBy token: NoraVoiceDaemonProbeToken) {
        let retiredEndpoint = lock.withLock {
            guard activeDaemon?.token == token else {
                return nil as NoraVoiceDaemonEndpoint?
            }
            let retiredEndpoint = activeDaemon
            activeDaemon = nil
            return retiredEndpoint
        }
        if let retiredEndpoint {
            close(retiredEndpoint.cutoffControlDescriptor)
        }
    }

    /// Only the verified Stealth exit path may lower this local sound wall.
    @discardableResult
    func resumeAfterVerifiedExit() -> Bool {
        lock.withLock {
            guard !entryLatch.isRaised else { return false }
            isCutOffStorage = false
            return true
        }
    }

    /// Event-tap safe: one best-effort nonblocking STOP write followed by
    /// immediate process freeze and kill. No process wait, actor hop, fsync,
    /// directory lookup, or allocation-dependent retry loop occurs here.
    private static func stopAndTerminateDaemon(
        _ endpoint: NoraVoiceDaemonEndpoint
    ) {
        var stopBytes: (UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0x53, 0x54, 0x4F, 0x50, 0x0A)
        withUnsafeBytes(of: &stopBytes) { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            _ = Darwin.write(
                endpoint.cutoffControlDescriptor,
                baseAddress,
                bytes.count
            )
        }
        close(endpoint.cutoffControlDescriptor)

        guard endpoint.processIdentifier > 1 else { return }
        _ = Darwin.kill(endpoint.processIdentifier, SIGSTOP)
        _ = Darwin.kill(endpoint.processIdentifier, SIGKILL)
    }
}

/// Correlates daemon events to the exact SAY request that produced them. A
/// bare/stale DONE can never become a completion receipt for a newer line.
nonisolated struct NoraVoiceDaemonEvent: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case began = "BEGAN"
        case done = "DONE"
        case stopped = "STOPPED"
        case blocked = "BLOCKED"
    }

    let kind: Kind
    let requestID: String

    init?(line: String) {
        guard !line.isEmpty,
              line.utf8.count <= 128,
              line == line.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !line.contains("\t") else {
            return nil
        }
        let fields = line.split(
            separator: " ",
            omittingEmptySubsequences: false
        )
        guard fields.count == 2,
              let kind = Kind(rawValue: String(fields[0])),
              NoraVoiceDaemonLaunchPlan.isCanonicalRequestID(
                  String(fields[1])
              ) else {
            return nil
        }
        self.kind = kind
        requestID = String(fields[1])
    }
}

struct NoraSpeechReceiptTracker {
    enum EventResult: Equatable {
        case ignored
        case began
        case finished(VoiceQueue.Completion)
    }

    private(set) var activeRequestID: String?
    private var activeRequestHasBegun = false
    private var outcomes: [String: VoiceQueue.Completion] = [:]

    mutating func begin(requestID: String) -> Bool {
        guard NoraVoiceDaemonLaunchPlan.isCanonicalRequestID(
                  requestID
              ),
              activeRequestID == nil else {
            return false
        }
        activeRequestID = requestID
        activeRequestHasBegun = false
        outcomes.removeValue(forKey: requestID)
        return true
    }

    mutating func record(event: String, requestID: String) -> EventResult {
        guard activeRequestID == requestID else { return .ignored }
        switch event {
        case "BEGAN":
            guard !activeRequestHasBegun else { return .ignored }
            activeRequestHasBegun = true
            return .began
        case "DONE":
            guard activeRequestHasBegun else {
                return finish(requestID: requestID, as: .failed)
            }
            return finish(requestID: requestID, as: .completed)
        case "STOPPED":
            return finish(requestID: requestID, as: .interrupted)
        case "BLOCKED":
            return finish(requestID: requestID, as: .failed)
        default:
            return .ignored
        }
    }

    @discardableResult
    mutating func finish(
        requestID: String,
        as completion: VoiceQueue.Completion
    ) -> EventResult {
        guard activeRequestID == requestID else { return .ignored }
        activeRequestID = nil
        activeRequestHasBegun = false
        outcomes[requestID] = completion
        return .finished(completion)
    }

    @discardableResult
    mutating func finishActive(
        as completion: VoiceQueue.Completion
    ) -> String? {
        guard let requestID = activeRequestID else { return nil }
        _ = finish(requestID: requestID, as: completion)
        return requestID
    }

    func outcome(for requestID: String) -> VoiceQueue.Completion? {
        outcomes[requestID]
    }

    mutating func takeOutcome(
        for requestID: String
    ) -> VoiceQueue.Completion? {
        outcomes.removeValue(forKey: requestID)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class NoraVoice {
    /// Readable fallback owned by CompanionManager. It fires only when an
    /// utterance genuinely failed; user interruption and Stealth stay silent.
    var onDeliveryFailure: ((String) -> Void)?
    /// Fired only from the daemon's correlated BEGAN receipt for the exact
    /// utterance currently owned by the one-mouth queue.
    var onDeliveryStarted: ((String) -> Void)?
    /// Content-free activity edge for the live-install gate. This never
    /// exposes the utterance; it reports only whether playback work exists.
    var onPlaybackActivityChanged: ((Bool) -> Void)?
    /// Retire idle automatic listening before taking the speech lease.
    /// Awaiting a real owner utterance remains cancellable by Stop/barge-in.
    var prepareMicrophoneForSpeech: (() async -> Bool)?

    /// Existing Stealth integration assigns this property. Its setter is now the
    /// synchronous process boundary: entry does not return until Nora's daemon
    /// has exited; exit merely lowers the restart wall and never starts speech.
    var isSuppressed: Bool {
        get {
            daemonProbeTracker.daemonStartsAreSuppressed
                || stealthSpeechBoundary.isCutOff
                || StealthEntryLatch.shared.isRaised
        }
        set {
            if newValue {
                suspendSynchronouslyForStealth()
            } else {
                resumeAfterStealth()
            }
        }
    }

    // MARK: - Daemon lifetime

    private var daemonProcess: Process?
    private var daemonStandardInput: Pipe?
    private var daemonProbeTracker = NoraVoiceDaemonProbeTracker()
    private var speechReceiptTracker = NoraSpeechReceiptTracker()
    private var speechTextByRequestID: [String: String] = [:]
    private var daemonVerdictProbeTask: Task<Void, Never>?
    private var speechStartTimeoutTask: Task<Void, Never>?
    private var speechStartTimedOutRequestIDs: Set<String> = []
    private var daemonOutputBuffer = Data()
    private let stealthSpeechBoundary: NoraVoiceStealthBoundary
    private var stealthEntryCutoffRegistration: UUID?
    /// True from the daemon's BEGAN line until its DONE/STOPPED line.
    private var daemonReportsSpeaking = false
    /// True from the moment SAY is sent until BEGAN arrives (or the pending
    /// window stales out). Without this, isPlaying was FALSE in the gap between
    /// sending an utterance and the daemon's BEGAN event — every caller that
    /// speaks-then-waits saw "not playing", declared the line finished, and the
    /// NEXT line's SAY replaced it mid-sentence. That was the founder's "ace
    /// cuts off the voicing" during the buyer walkthrough (2026-07-26).
    private var awaitingSpeechStart = false
    /// Generation stamp so a stale pending-window timeout can never clear the
    /// pending state of a NEWER utterance.
    private var speechGeneration = 0
    private var voiceConfiguration =
        AceVoiceModePolicy.standardConfiguration
    private var voiceConfigurationRevision = 0
    private var activeVoicePreview:
        (id: UUID, previous: PartnerVoiceConfiguration)?
    private let audioSessionCoordinator: AudioSessionCoordinator?

    // MARK: Speech lease
    //
    // The coordinator's speech lease used to be released ONLY by the `defer`
    // inside the voice queue's speak closure. That defer runs after
    // `driveDaemonToCompletion` unwinds — i.e. after the daemon has actually
    // stopped making sound — so `stopPlayback()` returned to its caller with the
    // lease still held. `CompanionManager` calls `stopPlayback()` and then
    // immediately starts push-to-talk capture, which the coordinator refused
    // ("Voice playback is finishing"); `BuddyDictationManager` treats a refusal
    // as a hard stop, so the barge-in press recorded NOTHING. That is the
    // founder's "why does the first attempt fail" — it fails whenever the owner
    // presses to talk while Ace is still speaking, which is normal use.
    // `haltDaemonNow` now hands the lease back synchronously, on the spot.
    //
    // The serial is what keeps the two release paths from fighting. Every
    // successful acquisition stamps a fresh serial; a release fires only if it
    // still owns that serial. So the flushed utterance's `defer`, which resumes
    // on the main actor at some later hop — possibly after a replacement
    // utterance has already taken its own lease — releases nothing instead of
    // yanking the microphone floor out from under the new speech.
    private var speechLeaseSerial = 0
    private var speechLeaseIsHeld = false

    init(audioSessionCoordinator: AudioSessionCoordinator? = nil) {
        self.audioSessionCoordinator = audioSessionCoordinator
        let stealthSpeechBoundary = NoraVoiceStealthBoundary(
            entryLatch: StealthEntryLatch.shared
        )
        self.stealthSpeechBoundary = stealthSpeechBoundary
        stealthEntryCutoffRegistration =
            StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                [weak stealthSpeechBoundary] in
                stealthSpeechBoundary?.cutOffSynchronously()
            }

        Self.ensureSupportDirectory()
        // Remove source/binary artifacts of every retired helper design. The
        // current daemon source exists only inside this signed app binary.
        for staleName in [
            "tts-nora-daemon.swift",
            "tts-voice-bin",
            "tts-voice.swift",
            "tts-warmup.swift",
        ] {
            if let staleURL = Self.supportDirectory?.appendingPathComponent(staleName) {
                try? FileManager.default.removeItem(at: staleURL)
            }
        }
    }

    deinit {
        if let stealthEntryCutoffRegistration {
            StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(
                stealthEntryCutoffRegistration
            )
        }
        stealthSpeechBoundary.cutOffSynchronously()
    }

    /// ONE MOUTH (VoiceQueue, ported from utah-Ace 2026-07-26): every lane's
    /// speech drains through this queue one item at a time, so the background
    /// agent finishing can never talk over a gold answer mid-sentence. A live
    /// reply (.foreground) jumps ahead of queued announcements; "stop" flushes.
    private lazy var voiceQueue = VoiceQueue(
        speak: { [weak self] spokenText in
            guard let self else { return .failed }
            return await self.speakQueuedTextToCompletion(spokenText)
        },
        haltCurrent: { [weak self] in
            self?.haltDaemonNow()
            // Restore before a replacement queue generation can speak.
            self?.restorePreviewVoiceConfiguration()
        },
        activityDidChange: { [weak self] active in
            self?.onPlaybackActivityChanged?(active)
        },
        // Everything Ace says becomes a labeled OUTBOUND event here — the one
        // place all ~80 speech call sites already funnel through. `.gold` lane
        // speech is sourced `.ace` (it is Ace's voice); the work lanes keep
        // their own source so Red's receipt can never be mistaken for Ace's
        // conversational reply, let alone for the owner.
        publishOutbound: { lane, state, spokenText, itemIdentifier in
            AceEventBus.shared.publishTerminalWork(
                source: .forVoiceLane(lane),
                state: state,
                payloadType: lane == .gold ? .aceSpeech : .laneReceipt,
                payload: spokenText,
                turnID: AceEventBus.shared.currentTurnID,
                correlationID: itemIdentifier
            )
        }
    )

    private func speakQueuedTextToCompletion(
        _ spokenText: String
    ) async -> VoiceQueue.Completion {
        if let prepare = self.prepareMicrophoneForSpeech,
           !(await prepare()) { return .interrupted }
        guard !Task.isCancelled, !self.isSuppressed else {
            return .interrupted
        }
        let lease = self.acquireSpeechLease()
        if let visibleFailure = lease.visibleFailure {
            self.onDeliveryFailure?(spokenText)
            Self.appendVoiceSafetyReceipt(
                "AUDIO-OWNER refused speech reason=\(visibleFailure)"
            )
            return .failed
        }
        // Still the normal end-of-utterance release. It is now serial-gated,
        // so it is a no-op when barge-in already released this lease — and
        // it can never release a LATER utterance's lease.
        defer {
            self.releaseSpeechLease(serial: lease.serial)
            self.onPlaybackActivityChanged?(self.isPlaying)
        }
        let completion =
            await self.driveDaemonToCompletion(spokenText)
        if completion == .failed {
            self.onDeliveryFailure?(spokenText)
        }
        return completion
    }

    /// Speaks `text` aloud in the Nora voice. Enqueues on the one-mouth queue —
    /// foreground/gold by default, so the 80 existing conversational call sites
    /// keep their behavior untouched. Background lanes pass their lane and
    /// `.background` so their announcements WAIT instead of cutting in.
    func speakText(_ text: String,
                   from lane: VoiceQueue.Lane = .gold,
                   priority: VoiceQueue.Priority = .foreground) async throws {
        guard !StealthEntryLatch.shared.isRaised, !isSuppressed else {
            return
        }
        let spokenText = Self.strippingSpokenMarkdown(
            from: Self.strippingCursorPointTags(from: text))
        guard !spokenText.isEmpty else { return }
        guard !Self.containsBlockedSpokenLanguage(spokenText) else {
            Self.appendVoiceSafetyReceipt(
                "BLOCKED source=app lane=\(lane.rawValue) characters=\(spokenText.count)")
            return
        }
        voiceQueue.enqueue(spokenText, from: lane, priority: priority)
    }

    /// Speaks local sensitive text without placing that text in AceTranscript
    /// or the outbound AceEvent stream. Admission is synchronous so a Stop or
    /// Private Mode boundary cannot flush the queue and then be followed by a
    /// detached late enqueue.
    @discardableResult
    func enqueueVolatileText(
        _ text: String,
        from lane: VoiceQueue.Lane = .gold,
        priority: VoiceQueue.Priority = .foreground
    ) -> Bool {
        guard !StealthEntryLatch.shared.isRaised, !isSuppressed else {
            return false
        }
        let spokenText = Self.strippingSpokenMarkdown(
            from: Self.strippingCursorPointTags(from: text)
        )
        guard !spokenText.isEmpty else { return false }
        guard !Self.containsBlockedSpokenLanguage(spokenText) else {
            Self.appendVoiceSafetyReceipt(
                "BLOCKED source=app lane=\(lane.rawValue) characters=\(spokenText.count)"
            )
            return false
        }
        return voiceQueue.enqueue(
            spokenText,
            from: lane,
            priority: priority,
            persistence: .volatile
        )
    }

    var repeatableResponseText: String? {
        guard !isSuppressed else { return nil }
        return voiceQueue.repeatableResponseText
    }

    /// Safety-sensitive speech receipt. Unlike `speakText`, this stays suspended
    /// until this exact queue item receives DONE from Nora's daemon. Any other
    /// terminal condition returns false and cannot authorize a downstream
    /// effect.
    func speakTextToVerifiedCompletion(
        _ text: String,
        from lane: VoiceQueue.Lane = .gold,
        priority: VoiceQueue.Priority = .foreground,
        persistence: VoiceQueue.Persistence = .durableTranscriptAndEvents
    ) async -> Bool {
        guard !StealthEntryLatch.shared.isRaised,
              !isSuppressed,
              !Task.isCancelled else {
            return false
        }
        let spokenText = Self.strippingSpokenMarkdown(
            from: Self.strippingCursorPointTags(from: text))
        guard !spokenText.isEmpty else { return false }
        guard !Self.containsBlockedSpokenLanguage(spokenText) else {
            Self.appendVoiceSafetyReceipt(
                "BLOCKED source=app lane=\(lane.rawValue) characters=\(spokenText.count)")
            return false
        }
        let completion = await voiceQueue.enqueueAndWait(
            spokenText,
            from: lane,
            priority: priority,
            persistence: persistence
        )
        return completion == .completed
            && !Task.isCancelled
            && !StealthEntryLatch.shared.isRaised
            && !isSuppressed
    }

    /// App-action review is different from conversational speech. Punctuation,
    /// Markdown marks, URLs, and bracketed text may be literal message or note
    /// content, so none of it may be stripped before the completion receipt.
    /// The immutable on-screen card remains the character-for-character source
    /// of truth; this method proves Nora reached the end of the same unmodified
    /// string before a confirmation window can open.
    func speakVerbatimTextToVerifiedCompletion(
        _ text: String,
        from lane: VoiceQueue.Lane = .gold,
        priority: VoiceQueue.Priority = .foreground
    ) async -> Bool {
        guard !StealthEntryLatch.shared.isRaised,
              !isSuppressed,
              !Task.isCancelled else {
            return false
        }
        let spokenText = Self.verbatimSafetyReadbackText(text)
        guard !spokenText.isEmpty else { return false }
        guard !Self.containsBlockedSpokenLanguage(spokenText) else {
            Self.appendVoiceSafetyReceipt(
                "BLOCKED source=app lane=\(lane.rawValue) characters=\(spokenText.count)")
            return false
        }
        let completion = await voiceQueue.enqueueAndWait(
            spokenText,
            from: lane,
            priority: priority
        )
        return completion == .completed
            && !Task.isCancelled
            && !StealthEntryLatch.shared.isRaised
            && !isSuppressed
    }

    nonisolated static func verbatimSafetyReadbackText(
        _ text: String
    ) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True while the voice is mid-line or has lines waiting — the queue is part
    /// of "playing", so speak-then-wait callers (the tour) hold for their whole
    /// utterance to actually finish draining.
    var isVoiceBusy: Bool {
        !isSuppressed && voiceQueue.hasPendingOrSpeaking
    }

    /// The queue's speak closure: hand ONE utterance to the daemon and stay
    /// suspended until the daemon reports it finished (or was stopped).
    private func driveDaemonToCompletion(
        _ spokenText: String
    ) async -> VoiceQueue.Completion {
        let deliveryAttempt = await VoiceDaemonRecoveryPolicy.deliver(
            attempt: { [weak self] attemptContext in
                guard let self else { return .interrupted }
                return await self.driveDaemonAttempt(
                    spokenText,
                    attemptContext: attemptContext
                )
            },
            recycle: { [weak self] in
                guard let self,
                      !StealthEntryLatch.shared.isRaised,
                      !self.isSuppressed else { return }
                LifecycleLog.append(
                    "VOICE daemon missed BEGAN — recycling once"
                )
                self.retireCurrentDaemon(
                    terminateIfRunning: true
                )
            }
        )
        switch deliveryAttempt {
        case .completed:
            return .completed
        case .interrupted:
            return .interrupted
        case .failed, .startTimedOut:
            return .failed
        }
    }

    private func driveDaemonAttempt(
        _ spokenText: String,
        attemptContext: VoiceDaemonAttemptContext
    ) async -> VoiceDaemonDeliveryAttempt {
        guard !StealthEntryLatch.shared.isRaised, !isSuppressed else {
            return VoiceDaemonDeliveryAttempt.interrupted
        }
        await VoiceReadiness.shared.waitForInitialProbeIfNeeded()
        guard !StealthEntryLatch.shared.isRaised, !isSuppressed else {
            return VoiceDaemonDeliveryAttempt.interrupted
        }
        ensureDaemonRunning()
        let readinessState =
            await VoiceReadiness.shared.waitForDaemonVerdictIfNeeded()
        guard !StealthEntryLatch.shared.isRaised,
              !isSuppressed,
              readinessState == .ready,
              daemonProcess?.isRunning == true else {
            reportVoiceUnavailable()
            return isSuppressed ? .interrupted : .failed
        }
        // isPlaying must be true from THIS moment, not from the daemon's BEGAN
        // — a false gap here is what once let lines replace each other.
        speechGeneration += 1
        let generationAtSend = speechGeneration
        let requestID = UUID().uuidString.lowercased()
        guard speechReceiptTracker.begin(requestID: requestID) else {
            return VoiceDaemonDeliveryAttempt.failed
        }
        defer {
            speechStartTimedOutRequestIDs.remove(requestID)
        }
        speechTextByRequestID[requestID] = spokenText
        defer { speechTextByRequestID.removeValue(forKey: requestID) }
        awaitingSpeechStart = true
        NoraSpeechActivityLatch.shared.markSpeaking()
        LifecycleLog.append(
            "VOICE started request=\(requestID) attempt=\(attemptContext.receiptLabel) characters=\(spokenText.count)"
        )
        speechStartTimeoutTask?.cancel()
        let speechStartDeadlineSeconds =
            VoiceStartDeadlinePolicy.seconds(
                forCharacterCount: spokenText.count,
                attemptContext: attemptContext
            )
        speechStartTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(speechStartDeadlineSeconds)
                )
            } catch {
                return
            }
            guard let self,
                  !StealthEntryLatch.shared.isRaised,
                  !self.isSuppressed,
                  self.speechGeneration == generationAtSend,
                  self.speechReceiptTracker.activeRequestID == requestID else {
                return
            }
            // BEGAN never came for this utterance (decode failure, daemon hiccup)
            // — clear the pending flag so the wait below can't wedge forever.
            self.awaitingSpeechStart = false
            self.daemonReportsSpeaking = false
            self.speechStartTimedOutRequestIDs.insert(requestID)
            LifecycleLog.append(
                "VOICE start timed out request=\(requestID) characters=\(spokenText.count) deadlineSeconds=\(Int(speechStartDeadlineSeconds))"
            )
            _ = self.speechReceiptTracker.finish(
                requestID: requestID,
                as: .failed
            )
            self.send(command: "STOP")
            self.speechStartTimeoutTask = nil
        }
        guard let commandData =
                NoraVoiceDaemonLaunchPlan.sayCommandData(
                    requestID: requestID,
                    text: spokenText
                ),
              send(commandData: commandData) else {
            speechStartTimeoutTask?.cancel()
            speechStartTimeoutTask = nil
            awaitingSpeechStart = false
            _ = speechReceiptTracker.finish(
                requestID: requestID,
                as: .failed
            )
            return Self.deliveryAttempt(
                from: speechReceiptTracker.takeOutcome(
                    for: requestID
                ) ?? .failed
            )
        }

        // Only a matching DONE creates `.completed`. STOPPED, BLOCKED, timeout,
        // daemon death, Stealth, queue flush, and task cancellation all publish
        // a non-success outcome for this request ID.
        while speechReceiptTracker.outcome(for: requestID) == nil {
            if Task.isCancelled {
                _ = speechReceiptTracker.finish(
                    requestID: requestID,
                    as: .interrupted
                )
                haltDaemonNow()
                break
            }
            guard !StealthEntryLatch.shared.isRaised,
                  !isSuppressed,
                  daemonProcess?.isRunning == true else {
                _ = speechReceiptTracker.finish(
                    requestID: requestID,
                    as: StealthEntryLatch.shared.isRaised || isSuppressed
                        ? .interrupted
                        : .failed
                )
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                _ = speechReceiptTracker.finish(
                    requestID: requestID,
                    as: .interrupted
                )
                haltDaemonNow()
            }
        }
        let completion = speechReceiptTracker.takeOutcome(
            for: requestID
        ) ?? .failed
        if speechStartTimedOutRequestIDs.contains(requestID) {
            return .startTimedOut
        }
        return Self.deliveryAttempt(from: completion)
    }

    private static func deliveryAttempt(
        from completion: VoiceQueue.Completion
    ) -> VoiceDaemonDeliveryAttempt {
        switch completion {
        case .completed:
            return .completed
        case .interrupted:
            return .interrupted
        case .failed:
            return .failed
        }
    }

    /// Takes the coordinator's speech lease for one utterance. Returns the serial
    /// that owns the lease, or the microphone owner's visible refusal when speech
    /// may not start (in which case nothing was taken and nothing must be given
    /// back). A `nil` coordinator is the standalone/test configuration: the lease
    /// is still tracked locally so the release path stays identical.
    private func acquireSpeechLease() -> (serial: Int, visibleFailure: String?) {
        if let visibleFailure = audioSessionCoordinator?
            .beginSpeech().visibleFailure {
            return (speechLeaseSerial, visibleFailure)
        }
        speechLeaseSerial &+= 1
        speechLeaseIsHeld = true
        return (speechLeaseSerial, nil)
    }

    /// Hands the lease back exactly once, and only for the utterance that still
    /// owns it. A stale serial is a deliberate no-op — never a double release,
    /// never a release of somebody else's lease.
    private func releaseSpeechLease(serial: Int) {
        guard speechLeaseIsHeld, serial == speechLeaseSerial else { return }
        speechLeaseIsHeld = false
        _ = audioSessionCoordinator?.endSpeech()
    }

    /// Immediate daemon halt — the queue's barge-in primitive. Internal only:
    /// public stopPlayback goes through the queue flush so queued lines die too.
    private func haltDaemonNow() {
        speechGeneration += 1
        speechStartTimeoutTask?.cancel()
        speechStartTimeoutTask = nil
        _ = speechReceiptTracker.finishActive(as: .interrupted)
        awaitingSpeechStart = false
        daemonReportsSpeaking = false
        NoraSpeechActivityLatch.shared.markNotSpeaking()
        // THE BARGE-IN RELEASE. Every other line above already declares this
        // mouth closed; the lease has to close with them, synchronously, so that
        // the push-to-talk press which triggered this halt finds the microphone
        // free the moment `stopPlayback()` returns. Placed BEFORE the
        // daemon-running guard on purpose: a halt with no live daemon must still
        // free the lease, or a failed/never-started utterance would strand it.
        releaseSpeechLease(serial: speechLeaseSerial)
        guard daemonProcess?.isRunning == true else { return }
        send(command: "STOP")
    }

    /// Warms the whole speech path at launch: starts the built-in JXA host,
    /// resolves Nora, speaks one muted real word to spool the neural vocoder,
    /// and writes voice-served.log. Nothing is audible. Every later utterance
    /// starts on a warm engine.
    func warmUpSilently() {
        guard !StealthEntryLatch.shared.isRaised, !isSuppressed else {
            return
        }
        ensureDaemonRunning()
    }

    func applyPartnerVoiceConfiguration(
        _ configuration: PartnerVoiceConfiguration
    ) {
        voiceConfigurationRevision &+= 1
        let hadPreview = activeVoicePreview != nil
        activeVoicePreview = nil
        if hadPreview || configuration != voiceConfiguration {
            voiceQueue.interruptAndFlush()
        }
        replaceVoiceConfiguration(configuration)
    }

    private func replaceVoiceConfiguration(
        _ configuration: PartnerVoiceConfiguration
    ) {
        guard configuration != voiceConfiguration else {
            return
        }
        retireCurrentDaemon(
            terminateIfRunning: true,
            waitForExit: true
        )
        voiceConfiguration = configuration
        VoiceReadiness.shared.probe(
            requiresFreshDaemonVerdict: true
        )
        warmUpSilently()
    }

    private func restorePreviewVoiceConfiguration() {
        guard let preview = activeVoicePreview else { return }
        activeVoicePreview = nil
        replaceVoiceConfiguration(preview.previous)
    }

    /// The sample is a single volatile queue item. Its configuration never
    /// persists and is restored before the next utterance acquires the mouth.
    func previewPartnerVoiceConfiguration(
        _ configuration: PartnerVoiceConfiguration
    ) async -> Bool {
        guard !Task.isCancelled, !isSuppressed,
              !StealthEntryLatch.shared.isRaised else { return false }
        let requestedRevision = voiceConfigurationRevision
        let completion = await voiceQueue.enqueueAndWait(
            configuration.previewSentence,
            from: .gold,
            persistence: .volatile,
            speechOverride: { [weak self] text in
                guard let self, !Task.isCancelled, !self.isSuppressed,
                      !StealthEntryLatch.shared.isRaised,
                      self.voiceConfigurationRevision == requestedRevision else {
                    return .interrupted
                }
                let identifier = UUID()
                self.activeVoicePreview = (identifier, self.voiceConfiguration)
                self.replaceVoiceConfiguration(configuration)
                defer {
                    if self.activeVoicePreview?.id == identifier {
                        self.restorePreviewVoiceConfiguration()
                    }
                }
                return await self.speakQueuedTextToCompletion(text)
            }
        )
        return completion == .completed && !Task.isCancelled
            && !isSuppressed && !StealthEntryLatch.shared.isRaised
    }

    /// Starts the daemon that owns this exact readiness request. A newer
    /// request always retires the older daemon first, even when the host path
    /// is unchanged, so an activation refresh cannot reuse stale Nora truth.
    func beginReadinessVerdict(
        _ request: VoiceDaemonVerdictRequest
    ) {
        guard !StealthEntryLatch.shared.isRaised,
              !isSuppressed,
              VoiceReadiness.shared.daemonVerdictRequest == request else {
            return
        }
        retireCurrentDaemon(terminateIfRunning: true)
        ensureDaemonRunning()
    }

    /// Stealth's synchronous sound wall. Raising the tracker gate first makes
    /// every queued stdout/termination/verdict callback stale before shutdown;
    /// flushing the queue invalidates its drain generation; retiring the daemon
    /// cancels probe/start tasks, terminates, and waits for process exit.
    func suspendSynchronouslyForStealth() {
        voiceQueue.forgetRepeatableResponse()
        stealthSpeechBoundary.cutOffSynchronously()
        daemonProbeTracker.suspendForStealth()
        voiceQueue.interruptAndFlush()
        retireCurrentDaemon(terminateIfRunning: true)
    }

    /// Final owner teardown. Flushes every pending mouth item, invalidates all
    /// asynchronous callbacks, and synchronously retires the persistent host so
    /// normal app restarts cannot leak orphaned Nora synthesizers.
    func shutdown() {
        voiceQueue.forgetRepeatableResponse()
        stealthSpeechBoundary.cutOffSynchronously()
        daemonProbeTracker.shutdown()
        voiceQueue.interruptAndFlush()
        retireCurrentDaemon(terminateIfRunning: true)
    }

    /// Explicit Stealth exit. This only permits a later intentional operation to
    /// start Nora again; it does not warm or spawn the daemon by itself.
    func resumeAfterStealth() {
        guard stealthSpeechBoundary.resumeAfterVerifiedExit(),
              !StealthEntryLatch.shared.isRaised else {
            daemonProbeTracker.suspendForStealth()
            return
        }
        daemonProbeTracker.resumeAfterStealth()
    }

    /// Re-resolves the required Nora voice using a fresh daemon. Setup calls
    /// this at a slow cadence while it proves speech.
    func recheckVoiceAssetForSetup() {
        guard !isSuppressed else { return }
        guard daemonProbeTracker.shouldRestartDaemonForSetup else { return }

        VoiceReadiness.shared.probe(
            requiresFreshDaemonVerdict: true
        )
        guard VoiceReadiness.shared.provenHostExecutablePath != nil else {
            return
        }

        retireCurrentDaemon(terminateIfRunning: true)
        ensureDaemonRunning()
    }

    /// Whether speech is currently playing back, as reported by the daemon
    /// (BEGAN → DONE/STOPPED). Truthful and immediate — no pid archaeology.
    var isPlaying: Bool {
        !isSuppressed
            && ((daemonProcess?.isRunning == true
                    && (daemonReportsSpeaking || awaitingSpeechStart))
                || voiceQueue.hasPendingOrSpeaking)
    }

    /// Stops any in-progress speech immediately AND clears every queued line —
    /// barge-in silences the whole mouth, not just the current word.
    func stopPlayback() {
        voiceQueue.interruptAndFlush()
        onPlaybackActivityChanged?(false)
    }

    // MARK: - Daemon plumbing

    private func ensureDaemonRunning() {
        guard !StealthEntryLatch.shared.isRaised,
              !stealthSpeechBoundary.isCutOff,
              daemonProbeTracker.canStartDaemon else {
            return
        }
        if daemonProcess?.isRunning == true { return }
        // A naturally exited process may still have a termination callback
        // queued on MainActor. Retire its identity before starting a replacement
        // so that callback cannot clear the replacement's state.
        retireCurrentDaemon(terminateIfRunning: false)

        guard let supportDirectory = Self.supportDirectory else {
            if let request =
                    VoiceReadiness.shared.daemonVerdictRequest {
                VoiceReadiness.shared.recordDaemonVoiceCheckFailure(
                    "voice support directory is unavailable",
                    for: request
                )
            }
            reportVoiceUnavailable()
            return
        }

        VoiceReadiness.shared.probe()
        guard let hostExecutablePath =
                VoiceReadiness.shared.provenHostExecutablePath else {
            reportVoiceUnavailable()
            return
        }
        guard let readinessRequest =
                VoiceReadiness.shared.daemonVerdictRequest,
              readinessRequest.hostExecutablePath
                == hostExecutablePath else {
            return
        }

        let launchPlan = NoraVoiceDaemonLaunchPlan(
            supportDirectoryPath: supportDirectory.path,
            preferredVoiceIdentifiers:
                voiceConfiguration.preferredVoiceIdentifiers,
            speakingRate: voiceConfiguration.speakingRate
        )
        guard launchPlan.executablePath == hostExecutablePath else {
            VoiceReadiness.shared.recordDaemonVoiceCheckFailure(
                "voice daemon host did not match the proven platform host",
                for: readinessRequest
            )
            return
        }
        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: launchPlan.executablePath
        )
        // The voice must not lose the CPU to whatever else is burning it — the
        // founder heard the demo line stutter precisely because it starts the
        // instant the brain subprocess (claude + screenshots) winds down.
        // User-interactive QoS keeps the vocoder fed through those spikes.
        process.qualityOfService = .userInteractive
        process.arguments = launchPlan.arguments
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = FileHandle.nullDevice
        guard let daemonToken = daemonProbeTracker.beginDaemon(for: process) else {
            if !StealthEntryLatch.shared.isRaised, !isSuppressed {
                VoiceReadiness.shared.recordDaemonVoiceCheckFailure(
                    "voice daemon launch was refused",
                    for: readinessRequest
                )
            }
            return
        }
        daemonProcess = process
        daemonStandardInput = standardInputPipe
        daemonReportsSpeaking = false
        daemonOutputBuffer.removeAll(keepingCapacity: true)

        // The daemon's stdout is its state channel. Every speech event carries
        // the request ID from SAY; chunks are buffered because a pipe read may
        // split a line at any byte.
        standardOutputPipe.fileHandleForReading.readabilityHandler = {
            [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty,
                  !StealthEntryLatch.shared.isRaised else {
                return
            }
            _ = StealthEntryLatch.shared.performUnlessRaised {
                DispatchQueue.main.async { [weak self] in
                    guard !StealthEntryLatch.shared.isRaised else {
                        return
                    }
                    self?.consumeDaemonOutput(
                        chunk,
                        ownedBy: daemonToken
                    )
                }
            }
        }
        let stealthSpeechBoundary = stealthSpeechBoundary
        process.terminationHandler = { [weak self] _ in
            stealthSpeechBoundary.retireDaemon(ownedBy: daemonToken)
            standardOutputPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.daemonProbeTracker.ownsCurrentDaemon(daemonToken)
                else { return }
                self.retireCurrentDaemon(terminateIfRunning: false)
            }
        }

        // A verdict file left by a previous generation must never satisfy this
        // request. Clear it before launch and trust only the owned daemon's
        // subsequent atomic report.
        if let staleVerdictURL = Self.supportDirectory?
            .appendingPathComponent("voice-served.log") {
            try? FileManager.default.removeItem(at: staleVerdictURL)
        }

        do {
            let didLaunch = try stealthSpeechBoundary.launchDaemonIfAllowed(
                token: daemonToken,
                controlDescriptor:
                    standardInputPipe.fileHandleForWriting.fileDescriptor
            ) {
                try process.run()
                return process.processIdentifier
            }
            guard didLaunch else {
                retireCurrentDaemon(terminateIfRunning: false)
                if !StealthEntryLatch.shared.isRaised,
                   !isSuppressed {
                    VoiceReadiness.shared.recordDaemonVoiceCheckFailure(
                        "voice daemon did not launch",
                        for: readinessRequest
                    )
                }
                return
            }
        } catch {
            retireCurrentDaemon(terminateIfRunning: false)
            LifecycleLog.append("VOICE daemon failed to launch: \(error)")
            VoiceReadiness.shared.recordDaemonVoiceCheckFailure(
                "voice daemon failed to launch",
                for: readinessRequest
            )
            reportVoiceUnavailable()
            return
        }

        readDaemonVoiceVerdict(
            ownedBy: daemonToken,
            readinessRequest: readinessRequest
        )
    }

    private func consumeDaemonOutput(
        _ chunk: Data,
        ownedBy daemonToken: NoraVoiceDaemonProbeToken
    ) {
        guard !StealthEntryLatch.shared.isRaised,
              !isSuppressed,
              daemonProbeTracker.ownsCurrentDaemon(daemonToken) else {
            return
        }
        daemonOutputBuffer.append(chunk)
        guard daemonOutputBuffer.count <= 16_384 else {
            daemonOutputBuffer.removeAll(keepingCapacity: true)
            _ = speechReceiptTracker.finishActive(as: .failed)
            speechStartTimeoutTask?.cancel()
            speechStartTimeoutTask = nil
            awaitingSpeechStart = false
            daemonReportsSpeaking = false
            NoraSpeechActivityLatch.shared.markNotSpeaking()
            // Malformed/unbounded protocol output invalidates the mouth itself.
            // STOP first, then synchronously retire the owned PID so audio
            // cannot continue behind an unusable receipt channel.
            _ = send(command: "STOP")
            retireCurrentDaemon(terminateIfRunning: true)
            return
        }

        while let newlineIndex = daemonOutputBuffer.firstIndex(of: 0x0A) {
            let lineData = daemonOutputBuffer[
                daemonOutputBuffer.startIndex..<newlineIndex
            ]
            daemonOutputBuffer.removeSubrange(
                daemonOutputBuffer.startIndex...newlineIndex
            )
            guard let line = String(
                data: lineData,
                encoding: .utf8
            ), !line.isEmpty else {
                continue
            }
            consumeDaemonEventLine(line)
        }
    }

    private func consumeDaemonEventLine(_ line: String) {
        guard !StealthEntryLatch.shared.isRaised, !isSuppressed else {
            return
        }
        guard let daemonEvent = NoraVoiceDaemonEvent(line: line) else {
            return
        }
        let event = daemonEvent.kind.rawValue
        let requestID = daemonEvent.requestID
        let result = speechReceiptTracker.record(
            event: event,
            requestID: requestID
        )
        switch result {
        case .ignored:
            return
        case .began:
            LifecycleLog.append(
                "VOICE-PLAYBACK event=BEGAN request=\(requestID) profile=\(voiceConfiguration.profile.rawValue)"
            )
            speechStartTimeoutTask?.cancel()
            speechStartTimeoutTask = nil
            awaitingSpeechStart = false
            daemonReportsSpeaking = true
            onPlaybackActivityChanged?(true)
            NoraSpeechActivityLatch.shared.markSpeaking()
            if let spokenText = speechTextByRequestID[requestID] {
                onDeliveryStarted?(spokenText)
            }
        case .finished(let completion):
            LifecycleLog.append(
                "VOICE-PLAYBACK event=\(event) request=\(requestID) profile=\(voiceConfiguration.profile.rawValue) completion=\(String(describing: completion))"
            )
            speechStartTimeoutTask?.cancel()
            speechStartTimeoutTask = nil
            awaitingSpeechStart = false
            daemonReportsSpeaking = false
            onPlaybackActivityChanged?(voiceQueue.hasPendingOrSpeaking)
            NoraSpeechActivityLatch.shared.markNotSpeaking()
            if event == "BLOCKED" || completion == .failed {
                Self.appendVoiceSafetyReceipt("BLOCKED source=daemon")
            }
        }
    }

    /// The daemon writes `voice-served.log` (`resolved=true|false`) the instant
    /// it starts — it is the ONLY process that can reliably resolve the
    /// preferred Nora asset and installed fallbacks from a hardened app. A
    /// `resolved=false` report now means no usable local voice exists.
    private func readDaemonVoiceVerdict(
        ownedBy daemonToken: NoraVoiceDaemonProbeToken,
        readinessRequest: VoiceDaemonVerdictRequest
    ) {
        guard let supportDirectory = Self.supportDirectory else {
            finishDaemonVerdictProbe(ifOwnedBy: daemonToken)
            return
        }
        let voiceServedLogURL = supportDirectory.appendingPathComponent("voice-served.log")

        // The report appears as soon as the built-in host resolves the preferred
        // voice or a fallback. Keep the established bounded window so a stalled
        // OS voice service cannot leave setup waiting forever.
        daemonVerdictProbeTask?.cancel()
        daemonVerdictProbeTask = Task { @MainActor [weak self] in
            defer {
                self?.finishDaemonVerdictProbe(ifOwnedBy: daemonToken)
            }
            for _ in 0..<120 {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self,
                      self.daemonProbeTracker.ownsActiveVerdictProbe(daemonToken)
                else { return }
                guard let report = try? String(contentsOf: voiceServedLogURL, encoding: .utf8),
                      report.contains("resolved=") else { continue }
                let voiceResolved = report.contains("resolved=true")
                VoiceReadiness.shared.recordDaemonVoiceReport(
                    voiceResolved: voiceResolved,
                    for: readinessRequest
                )
                if !voiceResolved { self.reportVoiceUnavailable() }
                return
            }
            guard let self,
                  self.daemonProbeTracker
                    .ownsActiveVerdictProbe(daemonToken) else {
                return
            }
            VoiceReadiness.shared.recordDaemonVoiceCheckFailure(
                "Ace's bundled voice did not answer within 30 seconds",
                for: readinessRequest
            )
            self.reportVoiceUnavailable()
        }
    }

    private func finishDaemonVerdictProbe(
        ifOwnedBy daemonToken: NoraVoiceDaemonProbeToken
    ) {
        guard daemonProbeTracker.finishVerdictProbe(ownedBy: daemonToken) else {
            return
        }
        daemonVerdictProbeTask = nil
    }

    /// Invalidates ownership before touching the process. Termination, stdout,
    /// and verdict callbacks all carry the retired token, so any work already
    /// queued by this process becomes harmless before a replacement is born.
    private func retireCurrentDaemon(
        terminateIfRunning: Bool,
        waitForExit: Bool = true
    ) {
        let process = daemonProcess
        if let daemonToken = daemonProbeTracker.currentDaemon {
            stealthSpeechBoundary.retireDaemon(ownedBy: daemonToken)
            daemonProbeTracker.retireDaemon(ownedBy: daemonToken)
        }
        daemonVerdictProbeTask?.cancel()
        daemonVerdictProbeTask = nil
        speechStartTimeoutTask?.cancel()
        speechStartTimeoutTask = nil
        speechGeneration &+= 1
        _ = speechReceiptTracker.finishActive(
            as: isSuppressed ? .interrupted : .failed
        )

        if let process {
            (process.standardOutput as? Pipe)?
                .fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
        }

        daemonProcess = nil
        daemonStandardInput = nil
        daemonOutputBuffer.removeAll(keepingCapacity: true)
        daemonReportsSpeaking = false
        awaitingSpeechStart = false
        NoraSpeechActivityLatch.shared.markNotSpeaking()

        if terminateIfRunning, let process, process.isRunning {
            // Freeze and kill the complete host/voice tree. Do not use
            // an unbounded wait on the MainActor: the in-process Stealth wall
            // is already raised, and a wedged child must never stall the
            // transition forever.
            RunningProcessBox.terminateProcessTree(process)
            if waitForExit {
                let deadline =
                    DispatchTime.now().uptimeNanoseconds
                        &+ 1_000_000_000
                while process.isRunning,
                      DispatchTime.now().uptimeNanoseconds
                        < deadline {
                    Thread.sleep(
                        forTimeInterval: 0.01
                    )
                }
            }
        }
    }

    /// Routes a mute Ace to the one channel that does not depend on Ace being
    /// able to speak. Everything in this app used to report through the mouth,
    /// which is useless precisely when the mouth is what broke.
    private func reportVoiceUnavailable() {
        let readinessState = VoiceReadiness.shared.state
        guard let failure = FirstRunFailure.voice(readinessState) else { return }
        FirstRunFailureReporter.shared.report(
            failure,
            interrupt: !AceIntroWindowController.shared.isVisible,
            repairRevision: "voice-readiness-v1",
            verifiedRepair: {
                let verdict = await VoiceReadiness.shared
                    .probeAndWaitForFullVerdict(
                        requiresFreshDaemonVerdict: true
                    )
                if verdict == .ready {
                    FirstRunFailureReporter.shared.clearVoiceFailures(
                        except: failure.id
                    )
                    return .succeeded(
                        .permissionReadback(permission: .voice)
                    )
                }
                return .failed(
                        PermissionRepairFailure(
                            code: "voice.readiness_not_verified",
                            message: verdict.ownerFacingSummary
                        )
                    )
            }
        )
    }

    @discardableResult
    private func send(command: String) -> Bool {
        guard let commandData = "\(command)\n".data(using: .utf8),
              commandData.count
                <= NoraVoiceDaemonLaunchPlan.maximumCommandByteCount else {
            return false
        }
        return send(commandData: commandData)
    }

    @discardableResult
    private func send(commandData: Data) -> Bool {
        guard daemonProcess?.isRunning == true,
              commandData.count
                <= NoraVoiceDaemonLaunchPlan.maximumCommandByteCount,
              let handle = daemonStandardInput?.fileHandleForWriting else {
            return false
        }
        return stealthSpeechBoundary.sendCommandIfAllowed(
            commandData,
            through: handle.fileDescriptor
        )
    }

    // MARK: - Paths

    private static var supportDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true)
    }

    private static func ensureSupportDirectory() {
        guard let supportDirectory else { return }
        try? FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
    }

    /// The brain appends a [POINT:x,y:label:screenN] tag to drive the cursor
    /// overlay; that tag must never be read aloud.
    private static func strippingCursorPointTags(from text: String) -> String {
        let withoutPointTags = text.replacingOccurrences(
            of: #"\[POINT:[^\]]*\]"#,
            with: "",
            options: .regularExpression
        )
        return withoutPointTags.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Brains emit markdown ("**$4,051.70**", `code`, [label](url)) that has no
    /// spoken form — the marks reach the synthesizer as pauses or literal noise.
    private static func strippingSpokenMarkdown(from text: String) -> String {
        var spoken = text
        // [label](url) → label; bare-link syntax <https://…> → the URL text.
        spoken = spoken.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        spoken = spoken.replacingOccurrences(
            of: #"<(https?://[^>]+)>"#, with: "$1", options: .regularExpression)
        // Emphasis and code marks: asterisks, double underscores, backticks,
        // strikethrough. Single underscores stay (snake_case identifiers).
        for mark in ["**", "__", "~~", "`", "*"] {
            spoken = spoken.replacingOccurrences(of: mark, with: "")
        }
        // Leading heading/bullet/quote furniture at each line start.
        spoken = spoken.replacingOccurrences(
            of: #"(?m)^\s*(#{1,6}\s+|>\s+|[-+]\s+|\d+\.\s+)"#,
            with: "", options: .regularExpression)
        return spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns true only for the prohibited whole-word forms, including common
    /// punctuation/spacing and leetspeak evasions. Word boundaries keep benign
    /// words that merely contain similar letters from being suppressed.
    nonisolated static func containsBlockedSpokenLanguage(_ text: String) -> Bool {
        let normalizedText = text
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        let blockedPattern = #"(?i)(?<![a-z0-9])n[\W_]*[i1!|][\W_]*g[\W_]*g[\W_]*(?:[e3][\W_]*r|[a@4])(?:[\W_]*s)?(?![a-z0-9])"#
        return normalizedText.range(
            of: blockedPattern,
            options: .regularExpression
        ) != nil
    }

    /// Audit the decision without persisting the rejected text itself.
    private static func appendVoiceSafetyReceipt(_ message: String) {
        guard let supportDirectory,
              let lineData = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
                .data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let logFileURL = supportDirectory.appendingPathComponent("voice-safety.log")
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        } else {
            try? lineData.write(to: logFileURL, options: .atomic)
        }
    }
}
#endif // circuit-convert
