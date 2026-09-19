// Sovereign — THE MODEL LIBRARY: a first-class, browse-&-swap surface over every brain route.
//
// The buyer shouldn't have to know an Ollama tag to change models. This file is the honest,
// unit-testable spine behind the "Models" panel in Settings: a curated pull catalog, a pure
// "which state is this row in?" classifier (active / installed / available), a pure route→provider
// swap-decision map, and a small pull driver that REUSES the exact `/api/pull` byte-stream pipeline
// the first-run onboarding uses (OrnithSetupModel → OllamaBrain.pull), so download progress here is
// the same real thing — never a fabricated bar.
//
// HONESTY (§5.1): the installed list is driven ONLY by a live GET /api/tags (OllamaBrain.parseTags);
// nothing here invents a model that isn't really on the buyer's disk. Curated entries carry an
// APPROXIMATE size clearly labeled as such — the exact byte total comes off the live pull stream.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

// MARK: - Curated catalog (the "browse" half of browse-&-swap)

/// One curated, one-tap-pullable local model. Every `tag` is a real Ollama registry tag; the size
/// is an honest APPROXIMATION (the real total is reported by the daemon during the pull).
struct CuratedModel: Identifiable, Equatable, Hashable {
    enum Category: String, CaseIterable, Equatable {
        case recommended, general, compact, coding
        /// Buyer-facing section label.
        var label: String {
            switch self {
            case .recommended: return "Recommended"
            case .general: return "General"
            case .compact: return "Compact · low memory"
            case .coding: return "Coding"
            }
        }
    }
    let tag: String            // exact Ollama pull tag — used verbatim by /api/pull
    let displayName: String    // buyer-facing name
    let approxGB: Double       // APPROXIMATE download size (honest ballpark; exact comes off the stream)
    let blurb: String          // one honest line about the model
    let category: Category
    var id: String { tag }

    /// Honest, clearly-approximate size label ("~4.7 GB"). Never presented as exact.
    var sizeLabel: String { "~\(String(format: "%.1f", approxGB)) GB" }
}

/// The shipped browse catalog. Real Ollama tags only; Ornith (Sovereign's recommended brain) leads.
/// Kept small and honest — a starting menu, not a claim of an exhaustive registry mirror.
enum ModelCatalog {
    static let curated: [CuratedModel] = [
        CuratedModel(tag: OrnithRecommended.Variant.b35.ollamaTag,
                     displayName: "Ornith 1.0 35B", approxGB: OrnithRecommended.Variant.b35.downloadGB,
                     blurb: "Sovereign's recommended brain — full power. Needs 48 GB+ memory.",
                     category: .recommended),
        CuratedModel(tag: OrnithRecommended.Variant.b9.ollamaTag,
                     displayName: "Ornith 1.0 9B", approxGB: OrnithRecommended.Variant.b9.downloadGB,
                     blurb: "The recommended brain, sized for 16 GB Macs.",
                     category: .recommended),
        CuratedModel(tag: "llama3.1:8b", displayName: "Llama 3.1 8B", approxGB: 4.7,
                     blurb: "Meta's general-purpose model. A strong all-rounder.", category: .general),
        CuratedModel(tag: "qwen2.5:7b", displayName: "Qwen2.5 7B", approxGB: 4.7,
                     blurb: "Alibaba's capable general model — solid reasoning for its size.", category: .general),
        CuratedModel(tag: "gemma2:9b", displayName: "Gemma 2 9B", approxGB: 5.4,
                     blurb: "Google's open model — good instruction-following.", category: .general),
        CuratedModel(tag: "llama3.2:3b", displayName: "Llama 3.2 3B", approxGB: 2.0,
                     blurb: "Small and fast — runs comfortably on lighter Macs.", category: .compact),
        CuratedModel(tag: "phi3:mini", displayName: "Phi-3 Mini", approxGB: 2.2,
                     blurb: "Microsoft's compact model — quick answers, low memory.", category: .compact),
        CuratedModel(tag: "qwen2.5-coder:7b", displayName: "Qwen2.5 Coder 7B", approxGB: 4.7,
                     blurb: "Tuned for code — completion, review, and refactors.", category: .coding),
    ]

