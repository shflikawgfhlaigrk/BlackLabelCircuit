// Sovereign — THE BRAIN PROVIDER ABSTRACTION.
//
// This is the architectural spine of the product. The shipped brain route is on-device, and the
// buyer chooses which to use:
//
//   1. On-device (Apple FoundationModels) — THE SHIPPED DEFAULT (Founder 2026-07-03): private,
//      free, offline, no account, answers with zero setup. Implemented in AI.swift (AIEngine).
//      Requires macOS 26 + Apple Intelligence.
//
//   2. Ornith 1.0 through the buyer's own local Ollama daemon or a loopback OpenAI-compatible
//      server — the buyer's deliberate opt-in. No account, no key, no hosted routing. Text only.
//
// `BrainRouter` picks the active provider from settings + what's actually available, and never
// fabricates: if neither brain is usable, callers get an honest error, never invented text.
//
// MODEL: Ornith 1.0 35B Q5_K_M by default for local Ollama (9B selectable for 16 GB Macs).
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

// MARK: - Provider selection

/// Which brain the buyer wants to use. `.auto` is retained for legacy settings, but the shipped
/// Settings surface offers the two local Ornith routes (Ollama / local server) and on-device.
enum BrainProvider: String, Codable, CaseIterable, Identifiable {
    case auto, onDevice, external, ollama, localEndpoint
    static var allCases: [BrainProvider] { [.ollama, .localEndpoint, .onDevice] }
    /// Keep the configured buyer-owned provider reachable after connection without advertising an
    /// unconfigured cloud route as ready. Local/on-device choices remain first.
    static func visibleCases(externalConnected: Bool) -> [BrainProvider] {
        externalConnected ? allCases + [.external] : allCases
    }
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .onDevice: return "On-device (private)"
        case .external: return "Connected provider"
        case .ollama: return "Ornith 1.0 (Ollama)"
        case .localEndpoint: return "Local server"
        }
    }
    var blurb: String {
        switch self {
        case .auto: return "Use Apple's on-device model when available, otherwise the local Ornith/Ollama brain."
        case .onDevice: return "Apple on-device model. Private, free, offline. Text only."
        case .external: return "Use the provider account you connected. The credential is stored in Keychain and sent only as authentication. The provider processes prompts, recent history, attachments, and enabled document or memory context included in a request."
        case .ollama: return "Run Ornith 1.0 fully locally through your own Ollama daemon. No account, no key, no cloud."
        case .localEndpoint: return "Any OpenAI-compatible server on this Mac — llama.cpp or LM Studio at 127.0.0.1. Serve Ornith 1.0 there and Sovereign runs it fully locally. No account, no key, no cloud."
        }
    }
    /// The buyer-facing group this provider belongs to in the multi-provider Models surface, so the
    /// picker presents Local / Apple / Advanced routes clearly instead of one flat list. PURE.
    var modelGroup: String {
        switch self {
        case .ollama, .localEndpoint: return "Local models"
        case .onDevice: return "Apple on-device"
        case .auto, .external: return "Advanced (Claude / Codex)"
        }
    }
}

// MARK: - SV-21 first-run brain default (pure, testable)

/// The zero-setup first-run brain default. On Apple silicon with Apple Intelligence enabled,
/// Apple's FoundationModels on-device brain is the default — it answers with NO download and NO
/// account. When it isn't available, we fall back to the bundled local Ornith brain (set up
/// inline via `OrnithSetupModel`) and state the gate honestly in-UI. This single decision is read
/// by both onboarding (Shell.swift) and the model library — PURE, so it's exhaustively unit-tested.
struct FirstRunBrainPlan: Equatable {
    /// The provider to select as the first-run default.
    let provider: BrainProvider
    /// True only when we must run the inline Ornith download/setup (no zero-setup Apple model here).
    let runsOrnithSetup: Bool
    /// The honest gate line to show when Apple's model couldn't be the default; nil when it could.
    /// It names the real Apple-Intelligence requirement — never implies universal offline AI.
    let gateNote: String?

    /// True when Apple's on-device model IS the default and nothing needs downloading first.
    var usesAppleZeroSetup: Bool { provider == .onDevice && !runsOrnithSetup }
}

/// SV-21 — the PURE, testable gate that decides whether Apple's bundled FoundationModels brain is the
/// ZERO-SETUP first-run default, mirroring `DictationPolicy`'s shape (a named enum of static, pure
/// decisions the source-scan test can pin). Availability is an INPUT — the one honest probe
/// `AIEngine.foundationModelsAvailable` (Apple silicon + Apple Intelligence enabled + model ready). This
/// policy ROUTES on availability; it never synthesizes it, so a build can't fabricate offline Apple AI on
/// unsupported hardware (§5.1). Both onboarding (Shell) and the model library read this one decision.
enum FoundationBrainPolicy {
    /// The first-run route chosen from real availability.
    enum Route: Equatable {
        case appleZeroSetup        // Apple's on-device brain answers immediately — no download, no account
        case bundledLocalFallback  // Apple unavailable → today's inline Ornith setup, byte-unchanged
    }

    /// The route for the given availability. PURE. Available → Apple zero-setup; unavailable → the
    /// bundled-local Ornith fallback. The availability bool is passed in, never invented here.
    static func route(foundationModelsAvailable: Bool) -> Route {
        foundationModelsAvailable ? .appleZeroSetup : .bundledLocalFallback
    }

    /// The honest gate line shown when Apple's model can't be the default — it names the REAL
    /// requirement (Apple Intelligence on Apple silicon) and the bundled-local fallback; nil when Apple
    /// IS the default. NEVER implies universal offline Apple AI on unsupported hardware (§5.1).
    static func gateNote(foundationModelsAvailable: Bool) -> String? {
        foundationModelsAvailable ? nil : AIEngine.appleUnavailableFallbackNote
    }

