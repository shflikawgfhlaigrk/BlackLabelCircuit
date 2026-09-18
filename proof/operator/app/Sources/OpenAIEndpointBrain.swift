// Sovereign — LOCAL OPENAI-COMPATIBLE ENDPOINT BRAIN: the second fully-local route.
//
// Ornith 1.0 (and any other GGUF) can be served on this Mac by llama.cpp's `llama-server`,
// LM Studio's local server, or any other OpenAI-compatible server. This actor talks to that
// server over LOOPBACK ONLY: GET /v1/models to discover what's actually being served (never
// assumed), POST /v1/chat/completions for chat. No account, no API key, no cloud, no Black
// Label backend — the model runs on the buyer's hardware and prompts never leave the device.
//
// LOOPBACK-ONLY BY CONSTRUCTION: the host is hardcoded to 127.0.0.1; only the port is
// buyer-tunable (Settings). There is no code path that reaches a remote host.
//
// HONESTY (§5.1): connection state is claimed only after a REAL round-trip. When the server
// is down, the model is missing, or a call fails, the buyer gets a precise, actionable error
// ("start llama.cpp / LM Studio on 127.0.0.1:PORT"), never a fabricated reply or a painted
// "connected". Mirrors OllamaBrain's standards and its unit-testable pure-helper style.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Ornith recognition, shared by BOTH local routes (Ollama tags + endpoint model ids).

/// Sovereign's recommended local brain — Ornith 1.0 — recognized robustly across every route.
/// A buyer who pulls Ornith under ANY tag (`ornith:latest`, a re-tag, a different quant like
/// Q4_K_M) or serves it under any endpoint model id is still running the recommended brain:
/// recognition is a case-insensitive match on "ornith" in the model id, never an exact string.
enum OrnithRecommended {
    /// The two shipped sizes of the recommended brain. 35B is full power for big-memory Macs;
    /// 9B is the same brain sized to run on a 16 GB machine. The rawValue is persisted in the
    /// settings blob — never rename a case.
    enum Variant: String, CaseIterable, Codable, Identifiable {
        case b35 = "35B"
        case b9  = "9B"
        var id: String { rawValue }

        /// Buyer-facing display name of this size of the brain.
        var displayName: String {
            switch self {
            case .b35: return "Ornith 1.0 35B Q5_K_M"
            case .b9:  return "Ornith 1.0 9B Q5_K_M"
            }
        }
        /// The exact Ollama tag Sovereign recommends pulling for this size.
        var ollamaTag: String {
            switch self {
            case .b35: return "hf.co/deepreinforce-ai/Ornith-1.0-35B-GGUF:Q5_K_M"
            case .b9:  return "hf.co/deepreinforce-ai/Ornith-1.0-9B-GGUF:Q5_K_M"
            }
        }
        /// The exact pull command shown to the buyer (guidance only; any ornith tag is recognized).
        var ollamaPullCommand: String { "ollama pull " + ollamaTag }
        /// The model id the same GGUF reports when served OpenAI-compatibly (llama.cpp / LM Studio).
        var endpointModelID: String {
            switch self {
            case .b35: return "deepreinforce-ai/Ornith-1.0-35B-GGUF:Q5_K_M"
            case .b9:  return "deepreinforce-ai/Ornith-1.0-9B-GGUF:Q5_K_M"
            }
        }
        /// The published GGUF file name, verbatim from the model repo — for llama-server guidance.
        var ggufFileName: String {
            switch self {
            case .b35: return "ornith-1.0-35b-Q5_K_M.gguf"
            case .b9:  return "ornith-1.0-9b-Q5_K_M.gguf"
            }
        }
        /// Published size of this Q5_K_M GGUF — honest download copy, never a guessed number.
        var downloadGB: Double {
            switch self {
            case .b35: return 24.7
            case .b9:  return 6.5
            }
        }
        /// Unified memory this size realistically needs to load and answer on-device.
        var minRAMGB: Int {
            switch self {
            case .b35: return 48
            case .b9:  return 16
            }
        }
        /// One-line buyer copy for the size picker.
        var subtitle: String {
            switch self {
            case .b35: return "Full power · 24.7 GB download · needs 48 GB+ memory"
            case .b9:  return "Light · 6.5 GB download · runs on 16 GB Macs"
            }
        }
    }

