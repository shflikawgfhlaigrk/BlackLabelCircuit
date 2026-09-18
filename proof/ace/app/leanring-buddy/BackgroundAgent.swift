//
//  BackgroundAgent.swift
//  Black Label Assistant — one isolated background execution worker.
//
//  The gold cursor talks with the owner. Independent Red and Silver instances
//  perform at most two concurrent tasks through buyer-owned bundled CLIs.
//

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

/// Thread-safe holder for the Claude process spawned on a background queue, so
/// the MainActor "stop" route can terminate it mid-task. Process itself is not
/// Sendable; every access goes through the lock.
nonisolated final class RunningProcessBox: @unchecked Sendable {
    private static let maximumProcessCount = 128

    private let lock = NSLock()
    private var process: Process?
    private var processGeneration: UInt64?
    private var pendingTerminationGenerations: Set<UInt64> = []

    func set(_ newProcess: Process?) {
        lock.lock()
        process = newProcess
        processGeneration = nil
        lock.unlock()
    }

    /// Publishes a process for one specific agent run. If cancellation won the
    /// tiny `Process.run()` → publication race, terminate the child immediately
    /// instead of forgetting the cancellation.
    func register(_ newProcess: Process, generation: UInt64) {
        lock.lock()
        let shouldTerminate = pendingTerminationGenerations.contains(generation)
        if !shouldTerminate {
            process = newProcess
            processGeneration = generation
        }
        lock.unlock()

        if shouldTerminate, newProcess.isRunning {
            Self.terminateProcessTree(newProcess)
        }
    }

    func clear(generation: UInt64) {
        lock.lock()
        pendingTerminationGenerations.remove(generation)
        if processGeneration == generation {
            process = nil
            processGeneration = nil
        }
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let processToTerminate = process
        lock.unlock()
        if let processToTerminate, processToTerminate.isRunning {
            Self.terminateProcessTree(processToTerminate)
        }
    }

    /// Records cancellation even before the child is published. `register`
    /// observes the latch and kills a process that lost that race.
    func terminate(generation: UInt64) {
        lock.lock()
        pendingTerminationGenerations.insert(generation)
        let processToTerminate = processGeneration == generation ? process : nil
        lock.unlock()
        if let processToTerminate, processToTerminate.isRunning {
            Self.terminateProcessTree(processToTerminate)
        }
    }

    /// A CLI may have helper descendants. Terminating only the parent can leave
    /// those descendants alive after Stealth Mode appears, so freeze discovery
    /// and kill the tree leaf-first.
    nonisolated static func terminateProcessTree(_ rootProcess: Process) {
        guard rootProcess.isRunning else { return }
        let rootProcessIdentifier = rootProcess.processIdentifier
        _ = Darwin.kill(rootProcessIdentifier, SIGSTOP)

        var frozenProcessIdentifiers: [pid_t] = [
            rootProcessIdentifier,
        ]
        var inspectionIndex = 0
        while inspectionIndex < frozenProcessIdentifiers.count,
              frozenProcessIdentifiers.count < maximumProcessCount {
            let parentProcessIdentifier =
                frozenProcessIdentifiers[inspectionIndex]
            inspectionIndex += 1
            let remainingCapacity =
                maximumProcessCount
                - frozenProcessIdentifiers.count
            var childProcessIdentifiers = [pid_t](
                repeating: 0,
                count: remainingCapacity
            )
            let discoveredCount =
                childProcessIdentifiers.withUnsafeMutableBytes {
                    buffer in
                    proc_listchildpids(
                        parentProcessIdentifier,
                        buffer.baseAddress,
                        Int32(buffer.count)
                    )
                }
            guard discoveredCount > 0 else { continue }
            let boundedDiscoveredCount = min(
                Int(discoveredCount),
                remainingCapacity
            )
            for childProcessIdentifier in
                childProcessIdentifiers.prefix(
                    boundedDiscoveredCount
                )
            where childProcessIdentifier > 1 {
                _ = Darwin.kill(childProcessIdentifier, SIGSTOP)
                frozenProcessIdentifiers.append(
                    childProcessIdentifier
                )
            }
        }
        for processIdentifier in frozenProcessIdentifiers.reversed() {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}

/// Total-orders model launch, generation admission, and Stealth entry.
///
/// X raises `StealthEntryLatch` before its MainActor transition. A launch that
/// wins the latch publishes its PID before releasing that latch; a launch that
/// loses never calls `Process.run`. The synchronous cutoff invalidates every
/// admitted generation before freezing and killing its bounded process tree.
/// It uses no helper process, pipe, filesystem operation, or process wait.
nonisolated final class StealthModelProcessAdmission: @unchecked Sendable {
    typealias ProcessTreeCutoff = @Sendable (pid_t) -> Void

    private static let maximumProcessCount = 128
    private static let defaultProcessTreeCutoff:
        ProcessTreeCutoff = { processIdentifier in
            freezeAndKillProcessTree(root: processIdentifier)
        }

    private let lock = NSLock()
    private let entryLatch: StealthEntryLatch
    private let processTreeCutoff: ProcessTreeCutoff
    private var synchronousCutoffIdentifier: UUID?
    private var nextGeneration: UInt64 = 0
    private var currentGenerations: Set<UInt64> = []
    private var publishedProcessIdentifiers: [UInt64: pid_t] = [:]

    init(
        entryLatch: StealthEntryLatch = .shared,
        processTreeCutoff: ProcessTreeCutoff? = nil
    ) {
        self.entryLatch = entryLatch
        self.processTreeCutoff =
            processTreeCutoff ?? Self.defaultProcessTreeCutoff
        synchronousCutoffIdentifier =
            entryLatch.registerSynchronousEntryCutoff { [weak self] in
                self?.cutOffSynchronously()
            }
    }

    deinit {
        if let synchronousCutoffIdentifier {
            entryLatch.unregisterSynchronousEntryCutoff(
                synchronousCutoffIdentifier
            )
        }
    }

    /// Claims the generation under the same latch X raises. X-first therefore
    /// creates no generation that delayed work could later use.
    func claimGeneration() -> UInt64? {
        entryLatch.performUnlessRaised {
            lock.withLock {
                nextGeneration &+= 1
                currentGenerations.insert(nextGeneration)
                return nextGeneration
            }
        }
    }

    /// `launch` is the production `Process.run()` call. PID publication occurs
    /// before either local lock or the process-wide Stealth latch is released.
    /// The injectable closures provide a process-free deterministic test seam.
    @discardableResult
    func launchAndPublishIfCurrent(
        generation: UInt64,
        launch: () throws -> pid_t,
        publish: (pid_t) -> Void
    ) rethrows -> Bool {
        let wasLaunched: Bool? = try entryLatch.performUnlessRaised {
            try lock.withLock {
                guard currentGenerations.contains(generation) else {
                    return false
                }
                let processIdentifier = try launch()
                publishedProcessIdentifiers[generation] =
                    processIdentifier
                publish(processIdentifier)
                return true
            }
        }
        return wasLaunched ?? false
    }

    func isCurrent(generation: UInt64) -> Bool {
        let isCurrent: Bool? = entryLatch.performUnlessRaised {
            lock.withLock {
                currentGenerations.contains(generation)
            }
        }
        return isCurrent ?? false
    }

    /// Normal stop/cancellation may perform its additional asynchronous
    /// cleanup after this returns. Generation invalidation and SIGSTOP/SIGKILL
    /// are complete before any later stdin commit can be admitted.
    func cancel(generation: UInt64) {
        let processIdentifier = lock.withLock { () -> pid_t? in
            currentGenerations.remove(generation)
            return publishedProcessIdentifiers.removeValue(
                forKey: generation
            )
        }
        if let processIdentifier {
            processTreeCutoff(processIdentifier)
        }
    }

    func cancelAll() {
        let processIdentifiers = invalidateAllGenerations()
        for processIdentifier in processIdentifiers {
            processTreeCutoff(processIdentifier)
        }
    }

    /// Retires only the PID after exit. The generation remains current until
    /// its caller has gated the answer read and any output publication.
    func retireProcess(generation: UInt64) {
        _ = lock.withLock {
            publishedProcessIdentifiers.removeValue(
                forKey: generation
            )
        }
    }

    func finish(generation: UInt64) {
        lock.withLock {
            currentGenerations.remove(generation)
            publishedProcessIdentifiers.removeValue(
                forKey: generation
            )
        }
    }

    private func cutOffSynchronously() {
        let processIdentifiers = invalidateAllGenerations()
        for processIdentifier in processIdentifiers {
            processTreeCutoff(processIdentifier)
        }
    }

    private func invalidateAllGenerations() -> [pid_t] {
        lock.withLock {
            currentGenerations.removeAll(keepingCapacity: true)
            let processIdentifiers =
                Array(publishedProcessIdentifiers.values)
            publishedProcessIdentifiers.removeAll(
                keepingCapacity: true
            )
            return processIdentifiers
        }
    }

    private static func freezeAndKillProcessTree(root: pid_t) {
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
                maximumProcessCount
                - frozenProcessIdentifiers.count
            var childProcessIdentifiers = [pid_t](
                repeating: 0,
                count: remainingCapacity
            )
            let discoveredCount =
                childProcessIdentifiers.withUnsafeMutableBytes { buffer in
                    proc_listchildpids(
                        parentProcessIdentifier,
                        buffer.baseAddress,
                        Int32(buffer.count)
                    )
                }
            guard discoveredCount > 0 else { continue }
            let boundedDiscoveredCount = min(
                Int(discoveredCount),
                remainingCapacity
            )
            for childProcessIdentifier in
                childProcessIdentifiers.prefix(boundedDiscoveredCount)
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

/// Writes private model data in bounded chunks without holding the event-tap
/// latch. X invalidates the generation immediately even if a filesystem or
/// test writer is stalled; the writer discards the result when its current
/// chunk returns and never starts another chunk.
nonisolated enum StealthPrivateDataStager {
    static let maximumChunkByteCount = 64 * 1_024

    static func writeChunksIfCurrent(
        _ data: Data,
        generation: UInt64,
        admission: StealthModelProcessAdmission,
        writeChunk: (UnsafeRawBufferPointer) throws -> Int
    ) rethrows -> Bool {
        var writtenByteCount = 0
        while writtenByteCount < data.count {
            guard admission.isCurrent(
                generation: generation
            ) else {
                return false
            }
            let nextChunkByteCount = min(
                maximumChunkByteCount,
                data.count - writtenByteCount
            )
            let chunkWrittenByteCount = try data.withUnsafeBytes {
                dataBytes in
                let chunkBytes = UnsafeRawBufferPointer(
                    rebasing:
                        dataBytes[
                            writtenByteCount
                                ..< writtenByteCount
                                + nextChunkByteCount
                        ]
                )
                return try writeChunk(chunkBytes)
            }
            guard chunkWrittenByteCount > 0,
                  chunkWrittenByteCount <= nextChunkByteCount else {
                return false
            }
            writtenByteCount += chunkWrittenByteCount
            guard admission.isCurrent(
                generation: generation
            ) else {
                return false
            }
        }
        return admission.isCurrent(generation: generation)
    }
}

/// An unlinked 0600 file supplies stdin without a blocking pipe write. Prompt
/// bytes are staged before launch, checked after every bounded chunk, and have
/// no pathname that a hard kill can strand.
nonisolated enum PrivateModelStandardInput {
    static func stage(
        standardInput: String,
        generation: UInt64,
        admission: StealthModelProcessAdmission,
        unlinkFile: (UnsafePointer<CChar>) -> Int32 = {
            Darwin.unlink($0)
        }
    ) throws -> FileHandle? {
        guard admission.isCurrent(generation: generation),
              let standardInputData =
                standardInput.data(using: .utf8) else {
            return nil
        }
        let temporaryFileTemplate =
            FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ace-model-input-\(UUID().uuidString)-XXXXXX"
            )
            .path
        var temporaryFileTemplateBytes =
            Array(temporaryFileTemplate.utf8CString)
        let fileDescriptor = temporaryFileTemplateBytes
            .withUnsafeMutableBufferPointer { buffer in
                mkstemp(buffer.baseAddress)
            }
        guard fileDescriptor >= 0 else {
            throw NSError(
                domain: "AceModelInput",
                code: Int(errno),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "could not create private model input",
                ]
            )
        }
        let didSetPrivatePermissions =
            fchmod(fileDescriptor, mode_t(0o600)) == 0
        let didUnlinkPrivateInput =
            didSetPrivatePermissions
            && temporaryFileTemplateBytes.withUnsafeBufferPointer {
                buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return false
                }
                return unlinkFile(baseAddress) == 0
            }
        guard didSetPrivatePermissions,
              didUnlinkPrivateInput else {
            let preparationError = errno
            close(fileDescriptor)
            temporaryFileTemplateBytes.withUnsafeBufferPointer {
                buffer in
                if let baseAddress = buffer.baseAddress {
                    _ = Darwin.unlink(baseAddress)
                }
            }
            throw NSError(
                domain: "AceModelInput",
                code: Int(preparationError),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "could not seal private model input",
                ]
            )
        }

        let didWriteAllInput =
            StealthPrivateDataStager.writeChunksIfCurrent(
                standardInputData,
                generation: generation,
                admission: admission
            ) { chunkBytes in
                while true {
                    let result = Darwin.write(
                        fileDescriptor,
                        chunkBytes.baseAddress,
                        chunkBytes.count
                    )
                    if result < 0, errno == EINTR {
                        continue
                    }
                    return result
                }
            }
        guard didWriteAllInput,
              lseek(fileDescriptor, 0, SEEK_SET) == 0,
              admission.isCurrent(
                generation: generation
              ) else {
            close(fileDescriptor)
            return nil
        }
        return FileHandle(
            fileDescriptor: fileDescriptor,
            closeOnDealloc: true
        )
    }
}

