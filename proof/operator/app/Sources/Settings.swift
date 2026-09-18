// Sovereign — buyer customization store. Everything here is the BUYER's own choice,
// persisted on-device (UserDefaults). NOTHING is hardcoded as fact: defaults are
// neutral, and the running app reflects whatever the buyer sets. No Michael data,
// no Utah dependency, no seeded sample records. Starts on honest defaults.
import Foundation
import CircuitPortKit
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Buyer-visible storage and provider data flow

/// One precise disclosure reused anywhere the UI describes workspace privacy. Storage is local;
/// inference egress depends on the brain the buyer selects. Keeping these concepts separate avoids
/// turning a true storage claim into a false claim that external-provider requests never leave.
enum DataHandlingCopy {
    static let localStorage =
        "Conversations, documents, and memories are stored in this device's local app data."
    static let externalProcessing =
        "When you use a configured external provider, the prompt, recent conversation history, attachments, and selected document, memory, tool, or other enabled context needed for that request are sent to that provider for processing."
    /// The other half of the truth, and the half a privacy-precision pass is most likely to delete by
    /// accident: naming the provider is NOT the same as saying who it belongs to. Both facts hold at
    /// once and both are verifiable in this tree —
    ///   · "runs on your own account" — `ExternalAuth` stores the BUYER's own credential in this
    ///     device's Keychain and `ExternalBrain.makeRequest()` authenticates with it; there is no
    ///     Black Label key, proxy, or relay anywhere in the request path.
    ///   · "Black Label never receives your data" — the ONLY blacklabelbots.com traffic in Sources is
    ///     `Updater.manifestURL`, an unauthenticated GET of a public version manifest that carries no
    ///     body and no buyer identifier, plus a `Link` to the privacy policy. No analytics SDK, no
    ///     telemetry beacon, no measurement domain.
    /// Deleting this to make the provider disclosure precise would trade one true statement for
    /// another instead of stating both, so it is a named constant and pinned by the suite.
    static let providerOwnershipAndNoBackend =
        "That provider is one you configure and it runs on your own account; Black Label operates no backend and never receives your data."
    static let storageAndExternal =
        localStorage + " " + externalProcessing + " " + providerOwnershipAndNoBackend
    static let documentImport =
        "Documents are read into local app storage. When you use a configured external provider, selected document excerpts needed for your request are sent to that provider for processing."
    static let memoryContext =
        "Enabled memories are stored in local app data and included as context on every prompt. When you use a configured external provider, that memory context is sent to the provider for processing."

    /// Exact default shipped before build 21's provider-neutral correction. Only this literal is
    /// migrated; buyer-authored instructions remain untouched.
    static let legacyOnDeviceSystemPrompt =
        "You are a private on-device assistant. You run entirely on this device. Be concise, helpful, and direct. Never claim to access the internet or external services."
    static let defaultSystemPrompt =
        "You are the assistant configured for this workspace. Be concise, helpful, and direct. Describe tools, network access, provider behavior, and privacy only from real runtime results. Never claim an action, source, connection, or privacy property that was not verified."

    static func migrateLegacySystemPrompt(_ value: String) -> String {
        value == legacyOnDeviceSystemPrompt ? defaultSystemPrompt : value
    }

    /// The canonical, live buyer-facing privacy policy. App Store review requires a reachable
    /// privacy policy link from inside the app; this is the single constant every surface links to
    /// so the shipped URL can never drift between Settings, About, and the store listing.
    static let privacyPolicyURL = URL(string: "https://blacklabelbots.com/privacy")!
}

// MARK: - SV-09 — ownership + precise data handling, stated where the buyer actually reads it

