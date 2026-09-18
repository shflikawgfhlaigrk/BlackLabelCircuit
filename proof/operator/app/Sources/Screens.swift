#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// Click/⌘K are pointer+keyboard affordances; the touch shell uses tap + Search.
#if os(macOS)
private let kPromptLibraryBlurb = "Reusable prompts you drop into The Brain with one click or ⌘K."
#else
private let kPromptLibraryBlurb = "Reusable prompts you drop into The Brain with one tap or Search."
#endif

// MARK: - Privacy-pane deep links (every TCC capability the app gates on)

/// The System Settings privacy panes Sovereign's capabilities are gated on. macOS supports deep
/// linking straight to each pane, so every denial surface offers the link instead of leaving the
/// buyer to navigate System Settings by prose. One enum holds every destination — a capability
/// cannot gain a TCC gate without gaining its pane here.
enum PrivacyPane: String {
    case calendars = "Privacy_Calendars"
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"
    case microphone = "Privacy_Microphone"
    case speechRecognition = "Privacy_SpeechRecognition"

    /// Deep link into System Settings → Privacy & Security → (pane).
    var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")! }

    /// Open the pane. macOS only — System Settings deep links do not exist on iOS, and no iOS
    /// surface offers one.
    func open() {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Notes vault row + editor (shared by the Knowledge screen)
struct NoteRowView: View {
    let note: Note; let tap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: tap) {
            HStack(spacing: 14) {
                Image(systemName: "doc.text.fill").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.ink)
                    .frame(width: 34, height: 34).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: BLTheme.gold.opacity(0.3), radius: 5, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title.isEmpty ? "Untitled note" : note.title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(note.preview).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                }
                Spacer()
                Text(note.updated.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            .padding(16).background(BLTheme.panelGrad).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(hover ? BLTheme.gold.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
            .shadow(color: hover ? BLTheme.gold.opacity(0.12) : .black.opacity(0.2), radius: hover ? 14 : 8, y: 5)
        }.buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hover = h } }
    }
}

struct NoteEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit note").font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Field(title: "Title", text: $note.title, prompt: "Note title")
            VStack(alignment: .leading, spacing: 4) {
                Text("BODY").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $note.body).font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 220).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            }
            HStack {
                Button("Delete", role: .destructive) { model.deleteNote(note); dismiss() }
                    .buttonStyle(.plain).foregroundColor(Color(hex: 0xFF6B6B))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                GoldButton(label: "Save note", icon: "checkmark") { model.upsert(note); dismiss() }
            }
        }
        .padding(24).keyboardDismissable().sheetWidth(520).background(BLTheme.bg)
    }
}

// MARK: - Weather (real network via open-meteo + CoreLocation geocoding)
struct WeatherScreen: View {
    @EnvironmentObject var settings: AppSettings
    @State private var city = City.all[0]
    @State private var typedPlace = ""
    @State private var weather: CurrentWeather?
    @State private var err: String?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenTitle(title: "Weather", subtitle: "Live current conditions, fetched in real time")
                if !settings.weatherEnabled {
                    Panel(title: "Weather is off", icon: "cloud.sun.fill") {
                        Text("The weather connector is disabled. Turn it on in Settings → Connectors to fetch live conditions.")
                            .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                Panel(title: "Search any city", icon: "magnifyingglass") {
                    HStack(alignment: .bottom, spacing: 12) {
                        Field(title: "City", text: $typedPlace, prompt: "City, ST")
                        GoldButton(label: loading ? "Locating…" : "Get weather", icon: "location.magnifyingglass") { search() }
                            .disabled(loading || typedPlace.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Type any place — Sovereign geocodes it (CoreLocation) and pulls live conditions from \(WeatherInfo.source).")
                        .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
                Panel(title: "Quick pick", icon: "cloud.sun.fill") {
                    HStack {
                        Picker("City", selection: $city) {
                            ForEach(City.all) { Text($0.name).tag($0) }
                        }.pickerStyle(.menu).tint(BLTheme.gold)
                        Spacer()
                        GoldButton(label: loading ? "Loading…" : "Fetch", icon: "arrow.clockwise") { fetchPreset() }
                            .disabled(loading)
                    }
                }
                if let w = weather {
                    Panel(title: w.conditions, icon: "cloud.sun.fill") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                            MetricCard(label: "Temperature", value: String(format: "%.0f°F", w.temperatureF), icon: "thermometer.medium")
                            MetricCard(label: "In Celsius", value: String(format: "%.0f°C", w.temperatureC), icon: "thermometer.snowflake", tint: BLTheme.green)
                            MetricCard(label: "Wind speed", value: String(format: "%.0f mph", w.windMph), icon: "wind", tint: BLTheme.text)
                            if let h = w.humidity {
                                MetricCard(label: "Humidity", value: String(format: "%.0f%%", h), icon: "humidity.fill", tint: BLTheme.holo)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        HStack(spacing: 6) {
                            Circle().fill(BLTheme.green).frame(width: 6, height: 6).shadow(color: BLTheme.green, radius: 3)
                            Text("\(WeatherInfo.attribution) · \(w.place)").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }
                } else if let e = err {
                    Panel(title: "Couldn't load weather", icon: "wifi.exclamationmark") {
                        HStack(spacing: 8) {
                            Image(systemName: "wifi.exclamationmark").foregroundColor(.orange)
                            Text(e).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        }
                    }
                } else {
                    Text("Search a city, or pick one above, for real current conditions.")
                        .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub).padding(.horizontal, 4)
                }
                }
            }.padding(24)
        }
    }

    private func search() {
        let q = typedPlace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        run { await WeatherService.fetch(place: q) }
    }
    private func fetchPreset() { let target = city; run { await WeatherService.fetch(target) } }

    private func run(_ op: @escaping () async -> Result<CurrentWeather, WeatherError>) {
        loading = true; err = nil
        Task { @MainActor in
            let result = await op()
            loading = false
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                switch result {
                case .success(let w): weather = w; err = nil
                case .failure(let e): err = e.rawValue; weather = nil
                }
            }
        }
    }
}