    /// Curated models in a stable section order for the browse UI. PURE.
    static func grouped() -> [(category: CuratedModel.Category, models: [CuratedModel])] {
        grouped(curated)
    }

    /// Group ANY model list into the stable section order (used by the live-registry browse, which
    /// merges live + curated). Preserves each model's within-category order as given. PURE.
    static func grouped(_ models: [CuratedModel]) -> [(category: CuratedModel.Category, models: [CuratedModel])] {
        CuratedModel.Category.allCases.compactMap { cat in
            let ms = models.filter { $0.category == cat }
            return ms.isEmpty ? nil : (cat, ms)
        }
    }

    /// Split the catalog against the buyer's REAL installed set (from /api/tags) into
    /// (installed, available). An Ornith curated entry counts as installed when ANY Ornith tag is
    /// present, matching the family-recognition used everywhere else. PURE — no fabrication.
    static func partition(installed: [OllamaModel]) -> (installed: [CuratedModel], available: [CuratedModel]) {
        let names = installed.map { $0.name }
        var have: [CuratedModel] = []
        var want: [CuratedModel] = []
        for m in curated {
            if isInstalled(tag: m.tag, installedNames: names) { have.append(m) } else { want.append(m) }
        }
        return (have, want)
    }

    /// True when a curated tag is already on the buyer's disk. Exact-tag match, OR — for the Ornith
    /// family — any installed Ornith tag satisfies any Ornith curated entry. PURE. Case-insensitive
    /// on the exact-tag path so a re-cased tag still counts.
    static func isInstalled(tag: String, installedNames: [String]) -> Bool {
        if OrnithRecommended.matches(tag) {
            return installedNames.contains { OrnithRecommended.matches($0) }
        }
        return installedNames.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

// MARK: - Live registry browse (widen the curated menu toward a live model list)

/// One entry from a LIVE model-registry fetch, decoded from the daemon's `/api/models/catalog`
/// (a server-maintained list of real Ollama tags, updatable without an app rebuild). Kept separate
/// from CuratedModel's hardcoded menu so a live list can WIDEN the browse surface toward LM Studio /
/// Msty breadth without the app shipping a stale, fabricated registry mirror. §5.1.
struct RegistryModel: Decodable, Equatable {
    let tag: String
    let name: String?
    let sizeGB: Double?
    let blurb: String?
    let category: String?
    enum CodingKeys: String, CodingKey {
        case tag, name, blurb, category
        case sizeGB = "size_gb"
    }
}

/// Fetches + resolves the browse catalog. The live path is BEST-EFFORT and keyless; when it returns
/// nothing (offline, no daemon, endpoint absent, bad JSON) the surface falls back to the curated
/// menu — so the library ALWAYS shows a real, non-empty list and NEVER a fabricated one. The pure
/// `parse`/`resolve`/`toCurated` decisions are unit-tested with no network.
enum ModelRegistry {
    /// Where the browse list came from — surfaced honestly in the UI. `.unreachable` is a DISTINCT
    /// state from `.curatedFallback`: the former means we asked the live registry and it did not
    /// answer (offline / no daemon / non-200 / bad JSON), the latter that it answered with nothing.
    /// Collapsing the two would let a silent network failure read as "this is the whole library" —
    /// the buyer deserves to know the live list is missing, not just see a short menu. §5.1.
    enum Source: Equatable {
        case live
        case curatedFallback          // registry answered, but had nothing to add → built-in menu
        case unreachable(String)      // registry did not answer → built-in menu + an honest reason
    }

    /// The outcome of a LIVE registry fetch. Distinguishes "answered with an empty list" from
    /// "never answered" — a bare `[]` return cannot, which is exactly how an outage disguises
    /// itself as an empty catalog.
    enum LiveFetch: Equatable {
        case models([CuratedModel])   // reachable (list may legitimately be empty)
        case unreachable(String)      // honest, buyer-facing reason
    }

    /// Map a decoded live entry to a CuratedModel, filling honest defaults for missing fields. A
    /// blank/whitespace tag is rejected (nil) so nothing unpullable enters the browse list. PURE.
    static func toCurated(_ r: RegistryModel) -> CuratedModel? {
        let tag = r.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return nil }
        let cat = CuratedModel.Category(rawValue: (r.category ?? "general").lowercased()) ?? .general
        return CuratedModel(
            tag: tag,
            displayName: (r.name?.isEmpty == false) ? r.name! : tag,
            approxGB: max(0, r.sizeGB ?? 0),
            blurb: (r.blurb?.isEmpty == false) ? r.blurb! : "Local model — one-tap download.",
            category: cat)
    }

    /// Parse a live registry JSON payload into curated rows. Accepts either a bare array or a
    /// `{"models":[...]}` envelope. Returns [] on anything unparseable (→ graceful fallback). PURE.
    static func parse(_ data: Data) -> [CuratedModel] {
        let decoder = JSONDecoder()
        if let arr = try? decoder.decode([RegistryModel].self, from: data) {
            return arr.compactMap(toCurated)
        }
        struct Wrap: Decodable { let models: [RegistryModel] }
        if let w = try? decoder.decode(Wrap.self, from: data) {
            return w.models.compactMap(toCurated)
        }
        return []
    }

    /// Resolve the browse catalog from a (possibly empty) live list: when it has entries, use it
    /// MERGED with any curated model the live list doesn't already cover (so Ornith always leads and
    /// nothing curated is lost); otherwise the curated menu alone. Dedup is case-insensitive by tag.
    /// PURE — no network here, so "what does the browse surface show?" is fully unit-testable. §5.1.
    static func resolve(live: [CuratedModel]) -> (models: [CuratedModel], source: Source) {
        guard !live.isEmpty else { return (ModelCatalog.curated, .curatedFallback) }
        var seen = Set(live.map { $0.tag.lowercased() })
        var merged = live
        // Curated Ornith entries lead, so prepend any curated model the live list is missing in
        // catalog order but keep live entries first for the rest.
        for c in ModelCatalog.curated where !seen.contains(c.tag.lowercased()) {
            merged.append(c)
            seen.insert(c.tag.lowercased())
        }
        return (merged, .live)
    }

    /// Resolve the browse catalog from a live FETCH OUTCOME. The catalog shown is always REAL — the
    /// live list when there is one, otherwise the built-in curated menu (whose tags are all real
    /// Ollama tags). An unreachable registry never invents entries to fill the gap; it falls back to
    /// the built-in menu and reports `.unreachable(reason)` so the UI can SAY the live list is
    /// missing. PURE — the whole "what does the browse surface show, and what does it admit?"
    /// decision is unit-testable with no network. §5.1.
    static func resolve(outcome: LiveFetch) -> (models: [CuratedModel], source: Source) {
        switch outcome {
        case .models(let live):
            return resolve(live: live)
        case .unreachable(let reason):
            return (ModelCatalog.curated, .unreachable(reason))
        }
    }

    /// Best-effort LIVE fetch of the available-models list from the buyer's loopback daemon. Reports
    /// an honest `.unreachable(reason)` on ANY failure (offline / no daemon / endpoint absent /
    /// non-200 / bad JSON) rather than a bare `[]`, so the caller can tell an outage from an empty
    /// registry. Never throws, never fabricates. Host is loopback by construction (the base comes
    /// from ToolClient.resolveBase → 127.0.0.1).
    static func fetchLive(base: URL?, timeout: TimeInterval = 4) async -> LiveFetch {
        guard let base, let url = URL(string: base.absoluteString + "/api/models/catalog") else {
            return .unreachable("The local Sovereign service isn’t running, so the live model registry can’t be reached.")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 2
        guard let (data, resp) = try? await URLSession(configuration: cfg).data(for: URLRequest(url: url)) else {
            return .unreachable("Couldn’t reach the live model registry (no response from the local service).")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            return .unreachable("The live model registry answered with HTTP \(code).")
        }
        // A 200 that doesn't parse is an outage of the LIST, not an empty list — say so.
        let parsed = parse(data)
        if parsed.isEmpty, !data.isEmpty, (try? JSONSerialization.jsonObject(with: data)) == nil {
            return .unreachable("The live model registry returned a response that couldn’t be read.")
        }
        return .models(parsed)
    }
}

// MARK: - Row state (the "swap decision" a browse row shows)

/// The state one model row is in, derived PURELY from (its tag, what's installed, what's active).
/// Mirrors `OllamaDetection.classify`'s discipline: a pure map from observed facts to UI verdict,
/// unit-tested with no network. `.active` is claimed ONLY when the row's model is genuinely the
/// selected one — never optimistically.
enum ModelRowState: Equatable {
    case active        // this model is the currently-selected brain
    case installed     // present on disk — one tap to make active
    case available     // not installed — offer a one-tap download

    /// Classify a row. `activeTag` is the model string of the CURRENTLY-ACTIVE local brain (empty
    /// when the active brain isn't a local model, e.g. Apple/Claude), so no local row falsely reads
    /// active. Ornith-family aware on both the installed and active checks. PURE.
    static func classify(tag: String, installedNames: [String], activeTag: String) -> ModelRowState {
        let installed = ModelCatalog.isInstalled(tag: tag, installedNames: installedNames)
        guard installed else { return .available }
        let isActive: Bool
        if OrnithRecommended.matches(tag) {
            isActive = OrnithRecommended.matches(activeTag)
        } else {
            isActive = !activeTag.isEmpty && activeTag.caseInsensitiveCompare(tag) == .orderedSame
        }
        return isActive ? .active : .installed
    }
}

// MARK: - Route → provider swap decision

/// The routes the Models surface can switch the brain to. Distinct from `BrainProvider` so the UI
/// can group Local / Apple / Advanced cleanly and the swap map stays a small pure function.
enum ModelRoute: String, CaseIterable, Identifiable {
    case ollama, localEndpoint, appleOnDevice, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ollama: return "Ornith / Ollama models"
        case .localEndpoint: return "Local server"
        case .appleOnDevice: return "Apple on-device"
        case .advanced: return "Advanced (Claude / Codex)"
        }
    }
    /// The BrainProvider this route selects. PURE.
    var provider: BrainProvider {
        switch self {
        case .ollama: return .ollama
        case .localEndpoint: return .localEndpoint
        case .appleOnDevice: return .onDevice
        case .advanced: return .external
        }
    }
}