    /// The size that genuinely fits a Mac with this much unified memory — the 35B only when the
    /// machine can actually hold it; everything smaller is recommended the 9B. PURE.
    static func recommendedVariant(forRAMGB ram: Int) -> Variant {
        ram >= Variant.b35.minRAMGB ? .b35 : .b9
    }

    /// This Mac's unified memory in whole GB — feeds the honest "fits this Mac" line in Settings.
    static var thisMacRAMGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    /// Which shipped size a model id names, when the id itself says so ("…35B…", "…9b…") —
    /// nil for size-less Ornith tags like `ornith:latest` (still the recommended family) and
    /// for anything that is not Ornith at all. PURE.
    static func variantHint(_ modelID: String) -> Variant? {
        guard matches(modelID) else { return nil }
        let lower = modelID.lowercased()
        if lower.contains("35b") { return .b35 }
        if lower.contains("9b") { return .b9 }
        return nil
    }

    /// Buyer-facing display name of the recommended brain (the full-power size; unchanged).
    static let displayName = Variant.b35.displayName
    /// The exact Ollama tag Sovereign recommends pulling — kept verbatim as guidance.
    static let ollamaTag = Variant.b35.ollamaTag
    /// The exact pull command shown to the buyer (guidance only; any ornith tag is recognized).
    static let ollamaPullCommand = Variant.b35.ollamaPullCommand
    /// The model id the same GGUF reports when served OpenAI-compatibly (llama.cpp / LM Studio).
    static let endpointModelID = Variant.b35.endpointModelID
    /// Honest install guidance for the endpoint route (the buyer's own server, their own port).
    static let endpointServeGuidance = "serve the Ornith GGUF with llama.cpp (`llama-server`) or LM Studio's local server on 127.0.0.1"

    /// True when this model id is the recommended Ornith brain — case-insensitive, tag-agnostic.
    /// Shared by BOTH routes: Ollama tags and OpenAI-endpoint model ids.
    static func matches(_ modelID: String) -> Bool {
        modelID.range(of: "ornith", options: .caseInsensitive) != nil
    }
}

// MARK: - The endpoint brain.

