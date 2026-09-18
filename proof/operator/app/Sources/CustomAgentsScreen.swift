#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — MY AGENTS: the custom agent builder + runner (tier-4).
//
// The buyer defines an agent in their own words — a name, what it's for, and which safe local
// tools it may use — then runs it through the SAME real plan→act→verify loop the built-in agent
// uses, with the same live receipts and the same confirmation gates. Everything persists locally.
// Nothing about an agent is fabricated; it is exactly what the buyer wrote.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

struct CustomAgentsScreen: View {
    @EnvironmentObject var customAgents: CustomAgentStore
    @EnvironmentObject var agent: AgentEngine
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var nav: Nav
    @State private var editing: CustomAgent?
    @State private var running: CustomAgent?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ScreenTitle(title: "My Agents", subtitle: brain.isAgentCapable
                            ? "Build agents with explicit tools, confirmation gates, and real execution receipts"
                            : "Local text-only mode uses safe read-only context receipts; connected actions require a tool-capable brain")
                Spacer()
                GoldButton(label: "New agent", icon: "plus") { editing = CustomAgent() }
            }.padding(24).padding(.bottom, 4)

            if !brain.isAgentRunnable {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(brain.agentUnavailableReason)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    GhostButton(label: "Open Settings", icon: "gearshape.fill", tint: BLTheme.gold) { nav.go(.settings) }
                }.padding(14).background(Color.orange.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
                .padding(.horizontal, 24).padding(.bottom, 8)
            } else if !brain.isAgentCapable {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundColor(BLTheme.gold)
                    Text(brain.agentLimitedReason)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    GhostButton(label: "Open Settings", icon: "gearshape.fill", tint: BLTheme.gold) { nav.go(.settings) }
                }.padding(14).background(BLTheme.gold.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.gold.opacity(0.35), lineWidth: 1))
                .padding(.horizontal, 24).padding(.bottom, 8)
            }

            if customAgents.agents.isEmpty {
                Spacer()
                EmptyState(icon: "person.2.badge.gearshape.fill", title: "No agents yet",
                           hint: brain.isAgentCapable
                           ? "Create one and choose its tools. Every real step and confirmation is shown."
                           : "Create a local text-only agent for read-only memory and knowledge context. Connect a tool-capable provider or local model before expecting actions.")
                Spacer()
            } else {
                ScrollView { LazyVStack(spacing: 12) { ForEach(customAgents.agents) { a in agentRow(a) } }.padding(.horizontal, 24).padding(.bottom, 24) }
            }
        }
        .sheet(item: $editing) { a in CustomAgentEditor(agent: a).environmentObject(customAgents).sheetCloseBar() }
        .sheet(item: $running) { a in CustomAgentRunner(agent: a).environmentObject(agent).environmentObject(brain).environmentObject(settings).environmentObject(nav).sheetCloseBar() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func agentRow(_ a: CustomAgent) -> some View {
        HoloCard(cornerRadius: 15, sweep: false, padding: 16) {
            HStack(spacing: 14) {
                Image(systemName: a.icon).font(.system(size: 15, weight: .bold)).foregroundColor(BLTheme.ink)
                    .frame(width: 38, height: 38).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.trimmedName).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(a.blurb.isEmpty ? String(a.instructions.prefix(80)) : a.blurb)
                        .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(a.tools) { t in
                            Label(t.label, systemImage: t.icon).font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                .foregroundColor(BLTheme.gold).padding(.vertical, 2).padding(.horizontal, 6)
                                .background(BLTheme.gold.opacity(0.12)).clipShape(Capsule())
                        }
                    }
                }
                Spacer()
                GhostButton(label: "Run", icon: "play.fill", tint: BLTheme.gold) { running = a }.disabled(!brain.isAgentRunnable)
                Menu {
                    Button("Edit") { editing = a }
                    Button("Delete", role: .destructive) { customAgents.delete(a) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.sub) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Agent actions")
            }
        }
    }
}

// MARK: - Editor (define an agent in plain language)
struct CustomAgentEditor: View {
    @EnvironmentObject var customAgents: CustomAgentStore
    @Environment(\.dismiss) var dismiss
    @State var agent: CustomAgent

    private let icons = ["person.crop.circle.badge.checkmark", "brain.head.profile", "magnifyingglass.circle.fill",
                         "calendar.badge.clock", "folder.badge.gearshape", "newspaper.fill", "lightbulb.fill", "doc.text.magnifyingglass"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(agent.isValid && customAgents.agents.contains(where: { $0.id == agent.id }) ? "Edit agent" : "New agent")
                    .font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)

                Field(title: "Name", text: $agent.name, prompt: "e.g. Morning Briefer")
                Field(title: "One-liner (optional)", text: $agent.blurb, prompt: "What this agent is for")