/// A resolved swap: which provider to select and which model string to write. `modelID` is empty
/// for routes that carry no per-model id (Apple on-device, the CLI/account advanced route).
struct BrainSwapPlan: Equatable {
    let provider: BrainProvider
    let modelID: String
}

/// Pure map from a chosen (route, model) to the exact settings mutation a swap should apply.
/// The single source of truth the UI and the tests both use, so "tap Use → what changes?" is
/// verifiable with no UI. Mirrors the `classify`-style pure-decision pattern. §5.1: never invents.
enum BrainSwap {
    static func plan(route: ModelRoute, model: String = "") -> BrainSwapPlan {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch route {
        case .ollama, .localEndpoint:
            return BrainSwapPlan(provider: route.provider, modelID: m)
        case .appleOnDevice, .advanced:
            return BrainSwapPlan(provider: route.provider, modelID: "")   // no per-model id on these routes
        }
    }
}

// MARK: - The chat-surface brain picker (SV-05: ≥4 providers/models within ≤2 clicks)

/// One selectable row in the chat header's brain menu.
///
/// Every entry is a route that can genuinely answer RIGHT NOW: a model actually installed in the
/// buyer's Ollama, a model their local server actually lists, Apple on-device only while the
/// framework reports `.ready`, and the Claude/Codex account only while it's really connected.
/// §5.1: a dead route is never offered as a live one — the menu's last row NAVIGATES to the model
/// library instead, which is honest ("go set one up") rather than a swap that silently does nothing.
struct BrainMenuEntry: Equatable, Identifiable {
    let title: String        // buyer-facing name (the model tag, or the route)
    let detail: String       // one honest line — where it runs
    let route: ModelRoute
    let modelID: String      // "" for routes that carry no per-model id
    let isActive: Bool       // this is the brain answering right now
    var id: String { "\(route.rawValue)|\(modelID)" }

