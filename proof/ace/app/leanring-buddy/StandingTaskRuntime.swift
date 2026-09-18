//
//  StandingTaskRuntime.swift
//  Black Label Assistant — standing tasks: the loop that survives the utterance.
//
//  Before this file, every goal died with the push-to-talk release: the red
//  worker ran one reasoning turn, spoke a summary, and forgot. A standing task
//  survives — it lives in a durable store on disk, fires on its own schedule
//  with nobody at the keyboard, produces a read-only reasoning result, records
//  what happened, and decides for itself: reschedule, retry, or escalate. The
//  runtime, not the model, is the loop.
//
//  Anatomy (each part maps to a piece of this file):
//    trigger  — a 20s timer tick finds due records; on relaunch the store is
//               re-read and work missed while the app was closed is recovered
//    record   — standing-tasks.json in Application Support/BlackLabel,
//               written atomically on every state change
//    loop     — fire → observe the worker's summary → update the record →
//               decide (reschedule / retry / complete / escalate)
//    gate     — app, file, web, message, and other consequential work is never
//               armed; a legacy stored approval is invalidated on load
//    verify   — scheduled runs must end with a concrete receipt and must
//               open with "FAILED:" on honest failure; the runtime classifies
//               the summary instead of trusting a bare "done"
//    receipts — runtime.log, same append pattern as agent.log
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

// MARK: - Schedule + record shapes

/// When a standing task fires. Exactly one shape's fields are populated,
/// discriminated by `kind`.
struct StandingTaskSchedule: Codable {
    enum Kind: String, Codable {
        case once      // one absolute fire time
        case interval  // every N seconds
        case daily     // every day at a local wall-clock time
    }

    var kind: Kind
    /// once: the absolute fire time (ISO8601).
    var onceFireAtISO: String?
    /// interval: seconds between fires (the parser floors this at 60).
    var intervalSeconds: Int?
    /// daily: local wall-clock hour (0-23) and minute.
    var dailyHour: Int?
    var dailyMinute: Int?
}

/// One durable standing task. This record IS the thing the user supervises —
/// it survives restarts, carries its own approval, and accumulates the honest
/// history of every fire.
struct StandingTaskRecord: Codable {
    var id: String
    var createdAtISO: String
    /// The action handed to the red worker on every fire (schedule phrase removed).
    var actionInstruction: String
    var schedule: StandingTaskSchedule
    /// Human phrasing of the schedule ("every 30 minutes", "every day at 8 am")
    /// so announcements never have to re-derive it.
    var spokenScheduleDescription: String
    /// Legacy decode field. New records are always false; a true value from an
    /// older build is terminally escalated before the scheduler can fire it.
    var approvedForDestructive: Bool
    /// scheduled | running | completed | cancelled | escalated
    var status: String
    var attemptCount: Int
    /// Recurring tasks that fail this many times IN A ROW escalate and stop —
    /// a broken loop must surface, not fire forever.
    var consecutiveFailureCount: Int
    var lastFiredAtISO: String?
    var lastResultSummary: String?
    var lastRunSucceeded: Bool?
    /// Recurring tasks announce their FIRST success out loud (proof of flow),
    /// then go quiet on success so an every-few-minutes task doesn't chatter.
    var hasAnnouncedFirstRecurringSuccess: Bool
    var nextFireAtISO: String
}

/// A schedule-shaped utterance the parser understood, ready to arm.
struct ParsedStandingTask {
    let actionInstruction: String
    let schedule: StandingTaskSchedule
    let spokenScheduleDescription: String
    let firstFireAt: Date
}

/// A running task that loses its worker before a verified receipt has an
/// unknown outcome. Read-only work is safe to try again; a consequential
/// action is not — the effect may already have happened.
enum StandingTaskUnknownOutcomeDisposition: Equatable {
    case escalatedConsequential
    case requeuedReadOnly
}

/// Pure transition policy shared by crash recovery, Stealth cancellation, and
/// worker failures. Keeping this outside the runtime makes the no-duplicate
/// boundary deterministic and independently testable without firing a task.
enum StandingTaskSafetyPolicy {
    static func isConsequential(_ record: StandingTaskRecord) -> Bool {
        record.approvedForDestructive
            || CrossAppActionPolicy.requiresConfirmation(record.actionInstruction)
    }

    @discardableResult
    static func applyUnknownOutcome(
        to record: inout StandingTaskRecord,
        summary: String
    ) -> StandingTaskUnknownOutcomeDisposition {
        record.lastRunSucceeded = false
        record.lastResultSummary = summary
        if record.consecutiveFailureCount < Int.max {
            record.consecutiveFailureCount += 1
        }

        guard !isConsequential(record) else {
            // Creation-time approval never survives an unknown effect boundary.
            // The escalated record is terminal until the user gives a new task;
            // no scheduler path may reuse this approval for an automatic retry.
            record.approvedForDestructive = false
            record.status = "escalated"
            return .escalatedConsequential
        }

        record.status = "scheduled"
        return .requeuedReadOnly
    }
}

/// Subscription authority never survives a server refusal. Unlike Stealth,
/// entitlement loss does not leave overdue work queued for the first tick
/// after reactivation: every old scheduled/running record becomes terminal.
enum StandingTaskEntitlementPolicy {
    @discardableResult
    static func cancelPreviouslyAdmittedWork(
        in records: inout [StandingTaskRecord]
    ) -> Int {
        var cancelledCount = 0
        for index in records.indices
        where records[index].status == "scheduled"
            || records[index].status == "running"
            || records[index].status == "paused" {
            records[index].status = "cancelled"
            records[index].approvedForDestructive = false
            records[index].lastRunSucceeded = false
            records[index].lastResultSummary =
                "cancelled because the Ace entitlement ended; not resumed"
            cancelledCount += 1
        }
        return cancelledCount
    }
}

// MARK: - Runtime

@MainActor
final class StandingTaskRuntime: ObservableObject {
    /// Runs one fire through the red worker: (instruction, approvedForDestructive)
    /// → the worker's spoken-style summary ("" means the user cancelled it).
    private let executeInstruction: (String, Bool) async -> String
    /// True while the worker is busy with something else — a due task simply
    /// waits for the next tick rather than stacking model sessions.
    private let isExecutorBusy: () -> Bool
    /// Speaks a line to the user. Returns whether it actually spoke (the
    /// caller suppresses speech during meeting capture); the runtime adds its
    /// own quiet-hours suppression and receipts either way.
    private let announce: (String) -> Bool

    @Published private(set) var records: [StandingTaskRecord] = []
    private let persistenceURL: URL?
    private let mayManage: () -> Bool
    private var tickTimer: Timer?
    /// One fire at a time — serialization is the concurrency model.
    private var fireInProgress = false
    private var fireTask: Task<Void, Never>?
    private var fireGeneration: UInt64 = 0
    private var activeFireRecordID: String?