/// Fully-local brain backed by any OpenAI-compatible server on this Mac (llama.cpp, LM Studio…).
/// Loopback only. No account, no key, no cloud.
actor OpenAIEndpointBrain: AgentBrain {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    /// llama.cpp's `llama-server` default port; LM Studio users can point Sovereign at 1234.
    static let defaultPort = 8080
    /// The ONLY host this brain will ever talk to. Never a remote machine.
    static let loopbackHost = "127.0.0.1"

    /// Clamp a buyer-entered port into the valid range; garbage falls back to the default. PURE.
    static func sanitizePort(_ port: Int) -> Int { (1...65535).contains(port) ? port : defaultPort }

    /// The loopback base URL for a port. Host is hardcoded — loopback-only by construction. PURE.
    static func baseURL(port: Int) -> String { "http://\(loopbackHost):\(sanitizePort(port))/v1" }

    private let session: URLSession
    private var currentPort: Int = defaultPort
    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        session = URLSession(configuration: cfg)
    }

    /// Track the currently selected local-server port so tool-loop requests and probes use the
    /// same effective endpoint as chat/completion.
    func setPort(_ port: Int) {
        currentPort = Self.sanitizePort(port)
    }

    // MARK: - Pure helpers (unit-tested without a network call)

    /// Build the POST /v1/chat/completions body from system + prior turns + the user text. PURE.
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
        let dict: [String: Any] = ["model": model, "messages": messages, "stream": stream]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    /// Parse a non-streaming /v1/chat/completions response: choices[0].message.content. PURE.
    /// Falls back to choices[0].text for legacy-completions-shaped servers. nil = no reply
    /// (the caller surfaces an honest error; a nil NEVER becomes fabricated text).
    static func parseChatContent(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { return nil }
        if let msg = first["message"] as? [String: Any], let content = msg["content"] as? String { return content }
        if let text = first["text"] as? String { return text }
        return nil
    }

    /// Surface the server's own error message from an error body. Handles both the OpenAI object
    /// form {"error":{"message":"…"}} and the bare-string form {"error":"…"}. PURE.
    static func parseErrorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        if let err = obj["error"] as? String { return err }
        return nil
    }

    // MARK: - Agent conversion layer (local OpenAI tool loop)

    /// Convert Sovereign's Anthropic-style tool definitions into OpenAI function tools.
    static func openAITools(_ anthropicTools: [[String: Any]]) -> [[String: Any]] {
        anthropicTools.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            var fn: [String: Any] = ["name": name]
            if let d = t["description"] as? String { fn["description"] = d }
            fn["parameters"] = t["input_schema"] ?? ["type": "object", "properties": [:]]
            return ["type": "function", "function": fn]
        }
    }

    /// Convert Anthropic-style loop messages into OpenAI function-calling messages.
    /// user/String and user/assistant blocks are supported; tool_result blocks become role: tool.
    static func openAIMessages(system: String, anthropic: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let sys = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sys.isEmpty { out.append(["role": "system", "content": sys]) }
        var toolNameByID: [String: String] = [:]
        for msg in anthropic {
            guard let blocks = msg["content"] as? [[String: Any]] else { continue }
            for b in blocks where (b["type"] as? String) == "tool_use" {
                if let id = b["id"] as? String, let name = b["name"] as? String { toolNameByID[id] = name }
            }
        }

        for msg in anthropic {
            let role = (msg["role"] as? String) ?? "user"
            if let text = msg["content"] as? String {
                out.append(["role": role, "content": text])
                continue
            }
            guard let blocks = msg["content"] as? [[String: Any]] else { continue }

            if role == "assistant" {
                var contentText = ""
                var calls: [[String: Any]] = []
                for b in blocks {
                    let kind = b["type"] as? String
                    if kind == "text" { contentText += (b["text"] as? String ?? "") }
                    else if kind == "tool_use" {
                        guard let name = b["name"] as? String else { continue }
                        let args = b["input"] as? [String: Any] ?? [:]
                        let data = try? JSONSerialization.data(withJSONObject: args)
                        let argJSON = String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
                        calls.append(["id": b["id"] as? String ?? UUID().uuidString,
                                      "type": "function",
                                      "function": ["name": name, "arguments": argJSON]])
                    }
                }
                var m: [String: Any] = ["role": "assistant", "content": contentText]
                if !calls.isEmpty { m["tool_calls"] = calls }
                out.append(m)
            } else {
                for b in blocks {
                    let kind = b["type"] as? String
                    if kind == "text" {
                        out.append(["role": "user", "content": b["text"] as? String ?? ""])
                    } else if kind == "tool_result" {
                        var m: [String: Any] = [
                            "role": "tool",
                            "tool_call_id": b["tool_use_id"] as? String ?? "",
                            "content": b["content"] as? String ?? ""
                        ]
                        if let id = b["tool_use_id"] as? String, let name = toolNameByID[id] { m["name"] = name }
                        out.append(m)
                    }
                }
            }
        }
        return out
    }

    /// Convert OpenAI function-calling output to Sovereign's internal AgentToolTurn format.
    static func parseToolTurn(_ data: Data) -> AgentToolTurn? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any] else { return nil }
        let text = (msg["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawCalls = msg["tool_calls"] as? [[String: Any]] ?? []
        var calls: [(id: String, name: String, input: [String: Any])] = []
        var blocks: [[String: Any]] = []

        if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
        for (i, raw) in rawCalls.enumerated() {
            guard let fn = raw["function"] as? [String: Any],
                  let name = fn["name"] as? String else { continue }
            let id = (raw["id"] as? String) ?? "openai_call_\(i)"
            var input: [String: Any] = [:]
            if let args = fn["arguments"] as? [String: Any] { input = args }
            else if let argsJSON = fn["arguments"] as? String,
                    let d = argsJSON.data(using: .utf8),
                    let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                input = parsed
            }
            calls.append((id: id, name: name, input: input))
            blocks.append(["type": "tool_use", "id": id, "name": name, "input": input])
        }
        return AgentToolTurn(text: text,
                             toolCalls: calls,
                             assistantContent: blocks.isEmpty ? [["type": "text", "text": ""]] : blocks,
                             stopReason: calls.isEmpty ? "end_turn" : "tool_use")
    }

    /// Probe tool-call support for the selected local model with a strict function-call request.
    func supportsTools(model: String, port: Int) async -> Bool {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, let url = URL(string: "\(Self.baseURL(port: port))/chat/completions") else { return false }
        let probeName = "_sovereign_probe"
        let probeDict: [String: Any] = [
            "name": probeName,
            "description": "Probe tool-calling support.",
            "input_schema": [
                "type": "object",
                "properties": ["probe": ["type": "string"]],
                "required": ["probe"]
            ]
        ]
        let payload: [String: Any] = [
            "model": m,
            "messages": [["role": "user", "content": "Call \\\(probeName) with probe=\"ok\"."]],
            "tools": Self.openAITools([probeDict]),
            "tool_choice": ["type": "function", "function": ["name": probeName]],
            "max_tokens": 128,
            "stream": false
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        do {
            let (data, response) = try await session.data(for: req)
            if (response as? HTTPURLResponse)?.statusCode != 200 { return false }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let msg = first["message"] as? [String: Any],
                  let toolCalls = msg["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty else { return false }
            return true
        } catch {
            return false
        }
    }

    /// Parse GET /v1/models into the list of model ids actually being served. PURE.
    /// Never assumes: an empty/garbage body yields an empty list, not invented models.
    static func parseModels(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            return id
        }
    }

    /// Parse one SSE line from a streaming /v1/chat/completions response. PURE.
    /// Lines look like `data: {"choices":[{"delta":{"content":"He"}}]}` and end with
    /// `data: [DONE]`. Non-data/garbage lines yield ("", false, nil) so the caller skips them.
    static func parseStreamLine(_ line: String) -> (delta: String, done: Bool, error: String?) {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("data:") else { return ("", false, nil) }
        let payload = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return ("", true, nil) }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ("", false, nil) }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return ("", true, msg) }
        if let err = obj["error"] as? String { return ("", true, err) }
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { return ("", false, nil) }
        var delta = ""
        if let d = first["delta"] as? [String: Any], let c = d["content"] as? String { delta = c }
        let done = (first["finish_reason"] as? String).map { !$0.isEmpty } ?? false
        return (delta, done, nil)
    }

    /// Map a transport error to an honest, actionable message (never a fabricated reply). PURE.
    static func describe(error: Error, port: Int) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain &&
            (ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorCannotFindHost
             || ns.code == NSURLErrorNetworkConnectionLost || ns.code == NSURLErrorTimedOut) {
            return "No local server is answering on \(loopbackHost):\(sanitizePort(port)) — start one (llama.cpp: `llama-server -m <model.gguf> --port \(sanitizePort(port))`, or LM Studio → Local Server), then try again."
        }
        return "Couldn't reach the local server at \(baseURL(port: port)): \(error.localizedDescription)"
    }

    /// One tool-use turn through the local OpenAI endpoint, mapped from Sovereign's internal
    /// Anthropic-format loop to OpenAI function calling.
    func toolTurn(model: String, system: String, messages: [[String: Any]],
                  tools: [[String: Any]], maxTokens: Int,
                  timeoutSeconds: TimeInterval,
                  credential: ExternalCredential) async throws -> AgentToolTurn {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else {
            throw Failure(message: "No local-server model selected. Detect and pick one in Settings.")
        }
        let port = currentPort
        guard let url = URL(string: "\(Self.baseURL(port: port))/chat/completions") else {
            throw Failure(message: "Invalid local server port.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if timeoutSeconds > 0 { req.timeoutInterval = timeoutSeconds }
        let payload: [String: Any] = [
            "model": m,
            "messages": Self.openAIMessages(system: system, anthropic: messages),
            "tools": Self.openAITools(tools),
            "tool_choice": "auto",
            "max_tokens": maxTokens,
            "stream": false
        ]
        req.httpBody = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if let msg = Self.parseErrorMessage(data) {
                    throw Failure(message: "Local server error (\(http.statusCode)): \(msg)")
                }
                throw Failure(message: "Local server returned HTTP \(http.statusCode).")
            }
            guard let turn = Self.parseToolTurn(data) else {
                throw Failure(message: "Local server returned an unexpected tool-turn response.")
            }
            return turn
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure(message: Self.describe(error: error, port: port))
        }
    }

    // MARK: - Network (loopback only)

    /// GET /v1/models — what the buyer's server is REALLY serving. Honest error if it's down.
    func listModels(port: Int) async throws -> [String] {
        guard let url = URL(string: "\(Self.baseURL(port: port))/models") else {
            throw Failure(message: "Invalid local server port.")
        }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if let msg = Self.parseErrorMessage(data) {
                    throw Failure(message: "Local server error (\(http.statusCode)): \(msg)")
                }
                throw Failure(message: "Local server returned HTTP \(http.statusCode) from /v1/models.")
            }
            return Self.parseModels(data)
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure(message: Self.describe(error: error, port: port))
        }
    }

    /// One non-streaming completion via POST /v1/chat/completions. Honest error on any failure.
    func complete(model: String, system: String, userText: String,
                  history: [(role: String, text: String)] = [],
                  port: Int) async throws -> String {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else {
            throw Failure(message: "No local-server model selected. Detect and pick one in Settings.")
        }
        guard let url = URL(string: "\(Self.baseURL(port: port))/chat/completions") else {
            throw Failure(message: "Invalid local server port.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.chatBody(model: m, system: system, userText: userText, history: history)
        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if let msg = Self.parseErrorMessage(data) {
                    throw Failure(message: "Local server error (\(http.statusCode)): \(msg)")
                }
                throw Failure(message: "Local server returned HTTP \(http.statusCode).")
            }
            guard let text = Self.parseChatContent(data), !text.isEmpty else {
                throw Failure(message: "The local server returned an empty reply.")
            }
            return text
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure(message: Self.describe(error: error, port: port))
        }
    }

    /// STREAMING completion via POST /v1/chat/completions (stream:true, SSE). `onToken` fires
    /// with cumulative text; resolves with the final text. Honest error on any failure.
    func stream(model: String, system: String, userText: String,
                history: [(role: String, text: String)],
                port: Int,
                onToken: @escaping (String) -> Void) async throws -> String {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else {
            throw Failure(message: "No local-server model selected. Detect and pick one in Settings.")
        }
        guard let url = URL(string: "\(Self.baseURL(port: port))/chat/completions") else {
            throw Failure(message: "Invalid local server port.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.chatBody(model: m, system: system, userText: userText, history: history, stream: true)
        do {
            let (bytes, response) = try await session.bytes(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                var raw = ""
                for try await line in bytes.lines { raw += line }
                if let data = raw.data(using: .utf8), let msg = Self.parseErrorMessage(data) {
                    throw Failure(message: "Local server error (\(http.statusCode)): \(msg)")
                }
                throw Failure(message: "Local server returned HTTP \(http.statusCode).")
            }
            var full = ""
            for try await line in bytes.lines {
                let (delta, done, err) = Self.parseStreamLine(line)
                if let err = err { throw Failure(message: "Local server error: \(err)") }
                if !delta.isEmpty { full += delta; onToken(full) }
                if done { break }   // finish_reason set or the `[DONE]` sentinel — either ends the stream
            }
            return full
        } catch let e as Failure {
            throw e
        } catch {
            throw Failure(message: Self.describe(error: error, port: port))
        }
    }
}