// MARK: - Dashboard (real, honest, live counts only)
struct DashboardScreen: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ai: AIEngine
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var skills: SkillStore
    @EnvironmentObject var prompts: PromptLibrary
    @EnvironmentObject var memory: MemoryStore
    @EnvironmentObject var runtime: Runtime
    @EnvironmentObject var activity: ActivityLog
    @EnvironmentObject var customAgents: CustomAgentStore
    @Binding var route: AppRoute

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                // "Perpetual license" is a macOS sale claim; the iOS build sells/verifies no license.
                #if os(macOS)
                ScreenTitle(title: "Operator", subtitle: "Local workspace. Buyer-selected brain. Perpetual license.")
                #else
                ScreenTitle(title: "Operator", subtitle: "Local workspace. Buyer-selected brain.")
                #endif
                Spacer()
                operatorPill
            }

            // M1 (2026-08-02): a buyer may ALWAYS enter the workspace, brain or no brain. When they
            // arrive unconfigured, the workspace says so up front — what isn't connected, the real
            // limit it imposes, and the one place to fix it. Honest AND usable; never a locked door.
            unconfiguredBanner

            // Capability status — every value read live, nothing simulated.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 14)], spacing: 14) {
                Group {
                    MetricCard(label: "Conversations", value: "\(store.conversations.count)", icon: "bubble.left.and.bubble.right.fill").staggerReveal(0)
                    MetricCard(label: "Messages", value: "\(store.totalMessages)", icon: "text.bubble.fill", tint: BLTheme.green).staggerReveal(1)
                    MetricCard(label: "Knowledge docs", value: "\(store.documents.count)", icon: "doc.text.fill", tint: BLTheme.champagne).staggerReveal(2)
                    MetricCard(label: "Memories", value: "\(memory.injectedCount)", icon: "brain.head.profile", tint: BLTheme.holo).staggerReveal(3)
                    MetricCard(label: "Prompts", value: "\(prompts.all.count)", icon: "text.book.closed.fill", tint: BLTheme.champagne).staggerReveal(4)
                }
                Group {
                    MetricCard(label: "Agents", value: "\(customAgents.agents.count)", icon: "person.2.badge.gearshape.fill", tint: BLTheme.gold).staggerReveal(5)
                    MetricCard(label: "Vault notes", value: "\(model.notes.count)", icon: "note.text", tint: BLTheme.green).staggerReveal(6)
                    MetricCard(label: "Skills", value: "\(skills.all.count)", icon: "wand.and.stars", tint: BLTheme.gold).staggerReveal(7)
                    MetricCard(label: "Automations", value: "\(store.automations.count)", icon: "gearshape.2.fill", tint: BLTheme.holo).staggerReveal(8)
                    MetricCard(label: "Reminders", value: "\(store.upcomingReminders.count)", icon: "bell.fill", tint: BLTheme.champagne).staggerReveal(9)
                    MetricCard(label: "Activity receipts", value: "\(activity.entries.count)", icon: "checklist.checked", tint: BLTheme.green).staggerReveal(10)
                    MetricCard(label: "Brain", value: brainShort, icon: "cpu", tint: brainTint).staggerReveal(11)
                }
            }

            // Quick actions
            Panel(title: "Quick actions", icon: "bolt.shield.fill") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                    quickAction("New conversation", "square.and.pencil") { store.newConversation(); route = .brain }
                    quickAction("Run an agent", "person.2.badge.gearshape.fill") { route = .agents }
                    quickAction("Use a prompt", "text.book.closed.fill") { route = .prompts }
                    quickAction("Add a memory", "brain.head.profile") { route = .memory }
                    quickAction("Add knowledge", "doc.badge.plus") { route = .knowledge }
                    quickAction("Run a skill", "wand.and.stars") { route = .skills }
                    quickAction("New automation", "gearshape.2.fill") { route = .automate }
                }
            }

            // Activity — real, from the brain
            Panel(title: "Recent activity", icon: "list.bullet.rectangle") {
                let recent = recentActivity()
                if recent.isEmpty {
                    Text("No activity yet. Start a conversation, add a document, or run a skill — your real activity appears here.")
                        .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub)
                } else {
                    VStack(spacing: 8) {
                        ForEach(recent, id: \.self) { line in activityRow(line) }
                        Button { route = .activity } label: {
                            HStack(spacing: 6) {
                                Text("View full activity log").font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.gold)
                                Spacer()
                            }.padding(.top, 2)
                        }.buttonStyle(.plain)
                    }
                }
            }

            // Honest storage + selected-brain explainer
            Panel(title: "How Sovereign works", icon: "lock.shield.fill") {
                Text("\(brandName) uses the brain you select: Apple on-device where available, Ornith/Ollama or a loopback server locally, or a provider you connect. " + DataHandlingCopy.storageAndExternal + " Voice output uses Apple speech synthesis. Automations and reminders run while the app is open.")
                    .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).onAppear { brain.resolve() } }
    }

    private var brandName: String { settings.assistantName.isEmpty ? "Sovereign" : settings.assistantName }
    private var brainShort: String {
        switch brain.active {
        case .onDevice: return "On-device"
        case .external: return "External"
        case .ollama(let m), .localEndpoint(let m):
            // Shared Ornith recognition across both local routes; honest "Local" otherwise.
            return OrnithRecommended.matches(m) ? "Ornith" : "Local"
        case .none: return "Offline"
        }
    }
    private var brainTint: Color { brain.isUsable ? BLTheme.green : .orange }

    /// The unconfigured-workspace disclosure. Shown only when no brain can answer; states the
    /// live reason from the router (never a generic guess) plus the exact remedy.
    @ViewBuilder private var unconfiguredBanner: some View {
        if !brain.isUsable {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("No brain connected").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                }
                Text(OnboardingFlowPolicy.unconfiguredNotice)
                    .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                if case .none(let reason) = brain.active, !reason.isEmpty {
                    Text(reason).font(.system(size: 11.5, design: .rounded)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
                GhostButton(label: "Set up a brain", icon: "cpu", tint: BLTheme.gold) { route = .settings }
            }
            .padding(14)
            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.45), lineWidth: 1))
        }
    }

    @ViewBuilder private var operatorPill: some View {
        if brain.isUsable { StatusPill(text: "\(brain.active.label)", tint: BLTheme.green) }
        else { StatusPill(text: "No brain connected", tint: .orange) }
    }

    @ViewBuilder private func quickAction(_ label: String, _ icon: String, _ act: @escaping () -> Void) -> some View {
        Button { withAnimation { act() } } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.ink)
                    .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                Text(label).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.sub)
            }.padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func recentActivity() -> [String] {
        var lines: [(Date, String)] = []
        // Real proof-of-execution receipts lead (the ledger is the authoritative source).
        for e in activity.entries.prefix(8) {
            lines.append((e.at, "\(e.kind.label) · \(e.title)"))
        }
        for c in store.conversations.prefix(6) { lines.append((c.updated, "Conversation · \(c.title)")) }
        return lines.sorted { $0.0 > $1.0 }.prefix(8).map { $0.1 }
    }
    @ViewBuilder private func activityRow(_ line: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundColor(BLTheme.gold)
            Text(line).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
            Spacer()
        }.padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Connectors (HONEST capability surface — every row's status traces to real state)
struct ConnectorsScreen: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var ai: AIEngine
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var externalAuth: ExternalAuth
    @EnvironmentObject var store: Store
    @EnvironmentObject var skills: SkillStore
    @EnvironmentObject var prompts: PromptLibrary
    @EnvironmentObject var memory: MemoryStore
    @EnvironmentObject var calendar: CalendarConnector
    @EnvironmentObject var files: FilesConnector
    @EnvironmentObject var mcp: MCPManager
    @EnvironmentObject var demo: DemoMode
    #if os(macOS)
    @State private var brainAccountBusy: BrainAccountConnector?
    @State private var brainAccountMessage = ""
    #endif

    private struct Connector: Identifiable {
        let id = UUID()
        let name: String, blurb: String, icon: String
        let status: String, tint: Color
        let live: Bool
    }

    private var connectors: [Connector] {
        let brainReady = ai.isReady
        let googleSet = !settings.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let docsOn = store.groundedDocCount > 0
        return [
            Connector(name: "On-device Brain", blurb: "Apple FoundationModels inference runs locally. Web research and connected tools make network requests only when used.",
                      icon: "cpu", status: brainReady ? "Ready" : "Unavailable", tint: brainReady ? BLTheme.green : .orange, live: brainReady),
            Connector(name: "Ornith 1.0 local brain", blurb: "Run Ornith through your own Ollama daemon or any OpenAI-compatible local server (llama.cpp, LM Studio). No account, no API key, no cloud.",
                      icon: "desktopcomputer",
                      status: !settings.ollamaModel.isEmpty ? settings.ollamaModel
                            : (!settings.endpointModel.isEmpty ? settings.endpointModel : "Choose model"),
                      tint: (settings.ollamaModel.isEmpty && settings.endpointModel.isEmpty) ? .orange : BLTheme.green,
                      live: !(settings.ollamaModel.isEmpty && settings.endpointModel.isEmpty)),
            Connector(name: "Multi-step Agent", blurb: "Plan -> act -> verify across safe local tools, with a real receipt for every step. Text-only local brain support is honest about unavailable tools.",
                      icon: "point.3.connected.trianglepath.dotted", status: "Local text route", tint: BLTheme.sub, live: false),
            Connector(name: "Streaming chat", blurb: "Token-by-token replies, markdown & code rendering, multiple saved conversations.",
                      icon: "bubble.left.and.bubble.right.fill", status: "\(store.conversations.count) saved", tint: BLTheme.green, live: true),
            Connector(name: "Memory", blurb: "Standing facts the brain knows about you, injected into every conversation. You decide what's kept.",
                      icon: "brain.head.profile", status: memory.memoryEnabled ? (memory.injectedCount > 0 ? "\(memory.injectedCount) active" : "On · empty") : "Off",
                      tint: memory.memoryEnabled && memory.injectedCount > 0 ? BLTheme.green : BLTheme.sub, live: memory.memoryEnabled && memory.injectedCount > 0),
            Connector(name: "Prompt library", blurb: kPromptLibraryBlurb,
                      icon: "text.book.closed.fill", status: "\(prompts.all.count) prompts", tint: BLTheme.green, live: true),
            Connector(name: "Skills", blurb: "Reusable instruction templates run live over text or a document.",
                      icon: "wand.and.stars", status: "\(skills.all.count) available", tint: BLTheme.green, live: true),
            Connector(name: "Automations", blurb: "Scheduled brain tasks that log real output while the app runs.",
                      icon: "gearshape.2.fill", status: "\(store.automations.filter { $0.enabled }.count) enabled", tint: store.automations.contains { $0.enabled } ? BLTheme.green : BLTheme.sub, live: store.automations.contains { $0.enabled }),
            Connector(name: "Knowledge / RAG", blurb: "Ground replies on your own notes & documents via on-device retrieval.",
                      icon: "doc.text.magnifyingglass", status: docsOn ? "\(store.groundedDocCount) docs grounding" : "No docs enabled",
                      tint: docsOn ? BLTheme.green : BLTheme.sub, live: docsOn),
            Connector(name: "Reminders", blurb: "Native notifications fired on schedule while the app is open.",
                      icon: "bell.fill", status: "\(store.upcomingReminders.count) upcoming", tint: store.upcomingReminders.isEmpty ? BLTheme.sub : BLTheme.green, live: !store.upcomingReminders.isEmpty),
            Connector(name: "Voice output", blurb: "Speaks replies aloud using a system voice you choose. Toggle in Settings.",
                      icon: "speaker.wave.2.fill", status: settings.voiceEnabled ? "On" : "Off",
                      tint: settings.voiceEnabled ? BLTheme.green : BLTheme.sub, live: settings.voiceEnabled),
            Connector(name: "Weather", blurb: "Live current conditions via open-meteo (keyless). Toggle in Settings.",
                      icon: "cloud.sun.fill", status: settings.weatherEnabled ? "Enabled" : "Disabled",
                      tint: settings.weatherEnabled ? BLTheme.green : BLTheme.sub, live: settings.weatherEnabled),
            Connector(name: "Sign in with Apple", blurb: "Native Apple identity — available on a provisioned build carrying the Apple Sign-In entitlement.",
                      icon: "apple.logo",
                      status: AppleSignInCapability.isAvailable ? "Available" : "Needs a provisioned build",
                      tint: AppleSignInCapability.isAvailable ? BLTheme.green : BLTheme.sub,
                      live: AppleSignInCapability.isAvailable),
            Connector(name: "Google sign-in", blurb: "OAuth 2.0 + PKCE using YOUR own client ID. Add it in Settings to enable.",
                      icon: "globe", status: googleSet ? "Configured" : "Not configured",
                      tint: googleSet ? BLTheme.green : BLTheme.sub, live: googleSet)
        ]
    }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(title: "Connectors", subtitle: "Every capability your operator runs — with its real, live status")

            brainAccountConnectors
            // Live, interactive local connectors the buyer grants + controls (real EventKit/files).
            calendarConnector
            filesConnector
            MCPConnectorCard()

            Text("CAPABILITIES").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(1.2).padding(.top, 4)
            ForEach(connectors) { c in connectorRow(c) }
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill").foregroundColor(settings.accent).font(.system(size: 12))
                Text("Status shown above is read live from this app — nothing is simulated. Calendar and Files read only the buyer's own data, only after an explicit grant. Nothing is mined in the background.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, 4)
        }.padding(24) }
        .onAppear { calendar.refreshAccess() }
    }

    // MARK: Claude + Codex account connectors
    // These are brain accounts, not MCP tool servers. They live on the same buyer-facing Connectors
    // screen so "connect my AI" has one obvious path instead of being buried inside Settings.
    @ViewBuilder private var brainAccountConnectors: some View {
        HoloCard(cornerRadius: 15,
                 sweep: BrainAccountConnector.connectedProvider(for: externalAuth.connectedKind) != nil,
                 padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(BLTheme.ink)
                        .frame(width: 38, height: 38)
                        .background(AnyShapeStyle(BLTheme.goldGrad))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI account connectors")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(BLTheme.text)
                        Text("Connect Claude or Codex with your own account. Sovereign launches that provider’s browser sign-in and accepts the connection only after the installed CLI returns a real answer.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    StatusPill(text: BrainAccountConnector.connectedProvider(for: externalAuth.connectedKind) == nil ? "Choose account" : "Connected",
                               tint: BrainAccountConnector.connectedProvider(for: externalAuth.connectedKind) == nil ? .orange : BLTheme.green)
                }

                #if os(macOS)
                ForEach(BrainAccountConnector.allCases) { connector in
                    brainAccountRow(connector)
                }
                if !brainAccountMessage.isEmpty {
                    Text(brainAccountMessage)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(brainAccountMessage.hasPrefix("✓") ? BLTheme.green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                #else
                Text("Claude and Codex account connectors run through their installed command-line apps and are available in the direct Mac download of Sovereign.")
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
        }
    }

    #if os(macOS)
    @ViewBuilder private func brainAccountRow(_ connector: BrainAccountConnector) -> some View {
        let connected = BrainAccountConnector.connectedProvider(for: externalAuth.connectedKind) == connector
        let installed = connector.installedExecutablePath != nil
        let busy = brainAccountBusy == connector
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: connector == .claude ? "sparkles" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(connected ? BLTheme.ink : BLTheme.gold)
                .frame(width: 34, height: 34)
                .background(connected ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(connector.displayName)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(connector == .claude
                     ? "Use your Claude subscription through the installed Claude CLI."
                     : "Use your ChatGPT/OpenAI account through the installed Codex CLI.")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            StatusPill(text: connected ? "Connected" : (busy ? "Checking…" : (installed ? "Ready to sign in" : "CLI needed")),
                       tint: connected ? BLTheme.green : (installed ? BLTheme.gold : .orange))
            if connected {
                GhostButton(label: settings.brainProvider == .external ? "In use" : "Use", icon: "checkmark.circle", tint: BLTheme.green) {
                    settings.brainProvider = .external
                    brain.resolve()
                    brainAccountMessage = "✓ \(connector.displayName) is now the active brain."
                }
                GhostButton(label: "Disconnect", icon: "xmark", tint: BLTheme.danger) {
                    externalAuth.disconnect()
                    if settings.brainProvider == .external { settings.brainProvider = .ollama }
                    brain.resolve()
                    brainAccountMessage = "Disconnected \(connector.displayName). Ornith is active again."
                }
            } else {
                GoldButton(label: busy ? "Connecting…" : "Connect \(connector.displayName)",
                           icon: busy ? "hourglass" : "person.badge.key") {
                    connectBrainAccount(connector)
                }
                .disabled(demo.active || brainAccountBusy != nil)
                .opacity(demo.active || brainAccountBusy != nil ? 0.5 : 1)
            }
        }
        .padding(11)
        .background(BLTheme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func connectBrainAccount(_ connector: BrainAccountConnector) {
        guard brainAccountBusy == nil else { return }
        brainAccountBusy = connector
        brainAccountMessage = "Checking your installed \(connector.displayName) account. If it is signed out, a browser sign-in will open."
        Task { @MainActor in
            let outcome = await BrainAccountConnectionFlow.connect(
                probe: { await probeBrainAccount(connector) },
                signIn: { await BrainAccountLogin.signIn(connector) })
            brainAccountBusy = nil
            switch outcome {
            case .connected(let path):
                switch connector {
                case .claude: externalAuth.connectCLI(cliPath: path)
                case .codex: externalAuth.connectSecondaryCLI(cliPath: path)
                }
                settings.brainProvider = .external
                brain.resolve()
                brainAccountMessage = "✓ Connected \(connector.displayName) with your own account and set it as the active brain."
            case .notInstalled:
                brainAccountMessage = connector == .claude
                    ? "Claude CLI is not installed. Install it with `npm install -g @anthropic-ai/claude-code`, then press Connect Claude again."
                    : "Codex CLI is not installed. Install it with `npm install -g @openai/codex`, then press Connect Codex again."
            case .failed(let message):
                brainAccountMessage = "\(connector.displayName) connection failed: \(message)"
            }
        }
    }

    private func probeBrainAccount(_ connector: BrainAccountConnector) async -> BrainAccountProbeResult {
        switch connector {
        case .claude:
            switch await CLIBrain.probe() {
            case .ok(let path): return .ready(path: path)
            case .notInstalled: return .notInstalled
            case .notLoggedIn: return .notLoggedIn
            case .failed(_, let message): return .failed(message)
            case .unsupportedPlatform: return .failed(CLIProbeResult.unsupportedPlatform.message)
            case .sandboxed: return .failed(CLIProbeResult.sandboxed.message)
            }
        case .codex:
            switch await SecondaryCLIBrain.probe() {
            case .ok(let path): return .ready(path: path)
            case .notInstalled: return .notInstalled
            case .notLoggedIn: return .notLoggedIn
            case .failed(_, let message): return .failed(message)
            case .unsupportedPlatform: return .failed(SecondaryCLIProbeResult.unsupportedPlatform.message)
            case .sandboxed: return .failed(SecondaryCLIProbeResult.sandboxed.message)
            }
        }
    }
    #endif

    // MARK: Calendar connector (real EventKit, permission-primed, buyer-toggled)
    @ViewBuilder private var calendarConnector: some View {
        let granted = calendar.access == .granted
        HoloCard(cornerRadius: 15, sweep: calendar.isReadable, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "calendar").font(.system(size: 15, weight: .bold)).foregroundColor(calendar.isReadable ? BLTheme.ink : BLTheme.sub)
                        .frame(width: 38, height: 38)
                        .background(calendar.isReadable ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calendar").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text("Reads your own upcoming events from Calendar on demand. When a configured external provider answers a request or agent run that uses Calendar, the selected event context needed for it is sent to that provider for processing.")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    StatusPill(text: calendarStatus, tint: calendar.isReadable ? BLTheme.green : (granted ? BLTheme.sub : .orange))
                }
                HStack(spacing: 10) {
                    switch calendar.access {
                    case .notDetermined:
                        GoldButton(label: "Grant calendar access", icon: "lock.open.fill") { calendar.requestAccess() }
                    case .denied:
                        GhostButton(label: "Open System Settings", icon: "gearshape.fill", tint: .orange) {
                            PrivacyPane.calendars.open()
                        }
                        Text("Access denied — enable Sovereign under Privacy → Calendars, then reopen.").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    case .granted:
                        Toggle(isOn: Binding(get: { calendar.enabled }, set: { _ in calendar.enabled.toggle() })) {
                            Text("Use my calendar").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        }.tint(BLTheme.gold)
                        if calendar.isReadable {
                            let n = calendar.upcoming(days: 7).count
                            Text("\(n) event\(n == 1 ? "" : "s") in the next 7 days").font(.system(size: 10.5, design: .monospaced)).foregroundColor(BLTheme.sub)
                        }
                    case .unavailable(let why):
                        Text(why).font(.system(size: 11, design: .rounded)).foregroundColor(.orange)
                    }
                    Spacer()
                }
            }
        }
    }
    private var calendarStatus: String {
        switch calendar.access {
        case .granted: return calendar.enabled ? "On" : "Granted · off"
        case .denied: return "Denied"
        case .notDetermined: return "Not connected"
        case .unavailable: return "Unavailable"
        }
    }

    // MARK: Files connector (buyer-granted folders, indexed into RAG — no background scan)
    @ViewBuilder private var filesConnector: some View {
        HoloCard(cornerRadius: 15, sweep: files.hasContent, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill").font(.system(size: 15, weight: .bold)).foregroundColor(files.hasContent ? BLTheme.ink : BLTheme.sub)
                        .frame(width: 38, height: 38)
                        .background(files.hasContent ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Files").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text("Point at a folder of your own documents. Sovereign indexes the text files so the agent can search them and RAG can ground on them. Only text files, only folders you choose.")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    StatusPill(text: files.hasContent ? "\(files.indexedFileCount) files indexed" : (files.sources.isEmpty ? "No folder" : "Empty"),
                               tint: files.hasContent ? BLTheme.green : BLTheme.sub)
                }
                HStack(spacing: 10) {
                    GoldButton(label: "Add a folder", icon: "plus") { pickFolder() }
                    if files.indexing { ProgressView().controlSize(.small).tint(BLTheme.gold); Text("Indexing…").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub) }
                    if !files.sources.isEmpty {
                        GhostButton(label: "Re-index", icon: "arrow.clockwise", tint: BLTheme.gold) { files.reindexAll() }
                    }
                    Spacer()
                }
                if let e = files.lastError {
                    Text(e).font(.system(size: 10.5, design: .rounded)).foregroundColor(.orange)
                }
                ForEach(files.sources) { s in fileSourceRow(s) }
            }
        }
    }
    @ViewBuilder private func fileSourceRow(_ s: FileSource) -> some View {
        HStack(spacing: 10) {
            Image(systemName: s.enabled ? "folder.fill" : "folder").font(.system(size: 12)).foregroundColor(s.enabled ? BLTheme.gold : BLTheme.sub)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("\(s.fileCount) files · \(s.wordCount) words · \(s.path)").font(.system(size: 9.5, design: .monospaced)).foregroundColor(BLTheme.sub).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { s.enabled }, set: { _ in files.toggle(s) })).labelsHidden().tint(BLTheme.gold)
            Button { files.remove(s) } label: { Image(systemName: "trash").font(.system(size: 11)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Remove file")
        }.padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func pickFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Connect folder"
        panel.message = "Choose a folder of your own documents to index. Only text files are read."
        if panel.runModal() == .OK, let url = panel.url { files.addFolder(url) }
        #else
        iosImportFiles(contentTypes: [], allowsMultiple: false, pickDirectories: true) { urls in
            if let url = urls.first { files.addFolder(url) }
        }
        #endif
    }

    @ViewBuilder private func connectorRow(_ c: Connector) -> some View {
        HoloCard(cornerRadius: 15, sweep: c.live, padding: 16) {
            HStack(spacing: 14) {
                Image(systemName: c.icon).font(.system(size: 15, weight: .bold)).foregroundColor(c.live ? BLTheme.ink : BLTheme.sub)
                    .frame(width: 38, height: 38)
                    .background(c.live ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(BLTheme.stroke.opacity(c.live ? 0 : 1), lineWidth: 1))
                    .shadow(color: c.live ? BLTheme.goldGlow : .clear, radius: 5, y: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.name).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(c.blurb).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                StatusPill(text: c.status, tint: c.tint)
            }
        }
    }
}

