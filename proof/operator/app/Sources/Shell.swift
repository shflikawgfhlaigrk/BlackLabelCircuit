// Sovereign — app shell: routing, the command palette (⌘K global search + navigation),
// onboarding, and the in-app help center. Keeps main.swift lean.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Shortcut notifications (driven by the native menu in AppDelegate; lives here so
// both the app and the headless test target compile — main.swift is excluded from tests).
extension Notification.Name {
    static let sovCommandPalette = Notification.Name("sov.commandPalette")
    static let sovNewConversation = Notification.Name("sov.newConversation")
    static let sovSearch = Notification.Name("sov.search")
    static let sovAttach = Notification.Name("sov.attach")
    static let sovStop = Notification.Name("sov.stop")
    static let sovRoute = Notification.Name("sov.route")          // object: AppRoute
    static let sovRouteKnowledgeDoc = Notification.Name("sov.route.knowledgeDoc") // object: UUID (a KnowledgeDoc id) — RAG citation deep-link
    static let sovInsertPrompt = Notification.Name("sov.insertPrompt")   // object: String (prompt body)
    static let sovWipeAllData = Notification.Name("sov.wipeAllData")     // delete account + all local data (5.1.1(v))
    static let sovGoLive = Notification.Name("sov.goLive")               // exit demo → connect-your-own setup
}

// MARK: - Routes
enum AppRoute: String, CaseIterable, Identifiable {
    case dashboard, brain, agent, agents, prompts, knowledge, memory, skills, automate, activity, connectors, weather, help, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Operator"
        case .brain: return "The Brain"
        case .agent: return "Agent"
        case .agents: return "My Agents"
        case .prompts: return "Prompts"
        case .knowledge: return "Knowledge"
        case .memory: return "Memory"
        case .skills: return "Skills"
        case .automate: return "Automations"
        case .activity: return "Activity"
        case .connectors: return "Connectors"
        case .weather: return "Weather"
        case .help: return "Help"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "bolt.shield.fill"
        case .brain: return "sparkles"
        case .agent: return "point.3.connected.trianglepath.dotted"
        case .agents: return "person.2.badge.gearshape.fill"
        case .prompts: return "text.book.closed.fill"
        case .knowledge: return "books.vertical.fill"
        case .memory: return "brain.head.profile"
        case .skills: return "wand.and.stars"
        case .automate: return "gearshape.2.fill"
        case .activity: return "checklist.checked"
        case .connectors: return "puzzlepiece.extension.fill"
        case .weather: return "cloud.sun.fill"
        case .help: return "questionmark.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
    /// Sidebar groupings.
    static var primary: [AppRoute] { [.dashboard, .brain, .agent, .agents, .prompts, .knowledge, .memory, .skills, .automate, .activity] }
    static var secondary: [AppRoute] { [.connectors, .weather, .help, .settings] }
}

// MARK: - Navigation state shared across the shell (for ⌘K, quick actions, shortcuts)

/// A Brain-scoped action requested from OUTSIDE the Brain screen (the global ⌥Space quick-ask, the
/// ⌘N/⌘O menu shortcuts, a ⌘K "insert prompt"). Because only the current route's screen is mounted,
/// posting a notification straight at ChatScreen is lost when the window is on any other screen — so
/// the trigger stashes the intent on `Nav` instead and ChatScreen drains it on appear.
enum BrainIntent: Equatable {
    case newConversation
    case attach
    case search
    case insertPrompt(String)
    case quickAsk(String)
}

