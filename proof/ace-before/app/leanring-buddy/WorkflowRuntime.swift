#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  WorkflowRuntime.swift
//  Ace
//
//  THE BUILD LANE (green) — founder ruling 2026-08-01.
//
//  What it is. Every existing effect path in Ace is one wrapper, one exact
//  readback, one `confirm`, one spawn, one verified result. That is the right
//  shape for "send this email" and it cannot express "build me a dashboard,"
//  which is hundreds of effects. This lane moves the gate from PER EFFECT to
//  PER JOB: one whole-job readback naming the goal, the exact folder, every
//  personal system it will read and every outside host it will reach, one
//  `confirm`, and then a bounded run with full machine authority — and a kill
//  word that works the entire time.
//
//  🚨 AUTHORITY. Founder ruling 2026-08-01 chose full machine authority for
//  this lane over a workspace sandbox, with the risk stated. So unlike
//  the selected provider's full-access Red profile —
//  the build lane runs with real tools on any Mac. Three things are load-bearing
//  because of that, and none of them are decoration:
//
//    1. NOTHING RUNS UNARMED. Authority exists only between a fresh `confirm`
//       and the job ending. There is no schedule, no standing job, no resume
//       after relaunch, and no path that arms a job without a live human
//       utterance inside the 30-second window. `StandingTaskRuntime` cannot
//       reach this lane; it is still zero-tool read-only reasoning.
//    2. THE KILL IS REAL. "stop" freezes and kills the whole process tree, and
//       Stealth does the same synchronously before it returns. A grant that
//       could outlive the owner's ability to revoke it would not be a grant.
//    3. THE LEDGER IS COMPLETE. Every armed job, every step, every kill and
//       every outcome appends to `workflow-ledger.log` with the full approved
//       readback. Full authority that leaves no trace is the actually dangerous
//       version of this feature; this one is auditable after the fact.
//
//  Deliberately NOT here: any way to arm a job without a human, any way to
//  widen `WorkflowSystem`, and any way for the model to see a wrapper path, a
//  one-use approval, or a credential. Those are the same rules the rest of the
//  app already keeps.
//

import Foundation
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

// MARK: - Bounded output

/// Job stdout is read continuously so progress markers arrive live and a long
/// build cannot fill memory. Its own copy rather than BackgroundAgent's private
/// one; the build lane must not reach into another lane's internals.
nonisolated private final class WorkflowOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) { self.limit = max(0, limit) }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if remaining > 0 { data.append(newData.prefix(remaining)) }
        if newData.count > remaining { truncated = true }
    }

    func snapshot() -> (text: String, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: data, as: UTF8.self), truncated)
    }
}

// MARK: - Stream decoding

/// Pulls the assistant's plain text out of the build lane's `stream-json`
/// output.
///
/// Why this exists: the build lane originally ran with `--output-format text`,
/// which emits ONE final block when the whole job is over. The per-step
/// narration contract ("print ACE-STEP n/N …") was therefore dead on arrival —
/// a real 109-second build produced zero markers, because there was no
/// incremental assistant text to carry them. `stream-json` emits one JSON line
/// per assistant turn, so markers arrive while the build is still running,
/// which is the whole point of narrating.
///
/// It buffers partial lines: a chunk boundary can land mid-JSON, and half an
/// object must never be parsed or spoken.
nonisolated final class WorkflowStreamTextExtractor: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLine = ""
    private var accumulatedText = ""

    /// Feed raw stdout. Returns only the assistant text newly revealed by this
    /// chunk, so a caller can narrate deltas without re-reading the whole job.
    func feed(_ rawChunk: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        pendingLine += rawChunk
        var revealed = ""
        while let newlineIndex = pendingLine.firstIndex(of: "\n") {
            let line = String(pendingLine[pendingLine.startIndex..<newlineIndex])
            pendingLine = String(pendingLine[pendingLine.index(after: newlineIndex)...])
            let text = Self.assistantText(inJSONLine: line)
            guard !text.isEmpty else { continue }
            revealed += text.hasSuffix("\n") ? text : text + "\n"
        }
        accumulatedText += revealed
        return revealed
    }

    /// Everything the assistant said across the whole job, newline-joined.
    var fullText: String {
        lock.lock()
        defer { lock.unlock() }
        return accumulatedText
    }

    /// Extract the text blocks of one `{"type":"assistant"}` event. Any other
    /// event shape — system init, rate-limit notices, tool results, the final
    /// result envelope — yields nothing, so machine chatter can never be spoken.
    static func assistantText(inJSONLine line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              (root["type"] as? String) == "assistant",
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? [Any]
        else { return "" }
        var pieces: [String] = []
        for block in content {
            guard let object = block as? [String: Any],
                  (object["type"] as? String) == "text",
                  let text = object["text"] as? String,
                  !text.isEmpty
            else { continue }
            pieces.append(text)
        }
        return pieces.joined(separator: "\n")
    }
}

// MARK: - Job state

enum WorkflowJobState: Equatable {
    case idle
    /// The immutable plan exists while its exact readback is in flight, but the
    /// confirmation clock is nil until that speech item reaches verified DONE.
    /// No authority exists in either phase.
    case awaitingConfirmation(
        WorkflowPlan,
        windowOpenedAt: Date?
    )
    /// Armed and running. Authority is live for exactly this window.
    case building(WorkflowPlan, startedAt: Date)
}

enum WorkflowJobOutcome: Equatable {
    case delivered(String)
    case finishedWithoutDeliverable(String)
    case failed(String)
    case killed(String)

    var spokenResult: String {
        switch self {
        case let .delivered(message),
             let .finishedWithoutDeliverable(message),
             let .failed(message),
             let .killed(message):
            return message
        }
    }
}

// MARK: - Hosted buyer artifact

struct HostedWorkflowArtifact: Equatable, Sendable {
    let content: String
    let closing: String
}

/// A buyer Mac has the hosted brain but no local model executable. The hosted
/// lane may supply bytes for the ONE deliverable named in the approved plan;
/// it never chooses a path or receives local execution authority.
enum HostedWorkflowArtifactPolicy {
    private static let maximumEnvelopeBytes = 64 * 1_024
    private static let maximumContentBytes = 17_000

    static func decode(_ raw: String) -> HostedWorkflowArtifact? {
        guard let data = raw.data(using: .utf8),
              data.count <= maximumEnvelopeBytes,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == ["content", "closing"],
              let content = object["content"] as? String,
              let closingValue = object["closing"] as? String,
              !content.isEmpty,
              content.data(using: .utf8)?.count ?? 0
                <= maximumContentBytes else {
            return nil
        }
        let closing = WorkflowPlanner.collapseWhitespace(closingValue)
        guard !closing.isEmpty, closing.count <= 160 else { return nil }
        return HostedWorkflowArtifact(
            content: content,
            closing: closing
        )
    }