/// The two promises that make Sovereign different from every assistant it competes with: you OWN it
/// (one payment, perpetual — not a subscription), and your data STAYS HERE (on-device storage, no
/// Black Label backend). Both were true and both were buried in Settings, which is the same as not
/// saying them. These constants put them on the FIRST RUN screen, and pin them so the claim can't
/// quietly drift away from what the product actually does.
///
/// §5.1 precision — every clause is literally true and nothing overclaims:
///   · "one payment · perpetual" — SV-10: own-it-once, no subscription.
///   · "stored in this device's local app data" — a claim about STORAGE, which is on-device, always.
///   · the external-provider clause — the honest caveat. Without it the guarantee would imply nothing
///     ever leaves the device, which is a promise an optional cloud brain would break.
///   · the ownership clause — the caveat must not swallow the differentiator. If the buyer connects
///     Claude/Codex, prompts go to THEIR OWN account with that provider, and Black Label still never
///     receives their data (§5.5, no backend dependency). Precision about the provider and the
///     no-backend promise are BOTH true; the copy states both.
enum OwnershipCopy {
    // The purchase-terms clause is a claim about the SALE, which only the macOS lane makes (and
    // enforces). The iOS binary sells and verifies nothing — its line states only what that build
    // guarantees: no account, no subscription mechanics, storage on this device.
    #if os(iOS)
    static let firstRunGuarantee =
        "Sovereign runs from this device — no account and no subscription. "
        + DataHandlingCopy.storageAndExternal
    #else
    static let firstRunGuarantee =
        "You own Sovereign — one payment, a perpetual license, no subscription. "
        + DataHandlingCopy.storageAndExternal
    #endif

    /// The short form for the first-run headline row.
    static let firstRunTitle = "Yours to own — with storage you control"
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Accent presets (the buyer can also pick a fully custom hex)
enum AccentPreset: String, CaseIterable, Identifiable, Codable {
    case gold, champagne, burgundy, holo, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .gold: return "Gold"
        case .champagne: return "Champagne"
        case .burgundy: return "Burgundy"
        case .holo: return "Holo Cyan"
        case .custom: return "Custom"
        }
    }
    var color: Color {
        switch self {
        case .gold: return Color(hex: 0xC9A961)
        case .champagne: return Color(hex: 0xD4C5A0)
        case .burgundy: return Color(hex: 0x8B3A4A)
        case .holo: return Color(hex: 0x4FD7FF)
        case .custom: return Color(hex: 0xC9A961)
        }
    }
}
#endif // circuit-convert

// MARK: - Voice choice (mirrors the system speech voices actually installed on THIS Mac)
struct VoiceOption: Identifiable, Hashable {
    let id: String        // AVSpeechSynthesisVoice identifier
    let name: String
}

// MARK: - Memory source toggles (which local stores the brain may ground on)
struct MemorySources: Codable, Equatable {
    var useNotes = true        // ground replies on the buyer's Vault notes
    var useDispatchLog = false // ground on the dispatch audit trail
}

// MARK: - Holographic theme model (the single source of truth the whole FX kit reads)
// Everything visual — border iridescence, sheen, glow, particle density, drift speed,
// background style, card tilt — scales off these knobs so the buyer fully owns the look.
// Persisted as part of AppSettings; no hardcoded intensities anywhere in the kit.

enum HoloIntensity: String, Codable, CaseIterable, Identifiable {
    case off, subtle, balanced, full
    var id: String { rawValue }
    var label: String { ["off": "Off", "subtle": "Subtle", "balanced": "Balanced", "full": "Full"][rawValue] ?? rawValue.capitalized }
    /// Master multiplier the kit applies to border iridescence, sheen & glow.
    var scale: Double { switch self { case .off: return 0; case .subtle: return 0.45; case .balanced: return 0.78; case .full: return 1.0 } }
}

enum MotionLevel: String, Codable, CaseIterable, Identifiable {
    case off, calm, lively
    var id: String { rawValue }
    var label: String { ["off": "Off", "calm": "Calm", "lively": "Lively"][rawValue] ?? rawValue.capitalized }
    /// Speed multiplier (>1 = faster). 0 means no continuous loops.
    var speed: Double { switch self { case .off: return 0; case .calm: return 0.7; case .lively: return 1.35 } }
    var animates: Bool { self != .off }
}