// MARK: - MCP (Integrations) connector card
// The UI face of MCP.swift's client. HONEST by construction: shows a true empty state until the
// BUYER adds a server; "Connect" runs a real handshake + tools/list (never faked); "Run" invokes a
// real tool and the result + a proof-of-execution receipt are the server's actual bytes. In Demo
// Mode the sample servers are shown but never dialed (no network), and running is disabled.
struct MCPConnectorCard: View {
    @EnvironmentObject var mcp: MCPManager
    @EnvironmentObject var demo: DemoMode
    @State private var showAdd = false
    @State private var runTool: MCPTool?

    /// This card shows only the buyer's MANUAL servers; one-click catalog connectors (GitHub, …) live
    /// in Settings → Connectors so their Keychain token is managed there, not orphaned by this trash.
    private var manual: [MCPServerConfig] { mcp.manualServers }
    private var manualToolCount: Int { manual.reduce(0) { $0 + mcp.tools(for: $1).count } }

    var body: some View {
        HoloCard(cornerRadius: 15, sweep: !manual.isEmpty, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if manual.isEmpty { emptyState }
                else { ForEach(manual) { server in serverBlock(server) } }
                HStack {
                    GoldButton(label: "Add MCP server", icon: "plus") { showAdd = true }
                    if !manual.isEmpty && !demo.active {
                        GhostButton(label: "Connect all", icon: "arrow.triangle.2.circlepath", tint: BLTheme.gold) {
                            Task { await mcp.discoverAll() }
                        }
                    }
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showAdd) { MCPAddServerSheet().environmentObject(mcp).sheetCloseBar() }
        .sheet(item: $runTool) { tool in
            if let server = mcp.servers.first(where: { $0.name == tool.server }) {
                MCPToolRunSheet(server: server, tool: tool).environmentObject(mcp).sheetCloseBar()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 15, weight: .bold))
                .foregroundColor(manual.isEmpty ? BLTheme.sub : BLTheme.ink)
                .frame(width: 38, height: 38)
                .background(manual.isEmpty ? AnyShapeStyle(BLTheme.bg2) : AnyShapeStyle(BLTheme.goldGrad))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom MCP servers").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("Point your operator at your OWN Model Context Protocol servers (HTTP). It discovers their real tools and can run them — every call is a real receipt. Nothing is bundled. (One-click providers like GitHub live in Settings → Connectors.)")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            StatusPill(text: manual.isEmpty ? "None configured" : "\(manual.count) server\(manual.count == 1 ? "" : "s") · \(manualToolCount) tool\(manualToolCount == 1 ? "" : "s")",
                       tint: manual.isEmpty ? BLTheme.sub : BLTheme.green)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundColor(BLTheme.sub).font(.system(size: 12))
            // The stdio caveat is about the sandboxed Mac App Store build — meaningless on iPhone.
            #if os(macOS)
            Text("No MCP servers configured. Add your own server's HTTPS endpoint to give your operator new tools — calendars, issue trackers, your files, anything that speaks MCP over HTTP. (The stdio transport isn't available in the sandboxed Mac App Store build.)")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            #else
            Text("No MCP servers configured. Add your own server's HTTPS endpoint to give your operator new tools — calendars, issue trackers, your files, anything that speaks MCP over HTTP.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            #endif
        }.padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func serverBlock(_ s: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").font(.system(size: 12)).foregroundColor(BLTheme.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(s.url).font(.system(size: 9.5, design: .monospaced)).foregroundColor(BLTheme.sub).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                StatusPill(text: statusText(s), tint: statusTint(s))
                if !demo.active {
                    Button { Task { await mcp.discover(s) } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11)).foregroundColor(BLTheme.gold)
                    }.buttonStyle(.plain).help("Connect & discover tools")
                }
                Button { mcp.removeServer(s) } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                }.buttonStyle(.plain)
            }
            if case .failed(let why) = mcp.status(for: s) {
                Text(why).font(.system(size: 10.5, design: .rounded)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(mcp.tools(for: s)) { tool in toolRow(s, tool) }
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func toolRow(_ s: MCPServerConfig, _ tool: MCPTool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver").font(.system(size: 10)).foregroundColor(BLTheme.sub)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundColor(BLTheme.text)
                if !tool.desc.isEmpty {
                    Text(tool.desc).font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if demo.active {
                Text("Sample").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
            } else {
                GhostButton(label: "Run", icon: "play.fill", tint: BLTheme.gold) { runTool = tool }
            }
        }.padding(.leading, 4)
    }

    private func statusText(_ s: MCPServerConfig) -> String {
        switch mcp.status(for: s) {
        case .idle:                       return demo.active ? "Sample" : "Not connected"
        case .connecting:                 return "Connecting…"
        case .connected(let n):           return "Connected · \(n) tool\(n == 1 ? "" : "s")"
        case .failed:                     return "Failed"
        }
    }
    private func statusTint(_ s: MCPServerConfig) -> Color {
        switch mcp.status(for: s) {
        case .connected: return BLTheme.green
        case .failed:    return .orange
        default:         return BLTheme.sub
        }
    }
}

// MARK: Add-server sheet (the buyer enters THEIR own server — never bundled)
struct MCPAddServerSheet: View {
    @EnvironmentObject var mcp: MCPManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var authHeader = ""
    @State private var authValue = ""

    private var draft: MCPServerConfig {
        MCPServerConfig(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "MCP server" : name,
                        url: url, authHeader: authHeader, authValue: authValue)
    }
    private var canAdd: Bool { draft.isValidURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add an MCP server").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text("Enter your own server's HTTPS endpoint (Streamable HTTP / JSON-RPC 2.0). An optional auth value is stored locally and sent to that server only as authentication.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            field("Name", "My MCP server", $name)
            field("Server URL", "https://your-mcp-server.example/mcp", $url)
            HStack(spacing: 10) {
                field("Auth header (optional)", "Authorization", $authHeader)
                field("Auth value (optional)", "Bearer …", $authValue)
            }
            if !url.isEmpty && !draft.isValidURL {
                Text("Enter a valid http/https URL.").font(.system(size: 10.5, design: .rounded)).foregroundColor(.orange)
            }
            HStack {
                GhostButton(label: "Cancel", icon: "xmark", tint: BLTheme.sub) { dismiss() }
                Spacer()
                GoldButton(label: "Add & connect", icon: "checkmark") {
                    let s = draft
                    mcp.addServer(s)
                    Task { await mcp.discover(s) }
                    dismiss()
                }.disabled(!canAdd).opacity(canAdd ? 1 : 0.5)
            }
        }
        .padding(24).sheetWidth(460)
        .background(BLTheme.bg)
    }

    @ViewBuilder private func field(_ label: String, _ placeholder: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(1)
            TextField(placeholder, text: binding)
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundColor(BLTheme.text)
                .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
        }
    }
}

