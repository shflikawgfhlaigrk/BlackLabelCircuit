// Sovereign — OLLAMA BRAIN: fully-local inference on the buyer's OWN machine.
//
// The site promises "Ollama for fully-local inference." This is that, honestly: Sovereign talks to
// the buyer's own Ollama daemon at http://127.0.0.1:11434 — no account, no API key, no cloud, no
// Black Label backend. The model runs on THEIR hardware; their prompts never leave the device.
//
// WORKS IN BOTH BUILD LANES: the app's network.client entitlement permits localhost HTTP, so this
// route is available in the sandboxed App Store build AND the Developer-ID build — unlike the CLI
// brains, which need subprocess spawn and are Developer-ID-only.
//
// HONESTY (§5.1): when the daemon is down, the model is missing, or a call fails, the buyer gets an
// honest error ("Ollama isn't running — start it with `ollama serve`"), never a fabricated reply.
// Model selection is driven by a live GET /api/tags — we never assume which models are installed.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One locally-installed Ollama model, parsed from GET /api/tags.
struct OllamaModel: Identifiable, Equatable, Hashable {
    let name: String                 // e.g. "llama3.2:3b" — used verbatim as the model id
    let sizeBytes: Int64             // on-disk size (for an honest size label)
    let capabilities: [String]       // e.g. ["completion","tools"] / ["embedding"] (empty on old daemons)
    var id: String { name }

    /// True when this model can answer chat (i.e. it isn't a pure embedding model). When the daemon
    /// doesn't report capabilities (older Ollama), we can't tell — default to usable, honestly.
    var isChatCapable: Bool {
        if capabilities.isEmpty { return true }
        if capabilities.contains("embedding") && !capabilities.contains("completion") { return false }
        return true
    }
    /// Human size label ("3.2 GB" / "274 MB"). Decimal units to match the Ollama UI.
    var sizeLabel: String {
        let gb = Double(sizeBytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(sizeBytes) / 1_000_000
        return String(format: "%.0f MB", mb)
    }
}

/// First-run local-brain DETECTION state — derived PURELY from a fast liveness probe of the
/// buyer's OWN Ollama daemon (:11434). The point is a unit-testable "did Ollama answer?" → "which
/// first-run UI do we show?" decision with NO network in the test. §5.1: `.running` is reported
/// ONLY after a real probe success — the UI never claims a daemon that isn't there.
enum OllamaDetection: Equatable {
    case unknown               // not probed yet — show nothing definitive
    case detecting             // a probe is in flight
    case running(models: Int)  // daemon answered — skip the install guide, go straight to pull/select
    case absent                // daemon unreachable — the one-step install guide is the right surface

    /// Map a fast liveness-probe result to the detection state. PURE: `reachable` is whether the
    /// GET /api/version probe returned HTTP 200; `chatModelCount` is how many chat-capable models
    /// were found (only meaningful when reachable). No fabrication — not reachable ⇒ `.absent`,
    /// and a negative count is clamped to 0.
    static func classify(reachable: Bool, chatModelCount: Int) -> OllamaDetection {
        reachable ? .running(models: max(0, chatModelCount)) : .absent
    }

    /// True when the daemon is up, so onboarding can skip the "install Ollama" step entirely and
    /// take the buyer straight to picking a size + pulling Ornith.
    var skipsInstallGuide: Bool { if case .running = self { return true }; return false }

    /// True once we actually know (probed). `.unknown`/`.detecting` carry no verdict yet, so the
    /// UI shows neither the green "detected" banner nor the install guide.
    var isResolved: Bool {
        switch self { case .unknown, .detecting: return false; case .running, .absent: return true }
    }

    /// The honest green banner text when Ollama is running (nil otherwise). Names whether the buyer
    /// already has a model installed so the copy never over-promises.
    var runningBanner: String? {
        guard case .running(let n) = self else { return nil }
        if n > 0 { return "Ollama detected — running on this Mac (\(n) local model\(n == 1 ? "" : "s") ready)." }
        return "Ollama detected — running on this Mac. Pick a size below to set up Ornith — no install needed."
    }
}

/// Fully-local brain backed by the buyer's own Ollama daemon. No account, no key, no cloud.
actor OllamaBrain {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    /// The buyer's local Ollama daemon. Loopback only — never a remote host.
    static let defaultHost = "http://127.0.0.1:11434"
    /// Sovereign's preferred high-capability local brain. The app never assumes it exists;
    /// it is selected only after a live /api/tags result proves it is installed.
    /// Names + recognition live in `OrnithRecommended` (OpenAIEndpointBrain.swift), SHARED by
    /// both local routes — these forwards keep existing call sites working.
    static let sovereignRecommendedDisplayName = OrnithRecommended.displayName
    static let sovereignRecommendedModel = OrnithRecommended.ollamaTag
    static let sovereignRecommendedPullCommand = OrnithRecommended.ollamaPullCommand

    /// True for ANY Ornith tag — `ornith:latest`, a re-tag, a different quant — not just the
    /// exact recommended string. Case-insensitive, shared with the endpoint route.
    static func isSovereignRecommended(model: String) -> Bool {
        OrnithRecommended.matches(model)
    }

    private let session: URLSession
    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        session = URLSession(configuration: cfg)
    }

