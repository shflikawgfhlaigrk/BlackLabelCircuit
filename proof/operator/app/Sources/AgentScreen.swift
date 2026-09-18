#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — the Agent screen: multi-step plan → act → verify, with a live receipt trail.
//
// This is where the assistant pursues a GOAL across steps instead of answering one prompt. It
// shows every real step — the agent's reasoning, each tool it actually ran, the actual result
// it got back, and the verified final answer. Nothing is shown as done unless a tool returned a
// result (true proof-of-execution). Runs on the buyer's External account (tools need it); when
// that isn't connected the screen says so honestly and offers the fix.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct AgentScreen: View {
    @EnvironmentObject var agent: AgentEngine
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var op: OperatorEngine
    @State private var goal = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            // The autonomy dial and pause control drive the macOS Accessibility operator; on iOS
            // every operator run reports "needs the macOS app", so the bar would be dead weight
            // implying a capability the platform lacks.
            #if os(macOS)
            operatorBar
            if !op.trace.isEmpty { operatorTrace }
            #endif
            if case .unavailable(let reason) = agent.status { unavailable(reason) }
            if let p = agent.pendingApproval { approvalBanner(p) }
            transcript
            composer
        }
        .onAppear { brain.resolve(); op.dial = settings.approvalDial }
        .onChange(of: settings.approvalDial) { op.dial = $0 }
    }

    // SV-15 — the top-level operator autonomy dial (Manual/Auto/Skip) mapped onto the shared grant
    // engine, plus a Pause/Resume control that genuinely HOLDS mutating operator steps.
    private var operatorBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.rays").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.gold)
            Text("Operator").font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Picker("", selection: Binding(get: { settings.approvalDial },
                                          set: { settings.approvalDial = $0; op.dial = $0 })) {
                ForEach(ApprovalDial.allCases) { d in Text(d.label).tag(d) }
            }.labelsHidden().pickerStyle(.segmented).frame(width: 220).tint(settings.accent)
            Spacer()
            Button { op.isPaused.toggle() } label: {
                Label(op.isPaused ? "Resume" : "Pause", systemImage: op.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(op.isPaused ? BLTheme.green : BLTheme.sub)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.bottom, 6)
        .help(settings.approvalDial.blurb)
    }

    // The live, pausable action/reasoning trace over the operator's real step receipts. Each row is
    // a genuine proposed/performed/blocked step — nothing narrated.
    private var operatorTrace: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("OPERATOR TRACE").font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.sub).tracking(0.6)
                if op.isPaused { Text("PAUSED").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.gold).padding(.vertical, 1).padding(.horizontal, 5).background(BLTheme.gold.opacity(0.15)).clipShape(Capsule()) }
                Spacer()
                Button("Clear") { op.clearTrace() }.buttonStyle(.plain).font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.mute)
            }
            ForEach(op.trace) { step in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(traceTint(step.decision)).frame(width: 6, height: 6).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(step.kind.verb) · \(step.element.bestLabel)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text(step.result).font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
        .padding(.horizontal, 20).padding(.bottom, 6)
    }

    private func traceTint(_ d: OperatorDecision) -> Color {
        if d.isBlock { return BLTheme.danger }
        if d.isConfirm { return BLTheme.gold }
        return BLTheme.green
    }

    /// Confirmation gate for side-effect / external tools (save_note, fetch_url). The agent loop
    /// is suspended until the buyer approves or declines — nothing happens without their OK.
    @ViewBuilder private func approvalBanner(_ p: PendingToolApproval) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundColor(BLTheme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("The agent wants to run \(p.toolName)").font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(p.summary).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            GhostButton(label: "Decline", icon: "xmark", tint: BLTheme.danger) { agent.resolveApproval(false) }
            GoldButton(label: "Approve", icon: "checkmark") { agent.resolveApproval(true) }
        }
        .padding(14).background(BLTheme.gold.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.gold.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 20).padding(.bottom, 4)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("Plan → act → verify, with a real receipt for every step").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            statusPill
            Spacer()
            if isRunning {
                GhostButton(label: "Stop", icon: "stop.fill", tint: BLTheme.danger) { agent.cancel() }
            }
        }.padding(20).padding(.bottom, 6)
    }

    private var isRunning: Bool {
        switch agent.status { case .planning, .acting, .verifying, .awaitingConfirmation: return true; default: return false }
    }

    @ViewBuilder private var statusPill: some View {
        switch agent.status {
        case .idle: StatusPill(text: "Ready", tint: BLTheme.sub)
        case .planning: StatusPill(text: "Planning", tint: BLTheme.gold)
        case .acting: StatusPill(text: "Acting", tint: BLTheme.gold)
        case .verifying: StatusPill(text: "Verifying", tint: BLTheme.gold)
        case .awaitingConfirmation: StatusPill(text: "Awaiting your OK", tint: BLTheme.gold)
        case .done: StatusPill(text: "Done", tint: BLTheme.green)
        case .failed: StatusPill(text: "Failed", tint: BLTheme.danger)
        case .unavailable: StatusPill(text: "Needs brain", tint: .orange)
        }
    }

    @ViewBuilder private func unavailable(_ reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(reason).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            Spacer()
            GhostButton(label: "Open Settings", icon: "gearshape.fill", tint: BLTheme.gold) { nav.go(.settings) }
        }
        .padding(14).background(Color.orange.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 20).padding(.bottom, 4)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if agent.steps.isEmpty {
                        EmptyState(icon: "point.3.connected.trianglepath.dotted", title: "Give the agent a goal",
                                   hint: "Describe what you want done. The agent will search your Knowledge, recall your Memory, and verify before answering — and show you every real step it took.")
                        .padding(.top, 50)
                        starters
                    }
                    ForEach(agent.steps) { step in stepRow(step).id(step.id) }
                }.padding(.horizontal, 20).padding(.vertical, 14)
            }
            .onChange(of: agent.steps.count) { _ in
                if let last = agent.steps.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var starters: some View {
        // Three long sentences fit the wide mac canvas; a 390pt phone needs them to scroll
        // sideways instead of compressing into tall multi-line slivers.
        #if os(iOS)
        ScrollView(.horizontal, showsIndicators: false) { starterRow }.padding(.top, 8)
        #else
        starterRow.padding(.top, 8)
        #endif
    }
    private var starterRow: some View {
        HStack(spacing: 10) {
            ForEach(["What's on my calendar this week?", "Find my notes on this and brief me", "Search my files for the spec and summarize it"], id: \.self) { s in
                Button { goal = s; focused = true } label: {
                    Text(s).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                        .padding(.vertical, 8).padding(.horizontal, 13).background(BLTheme.bg2).clipShape(Capsule())
                        .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func stepRow(_ step: AgentStep) -> some View {
        let (icon, tint, label) = style(step.kind)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundColor(tint)
                .frame(width: 26, height: 26).background(tint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(step.title).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(label).font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundColor(tint).tracking(0.5)
                        .padding(.vertical, 1).padding(.horizontal, 5).background(tint.opacity(0.12)).clipShape(Capsule())
                    Spacer()
                    Text(step.at.formatted(date: .omitted, time: .standard)).font(.system(size: 9, design: .monospaced)).foregroundColor(BLTheme.mute)
                }
                if step.kind == .answer {
                    MarkdownView(text: step.detail)
                } else {
                    Text(step.detail).font(.system(size: 12, design: step.kind == .toolResult ? .monospaced : .rounded))
                        .foregroundColor(BLTheme.sub).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(13).background(BLTheme.panelGrad).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(step.kind == .answer ? BLTheme.gold.opacity(0.35) : BLTheme.stroke, lineWidth: 1))
    }

    private func style(_ k: AgentStep.Kind) -> (String, Color, String) {
        switch k {
        case .thought: return ("brain", BLTheme.sub, "THINK")
        case .toolCall: return ("hammer.fill", BLTheme.gold, "CALL")
        case .toolResult: return ("checkmark.seal.fill", BLTheme.green, "RESULT")
        case .answer: return ("sparkles", BLTheme.gold, "ANSWER")
        case .error: return ("exclamationmark.triangle.fill", BLTheme.danger, "ERROR")
        case .awaitingConfirm: return ("hand.raised.fill", BLTheme.gold, "CONFIRM")
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Give the agent a goal…", text: $goal, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14, design: .rounded)).foregroundColor(BLTheme.text)
                .lineLimit(1...4).padding(.vertical, 11).padding(.horizontal, 14)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? BLTheme.gold.opacity(0.5) : BLTheme.stroke, lineWidth: 1))
                .focused($focused).onSubmit(run)
            GoldButton(label: "Run", icon: "play.fill") { run() }
        }.padding(20).padding(.top, 0)
    }

    private func run() {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty, !isRunning else { return }
        agent.run(goal: g)
    }
}
#endif // circuit-convert