enum HoloBackground: String, Codable, CaseIterable, Identifiable {
    case aurora, starfield, solid
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// The live theme the FX kit reads from the environment. Pure value type so it threads cheaply
/// and SwiftUI can diff it. `effectiveMotion`/`effectiveScale` fold in the global motion gate
/// + Reduce Motion so each component just reads the resolved value.
struct HoloTheme: Equatable {
    var accent: Color = Color(hex: 0xC9A961)
    var secondary: Color = Color(hex: 0x4FD7FF)     // iridescent companion hue
    var intensity: HoloIntensity = .full
    var motion: MotionLevel = .calm
    var particleDensity: Double = 0.55              // 0…1 (maps onto a capped count)
    var background: HoloBackground = .aurora
    var tiltEnabled: Bool = false                   // default OFF — pointer 3D tilt perspective-softens card text; opt back in via Theme Studio
    var tiltStrength: Double = 0.6                  // 0…1
    var glowStrength: Double = 0.7                  // 0…1
    /// True only when continuous animation is allowed (global toggle + Reduce Motion already folded in by RootView).
    var motionAllowed: Bool = true

    /// Resolved continuous-motion flag the kit gates loops on.
    var animates: Bool { motionAllowed && motion.animates && intensity != .off }
    /// Resolved effect strength (0…1) — combines intensity + glow knob, zeroed when off.
    var fxScale: Double { intensity.scale }
    var glow: Double { glowStrength * intensity.scale }
    var tilt: Double { (tiltEnabled && intensity != .off) ? tiltStrength : 0 }
    /// Capped particle count (kept GPU-light) — 0…56.
    var particleCount: Int { intensity == .off ? 0 : Int((particleDensity * 56).rounded()) }
    var driftSpeed: Double { animates ? motion.speed : 0 }

    /// Persisted, accent-resolved snapshot used to compare presets in tests.
    struct Stored: Codable, Equatable, Hashable {
        var accentHex: String = "C9A961"
        var secondaryHex: String = "4FD7FF"
        var intensity: HoloIntensity = .full
        var motion: MotionLevel = .calm
        var particleDensity: Double = 0.55
        var background: HoloBackground = .aurora
        var tiltEnabled: Bool = false               // default OFF (see HoloTheme.tiltEnabled)
        var tiltStrength: Double = 0.6
        var glowStrength: Double = 0.7
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// A named, one-click look. Built-ins ship with the app; the buyer can save their own.
struct HoloPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var value: HoloTheme.Stored
    var builtIn: Bool = false