@MainActor
final class Nav: ObservableObject {
    @Published var route: AppRoute = .dashboard
    @Published var showPalette = false
    /// When a ⌘K Activity hit is chosen, the specific receipt to deep-link to. The Activity screen
    /// observes this, scrolls the row into view, and highlights it, then clears it.
    @Published var activityTarget: UUID? = nil
    /// When a RAG citation chip is tapped, the specific Knowledge document to deep-link to. The
    /// Knowledge screen observes this, switches to Documents, drops the search filter, scrolls
    /// the row into view + rings it, then clears it.
    @Published var knowledgeTarget: UUID? = nil
    /// A Brain-scoped action requested from OUTSIDE the Brain screen (global ⌥Space quick-ask, the
    /// ⌘N/⌘O menu shortcuts, a ⌘K "insert prompt"). Only the current route's screen is mounted, so a
    /// notification posted straight at ChatScreen is silently lost when the window is on another screen.
    /// We stash the intent here, route to Brain, and ChatScreen drains it on appear (same deep-link idiom
    /// as activityTarget/knowledgeTarget), clearing it once it runs.
    @Published var brainIntent: BrainIntent? = nil
    func go(_ r: AppRoute) { route = r; showPalette = false }
    /// Route to The Brain carrying an intent the Brain screen runs once it appears.
    func goToBrain(_ intent: BrainIntent) { brainIntent = intent; route = .brain; showPalette = false }
    /// Deep-link straight to a specific Activity receipt row.
    func goToActivity(_ id: UUID) { activityTarget = id; route = .activity; showPalette = false }
    /// Deep-link straight to a specific Knowledge document (from a RAG citation chip).
    func goToKnowledge(_ docID: UUID) { knowledgeTarget = docID; route = .knowledge; showPalette = false }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Command palette (⌘K): fuzzy navigation + actions (run skills, insert prompts,
// jump to conversations) + live global search across the buyer's own data. The Raycast model.
struct CommandPalette: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var store: Store
    @EnvironmentObject var skills: SkillStore
    @EnvironmentObject var prompts: PromptLibrary
    @EnvironmentObject var activity: ActivityLog
    @EnvironmentObject var memory: MemoryStore
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Action: Identifiable { let id = UUID(); let title: String; let subtitle: String; let icon: String; let run: () -> Void }

    private var navActions: [Action] {
        AppRoute.allCases.map { r in Action(title: "Go to \(r.title)", subtitle: "Navigate", icon: r.icon) { nav.go(r) } }
            + [Action(title: "New conversation", subtitle: "The Brain", icon: "square.and.pencil") { store.newConversation(); nav.go(.brain) }]
    }
    private func matches(_ a: Action, _ q: String) -> Bool { q.isEmpty || a.title.lowercased().contains(q) }
    private var q: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var filteredNav: [Action] { navActions.filter { matches($0, q) } }

    // Insert a saved prompt straight into The Brain composer.
    private var promptActions: [Action] {
        prompts.all
            .filter { q.isEmpty ? false : ($0.title.lowercased().contains(q) || $0.body.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) }) }
            .prefix(5)
            .map { p in Action(title: p.title, subtitle: "Use prompt · \(p.category.label)", icon: p.category.icon) {
                prompts.recordUse(p); store.ensureActiveConversation()
                NotificationCenter.default.post(name: .sovInsertPrompt, object: p.body); nav.go(.brain)
            } }
    }
    // Open a skill runner from the Skills screen.
    private var skillActions: [Action] {
        skills.all
            .filter { q.isEmpty ? false : ($0.name.lowercased().contains(q) || $0.blurb.lowercased().contains(q)) }
            .prefix(5)
            .map { s in Action(title: s.name, subtitle: "Open skill · \(s.blurb)", icon: s.icon) { nav.go(.skills) } }
    }
    private var searchHits: [Store.SearchHit] {
        query.count >= 2 ? store.search(query) : []
    }
    // Proof-of-execution receipts surfaced in ⌘K — jump straight to the Activity ledger.
    private var activityHits: [ActivityEntry] {
        query.count >= 2 ? Array(activity.search(query).prefix(5)) : []
    }
    // Saved memories surfaced in ⌘K — jump to the Memory screen to view/edit/toggle. Memory was
    // the one buyer data-surface global search did not reach; this closes that gap.
    private var memoryHits: [MemoryItem] {
        query.count >= 2 ? Array(memory.search(query).prefix(5)) : []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundColor(BLTheme.gold)
                TextField("Search, jump, run a skill, insert a prompt…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 16, design: .rounded)).foregroundColor(BLTheme.text)
                    .focused($focused).onSubmit(runFirst)
                Text("esc").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.sub)
                    .padding(.vertical, 2).padding(.horizontal, 6).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 5))
            }.padding(16)
            Divider().background(BLTheme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !filteredNav.isEmpty {
                        sectionHeader("Navigate")
                        ForEach(filteredNav.prefix(6)) { a in actionRow(a.title, a.subtitle, a.icon, a.run) }
                    }
                    if !promptActions.isEmpty {
                        sectionHeader("Prompts")
                        ForEach(promptActions) { a in actionRow(a.title, a.subtitle, a.icon, a.run) }
                    }
                    if !skillActions.isEmpty {
                        sectionHeader("Skills")
                        ForEach(skillActions) { a in actionRow(a.title, a.subtitle, a.icon, a.run) }
                    }
                    if !searchHits.isEmpty {
                        sectionHeader("Results")
                        ForEach(searchHits.prefix(8)) { hit in
                            actionRow(hit.title, "\(hit.kind) · \(hit.snippet)", hitIcon(hit.kind)) { open(hit) }
                        }
                    }
                    if !memoryHits.isEmpty {
                        sectionHeader("Memory")
                        ForEach(memoryHits) { m in
                            actionRow(m.trimmed, m.enabled ? "Memory · standing fact" : "Memory · disabled (off)", "brain.head.profile") { nav.go(.memory) }
                        }
                    }
                    if !activityHits.isEmpty {
                        sectionHeader("Activity")
                        ForEach(activityHits) { e in
                            actionRow(e.title, "\(e.kind.label) · \(e.outcome.label) · \(e.snippet)", e.kind.icon) { nav.goToActivity(e.id) }
                        }
                    }
                    if filteredNav.isEmpty && promptActions.isEmpty && skillActions.isEmpty && searchHits.isEmpty && memoryHits.isEmpty && activityHits.isEmpty {
                        Text("No matches.").font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub).padding(16)
                    }
                }.padding(8)
            }.frame(maxHeight: 380)
        }
        .responsiveWidth(540)
        .background(BLTheme.glassStrong).background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .onAppear { focused = true }
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.sub).tracking(0.8).padding(.horizontal, 10).padding(.top, 8)
    }
    private func actionRow(_ title: String, _ subtitle: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button { run(); dismiss() } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.gold).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                    Text(subtitle).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                }
                Spacer()
            }.padding(.vertical, 7).padding(.horizontal, 10).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.001)))
        }.buttonStyle(.plain).onHoverHighlight()
    }
    private func hitIcon(_ kind: String) -> String {
        switch kind { case "Conversation": return "bubble.left.fill"; case "Document": return "doc.text.fill"; case "Reminder": return "bell.fill"; default: return "gearshape.2.fill" }
    }
    private func open(_ hit: Store.SearchHit) {
        if let cid = hit.conversationID { store.activeConversationID = cid; nav.go(.brain) }
        else if let docID = hit.documentID { nav.goToKnowledge(docID) }
        else if hit.kind == "Reminder" || hit.kind == "Automation" { nav.go(.automate) }
        dismiss()
    }
    private func runFirst() {
        if let hit = searchHits.first { open(hit) }
        else if !memoryHits.isEmpty { nav.go(.memory); dismiss() }
        else if let e = activityHits.first { nav.goToActivity(e.id); dismiss() }
        else if let p = promptActions.first { p.run(); dismiss() }
        else if let s = skillActions.first { s.run(); dismiss() }
        else if let first = filteredNav.first { first.run(); dismiss() }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
private struct HoverHighlight: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: 9).fill(hover ? BLTheme.gold.opacity(0.10) : .clear))
            .onHover { hover = $0 }
    }
}
#endif // circuit-convert
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
private extension View { func onHoverHighlight() -> some View { modifier(HoverHighlight()) } }
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Help center (in-app, real — no external links required)
struct HelpScreen: View {
    @EnvironmentObject var nav: Nav
    private struct Topic: Identifiable { let id = UUID(); let q: String; let a: String; let icon: String }
    private let topics: [Topic] = [
        Topic(q: "How does the brain work?", a: "Sovereign defaults to Ornith 1.0 running locally on this Mac — through your own Ollama daemon, or any OpenAI-compatible local server (llama.cpp, LM Studio) at 127.0.0.1. You can also use Apple's on-device model where available. Nothing is bundled with a hosted account, and when no brain is available the app says so honestly instead of faking a reply.", icon: "cpu"),
        Topic(q: "Can I analyze a document or image?", a: DataHandlingCopy.documentImport + " The default Ornith/Ollama and on-device routes are text-only and say so honestly for images.", icon: "doc.text.magnifyingglass"),
        Topic(q: "What is the Knowledge base?", a: "Notes and imported documents are stored locally. Enabled documents are retrieved by relevance using on-device semantic embeddings (with keyword fallback) and selected excerpts are passed to the active brain as grounding. A configured external provider processes those excerpts under your account; citations identify the source document.", icon: "books.vertical.fill"),
        Topic(q: "What is the Agent?", a: "The Agent pursues a goal across multiple steps: it plans, then acts using safe local tools, observes the real results, and verifies before answering. Every step shows a real receipt — what it did and the actual result — so nothing is ever narrated as done unless a tool truly returned it. Local text brains report unavailable tool paths honestly.", icon: "point.3.connected.trianglepath.dotted"),
        Topic(q: "Can I summon it from anywhere?", a: "Yes. Sovereign lives in your menu bar, and pressing ⌥Space from any app opens a floating quick-ask box — type a question, press Return, and it routes into The Brain. Closing the window keeps Sovereign in the menu bar; click the Dock icon or the menu-bar item to bring it back.", icon: "menubar.arrow.up.rectangle"),
        Topic(q: "How does Memory work?", a: DataHandlingCopy.memoryContext + " You write each memory by hand or save one from a reply; nothing is auto-collected, and you can disable any item.", icon: "brain.head.profile"),
        Topic(q: "What is the Prompt library?", a: "A collection of reusable prompts you can drop into The Brain with one click, or via ⌘K. Built-ins give you starters; add your own with a category and tags, pin favorites, and they sort by how often you use them. A prompt is a reusable starting message — distinct from a Skill, which transforms input you paste in.", icon: "text.book.closed.fill"),
        Topic(q: "What are Skills?", a: "Reusable instruction templates you run over any input or a document — summarize, rewrite, extract action items, code review, and more. Add your own with a custom prompt template using {input}. Every result is generated live; nothing is canned.", icon: "wand.and.stars"),
        Topic(q: "How do Automations run?", a: "An automation is a saved instruction the brain runs on a schedule (hourly/daily/weekly) or on demand. Output is logged. They run while the app is open — the runtime banner shows the last tick.", icon: "gearshape.2.fill"),
        Topic(q: "Do reminders work in the background?", a: "Reminders fire native notifications at the time you set, while the app is open. One-off or recurring. You can also fire any reminder immediately.", icon: "bell.fill"),
        Topic(q: "Can I white-label it?", a: "Fully. Set the assistant name, tagline, accent color (or custom hex), and system-prompt persona in Settings, then save it as a profile. Switch personas per conversation from the persona menu in The Brain.", icon: "paintpalette.fill"),
        Topic(q: "Does voice need a microphone?", a: "Voice output uses Apple speech synthesis. Voice input uses the microphone only with permission; raw audio is recognized on this Mac and is not sent to a speech service. The resulting text goes to the active brain, so a configured external provider processes it.", icon: "speaker.wave.2.fill"),
        Topic(q: "Where is my data stored?", a: DataHandlingCopy.storageAndExternal + " Credentials are stored in Keychain and presented to their provider or connector only as authentication. Delete your account or reset settings any time in Settings.", icon: "lock.shield.fill")
    ]
    private let shortcuts: [(String, String)] = [
        ("⌥Space", "Quick Ask — summon Sovereign from any app"),
        ("⌘K", "Command palette — search, jump, run a skill, insert a prompt"),
        ("⌘N", "New conversation"),
        ("⌘F", "Search conversations"),
        ("⌘O", "Attach a document or image"),
        ("⌘1", "Operator"),
        ("⌘2", "The Brain"),
        ("⌘3", "Prompts"),
        ("⌘4", "Knowledge"),
        ("⌘5", "Memory"),
        ("⌘6", "Skills"),
        ("⌘7", "Automations"),
        ("⌘,", "Settings"),
        ("⌘⌫", "Stop generating")
    ]