                VStack(alignment: .leading, spacing: 4) {
                    Text("INSTRUCTIONS (its role — write it in plain language)").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    TextEditor(text: $agent.instructions).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                        .scrollContentBackground(.hidden).padding(8).frame(height: 120).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("TOOLS THIS AGENT MAY USE").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    ForEach(AgentTool.allCases) { t in toolToggle(t) }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("ICON").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    HStack(spacing: 8) {
                        ForEach(icons, id: \.self) { ic in
                            Button { agent.icon = ic } label: {
                                Image(systemName: ic).font(.system(size: 14, weight: .bold)).foregroundColor(agent.icon == ic ? BLTheme.ink : BLTheme.sub)
                                    .frame(width: 34, height: 34).background(agent.icon == ic ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                    GoldButton(label: "Save agent", icon: "checkmark") {
                        guard agent.isValid else { return }
                        if agent.tools.isEmpty { agent.tools = [.searchKnowledge, .recallMemory] }
                        customAgents.upsert(agent); dismiss()
                    }
                }
            }.padding(24).keyboardDismissable().sheetWidth(580)
        }.frame(maxHeight: 720).background(BLTheme.bg)
    }

    @ViewBuilder private func toolToggle(_ t: AgentTool) -> some View {
        let on = agent.tools.contains(t)
        Button {
            if on { agent.tools.removeAll { $0 == t } } else { agent.tools.append(t) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: t.icon).font(.system(size: 12, weight: .bold)).foregroundColor(on ? BLTheme.ink : BLTheme.sub)
                    .frame(width: 30, height: 30).background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(t.label).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        if t.requiresConfirmation { Text("ASK").font(.system(size: 7.5, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.gold).padding(.vertical, 1).padding(.horizontal, 4).background(BLTheme.gold.opacity(0.15)).clipShape(Capsule()) }
                    }
                    Text(t.blurb).font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundColor(on ? BLTheme.green : BLTheme.sub)
            }.padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? BLTheme.gold.opacity(0.3) : BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

// MARK: - Runner (runs the custom agent through the real AgentEngine, with receipts + confirm gates)
struct CustomAgentRunner: View {
    let agent: CustomAgent
    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var nav: Nav
    @Environment(\.dismiss) var dismiss
    @State private var goal = ""

    private var isRunning: Bool {
        switch engine.status { case .planning, .acting, .verifying, .awaitingConfirmation: return true; default: return false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: agent.icon).font(.system(size: 14, weight: .bold)).foregroundColor(BLTheme.ink)
                    .frame(width: 32, height: 32).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.trimmedName).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(agent.blurb.isEmpty ? "Custom agent" : agent.blurb).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                if isRunning { GhostButton(label: "Stop", icon: "stop.fill", tint: BLTheme.danger) { engine.cancel() } }
                Button { engine.cancel(); dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Cancel and close")
            }.padding(18)

            // Honest failure surface (dogfood 2026-07-03): pressing Run with no tool-capable brain
            // set engine.status = .unavailable but this sheet never showed it — the button felt
            // DEAD. Render the reason + the way out, mirroring AgentScreen's banner.
            if case .unavailable(let reason) = engine.status {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(reason).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    GhostButton(label: "Open Settings", icon: "gearshape.fill", tint: BLTheme.gold) { dismiss(); nav.go(.settings) }
                }
                .padding(12).background(Color.orange.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.orange.opacity(0.35), lineWidth: 1))
                .padding(.horizontal, 18).padding(.bottom, 6)
            }

            if let p = engine.pendingApproval {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").foregroundColor(BLTheme.gold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wants to run \(p.toolName)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text(p.summary).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    GhostButton(label: "Decline", icon: "xmark", tint: BLTheme.danger) { engine.resolveApproval(false) }
                    GoldButton(label: "Approve", icon: "checkmark") { engine.resolveApproval(true) }
                }.padding(12).background(BLTheme.gold.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.gold.opacity(0.4), lineWidth: 1)).padding(.horizontal, 18).padding(.bottom, 6)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if engine.steps.isEmpty {
                            EmptyState(icon: agent.icon, title: "Give \(agent.trimmedName) a goal",
                                       hint: "It will use only the tools you granted, and show every real step.").padding(.top, 30)
                        }
                        ForEach(engine.steps) { s in AgentStepRow(step: s).id(s.id) }
                    }.padding(.horizontal, 18).padding(.vertical, 12)
                }
                .onChange(of: engine.steps.count) { _ in
                    if let last = engine.steps.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }.frame(minHeight: 280)

            HStack(spacing: 10) {
                TextField("What should \(agent.trimmedName) do…", text: $goal, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13.5, design: .rounded)).foregroundColor(BLTheme.text)
                    .lineLimit(1...3).padding(.vertical, 10).padding(.horizontal, 13).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1)).onSubmit(run)
                GoldButton(label: "Run", icon: "play.fill") { run() }
            }.padding(18).padding(.top, 0)
        }
        #if os(macOS)
        .frame(width: 640, height: 560).background(BLTheme.bg)
        #else
        .frame(maxWidth: 640, maxHeight: .infinity).background(BLTheme.bg)
        #endif
        .onAppear { engine.cancel() }   // clear any prior built-in run state
    }

    private func run() {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty, !isRunning else { return }
        engine.run(custom: agent, goal: g, basePersona: settings.effectiveSystemPrompt)
    }
}

// MARK: - Shared agent step row (used by the custom-agent runner; mirrors AgentScreen's styling)
struct AgentStepRow: View {
    let step: AgentStep
    var body: some View {
        let (icon, tint, label) = style(step.kind)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundColor(tint)
                .frame(width: 24, height: 24).background(tint.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(step.title).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(tint).tracking(0.5)
                        .padding(.vertical, 1).padding(.horizontal, 5).background(tint.opacity(0.12)).clipShape(Capsule())
                    Spacer()
                }
                if step.kind == .answer { MarkdownView(text: step.detail) }
                else {
                    Text(step.detail).font(.system(size: 11.5, design: step.kind == .toolResult ? .monospaced : .rounded))
                        .foregroundColor(BLTheme.sub).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12).background(BLTheme.panelGrad).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(step.kind == .answer ? BLTheme.gold.opacity(0.35) : BLTheme.stroke, lineWidth: 1))
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
}
#endif // circuit-convert
