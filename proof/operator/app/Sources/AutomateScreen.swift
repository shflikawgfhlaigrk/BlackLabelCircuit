#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — Automations & Reminders. Automations are saved instructions the on-device
// brain runs on a schedule (or on demand); their real output is logged. Reminders fire as
// native notifications. HONEST: both run only while the app is open — the UI says so plainly.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

struct AutomateScreen: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var runtime: Runtime
    @EnvironmentObject var ai: AIEngine
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var taskStore: ScheduledTaskStore
    @EnvironmentObject var scheduler: TaskScheduler
    @State private var tab = 0
    @State private var editingAuto: Automation?
    @State private var editingReminder: Reminder?
    @State private var viewingOutput: Automation?
    @State private var editingTask: ScheduledTask?
    @State private var viewingTaskOutput: ScheduledTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ScreenTitle(title: "Automations", subtitle: "Autonomous scheduled tasks, brain automations & reminders — run while Sovereign is open")
                Spacer()
                switch tab {
                case 0: GoldButton(label: "New task", icon: "plus") { editingTask = ScheduledTask() }
                case 1: GoldButton(label: "New automation", icon: "plus") { editingAuto = Automation() }
                default: GoldButton(label: "New reminder", icon: "plus") { editingReminder = Reminder() }
                }
            }.padding(24).padding(.bottom, 4)

            Picker("", selection: $tab) {
                Text("Tasks (\(taskStore.tasks.count))").tag(0)
                Text("Automations (\(store.automations.count))").tag(1)
                Text("Reminders (\(store.upcomingReminders.count))").tag(2)
            }.pickerStyle(.segmented).labelsHidden().segmentedWidth(480).padding(.horizontal, 24).padding(.bottom, 10)

            runtimeBanner

            switch tab {
            case 0: taskList
            case 1: automationList
            default: reminderList
            }
        }
        .sheet(item: $editingAuto) { a in AutomationEditor(auto: a).environmentObject(store).sheetCloseBar() }
        .sheet(item: $editingReminder) { r in ReminderEditor(reminder: r).environmentObject(store).environmentObject(runtime).sheetCloseBar() }
        .sheet(item: $viewingOutput) { a in AutomationOutput(auto: a).sheetCloseBar() }
        .sheet(item: $editingTask) { t in ScheduledTaskEditor(task: t).environmentObject(taskStore).sheetCloseBar() }
        .sheet(item: $viewingTaskOutput) { t in ScheduledTaskOutput(task: t).sheetCloseBar() }
    }

    private var runtimeBanner: some View {
        let tick = tab == 0 ? scheduler.lastTick : runtime.lastTick
        return HStack(spacing: 8) {
            Circle().fill(BLTheme.green).frame(width: 6, height: 6).shadow(color: BLTheme.green, radius: 3)
            Text((tab == 0 ? "Scheduler active" : "Runtime active") + (tick != nil ? " · last tick \(tick!.formatted(date: .omitted, time: .standard))" : ""))
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            Spacer()
            if !brain.isUsable { Label("No brain connected — tasks won't produce output", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, design: .rounded)).foregroundColor(.orange) }
        }.padding(.vertical, 7).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 24).padding(.bottom, 10)
    }

    // MARK: Scheduled Tasks (SOV-AGENT-003 — autonomous modules the buyer defines, run on schedule)
    @ViewBuilder private var taskList: some View {
        if taskStore.tasks.isEmpty {
            ScrollView {
                VStack(spacing: 16) {
                    EmptyState(icon: "bolt.badge.clock.fill", title: "No scheduled tasks yet",
                               hint: "Create an autonomous task — a prompt your operator runs on a schedule. It runs through your brain with proof-of-execution receipts and your guardrail policy. Ships empty: you define the work.")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EXAMPLES YOU CAN CREATE").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                        ForEach(Self.taskExamples, id: \.name) { ex in
                            Button { editingTask = ScheduledTask(name: ex.name, prompt: ex.prompt, schedule: ex.schedule) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus.circle.fill").foregroundColor(BLTheme.gold).font(.system(size: 13))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ex.name).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                        Text(ex.schedule.label).font(.system(size: 10, design: .monospaced)).foregroundColor(BLTheme.sub)
                                    }
                                    Spacer()
                                }.padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }.frame(maxWidth: 460)
                }.frame(maxWidth: .infinity).padding(.top, 30).padding(.horizontal, 24)
            }
        } else {
            ScrollView { LazyVStack(spacing: 10) { ForEach(taskStore.tasks) { t in taskRow(t) } }.padding(.horizontal, 24).padding(.bottom, 24) }
        }
    }

    /// Honest example tasks the buyer can one-tap create. These are NOT bundled tasks — nothing runs
    /// until the buyer creates one. They are starter templates, ship-empty preserved.
    private static let taskExamples: [(name: String, prompt: String, schedule: TaskSchedule)] = [
        ("Morning brief", "Give me a short brief for today: pull what moved on my machine, my standing memory, and anything notable. Keep it tight.", TaskSchedule(kind: .dailyAt, intervalSeconds: 3600, hour: 8, minute: 0)),
        ("Hourly inbox triage", "Review my recent context and suggest the 3 most important things I should act on next.", TaskSchedule(kind: .interval, intervalSeconds: 3600, hour: 9, minute: 0)),
        ("End-of-day recap", "Summarize what changed today from my activity and CRM pipeline. If nothing moved, say so.", TaskSchedule(kind: .dailyAt, intervalSeconds: 3600, hour: 18, minute: 0)),
    ]

    @ViewBuilder private func taskRow(_ t: ScheduledTask) -> some View {
        let isRunning = scheduler.runningTaskIDs.contains(t.id)
        HoloCard(cornerRadius: 15, sweep: t.enabled, padding: 16) {
            HStack(spacing: 14) {
                Image(systemName: "bolt.badge.clock.fill").font(.system(size: 14, weight: .bold)).foregroundColor(t.enabled ? BLTheme.ink : BLTheme.sub)
                    .frame(width: 36, height: 36).background(t.enabled ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(t.prompt).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                    HStack(spacing: 8) {
                        Label(t.schedule.label, systemImage: "clock").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.gold)
                        if t.enabled { Text("· next \(t.displayNextRun().formatted(date: .omitted, time: .shortened))").font(.system(size: 10, design: .monospaced)).foregroundColor(BLTheme.sub) }
                        if t.runCount > 0 { Text("· \(t.runCount) runs").font(.system(size: 10, design: .monospaced)).foregroundColor(BLTheme.sub) }
                        if let last = t.lastRun { Text("· last \(last.formatted(date: .omitted, time: .shortened))").font(.system(size: 10, design: .monospaced)).foregroundColor(BLTheme.sub) }
                        if let o = t.lastOutcome { Text(o.label).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(o.tint) }
                    }
                }
                Spacer()
                if isRunning { ProgressView().controlSize(.small).tint(BLTheme.gold) }
                else { GhostButton(label: "Run now", icon: "play.fill", tint: BLTheme.gold) { scheduler.runNow(t) }.disabled(!brain.isUsable) }
                Toggle("", isOn: Binding(get: { t.enabled }, set: { taskStore.setEnabled(t, $0) })).labelsHidden().tint(BLTheme.gold)
                Menu {
                    if !t.lastResult.isEmpty { Button("View last result") { viewingTaskOutput = t } }
                    Button("Edit") { editingTask = t }
                    Button("Delete", role: .destructive) { taskStore.delete(t) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.sub) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Task actions")
            }
        }
    }

    // MARK: Automations
    @ViewBuilder private var automationList: some View {
        if store.automations.isEmpty {
            Spacer()
            EmptyState(icon: "gearshape.2.fill", title: "No automations yet",
                       hint: "Create a recurring brain task — e.g. \"Draft 3 content ideas\" daily. It runs on schedule while the app is open and logs real output.")
            Spacer()
        } else {
            ScrollView { LazyVStack(spacing: 10) { ForEach(store.automations) { a in autoRow(a) } }.padding(.horizontal, 24).padding(.bottom, 24) }
        }
    }
    @ViewBuilder private func autoRow(_ a: Automation) -> some View {
        let isRunning = runtime.runningAutomationIDs.contains(a.id)
        HoloCard(cornerRadius: 15, sweep: a.enabled, padding: 16) {
            HStack(spacing: 14) {
                Image(systemName: "gearshape.2.fill").font(.system(size: 14, weight: .bold)).foregroundColor(a.enabled ? BLTheme.ink : BLTheme.sub)
                    .frame(width: 36, height: 36).background(a.enabled ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(a.instruction).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                    HStack(spacing: 8) {
                        Label(a.schedule.label, systemImage: "clock").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.gold)
                        if a.runCount > 0 { Text("· \(a.runCount) runs").font(.system(size: 10, design: .monospaced)).foregroundColor(BLTheme.sub) }
                        if let last = a.lastRun { Text("· last \(last.formatted(date: .omitted, time: .shortened))").font(.system(size: 10, design: .monospaced)).foregroundColor(BLTheme.sub) }
                    }
                }
                Spacer()
                if isRunning { ProgressView().controlSize(.small).tint(BLTheme.gold) }
                else { GhostButton(label: "Run now", icon: "play.fill", tint: BLTheme.gold) { runtime.run(a) }.disabled(!brain.isUsable) }
                Toggle("", isOn: Binding(get: { a.enabled }, set: { var x = a; x.enabled = $0; store.upsertAutomation(x) })).labelsHidden().tint(BLTheme.gold)
                Menu {
                    if !a.lastOutput.isEmpty { Button("View last output") { viewingOutput = a } }
                    Button("Edit") { editingAuto = a }
                    Button("Delete", role: .destructive) { store.deleteAutomation(a) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.sub) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Automation actions")
            }
        }
    }

    // MARK: Reminders
    @ViewBuilder private var reminderList: some View {
        if store.reminders.filter({ !$0.done }).isEmpty {
            Spacer()
            EmptyState(icon: "bell.badge.fill", title: "No reminders",
                       hint: "Add a reminder. It fires a native notification at the time you set, while the app is open. One-off or recurring.")
            Spacer()
        } else {
            ScrollView { LazyVStack(spacing: 10) {
                // The in-app record of real fires this session — the visible counterpart of each
                // notification (and the whole record when notifications aren't authorized).
                if !runtime.firedReminderTitles.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.and.waves.left.and.right.fill").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.gold)
                        Text("Fired this session: " + runtime.firedReminderTitles.prefix(3).joined(separator: " · "))
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(2)
                        Spacer()
                    }
                }
                ForEach(store.upcomingReminders) { r in reminderRow(r) }
            }.padding(.horizontal, 24).padding(.bottom, 24) }
        }
    }
    @ViewBuilder private func reminderRow(_ r: Reminder) -> some View {
        let overdue = r.fireAt < Date()
        HStack(spacing: 14) {
            Image(systemName: "bell.fill").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.ink)
                .frame(width: 34, height: 34).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title.isEmpty ? "Reminder" : r.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                HStack(spacing: 6) {
                    Text(r.fireAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11, design: .monospaced)).foregroundColor(overdue ? .orange : BLTheme.sub)
                    if r.repeats != .once { Label(r.repeats.label, systemImage: "repeat").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.gold) }
                    if overdue { Text("· due").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(.orange) }
                }
            }
            Spacer()
            GhostButton(label: "Fire now", icon: "bell.badge", tint: BLTheme.gold) { runtime.fireNow(r) }
            Button { editingReminder = r } label: { Image(systemName: "pencil").font(.system(size: 12)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Edit reminder")
            Button { store.deleteReminder(r) } label: { Image(systemName: "trash").font(.system(size: 12)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Delete reminder")
        }
        .padding(14).background(BLTheme.panelGrad).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(overdue ? Color.orange.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
    }
}

// MARK: - Editors
struct AutomationEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var auto: Automation
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(auto.name == "Untitled automation" || auto.name.isEmpty ? "New automation" : "Edit automation").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Field(title: "Name", text: $auto.name, prompt: "e.g. Daily content ideas")
            VStack(alignment: .leading, spacing: 4) {
                Text("INSTRUCTION (what the brain should do each run)").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $auto.instruction).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 100).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            }
            HStack {
                Text("SCHEDULE").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                Picker("", selection: $auto.schedule) { ForEach(ReminderRepeat.allCases) { Text($0.label).tag($0) } }.labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                Spacer()
                Toggle(isOn: $auto.groundOnKnowledge) { Text("Use knowledge base").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text) }.tint(BLTheme.gold)
            }
            Toggle(isOn: $auto.enabled) { Text("Enabled (runs on schedule while the app is open)").font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text) }.tint(BLTheme.gold)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                GoldButton(label: "Save", icon: "checkmark") {
                    guard !auto.name.trimmingCharacters(in: .whitespaces).isEmpty, !auto.instruction.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    store.upsertAutomation(auto); dismiss()
                }
            }
        }.padding(24).keyboardDismissable().sheetWidth(560).background(BLTheme.bg)
    }
}

