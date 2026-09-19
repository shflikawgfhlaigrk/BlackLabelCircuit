//
//  PermissionWarmup.swift
//  Black Label Assistant — "grant yourself access".
//
//  macOS grants Automation permission per (Ace → target app) pair, and only on
//  first use. This runs one benign read against each app Ace's tools control,
//  DIRECTLY from Ace (never through a model — a consent dialog blocks the script
//  that triggered it, so a model-driven warm-up just eats its own timeout and
//  dies, which is exactly what happened on 2026-07-17). One prompt at a time;
//  the user clicks Allow on each; afterwards every tool runs promptless.
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
#if canImport(CoreServices) && !CIRCUIT_WINDOWS_SIM
import CoreServices
#endif
import Foundation
import CircuitPortKit

/// One terminal result even if the native API returns after a deadline.
nonisolated private final class PermissionWarmupNativeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32?, Never>?

    var isFinished: Bool { lock.withLock { finished } }

    func wait() async -> Int32? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                let result = status
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ status: Int32?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        self.status = status
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
    }
}

/// A stuck system consent call cannot keep setup Checking indefinitely. Keep
/// its target occupied until the native call returns, so Retry cannot accumulate
/// blocked threads. Different app targets remain independent.
nonisolated final class PermissionWarmupNativePermissionBroker: @unchecked Sendable {
    static let shared = PermissionWarmupNativePermissionBroker()
    private let lock = NSLock()
    private var inFlight = Set<PermissionAutomationTarget>()
    static let timeoutStatus: Int32 = -1712

    func status(
        for target: PermissionAutomationTarget,
        requestConsent: Bool,
        checkTimeoutNanoseconds: UInt64 = 5_000_000_000,
        consentTimeoutNanoseconds: UInt64 = 60_000_000_000,
        operation: @escaping @Sendable (Bool) -> Int32?
    ) async -> Int32? {
        let preflight = await query(
            target, timeoutNanoseconds: checkTimeoutNanoseconds
        ) { operation(false) }
        // Only the explicit consent-required status warrants a prompting call.
        // Already-granted and denied targets must never enter that system path.
        guard preflight == -1744, requestConsent, !Task.isCancelled else {
            return preflight
        }
        return await query(
            target, timeoutNanoseconds: consentTimeoutNanoseconds
        ) { operation(true) }
    }

    private func query(
        _ target: PermissionAutomationTarget,
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () -> Int32?
    ) async -> Int32? {
        guard !Task.isCancelled else { return nil }
        guard lock.withLock({ inFlight.insert(target).inserted }) else {
            return Self.timeoutStatus
        }
        let completion = PermissionWarmupNativeCompletion()
        // Keep a blocked system API off Swift's cooperative executor. A task
        // group would also wait for that child after the timeout wins.
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = completion.isFinished ? nil : operation()
            _ = lock.withLock { inFlight.remove(target) }
            completion.finish(result)
        }
        let deadline = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                completion.finish(Self.timeoutStatus)
            } catch { }
        }
        let result = await withTaskCancellationHandler {
            await completion.wait()
        } onCancel: {
            completion.finish(nil)
        }
        deadline.cancel()
        return result
    }
}

/// `Process.terminationHandler` and task cancellation can race. Keep the one
/// continuation behind a lock so process exit is delivered exactly once, even
/// when the process exits before `wait()` installs its continuation.
nonisolated private final class PermissionWarmupPokeCompletion:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var terminationStatus: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let terminationStatus {
                lock.unlock()
                continuation.resume(returning: terminationStatus)
                return
            }
            precondition(self.continuation == nil, "a permission poke may only be awaited once")
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(with terminationStatus: Int32) {
        lock.lock()
        guard self.terminationStatus == nil else {
            lock.unlock()
            return
        }
        self.terminationStatus = terminationStatus
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: terminationStatus)
    }
}

/// Exact Automation-poke child registered with the Private Mode entry latch
/// before `run()`.
/// Entry only sends SIGTERM to this one child and returns; no actor hop, wait,
/// Apple Event, or process-tree scan occurs on the keyboard callback.
nonisolated private final class PermissionWarmupProcessCutoffBox:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let process: Process
    private var wasCutOff = false

    init(process: Process) {
        self.process = process
    }

    var isCutOff: Bool {
        lock.withLock { wasCutOff }
    }

    func cutOffSynchronously() {
        let shouldTerminate = lock.withLock {
            guard !wasCutOff else { return false }
            wasCutOff = true
            return process.isRunning
        }
        if shouldTerminate {
            process.terminate()
        }
    }
}