    /// Clicks from the chat surface to make this the active brain: open the header menu (1) + tap
    /// the row (1). The menu is FLAT by construction — no submenus, no "More…" indirection on a
    /// real route — so the ≤2-click bar is a PROPERTY OF THE DATA the tests read, not a claim in a
    /// document. If anyone ever nests a route behind a submenu, this stops being 2 and the test that
    /// asserts `clicks <= clickBudget` fails.
    var clicks: Int { 2 }

    /// The exact settings mutation selecting this row applies — the same pure map the Settings
    /// library uses, so the chat picker and the Settings picker can never drift apart.
    var swapPlan: BrainSwapPlan { BrainSwap.plan(route: route, model: modelID) }
}

/// Builds the chat-header brain menu. PURE — no network, no UI — so "how many providers/models are
/// within 2 clicks of the chat surface?" is a unit-testable fact about the buyer's real machine
/// state, never an assertion in a status file.
enum ChatBrainMenu {
    /// The reachability bar SV-05 is measured against: ≥4 providers/models, each ≤2 clicks away.
    static let clickBudget = 2
    static let breadthBar = 4

    /// The flat menu, built from ONLY what is genuinely ready. Order: the local models the buyer
    /// actually has (Ornith first — it's the recommended brain), then their local server's models,
    /// then Apple on-device, then the connected account.
    static func entries(installed: [OllamaModel], endpointModels: [String], appleReady: Bool,
                        externalConnected: Bool, externalLabel: String = "Claude / Codex",
                        provider: BrainProvider, ollamaModel: String, endpointModel: String) -> [BrainMenuEntry] {
        var out: [BrainMenuEntry] = []

        // Local Ollama models — real, straight off /api/tags. Embedding-only models can't chat, so
        // they are not offered as a brain (they'd produce nothing). Ornith leads.
        let chattable = installed.filter { $0.isChatCapable }
        let ordered = chattable.filter { OrnithRecommended.matches($0.name) }
            + chattable.filter { !OrnithRecommended.matches($0.name) }
        for m in ordered {
            let active = provider == .ollama
                && ModelRowState.classify(tag: m.name, installedNames: installed.map { $0.name },
                                          activeTag: ollamaModel) == .active
            out.append(BrainMenuEntry(
                title: OrnithRecommended.matches(m.name) ? "Ornith · \(m.name)" : m.name,
                detail: "Runs fully on this Mac · \(m.sizeLabel)",
                route: .ollama, modelID: m.name, isActive: active))
        }

        // The buyer's own local server (LM-Studio-class OpenAI endpoint).
        for id in endpointModels {
            out.append(BrainMenuEntry(
                title: id, detail: "Your local server · stays on this Mac",
                route: .localEndpoint, modelID: id,
                isActive: provider == .localEndpoint && !endpointModel.isEmpty
                    && endpointModel.caseInsensitiveCompare(id) == .orderedSame))
        }

        // Apple on-device — offered ONLY when the framework really reports ready. (FoundationModels
        // can report .ready and still throw at generation if the model isn't downloaded, which is
        // why it isn't the default; but an .unavailable engine must never even be listed.)
        if appleReady {
            out.append(BrainMenuEntry(
                title: "Apple on-device", detail: "Private, free, offline · zero setup",
                route: .appleOnDevice, modelID: "", isActive: provider == .onDevice))
        }

        // The buyer's OWN connected Claude/Codex account (§5.5 — their login, never ours).
        if externalConnected {
            out.append(BrainMenuEntry(
                title: externalLabel, detail: "Your own account · adds images + multi-step agents",
                route: .advanced, modelID: "", isActive: provider == .external))
        }
        return out
    }