    // MARK: - Pure helpers (unit-tested without a network call)

    /// Context window requested per chat call. Ollama's own default is 4,096 tokens — with RAG
    /// grounding + history folded in, a real conversation silently truncated (oldest turns AND
    /// sometimes the system prompt fell out of the window ⇒ off-topic answers). Ornith 1.0 supports
    /// a 262k context; 32k is the sane resident-KV compromise (a few GB on the 35B, fine on 16 GB
    /// Macs with the 9B). Ollama clamps to the model's own max when smaller.
    static let chatContextTokens = 32_768
    /// Keep the model resident between asks. Ollama's default unloads after 5 idle minutes, so the
    /// next question paid a full cold load (~10 s on an M-class 64 GB Mac, far worse on smaller
    /// machines) — which reads as "Sovereign hung". Two hours matches a working session.
    static let keepAliveWindow = "2h"

    /// The shared per-request tuning block. PURE.
    static func requestOptions() -> [String: Any] { ["num_ctx": chatContextTokens] }

    /// Build the POST /api/chat request body from system + user + prior turns. PURE — tested directly.
    static func chatBody(model: String, system: String, userText: String,
                         history: [(role: String, text: String)], stream: Bool = false) -> Data {
        var messages: [[String: Any]] = []
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { messages.append(["role": "system", "content": sys]) }
        for turn in history {
            let role = turn.role == "assistant" ? "assistant" : "user"
            let t = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { messages.append(["role": role, "content": t]) }
        }
        messages.append(["role": "user", "content": userText])
        let dict: [String: Any] = ["model": model, "messages": messages, "stream": stream,
                                   "options": requestOptions(), "keep_alive": keepAliveWindow]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    /// Build the POST /api/generate request body (fallback for older daemons). PURE.
    static func generateBody(model: String, system: String, userText: String, stream: Bool = false) -> Data {
        var dict: [String: Any] = ["model": model, "prompt": userText, "stream": stream,
                                   "options": requestOptions(), "keep_alive": keepAliveWindow]
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { dict["system"] = sys }
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    /// Parse a /api/chat (or /api/generate) non-streaming response for the assistant text. PURE.
    /// /api/chat returns {"message":{"content":"..."}}; /api/generate returns {"response":"..."}.
    static func parseChatContent(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let msg = obj["message"] as? [String: Any], let content = msg["content"] as? String { return content }
        if let resp = obj["response"] as? String { return resp }
        return nil
    }

    /// Parse one streamed NDJSON line for its incremental content delta. PURE.
    /// Returns (delta, thinking, done, error). A blank/garbage line yields ("", "", false, nil) so
    /// the caller skips it. `thinking` is the REASONING delta a thinking model (Ornith 1.0) emits
    /// in `message.thinking` before any answer text — for the whole reasoning phase `delta` stays
    /// empty, which used to read as a dead hang in the chat UI. Surfacing it lets the UI show live,
    /// honest progress (the model's own reasoning stream, never invented).
    static func parseStreamLine(_ line: String) -> (delta: String, thinking: String, done: Bool, error: String?) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ("", "", false, nil) }
        if let err = obj["error"] as? String { return ("", "", true, err) }
        var delta = ""
        var thinking = ""
        if let msg = obj["message"] as? [String: Any] {
            if let c = msg["content"] as? String { delta = c }
            if let th = msg["thinking"] as? String { thinking = th }
        } else if let r = obj["response"] as? String { delta = r }
        let done = (obj["done"] as? Bool) == true
        return (delta, thinking, done, nil)
    }

