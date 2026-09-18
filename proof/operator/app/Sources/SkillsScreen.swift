#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — Skills: a registry of reusable instruction templates the buyer runs against
// the on-device brain over any input. Built-ins ship as templates; the buyer can add their
// own. Running a skill is a real brain call streamed live — output is never fabricated.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

struct SkillsScreen: View {
    @EnvironmentObject var skills: SkillStore
    @EnvironmentObject var ai: AIEngine
    @EnvironmentObject var settings: AppSettings
    @State private var running: Skill?
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var activity: ActivityLog
    @State private var editing: Skill?
    @State private var smithing: SmithRequest?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ScreenTitle(title: "Skills", subtitle: "Reusable instruction templates — run any over text, a paste, or a document")
                Spacer()
                GhostButton(label: "Draft with AI", icon: "wand.and.stars") { smithing = SmithRequest() }
                GoldButton(label: "New skill", icon: "plus") { editing = Skill(name: "", blurb: "", icon: "sparkles", instruction: "", promptTemplate: "{input}") }
            }.padding(24).padding(.bottom, 4)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                TextField("Search skills", text: $search).textFieldStyle(.plain).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
            }
            .padding(.vertical, 8).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1)).padding(.horizontal, 24).padding(.bottom, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    ForEach(filtered) { s in skillCard(s) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .sheet(item: $running) { s in SkillRunner(skill: s).environmentObject(ai).environmentObject(settings).sheetCloseBar() }
        .sheet(item: $editing) { s in SkillEditor(skill: s).environmentObject(skills).sheetCloseBar() }
        .sheet(item: $smithing) { req in
            SkillSmithSheet(refine: req.refine, onDrafted: openEditor)
                .environmentObject(brain).environmentObject(activity).sheetCloseBar()
        }
    }

    /// Hand a freshly drafted/refined skill to the editor for review — the buyer always confirms
    /// before anything is saved. Delayed a beat so the Smith sheet finishes dismissing first.
    private func openEditor(_ s: Skill) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editing = s }
    }

    private var filtered: [Skill] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return skills.all }
        return skills.all.filter { $0.name.lowercased().contains(q) || $0.blurb.lowercased().contains(q) }
    }

    @ViewBuilder private func skillCard(_ s: Skill) -> some View {
        HoloCard(cornerRadius: 16, sweep: false, padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: s.icon).font(.system(size: 15, weight: .bold)).foregroundColor(BLTheme.ink)
                        .frame(width: 36, height: 36).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: BLTheme.goldGlow, radius: 5, y: 2)
                    Spacer()
                    if s.builtIn { FoilBadge(text: "Built-in") }
                    else {
                        Menu { Button("Edit") { editing = s }; Button("Refine with AI\u{2026}") { smithing = SmithRequest(refine: s) }; Button("Delete", role: .destructive) { skills.delete(s) } }
                        label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.sub) }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Skill actions")
                    }
                }
                Text(s.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(s.blurb).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                GoldButton(label: "Run", fill: true, icon: "play.fill") { running = s }
            }
        }
    }
}

// MARK: - Run a skill (live streamed output)
struct SkillRunner: View {
    let skill: Skill
    @EnvironmentObject var ai: AIEngine
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var activity: ActivityLog
    @Environment(\.dismiss) var dismiss
    @State private var input = ""
    @State private var output = ""
    @State private var running = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: skill.icon).font(.system(size: 14, weight: .bold)).foregroundColor(BLTheme.ink)
                    .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                Text(skill.name).font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Close")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("INPUT").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $input).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 130).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            }
            HStack {
                if case .none(let r) = brain.active {
                    Label(r, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(.orange).lineLimit(1)
                }
                Spacer()
                if running { GhostButton(label: "Stop", icon: "stop.fill", tint: BLTheme.danger) { brain.cancel(); running = false } }
                GoldButton(label: running ? "Running…" : "Run skill", icon: "play.fill") { run() }
            }
            if running || !output.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("OUTPUT").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                        Spacer()
                        if !output.isEmpty {
                            Button {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string)
                                copied = true; DispatchQueue.main.asyncAfter(deadline: .now()+1.2) { copied = false }
                            } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(copied ? BLTheme.green : BLTheme.sub) }.buttonStyle(.plain)
                        }
                    }
                    ScrollView {
                        MarkdownView(text: output.isEmpty ? "…" : output).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 200).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                }
            }
        }
        .padding(24).keyboardDismissable().sheetWidth(560).background(BLTheme.bg)
    }

    private func run() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        output = ""; running = true
        let startedAt = Date()
        brain.stream(prompt: skill.buildPrompt(text), system: skill.instruction, grounding: "",
                     images: [], history: [],
                     onToken: { output = $0 },
                     onDone: { final in
                         running = false
                         let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                         if let f = final, !f.isEmpty {
                             output = f
                             activity.record(kind: .skill, title: skill.name.isEmpty ? "Skill" : skill.name,
                                             detail: f, outcome: .success, durationMS: ms)
                         } else {
                             let err = brain.lastError ?? "No output produced."
                             output = err
                             activity.record(kind: .skill, title: skill.name.isEmpty ? "Skill" : skill.name,
                                             detail: err, outcome: .failure, durationMS: ms)
                         }
                     })
    }
}