/// Orders one asynchronous hidden Launch Services request against X.
///
/// The native request itself is registered under `performUnlessRaised`. Its
/// exact `NSRunningApplication` is then installed as the synchronous cutoff in
/// the completion callback before any result can reach the MainActor. If X
/// arrived while Launch Services was in flight, late registration invokes the
/// cutoff immediately and the stale application is never accepted.
nonisolated final class PermissionWarmupApplicationLaunchBoundary:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let entryLatch: StealthEntryLatch
    private var wasCutOff = false
    private var exactApplicationCutoff: (@Sendable () -> Void)?
    private var cutoffRegistration: UUID?

    init(entryLatch: StealthEntryLatch = .shared) {
        self.entryLatch = entryLatch
        cutoffRegistration = nil
        cutoffRegistration =
            entryLatch.registerSynchronousEntryCutoff { [weak self] in
                self?.cutOffSynchronously()
            }
    }

    deinit {
        if let cutoffRegistration {
            entryLatch.unregisterSynchronousEntryCutoff(cutoffRegistration)
        }
    }

    func beginNativeLaunchIfAdmitted(_ launch: () -> Void) -> Bool {
        entryLatch.performUnlessRaised {
            guard !lock.withLock({ wasCutOff }) else { return false }
            launch()
            return true
        } == true
    }

    /// Returns false when X already won. Late registration still invokes the
    /// exact cutoff before this method returns.
    func registerExactApplicationCutoff(
        _ cutoff: @escaping @Sendable () -> Void
    ) -> Bool {
        let shouldCutOff = lock.withLock {
            if wasCutOff {
                return true
            }
            exactApplicationCutoff = cutoff
            return false
        }
        if shouldCutOff {
            cutoff()
            return false
        }
        return true
    }

    func clearExactApplicationCutoff() {
        lock.withLock {
            exactApplicationCutoff = nil
        }
    }

    var isCutOff: Bool {
        lock.withLock { wasCutOff }
    }

    func cutOffSynchronously() {
        let cutoff: (@Sendable () -> Void)? = lock.withLock {
            guard !wasCutOff else { return nil }
            wasCutOff = true
            let cutoff = exactApplicationCutoff
            exactApplicationCutoff = nil
            return cutoff
        }
        cutoff?()
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Exact hidden system application returned by Launch Services. X may call
/// this from the event-tap thread; termination is idempotent and never waits.
nonisolated private final class PermissionWarmupApplicationCutoffBox:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let application: NSRunningApplication
    private var wasTerminated = false

    init(application: NSRunningApplication) {
        self.application = application
    }

    func terminateSynchronously() {
        let shouldTerminate = lock.withLock {
            guard !wasTerminated else { return false }
            wasTerminated = true
            return !application.isTerminated
        }
        if shouldTerminate {
            _ = application.terminate()
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class PermissionWarmup: ObservableObject {
    typealias TargetProbe = @Sendable (
        PermissionAutomationTarget
    ) async -> PermissionAutomationEvidence

    private static let legacyCompletedProofKey =
        "AceCompletedAppAutomationProofV1"

    @Published private(set) var isRunning = false
    @Published private(set) var isRevalidatingAutomation = false
    @Published private(set) var hasProvenAppAutomation: Bool
    @Published private(set) var hasEnabledAppleMailAccount: Bool?
    @Published private(set) var currentAutomationTarget:
        PermissionAutomationTarget?
    @Published private(set) var completedAutomationTargetCount = 0
    @Published private(set) var lastDeniedApplications: [String] = []
    @Published private(set) var lastCrashedApplications: [String] = []
    @Published private(set) var automationFailures: [PermissionAutomationTarget: PermissionAutomationFailure] = [:]
    @Published private(set) var automationStatuses:
        [PermissionAutomationTarget: PermissionAutomationTargetStatus]
    private var isSuspendedForStealth = false
    private var runGeneration: UInt64 = 0
    private var runningProcess: Process?
    private var revalidationTask: Task<Void, Never>?
    private var revalidationLaunchedApplication: NSRunningApplication?
    private let targetProbe: TargetProbe?

    init(targetProbe: TargetProbe? = nil) {
        // Automation can be revoked in System Settings at any time, and a
        // migrated defaults domain says nothing about this Mac's TCC database.
        // Every process therefore begins unproven and performs a fresh benign
        // read of every target before setup can be considered ready.
        hasProvenAppAutomation = false
        hasEnabledAppleMailAccount = nil
        currentAutomationTarget = nil
        automationStatuses = PermissionWarmupProofPolicy.statuses(from: [])
        self.targetProbe = targetProbe
        UserDefaults.standard.removeObject(
            forKey: Self.legacyCompletedProofKey
        )
    }

    func automationStatus(
        for target: PermissionAutomationTarget
    ) -> PermissionAutomationTargetStatus {
        automationStatuses[target] ?? .notRequested
    }

    /// Requests and proves exactly one optional Ace → app Automation grant.
    /// Its result updates only that target; sibling grants and core readiness
    /// are never collapsed into one all-or-nothing permission bit.
    @discardableResult
    func requestAndProveAutomation(
        for target: PermissionAutomationTarget
    ) async -> PermissionAutomationTargetStatus {
        guard !isRunning, !isRevalidatingAutomation else {
            return automationStatus(for: target)
        }
        guard !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else {
            return automationStatus(for: target)
        }

        isSuspendedForStealth = false
        runGeneration &+= 1
        let generation = runGeneration
        isRunning = true
        currentAutomationTarget = target
        automationStatuses[target] = .checking
        defer {
            if runGeneration == generation {
                currentAutomationTarget = nil
                isRunning = false
            }
        }

        let evidence = await probeTarget(target, generation: generation)

        guard shouldContinue(generation: generation),
              evidence.target == target else {
            automationStatuses[target] = .notRequested
            return .notRequested
        }
        let status = PermissionWarmupProofPolicy.statuses(
            from: [evidence]
        )[target] ?? .notRequested
        automationStatuses[target] = status
        automationFailures[target] = evidence.failure
        recordProbeLog(
            "WARMUP-TARGET \(target.rawValue) allowed=\(evidence.automationAllowed)"
                + (evidence.failure.map { " code=\($0.code)" } ?? "")
        )
        lastDeniedApplications = PermissionAutomationTarget.allCases
            .filter { automationStatuses[$0] == .denied }
            .map(\.rawValue)
        lastCrashedApplications = PermissionAutomationTarget.allCases
            .filter { automationStatuses[$0] == .targetCrashed }
            .map(\.rawValue)
        hasProvenAppAutomation = PermissionAutomationTarget.allCases
            .allSatisfy { automationStatuses[$0] == .allowed }
        if targetProbe == nil, status == .denied,
           !StealthEntryLatch.shared.isRaised,
           !StealthVisibilityGate.shared.isActive {
            _ = SetupVisibleEffectAdmission.commit {
                return NSWorkspace.shared.open(
                    PermissionSystemSettingsPane.automation.deepLink
                )
            }
        }
        return status
    }

    var failureSummary: String {
        let grantedCount = automationStatuses.values.filter { $0 == .allowed }.count
        let details = PermissionAutomationTarget.allCases.compactMap { target -> String? in
            guard automationStatuses[target] != .allowed else { return nil }
            if let failure = automationFailures[target] {
                return "\(target.ownerFacingName): \(failure.message) [\(failure.code)]"
            }
            if automationStatuses[target] == .targetCrashed {
                return "\(target.ownerFacingName) crashed during its check."
            }
            return "\(target.ownerFacingName): access has not been verified."
        }
        return "\(grantedCount) of \(PermissionAutomationTarget.allCases.count) apps verified. "
            + details.joined(separator: " ")
            + " These optional apps do not block Continue."
    }

    private func probeTarget(
        _ target: PermissionAutomationTarget,
        generation: UInt64
    ) async -> PermissionAutomationEvidence {
        if let targetProbe {
            return await targetProbe(target)
        }
        // Asking the permission service avoids Reminders' crashing count
        // handler and Contacts' database-dependent read during setup.
        if target.usesNativePermissionRequest {
            let status = await noninteractivePermissionStatus(
                for: target, generation: generation, requestConsent: true
            )
            return PermissionWarmupProofPolicy.noninteractiveEvidence(
                target: target, appleEventPermissionStatus: status
            )
        }
        let execution = await runPoke(
            script: PermissionWarmupProofPolicy.warmupScript(for: target),
            generation: generation
        )
        return PermissionWarmupProofPolicy.evidence(
            target: target,
            terminationStatus: execution.terminationStatus,
            standardOutput: execution.standardOutput,
            standardError: execution.standardError
        )
    }

    // MARK: - Crashed-target suppression

    private static func crashSuppressionKey(
        _ target: PermissionAutomationTarget
    ) -> String {
        "ace.warmup.crashed.\(target.rawValue)"
    }

    private static func targetIsSuppressedAfterCrash(
        _ target: PermissionAutomationTarget
    ) -> Bool {
        guard let crashedAt = UserDefaults.standard.object(
            forKey: crashSuppressionKey(target)
        ) as? Date else { return false }
        return Date().timeIntervalSince(crashedAt) < 24 * 3600
    }

    private static func recordTargetCrashSuppression(
        _ target: PermissionAutomationTarget
    ) {
        UserDefaults.standard.set(
            Date(), forKey: crashSuppressionKey(target)
        )
    }

    /// True when the probed app left a fresh crash report during the probe
    /// window — the strongest available proof that the failure was the app
    /// dying, not the owner denying Automation.
    private nonisolated static func targetCrashedDuringProbe(
        _ target: PermissionAutomationTarget,
        since probeStartedAt: Date
    ) -> Bool {
        let reportsDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Logs/DiagnosticReports", isDirectory: true
            )
        let crashReportPrefix = target.applicationPath
            .components(separatedBy: "/").last?
            .replacingOccurrences(of: ".app", with: "") ?? target.rawValue
        guard let reportNames = try? FileManager.default
            .contentsOfDirectory(atPath: reportsDirectory.path)
        else { return false }
        // Small slack: the crash reporter stamps the filename a moment after
        // the process actually died.
        let windowStart = probeStartedAt.addingTimeInterval(-2)
        for reportName in reportNames
        where reportName.hasPrefix("\(crashReportPrefix)-")
            && reportName.hasSuffix(".ips") {
            let reportURL = reportsDirectory
                .appendingPathComponent(reportName)
            if let modified = (try? FileManager.default.attributesOfItem(
                atPath: reportURL.path
            ))?[.modificationDate] as? Date,
               modified >= windowStart {
                return true
            }
        }
        return false
    }

    /// One benign read per app the tool library controls. Order = prompt order.
    private static let applicationPokes: [(
        target: PermissionAutomationTarget,
        script: String
    )] = PermissionAutomationTarget.allCases.map { target in
        (
            target,
            PermissionWarmupProofPolicy.warmupScript(for: target)
        )
    }

    /// Runs every poke sequentially and returns the sentence to speak.
    func run() async -> String {
        guard !isRunning else { return "i'm already setting that up." }
        guard !isRevalidatingAutomation else {
            return "i'm checking app access now."
        }
        guard !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else {
            return "permission setup is paused while stealth is active."
        }

        isSuspendedForStealth = false
        // A retry is a new proof, never permission to reuse the prior result.
        hasProvenAppAutomation = false
        hasEnabledAppleMailAccount = nil
        currentAutomationTarget = nil
        completedAutomationTargetCount = 0
        lastDeniedApplications = []
        lastCrashedApplications = []
        automationFailures = [:]
        automationStatuses = PermissionWarmupProofPolicy.statuses(from: [])
        runGeneration &+= 1
        let generation = runGeneration
        isRunning = true
        defer {
            currentAutomationTarget = nil
            isRunning = false
        }

        var evidence: [PermissionAutomationEvidence] = []
        var grantedApps: [String] = []
        var deniedApps: [String] = []
        var crashedApps: [String] = []
        for poke in Self.applicationPokes {
            currentAutomationTarget = poke.target
            automationStatuses[poke.target] = .checking
            guard shouldContinue(generation: generation) else {
                return "permission setup paused."
            }

            // A target that CRASHED answering the last probe is Apple's bug,
            // not a denial — macOS 27 beta's Reminders dies inside its own
            // count handler (verified crash reports, 2026-08-15). Re-poking
            // just crashes it again in front of the owner, so a crashed
            // target is skipped for a day and reported as broken, not denied.
            if !poke.target.usesNativePermissionRequest,
               Self.targetIsSuppressedAfterCrash(poke.target) {
                evidence.append(PermissionAutomationEvidence(
                    target: poke.target,
                    automationAllowed: false,
                    hasEnabledMailAccount: nil,
                    targetCrashed: true
                ))
                completedAutomationTargetCount = evidence.count
                automationStatuses[poke.target] = .targetCrashed
                crashedApps.append(poke.target.rawValue)
                recordProbeLog(
                    "WARMUP \(poke.target.rawValue) skipped —"
                        + " the app crashed answering a recent probe"
                )
                continue
            }

            let pokeStartedAt = Date()
            let result = await probeTarget(poke.target, generation: generation)

            guard shouldContinue(generation: generation) else {
                return "permission setup paused."
            }
            automationFailures[poke.target] = result.failure

            if !result.automationAllowed,
               Self.targetCrashedDuringProbe(
                   poke.target, since: pokeStartedAt
               ) {
                Self.recordTargetCrashSuppression(poke.target)
                evidence.append(PermissionAutomationEvidence(
                    target: poke.target,
                    automationAllowed: false,
                    hasEnabledMailAccount: nil,
                    targetCrashed: true
                ))
                completedAutomationTargetCount = evidence.count
                automationStatuses[poke.target] = .targetCrashed
                crashedApps.append(poke.target.rawValue)
                recordProbeLog(
                    "WARMUP \(poke.target.rawValue) TARGET CRASHED during"
                        + " probe — macOS bug, not a denial; suppressing"
                        + " further probes for 24h"
                )
                continue
            }

            evidence.append(result)
            automationStatuses[poke.target] = PermissionWarmupProofPolicy.statuses(
                from: [result]
            )[poke.target]
            completedAutomationTargetCount = evidence.count
            if poke.target == .mail {
                hasEnabledAppleMailAccount = result.hasEnabledMailAccount
            }
            if result.automationAllowed {
                grantedApps.append(poke.target.rawValue)
            } else {
                deniedApps.append(poke.target.rawValue)
            }
            recordProbeLog(
                "WARMUP \(poke.target.rawValue)"
                    + " allowed=\(result.automationAllowed)"
                    + (result.failure.map { " code=\($0.code)" } ?? "")
                    + (poke.target == .mail
                        ? " appleMailAccountConfigured=\(result.hasEnabledMailAccount == true)"
                        : "")
            )
        }

        lastDeniedApplications = deniedApps
        lastCrashedApplications = crashedApps
        // Exclude targets that crashed during their own check — they are
        // unreachable, not refused, and requiring them locked setup forever.
        hasProvenAppAutomation =
            PermissionWarmupProofPolicy.completesCurrentRun(
                evidence,
                crashedTargets: Set(
                    crashedApps.compactMap(PermissionAutomationTarget.init)
                )
            )
        // A crash is distinct from a denial, but remains an unverified target.
        let crashedNote = crashedApps.isEmpty
            ? ""
            : " \(Self.spokenList(crashedApps)) "
                + (crashedApps.count == 1 ? "is" : "are")
                + " crashing on this version of macos, so i'm skipping "
                + (crashedApps.count == 1 ? "it" : "them")
                + " for now — that's apple's bug, not yours."
        if deniedApps.isEmpty && crashedApps.isEmpty {
            if hasEnabledAppleMailAccount == false {
                return "all set — app access works. Apple Mail has no account yet, "
                    + "and that's okay. i'll ask you to set up Apple Mail only if "
                    + "you ask me to use email." + crashedNote
            }
            return "all set — i can now control \(grantedApps.count) apps: \(Self.spokenList(grantedApps))."
                + crashedNote
        }
        return failureSummary
    }

    /// Starts a no-prompt current-TCC revalidation and marks the launch as
    /// pending synchronously. Call this only for an owner who previously
    /// completed onboarding. A clean first run must use `runForSetup()` so
    /// consent prompts appear only after the owner presses the setup button.
    ///
    /// Apple's public TCC predicate requires a running target. For an Apple
    /// system app that is not running, the probe opens the exact system bundle
    /// hidden and without activation, asks TCC with `askUserIfNeeded=false`,
    /// then terminates only the process this probe started. No Apple Event is
    /// sent and this path can never raise an Automation consent prompt.
    func beginNoninteractiveRevalidation() {
        guard !isRunning,
              !isRevalidatingAutomation,
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else { return }

        hasProvenAppAutomation = false
        hasEnabledAppleMailAccount = nil
        lastDeniedApplications = []
        lastCrashedApplications = []
        automationFailures = [:]
        automationStatuses = PermissionWarmupProofPolicy.statuses(from: [])
        runGeneration &+= 1
        let generation = runGeneration
        isRevalidatingAutomation = true

        revalidationTask = Task { @MainActor [weak self] in
            await self?.performNoninteractiveRevalidation(
                generation: generation
            )
        }
    }

    private func performNoninteractiveRevalidation(
        generation: UInt64
    ) async {
        defer {
            if runGeneration == generation {
                isRevalidatingAutomation = false
                revalidationTask = nil
            }
        }

        var evidence: [PermissionAutomationEvidence] = []
        for target in PermissionAutomationTarget.allCases {
            guard shouldContinueRevalidation(generation: generation) else {
                return
            }
            let status = await noninteractivePermissionStatus(
                for: target,
                generation: generation
            )
            guard shouldContinueRevalidation(generation: generation) else {
                return
            }
            let result = PermissionWarmupProofPolicy.noninteractiveEvidence(
                target: target,
                appleEventPermissionStatus: status
            )
            evidence.append(result)
            automationStatuses[target] = PermissionWarmupProofPolicy.statuses(
                from: [result]
            )[target]
            automationFailures[target] = result.failure
            recordProbeLog(
                "WARMUP-REVALIDATE \(target.rawValue)"
                    + " allowed=\(result.automationAllowed)"
            )
        }

        hasProvenAppAutomation =
            PermissionWarmupProofPolicy.completesCurrentRun(evidence)
        lastDeniedApplications = evidence.compactMap {
            $0.automationAllowed ? nil : $0.target.rawValue
        }
        recordProbeLog(
            "WARMUP-REVALIDATE complete"
                + " allowed=\(hasProvenAppAutomation)"
        )
    }

    private func noninteractivePermissionStatus(
        for target: PermissionAutomationTarget,
        generation: UInt64,
        requestConsent: Bool = false
    ) async -> Int32? {
        let applicationURL = URL(fileURLWithPath: target.applicationPath)
            .standardizedFileURL
        guard Bundle(url: applicationURL)?.bundleIdentifier
                == target.bundleIdentifier else {
            return nil
        }

        var runningApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: target.bundleIdentifier)
            .first {
                $0.bundleURL?.standardizedFileURL == applicationURL
                    && !$0.isTerminated
            }
        let wasAlreadyRunning = runningApplication != nil
        var ownedLaunchBoundary:
            PermissionWarmupApplicationLaunchBoundary?
        defer {
            ownedLaunchBoundary?.clearExactApplicationCutoff()
        }

        if runningApplication == nil {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.promptsUserIfNeeded = false
            configuration.addsToRecentItems = false
            configuration.activates = false
            configuration.hides = true
            configuration.hidesOthers = false
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false
            let launchBoundary =
                PermissionWarmupApplicationLaunchBoundary()
            ownedLaunchBoundary = launchBoundary

            runningApplication = await withCheckedContinuation {
                (
                    continuation:
                        CheckedContinuation<
                            NSRunningApplication?,
                            Never
                        >
                ) in
                let didBegin = launchBoundary
                    .beginNativeLaunchIfAdmitted {
                        let request: Void = NSWorkspace.shared.openApplication(
                            at: applicationURL,
                            configuration: configuration
                        ) { application, error in
                            guard let application else {
                                continuation.resume(returning: nil)
                                return
                            }

                            let cutoffBox =
                                PermissionWarmupApplicationCutoffBox(
                                    application: application
                                )
                            guard launchBoundary
                                .registerExactApplicationCutoff({
                                    cutoffBox.terminateSynchronously()
                                }) else {
                                continuation.resume(returning: nil)
                                return
                            }
                            guard error == nil else {
                                cutoffBox.terminateSynchronously()
                                continuation.resume(returning: nil)
                                return
                            }
                            continuation.resume(returning: application)
                        }
                        _ = request
                    }
                if !didBegin {
                    continuation.resume(returning: nil)
                }
            }
            guard !launchBoundary.isCutOff else {
                return nil
            }
        }

        guard let runningApplication else { return nil }
        if !wasAlreadyRunning {
            revalidationLaunchedApplication = runningApplication
        }
        defer {
            if !wasAlreadyRunning,
               !runningApplication.isTerminated,
               !runningApplication.isActive {
                _ = runningApplication.terminate()
            }
            if revalidationLaunchedApplication === runningApplication {
                revalidationLaunchedApplication = nil
            }
        }

        guard (requestConsent
                ? shouldContinue(generation: generation)
                : shouldContinueRevalidation(generation: generation)),
              runningApplication.bundleIdentifier
                == target.bundleIdentifier,
              runningApplication.bundleURL?.standardizedFileURL
                == applicationURL else {
            return nil
        }
        return await Self.appleEventPermissionStatus(
            target: target,
            requestConsent: requestConsent
        )
    }

    // Contacts can expose processIdentifier == -1 through NSRunningApplication
    // even when the exact system app is running. The caller has already verified
    // its bundle path and identity; permission lookup addresses that bundle,
    // avoiding a dead PID descriptor without sending a data-reading Apple Event.
    nonisolated static func automationPermissionAddress(
        for target: PermissionAutomationTarget
    ) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(bundleIdentifier: target.bundleIdentifier)
    }

    private nonisolated static func appleEventPermissionStatus(
        target: PermissionAutomationTarget,
        requestConsent: Bool = false
    ) async -> Int32? {
        await PermissionWarmupNativePermissionBroker.shared.status(
            for: target, requestConsent: requestConsent
        ) { shouldRequestConsent in
            guard !StealthEntryLatch.shared.isRaised else { return nil }
            let descriptor = automationPermissionAddress(for: target)
            guard let address = descriptor.aeDesc else { return nil }
            return AEDeterminePermissionToAutomateTarget(
                address,
                typeWildCard,
                typeWildCard,
                shouldRequestConsent
            )
        }
    }

    private func shouldContinueRevalidation(
        generation: UInt64
    ) -> Bool {
        !Task.isCancelled
            && isRevalidatingAutomation
            && runGeneration == generation
            && !StealthEntryLatch.shared.isRaised
            && !StealthVisibilityGate.shared.isActive
    }

    /// A launch must never wait forever on a wedged Launch Services/TCC query.
    /// The caller owns the visible repair UI; this method synchronously removes
    /// all authority, invalidates every in-flight callback, and stops only the
    /// hidden system-app process that this revalidation started.
    func failCurrentNoninteractiveRevalidation() {
        guard isRevalidatingAutomation else { return }
        runGeneration &+= 1
        revalidationTask?.cancel()
        revalidationTask = nil
        isRevalidatingAutomation = false
        hasProvenAppAutomation = false
        hasEnabledAppleMailAccount = nil
        lastDeniedApplications =
            PermissionAutomationTarget.allCases.map(\.rawValue)
        automationStatuses = Dictionary(
            uniqueKeysWithValues: PermissionAutomationTarget.allCases.map {
                ($0, PermissionAutomationTargetStatus.denied)
            }
        )
        terminateRevalidationLaunchedApplicationIfSafe()
        recordProbeLog(
            "WARMUP-REVALIDATE invalidated (timeout or interrupted launch)"
        )
    }

    /// First-run setup starts the same proof without requiring voice. macOS may
    /// show an Ace → Apple Mail Automation prompt because this performs the same
    /// harmless account-count read as every other target. A missing Apple Mail account
    /// is deliberately not a denial, and no message is opened, drafted, or sent;
    /// only a rejected/broken Automation read opens the exact Settings pane.
    @discardableResult
    func runForSetup() -> Bool {
        recordProbeLog(
            "WARMUP-SETUP requested"
                + " running=\(isRunning)"
                + " revalidating=\(isRevalidatingAutomation)"
        )
        guard !isRunning, !isRevalidatingAutomation else { return false }
        Task { @MainActor [weak self] in
            // Leave SwiftUI's button-action transaction before spawning the
            // Apple Event that may synchronously raise a macOS consent sheet.
            // Starting it from inside AppKitEventBindingBridge.flushActions()
            // crashes SwiftUI's executor check on current macOS seeds.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self else { return }
            _ = await run()
            guard !StealthEntryLatch.shared.isRaised,
                  !StealthVisibilityGate.shared.isActive,
                  !hasProvenAppAutomation else { return }
            _ = SetupVisibleEffectAdmission.commit {
                return NSWorkspace.shared.open(
                    PermissionSystemSettingsPane.automation.deepLink
                )
            }
        }
        return true
    }

    /// Stealth entry is a hard wall: invalidate the sequence before terminating
    /// its current child so the loop cannot advance to the next consent prompt.
    /// A later explicit `run()` after stealth exits starts a fresh sequence.
    func suspendForStealth() {
        isSuspendedForStealth = true
        currentAutomationTarget = nil
        completedAutomationTargetCount = 0
        for target in PermissionAutomationTarget.allCases
        where automationStatuses[target] == .checking {
            automationStatuses[target] = .notRequested
        }
        if isRevalidatingAutomation {
            failCurrentNoninteractiveRevalidation()
        } else {
            runGeneration &+= 1
        }
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
        }
    }

    private func terminateRevalidationLaunchedApplicationIfSafe() {
        if let revalidationLaunchedApplication,
           !revalidationLaunchedApplication.isTerminated,
           !revalidationLaunchedApplication.isActive {
            _ = revalidationLaunchedApplication.terminate()
        }
        revalidationLaunchedApplication = nil
    }

    /// Runs one osascript poke as a direct child of Ace. Generous timeout: the
    /// process legitimately sits blocked while the consent dialog is on screen.
    private func runPoke(
        script: String,
        generation: UInt64
    ) async -> (
        terminationStatus: Int32?,
        standardOutput: String,
        standardError: String
    ) {
        guard shouldContinue(generation: generation) else {
            return (nil, "", "")
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let completion = PermissionWarmupPokeCompletion()
        process.terminationHandler = { process in
            completion.finish(with: process.terminationStatus)
        }

        let processCutoffBox =
            PermissionWarmupProcessCutoffBox(process: process)
        let cutoffRegistration =
            StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                processCutoffBox.cutOffSynchronously()
            }
        defer {
            StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(
                cutoffRegistration
            )
        }

        do {
            // `Process.run()` is the Automation-prompt admission point. It is a
            // bounded spawn call: X either wins first and no child exists, or
            // the child starts first and the registered cutoff terminates it.
            let didLaunch = try StealthEntryLatch.shared
                .performUnlessRaised {
                    try process.run()
                    return true
                }
            guard didLaunch == true, !processCutoffBox.isCutOff else {
                if process.isRunning {
                    process.terminate()
                }
                process.terminationHandler = nil
                return (nil, "", "")
            }
        } catch {
            process.terminationHandler = nil
            return (nil, "", "")
        }
        runningProcess = process

        // No actor work can interleave between the guard and `run()`, but task
        // cancellation may already be pending by the time the child launches.
        if !shouldContinue(generation: generation) {
            process.terminate()
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + 75, execute: watchdog)

        let terminationStatus = await withTaskCancellationHandler {
            await completion.wait()
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
        watchdog.cancel()
        if runningProcess === process {
            runningProcess = nil
        }
        try? outputPipe.fileHandleForWriting.close()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        try? outputPipe.fileHandleForReading.close()
        try? errorPipe.fileHandleForWriting.close()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        try? errorPipe.fileHandleForReading.close()
        return (
            terminationStatus,
            String(data: outputData, encoding: .utf8) ?? "",
            String(data: errorData.prefix(4096), encoding: .utf8) ?? ""
        )
    }

    private func shouldContinue(generation: UInt64) -> Bool {
        !Task.isCancelled
            && !isSuspendedForStealth
            && runGeneration == generation
            && !StealthEntryLatch.shared.isRaised
            && !StealthVisibilityGate.shared.isActive
    }

    private static func spokenList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    private func recordProbeLog(_ message: String) {
        guard targetProbe == nil else { return }
        Self.appendLog(message)
    }

    private static func appendLog(_ message: String) {
        guard let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true) else { return }
        // 0700 or the bundled tools all fail closed — see LifecycleLog.append.
        try? PrivateSupportDirectory.ensure(at: directory)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let fileURL = directory.appendingPathComponent("agent.log")
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: fileURL, options: .atomic)
        }
    }
}
#endif // circuit-convert