    /// The five shipped looks (pure config — no data, no personal info).
    static let builtIns: [HoloPreset] = [
        HoloPreset(name: "Gold Vault", value: .init(accentHex: "C9A961", secondaryHex: "4FD7FF", intensity: .full, motion: .calm, particleDensity: 0.55, background: .aurora, tiltEnabled: false, tiltStrength: 0.6, glowStrength: 0.7), builtIn: true),
        HoloPreset(name: "Platinum", value: .init(accentHex: "D4C5A0", secondaryHex: "BFE9FF", intensity: .balanced, motion: .calm, particleDensity: 0.35, background: .aurora, tiltEnabled: false, tiltStrength: 0.45, glowStrength: 0.5), builtIn: true),
        HoloPreset(name: "Aurora", value: .init(accentHex: "8FE3C8", secondaryHex: "9B8CFF", intensity: .full, motion: .lively, particleDensity: 0.7, background: .aurora, tiltEnabled: false, tiltStrength: 0.7, glowStrength: 0.85), builtIn: true),
        HoloPreset(name: "Cyber Neon", value: .init(accentHex: "4FD7FF", secondaryHex: "FF4FD8", intensity: .full, motion: .lively, particleDensity: 0.85, background: .starfield, tiltEnabled: false, tiltStrength: 0.85, glowStrength: 1.0), builtIn: true),
        HoloPreset(name: "Midnight", value: .init(accentHex: "C9A961", secondaryHex: "6B7CFF", intensity: .subtle, motion: .calm, particleDensity: 0.2, background: .solid, tiltEnabled: false, tiltStrength: 0.3, glowStrength: 0.35), builtIn: true)
    ]
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension Color {
    /// Hex string "RRGGBB" -> Color, falling back to gold for garbage. Used by HoloTheme persistence.
    static func fromHex(_ s: String, fallback: UInt32 = 0xC9A961) -> Color {
        let v = UInt32(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: ""), radix: 16)
        return Color(hex: v ?? fallback)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Single source of truth for every buyer-tunable knob. Persisted to UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    // Branding / identity
    @Published var assistantName: String { didSet { persist() } }
    @Published var tagline: String { didSet { persist() } }
    @Published var accentPreset: AccentPreset { didSet { persist() } }
    @Published var customAccentHex: String { didSet { persist() } }   // "RRGGBB"

    // Motion / accessibility
    @Published var motionEnabled: Bool { didSet { persist() } }

    // Voice
    @Published var voiceEnabled: Bool { didSet { persist() } }
    @Published var voiceIdentifier: String { didSet { persist() } }   // "" = system default
    @Published var wakeEnabled: Bool { didSet { persist() } }         // always-listening wake word (only after training)
    @Published var wakeTrained: Bool { didSet { persist() } }         // 3 real recognitions passed — never defaulted true
    @Published var wakePhrase: String { didSet { persist() } }        // the trained phrase (assistant's name by default)

    // Brain
    @Published var systemPrompt: String { didSet { persist() } }       // buyer-editable persona/instructions
    @Published var memory: MemorySources { didSet { persist() } }
    @Published var brainProvider: BrainProvider { didSet { persist() } }  // ollama | on-device; legacy values still decode
    @Published var externalModel: String { didSet { persist() } }           // legacy external-account model id
    @Published var ollamaModel: String { didSet { persist() } }           // buyer's chosen local Ollama model
    @Published var ornithVariant: OrnithRecommended.Variant { didSet { persist() } } // chosen size of the recommended brain (35B / 9B)
    @Published var endpointModel: String { didSet { persist() } }        // buyer's chosen local-server (OpenAI-compatible) model id
    @Published var endpointPort: Int { didSet { persist() } }            // buyer's local-server port (host is always 127.0.0.1)
    @Published var semanticRAG: Bool { didSet { persist() } }             // embedding retrieval (on) vs keyword (off)
    // Research mode: every chat question runs through live web research (search → read →
    // cite) with the active brain as summarizer. Off = normal chat, with automatic
    // research escalation only when the local brain misses ("I can't look that up").
    @Published var researchMode: Bool { didSet { persist() } }

    // Guardrails — the buyer's safety posture for side-effecting agent/connector actions. Persisted
    // in this same settings blob (no new key); mirrored to GuardrailPolicy.current so the AgentEngine
    // reads the live choice. Default is the safe `.confirmSideEffects`.
    @Published var guardrailPosture: GuardrailPosture { didSet { persist(); GuardrailPolicy.current = guardrailPosture } }

    /// SV-15 — the operator's top-level Manual/Auto/Skip autonomy dial. It is a VIEW over the same
    /// stored `guardrailPosture` (no second persisted key, no divergent policy): reading maps the
    /// posture to a dial, writing maps the dial back to a posture. The operator + agent both gate
    /// through the one grant engine. Default `.manual` (deny-by-default).
    var approvalDial: ApprovalDial {
        get { ApprovalDial(posture: guardrailPosture) }
        set { guardrailPosture = newValue.posture }
    }

    // Connectors (honest: only weather is wired in this build; others are buyer-gated config)
    @Published var weatherEnabled: Bool { didSet { persist() } }
    @Published var googleClientID: String { didSet { persist() } }     // buyer's own OAuth client id

    // Holographic Theme / Appearance Studio (the whole FX kit reads `holoTheme`).
    @Published var holoStored: HoloTheme.Stored { didSet { persist() } }
    @Published var savedHoloPresets: [HoloPreset] = [] { didSet { persist() } }

    private let d = UserDefaults.standard
    private let key = "com.blacklabel.sovereign.settings.v1"
    /// Demo Mode: settings changed inside the demo stay in memory only (ship-no-data —
    /// "nothing saved" must hold for UserDefaults exactly as it does for the JSON stores).
    private var demoEphemeral = false

    /// The resolved accent color the whole UI reads from.
    var accent: Color {
        if accentPreset == .custom, let v = UInt32(customAccentHex, radix: 16) { return Color(hex: v) }
        return accentPreset.color
    }

    /// The live HoloTheme the FX kit consumes. `motionAllowed` is injected by RootView (folds in
    /// the global motion toggle + macOS Reduce Motion). Accent here mirrors the branding accent so
    /// the two stay consistent, while the Studio's own hue knobs layer iridescence on top.
    func holoTheme(motionAllowed: Bool) -> HoloTheme {
        HoloTheme(accent: Color.fromHex(holoStored.accentHex),
                  secondary: Color.fromHex(holoStored.secondaryHex, fallback: 0x4FD7FF),
                  intensity: holoStored.intensity,
                  motion: holoStored.motion,
                  particleDensity: holoStored.particleDensity,
                  background: holoStored.background,
                  tiltEnabled: holoStored.tiltEnabled,
                  tiltStrength: holoStored.tiltStrength,
                  glowStrength: holoStored.glowStrength,
                  motionAllowed: motionAllowed)
    }

    /// Apply a named look (preset) to the live theme — persists instantly, app-wide.
    func applyHoloPreset(_ p: HoloPreset) { holoStored = p.value }
    /// Save the current Studio settings as a reusable named preset.
    func saveHoloPreset(named name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        savedHoloPresets.insert(HoloPreset(name: t, value: holoStored, builtIn: false), at: 0)
    }
    func deleteHoloPreset(_ p: HoloPreset) { savedHoloPresets.removeAll { $0.id == p.id } }
    /// Built-ins + the buyer's own, in one ordered list for the Studio.
    var allHoloPresets: [HoloPreset] { HoloPreset.builtIns + savedHoloPresets }

    init() {
        // Honest, neutral defaults — not personalized to any individual.
        var s = Stored()
        if let data = d.data(forKey: key), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            s = decoded
        } else if let brand = WhiteLabel.installed {
            // SV-16: a white-label export carries a brand seed in its bundle. On a FRESH profile it
            // becomes the defaults, so the client's build opens already calling itself by their name.
            // Only on a fresh profile: a seed must never overwrite settings the user has since chosen.
            s = Stored.seeded(with: brand)
        }
        let migratedSystemPrompt = DataHandlingCopy.migrateLegacySystemPrompt(s.systemPrompt)
        let didMigrateSystemPrompt = migratedSystemPrompt != s.systemPrompt
        s.systemPrompt = migratedSystemPrompt
        assistantName = s.assistantName
        tagline = s.tagline
        accentPreset = s.accentPreset
        customAccentHex = s.customAccentHex
        motionEnabled = s.motionEnabled
        voiceEnabled = s.voiceEnabled
        voiceIdentifier = s.voiceIdentifier
        systemPrompt = s.systemPrompt
        memory = s.memory
        brainProvider = s.brainProvider
        externalModel = s.externalModel
        ollamaModel = s.ollamaModel
        ornithVariant = s.ornithVariant.flatMap { OrnithRecommended.Variant(rawValue: $0) }
            ?? OrnithRecommended.recommendedVariant(forRAMGB: OrnithRecommended.thisMacRAMGB)
        endpointModel = s.endpointModel ?? ""
        endpointPort = OpenAIEndpointBrain.sanitizePort(s.endpointPort ?? OpenAIEndpointBrain.defaultPort)
        wakeEnabled = s.wakeEnabled ?? false
        wakeTrained = s.wakeTrained ?? false
        wakePhrase = (s.wakePhrase?.isEmpty == false) ? s.wakePhrase! : "Sovereign"
        semanticRAG = s.semanticRAG
        researchMode = s.researchMode ?? false
        guardrailPosture = s.guardrailPosture
        weatherEnabled = s.weatherEnabled
        googleClientID = s.googleClientID
        holoStored = s.holoStored
        savedHoloPresets = s.savedHoloPresets
        // Mirror the loaded posture into the process-wide live value the AgentEngine reads.
        GuardrailPolicy.current = guardrailPosture
        if didMigrateSystemPrompt { persist() }
    }

