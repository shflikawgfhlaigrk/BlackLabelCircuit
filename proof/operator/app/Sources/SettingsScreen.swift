#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — Settings: the deep customization surface. Branding, brain/persona, voice,
// memory sources, connectors, appearance, saved profiles, account, storage, about. Every
// change persists to this device. Nothing hardcoded as fact.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

struct SettingsScreen: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var ai: AIEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var voice: VoiceEngine
    @EnvironmentObject var dictation: DictationEngine
    @EnvironmentObject var wake: WakeEngine
    @EnvironmentObject var memory: MemoryStore
    @EnvironmentObject var prompts: PromptLibrary
    @EnvironmentObject var brain: BrainRouter
    @EnvironmentObject var externalAuth: ExternalAuth
    @EnvironmentObject var selfCoding: SelfCodingEngine   // SV-11 self-coding tool-loop (gated surface)

    #if os(macOS)
    // Ambient context is a buyer-owned, durable preference. It ships OFF and reconciles the live
    // sampler immediately when changed; the sampler repeats the consent check at its own boundary.
    @AppStorage(AmbientSampler.enabledKey) private var ambientCaptureEnabled = AmbientSampler.shipsEnabled
    @State private var ambientAccessibilityTrusted = AmbientAX.isTrusted
    @State private var ambientSampleCount = 0
    #endif

    @State private var confirmDelete = false
    #if os(macOS)
    // Launch-at-login (SMAppService). Local to Settings — reflects the REAL system status, never faked.
    @StateObject private var launch = LaunchAtLogin()
    #endif
    @State private var voiceList: [VoiceOption] = []
    @State private var newProfileName = ""
    @State private var apiKeyDraft = ""
    @State private var externalErr = ""
    // CLI subscription connect (the buyer's own `external login`) — macOS only.
    @State private var cliConnecting = false
    @State private var cliStatus = ""        // honest result of the last probe (never faked)
    @State private var secondaryConnecting = false
    @State private var secondaryStatus = ""      // honest result of the last Secondary probe (never faked)
    // Custom CLI connect (any prompt-capable command on PATH) — macOS only.
    @State private var customCLIDraft = ""
    @State private var customCLIConnecting = false
    @State private var customCLIStatus = ""  // honest result of the last custom-CLI probe (never faked)
    // Ornith local brain (fully-local) — works in every build (loopback HTTP). TWO routes:
    // the buyer's own Ollama daemon (:11434) and any OpenAI-compatible server on a buyer-set port.
    @State private var ollamaModels: [OllamaModel] = []
    @State private var endpointModels: [String] = []
    @State private var localDetecting = false
    @State private var ollamaStatus = ""     // honest live result of the last /api/tags detect
    @State private var endpointStatus = ""   // honest live result of the last /v1/models detect
    @State private var endpointPortDraft = ""
    @State private var wakeTrainPasses = 0
    @State private var wakeTraining = false
    // Diagnostics — prove the brain answers and the daemon tools work (never faked).
    @State private var diagBrainBusy = false
    @State private var diagBrainResult = ""
    @State private var diagToolBusy = ""       // which tool test is running ("" = none)
    @State private var diagToolResult = ""
    @State private var researchStatus: ResearchStatus? = nil
    // Add-a-brain (optional cloud/CLI upgrades over the shipped Ornith default).
    @State private var addBrainKey = ""        // Claude API key draft (sk-ant-…)
    @State private var addBrainCLI = ""        // CLI command draft (claude / codex / custom)
    @State private var addBrainBusy = ""       // which connect is running ("" = none)
    @State private var addBrainStatus = ""     // honest result (✓/✗)
    // Claude-subscription sign-in (buyer's own Claude login via OAuth+PKCE, no bundled client_id).
    @State private var claudeSubClientID = ""  // buyer-pasted PUBLIC client_id (only when none stored)
    // One-tap "set up your free local brain": pull the fitting Ornith size into the buyer's own
    // Ollama, with real byte-progress. `setupState` drives the panel; nothing here is fabricated —
    // every number/phrase comes from the live /api/pull stream.
    @State private var setupState: LocalSetupState = .idle
    @State private var setupProgress = OllamaBrain.PullProgress()
    // Tracks which copy-paste command was last copied, so its button can show "Copied".
    @State private var copiedCommand: String = ""
    // Auto-detect: a FAST, non-blocking liveness probe of the buyer's own Ollama daemon. When it's
    // already running we skip the install guide and go straight to pull/select. Re-probed on the
    // panel's appear and after the copy-paste install command is used (§5.1: real probe only).
    @State private var ollamaPresence: OllamaDetection = .unknown
    // The Homebrew one-liner that installs + starts Ollama — named so copying it can trigger a re-probe.
    private let ollamaInstallCommand = "brew install --cask ollama && ollama serve"
    // The gguf / llama.cpp / LM Studio (OpenAI-compatible local server) route lives behind this
    // collapsed "Advanced" disclosure so the default first-run flow is exactly Ollama → Ornith → chat.
    @State private var showAdvancedLocal = false
    // Model library — one-tap browse-&-download of curated local models. Reuses the onboarding
    // /api/pull byte-stream pipeline (ModelPull → OllamaBrain.pull); progress is the real thing.
    @StateObject private var modelPull = ModelPull()
    // Live browse catalog: fetched from the loopback daemon (/api/models/catalog) to widen the menu
    // toward LM Studio/Msty breadth, with a graceful fallback to the built-in curated 8 when the
    // daemon is unreachable. Resolved purely by ModelRegistry — never a fabricated list. §5.1.
    @State private var browseCatalog: [CuratedModel] = ModelCatalog.curated
    @State private var browseSource: ModelRegistry.Source = .curatedFallback
    @State private var browseLoading = false

    /// Load the live browse catalog best-effort; keep the built-in menu on any failure (offline / no
    /// daemon / bad JSON) — and REPORT that failure rather than letting it read as an empty registry.
    /// The resolve/merge/fallback/unreachable decision is the pure, unit-tested ModelRegistry.
    private func loadBrowseCatalog() async {
        await MainActor.run { browseLoading = true }
        let base = await ToolClient.shared.resolveBase()
        let outcome = await ModelRegistry.fetchLive(base: base)
        let resolved = ModelRegistry.resolve(outcome: outcome)
        await MainActor.run {
            browseCatalog = resolved.models
            browseSource = resolved.source
            browseLoading = false
        }
    }

    /// The one-tap local-brain setup flow's honest state machine.
    enum LocalSetupState: Equatable {
        case idle
        case checking                 // probing whether Ollama is up
        case needsOllama(String)      // Ollama isn't installed/running — show the one-step install
        case pulling                  // downloading the Ornith GGUF (progress in setupProgress)
        case done(String)             // installed + selected — names the model
        case failed(String)           // honest failure text from the daemon/transport
    }

    private var googleConfigured: Bool {
        !settings.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func memoryCountLabel(grounded: Int, total: Int) -> String {
        grounded < total ? "\(grounded) of \(total)" : "\(total)"
    }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(title: "Settings", subtitle: "Tailor your operator — every change saves to this device")
            brandingPanel
            brainPanel
            // The model library's installed-list/download lanes and the Ornith/Ollama panel drive a
            // daemon at 127.0.0.1 with Mac install steps — impossible on iOS, where the honest
            // routes (Apple on-device + API key) live in Brain & persona and Add-a-brain below.
            #if os(macOS)
            modelLibraryPanel
            ollamaPanel
            #endif
            addBrainPanel
            diagnosticsPanel
            voicePanel
            memoryPanel
            #if os(macOS)
            ambientContextPanel
            #endif
            connectorsPanel
            guardrailsPanel
            selfCodingPanel
            #if os(macOS)
            launchPanel
            #endif
            appearancePanel
            themeStudioPanel
            profilesPanel
            accountPanel
            storagePanel
            #if os(macOS)
            supportPanel
            #endif
            aboutPanel
        }.padding(24) }
        .keyboardDismissable()
        .onAppear {
            voiceList = VoiceEngine.availableVoices()
            endpointPortDraft = String(settings.endpointPort)
            probeOllamaPresence()
            #if os(macOS)
            refreshAmbientStatus()
            #endif
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAmbientStatus()
        }
        #endif
        // Re-probe after the buyer copies the Ollama install one-liner — by the time they return to
        // this view the daemon may be up, so the install guide should quietly fold away.
        .onChange(of: copiedCommand) { cmd in
            if cmd == ollamaInstallCommand { probeOllamaPresence() }
        }
        .alert("Delete account and all data?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete everything", role: .destructive) {
                // Remove this account's credential, then wipe ALL local data (App Store 5.1.1(v)).
                // RootView owns every store, so it performs the coordinated, complete erase.
                if session.email != "guest" && !session.email.isEmpty { AccountStore.delete(session.email) }
                NotificationCenter.default.post(name: .sovWipeAllData, object: nil)
            }
        } message: {
            // The erase is complete for LOCAL data. It cannot reach a provider's own retention:
            // Sovereign holds no delete channel into the buyer's Anthropic/connector account, so
            // the copy states that limit instead of implying a deletion it cannot perform.
            Text("This permanently deletes your account and ALL data on this device — conversations, memory, notes, knowledge documents, prompts, skills, agents, automations, the activity log, saved profiles, and settings. This cannot be undone. It deletes local data on this device only and does not delete data retained by connected providers — use that provider's own account controls for anything they still hold.")
        }
    }

    private var brandingPanel: some View {
        Panel(title: "Branding & identity", icon: "paintpalette.fill") {
            Field(title: "Assistant name", text: $settings.assistantName, prompt: "Sovereign")
            Field(title: "Tagline", text: $settings.tagline, prompt: "Own your operator")
            Text("ACCENT").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            HStack(spacing: 8) {
                ForEach(AccentPreset.allCases) { p in
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { settings.accentPreset = p } } label: {
                        VStack(spacing: 4) {
                            Circle().fill(p == .custom ? AnyShapeStyle(settings.accent) : AnyShapeStyle(p.color))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(BLTheme.text.opacity(settings.accentPreset == p ? 0.9 : 0.15), lineWidth: settings.accentPreset == p ? 2 : 1))
                                .shadow(color: (p == .custom ? settings.accent : p.color).opacity(0.5), radius: settings.accentPreset == p ? 8 : 0)
                            Text(p.label).font(BLTheme.mono(8, weight: .medium)).foregroundColor(settings.accentPreset == p ? BLTheme.text : BLTheme.sub)
                        }
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            if settings.accentPreset == .custom {
                HStack(spacing: 8) {
                    Text("#").foregroundColor(BLTheme.sub).font(BLTheme.mono(13))
                    TextField("C9A961", text: $settings.customAccentHex)
                        .textFieldStyle(.plain).font(BLTheme.mono(13)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 8).padding(.horizontal, 11)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1)).frame(width: 130)
                    Text("Hex RRGGBB").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                    Spacer()
                }
            }
        }
    }

    private var brainPanel: some View {
        Panel(title: "Brain & persona", icon: "cpu") {
            // Which brain to use.
            Text("BRAIN").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            Picker("", selection: $settings.brainProvider) {
                ForEach(BrainProvider.visibleCases(externalConnected: externalAuth.isConnected)) { p in Text(p.label).tag(p) }
            }.labelsHidden().pickerStyle(.segmented).tint(settings.accent)
                .onChange(of: settings.brainProvider) { _ in brain.resolve() }
            Text(settings.brainProvider.blurb).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            // Honest live state of each brain.
            switch ai.availability {
            case .ready: Stat(label: "On-device model", value: "Apple FoundationModels · Ready", tint: BLTheme.green)
            case .unavailable(let reason):
                Stat(label: "On-device model", value: "Unavailable", tint: .orange)
                Text(reason).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            Stat(label: "Active brain", value: brain.active.label, tint: brain.isUsable ? BLTheme.green : .orange)

            Text("SYSTEM PROMPT (PERSONA & INSTRUCTIONS)").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            TextEditor(text: $settings.systemPrompt)
                .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                .scrollContentBackground(.hidden).padding(8).frame(height: 92)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            Text("Edits apply to the next message. The assistant's name is folded in automatically. Per-conversation personas can override this from a saved profile.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Add a cloud / CLI brain (optional upgrades over the shipped Ornith default)
    private var addBrainPanel: some View {
        Panel(title: "Add a cloud or CLI brain (optional)", icon: "link") {
            // The capability half is TRUE and is what the buyer is deciding on: `ActiveBrain.external`
            // is the only route with `supportsTools`, so the multi-step agent loop genuinely depends
            // on connecting one. Images are narrower still — `BrainRouter.supportsImages` returns
            // false for the CLI kinds — so the restored claim scopes image analysis to the API-key
            // route rather than repeating the old blanket "cloud/CLI" wording. Stating the data flow
            // precisely must not delete the reason to connect.
            Text("Choose a local brain or connect a provider you control. A connected provider also unlocks multi-step agents, and an API-key provider adds image analysis. Credentials are stored in Sovereign’s owner-only on-device credential directory and presented only for authentication. " + DataHandlingCopy.externalProcessing + " Sovereign bundles no account, key, or conversation history.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)

            #if os(macOS)
            if externalAuth.isConnected {
                Stat(label: "Connected brain", value: brainConnectedLabel, tint: BLTheme.green)
                Text(settings.brainProvider == .external
                     ? "This connected brain is active. Pick Ornith / on-device in Brain & persona above to switch back."
                     : "Connected, but Ornith/local is the active brain. Set the provider to “External” to use it.")
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                GhostButton(label: "Disconnect", icon: "rectangle.portrait.and.arrow.right", tint: BLTheme.danger) {
                    disconnectAddedBrain()
                }
            } else {
                // ── Claude — SUBSCRIPTION SIGN-IN (buyer's own Claude login via OAuth + PKCE) ──
                // One click runs the shared OAuthCore flow on the buyer's OWN Claude subscription; the
                // access token lands in Sovereign's private credential store only. No client_id/secret is bundled —
                // when Anthropic advertises DCR the client_id is minted on the fly, else the buyer pastes
                // their own PUBLIC client_id below. Nothing shows connected until a real token returns.
                Text("CLAUDE — SUBSCRIPTION (SIGN IN)").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                if ClaudeSubscriptionConnector.storedClientID == nil {
                    SecureField("your public OAuth client ID (optional)", text: $claudeSubClientID)
                        .textFieldStyle(.plain).font(BLTheme.mono(12)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 8).padding(.horizontal, 11)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                }
                GoldButton(label: addBrainBusy == "claude-sub" ? "Opening your Claude sign-in…" : "Sign in with Claude",
                           icon: addBrainBusy == "claude-sub" ? "hourglass" : "person.badge.key") {
                    connectClaudeSubscription()
                }
                Text("Signs in with YOUR Claude account in a secure browser window and runs on your own subscription — no key to paste, nothing billed to us. A client ID is public (not a secret); if Claude doesn't mint one automatically, paste your own from console.anthropic.com. The access token stays in Sovereign’s owner-only on-device credential directory, never bundled or synced.")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

                // ── Claude / Codex via CLI (round-trip verified before "connected") ──
                Text("CLAUDE / CODEX — CLI").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                HStack(spacing: 8) {
                    GhostButton(label: "Use Claude CLI", icon: "terminal") { addBrainCLI = "claude -p {prompt}" }
                    GhostButton(label: "Use Codex CLI", icon: "terminal") { addBrainCLI = "codex exec {prompt}" }
                }
                HStack(spacing: 8) {
                    TextField("claude -p {prompt}", text: $addBrainCLI)
                        .textFieldStyle(.plain).font(BLTheme.mono(12)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 8).padding(.horizontal, 11)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                    GoldButton(label: addBrainBusy == "cli" ? "Connecting…" : "Connect CLI",
                               icon: addBrainBusy == "cli" ? "hourglass" : "bolt.fill") { connectCLIBrain() }
                }
                Text("Point Sovereign at any prompt-capable CLI already installed and signed in on this Mac. `{prompt}` is where your message goes. Sovereign proves a real round-trip before it shows “connected” — it never fakes a connection.")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                // Full copy-paste account setup for the Claude CLI lane (uses the buyer's OWN Claude
                // login — no key of ours, billed to their own subscription). Numbered, one-tap copy.
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Install the Claude CLI (needs Node.js):")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        copyCommandRow("npm install -g @anthropic-ai/claude-code")
                        Text("2. Sign in with YOUR Claude account (opens your browser):")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        copyCommandRow("claude /login")
                        Text("3. Verify it answers, then press “Use Claude CLI” + “Connect CLI” above:")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        copyCommandRow("claude -p \"say hello\"")

                        Divider().padding(.vertical, 2)
                        Text("Prefer Codex? Same idea, using YOUR OpenAI/ChatGPT login:")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.champagne)
                        Text("1. Install the Codex CLI (needs Node.js):")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        copyCommandRow("npm install -g @openai/codex")
                        Text("2. Sign in with YOUR account (opens your browser):")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        copyCommandRow("codex login")
                        Text("3. Verify it answers, then press “Use Codex CLI” + “Connect CLI” above:")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        copyCommandRow("codex exec \"say hello\"")
                    }.padding(.top, 4)
                } label: {
                    Text("Step-by-step setup — Claude or Codex (copy-paste, no key needed)")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.champagne)
                }

                // ── Claude via API key ──
                Text("CLAUDE — API KEY").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                HStack(spacing: 8) {
                    SecureField("sk-ant-…", text: $addBrainKey)
                        .textFieldStyle(.plain).font(BLTheme.mono(12)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 8).padding(.horizontal, 11)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                    GoldButton(label: addBrainBusy == "api" ? "Verifying…" : "Connect",
                               icon: addBrainBusy == "api" ? "hourglass" : "key.fill") {
                        Task { await connectClaudeAPI() }
                    }.disabled(!addBrainBusy.isEmpty)
                }
                Text("Paste an Anthropic API key from console.anthropic.com. Sovereign verifies it with Anthropic before saving it in its owner-only on-device credential directory. Anthropic processes requests and bills your account.")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            if !addBrainStatus.isEmpty {
                Text(addBrainStatus).font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(addBrainStatus.hasPrefix("✓") ? BLTheme.green : .orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            #else
            if externalAuth.isConnected {
                Stat(label: "Connected provider", value: brainConnectedLabel, tint: BLTheme.green)
                GhostButton(label: "Disconnect", icon: "rectangle.portrait.and.arrow.right", tint: BLTheme.danger) {
                    disconnectAddedBrain()
                }
            } else {
                Text("ANTHROPIC API KEY").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                HStack(spacing: 8) {
                    SecureField("sk-ant-…", text: $addBrainKey)
                        .textFieldStyle(.plain).font(BLTheme.mono(12)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 8).padding(.horizontal, 11)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                    GoldButton(label: addBrainBusy == "api" ? "Verifying…" : "Connect",
                               icon: addBrainBusy == "api" ? "hourglass" : "key.fill") {
                        Task { await connectClaudeAPI() }
                    }.disabled(!addBrainBusy.isEmpty)
                }
                Text("Verified with Anthropic before it is stored in Sovereign’s owner-only on-device credential directory. Conversation history and selected document or memory context sent through this brain are processed by Anthropic and billed to your account. CLI-based Claude/Codex login is available only in the Mac app.")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            #endif

            // ── Apple Intelligence lane ──
            Text("APPLE INTELLIGENCE").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            switch ai.availability {
            case .ready:
                HStack(spacing: 8) {
                Text("Available on this device.").font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.text)
                    Spacer()
                    GhostButton(label: settings.brainProvider == .onDevice ? "In use" : "Use Apple Intelligence",
                                icon: "apple.logo", tint: settings.brainProvider == .onDevice ? BLTheme.green : BLTheme.text) {
                        settings.brainProvider = .onDevice; brain.resolve()
                        addBrainStatus = "✓ Switched to Apple's on-device model."
                    }
                }
            case .unavailable(let reason):
                Text("Not available on this device: \(reason)")
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A friendly label for whatever added brain is connected.
    private var brainConnectedLabel: String {
        switch externalAuth.connectedKind {
        case .apiKey, .oauth: return "Claude API · \(externalAuth.maskedLabel)"
        case .cli: return "Claude CLI"
        case .secondaryCLI: return "Secondary CLI"
        case .customCLI: return "CLI · \(externalAuth.maskedLabel)"
        case .none: return "—"
        }
    }

    /// Connect the buyer's own Claude subscription via OAuth PKCE. Stores the buyer-owned
    /// access token in the private credential store and activates it as the active external brain.
    private func connectClaudeSubscription() {
        guard addBrainBusy.isEmpty else { return }
        addBrainBusy = "claude-sub"
        addBrainStatus = ""
        let trimmedClientID = claudeSubClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedClientID.isEmpty {
            ClaudeSubscriptionConnector.setClientID(trimmedClientID)
        }
        Task { @MainActor in
            defer { addBrainBusy = "" }
            do {
                try await ClaudeSubscriptionConnector.signIn()
                settings.externalModel = "claude-opus-4-8"
                settings.brainProvider = .external
                brain.resolve()
                claudeSubClientID = ""
                addBrainStatus = "✓ Connected with your Claude subscription and set as the active brain — switch back to Ornith anytime."
            } catch let err as OAuthError {
                addBrainStatus = "✗ \(err.errorDescription ?? err.localizedDescription)"
            } catch {
                addBrainStatus = "✗ \(error.localizedDescription)"
            }
        }
    }

    /// Connect Claude by API key only after Anthropic's read-only Models endpoint accepts it.
    @MainActor private func connectClaudeAPI() async {
        guard addBrainBusy.isEmpty else { return }
        addBrainBusy = "api"
        addBrainStatus = "Verifying with Anthropic…"
        let outcome = await externalAuth.connect(apiKey: addBrainKey)
        switch outcome {
        case .rejected(let message), .invalidShape(let message), .storeFailed(let message):
            addBrainStatus = "✗ \(message)"
            addBrainBusy = ""
            return
        case .savedPendingVerification(let message):
            // M3: unreachable provider ≠ bad key. The key is saved here and re-checked; it is NOT
            // switched on as the active brain until a check actually succeeds.
            addBrainKey = ""
            addBrainStatus = "⏳ \(message)"
            addBrainBusy = ""
            brain.resolve()
            return
        case .verified:
            break
        }
        settings.externalModel = "claude-opus-4-8"   // a real current Anthropic model id
        settings.brainProvider = .external
        brain.resolve()
        addBrainKey = ""
        addBrainStatus = "✓ Verified with Anthropic and connected. It's now your active brain — switch back to Ornith anytime in Brain & persona."
        addBrainBusy = ""
    }

    /// Connect any prompt-capable CLI (Claude, Codex, custom) as the brain. Proves a REAL
    /// round-trip before storing "connected" — never paints a connection it didn't make.
    private func connectCLIBrain() {
        #if os(macOS)
        guard addBrainBusy.isEmpty else { return }
        let cmd = addBrainCLI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { addBrainStatus = "Enter a CLI command first — try the Claude or Codex buttons above."; return }
        addBrainBusy = "cli"; addBrainStatus = ""
        let spec = CustomCLISpec(command: cmd)
        Task { @MainActor in
            let result = await CustomCLIBrain.probe(spec: spec)
            addBrainBusy = ""
            switch result {
            case .ok:
                externalAuth.connectCustomCLI(spec: spec)
                settings.brainProvider = .external
                brain.resolve()
                addBrainStatus = "✓ Connected `\(spec.displayName)` as your brain — a real round-trip succeeded. Switch back to Ornith anytime."
            default:
                addBrainStatus = "✗ \(result.message)"
            }
        }
        #endif
    }

    /// Disconnect the added cloud/CLI brain and fall back to Ornith (the shipped default).
    private func disconnectAddedBrain() {
        externalAuth.disconnect()
        if settings.brainProvider == .external { settings.brainProvider = .ollama }
        brain.resolve()
        addBrainStatus = "Disconnected. Ornith (local) is your brain again."
    }

    // MARK: Diagnostics — prove the brain answers and the daemon tools work.
    private var diagnosticsPanel: some View {
        Panel(title: "Diagnostics — brain & tools", icon: "stethoscope") {
            Text("Prove the active brain answers and that Sovereign's real tools (desktop, vision, web, devices) work on this Mac. Every result below is live — nothing is simulated.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)

            Stat(label: "Active brain", value: brain.active.label, tint: brain.isUsable ? BLTheme.green : .orange)
            // Web-research connection state (truthful — always at least the keyless engine).
            if let rs = researchStatus {
                Stat(label: "Web research",
                     value: rs.connected ? "Connected · \(rs.activeProvider ?? "web")" : "Not connected",
                     tint: rs.connected ? BLTheme.green : .orange)
                if let note = rs.note, !note.isEmpty {
                    Text(note).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Stat(label: "Web research", value: "Checking…", tint: BLTheme.sub)
            }

            // Test brain — proves a chat completion works on the active brain.
            GoldButton(label: diagBrainBusy ? "Testing brain…" : "Test brain",
                       icon: diagBrainBusy ? "hourglass" : "bolt.fill") { testBrain() }
            if !diagBrainResult.isEmpty {
                Text(diagBrainResult).font(.system(size: 11.5, design: .rounded))
                    .foregroundColor(diagBrainResult.hasPrefix("✓") ? BLTheme.green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Test tools — each hits the real daemon tool and shows the live result.
            Text("TEST TOOLS").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            HStack(spacing: 8) {
                GhostButton(label: "Desktop", icon: "camera.viewfinder") { testTool("desktop") }
                GhostButton(label: "Vision", icon: "eye") { testTool("vision") }
            }
            HStack(spacing: 8) {
                GhostButton(label: "Web search", icon: "globe") { testTool("web") }
                GhostButton(label: "Devices", icon: "cable.connector") { testTool("devices") }
            }
            if !diagToolBusy.isEmpty {
                Text("Running \(diagToolBusy) test…").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            if !diagToolResult.isEmpty {
                Text(diagToolResult).font(.system(size: 11.5, design: .rounded))
                    .foregroundColor(diagToolResult.hasPrefix("✓") ? BLTheme.green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .onAppear { Task { researchStatus = await ToolClient.shared.researchStatus() } }
    }

    /// Prove the active brain can complete a prompt (never a fake reply).
    private func testBrain() {
        guard !diagBrainBusy else { return }
        diagBrainBusy = true; diagBrainResult = ""
        brain.complete(prompt: "Reply with exactly this phrase and nothing else: Sovereign brain online.",
                       system: "You are a test harness. Reply with exactly what is asked.") { result in
            Task { @MainActor in
                diagBrainBusy = false
                switch result {
                case .success(let text):
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    diagBrainResult = "✓ \(brain.active.label) replied: \(t.isEmpty ? "(empty)" : t)"
                case .failure(let err):
                    let msg = (err as? ExternalBrain.Failure)?.message ?? err.localizedDescription
                    diagBrainResult = "✗ \(msg)"
                }
            }
        }
    }

    /// Prove a daemon tool works end-to-end and show its live result.
    private func testTool(_ kind: String) {
        guard diagToolBusy.isEmpty else { return }
        diagToolBusy = kind; diagToolResult = ""
        Task {
            var line = ""
            switch kind {
            case "desktop":
                let r = await ToolClient.shared.callTool(name: "desktop.capture", args: [:])
                switch r {
                case .success(let obj):
                    let root = (obj["result"] as? [String: Any]) ?? obj
                    if let path = root["path"] as? String {
                        line = "✓ Desktop captured → \(path) (\((root["bytes"] as? Int) ?? 0) bytes)"
                    } else { line = "✗ \(root["error"] as? String ?? root["reason"] as? String ?? "capture failed")" }
                case .failure(let e): line = "✗ \(e)"
                }
            case "vision":
                let cap = await ToolClient.shared.callTool(name: "desktop.capture", args: [:])
                var path = ""
                if case .success(let obj) = cap { path = ((obj["result"] as? [String: Any]) ?? obj)["path"] as? String ?? "" }
                if path.isEmpty { line = "✗ couldn't capture a screenshot to analyze" ; break }
                let r = await ToolClient.shared.analyzeDesktop(path: path)
                switch r {
                case .success(let obs):
                    let front = obs.activeWindow?.app ?? "?"
                    line = "✓ Vision: \(obs.visibleApps.count) apps, \(obs.windows.count) windows, "
                        + "\(obs.textSeen.count) text lines · active: \(front) · OCR: \(obs.ocrSource ?? "?")"
                case .failure(let e): line = "✗ \(e)"
                }
            case "web":
                let r = await ToolClient.shared.searchWeb(query: "current date today news", count: 3)
                switch r {
                case .success(let results):
                    if let first = results.first {
                        line = "✓ Web search returned \(results.count) results. Top: \(first.title) — \(first.url)"
                    } else { line = "✗ search returned no results" }
                case .failure(let e): line = "✗ \(e)"
                }
            case "devices":
                let r = await ToolClient.shared.devices()
                switch r {
                case .success(let list): line = "✓ \(list.count) device(s) detected via the daemon"
                case .failure(let e): line = "✗ \(e)"
                }
            default: line = "✗ unknown test"
            }
            await MainActor.run { diagToolBusy = ""; diagToolResult = line }
        }
    }

    #if false
    /// Legacy external-account panel retained out of the shipped UI.
    private var externalPanel: some View {
        Panel(title: "Your AI account", icon: "key.fill") {
            if externalAuth.isConnected {
                Stat(label: "Connected", value: "\(connectedKindLabel) · \(externalAuth.maskedLabel)", tint: BLTheme.green)
                if externalAuth.connectedKind == .secondaryCLI {
                    Text("Secondary CLI uses your installed Secondary login in a clean read-only exec session. Sovereign stores only the CLI path, not an OpenAI key.")
                        .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Text("MODEL").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                        Spacer()
                        Picker("", selection: $settings.externalModel) {
                            Text("External Opus 4.8 (recommended)").tag("external-opus-4-8")
                            Text("External Sonnet 4.6").tag("external-sonnet-4-6")
                            Text("External Haiku 4.5").tag("external-haiku-4-5")
                        }.labelsHidden().pickerStyle(.menu).tint(settings.accent).frame(maxWidth: 280)
                            .onChange(of: settings.externalModel) { _ in brain.resolve() }
                    }
                }
                GhostButton(label: "Disconnect", icon: "rectangle.portrait.and.arrow.right", tint: BLTheme.danger) {
                    externalAuth.disconnect(); brain.resolve()
                }
                Text("Your credential or CLI path is stored in Sovereign’s owner-only on-device credential directory. A credential is presented to its provider as authentication; it is not bundled with Sovereign or written into workspace data.")
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            } else {
                #if os(macOS)
                if ExternalCLI.isSandboxed {
                    // SANDBOXED (App Store / TestFlight) build: a sandboxed process can't spawn the
                    // external CLI, so the subscription path is genuinely unavailable here. Say so
                    // honestly and route to the Mac download or the API-key path below — never a
                    // dead toggle that silently does nothing (§5.1 zero-fabrication).
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use my External or Secondary CLI")
                            .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text("CLI connect requires the Mac download version of Sovereign. This App Store build is sandboxed and can't launch external, secondary, or a custom CLI. On this build, connect with an API key below — or use the Ollama (local) brain, which works here too. Download the Mac version to use your local CLI account.")
                            .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.champagne).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider().overlay(BLTheme.stroke).padding(.vertical, 2)
                    Text("Connect with an API key")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                } else {
                    // PREFERRED (Developer-ID / Mac download build): run on the buyer's own External
                    // SUBSCRIPTION via the `external` CLI — no API key, no per-token billing. Their own
                    // logged-in session, their own machine.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use my External subscription (CLI)")
                            .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text("Run Sovereign on your own External Pro/Max plan — no API key, no per-token cost. Install the external CLI and run `external login` once, then connect below. It's your own External login, on your own device.")
                            .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                        GoldButton(label: cliConnecting ? "Checking your External…" : "Connect my External subscription",
                                   icon: cliConnecting ? "hourglass" : "person.badge.key.fill") {
                            connectCLI()
                        }
                        if !cliStatus.isEmpty {
                            Text(cliStatus)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundColor(cliStatus.hasPrefix("Connected") ? BLTheme.green : BLTheme.champagne)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider().overlay(BLTheme.stroke).padding(.vertical, 2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use my Secondary CLI")
                            .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text("Run Sovereign through your installed Secondary CLI. Open Secondary or run `secondary login` once, then connect below. Sovereign stores the CLI path only.")
                            .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                        GoldButton(label: secondaryConnecting ? "Checking Secondary…" : "Connect my Secondary CLI",
                                   icon: secondaryConnecting ? "hourglass" : "terminal.fill") {
                            connectSecondaryCLI()
                        }
                        if !secondaryStatus.isEmpty {
                            Text(secondaryStatus)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundColor(secondaryStatus.hasPrefix("Connected") ? BLTheme.green : BLTheme.champagne)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider().overlay(BLTheme.stroke).padding(.vertical, 2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use any CLI on your PATH")
                            .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text("Point Sovereign at any prompt-capable command — e.g. `llm -m llama3` or `mycli --prompt {prompt}`. Put {prompt} where the prompt goes, or leave it out to pipe the prompt on stdin. Sovereign runs your command on this device and returns its output.")
                            .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                        TextField("llm -m llama3   (or)   mycli --prompt {prompt}", text: $customCLIDraft)
                            .textFieldStyle(.plain).font(BLTheme.mono(12)).foregroundColor(BLTheme.text)
                            .padding(.vertical, 9).padding(.horizontal, 12)
                            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                        GoldButton(label: customCLIConnecting ? "Checking your CLI…" : "Connect my custom CLI",
                                   icon: customCLIConnecting ? "hourglass" : "terminal.fill") {
                            connectCustomCLI()
                        }
                        if !customCLIStatus.isEmpty {
                            Text(customCLIStatus)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundColor(customCLIStatus.hasPrefix("Connected") ? BLTheme.green : BLTheme.champagne)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider().overlay(BLTheme.stroke).padding(.vertical, 2)
                    Text("Or use an API key")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                }
                #endif
                Text("Run the assistant on your OWN External — vision, tools, and the latest models. Paste an API key from console.anthropic.com (starts with “sk-ant-”). Nothing is bundled with the app.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    SecureField("sk-ant-…", text: $apiKeyDraft)
                        .textFieldStyle(.plain).font(BLTheme.mono(12)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 9).padding(.horizontal, 12)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                    GoldButton(label: "Connect", icon: "checkmark") {
                        Task { @MainActor in
                            let outcome = await externalAuth.connect(apiKey: apiKeyDraft)
                            // A saved-but-unverified key clears the field (it IS stored) and states
                            // the honest reason; a rejection leaves the field for correction.
                            if outcome.didPersistCredential { apiKeyDraft = "" }
                            externalErr = outcome.message ?? ""
                            brain.resolve()
                        }
                    }
                }
                if !externalErr.isEmpty {
                    Text(externalErr).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true)
                }
                if externalAuth.legacyRecoveryAvailable {
                    GhostButton(label: "Recover credential from older build", icon: "key.horizontal", tint: BLTheme.gold) {
                        let result = externalAuth.recoverLegacyCredential()
                        switch result {
                        case .recovered:
                            externalErr = "Recovered into Sovereign’s private credential store. The old Keychain item was left untouched."
                            brain.resolve()
                        case .unavailable:
                            externalErr = "No readable credential was recovered. You can reconnect without deleting the old item."
                        case .storeFailed:
                            externalErr = "The old item was readable, but the private credential-store copy could not be verified. Nothing was deleted."
                        }
                    }
                }
                // A key saved on this device that has not been proven yet — stated, with the re-check.
                if let disclosure = externalAuth.verificationDisclosure {
                    Text(disclosure).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.champagne)
                        .fixedSize(horizontal: false, vertical: true)
                    GhostButton(label: "Verify now", icon: "arrow.clockwise", tint: BLTheme.gold) {
                        Task { @MainActor in
                            await externalAuth.reverifyIfNeeded()
                            brain.resolve()
                        }
                    }
                }
            }
        }
    }

    /// Honest label for the connected credential kind.
    private var connectedKindLabel: String {
        switch externalAuth.connectedKind {
        case .oauth: return "Sign-in"
        case .cli: return "Subscription (CLI)"
        case .secondaryCLI: return "Secondary (CLI)"
        case .customCLI: return "Custom CLI"
        case .apiKey, .none: return "API key"
        }
    }

    /// Connect the buyer's External SUBSCRIPTION via the CLI. PROVES a real round-trip before storing
    /// "connected" — never shows a connection that isn't real. macOS only.
    private func connectCLI() {
        #if os(macOS)
        guard !cliConnecting else { return }
        cliConnecting = true
        cliStatus = ""
        Task { @MainActor in
            let result = await CLIBrain.probe()
            cliConnecting = false
            switch result {
            case .ok(let path):
                externalAuth.connectCLI(cliPath: path)
                settings.brainProvider = .external
                brain.resolve()
                cliStatus = "Connected to your External subscription (CLI). The brain now runs on your own External plan."
            default:
                cliStatus = result.message
            }
        }
        #endif
    }

    /// Connect the buyer's Secondary CLI. PROVES a real round-trip before storing "connected".
    private func connectSecondaryCLI() {
        #if os(macOS)
        guard !secondaryConnecting else { return }
        secondaryConnecting = true
        secondaryStatus = ""
        Task { @MainActor in
            let result = await SecondaryCLIBrain.probe()
            secondaryConnecting = false
            switch result {
            case .ok(let path):
                externalAuth.connectSecondaryCLI(cliPath: path)
                settings.brainProvider = .external
                brain.resolve()
                secondaryStatus = "Connected to your Secondary CLI. The brain now runs through your installed Secondary account."
            default:
                secondaryStatus = result.message
            }
        }
        #endif
    }

    /// Connect ANY prompt-capable CLI on PATH. PROVES a real round-trip before storing "connected" —
    /// never paints a connection it didn't make. macOS only (subprocess spawn).
    private func connectCustomCLI() {
        #if os(macOS)
        guard !customCLIConnecting else { return }
        let cmd = customCLIDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { customCLIStatus = "Enter a command first — e.g. `llm -m llama3`."; return }
        customCLIConnecting = true
        customCLIStatus = ""
        let spec = CustomCLISpec(command: cmd)
        Task { @MainActor in
            let result = await CustomCLIBrain.probe(spec: spec)
            customCLIConnecting = false
            switch result {
            case .ok:
                externalAuth.connectCustomCLI(spec: spec)
                settings.brainProvider = .external
                brain.resolve()
                customCLIStatus = "Connected `\(spec.displayName)` as your brain. Sovereign now runs your command on this device."
            default:
                customCLIStatus = result.message
            }
        }
        #endif
    }
    #endif

    /// Ornith 1.0 — DUAL-ROUTE local brain panel. Detect probes BOTH loopback routes honestly:
    /// the buyer's Ollama daemon (:11434 /api/tags) AND any OpenAI-compatible server
    /// (127.0.0.1:<port> /v1/models — llama.cpp, LM Studio). Models from both are listed with
    /// their source; any model id containing “ornith” is marked as the recommended brain.
    /// Selecting a model from either route sets the brain and persists. Never invents a model.
    // MARK: Model library — the first-class, multi-provider browse-&-swap surface.
    /// One place to see every brain route and switch the model that answers: what's installed on
    /// this Mac (live /api/tags), a curated one-click download library (real /api/pull progress),
    /// Apple on-device, and a pointer to the advanced Claude/Codex route. Every swap is instant and
    /// stays on this Mac. §5.1: the installed list is live-probed, never fabricated.
    private var modelLibraryPanel: some View {
        Panel(title: "Model library", icon: "square.stack.3d.up.fill") {
            Text("Browse and switch the brain that answers — installed local models, a one-click download library, Apple on-device, or an advanced Claude/Codex route. Your selection is saved in local app settings.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            Stat(label: "Active brain", value: brain.active.label, tint: brain.isUsable ? BLTheme.green : .orange)
            Text("Route: \(settings.brainProvider.modelGroup)")
                .font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)

            // ── INSTALLED ON THIS MAC — live /api/tags (Ollama) + /v1/models (local server) ──
            HStack {
                Text("INSTALLED ON THIS MAC").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                Spacer()
                GhostButton(label: localDetecting ? "Refreshing…" : "Refresh installed models",
                            icon: localDetecting ? "hourglass" : "arrow.clockwise", tint: settings.accent) { detectLocalBrains() }
            }
            if ollamaModels.isEmpty && endpointModels.isEmpty {
                // Honest empty / unreachable — never a fabricated list. Surfaces the real probe result.
                Text(ollamaStatus.isEmpty
                     ? "No local models detected yet. Press Refresh — if Ollama isn't running, download a model below and Sovereign will install it for you."
                     : "Ollama: \(ollamaStatus)")
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.champagne).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(ollamaModels) { m in
                        localModelRow(name: m.name, detail: m.sizeLabel, source: "Ollama",
                                      isActive: settings.brainProvider == .ollama && settings.ollamaModel == m.name) {
                            applySwap(.ollama, model: m.name)
                        }
                    }
                    ForEach(endpointModels, id: \.self) { id in
                        localModelRow(name: id, detail: nil, source: "127.0.0.1:\(settings.endpointPort)",
                                      isActive: settings.brainProvider == .localEndpoint && settings.endpointModel == id) {
                            applySwap(.localEndpoint, model: id)
                        }
                    }
                }
            }

            // ── BROWSE MODELS — live registry (falls back to the built-in menu, and SAYS so) ──
            HStack {
                Text("BROWSE MODELS — one-click download").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                Spacer()
                if browseLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text(browseBadge).font(BLTheme.mono(8.5, weight: .bold))
                        .foregroundColor(browseBadgeTint).tracking(0.6)
                }
            }
            // An unreachable live registry is NOT the same as a short library. Saying "BUILT-IN MENU"
            // when the network actually failed would let an outage read as "this is everything there
            // is" — so the failure is stated, with its real reason, and offered a retry. The list
            // below stays the built-in menu: every tag in it is a real Ollama tag, so the buyer can
            // still download and swap. We never invent entries to paper over the gap. §5.1.
            if case .unreachable(let reason) = browseSource {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundColor(.orange)
                    Text("\(reason) Showing the built-in menu — these models still download and run.")
                        .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.champagne)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    GhostButton(label: "Retry", icon: "arrow.clockwise", tint: settings.accent) {
                        Task { await loadBrowseCatalog() }
                    }
                }
                .padding(10).background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 1))
            }
            ForEach(ModelCatalog.grouped(browseCatalog), id: \.category) { group in
                Text(group.category.label.uppercased())
                    .font(BLTheme.mono(8.5, weight: .bold)).foregroundColor(BLTheme.sub.opacity(0.8)).tracking(0.6)
                VStack(spacing: 8) { ForEach(group.models) { curatedModelRow($0) } }
            }
            .task { await loadBrowseCatalog() }
            if let err = modelPull.lastError {
                Text(err).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.champagne)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text("Sizes are approximate — Ollama reports the exact download size as it streams. Model inference runs on this Mac. Web research and connected tools make network requests only when you use those features.")
                .font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            // ── OTHER ROUTES — Apple on-device + a pointer to the advanced Claude/Codex lane ──
            Text("OTHER ROUTES").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            switch ai.availability {
            case .ready:
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Apple on-device").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                            // SV-21: on Apple silicon with Apple Intelligence enabled, this IS the
                            // zero-setup first-run default — group it honestly as the default route.
                            Text("DEFAULT").font(BLTheme.mono(8, weight: .bold)).foregroundColor(BLTheme.gold).tracking(0.6)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(BLTheme.gold.opacity(0.14)).clipShape(Capsule())
                        }
                        Text("Private, free, offline. Zero setup — the first-run default on this Mac.").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                    Spacer()
                    if settings.brainProvider == .onDevice {
                        Text("ACTIVE").font(BLTheme.mono(8.5, weight: .bold)).foregroundColor(BLTheme.green)
                    } else {
                        GhostButton(label: "Use", icon: "apple.logo", tint: settings.accent) { applySwap(.appleOnDevice) }
                    }
                }
                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(settings.brainProvider == .onDevice ? BLTheme.green.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
            case .unavailable(let reason):
                Text("Apple on-device isn't available on this Mac: \(reason). Use a local model above instead.")
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            Text("Want Claude or Codex on your own account? Connect it in “Add a cloud or CLI brain” below — it unlocks image analysis and multi-step agents, and you can switch back here anytime.")
                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The browse list's provenance badge — three DISTINCT states, because collapsing them would let
    /// an outage masquerade as a complete library.
    private var browseBadge: String {
        switch browseSource {
        case .live: return "LIVE · \(browseCatalog.count)"
        case .curatedFallback: return "BUILT-IN MENU"
        case .unreachable: return "REGISTRY UNREACHABLE"
        }
    }
    private var browseBadgeTint: Color {
        switch browseSource {
        case .live: return BLTheme.green
        case .curatedFallback: return BLTheme.sub
        case .unreachable: return .orange
        }
    }

    /// One curated browse row: name + blurb + approx size, with a state-driven action —
    /// ACTIVE badge / "Use" (installed) / "Download" (available, with live /api/pull progress).
    @ViewBuilder private func curatedModelRow(_ m: CuratedModel) -> some View {
        let activeTag = settings.brainProvider == .ollama ? settings.ollamaModel : ""
        let state = ModelRowState.classify(tag: m.tag, installedNames: ollamaModels.map { $0.name }, activeTag: activeTag)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: state == .active ? "checkmark.circle.fill" : (state == .installed ? "circle" : "arrow.down.circle"))
                    .font(.system(size: 14)).foregroundColor(state == .active ? BLTheme.green : BLTheme.sub)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(m.displayName).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                        if OrnithRecommended.matches(m.tag) { FoilBadge(text: "recommended") }
                    }
                    Text("\(m.blurb) · \(m.sizeLabel)").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch state {
                case .active:
                    Text("ACTIVE").font(BLTheme.mono(8.5, weight: .bold)).foregroundColor(BLTheme.green)
                case .installed:
                    GhostButton(label: "Use", icon: "checkmark", tint: settings.accent) { applySwap(.ollama, model: m.tag) }
                case .available:
                    if modelPull.isPulling(m.tag) {
                        ProgressView().controlSize(.small)
                    } else {
                        GoldButton(label: "Download", icon: "arrow.down") { downloadCurated(m) }
                    }
                }
            }
            // Live per-row progress bar while THIS model downloads — the real /api/pull byte stream.
            if modelPull.isPulling(m.tag) {
                ProgressView(value: modelPull.progress.fraction ?? 0).progressViewStyle(.linear).tint(BLTheme.green)
                Text(modelPull.progressLabel).font(BLTheme.mono(10)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(state == .active ? BLTheme.green.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
    }

    /// Download a curated model via the shared /api/pull pipeline, then select it the instant Ollama
    /// confirms it's installed — and refresh the installed list so its row flips to ACTIVE.
    private func downloadCurated(_ m: CuratedModel) {
        modelPull.pull(tag: m.tag) { installedName in
            applySwap(.ollama, model: installedName)
            detectLocalBrains()
        }
    }

    /// Apply a brain swap through the single pure decision map, then resolve the router. One code
    /// path for every route so "tap Use → what changes" is exactly what `BrainSwap.plan` computes.
    private func applySwap(_ route: ModelRoute, model: String = "") {
        let plan = BrainSwap.plan(route: route, model: model)
        switch route {
        case .ollama: settings.ollamaModel = plan.modelID
        case .localEndpoint: settings.endpointModel = plan.modelID
        case .appleOnDevice, .advanced: break   // no per-model id on these routes
        }
        settings.brainProvider = plan.provider
        brain.resolve()
    }

    private var ollamaPanel: some View {
        Panel(title: "Ornith 1.0 — local brain", icon: "desktopcomputer") {
            Text("Run Ornith 1.0 inference on this Mac through your own Ollama daemon — no model-provider account or API key. Web research and connected tools make network requests only when you use those features.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            // ONE-TAP DAY-ONE BRAIN: on a clean Mac, get a working local brain from inside the app —
            // no Terminal chore. The button probes Ollama, then pulls the fitting Ornith size with
            // real progress and selects it. If Ollama isn't there, an honest one-step install guide.
            localSetupBlock

            // Ornith ships in two sizes — the buyer picks the one that fits their Mac. Switching
            // retargets an Ornith (or empty) selection; a deliberate non-Ornith pick is kept.
            HStack(spacing: 8) {
                ForEach(OrnithRecommended.Variant.allCases) { v in ornithSizeCard(v) }
            }
            Text("This Mac has \(OrnithRecommended.thisMacRAMGB) GB of memory — Ornith \(OrnithRecommended.recommendedVariant(forRAMGB: OrnithRecommended.thisMacRAMGB).rawValue) is the size that fits it.")
                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)

            GoldButton(label: localDetecting ? "Checking for Ollama models…" : "Detect installed Ollama models",
                       icon: localDetecting ? "hourglass" : "arrow.clockwise") {
                detectLocalBrains()
            }
            if !ollamaStatus.isEmpty {
                Text("Ollama: \(ollamaStatus)")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(ollamaStatus.hasPrefix("found") ? BLTheme.green : BLTheme.champagne)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Detected Ollama models — every row names its real source; nothing invented.
            if !ollamaModels.isEmpty {
                VStack(spacing: 8) {
                    ForEach(ollamaModels) { m in
                        localModelRow(name: m.name, detail: m.sizeLabel, source: "Ollama",
                                      isActive: settings.brainProvider == .ollama && settings.ollamaModel == m.name) {
                            settings.ollamaModel = m.name
                            settings.brainProvider = .ollama
                            brain.resolve()
                        }
                    }
                }
            }

            Text("Sovereign's recommended brain is \(settings.ornithVariant.displayName) — install Ollama, run `ollama serve`, then `\(settings.ornithVariant.ollamaPullCommand)`. Detect above, then pick the model. Any tag containing “ornith” is recognized as the recommended brain.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            // ADVANCED — the second local route (an OpenAI-compatible server: llama.cpp, LM Studio,
            // a raw gguf served by llama-server). Collapsed by default so the day-one flow stays
            // Ollama → Ornith → chat; nothing removed, just relocated here for power users.
            DisclosureGroup(isExpanded: $showAdvancedLocal) {
                advancedLocalServerBlock
            } label: {
                Label("Advanced — OpenAI-compatible local server (llama.cpp, LM Studio, gguf)", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.champagne)
            }
            .tint(settings.accent)
        }
    }

    /// The relocated gguf / llama.cpp / LM Studio route: point Sovereign at any OpenAI-compatible
    /// server on 127.0.0.1:<port>. Host is ALWAYS loopback — only the port moves. Detection is
    /// shared with the Ollama route (the Detect button above probes both); this block surfaces the
    /// local-server port, its honest status, its detected models, and the serve guidance.
    @ViewBuilder private var advancedLocalServerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Point Sovereign at any OpenAI-compatible server (llama.cpp, LM Studio) running on 127.0.0.1. Model inference is fixed to loopback; web research and connected tools make network requests only when used.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            // Buyer-tunable local-server port. The host is ALWAYS loopback — only the port moves.
            HStack(spacing: 8) {
                Text("LOCAL SERVER PORT").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                TextField("8080", text: $endpointPortDraft)
                    .textFieldStyle(.plain).font(BLTheme.mono(12)).foregroundColor(BLTheme.text)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
                    .frame(width: 76)
                    .onSubmit { commitEndpointPort() }
                Text("host is fixed to 127.0.0.1 — never a remote server")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                Spacer()
            }

            if !endpointStatus.isEmpty {
                Text("Local server: \(endpointStatus)")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(endpointStatus.hasPrefix("found") ? BLTheme.green : BLTheme.champagne)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !endpointModels.isEmpty {
                VStack(spacing: 8) {
                    ForEach(endpointModels, id: \.self) { id in
                        localModelRow(name: id, detail: nil, source: "127.0.0.1:\(settings.endpointPort)",
                                      isActive: settings.brainProvider == .localEndpoint && settings.endpointModel == id) {
                            settings.endpointModel = id
                            settings.brainProvider = .localEndpoint
                            brain.resolve()
                        }
                    }
                }
            }

            Text("Serve Ornith here instead: \(OrnithRecommended.endpointServeGuidance) — e.g. `llama-server -m \(settings.ornithVariant.ggufFileName) --port \(settings.endpointPort)`. Press “Detect installed Ollama models” above — it probes this local server too — then pick the model. Any id containing “ornith” is recognized as the recommended brain.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    /// The one-tap "set up your free local brain" surface. Idle: a single GoldButton. Pulling: a live
    /// progress bar fed by the real /api/pull byte stream. needsOllama: an honest one-step install
    /// guide with a button that opens ollama.com/download. done/failed: honest result copy.
    @ViewBuilder private var localSetupBlock: some View {
        let v = settings.ornithVariant
        VStack(alignment: .leading, spacing: 8) {
            switch setupState {
            case .idle, .done, .failed:
                // Auto-detect: when the daemon is already up, say so (green) and skip straight to
                // setup — no install step. Only shown after a real probe resolved to `.running`.
                if let banner = ollamaPresence.runningBanner {
                    Label(banner, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.green).fixedSize(horizontal: false, vertical: true)
                }
                GoldButton(label: "Set up your free local brain — Ornith \(v.rawValue) (\(String(format: "%.1f", v.downloadGB)) GB)",
                           icon: "sparkles") { startLocalSetup() }
                if case .done(let m) = setupState {
                    Text("Installed \(m) into your Ollama and selected it. Ask The Brain anything — it runs on this Mac.")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let msg) = setupState {
                    Text(msg).font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(BLTheme.champagne).fixedSize(horizontal: false, vertical: true)
                }
            case .checking:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking for Ollama on this Mac…").font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub) }
            case .needsOllama(let why):
                VStack(alignment: .leading, spacing: 6) {
                    Text("One step first: install Ollama (free, open-source) so Sovereign can run Ornith locally — no account, no cloud.")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(why).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    // Two honest routes — pick either, no terminal knowledge required:
                    Text("1. One-click app").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.champagne)
                    HStack(spacing: 8) {
                        GhostButton(label: "Download Ollama", icon: "arrow.down.circle", tint: settings.accent) {
                            if let u = URL(string: "https://ollama.com/download") { NSWorkspace.shared.open(u) }
                        }
                        GhostButton(label: "I installed it — retry", icon: "arrow.clockwise", tint: BLTheme.text) { startLocalSetup() }
                    }
                    Text("Open the downloaded Ollama app once, then press retry above. Sovereign does the rest — no terminal.")
                        .font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    Text("2. Or copy-paste (if you use Homebrew)").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.champagne)
                    copyCommandRow(ollamaInstallCommand)
                    Text("Paste into Terminal, run it, then press retry. This installs Ollama and starts the local server in one line.")
                        .font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            case .pulling:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Downloading Ornith \(v.rawValue) into your Ollama…")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                    }
                    ProgressView(value: setupProgress.fraction ?? 0)
                        .progressViewStyle(.linear).tint(BLTheme.green)
                    Text(setupProgressLabel)
                        .font(BLTheme.mono(10.5)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.green.opacity(0.3), lineWidth: 1))
            }
        }
    }

    /// A copy-paste command row: monospaced command + a one-tap Copy button that puts the exact
    /// text on the clipboard (NSPasteboard). Used by the setup + account guides so a buyer never
    /// has to retype a command. Nothing is executed on their behalf — they paste and run it.
    @ViewBuilder private func copyCommandRow(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(BLTheme.mono(10.5)).foregroundColor(BLTheme.text)
                .textSelection(.enabled)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(BLTheme.stroke, lineWidth: 1))
            GhostButton(label: copiedCommand == command ? "Copied" : "Copy",
                        icon: copiedCommand == command ? "checkmark" : "doc.on.doc",
                        tint: copiedCommand == command ? BLTheme.green : settings.accent) {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                #endif
                copiedCommand = command
            }
        }
    }

    /// Honest one-line status under the progress bar: Ollama's own phase text + real byte counts.
    private var setupProgressLabel: String {
        let p = setupProgress
        let phase = p.status.isEmpty ? "starting…" : p.status
        if p.total > 0 {
            let f = ByteCountFormatter()
            f.countStyle = .file
            let pct = Int((p.fraction ?? 0) * 100)
            return "\(phase) — \(f.string(fromByteCount: p.completed)) / \(f.string(fromByteCount: p.total)) (\(pct)%)"
        }
        return phase
    }

    /// Fast, non-blocking auto-detect of the buyer's own Ollama daemon. Sets `ollamaPresence` from a
    /// real liveness probe (short timeout) plus a chat-model count — no fabrication. When it reports
    /// `.running`, the setup block skips the install guide and shows the green "detected" banner.
    private func probeOllamaPresence() {
        ollamaPresence = .detecting
        Task { @MainActor in
            let reachable = await OllamaBrain.quickReachable()
            var chatModels = 0
            if reachable {
                chatModels = ((try? await OllamaBrain().listModels()) ?? []).filter { $0.isChatCapable }.count
            }
            ollamaPresence = OllamaDetection.classify(reachable: reachable, chatModelCount: chatModels)
        }
    }

    /// Probe Ollama; if it's up, pull the fitting Ornith size; if not, guide the one-step install.
    /// Real network only — no fabricated progress, no fabricated "installed".
    private func startLocalSetup() {
        setupState = .checking
        setupProgress = OllamaBrain.PullProgress()
        Task { @MainActor in
            do {
                _ = try await OllamaBrain().version()
                await pullOrnith()
            } catch {
                let msg = (error as? OllamaBrain.Failure)?.message ?? error.localizedDescription
                setupState = .needsOllama(msg)
                ollamaPresence = .absent   // the setup probe just proved the daemon is down
            }
        }
    }

    /// Pull the buyer's fitting Ornith tag via /api/pull, streaming real progress, then select it.
    @MainActor private func pullOrnith() async {
        let v = settings.ornithVariant
        let tag = v.ollamaTag
        setupState = .pulling
        do {
            try await OllamaBrain().pull(model: tag) { p in
                Task { @MainActor in setupProgress = p }
            }
            // Confirm it's actually installed now (never claim success on faith) and select it.
            let installed = (try? await OllamaBrain().listModels()) ?? []
            let match = installed.first(where: { $0.name == tag })
                ?? installed.first(where: { OrnithRecommended.matches($0.name) && OrnithRecommended.variantHint($0.name) == v })
                ?? installed.first(where: { OrnithRecommended.matches($0.name) })
            guard let picked = match else {
                setupState = .failed("The download finished but the model isn't listed in Ollama yet. Press Detect below.")
                return
            }
            settings.ollamaModel = picked.name
            settings.brainProvider = .ollama
            brain.resolve()
            ollamaModels = installed.filter { $0.isChatCapable }
            setupState = .done(picked.name)
            ollamaPresence = .running(models: ollamaModels.count)   // pull confirmed the daemon is up
        } catch {
            let msg = (error as? OllamaBrain.Failure)?.message ?? error.localizedDescription
            setupState = .failed(msg)
        }
    }

    /// One selectable size of the recommended brain (35B / 9B): honest download size + memory
    /// need, a "fits this Mac" badge on the size this machine can actually hold, and selection
    /// that persists + retargets an Ornith/empty Ollama pick (never a deliberate non-Ornith one).
    @ViewBuilder private func ornithSizeCard(_ v: OrnithRecommended.Variant) -> some View {
        let isActive = settings.ornithVariant == v
        Button {
            settings.selectOrnithVariant(v)
            brain.resolve()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13)).foregroundColor(isActive ? BLTheme.green : BLTheme.sub)
                    Text("Ornith \(v.rawValue)")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                    if OrnithRecommended.recommendedVariant(forRAMGB: OrnithRecommended.thisMacRAMGB) == v {
                        FoilBadge(text: "fits this Mac")
                    }
                }
                Text(v.subtitle)
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? BLTheme.green.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// One detected local model row: name + real source (+ size when known), the Ornith
    /// recommended badge when it matches, and a Use button that sets brain + persists.
    @ViewBuilder private func localModelRow(name: String, detail: String?, source: String,
                                            isActive: Bool, select: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14)).foregroundColor(isActive ? BLTheme.green : BLTheme.sub)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(BLTheme.mono(11.5, weight: .semibold)).foregroundColor(BLTheme.text).lineLimit(1)
                    if OrnithRecommended.matches(name) { FoilBadge(text: "Ornith · recommended") }
                }
                Text(detail == nil ? source : "\(source) · \(detail ?? "")")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            if isActive {
                Text("ACTIVE").font(BLTheme.mono(8.5, weight: .bold)).foregroundColor(BLTheme.green)
            } else {
                GhostButton(label: "Use", icon: "checkmark", tint: settings.accent) { select() }
            }
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? BLTheme.green.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
    }

    /// Fold the typed port into settings (sanitized 1…65535; garbage falls back to the default).
    private func commitEndpointPort() {
        let t = endpointPortDraft.trimmingCharacters(in: .whitespaces)
        let port = OpenAIEndpointBrain.sanitizePort(Int(t) ?? OpenAIEndpointBrain.defaultPort)
        settings.endpointPort = port
        endpointPortDraft = String(port)
        brain.resolve()
    }

    /// Live dual probe — GET :11434/api/tags AND GET 127.0.0.1:<port>/v1/models, concurrently.
    /// Populates the unified list honestly, or surfaces each route's real down/no-models state.
    /// Never invents a model list; auto-fills only an EMPTY selection (prefers an Ornith match).
    private func detectLocalBrains() {
        guard !localDetecting else { return }
        commitEndpointPort()
        localDetecting = true
        ollamaStatus = ""; endpointStatus = ""
        let port = settings.endpointPort
        Task { @MainActor in
            // Start both probes concurrently — each answers (or fails) on its own.
            let ollamaProbe = Task { try await OllamaBrain().listModels().filter { $0.isChatCapable } }
            let endpointProbe = Task { try await OpenAIEndpointBrain().listModels(port: port) }
            do {
                let models = try await ollamaProbe.value
                ollamaModels = models
                ollamaStatus = models.isEmpty
                    ? "running, but no chat models are installed. Run `\(settings.ornithVariant.ollamaPullCommand)` in Terminal, then detect again."
                    : "found \(models.count) local model\(models.count == 1 ? "" : "s")."
            } catch {
                ollamaModels = []
                ollamaStatus = (error as? OllamaBrain.Failure)?.message ?? error.localizedDescription
            }
            do {
                let ids = try await endpointProbe.value
                endpointModels = ids
                endpointStatus = ids.isEmpty
                    ? "answering on 127.0.0.1:\(port), but /v1/models lists no models. Load one (llama.cpp `llama-server -m <model.gguf>` or LM Studio → Local Server), then detect again."
                    : "found \(ids.count) model\(ids.count == 1 ? "" : "s") on 127.0.0.1:\(port)."
            } catch {
                endpointModels = []
                endpointStatus = (error as? OpenAIEndpointBrain.Failure)?.message ?? error.localizedDescription
            }
            // Auto-fill an empty selection only (prefer the buyer's chosen Ornith size, then any
            // Ornith, on each route) — a choice the buyer already made is never flipped.
            if settings.ollamaModel.isEmpty, !ollamaModels.isEmpty {
                settings.ollamaModel = (ollamaModels.first(where: { OrnithRecommended.variantHint($0.name) == settings.ornithVariant })
                    ?? ollamaModels.first(where: { OrnithRecommended.matches($0.name) })
                    ?? ollamaModels[0]).name
            }
            if settings.endpointModel.isEmpty, !endpointModels.isEmpty {
                settings.endpointModel = endpointModels.first(where: { OrnithRecommended.variantHint($0) == settings.ornithVariant })
                    ?? endpointModels.first(where: { OrnithRecommended.matches($0) })
                    ?? endpointModels[0]
            }
            brain.resolve()
            localDetecting = false
        }
    }

    private var voicePanel: some View {
        Panel(title: "Voice", icon: "speaker.wave.2.fill") {
            Toggle(isOn: $settings.voiceEnabled) {
                Text("Speak replies aloud").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            }.tint(settings.accent)
            if settings.voiceEnabled {
                HStack {
                    Text("VOICE").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                    Spacer()
                    Picker("", selection: $settings.voiceIdentifier) {
                        Text("System default").tag("")
                        ForEach(voiceList) { v in Text(v.name).tag(v.id) }
                    }.labelsHidden().pickerStyle(.menu).tint(settings.accent).frame(maxWidth: 280)
                }
                GhostButton(label: voice.speaking ? "Stop" : "Preview voice", icon: voice.speaking ? "stop.fill" : "play.fill", tint: settings.accent) {
                    if voice.speaking { voice.stop() }
                    else { voice.speak("This is \(settings.assistantName.isEmpty ? "Sovereign" : settings.assistantName), your Sovereign operator.", voiceID: settings.voiceIdentifier) }
                }
                Text(dictation.available
                     ? "Voice output uses Apple speech synthesis — no microphone, no cloud. Voice input (dictation) is ON — click the mic in the composer; recognition runs " + (dictation.onDevice ? "on-device, so your audio never leaves this device." : "via the system speech service.")
                     : "Voice output uses Apple speech synthesis — no microphone, no cloud. " + dictation.unavailableReason)
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Off. When on, the assistant reads its replies aloud with a voice you pick.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
            }

            // WAKE WORD — always-listening activation, trained on this Mac, on-device.
            if wake.available {
                Toggle(isOn: $settings.wakeEnabled) {
                    Text("Wake word — “\(settings.wakePhrase)”")
                        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                }.tint(settings.accent).disabled(!settings.wakeTrained)
                if wakeTraining {
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle().fill(i < wakeTrainPasses ? BLTheme.green : BLTheme.bg2)
                                .overlay(Circle().stroke(i < wakeTrainPasses ? BLTheme.green : BLTheme.stroke, lineWidth: 1))
                                .frame(width: 12, height: 12)
                        }
                        Text(wake.heardPartial.isEmpty ? "Say “\(settings.assistantName)”…" : "Heard: “\(wake.heardPartial)”")
                            .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.gold).lineLimit(1)
                        Spacer()
                        GhostButton(label: "Stop", icon: "stop.fill", tint: settings.accent) { stopWakeTraining() }
                    }
                } else {
                    HStack(spacing: 10) {
                        GhostButton(label: settings.wakeTrained ? "Re-train wake word" : "Train wake word",
                                    icon: "waveform.badge.mic", tint: settings.accent) { runWakeTraining() }
                        Text(settings.wakeTrained
                             ? "Trained. When on, \(settings.assistantName) listens from launch — say the name, then just talk."
                             : "Not trained yet — three real recognitions of the name and it's on.")
                            .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                        Spacer()
                    }
                }
                if let e = wake.lastError {
                    Text(e).font(.system(size: 11, design: .rounded)).foregroundColor(.orange)
                    // A TCC denial names its fix: deep-link straight to the pane that re-grants it.
                    if let pane = wake.deniedPane {
                        GhostButton(label: "Open System Settings", icon: "gearshape.fill", tint: .orange) { pane.open() }
                    }
                }
            } else {
                Text("Wake word: " + wake.unavailableReason)
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
            }
        }
    }

    /// Three REAL training passes (a pass counts only when the recognizer heard the phrase).
    /// Success stores the phrase + flips wake on; RootView starts the loop live.
    private func runWakeTraining() {
        guard wake.available, !wakeTraining else { return }
        settings.wakeEnabled = false           // release the mic from any running wake loop
        wakeTrainPasses = 0
        wakeTraining = true
        Task { @MainActor in
            let phrase = settings.assistantName.isEmpty ? "Sovereign" : settings.assistantName
            while wakeTrainPasses < 3 && wakeTraining {
                let ok = await wake.trainPass(phrase: phrase)
                guard wakeTraining else { break }
                if ok { wakeTrainPasses += 1 }
            }
            if wakeTrainPasses >= 3 {
                settings.wakePhrase = phrase
                settings.wakeTrained = true
                settings.wakeEnabled = true    // RootView's onChange starts listening immediately
            }
            wakeTraining = false
        }
    }

    private func stopWakeTraining() {
        wakeTraining = false
        wake.stop()
    }

    private var memoryPanel: some View {
        Panel(title: "Memory & grounding sources", icon: "lock.doc.fill") {
            Toggle(isOn: $memory.memoryEnabled) {
                Text("Standing Memory — injected into every conversation (\(memory.injectedCount) active)").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            }.tint(settings.accent)
            Toggle(isOn: $settings.memory.useNotes) {
                Text("Ground replies on Vault notes (\(memoryCountLabel(grounded: model.groundedNotesCount, total: model.notes.count)))").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            }.tint(settings.accent)
            Stat(label: "Knowledge documents grounding (RAG)", value: "\(store.groundedDocCount) of \(store.documents.count)", tint: store.groundedDocCount > 0 ? BLTheme.green : BLTheme.sub)
            Text(DataHandlingCopy.memoryContext + " Vault notes and enabled Knowledge documents are added only when relevant. The counts show how much context actually reaches the selected brain; nothing is invented.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    #if os(macOS)
    private var ambientContextPanel: some View {
        Panel(title: "On-screen context", icon: "rectangle.on.rectangle.angled") {
            Toggle(isOn: $ambientCaptureEnabled) {
                Text("Remember the apps and windows I use")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.text)
            }
            .tint(settings.accent)
            .onChange(of: ambientCaptureEnabled) { isEnabled in
                AmbientSampler.shared.setBuyerOptIn(isEnabled)
                refreshAmbientStatus()
            }

            Text(ambientCaptureEnabled
                 ? "On. When you switch apps, Sovereign saves the app name, window title, site host, and accessible interface text to a private timeline on this Mac. Credential windows are skipped, and detected passwords, tokens, API keys, and payment-card numbers are redacted before saving. The timeline is never uploaded automatically. When an agent uses it, selected context is sent to the brain you chose; a connected cloud brain sends that context to its provider."
                 : "Off. Sovereign records no app switches or window context. The timeline ships empty and stays on this Mac if you choose to turn it on.")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)

            if ambientCaptureEnabled {
                Stat(label: "Accessibility",
                     value: ambientAccessibilityTrusted ? "Allowed" : "Permission needed",
                     tint: ambientAccessibilityTrusted ? BLTheme.green : .orange)
                if !ambientAccessibilityTrusted {
                    Text("Without Accessibility permission, Sovereign can note the active app but cannot read its window context. macOS binds this permission to the signed app you grant it to.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    GhostButton(label: "Open Accessibility Settings", icon: "hand.raised.fill", tint: settings.accent) {
                        // requestTrust fires the one-time OS prompt; on an already-denied Mac that
                        // prompt never re-fires, so deep-link straight to the Accessibility pane.
                        ambientAccessibilityTrusted = OperatorAXDriver.requestTrust()
                        if !ambientAccessibilityTrusted { PrivacyPane.accessibility.open() }
                    }
                } else {
                    GhostButton(label: "Recheck permission", icon: "arrow.clockwise", tint: settings.accent) {
                        refreshAmbientStatus()
                    }
                }
            }

            Stat(label: "Stored timeline", value: "\(ambientSampleCount) sample\(ambientSampleCount == 1 ? "" : "s")",
                 tint: ambientSampleCount > 0 ? settings.accent : BLTheme.sub)
            if ambientSampleCount > 0 {
                GhostButton(label: "Erase on-screen history", icon: "trash", tint: BLTheme.danger) {
                    AmbientTimelineStore.shared.deleteAll()
                    refreshAmbientStatus()
                }
            }
        }
    }

    private func refreshAmbientStatus() {
        ambientAccessibilityTrusted = AmbientAX.isTrusted
        ambientSampleCount = AmbientTimelineStore.shared.count()
    }
    #endif

    private var connectorsPanel: some View {
        Panel(title: "Connectors", icon: "puzzlepiece.extension.fill") {
            Text("ONE-CLICK INTEGRATIONS").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            ConnectorGallery()
            Divider().background(BLTheme.stroke).padding(.vertical, 6)
            Toggle(isOn: $settings.weatherEnabled) {
                Text("Weather (open-meteo, keyless)").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            }.tint(settings.accent)
            Field(title: "Google OAuth client ID", text: $settings.googleClientID, prompt: "your-id.apps.googleusercontent.com")
            Stat(label: "Google sign-in", value: googleConfigured ? "Configured" : "Not configured", tint: googleConfigured ? BLTheme.green : .orange)
            Text("Add your own Google client ID to enable Google sign-in (OAuth 2.0 + PKCE — no client secret stored). Until set, the Google button is hidden rather than dead.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var guardrailsPanel: some View {
        Panel(title: "Guardrails & safety policy", icon: "shield.lefthalf.filled") {
            // SV-15 — the operator autonomy dial. Segmented Manual/Auto/Skip that maps 1:1 onto the
            // safety posture below (one stored value), so this is the single top-level control.
            Text("OPERATOR AUTONOMY").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            Picker("", selection: Binding(get: { settings.approvalDial },
                                          set: { settings.approvalDial = $0 })) {
                ForEach(ApprovalDial.allCases) { d in
                    Label(d.label, systemImage: d.icon).tag(d)
                }
            }.labelsHidden().pickerStyle(.segmented).tint(settings.accent)
            Text(settings.approvalDial.blurb)
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            Divider().background(BLTheme.stroke).padding(.vertical, 4)
            Text("SAFETY POSTURE").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            Picker("", selection: $settings.guardrailPosture) {
                ForEach(GuardrailPosture.allCases) { p in Text(p.label).tag(p) }
            }.labelsHidden().pickerStyle(.segmented).tint(settings.accent)
            Text(settings.guardrailPosture.blurb)
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            Divider().background(BLTheme.stroke).padding(.vertical, 4)
            Text(OperatorAX.honestDescription)
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            Text(Guardrails.honestDescription)
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    // SV-11 — the self-coding tool-loop, made buyer-REACHABLE behind the same deny-by-default,
    // approve-every-step discipline as the operator. The MASTER flip is an owner policy gate
    // (`sov grant brain.toolloop`): this surface is honest and reachable, but ships OFF and the app
    // never flips it silently. The buyer can pre-authorize per-tool grants (deny-by-default) here.
    private var selfCodingPanel: some View {
        Panel(title: "Self-coding (developer)", icon: "chevron.left.forwardslash.chevron.right") {
            // Master state — read-only surface: turning the loop on is a founder policy gate.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selfCoding.masterEnabled ? "bolt.fill" : "lock.fill")
                    .font(.system(size: 12)).foregroundColor(selfCoding.masterEnabled ? BLTheme.green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(selfCoding.masterEnabled
                         ? "Self-coding is ON — \(SelfCodingLoop.visibleTools(masterEnabled: true, granted: selfCoding.granted).count) granted tool(s) reachable, every step approved."
                         : "Self-coding is OFF (default). Turning it on is an owner policy gate — grant `\(SelfCodingLoop.grantSubject)`. The loop performs nothing until then.")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Grant `\(SelfCodingLoop.grantSubject)` at the CLI to unlock the master. This build ships it off; it is never ungated silently.")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().background(BLTheme.stroke).padding(.vertical, 4)
            // Per-tool grants — deny-by-default. The buyer decides which tools the loop MAY use; even
            // so, nothing runs until the owner master flip above (belt and suspenders).
            Text("GRANTED TOOLS (DENY BY DEFAULT)").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            ForEach(SelfCodingTool.allCases) { tool in
                Toggle(isOn: Binding(get: { selfCoding.granted.contains(tool) },
                                     set: { selfCoding.setGranted(tool, $0) })) {
                    HStack(spacing: 8) {
                        Image(systemName: tool.icon).font(.system(size: 11)).foregroundColor(BLTheme.sub).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tool.label).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                            Text(tool.blurb).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.tint(settings.accent)
            }
            Divider().background(BLTheme.stroke).padding(.vertical, 4)
            // SV-17 — the self-authored-tool surface: proposed changes, the REAL diff BEFORE apply,
            // explicit approve/deny (deny-by-default), and rollback of an applied change to its bytes.
            selfCodingTrace
            Text(SelfCodingLoop.honestDescription)
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    // SV-17: the proposed self-authored tool changes. Renders the live trace — each step's decision,
    // the unified diff shown BEFORE apply, an explicit Approve/Deny for a held write, and Rollback for
    // an applied write. When the loop is off/idle (the shipped default) it shows an honest empty state,
    // never a fabricated "pending change".
    @ViewBuilder private var selfCodingTrace: some View {
        Text("PROPOSED CHANGES").font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
        if selfCoding.trace.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                Text(selfCoding.masterEnabled
                     ? "No proposed changes yet. When the brain proposes a self-authored edit it appears here — you review the full diff and approve before a single byte is written."
                     : "Self-coding is off, so there are no proposed changes. Nothing runs until the owner policy gate turns the loop on.")
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ForEach(selfCoding.trace) { step in selfCodingStepRow(step) }
        }
        Divider().background(BLTheme.stroke).padding(.vertical, 4)
    }

    @ViewBuilder private func selfCodingStepRow(_ step: SelfCodingStep) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: step.tool.icon).font(.system(size: 11)).foregroundColor(BLTheme.sub).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(step.tool.label) · \(step.target)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(selfCodingStatusLine(step))
                        .font(.system(size: 10.5, design: .rounded)).foregroundColor(selfCodingStatusTint(step))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The REAL unified diff, shown BEFORE apply for a file write — the see-it-first primitive.
            if let diff = step.diff, step.tool.touchesFiles {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(diff).font(.system(size: 10, design: .monospaced))
                        .foregroundColor(BLTheme.text).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(BLTheme.stroke, lineWidth: 1))
            }
            // Deny-by-default approval: a held (confirm) step needs an explicit Approve; Deny writes
            // nothing. An applied write can be rolled back to the exact pre-apply bytes.
            HStack(spacing: 8) {
                if step.decision.isConfirm && !step.applied && step.result == "Awaiting your approval." {
                    Button { selfCoding.resolve(step.id, approved: true) } label: {
                        Label("Approve", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(.borderedProminent).tint(BLTheme.green).controlSize(.small)
                    Button { selfCoding.resolve(step.id, approved: false) } label: {
                        Label("Deny", systemImage: "xmark.circle").font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                if step.canRollback {
                    Button { selfCoding.rollback(step.id) } label: {
                        Label("Roll back", systemImage: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(.bordered).tint(.orange).controlSize(.small)
                }
                // SV-17 publish-to-MCP (export half): export an approved+applied self-authored tool as
                // a standard MCP tool definition the buyer registers into their OWN server — copied to
                // the clipboard. Honest: an export, not a live registration (Sovereign hosts no server).
                if step.canPublish {
                    Button { publishSelfCodingTool(step) } label: {
                        Label("Publish to MCP", systemImage: "square.and.arrow.up.on.square")
                            .font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(.bordered).tint(BLTheme.gold).controlSize(.small)
                }
                if step.rolledBack {
                    Label("Rolled back", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 10.5, weight: .medium)).foregroundColor(.orange)
                }
                if let registered = step.registeredToolName {
                    Label("Registered locally as \u{201C}\(registered)\u{201D}", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 10.5, weight: .medium)).foregroundColor(BLTheme.green)
                } else if step.published {
                    Label("Exported MCP definition", systemImage: "square.and.arrow.up.on.square.fill")
                        .font(.system(size: 10.5, weight: .medium)).foregroundColor(BLTheme.gold)
                }
            }
            if step.canPublish || step.published {
                Text(SelfCodingPublish.honestNote)
                    .font(.system(size: 9.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Export the self-authored tool as an MCP tool definition and put the portable JSON on the
    /// clipboard. The declared spec carries only what we honestly know (the tool's target as its
    /// summary, no invented params); the engine records the real proof-of-execution receipt.
    private func publishSelfCodingTool(_ step: SelfCodingStep) {
        let spec = SelfAuthoredToolSpec(summary: "Self-authored tool from \(step.target).")
        if let json = selfCoding.publish(step.id, as: spec) {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
            #endif
        }
    }

    private func selfCodingStatusLine(_ step: SelfCodingStep) -> String {
        if step.rolledBack { return step.result }
        if step.applied { return step.result.isEmpty ? "Applied." : step.result }
        return step.result.isEmpty ? step.decision.reason : step.result
    }
    private func selfCodingStatusTint(_ step: SelfCodingStep) -> Color {
        if step.rolledBack { return .orange }
        if step.decision.isBlock { return .orange }
        if step.applied { return BLTheme.green }
        return BLTheme.sub
    }

    #if os(macOS)
    @AppStorage(MenuBarCompanion.hotkeyDefaultsKey) private var quickAskHotkey = true

    // Launch-at-login (SOV-AGENT-002): make the operator genuinely resident across logins. Honest:
    // the live SMAppService status is read from the system, never faked; the sandboxed App-Store
    // build shows the limitation and routes to the Mac download (where login items actually persist).
    private var launchPanel: some View {
        Panel(title: "Startup — resident operator", icon: "power") {
            if launch.sandboxLimited {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundColor(.orange).font(.system(size: 12))
                    Text("Launch at login is available in the Mac download (Developer-ID) version. This App Store build is sandboxed and can't register a persistent login item. Download the Mac version to make Sovereign a resident operator that starts when you log in.")
                        .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
                Text("Live login-item status: \(launch.statusText)")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.sub)
            } else {
                Toggle(isOn: Binding(get: { launch.isEnabled }, set: { launch.setEnabled($0) })) {
                    Text("Start Sovereign when I log in").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                }.tint(settings.accent)
                Text(launch.statusText)
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                if let err = launch.lastError {
                    Text("Login item error: \(err)").font(.system(size: 11, design: .rounded)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("Registers Sovereign as a macOS login item (SMAppService). Combined with scheduled tasks, your operator runs whenever you're logged in — not a boot-time system daemon, which the sandbox forbids.")
                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.15)
            Toggle(isOn: $quickAskHotkey) {
                Text("Quick Ask hotkey (⌥Space) from any app").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            }.tint(settings.accent)
            Text("Summons the floating quick-ask box system-wide. Turn this off if you type Option-Space (a non-breaking space on some keyboard layouts) or another launcher owns that shortcut. Takes effect immediately.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }.onAppear { launch.refresh() }
    }
    #endif

    private var appearancePanel: some View {
        Panel(title: "Appearance", icon: "sparkles") {
            Toggle(isOn: $settings.motionEnabled) {
                Text("Holographic motion (shimmer, sweep, drift)").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            }.tint(settings.accent)
            Text("Slow ambient animations. Turning this off — or enabling Reduce Motion in macOS — stills the app.")
                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Theme / Appearance Studio (live preview + full holographic customization)
    @State private var newHoloPresetName = ""

    private var themeStudioPanel: some View {
        Panel(title: "Theme Studio", icon: "wand.and.stars.inverse") {
            Text("Own the look. Every control retunes the holographic FX across the whole app instantly — the preview below is live.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            ThemeStudioPreview()
                .frame(height: 168)
                .padding(.vertical, 2)

            // Presets — one-click named looks + the buyer's own saved looks.
            studioLabel("PRESETS")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(settings.allHoloPresets) { p in presetChip(p) }
                }.padding(.vertical, 2)
            }
            HStack(spacing: 10) {
                TextField("Name this look", text: $newHoloPresetName)
                    .textFieldStyle(.plain).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                    .padding(.vertical, 8).padding(.horizontal, 11)
                    .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                GoldButton(label: "Save look", icon: "square.and.arrow.down") {
                    settings.saveHoloPreset(named: newHoloPresetName); newHoloPresetName = ""
                }
            }

            Divider().background(BLTheme.stroke).padding(.vertical, 4)

            // Accent + iridescent companion hue.
            studioLabel("ACCENT")
            HStack(spacing: 10) {
                ForEach(holoAccentSwatches, id: \.self) { hex in accentSwatch(hex) }
                ColorPicker("", selection: accentBinding, supportsOpacity: false).labelsHidden().frame(width: 34)
                Spacer()
            }
            HStack(spacing: 10) {
                Text("IRIDESCENT HUE").font(BLTheme.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                ColorPicker("", selection: secondaryBinding, supportsOpacity: false).labelsHidden().frame(width: 34)
                Spacer()
            }

            // Holo Intensity.
            studioLabel("HOLO INTENSITY")
            Picker("", selection: Binding(get: { settings.holoStored.intensity }, set: { settings.holoStored.intensity = $0 })) {
                ForEach(HoloIntensity.allCases) { Text($0.label).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).tint(settings.accent)

            // Motion Level.
            studioLabel("MOTION LEVEL")
            Picker("", selection: Binding(get: { settings.holoStored.motion }, set: { settings.holoStored.motion = $0 })) {
                ForEach(MotionLevel.allCases) { Text($0.label).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).tint(settings.accent)
            Text("Reduce Motion (macOS) and the Appearance “Holographic motion” toggle both still hard-override to safe.")
                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            // Background style.
            studioLabel("BACKGROUND")
            Picker("", selection: Binding(get: { settings.holoStored.background }, set: { settings.holoStored.background = $0 })) {
                ForEach(HoloBackground.allCases) { Text($0.label).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).tint(settings.accent)

            // Particle density.
            sliderRow("PARTICLE DENSITY",
                      value: Binding(get: { settings.holoStored.particleDensity }, set: { settings.holoStored.particleDensity = $0 }),
                      detail: settings.holoStored.particleDensity <= 0.01 ? "Off" : "\(Int((settings.holoStored.particleDensity * 56).rounded())) motes")

            // Glow strength.
            sliderRow("GLOW STRENGTH",
                      value: Binding(get: { settings.holoStored.glowStrength }, set: { settings.holoStored.glowStrength = $0 }),
                      detail: "\(Int((settings.holoStored.glowStrength * 100).rounded()))%")

            // Card tilt.
            Toggle(isOn: Binding(get: { settings.holoStored.tiltEnabled }, set: { settings.holoStored.tiltEnabled = $0 })) {
                Text("Card 3D tilt (pointer-reactive)").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            }.tint(settings.accent)
            if settings.holoStored.tiltEnabled {
                sliderRow("TILT STRENGTH",
                          value: Binding(get: { settings.holoStored.tiltStrength }, set: { settings.holoStored.tiltStrength = $0 }),
                          detail: "\(Int((settings.holoStored.tiltStrength * 100).rounded()))%")
            }
        }
    }

    private var holoAccentSwatches: [String] { ["C9A961", "D4C5A0", "8B3A4A", "4FD7FF", "8FE3C8", "9B8CFF", "FF4FD8"] }
    private var accentBinding: Binding<Color> {
        Binding(get: { Color.fromHex(settings.holoStored.accentHex) },
                set: { settings.holoStored.accentHex = $0.hexString })
    }
    private var secondaryBinding: Binding<Color> {
        Binding(get: { Color.fromHex(settings.holoStored.secondaryHex, fallback: 0x4FD7FF) },
                set: { settings.holoStored.secondaryHex = $0.hexString })
    }
    @ViewBuilder private func studioLabel(_ s: String) -> some View {
        Text(s).font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8).padding(.top, 2)
    }
    @ViewBuilder private func accentSwatch(_ hex: String) -> some View {
        let selected = settings.holoStored.accentHex.uppercased() == hex
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { settings.holoStored.accentHex = hex } } label: {
            Circle().fill(Color.fromHex(hex)).frame(width: 26, height: 26)
                .overlay(Circle().stroke(BLTheme.text.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2 : 1))
                .shadow(color: Color.fromHex(hex).opacity(0.5), radius: selected ? 8 : 0)
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func sliderRow(_ label: String, value: Binding<Double>, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                studioLabel(label)
                Spacer()
                Text(detail).font(BLTheme.mono(9.5, weight: .medium)).foregroundColor(BLTheme.sub)
            }
            Slider(value: value, in: 0...1).tint(settings.accent)
        }
    }
    @ViewBuilder private func presetChip(_ p: HoloPreset) -> some View {
        VStack(spacing: 5) {
            // tiny accent/secondary swatch pair as a look thumbnail
            HStack(spacing: 0) {
                Color.fromHex(p.value.accentHex)
                Color.fromHex(p.value.secondaryHex, fallback: 0x4FD7FF)
            }
            .frame(width: 56, height: 30).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
            Text(p.name).font(BLTheme.mono(8.5, weight: .bold)).foregroundColor(BLTheme.text).lineLimit(1)
            if p.builtIn {
                Button("Apply") { withAnimation { settings.applyHoloPreset(p) } }
                    .buttonStyle(.plain).font(BLTheme.mono(8, weight: .bold)).foregroundColor(settings.accent)
            } else {
                HStack(spacing: 6) {
                    Button("Apply") { withAnimation { settings.applyHoloPreset(p) } }
                        .buttonStyle(.plain).font(BLTheme.mono(8, weight: .bold)).foregroundColor(settings.accent)
                    Button { settings.deleteHoloPreset(p) } label: { Image(systemName: "trash").font(.system(size: 8)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Delete preset")
                }
            }
        }
        .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private var profilesPanel: some View {
        Panel(title: "Saved profiles", icon: "person.2.crop.square.stack.fill") {
            HStack(spacing: 10) {
                TextField("Profile name", text: $newProfileName)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                GoldButton(label: "Save current", icon: "square.and.arrow.down") {
                    profiles.capture(named: newProfileName, from: settings); newProfileName = ""
                }
            }
            if profiles.profiles.isEmpty {
                Text("Capture the current name, tagline, accent, and persona as a reusable profile — white-label in seconds, and switch personas per conversation.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) { ForEach(profiles.profiles) { p in profileRow(p) } }
            }
        }
    }

    @ViewBuilder private func profileRow(_ p: BrandProfile) -> some View {
        HStack(spacing: 10) {
            Circle().fill(p.accentPreset == .custom ? AnyShapeStyle(Color(hex: UInt32(p.customAccentHex, radix: 16) ?? 0xC9A961)) : AnyShapeStyle(p.accentPreset.color))
                .frame(width: 22, height: 22).overlay(Circle().stroke(BLTheme.stroke, lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("\(p.assistantName) · \(p.tagline)").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
            }
            Spacer()
            GhostButton(label: "Apply", icon: "checkmark", tint: settings.accent) { withAnimation { profiles.apply(p, to: settings) } }
            Button { profiles.delete(p) } label: { Image(systemName: "trash").font(.system(size: 12)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Delete profile")
        }
        .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private var accountPanel: some View {
        Panel(title: "Account", icon: "person.crop.circle") {
            Stat(label: "Signed in as", value: session.email.isEmpty ? "guest" : session.email)
            HStack(spacing: 10) {
                GhostButton(label: "Sign out", icon: "rectangle.portrait.and.arrow.right") {
                    // Sign out must clear the remembered session, or the next launch re-signs-in.
                    RememberedSession.forget()
                    withAnimation { session.signedIn = false; session.email = "" }
                }
                Spacer()
                GhostButton(label: "Reset settings", icon: "arrow.counterclockwise", tint: BLTheme.sub) { withAnimation { settings.resetToDefaults() } }
            }
            // App Store Guideline 5.1.1(v): a single, unmistakable action that deletes the account
            // AND erases every byte of local data. Shown for any signed-in identity (incl. guest),
            // since a guest still accumulates on-device data.
            GhostButton(label: session.email == "guest" || session.email.isEmpty ? "Delete all my data" : "Delete account and all data",
                        icon: "trash", tint: BLTheme.danger) { confirmDelete = true }
                .help("Permanently delete your account and every byte of data stored on this device.")
        }
    }

    private var storagePanel: some View {
        Panel(title: "Local storage", icon: "internaldrive") {
            if let note = store.dataHealthNote {
                Text(note).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Stat(label: "Conversations", value: "\(store.conversations.count)")
            Stat(label: "Messages", value: "\(store.totalMessages)")
            Stat(label: "Knowledge documents", value: "\(store.documents.count)")
            Stat(label: "Knowledge words", value: "\(store.totalKnowledgeWords)")
            Stat(label: "Notes", value: "\(model.notes.count)")
            Stat(label: "Memories", value: "\(memory.items.count)")
            Stat(label: "Saved prompts", value: "\(prompts.custom.count)")
            Stat(label: "Automations", value: "\(store.automations.count)")
            Stat(label: "Reminders", value: "\(store.reminders.count)")
        }
    }

    #if os(macOS)
    // MARK: Support — privacy-safe diagnostic report export (DOD-11.5).
    @State private var diagExportStatus = ""

    private var supportPanel: some View {
        Panel(title: "Support", icon: "lifepreserver") {
            Text("Export a privacy-safe diagnostics report to attach to a support request. It contains version identity, macOS version and architecture, feature toggles, and item counts — never conversation content, document text, credentials, your account address, or file paths.")
                .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                GoldButton(label: "Export diagnostics report", icon: "square.and.arrow.up") { exportDiagnostics() }
                if !diagExportStatus.isEmpty {
                    Text(diagExportStatus).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                }
                Spacer()
            }
        }
    }

    /// Gather the facts (all already shown on this screen), compose the pure report, and let the
    /// buyer choose where it goes. Honest status either way — including write failures.
    private func exportDiagnostics() {
        let facts = DiagnosticFacts(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
            bundleID: Bundle.main.bundleIdentifier ?? "com.blacklabel.sovereign",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: DiagnosticsReport.currentArchitecture(),
            brainProviderLabel: settings.brainProvider.label,
            localModelTag: settings.ollamaModel,
            wakeWordEnabled: settings.wakeEnabled,
            signedIn: session.signedIn,
            accountKind: (session.email.isEmpty || session.email == "guest") ? "guest" : "account",
            conversations: store.conversations.count,
            messages: store.totalMessages,
            documents: store.documents.count,
            knowledgeWords: store.totalKnowledgeWords,
            notes: model.notes.count,
            memories: memory.items.count,
            savedPrompts: prompts.custom.count,
            automations: store.automations.count,
            reminders: store.reminders.count,
            generatedAt: Date())
        let report = DiagnosticsReport.compose(facts)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DiagnosticsReport.filename()
        panel.title = "Export Diagnostics Report"
        panel.canCreateDirectories = true
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                diagExportStatus = "Saved \(url.lastPathComponent)"
            } catch {
                diagExportStatus = "Export failed: \(error.localizedDescription)"
            }
        }
    }
    #endif

    /// Version string derived from the bundle — never hardcoded, so About can't drift from the
    /// shipped Info.plist (the "v1.1" hardcode contradicted the 1.0 build-43 release).
    private var aboutVersionLabel: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        if let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !b.isEmpty {
            return "Sovereign v\(v) (build \(b))"
        }
        return "Sovereign v\(v)"
    }

    private var aboutPanel: some View {
        Panel(title: "About", icon: "info.circle") {
            HStack(spacing: 8) {
                Text(aboutVersionLabel).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                FoilBadge(text: "Black Label")
            }
            // "Perpetual license." is a macOS sale claim; the iOS build sells/verifies no license.
            #if os(macOS)
            Text("The AI operator you own, running from this device with a local brain or a provider you connect. Sovereign includes conversations, cited knowledge, memory, skills, automations, branding, and a white-label shell. Perpetual license. " + DataHandlingCopy.storageAndExternal)
                .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            #else
            Text("The AI operator you own, running from this device with a local brain or a provider you connect. Sovereign includes conversations, cited knowledge, memory, skills, automations, branding, and a white-label shell. " + DataHandlingCopy.storageAndExternal)
                .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            #endif
            // App Store review requires a privacy policy reachable from inside the app, not only
            // from the store listing. One constant, so this link can never drift from the shipped URL.
            Link("Privacy Policy", destination: DataHandlingCopy.privacyPolicyURL)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundColor(settings.accent)
        }
    }
}
#endif // circuit-convert
