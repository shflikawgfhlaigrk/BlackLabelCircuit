//
//  VoiceReadiness.swift
//  Ace
//
//  First-run truth about Ace's MOUTH, in the same spirit as BrainConnection's
//  truth about its brain.
//
//  Ace proves the signed app's own universal voice daemon and on-device model.
//  The buyer never installs or selects a macOS voice, signs into a speech
//  account, or grants Siri access. A correlated live-daemon verdict remains
//  required after the silent bundled-runtime self-test.
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
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import CircuitPortKit

private struct VoiceProbeCommandResult: Sendable {
    let terminationStatus: Int32
    let output: String
    let timedOut: Bool
    let cancelledForStealth: Bool
}

enum VoiceHostProbeResult: Equatable, Sendable {
    case ready(hostExecutablePath: String)
    case timedOut
    case unavailable(details: String)
    case cancelled
}

/// Correlates the only process that can resolve Nora with the exact platform-host
/// proof that requested that verdict. A report from an older daemon generation
/// can never make a newer readiness cycle look ready.
struct VoiceDaemonVerdictRequest: Hashable, Sendable {
    let generation: UInt64
    let hostExecutablePath: String
}

/// Value-only generation gate used by the live probe and offline race tests.
/// Any Stealth transition advances the generation, making an already-running
/// probe permanently ineligible to publish even if Stealth exits immediately.
struct VoiceProbePublicationGate: Sendable {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

/// Monotonic deadline policy for the daemon half of readiness. Wall-clock
/// changes cannot extend or skip this bound.
struct VoiceDaemonVerdictDeadline: Sendable {
    private(set) var request: VoiceDaemonVerdictRequest?
    private var deadline: ContinuousClock.Instant?

    mutating func hasExpired(
        waitingFor request: VoiceDaemonVerdictRequest,
        now: ContinuousClock.Instant,
        timeout: Duration = .seconds(32)
    ) -> Bool {
        if self.request != request {
            self.request = request
            deadline = now.advanced(by: timeout)
            return false
        }
        guard let deadline else { return false }
        return now >= deadline
    }
}

nonisolated final class VoiceStealthEpochBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var epochStorage: UInt64 = 0

    var epoch: UInt64 {
        lock.withLock { epochStorage }
    }

    func markEntry() {
        lock.withLock {
            epochStorage &+= 1
        }
    }
}

private nonisolated final class VoiceProbeOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 16 * 1_024

    func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        lock.withLock {
            let remaining = max(0, limit - data.count)
            if remaining > 0 {
                data.append(bytes.prefix(remaining))
            }
        }
    }

    func snapshot() -> Data {
        lock.withLock { data }
    }
}