    /// Internal (not private) so the test suite can prove the white-label seeding rule directly
    /// rather than only source-scanning for it.
    struct Stored: Codable {
        var assistantName = "Sovereign"
        var tagline = "Own your operator"
        var accentPreset: AccentPreset = .gold
        var customAccentHex = "C9A961"
        // Fresh profiles ship with motion OFF (Founder 2026-07-08, mirroring the Marketing
        // directive): the iridescent drift/particles annoyed a first-run tester and tax weaker
        // machines. It stays a one-tap opt-in in Appearance. Existing profiles keep their saved
        // choice — this default only applies before anything is persisted.
        var motionEnabled = false
        var voiceEnabled = false
        var voiceIdentifier = ""
        var systemPrompt = DataHandlingCopy.defaultSystemPrompt
        var memory = MemorySources()
        // Ornith is the brain Sovereign SHIPS WITH — the local, private, free default. A blank
        // device is guided to install it in one tap (Settings → Brain). Claude (API/CLI), Codex
        // (CLI), and Apple Intelligence are opt-in add-ons the buyer connects. (Founder 2026-07-07,
        // superseding the 2026-07-03 Apple-on-device default, which errored when Apple Intelligence
        // wasn't downloaded — ModelManagerError 1026.)
        var brainProvider: BrainProvider = .ollama
        var externalModel = ""
        var ollamaModel = OllamaBrain.sovereignRecommendedModel
        // OPTIONAL so pre-existing settings blobs (which lack these keys) still decode —
        // adding a required key here would silently reset every buyer's saved settings.
        var endpointModel: String? = nil           // nil -> "" (no local-server model chosen yet)
        var endpointPort: Int? = nil               // nil -> OpenAIEndpointBrain.defaultPort
        var ornithVariant: String? = nil           // nil -> the size that fits this Mac's memory
        var wakeEnabled: Bool? = nil               // nil -> false (never listening without consent)
        var wakeTrained: Bool? = nil               // nil -> false (training is earned, not assumed)
        var wakePhrase: String? = nil              // nil -> "Sovereign"
        var semanticRAG = true                     // on-device embedding retrieval by default
        var researchMode: Bool? = nil              // nil -> false (normal chat; auto-escalate on miss)
        var guardrailPosture: GuardrailPosture = .confirmSideEffects   // safe default safety posture
        var weatherEnabled = true
        var googleClientID = ""
        // Fresh-profile appearance: calm + static + cheap (Founder 2026-07-08). Subtle intensity,
        // motion off, solid background (no animated aurora), low glow, no particles — a clean, fast
        // first impression that doesn't lag 16 GB machines. Every knob remains a live opt-in in the
        // Appearance Studio, and the full "Gold Vault"/"Aurora" looks are one tap away.
        var holoStored = HoloTheme.Stored(intensity: .subtle, motion: .off, particleDensity: 0.0,
                                          background: .solid, tiltEnabled: false, tiltStrength: 0.3,
                                          glowStrength: 0.35)
        var savedHoloPresets: [HoloPreset] = []

