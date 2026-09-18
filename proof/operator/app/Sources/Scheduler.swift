// Sovereign — SCHEDULED TASKS (the autonomous "modules" the site sells, made real).
//
// THE HONEST CLAIM. The website sells autonomous scheduled modules that run work in the
// background. What is REAL and shippable here: a persisted ScheduledTask model the buyer
// defines (a name + a prompt + a schedule), a scheduler that fires due tasks on time and runs
// each through the SAME agent/brain path the rest of the app uses — writing real
// proof-of-execution receipts and honoring the deterministic Guardrail gate — and a UI to
// create / list / enable / disable / run-now / see-last-result. It ships EMPTY: no bundled
// "revenue modules", no fabricated outputs. The buyer writes the tasks; Sovereign runs them.
//
// HONEST SCOPE OF "ALWAYS-ON". While the app is running, tasks fire on schedule. Combined with
// launch-at-login (LaunchAtLogin / SMAppService, the Mac download build) they run whenever the
// buyer is logged in. A fully-headless overnight daemon with the display locked is beyond the
// App-Store sandbox; the resident login-item + this scheduler is the real, shippable mechanism.
// The UI says this plainly — nothing here pretends to be a boot-time system daemon.
//
// The schedule math (interval + daily-at-time due-calculation, next-run) is PURE and static so it
// is exhaustively unit-tested with no clock, no actor, no UI. The scheduler then enforces it live.
import Foundation
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

// MARK: - Schedule (pure, value-typed, trivially Codable)

/// When a task should fire. Two honest shapes a buyer understands: every N (interval) or once a
/// day at a wall-clock time. Stored as a plain struct (no associated-value enum) so Codable is
/// automatic and the encode/decode round-trip is dead simple to verify.
struct TaskSchedule: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case interval     // every `intervalSeconds`
        case dailyAt      // once per day at hour:minute
        var id: String { rawValue }
        var label: String { self == .interval ? "Every…" : "Daily at…" }
    }

    var kind: Kind = .interval
    var intervalSeconds: Int = 3600     // used when kind == .interval
    var hour: Int = 9                   // used when kind == .dailyAt (0…23)
    var minute: Int = 0                 // used when kind == .dailyAt (0…59)

    /// Floor so a buyer (or a bad import) can't set a runaway sub-minute interval that burns tokens.
    static let minInterval = 60

    private var effectiveInterval: Int { max(Self.minInterval, intervalSeconds) }
    private var safeHour: Int { min(23, max(0, hour)) }
    private var safeMinute: Int { min(59, max(0, minute)) }

    /// A short human label for the row/editor.
    var label: String {
        switch kind {
        case .interval:
            let s = effectiveInterval
            if s % 86400 == 0 { let d = s / 86400; return d == 1 ? "Every day" : "Every \(d) days" }
            if s % 3600 == 0 { let h = s / 3600; return h == 1 ? "Every hour" : "Every \(h) hours" }
            if s % 60 == 0 { let m = s / 60; return m == 1 ? "Every minute" : "Every \(m) minutes" }
            return "Every \(s) seconds"
        case .dailyAt:
            return String(format: "Daily at %02d:%02d", safeHour, safeMinute)
        }
    }

    /// The day's matching DateComponents (hour:minute:00) for daily-at scheduling.
    private var dailyComponents: DateComponents {
        DateComponents(hour: safeHour, minute: safeMinute, second: 0)
    }

    /// The next time this schedule should fire, strictly AFTER `reference`. Pure.
    func nextFireDate(after reference: Date, calendar: Calendar = .current) -> Date {
        switch kind {
        case .interval:
            return reference.addingTimeInterval(TimeInterval(effectiveInterval))
        case .dailyAt:
            return calendar.nextDate(after: reference, matching: dailyComponents,
                                     matchingPolicy: .nextTime) ?? reference.addingTimeInterval(86400)
        }
    }

    /// The most recent scheduled fire time at-or-before `now` (daily-at only). Pure.
    private func mostRecentFire(onOrBefore now: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: now, matching: dailyComponents,
                          matchingPolicy: .nextTime, direction: .backward)
    }

    /// Is the task due now, given when it last ran? A never-run task is due immediately (matches the
    /// existing automation runtime's "never run -> run once now"). Pure → exhaustively unit-tested.
    func isDue(now: Date, lastRun: Date?, calendar: Calendar = .current) -> Bool {
        switch kind {
        case .interval:
            guard let last = lastRun else { return true }
            return now.timeIntervalSince(last) >= TimeInterval(effectiveInterval)
        case .dailyAt:
            guard let last = lastRun else { return true }
            guard let recent = mostRecentFire(onOrBefore: now, calendar: calendar) else { return false }
            return last < recent   // haven't run since the latest scheduled time
        }
    }
}