// MARK: - Create / edit a custom skill
struct SkillEditor: View {
    @EnvironmentObject var skills: SkillStore
    @Environment(\.dismiss) var dismiss
    @State var skill: Skill
    private let icons = ["sparkles", "wand.and.stars", "text.append", "checklist", "lightbulb.fill", "bolt.fill", "doc.text.fill", "chevron.left.forwardslash.chevron.right", "envelope.fill", "magnifyingglass"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(skill.name.isEmpty ? "New skill" : "Edit skill").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Field(title: "Name", text: $skill.name, prompt: "e.g. Summarize meeting")
            Field(title: "Blurb", text: $skill.blurb, prompt: "Short description")
            VStack(alignment: .leading, spacing: 5) {
                Text("ICON").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                HStack(spacing: 8) { ForEach(icons, id: \.self) { ic in
                    Button { skill.icon = ic } label: {
                        Image(systemName: ic).font(.system(size: 13, weight: .bold)).foregroundColor(skill.icon == ic ? BLTheme.ink : BLTheme.sub)
                            .frame(width: 30, height: 30).background(skill.icon == ic ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                } }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("SYSTEM INSTRUCTION").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $skill.instruction).font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 60).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("PROMPT TEMPLATE  —  use {input} for the buyer's text").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $skill.promptTemplate).font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 70).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                GoldButton(label: "Save skill", icon: "checkmark") {
                    guard !skill.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    if !skill.promptTemplate.contains("{input}") { skill.promptTemplate += "\n\n{input}" }
                    if skills.custom.contains(where: { $0.id == skill.id }) { skills.update(skill) } else { skills.add(skill) }
                    dismiss()
                }
            }
        }.padding(24).keyboardDismissable().sheetWidth(560).background(BLTheme.bg)
    }
}

// A request to draft a brand-new skill (refine == nil) or refine an existing one.
struct SmithRequest: Identifiable { let id = UUID(); var refine: Skill? = nil }

// MARK: - Draft / refine a skill with the brain (self-improving skills, review-gated)
// The buyer states a goal (or what to improve); the assistant PROPOSES a skill via a real
// brain call; SkillSmith parses it; the proposal opens in the editor for review/save. Nothing
// is created or changed until the buyer saves. An unparseable reply shows an honest message —
// never a fabricated skill.
struct SkillSmithSheet: View {
    var refine: Skill? = nil
    let onDrafted: (Skill) -> Void
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var activity: ActivityLog
    @Environment(\.dismiss) var dismiss
    @State private var goal = ""
    @State private var working = false
    @State private var error: String?

    private var isRefine: Bool { refine != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars").font(.system(size: 14, weight: .bold)).foregroundColor(BLTheme.ink)
                    .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                Text(isRefine ? "Refine “\(refine!.name)” with AI" : "Draft a skill with AI")
                    .font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Close")
            }
            Text(isRefine
                 ? "Describe what to improve. The assistant proposes an updated skill — you review and save it; nothing changes until you do."
                 : "Describe what you want this skill to do. The assistant drafts a reusable skill — you review and save it; nothing is created until you do.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(isRefine ? "WHAT TO IMPROVE" : "WHAT SHOULD IT DO").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $goal).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 110).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            }
            if case .none(let r) = brain.active {
                Label(r, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(.orange).lineLimit(2)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                GoldButton(label: working ? "Drafting…" : (isRefine ? "Propose update" : "Draft skill"), icon: "wand.and.stars") { draft() }
            }
        }.padding(24).keyboardDismissable().sheetWidth(560).background(BLTheme.bg)
    }

    private func draft() {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty, !working else { return }
        working = true; error = nil
        let prompt = isRefine ? SkillSmith.refinePrompt(refine!, feedback: g) : SkillSmith.draftPrompt(from: g)
        let startedAt = Date()
        brain.complete(prompt: prompt, system: SkillSmith.system) { result in
            working = false
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            switch result {
            case .success(let raw):
                if let skill = SkillSmith.parse(raw, keepingID: refine?.id) {
                    activity.record(kind: .skill,
                                    title: isRefine ? "Refined skill: \(skill.name)" : "Drafted skill: \(skill.name)",
                                    detail: raw, outcome: .success, durationMS: ms)
                    dismiss()
                    onDrafted(skill)
                } else {
                    error = "Couldn’t draft a usable skill from that — try adding more detail."
                    activity.record(kind: .skill, title: isRefine ? "Refine skill" : "Draft skill",
                                    detail: "Model reply could not be parsed into a skill:\n\n\(raw)",
                                    outcome: .failure, durationMS: ms)
                }
            case .failure(let e):
                error = e.localizedDescription
                activity.record(kind: .skill, title: isRefine ? "Refine skill" : "Draft skill",
                                detail: e.localizedDescription, outcome: .failure, durationMS: ms)
            }
        }
    }
}
#endif // circuit-convert
