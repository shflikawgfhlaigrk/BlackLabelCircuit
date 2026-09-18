#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — The Brain: multi-conversation streaming chat with markdown/code rendering,
// per-message copy & regenerate, document drop for analysis, persona selection, conversation
// search, and export. Streams token-by-token from the chosen brain. No fabrication —
// when the model is unavailable, an honest banner replaces the composer.
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ChatScreen: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var ai: AIEngine
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var voice: VoiceEngine
    @EnvironmentObject var dictation: DictationEngine
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var memory: MemoryStore
    @EnvironmentObject var crm: ClientStore
    @EnvironmentObject var activity: ActivityLog
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var externalAuth: ExternalAuth   // backs the chat brain picker's account route

    // SV-05 — the REAL brains the chat-header picker offers. Loaded from the buyer's own Ollama
    // (/api/tags) and their local server; a failed load leaves these empty, which honestly shrinks
    // the menu rather than inventing a row for a model they don't have.
    @State private var installedLocalModels: [OllamaModel] = []
    @State private var endpointModelIDs: [String] = []

    @State private var draft = ""
    @State private var dictationBase = ""   // draft text captured when dictation starts
    // Hands-free VOICE OPERATOR: true while a wake-initiated turn is in flight, so when on-device
    // dictation finalizes we auto-send the request to the LOCAL brain (which speaks its reply back
    // via TTS when voiceEnabled). This is what makes wake → STT → tool-loop → TTS ONE path instead
    // of just filling the composer. Reset the moment the turn is consumed or abandoned. See VoiceOperator.
    @State private var voiceTurnActive = false
    @State private var convoSearch = ""
    @State private var streamingText = ""        // live cumulative text for the in-flight reply
    @State private var streamingMessageID: UUID?
    // The conversation that OWNS the in-flight stream (captured when the placeholder is appended).
    // Stop/cancel must write into THIS conversation — the buyer may have switched to another one
    // mid-generation, and activeConversationID would corrupt the switched-to chat's last reply.
    @State private var streamingConvoID: UUID?
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var dropTargeted = false
    @State private var attachedDocName: String?
    @State private var attachedDocBody: String = ""
    // An honest reason a dropped/imported file produced no grounding (scan/empty/too-large/unreadable).
    // §5.1: a dropped file must never silently no-op — the buyer sees why it couldn't attach.
    @State private var attachedDocError: String?
    @State private var attachedImages: [BrainImage] = []   // image attachments (External vision)
    @State private var pendingDesktopReviewPrompt = ""
    @State private var pendingDesktopReviewConvoID: UUID?
    @State private var pendingDesktopReviewImages: [BrainImage] = []
    @State private var desktopReviewBusy = false
    // A dropped document now PERSISTS across follow-up turns; this binds it to the conversation it
    // was first sent in so it can never ground a DIFFERENT chat (nil = freshly dropped, not yet sent).
    @State private var attachedDocConvoID: UUID? = nil
    @State private var lastCitations: [RetrievedChunk] = [] // sources used for the last reply
    // Which conversation those citations belong to. The "Sources" bar must show ONLY under that
    // conversation; otherwise a RAG reply's document citations bleed onto a different (or new) chat
    // after a switch — a real misattribution of the buyer's own files. See citationsVisible().
    @State private var lastCitationsConvoID: UUID? = nil
    // SV-07 — the REAL web pages the last reply cited (web_search / url_context). Kept separate from
    // the document chunks above because they are a different kind of provenance (a live URL the buyer
    // can open, not a file they own). Populated ONLY through WebAnswerGate, so a chip here always
    // means: this page was really fetched AND the reply really cited it. A phantom "[7]" never lands.
    @State private var lastWebSources: [WebSource] = []
    @State private var lastWebSourcesConvoID: UUID? = nil   // same anti-misattribution binding as docs
    @State private var lastWebUncited = false               // sources were read, the reply cited none
    @State private var savedMessageID: UUID?
    @State private var showConvoDrawer = false       // iOS compact: conversation list as a slide-over
    // Inline first-run brain AUTO-SETUP — SAME OrnithSetupModel the onboarding stepBrain drives, so a
    // no-brain buyer sets up the shipped local brain WITHOUT being bounced to Settings (Founder B37).
    @StateObject private var ornith = OrnithSetupModel()
    @FocusState private var composerFocused: Bool
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var isPhone: Bool { hSize == .compact }
    #else
    private var isPhone: Bool { false }
    #endif

    private var active: Conversation? { store.activeConversation }

    // macOS: a draggable HSplitView (conversation list | chat pane). On iPad (regular width) the
    // same side-by-side HStack is fine. On iPhone (compact) a fixed 230-340pt list would eat the
    // screen, so the list becomes a slide-over drawer toggled from the chat header.
    @ViewBuilder private var splitBody: some View {
        #if os(macOS)
        HSplitView {
            conversationList
                .frame(minWidth: 230, idealWidth: 264, maxWidth: 340)
            chatPane
        }
        #else
        if isPhone {
            phoneBody
        } else {
            HStack(spacing: 0) {
                conversationList
                    .frame(minWidth: 230, idealWidth: 264, maxWidth: 340)
                chatPane
            }
        }
        #endif
    }

    // iPhone: chat fills the screen; the conversation list slides over from the left on demand.
    @ViewBuilder private var phoneBody: some View {
        ZStack(alignment: .leading) {
            chatPane
            if showConvoDrawer {
                Color.black.opacity(0.45).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showConvoDrawer = false } }
                conversationList
                    .frame(width: 300)
                    .background(BLTheme.bg2)
                    .overlay(alignment: .trailing) { Rectangle().fill(BLTheme.stroke).frame(width: 1) }
                    .transition(.move(edge: .leading))
                    .shadow(color: .black.opacity(0.4), radius: 16, x: 6)
            }
        }
        // Tapping a conversation closes the drawer.
        .onChange(of: store.activeConversationID) { _ in
            if showConvoDrawer { withAnimation(.easeOut(duration: 0.2)) { showConvoDrawer = false } }
        }
    }

    var body: some View {
        splitBody
        .onAppear { store.ensureActiveConversation(); brain.resolve(); brain.prewarm(); consumeBrainIntent() }
        .onChange(of: nav.brainIntent) { _ in consumeBrainIntent() }
        .sheet(item: $renaming) { c in renameSheet(c).sheetCloseBar() }
        .onReceive(NotificationCenter.default.publisher(for: .sovStop)) { _ in
            if brain.thinking { brain.cancel(); finalizeStream(cancelled: true) }
        }
        // Wake word heard: go hands-free — start dictation into the composer exactly like
        // tapping the mic, so the buyer can just keep talking. When voice OUTPUT is on this is a full
        // hands-free operator turn: the finalized transcript auto-sends to the local brain (below).
        .onReceive(NotificationCenter.default.publisher(for: .sovereignWake)) { _ in
            guard dictation.available, !dictation.listening else { return }
            dictationBase = draft
            // A wake-initiated turn with voice output on runs the full loop; otherwise it's plain
            // hands-free dictation into the composer (unchanged behavior).
            voiceTurnActive = settings.voiceEnabled
            dictation.start { t in draft = dictationBase.isEmpty ? t : dictationBase + " " + t }
            composerFocused = true
        }
        // Hands-free auto-send: when the on-device recognizer finalizes (dictation.listening flips to
        // false) during a voice-operator turn, send the captured request to the LOCAL brain — closing
        // wake → STT → (brain + tool-loop) → TTS as one path. Only REAL speech is sent (VoiceOperator
        // gates out an empty capture or a bare wake-phrase echo, which would loop). §5.1: never
        // synthesizes a request the buyer didn't speak.
        .onChange(of: dictation.listening) { listening in
            guard !listening, voiceTurnActive else { return }
            voiceTurnActive = false
            let spoken = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard VoiceOperator.shouldAutoSend(transcript: spoken, wakePhrase: settings.wakePhrase),
                  !brain.thinking else { return }
            // Strip a leading wake-phrase echo so the brain sees just the command.
            draft = VoiceOperator.strippingLeadingWake(spoken, phrase: settings.wakePhrase)
            if draft.isEmpty { draft = spoken }
            send()
        }
    }

    /// Drain a Brain-scoped intent stashed on `Nav` by an off-screen trigger (the global ⌥Space
    /// quick-ask, the ⌘N/⌘O menu shortcuts, a ⌘K "insert prompt"). Routing to Brain mounts this
    /// screen with the intent already set, so `.onAppear` runs it reliably even when the window was
    /// on another screen — fixing the silent loss where the notification fired before ChatScreen
    /// existed. Same idiom as the activityTarget/knowledgeTarget deep-links; cleared once it runs.
    private func consumeBrainIntent() {
        guard let intent = nav.brainIntent else { return }
        switch intent {
        case .newConversation:
            withAnimation { store.newConversation(); draft = ""; clearAttachment() }
        case .search:
            composerFocused = false
        case .attach:
            importDocument()
        case .insertPrompt(let body):
            store.ensureActiveConversation()
            draft = body
            composerFocused = true
        case .quickAsk(let text):
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { break }
            store.newConversation()
            draft = body
            send()
        }
        nav.brainIntent = nil
    }

    // MARK: - Conversation list (searchable, pin, rename, delete, export)
    private var conversationList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Conversations").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Button { withAnimation { store.newConversation(); draft = ""; clearAttachment() } } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.gold)
                }.buttonStyle(.plain).help("New conversation (⌘N)")
            }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                TextField("Search conversations", text: $convoSearch)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text)
                if !convoSearch.isEmpty {
                    Button { convoSearch = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.vertical, 7).padding(.horizontal, 10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
            .padding(.horizontal, 12).padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredConversations) { c in convoRow(c) }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }
        }
        .background(BLTheme.bg2.opacity(0.5))
    }

    private var filteredConversations: [Conversation] {
        let q = convoSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let base = store.sortedConversations
        guard !q.isEmpty else { return base }
        return base.filter { $0.title.range(of: q, options: .caseInsensitive) != nil || $0.messages.contains { $0.text.range(of: q, options: .caseInsensitive) != nil } }
    }

    @ViewBuilder private func convoRow(_ c: Conversation) -> some View {
        let isActive = c.id == store.activeConversationID
        Button { withAnimation { store.activeConversationID = c.id; clearAttachment() } } label: {
            HStack(spacing: 9) {
                Image(systemName: c.pinned ? "pin.fill" : "bubble.left.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundColor(isActive ? BLTheme.ink : BLTheme.gold)
                    .frame(width: 24, height: 24)
                    .background(isActive ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.gold.opacity(0.10)))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title).font(.system(size: 12.5, weight: isActive ? .bold : .semibold, design: .rounded))
                        .foregroundColor(isActive ? BLTheme.text : BLTheme.sub).lineLimit(1)
                    Text(c.preview).font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.mute).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7).padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(isActive ? BLTheme.gold.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? BLTheme.gold.opacity(0.25) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu {
            Button(c.pinned ? "Unpin" : "Pin") { store.togglePin(c.id) }
            Button("Rename") { renaming = c; renameText = c.title }
            Button("Export…") { exportConversation(c) }
            Divider()
            Button("Delete", role: .destructive) { withAnimation { store.deleteConversation(c.id) } }
        }
    }

    @ViewBuilder private func renameSheet(_ c: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename conversation").font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Field(title: "Title", text: $renameText, prompt: "Conversation title")
            HStack { Spacer()
                Button("Cancel") { renaming = nil }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                GoldButton(label: "Save", icon: "checkmark") { store.renameConversation(c.id, to: renameText); renaming = nil }
            }
        }.padding(24).keyboardDismissable().sheetWidth(420).background(BLTheme.bg)
    }

    // MARK: - Chat pane
    private var chatPane: some View {
        VStack(spacing: 0) {
            header
            if case .none(let reason) = brain.active { unavailableBanner(reason) }
            messageScroller
            if Self.citationsVisible(hasCitations: !lastCitations.isEmpty, citationsConvo: lastCitationsConvoID, activeConvo: store.activeConversationID) { citationsBar }
            if Self.citationsVisible(hasCitations: !lastWebSources.isEmpty, citationsConvo: lastWebSourcesConvoID, activeConvo: store.activeConversationID) { webSourcesBar }
            if pendingDesktopReviewConvoID == store.activeConversationID { desktopReviewAccessBanner }
            if let name = attachedDocName,
               Self.attachmentApplies(attachmentConvo: attachedDocConvoID, activeConvo: store.activeConversationID) {
                attachmentChip(name)
            }
            if !attachedImages.isEmpty { imageChips }
            if let err = attachedDocError { attachmentErrorChip(err) }
            composer
        }
        .onDrop(of: [.fileURL, .plainText], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
        .overlay { if dropTargeted { dropOverlay } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // iPhone: open the conversation-list drawer + start a new conversation (the macOS
            // sidebar's affordances surfaced as visible, finger-sized buttons).
            if isPhone {
                Button { withAnimation(.easeOut(duration: 0.2)) { showConvoDrawer.toggle() } } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 17, weight: .bold)).foregroundColor(BLTheme.gold)
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Conversations")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(active?.title ?? "The Brain").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                Text(brainSubtitle).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            availabilityPill
            if settings.voiceEnabled { StatusPill(text: voice.speaking ? "Speaking" : "Voice on", tint: voice.speaking ? settings.accent : BLTheme.sub) }
            Spacer()
            researchToggle
            brainMenu
            personaMenu
            if voice.speaking { GhostButton(label: "Stop voice", icon: "stop.fill", tint: BLTheme.danger) { voice.stop() } }
            GhostButton(label: "Clear", icon: "trash", tint: BLTheme.sub) {
                withAnimation {
                    store.clearActiveMessages(); brain.resetSession()
                    lastCitations = []; lastCitationsConvoID = nil
                    lastWebSources = []; lastWebSourcesConvoID = nil; lastWebUncited = false
                    voice.stop()
                }
            }.help("Clear this conversation")
        }.padding(20).padding(.bottom, 6)
    }

    /// Research-mode toggle: ON routes every question through live web research
    /// (search → read → cite) with the active brain as summarizer. The pill reflects
    /// the real persisted setting — green when live.
    private var researchToggle: some View {
        Button {
            settings.researchMode.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe").font(.system(size: 11, weight: .semibold))
                Text(settings.researchMode ? "Research on" : "Research")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundColor(settings.researchMode ? BLTheme.ink : BLTheme.sub)
            .padding(.vertical, 6).padding(.horizontal, 11)
            .background(settings.researchMode ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(settings.researchMode ? settings.accent.opacity(0.8) : BLTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(settings.researchMode
              ? "Research mode is ON — every question searches the web, reads the top pages, and answers with cited sources."
              : "Turn on research mode — every question searches the web and answers with cited sources.")
        .accessibilityLabel("Web research mode")
    }

    // MARK: Brain picker (SV-05) — every provider/model the buyer really has, 2 clicks from chat
    /// The model library used to live only in Settings, which put a brain swap 3+ clicks and a screen
    /// away from the conversation you wanted to swap it for. This is the same library's decision map
    /// (`BrainSwap.plan`) surfaced where it's used: ONE click opens this menu, ONE click switches the
    /// brain. The menu is FLAT — no submenus — so every route is exactly 2 clicks (`BrainMenuEntry
    /// .clicks`), and the rows are built by the pure `ChatBrainMenu.entries` from what is genuinely
    /// installed/connected, so a dead route is never offered as a live one (§5.1). The last row
    /// NAVIGATES to the full library rather than pretending to be a brain.
    private var brainMenu: some View {
        let entries = ChatBrainMenu.entries(
            installed: installedLocalModels, endpointModels: endpointModelIDs,
            appleReady: ai.isReady, externalConnected: externalAuth.isConnected,
            provider: settings.brainProvider, ollamaModel: settings.ollamaModel,
            endpointModel: settings.endpointModel)
        return Menu {
            if entries.isEmpty {
                // Honest empty state: nothing can answer yet, so offer no false swap.
                Text("No brain is set up yet")
            } else {
                ForEach(entries) { e in
                    Button {
                        applyBrainSwap(e)
                    } label: {
                        // The active row is checked — the buyer can see which brain is answering.
                        Label(e.isActive ? "✓ \(e.title)" : e.title, systemImage: brainIcon(e.route))
                    }
                }
            }
            Divider()
            Button("Model library…") { nav.route = .settings }   // navigation, not a brain — never a fake swap
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu").font(.system(size: 11, weight: .semibold))
                Text(activeBrainLabel).font(.system(size: 11.5, weight: .semibold, design: .rounded)).lineLimit(1)
            }.foregroundColor(BLTheme.sub)
            .padding(.vertical, 6).padding(.horizontal, 11).background(BLTheme.bg2).clipShape(Capsule())
            .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Switch the brain — every model and provider you have set up is one click away")
        .accessibilityLabel("Switch brain")
        .task { await loadBrainMenuSources() }
    }

    private func brainIcon(_ r: ModelRoute) -> String {
        switch r {
        case .ollama: return "desktopcomputer"
        case .localEndpoint: return "server.rack"
        case .appleOnDevice: return "apple.logo"
        case .advanced: return "cloud"
        }
    }

    /// The pill's label: the brain answering right now, named honestly (never "Ornith" for a model
    /// that isn't one).
    private var activeBrainLabel: String {
        switch brain.active {
        case .onDevice: return "Apple"
        case .external: return "Account"
        case .ollama(let m), .localEndpoint(let m):
            return OrnithRecommended.matches(m) ? "Ornith" : m
        case .none: return "Brain"
        }
    }

    /// Apply a swap from the chat menu through the SAME pure plan the Settings library uses, so the
    /// two surfaces cannot drift. Resets the session so the next turn is answered by the new brain.
    private func applyBrainSwap(_ e: BrainMenuEntry) {
        let plan = e.swapPlan
        switch e.route {
        case .ollama: settings.ollamaModel = plan.modelID
        case .localEndpoint: settings.endpointModel = plan.modelID
        case .appleOnDevice, .advanced: break      // no per-model id on these routes
        }
        settings.brainProvider = plan.provider
        brain.resolve()
        brain.resetSession()
    }

    /// Load the REAL local model lists that back the menu: the buyer's installed Ollama models
    /// (/api/tags) and whatever their local server lists. Best-effort — a failure leaves the lists
    /// empty, which honestly shrinks the menu rather than inventing rows.
    private func loadBrainMenuSources() async {
        let port = settings.endpointPort
        async let ollama = (try? await OllamaBrain().listModels()) ?? []
        async let endpoint = (try? await OpenAIEndpointBrain().listModels(port: port)) ?? []
        let (models, ids) = await (ollama, endpoint)
        await MainActor.run {
            installedLocalModels = models
            endpointModelIDs = ids
        }
    }

    private var personaMenu: some View {
        Menu {
            Button("Default persona") { setPersona("") }
            if !profiles.profiles.isEmpty {
                Divider()
                ForEach(profiles.profiles) { p in Button(p.name) { setPersona(p.name) } }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle").font(.system(size: 11, weight: .semibold))
                Text(active?.personaName.isEmpty == false ? active!.personaName : "Persona").font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }.foregroundColor(BLTheme.sub)
            .padding(.vertical, 6).padding(.horizontal, 11).background(BLTheme.bg2).clipShape(Capsule())
            .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
        }.menuStyle(.borderlessButton).fixedSize().help("Switch the persona for this conversation")
    }
    private func setPersona(_ name: String) {
        guard let id = store.activeConversationID, let i = store.conversations.firstIndex(where: { $0.id == id }) else { return }
        store.conversations[i].personaName = name
        brain.resetSession()
    }

    private var brainSubtitle: String {
        // "on this Mac" is only true where the daemon actually runs; iOS surfaces stay neutral.
        #if os(macOS)
        let inferenceNote = "model inference on this Mac"
        #else
        let inferenceNote = "local model inference"
        #endif
        switch brain.active {
        case .onDevice: return "On-device · Apple model inference on this device"
        case .external(let m):
            if m == "Secondary CLI" { return "External CLI" }
            if m == "Custom CLI" { return "Your custom CLI" }
            return "External account · \(m)"
        case .ollama(let m):
            // "Ornith" only when an ornith model is actually answering — honest for any other tag.
            return OrnithRecommended.matches(m)
                ? "Ornith · \(m) · \(inferenceNote)"
                : "Ollama · \(m) · \(inferenceNote)"
        case .localEndpoint(let m):
            return OrnithRecommended.matches(m)
                ? "Ornith · \(m) · \(inferenceNote)"
                : "Local server · \(m) · \(inferenceNote)"
        case .none: return "No brain connected"
        }
    }
    @ViewBuilder private var availabilityPill: some View {
        switch brain.active {
        case .onDevice: StatusPill(text: "On-device", tint: BLTheme.green)
        case .external(let m):
            StatusPill(text: m == "Secondary CLI" ? "External CLI" : (m == "Custom CLI" ? "Custom CLI" : "External"), tint: BLTheme.gold)
        case .ollama(let m), .localEndpoint(let m):
            // Shared Ornith recognition across BOTH local routes; non-ornith models say "Local".
            StatusPill(text: OrnithRecommended.matches(m) ? "Ornith" : "Local", tint: BLTheme.green)
        case .none: StatusPill(text: "Not connected", tint: .orange)
        }
    }

    @ViewBuilder private func unavailableBanner(_ reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(reason).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            Spacer()
            // Day-one escape hatch: never strand the buyer on the chat screen with no brain. One tap
            // jumps to Settings → Brain, where the "Set up your free local brain" flow lives.
            GhostButton(label: "Set up a brain", icon: "sparkles", tint: settings.accent) {
                NotificationCenter.default.post(name: .sovRoute, object: AppRoute.settings)
            }
        }
        .padding(14).background(Color.orange.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 20).padding(.bottom, 4)
    }

    private var messageScroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if (active?.messages.isEmpty ?? true) && streamingMessageID == nil {
                        emptyChat.padding(.top, 60)
                    }
                    ForEach(active?.messages ?? []) { m in bubble(m).id(m.id) }
                    if brain.thinking && streamingText.isEmpty {
                        thinkingRow.id("thinking")
                    }
                    if let e = brain.lastError {
                        Text(e).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(Color(hex: 0xFF6B6B)).padding(.horizontal, 20)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 16)
            }
            .onChange(of: active?.messages.count ?? 0) { _ in scrollToEnd(proxy) }
            .onChange(of: streamingText) { _ in scrollToEnd(proxy) }
        }
    }
    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = active?.messages.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
    }

    private var emptyChat: some View {
        VStack(spacing: 16) {
            // Blank-device guided setup: if no brain is usable yet, walk the user to set one up
            // instead of letting the first message fail. Ornith ships as the default; this appears
            // only when it (and every other brain) isn't ready on this Mac.
            if !brain.isUsable {
                brainSetupCard
            }
            EmptyState(icon: "sparkles", title: "Your assistant workspace",
                       hint: "Ask anything, drop a document to analyze, or pick a starter below. " + DataHandlingCopy.storageAndExternal)
            // The four capsules fit the wide mac canvas as-is; a 390pt phone needs them to scroll
            // sideways instead of compressing into tall multi-line slivers.
            #if os(iOS)
            ScrollView(.horizontal, showsIndicators: false) { starterChips }
            #else
            starterChips
            #endif
        }
    }

    private var starterChips: some View {
        HStack(spacing: 10) {
            ForEach(["Summarize my day", "Draft an email", "Explain a concept", "Plan a project"], id: \.self) { s in
                Button { draft = s; composerFocused = true } label: {
                    Text(s).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                        .padding(.vertical, 8).padding(.horizontal, 13).background(BLTheme.bg2).clipShape(Capsule())
                        .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }

    /// Guided first-run brain setup, shown when no brain is usable (a blank device before Ornith
    /// is installed). Founder B37: "Set it up in one tap" now runs the SAME inline `OrnithSetupModel`
    /// auto-setup the onboarding stepBrain drives — detect Ollama → guide the one free helper →
    /// live-progress pull → select — INSTEAD of bouncing the buyer to Settings. Every line reflects a
    /// real probe/pull (§5.1); connecting Claude/Codex/Apple stays a small documented Advanced link.
    private var brainSetupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cpu").foregroundColor(settings.accent)
                Text("Set up your brain").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            }

            #if os(iOS)
            // iPhone/iPad first run: the Ornith/Ollama helper flow probes 127.0.0.1:11434, which can
            // never exist on iOS — that card would spin on "waiting for the helper" forever. The two
            // routes that genuinely work here are Apple's on-device model (when Apple Intelligence is
            // ready) and a connected provider account. §5.1: the Apple button appears only when the
            // real availability probe says the model can answer.
            if ai.foundationModelsAvailable {
                Text("Apple Intelligence is ready on this device — private, free, offline. One tap and chat works.")
                    .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                GoldButton(label: "Use Apple Intelligence (on-device)", icon: "apple.logo") {
                    settings.brainProvider = .onDevice
                    brain.resolve()
                }
            } else {
                Text("Apple\u{2019}s on-device model needs Apple Intelligence enabled on this device. Until it is, connect your own Claude account (API key) in Settings and chat runs through it.")
                    .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            GoldButton(label: "Connect a brain in Settings", icon: "link") { nav.route = .settings }
            #else
            switch ornith.phase {
            case .idle:
                Text("Sovereign ships with **Ornith** — a private brain that runs on this Mac. Set it up in one tap, or connect Claude / Codex (API or CLI) or Apple Intelligence. Until then, chat has no brain to answer with.")
                    .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                if case .none(let reason) = brain.active {
                    Text(reason).font(.system(size: 11, design: .rounded)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
                GoldButton(label: "Set it up in one tap", icon: "sparkles") { ornith.begin(settings: settings, brain: brain) }
                Button("Advanced: connect Claude, Codex, or Apple Intelligence") { nav.route = .settings }
                    .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)

            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Getting your Mac ready…").font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub)
                }

            case .needsHelper:
                Text("Sovereign uses one small free helper to run privately on your Mac. Download it, open the file it downloads, then come back — Sovereign continues on its own.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                GoldButton(label: "Download the free helper", icon: "arrow.down.circle") {
                    if let u = URL(string: "https://ollama.com/download") {
                        #if canImport(AppKit)
                        NSWorkspace.shared.open(u)
                        #endif
                    }
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the helper… I'll continue automatically.")
                        .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                }

            case .pulling:
                Text("Downloading your assistant's brain…").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                ProgressView(value: ornith.progress.fraction ?? 0).progressViewStyle(.linear).tint(BLTheme.green)
                Text(ornith.progressLabel).font(BLTheme.mono(10.5)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Text("One-time download, stays on your Mac. You can keep going — it finishes in the background.")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            case .ready(let model):
                Label("Your assistant is ready", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                Text("\(model) is installed and running privately on this Mac. Just start typing below.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            case .failed(let reason):
                Label("That didn't finish", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(.orange)
                Text(reason).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                GoldButton(label: "Try again", icon: "arrow.clockwise") { ornith.retry(settings: settings, brain: brain) }
            }
            #endif
        }
        .padding(16)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(settings.accent.opacity(0.4), lineWidth: 1))
        .frame(maxWidth: 460)
        .onDisappear { ornith.stopPolling() }
    }

    private var thinkingRow: some View {
        // A thinking model (Ornith) streams its REASONING before any answer text — that phase
        // used to render as a bare spinner for up to a minute, which read as a hang. Show the
        // live tail of the model's own reasoning stream (never invented text) so the wait is
        // visibly the model working.
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(settings.accent)
                Text(brain.liveReasoning.isEmpty ? "\(brandName) is thinking…" : "\(brandName) is reasoning…")
                    .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            if !brain.liveReasoning.isEmpty {
                Text(String(brain.liveReasoning.suffix(220)).trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.mute)
                    .lineLimit(3).frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transaction { $0.animation = nil }   // raw stream tail — never animate re-layout
            }
        }.accessibilityLabel("Thinking")
    }
    private var brandName: String { settings.assistantName.isEmpty ? "Sovereign" : settings.assistantName }

    // MARK: Message bubble (markdown for assistant, plain for user) + per-message actions
    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        let isUser = m.role == .user
        let isStreaming = m.id == streamingMessageID
        let displayText = isStreaming ? streamingText : m.text
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 70) }
            if !isUser {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.ink)
                    .frame(width: 26, height: 26).background(BLTheme.goldGrad).clipShape(Circle())
                    .shadow(color: BLTheme.gold.opacity(0.3), radius: 4, y: 1)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                Group {
                    if isUser {
                        Text(displayText).font(.system(size: 13.5, design: .rounded)).foregroundColor(BLTheme.ink).textSelection(.enabled)
                    } else {
                        MarkdownView(text: displayText.isEmpty && isStreaming ? "…" : displayText)
                    }
                }
                .padding(.vertical, 11).padding(.horizontal, 15)
                .background(isUser ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.panelGrad))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(isUser ? BLTheme.goldHi.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
                .shadow(color: isUser ? BLTheme.gold.opacity(0.2) : .black.opacity(0.25), radius: 8, y: 3)

                if !isUser && !isStreaming && !m.text.isEmpty { messageActions(m) }
            }
            if !isUser { Spacer(minLength: 70) }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: isUser ? .trailing : .leading)), removal: .opacity))
    }

    @ViewBuilder private func messageActions(_ m: ChatMessage) -> some View {
        HStack(spacing: 12) {
            iconAction("doc.on.doc", "Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.text, forType: .string) }
            iconAction("arrow.clockwise", "Regenerate") { regenerate() }
            iconAction("speaker.wave.2.fill", "Speak") { voice.speak(m.text, voiceID: settings.voiceIdentifier) }
            // Save a fact from this reply into standing Memory (the buyer chooses what to keep —
            // never auto-mined). Confirms briefly so the action is visibly real.
            iconAction(savedMessageID == m.id ? "checkmark.circle.fill" : "brain.head.profile",
                       savedMessageID == m.id ? "Saved to memory" : "Save to memory") {
                memory.add(m.text, source: "chat")
                savedMessageID = m.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if savedMessageID == m.id { savedMessageID = nil } }
            }
        }.padding(.leading, 4)
    }
    @ViewBuilder private func iconAction(_ icon: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundColor(BLTheme.sub) }
            .buttonStyle(.plain).help(help)
    }

    // MARK: Citations bar — the actual sources retrieved for the last reply (honest provenance)
    /// A RAG reply's "Sources" bar belongs to the conversation that produced it. Show it ONLY while
    /// that conversation is active, so switching conversations (or starting a new chat) never bleeds
    /// one reply's document citations onto an unrelated conversation — a real misattribution of the
    /// buyer's own files. nonisolated + static so it is deterministically unit-testable headless.
    nonisolated static func citationsVisible(hasCitations: Bool, citationsConvo: UUID?, activeConvo: UUID?) -> Bool {
        hasCitations && citationsConvo != nil && citationsConvo == activeConvo
    }

    /// Whether a persisted document attachment (bound to `attachmentConvo`, nil = freshly dropped /
    /// not yet sent) should ground a turn in `activeConvo`. A dropped file now persists across
    /// follow-up turns so the buyer can keep asking about it without re-dropping — but it must ground
    /// ONLY its own conversation: an unbound attachment binds to the next send, and once bound it
    /// never grounds (or shows under) a different chat. Mirrors citationsVisible() — the same §5.1
    /// misattribution guard, applied to the grounding side instead of the citation side.
    nonisolated static func attachmentApplies(attachmentConvo: UUID?, activeConvo: UUID?) -> Bool {
        attachmentConvo == nil || attachmentConvo == activeConvo
    }

    // MARK: Cited-only gate (§5.1 — no fabricated grounding)
    /// The retriever surfaces candidate chunks to GROUND the model, but the "Sources" bar must
    /// attribute the answer to ONLY the documents the reply actually cited inline ("[n]"). Showing
    /// every retrieved candidate would imply the reply drew on files it may never have used —
    /// fabricated grounding AND a misleading "these files were used" privacy signal on the buyer's
    /// own documents. A bracket group is treated as a citation list ONLY when its whole content is
    /// integers separated by commas/semicolons/whitespace, so the grouped forms a model actually
    /// emits — "[1]", "[1, 2]", "[1;3]", adjacent "[1][2]" — all resolve, while "[12]" stays the
    /// single number 12 (never 1+2) and a non-citation bracket (a markdown link "[2nd quarter]" or a
    /// range "[1-3]") is ignored so we never OVER-attribute a doc the reply didn't cite (§5.1).
    /// Order-preserving; a reply with no citation markers yields an empty set → the bar hides
    /// (honest empty). nonisolated + static so it is deterministically unit-testable headless.
    nonisolated static func citedChunks(_ candidates: [RetrievedChunk], in reply: String) -> [RetrievedChunk] {
        let cited = citedNumbers(in: reply)
        guard !cited.isEmpty else { return [] }
        return candidates.filter { cited.contains($0.citation) }
    }

    /// The set of citation numbers a reply actually used. Delegates to `CitationMarkers` — the ONE
    /// parser the document-RAG path and the web cite-or-refuse gate (WebCitations.swift) both
    /// compile against, so "what counts as a citation?" can never drift into two different answers.
    nonisolated static func citedNumbers(in reply: String) -> Set<Int> {
        CitationMarkers.numbers(in: reply)
    }
    private var citationsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Image(systemName: "quote.opening").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.gold)
                Text("Sources").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.sub).tracking(0.6)
                ForEach(lastCitations) { c in
                    if c.routable {
                        Button { NotificationCenter.default.post(name: .sovRouteKnowledgeDoc, object: c.docID) } label: {
                            citationChipLabel(c, attachment: false)
                        }.buttonStyle(.plain).help("Used \(Int(c.score * 100))% match — open “\(c.docName)” in Knowledge")
                    } else {
                        // Ephemeral attachment: not in Knowledge, so a non-tappable paperclip marker
                        // (never a dead "open in Knowledge" click), honest about what it is.
                        citationChipLabel(c, attachment: true)
                            .help("Attached file — grounded this reply (not saved to Knowledge)")
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, 6)
        }
    }
    // MARK: Web sources bar (SV-07) — the live pages the reply actually cited
    /// Every chip here is a page the daemon really fetched AND the reply really cited (the set comes
    /// from `WebAnswerGate`, which intersects the two — see WebCitations.swift). Tapping opens the
    /// real URL, so the buyer can check the claim against the source in one click. When the reply
    /// cited none of the pages that were read, the bar says so out loud instead of implying the
    /// answer was sourced. §5.1.
    private var webSourcesBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.gold)
                Text(lastWebUncited ? "Read (uncited)" : "Web sources")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(lastWebUncited ? .orange : BLTheme.sub).tracking(0.6)
                ForEach(lastWebSources) { s in
                    Button { Self.openExternal(s.url) } label: { webSourceChipLabel(s) }
                        .buttonStyle(.plain)
                        .help(lastWebUncited
                              ? "Read for this answer, but the reply didn’t cite it — open \(s.url) to verify"
                              : "Cited [\(s.n)] — open \(s.url)")
                }
                if lastWebUncited {
                    Text(WebAnswerGate.uncitedNotice)
                        .font(.system(size: 10, design: .rounded)).foregroundColor(.orange).lineLimit(1)
                }
            }.padding(.horizontal, 20).padding(.vertical, 6)
        }
    }

    /// One web-source chip: the citation number, the page title, and the REAL host — so the buyer
    /// sees who said it without opening anything.
    @ViewBuilder private func webSourceChipLabel(_ s: WebSource) -> some View {
        HStack(spacing: 5) {
            Text("[\(s.n)]").font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(lastWebUncited ? .orange : BLTheme.gold)
            Text(s.label).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(BLTheme.text).lineLimit(1)
            if !s.host.isEmpty {
                Text(s.host).font(.system(size: 9.5, design: .monospaced)).foregroundColor(BLTheme.sub).lineLimit(1)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 9)
        .background(BLTheme.bg2).clipShape(Capsule())
        .overlay(Capsule().stroke(lastWebUncited ? Color.orange.opacity(0.45) : BLTheme.stroke, lineWidth: 1))
    }

    /// Open a real fetched source in the buyer's browser. macOS-only (no loopback assumption).
    nonisolated static func openExternal(_ url: String) {
        guard let u = URL(string: url) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(u)
        #endif
    }

    /// One source chip. `attachment` prepends a paperclip so a dropped-file source is visually
    /// distinct from a Knowledge document (which is tappable to open).
    @ViewBuilder private func citationChipLabel(_ c: RetrievedChunk, attachment: Bool) -> some View {
        HStack(spacing: 5) {
            if attachment {
                Image(systemName: "paperclip").font(.system(size: 9, weight: .bold)).foregroundColor(BLTheme.gold)
            }
            Text("[\(c.citation)]").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.gold)
            Text(c.docName).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
        }
        .padding(.vertical, 4).padding(.horizontal, 9).background(BLTheme.gold.opacity(0.08)).clipShape(Capsule())
        .overlay(Capsule().stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
    }

    private var desktopReviewAccessBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "display.and.arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(BLTheme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Desktop review access")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundColor(BLTheme.text)
                Text(desktopReviewBusy
                     ? "Capturing the current desktop through the local Sovereign daemon."
                     : "Allow one screenshot for this request, or cancel.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.sub)
                    .lineLimit(2)
            }
            Spacer()
            if desktopReviewBusy { ProgressView().scaleEffect(0.7) }
            GhostButton(label: "Cancel", icon: "xmark", tint: BLTheme.sub) { cancelDesktopReviewAccess() }
                .disabled(desktopReviewBusy)
            GoldButton(label: "Allow once", icon: "camera.viewfinder") { approveDesktopReviewAccess() }
                .disabled(desktopReviewBusy)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(BLTheme.gold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    // MARK: Image attachment chips (External vision)
    private var imageChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachedImages) { img in
                    HStack(spacing: 7) {
                        Image(systemName: "photo.fill").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.gold)
                        Text(img.name).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                        Text("\(img.approxKB) KB").font(.system(size: 9, design: .monospaced)).foregroundColor(BLTheme.sub)
                        Button { attachedImages.removeAll { $0.id == img.id } } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                        }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 5).padding(.horizontal, 10).background(BLTheme.gold.opacity(0.08)).clipShape(Capsule())
                    .overlay(Capsule().stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
                }
                if !brain.supportsImages {
                    Text("Images are not available on the local text brain.")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(.orange)
                }
            }.padding(.horizontal, 20).padding(.vertical, 4)
        }
    }

    // MARK: Attachment chip (a dropped document, used as grounding for the next prompt)
    @ViewBuilder private func attachmentChip(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.gold)
            Text("Attached: \(name)").font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
            Text(Self.attachmentStatus(attachedDocBody)).font(.system(size: 10, design: .monospaced)).foregroundColor(BLTheme.sub)
            Spacer()
            Button { clearAttachment() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Remove attachment")
        }
        .padding(.vertical, 7).padding(.horizontal, 12).background(BLTheme.gold.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20).padding(.bottom, 4)
    }

    // MARK: Attachment error chip (honest "couldn't read this file" — never a silent swallow, §5.1)
    @ViewBuilder private func attachmentErrorChip(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.danger)
            Text(message).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(2)
            Spacer()
            Button { attachedDocError = nil } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Dismiss attachment error")
        }
        .padding(.vertical, 7).padding(.horizontal, 12).background(BLTheme.danger.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.danger.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20).padding(.bottom, 4)
        .accessibilityLabel("Attachment error: \(message)")
    }

    // MARK: Composer
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 10) {
            Button { importDocument() } label: {
                Image(systemName: "paperclip").font(.system(size: 15, weight: .semibold)).foregroundColor(BLTheme.sub)
                    .frame(width: 38, height: 38).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
            }.buttonStyle(.plain).help("Attach a document (⌘O)")

            // Voice INPUT: on-device dictation. Shown ONLY when the running build is entitled
            // for the mic (§5.8) — never a dead control. Taps stream the transcript into the draft.
            if dictation.available {
                Button {
                    if dictation.listening { dictation.stop() }
                    else {
                        dictationBase = draft
                        dictation.start { t in draft = dictationBase.isEmpty ? t : dictationBase + " " + t }
                        composerFocused = true
                    }
                } label: {
                    Image(systemName: dictation.listening ? "mic.fill" : "mic")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(dictation.listening ? BLTheme.gold : BLTheme.sub)
                        .frame(width: 38, height: 38).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(dictation.listening ? BLTheme.gold.opacity(0.6) : BLTheme.stroke, lineWidth: 1))
                }.buttonStyle(.plain)
                 .help(dictation.listening ? "Stop dictation" : (dictation.onDevice ? "Dictate — on-device speech-to-text" : "Dictate — speech-to-text"))
                 .accessibilityLabel(dictation.listening ? "Stop dictation" : "Start dictation")
            }

            TextField(attachedDocName == nil ? "Ask anything…" : "Ask about \(attachedDocName!)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14, design: .rounded)).foregroundColor(BLTheme.text)
                .lineLimit(1...6).padding(.vertical, 11).padding(.horizontal, 14)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(composerFocused ? BLTheme.gold.opacity(0.5) : BLTheme.stroke, lineWidth: 1))
                .focused($composerFocused).onSubmit(send)
                .accessibilityLabel("Message input")

            if brain.thinking {
                Button { brain.cancel(); finalizeStream(cancelled: true) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold)).foregroundColor(BLTheme.ink)
                        .frame(width: 44, height: 44).background(BLTheme.danger).clipShape(Circle())
                }.buttonStyle(.plain).help("Stop generating")
            } else {
                GoldButton(label: "Send", icon: "arrow.up") { send() }
            }
        }
        if let derr = dictation.lastError, !derr.isEmpty {
            HStack(spacing: 8) {
                Text(derr).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                // A TCC denial names its fix: deep-link straight to the pane that re-grants it.
                if let pane = dictation.deniedPane {
                    Button("Open System Settings") { pane.open() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                }
            }.padding(.horizontal, 4)
        }
        }.padding(20).padding(.top, 0)
    }

    private var dropOverlay: some View {
        ZStack {
            BLTheme.bg.opacity(0.7)
            VStack(spacing: 10) {
                Image(systemName: "doc.badge.arrow.up.fill").font(.system(size: 40)).foregroundColor(BLTheme.gold)
                Text("Drop a document to analyze").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(DataHandlingCopy.documentImport).font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub)
            }
        }.allowsHitTesting(false)
    }

    // MARK: Send / stream / regenerate
    private func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow image-only sends (e.g. "what is this?" implied) only if there's also text;
        // require non-empty text so a brain call always has a clear request.
        guard !prompt.isEmpty, !brain.thinking else { return }
        store.ensureActiveConversation()
        guard let convoID = store.activeConversationID else { return }
        draft = ""
        var marker = ""
        if attachedDocName != nil { marker += "\n\n[Attached: \(attachedDocName!)]" }
        if !attachedImages.isEmpty { marker += "\n\n[\(attachedImages.count) image\(attachedImages.count == 1 ? "" : "s") attached]" }
        let userMsg = ChatMessage(role: .user, text: prompt + marker)
        store.appendMessage(userMsg, to: convoID)
        // Desktop review exists only where a desktop does: capture requires the macOS daemon, so on
        // iOS "look at this screenshot" must reach the normal stream/vision path (with any attached
        // photo intact) instead of an approval flow that can only end in a capability error.
        #if os(macOS)
        if Self.isDesktopReviewRequest(prompt) {
            requestDesktopReviewAccess(prompt: prompt, convoID: convoID, images: attachedImages)
            attachedImages = []
            return
        }
        #endif
        // First-class WEB capabilities for the LOCAL brain (parity with Open WebUI/Msty), routed by
        // the pure WebCapability map: a pasted URL is read verbatim (url_context) and answered with a
        // cited source; an explicit search phrasing or Research mode runs live web_search → read →
        // cite. Only when no image is attached (so image analysis isn't hijacked). §5.1: honest empty
        // states, real source URLs, never a fabricated snippet.
        if attachedImages.isEmpty {
            switch WebCapability.route(prompt: prompt, researchMode: settings.researchMode,
                                       explicitSearch: Self.webResearchQuery(prompt)) {
            case .readURLs(let urls):
                startURLContext(urls: urls, question: prompt, convoID: convoID)
                return
            case .search(let query):
                startWebResearch(query: query, convoID: convoID)
                return
            case .none:
                break
            }
        }
        startStream(prompt: prompt, convoID: convoID, images: attachedImages)
    }

    private func requestDesktopReviewAccess(prompt: String, convoID: UUID, images: [BrainImage]) {
        pendingDesktopReviewPrompt = prompt
        pendingDesktopReviewConvoID = convoID
        pendingDesktopReviewImages = images
        desktopReviewBusy = false
        store.appendMessage(ChatMessage(
            role: .assistant,
            text: "Desktop review needs your approval first. Click Allow once to capture the current desktop through the local Sovereign daemon, or Cancel."
        ), to: convoID)
    }

    private func cancelDesktopReviewAccess() {
        let convoID = pendingDesktopReviewConvoID
        pendingDesktopReviewPrompt = ""
        pendingDesktopReviewConvoID = nil
        pendingDesktopReviewImages = []
        desktopReviewBusy = false
        if let convoID {
            store.appendMessage(ChatMessage(role: .assistant, text: "Desktop review cancelled. No screenshot was captured."), to: convoID)
        }
    }

    private func approveDesktopReviewAccess() {
        guard let convoID = pendingDesktopReviewConvoID, !pendingDesktopReviewPrompt.isEmpty, !desktopReviewBusy else { return }
        let prompt = pendingDesktopReviewPrompt
        let carriedImages = pendingDesktopReviewImages
        desktopReviewBusy = true
        Task {
            let result = await Self.captureDesktopScreenshot()
            await MainActor.run {
                finishDesktopReviewCapture(result, prompt: prompt, convoID: convoID, carriedImages: carriedImages)
            }
        }
    }

    private func finishDesktopReviewCapture(_ result: DesktopScreenshotCapture, prompt: String, convoID: UUID, carriedImages: [BrainImage]) {
        pendingDesktopReviewPrompt = ""
        pendingDesktopReviewConvoID = nil
        pendingDesktopReviewImages = []
        switch result {
        case .success(let path, _):
            // Path A — a vision-capable brain: hand it the raw pixels (highest fidelity).
            if brain.supportsImages, let screenshot = Self.loadImage(URL(fileURLWithPath: path)) {
                desktopReviewBusy = false
                let reviewPrompt = "Review the desktop screenshot captured after I approved access. User request: \(prompt)"
                startStream(prompt: reviewPrompt, convoID: convoID, images: carriedImages + [screenshot])
                return
            }
            // Path B — a TEXT-ONLY brain (on-device / Ornith-Ollama / local server):
            // route the screenshot through the daemon's on-device vision analyzer
            // (Apple Vision OCR + the macOS window graph) and feed the structured
            // observations to the active brain as grounding. This is the fix for the
            // old dead end: Sovereign does the task instead of telling the user to
            // switch brains. No "vision-capable brain" blocker in normal UX.
            let statusMsg = ChatMessage(role: .assistant, text: "Analyzing your desktop on-device…")
            store.appendMessage(statusMsg, to: convoID)
            Task {
                let analysis = await ToolClient.shared.analyzeDesktop(path: path)
                await MainActor.run {
                    desktopReviewBusy = false
                    // Drop the transient "Analyzing…" bubble; the answer replaces it.
                    if store.conversations.first(where: { $0.id == convoID })?.messages.last?.id == statusMsg.id {
                        store.removeLastAssistant(in: convoID)
                    }
                    switch analysis {
                    case .success(let obs):
                        let reviewPrompt = """
                        You asked me to look at your desktop. I captured a screenshot and analyzed it on-device \
                        (Apple Vision OCR + the macOS window list). Answer the request using ONLY these real \
                        observations — do not invent anything that is not listed.

                        \(obs.promptBlock)

                        User request: \(prompt)
                        """
                        startStream(prompt: reviewPrompt, convoID: convoID, images: [],
                                    allowResearchEscalation: false)
                    case .failure(let reason):
                        // Actionable — never a dead chat message.
                        store.appendMessage(ChatMessage(
                            role: .assistant,
                            text: "I captured your desktop screenshot (\(path)) but couldn't analyze it: \(reason)"
                        ), to: convoID)
                    }
                }
            }
        case .failure(let reason):
            desktopReviewBusy = false
            store.appendMessage(ChatMessage(
                role: .assistant,
                text: "Desktop access was not granted or the daemon could not capture the screen: \(reason)"
            ), to: convoID)
        }
    }

    // MARK: Web research (real search → read → cite)

    /// Run a real web-research turn: the daemon searches, reads the top pages, and
    /// returns the sources it actually fetched; the active brain then summarizes from
    /// that grounding and every source URL is shown. No fabricated results, no dead end.
    private func startWebResearch(query: String, convoID: UUID) {
        let statusMsg = ChatMessage(role: .assistant, text: "Searching the web for “\(query)”…")
        store.appendMessage(statusMsg, to: convoID)
        Task {
            let res = await ToolClient.shared.research(query: query)
            await MainActor.run {
                if store.conversations.first(where: { $0.id == convoID })?.messages.last?.id == statusMsg.id {
                    store.removeLastAssistant(in: convoID)
                }
                switch res {
                case .success(let r):
                    guard !r.sources.isEmpty, !r.context.isEmpty else {
                        store.appendMessage(ChatMessage(
                            role: .assistant,
                            text: "I searched the web for “\(query)” but found no usable sources. Try rephrasing the query."
                        ), to: convoID)
                        return
                    }
                    let sourcesList = r.sources
                        .map { "[\($0.n)] \($0.title.isEmpty ? $0.url : $0.title) — \($0.url)" }
                        .joined(separator: "\n")
                    let providerNote = (r.provider == "google_cse") ? "Google" : "the web"
                    let systemExtra = "\n\nYou are answering with LIVE web research from \(providerNote). "
                        + "Use ONLY the numbered sources provided as grounding. Cite each claim inline with "
                        + "[n] matching the source numbers. Be concise and factual; never invent a source."
                    let grounding = "WEB SOURCES (fetched just now for “\(query)”):\n\n\(r.context)"
                    let userPrompt = "Question: \(query)\n\nAnswer using the numbered web sources above, citing [n]."
                    // The sources the daemon REALLY fetched, carried into the cite-or-refuse gate.
                    let fetched = r.sources.map { WebSource(n: $0.n, title: $0.title, url: $0.url) }
                    streamWithGrounding(userPrompt: userPrompt, systemExtra: systemExtra,
                                        grounding: grounding, suffix: "\n\n**Sources**\n\(sourcesList)",
                                        convoID: convoID, webSources: fetched)
                case .failure(let reason):
                    store.appendMessage(ChatMessage(
                        role: .assistant,
                        text: "Web research couldn't run: \(reason)"
                    ), to: convoID)
                }
            }
        }
    }

    /// Read the exact URL(s) the buyer pasted via the daemon's keyless `url_context` tool, then answer
    /// the question grounded ONLY on the fetched page text — with the real source URL cited. Works on
    /// the LOCAL brain (grounding-based, no cloud key). Honest empty state when a page can't be read;
    /// never a fabricated snippet.
    private func startURLContext(urls: [String], question: String, convoID: UUID) {
        let targets = Array(urls.prefix(3))
        let statusMsg = ChatMessage(role: .assistant,
            text: "Reading \(targets.count == 1 ? "the page" : "\(targets.count) pages")…")
        store.appendMessage(statusMsg, to: convoID)
        Task {
            var pages: [URLContext] = []
            var failures: [String] = []
            for u in targets {
                switch await ToolClient.shared.readURL(u) {
                case .success(let pc): pages.append(pc)
                case .failure(let e): failures.append("\(u): \(e)")
                }
            }
            await MainActor.run {
                if store.conversations.first(where: { $0.id == convoID })?.messages.last?.id == statusMsg.id {
                    store.removeLastAssistant(in: convoID)
                }
                guard !pages.isEmpty else {
                    let why = failures.first ?? "the page returned no readable text"
                    store.appendMessage(ChatMessage(role: .assistant,
                        text: "I couldn't read \(targets.count == 1 ? "that page" : "those pages"): \(why)"), to: convoID)
                    return
                }
                let sourcesList = pages.enumerated()
                    .map { "[\($0.offset + 1)] \($0.element.title.isEmpty ? $0.element.url : $0.element.title) — \($0.element.url)" }
                    .joined(separator: "\n")
                let grounding = "PAGE CONTENT (fetched just now):\n\n" + pages.enumerated()
                    .map { "[\($0.offset + 1)] \($0.element.url)\n\($0.element.text)" }
                    .joined(separator: "\n\n")
                let systemExtra = "\n\nYou are answering from the FETCHED page content below. Use ONLY it as "
                    + "grounding; cite each claim inline with [n] matching the source numbers. Never invent "
                    + "content that isn't in the pages."
                let userPrompt = "Question: \(question)\n\nAnswer using the numbered page content above, citing [n]."
                // The pages url_context REALLY read (numbered exactly as the grounding block numbered
                // them), carried into the cite-or-refuse gate.
                let fetched = pages.enumerated().map {
                    WebSource(n: $0.offset + 1, title: $0.element.title, url: $0.element.url)
                }
                streamWithGrounding(userPrompt: userPrompt, systemExtra: systemExtra,
                                    grounding: grounding, suffix: "\n\n**Sources**\n\(sourcesList)",
                                    convoID: convoID, webSources: fetched)
            }
        }
    }

    /// Stream a brain answer with an explicit grounding block and a deterministic
    /// suffix appended to the final text (used to guarantee the real source URLs are
    /// shown even if the model omits them). Mirrors `startStream`'s streaming UI.
    /// `webSources` are the pages the daemon ACTUALLY fetched for this turn. They are run through
    /// `WebAnswerGate` when the reply lands, which decides what may render: only the fetched sources
    /// the reply genuinely cited become chips (a phantom "[7]" is dropped, never minted), and a reply
    /// that cited nothing is labelled unsourced rather than dressed up as research. §5.1.
    private func streamWithGrounding(userPrompt: String, systemExtra: String,
                                     grounding: String, suffix: String, convoID: UUID,
                                     webSources: [WebSource] = []) {
        let placeholder = ChatMessage(role: .assistant, text: "")
        store.appendMessage(placeholder, to: convoID)
        streamingMessageID = placeholder.id
        streamingConvoID = convoID
        streamingText = ""
        let system = settings.effectiveSystemPrompt + systemExtra
        brain.stream(prompt: userPrompt, system: system, grounding: grounding, images: [], history: [],
            onToken: { token in self.streamingText = token },
            onDone: { final in
                if let final = final, !final.isEmpty {
                    self.store.updateLastAssistant(final + suffix, in: convoID)
                    self.applyWebGate(fetched: webSources, reply: final, convoID: convoID)
                    if self.settings.voiceEnabled { self.voice.speak(final, voiceID: self.settings.voiceIdentifier) }
                } else {
                    // Brain produced nothing — still surface the real sources so the
                    // research isn't lost (honest, never a blank bubble).
                    self.store.removeLastAssistant(in: convoID)
                    let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.store.appendMessage(ChatMessage(
                            role: .assistant,
                            text: "Here are the sources I found:\n\(trimmed)"
                        ), to: convoID)
                    }
                    // No reply text = nothing cited anything. Show the pages as read-but-uncited.
                    self.applyWebGate(fetched: webSources, reply: "", convoID: convoID)
                }
                self.finalizeStream(cancelled: false)
            })
    }

    /// Run the cite-or-refuse gate and bind the result to the conversation that produced it. The ONLY
    /// writer of `lastWebSources` — so a chip on screen always traces to a real fetch + a real cite.
    private func applyWebGate(fetched: [WebSource], reply: String, convoID: UUID) {
        guard !fetched.isEmpty else {
            lastWebSources = []; lastWebSourcesConvoID = nil; lastWebUncited = false
            return
        }
        switch WebAnswerGate.decide(fetched: fetched, reply: reply) {
        case .refuse:
            lastWebSources = []; lastWebSourcesConvoID = nil; lastWebUncited = false
        case .cited(let sources):
            lastWebSources = sources; lastWebSourcesConvoID = convoID; lastWebUncited = false
        case .uncited(let sources):
            lastWebSources = sources; lastWebSourcesConvoID = convoID; lastWebUncited = true
        }
    }

    private func regenerate() {
        guard let convoID = store.activeConversationID, let prompt = store.lastUserPrompt(in: convoID), !brain.thinking else { return }
        store.removeLastAssistant(in: convoID)
        brain.resetSession()
        // strip the attachment marker from the stored prompt for a clean re-ask
        let clean = prompt.components(separatedBy: "\n\n[Attached:").first?
            .components(separatedBy: "\n\n[").first ?? prompt
        startStream(prompt: clean, convoID: convoID, images: [])
    }

    private func startStream(prompt: String, convoID: UUID, images: [BrainImage],
                             allowResearchEscalation: Bool = true) {
        let placeholder = ChatMessage(role: .assistant, text: "")
        store.appendMessage(placeholder, to: convoID)
        streamingMessageID = placeholder.id
        streamingConvoID = convoID
        streamingText = ""
        // Retrieve sources first so we can both ground the brain AND show the citation list.
        let chunks = store.retrieve(for: prompt, useSemantic: settings.semanticRAG)
        // An attached file (ephemeral, dropped this turn) is cited too — numbered AFTER the
        // Knowledge chunks so the [n] never collides — so the buyer sees their OWN file in the
        // Sources bar, auditable like Knowledge RAG. The grounding string is built HERE (not in
        // composedPrompt) so the [n] the model is told to cite is the SAME [n] shown on the chip.
        var attachmentGrounding: String? = nil
        var attachmentChunks: [RetrievedChunk] = []
        if let name = attachedDocName, !attachedDocBody.isEmpty,
           Self.attachmentApplies(attachmentConvo: attachedDocConvoID, activeConvo: convoID) {
            let cited = Self.groundedAttachmentCited(body: attachedDocBody, name: name, query: prompt,
                                                     useSemantic: settings.semanticRAG,
                                                     citation: chunks.count + 1)
            attachmentGrounding = cited.grounding
            attachmentChunks = [cited.chunk]
            attachedDocConvoID = convoID   // bind the persisted attachment to this conversation
        }
        let candidates = chunks + attachmentChunks
        lastCitations = candidates
        lastCitationsConvoID = convoID   // bind these sources to the conversation that produced them
        let grounding = buildGrounding(for: prompt, chunks: chunks)
        let system = effectiveSystem(for: convoID)
        // Prior turns for External context (on-device keeps its own session). Exclude the
        // just-added placeholder and the user message we're answering.
        let history = brainHistory(convoID: convoID)
        brain.stream(prompt: composedPrompt(prompt, attachmentGrounding: attachmentGrounding), system: system, grounding: grounding,
            images: images, history: history,
            onToken: { token in self.streamingText = token },
            onDone: { final in
                if let final = final, !final.isEmpty {
                    // RESEARCH ESCALATION: the brain answered with a refusal/miss ("I can't
                    // look that up", "no access to the internet", "I don't know"). Instead of
                    // leaving that dead end — or letting a local model free-associate about
                    // something it doesn't know — drop the refusal and run REAL web research
                    // on the original question (search → read → cite). The daemon does the
                    // searching; the same brain then answers grounded on fetched sources.
                    if allowResearchEscalation, images.isEmpty, Self.isResearchMiss(final) {
                        self.store.removeLastAssistant(in: convoID)
                        self.lastCitations = []
                        self.lastCitationsConvoID = nil
                        self.finalizeStream(cancelled: false)
                        self.startWebResearch(query: prompt, convoID: convoID)
                        return
                    }
                    self.store.updateLastAssistant(final, in: convoID)
                    // §5.1 — attribute the answer to ONLY the documents the reply actually cited
                    // inline ("[n]"). The retrieved candidates grounded the model; showing all of
                    // them would imply the reply used files it may never have referenced. If the
                    // reply cited nothing, the Sources bar hides (honest empty), not "all sources".
                    self.lastCitations = Self.citedChunks(candidates, in: final)
                    if self.lastCitations.isEmpty { self.lastCitationsConvoID = nil }
                    if self.settings.voiceEnabled { self.voice.speak(final, voiceID: self.settings.voiceIdentifier) }
                } else {
                    // Failed or empty — remove the empty placeholder so no blank bubble remains.
                    self.store.removeLastAssistant(in: convoID)
                    self.lastCitations = []
                    self.lastCitationsConvoID = nil
                }
                self.finalizeStream(cancelled: false)
            })
    }

    /// Prior conversation turns (role/text) for External context — excludes the in-flight pair.
    private func brainHistory(convoID: UUID) -> [(role: String, text: String)] {
        guard let convo = store.conversations.first(where: { $0.id == convoID }) else { return [] }
        // Drop the trailing empty assistant placeholder and the user message being answered.
        var msgs = convo.messages
        if msgs.last?.role == .assistant, (msgs.last?.text.isEmpty ?? false) { msgs.removeLast() }
        if msgs.last?.role == .user { msgs.removeLast() }
        return msgs.filter { !$0.text.isEmpty }.suffix(20).map {
            (role: $0.role == .user ? "user" : "assistant", text: $0.text)
        }
    }
    private func finalizeStream(cancelled: Bool) {
        if cancelled, let id = streamingMessageID, let convoID = streamingConvoID {
            // Touch the message only if the owner's last assistant row is still OUR placeholder —
            // guards the (theoretical) case where the owning conversation gained a newer reply.
            let lastAssistantID = store.conversations.first(where: { $0.id == convoID })?
                .messages.last(where: { $0.role == .assistant })?.id
            if lastAssistantID == id {
                if !streamingText.isEmpty { store.updateLastAssistant(streamingText + "\n\n_[stopped]_", in: convoID) }
                else { store.removeLastAssistant(in: convoID) }
            }
        }
        streamingMessageID = nil; streamingConvoID = nil; streamingText = ""
        // A dropped DOCUMENT persists across follow-up turns (cleared on new chat / switch / the X)
        // so the buyer can keep asking about it without re-dropping; one-shot vision images are
        // cleared so a follow-up turn doesn't silently re-send (and re-bill) the same image.
        attachedImages = []
    }

    /// Composes the model prompt. When an attachment grounded this turn, `attachmentGrounding`
    /// (built by groundedAttachmentCited so its [n] tag matches the Sources chip) is prepended;
    /// nil grounding == no attachment, so a plain chat is untouched.
    private func composedPrompt(_ prompt: String, attachmentGrounding: String?) -> String {
        guard let g = attachmentGrounding else { return prompt }
        return "\(g)\n\nUser request: \(prompt)"
    }

    nonisolated static func isDesktopReviewRequest(_ raw: String) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }
        let targets = ["desktop", "screen", "display", "monitor", "screenshot"]
        let verbs = ["review", "look at", "look over", "check", "inspect", "analyze", "analyse", "see", "read", "what is on", "what's on"]
        return targets.contains { q.contains($0) } && verbs.contains { q.contains($0) }
    }

    /// Detects an explicit web-research request and returns the query to run (nil if
    /// this is ordinary chat). Kept tight so normal conversation isn't hijacked — it
    /// fires on clear "search / look up / research on the web" phrasings.
    nonisolated static func webResearchQuery(_ raw: String) -> String? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 4 else { return nil }
        let low = q.lowercased()
        // Leading command phrases → the remainder is the query.
        let prefixes = [
            "search google for ", "search the web for ", "search online for ",
            "search for ", "google ", "look up ", "look online for ",
            "research ", "find online ", "find on the web ", "web search for ",
            "search the internet for ", "what's the latest on ", "whats the latest on ",
            "latest news on ", "look this up online: ",
        ]
        for t in prefixes where low.hasPrefix(t) {
            let query = String(q.dropFirst(t.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: " :\"'?."))
            return query.count >= 2 ? query : nil
        }
        // Embedded command phrases mid-sentence ("what about look up hangoutfest",
        // "can you search for X") → the remainder after the phrase is the query.
        for t in ["look up ", "search for "] {
            if let r = low.range(of: t) {
                let tail = String(q[r.upperBound...]).trimmingCharacters(
                    in: CharacterSet(charactersIn: " :\"'?."))
                if tail.count >= 2 { return tail }
            }
        }
        // Embedded "search google/the web/online" anywhere → use the whole line as the query.
        let embedded = ["search google", "search the web", "search online",
                        "web search", "search the internet", "on the web"]
        if embedded.contains(where: { low.contains($0) }) {
            return q
        }
        return nil
    }

    /// True when a brain reply is a RESEARCH MISS — a refusal / "no internet access" /
    /// "I don't know" answer that live web research can actually satisfy. Mirrors the
    /// daemon's learn-on-miss markers. Lower-cased substring match, deliberately tight
    /// so real answers never re-trigger a search.
    nonisolated static func isResearchMiss(_ reply: String) -> Bool {
        let low = reply.lowercased()
        let markers = [
            "i can't look up", "i cannot look up", "can't look that up",
            "i can't search", "i cannot search", "i can't browse", "i cannot browse",
            "unable to browse", "do not have access to the internet",
            "don't have access to the internet", "no access to the internet",
            "don't have internet access", "do not have internet access",
            "external search engines", "i don't have real-time", "i do not have real-time",
            "as of my last training", "as of my training data", "my training data",
            "my knowledge cutoff", "i don't know", "i do not know",
            "no information about", "i don't have information",
            "i do not have information",
        ]
        return markers.contains { low.contains($0) }
    }

    enum DesktopScreenshotCapture: Equatable {
        case success(path: String, bytes: Int)
        case failure(String)
    }

    nonisolated static let desktopDaemonPorts = Array(8765...8785)

    static func captureDesktopScreenshot() async -> DesktopScreenshotCapture {
        #if os(macOS)
        var lastError = "the Sovereign background service isn't running on this Mac — desktop capture "
            + "comes with the separately-installed daemon kit (chat works without it)."
        for port in desktopDaemonPorts {
            guard let url = URL(string: "http://127.0.0.1:\(port)/api/desktop/screenshot") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 2
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Same loopback auth as every ToolClient call — a tokened daemon 403s bare requests.
            if let token = ToolClient.daemonToken { req.setValue(token, forHTTPHeaderField: "X-Sovereign-Token") }
            req.httpBody = Data("{}".utf8)
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let payload = desktopScreenshotPayload(data)
                if payload.ok == true, let path = payload.path, !path.isEmpty {
                    return .success(path: path, bytes: payload.bytes ?? 0)
                }
                if let reason = payload.reason, !reason.isEmpty {
                    return .failure(reason)
                }
                if status >= 200 && status < 300 {
                    return .failure("daemon returned success without a screenshot path")
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        return .failure(lastError)
        #else
        return .failure("desktop screenshot capture is only available on macOS")
        #endif
    }

    private static func desktopScreenshotPayload(_ data: Data) -> (ok: Bool?, path: String?, bytes: Int?, reason: String?) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, nil, nil, nil)
        }
        let root = (obj["result"] as? [String: Any]) ?? obj
        let ok = (root["ok"] as? Bool) ?? (obj["ok"] as? Bool)
        let path = (root["path"] as? String) ?? (obj["path"] as? String)
        let reason = (root["reason"] as? String) ?? (root["error"] as? String) ?? (obj["reason"] as? String) ?? (obj["error"] as? String)
        let rawBytes = root["bytes"] ?? obj["bytes"]
        let bytes: Int?
        if let n = rawBytes as? Int { bytes = n }
        else if let n = rawBytes as? Double { bytes = Int(n) }
        else if let s = rawBytes as? String { bytes = Int(s) }
        else { bytes = nil }
        return (ok, path, bytes, reason)
    }

    /// Characters of an attached document that actually reach the model as grounding. Both the
    /// chip status (attachmentStatus) and the prompt builder (composedPrompt -> groundedAttachment)
    /// key off this ONE budget, so the buyer is never shown a word-count implying the whole file
    /// is in play when only this leading prefix is (§5.1).
    nonisolated static let groundingCharBudget = 8000
    /// Selects the portion of an attached document that grounds the model. Within budget → the whole
    /// document, verbatim. Over budget → the body is chunked and the chunks most relevant to `query`
    /// are reassembled (in document order) up to the budget, so a question about page 40 of a 50-page
    /// file is actually grounded instead of always the first ~8000 chars. Honest fallbacks: an empty
    /// query (no relevance signal) or retrieval that clears nothing keeps the leading-prefix behavior
    /// — never empty grounding. Pure + nonisolated so it unit-tests on the fast logic path.
    /// The ellipsis separator between non-contiguous selected passages, so the model (and any
    /// reader) sees the excerpts are not contiguous. One source of truth for the grounding string
    /// and the budget math.
    nonisolated static let attachmentExcerptSeparator = "\n\n…\n\n"

    /// The query-relevant passages of an OVER-BUDGET attachment, in document order, budget-capped.
    /// Returns nil to signal "use the leading-prefix fallback": within budget, an empty query (no
    /// relevance signal), a single chunk, or retrieval that cleared nothing. Pure + nonisolated so
    /// it unit-tests headless. Single source of truth for groundedAttachment (string) AND
    /// groundedAttachmentCited (citation chip), so the passages the model reads always match.
    nonisolated static func selectedAttachmentPassages(_ body: String, query: String, useSemantic: Bool) -> [String]? {
        guard body.count > groundingCharBudget else { return nil }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let chunks = FileIndexer.chunk(body)
        guard chunks.count > 1 else { return nil }
        let doc = SemanticRAG.Doc(id: UUID(), name: "attachment", chunks: chunks)
        // Pull enough top chunks to fill the budget (≈ budget / chunk-size, plus a little margin).
        let maxChunks = max(1, groundingCharBudget / 600 + 2)
        let hits = SemanticRAG.retrieve(query: q, docs: [doc], max: maxChunks, useSemantic: useSemantic)
        guard !hits.isEmpty else { return nil }
        // Order selected passages by original document position for coherent reading; cap to the
        // budget. First-occurrence index map keeps duplicate chunks (repeated boilerplate) crash-safe.
        var order: [String: Int] = [:]
        for (i, c) in chunks.enumerated() where order[c] == nil { order[c] = i }
        let selected = hits.map { $0.text }.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
        let sepLen = attachmentExcerptSeparator.count
        var capped: [String] = []
        var total = 0
        for piece in selected {
            let sep = capped.isEmpty ? 0 : sepLen
            if total + sep + piece.count > groundingCharBudget { break }
            capped.append(piece); total += sep + piece.count
        }
        return capped.isEmpty ? nil : capped
    }

    nonisolated static func groundedAttachment(_ body: String, query: String, useSemantic: Bool) -> String {
        guard let passages = selectedAttachmentPassages(body, query: query, useSemantic: useSemantic) else {
            return body.count > groundingCharBudget ? String(body.prefix(groundingCharBudget)) : body
        }
        return passages.joined(separator: attachmentExcerptSeparator)
    }

    /// Grounds an attached document for the prompt AND yields the citation chip to surface, so the
    /// buyer can SEE which file grounded the answer (auditable provenance, like Knowledge RAG).
    /// One attachment = ONE citation number (`citation`, assigned AFTER the Knowledge chunks so it
    /// never collides). Over budget → the query-relevant excerpts, tagged [citation]; within budget
    /// → the whole document, tagged [citation]; over-budget-no-signal → the leading prefix, tagged
    /// [citation]. The grounding instructs the model to cite "[citation]" ONLY when it actually uses
    /// the material, so an unused attachment drops out of the Sources bar via citedChunks (§5.1).
    /// The returned chunk is `routable: false` — an attachment is ephemeral, not a Knowledge doc.
    nonisolated static func groundedAttachmentCited(body: String, name: String, query: String,
                                                    useSemantic: Bool, citation: Int)
        -> (grounding: String, chunk: RetrievedChunk) {
        let overBudget = body.count > groundingCharBudget
        let excerpt: String
        if let passages = selectedAttachmentPassages(body, query: query, useSemantic: useSemantic) {
            excerpt = passages.joined(separator: attachmentExcerptSeparator)
        } else {
            excerpt = overBudget ? String(body.prefix(groundingCharBudget)) : body
        }
        let preamble = overBudget
            ? "Here are the most relevant excerpts from a file the user attached, \"\(name)\" (the full file is larger; these were selected for this request). When you use this material, cite it inline as [\(citation)]:"
            : "Here is a file the user attached, \"\(name)\". When you use it, cite it inline as [\(citation)]:"
        let grounding = "\(preamble)\n\n\"\"\"\n[\(citation)] \(excerpt)\n\"\"\""
        let chunk = RetrievedChunk(citation: citation, docName: name, docID: UUID(),
                                   text: excerpt, score: 1.0, routable: false)
        return (grounding, chunk)
    }

    /// Honest one-line status for the attachment chip. A dropped document is capped to
    /// `groundingCharBudget` characters before it reaches the model; a 30k-word file that showed
    /// its FULL word count implied the whole document grounded the answer when ~96% was silently
    /// dropped. When the body overflows the budget this surfaces "<grounded> of <total> words
    /// grounded"; otherwise the plain word count. Pure + nonisolated so it unit-tests on the fast
    /// logic path (mirrors citedNumbers).
    nonisolated static func attachmentStatus(_ body: String) -> String {
        let total = body.split(whereSeparator: { $0.isWhitespace }).count
        guard body.count > groundingCharBudget else {
            return "\(total) word\(total == 1 ? "" : "s")"
        }
        let grounded = body.prefix(groundingCharBudget).split(whereSeparator: { $0.isWhitespace }).count
        return "\(grounded) of \(total) words grounded"
    }

    private func buildGrounding(for prompt: String, chunks: [RetrievedChunk]) -> String {
        var parts: [String] = []
        // Standing memory (what the brain always knows about the user) is injected on EVERY call,
        // so the assistant feels like it remembers you across conversations. Honest: only the
        // buyer's own enabled memories, capped, never fabricated.
        let standing = memory.standingContext()
        if !standing.isEmpty { parts.append(standing) }
        // Structured client records: when the buyer names a saved client in the prompt, inject that
        // client's real contact history + deal pipeline so ANY brain (even text-only on-device) can
        // answer "what's the status of <client>?" from stored records. "" when no client is named.
        let crmGround = crm.grounding(for: prompt)
        if !crmGround.isEmpty { parts.append(crmGround) }
        // "What moved today?": when the buyer asks for a daily recap, inject the REAL digest computed
        // from their own activity ledger, CRM pipeline, and memory — so even a text-only on-device
        // brain reads back what actually changed. "" for any non-digest prompt (never injected otherwise).
        let digestGround = DailyDigest.grounding(activity: activity.entries, clients: crm.clients,
                                                 deals: crm.deals, memories: memory.items, for: prompt)
        if !digestGround.isEmpty { parts.append(digestGround) }
        // Relevant knowledge documents (on-device semantic RAG, with citation tags).
        let docs = SemanticRAG.groundingText(chunks)
        if !docs.isEmpty { parts.append(docs) }
        return parts.joined(separator: "\n\n")
    }
    /// What the chat brain ACTUALLY is and can do, stated to the model so it never invents
    /// capabilities. Without this, a bare local model happily claimed it could "manage files"
    /// and act "instantly" — abilities plain chat does not have (§5.1 applies to the model's own
    /// claims about the product too).
    private static let capabilityCard = """
    About your environment (state it honestly; never claim more): you are the chat brain inside \
    Sovereign, an assistant app using the brain the user configured. In this chat you CAN: answer \
    from your knowledge; use grounding excerpts provided from the user's own Knowledge and files; \
    read documents and URLs the user attaches; run web research when the user asks you to search. \
    You CANNOT directly manage files, control apps, send messages, or take actions from this chat. \
    Multi-step actions with tools (calendar, files, memory, connected apps) run from the app's \
    Agent screen, which shows a receipt for every real step. If the user asks for something \
    outside this chat's abilities, say so and point them to the right screen — never imply you \
    already did it.
    """
    private func effectiveSystem(for convoID: UUID) -> String {
        // Per-conversation persona override (by name) folds the profile's system prompt in.
        if let convo = store.conversations.first(where: { $0.id == convoID }),
           !convo.personaName.isEmpty,
           let p = profiles.profiles.first(where: { $0.name == convo.personaName }) {
            let base = p.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = p.assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
            let persona = name.isEmpty ? base : "Your name is \(name). \(base)"
            return persona + "\n\n" + Self.capabilityCard
        }
        return settings.effectiveSystemPrompt + "\n\n" + Self.capabilityCard
    }

    // MARK: Document import / drop
    private func importDocument() {
        let types: [UTType] = [.plainText, .pdf, .text, .json, .commaSeparatedText,
                               UTType("net.daringfireball.markdown") ?? .plainText, .sourceCode,
                               .png, .jpeg, .gif, .image].compactMap { $0 }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types
        if panel.runModal() == .OK { for url in panel.urls { loadDroppedFile(url) } }
        #else
        iosImportFiles(contentTypes: types, allowsMultiple: true) { urls in
            for url in urls { loadDroppedFile(url) }
        }
        #endif
    }
    private func loadDocument(_ url: URL) {
        // PDFs go through PDFKit's real text layer; plain text keeps the bounded-prefix decode.
        // A raw isoLatin1 decode of a PDF would feed binary mojibake to the model as grounding.
        // §5.1: a file that yields no text (scan/empty/too-large/unreadable) is surfaced as an
        // honest error chip, never swallowed — the buyer dropped it expecting feedback.
        switch DocumentText.extractOutcome(from: url) {
        case .text(let text):
            attachedDocError = nil
            attachedDocName = url.lastPathComponent
            attachedDocBody = text
        case .failed(let reason):
            attachedDocError = DocumentText.failureMessage(name: url.lastPathComponent, reason: reason)
        }
    }
    /// Max bytes we read from a dropped/imported text document. Only the first ~8 KB ever feeds
    /// grounding (see groundedAttachment()), so an unbounded Data(contentsOf:) on a multi-GB log/CSV/
    /// JSON would balloon memory — and could hang/OOM the app — on the buyer's OWN file, for
    /// nothing. We read at most this prefix via FileHandle, symmetric with loadImage's 5 MB cap.
    static let maxDocBytes = 2 * 1024 * 1024   // 2 MB
    /// Read at most `maxDocBytes` from `url` without mapping the whole file into memory.
    static func boundedDocData(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxDocBytes)
    }
    private func clearAttachment() { attachedDocName = nil; attachedDocBody = ""; attachedImages = []; attachedDocConvoID = nil; attachedDocError = nil }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                DispatchQueue.main.async { self.loadDroppedFile(url) }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { str, _ in
                guard let s = str as? String else { return }
                DispatchQueue.main.async { self.attachedDocName = "Pasted text"; self.attachedDocBody = s }
            }
            return true
        }
        return false
    }

    /// Route a dropped file: images → vision attachment; everything else → document grounding.
    private func loadDroppedFile(_ url: URL) {
        if let img = Self.loadImage(url) { attachedImages.append(img) }
        else { loadDocument(url) }
    }

    /// Read an image file into a BrainImage (base64) for External vision. Returns nil for non-images
    /// or anything over a sane size cap (External limits image bytes; we keep the buyer honest on cost).
    static func loadImage(_ url: URL) -> BrainImage? {
        let mediaType: String
        switch url.pathExtension.lowercased() {
        case "png": mediaType = "image/png"
        case "jpg", "jpeg": mediaType = "image/jpeg"
        case "webp": mediaType = "image/webp"
        case "gif": mediaType = "image/gif"
        default: return nil
        }
        guard let data = try? Data(contentsOf: url), data.count <= 5 * 1024 * 1024 else { return nil }
        return BrainImage(name: url.lastPathComponent, mediaType: mediaType, base64: data.base64EncodedString())
    }

    // MARK: Export
    private func exportConversation(_ c: Conversation) {
        var md = "# \(c.title)\n\n_\(c.created.formatted())_\n\n"
        for m in c.messages {
            md += m.role == .user ? "**You:** \(m.text)\n\n" : "**\(brandName):** \(m.text)\n\n"
        }
        saveText(md, suggested: "\(c.title).md")
    }
    private func saveText(_ text: String, suggested: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested.replacingOccurrences(of: "/", with: "-")
        panel.allowedContentTypes = [UTType("net.daringfireball.markdown") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url { try? text.data(using: .utf8)?.write(to: url) }
        #else
        iosExportText(text, suggestedName: suggested)
        #endif
    }
}
#endif // circuit-convert