    /// The full first-run plan (provider + whether the inline Ornith setup runs + the gate note),
    /// assembled from the route. PURE → exhaustively unit-tested. `BrainProvider.firstRunPlan`
    /// delegates here so there is ONE decision, not two.
    static func firstRunPlan(foundationModelsAvailable: Bool) -> FirstRunBrainPlan {
        switch route(foundationModelsAvailable: foundationModelsAvailable) {
        case .appleZeroSetup:
            return FirstRunBrainPlan(provider: .onDevice, runsOrnithSetup: false, gateNote: nil)
        case .bundledLocalFallback:
            return FirstRunBrainPlan(provider: .ollama, runsOrnithSetup: true,
                                     gateNote: AIEngine.appleUnavailableFallbackNote)
        }
    }
}

extension BrainProvider {
    /// Decide the first-run default from whether Apple's on-device model is available. PURE.
    /// Available → Apple on-device (zero setup, no gate note). Unavailable → bundled local Ornith
    /// with the honest gate copy — never claiming offline Apple AI on unsupported hardware. Delegates
    /// to `FoundationBrainPolicy` (the single canonical gate) so the two never drift.
    static func firstRunPlan(foundationModelsAvailable: Bool) -> FirstRunBrainPlan {
        FoundationBrainPolicy.firstRunPlan(foundationModelsAvailable: foundationModelsAvailable)
    }
}

/// What the buyer's LOCAL model setup actually is right now. "Configured but unreachable" is a
/// real, recoverable state and is NOT the same fact as "nothing is set up" (M2, 2026-08-02): a
/// daemon that isn't answering must never be reported as if the buyer never installed anything,
/// and must never be the reason a buyer cannot use the app.
enum LocalBrainState: Equatable, Sendable {
    case notConfigured      // no model tag chosen
    case probing            // a tag is configured; the liveness probe hasn't answered yet
    case unreachable        // a tag is configured; the daemon answered "not running" (or timed out)
    case live               // a tag is configured and the daemon is CONFIRMED reachable
    /// The buyer's setup survives in these states — only the daemon is missing.
    var isConfigured: Bool { self != .notConfigured }
}

/// Pure local-brain policy: state from (model tag, probe answer), and the honest sentence for each
/// state. No network, no actor, no UI — so the distinction is testable and cannot drift.
enum LocalBrainPolicy {
    static func state(modelTag: String, reachable: Bool?) -> LocalBrainState {
        guard !modelTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notConfigured }
        switch reachable {
        case .some(true): return .live
        case .some(false): return .unreachable
        case .none: return .probing
        }
    }
    /// Honest copy per state. `.unreachable` states the setup is KEPT and names the real remedy;
    /// it never claims the model is answering, and never implies the buyer must start over.
    /// iOS cannot run the Ollama daemon at all, so its lines route to what works there instead of
    /// naming Mac apps and shell commands the device cannot execute.
    static func reason(for state: LocalBrainState) -> String {
        switch state {
        #if os(iOS)
        case .notConfigured:
            return "The Ollama route runs on a Mac. On this device, pick Apple on-device or connect your own provider account in Settings."
        case .probing:
            return "Checking for a local brain…"
        case .unreachable:
            return "The Ollama route isn't reachable from this device. Pick Apple on-device or connect your own provider account in Settings — your saved model choice is kept."
        #else
        case .notConfigured:
            return "Pick an installed Ollama model in Settings (or run `ollama pull llama3.2`). Ollama runs fully locally on this Mac."
        case .probing:
            return "Checking for the local Ollama brain on this Mac…"
        case .unreachable:
            return "Your local brain is set up but Ollama isn't answering on this Mac right now — open the Ollama app and Sovereign reconnects by itself. Your model choice is kept; nothing needs to be set up again."
        #endif
        case .live:
            return ""
        }
    }
}

/// The brain that's actually answering right now (resolved from provider + availability).
enum ActiveBrain: Equatable {
    case onDevice
    case external(model: String)
    case ollama(model: String)         // fully-local inference via the buyer's own Ollama daemon. Text only.
    case localEndpoint(model: String)  // fully-local inference via a loopback OpenAI-compatible server. Text only.
    case none(reason: String)          // honest: nothing usable; UI shows this, never fakes a reply

    var isUsable: Bool { if case .none = self { return false } else { return true } }
    var supportsImages: Bool { if case .external = self { return true } else { return false } }
    var supportsTools: Bool { if case .external = self { return true } else { return false } }
    var label: String {
        switch self {
        case .onDevice: return "On-device"
        case .external(let m):
            if m == "Secondary CLI" { return "External CLI" }
            if m == "Custom CLI" { return "Custom CLI" }
            return "External account · \(m)"
        case .ollama(let m): return "Ornith/Ollama · \(m)"
        case .localEndpoint(let m):
            return OrnithRecommended.matches(m) ? "Ornith · local server · \(m)" : "Local server · \(m)"
        case .none: return "Not connected"
        }
    }
}

// MARK: - A user-attached image, carried into a vision-capable brain call.
struct BrainImage: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let mediaType: String   // "image/png" | "image/jpeg" | "image/webp" | "image/gif"
    let base64: String      // raw base64, no data: prefix
    var approxKB: Int { (base64.count * 3 / 4) / 1024 }
}

// MARK: - Agent brain seam.

/// One TURN of a tool-use loop. Returned by any brain the AgentEngine can drive. Defined at
/// top level (not nested) so a test double can construct it without a network call.
struct AgentToolTurn {
    let text: String
    let toolCalls: [(id: String, name: String, input: [String: Any])]
    let assistantContent: [[String: Any]]   // echo verbatim on the next request
    let stopReason: String
}

// MARK: - Shared task-level model routing

/// The kind of model work being requested. The heavy lane is intentionally explicit: normal chat,
/// skills, automations, and ordinary agent iterations can never drift into the most expensive model.
enum ModelWorkload: Equatable {
    case routine
    case rootPlanning
    case hardestChild
    case verification
}

/// Stable execution lanes shared by every external-model caller.
enum ModelLane: String, CaseIterable, Equatable {
    case fast
    case root
    case heavy
}