// MARK: - ScheduledTask (the persisted unit of work — ships EMPTY)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct ScheduledTask: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var prompt = ""                 // the real agent/brain prompt the buyer defines
    var schedule = TaskSchedule()
    var enabled = true
    var created = Date()
    var lastRun: Date?
    var nextRun: Date?
    var lastResult = ""             // the REAL output/error from the last run (never fabricated)
    var lastOutcomeRaw = ""         // ActivityOutcome rawValue, empty until first run
    var runCount = 0

    var lastOutcome: ActivityOutcome? { ActivityOutcome(rawValue: lastOutcomeRaw) }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// nextRun for display, computed on the fly if it was never persisted yet.
    func displayNextRun(now: Date = Date(), calendar: Calendar = .current) -> Date {
        nextRun ?? schedule.nextFireDate(after: now, calendar: calendar)
    }
}
#endif // circuit-convert

// MARK: - Store (persisted JSON in the app-support container; ship-no-data)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class ScheduledTaskStore: ObservableObject {
    @Published private(set) var tasks: [ScheduledTask] = [] { didSet { save() } }

    private let url: URL
    private var loading = false
    /// Demo Mode: tasks created inside the demo stay in memory only, never on the buyer's disk.
    private var demoEphemeral = false

    /// App-support default location (Application Support/Sovereign/tasks.json).
    convenience init(filename: String = "tasks.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sovereign", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.init(url: base.appendingPathComponent(filename))
    }
    /// Explicit URL initializer — used by tests for isolation.
    init(url: URL) { self.url = url; load() }

    private func load() {
        loading = true; defer { loading = false }
        // SHIP-EMPTY: an absent file decodes to nothing → tasks stays []. Never seeded.
        guard let data = try? Data(contentsOf: url) else { return }
        guard let rows = try? JSONDecoder().decode([ScheduledTask].self, from: data) else {
            // Unreadable ≠ empty: park the bytes where the next save can't destroy them.
            preserveCorruptBlob(at: url)
            return
        }
        tasks = rows
    }
    private func save() {
        guard !loading, !demoEphemeral else { return }
        if let data = try? JSONEncoder().encode(tasks) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Demo Mode (in memory only; flag set BEFORE the mutation so nothing demo persists)
    func seedDemo() {
        demoEphemeral = true
        tasks = []   // the demo starts on an empty schedule, never the buyer's real tasks
    }
    func endDemo() {
        loading = true
        tasks = []
        load()
        loading = false
        demoEphemeral = false
    }

    // MARK: Mutation
    func upsert(_ t: ScheduledTask) {
        if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } else { tasks.append(t) }
    }
    func delete(_ t: ScheduledTask) { tasks.removeAll { $0.id == t.id } }
    func setEnabled(_ t: ScheduledTask, _ on: Bool) { var x = t; x.enabled = on; upsert(x) }

    /// Record the REAL result of a run: stamps lastRun/runCount/outcome/result and recomputes nextRun.
    func recordRun(_ id: UUID, at when: Date, outcome: ActivityOutcome, result: String,
                   calendar: Calendar = .current) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        var t = tasks[i]
        t.lastRun = when
        t.runCount += 1
        t.lastOutcomeRaw = outcome.rawValue
        t.lastResult = result
        t.nextRun = t.schedule.nextFireDate(after: when, calendar: calendar)
        tasks[i] = t
    }

    /// Permanently erase ALL scheduled tasks — in memory and on disk (App Store 5.1.1(v) / wipe).
    func wipeAll() { loading = false; demoEphemeral = false; tasks = [] }

    // MARK: Pure selection (testable)
    /// The enabled, valid tasks that should fire at `now`. Pure over the current task list.
    func dueTasks(now: Date, calendar: Calendar = .current) -> [ScheduledTask] {
        tasks.filter { $0.enabled && $0.isValid && $0.schedule.isDue(now: now, lastRun: $0.lastRun, calendar: calendar) }
    }
}
#endif // circuit-convert

