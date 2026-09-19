#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — the automation/reminder runtime. A single repeating timer (while the app
// is open) fires due reminders as native notifications and runs due automations against
// the on-device brain, appending real output to each automation's log. HONEST: this runs
// only while the app is running — the UI states that plainly. Nothing is simulated.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UserNotifications) && !CIRCUIT_WINDOWS_SIM
import UserNotifications
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

@MainActor
final class Runtime: ObservableObject {
    @Published var lastTick: Date?
    @Published var runningAutomationIDs: Set<UUID> = []
    @Published var firedReminderTitles: [String] = []   // recent in-app banner feed (honest, real fires)

    private weak var store: Store?
    private weak var ai: AIEngine?
    private weak var settings: AppSettings?
    private weak var memory: MemoryStore?
    private weak var router: BrainRouter?
    private weak var calendar: CalendarConnector?
    private weak var files: FilesConnector?
    private weak var activity: ActivityLog?
    private var timer: Timer?
    private var notifAuthorized = false
    #if os(iOS)
    // fireAt each reminder occurrence was handed to the OS for — lets the foreground tick skip the
    // duplicate immediate banner for occurrences iOS will deliver (or already delivered) itself.
    private var scheduledFireAt: [UUID: Date] = [:]
    // iOS suppresses banners for a foregrounded app unless a delegate opts in via willPresent.
    // Without this the in-app tick's "fired" ledger entry has no visible counterpart at all.
    private static let foregroundDelegate = ForegroundNotificationDelegate()
    final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }
    #endif

    func attach(store: Store, ai: AIEngine, settings: AppSettings, memory: MemoryStore? = nil,
                router: BrainRouter? = nil, activity: ActivityLog? = nil) {
        self.store = store; self.ai = ai; self.settings = settings; self.memory = memory; self.router = router
        self.activity = activity
        start()
    }

    /// Wire the local connectors so automations (incl. the proactive daily briefing) can ground
    /// on the buyer's real calendar + files. Only used when the buyer has turned them on.
    func attachConnectors(calendar: CalendarConnector?, files: FilesConnector?) {
        self.calendar = calendar; self.files = files
    }

    func requestNotificationAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.notifAuthorized = granted }
        }
    }

    /// Restore an already-made grant on relaunch WITHOUT prompting — `notifAuthorized` starts
    /// false every launch, and without this a buyer who granted last session is silently back
    /// on the beep-only fallback.
    func refreshNotificationAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            Task { @MainActor in self.notifAuthorized = ok }
        }
    }

    func start() {
        timer?.invalidate()
        refreshNotificationAuth()
        #if os(iOS)
        UNUserNotificationCenter.current().delegate = Self.foregroundDelegate
        #endif
        // Tick every 30s — granular enough for reminders/automations, light on the CPU.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Run one tick shortly after launch so due items don't wait a full interval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in Task { @MainActor in self?.tick() } }
    }

    func tick() {
        lastTick = Date()
        fireDueReminders()
        #if os(iOS)
        syncScheduledReminderNotifications()
        #endif
        runDueAutomations()
    }

    #if os(iOS)
    /// Hand every pending future occurrence to the OS as a real scheduled notification, so a locked
    /// or suspended iPhone still shows the reminder at its fire time — the in-app 30s timer cannot
    /// run there. Identifiers are stable per reminder, so rescheduling replaces rather than stacks;
    /// removed/done reminders drop their pending request.
    private func syncScheduledReminderNotifications() {
        guard let store else { return }
        let center = UNUserNotificationCenter.current()
        let now = Date()
        var valid: [UUID: Date] = [:]
        for r in store.reminders where !r.done && r.fireAt > now.addingTimeInterval(1) {
            valid[r.id] = r.fireAt
            guard scheduledFireAt[r.id] != r.fireAt else { continue }   // already scheduled as-is
            let content = UNMutableNotificationContent()
            content.title = "Reminder"
            content.body = r.title.isEmpty ? "Reminder" : r.title
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, r.fireAt.timeIntervalSince(now)), repeats: false)
            center.add(UNNotificationRequest(identifier: "reminder-\(r.id.uuidString)", content: content, trigger: trigger))
        }
        let stale = scheduledFireAt.keys.filter { valid[$0] == nil }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale.map { "reminder-\($0.uuidString)" })
        }
        scheduledFireAt = valid
    }
    #endif

    // MARK: Reminders
    private func fireDueReminders() {
        guard let store else { return }
        let now = Date()
        for r in store.reminders where !r.done && r.fireAt <= now {
            #if os(iOS)
            // If this occurrence was handed to the OS, iOS shows (or already showed) that banner —
            // a second immediate notification here would double-fire. Post directly only for
            // occurrences the OS never had (e.g. created already-due while foreground).
            if scheduledFireAt[r.id] != r.fireAt {
                notify(title: "Reminder", body: r.title.isEmpty ? "Reminder" : r.title)
            }
            #else
            notify(title: "Reminder", body: r.title.isEmpty ? "Reminder" : r.title)
            #endif
            firedReminderTitles.insert(r.title.isEmpty ? "Reminder" : r.title, at: 0)
            activity?.record(kind: .reminder, title: r.title.isEmpty ? "Reminder" : r.title,
                             detail: "Fired on schedule (\(r.repeats.label.lowercased())).", outcome: .info)
            if firedReminderTitles.count > 12 { firedReminderTitles = Array(firedReminderTitles.prefix(12)) }
            var updated = r
            updated.lastFired = now
            switch r.repeats {
            case .once:   updated.done = true
            case .hourly: updated.fireAt = now.addingTimeInterval(3600)
            case .daily:  updated.fireAt = now.addingTimeInterval(86400)
            case .weekly: updated.fireAt = now.addingTimeInterval(604800)
            }
            store.upsertReminder(updated)
        }
    }

    /// Manually fire a reminder now (UI button) — same path as the timer.
    func fireNow(_ r: Reminder) {
        guard let store else { return }
        notify(title: "Reminder", body: r.title.isEmpty ? "Reminder" : r.title)
        var u = r; u.lastFired = Date(); if r.repeats == .once { u.done = true }
        store.upsertReminder(u)
        firedReminderTitles.insert(u.title.isEmpty ? "Reminder" : u.title, at: 0)
        activity?.record(kind: .reminder, title: u.title.isEmpty ? "Reminder" : u.title,
                         detail: "Fired manually.", outcome: .info)
    }

    private func notify(title: String, body: String) {
        guard notifAuthorized else {
            // Fall back to an in-app banner feed only — never silently drop, never fake a system notification.
            NSSound.beep(); return
        }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: Automations
    private func dueInterval(_ s: ReminderRepeat) -> TimeInterval {
        switch s { case .once: return .greatestFiniteMagnitude; case .hourly: return 3600; case .daily: return 86400; case .weekly: return 604800 }
    }
    private func runDueAutomations() {
        guard let store else { return }
        let now = Date()
        for a in store.automations where a.enabled && !a.instruction.isEmpty {
            let due: Bool
            if let last = a.lastRun { due = now.timeIntervalSince(last) >= dueInterval(a.schedule) }
            else { due = true }     // never run -> run once now
            if due && !runningAutomationIDs.contains(a.id) { run(a) }
        }
    }

    /// Run an automation immediately (timer or the UI "Run now" button). Real brain call —
    /// uses whichever brain is active (the buyer's External or the on-device model).
    func run(_ a: Automation) {
        guard let store, let settings, let router, !runningAutomationIDs.contains(a.id) else { return }
        guard router.isUsable else {
            let msg = "No brain available — automation did not run. Install Ornith 1.0 through Ollama (or serve it on a local OpenAI-compatible server), or enable Apple Intelligence."
            store.recordAutomationRun(a.id, output: msg)
            activity?.record(kind: .automation, title: a.name, detail: msg, outcome: .failure)
            return
        }
        runningAutomationIDs.insert(a.id)
        let startedAt = Date()
        // Multi-source grounding: standing memory + knowledge docs + indexed files + (if the
        // buyer turned the Calendar connector on) their real upcoming events. All honest, all the
        // buyer's own data — empty strings drop out so nothing is fabricated.
        let docGrounding = a.groundOnKnowledge
            ? store.documentGrounding(for: a.instruction, useSemantic: settings.semanticRAG, includeFiles: true) : ""
        let standing = memory?.standingContext() ?? ""
        let calGrounding = (calendar?.isReadable == true) ? (calendar?.groundingText(days: 7) ?? "") : ""
        let grounding = [standing, calGrounding, docGrounding].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let system = settings.effectiveSystemPrompt
        let prompt = grounding.isEmpty ? a.instruction
            : a.instruction + "\n\nContext for this run:\n" + grounding
        router.complete(prompt: prompt, system: system) { [weak self] result in
            guard let self else { return }
            self.runningAutomationIDs.remove(a.id)
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            switch result {
            case .success(let text):
                store.recordAutomationRun(a.id, output: text)
                self.activity?.record(kind: .automation, title: a.name, detail: text, outcome: .success, durationMS: ms)
            case .failure(let err):
                let msg = (err as? ExternalBrain.Failure)?.message ?? (err as? AIError)?.message ?? err.localizedDescription
                store.recordAutomationRun(a.id, output: "Run failed: \(msg)")
                self.activity?.record(kind: .automation, title: a.name, detail: "Run failed: \(msg)", outcome: .failure, durationMS: ms)
            }
        }
    }

    deinit { timer?.invalidate() }
}
#endif // circuit-convert