    // Which bundled buyer guide is open in the reader sheet (nil = none).
    @State private var openGuide: BundledGuide? = nil

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(title: "Help", subtitle: "Everything you can do — answered in-app, no internet required")
            // Buyer guides — the six release documents, bundled into this build and rendered
            // in-house (DOD-3.7: documentation reachable inside the product). The catalog is
            // per-platform (empty on iOS, where the Mac-lane guides would misinform), so the
            // panel only renders when there is something true to open.
            if !GuideLibrary.catalog.isEmpty {
            Panel(title: "Guides", icon: "book.closed.fill") {
                VStack(spacing: 8) {
                    ForEach(GuideLibrary.catalog) { g in
                        Button { openGuide = g } label: {
                            HStack(spacing: 12) {
                                Image(systemName: g.icon).font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.ink)
                                    .frame(width: 28, height: 28).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(g.title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Text(g.blurb).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.sub)
                            }
                            .contentShape(Rectangle())
                            .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(g.title)")
                    }
                }
            }
            }
            // ⌘-chords need a hardware keyboard with a Command key — a touch iPhone can't invoke
            // any of them, so the panel is macOS-only.
            #if os(macOS)
            Panel(title: "Keyboard shortcuts", icon: "keyboard") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
                    ForEach(shortcuts, id: \.0) { s in
                        HStack(spacing: 10) {
                            Text(s.0).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.gold)
                                .padding(.vertical, 3).padding(.horizontal, 8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(BLTheme.stroke, lineWidth: 1))
                            Text(s.1).font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub)
                            Spacer()
                        }
                    }
                }
            }
            #endif
            ForEach(topics) { t in HelpRow(topic: (t.q, t.a, t.icon)) }
        }.padding(24) }
        .sheet(item: $openGuide) { g in GuideReaderView(guide: g) }
    }
}
#endif // circuit-convert
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
private struct HelpRow: View {
    let topic: (q: String, a: String, icon: String)
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { open.toggle() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: topic.icon).font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.ink)
                        .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                    Text(topic.q).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.sub).rotationEffect(.degrees(open ? 180 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                Text(topic.a).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10).padding(.leading, 42)
            }
        }
        .padding(16).background(BLTheme.panelGrad).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }
}
#endif // circuit-convert