    static func write(
        _ artifact: HostedWorkflowArtifact,
        deliverable: String,
        workspaceURL: URL
    ) throws {
        guard workspaceURL.path.hasPrefix("/"),
              WorkflowPlanner.sanitizedDeliverable(deliverable)
                == deliverable else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let resolvedWorkspace = workspaceURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let destination = workspaceURL
            .appendingPathComponent(deliverable)
            .standardizedFileURL
        guard destination.path.hasPrefix(resolvedWorkspace.path + "/")
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let resolvedParent = parent
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedParent.path == resolvedWorkspace.path
                || resolvedParent.path.hasPrefix(
                    resolvedWorkspace.path + "/"
                ) else {
            throw CocoaError(.fileWriteNoPermission)
        }

        if fileManager.fileExists(atPath: destination.path) {
            let attributes = try fileManager.attributesOfItem(
                atPath: destination.path
            )
            guard (attributes[.type] as? FileAttributeType)
                    == .typeRegular else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }

        let bytes = Data(artifact.content.utf8)
        try bytes.write(to: destination, options: .atomic)
        let committed = try Data(contentsOf: destination)
        guard committed == bytes else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

// MARK: - Runtime

@MainActor
final class WorkflowRuntime: ObservableObject {

    /// Live lane state for the gem and the per-lane busy gate.
    @Published private(set) var isBuilding = false
    /// Planning also reserves Silver. Without this edge a second background
    /// check could claim the slot while a workflow planner was awaiting its
    /// model response, then both would start under one Silver identity.
    @Published private(set) var isPlanning = false
    /// Step position for the overlay. State, never private content.
    @Published private(set) var stepPosition: String = ""
    /// Latest immutable START/STEP/DONE/FAILED receipt for the panel. A DONE
    /// receipt is shown only after its current on-disk SHA-256 verifies.
    @Published private(set) var lastArtifactReceipt: ArtifactReceipt?

    private(set) var state: WorkflowJobState = .idle

    /// True while a read-back job is held awaiting `confirm`. No authority
    /// exists in this state — it only tells the router that the next `confirm`
    /// belongs to a build rather than to some other pending action.
    var hasPendingPlan: Bool {
        if case .awaitingConfirmation = state { return true }
        return false
    }

    /// Hard ceiling on one job. A build that has not finished in this window is
    /// killed and reported, not left running with authority. Owned by
    /// `WorkflowBoundary` so every cap lives in one place; raised to 1000s on
    /// founder direction 2026-08-01.
    static var jobTimeout: TimeInterval { WorkflowBoundary.jobTimeout }
    /// Planning is a small zero-tool call and must not hang the utterance.
    static let planningTimeout: TimeInterval = 60

    private let runningProcessBox = RunningProcessBox()
    private let processAdmission: StealthModelProcessAdmission
    private let artifactReceiptStore: ArtifactReceiptStore
    /// Exact destination for this runtime's audit trail. Production defaults
    /// to Ace's Application Support ledger; tests must inject a temporary URL
    /// so fixture activity can never contaminate the owner's real state.
    private let ledgerFileURL: URL?
    private var isSuspendedForStealth = false
    private var activeJobTask: Task<Void, Never>?
    private var activeArtifactOperationID: UUID?
    private var terminalAnnouncementSuppressedOperationIDs: Set<UUID> = []

    var activeOperationIdentifier: UUID? {
        activeArtifactOperationID
    }

    private func announceTerminal(
        _ message: String,
        operationID: UUID
    ) {
        if terminalAnnouncementSuppressedOperationIDs.remove(
            operationID
        ) != nil {
            return
        }
        announce(message)
    }

    /// Spoken announcements from the lane. CompanionManager routes these into
    /// the one mouth as `.background` so a build narrates without ever cutting
    /// off a foreground answer.
    private let announce: @MainActor (String) -> Void

    init(
        entryLatch: StealthEntryLatch = .shared,
        artifactReceiptStore: ArtifactReceiptStore = .shared,
        ledgerURL: URL? = WorkflowRuntime.ledgerURL(),
        announce: @escaping @MainActor (String) -> Void
    ) {
        self.announce = announce
        self.artifactReceiptStore = artifactReceiptStore
        ledgerFileURL = ledgerURL
        processAdmission = StealthModelProcessAdmission(entryLatch: entryLatch)
        lastArtifactReceipt = try? artifactReceiptStore
            .latestVerifiedDone()
    }

    // MARK: - Planning

    /// Decompose a build request. Runs on the isolated zero-tool planner: it
    /// receives the request and the contract, and no tools, paths, approvals,
    /// credentials, history, or screenshots. Its output is untrusted text
    /// decoded fail-closed by `WorkflowPlanner`.
    func planJob(from request: String) async -> WorkflowPlanDecoding {
        guard !isSuspendedForStealth else {
            return .clarification("")
        }
        guard !isPlanning else {
            return .clarification(
                "i'm already planning another build, so i didn't start this one."
            )
        }
        guard case .idle = state else {
            return .clarification(
                "i'm already in the middle of a build, so i didn't start "
                    + "this one. say stop to kill the running build first.")
        }
        isPlanning = true
        defer { isPlanning = false }
        let prompt = """
            \(WorkflowPlanner.plannerContract)

            The owner's request:
            \(request)
            """

        if AceBrainRoute.current == .founderHosted {
            do {
                let hostedPlan = try await HostedBrainClient.complete(
                    kind: .workflowPlanner,
                    prompt: prompt
                )
                return WorkflowPlanner.decode(
                    hostedPlan,
                    ownerRequest: request
                )
            } catch {
                return .clarification(
                    "i couldn't reach my CLI brain, so i didn't plan anything.")
            }
        }

        let selectedCLI = BrainBackend.selectedCLI
        if selectedCLI == .qwen {
            do {
                let local = try await AceLocalBrain.envelopeText(
                    images: [],
                    systemPrompt: WorkflowPlanner.plannerContract,
                    userPrompt: "The owner's request:\n\(request)",
                    responseFormat: .strictJSON,
                    timeout: Self.planningTimeout
                )
                return WorkflowPlanner.decode(
                    local.text,
                    ownerRequest: request
                )
            } catch {
                return .clarification(
                    "i couldn't reach the local Qwen brain, so i didn't plan anything."
                )
            }
        }
        guard let executablePath =
            BrainBackend.resolveExecutable(for: selectedCLI) else {
            return .clarification(
                "i couldn't reach the brain, so i didn't plan anything.")
        }

        let arguments: [String]
        do {
            arguments = try await Self.resolvedPlannerArguments(
                for: selectedCLI,
                executablePath: executablePath
            )
        } catch {
            return .clarification(
                "i couldn't verify this ChatGPT account's Codex capability, so i didn't plan anything."
            )
        }

        let result = await Self.runProcess(
            executablePath: executablePath,
            arguments: arguments,
            standardInput: prompt,
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: Self.planningTimeout,
            outputLimit: 32 * 1_024,
            processBox: runningProcessBox,
            onOutputChunk: nil
        )
        guard !result.wasKilled else {
            return .clarification("")
        }
        return WorkflowPlanner.decode(
            result.text,
            ownerRequest: request
        )
    }

    /// Read the job back and hold it for exactly one confirmation window. No
    /// authority exists in this state — the workspace is not created, no
    /// process runs, and an expired or replaced plan simply dies.
    func armPendingJob(
        _ plan: WorkflowPlan,
        now _: Date = Date()
    ) -> String {
        // Boundaries are judged BEFORE the readback, not after the confirm: a
        // job that can never legally run must not be read back as if the
        // owner's word were the only thing standing between it and the disk.
        if let refusal = WorkflowBoundary.refusal(for: plan) {
            state = .idle
            appendLedger(
                "REFUSED boundary workspace=\(plan.workspaceName) "
                    + "reason=\(refusal)")
            return refusal.spokenRefusal
        }
        state = .awaitingConfirmation(
            plan,
            windowOpenedAt: nil
        )
        appendLedger(
            "ARMED readback-pending workspace=\(plan.workspaceName) "
                + "systems=\(plan.systems.count) effects=\(plan.effects.count) "
                + "external=\(plan.externalSources.count) "
                + "steps=\(plan.steps.count)\n\(plan.writtenReadback)")
        return plan.spokenReadback
    }

    /// Opens the confirmation window only for the SAME immutable plan whose
    /// complete readback just received Nora's verified speech-DONE receipt.
    /// A stale or duplicate completion cannot open or restart another window.
    @discardableResult
    func markPendingPlanReadbackCompleted(
        _ plan: WorkflowPlan,
        now: Date = Date()
    ) -> Bool {
        guard case let .awaitingConfirmation(
            pendingPlan,
            windowOpenedAt
        ) = state,
              pendingPlan == plan,
              windowOpenedAt == nil else {
            return false
        }
        state = .awaitingConfirmation(
            pendingPlan,
            windowOpenedAt: now
        )
        appendLedger(
            "READBACK DONE confirmation-open workspace="
                + pendingPlan.workspaceName
        )
        return true
    }

    func cancelPendingJob(
        ifMatching expectedPlan: WorkflowPlan? = nil
    ) -> Bool {
        guard case let .awaitingConfirmation(plan, _) = state,
              expectedPlan == nil || expectedPlan == plan else {
            return false
        }
        state = .idle
        appendLedger("CANCELLED before-authority workspace=\(plan.workspaceName)")
        return true
    }

    /// True when a held plan is still inside its window. A stale plan is
    /// consumed rather than run — a `confirm` that arrives late must never
    /// inherit authority for a job the owner has moved on from.
    func pendingPlanIsCurrent(now: Date = Date()) -> Bool {
        guard case let .awaitingConfirmation(_, openedAt) = state,
              let openedAt else {
            return false
        }
        return SilverConfirmationWindow.isCurrent(
            openedAt: openedAt,
            now: now,
            lifetime: WorkflowRequestPolicy.confirmationLifetime
        )
    }

    // MARK: - Execution

    /// Starts one validated app-owned plan in the same turn that selected it.
    /// Boundary validation, one-shot consumption, Stealth checks, operation
    /// identity, and artifact receipts remain identical to the held-plan path;
    /// there is no owner-facing Ace confirmation or readback pause.
    func startPlannedJobImmediately(
        _ plan: WorkflowPlan,
        now: Date = Date(),
        suppressTerminalAnnouncement: Bool = false
    ) -> String {
        let refusalOrReadback = armPendingJob(plan, now: now)
        guard hasPendingPlan else { return refusalOrReadback }
        guard markPendingPlanReadbackCompleted(plan, now: now) else {
            _ = cancelPendingJob(ifMatching: plan)
            return "the validated workflow could not acquire its execution slot. nothing ran."
        }
        appendLedger(
            "DIRECT START no-ace-confirmation workspace="
                + plan.workspaceName
        )
        return confirmPendingJob(
            now: now,
            suppressTerminalAnnouncement: suppressTerminalAnnouncement
        )
    }

    /// Consume the held plan and start the build. This is the one and only
    /// place authority is created, and it revalidates the UNCHANGED plan and
    /// its freshness immediately before it does.
    func confirmPendingJob(
        now: Date = Date(),
        suppressTerminalAnnouncement: Bool = false
    ) -> String {
        guard case let .awaitingConfirmation(plan, openedAt) = state else {
            return "i don't have a build waiting."
        }
        guard let openedAt else {
            return "the exact plan readback has not finished. nothing ran."
        }
        // Consume first: no path may leave an armed plan behind.
        state = .idle
        let age = now.timeIntervalSince(openedAt)
        guard SilverConfirmationWindow.isCurrent(
            openedAt: openedAt,
            now: now,
            lifetime: WorkflowRequestPolicy.confirmationLifetime
        ) else {
            appendLedger("EXPIRED workspace=\(plan.workspaceName) ageSeconds=\(Int(age))")
            return "that build plan sat past its confirmation window, so i "
                + "dropped it. say go and i'll re-plan it from scratch."
        }
        guard !isSuspendedForStealth else {
            appendLedger("BLOCKED stealth workspace=\(plan.workspaceName)")
            return ""
        }
        guard StealthEntryLatch.shared.performUnlessRaised({ true }) == true else {
            appendLedger("BLOCKED stealth-latch workspace=\(plan.workspaceName)")
            return ""
        }
        let workspaceURL = plan.workspaceURL()
        guard Self.prepareWorkspace(at: workspaceURL) else {
            appendLedger("FAILED workspace-unavailable path=\(workspaceURL.path)")
            return "i couldn't create the project folder, so i didn't build anything."
        }
        let operationID = UUID()
        do {
            let startReceipt = try artifactReceiptStore.recordStarted(
                operationID: operationID,
                artifactPath: plan.deliverableURL().path,
                at: now
            )
            activeArtifactOperationID = operationID
            lastArtifactReceipt = startReceipt
            if suppressTerminalAnnouncement {
                terminalAnnouncementSuppressedOperationIDs.insert(
                    operationID
                )
            }
        } catch {
            appendLedger(
                "FAILED artifact-receipt-start workspace=\(plan.workspaceName)"
            )
            return "i couldn't create the build receipt, so i did not start the full-access job."
        }
        if AceBrainRoute.current == .founderHosted {
            state = .building(plan, startedAt: now)
            isBuilding = true
            stepPosition = "1/\(plan.steps.count)"
            appendLedger(
                "STARTED authority=approved-deliverable workspace="
                    + "\(workspaceURL.path)\n\(plan.writtenReadback)"
            )
            activeJobTask = Task { [weak self] in
                await self?.runHostedJob(
                    plan: plan,
                    workspaceURL: workspaceURL,
                    operationID: operationID
                )
            }
            return "starting. i'll tell you when it's done. say stop to kill it."
        }
        let selectedCLI = BrainBackend.selectedCLI
        guard let executablePath =
            BrainBackend.resolveExecutable(for: selectedCLI) else {
            appendLedger("FAILED brain-unresolved workspace=\(plan.workspaceName)")
            recordArtifactFailure(
                for: plan,
                operationID: operationID,
                reason: "The bundled customer CLI was unavailable."
            )
            return "i couldn't reach the brain, so i didn't build anything."
        }

        state = .building(plan, startedAt: now)
        isBuilding = true
        stepPosition = "1/\(plan.steps.count)"
        appendLedger(
            "STARTED authority=full workspace=\(workspaceURL.path)\n"
                + plan.writtenReadback)

        activeJobTask = Task { [weak self] in
            await self?.runJob(
                plan: plan,
                workspaceURL: workspaceURL,
                executablePath: executablePath,
                brainCLI: selectedCLI,
                operationID: operationID
            )
        }

        return "starting. i'll tell you when it's done. say stop to kill it."
    }

    private func runHostedJob(
        plan: WorkflowPlan,
        workspaceURL: URL,
        operationID: UUID
    ) async {
        let protectedStamp = WorkflowBoundary.ProtectedPathStamp.take()
        do {
            let rawArtifact = try await HostedBrainClient.complete(
                kind: .workflowPlanner,
                prompt: Self.hostedArtifactPrompt(for: plan)
            )
            try Task.checkCancellation()
            guard case .building = state,
                  let artifact =
                    HostedWorkflowArtifactPolicy.decode(rawArtifact) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let committed = try StealthEntryLatch.shared
                .performUnlessRaised {
                    try HostedWorkflowArtifactPolicy.write(
                        artifact,
                        deliverable: plan.deliverable,
                        workspaceURL: workspaceURL
                    )
                    guard Self.installDashboardLauncher(
                        for: plan,
                        workspaceURL: workspaceURL
                    ) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    return true
                }
            guard committed == true else { throw CancellationError() }
            try Task.checkCancellation()
            guard case let .building(_, hostedJobStartedAt) = state else {
                return
            }
            state = .idle
            isBuilding = false
            stepPosition = ""
            activeJobTask = nil

            let violations = WorkflowBoundary.violations(
                for: plan,
                workspaceURL: workspaceURL,
                stamp: protectedStamp
            )
            guard violations.isEmpty else {
                for violation in violations {
                    appendLedger(
                        "VIOLATION workspace=\(plan.workspaceName) "
                            + "boundary=\(violation.boundary) "
                            + "detail=\(violation.detail)"
                    )
                }
                appendLedger(
                    "FAILED boundary-violation workspace="
                        + plan.workspaceName
                )
                recordArtifactFailure(
                    for: plan,
                    operationID: operationID,
                    reason:
                        "The build crossed an approved boundary and is not verified complete."
                )
                announceTerminal(
                    "heads up — that build crossed a boundary i set, so i'm "
                        + "not calling it complete.",
                    operationID: operationID
                )
                return
            }

            // The hosted lane wrote the deliverable itself moments ago, so a
            // synthetic clean process result is honest here; freshness still
            // runs against this job's start.
            let outcome = Self.outcome(
                for: plan,
                processResult: ProcessResult(
                    text: "",
                    truncated: false,
                    wasKilled: false,
                    timedOut: false,
                    launched: true,
                    exitStatus: 0
                ),
                assistantText: "ACE-DONE \(artifact.closing)",
                workspaceURL: workspaceURL,
                jobStartedAt: hostedJobStartedAt
            )
            guard recordArtifactDone(
                for: plan,
                operationID: operationID
            ) else {
                announceTerminal(
                    "the file exists, but i could not verify its artifact receipt. the build is not complete.",
                    operationID: operationID
                )
                return
            }
            appendLedger(
                "DELIVERED workspace=\(plan.workspaceName) "
                    + "file=\(plan.deliverableURL().path)"
            )
            announceTerminal(
                outcome.spokenResult,
                operationID: operationID
            )
        } catch is CancellationError {
            return
        } catch {
            guard case .building = state else { return }
            state = .idle
            isBuilding = false
            stepPosition = ""
            activeJobTask = nil
            appendLedger(
                "FAILED hosted-deliverable workspace=\(plan.workspaceName)"
            )
            recordArtifactFailure(
                for: plan,
                operationID: operationID,
                reason: "The hosted build did not produce a verified deliverable."
            )
            announceTerminal(
                "i couldn't finish that build, so i'm not calling it done — "
                    + "no verified deliverable came out. say go and i'll run it again.",
                operationID: operationID
            )
        }
    }

    private func runJob(
        plan: WorkflowPlan,
        workspaceURL: URL,
        executablePath: String,
        brainCLI: BrainCLI,
        operationID: UUID
    ) async {
        let stepCount = plan.steps.count
        let buildArguments: [String]
        do {
            buildArguments = try await Self.resolvedBuildLaneArguments(
                for: brainCLI,
                executablePath: executablePath
            )
        } catch {
            guard case .building = state else { return }
            state = .idle
            isBuilding = false
            stepPosition = ""
            activeJobTask = nil
            appendLedger(
                "FAILED codex-capability workspace=\(plan.workspaceName)"
            )
            recordArtifactFailure(
                for: plan,
                operationID: operationID,
                reason: error.localizedDescription
            )
            announceTerminal(
                "i couldn't verify this ChatGPT account's Codex capability, so the build did not start.",
                operationID: operationID
            )
            return
        }
        guard case .building = state else { return }
        // Stamp every protected path immediately before authority exists. The
        // comparison after the job is a tripwire, not containment — see the
        // header of WorkflowBoundary for exactly what it can and cannot catch.
        let protectedStamp = WorkflowBoundary.ProtectedPathStamp.take()
        // The child speaks stream-json; only the assistant's own text ever
        // reaches narration or the outcome scan. System, rate-limit, and tool
        // events are machine chatter and are dropped by the extractor.
        let textExtractor = WorkflowStreamTextExtractor()
        let outputHandler: (@Sendable (String) -> Void)?
        if brainCLI == .claude {
            outputHandler = { [weak self] rawChunk in
                let revealed = textExtractor.feed(rawChunk)
                guard !revealed.isEmpty else { return }
                Task { @MainActor in
                    self?.consumeProgress(revealed, stepCount: stepCount)
                }
            }
        } else {
            outputHandler = nil
        }
        let result: ProcessResult
        let assistantText: String
        if brainCLI == .qwen {
            do {
                assistantText = try await AceLocalBrain.agentText(
                    systemPrompt:
                        "You are Ace's local workflow builder. Use the shell tool until the exact deliverable is created and verified. Return only a truthful completion summary.",
                    userPrompt: Self.buildPrompt(
                        for: plan,
                        workspaceURL: workspaceURL
                    ),
                    workingDirectory: workspaceURL,
                    timeout: Self.jobTimeout
                )
                result = ProcessResult(
                    text: assistantText,
                    truncated: false,
                    wasKilled: false,
                    timedOut: false,
                    launched: true,
                    exitStatus: 0
                )
            } catch is CancellationError {
                assistantText = ""
                result = ProcessResult(
                    text: "",
                    truncated: false,
                    wasKilled: true,
                    timedOut: false,
                    launched: true,
                    exitStatus: -1
                )
            } catch {
                assistantText = error.localizedDescription
                result = ProcessResult(
                    text: assistantText,
                    truncated: false,
                    wasKilled: false,
                    timedOut: false,
                    launched: true,
                    exitStatus: 1
                )
            }
        } else {
            result = await Self.runProcess(
                executablePath: executablePath,
                arguments: buildArguments,
                standardInput: Self.buildPrompt(
                    for: plan,
                    workspaceURL: workspaceURL
                ),
                workingDirectory: workspaceURL,
                timeout: Self.jobTimeout,
                outputLimit: 1_024 * 1_024,
                processBox: runningProcessBox,
                environment: Self.buildLaneEnvironment(
                    claudeExecutablePath: executablePath),
                onOutputChunk: outputHandler
            )
            assistantText = brainCLI == .claude
                ? textExtractor.fullText : result.text
        }
        if brainCLI == .codex || brainCLI == .qwen {
            consumeProgress(assistantText, stepCount: stepCount)
        }

        guard case let .building(_, jobStartedAt) = state else { return }
        state = .idle
        isBuilding = false
        stepPosition = ""

        guard Self.installDashboardLauncher(
            for: plan,
            workspaceURL: workspaceURL
        ) else {
            appendLedger(
                "FAILED dashboard-launcher workspace=\(plan.workspaceName)"
            )
            recordArtifactFailure(
                for: plan,
                operationID: operationID,
                reason: "Ace could not install the verified dashboard launcher."
            )
            announceTerminal(
                "the project file exists, but Ace couldn't install its clean-Mac "
                    + "dashboard launcher, so i'm not calling it done.",
                operationID: operationID
            )
            return
        }

        // Audit before announcing. A job that delivered its file AND crossed a
        // boundary is not a success, and the owner hears about the boundary
        // first.
        let violations = WorkflowBoundary.violations(
            for: plan, workspaceURL: workspaceURL, stamp: protectedStamp)
        if !violations.isEmpty {
            for violation in violations {
                appendLedger(
                    "VIOLATION workspace=\(plan.workspaceName) "
                        + "boundary=\(violation.boundary) detail=\(violation.detail)")
            }
            announceTerminal(
                "heads up — that build crossed a boundary i set: "
                    + violations.map(\.spokenWarning).joined(separator: "; ")
                    + ". the files remain in Ace Projects, but i'm not calling "
                    + "the job complete.",
                operationID: operationID)
            appendLedger(
                "FAILED boundary-violation workspace=\(plan.workspaceName)")
            recordArtifactFailure(
                for: plan,
                operationID: operationID,
                reason:
                    "The build crossed an approved boundary and is not verified complete."
            )
            return
        }

        let outcome = Self.outcome(
            for: plan,
            processResult: result,
            assistantText: assistantText,
            workspaceURL: workspaceURL,
            jobStartedAt: jobStartedAt
        )
        switch outcome {
        case let .delivered(message):
            guard recordArtifactDone(
                for: plan,
                operationID: operationID
            ) else {
                announceTerminal(
                    "the file exists, but i could not verify its artifact receipt. the build is not complete.",
                    operationID: operationID
                )
                return
            }
            appendLedger(
                "DELIVERED workspace=\(plan.workspaceName) "
                    + "file=\(plan.deliverableURL().path)")
            announceTerminal(message, operationID: operationID)
        case let .finishedWithoutDeliverable(message):
            recordArtifactFailure(
                for: plan,
                operationID: operationID,
                reason: "The expected deliverable was missing."
            )
            appendLedger(
                "INCOMPLETE workspace=\(plan.workspaceName) "
                    + "expected=\(plan.deliverableURL().path) missing")
            announceTerminal(message, operationID: operationID)
        case let .failed(message):
            recordArtifactFailure(
                for: plan,
                operationID: operationID,
                reason: message
            )
            appendLedger("FAILED workspace=\(plan.workspaceName)")
            announceTerminal(message, operationID: operationID)
        case let .killed(message):
            recordArtifactFailure(
                for: plan,
                operationID: operationID,
                reason: "The build was stopped before verification."
            )
            appendLedger("KILLED workspace=\(plan.workspaceName)")
            if !message.isEmpty {
                announceTerminal(message, operationID: operationID)
            }
        }
    }

    /// Parse `ACE-STEP n/N title` markers out of the live stream and narrate
    /// them. Only the marker line is ever spoken or logged — the build's own
    /// output can contain the owner's data and never becomes speech or a
    /// receipt.
    private func consumeProgress(_ chunk: String, stepCount: Int) {
        guard isBuilding else { return }
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("ACE-STEP ") else { continue }
            let remainder = text.dropFirst("ACE-STEP ".count)
            let parts = remainder.split(separator: " ", maxSplits: 1)
            guard let position = parts.first else { continue }
            stepPosition = String(position)
            guard parts.count == 2 else { continue }
            let title = WorkflowPlanner.collapseWhitespace(String(parts[1]))
            guard !title.isEmpty, title.count <= WorkflowPlan.maximumStepTitleLength
            else { continue }
            appendLedger("STEP \(position) \(title)")
            if let operationID = activeArtifactOperationID {
                let counts = position.split(separator: "/")
                if counts.count == 2,
                   let current = Int(counts[0]),
                   let total = Int(counts[1]) {
                    do {
                        let receipt = try artifactReceiptStore.recordStep(
                            operationID: operationID,
                            artifactPath: currentArtifactPath,
                            current: current,
                            total: total,
                            title: title
                        )
                        lastArtifactReceipt = receipt
                    } catch {
                        appendLedger(
                            "FAILED artifact-receipt-step position=\(position)"
                        )
                        failActiveJobForReceiptError()
                        return
                    }
                }
            }
            announce(title.lowercased())
        }
    }

    private var currentArtifactPath: String {
        switch state {
        case .idle:
            return ""
        case let .awaitingConfirmation(plan, _),
             let .building(plan, _):
            return plan.deliverableURL().path
        }
    }

    @discardableResult
    private func recordArtifactDone(
        for plan: WorkflowPlan,
        operationID: UUID
    ) -> Bool {
        do {
            let receipt = try artifactReceiptStore.recordDone(
                operationID: operationID,
                artifactURL: plan.deliverableURL()
            )
            lastArtifactReceipt = receipt
            activeArtifactOperationID = nil
            appendLedger(
                "ARTIFACT DONE operation=\(operationID.uuidString.lowercased()) "
                    + "path=\(receipt.artifactPath) sha256=\(receipt.sha256 ?? "missing")"
            )
            return true
        } catch {
            appendLedger(
                "FAILED artifact-receipt-done workspace=\(plan.workspaceName)"
            )
            recordArtifactFailure(
                for: plan,
                operationID: operationID,
                reason:
                    "The deliverable could not be hash-verified, so the build is not verified complete."
            )
            return false
        }
    }

    private func recordArtifactFailure(
        for plan: WorkflowPlan,
        operationID: UUID,
        reason: String
    ) {
        do {
            lastArtifactReceipt = try artifactReceiptStore.recordFailed(
                operationID: operationID,
                artifactPath: plan.deliverableURL().path,
                reason: reason
            )
        } catch {
            appendLedger(
                "FAILED artifact-receipt-terminal workspace=\(plan.workspaceName)"
            )
        }
        if activeArtifactOperationID == operationID {
            activeArtifactOperationID = nil
        }
    }

    private func failActiveJobForReceiptError() {
        guard case let .building(plan, _) = state,
              let operationID = activeArtifactOperationID else {
            return
        }
        state = .idle
        isBuilding = false
        stepPosition = ""
        activeJobTask?.cancel()
        activeJobTask = nil
        processAdmission.cancelAll()
        runningProcessBox.terminate()
        recordArtifactFailure(
            for: plan,
            operationID: operationID,
            reason:
                "Artifact progress could not be recorded, so Ace stopped the full-access job."
        )
        announceTerminal(
            "i stopped that build because its artifact receipt could not be recorded. the task is not verified complete.",
            operationID: operationID
        )
    }

    // MARK: - Kill paths

    /// The owner's kill word. Freezes and kills the whole process tree — a
    /// build that ignored "stop" would make the grant unrevocable.
    @discardableResult
    func abortActiveJob() -> Bool {
        CodexModelCapabilityPreflight.shared.invalidate(
            reason: .cancellation
        )
        switch state {
        case .idle:
            return false
        case let .awaitingConfirmation(plan, _):
            state = .idle
            appendLedger("CANCELLED before-authority workspace=\(plan.workspaceName)")
            return true
        case let .building(plan, _):
            let operationID = activeArtifactOperationID
            state = .idle
            isBuilding = false
            stepPosition = ""
            activeJobTask?.cancel()
            activeJobTask = nil
            processAdmission.cancelAll()
            runningProcessBox.terminate()
            if let operationID {
                recordArtifactFailure(
                    for: plan,
                    operationID: operationID,
                    reason: "The buyer stopped the build before verification."
                )
            }
            appendLedger("KILLED by-owner workspace=\(plan.workspaceName)")
            return true
        }
    }

    /// Stealth's synchronous boundary. Authority ends before Stealth reports
    /// active — a running build must not survive into a mode whose entire
    /// purpose is that Ace is doing nothing observable. Never vetoes Stealth.
    func suspendSynchronouslyForStealth() {
        CodexModelCapabilityPreflight.shared.invalidate(
            reason: .privateMode
        )
        isSuspendedForStealth = true
        let hadJob: Bool
        let activePlan: WorkflowPlan?
        switch state {
        case .idle:
            hadJob = false
            activePlan = nil
        case .awaitingConfirmation:
            hadJob = true
            activePlan = nil
        case let .building(plan, _):
            hadJob = true
            activePlan = plan
        }
        state = .idle
        isBuilding = false
        stepPosition = ""
        activeJobTask?.cancel()
        activeJobTask = nil
        processAdmission.cancelAll()
        runningProcessBox.terminate()
        if let activePlan,
           let operationID = activeArtifactOperationID {
            recordArtifactFailure(
                for: activePlan,
                operationID: operationID,
                reason: "Private Mode stopped the build before verification."
            )
        }
        if hadJob { appendLedger("KILLED stealth-entry") }
    }

    /// Leaving Stealth restores the lane's ability to accept a NEW job. It
    /// never resurrects the killed one: authority does not survive the wall.
    func resumeAfterStealth() {
        isSuspendedForStealth = false
    }

    /// Reopens admission after a new signed lease. `suspendSynchronously` put
    /// the prior plan in terminal failure and killed its process tree, so this
    /// cannot resurrect that job.
    func resumeNewWorkAfterEntitlementRestored() {
        isSuspendedForStealth = false
    }

    /// Spoken progress for "how's that build going".
    func spokenProgress() -> String {
        switch state {
        case .idle:
            return "i'm not building anything right now."
        case let .awaitingConfirmation(plan, openedAt):
            if openedAt == nil {
                return "i'm reading the exact plan for \(plan.workspaceName). confirmation is not open yet."
            }
            return "i'm holding a build for \(plan.workspaceName). say confirm to start it."
        case let .building(plan, startedAt):
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            let minutes = elapsed / 60
            let position = stepPosition.isEmpty ? "" : " on step \(stepPosition)"
            let duration = minutes < 1
                ? "under a minute in"
                : (minutes == 1 ? "a minute in" : "\(minutes) minutes in")
            return "still building \(plan.workspaceName)\(position), \(duration)."
        }
    }

    // MARK: - Prompt

    /// The build brief. It hands over the plan, the workspace, and the ONLY
    /// sanctioned way to reach the owner's systems — the bundled read tools
    /// that already ship and are already tested — so a generated dashboard
    /// shells out to a known-good reader instead of improvising AppleScript
    /// against Mail.
    static func hostedArtifactPrompt(for plan: WorkflowPlan) -> String {
        let encodedPlan =
            (try? JSONEncoder().encode(plan))
                .map { String(decoding: $0, as: UTF8.self) }
            ?? "{}"
        return """
            Build the approved Ace workflow below as ONE complete,
            self-contained deliverable. Return exactly one compact JSON object
            with exactly these fields and no Markdown fence or prose:
            {"content":"THE COMPLETE FILE BYTES AS A JSON STRING",
            "closing":"ONE SHORT TRUE COMPLETION SENTENCE"}

            The content must be non-empty and at most 17000 UTF-8 bytes. Never
            return a path: the signed app writes only the deliverable already
            approved by the owner. For HTML, inline all CSS and JavaScript and
            make it open cleanly from a file URL on macOS 13 with no package
            manager, local server, developer tools, or separate assets. Build
            every feature that fits in that single file. Never invent private
            inbox, calendar, contact, file, screen, or clipboard contents; use
            an honest empty or connect state when the approved plan names data
            that is not present in this request. Reach no host except an exact
            HTTPS source already present in the approved plan.

            APPROVED_PLAN_JSON
            \(encodedPlan)
            """
    }

    /// The build brief. It hands over the plan, the workspace, and the ONLY
    /// sanctioned way to reach the owner's systems — the bundled read tools
    /// that already ship and are already tested — so a generated dashboard
    /// shells out to a known-good reader instead of improvising AppleScript
    /// against Mail.

    static func buildPrompt(for plan: WorkflowPlan, workspaceURL: URL) -> String {
        var sections: [String] = []
        sections.append("""
            You are Ace's build lane. Build the following, completely, in the \
            current working directory. Do not ask questions — the owner already \
            approved this exact job and is not at the keyboard.

            GOAL: \(plan.goal)
            WORKSPACE: \(workspaceURL.path)
            DELIVERABLE: \(plan.deliverable) (must exist and open cleanly when done)

            FIDELITY: implement every requirement in GOAL. Never silently drop \
            a requested feature, and never substitute a static snapshot for \
            data the owner requested as live. If browser security requires a \
            local bridge, keep it inside this workspace and include the \
            requested one-click local run script.
            """)

        if plan.systems.isEmpty {
            sections.append(
                "READ: this build reads none of the owner's data. Do not go "
                    + "looking for any.")
        } else {
            let toolLines = plan.systems.map { system in
                "  - \(system.spokenName): `\(system.invocation)`"
            }.joined(separator: "\n")
            sections.append("""
                READ: the owner approved reading exactly these, and nothing else:
                \(toolLines)
                These tools are on PATH. They are the only sanctioned readers — \
                never improvise AppleScript, never read a mail store, database, \
                or Library file directly, and never widen this list. If a tool \
                is missing or fails, build the deliverable with that section \
                empty and labelled, and say so at the end. Any generated local \
                service that needs these readers after this build must resolve \
                them from /Applications/Ace.app/Contents/Resources/tools; the \
                temporary build PATH does not survive in a one-click launcher.
                """)
        }

        // Effects are stated separately from reads, and their absence is stated
        // just as explicitly — "nothing was approved" has to be unmissable.
        let callableEffects = plan.effects.filter(\.isCallableFromABuild)
        if callableEffects.isEmpty {
            sections.append("""
                CHANGE: the owner approved NO changes to the Mac. Do not create \
                calendar events, reminders, or notes, do not draft mail, and do \
                not alter volume, appearance, wallpaper, Wi-Fi, the clipboard, \
                or music. Build files in the working directory and nothing else.
                """)
        } else {
            let effectLines = callableEffects.map { effect in
                "  - \(effect.spokenName): `\(effect.invocation)`"
            }.joined(separator: "\n")
            sections.append("""
                CHANGE: the owner approved exactly these changes, and nothing else:
                \(effectLines)
                Never choose among ambiguous accounts, calendars, folders, or \
                lists — those wrappers require exact selectors and will refuse a \
                guess. Anything not on this list is forbidden even if it seems \
                helpful.
                """)
        }

        sections.append("""
            NEVER, whatever the goal: \
            \(WorkflowForbiddenTool.allCases.map { "`\($0.rawValue)` (\($0.reason))" }
                .joined(separator: "; ")).
            """)

        sections.append("""
            BOUNDARIES — these hold regardless of what you can technically do, \
            and are checked after you finish:
            \(WorkflowBoundary.writtenBoundaries)
            Writing any protected path is a reported violation of the owner's \
            trust, not a shortcut.
            """)

        if plan.externalSources.isEmpty {
            sections.append("""
                NETWORK: make no direct network requests. Approved bundled \
                readers may use their own fixed providers; the project itself \
                must stay local and reach no outside host directly.
                """)
        } else {
            sections.append("""
                NETWORK: the owner approved exactly these outside sources:
                \(plan.externalSources.map { "  - \($0.absoluteString)" }
                    .joined(separator: "\n"))
                Reach no other host.
                """)
        }

        if plan.deliverableURL().pathExtension.lowercased() == "html" {
            sections.append("""
                DASHBOARD HOST: run.command is installed by Ace after this build. \
                Do not create server.py, a Python/Node/Ruby server, package \
                manifest, dependency installer, or alternate launcher. The \
                dashboard opens from Ace's signed loopback host on every clean \
                Mac. To refresh an approved reader from browser JavaScript, \
                fetch a relative URL shaped exactly like \
                `api/read?tool=system-info` (add repeated percent-encoded `arg` \
                query items only when the reader contract above requires them). \
                The response is JSON: `{"ok":true,"tool":"system-info", \
                "output":"the bounded reader output"}`. A reader not named in \
                READ is unavailable. Keep static assets relative to index.html.
                """)
        }

        let stepLines = plan.steps.enumerated().map { index, step in
            "\(index + 1). \(step.title) — \(step.detail)"
        }.joined(separator: "\n")
        sections.append("""
            STEPS:
            \(stepLines)

            Before you begin each step, print exactly one line:
            ACE-STEP <n>/\(plan.steps.count) <the step's title>
            That line is spoken to the owner, so print nothing private on it.

            Stay inside the working directory for everything you create. When \
            the deliverable exists and works, print a final line beginning \
            ACE-DONE followed by one short sentence the owner will hear.
            """)
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Outcome

    nonisolated static func outcome(
        for plan: WorkflowPlan,
        processResult: ProcessResult,
        assistantText: String,
        workspaceURL: URL,
        jobStartedAt: Date
    ) -> WorkflowJobOutcome {
        if processResult.wasKilled {
            return .killed("")
        }
        // Process truth comes before the filesystem: a retained workspace can
        // hold an OLD deliverable, and Build 61 announced those as newly built
        // after launch failures, timeouts, and nonzero exits.
        guard processResult.launched else {
            return .failed(
                "the build tool couldn't start on this Mac, so nothing ran. "
                    + "nothing new is in \(plan.workspaceName).")
        }
        if processResult.timedOut {
            return .failed(
                "that build ran past its time limit and i stopped it. "
                    + "nothing finished in \(plan.workspaceName).")
        }
        guard processResult.exitStatus == 0 else {
            return .failed(
                "the build tool stopped with an error before finishing "
                    + "(exit \(processResult.exitStatus)). the partial work is "
                    + "in \(plan.workspaceName), in Ace Projects.")
        }

        let deliverableURL = workspaceURL.appendingPathComponent(plan.deliverable)
        var isDirectory: ObjCBool = false
        let deliverableExists = FileManager.default.fileExists(
            atPath: deliverableURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue

        // Completion is proven by the artifact on disk, never by the model
        // saying it finished. A build that reports success without a file is
        // reported as incomplete.
        guard deliverableExists else {
            return .finishedWithoutDeliverable(
                "the build finished but \(plan.deliverable) isn't there, so i'm "
                    + "not calling it done. the work so far is in "
                    + "\(plan.workspaceName), in Ace Projects.")
        }

        // The deliverable must be THIS run's work. The workspace is retained
        // between runs, so a file untouched since before the job started is a
        // leftover, not a delivery. Small slack absorbs filesystem timestamp
        // granularity.
        let modificationDate = (try? FileManager.default.attributesOfItem(
            atPath: deliverableURL.path))?[.modificationDate] as? Date
        let freshnessFloor = jobStartedAt.addingTimeInterval(-2)
        guard let modificationDate, modificationDate >= freshnessFloor else {
            return .finishedWithoutDeliverable(
                "the build finished but \(plan.deliverable) wasn't updated by "
                    + "this run — the file there is from an earlier build. i'm "
                    + "not calling it done. the workspace is "
                    + "\(plan.workspaceName), in Ace Projects.")
        }

        let closing = spokenClosingLine(from: assistantText)
        let base = "\(plan.workspaceName) is built. open \(plan.deliverable) in "
            + "Ace Projects."
        return .delivered(closing.isEmpty ? base : "\(base) \(closing)")
    }

    /// Every HTML project receives the same launcher written by trusted app
    /// code after the model exits. The model cannot substitute Python or Node,
    /// widen the approved readers, or point at an unsigned machine-global host.
    static func dashboardLauncherScript(
        for plan: WorkflowPlan
    ) -> String? {
        guard plan.deliverableURL().pathExtension.lowercased() == "html" else {
            return nil
        }
        return DashboardHostPolicy.launcherScript(
            allowedTools: plan.systems.map(\.bundledReadTool)
        )
    }

    static func installDashboardLauncher(
        for plan: WorkflowPlan,
        workspaceURL: URL
    ) -> Bool {
        guard let script = dashboardLauncherScript(for: plan) else {
            return true
        }
        let launcherURL = workspaceURL
            .appendingPathComponent("run.command", isDirectory: false)
            .standardizedFileURL
        guard launcherURL.deletingLastPathComponent() == workspaceURL
                .standardizedFileURL,
              launcherURL.resolvingSymlinksInPath() == launcherURL else {
            return false
        }
        let descriptor = launcherURL.path.withCString {
            open(
                $0,
                O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW,
                mode_t(0o755)
            )
        }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let bytes = Array(script.utf8)
        var offset = 0
        let wroteAll = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
        return wroteAll && fchmod(descriptor, mode_t(0o755)) == 0
    }

    /// The model's one closing sentence, bounded. Anything else it printed is
    /// build output and never becomes speech.
    nonisolated static func spokenClosingLine(from output: String) -> String {
        for line in output.split(separator: "\n").reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("ACE-DONE") else { continue }
            let sentence = WorkflowPlanner.collapseWhitespace(
                String(text.dropFirst("ACE-DONE".count)))
            guard !sentence.isEmpty, sentence.count <= 160 else { return "" }
            return sentence
        }
        return ""
    }

    // MARK: - Workspace

    /// Create the workspace, refusing anything that is not a real directory we
    /// own at that exact path. A symlink standing in for the workspace would
    /// redirect the whole job somewhere the owner never approved.
    nonisolated static func prepareWorkspace(at url: URL) -> Bool {
        let fileManager = FileManager.default
        let parent = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: parent, withIntermediateDirectories: true)
        } catch { return false }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return false }
            // An existing entry must be a real directory, not a link to one.
            guard let attributes = try? fileManager.attributesOfItem(
                atPath: url.path),
                (attributes[.type] as? FileAttributeType) == .typeDirectory
            else { return false }
            return true
        }
        do {
            try fileManager.createDirectory(
                at: url, withIntermediateDirectories: false)
        } catch { return false }
        return true
    }

    // MARK: - Brain arguments

    /// Planning is zero-tool. The planner decides WHAT to build; it never
    /// touches anything.
    nonisolated static func plannerArguments(
        for cli: BrainCLI,
        resolvedCodexModel: String?
    ) -> [String] {
        switch cli {
        case .codex:
            guard let resolvedCodexModel else {
                preconditionFailure(
                    "Codex capability must resolve before workflow planning argv"
                )
            }
            return BrainBackend.codexSandboxedArguments(
                resolvedModel: resolvedCodexModel
            )
        case .claude:
            // The zero-tool planner emits one strict JSON object; it is
            // deliberately pinned to Sonnet for bounded planning latency and
            // is not an owner answer lane.
            return BrainBackend.privacyArguments(
                for: .claude,
                BrainBackend.isolatedBaseArguments(model: .sonnet) + [
                "--safe-mode",
                "--disable-slash-commands",
                "--no-chrome",
                "--no-session-persistence",
                "--permission-mode", "dontAsk",
                "--tools", "",
            ])
        case .qwen:
            return AceLocalBrain.cliAnswerArguments(json: true)
        }
    }

    nonisolated static func resolvedPlannerArguments(
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
        return plannerArguments(
            for: cli,
            resolvedCodexModel: resolvedModel
        )
    }

    /// 🚨 FULL MACHINE AUTHORITY — founder ruling 2026-08-01, chosen over a
    /// workspace-scoped sandbox with the risk stated. Real tools, no permission
    /// prompts, no per-effect gate. Unlike `BackgroundAgent.fullAccessClaudeArguments()`
    /// this is NOT gated to the developer Mac: the ruling was about the lane,
    /// and the same bundle ships to buyers.
    ///
    /// What still holds the line, and must keep holding it: execution is
    /// reachable only from an app-owned validated WorkflowPlan consumed once
    /// by the runtime. Session state and MCP servers stay isolated for the same
    /// reason every other lane isolates them.
    nonisolated static func buildLaneArguments(
        for cli: BrainCLI,
        resolvedCodexModel: String?
    ) -> [String] {
        switch cli {
        case .codex:
            guard let resolvedCodexModel else {
                preconditionFailure(
                    "Codex capability must resolve before workflow build argv"
                )
            }
            return BrainBackend.codexFullAccessArguments(
                resolvedModel: resolvedCodexModel
            )
        case .claude:
            return BrainBackend.privacyArguments(for: .claude, [
                "-p",
                "--model", "opus",
                "--output-format", "stream-json",
                "--verbose",
                "--setting-sources", "",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--no-chrome",
                "--no-session-persistence",
                "--dangerously-skip-permissions",
            ])
        case .qwen:
            return AceLocalBrain.cliAnswerArguments()
        }
    }

    nonisolated static func resolvedBuildLaneArguments(
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
        return buildLaneArguments(
            for: cli,
            resolvedCodexModel: resolvedModel
        )
    }

    /// The bundled tool directory inside our own app bundle. Resolved the same
    /// way `AppActionBroker` resolves it, and refused unless it is a real
    /// directory at the exact expected path.
    nonisolated static func bundledToolsDirectory() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let toolsURL = resourceURL
            .appendingPathComponent("tools", isDirectory: true)
            .standardizedFileURL
        guard toolsURL.resolvingSymlinksInPath() == toolsURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: toolsURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return toolsURL
    }

    /// Environment for the build child: the standard isolated environment plus
    /// the bundled tool directory on PATH.
    ///
    /// Without this the build prompt's "these tools are on PATH" was a lie —
    /// the first real job reported "both bundled tools are missing from this
    /// Mac" and rendered a dashboard with four empty panels. The model still
    /// never receives a tool PATH as a value; it invokes them by name, exactly
    /// as the prompt says, and the directory is the one inside our signed
    /// bundle rather than anything the model chose.
    nonisolated static func buildLaneEnvironment(
        claudeExecutablePath: String
    ) -> [String: String] {
        var environment = BrainBackend.processEnvironment(
            claudeExecutablePath: claudeExecutablePath)
        environment["ACE_EFFECT_GUARD_LOCK"] = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("ace-workflow-visible-effect.lock")
            .path
        guard let toolsDirectory = bundledToolsDirectory() else { return environment }
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(toolsDirectory.path):\(existingPath)"
        return environment
    }

    // MARK: - Ledger

    /// Full authority that leaves no trace is the dangerous version of this
    /// feature. Every arm, step, kill and outcome lands here with the exact
    /// approved readback, so a job can be audited after the fact.
    nonisolated static func ledgerURL() -> URL? {
        guard let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true)
        else { return nil }
        // 🚨 0o700 explicitly. `tools/effect-guard.sh` refuses EVERY bundled
        // tool unless this directory is owned by us at exactly 700 — it treats
        // anything looser as an unsafe effect boundary and fails closed. A
        // plain createDirectory uses the process umask (0o755 here), so a
        // subsystem that merely touches its log first can silently disarm the
        // whole tool library. That had already happened on the dev Mac: every
        // tool returned "app action blocked because Ace's effect boundary is
        // unsafe" until the mode was restored.
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("workflow-ledger.log")
    }

    nonisolated func appendLedger(_ message: String) {
        guard let fileURL = ledgerFileURL else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(stamp)] \(message)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Process

    struct ProcessResult: Sendable {
        let text: String
        let truncated: Bool
        let wasKilled: Bool
        let timedOut: Bool
        /// False when the child could not even be spawned. Build 61 collapsed
        /// a launch failure into an empty successful-looking result, and a
        /// stale deliverable then shipped as newly built.
        let launched: Bool
        /// The child's exit status; nonzero is a failed build even when an
        /// old deliverable file still sits in the retained workspace.
        let exitStatus: Int32
    }

    /// One bounded child. stdin is piped, never staged to disk, so a prompt
    /// containing the owner's framing cannot be stranded in a temp file if the
    /// child is SIGKILLed. stdout streams so progress markers arrive live.
    nonisolated static func runProcess(
        executablePath: String,
        arguments: [String],
        standardInput: String,
        workingDirectory: URL,
        timeout: TimeInterval,
        outputLimit: Int,
        processBox: RunningProcessBox,
        /// Nil keeps the standard isolated environment. Only the build lane
        /// overrides it, to put the bundled read tools on PATH; the planner
        /// must never receive them, because it has no tools at all.
        environment: [String: String]? = nil,
        onOutputChunk: (@Sendable (String) -> Void)?
    ) async -> ProcessResult {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<ProcessResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.environment = environment
                    ?? BrainBackend.processEnvironment(
                        claudeExecutablePath: executablePath)

                let inputPipe = Pipe()
                let outputPipe = Pipe()
                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice

                let outputBox = WorkflowOutputBox(limit: outputLimit)
                let outputClosed = DispatchSemaphore(value: 0)
                let outputHandle = outputPipe.fileHandleForReading
                outputHandle.readabilityHandler = { handle in
                    let available = handle.availableData
                    if available.isEmpty {
                        handle.readabilityHandler = nil
                        outputClosed.signal()
                    } else {
                        outputBox.append(available)
                        if let onOutputChunk {
                            onOutputChunk(String(decoding: available, as: UTF8.self))
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    outputHandle.readabilityHandler = nil
                    continuation.resume(
                        returning: ProcessResult(
                            text: "", truncated: false,
                            wasKilled: false, timedOut: false,
                            launched: false, exitStatus: -1))
                    return
                }
                processBox.register(process, generation: 0)

                // Write the prompt off the reader's back so a large brief can
                // never deadlock against a full pipe buffer.
                DispatchQueue.global(qos: .utility).async {
                    let handle = inputPipe.fileHandleForWriting
                    if let data = standardInput.data(using: .utf8) {
                        try? handle.write(contentsOf: data)
                    }
                    try? handle.close()
                }

                let deadline = DispatchTime.now() + timeout
                let timedOut = outputClosed.wait(timeout: deadline) == .timedOut
                if timedOut, process.isRunning {
                    RunningProcessBox.terminateProcessTree(process)
                    outputHandle.readabilityHandler = nil
                }
                process.waitUntilExit()
                processBox.clear(generation: 0)

                let snapshot = outputBox.snapshot()
                // A signal death is the kill path (owner "stop", or Stealth),
                // not a build failure — the difference decides whether Ace says
                // anything at all afterwards.
                let wasKilled = process.terminationReason == .uncaughtSignal && !timedOut
                continuation.resume(
                    returning: ProcessResult(
                        text: snapshot.text,
                        truncated: snapshot.truncated,
                        wasKilled: wasKilled,
                        timedOut: timedOut,
                        launched: true,
                        exitStatus: process.terminationStatus
                    )
                )
            }
        }
    }
}
#endif // circuit-convert