        /// SV-16 — the fresh-profile defaults for a white-label export. It seeds ONLY the four
        /// surfaces the client bought (name, tagline, accent, wake phrase) and leaves every other
        /// default exactly as Sovereign ships it: a re-brand is a re-brand, not a different product
        /// with quietly different safety and privacy defaults. In particular the guardrail posture
        /// stays `.confirmSideEffects` and the vault still starts empty — a client cannot be handed
        /// a build that is looser than the one Black Label sells.
        static func seeded(with brand: WhiteLabel.Brand) -> Stored {
            var s = Stored()
            s.assistantName = brand.assistantName
            s.tagline = brand.tagline
            s.accentPreset = .custom
            s.customAccentHex = brand.accentHex
            s.wakePhrase = brand.wakePhrase
            s.holoStored.accentHex = brand.accentHex
            return s
        }
    }

    private func persist() {
        guard !demoEphemeral else { return }
        var s = Stored(assistantName: assistantName, tagline: tagline, accentPreset: accentPreset,
                       customAccentHex: customAccentHex, motionEnabled: motionEnabled,
                       voiceEnabled: voiceEnabled, voiceIdentifier: voiceIdentifier,
                       systemPrompt: systemPrompt, memory: memory,
                       brainProvider: brainProvider, externalModel: externalModel, ollamaModel: ollamaModel,
                       semanticRAG: semanticRAG,
                       weatherEnabled: weatherEnabled, googleClientID: googleClientID)
        s.guardrailPosture = guardrailPosture
        s.endpointModel = endpointModel
        s.endpointPort = endpointPort
        s.ornithVariant = ornithVariant.rawValue
        s.wakeEnabled = wakeEnabled
        s.wakeTrained = wakeTrained
        s.wakePhrase = wakePhrase
        s.researchMode = researchMode
        s.holoStored = holoStored
        s.savedHoloPresets = savedHoloPresets
        if let data = try? JSONEncoder().encode(s) { d.set(data, forKey: key) }
    }

