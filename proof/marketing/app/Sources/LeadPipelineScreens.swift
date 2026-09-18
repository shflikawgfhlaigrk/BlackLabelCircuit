#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — pipeline / outreach screens surfaced by the 2026-07 Leads merge.
// These wire the ported engines (deal Kanban, outreach sequences, IMAP inbox, the real
// send runner, and the RBAC team) onto Marketing's own design system. Everything reads the
// buyer's OWN unified Lead pool; honest empty states, nothing fabricated, no real send in demo.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Deal pipeline (Kanban over the buyer's stages)

struct DealPipelineScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var leadEngine: LeadEngineStore
    @State private var toast = ""

    private var stages: [DealStage] { leadEngine.settings.stages }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Pipeline", subtitle: "Track every opportunity through your own stages — real deals, real values, no invented numbers.")
                if model.deals.isEmpty {
                    Panel(title: "No deals yet", icon: "chart.bar.doc.horizontal") {
                        EmptyState(icon: "rectangle.stack.badge.plus", title: "Your pipeline is empty",
                                   hint: "Add a lead in Leads, then create a deal on it. Deals you open here move across the stages you define in Settings → Pipeline.")
                        if !model.leads.isEmpty {
                            GoldButton(label: "Open deals for every lead", icon: "wand.and.stars") {
                                let n = model.backfillMissingDeals(stages: stages)
                                toast = n == 0 ? "Every lead already has a deal." : "Opened \(n) deal\(n == 1 ? "" : "s")."
                            }
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(stages) { stage in stageColumn(stage) }
                        }
                    }
                    Panel(title: "Pipeline value", icon: "dollarsign.circle.fill") {
                        let open = model.deals.filter { d in stages.first { $0.id == d.stageID }?.terminal == DealStage.TerminalKind.open }
                        Text("\(open.count) open deal\(open.count == 1 ? "" : "s") · \(currency(open.reduce(0) { $0 + $1.value })) in flight")
                            .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }
                if !toast.isEmpty { Text(toast).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold) }
            }
            .padding(28)
        }
    }

    @ViewBuilder private func stageColumn(_ stage: DealStage) -> some View {
        let deals = model.deals.filter { $0.stageID == stage.id }.sorted { $0.sort < $1.sort }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(stage.color).frame(width: 9, height: 9)
                Text(stage.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("\(deals.count)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            ForEach(deals) { deal in dealCard(deal, stage: stage) }
            if deals.isEmpty {
                Text("—").font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub).padding(.vertical, 8)
            }
        }
        .padding(12).frame(width: 220, alignment: .leading)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func dealCard(_ deal: Deal, stage: DealStage) -> some View {
        let lead = model.prospect(deal.prospectID)
        VStack(alignment: .leading, spacing: 4) {
            Text(deal.title.isEmpty ? (lead?.displayName ?? "Untitled deal") : deal.title)
                .font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
            if deal.value > 0 {
                Text(currency(deal.value)).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
            }
            HStack(spacing: 6) {
                ForEach(moveTargets(from: stage), id: \.id) { target in
                    Button { model.moveDeal(deal, to: target.id, stages: stages) } label: {
                        Image(systemName: "arrow.right.circle").font(.system(size: 13)).foregroundColor(BLTheme.sub)
                    }.buttonStyle(.plain).help("Move to \(target.name)")
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 9))
    }

    /// The next stage (single-step move keeps the UI simple + honest).
    private func moveTargets(from stage: DealStage) -> [DealStage] {
        guard let i = stages.firstIndex(where: { $0.id == stage.id }), i + 1 < stages.count else { return [] }
        return [stages[i + 1]]
    }
    private func currency(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "$\(Int(v))"
    }
}

// MARK: - Outreach sequences (cadence templates the runner executes)

struct SequencesScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var leadEngine: LeadEngineStore
    @State private var runReport = ""
    @State private var running = false
    @State private var enrollFor: OutreachSequence?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Sequences", subtitle: "Multi-step cold outreach with A/B subjects, warmup caps, and auto-stop on reply — sent from your own mailbox, gated for deliverability.")

                Panel(title: "Send runner", icon: "paperplane.fill") {
                    let due = SequenceRunner.dueCount(model: model)
                    Text(due == 0 ? "No steps are due right now."
                                  : "\(due) step\(due == 1 ? "" : "s") due to send.")
                        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    HStack(spacing: 10) {
                        GhostButton(label: "Preview (dry run)", icon: "eye") { Task { await run(dryRun: true) } }
                        GoldButton(label: running ? "Sending…" : "Send due now", icon: "paperplane.fill") { Task { await run(dryRun: false) } }
                            .disabled(running || due == 0)
                    }
                    if !runReport.isEmpty {
                        Text(runReport).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.gold)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if model.sequences.isEmpty {
                    Panel(title: "No sequences yet", icon: "arrow.triangle.branch") {
                        EmptyState(icon: "arrow.triangle.branch", title: "Build your first cadence",
                                   hint: "A sequence is an ordered set of emails with day delays. Enroll leads and the runner sends each step from your own mailbox, stopping automatically when someone replies.")
                        GoldButton(label: "Add a 3-touch starter", icon: "plus") {
                            model.upsertSequence(OutreachSequence.starter())
                        }
                    }
                } else {
                    Panel(title: "Sequences (\(model.sequences.count))", icon: "arrow.triangle.branch") {
                        VStack(spacing: 8) { ForEach(model.sequences) { seq in sequenceRow(seq) } }
                    }
                }
            }
            .padding(28)
        }
        .sheet(item: $enrollFor) { seq in
            EnrollLeadsSheet(sequence: seq).environmentObject(model).sheetCloseBar()
        }
    }

    @ViewBuilder private func sequenceRow(_ seq: OutreachSequence) -> some View {
        let live = model.enrollments.filter { $0.sequenceID == seq.id && $0.status.isOpen }.count
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(seq.name).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("\(seq.stepCount) step\(seq.stepCount == 1 ? "" : "s") · \(seq.spanDays)-day span · \(live) active")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            if seq.stopOnReply { pill("stops on reply") }
            GhostButton(label: "Enroll leads", icon: "person.badge.plus") { enrollFor = seq }
            IconButton(system: "trash", tint: BLTheme.danger) { model.deleteSequence(seq) }
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func pill(_ s: String) -> some View {
        Text(s).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
            .padding(.vertical, 3).padding(.horizontal, 7).background(BLTheme.green.opacity(0.14)).clipShape(Capsule())
    }

    private func run(dryRun: Bool) async {
        running = true; defer { running = false }
        let report = await SequenceRunner.runDue(model: model, settings: leadEngine.settings, dryRun: dryRun)
        var lines = ["\(dryRun ? "Would send" : "Sent") \(report.sent) · blocked \(report.blocked) · skipped \(report.skipped) · stopped \(report.stopped)"]
        lines += report.messages.prefix(6)
        runReport = lines.joined(separator: "\n")
    }
}