struct ReminderEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var runtime: Runtime
    @Environment(\.dismiss) var dismiss
    @State var reminder: Reminder
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(reminder.title.isEmpty ? "New reminder" : "Edit reminder").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Field(title: "Title", text: $reminder.title, prompt: "What to remember")
            DatePicker("Fire at", selection: $reminder.fireAt).datePickerStyle(.compact).tint(BLTheme.gold)
                .font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
            HStack {
                Text("REPEAT").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                Picker("", selection: $reminder.repeats) { ForEach(ReminderRepeat.allCases) { Text($0.label).tag($0) } }.labelsHidden().pickerStyle(.segmented)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                GoldButton(label: "Save", icon: "checkmark") {
                    guard !reminder.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    reminder.done = false; store.upsertReminder(reminder)
                    // Saving a reminder is the moment notifications become real: ask now, in
                    // context, so due reminders can post a system notification instead of the
                    // beep-only fallback. (macOS remembers the answer; no re-prompt after this.)
                    runtime.requestNotificationAuth()
                    dismiss()
                }
            }
        }.padding(24).keyboardDismissable().sheetWidth(460).background(BLTheme.bg)
    }
}

struct AutomationOutput: View {
    let auto: Automation
    @Environment(\.dismiss) var dismiss
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(auto.name).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(auto.lastOutput, forType: .string); copied = true } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(copied ? BLTheme.green : BLTheme.sub)
                }.buttonStyle(.plain)
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Close")
            }
            if let last = auto.lastRun { Text("Last run \(last.formatted())").font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.sub) }
            ScrollView { MarkdownView(text: auto.lastOutput).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 320).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
        }.padding(24).keyboardDismissable().sheetWidth(600).background(BLTheme.bg)
    }
}