    /// Switch the recommended-brain size (35B ⇄ 9B). Guidance and the pull command follow the
    /// choice everywhere; and when the current Ollama selection is Ornith (any size) — or nothing
    /// yet — it is retargeted to the chosen size so Chat actually uses what the buyer picked.
    /// A non-Ornith model the buyer chose deliberately is never flipped.
    func selectOrnithVariant(_ v: OrnithRecommended.Variant) {
        ornithVariant = v
        if ollamaModel.isEmpty || OrnithRecommended.matches(ollamaModel) {
            ollamaModel = v.ollamaTag
        }
    }

    /// Effective system prompt the brain uses, with the buyer's chosen name folded in.
    var effectiveSystemPrompt: String {
        let name = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return base }
        return "Your name is \(name). \(base)"
    }

    func resetToDefaults() {
        let s = Stored()
        assistantName = s.assistantName; tagline = s.tagline
        accentPreset = s.accentPreset; customAccentHex = s.customAccentHex
        motionEnabled = s.motionEnabled; voiceEnabled = s.voiceEnabled; voiceIdentifier = s.voiceIdentifier
        systemPrompt = s.systemPrompt; memory = s.memory
        brainProvider = s.brainProvider; externalModel = s.externalModel; ollamaModel = s.ollamaModel; semanticRAG = s.semanticRAG
        researchMode = s.researchMode ?? false
        endpointModel = s.endpointModel ?? ""; endpointPort = OpenAIEndpointBrain.sanitizePort(s.endpointPort ?? OpenAIEndpointBrain.defaultPort)
        ornithVariant = OrnithRecommended.recommendedVariant(forRAMGB: OrnithRecommended.thisMacRAMGB)
        wakeEnabled = s.wakeEnabled ?? false; wakeTrained = s.wakeTrained ?? false; wakePhrase = s.wakePhrase ?? "Sovereign"
        guardrailPosture = s.guardrailPosture
        weatherEnabled = s.weatherEnabled; googleClientID = s.googleClientID
        holoStored = s.holoStored   // theme back to "Gold Vault" defaults (saved presets are kept)
    }