// MARK: - Enroll leads into a sequence (wires the CRM enroll path to a real buyer UI)
/// Pick leads that have an email and aren't already in an open sequence, then enroll them so the
/// Send runner has steps to send. Enrollment only QUEUES — the actual send stays gated by the
/// deliverability checks and the buyer's own mailbox (nothing is sent from here).
struct EnrollLeadsSheet: View {
    let sequence: OutreachSequence
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var result = ""

    /// Eligible = has an email address AND isn't already in an open enrollment anywhere.
    private var eligible: [Lead] {
        model.leads.filter { !$0.email.isEmpty && model.enrollment(for: $0.id) == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enroll leads").font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(sequence.name).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                IconButton(system: "xmark", tint: BLTheme.sub) { dismiss() }
            }
            .padding(18)
            Divider().background(BLTheme.stroke)

            if eligible.isEmpty {
                EmptyState(icon: "person.crop.circle.badge.questionmark",
                           title: "No leads ready to enroll",
                           hint: "A lead needs an email address and can't already be in another sequence. Add leads with emails in Leads or Find Clients, then come back here.")
                    .padding(28)
            } else {
                HStack {
                    Button(selected.count == eligible.count ? "Clear all" : "Select all") {
                        selected = selected.count == eligible.count ? [] : Set(eligible.map { $0.id })
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                    Spacer()
                    Text("\(selected.count) of \(eligible.count) selected").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                .padding(.horizontal, 18).padding(.vertical, 10)

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(eligible) { lead in
                            Button { toggle(lead.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selected.contains(lead.id) ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(selected.contains(lead.id) ? BLTheme.gold : BLTheme.sub)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(lead.displayName).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                        Text(lead.email).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                                    }
                                    Spacer()
                                }
                                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .frame(maxHeight: 320)

                Divider().background(BLTheme.stroke)
                HStack(spacing: 10) {
                    if !result.isEmpty {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    GoldButton(label: selected.isEmpty ? "Enroll leads" : "Enroll \(selected.count)", fill: true, icon: "paperplane.fill") { enroll() }
                        .opacity(selected.isEmpty ? 0.5 : 1).disabled(selected.isEmpty)
                }
                .padding(18)
            }
        }
        #if os(macOS)
        .frame(width: 470)
        #else
        .frame(maxWidth: .infinity)
        #endif
        .background(BLTheme.bg)
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    private func enroll() {
        let added = model.enroll(Array(selected), in: sequence, mailboxID: nil)
        selected = []
        if added == 0 {
            result = (sequence.steps.isEmpty || !sequence.active)
                ? "This sequence has no active steps yet — add steps before enrolling."
                : "No new leads were enrolled."
        } else {
            result = added == 1 ? "Enrolled 1 lead — the runner sends each step when it's due."
                                : "Enrolled \(added) leads — the runner sends each step when it's due."
        }
    }
}

// MARK: - Inbox (IMAP reply detection over the buyer's own mailbox)

struct InboxScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var leadEngine: LeadEngineStore
    @State private var status = ""
    @State private var syncing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Inbox", subtitle: "Read-only reply and bounce detection on your own mailbox — folds real replies back into the pipeline and stops sequences automatically.")

                if !leadEngine.settings.imapEnabled {
                    Panel(title: "Connect your inbox", icon: "envelope.badge") {
                        EmptyState(icon: "tray.and.arrow.down", title: "Reply detection is off",
                                   hint: "Turn on IMAP in Connectors → Inbox with your own mailbox host and username. We only read envelopes to detect replies and bounces — never send from here.")
                    }
                } else {
                    Panel(title: "Sync", icon: "arrow.clockwise") {
                        GoldButton(label: syncing ? "Checking…" : "Check for replies", icon: "arrow.clockwise") {
                            Task { await sync() }
                        }.disabled(syncing)
                        if !status.isEmpty { Text(status).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.gold) }
                    }
                }

                if model.inbox.isEmpty {
                    Panel(title: "No messages yet", icon: "tray") {
                        EmptyState(icon: "tray", title: "Nothing here yet",
                                   hint: "Detected replies and bounces from your own mailbox will appear here after a sync.")
                    }
                } else {
                    Panel(title: "Recent (\(model.inbox.count))", icon: "tray.full") {
                        VStack(spacing: 8) { ForEach(model.inbox.prefix(40)) { msg in inboxRow(msg) } }
                    }
                }
            }
            .padding(28)
        }
    }

    @ViewBuilder private func inboxRow(_ msg: InboxMessage) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(msg.fromName.isEmpty ? msg.fromEmail : msg.fromName)
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(msg.subject.isEmpty ? "(no subject)" : msg.subject)
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
            }
            Spacer()
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func sync() async {
        syncing = true; defer { syncing = false }
        let r = await InboxSync.run(model: model, settings: leadEngine.settings)
        status = r.message
    }
}