// MARK: - Scheduled Task editor + output

struct ScheduledTaskEditor: View {
    @EnvironmentObject var taskStore: ScheduledTaskStore
    @Environment(\.dismiss) var dismiss
    @State var task: ScheduledTask

    private static let intervalPresets: [(label: String, seconds: Int)] = [
        ("Every 15 minutes", 900), ("Every 30 minutes", 1800), ("Every hour", 3600),
        ("Every 3 hours", 10800), ("Every 6 hours", 21600), ("Every 12 hours", 43200), ("Every 24 hours", 86400)
    ]

    /// Bridge the schedule's hour/minute to a DatePicker without a separate @State (no drift).
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents(); c.hour = task.schedule.hour; c.minute = task.schedule.minute
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                task.schedule.hour = c.hour ?? 9
                task.schedule.minute = c.minute ?? 0
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(task.name.trimmingCharacters(in: .whitespaces).isEmpty ? "New task" : "Edit task")
                .font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Field(title: "Name", text: $task.name, prompt: "e.g. Morning brief")
            VStack(alignment: .leading, spacing: 4) {
                Text("PROMPT (what your operator should do each run)").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $task.prompt).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 100).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            }
            Text("SCHEDULE").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
            Picker("", selection: $task.schedule.kind) {
                ForEach(TaskSchedule.Kind.allCases) { Text($0.label).tag($0) }
            }.labelsHidden().pickerStyle(.segmented)
            if task.schedule.kind == .interval {
                Picker("Interval", selection: $task.schedule.intervalSeconds) {
                    ForEach(Self.intervalPresets, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }.pickerStyle(.menu).tint(BLTheme.gold)
            } else {
                DatePicker("Run at", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact).tint(BLTheme.gold)
                    .font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
            }
            Toggle(isOn: $task.enabled) { Text("Enabled (runs on schedule while the app is open)").font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text) }.tint(BLTheme.gold)
            Text("Runs through your connected brain. On the local Ornith/Ollama route it generates text; tool-capable routes write proof-of-execution receipts. On unattended runs, confirmation-gated side-effects are auto-declined unless your safety posture is Autonomous.")
                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                GoldButton(label: "Save", icon: "checkmark") {
                    guard task.isValid else { return }
                    if task.schedule.kind == .interval && task.schedule.intervalSeconds < TaskSchedule.minInterval {
                        task.schedule.intervalSeconds = 3600
                    }
                    task.nextRun = task.schedule.nextFireDate(after: Date())
                    taskStore.upsert(task); dismiss()
                }
            }
        }.padding(24).keyboardDismissable().sheetWidth(560).background(BLTheme.bg)
    }
}

struct ScheduledTaskOutput: View {
    let task: ScheduledTask
    @Environment(\.dismiss) var dismiss
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(task.name).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(task.lastResult, forType: .string); copied = true } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(copied ? BLTheme.green : BLTheme.sub)
                }.buttonStyle(.plain)
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Close")
            }
            HStack(spacing: 8) {
                if let last = task.lastRun { Text("Last run \(last.formatted())").font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.sub) }
                if let o = task.lastOutcome { Text("· \(o.label)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(o.tint) }
            }
            ScrollView { MarkdownView(text: task.lastResult).padding(14).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 320).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
        }.padding(24).keyboardDismissable().sheetWidth(600).background(BLTheme.bg)
    }
}
#endif // circuit-convert