// MARK: - Onboarding (first run — honest, no fake data, sets up the buyer)

enum OnboardingPlatform: Equatable { case macOS, iOS }
enum OnboardingStage: Equatable { case welcome, personalize, voice, brain, ready }

/// How the workspace opens when onboarding ends. Entry itself is UNCONDITIONAL — this says only
/// whether the buyer lands fully configured or openly unconfigured, and carries the honest notice
/// for the second case. PURE.
enum WorkspaceEntry: Equatable {
    case configured
    case unconfigured(notice: String)

    /// ALWAYS true, in every case. The workspace is the buyer's; onboarding may inform them, never
    /// imprison them (M1, 2026-08-02).
    var entersWorkspace: Bool { true }
    /// The honest "what isn't connected, and how to fix it" line, when there is one.
    var notice: String? { if case .unconfigured(let n) = self { return n }; return nil }
    var isConfigured: Bool { self == .configured }
}

/// Pure platform/flow policy. iOS has no wake-word architecture in this target.
///
/// M1 (2026-08-02 lockout): `canFinish` is a COMPLETENESS signal — it says whether setup ended with
/// a brain that can actually answer, and it drives copy and nudges ONLY. It is never a gate on
/// entering the workspace. It used to guard `finish()`, the single setter of `done`, so a buyer
/// with no usable brain (offline, no Apple Intelligence, no local daemon) was bounced back to the
/// brain step forever and could not reach ANY part of the app they bought.
enum OnboardingFlowPolicy {
    static func stages(for platform: OnboardingPlatform) -> [OnboardingStage] {
        switch platform {
        case .macOS: return [.welcome, .personalize, .voice, .brain, .ready]
        case .iOS: return [.welcome, .personalize, .brain, .ready]
        }
    }
    /// Did setup end with a genuinely usable brain? Copy/nudge signal only — NEVER an exit gate.
    static func canFinish(brainUsable: Bool) -> Bool { brainUsable }