// MARK: - Scheduler (fires due tasks through the real agent/brain path)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class TaskScheduler: ObservableObject {
    @Published var lastTick: Date?
    @Published var runningTaskIDs: Set<UUID> = []

    private weak var store: ScheduledTaskStore?
    private weak var router: BrainRouter?
    private weak var activity: ActivityLog?
    private weak var settings: AppSettings?

    /// A PRIVATE agent engine the scheduler drives unattended, so a background scheduled run never
    /// clobbers the UI's own agent state. It writes its real receipts to the shared activity ledger.
    private let agent = AgentEngine()
    private var bag = Set<AnyCancellable>()
    private var pendingAgentSink: AnyCancellable?
    private var timer: Timer?
    private var isProcessing = false

    /// Wire the scheduler + its private agent engine to the app's real dependencies.
    /// `autostart` starts the live 30s timer (production); tests pass false to stay hermetic.
    func attach(store: ScheduledTaskStore, router: BrainRouter, activity: ActivityLog?, settings: AppSettings?,
                chatStore: Store, memory: MemoryStore, calendar: CalendarConnector? = nil,
                files: FilesConnector? = nil, mcp: MCPManager? = nil, crm: ClientStore? = nil,
                autostart: Bool = true) {
        self.store = store; self.router = router; self.activity = activity; self.settings = settings
        agent.attach(router: router, store: chatStore, memory: memory, calendar: calendar,
                     files: files, activity: activity, mcp: mcp, crm: crm)
        // UNATTENDED SAFETY: a scheduled run has no human to confirm. Any confirmation-gated tool
        // (side-effect under confirm posture, or a destructive action) is auto-DECLINED — the safe
        // default. Under the buyer's Autonomous posture, side-effecting tools auto-allow upstream in
        // the guardrail gate (no prompt is raised), so opted-in autonomy still works. The guardrail
        // receipt for the confirm-demand is still written, so the ledger is honest about what was
        // skipped vs. what ran.
        agent.$pendingApproval
            .sink { [weak self] approval in if approval != nil { self?.agent.resolveApproval(false) } }
            .store(in: &bag)
        if autostart { start() }
    }

    func start() {
        timer?.invalidate()
        // 30s tick — granular enough for daily-at and short intervals, light on the CPU.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in Task { @MainActor in self?.tick() } }
    }

    func tick() {
        lastTick = Date()
        guard let store, !isProcessing else { return }
        let due = store.dueTasks(now: Date())
        guard !due.isEmpty else { return }
        isProcessing = true
        Task { @MainActor in
            defer { isProcessing = false }
            // Scheduler-fired runs are UNATTENDED — the buyer walked away, so each completed run
            // leaves ONE reviewable "assign-and-walk-away" ping (SV-19).
            for t in due where !runningTaskIDs.contains(t.id) { await runOne(t, unattended: true) }
        }
    }

    /// Manual "Run now" from the UI — same real path, serialized against the shared engine. The
    /// buyer is present and watching, so it writes NO walk-away review ping.
    func runNow(_ task: ScheduledTask) {
        guard !runningTaskIDs.contains(task.id) else { return }
        Task { @MainActor in
            while isProcessing { try? await Task.sleep(nanoseconds: 200_000_000) }
            isProcessing = true
            defer { isProcessing = false }
            await runOne(task, unattended: false)
        }
    }

    /// Test seam: drive one run deterministically without the live timer. Mirrors the exact path a
    /// scheduled tick (unattended) or a manual Run-now (attended) takes.
    func runForTest(_ task: ScheduledTask, unattended: Bool) async { await runOne(task, unattended: unattended) }

    private func runOne(_ task: ScheduledTask, unattended: Bool) async {
        guard let store, let router else { return }
        guard router.isUsable else {
            let msg = "No brain connected — the task did not run. Install Ornith 1.0 through Ollama (or serve it on a local OpenAI-compatible server), or enable the on-device brain."
            store.recordRun(task.id, at: Date(), outcome: .failure, result: msg)
            activity?.record(kind: .automation, title: task.name.isEmpty ? "Scheduled task" : task.name,
                             detail: msg, outcome: .failure)
            if unattended { writeReviewPing(task: task, outcome: .failure, summary: msg) }
            return
        }
        runningTaskIDs.insert(task.id)
        let (outcome, text) = await execute(task)
        runningTaskIDs.remove(task.id)
        store.recordRun(task.id, at: Date(), outcome: outcome, result: text)
        if unattended { writeReviewPing(task: task, outcome: outcome, summary: text) }
    }

    /// SV-19 — write the single "assign-and-walk-away" review ping for a completed unattended run.
    private func writeReviewPing(task: ScheduledTask, outcome: ActivityOutcome, summary: String) {
        let ping = Self.reviewPing(taskName: task.name, outcome: outcome, summary: summary)
        activity?.recordReviewPing(title: ping.title, detail: ping.detail, outcome: outcome)
    }

    /// PURE, testable content of the walk-away review ping — names the task, states whether it just
    /// ran or needs attention, and carries the REAL (capped) result. Never fabricated.
    static func reviewPing(taskName: String, outcome: ActivityOutcome, summary: String)
        -> (title: String, detail: String) {
        let name = taskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Scheduled task" : taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let head: String
        switch outcome {
        case .success: head = "ran while you were away"
        case .failure: head = "needs your attention"
        case .info:    head = "completed"
        }
        let body = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = body.isEmpty ? "\(name) \(head)." : "\(name) \(head).\n\n\(String(body.prefix(600)))"
        return (title: "Review \u{00B7} \(name)", detail: detail)
    }

    /// Run a task through the AGENT path (tools + per-tool guardrail enforcement + a full receipt
    /// trace) when a tool-capable External account is connected; otherwise fall back to the plain
    /// BRAIN path (text only — no tools, nothing to gate). Both produce real receipts; nothing is
    /// fabricated. The agent path's own terminal receipt is the proof, so we don't double-log it.
    private func execute(_ task: ScheduledTask) async -> (ActivityOutcome, String) {
        guard let router else { return (.failure, "Not configured.") }
        let prompt = task.prompt
        if router.externalForAgent() != nil {
            return await runViaAgent(goal: prompt)
        } else {
            return await runViaBrain(prompt: prompt, taskName: task.name)
        }
    }

    /// Drive the private agent engine unattended and await its terminal status. The engine writes
    /// its own `.agent` receipt (terminal + per-tool steps + guardrail decisions) to the ledger.
    private func runViaAgent(goal: String) async -> (ActivityOutcome, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(ActivityOutcome, String), Never>) in
            var resumed = false
            let sink = agent.$status
                .dropFirst()                       // skip the pre-run (current) value
                .sink { [weak self] st in
                    guard let self else { return }
                    let terminal: (ActivityOutcome, String)?
                    switch st {
                    case .done:               terminal = (.success, self.agent.finalAnswer)
                    case .failed(let m):      terminal = (.failure, m)
                    case .unavailable(let m): terminal = (.failure, m)
                    default:                  terminal = nil
                    }
                    if let t = terminal, !resumed { resumed = true; cont.resume(returning: t) }
                }
            pendingAgentSink = sink
            agent.run(goal: goal)
        }
    }

    /// Plain brain completion (any connected brain) — TEXT ONLY, no tool surface, so there is
    /// nothing for the guardrail gate to act on. Records ONE real `.automation` receipt.
    private func runViaBrain(prompt: String, taskName: String) async -> (ActivityOutcome, String) {
        let system = settings?.effectiveSystemPrompt ?? ""
        let started = Date()
        let result: (ActivityOutcome, String) = await withCheckedContinuation { cont in
            guard let router else { cont.resume(returning: (.failure, "Not configured.")); return }
            router.complete(prompt: prompt, system: system) { r in
                switch r {
                case .success(let s): cont.resume(returning: (.success, s))
                case .failure(let e):
                    let msg = (e as? ExternalBrain.Failure)?.message ?? (e as? AIError)?.message ?? e.localizedDescription
                    cont.resume(returning: (.failure, "Run failed: \(msg)"))
                }
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        activity?.record(kind: .automation, title: taskName.isEmpty ? "Scheduled task" : taskName,
                         detail: result.1, outcome: result.0, durationMS: ms)
        return result
    }

    deinit { timer?.invalidate() }
}
#endif // circuit-convert