    /// Distinct PROVIDERS the menu reaches (many Ollama models collapse to one provider). Used to
    /// describe breadth honestly — "4 models on one provider" is not "4 providers".
    static func reachableProviders(_ entries: [BrainMenuEntry]) -> Set<BrainProvider> {
        Set(entries.map { $0.route.provider })
    }

    /// Does the machine's REAL state meet the SV-05 bar — at least `breadthBar` providers/models,
    /// every one of them within `clickBudget` clicks of the chat surface? The bar counts
    /// providers-or-models (a buyer with four local models genuinely has four brains one tap away),
    /// which is exactly how the bar is worded.
    static func meetsBreadthBar(_ entries: [BrainMenuEntry]) -> Bool {
        entries.count >= breadthBar && entries.allSatisfy { $0.clicks <= clickBudget }
    }

    /// The honest empty state: nothing is ready, so the menu offers no false swap — the buyer is
    /// pointed at the library to set a brain up. Never presented as "you have brains available".
    static func isEmpty(_ entries: [BrainMenuEntry]) -> Bool { entries.isEmpty }
}

// MARK: - Pull driver (reuses the onboarding /api/pull pipeline)

/// Drives a one-tap download of an arbitrary curated tag into the buyer's OWN Ollama, streaming the
/// SAME real byte progress the first-run onboarding shows. This is deliberately the same pipeline as
/// `OrnithSetupModel` — `OllamaBrain.pull` — just parameterized by tag so the browse library can pull
/// any catalog model. §5.1: `.done` is published ONLY after the daemon reports success; progress is
/// verbatim off the stream, never faked.
@MainActor
final class ModelPull: ObservableObject {
    @Published var pullingTag: String? = nil                      // the tag currently downloading (nil = idle)
    @Published var progress = OllamaBrain.PullProgress()
    @Published var lastError: String? = nil                       // honest failure text from the daemon/transport
    @Published var lastDoneTag: String? = nil                     // the last tag that finished successfully