/// A bounded X-turn cutoff for a read-only readiness probe. Full process-tree
/// reap happens on the worker queue after this root kill.
nonisolated final class VoiceProbeAttemptBoundary: @unchecked Sendable {
    typealias CutoffPrimitive = @Sendable (pid_t) -> Void

    private let lock = NSLock()
    private let entryLatch: StealthEntryLatch
    private let cutoffPrimitive: CutoffPrimitive
    private var processIdentifier: pid_t?
    private var cancellationRequested = false

    init(
        entryLatch: StealthEntryLatch = .shared,
        cutoffPrimitive: CutoffPrimitive? = nil
    ) {
        self.entryLatch = entryLatch
        self.cutoffPrimitive = cutoffPrimitive ?? { processIdentifier in
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        cancellationRequested = entryLatch.isRaised
    }

    /// Closes the pre-run/post-register gap. PID publication is part of the
    /// same global admission Private Mode entry raises, so concurrent entry cannot return before
    /// its synchronous cutoff has seen the returned root.
    func launchProcessIfAllowed(
        _ launch: () throws -> pid_t
    ) rethrows -> Bool {
        let didLaunch: Bool? = try entryLatch.performUnlessRaised {
            try lock.withLock {
                guard !cancellationRequested else { return false }
                let launchedProcessIdentifier = try launch()
                guard launchedProcessIdentifier > 0 else {
                    return false
                }
                processIdentifier = launchedProcessIdentifier
                return true
            }
        }
        if didLaunch == nil {
            lock.withLock {
                cancellationRequested = true
            }
        }
        return didLaunch == true
    }

    func cancelSynchronously() {
        let processIdentifier = lock.withLock {
            cancellationRequested = true
            let snapshot = self.processIdentifier
            self.processIdentifier = nil
            return snapshot
        }
        if let processIdentifier {
            cutoffPrimitive(processIdentifier)
        }
    }

    var wasCancelledForStealth: Bool {
        lock.withLock { cancellationRequested }
    }

    /// Timeout is not Stealth. It still needs the same immediate root cutoff,
    /// but must not poison the attempt's sticky Stealth bit.
    func terminateCurrentRoot() {
        let processIdentifier = lock.withLock { self.processIdentifier }
        if let processIdentifier {
            cutoffPrimitive(processIdentifier)
        }
    }

    func clear() {
        lock.withLock {
            processIdentifier = nil
        }
    }
}

/// Why Ace cannot currently speak, or that it can. Ordered by what the owner
/// has to do about it — each case maps to one concrete action, never a shrug.
enum VoiceReadinessState: Equatable, Sendable {
    /// The bundled runtime self-test passed AND its daemon reported a usable
    /// packaged model.
    case ready

    /// The signed app's bundled voice daemon could not execute.
    case voiceHostUnavailable(details: String)

    /// The daemon ran, but its bundled model or voice profile did not resolve.
    case voiceAssetMissing

    /// The host worked, but the correlated Ace voice daemon did not publish a
    /// verdict inside its bounded cold-start window.
    case voiceCheckFailed(details: String)

    /// Probed but not yet answered.
    case unknown

    var canSpeak: Bool { self == .ready }

    /// One line, in the product's voice, for the setup window and the panel.
    var ownerFacingSummary: String {
        switch self {
        case .ready:
            return "Ace Voice is built in and ready."
        case .voiceHostUnavailable:
            return "Ace couldn't start its built-in voice."
        case .voiceAssetMissing:
            return "Ace's built-in voice model is missing."
        case .voiceCheckFailed:
            return "Ace can't speak yet — its voice check didn't finish."
        case .unknown:
            return "Checking whether Ace can speak…"
        }
    }

    /// What the owner actually does next. Nil when there is nothing to do.
    var ownerFacingRemedy: String? {
        switch self {
        case .ready, .unknown:
            return nil
        case .voiceHostUnavailable(let details):
            return "Reinstall this Ace package. Its bundled voice runtime did not pass verification. (\(details))"
        case .voiceAssetMissing:
            return "Reinstall this Ace package. The built-in voice model is part of the app."
        case .voiceCheckFailed(let details):
            return "Quit and reopen Ace. If it still can't speak, open Setup. (\(details))"
        }
    }
}

/// MainActor owns the live copy, but every transition is value-only so the
/// ordering policy can be proven without launching a process or an app.
struct VoiceReadinessTruthLedger: Sendable {
    private(set) var state: VoiceReadinessState = .unknown
    private(set) var provenHostExecutablePath: String?
    private(set) var daemonVerdictRequest: VoiceDaemonVerdictRequest?

    private var nextDaemonVerdictGeneration: UInt64 = 0
    private var bufferedDaemonVerdicts:
        [VoiceDaemonVerdictRequest: VoiceReadinessState] = [:]

    func needsHostProbe(requiresFreshDaemonVerdict: Bool) -> Bool {
        if requiresFreshDaemonVerdict { return true }
        // Starting the daemon must not launch a second model self-test while
        // its already-proven host is publishing the live voice verdict.
        return provenHostExecutablePath == nil
            || (state != .ready && state != .unknown)
    }

    mutating func applyHost(
        _ result: VoiceHostProbeResult,
        requiresFreshDaemonVerdict: Bool
    ) {
        switch result {
        case .ready(let hostExecutablePath):
            let pathIsUnchanged =
                provenHostExecutablePath == hostExecutablePath
            let existingVerdictIsReusable =
                pathIsUnchanged
                && !requiresFreshDaemonVerdict
                && (
                    state == .ready
                    || state == .voiceAssetMissing
                    || (
                        state == .unknown
                        && daemonVerdictRequest?
                            .hostExecutablePath
                            == hostExecutablePath
                    )
                )

            provenHostExecutablePath = hostExecutablePath
            guard !existingVerdictIsReusable else { return }

            state = .unknown
            nextDaemonVerdictGeneration &+= 1
            let request = VoiceDaemonVerdictRequest(
                generation: nextDaemonVerdictGeneration,
                hostExecutablePath: hostExecutablePath
            )
            daemonVerdictRequest = request
            if let buffered = bufferedDaemonVerdicts.removeValue(
                forKey: request
            ) {
                state = buffered
            }
            bufferedDaemonVerdicts = bufferedDaemonVerdicts.filter {
                $0.key == request
            }

        case .timedOut:
            // A redundant probe's deadline is not evidence against a live
            // daemon that completed the current readiness request.
            if !requiresFreshDaemonVerdict,
               state == .ready,
               provenHostExecutablePath != nil {
                return
            }
            state = .voiceCheckFailed(
                details: "The voice startup check took too long. Retry Ace Voice in Setup."
            )
            provenHostExecutablePath = nil
            daemonVerdictRequest = nil
            bufferedDaemonVerdicts.removeAll()

        case .unavailable(let details):
            state = .voiceHostUnavailable(details: details)
            provenHostExecutablePath = nil
            daemonVerdictRequest = nil
            bufferedDaemonVerdicts.removeAll()

        case .cancelled:
            invalidateForStealth()
        }
    }

    @discardableResult
    mutating func recordDaemonVerdict(
        voiceResolved: Bool,
        for request: VoiceDaemonVerdictRequest
    ) -> Bool {
        let verdict: VoiceReadinessState =
            voiceResolved ? .ready : .voiceAssetMissing
        bufferedDaemonVerdicts[request] = verdict
        guard daemonVerdictRequest == request,
              provenHostExecutablePath
                == request.hostExecutablePath else {
            return false
        }
        state = verdict
        bufferedDaemonVerdicts.removeValue(forKey: request)
        return true
    }

    @discardableResult
    mutating func recordDaemonFailure(
        _ details: String,
        for request: VoiceDaemonVerdictRequest
    ) -> Bool {
        guard daemonVerdictRequest == request,
              provenHostExecutablePath
                == request.hostExecutablePath else {
            return false
        }
        state = .voiceCheckFailed(details: details)
        return true
    }

    mutating func invalidateForStealth() {
        state = .unknown
        provenHostExecutablePath = nil
        daemonVerdictRequest = nil
        bufferedDaemonVerdicts.removeAll()
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Probes, and can repair, everything Ace needs in order to speak.
@MainActor
final class VoiceReadiness: ObservableObject {

    /// One probe result shared by everything that needs it — the voice itself
    /// (NoraVoice), the setup window's voice step, and the menu-bar panel.
    /// Three independent probes would race each other's platform-host calls
    /// and could disagree on screen.
    static let shared = VoiceReadiness()

    @Published private(set) var state: VoiceReadinessState = .unknown

    /// The exact bundled voice daemon proven by its silent model self-test.
    @Published private(set) var provenHostExecutablePath: String?

    /// Exact daemon verdict currently required to turn `.unknown` into a
    /// truthful ready/missing verdict.
    @Published private(set) var daemonVerdictRequest:
        VoiceDaemonVerdictRequest?

    private var probeTask: Task<Void, Never>?
    private var probePublicationGate = VoiceProbePublicationGate()
    private var activeProbeGeneration: UInt64?
    private var activeProbeRequiresFreshDaemonVerdict = false
    private var truthLedger = VoiceReadinessTruthLedger()
    private let stealthEpochBoundary = VoiceStealthEpochBoundary()
    private var observedStealthEpoch: UInt64 = 0
    private var stealthEntryCutoffRegistration: UUID?
    private var applicationDidBecomeActiveObserver: NSObjectProtocol?

    private init() {
        let stealthEpochBoundary = stealthEpochBoundary
        stealthEntryCutoffRegistration =
            StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                stealthEpochBoundary.markEntry()
            }
        observedStealthEpoch = stealthEpochBoundary.epoch

        // Returning to Ace re-proves the voice ONLY while it is unproven. A
        // proven daemon keeps running: Build 62 demanded a fresh verdict on
        // every activation and respawned Nora once per interaction (issue
        // #21). Speech setup stays inside the app.
        applicationDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleApplicationDidBecomeActive()
            }
        }
    }

    deinit {
        if let stealthEntryCutoffRegistration {
            StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(
                stealthEntryCutoffRegistration
            )
        }
        if let applicationDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(
                applicationDidBecomeActiveObserver
            )
        }
    }

    // MARK: - Probing

    /// The one probe invokes the bundled daemon's no-audio model self-test. It
    /// never consults developer tooling, downloads anything, produces audio,
    /// or presents a system dialog.
    @discardableResult
    func probe(requiresFreshDaemonVerdict: Bool = false) -> Bool {
        synchronizeStealthEpoch()
        guard probeTask == nil,
              !StealthEntryLatch.shared.isRaised,
              truthLedger.needsHostProbe(
                  requiresFreshDaemonVerdict: requiresFreshDaemonVerdict
              ) else { return false }
        let generation = probePublicationGate.begin()
        activeProbeGeneration = generation
        activeProbeRequiresFreshDaemonVerdict =
            requiresFreshDaemonVerdict
        let attemptBoundary = VoiceProbeAttemptBoundary()
        let cutoffIdentifier =
            StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                attemptBoundary.cancelSynchronously()
            }
        probeTask = Task { @MainActor [weak self] in
            let result = await Self.resolvePlatformHostOffMainActor(
                attemptBoundary: attemptBoundary,
                cutoffIdentifier: cutoffIdentifier
            )
            guard let self,
                  self.activeProbeGeneration == generation else { return }
            self.probeTask = nil
            self.activeProbeGeneration = nil
            let requiresFreshDaemonVerdict =
                self.activeProbeRequiresFreshDaemonVerdict
            self.activeProbeRequiresFreshDaemonVerdict = false
            self.synchronizeStealthEpoch()
            guard self.probePublicationGate.accepts(generation),
                  !StealthEntryLatch.shared.isRaised,
                  result != .cancelled else {
                self.truthLedger.invalidateForStealth()
                self.publishTruth()
                return
            }
            self.truthLedger.applyHost(
                result,
                requiresFreshDaemonVerdict:
                    requiresFreshDaemonVerdict
            )
            self.publishTruth()
        }
        return true
    }

    /// Used only where the immediate first-run report needs the resolved truth.
    /// Process I/O and waits remain entirely off MainActor.
    func probeAndWait(
        requiresFreshDaemonVerdict: Bool = false
    ) async {
        var freshVerdictStillRequired =
            requiresFreshDaemonVerdict
        while !Task.isCancelled {
            synchronizeStealthEpoch()
            if StealthEntryLatch.shared.isRaised {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }

            probe(
                requiresFreshDaemonVerdict:
                    freshVerdictStillRequired
            )
            let activeWasFresh =
                activeProbeRequiresFreshDaemonVerdict
            let activeProbe = probeTask
            await activeProbe?.value

            if freshVerdictStillRequired && !activeWasFresh {
                freshVerdictStillRequired = false
                probe(requiresFreshDaemonVerdict: true)
                await probeTask?.value
            } else {
                freshVerdictStillRequired = false
            }

            synchronizeStealthEpoch()
            if !StealthEntryLatch.shared.isRaised,
               state != .unknown
                || provenHostExecutablePath != nil {
                return
            }
        }
    }

    /// A first speech request must not race the initial clean-Mac probe. Once a
    /// host verdict exists (or a proven path is waiting only on Nora's
    /// daemon report), later speech requests return immediately.
    func waitForInitialProbeIfNeeded() async {
        synchronizeStealthEpoch()
        if let activeProbe = probeTask {
            await activeProbe.value
        }
        guard provenHostExecutablePath == nil,
              state == .unknown else { return }
        await probeAndWait()
    }

    /// Launch/report paths wait for both halves of the proof. The daemon itself
    /// publishes a bounded failure if its 30-second cold-start window expires.
    func probeAndWaitForFullVerdict(
        requiresFreshDaemonVerdict: Bool = false
    ) async -> VoiceReadinessState {
        await probeAndWait(
            requiresFreshDaemonVerdict:
                requiresFreshDaemonVerdict
        )
        return await waitForDaemonVerdictIfNeeded()
    }

    func waitForDaemonVerdictIfNeeded() async
        -> VoiceReadinessState {
        let clock = ContinuousClock()
        var verdictDeadline = VoiceDaemonVerdictDeadline()
        while !Task.isCancelled {
            let wasInvalidatedForStealth =
                synchronizeStealthEpoch()
            if wasInvalidatedForStealth {
                await probeAndWait(
                    requiresFreshDaemonVerdict: true
                )
                continue
            }
            guard !StealthEntryLatch.shared.isRaised else {
                await probeAndWait(
                    requiresFreshDaemonVerdict: true
                )
                continue
            }
            guard provenHostExecutablePath != nil,
                  let daemonVerdictRequest,
                  state == .unknown else {
                return state
            }
            // Ace Voice owns a 30-second cold-start probe. This two-second envelope
            // guarantees launch/first-speech can never wait forever if daemon
            // creation fails before that probe starts.
            if verdictDeadline.hasExpired(
                waitingFor: daemonVerdictRequest,
                now: clock.now
            ) {
                _ = truthLedger.recordDaemonFailure(
                    "Ace's bundled voice did not answer within 32 seconds",
                    for: daemonVerdictRequest
                )
                publishTruth()
                return state
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return state
    }

    private nonisolated static var platformHostExecutablePath: String {
        NoraVoiceDaemonLaunchPlan.bundledExecutablePath
    }
    private nonisolated static var bundledModelPath: String {
        NoraVoiceDaemonLaunchPlan.bundledModelPath
    }
    private nonisolated static let platformHostProbeMarker =
        "ACE_OWNED_VOICE_READY"

    /// Resolves and proves Ace's packaged engine/model without blocking
    /// MainActor and without producing audio.
    private nonisolated static func resolvePlatformHostOffMainActor(
        attemptBoundary: VoiceProbeAttemptBoundary,
        cutoffIdentifier: UUID
    ) async -> VoiceHostProbeResult {
        defer {
            attemptBoundary.clear()
            StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(
                cutoffIdentifier
            )
        }
        guard !attemptBoundary.wasCancelledForStealth,
              !StealthEntryLatch.shared.isRaised else {
            return .cancelled
        }

        guard FileManager.default.isExecutableFile(
            atPath: platformHostExecutablePath
        ) else {
            return .unavailable(
                details: "\(platformHostExecutablePath) is missing or not executable"
            )
        }
        let probeResult = await runProbeCommand(
            executablePath: platformHostExecutablePath,
            arguments: ["--self-test", bundledModelPath],
            timeoutSeconds: 30,
            attemptBoundary: attemptBoundary
        )
        guard !probeResult.cancelledForStealth else {
            return .cancelled
        }
        if probeResult.timedOut {
            return .timedOut
        }
        guard platformHostProbeSucceeded(
            terminationStatus: probeResult.terminationStatus,
            output: probeResult.output
        ) else {
            let trimmedOutput = probeResult.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(400)
            let outputDetail = trimmedOutput.isEmpty
                ? "no diagnostic output"
                : String(trimmedOutput)
            return .unavailable(
                details:
                    "the bundled voice self-test exited \(probeResult.terminationStatus): \(outputDetail)"
            )
        }
        return .ready(
            hostExecutablePath: platformHostExecutablePath
        )
    }

    private nonisolated static func runProbeCommand(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        attemptBoundary: VoiceProbeAttemptBoundary
    ) async -> VoiceProbeCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let outputPipe = Pipe()
                let outputBox = VoiceProbeOutputBox()
                let readerGroup = DispatchGroup()
                let terminationSignal = DispatchSemaphore(value: 0)
                defer {
                    attemptBoundary.clear()
                }

                guard !attemptBoundary.wasCancelledForStealth,
                      !StealthEntryLatch.shared.isRaised else {
                    continuation.resume(
                        returning: VoiceProbeCommandResult(
                            terminationStatus: -1,
                            output: "",
                            timedOut: false,
                            cancelledForStealth: true
                        )
                    )
                    return
                }

                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.standardOutput = outputPipe
                process.standardError = outputPipe
                process.terminationHandler = { _ in
                    terminationSignal.signal()
                }

                do {
                    let didLaunch =
                        try attemptBoundary.launchProcessIfAllowed {
                            try process.run()
                            return process.processIdentifier
                        }
                    guard didLaunch else {
                        continuation.resume(
                            returning: VoiceProbeCommandResult(
                                terminationStatus: -1,
                                output: "",
                                timedOut: false,
                                cancelledForStealth: true
                            )
                        )
                        return
                    }
                } catch {
                    continuation.resume(
                        returning: VoiceProbeCommandResult(
                            terminationStatus: -1,
                            output: "",
                            timedOut: false,
                            cancelledForStealth:
                                attemptBoundary.wasCancelledForStealth
                                || StealthEntryLatch.shared.isRaised
                        )
                    )
                    return
                }

                readerGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    let handle = outputPipe.fileHandleForReading
                    while let bytes = try? handle.read(upToCount: 4_096),
                          !bytes.isEmpty {
                        outputBox.append(bytes)
                    }
                    readerGroup.leave()
                }

                let timedOut = terminationSignal.wait(
                    timeout: .now() + timeoutSeconds
                ) == .timedOut
                let cancelledForStealth =
                    attemptBoundary.wasCancelledForStealth
                    || StealthEntryLatch.shared.isRaised
                if timedOut || cancelledForStealth {
                    if timedOut && !cancelledForStealth {
                        attemptBoundary.terminateCurrentRoot()
                    }
                    RunningProcessBox.terminateProcessTree(process)
                    _ = terminationSignal.wait(timeout: .now() + 1)
                }
                _ = readerGroup.wait(timeout: .now() + 1)

                let status = process.isRunning
                    ? Int32(-1)
                    : process.terminationStatus
                let output = String(
                    data: outputBox.snapshot(),
                    encoding: .utf8
                ) ?? ""
                continuation.resume(
                    returning: VoiceProbeCommandResult(
                        terminationStatus: status,
                        output: output,
                        timedOut: timedOut,
                        cancelledForStealth: cancelledForStealth
                    )
                )
            }
        }
    }

    /// Value-only verdict so the proof policy can be regression-tested without
    /// launching a process or producing audio.
    nonisolated static func platformHostProbeSucceeded(
        terminationStatus: Int32,
        output: String
    ) -> Bool {
        guard terminationStatus == 0 else { return false }
        let exactOutput = output.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let pattern =
            "^\(platformHostProbeMarker) voice=af_sarah sid=3 sample-rate=24000 samples=[1-9][0-9]*$"
        return exactOutput.range(
            of: pattern,
            options: .regularExpression
        ) != nil
    }

    /// The daemon writes `voice-served.log` with `resolved=true|false` — the one
    /// honest signal that the packaged model resolved in the long-lived voice
    /// process. NoraVoice hands us that verdict.
    func recordDaemonVoiceReport(
        voiceResolved: Bool,
        for request: VoiceDaemonVerdictRequest
    ) {
        synchronizeStealthEpoch()
        guard !StealthEntryLatch.shared.isRaised else { return }
        guard truthLedger.recordDaemonVerdict(
            voiceResolved: voiceResolved,
            for: request
        ) else { return }
        publishTruth()
    }

    func recordDaemonVoiceCheckFailure(
        _ details: String,
        for request: VoiceDaemonVerdictRequest
    ) {
        synchronizeStealthEpoch()
        guard !StealthEntryLatch.shared.isRaised,
              truthLedger.recordDaemonFailure(
                  details,
                  for: request
              ) else {
            return
        }
        publishTruth()
    }

    @discardableResult
    private func synchronizeStealthEpoch() -> Bool {
        let currentEpoch = stealthEpochBoundary.epoch
        guard currentEpoch != observedStealthEpoch else {
            return false
        }
        observedStealthEpoch = currentEpoch
        probePublicationGate.invalidate()
        truthLedger.invalidateForStealth()
        publishTruth()
        return true
    }

    private func publishTruth() {
        let previousState = state
        let previousHostPath = provenHostExecutablePath
        let previousRequest = daemonVerdictRequest
        state = truthLedger.state
        provenHostExecutablePath =
            truthLedger.provenHostExecutablePath
        daemonVerdictRequest =
            truthLedger.daemonVerdictRequest
        guard previousState != state
                || previousHostPath
                    != provenHostExecutablePath
                || previousRequest != daemonVerdictRequest else {
            return
        }
        LifecycleLog.append(
            "VOICE-READINESS \(state)"
                + " host=\(provenHostExecutablePath ?? "none")"
                + " daemon-generation="
                + "\(daemonVerdictRequest?.generation ?? 0)"
        )
    }

    // MARK: - Repair

    private func handleApplicationDidBecomeActive() {
        synchronizeStealthEpoch()
        guard !StealthEntryLatch.shared.isRaised else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.synchronizeStealthEpoch()
            guard !StealthEntryLatch.shared.isRaised else { return }
            // ONE persistent daemon (issue #21): a fresh daemon verdict RETIRES
            // the running daemon and cold-starts a replacement. Build 62 asked
            // for one on EVERY activation, so the founder's live log showed
            // daemon-generation climbing 1→8 in two minutes — one Nora respawn
            // per spoken interaction. A proven voice, or a verdict already in
            // flight, is left alone: the daemon that already answered keeps
            // running, and if it ever dies the next utterance restarts and
            // re-proves it lazily. Activation re-proves only an UNPROVEN voice.
            switch VoiceActivationRefreshPolicy.action(
                voiceIsReady: self.state == .ready,
                verdictIsPending: self.state == .unknown,
                hostIsProven: self.provenHostExecutablePath != nil
            ) {
            case .keepProvenVoice, .awaitPendingVerdict:
                return
            case .proveWithoutRestart:
                await self.probeAndWait(
                    requiresFreshDaemonVerdict: false
                )
            case .retryWithFreshDaemon:
                // A retired daemon takes the utterance it is speaking with it.
                // Activating Ace mid-sentence therefore truncated the line —
                // and because the app action and full-access consent cards
                // only arm after Nora reports the exact untruncated readback
                // finished, a truncated readback silently disarmed the buyer's
                // approval and re-opened the same review on the next request,
                // forever.
                //
                // The verdict is not urgent; the sentence is. Wait for the
                // mouth to go idle before demanding a new daemon. The wait is
                // bounded so a wedged or lying daemon can never postpone the
                // proof indefinitely — on expiry we probe anyway and keep the
                // old fail-closed behaviour.
                await self.waitForSpeechToFinishBeforeFreshVerdict()
                self.synchronizeStealthEpoch()
                guard !StealthEntryLatch.shared.isRaised else { return }
                await self.probeAndWait(
                    requiresFreshDaemonVerdict: true
                )
            }
        }
    }

    /// Longest we will defer an activation voice re-probe while Nora is
    /// speaking. Comfortably longer than any readback Ace speaks, short enough
    /// that a stuck daemon still yields a verdict promptly.
    private static let speechSettleTimeoutForFreshVerdict: TimeInterval = 30

    /// Polls the process-wide speech latch until the mouth is idle or the bound
    /// expires. Polling (rather than an await on the voice object) keeps this
    /// free of any reference to `NoraVoice`, which this type does not own.
    private func waitForSpeechToFinishBeforeFreshVerdict() async {
        guard NoraSpeechActivityLatch.shared.isSpeaking else { return }
        let deadline = Date().addingTimeInterval(
            Self.speechSettleTimeoutForFreshVerdict
        )
        while NoraSpeechActivityLatch.shared.isSpeaking, Date() < deadline {
            if StealthEntryLatch.shared.isRaised { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if NoraSpeechActivityLatch.shared.isSpeaking {
            LifecycleLog.append(
                "VOICE-READINESS fresh verdict proceeding despite live speech"
                    + " after \(Int(Self.speechSettleTimeoutForFreshVerdict))s"
            )
        }
    }

}
#endif // circuit-convert