    /// The worker's canned fallback lines. A scheduled run that comes back
    /// with one of these did NOT produce its effect — classify as failure.
    /// (Kept in sync with BackgroundAgent.run's two fallback returns.)
    private static let workerTimeoutSummary =
        "that one was taking too long, so i stopped it. want me to try a simpler version?"
    private static let workerNoResultSummary =
        "i finished, but didn't get a clear result back."

    init(
        executeInstruction: @escaping (String, Bool) async -> String,
        isExecutorBusy: @escaping () -> Bool,
        announce: @escaping (String) -> Bool,
        mayManage: @escaping () -> Bool,
        storeURL: URL? = nil
    ) {
        self.executeInstruction = executeInstruction
        self.isExecutorBusy = isExecutorBusy
        self.announce = announce
        self.mayManage = mayManage
        self.persistenceURL = storeURL ?? Self.storeURL
    }

    // MARK: Lifecycle

    func start() {
        records = Self.loadRecords(from: persistenceURL)
        invalidateLegacyConsequentialRecords()
        recoverAfterRelaunch()
        saveRecords()
        let timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 5
        tickTimer = timer
        let scheduledCount = records.filter { $0.status == "scheduled" }.count
        appendReceipt("RUNTIME start scheduled=\(scheduledCount) total=\(records.count)")
    }

    /// Older builds could persist creation-time approval for unattended app
    /// effects. The current runtime has no such authority. Invalidate those
    /// records before crash recovery or the first timer tick.
    private func invalidateLegacyConsequentialRecords() {
        for index in records.indices {
            guard records[index].approvedForDestructive
                    || CrossAppActionPolicy.requiresConfirmation(
                        records[index].actionInstruction
                    ) else { continue }
            records[index].approvedForDestructive = false
            if records[index].status == "scheduled"
                || records[index].status == "running" {
                records[index].status = "escalated"
                records[index].lastRunSucceeded = false
                records[index].lastResultSummary =
                    "legacy unattended action disabled; no execution attempted"
            }
            appendReceipt(
                "TASK-MIGRATE id=\(Self.shortID(records[index].id)) "
                    + "legacy-consequential → escalated approval=invalidated"
            )
        }
    }

    /// The app was relaunched — the store is the memory. A task that should
    /// have fired while the app was closed is recovered, not silently lost:
    /// recent one-shots fire shortly after launch, stale one-shots escalate
    /// out loud, and recurring tasks resume on their next natural occurrence
    /// (never a burst of make-up fires).
    private func recoverAfterRelaunch() {
        let now = Date()
        for index in records.indices {
            var record = records[index]

            // Killed mid-fire (crash / hard quit): the effect boundary is
            // unknown. Consequential work becomes terminal immediately and
            // loses its carried approval; only read-only work may requeue.
            if record.status == "running" {
                let disposition = StandingTaskSafetyPolicy.applyUnknownOutcome(
                    to: &record,
                    summary: "interrupted — the app closed mid-run; outcome unknown"
                )
                switch disposition {
                case .escalatedConsequential:
                    appendReceipt(
                        "TASK-RECOVER id=\(Self.shortID(record.id)) was=running → escalated reason=outcome-unknown approval=invalidated")
                    announceIfAllowed(
                        "i stopped an interrupted standing task because its app action may already have happened. i did not retry it.")
                case .requeuedReadOnly:
                    appendReceipt(
                        "TASK-RECOVER id=\(Self.shortID(record.id)) was=running → scheduled read-only")
                }
            }

            guard record.status == "scheduled",
                  let nextFireAt = Self.isoFormatter.date(from: record.nextFireAtISO),
                  nextFireAt < now else {
                records[index] = record
                continue
            }

            switch record.schedule.kind {
            case .once:
                // Missed by less than six hours → still worth doing; fire soon.
                // Older than that → the moment has passed; say so instead of
                // silently doing something the user scheduled for a gone context.
                if now.timeIntervalSince(nextFireAt) < 6 * 3600 {
                    record.nextFireAtISO = Self.isoFormatter.string(from: now.addingTimeInterval(45))
                    appendReceipt("TASK-RECOVER id=\(Self.shortID(record.id)) missed-once → firing in 45s")
                } else {
                    record.status = "escalated"
                    appendReceipt("TASK-RECOVER id=\(Self.shortID(record.id)) missed-once stale → escalated")
                    announceIfAllowed(
                        "heads up — i missed a standing task while i was closed: \(Self.spokenAction(record)). tell me again if you still want it.")
                }
            case .interval:
                let interval = TimeInterval(record.schedule.intervalSeconds ?? 3600)
                record.nextFireAtISO = Self.isoFormatter.string(from: now.addingTimeInterval(interval))
                appendReceipt("TASK-RECOVER id=\(Self.shortID(record.id)) interval resumes at \(record.nextFireAtISO)")
            case .daily:
                record.nextFireAtISO = Self.isoFormatter.string(
                    from: Self.nextDailyOccurrence(
                        hour: record.schedule.dailyHour ?? 9,
                        minute: record.schedule.dailyMinute ?? 0,
                        after: now))
                appendReceipt("TASK-RECOVER id=\(Self.shortID(record.id)) daily resumes at \(record.nextFireAtISO)")
            }
            records[index] = record
        }
    }

    // MARK: The loop