/// One bounded model-call plan. Candidate order is also the fallback order; duplicates and empty
/// model ids are removed before the plan leaves ModelRoutingPolicy.
struct ModelRoutePlan: Equatable {
    let lane: ModelLane
    let candidateModels: [String]
    let maxOutputTokens: Int
    let timeoutSeconds: TimeInterval
    let maxConcurrent: Int
}

/// Shared, deterministic policy for paid external inference.
///
/// Current identifiers were checked against Anthropic's official model list on 2026-07-16:
/// Haiku 4.5 is the cheap/fast lane and Fable 5 is the highest-capability generally available lane.
/// The buyer's selected model remains the root planner. If a lane model is unavailable to that
/// buyer, the ordered candidates fall back without inventing a successful call.
enum ModelRoutingPolicy {
    static let fastModel = "claude-haiku-4-5"
    static let heavyModel = "claude-fable-5"
    static let maxAgentOutputBudget = 32_000

    static func plan(for workload: ModelWorkload, selectedModel: String) -> ModelRoutePlan {
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        switch workload {
        case .routine:
            return ModelRoutePlan(lane: .fast,
                                  candidateModels: candidates([fastModel, selected]),
                                  maxOutputTokens: 4_096, timeoutSeconds: 45, maxConcurrent: 4)
        case .rootPlanning:
            return ModelRoutePlan(lane: .root,
                                  candidateModels: candidates([selected, fastModel]),
                                  maxOutputTokens: 8_000, timeoutSeconds: 90, maxConcurrent: 2)
        case .hardestChild:
            return ModelRoutePlan(lane: .heavy,
                                  candidateModels: candidates([heavyModel, selected, fastModel]),
                                  maxOutputTokens: 16_000, timeoutSeconds: 180, maxConcurrent: 1)
        case .verification:
            return ModelRoutePlan(lane: .fast,
                                  candidateModels: candidates([fastModel, selected]),
                                  maxOutputTokens: 4_096, timeoutSeconds: 45, maxConcurrent: 4)
        }
    }

    /// First agent turn is root planning. Every ordinary follow-up is the fast lane; a future child
    /// harness must ask for `.hardestChild` explicitly before Fable can ever be selected.
    static func agentWorkload(iteration: Int) -> ModelWorkload {
        iteration == 0 ? .rootPlanning : .routine
    }

    private static func candidates(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        return raw.compactMap {
            let model = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { return nil }
            return model
        }
    }
}

/// Process-wide lane limiter. Agent engines live on MainActor, so this provides one shared,
/// deterministic concurrency boundary without a second daemon or network broker.
@MainActor
final class ModelLaneGate {
    static let shared = ModelLaneGate()
    private var active: [ModelLane: Int] = [:]
    private var waiters: [ModelLane: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ lane: ModelLane, limit: Int) async {
        let cap = max(1, limit)
        if active[lane, default: 0] < cap {
            active[lane, default: 0] += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters[lane, default: []].append(continuation)
        }
    }

    func release(_ lane: ModelLane) {
        if var queue = waiters[lane], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[lane] = queue
            next.resume()
            return
        }
        active[lane] = max(0, active[lane, default: 0] - 1)
    }
}

struct ModelRoutingFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The seam the multi-step AgentEngine drives. `ExternalBrain` is the real implementation; tests
/// inject a deterministic fake so the agent's per-step receipt recording can be proven WITHOUT
/// any network call. This is what closes the "behavioral test" gap — the engine no longer depends
/// on the concrete network client.
protocol AgentBrain: Sendable {
    func toolTurn(model: String, system: String, messages: [[String: Any]],
                  tools: [[String: Any]], maxTokens: Int,
                  timeoutSeconds: TimeInterval,
                  credential: ExternalCredential) async throws -> AgentToolTurn
}

// MARK: - External brain — streams from /v1/messages on the BUYER's own credential.