// MARK: Tool-run sheet (a REAL tools/call against the buyer's server — output is the real bytes)
struct MCPToolRunSheet: View {
    let server: MCPServerConfig
    let tool: MCPTool
    @EnvironmentObject var mcp: MCPManager
    @Environment(\.dismiss) private var dismiss
    @State private var args: [String: String] = [:]
    @State private var running = false
    @State private var result: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tool.name).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.text)
            if !tool.desc.isEmpty {
                Text(tool.desc).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            if tool.paramNames.isEmpty {
                Text("This tool takes no arguments.").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
            } else {
                ForEach(tool.paramNames, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(p).font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.sub)
                            if tool.requiredParams.contains(p) { Text("required").font(.system(size: 8.5, weight: .bold)).foregroundColor(.orange) }
                        }
                        TextField("value", text: Binding(get: { args[p] ?? "" }, set: { args[p] = $0 }))
                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundColor(BLTheme.text)
                            .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                }
            }
            if let r = result {
                ScrollView {
                    Text(r).font(.system(size: 11, design: .monospaced)).foregroundColor(isError ? .orange : BLTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 220)
                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                GhostButton(label: "Close", icon: "xmark", tint: BLTheme.sub) { dismiss() }
                Spacer()
                if running { ProgressView().controlSize(.small).tint(BLTheme.gold) }
                GoldButton(label: "Run tool", icon: "play.fill") { run() }.disabled(running).opacity(running ? 0.5 : 1)
            }
        }
        .padding(24).sheetWidth(480)
        .background(BLTheme.bg)
    }

    private func run() {
        running = true; result = nil
        // Only non-empty args are sent; the server validates required params (we surface its real error).
        let payload: [String: Any] = args.reduce(into: [:]) { acc, kv in
            let v = kv.value.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { acc[kv.key] = MCPRPC.coerceArgument(v, schemaType: tool.paramTypes[kv.key]) }
        }
        Task {
            let out = await mcp.callTool(server: server, tool: tool.name, arguments: payload)
            await MainActor.run {
                running = false
                if let out = out { result = out.text; isError = out.isError }
                else { result = "The tool call failed — see Activity for the receipt."; isError = true }
            }
        }
    }
}
#endif // circuit-convert