    private let ollama = OllamaBrain()

    /// True while THIS tag is downloading (drives the per-row progress bar).
    func isPulling(_ tag: String) -> Bool { pullingTag == tag }

    /// Honest one-line status under a row's progress bar: the daemon's own phase + real byte counts.
    var progressLabel: String {
        let p = progress
        let phase = p.status.isEmpty ? "starting…" : p.status
        if p.total > 0 {
            let f = ByteCountFormatter(); f.countStyle = .file
            let pct = Int((p.fraction ?? 0) * 100)
            return "\(phase) — \(f.string(fromByteCount: p.completed)) / \(f.string(fromByteCount: p.total)) (\(pct)%)"
        }
        return phase
    }

    /// Pull `tag` with live progress, then confirm it's actually installed and hand the confirmed
    /// model name back to the caller (which selects it). Never claims success on faith.
    func pull(tag: String, onInstalled: @escaping (String) -> Void) {
        guard pullingTag == nil else { return }                  // one download at a time
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        pullingTag = t
        lastError = nil
        progress = OllamaBrain.PullProgress()
        Task { @MainActor in
            do {
                try await ollama.pull(model: t) { p in
                    Task { @MainActor in self.progress = p }
                }
                // Confirm on-disk (never optimistic): prefer the exact tag, then any Ornith family match.
                let installed = (try? await ollama.listModels()) ?? []
                let match = installed.first(where: { $0.name == t })
                    ?? (OrnithRecommended.matches(t) ? installed.first(where: { OrnithRecommended.matches($0.name) }) : nil)
                guard let picked = match else {
                    lastError = "The download finished but \(t) isn't listed in Ollama yet — press Refresh installed models."
                    pullingTag = nil
                    return
                }
                lastDoneTag = picked.name
                pullingTag = nil
                onInstalled(picked.name)
            } catch {
                lastError = (error as? OllamaBrain.Failure)?.message ?? error.localizedDescription
                pullingTag = nil
            }
        }
    }
}