// MARK: - Team (RBAC — owner + members, lead scoping)

struct TeamScreen: View {
    @EnvironmentObject var team: TeamStore
    @State private var newName = ""
    @State private var newEmail = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Team", subtitle: "Add teammates and control who can see and act on which leads. You are the owner; nothing is locked until you add members.")
                Panel(title: "Members (\(team.workspace.members.count))", icon: "person.2.fill") {
                    VStack(spacing: 8) { ForEach(team.workspace.members) { m in memberRow(m) } }
                }
                Panel(title: "Add a teammate", icon: "person.badge.plus") {
                    Field(title: "Name", text: $newName)
                    Field(title: "Email", text: $newEmail)
                    GoldButton(label: "Add as Rep", icon: "plus") {
                        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        team.addMember(name: newName, email: newEmail, role: .rep)
                        newName = ""; newEmail = ""
                    }
                }
            }
            .padding(28)
        }
    }

    @ViewBuilder private func memberRow(_ m: WorkspaceMember) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name.isEmpty ? "(unnamed)" : m.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("\(m.role.label)\(m.isOwner ? " · owner" : "")").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            if !m.isOwner {
                IconButton(system: "trash", tint: BLTheme.danger) { team.removeMember(m.id) }
            }
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
#endif // circuit-convert