/// Captures model stdout without ever naming it in the filesystem. The reader
/// continues draining after the limit so a verbose child cannot deadlock on a
/// full pipe; only the bounded prefix is retained in this process's memory.
nonisolated private final class BoundedProcessOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(newData.prefix(remaining))
        }
        if newData.count > remaining {
            truncated = true
        }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, truncated)
    }
}

nonisolated private final class ProcessWatchdogState: @unchecked Sendable {
    private let lock = NSLock()
    private var firedStorage = false

    func markFired() {
        lock.withLock { firedStorage = true }
    }

    var fired: Bool { lock.withLock { firedStorage } }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class BackgroundAgent: ObservableObject {
    nonisolated enum Identity: String, Sendable {
        case red
        case silver

        var displayName: String {
            self == .red ? "Red Agent" : "Silver Agent"
        }
    }

    /// True while a background task is running — CompanionManager mirrors this to
    /// `backgroundTaskActive`; each instance also drives its own lane gem.
    @Published private(set) var isWorking = false
    @Published private(set) var status = "Idle"

    /// The currently running provider process, reachable across threads.
    private var browserService: BackgroundBrowserService?
    private let runningProcessBox: RunningProcessBox
    private let modelProcessAdmission: StealthModelProcessAdmission
    private let identity: Identity

    /// Stealth is a persistent execution gate, not a one-shot cancel flag. A
    /// worker Task queued before entry may not call `run` until later.
    private var isSuspendedForStealth = false
    private var activeRunGeneration: UInt64?
    private var cancelledRunGenerations: Set<UInt64> = []

    init(
        identity: Identity = .red,
        entryLatch: StealthEntryLatch = .shared
    ) {
        let runningProcessBox = RunningProcessBox()
        self.runningProcessBox = runningProcessBox
        self.identity = identity
        modelProcessAdmission = StealthModelProcessAdmission(
            entryLatch: entryLatch
        )
    }

    /// User said "stop" — kill the in-flight reasoning task. `run` sees the
    /// generation latch and returns silently without logging private context.
    func cancelCurrentTask() {
        CodexModelCapabilityPreflight.shared.invalidate(
            reason: .cancellation
        )
        guard let generation = activeRunGeneration else { return }
        browserService?.stop(); browserService = nil
        cancelledRunGenerations.insert(generation)
        modelProcessAdmission.cancel(generation: generation)
        runningProcessBox.terminate(generation: generation)
    }

    /// Raises a hard wall before CompanionManager yields the main actor. Existing
    /// work is cancelled, and delayed calls to `run` fail closed until exit.
    func suspendForStealth() {
        CodexModelCapabilityPreflight.shared.invalidate(
            reason: .privateMode
        )
        guard !isSuspendedForStealth else { return }
        isSuspendedForStealth = true
        browserService?.stop(); browserService = nil
        if let generation = activeRunGeneration {
            cancelledRunGenerations.insert(generation)
            modelProcessAdmission.cancel(generation: generation)
            runningProcessBox.terminate(generation: generation)
        }
    }

    func resumeAfterStealth() {
        isSuspendedForStealth = false
    }

    /// A new signed lease reopens the lane only. The entitlement-loss path has
    /// already cancelled the old generation/process, so no prior run can be
    /// recovered by this method.
    func resumeNewWorkAfterEntitlementRestored() {
        isSuspendedForStealth = false
    }

    /// FULL-ACCESS lane — real tools, no permission prompts.
    ///
    /// 2026-07-31 founder ruling: the background lane could not see the screen or find anything,
    /// because `--tools ""` gave it no tools at all. This is the opposite lane: the CLI's own
    /// tools with `--dangerously-skip-permissions`, so Ace can actually read files, search, and
    /// look at a captured screen instead of reasoning from nothing and then honestly reporting
    /// that it saw nothing.
    ///
    /// Customer-owned Codex is intentionally unrestricted. Founder-hosted
    /// traffic never reaches this local process lane.
    nonisolated static func fullAccessClaudeArguments(
        model: AceClaudeModel
    ) -> [String] {
        BrainBackend.privacyArguments(
            for: .claude,
            BrainBackend.isolatedBaseArguments(model: model) + [
            "--disable-slash-commands",
            "--no-chrome",
            "--no-session-persistence",
            "--dangerously-skip-permissions",
        ] + RedProviderExecutionProfilePolicy.claudeSystemPromptArguments)
    }

    /// Argv for the selected provider. Every provider gets the same full
    /// local access; only the model process differs.
    nonisolated static func laneArguments(
        for cli: BrainCLI,
        resolvedCodexModel: String?
    ) -> [String] {
        switch cli {
        case .codex:
            guard let resolvedCodexModel else {
                preconditionFailure(
                    "Codex capability must resolve before background argv"
                )
            }
            return BrainBackend.codexFullAccessArguments(
                resolvedModel: resolvedCodexModel
            ) + RedProviderExecutionProfilePolicy.codexSystemPromptArguments
        case .claude:
            // The Red lane answers with the owner's current picker choice.
            let selectedClaudeModel = AceClaudeModel.currentSelection
            return fullAccessClaudeArguments(model: selectedClaudeModel)
        case .qwen:
            return AceLocalBrain.cliAnswerArguments()
        }
    }

    nonisolated static func resolvedLaneArguments(
        for cli: BrainCLI,
        executablePath: String,
        resolveCodexModel:
            @escaping @Sendable (String) async throws -> String = {
                try await BrainBackend.resolveCodexModel(
                    executablePath: $0
                )
            }
    ) async throws -> [String] {
        let resolvedModel = cli == .codex
            ? try await resolveCodexModel(executablePath)
            : nil
        return laneArguments(
            for: cli,
            resolvedCodexModel: resolvedModel
        )
    }

    /// Runs one background task and returns one app-owned terminal classification.
    /// Model text supplies only the bounded reason for a completed run; it
    /// cannot relabel an app-observed block, timeout, failure, or cancellation.
    func run(
        instruction: String,
        screenshotPaths: [String],
        provider: BrainCLI
    ) async -> BackgroundAgentTerminalResult {
        let agentDisplayName = identity.displayName
        guard !isSuspendedForStealth, !Task.isCancelled else {
            return BackgroundAgentDeliveryPolicy.cancelled()
        }
        guard activeRunGeneration == nil else {
            return BackgroundAgentDeliveryPolicy.blocked(
                outcome: "blocked.busy",
                reason: "i'm already handling another background task, so i didn't start a second one."
            )
        }
        guard let generation =
            modelProcessAdmission.claimGeneration() else {
            return BackgroundAgentDeliveryPolicy.failed(
                outcome: "failed.admission",
                reason: "\(agentDisplayName) could not acquire its process slot. The task did not start."
            )
        }
        let modelProcessAdmission = self.modelProcessAdmission
        activeRunGeneration = generation
        isWorking = true
        // Never mirror the owner's full instruction into an observable status
        // string; future UI/log subscribers get state, not private content.
        status = "Working"
        defer {
            cancelledRunGenerations.remove(generation)
            modelProcessAdmission.finish(generation: generation)
            runningProcessBox.clear(generation: generation)
            if activeRunGeneration == generation {
                browserService?.stop(); browserService = nil
                activeRunGeneration = nil
                isWorking = false
                status = "Idle"
            }
        }

        guard shouldContinueRun(generation) else {
            return BackgroundAgentDeliveryPolicy.cancelled()
        }

        // Provider selection changes the model binary, not the slot's authority.
        let selectedCLI = provider
        let providerInvocation = AceProviderTurn(provider: selectedCLI)
        let providerInvocationStartedAt = Date()
        let brainExecutablePath: String?
        do {
            brainExecutablePath =
                try await ClaudePrivateIOWorker.perform {
                    guard modelProcessAdmission.isCurrent(
                        generation: generation
                    ) else {
                        throw CancellationError()
                    }
                    return BrainBackend.resolveExecutable(for: selectedCLI)
                }
        } catch {
            return shouldContinueRun(generation)
                ? BackgroundAgentDeliveryPolicy.failed(
                    outcome: "failed.cli-resolution",
                    reason: "\(agentDisplayName) could not resolve the selected customer CLI. The task did not start."
                )
                : BackgroundAgentDeliveryPolicy.cancelled()
        }
        if AceBrainRoute.current == .customerOwned,
           brainExecutablePath == nil {
            return BackgroundAgentDeliveryPolicy.blocked(
                outcome: "blocked.cli-unavailable",
                reason: "\(agentDisplayName) needs a bundled customer CLI selected and signed in. The task did not start."
            )
        }
        if modelProcessAdmission.isCurrent(generation: generation) {
            Self.scheduleLog(
                "TASK provider=\(selectedCLI.rawValue) instructionBytes=\(instruction.utf8.count)",
                admission: modelProcessAdmission,
                generation: generation
            )
        }

        let usesHostedBrain = AceBrainRoute.current == .founderHosted
        let composedPrompt: String
        do {
            composedPrompt =
                try await ClaudePrivateIOWorker.perform {
                    guard modelProcessAdmission.isCurrent(
                        generation: generation
                    ) else {
                        throw CancellationError()
                    }
                    let composedPrompt = RedProviderExecutionProfilePolicy
                        .workerPrompt(
                            instruction: instruction,
                            screenshotPaths: screenshotPaths,
                            provider: selectedCLI,
                            isHosted: usesHostedBrain
                        )
                    guard modelProcessAdmission.isCurrent(
                        generation: generation
                    ) else {
                        throw CancellationError()
                    }
                    return composedPrompt
                }
        } catch {
            return shouldContinueRun(generation)
                ? BackgroundAgentDeliveryPolicy.failed(
                    outcome: "failed.prompt-preparation",
                    reason: "\(agentDisplayName) could not prepare the task. Nothing ran."
                )
                : BackgroundAgentDeliveryPolicy.cancelled()
        }

        if usesHostedBrain {
            do {
                let summary = try await HostedBrainClient.complete(
                    kind: .background,
                    prompt: composedPrompt
                )
                guard shouldContinueRun(generation) else {
                    return BackgroundAgentDeliveryPolicy.cancelled()
                }
                Self.scheduleLog(
                    "DONE hosted summaryBytes=\(summary.utf8.count)",
                    admission: modelProcessAdmission,
                    generation: generation
                )
                return BackgroundAgentDeliveryPolicy.terminalResult(
                    rawOutput: summary,
                    timedOut: false,
                    explicitlyCancelled: false
                )
            } catch is CancellationError {
                return BackgroundAgentDeliveryPolicy.cancelled()
            } catch {
                guard shouldContinueRun(generation) else {
                    return BackgroundAgentDeliveryPolicy.cancelled()
                }
                return BackgroundAgentDeliveryPolicy.failed(
                    outcome: "failed.hosted-unavailable",
                    reason: "the hosted reasoning call is unavailable right now. no apps or files were changed."
                )
            }
        }

        let browser = BackgroundBrowserService(isAllowed: { [weak self] in
            self?.shouldContinueRun(generation) == true
        }, dataAdapter: { [weak self] request in
            await BackgroundDataAdapter.execute(request) {
                self?.shouldContinueRun(generation) == true
            }
        })
        browserService = browser
        var browserEnvironment: [String: String] = [:]
        do { browserEnvironment = try await browser.start() }
        catch {
            browser.stop()
            if browserService === browser { browserService = nil }
            guard shouldContinueRun(generation) else {
                return BackgroundAgentDeliveryPolicy.cancelled()
            }
            // This is one optional tool, not a prerequisite for filesystem,
            // native-app, or other browser work admitted by the owner.
            Self.scheduleLog(
                "SERVICE isolated-browser-unavailable; continuing with available tools",
                admission: modelProcessAdmission,
                generation: generation
            )
        }
        guard shouldContinueRun(generation) else {
            return BackgroundAgentDeliveryPolicy.cancelled()
        }

        if selectedCLI == .qwen {
            do {
                let summary = try await AceLocalBrain.agentText(
                    systemPrompt:
                        RedProviderExecutionProfilePolicy.workerSystemInstructions,
                    userPrompt: composedPrompt,
                    workingDirectory:
                        FileManager.default.homeDirectoryForCurrentUser,
                    toolRoutingObjective: instruction,
                    browserEnvironment: browserEnvironment
                )
                guard shouldContinueRun(generation) else {
                    return BackgroundAgentDeliveryPolicy.cancelled()
                }
                Self.scheduleLog(
                    "DONE qwen summaryBytes=\(summary.utf8.count)",
                    admission: modelProcessAdmission,
                    generation: generation
                )
                return BackgroundAgentDeliveryPolicy.terminalResult(
                    rawOutput: summary,
                    timedOut: false,
                    explicitlyCancelled: false
                )
            } catch is CancellationError {
                return BackgroundAgentDeliveryPolicy.cancelled()
            } catch {
                guard shouldContinueRun(generation) else {
                    return BackgroundAgentDeliveryPolicy.cancelled()
                }
                AceProviderInvocationReceiptStore.recordRuntimeFailure(
                    providerInvocation, startedAt: providerInvocationStartedAt,
                    cause: AceReasoningRecoveryPolicy.failureCause(
                        errorTypeName: String(describing: type(of: error)),
                        errorDescription: error.localizedDescription
                    )
                )
                return BackgroundAgentDeliveryPolicy.failed(
                    outcome: "failed.qwen-local-agent",
                    reason: error.localizedDescription
                )
            }
        }

        guard let brainExecutablePath else {
            return BackgroundAgentDeliveryPolicy.blocked(
                outcome: "blocked.cli-unavailable",
                reason: "\(agentDisplayName) needs a bundled customer CLI selected and signed in. The task did not start."
            )
        }
        let workingDirectory = FileManager.default.homeDirectoryForCurrentUser
        let effectAuthority: OwnerTurnEffectAuthority
        var workerEnvironment: [String: String]
        do {
            effectAuthority = try OwnerTurnEffectAuthority.issue()
            let authorityEnvironment = effectAuthority.wrapperEnvironment()
            let trustedTurnAuthority = authorityEnvironment.filter {
                $0.key == "ACE_APP_MUTATION_APPROVED"
                    || $0.key == "ACE_APP_MUTATION_TOKEN_PATH"
            }
            var redTurnAuthority = trustedTurnAuthority
            redTurnAuthority["ACE_OWNER_TURN_MULTI_EFFECT"] = "1"
            guard let resourcesURL = Bundle.main.resourceURL,
                  let applicationSupportURL = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                  ).first else {
                effectAuthority.destroy()
                return BackgroundAgentDeliveryPolicy.failed(
                    outcome: "failed.tool-boundary",
                    reason:
                        "\(agentDisplayName) could not resolve Ace's private tool boundary. Nothing ran."
                )
            }
            workerEnvironment = try RedProviderExecutionProfilePolicy
                .processEnvironment(
                    resourcesURL: resourcesURL,
                    supportDirectoryURL: applicationSupportURL
                        .appendingPathComponent(
                            "BlackLabel",
                            isDirectory: true
                        ),
                    executablePath: brainExecutablePath,
                    parent: ProcessInfo.processInfo.environment,
                    trustedTurnAuthority: redTurnAuthority
                )
        } catch {
            return BackgroundAgentDeliveryPolicy.failed(
                outcome: "failed.tool-boundary",
                reason:
                    "\(agentDisplayName) could not secure Ace's signed tool boundary. Nothing ran."
            )
        }
        defer { effectAuthority.destroy() }
        workerEnvironment.merge(browserEnvironment) { _, trusted in trusted }

        // Every customer provider receives the same signed Ace tools and one
        // app-issued owner-turn effect authority. Provider choice changes only
        // the model process, never this slot's capabilities or admission state.
        let brainArguments: [String]
        do {
            brainArguments = try await Self.resolvedLaneArguments(
                for: selectedCLI,
                executablePath: brainExecutablePath
            )
        } catch is CancellationError {
            return BackgroundAgentDeliveryPolicy.cancelled()
        } catch {
            return BackgroundAgentDeliveryPolicy.failed(
                outcome: "failed.codex-capability",
                reason: error.localizedDescription
            )
        }

        guard shouldContinueRun(generation) else {
            return BackgroundAgentDeliveryPolicy.cancelled()
        }
        let backendLaunch: (executablePath: String, arguments: [String])
        do {
            backendLaunch = try RedProviderExecutionProfilePolicy.backendProcessLaunch(
                executablePath: brainExecutablePath, arguments: brainArguments
            )
        } catch {
            return BackgroundAgentDeliveryPolicy.failed(
                outcome: "failed.provider-executable",
                reason: "The selected provider executable is unavailable. The task did not start."
            )
        }
        let processResult = await withTaskCancellationHandler {
            await Self.runProviderProcess(
                executablePath: backendLaunch.executablePath,
                arguments: backendLaunch.arguments,
                standardInput: composedPrompt,
                workingDirectory: workingDirectory,
                timeout: InteractiveLatencyPolicy.redExecutionDeadline,
                processBox: runningProcessBox,
                processAdmission: modelProcessAdmission,
                processGeneration: generation,
                environment: workerEnvironment
            )
        } onCancel: {
            [modelProcessAdmission, runningProcessBox] in
            modelProcessAdmission.cancel(generation: generation)
            runningProcessBox.terminate(generation: generation)
        }

        // A user-requested stop also surfaces as a terminated process — check the
        // cancel flag before the timeout fallback so a "stop" stays silent.
        if !shouldContinueRun(generation) {
            return BackgroundAgentDeliveryPolicy.cancelled()
        }

        guard modelProcessAdmission.isCurrent(
            generation: generation
        ) else {
            return BackgroundAgentDeliveryPolicy.cancelled()
        }
        let summary =
            String(data: processResult.output, encoding: .utf8)?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
        guard modelProcessAdmission.isCurrent(
            generation: generation
        ) else {
            return BackgroundAgentDeliveryPolicy.cancelled()
        }
        // Model prose never enters the trusted receipt stream. Besides leaking
        // answer content, embedded newlines could forge apparent ROUTE/SWITCH
        // receipts that a later component might mistake for app-owned truth.
        Self.scheduleLog(
            "DONE timedOut=\(processResult.timedOut) "
                + "summaryBytes=\(summary.utf8.count) "
                + "truncated=\(processResult.outputWasTruncated)",
            admission: modelProcessAdmission,
            generation: generation
        )
        guard modelProcessAdmission.isCurrent(
            generation: generation
        ) else {
            return BackgroundAgentDeliveryPolicy.cancelled()
        }
        if processResult.timedOut || processResult.exitStatus != 0
            || processResult.processFailure != nil || summary.isEmpty {
            let diagnostic = processResult.timedOut ? "provider timeout"
                : summary.isEmpty ? "provider returned an empty answer"
                : summary
            AceProviderInvocationReceiptStore.recordRuntimeFailure(
                providerInvocation, startedAt: providerInvocationStartedAt,
                cause: AceReasoningRecoveryPolicy.failureCause(
                    errorTypeName: "ProviderProcessFailure",
                    errorDescription: diagnostic
                )
            )
        }
        return BackgroundAgentDeliveryPolicy.terminalResult(
            rawOutput: summary,
            timedOut: processResult.timedOut,
            explicitlyCancelled: false,
            processExitStatus: processResult.exitStatus,
            processFailure: processResult.processFailure
        )
    }

    private func shouldContinueRun(_ generation: UInt64) -> Bool {
        !Task.isCancelled
            && !isSuspendedForStealth
            && activeRunGeneration == generation
            && !cancelledRunGenerations.contains(generation)
            && modelProcessAdmission.isCurrent(generation: generation)
    }

    // MARK: - provider process

    struct ProviderProcessResult: Sendable {
        let timedOut: Bool
        let exitStatus: Int32?
        let processFailure: BackgroundAgentProcessFailure?
        let output: Data
        let outputWasTruncated: Bool
    }

    /// Returns a bounded, memory-only stdout capture. If the process was killed
    /// by the timeout watchdog, `timedOut` is true. A child that signals itself
    /// is instead preserved as an exact signal failure; cancellation remains
    /// distinguished by the caller's generation latch.
    static func runProviderProcess(
        executablePath: String,
        arguments: [String],
        standardInput: String,
        workingDirectory: URL,
        timeout timeoutSeconds: TimeInterval?,
        processBox: RunningProcessBox,
        processAdmission: StealthModelProcessAdmission,
        processGeneration: UInt64,
        environment: [String: String]
    ) async -> ProviderProcessResult {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<ProviderProcessResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.environment = environment
                let outputPipe = Pipe()
                let outputCapture = BoundedProcessOutputBox(limit: 64 * 1_024)
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice

                let privateInputFileHandle: FileHandle
                do {
                    guard let stagedInput =
                        try PrivateModelStandardInput.stage(
                            standardInput: standardInput,
                            generation: processGeneration,
                            admission: processAdmission
                        ) else {
                        continuation.resume(
                            returning: ProviderProcessResult(
                                timedOut: false,
                                exitStatus: nil,
                                processFailure: .inputAdmissionRefused,
                                output: Data(),
                                outputWasTruncated: false
                            )
                        )
                        return
                    }
                    privateInputFileHandle = stagedInput
                    process.standardInput = privateInputFileHandle
                } catch {
                    continuation.resume(
                        returning: ProviderProcessResult(
                            timedOut: false,
                            exitStatus: nil,
                            processFailure: .inputStaging,
                            output: Data(),
                            outputWasTruncated: false
                        )
                    )
                    return
                }

                // Keep stdout moving while the child runs. Captured prose never
                // receives a pathname, so SIGKILL cannot strand it in /tmp.
                let outputHandle = outputPipe.fileHandleForReading
                let outputClosed = DispatchSemaphore(value: 0)
                outputHandle.readabilityHandler = { handle in
                    let availableData = handle.availableData
                    if availableData.isEmpty {
                        handle.readabilityHandler = nil
                        outputClosed.signal()
                    } else {
                        outputCapture.append(availableData)
                    }
                }
                let wasLaunched: Bool
                do {
                    wasLaunched =
                        try processAdmission.launchAndPublishIfCurrent(
                            generation: processGeneration,
                            launch: {
                                try process.run()
                                return process.processIdentifier
                            },
                            publish: { _ in
                                processBox.register(
                                    process,
                                    generation: processGeneration
                                )
                            }
                        )
                } catch {
                    try? privateInputFileHandle.close()
                    outputHandle.readabilityHandler = nil
                    continuation.resume(
                            returning: ProviderProcessResult(
                            timedOut: false,
                            exitStatus: nil,
                            processFailure: .launch,
                            output: Data(),
                            outputWasTruncated: false
                        )
                    )
                    return
                }
                guard wasLaunched else {
                    try? privateInputFileHandle.close()
                    outputHandle.readabilityHandler = nil
                    try? outputHandle.close()
                    continuation.resume(
                        returning: ProviderProcessResult(
                            timedOut: false,
                            exitStatus: nil,
                            processFailure: .launchAdmissionRefused,
                            output: Data(),
                            outputWasTruncated: false
                        )
                    )
                    return
                }
                try? privateInputFileHandle.close()
                // SIGTERM at the deadline, then escalate to SIGKILL so a child
                // that ignores TERM can't keep the parent (and this task) alive.
                let watchdogState = ProcessWatchdogState()
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        watchdogState.markFired()
                        RunningProcessBox.terminateProcessTree(process)
                    }
                }
                if let timeoutSeconds {
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + timeoutSeconds, execute: watchdog
                    )
                }
                process.waitUntilExit()
                watchdog.cancel()
                // A misbehaving descendant may inherit stdout after the Claude
                // parent exits. Never turn that descriptor into an unbounded
                // read; allow normal EOF briefly, then close our end.
                _ = outputClosed.wait(timeout: .now() + 1)
                outputHandle.readabilityHandler = nil
                try? outputHandle.close()
                processAdmission.retireProcess(
                    generation: processGeneration
                )
                processBox.clear(generation: processGeneration)
                let captured = outputCapture.snapshot()
                let timedOut = watchdogState.fired
                let processFailure =
                    BackgroundAgentDeliveryPolicy.processFailure(
                        watchdogFired: timedOut,
                        terminationReason: process.terminationReason,
                        exitStatus: process.terminationStatus
                    )
                continuation.resume(
                    returning: ProviderProcessResult(
                        timedOut: timedOut,
                        exitStatus:
                            process.terminationReason == .exit
                                ? process.terminationStatus
                                : nil,
                        processFailure: processFailure,
                        output: captured.data,
                        outputWasTruncated: captured.truncated
                    )
                )
            }
        }
    }

    // MARK: - Walkthrough capture

    struct WalkthroughPage: Sendable {
        let name: String
        let url: String
        let screenshotPath: String
    }

    /// Walkthrough discovery used to give a model full shell/browser access.
    /// It is disabled until CompanionManager owns a deterministic capture plan.
    func captureWalkthrough(site: String) async -> [WalkthroughPage] {
        Self.scheduleLog(
            "WALKTHROUGH refused model capture siteBytes=\(site.utf8.count) "
                + "deterministicAppOwnedCaptureRequired=true"
        )
        return []
    }

    private nonisolated static func scheduleLog(_ message: String) {
        ClaudePrivateIOWorker.schedule {
            appendLog(message)
        }
    }

    private nonisolated static func scheduleLog(
        _ message: String,
        admission: StealthModelProcessAdmission,
        generation: UInt64
    ) {
        ClaudePrivateIOWorker.schedule {
            guard admission.isCurrent(
                generation: generation
            ) else {
                return
            }
            appendLog(message)
        }
    }

    private nonisolated static func appendLog(_ message: String) {
        guard let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeMessage = message
            .components(separatedBy: .newlines)
            .joined(separator: "\\n")
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
        let line =
            "\(ISO8601DateFormatter().string(from: Date())) \(safeMessage)\n"
        let url = dir.appendingPathComponent("agent.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }
}
#endif // circuit-convert