    /// Entry is unconditional by contract: this returns an entry in EVERY case, and its
    /// `entersWorkspace` is constant-true. An unconfigured buyer gets in, and gets told what is
    /// missing and how to fix it.
    static func entry(brainUsable: Bool) -> WorkspaceEntry {
        brainUsable ? .configured : .unconfigured(notice: unconfiguredNotice)
    }
    /// The honest unconfigured-workspace disclosure. States the limit plainly (no brain ⇒ no
    /// replies) without pretending anything works, and names the exact remedy.
    static let unconfiguredNotice = "No brain is connected yet, so the assistant can't answer messages. Open Settings → Brain to set up the free local model on this Mac, or connect your own provider. Everything else in your workspace works now."

    /// Where the "use current setup / set up a brain" NUDGE lands. A nudge, never a wall: the skip
    /// path out of onboarding does not go through here.
    static func skipDestination(for platform: OnboardingPlatform, brainUsable: Bool) -> OnboardingStage {
        brainUsable ? .ready : .brain
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct OnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ai: AIEngine
    @EnvironmentObject var wake: WakeEngine
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var externalAuth: ExternalAuth
    @Binding var done: Bool
    @State private var step = 0
    @State private var name = ""
    @State private var wakePasses = 0
    @State private var wakeBusy = false
    @State private var wakeDone = false
    @State private var brainGateNote: String?              // SV-21: honest copy when Apple's model can't be the default
    @State private var providerKey = ""
    @State private var providerStatus = ""
    @State private var providerBusy = false
    @StateObject private var ornith = OrnithSetupModel()   // inline first-run brain auto-setup

    private var platform: OnboardingPlatform {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
    private var stages: [OnboardingStage] { OnboardingFlowPolicy.stages(for: platform) }
    private var currentStage: OnboardingStage { stages[min(step, stages.count - 1)] }
    private var isLastStage: Bool { step == stages.count - 1 }
    /// Did setup end with a brain that can actually answer? Drives COPY and the nudge destination
    /// only — never whether the buyer may leave onboarding (M1).
    private var setupComplete: Bool { OnboardingFlowPolicy.canFinish(brainUsable: brain.isUsable) }

    var body: some View {
        ZStack {
            AuroraBackdrop()                         // living, theme-driven first-run backdrop
            ParticleField().allowsHitTesting(false)
            // Same overflow guard as AuthView: the brain step's expanded provider disclosure can push
            // the card past a 680pt window, so the card scrolls when it does not fit and stays
            // centered when it does.
            GeometryReader { geo in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 22) {
                        Logo(size: 84).shadow(color: BLTheme.gold.opacity(0.4), radius: 26, y: 6)
                        ShimmerText(text: "Welcome to Sovereign", size: 34)
                        Group {
                            switch currentStage {
                            case .welcome: stepWelcome
                            case .personalize: stepBranding
                            case .voice: stepVoice
                            case .brain: stepBrain
                            case .ready: stepReady
                            }
                        }.responsiveWidth(420)
                        HStack(spacing: 12) {
                            if step > 0 { GhostButton(label: "Back", icon: "chevron.left") { moveTo(step - 1) } }
                            // Never disabled: the buyer's way into their own workspace is not conditional.
                            GoldButton(label: isLastStage ? "Enter Sovereign" : "Continue", icon: "arrow.right") {
                                if isLastStage { finish() } else { moveTo(step + 1) }
                            }
                        }
                        HStack(spacing: 16) {
                            // The NUDGE toward a brain (or "you're set") — routes within onboarding. This is
                            // the ONLY thing setup-completeness may drive: copy and a suggested destination.
                            Button(setupComplete ? "Use current setup" : "Set up a brain") { skipSetup() }
                                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                            // THE UNBLOCKABLE ESCAPE (M1): always present, never disabled, calls finish()
                            // directly. Nothing may ever gate this path out of onboarding.
                            Button(brain.isUsable ? "Skip setup" : "Skip setup — enter without a brain") { finish() }
                                .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }
                    .padding(40).responsiveWidth(520)
                    .background(.ultraThinMaterial).background(BLTheme.panel.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(BLTheme.hairline, lineWidth: 1))
                    .shadow(color: BLTheme.gold.opacity(0.16), radius: 70, y: 16)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        }
        .onAppear { name = settings.assistantName }
    }

    private var stepWelcome: some View {
        VStack(spacing: 14) {
            Text("A personal AI workspace you control").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
            VStack(alignment: .leading, spacing: 10) {
                onboardPoint("cpu", "Choose how your assistant answers", "Use Apple's on-device model when available, a local model on Mac, or a supported provider through your own account.")
                onboardPoint("brain.head.profile", "Memory that's yours", "Tell it what to remember about you; it's recalled in every conversation — and you control every fact.")
                onboardPoint("books.vertical.fill", "Knowledge, prompts & skills",
                             platform == .macOS
                                ? "Ground replies on your own files; reuse prompts with ⌘K; run skills over any text."
                                : "Ground replies on your own files; reuse prompts from Search; run skills over any text.")
                onboardPoint("gearshape.2.fill", "Automations & reminders", "Schedule brain tasks and reminders that run while the app is open.")
                // SV-09: the license + on-device-data guarantee, stated on the FIRST screen the buyer
                // ever sees — not buried in Settings where it may as well not exist.
                onboardPoint("lock.shield.fill", OwnershipCopy.firstRunTitle, OwnershipCopy.firstRunGuarantee)
            }
        }
    }
    private var stepBranding: some View {
        VStack(spacing: 14) {
            Text("Make it yours").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
            Field(title: "Name your assistant", text: $name, prompt: "Sovereign")
            Text("ACCENT").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            HStack(spacing: 10) {
                ForEach(AccentPreset.allCases.filter { $0 != .custom }) { p in
                    Button { settings.accentPreset = p } label: {
                        Circle().fill(p.color).frame(width: 30, height: 30)
                            .overlay(Circle().stroke(BLTheme.text.opacity(settings.accentPreset == p ? 0.9 : 0.15), lineWidth: settings.accentPreset == p ? 2 : 1))
                            .shadow(color: p.color.opacity(0.5), radius: settings.accentPreset == p ? 8 : 0)
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            Text("You can adjust the name, accent, persona, and saved profiles later in Settings.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
        }
    }
    /// The wake phrase this buyer will train — the name they just gave the assistant.
    private var trainedPhrase: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? settings.assistantName : n
    }

    /// Voice setup — training AUTO-STARTS the moment this step appears (never a buried button).
    private var stepVoice: some View {
        VStack(spacing: 14) {
            if wake.available {
                Text("Train your wake word").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(wakeDone
                     ? "Trained. \(trainedPhrase) now listens from the moment it launches — say the name and just start talking."
                     : "Say “\(trainedPhrase)” out loud — three times. Recognition runs on this Mac; your voice never leaves it.")
                    .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(i < wakePasses ? BLTheme.green : BLTheme.bg2)
                            .overlay(Circle().stroke(i < wakePasses ? BLTheme.green : BLTheme.stroke, lineWidth: 1))
                            .frame(width: 14, height: 14)
                    }
                }
                if wakeDone {
                    Label("Wake word trained — voice is on", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                } else if wakeBusy {
                    Label("Listening…", systemImage: "waveform")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                    if !wake.heardPartial.isEmpty {
                        Text("Heard: “\(wake.heardPartial)”")
                            .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(2)
                    }
                }
                if let e = wake.lastError {
                    Text(e).font(.system(size: 11, design: .rounded)).foregroundColor(.orange).multilineTextAlignment(.center)
                }
            } else {
                Label("Voice isn't available in this build", systemImage: "mic.slash.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(.orange)
                Text(wake.unavailableReason + " You can train the wake word anytime in Settings → Voice.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
            }
        }
        .onAppear { startWakeTraining() }
        .onDisappear { if !wakeDone { wake.stop(); wakeBusy = false } }
    }

    /// Run real training passes until three succeed. A pass counts ONLY when the recognizer
    /// genuinely heard the phrase; silence just keeps listening. Leaving the step stops the mic.
    private func startWakeTraining() {
        guard wake.available, !wakeDone, !wakeBusy else { return }
        wakeBusy = true
        Task { @MainActor in
            while wakePasses < 3 && currentStage == .voice && !wakeDone {
                let ok = await wake.trainPass(phrase: trainedPhrase)
                guard currentStage == .voice else { break }          // buyer moved on — stop cleanly
                if ok { wakePasses += 1 }
            }
            if wakePasses >= 3 {
                settings.wakePhrase = trainedPhrase
                settings.wakeTrained = true
                settings.voiceEnabled = true            // spoken replies on — voice is now live
                settings.wakeEnabled = true             // RootView starts the loop immediately
                wakeDone = true
            }
            wakeBusy = false
        }
    }

    /// Step navigation that always releases the mic when leaving the voice step and stops the brain
    /// auto-detect poll when leaving the brain step (a running download continues on its own).
    private func moveTo(_ next: Int) {
        if currentStage == .voice && !wakeDone { wake.stop(); wakeBusy = false }
        if currentStage == .brain { ornith.stopPolling() }
        withAnimation { step = min(max(0, next), stages.count - 1) }
    }

    private func skipSetup() {
        let destination = OnboardingFlowPolicy.skipDestination(for: platform, brainUsable: brain.isUsable)
        if let index = stages.firstIndex(of: destination) { moveTo(index) }
    }

    /// Brain-setup step (Founder 2026-07-09 dad-simple first-run): Ornith is Sovereign's SHIPPED
    /// DEFAULT brain, so there is NO engine-selection step here — reaching this step just sets Ornith
    /// up, inline, for a non-technical buyer. It auto-detects the buyer's Ollama, guides the one free
    /// helper install if needed (auto-continuing the moment it appears), shows a live download bar,
    /// and ends on a clear "you're ready". Nothing is faked: every line reflects a real probe/pull via
    /// `OrnithSetupModel`. The buyer's own Claude/Codex account stays available as a small ADVANCED
    /// link — documented, discoverable, never in the way.
    private var stepBrain: some View {
        VStack(spacing: 14) {
            Text("Setting up your assistant").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)

            // SV-21: when Apple's on-device model can't be the zero-setup default, state the gate
            // honestly — the real requirement, and that the bundled local brain is being used instead.
            if let note = brainGateNote {
                Text(note).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.champagne)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }

            #if os(iOS)
            iosBrainSetup
            #else
            if brain.isUsable, case .idle = ornith.phase {
                // A brain is already usable (Apple on-device, or a model already installed) — nothing
                // to download. Say so plainly and let them continue.
                Label("Your assistant is ready — \(brain.active.label)", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                Text("Sovereign already has a working brain: \(brain.active.label). Press Continue — you can change or add brains anytime in Settings.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
            } else {
                switch ornith.phase {
                case .idle, .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Getting your Mac ready…").font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                    Text("Sovereign runs a private assistant on your own Mac — free, no account needed. This only takes a moment.")
                        .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)

                case .needsHelper:
                    VStack(spacing: 10) {
                        Text("One quick thing").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text("Sovereign uses one small free helper to run privately on your Mac. Do these three steps and it finishes on its own:")
                            .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                        VStack(alignment: .leading, spacing: 6) {
                            onboardStepLine("1", "Click the button below to download the free helper.")
                            onboardStepLine("2", "Open the file it downloads and follow its steps.")
                            onboardStepLine("3", "Come back here — Sovereign continues by itself.")
                        }
                        GoldButton(label: "Download the free helper", icon: "arrow.down.circle") {
                            if let u = URL(string: "https://ollama.com/download") { NSWorkspace.shared.open(u) }
                        }
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the helper… I'll continue automatically. (Stay online — the helper and the brain are internet downloads.)")
                                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }

                case .pulling:
                    VStack(spacing: 8) {
                        Text("Downloading your assistant’s brain…").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        ProgressView(value: ornith.progress.fraction ?? 0).progressViewStyle(.linear).tint(BLTheme.green)
                        Text(ornith.progressLabel).font(BLTheme.mono(10.5)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                        Text("This is a one-time download and it stays on your Mac. You can keep going — it finishes in the background.")
                            .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                    }

                case .ready(let model):
                    Label("Your assistant is ready", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                    Text("\(model) is installed and running privately on this Mac. Press Continue — you can just start talking.")
                        .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)

                case .failed(let reason):
                    Label("That didn’t finish", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(.orange)
                    Text(reason).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                    GoldButton(label: "Try again", icon: "arrow.clockwise") { ornith.retry(settings: settings, brain: brain) }
                }
            }

            DisclosureGroup("Use my own Anthropic provider account instead") {
                VStack(spacing: 8) {
                    SecureField("Anthropic API key (sk-ant-…)", text: $providerKey)
                        .textFieldStyle(.plain).font(BLTheme.mono(12)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 9).padding(.horizontal, 11).background(BLTheme.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                    GoldButton(label: providerBusy ? "Verifying…" : "Use my provider",
                               icon: providerBusy ? "hourglass" : "key.fill") {
                        Task { await connectProvider() }
                    }.disabled(providerBusy)
                    Text("After verification, the key is stored in this Mac's Keychain and sent to Anthropic only as authentication. Anthropic processes prompts, recent history, attachments, and enabled document or memory context included in a request. Claude/Codex CLI setup is also available later in Settings.")
                        .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 6)
            }
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundColor(BLTheme.sub)
            if !providerStatus.isEmpty {
                Text(providerStatus).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(providerStatus.hasPrefix("Verified") ? BLTheme.green : .orange)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            providerVerificationRow
            #endif
        }
        .onAppear {
            // SV-21: on Apple silicon with Apple Intelligence enabled, default first-run straight to
            // Apple's ZERO-SETUP on-device brain — no Ornith download, no wait. Otherwise run the
            // inline Ornith setup unchanged and state the Apple gate honestly (never implying offline
            // Apple AI on unsupported hardware).
            ai.refreshAvailability()
            // SV-21: the single PURE gate (FoundationBrainPolicy) routes first-run from the one honest
            // availability probe — Apple zero-setup where available, else today's Ornith flow unchanged.
            let plan = FoundationBrainPolicy.firstRunPlan(foundationModelsAvailable: ai.foundationModelsAvailable)
            #if os(iOS)
            brainGateNote = ai.foundationModelsAvailable ? nil : "Apple's on-device model requires iOS 26 and Apple Intelligence. Connect your own supported provider below to continue."
            if plan.usesAppleZeroSetup {
                settings.brainProvider = .onDevice
            } else if externalAuth.isConnected {
                settings.brainProvider = .external
            }
            brain.resolve()
            #else
            brainGateNote = plan.gateNote
            if plan.usesAppleZeroSetup {
                settings.brainProvider = .onDevice
                brain.resolve()
            } else {
                brain.resolve()
                if !brain.isUsable, case .idle = ornith.phase {
                    ornith.begin(settings: settings, brain: brain)   // bundled local brain, set up inline
                }
            }
            #endif
        }
        .onDisappear { ornith.stopPolling() }
    }

    #if os(iOS)
    private var iosBrainSetup: some View {
        VStack(spacing: 12) {
            if brain.isUsable {
                Label("Ready — \(brain.active.label)", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                Text("Continue to your empty workspace. You can change providers later in Settings.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
            } else {
                Text("CONNECT YOUR PROVIDER").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                SecureField("Anthropic API key (sk-ant-…)", text: $providerKey)
                    .textFieldStyle(.plain).font(BLTheme.mono(12)).foregroundColor(BLTheme.text)
                    .padding(.vertical, 10).padding(.horizontal, 12).background(BLTheme.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                GoldButton(label: providerBusy ? "Verifying…" : "Use my provider",
                           icon: providerBusy ? "hourglass" : "key.fill") {
                    Task { await connectProvider() }
                }.disabled(providerBusy)
                Text("After verification, the key is stored in this device's Keychain and sent to Anthropic only as authentication. Anthropic processes prompts, recent history, attachments, and enabled document or memory context included in a request; Sovereign bundles no account or key.")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if !providerStatus.isEmpty {
                Text(providerStatus).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(providerStatus.hasPrefix("Verified") ? BLTheme.green : .orange)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            providerVerificationRow
        }
    }

    #endif

    /// M3: a provider key that is SAVED on this device but not proven yet (or was carried over from
    /// an older build, or was refused on a re-check) says so out loud, and offers the re-check.
    @ViewBuilder private var providerVerificationRow: some View {
        if providerStatus.isEmpty, let disclosure = externalAuth.verificationDisclosure {
            Text(disclosure).font(.system(size: 11, design: .rounded)).foregroundColor(.orange)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Verify now") {
                Task { @MainActor in
                    await externalAuth.reverifyIfNeeded()
                    brain.resolve()
                }
            }
            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
        }
    }

    @MainActor private func connectProvider() async {
        guard !providerBusy else { return }
        providerBusy = true
        providerStatus = "Verifying with Anthropic…"
        let outcome = await externalAuth.connect(apiKey: providerKey)
        switch outcome {
        case .verified:
            settings.externalModel = "claude-opus-4-8"
            settings.brainProvider = .external
            brain.resolve()
            providerKey = ""
            providerStatus = "Verified with Anthropic and saved in Keychain."
        case .savedPendingVerification(let message):
            // M3: the key is KEPT. Say plainly that it is saved but unproven — and that the buyer
            // can continue into the workspace right now either way.
            providerKey = ""
            providerStatus = message
            brain.resolve()
        case .rejected(let message), .invalidShape(let message), .storeFailed(let message):
            providerStatus = message
        }
        providerBusy = false
    }

    /// One numbered step line for the plain-language helper-install guide.
    private func onboardStepLine(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.bg)
                .frame(width: 18, height: 18).background(Circle().fill(BLTheme.gold))
            Text(text).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var stepReady: some View {
        VStack(spacing: 14) {
            if brain.isUsable {
                Label("You’re all set — \(brain.active.label)", systemImage: "checkmark.seal.fill").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                Text(platform == .macOS ? "Your assistant is ready. Start a conversation, or use voice when enabled." : "Your assistant is ready. Start a conversation in your empty workspace.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
            } else {
                Label("No brain connected yet", systemImage: "exclamationmark.triangle.fill").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(.orange)
                Text(OnboardingFlowPolicy.unconfiguredNotice)
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text((platform == .macOS ? "Press ⌘K for search. " : "") + "Your workspace starts empty. " + DataHandlingCopy.storageAndExternal)
                .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
        }
    }
    private func onboardPoint(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.ink)
                .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(body).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
    /// The ONE setter of `done` — and it is UNCONDITIONAL by contract (M1, 2026-08-02).
    ///
    /// A buyer must always be able to reach the workspace they paid for, brain or no brain. Nothing
    /// may guard this function: no `guard`, no early `return`, no readiness check. The honesty
    /// requirement is met where it belongs — the workspace opens in a clearly UNCONFIGURED state
    /// (OnboardingFlowPolicy.unconfiguredNotice, the "No brain connected" pill, the brain-setup
    /// card) that says exactly what is missing and how to fix it. A locked door is not honesty.
    private func finish() {
        if !wakeDone { wake.stop() }   // never leave the mic running out of an abandoned training
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { settings.assistantName = n }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { done = true }
    }
}
#endif // circuit-convert