    // MARK: Demo Mode (ship-no-data): the demo may read settings but never write them to disk.
    func seedDemo() { demoEphemeral = true }
    /// Restore the buyer's persisted (pre-demo) settings, discarding any demo-session tweaks.
    /// Mirrors init's decode chain — including the fresh-profile white-label seed — so exiting the
    /// demo can never lose a brand seed or resurrect stale values. Assignments run while persistence
    /// is still suppressed (they re-state what disk already holds).
    func endDemo() {
        var s = Stored()
        if let data = d.data(forKey: key), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            s = decoded
        } else if let brand = WhiteLabel.installed {
            s = Stored.seeded(with: brand)
        }
        s.systemPrompt = DataHandlingCopy.migrateLegacySystemPrompt(s.systemPrompt)
        assistantName = s.assistantName; tagline = s.tagline
        accentPreset = s.accentPreset; customAccentHex = s.customAccentHex
        motionEnabled = s.motionEnabled; voiceEnabled = s.voiceEnabled; voiceIdentifier = s.voiceIdentifier
        systemPrompt = s.systemPrompt; memory = s.memory
        brainProvider = s.brainProvider; externalModel = s.externalModel; ollamaModel = s.ollamaModel
        ornithVariant = s.ornithVariant.flatMap { OrnithRecommended.Variant(rawValue: $0) }
            ?? OrnithRecommended.recommendedVariant(forRAMGB: OrnithRecommended.thisMacRAMGB)
        endpointModel = s.endpointModel ?? ""
        endpointPort = OpenAIEndpointBrain.sanitizePort(s.endpointPort ?? OpenAIEndpointBrain.defaultPort)
        wakeEnabled = s.wakeEnabled ?? false; wakeTrained = s.wakeTrained ?? false
        wakePhrase = (s.wakePhrase?.isEmpty == false) ? s.wakePhrase! : "Sovereign"
        semanticRAG = s.semanticRAG
        researchMode = s.researchMode ?? false
        guardrailPosture = s.guardrailPosture   // didSet re-mirrors GuardrailPolicy.current
        weatherEnabled = s.weatherEnabled; googleClientID = s.googleClientID
        holoStored = s.holoStored
        savedHoloPresets = s.savedHoloPresets
        demoEphemeral = false
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Saved profiles (named snapshots of the whole customization surface)
struct BrandProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var assistantName: String
    var tagline: String
    var accentPreset: AccentPreset
    var customAccentHex: String
    var systemPrompt: String
    var created = Date()
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [BrandProfile] = [] { didSet { persist() } }
    private let d = UserDefaults.standard
    private let key = "com.blacklabel.sovereign.profiles.v1"

    init() {
        if let data = d.data(forKey: key), let decoded = try? JSONDecoder().decode([BrandProfile].self, from: data) {
            profiles = decoded.map { profile in
                var migrated = profile
                migrated.systemPrompt = DataHandlingCopy.migrateLegacySystemPrompt(profile.systemPrompt)
                return migrated
            }
            if profiles != decoded { persist() }
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { d.set(data, forKey: key) }
    }
    func capture(named name: String, from s: AppSettings) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles.insert(BrandProfile(name: trimmed, assistantName: s.assistantName, tagline: s.tagline,
                                     accentPreset: s.accentPreset, customAccentHex: s.customAccentHex,
                                     systemPrompt: s.systemPrompt), at: 0)
    }
    func apply(_ p: BrandProfile, to s: AppSettings) {
        s.assistantName = p.assistantName; s.tagline = p.tagline
        s.accentPreset = p.accentPreset; s.customAccentHex = p.customAccentHex
        s.systemPrompt = p.systemPrompt
    }
    func delete(_ p: BrandProfile) { profiles.removeAll { $0.id == p.id } }

    /// Permanently erase ALL of the buyer's saved profiles — in memory and on disk
    /// (App Store Guideline 5.1.1(v)).
    func wipeAll() { profiles = [] }
}
#endif // circuit-convert