/// Honest, dependency-free Anthropic Messages client. No SDK (Swift has none); raw HTTPS + SSE.
/// Uses the buyer's Keychain credential. Never carries a bundled secret.
actor ExternalBrain: AgentBrain {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    private let session: URLSession
    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        session = URLSession(configuration: cfg)
    }

    /// Build the authenticated request for the buyer's credential kind.
    private func makeRequest(credential: ExternalCredential, body: Data,
                             timeoutSeconds: TimeInterval? = nil) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw Failure(message: "Invalid endpoint.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        switch credential.kind {
        case .apiKey:
            req.setValue(credential.secret, forHTTPHeaderField: "x-api-key")
        case .oauth:
            req.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        case .cli, .secondaryCLI, .customCLI:
            // The CLI brains never authenticate over HTTP — they run through their CLIBrain actors.
            // If a CLI credential reaches this client, that's a routing bug; fail honestly, never silently.
            throw Failure(message: "The CLI brain doesn't use HTTP. Re-connect in Settings.")
        }
        req.httpBody = body
        if let timeoutSeconds, timeoutSeconds > 0 { req.timeoutInterval = timeoutSeconds }
        return req
    }

    /// Compose the request JSON. Adaptive thinking + streaming. System prompt + grounding folded in.
    private func buildBody(model: String, system: String, messages: [[String: Any]],
                           maxTokens: Int, tools: [[String: Any]]?, stream: Bool) -> Data {
        var dict: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": messages,
            "stream": stream
        ]
        if !system.isEmpty { dict["system"] = system }
        if let tools = tools, !tools.isEmpty { dict["tools"] = tools }
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    /// Map a transport / HTTP error to an honest, human message (never a fake reply).
    private func describe(status: Int, body: String) -> String {
        switch status {
        case 401: return "Your external account credential was rejected (401)."
        case 403: return "Your external account doesn't have access to this model (403)."
        case 404: return "That model wasn't found (404). Pick another in Settings."
        case 429: return "External account rate limit reached (429). Wait a moment and try again."
        case 500...599: return "External account server error (\(status)). Try again shortly."
        default:
            // Surface the API's own error text when present — it's the buyer's account, their info.
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                return "External account error (\(status)): \(msg)"
            }
            return "External account request failed (\(status))."
        }
    }

    /// STREAMING chat. Emits cumulative text via `onToken`; resolves with the final text.
    /// Throws Failure on any non-success (caller shows the honest message).
    func stream(model: String, system: String, userText: String, images: [BrainImage],
                history: [(role: String, text: String)], maxTokens: Int,
                credential: ExternalCredential,
                onToken: @escaping (String) -> Void) async throws -> String {
        var messages: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }
        // Final user turn: text + any images (vision).
        var content: [[String: Any]] = []
        for img in images {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": img.mediaType, "data": img.base64]
            ])
        }
        content.append(["type": "text", "text": userText])
        messages.append(["role": "user", "content": content])

        let body = buildBody(model: model, system: system, messages: messages,
                             maxTokens: maxTokens, tools: nil, stream: true)
        let req = try makeRequest(credential: credential, body: body)

        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // Drain the body for the error message.
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw Failure(message: describe(status: http.statusCode, body: raw))
        }

        var full = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let evt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let type = evt["type"] as? String
            if type == "content_block_delta",
               let delta = evt["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                full += text
                onToken(full)
            } else if type == "error",
                      let err = evt["error"] as? [String: Any],
                      let msg = err["message"] as? String {
                throw Failure(message: "External account error: \(msg)")
            }
        }
        return full
    }

    /// NON-streaming single-shot (used by Skills/Automations and the agent's verify step).
    func complete(model: String, system: String, userText: String, maxTokens: Int,
                  timeoutSeconds: TimeInterval? = nil,
                  credential: ExternalCredential) async throws -> String {
        let messages: [[String: Any]] = [["role": "user", "content": userText]]
        let body = buildBody(model: model, system: system, messages: messages,
                             maxTokens: maxTokens, tools: nil, stream: false)
        let req = try makeRequest(credential: credential, body: body, timeoutSeconds: timeoutSeconds)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure(message: describe(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw Failure(message: "External account returned an unexpected response.")
        }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        return text
    }

    /// One TURN of a tool-use loop. Returns the assistant's text + any tool calls it requested
    /// + the raw assistant content blocks (to echo back on the next turn). Used by AgentEngine
    /// through the `AgentBrain` seam.
    func toolTurn(model: String, system: String, messages: [[String: Any]],
                  tools: [[String: Any]], maxTokens: Int,
                  timeoutSeconds: TimeInterval,
                  credential: ExternalCredential) async throws -> AgentToolTurn {
        let body = buildBody(model: model, system: system, messages: messages,
                             maxTokens: maxTokens, tools: tools, stream: false)
        let req = try makeRequest(credential: credential, body: body, timeoutSeconds: timeoutSeconds)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure(message: describe(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw Failure(message: "External account returned an unexpected response.")
        }
        let stop = obj["stop_reason"] as? String ?? "end_turn"
        var text = ""
        var calls: [(id: String, name: String, input: [String: Any])] = []
        for block in content {
            switch block["type"] as? String {
            case "text": text += (block["text"] as? String ?? "")
            case "tool_use":
                if let id = block["id"] as? String, let name = block["name"] as? String {
                    calls.append((id: id, name: name, input: block["input"] as? [String: Any] ?? [:]))
                }
            default: break
            }
        }
        return AgentToolTurn(text: text, toolCalls: calls, assistantContent: content, stopReason: stop)
    }
}

// MARK: - BrainRouter — the single entry point the UI talks to.

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Resolves the active brain from the buyer's chosen provider + what's actually available,
/// and dispatches streaming / single-shot calls to it. Pure honesty: when nothing is usable,
/// it reports an honest reason and never invents output.
@MainActor
final class BrainRouter: ObservableObject {
    @Published var active: ActiveBrain = .none(reason: "Checking brains…")
    @Published var thinking = false
    @Published var lastError: String?
    /// The model's LIVE reasoning stream (thinking models — Ornith). Cumulative, cleared at each
    /// stream start; the chat UI shows its tail so the reasoning phase never reads as a hang.
    /// This is the model's own output, never invented text.
    @Published var liveReasoning: String = ""
    /// True when the ACTIVE local Ollama model reports native tool-calling (probed via /api/show,
    /// cached per model tag). Gates the real agent loop on the local brain — §5.1: set only from a
    /// real probe result, never assumed.
    @Published var localToolCapable = false
    /// True when the ACTIVE local OpenAI-compatible endpoint model reports native function-calling.
    /// Cached per endpoint model and selected port. Gates the local-endpoint tool loop with
    /// a real probe, never a guess.
    @Published var localEndpointToolCapable = false
    private var toolCapabilityProbedModel: String?
    private var endpointToolCapabilityProbedModel: String?

    /// Liveness of the buyer's local Ollama daemon (nil = not yet probed). Resolve treats only a
    /// CONFIRMED-reachable daemon as a usable brain — a pre-filled model tag alone must never light
    /// the "ready" state on a Mac where Ollama was never installed (§5.1: no fabricated presence).
    private var ollamaReachable: Bool?
    private var ollamaProbeInFlight = false

    /// The buyer's LOCAL model setup as a state, not a boolean. Published so the UI can say
    /// "configured but unreachable" (recoverable, setup kept) instead of collapsing it into
    /// "no brain" — the copy that made an offline buyer think they had to start over (M2).
    @Published private(set) var localBrain: LocalBrainState = .notConfigured

    private weak var ai: AIEngine?
    private weak var settings: AppSettings?
    /// Demo Mode: when active, brain calls return a clearly-labeled SAMPLE reply instead of
    /// reaching any real account/model (no AI login exists in demo). Set in RootView.onAppear.
    weak var demo: DemoMode?
    private let auth = ExternalAuth.shared
    private let external = ExternalBrain()
    private let cli = CLIBrain()        // the buyer's External SUBSCRIPTION via the `external` CLI (macOS)
    private let secondaryCLI = SecondaryCLIBrain() // the buyer's installed Secondary CLI session (macOS)
    private let customCLI = CustomCLIBrain() // any prompt-capable CLI on PATH (macOS)
    private let ollama = OllamaBrain()  // fully-local inference via the buyer's own Ollama daemon
    private let ollamaAgent = OllamaAgentBrain()  // native tool-calling agent loop on that same daemon
    private let endpoint = OpenAIEndpointBrain()  // fully-local inference via a loopback OpenAI-compatible server
    private var streamTask: Task<Void, Never>?

    /// The buyer's configured local-server port (Settings), sanitized. Loopback host is fixed.
    private var endpointPort: Int { OpenAIEndpointBrain.sanitizePort(settings?.endpointPort ?? OpenAIEndpointBrain.defaultPort) }

    func attach(ai: AIEngine, settings: AppSettings) {
        self.ai = ai
        self.settings = settings
        resolve()
    }

    /// True while the reviewer/sample experience is active — the router then simulates replies.
    var isDemo: Bool { demo?.active ?? false }

    /// Recompute which brain is active. Call after auth changes, settings changes, or availability refresh.
    func resolve() {
        // Demo Mode: present a usable "Demo brain" so every chat surface is exercisable without
        // any account. Replies are simulated + labeled (never a real model call).
        if isDemo { active = .external(model: "Demo (sample replies)"); return }
        guard let settings = settings else { active = .none(reason: "Not configured"); return }
        let provider = settings.brainProvider
        let model = settings.externalModel.isEmpty ? ExternalAuth.defaultModel : settings.externalModel
        let activeModel: String
        switch auth.connectedKind {
        case .secondaryCLI: activeModel = "Secondary CLI"
        case .customCLI: activeModel = "Custom CLI"
        default: activeModel = model
        }
        let externalReady = auth.isConnected
        let deviceReady = ai?.isReady ?? false

        switch provider {
        case .external:
            active = externalReady ? .external(model: activeModel)
                : .none(reason: "External account mode is not configured. Use the local Ornith/Ollama brain in Settings.")
        case .onDevice:
            active = deviceReady ? .onDevice
                : .none(reason: onDeviceReason())
        case .ollama:
            let m = settings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
            localBrain = LocalBrainPolicy.state(modelTag: m, reachable: ollamaReachable)
            if m.isEmpty {
                active = .none(reason: LocalBrainPolicy.reason(for: .notConfigured))
            } else if ollamaReachable == true {
                active = .ollama(model: m)
                probeLocalToolCapability(model: m)
                probeOllamaReachability()   // keep the confirmed state honest if the daemon quits
            } else {
                // A pre-filled model tag is NOT a running brain, so this is still the honest
                // no-brain state — but it is "CONFIGURED BUT UNREACHABLE", not "nothing is set up",
                // and it never blocks the buyer from entering their workspace (M1/M2).
                active = .none(reason: LocalBrainPolicy.reason(for: localBrain))
                probeOllamaReachability()
            }
        case .localEndpoint:
            let m = settings.endpointModel.trimmingCharacters(in: .whitespacesAndNewlines)
            active = m.isEmpty
                ? .none(reason: "Pick a model from your local server in Settings — serve one on 127.0.0.1:\(endpointPort) (llama.cpp `llama-server` or LM Studio), then Detect.")
                : .localEndpoint(model: m)
            if !m.isEmpty { probeLocalEndpointToolCapability(model: m) }
        case .auto:
            // Apple's on-device model FIRST (Founder 2026-07-03): it answers with zero setup.
            // The local Ornith routes are the buyer's deliberate opt-in, never the silent default.
            let m = settings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let em = settings.endpointModel.trimmingCharacters(in: .whitespacesAndNewlines)
            localBrain = LocalBrainPolicy.state(modelTag: m, reachable: ollamaReachable)
            if !m.isEmpty { probeOllamaReachability() }   // let auto upgrade once the daemon answers
            if deviceReady { active = .onDevice }
            else if !m.isEmpty, ollamaReachable == true { active = .ollama(model: m); probeLocalToolCapability(model: m) }
            else if !em.isEmpty { active = .localEndpoint(model: em); probeLocalEndpointToolCapability(model: em) }
            else if externalReady { active = .external(model: activeModel) }
            else if localBrain.isConfigured {
                // The buyer DID set up a local brain; the daemon just isn't answering. Say that,
                // instead of the "nothing is installed" copy that reads like their setup vanished.
                active = .none(reason: LocalBrainPolicy.reason(for: localBrain))
            }
            else { active = .none(reason: "No brain available yet — enable Apple Intelligence for the on-device model, or install Ornith 1.0 through Ollama (or serve it on a local OpenAI-compatible server).") }
        }
    }

    /// Probe the local Ollama daemon's liveness (fast, never optimistic) and re-resolve when the
    /// answer changes. One probe in flight at a time; steady states never loop (resolve → probe →
    /// same value → no resolve).
    private func probeOllamaReachability() {
        guard !ollamaProbeInFlight else { return }
        ollamaProbeInFlight = true
        Task { @MainActor in
            let up = await OllamaBrain.quickReachable()
            self.ollamaProbeInFlight = false
            if self.ollamaReachable != up { self.ollamaReachable = up; self.resolve() }
        }
    }

    /// Probe (once per model tag) whether the active local Ollama model supports NATIVE tool
    /// calling, so the agent loop can run for real on the buyer's own local model. The published
    /// flag flips only on a real /api/show answer; a daemon error leaves it false (receipts mode).
    private func probeLocalToolCapability(model: String) {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { localToolCapable = false; toolCapabilityProbedModel = nil; return }
        guard toolCapabilityProbedModel != m else { return }
        toolCapabilityProbedModel = m
        localToolCapable = false
        Task { @MainActor in
            let supported = await ollama.supportsTools(model: m)
            // Only publish if the buyer hasn't switched models while the probe was in flight.
            if self.toolCapabilityProbedModel == m { self.localToolCapable = supported }
        }
    }

    /// Probe whether the configured local OpenAI-compatible endpoint model reports function-calling.
    /// This is cached by model+port so settings changes to either trigger a fresh probe.
    private func probeLocalEndpointToolCapability(model: String) {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = endpointPort
        let probeKey = "\(m)|\(port)"
        guard !m.isEmpty else { localEndpointToolCapable = false; endpointToolCapabilityProbedModel = nil; return }
        guard endpointToolCapabilityProbedModel != probeKey else { return }
        endpointToolCapabilityProbedModel = probeKey
        localEndpointToolCapable = false
        Task { @MainActor in
            await endpoint.setPort(port)
            let supported = await endpoint.supportsTools(model: m, port: port)
            if self.endpointToolCapabilityProbedModel == probeKey {
                self.localEndpointToolCapable = supported
            }
        }
    }

    /// The LOCAL agent brain (native Ollama tool-calling) + model, when the active brain is a
    /// tool-capable Ollama model. The placeholder credential satisfies the shared seam — the local
    /// daemon authenticates nothing and the adapter never reads it.
    func localAgentIfCapable() -> (brain: any AgentBrain, model: String, credential: ExternalCredential)? {
        if case .ollama(let model) = active, localToolCapable {
            return (ollamaAgent, model, ExternalCredential(kind: .apiKey, secret: "local-ollama"))
        }
        if case .localEndpoint(let model) = active, localEndpointToolCapable {
            let port = endpointPort
            Task { await endpoint.setPort(port) }
            return (endpoint, model, ExternalCredential(kind: .apiKey, secret: "local-endpoint"))
        }
        return nil
    }

    private func onDeviceReason() -> String {
        if case .unavailable(let r) = ai?.availability { return r }
        return "On-device model not available on this device."
    }

    /// The CLI takes ONE prompt, not a structured messages array. Flatten prior turns into a short
    /// transcript so the CLI brain still has conversation context. Honest framing; no fabrication.
    nonisolated static func flattenHistory(_ history: [(role: String, text: String)], prompt: String) -> String {
        guard !history.isEmpty else { return prompt }
        var lines: [String] = []
        for turn in history.suffix(20) {   // cap context so the prompt stays bounded
            let who = turn.role == "assistant" ? "Assistant" : "User"
            let t = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append("\(who): \(t)") }
        }
        lines.append("User: \(prompt)")
        lines.append("Assistant:")
        return lines.joined(separator: "\n\n")
    }

    var isUsable: Bool { active.isUsable }
    var isAgentCapable: Bool {
        if isDemo { return true }
        // The local Ollama brain drives the REAL structured tool loop when its model reports
        // native tool support (Ornith does) — probed, never assumed.
        if case .ollama = active, localToolCapable { return true }
        if case .localEndpoint = active, localEndpointToolCapable { return true }
        guard case .external = active, let kind = auth.connectedKind else { return false }
        return kind != .cli && kind != .secondaryCLI && kind != .customCLI
    }
    var isAgentRunnable: Bool {
        isDemo || active.isUsable
    }
    var agentLimitedReason: String {
        guard !isAgentCapable, isAgentRunnable else { return "" }
        switch active {
        case .external:
            return "This text brain can run local agent receipts, but not structured tool calls. Connect an API/OAuth brain to use connected tools and confirmation-gated actions."
        case .ollama:
            return "This local model doesn't report native tool-calling, so agents run safe read-only receipts and answer from them. Pick a tool-capable local model (Ornith 1.0) in Settings for the full agent loop."
        case .localEndpoint:
            return "This local server model doesn't report native tool-calling, so agents run safe read-only receipts and answer from them. Confirm the server is serving a tool-calling-capable model, then run tool-based agent mode."
        case .onDevice:
            return "Local agent mode runs safe read-only receipts on this Mac, then answers with the active brain. Connect an API/OAuth brain (or the tool-capable Ornith 1.0 through Ollama) for the full agent loop."
        case .none:
            return ""
        }
    }
    var agentUnavailableReason: String {
        if isAgentRunnable { return "" }
        if case .external = active, let kind = auth.connectedKind,
           kind == .cli || kind == .secondaryCLI || kind == .customCLI {
            return "Agents need a tool-capable API/OAuth brain. The connected CLI route can answer chat, but it cannot drive structured tool calls. Connect an API key or OAuth account in Settings → Brain, then run this agent."
        }
        switch active {
        case .onDevice, .ollama, .localEndpoint:
            return ""
        case .none(let reason):
            return "No agent brain is connected. \(reason) Open Settings → Brain and choose Ornith/Ollama, a local server, on-device, or API/OAuth."
        case .external:
            return ""
        }
    }
    var supportsImages: Bool {
        if case .external = active, let kind = auth.connectedKind,
           kind == .cli || kind == .secondaryCLI || kind == .customCLI { return false }
        return active.supportsImages
    }

    /// STREAMING. `onToken` fires with cumulative text; `onDone` with the final text (nil on fail).
    func stream(prompt: String, system: String, grounding: String, images: [BrainImage],
                history: [(role: String, text: String)],
                onToken: @escaping (String) -> Void, onDone: @escaping (String?) -> Void) {
        lastError = nil
        resolve()
        // Demo Mode: simulate a streamed reply (token-by-token) so the chat UI behaves exactly as
        // it would live, but with NO account, NO network, and a clear "sample reply" label.
        if isDemo {
            streamDemo(prompt: prompt, onToken: onToken, onDone: onDone)
            return
        }
        switch active {
        case .none(let reason):
            lastError = reason
            onDone(nil)

        case .onDevice:
            // FoundationModels is text-only — surface an honest note if images were attached.
            if !images.isEmpty {
                lastError = "The on-device model is text-only. Image analysis is not available on this local brain."
                onDone(nil); return
            }
            ai?.stream(prompt: prompt, system: system, grounding: grounding,
                       onToken: onToken,
                       onDone: { final in
                           self.thinking = false
                           self.lastError = self.ai?.lastError
                           onDone(final)
                       })
            thinking = ai?.thinking ?? false

        case .ollama(let model):
            // Fully-local: text-only in Sovereign. Honest note if images were attached.
            if !images.isEmpty {
                lastError = "The Ornith/Ollama brain is text-only in Sovereign. Image analysis is not available on this local brain."
                onDone(nil); return
            }
            let fullSystem = grounding.isEmpty ? system
                : system + "\n\nGrounding context (the user's own private notes & documents — use only if relevant, never invent):\n" + grounding
            thinking = true
            liveReasoning = ""
            streamTask?.cancel()
            streamTask = Task { @MainActor in
                do {
                    let final = try await ollama.stream(model: model, system: fullSystem, userText: prompt,
                                                        history: history,
                                                        onThinking: { r in
                        Task { @MainActor in self.liveReasoning = r }
                    },
                                                        onToken: { t in
                        Task { @MainActor in onToken(t) }
                    })
                    self.thinking = false
                    self.liveReasoning = ""
                    onDone(final.isEmpty ? nil : final)
                } catch is CancellationError {
                    self.thinking = false; self.liveReasoning = ""; onDone(nil)
                } catch {
                    self.thinking = false
                    self.liveReasoning = ""
                    self.lastError = (error as? OllamaBrain.Failure)?.message ?? error.localizedDescription
                    onDone(nil)
                }
            }

        case .localEndpoint(let model):
            // Fully-local via the buyer's own loopback server: text-only in Sovereign. Honest note
            // if images were attached — never a silently-dropped attachment.
            if !images.isEmpty {
                lastError = "The local-server brain is text-only in Sovereign. Image analysis is not available on this local brain."
                onDone(nil); return
            }
            let fullSystem = grounding.isEmpty ? system
                : system + "\n\nGrounding context (the user's own private notes & documents — use only if relevant, never invent):\n" + grounding
            thinking = true
            streamTask?.cancel()
            let port = endpointPort
            streamTask = Task { @MainActor in
                do {
                    let final = try await endpoint.stream(model: model, system: fullSystem, userText: prompt,
                                                          history: history, port: port, onToken: { t in
                        Task { @MainActor in onToken(t) }
                    })
                    self.thinking = false
                    onDone(final.isEmpty ? nil : final)
                } catch is CancellationError {
                    self.thinking = false; onDone(nil)
                } catch {
                    self.thinking = false
                    self.lastError = (error as? OpenAIEndpointBrain.Failure)?.message ?? error.localizedDescription
                    onDone(nil)
                }
            }

        case .external(let model):
            guard let cred = auth.currentCredential() else {
                lastError = "The external account credential is missing. Use the local Ornith/Ollama brain in Settings."
                onDone(nil); return
            }
            let fullSystem = grounding.isEmpty ? system
                : system + "\n\nGrounding context (the user's own private notes & documents — use only if relevant, never invent):\n" + grounding
            let maxTokens = 16000
            thinking = true
            streamTask?.cancel()

            // CLI subscription path: the buyer's own `external login` session (no key, no per-token
            // billing). Text-only — surface an honest note if images were attached.
            if cred.kind == .cli || cred.kind == .secondaryCLI || cred.kind == .customCLI {
                if !images.isEmpty {
                    self.thinking = false
                    lastError = "The CLI brain is text-only. Connect an API key to analyze images."
                    onDone(nil); return
                }
                let cliPath = cred.secret   // the resolved CLI path / encoded custom-CLI spec (non-secret)
                let convo = Self.flattenHistory(history, prompt: prompt)
                let kind = cred.kind
                streamTask = Task { @MainActor in
                    do {
                        let final: String
                        switch kind {
                        case .secondaryCLI:
                            final = try await secondaryCLI.stream(system: fullSystem, prompt: convo,
                                                              cliPath: cliPath, onToken: { t in
                                Task { @MainActor in onToken(t) }
                            })
                        case .customCLI:
                            guard let spec = CustomCLISpec.decode(cliPath) else {
                                throw CustomCLIBrain.Failure(message: "Your custom CLI command is missing. Re-connect in Settings.")
                            }
                            final = try await customCLI.stream(spec: spec, system: fullSystem, prompt: convo,
                                                               onToken: { t in
                                Task { @MainActor in onToken(t) }
                            })
                        default:
                            final = try await cli.stream(model: model, system: fullSystem, prompt: convo,
                                                          cliPath: cliPath, onToken: { t in
                                Task { @MainActor in onToken(t) }
                            })
                        }
                        self.thinking = false
                        onDone(final.isEmpty ? nil : final)
                    } catch is CancellationError {
                        self.thinking = false; onDone(nil)
                    } catch {
                        self.thinking = false
                        self.lastError = (error as? CLIBrain.Failure)?.message
                            ?? (error as? SecondaryCLIBrain.Failure)?.message
                            ?? (error as? CustomCLIBrain.Failure)?.message
                            ?? error.localizedDescription
                        onDone(nil)
                    }
                }
                return
            }

            streamTask = Task { @MainActor in
                do {
                    let final = try await external.stream(model: model, system: fullSystem, userText: prompt,
                                                         images: images, history: history, maxTokens: maxTokens,
                                                         credential: cred, onToken: { t in
                        Task { @MainActor in onToken(t) }
                    })
                    self.thinking = false
                    onDone(final.isEmpty ? nil : final)
                } catch is CancellationError {
                    self.thinking = false; onDone(nil)
                } catch {
                    self.thinking = false
                    self.lastError = (error as? ExternalBrain.Failure)?.message ?? error.localizedDescription
                    onDone(nil)
                }
            }
        }
    }

    /// Demo Mode streamed reply: a deterministic, clearly-labeled SAMPLE answer, delivered
    /// word-by-word so the typing animation looks live. No account, no network egress.
    private func streamDemo(prompt: String, onToken: @escaping (String) -> Void, onDone: @escaping (String?) -> Void) {
        let full = DemoMode.cannedReply(to: prompt) + "\n\n" + DemoMode.replyFootnote
        let words = full.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        thinking = true
        streamTask?.cancel()
        streamTask = Task { @MainActor in
            var shown = ""
            for (i, w) in words.enumerated() {
                if Task.isCancelled { break }
                shown += (i == 0 ? "" : " ") + w
                onToken(shown)
                try? await Task.sleep(nanoseconds: 18_000_000)   // ~18ms/word: lifelike, quick
            }
            self.thinking = false
            onDone(Task.isCancelled ? (shown.isEmpty ? nil : shown) : full)
        }
    }

    /// Execute one non-streaming external call through the shared lane policy. A failed preferred
    /// model is retried only against the plan's bounded fallback list; every attempt holds the
    /// lane's process-wide concurrency permit and uses the lane timeout/token ceiling.
    private func routedExternalComplete(selectedModel: String, workload: ModelWorkload,
                                        prompt: String, system: String,
                                        credential: ExternalCredential) async throws -> String {
        let plan = ModelRoutingPolicy.plan(for: workload, selectedModel: selectedModel)
        var failures: [String] = []
        for candidate in plan.candidateModels {
            await ModelLaneGate.shared.acquire(plan.lane, limit: plan.maxConcurrent)
            do {
                if Task.isCancelled { throw CancellationError() }
                let answer = try await external.complete(model: candidate, system: system, userText: prompt,
                                                         maxTokens: plan.maxOutputTokens,
                                                         timeoutSeconds: plan.timeoutSeconds,
                                                         credential: credential)
                ModelLaneGate.shared.release(plan.lane)
                return answer
            } catch {
                ModelLaneGate.shared.release(plan.lane)
                if error is CancellationError { throw error }
                failures.append("\(candidate): \(error.localizedDescription)")
            }
        }
        let detail = failures.isEmpty ? "no usable model candidates" : failures.joined(separator: " | ")
        throw ModelRoutingFailure(message: "The \(plan.lane.rawValue) model lane failed: \(detail)")
    }

    /// NON-streaming single-shot (Skills / Automations). Honest error on failure.
    func complete(prompt: String, system: String, onResult: @escaping (Result<String, Error>) -> Void) {
        resolve()
        // Demo Mode: return a clearly-labeled SAMPLE result so Skills/Automations are demonstrable
        // without an account. Never a real model call.
        if isDemo {
            onResult(.success(DemoMode.cannedReply(to: prompt) + "\n\n" + DemoMode.replyFootnote))
            return
        }
        switch active {
        case .none(let reason):
            onResult(.failure(ExternalBrain.Failure(message: reason)))
        case .onDevice:
            ai?.complete(prompt: prompt, system: system) { r in
                switch r { case .success(let s): onResult(.success(s)); case .failure(let e): onResult(.failure(e)) }
            }
        case .ollama(let model):
            Task { @MainActor in
                do {
                    let s = try await ollama.complete(model: model, system: system, userText: prompt)
                    onResult(.success(s))
                } catch { onResult(.failure(error)) }
            }
        case .localEndpoint(let model):
            let port = endpointPort
            Task { @MainActor in
                do {
                    let s = try await endpoint.complete(model: model, system: system, userText: prompt, port: port)
                    onResult(.success(s))
                } catch { onResult(.failure(error)) }
            }
        case .external(let model):
            guard let cred = auth.currentCredential() else {
                onResult(.failure(ExternalBrain.Failure(message: "The external account credential is missing."))); return
            }
            if cred.kind == .cli || cred.kind == .secondaryCLI || cred.kind == .customCLI {
                let cliPath = cred.secret
                let kind = cred.kind
                Task { @MainActor in
                    do {
                        let s: String
                        switch kind {
                        case .secondaryCLI:
                            s = try await secondaryCLI.complete(system: system, prompt: prompt, cliPath: cliPath)
                        case .customCLI:
                            guard let spec = CustomCLISpec.decode(cliPath) else {
                                throw CustomCLIBrain.Failure(message: "Your custom CLI command is missing. Re-connect in Settings.")
                            }
                            s = try await customCLI.complete(spec: spec, system: system, prompt: prompt)
                        default:
                            s = try await cli.complete(model: model, system: system, prompt: prompt, cliPath: cliPath)
                        }
                        onResult(.success(s))
                    } catch { onResult(.failure(error)) }
                }
                return
            }
            Task { @MainActor in
                do {
                    // Skills/automations are routine work: cheap lane first, selected buyer model as
                    // the bounded fallback. Chat streaming still honors the explicitly selected model.
                    let s = try await self.routedExternalComplete(selectedModel: model, workload: .routine,
                                                                  prompt: prompt, system: system,
                                                                  credential: cred)
                    onResult(.success(s))
                } catch { onResult(.failure(error)) }
            }
        }
    }

    /// Expose the agent brain (through the `AgentBrain` seam) + credential for the agentic loop.
    /// The multi-step tool-use loop needs the structured /v1/messages tool protocol — the CLI
    /// subscription path is a plain text completion, so it cannot drive the agent. Returns nil for
    /// a CLI credential; the AgentEngine then reports honestly that agents need an API-key brain.
    func externalForAgent() -> (brain: any AgentBrain, model: String, credential: ExternalCredential)? {
        guard case .external(let model) = active, let cred = auth.currentCredential(),
              cred.kind != .cli && cred.kind != .secondaryCLI && cred.kind != .customCLI else { return nil }
        return (external, model, cred)
    }

    func cancel() {
        streamTask?.cancel(); streamTask = nil
        ai?.cancel()
        thinking = false
        liveReasoning = ""
    }
    /// Warm the active brain so the FIRST question doesn't pay a cold model load. For the local
    /// Ollama route this preloads the selected model into memory (best-effort, fire-and-forget) —
    /// without it, Ollama's 5-minute idle unload made every return to Sovereign stall multi-second
    /// on the next ask, which read as "answering is broken".
    func prewarm() {
        ai?.prewarm()
        if case .ollama(let model) = active {
            Task { await ollama.preload(model: model) }
        }
    }
    func resetSession() { ai?.resetSession() }
}
#endif // circuit-convert