    /// Parse GET /api/tags into the installed model list. PURE.
    static func parseTags(_ data: Data) -> [OllamaModel] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { m in
            guard let name = m["name"] as? String, !name.isEmpty else { return nil }
            let size = (m["size"] as? NSNumber)?.int64Value ?? 0
            let caps = (m["capabilities"] as? [String]) ?? []
            return OllamaModel(name: name, sizeBytes: size, capabilities: caps)
        }
    }

    /// One parsed line of a streaming /api/pull response. `completed`/`total` are byte counts that
    /// Ollama reports during the layer download; `status` is Ollama's own phase text (e.g.
    /// "pulling manifest", "pulling <digest>", "verifying sha256 digest", "success"). Nothing here
    /// is invented — every field comes straight off the daemon's NDJSON. PURE.
    struct PullProgress: Equatable {
        var status: String = ""
        var completed: Int64 = 0
        var total: Int64 = 0
        var done: Bool = false          // the daemon reported "success"
        var error: String? = nil        // the daemon reported an error object/string
        /// 0…1 download fraction, only when the daemon has given us a real total.
        var fraction: Double? { total > 0 ? min(1, Double(completed) / Double(total)) : nil }
    }

    /// Parse one NDJSON line of POST /api/pull into a PullProgress. PURE — no fabrication:
    /// bytes and status text are taken verbatim; a line with no numbers just carries its status.
    static func parsePullLine(_ line: String) -> PullProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var p = PullProgress()
        p.status = (obj["status"] as? String) ?? ""
        p.completed = (obj["completed"] as? NSNumber)?.int64Value ?? 0
        p.total = (obj["total"] as? NSNumber)?.int64Value ?? 0
        if let err = obj["error"] as? String { p.error = err }
        if p.status.lowercased() == "success" { p.done = true }
        return p
    }

    /// Map a transport error to an honest, human message (never a fabricated reply).
    static func describe(error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain &&
            (ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorCannotFindHost
             || ns.code == NSURLErrorNetworkConnectionLost || ns.code == NSURLErrorTimedOut) {
            return "Ollama isn't running — start it with `ollama serve` (or open the Ollama app), then try again."
        }
        return "Couldn't reach Ollama at \(defaultHost): \(error.localizedDescription)"
    }

    // MARK: - Network

    /// GET /api/tags — the buyer's actually-installed models. Honest error if the daemon is down.
    func listModels(host: String = OllamaBrain.defaultHost) async throws -> [OllamaModel] {
        guard let url = URL(string: "\(host)/api/tags") else { throw Failure(message: "Invalid Ollama host.") }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Failure(message: "Ollama returned HTTP \(http.statusCode) from /api/tags.")
            }
            return Self.parseTags(data)
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure(message: Self.describe(error: error))
        }
    }

    /// GET /api/version — a cheap liveness probe. Returns the daemon's reported version string when
    /// it's up, or throws an honest "isn't running" Failure when it isn't. Used by the one-tap
    /// setup flow to tell "install Ollama" apart from "Ollama is here, just pull the model".
    func version(host: String = OllamaBrain.defaultHost) async throws -> String {
        guard let url = URL(string: "\(host)/api/version") else { throw Failure(message: "Invalid Ollama host.") }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Failure(message: "Ollama returned HTTP \(http.statusCode) from /api/version.")
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let v = obj["version"] as? String { return v }
            return "unknown"
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure(message: Self.describe(error: error))
        }
    }

    /// FAST, non-blocking liveness probe for the first-run UI: GET /api/version with a SHORT timeout
    /// so a down daemon fails in ~`timeout`s instead of stalling onboarding behind the long request
    /// timeout used for model pulls. Returns true ONLY on a real HTTP 200 — never optimistic; used
    /// to auto-detect a running Ollama and skip the install guide (§5.1: no fabricated presence).
    static func quickReachable(host: String = OllamaBrain.defaultHost, timeout: TimeInterval = 2.5) async -> Bool {
        guard let url = URL(string: "\(host)/api/version") else { return false }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        do {
            let (_, response) = try await URLSession(configuration: cfg).data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    /// POST /api/pull (stream:true, NDJSON) — pull a model into the buyer's OWN Ollama on THIS Mac.
    /// This is the one-tap "set up your free local brain" path: Ollama fetches the GGUF from its
    /// registry directly to the buyer's disk; the model runs locally, prompts never leave the device.
    /// `onProgress` fires on the main actor with each real progress line (byte counts + phase text);
    /// nothing is invented. Resolves when the daemon reports "success"; throws on any daemon error.
    func pull(model: String,
              host: String = OllamaBrain.defaultHost,
              onProgress: @escaping @Sendable (PullProgress) -> Void) async throws {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { throw Failure(message: "No model to pull.") }
        guard let url = URL(string: "\(host)/api/pull") else { throw Failure(message: "Invalid Ollama host.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60 * 60          // large models take a while; the stream keeps it alive
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": m, "stream": true])
        do {
            let (bytes, response) = try await session.bytes(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var raw = ""
                for try await line in bytes.lines { raw += line }
                if let data = raw.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = obj["error"] as? String {
                    throw Failure(message: "Ollama couldn't pull \(m): \(err)")
                }
                throw Failure(message: "Ollama returned HTTP \(http.statusCode) from /api/pull.")
            }
            var sawSuccess = false
            for try await line in bytes.lines {
                guard let p = Self.parsePullLine(line) else { continue }
                if let err = p.error { throw Failure(message: "Ollama couldn't pull \(m): \(err)") }
                let progress = p
                await MainActor.run { onProgress(progress) }
                if p.done { sawSuccess = true }
            }
            guard sawSuccess else {
                throw Failure(message: "The download ended before Ollama reported success — try again.")
            }
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure(message: Self.describe(error: error))
        }
    }

    /// POST a non-streaming request and return the parsed reply (nil if none). Surfaces Ollama's own
    /// error text + the HTTP status so the caller can distinguish a 404 (try /api/generate) honestly.
    private func post(path: String, body: Data, host: String) async throws -> String? {
        guard let url = URL(string: "\(host)\(path)") else { throw Failure(message: "Invalid Ollama host.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = obj["error"] as? String {
                    throw Failure(message: "Ollama error (\(http.statusCode)): \(err)")
                }
                throw Failure(message: "Ollama returned HTTP \(http.statusCode).")
            }
            return Self.parseChatContent(data)
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure(message: Self.describe(error: error))
        }
    }

    /// One non-streaming completion via POST /api/chat (preferred), falling back to /api/generate on
    /// an old daemon that 404s /api/chat. Honest error on any failure; never a fabricated reply.
    func complete(model: String, system: String, userText: String,
                  history: [(role: String, text: String)] = [],
                  host: String = OllamaBrain.defaultHost) async throws -> String {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else {
            throw Failure(message: "No Ollama model selected. Pick one in Settings (or run `ollama pull llama3.2`).")
        }
        do {
            if let text = try await post(path: "/api/chat",
                                         body: Self.chatBody(model: m, system: system, userText: userText, history: history),
                                         host: host), !text.isEmpty {
                return text
            }
        } catch let e as Failure {
            if !e.message.contains("(404)") { throw e }   // only a missing /api/chat falls through
        }
        guard let text = try await post(path: "/api/generate",
                                        body: Self.generateBody(model: m, system: system, userText: userText),
                                        host: host), !text.isEmpty else {
            throw Failure(message: "Ollama returned an empty reply.")
        }
        return text
    }

    /// STREAMING completion via POST /api/chat (stream:true, NDJSON). `onToken` fires with cumulative
    /// text; `onThinking` (optional) fires with the model's cumulative REASONING stream while a
    /// thinking model (Ornith) works — the phase that used to look like a hang. Resolves with the
    /// final text. Falls back to a single-shot completion on a 404 (old daemon).
    func stream(model: String, system: String, userText: String,
                history: [(role: String, text: String)],
                host: String = OllamaBrain.defaultHost,
                onThinking: ((String) -> Void)? = nil,
                onToken: @escaping (String) -> Void) async throws -> String {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else {
            throw Failure(message: "No Ollama model selected. Pick one in Settings (or run `ollama pull llama3.2`).")
        }
        guard let url = URL(string: "\(host)/api/chat") else { throw Failure(message: "Invalid Ollama host.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.chatBody(model: m, system: system, userText: userText, history: history, stream: true)
        do {
            let (bytes, response) = try await session.bytes(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if http.statusCode == 404 {
                    let text = try await complete(model: m, system: system, userText: userText, history: history, host: host)
                    onToken(text); return text
                }
                var raw = ""
                for try await line in bytes.lines { raw += line }
                if let data = raw.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = obj["error"] as? String {
                    throw Failure(message: "Ollama error (\(http.statusCode)): \(err)")
                }
                throw Failure(message: "Ollama returned HTTP \(http.statusCode).")
            }
            var full = ""
            var reasoning = ""
            for try await line in bytes.lines {
                let (delta, thinking, done, err) = Self.parseStreamLine(line)
                if let err = err { throw Failure(message: "Ollama error: \(err)") }
                if !thinking.isEmpty { reasoning += thinking; onThinking?(reasoning) }
                if !delta.isEmpty { full += delta; onToken(full) }
                if done { break }
            }
            return full
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure(message: Self.describe(error: error))
        }
    }

    /// Preload a model into memory (fire-and-forget warmup). POST /api/generate with an empty
    /// prompt makes Ollama load the model and hold it for `keep_alive` without generating anything
    /// — so the buyer's FIRST question doesn't pay the multi-second cold load. Failures are
    /// swallowed: warmup is best-effort and must never surface an error for a question not asked.
    func preload(model: String, host: String = OllamaBrain.defaultHost) async {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, let url = URL(string: "\(host)/api/generate") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = (try? JSONSerialization.data(withJSONObject: [
            "model": m, "keep_alive": Self.keepAliveWindow
        ])) ?? Data()
        _ = try? await session.data(for: req)
    }

    /// True when the installed model reports native tool-calling support (POST /api/show →
    /// capabilities contains "tools"). Ornith 1.0 does. §5.1: this is a REAL probe of the buyer's
    /// own daemon — never assumed; on any error the answer is false and the caller stays in the
    /// receipts-only local mode.
    func supportsTools(model: String, host: String = OllamaBrain.defaultHost) async -> Bool {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, let url = URL(string: "\(host)/api/show") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = (try? JSONSerialization.data(withJSONObject: ["model": m])) ?? Data()
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let caps = obj["capabilities"] as? [String] else { return false }
        return caps.contains("tools")
    }
}

// MARK: - OllamaAgentBrain — the REAL agent loop on the buyer's own local model.
//
// Ornith 1.0 (and other tool-capable Ollama models) support NATIVE structured tool-calling —
// but until 2026-07-27 the app hardcoded "local brains can't do tools" and ran a canned
// keyword-picked receipts pass instead, with the model reduced to summarizing. This adapter
// implements the same `AgentBrain` seam the External API brain uses, translating the agent
// loop's Anthropic-format messages/tools to Ollama's /api/chat tool protocol and back — so
// plan → act → verify actually RUNS ON the buyer's own local model. No account, no cloud.
actor OllamaAgentBrain: AgentBrain {
    private let session: URLSession
    private let host: String
    init(host: String = OllamaBrain.defaultHost) {
        self.host = host
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 240
        cfg.timeoutIntervalForResource = 600
        session = URLSession(configuration: cfg)
    }

    // MARK: Pure translation (unit-testable without a daemon)

    /// Anthropic tool defs → Ollama /api/chat tool defs. PURE.
    static func ollamaTools(_ anthropicTools: [[String: Any]]) -> [[String: Any]] {
        anthropicTools.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            var fn: [String: Any] = ["name": name]
            if let d = t["description"] as? String { fn["description"] = d }
            fn["parameters"] = t["input_schema"] ?? ["type": "object", "properties": [:]]
            return ["type": "function", "function": fn]
        }
    }

    /// Anthropic-format loop messages → Ollama chat messages. PURE.
    /// user/String → user; user/[tool_result…] → role:"tool" messages (named via the id→name map
    /// built from earlier assistant tool_use blocks); assistant/[text|tool_use…] → assistant with
    /// content + tool_calls. Unknown shapes are skipped, never invented.
    static func ollamaMessages(system: String, anthropic: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { out.append(["role": "system", "content": sys]) }
        // Map tool_use ids → tool names so tool_result blocks can carry the right tool name.
        var toolName: [String: String] = [:]
        for msg in anthropic {
            guard let blocks = msg["content"] as? [[String: Any]] else { continue }
            for b in blocks where (b["type"] as? String) == "tool_use" {
                if let id = b["id"] as? String, let name = b["name"] as? String { toolName[id] = name }
            }
        }
        for msg in anthropic {
            let role = msg["role"] as? String ?? "user"
            if let text = msg["content"] as? String {
                out.append(["role": role, "content": text])
                continue
            }
            guard let blocks = msg["content"] as? [[String: Any]] else { continue }
            if role == "assistant" {
                var text = ""
                var calls: [[String: Any]] = []
                for b in blocks {
                    switch b["type"] as? String {
                    case "text": text += (b["text"] as? String ?? "")
                    case "tool_use":
                        calls.append(["function": ["name": b["name"] as? String ?? "",
                                                   "arguments": b["input"] as? [String: Any] ?? [:]]])
                    default: break
                    }
                }
                var m: [String: Any] = ["role": "assistant", "content": text]
                if !calls.isEmpty { m["tool_calls"] = calls }
                out.append(m)
            } else {
                for b in blocks {
                    switch b["type"] as? String {
                    case "text":
                        out.append(["role": "user", "content": b["text"] as? String ?? ""])
                    case "tool_result":
                        var m: [String: Any] = ["role": "tool",
                                                "content": b["content"] as? String ?? ""]
                        if let id = b["tool_use_id"] as? String, let name = toolName[id] {
                            m["tool_name"] = name
                        }
                        out.append(m)
                    default: break
                    }
                }
            }
        }
        return out
    }

    /// Ollama /api/chat response → the seam's AgentToolTurn. PURE.
    /// `assistantContent` is rebuilt in ANTHROPIC block format (text + tool_use with generated
    /// ids) so the engine's echo-back → next-turn translation round-trips exactly. On a tool-call
    /// turn with empty content, the model's own `thinking` stream is surfaced as the turn text —
    /// its real reasoning, shown under the Reasoning receipt (never a fabricated narration).
    static func parseToolTurn(_ data: Data) -> AgentToolTurn? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["message"] as? [String: Any] else { return nil }
        let content = (msg["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let thinking = (msg["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawCalls = msg["tool_calls"] as? [[String: Any]] ?? []
        var calls: [(id: String, name: String, input: [String: Any])] = []
        var blocks: [[String: Any]] = []
        if !content.isEmpty { blocks.append(["type": "text", "text": content]) }
        for (i, rc) in rawCalls.enumerated() {
            guard let fn = rc["function"] as? [String: Any],
                  let name = fn["name"] as? String, !name.isEmpty else { continue }
            var input = fn["arguments"] as? [String: Any] ?? [:]
            // Some daemons return arguments as a JSON STRING — decode it rather than dropping it.
            if input.isEmpty, let s = fn["arguments"] as? String, let d = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { input = parsed }
            let id = "ollama_call_\(i)"
            calls.append((id: id, name: name, input: input))
            blocks.append(["type": "tool_use", "id": id, "name": name, "input": input])
        }
        let display = calls.isEmpty ? content : (content.isEmpty ? thinking : content)
        return AgentToolTurn(text: display,
                             toolCalls: calls,
                             assistantContent: blocks.isEmpty ? [["type": "text", "text": ""]] : blocks,
                             stopReason: calls.isEmpty ? "end_turn" : "tool_use")
    }

    /// One tool-use turn against the buyer's own Ollama daemon. The `credential` is unused —
    /// the local daemon needs none; it exists to satisfy the shared AgentBrain seam.
    func toolTurn(model: String, system: String, messages: [[String: Any]],
                  tools: [[String: Any]], maxTokens: Int,
                  timeoutSeconds: TimeInterval,
                  credential: ExternalCredential) async throws -> AgentToolTurn {
        guard let url = URL(string: "\(host)/api/chat") else {
            throw OllamaBrain.Failure(message: "Invalid Ollama host.")
        }
        var options = OllamaBrain.requestOptions()
        // Thinking models (Ornith) spend generated tokens on reasoning BEFORE the tool call /
        // answer; a low cap truncates mid-think and the turn comes back with no tool call, which
        // the loop would read as a (reasoning-shaped) final answer. Floor the cap well above the
        // routine lane so a local turn always has room to finish.
        options["num_predict"] = max(maxTokens, 8_192)
        let dict: [String: Any] = [
            "model": model,
            "messages": Self.ollamaMessages(system: system, anthropic: messages),
            "tools": Self.ollamaTools(tools),
            "stream": false,
            "options": options,
            "keep_alive": OllamaBrain.keepAliveWindow
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if timeoutSeconds > 0 { req.timeoutInterval = timeoutSeconds }
        req.httpBody = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = obj["error"] as? String {
                    throw OllamaBrain.Failure(message: "Ollama error (\(http.statusCode)): \(err)")
                }
                throw OllamaBrain.Failure(message: "Ollama returned HTTP \(http.statusCode).")
            }
            guard let turn = Self.parseToolTurn(data) else {
                throw OllamaBrain.Failure(message: "Ollama returned an unexpected tool-turn response.")
            }
            return turn
        } catch let e as OllamaBrain.Failure {
            throw e
        } catch {
            throw OllamaBrain.Failure(message: OllamaBrain.describe(error: error))
        }
    }
}