    /// True while ghost mode is on. The timer keeps ticking but fires nothing —
    /// a stealthed Ace must never start a background job that opens apps, types,
    /// or speaks. Nothing is lost: a task that comes due during stealth fires on
    /// the first tick after stealth ends.
    private(set) var isSuspended = false

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        fireGeneration &+= 1
        fireTask?.cancel()
        fireTask = nil
        deferActiveFireForStealth()
        appendReceipt("RUNTIME suspended (stealth) — nothing fires until stealth ends")
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        appendReceipt("RUNTIME resumed")
    }

    /// Hard entitlement boundary. This differs from Stealth suspension:
    /// reactivation may admit newly-created work, but never an old queued or
    /// in-flight task whose original admission ended with the subscription.
    func suspendAndCancelForEntitlementLoss() {
        isSuspended = true
        fireGeneration &+= 1
        fireTask?.cancel()
        fireTask = nil
        fireInProgress = false
        activeFireRecordID = nil
        let cancelledCount =
            StandingTaskEntitlementPolicy.cancelPreviouslyAdmittedWork(
                in: &records
            )
        saveRecords()
        appendReceipt(
            "RUNTIME entitlement-closed cancelled=\(cancelledCount)"
        )
    }

    /// Opens the scheduler for tasks the owner explicitly creates after a new
    /// lease. Cancelled pre-refusal records remain terminal.
    func resumeNewWorkAfterEntitlementRestored() {
        guard isSuspended else { return }
        isSuspended = false
        appendReceipt("RUNTIME entitlement-restored new-work-only")
    }

    private func tick() {
        guard !isSuspended else { return }
        guard !fireInProgress else { return }
        let now = Date()
        guard let dueIndex = records.firstIndex(where: { record in
            record.status == "scheduled"
                && (Self.isoFormatter.date(from: record.nextFireAtISO) ?? .distantFuture) <= now
        }) else { return }

        // A live worker task (the user's own, or a previous fire) owns the
        // executor — the due task just waits for the next tick.
        if isExecutorBusy() {
            appendReceipt("TASK-DEFER id=\(Self.shortID(records[dueIndex].id)) executor busy")
            return
        }
        fire(recordIndex: dueIndex)
    }

    @discardableResult
    private func fire(recordIndex: Int) -> Bool {
        guard !isSuspended, mayManage() else { return false }
        let before = records
        fireInProgress = true
        records[recordIndex].status = "running"
        records[recordIndex].attemptCount += 1
        records[recordIndex].lastFiredAtISO = Self.isoFormatter.string(from: Date())
        guard saveRecords() else {
            records = before
            fireInProgress = false
            appendReceipt("TASK-FIRE-FAILED reason=persist-write-failed")
            return false
        }

        let record = records[recordIndex]
        fireGeneration &+= 1
        let generation = fireGeneration
        activeFireRecordID = record.id
        appendReceipt(
            "TASK-FIRE id=\(Self.shortID(record.id)) "
                + "attempt=\(record.attemptCount) "
                + "instructionCharacters=\(record.actionInstruction.count)"
        )

        // The executor is a no-tool reasoning lane. Restate that constraint in
        // the task itself so the output never implies an external effect.
        let scheduledRunInstruction = """
        \(record.actionInstruction)

        SCHEDULED RUN: this is an unattended read-only reasoning task. You have no tools and must not claim to inspect live data, use an app, read a file, browse, send, or change anything. Answer only from the instruction itself. If the requested answer needs external state, begin with exactly "FAILED:" and one short reason.
        """

        fireTask = Task { [weak self] in
            guard let self else { return }
            guard self.canContinueFire(recordID: record.id, generation: generation) else {
                self.deferActiveFireForStealth(
                    expectedRecordID: record.id,
                    expectedGeneration: generation
                )
                return
            }
            let summary = await self.executeInstruction(
                scheduledRunInstruction,
                record.approvedForDestructive
            )
            guard self.canContinueFire(recordID: record.id, generation: generation) else {
                return
            }
            self.completeFire(recordID: record.id, summary: summary)
        }
        return true
    }

    private func canContinueFire(recordID: String, generation: UInt64) -> Bool {
        !Task.isCancelled
            && !isSuspended
            && mayManage()
            && fireGeneration == generation
            && activeFireRecordID == recordID
    }

    /// Stealth cancellation crosses an unknown effect boundary. Read-only work
    /// remains due; consequential work escalates and invalidates its approval so
    /// the first post-Stealth tick can never duplicate a possibly completed act.
    private func deferActiveFireForStealth(
        expectedRecordID: String? = nil,
        expectedGeneration: UInt64? = nil
    ) {
        if let expectedRecordID, let expectedGeneration {
            guard activeFireRecordID == expectedRecordID,
                  fireGeneration == expectedGeneration else { return }
        }
        guard let recordID = activeFireRecordID,
              let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].status == "running" else {
            fireInProgress = false
            activeFireRecordID = nil
            return
        }
        let disposition = StandingTaskSafetyPolicy.applyUnknownOutcome(
            to: &records[index],
            summary: "interrupted by Stealth while running; outcome unknown"
        )
        fireTask = nil
        fireInProgress = false
        activeFireRecordID = nil
        saveRecords()
        switch disposition {
        case .escalatedConsequential:
            appendReceipt(
                "TASK-ESCALATE id=\(Self.shortID(recordID)) reason=stealth-interrupted-outcome-unknown approval=invalidated")
        case .requeuedReadOnly:
            appendReceipt("TASK-DEFER id=\(Self.shortID(recordID)) stealth read-only")
        }
    }

    /// Observe → update → decide. This is where the loop closes: the record
    /// absorbs what actually happened and the runtime picks the next state.
    private func completeFire(recordID: String, summary: String) {
        defer {
            fireTask = nil
            activeFireRecordID = nil
            fireInProgress = false
            saveRecords()
        }
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        var record = records[index]

        // The user cancelled this task while it was mid-fire — the cancel wins;
        // writing a completion state here would silently resurrect it.
        if record.status == "cancelled" {
            appendReceipt("TASK-DONE id=\(Self.shortID(record.id)) discarded=cancelled-mid-run")
            return
        }

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let userCancelled = trimmedSummary.isEmpty
        let confessedFailure = trimmedSummary.lowercased().hasPrefix("failed:")
        let workerFellBack = trimmedSummary == Self.workerTimeoutSummary
            || trimmedSummary == Self.workerNoResultSummary
        let runSucceeded = !userCancelled && !confessedFailure && !workerFellBack

        record.lastRunSucceeded = runSucceeded
        record.lastResultSummary = userCancelled ? "cancelled by the user mid-run" : trimmedSummary
        appendReceipt(
            "TASK-DONE id=\(Self.shortID(record.id)) "
                + "ok=\(runSucceeded) cancelled=\(userCancelled) "
                + "summaryCharacters=\(trimmedSummary.count)"
        )

        // No receipt proves that a consequential effect did not happen. This
        // applies to one-shot and recurring records alike: timeout, cancellation,
        // fallback, or FAILED all stop the loop and invalidate the old approval.
        if !runSucceeded, StandingTaskSafetyPolicy.isConsequential(record) {
            let unknownSummary = userCancelled
                ? "interrupted or cancelled mid-run; outcome unknown"
                : (trimmedSummary.isEmpty ? "worker returned no receipt; outcome unknown" : trimmedSummary)
            StandingTaskSafetyPolicy.applyUnknownOutcome(
                to: &record,
                summary: unknownSummary
            )
            appendReceipt(
                "TASK-ESCALATE id=\(Self.shortID(record.id)) reason=effect-outcome-unknown approval=invalidated")
            announceIfAllowed(
                "i stopped that standing task because its app action could not be verified. i did not retry it, so it couldn't happen twice.")
            records[index] = record
            return
        }

        switch record.schedule.kind {
        case .once:
            if runSucceeded {
                record.status = "completed"
                appendReceipt("TASK-COMPLETE id=\(Self.shortID(record.id))")
                announceIfAllowed("your standing task is done — \(Self.spokenSummary(trimmedSummary))")
            } else if record.attemptCount < 3 {
                // One honest retry cycle before giving up: five minutes out.
                record.status = "scheduled"
                record.nextFireAtISO = Self.isoFormatter.string(from: Date().addingTimeInterval(300))
                appendReceipt("TASK-RETRY id=\(Self.shortID(record.id)) attempt=\(record.attemptCount) next=\(record.nextFireAtISO)")
            } else {
                record.status = "escalated"
                appendReceipt("TASK-ESCALATE id=\(Self.shortID(record.id)) reason=once-failed-3-attempts")
                announceIfAllowed(
                    "your standing task — \(Self.spokenAction(record)) — failed three times. last result: \(Self.spokenSummary(record.lastResultSummary ?? "no result")). i've stopped trying.")
            }
        case .interval, .daily:
            if runSucceeded {
                record.consecutiveFailureCount = 0
                if !record.hasAnnouncedFirstRecurringSuccess {
                    record.hasAnnouncedFirstRecurringSuccess = true
                    announceIfAllowed(
                        "your standing task ran — \(Self.spokenSummary(trimmedSummary)) i'll keep running it \(record.spokenScheduleDescription), quietly unless something fails.")
                }
            } else if !userCancelled {
                record.consecutiveFailureCount += 1
            }

            if record.consecutiveFailureCount >= 3 {
                record.status = "escalated"
                appendReceipt("TASK-ESCALATE id=\(Self.shortID(record.id)) reason=recurring-failed-3-consecutive")
                announceIfAllowed(
                    "your standing task — \(Self.spokenAction(record)) — has failed three times in a row, so i've paused it. last result: \(Self.spokenSummary(record.lastResultSummary ?? "no result"))")
            } else {
                record.status = "scheduled"
                record.nextFireAtISO = Self.isoFormatter.string(from: nextOccurrence(for: record.schedule))
                appendReceipt("TASK-NEXT id=\(Self.shortID(record.id)) at=\(record.nextFireAtISO)")
            }
        }
        records[index] = record
    }

    private func nextOccurrence(for schedule: StandingTaskSchedule) -> Date {
        switch schedule.kind {
        case .once:
            return Self.isoFormatter.date(from: schedule.onceFireAtISO ?? "") ?? Date().addingTimeInterval(60)
        case .interval:
            return Date().addingTimeInterval(TimeInterval(max(60, schedule.intervalSeconds ?? 3600)))
        case .daily:
            return Self.nextDailyOccurrence(
                hour: schedule.dailyHour ?? 9, minute: schedule.dailyMinute ?? 0, after: Date())
        }
    }

    // MARK: Creation + management (called from CompanionManager's routes)

    /// Parses a schedule-shaped utterance. nil = not a standing-task request;
    /// the caller falls through to its normal routing.
    func parse(_ utterance: String) -> ParsedStandingTask? {
        StandingTaskParser.parse(utterance)
    }

    /// Arms a parsed task into the store and returns the spoken confirmation.
    func arm(
        _ parsed: ParsedStandingTask,
        approvedForDestructive: Bool
    ) -> String {
        guard !approvedForDestructive,
              !CrossAppActionPolicy.requiresConfirmation(
                parsed.actionInstruction
              ) else {
            return "i did not arm that standing task because unattended "
                + "app, file, web, and message actions are disabled."
        }
        let record = StandingTaskRecord(
            id: UUID().uuidString,
            createdAtISO: Self.isoFormatter.string(from: Date()),
            actionInstruction: parsed.actionInstruction,
            schedule: parsed.schedule,
            spokenScheduleDescription: parsed.spokenScheduleDescription,
            approvedForDestructive: approvedForDestructive,
            status: "scheduled",
            attemptCount: 0,
            consecutiveFailureCount: 0,
            lastFiredAtISO: nil,
            lastResultSummary: nil,
            lastRunSucceeded: nil,
            hasAnnouncedFirstRecurringSuccess: false,
            nextFireAtISO: Self.isoFormatter.string(from: parsed.firstFireAt)
        )
        records.append(record)
        // "armed" depends on the record being PROVEN on disk: an in-memory
        // record would fire this session and silently vanish on relaunch —
        // a confirmed schedule the owner believes in and Ace does not keep
        // (issue #14). Roll it back so no half-armed state exists.
        guard saveRecords() else {
            records.removeLast()
            appendReceipt(
                "TASK-ARM-FAILED id=\(Self.shortID(record.id)) "
                    + "reason=persist-write-failed"
            )
            return "i couldn't save that standing task, so it is not armed. "
                + "try again in a moment."
        }
        appendReceipt(
            "TASK-ARM id=\(Self.shortID(record.id)) "
                + "schedule=\(parsed.spokenScheduleDescription) "
                + "approved=\(approvedForDestructive) "
                + "instructionCharacters=\(parsed.actionInstruction.count)"
        )
        let spokenFirstFire = Self.spokenClockTime(parsed.firstFireAt)
        return "standing task armed — \(parsed.actionInstruction), \(parsed.spokenScheduleDescription). first run around \(spokenFirstFire)."
    }

    enum ControlAction { case pause, resume, runNow, delete, edit(String) }
    struct ControlResult {
        let succeeded: Bool
        let message: String
    }

    /// Controls bind one exact persisted task; they never select by visible row
    /// position or recycle a terminal task after entitlement loss.
    func manage(id: String, action: ControlAction) -> ControlResult {
        func result(_ succeeded: Bool, _ message: String) -> ControlResult {
            ControlResult(succeeded: succeeded, message: message)
        }
        guard !isSuspended, mayManage() else {
            return result(false, "Task controls are paused. Leave Stealth and verify your Ace access first.")
        }
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return result(false, "This task is no longer available. Refresh the task list.")
        }
        let original = records
        switch action {
        case .pause:
            guard ["scheduled", "running"].contains(records[index].status) else {
                return result(false, "Only a scheduled or running task can be paused.")
            }
            if records[index].status == "running" {
                records[index].lastRunSucceeded = false
                records[index].lastResultSummary = "Paused during this run; no completed result was verified."
            }
            records[index].status = "paused"
        case .resume:
            guard records[index].status == "paused",
                  !StandingTaskSafetyPolicy.isConsequential(records[index]) else {
                return result(false, "Only a paused reasoning task can resume. Create a new task for changed work.")
            }
            records[index].status = "scheduled"
            records[index].nextFireAtISO = Self.isoFormatter.string(from: max(Date(), nextOccurrence(for: records[index].schedule)))
            records[index].consecutiveFailureCount = 0
        case .runNow:
            guard records[index].status == "scheduled",
                  !StandingTaskSafetyPolicy.isConsequential(records[index]) else {
                return result(false, "Resume a paused task before running it. Completed or cancelled tasks need a new schedule.")
            }
            guard !fireInProgress, !isExecutorBusy() else {
                return result(false, "Ace is working on another task. Try Run now after it finishes.")
            }
            return fire(recordIndex: index)
                ? result(true, "Task started. Its result will appear here when the run finishes.")
                : result(false, "The run did not start because its state could not be saved or access changed.")
        case .delete:
            guard records[index].status != "running" else {
                return result(false, "Pause the running task before deleting it.")
            }
            records.remove(at: index)
        case .edit(let sentence):
            guard ["scheduled", "paused"].contains(records[index].status),
                  sentence.count <= 8_000,
                  let parsed = parse(sentence),
                  !CrossAppActionPolicy.requiresConfirmation(parsed.actionInstruction) else {
                return result(false, "Enter a reasoning task with an explicit schedule, up to 8,000 characters. Pause running work first; app, file, web and message actions require you to be present.")
            }
            records[index].actionInstruction = parsed.actionInstruction
            records[index].schedule = parsed.schedule
            records[index].spokenScheduleDescription = parsed.spokenScheduleDescription
            records[index].nextFireAtISO = Self.isoFormatter.string(from: parsed.firstFireAt)
            records[index].attemptCount = 0
            records[index].consecutiveFailureCount = 0
            records[index].lastFiredAtISO = nil
            records[index].lastResultSummary = nil
            records[index].lastRunSucceeded = nil
            records[index].hasAnnouncedFirstRecurringSuccess = false
        }
        guard saveRecords() else {
            records = original
            return result(false, "The change could not be saved. The task retains its previous state.")
        }
        if case .pause = action, activeFireRecordID == id {
            fireGeneration &+= 1
            fireTask?.cancel()
            fireTask = nil
            activeFireRecordID = nil
            fireInProgress = false
        }
        appendReceipt("TASK-CONTROL id=\(Self.shortID(id)) saved=true")
        switch action {
        case .pause: return result(true, "Task paused and saved. An interrupted run has no verified result.")
        case .resume: return result(true, "Task resumed and its next run was saved.")
        case .delete: return result(true, "Task deleted from the saved schedule.")
        case .edit: return result(true, "Task and schedule saved. Previous run details were cleared for the changed task.")
        case .runNow: return result(false, "The task did not start.")
        }
    }

    /// "what are your standing tasks" — the record store, spoken honestly,
    /// including what the last run actually produced.
    func spokenTaskList() -> String {
        let activeRecords = records.filter { ["scheduled", "running", "paused"].contains($0.status) }
        let escalatedRecords = records.filter { $0.status == "escalated" }
        if activeRecords.isEmpty && escalatedRecords.isEmpty {
            return "no standing tasks right now. standing tasks are limited to "
                + "read-only reasoning that needs no live app or web data."
        }
        var spokenParts: [String] = []
        if !activeRecords.isEmpty {
            spokenParts.append("i have \(activeRecords.count) standing task\(activeRecords.count == 1 ? "" : "s").")
            for (position, record) in activeRecords.prefix(5).enumerated() {
                var line = "\(position + 1) — \(Self.spokenAction(record)), \(record.spokenScheduleDescription), \(record.status)."
                if let lastResultSummary = record.lastResultSummary, let lastRunSucceeded = record.lastRunSucceeded {
                    line += lastRunSucceeded
                        ? " last run: \(Self.spokenSummary(lastResultSummary))"
                        : " last run failed: \(Self.spokenSummary(lastResultSummary))"
                } else {
                    line += " hasn't run yet."
                }
                spokenParts.append(line)
            }
        }
        if !escalatedRecords.isEmpty {
            spokenParts.append(
                "\(escalatedRecords.count) escalated and waiting on you: "
                + escalatedRecords.prefix(3).map { Self.spokenAction($0) }.joined(separator: "; ") + ".")
        }
        return spokenParts.joined(separator: " ")
    }

    /// Cancels standing tasks. keywords nil = cancel everything active;
    /// otherwise the words must appear in the task's action text.
    func cancelTasks(matching keywords: String?) -> String {
        var cancelledActions: [String] = []
        var priorStatusByIndex: [Int: String] = [:]
        for index in records.indices where ["scheduled", "running", "paused"].contains(records[index].status) {
            let actionText = records[index].actionInstruction.lowercased()
            let matches: Bool
            if let keywords, !keywords.isEmpty {
                // Every meaningful keyword must appear — "the email one" should
                // not cancel an unrelated task by a stray stop-word match.
                let meaningfulWords = keywords.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count > 2 && !["the", "one", "task", "about", "for", "that"].contains($0) }
                matches = !meaningfulWords.isEmpty && meaningfulWords.allSatisfy { actionText.contains($0) }
            } else {
                matches = true
            }
            if matches {
                priorStatusByIndex[index] = records[index].status
                records[index].status = "cancelled"
                cancelledActions.append(Self.spokenAction(records[index]))
            }
        }
        if cancelledActions.isEmpty {
            return "i didn't find a standing task matching that."
        }
        // "cancelled" depends on the store being PROVEN on disk: an
        // unpersisted cancellation resurrects the task on relaunch
        // (issue #14). Revert the in-memory flip so live state matches what
        // the owner was told, and write the receipts only for durable truth.
        guard saveRecords() else {
            for (index, priorStatus) in priorStatusByIndex {
                records[index].status = priorStatus
            }
            appendReceipt(
                "TASK-CANCEL-FAILED count=\(priorStatusByIndex.count) "
                    + "reason=persist-write-failed"
            )
            return "i couldn't save that cancellation, so those standing "
                + "tasks are still armed. try again in a moment."
        }
        for index in priorStatusByIndex.keys.sorted() {
            appendReceipt(
                "TASK-CANCEL id=\(Self.shortID(records[index].id)) "
                    + "instructionCharacters="
                    + "\(records[index].actionInstruction.count)"
            )
        }
        return "cancelled — \(cancelledActions.joined(separator: "; "))."
    }

    // MARK: Announcements

    /// Speech policy for unattended results: never overnight (a 3am success
    /// spoken to an empty room is noise — the receipt and the record keep the
    /// truth), and the CompanionManager closure additionally suppresses speech
    /// during meeting capture.
    private func announceIfAllowed(_ spokenLine: String) {
        let hour = Calendar.current.component(.hour, from: Date())
        guard (7...23).contains(hour) else {
            appendReceipt(
                "TASK-ANNOUNCE suppressed=quiet-hours "
                    + "characters=\(spokenLine.count)"
            )
            return
        }
        let spoke = announce(spokenLine)
        appendReceipt(
            "TASK-ANNOUNCE spoken=\(spoke) "
                + "characters=\(spokenLine.count)"
        )
    }

    // MARK: Voice-grammar helpers for CompanionManager's routes

    nonisolated private static let listRequestPattern =
        #"(?i)^\s*(?:what\s+are\s+(?:your|my|the)|list\s+(?:your|my|the)?|show\s+me\s+(?:your|my|the)?|do\s+you\s+have\s+any)\s*(?:standing|scheduled|recurring)\s+tasks?\b"#

    nonisolated static func isListRequest(_ utterance: String) -> Bool {
        utterance.range(of: listRequestPattern, options: .regularExpression) != nil
    }

    nonisolated private static let cancelRequestPattern =
        #"(?i)^\s*(?:please\s+)?(?:cancel|stop|kill|remove|drop)\s+(?:the\s+|my\s+|all\s+(?:of\s+)?(?:the\s+|my\s+)?|every\s+)?(?:standing|scheduled|recurring)\s+tasks?\b(?:\s+(?:about|for|that\s+says?)\s+(.+?))?\s*[.!?]*\s*$"#

    /// "cancel the standing task about the email" → keywords "the email";
    /// "cancel all standing tasks" → keywords nil (cancel everything).
    nonisolated static func extractCancelRequest(_ utterance: String) -> (keywords: String?, isCancelRequest: Bool) {
        guard let regex = try? NSRegularExpression(pattern: cancelRequestPattern),
              let match = regex.firstMatch(in: utterance, range: NSRange(utterance.startIndex..., in: utterance)) else {
            return (nil, false)
        }
        if match.range(at: 1).location != NSNotFound, let keywordRange = Range(match.range(at: 1), in: utterance) {
            return (String(utterance[keywordRange]), true)
        }
        return (nil, true)
    }

    // MARK: Spoken-phrase helpers

    private static func spokenAction(_ record: StandingTaskRecord) -> String {
        let action = record.actionInstruction
        return action.count > 70 ? String(action.prefix(67)) + "…" : action
    }

    private static func spokenSummary(_ summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 220 ? String(trimmed.prefix(217)) + "…" : trimmed
    }

    private static func spokenClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date).lowercased()
    }

    // Pure date math — callable from the (nonisolated) parser.
    nonisolated static func nextDailyOccurrence(hour: Int, minute: Int, after referenceDate: Date) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return Calendar.current.nextDate(
            after: referenceDate, matching: components, matchingPolicy: .nextTime
        ) ?? referenceDate.addingTimeInterval(24 * 3600)
    }

    // MARK: Store

    nonisolated static var isoFormatter: ISO8601DateFormatter {
        ISO8601DateFormatter()
    }

    private static func shortID(_ id: String) -> String { String(id.prefix(8)) }

    private static var storeURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true)
            .appendingPathComponent("standing-tasks.json")
    }

    private static func loadRecords(from storeURL: URL?) -> [StandingTaskRecord] {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let loadedRecords = try? JSONDecoder().decode([StandingTaskRecord].self, from: data) else {
            return []
        }
        return loadedRecords
    }

    /// True only when the records are proven on disk. Arm and cancel speak
    /// their confirmations from this verdict — a swallowed write error here
    /// would confirm durable state that does not survive a relaunch
    /// (issue #14). Fire-loop callers may still discard the result: their
    /// truth channel is the receipt log, not a spoken confirmation.
    @discardableResult
    private func saveRecords() -> Bool {
        guard let storeURL = persistenceURL else { return false }
        guard (try? PrivateSupportDirectory.ensure(
            at: storeURL.deletingLastPathComponent()
        )) != nil else {
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return false }
        do {
            try data.write(to: storeURL, options: .atomic)
            return try Data(contentsOf: storeURL) == data
        } catch {
            return false
        }
    }

    // MARK: Receipts

    private func appendReceipt(_ message: String) {
        guard let directory = persistenceURL?.deletingLastPathComponent() else { return }
        guard (try? PrivateSupportDirectory.ensure(at: directory)) != nil
        else {
            return
        }
        let line = "\(Self.isoFormatter.string(from: Date())) \(message)\n"
        let fileURL = directory.appendingPathComponent("runtime.log")
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Parser

/// Turns a schedule-shaped utterance into (action, schedule). Pure functions,
/// no state — testable by replaying utterances. The grammar is deliberately
/// narrow: only phrasings with an explicit time shape arm a task, so ordinary
/// questions and one-shot commands never get captured by accident.
enum StandingTaskParser {

    /// Existing tools and machines own these words — "set a timer", "remind
    /// me", "put a meeting at 5:30 on my calendar" — and a standing task must
    /// never steal them. Calendar-family words route to the worker's
    /// calendar-add tool, where they belong.
    private static let excludedDomainPattern =
        #"(?i)\b(timer|alarm|remind|reminder|reminders|calendar|meeting|meetings|appointment|appointments|event|events)\b"#

    /// Question-shaped remainders ("what's at 5 pm", "is my wifi on…") are
    /// asks, not actions to schedule. do/does/did only count as questions when
    /// a pronoun follows — "do the backup" is an imperative and must pass.
    private static let questionShapedRemainderPattern =
        #"(?i)^\s*(?:what|what's|when|when's|where|where's|who|who's|why|how|is|are|am|was|were|(?:do|does|did)\s+(?:you|i|we|they|he|she|it))\b"#

    /// A time like "8", "8:30", "8 am", "8.30 pm", "noon", "midnight".
    /// Groups: 1=hour 2=minute 3=am/pm 4=noon/midnight.
    private static let clockTimePattern =
        #"(?:(\d{1,2})(?:[:.](\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?|(noon|midnight))"#

    static func parse(_ utterance: String) -> ParsedStandingTask? {
        guard utterance.range(of: excludedDomainPattern, options: .regularExpression) == nil else { return nil }
        let normalized = normalizeNumberWords(utterance)

        // Try each schedule shape; first hit wins. Each matcher returns the
        // schedule plus the RANGE of the schedule phrase so the action is
        // whatever remains.
        let matchers: [(String) -> (schedule: StandingTaskSchedule, spoken: String, firstFireAt: Date, phraseRange: Range<String.Index>)?] = [
            matchIntervalSchedule, matchDailySchedule, matchRelativeOnceSchedule, matchAbsoluteOnceSchedule,
        ]
        for matcher in matchers {
            guard let matched = matcher(normalized) else { continue }
            var actionText = normalized
            actionText.removeSubrange(matched.phraseRange)
            let actionInstruction = cleanActionRemainder(actionText)
            guard isUsableAction(actionInstruction) else { continue }
            return ParsedStandingTask(
                actionInstruction: actionInstruction,
                schedule: matched.schedule,
                spokenScheduleDescription: matched.spoken,
                firstFireAt: matched.firstFireAt)
        }
        return nil
    }

    // "every 30 minutes …", "every hour …", "every half hour …"
    private static func matchIntervalSchedule(_ text: String)
        -> (schedule: StandingTaskSchedule, spoken: String, firstFireAt: Date, phraseRange: Range<String.Index>)? {
        let pattern = #"(?i)\b(?:every|each)\s+(?:(\d+)\s+)?(half\s+an?\s+hour|half\s+hour|minutes?|mins?|hours?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let phraseRange = Range(match.range, in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let unit = text[unitRange].lowercased()
        var quantity = 1
        if match.range(at: 1).location != NSNotFound, let quantityRange = Range(match.range(at: 1), in: text) {
            guard let parsedQuantity = Int(text[quantityRange]) else { return nil }
            quantity = parsedQuantity
        }
        let seconds: Int
        if unit.hasPrefix("half") {
            seconds = 1800
        } else if unit.hasPrefix("hour") {
            guard quantity <= Int.max / 3600 else { return nil }
            seconds = quantity * 3600
        } else {
            guard quantity <= Int.max / 60 else { return nil }
            seconds = quantity * 60
        }
        // Floor at one minute — "every second" is a runaway, not a schedule.
        let flooredSeconds = max(60, seconds)
        guard Date().timeIntervalSince1970 + Double(flooredSeconds) < 253_402_300_799 else { return nil }
        let spoken: String
        if flooredSeconds == 1800 {
            spoken = "every half hour"
        } else if flooredSeconds % 3600 == 0 {
            let hours = flooredSeconds / 3600
            spoken = hours == 1 ? "every hour" : "every \(hours) hours"
        } else {
            let minutes = flooredSeconds / 60
            spoken = minutes == 1 ? "every minute" : "every \(minutes) minutes"
        }
        return (
            StandingTaskSchedule(kind: .interval, onceFireAtISO: nil, intervalSeconds: flooredSeconds, dailyHour: nil, dailyMinute: nil),
            spoken,
            Date().addingTimeInterval(TimeInterval(flooredSeconds)),
            phraseRange)
    }

    // "every morning …", "every day at 8:30 …", "daily at 9 pm …"
    private static func matchDailySchedule(_ text: String)
        -> (schedule: StandingTaskSchedule, spoken: String, firstFireAt: Date, phraseRange: Range<String.Index>)? {
        // The word boundary sits BEFORE the optional at-clause: a time ending
        // in a dot ("8 a.m.") has no trailing \b, and a boundary placed after
        // the clause makes the regex silently drop the time and mis-default.
        let pattern = #"(?i)\b(?:(?:every|each)\s+(morning|day|afternoon|evening|night)|daily)\b(?:\s+at\s+"# + clockTimePattern + #")?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let phraseRange = Range(match.range, in: text) else { return nil }

        var dayWord = "day"
        if match.range(at: 1).location != NSNotFound, let dayWordRange = Range(match.range(at: 1), in: text) {
            dayWord = text[dayWordRange].lowercased()
        }
        // Defaults per day-part; an explicit "at TIME" overrides.
        var hour: Int
        var minute = 0
        switch dayWord {
        case "morning": hour = 8
        case "afternoon": hour = 13
        case "evening": hour = 18
        case "night": hour = 21
        default: hour = 9
        }
        if let explicitTime = extractClockTime(from: text, match: match, firstGroupIndex: 2) {
            hour = explicitTime.hour
            minute = explicitTime.minute
            // "every night at 8" means 8 pm, not 8 am — day-part disambiguates
            // a bare hour with no meridiem.
            if !explicitTime.hadMeridiem, hour < 12, dayWord == "evening" || dayWord == "night" {
                hour += 12
            }
        }
        let firstFireAt = StandingTaskRuntime.nextDailyOccurrence(hour: hour, minute: minute, after: Date())
        let spoken = "every day at \(spokenTime(hour: hour, minute: minute))"
        return (
            StandingTaskSchedule(kind: .daily, onceFireAtISO: nil, intervalSeconds: nil, dailyHour: hour, dailyMinute: minute),
            spoken,
            firstFireAt,
            phraseRange)
    }

    // "in 20 minutes …", "in an hour …"
    private static func matchRelativeOnceSchedule(_ text: String)
        -> (schedule: StandingTaskSchedule, spoken: String, firstFireAt: Date, phraseRange: Range<String.Index>)? {
        let pattern = #"(?i)\bin\s+(\d+)\s+(minutes?|mins?|hours?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let phraseRange = Range(match.range, in: text),
              let quantityRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let quantity = Int(text[quantityRange]) else { return nil }
        let multiplier = text[unitRange].lowercased().hasPrefix("hour") ? 3600 : 60
        guard quantity <= Int.max / multiplier else { return nil }
        let seconds = quantity * multiplier
        let flooredSeconds = max(60, seconds)
        guard Date().timeIntervalSince1970 + Double(flooredSeconds) < 253_402_300_799 else { return nil }
        let fireAt = Date().addingTimeInterval(TimeInterval(flooredSeconds))
        let spokenUnit = text[unitRange].lowercased().hasPrefix("hour")
            ? (quantity == 1 ? "hour" : "hours") : (quantity == 1 ? "minute" : "minutes")
        return (
            StandingTaskSchedule(
                kind: .once, onceFireAtISO: StandingTaskRuntime.isoFormatter.string(from: fireAt),
                intervalSeconds: nil, dailyHour: nil, dailyMinute: nil),
            "once, in \(quantity) \(spokenUnit)",
            fireAt,
            phraseRange)
    }

    // "at 5:30 pm …", "at noon …" — requires a meridiem, colon form, or a
    // named time, so a bare ambiguous "at 5" never arms anything.
    private static func matchAbsoluteOnceSchedule(_ text: String)
        -> (schedule: StandingTaskSchedule, spoken: String, firstFireAt: Date, phraseRange: Range<String.Index>)? {
        // No \b after the time: "5 p.m." ends in a dot, where \b never matches.
        let pattern = #"(?i)\bat\s+"# + clockTimePattern + #"(?:\s+(today|tonight|tomorrow))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let phraseRange = Range(match.range, in: text),
              let clockTime = extractClockTime(from: text, match: match, firstGroupIndex: 1),
              clockTime.isUnambiguous else { return nil }
        var fireAt = nextOccurrenceToday(hour: clockTime.hour, minute: clockTime.minute)
        if match.range(at: 5).location != NSNotFound, let dayWordRange = Range(match.range(at: 5), in: text),
           text[dayWordRange].lowercased() == "tomorrow" {
            // "tomorrow at 9 am" when 9 am today hasn't passed yet still means
            // tomorrow — push a same-day occurrence out by a day.
            if Calendar.current.isDateInToday(fireAt) {
                fireAt = fireAt.addingTimeInterval(24 * 3600)
            }
        }
        return (
            StandingTaskSchedule(
                kind: .once, onceFireAtISO: StandingTaskRuntime.isoFormatter.string(from: fireAt),
                intervalSeconds: nil, dailyHour: nil, dailyMinute: nil),
            "once, at \(spokenTime(hour: clockTime.hour, minute: clockTime.minute))",
            fireAt,
            phraseRange)
    }

    // MARK: parser internals

    private struct ParsedClockTime {
        let hour: Int
        let minute: Int
        let hadMeridiem: Bool
        /// True when the phrasing can't be mistaken for a count or an address:
        /// it carried am/pm, a colon, or was a named time (noon/midnight).
        let isUnambiguous: Bool
    }

    /// Reads the clockTimePattern groups out of a match. `firstGroupIndex` is
    /// the group number where the clock-time groups start inside the caller's
    /// larger pattern (hour, minute, meridiem, named).
    private static func extractClockTime(
        from text: String, match: NSTextCheckingResult, firstGroupIndex: Int
    ) -> ParsedClockTime? {
        let namedGroupIndex = firstGroupIndex + 3
        if match.range(at: namedGroupIndex).location != NSNotFound,
           let namedRange = Range(match.range(at: namedGroupIndex), in: text) {
            let named = text[namedRange].lowercased()
            return ParsedClockTime(hour: named == "noon" ? 12 : 0, minute: 0, hadMeridiem: true, isUnambiguous: true)
        }
        guard match.range(at: firstGroupIndex).location != NSNotFound,
              let hourRange = Range(match.range(at: firstGroupIndex), in: text),
              var hour = Int(text[hourRange]), hour <= 23 else { return nil }
        var minute = 0
        var hadColonForm = false
        if match.range(at: firstGroupIndex + 1).location != NSNotFound,
           let minuteRange = Range(match.range(at: firstGroupIndex + 1), in: text),
           let parsedMinute = Int(text[minuteRange]), parsedMinute <= 59 {
            minute = parsedMinute
            hadColonForm = true
        }
        var hadMeridiem = false
        if match.range(at: firstGroupIndex + 2).location != NSNotFound,
           let meridiemRange = Range(match.range(at: firstGroupIndex + 2), in: text) {
            hadMeridiem = true
            let meridiem = text[meridiemRange].lowercased()
            if meridiem.hasPrefix("p"), hour < 12 { hour += 12 }
            if meridiem.hasPrefix("a"), hour == 12 { hour = 0 }
        }
        return ParsedClockTime(
            hour: hour, minute: minute, hadMeridiem: hadMeridiem,
            isUnambiguous: hadMeridiem || hadColonForm)
    }

    private static func nextOccurrenceToday(hour: Int, minute: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        let candidate = Calendar.current.date(from: components) ?? Date().addingTimeInterval(3600)
        // Already passed today → tomorrow.
        return candidate > Date() ? candidate : candidate.addingTimeInterval(24 * 3600)
    }

    private static func spokenTime(hour: Int, minute: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        guard let date = Calendar.current.date(from: components) else { return "\(hour):\(minute)" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date).lowercased()
    }

    /// STT sometimes writes small numbers as words ("in twenty minutes").
    /// Normalize the common ones so the digit-based patterns match. "a"/"an"
    /// before a time unit means one ("in an hour").
    private static func normalizeNumberWords(_ text: String) -> String {
        var normalized = text
        let numberWords: [(String, String)] = [
            ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"), ("five", "5"),
            ("six", "6"), ("seven", "7"), ("eight", "8"), ("nine", "9"), ("ten", "10"),
            ("fifteen", "15"), ("twenty", "20"), ("thirty", "30"), ("forty five", "45"), ("sixty", "60"),
            ("an", "1"), ("a", "1"),
        ]
        for (word, digits) in numberWords {
            normalized = normalized.replacingOccurrences(
                of: #"(?i)\b"# + word + #"\b(?=\s+(?:minutes?|mins?|hours?)\b)"#,
                with: digits,
                options: .regularExpression)
        }
        return normalized
    }

    /// Strips connective debris left where the schedule phrase was removed,
    /// plus explicit "schedule a task to …" framing.
    private static func cleanActionRemainder(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Polite wrappers first ("can you please …", "i need you to …") so the
        // framing strip below sees the bare request.
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)^(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?|i\s+(?:want|need)\s+you\s+to\s+|please\s+)"#,
            with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)^(?:please\s+)?(?:schedule|set\s+up|create|give\s+yourself|make)\s+(?:a\s+|another\s+)?(?:standing\s+|scheduled\s+|recurring\s+)?(?:task|job)\s*(?:to|that|:)?\s*"#,
            with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)^(?:and\s+|then\s+|to\s+|please\s+|,\s*)+"#, with: "", options: .regularExpression)
        // ReDoS-safe. The previous form was
        //   (?:\s*[,;]\s*|\s+and\s+|\s+then\s+|\s+please\s*)+$
        // where each alternative both began and ended with \s+, so a run of spaces
        // between two filler words could be split between one iteration's trailing \s+
        // and the next one's leading \s+ in exponentially many ways. On a non-matching
        // tail the engine explores all of them: " and" + "   and"*22 + "!" took 4.5s,
        // doubling with every extra repetition — and this runs on raw dictated speech.
        // Whitespace is now consumed only at the START of an alternative; "and"/"then"
        // assert their following space with a non-consuming lookahead, so no two
        // iterations can ever contest the same whitespace. Same input took 0.0002s.
        // 60k-case differential fuzz vs the old pattern: the only behaviour change is
        // that a dangling trailing "and"/"then" is now also stripped (the old form
        // needed whitespace on BOTH sides and so left it behind). Never strips content.
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)(?:\s*[,;]|\s+and(?=\s)|\s+then(?=\s)|\s+please)+\s*$"#, with: "", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The remainder must be a real action: non-trivial and not
    /// question-shaped — "what's at 5 pm" is an ask, never a task.
    private static func isUsableAction(_ action: String) -> Bool {
        guard action.count >= 3, action.rangeOfCharacter(from: .letters) != nil else { return false }
        guard action.range(of: questionShapedRemainderPattern, options: .regularExpression) == nil else { return false }
        // A clock in a factual statement is context, not authorization to
        // schedule its remaining words. Only an explicit imperative enters
        // this deterministic scheduler; other wording stays conversational.
        let imperative = #"(?i)^(?:check|monitor|review|summarize|explain|analyse|analyze|calculate|compare|report|tell|notify|read|list|look|run|do|perform|send|open|close|create|write|save|delete|remove|move|copy|back\s+up|backup|update|refresh|fetch|download|upload|start|stop|turn|scan|generate|prepare|print|clean|clear|restart|launch|archive|export|import)\b"#
        return action.range(of: imperative, options: .regularExpression) != nil
    }
}
