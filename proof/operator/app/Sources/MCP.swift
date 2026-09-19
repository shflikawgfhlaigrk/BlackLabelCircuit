// Sovereign — MODEL CONTEXT PROTOCOL (MCP) client. The named Tier-3 "Integrations via MCP"
// capability + the headline differentiator of External-desktop / Raycast: the buyer points the
// operator at their OWN MCP servers and it gains real, discoverable tools.
//
// TRANSPORT — Streamable HTTP, deliberately. The Mac App Store build is app-sandboxed
// (app.entitlements: "no subprocess spawn, no raw sockets"), so the stdio transport (which
// forks a server subprocess) is architecturally impossible here. The remote MCP transport is
// JSON-RPC 2.0 over HTTPS, which the app's existing `com.apple.security.network.client`
// entitlement already covers — the same one Brain/Weather/WebFetch use. No new entitlement.
//
// HONESTY (CHARTER §5.1 / §5.2):
//   • Ships EMPTY. No server is bundled. The config file only exists once the BUYER adds one;
//     with no config the UI shows a true empty state, never a fabricated tool.
//   • Tool lists + tool outputs are the REAL bytes the buyer's server returned, or an honest
//     error. Nothing is narrated. Every invocation writes one real proof-of-execution receipt.
//   • The buyer's server config + any auth header live only in their app-support container.
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

// MARK: - Config model (the buyer's OWN servers — ships empty)

/// One MCP server the buyer configured. `url` is their server's Streamable-HTTP endpoint; an
/// optional `authHeader`/`authValue` carries a bearer token or API key THEY supply (never bundled).
struct MCPServerConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String                 // buyer's label for the server
    var url: String                  // https endpoint (JSON-RPC 2.0 / Streamable HTTP)
    var authHeader: String = ""      // optional, e.g. "Authorization"
    var authValue: String = ""       // optional, e.g. "Bearer sk-..." — the buyer's own secret (manual
                                     // path). For a MANAGED catalog connector this holds only the
                                     // NON-secret prefix (e.g. "Bearer "); the bare token lives in the
                                     // private store (ConnectorSecrets) and is composed at call time.

    /// Catalog connector id when this row was created from ConnectorCatalog (nil = a manual,
    /// buyer-entered server). Lets the connector gallery find / refresh / disconnect a managed connector.
    var connectorID: String? = nil
    /// Private-store account (in ConnectorSecrets) holding this connector's bare token, when the secret is
    /// MANAGED (catalog connectors). nil = the secret, if any, lives inline in `authValue` (manual
    /// path). The raw token is NEVER persisted in this row — only this reference + the non-secret prefix.
    var secretRef: String? = nil

    /// The request headers this server needs (only adds the auth pair when the buyer set both). For a
    /// manual server this is the full picture; managed catalog connectors resolve their secret in
    /// `resolvedHeaders()` instead (the token isn't in this struct).
    var headers: [String: String] {
        let h = authHeader.trimmingCharacters(in: .whitespaces)
        let v = authValue.trimmingCharacters(in: .whitespaces)
        return (!h.isEmpty && !v.isEmpty) ? [h: v] : [:]
    }

    /// The headers used at CALL TIME. For a MANAGED (catalog) connector the bare token is read from the
    /// private store (ConnectorSecrets, keyed by `secretRef`) and composed with the non-secret `authValue`
    /// prefix — the secret is never persisted in mcp.json. For a manual server this is identical to
    /// `headers`. If a managed connector has no stored token, returns NO auth header: an honest
    /// unauthenticated request the server rejects with a real error, never a fabricated success.
    func resolvedHeaders() -> [String: String] {
        guard let ref = secretRef else { return headers }
        let h = authHeader.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, let token = ConnectorSecrets.token(forAccount: ref), !token.isEmpty else { return [:] }
        return [h: authValue + token]
    }

    /// Only http/https with a real host. (localhost IS allowed here — unlike the agent's
    /// SSRF-guarded fetch_url — because a buyer's MCP server commonly runs locally on a port,
    /// and the buyer is explicitly naming it, not the model.)
    var isValidURL: Bool {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty else { return false }
        return true
    }

    /// A MANUAL (non-catalog) server that still carries its secret INLINE in `authValue` — the
    /// plaintext-in-mcp.json case that must be migrated into the private store. Catalog connectors already
    /// keep their token there (secretRef set), so they never match. PURE.
    var hasInlineSecret: Bool {
        connectorID == nil && secretRef == nil &&
        !authValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The private-store account (in ConnectorSecrets) a migrated manual server's token is stored under.
    /// Keyed by the row's stable id and namespaced so it can't collide with a catalog connector id. PURE.
    var manualSecretAccount: String { "manual-\(id.uuidString)" }

    /// True when a token may safely traverse this server's transport: https, or a loopback/localhost
    /// host where http never leaves the machine. A REMOTE http:// server with a bearer would send the
    /// secret in plaintext — flagged (not silently accepted) at add/migrate time. PURE.
    var tokenTransportIsSecure: Bool {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = u.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        let host = (u.host ?? "").lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }
}

/// One tool a server advertised. The schema is the server's real `inputSchema`; we keep a
/// human param summary for the UI but never invent a tool that wasn't returned.
struct MCPTool: Identifiable, Hashable {
    var id: String { server + "::" + name }
    let server: String
    let name: String
    let desc: String
    let paramNames: [String]         // top-level inputSchema.properties keys (for a UI hint)
    let requiredParams: [String]
    var paramTypes: [String: String] = [:]   // param name -> JSON-schema type (integer/number/boolean/array/object/string)
}

/// Persisted set of the buyer's MCP servers. Stored as JSON in the app-support container, on the
/// buyer's machine only. Absent file = no servers = honest empty state (the ship-no-data default).
struct MCPConfigStore {
    static func fileURL(filename: String = "mcp.json") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sovereign", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(filename)
    }

    static func load(from url: URL = fileURL()) -> [MCPServerConfig] {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else { return [] }
        return rows
    }

    @discardableResult
    static func save(_ servers: [MCPServerConfig], to url: URL = fileURL()) -> Bool {
        // WRITE-BOUNDARY GUARANTEE: never persist a bearer/secret inline. Any manual row still holding an
        // inline token has it moved to ConnectorSecrets here, and only its secretRef + the
        // non-secret header name is written to mcp.json. This is the last line of defense so no code path
        // — the manager, the CLI connector harness, or a re-save of a legacy file — can leak a token to
        // disk. Catalog rows and secret-less rows pass through untouched.
        var migrationFailed = false
        let sanitized = servers.map { row -> MCPServerConfig in
            guard row.hasInlineSecret else { return row }
            var out = row
            let token = row.authValue.trimmingCharacters(in: .whitespaces)
            guard ConnectorSecrets.store(account: row.manualSecretAccount, token: token),
                  ConnectorSecrets.token(forAccount: row.manualSecretAccount) == token else {
                migrationFailed = true
                return row
            }
            out.secretRef = row.manualSecretAccount
            out.authValue = ""
            return out
        }
        // Never spill an inline token to disk and never truncate the previous config when securing
        // the token failed. The in-memory caller still owns the original bytes and can retry.
        guard !migrationFailed, let data = try? JSONEncoder().encode(sanitized) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Parse the External-desktop-style `{ "mcpServers": { "<name>": { "url": "...", "headers": {...} } } }`
    /// shape, so a buyer can paste an existing remote-server config. Pure → testable. Only the
    /// HTTP-transport entries (those with a `url`) are importable; stdio entries (a `command`) are
    /// skipped honestly, because this sandboxed build cannot spawn a subprocess.
    static func parseExternalDesktopFormat(_ json: Data) -> [MCPServerConfig] {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return [] }
        var out: [MCPServerConfig] = []
        for (name, raw) in servers {
            guard let entry = raw as? [String: Any], let url = entry["url"] as? String, !url.isEmpty else { continue }
            var cfg = MCPServerConfig(name: name, url: url)
            if let headers = entry["headers"] as? [String: String], let first = headers.first {
                cfg.authHeader = first.key; cfg.authValue = first.value
            }
            if cfg.isValidURL { out.append(cfg) }
        }
        return out.sorted { $0.name < $1.name }
    }
}

// MARK: - JSON-RPC 2.0 over Streamable HTTP (pure helpers are unit-tested)

enum MCPError: Error, LocalizedError {
    case badURL
    case transport(String)
    case http(Int)
    case rpc(code: Int, message: String)
    case decode(String)
    var errorDescription: String? {
        switch self {
        case .badURL:                 return "That isn't a valid http/https URL."
        case .transport(let m):       return "Couldn't reach the server: \(m)"
        case .http(let c):            return "The server returned HTTP \(c)."
        case .rpc(let code, let m):   return "The server rejected the request (\(code)): \(m)"
        case .decode(let m):          return "Couldn't read the server's reply: \(m)"
        }
    }
}

/// Pure JSON-RPC framing + parsing. No I/O here, so it is exercised directly in LogicTests.
enum MCPRPC {
    static let protocolVersion = "2025-03-26"

    /// Build a single JSON-RPC 2.0 request body.
    static func requestBody(id: Int, method: String, params: [String: Any]) -> Data {
        var obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { obj["params"] = params }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    /// Build the `notifications/initialized` notification (no id → no response expected).
    static func initializedNotification() -> Data {
        let obj: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    static func initializeParams(clientName: String, clientVersion: String) -> [String: Any] {
        ["protocolVersion": protocolVersion,
         "capabilities": [:],
         "clientInfo": ["name": clientName, "version": clientVersion]]
    }

    /// A Streamable-HTTP response is either a JSON body or an SSE stream whose `data:` lines each
    /// carry a JSON-RPC message. Extract every JSON-RPC object from the raw body, regardless of
    /// framing. Pure → testable.
    static func jsonRPCObjects(body: Data, contentType: String) -> [[String: Any]] {
        let ct = contentType.lowercased()
        let text = String(data: body, encoding: .utf8) ?? ""
        if ct.contains("text/event-stream") || text.hasPrefix("event:") || text.contains("\ndata:") || text.hasPrefix("data:") {
            // SSE: collect the JSON payload of each `data:` line.
            var objs: [[String: Any]] = []
            for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                if let d = payload.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { objs.append(o) }
            }
            return objs
        }
        // Plain JSON: a single object, or a batch array.
        if let o = try? JSONSerialization.jsonObject(with: body) {
            if let one = o as? [String: Any] { return [one] }
            if let arr = o as? [[String: Any]] { return arr }
        }
        return []
    }

    /// Pull the `result` object for our request id out of a response body, or throw an honest error
    /// if the server returned a JSON-RPC `error` (or nothing parseable). Pure → testable.
    static func result(body: Data, contentType: String, id: Int) throws -> [String: Any] {
        let objs = jsonRPCObjects(body: body, contentType: contentType)
        guard !objs.isEmpty else { throw MCPError.decode("empty or non-JSON response") }
        // Prefer the object whose id matches our request; fall back to the first that has a result/error.
        let match = objs.first { ($0["id"] as? Int) == id } ?? objs.first { $0["result"] != nil || $0["error"] != nil }
        guard let obj = match else { throw MCPError.decode("no matching JSON-RPC response") }
        if let err = obj["error"] as? [String: Any] {
            let code = (err["code"] as? Int) ?? -1
            let msg = (err["message"] as? String) ?? "unknown error"
            throw MCPError.rpc(code: code, message: msg)
        }
        guard let result = obj["result"] as? [String: Any] else {
            throw MCPError.decode("response had no result")
        }
        return result
    }

    /// Map a `tools/list` result into typed tools. Pure → testable.
    static func tools(from result: [String: Any], server: String) -> [MCPTool] {
        guard let arr = result["tools"] as? [[String: Any]] else { return [] }
        return arr.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let desc = (t["description"] as? String) ?? ""
            let schema = t["inputSchema"] as? [String: Any]
            let propsDict = (schema?["properties"] as? [String: Any]) ?? [:]
            let props = propsDict.keys.sorted()
            let required = (schema?["required"] as? [String]) ?? []
            // Capture each property's JSON-schema type so the UI can send the buyer's value as the
            // right JSON type, not always a string (a strict server rejects "5" where it wants 5).
            var types: [String: String] = [:]
            for key in props {
                guard let pv = propsDict[key] as? [String: Any] else { continue }
                if let ty = pv["type"] as? String { types[key] = ty }
                else if let tyArr = pv["type"] as? [String],
                        let first = tyArr.first(where: { $0.lowercased() != "null" }) { types[key] = first }
            }
            return MCPTool(server: server, name: name, desc: desc, paramNames: props, requiredParams: required, paramTypes: types)
        }
    }

    /// Coerce a buyer's free-text field value into the JSON type the tool's `inputSchema` declared,
    /// so a strict server doesn't reject `"5"` where it required the number `5` (or `"true"` for a
    /// boolean). Anything un-parseable or string-typed passes through unchanged — we never silently
    /// corrupt a value; we let the server return its real validation error. Pure → testable.
    static func coerceArgument(_ raw: String, schemaType: String?) -> Any {
        switch (schemaType ?? "string").lowercased() {
        case "integer":
            return Int(raw) ?? raw
        case "number":
            return Double(raw) ?? raw
        case "boolean":
            switch raw.lowercased() {
            case "true", "yes", "1":  return true
            case "false", "no", "0":  return false
            default:                  return raw
            }
        case "array", "object":
            if let d = raw.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: d) { return j }
            return raw
        default:
            return raw   // string / unknown -> leave as typed
        }
    }

    /// Flatten a `tools/call` result's `content` blocks into readable text (the real tool output),
    /// honoring the `isError` flag. Pure → testable.
    static func callText(from result: [String: Any]) -> (text: String, isError: Bool) {
        let isError = (result["isError"] as? Bool) ?? false
        guard let content = result["content"] as? [[String: Any]] else {
            // Some servers return structured-only content; surface it rather than pretend it's empty.
            if let sc = result["structuredContent"], let d = try? JSONSerialization.data(withJSONObject: sc),
               let s = String(data: d, encoding: .utf8) { return (s, isError) }
            return ("(the tool returned no text content)", isError)
        }
        let parts: [String] = content.compactMap { block in
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "resource":
                if let r = block["resource"] as? [String: Any], let t = r["text"] as? String { return t }
                return "(resource)"
            case "image": return "(image content)"
            default:
                if let t = block["text"] as? String { return t }
                return nil
            }
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? "(the tool returned no text content)" : text, isError)
    }
}

// MARK: - The live client (the only part that does I/O)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Drives one buyer-configured server over Streamable HTTP. Each high-level operation runs a
/// fresh `initialize` handshake (stateless-safe), captures the optional `Mcp-Session-Id`, sends
/// the `initialized` notification, then performs the operation. No background polling, no server.
struct MCPClient {
    let config: MCPServerConfig
    var clientName: String = "Black Label Sovereign"
    var clientVersion: String = "1.1"
    var timeout: TimeInterval = 25

    private func post(body: Data, sessionId: String?, allowRefresh: Bool = true) async throws -> (Data, String, String?) {
        guard config.isValidURL, let url = URL(string: config.url.trimmingCharacters(in: .whitespaces)) else {
            throw MCPError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("\(clientName)/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        if let sid = sessionId { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        // resolvedHeaders() composes a managed connector's private token at call time (and is identical
        // to `headers` for a manual server) — the secret is never read from the persisted config.
        for (k, v) in config.resolvedHeaders() { req.setValue(v, forHTTPHeaderField: k) }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession(configuration: cfg).data(for: req)
        } catch {
            throw MCPError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MCPError.transport("no HTTP response") }
        // Auto-refresh-on-401 for a managed OAuth connector: the access token expired. Renew it once via
        // the stored refresh token, then retry exactly ONCE with rebuilt headers (resolvedHeaders() now
        // reads the fresh private-store token). If refresh can't help (no refresh token / token connector),
        // fall through to the honest HTTP 401. Guard (allowRefresh) prevents an infinite retry loop.
        if http.statusCode == 401, allowRefresh, let connectorID = config.connectorID {
            if await OAuthConnector.shared.refresh(connectorID: connectorID) {
                return try await post(body: body, sessionId: sessionId, allowRefresh: false)
            }
        }
        // 202 Accepted (notifications) carries no body and is fine.
        if !(200...299).contains(http.statusCode) { throw MCPError.http(http.statusCode) }
        let ct = (http.value(forHTTPHeaderField: "Content-Type")) ?? "application/json"
        let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        return (data, ct, sid)
    }

    /// initialize → capture session → initialized notification. Returns the session id (if any).
    private func handshake() async throws -> String? {
        let body = MCPRPC.requestBody(id: 1, method: "initialize",
                                      params: MCPRPC.initializeParams(clientName: clientName, clientVersion: clientVersion))
        let (data, ct, sid) = try await post(body: body, sessionId: nil)
        _ = try MCPRPC.result(body: data, contentType: ct, id: 1)   // validates handshake / surfaces rpc error
        // Best-effort initialized notification (a 2xx/202 with no body is expected; ignore failure).
        _ = try? await post(body: MCPRPC.initializedNotification(), sessionId: sid)
        return sid
    }

    /// Discover the server's real tools.
    func listTools() async throws -> [MCPTool] {
        let sid = try await handshake()
        let body = MCPRPC.requestBody(id: 2, method: "tools/list", params: [:])
        let (data, ct, _) = try await post(body: body, sessionId: sid)
        let result = try MCPRPC.result(body: data, contentType: ct, id: 2)
        return MCPRPC.tools(from: result, server: config.name)
    }

    /// Invoke one real tool with the buyer's arguments. Returns (text, isError) — the real bytes.
    func callTool(_ name: String, arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        let sid = try await handshake()
        let body = MCPRPC.requestBody(id: 3, method: "tools/call",
                                      params: ["name": name, "arguments": arguments])
        let (data, ct, _) = try await post(body: body, sessionId: sid)
        let result = try MCPRPC.result(body: data, contentType: ct, id: 3)
        return MCPRPC.callText(from: result)
    }
}
#endif // circuit-convert

// MARK: - Manager (ObservableObject the UI + agent read; writes real receipts)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class MCPManager: ObservableObject {
    @Published private(set) var servers: [MCPServerConfig] = []
    /// Discovered tools per server name. Only populated by a real `tools/list` round-trip.
    @Published private(set) var toolsByServer: [String: [MCPTool]] = [:]
    /// Per-server live status, for honest UI (never "connected" unless a handshake actually succeeded).
    @Published private(set) var status: [UUID: ServerStatus] = [:]

    /// Connector receipts (a discover/invoke happened) write here — same ledger as every other tool.
    weak var activity: ActivityLog?

    private var demoEphemeral = false
    private let configURL: URL

    enum ServerStatus: Equatable {
        case idle, connecting, connected(toolCount: Int), failed(String)
    }

    init(configURL: URL = MCPConfigStore.fileURL()) {
        self.configURL = configURL
        servers = MCPConfigStore.load(from: configURL)
    }

    /// Move a MANUAL server's INLINE secret into ConnectorSecrets, returning a row that
    /// carries only a `secretRef` + the (non-secret) header name — never the bare token. Catalog rows and
    /// secret-less rows pass through unchanged. Mirrors how a catalog connector stores its token; a token
    /// over an insecure (remote http) transport is still stored securely but flagged with a receipt.
    private func migratedForStorage(_ s: MCPServerConfig) -> MCPServerConfig {
        guard s.hasInlineSecret else { return s }
        var out = s
        let token = s.authValue.trimmingCharacters(in: .whitespaces)
        guard ConnectorSecrets.store(account: s.manualSecretAccount, token: token),
              ConnectorSecrets.token(forAccount: s.manualSecretAccount) == token else { return s }
        out.secretRef = s.manualSecretAccount
        out.authValue = ""
        if !s.tokenTransportIsSecure {
            activity?.record(kind: .connector, title: "MCP · \(s.name) · token secured (http transport)",
                             detail: "The token for \(s.name) is kept in Sovereign's private credential store, never in mcp.json — but this server uses http://, so the token will be sent unencrypted. Use an https endpoint for a remote server.",
                             outcome: .info)
        }
        return out
    }

    var isEmpty: Bool { servers.isEmpty }
    var allTools: [MCPTool] { servers.flatMap { toolsByServer[$0.name] ?? [] } }
    var totalToolCount: Int { allTools.count }

    func status(for s: MCPServerConfig) -> ServerStatus { status[s.id] ?? .idle }
    func tools(for s: MCPServerConfig) -> [MCPTool] { toolsByServer[s.name] ?? [] }

    @discardableResult
    private func persist() -> Bool {
        guard !demoEphemeral else { return true }
        return MCPConfigStore.save(servers, to: configURL)
    }

    // MARK: Buyer edits

    func addServer(_ s: MCPServerConfig) {
        // Migrate any inline secret to ConnectorSecrets BEFORE the row enters memory or disk, so the token
        // never lives in `servers` (or mcp.json) as plaintext — mirrors the catalog-connector path.
        servers.append(migratedForStorage(s)); persist()
    }
    func removeServer(_ s: MCPServerConfig) {
        servers.removeAll { $0.id == s.id }
        toolsByServer[s.name] = nil
        status[s.id] = nil
        // A migrated MANUAL server keeps its token under manualSecretAccount — remove it
        // too so "remove" never orphans a secret. (Catalog tokens are cleared by disconnectCatalog.)
        if s.connectorID == nil { ConnectorSecrets.delete(account: s.manualSecretAccount) }
        persist()
    }

    // MARK: Live operations

    /// Discover one server's tools via a real handshake + tools/list. Updates status honestly and
    /// records a `.connector` receipt for the discovery (success = N tools, failure = the real error).
    func discover(_ s: MCPServerConfig) async {
        status[s.id] = .connecting
        let started = Date()
        do {
            let tools = try await MCPClient(config: s).listTools()
            toolsByServer[s.name] = tools
            status[s.id] = .connected(toolCount: tools.count)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let names = tools.map { $0.name }.joined(separator: ", ")
            activity?.record(kind: .connector, title: "MCP · \(s.name) · discovered \(tools.count) tool\(tools.count == 1 ? "" : "s")",
                             detail: tools.isEmpty ? "The server connected but advertised no tools." : "Tools: \(names)",
                             outcome: tools.isEmpty ? .info : .success, durationMS: ms)
        } catch {
            let msg = (error as? MCPError)?.errorDescription ?? error.localizedDescription
            status[s.id] = .failed(msg)
            toolsByServer[s.name] = nil
            activity?.record(kind: .connector, title: "MCP · \(s.name) · connection failed",
                             detail: msg, outcome: .failure)
        }
    }

    func discoverAll() async {
        for s in servers { await discover(s) }
    }

    // MARK: Catalog connectors (one-click managed integrations — token private, never mcp.json)

    /// The buyer's manual servers only (the connector gallery owns the managed/catalog rows separately).
    var manualServers: [MCPServerConfig] { servers.filter { $0.connectorID == nil } }

    /// The live config row for a catalog connector (present once the buyer has connected it).
    func connectorServer(id: String) -> MCPServerConfig? { servers.first { $0.connectorID == id } }
    func isConnectorConnected(id: String) -> Bool { connectorServer(id: id) != nil }
    func connectorStatus(id: String) -> ServerStatus {
        guard let s = connectorServer(id: id) else { return .idle }
        return status(for: s)
    }

    /// Connect a catalog connector with the buyer's OWN token. Stores the token in ConnectorSecrets
    /// (ConnectorSecrets), persists ONLY the non-secret config row (connectorID + secretRef + prefix),
    /// then runs a REAL discover (handshake + tools/list). Status is driven by that round-trip — never
    /// "connected" on faith. An invalid token yields a real `.failed`, never a fabricated success.
    func connectCatalog(_ entry: ConnectorEntry, token: String) async {
        guard let cfg = entry.makeServerConfig() else { return }
        guard ConnectorSecrets.store(account: entry.id, token: token),
              ConnectorSecrets.token(forAccount: entry.id) == token.trimmingCharacters(in: .whitespacesAndNewlines) else {
            status[cfg.id] = .failed("Sovereign could not save this token in its private credential store.")
            return
        }
        servers.removeAll { $0.connectorID == entry.id }
        toolsByServer[cfg.name] = nil
        servers.append(cfg)
        persist()
        await discover(cfg)
    }

    /// Re-discover catalog connectors not yet dialed this session (e.g. after relaunch), so the gallery
    /// shows live status. Skips already connecting/connected rows and never touches manual servers.
    func refreshConnectors() async {
        for s in servers where s.connectorID != nil {
            if case .idle = status(for: s) { await discover(s) }
        }
    }

    /// Disconnect a catalog connector: remove its config row, its private token(s), and — for an OAuth
    /// connector — the refresh sidecar + the non-secret client state (client_id / token endpoint).
    func disconnectCatalog(_ entry: ConnectorEntry) {
        if let s = connectorServer(id: entry.id) { removeServer(s) }
        OAuthTokenStore.delete(connectorID: entry.id)   // access (`<id>`) + refresh sidecar (`<id>.oauth`)
        OAuthClientStore.clear(entry.id)                // non-secret client_id + token endpoint
    }

    /// Buyer-triggered recovery from a pre-file-store build. This is the only connector path that
    /// reads Security.framework, and it is never called by init/refresh/status/timers.
    @discardableResult
    func recoverLegacyCredential(for entry: ConnectorEntry) async -> SovereignLegacyRecoveryResult {
        let access = ConnectorSecrets.recoverLegacy(account: entry.id)
        if entry.authKind == .oauth2 {
            _ = ConnectorSecrets.recoverLegacy(account: OAuthTokenStore.sidecarAccount(entry.id))
        }
        if access == .recovered, let server = connectorServer(id: entry.id) {
            await discover(server)
        }
        return access
    }

    /// Invoke a discovered tool with the buyer's arguments. Returns the REAL output text (or throws),
    /// and writes one real proof-of-execution receipt either way. This is the genuine "integration
    /// via MCP" — the buyer's own server doing real work, logged like every other action.
    @discardableResult
    func callTool(server: MCPServerConfig, tool: String, arguments: [String: Any],
                  recordReceipt: Bool = true) async -> (text: String, isError: Bool)? {
        let started = Date()
        do {
            let (text, isError) = try await MCPClient(config: server).callTool(tool, arguments: arguments)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if recordReceipt {
                activity?.record(kind: .connector, title: "MCP · \(server.name) · \(tool)",
                                 detail: text, outcome: isError ? .failure : .success, durationMS: ms)
            }
            return (text, isError)
        } catch {
            let msg = (error as? MCPError)?.errorDescription ?? error.localizedDescription
            if recordReceipt {
                activity?.record(kind: .connector, title: "MCP · \(server.name) · \(tool) failed",
                                 detail: msg, outcome: .failure)
            }
            return nil
        }
    }

    /// Resolve a server by the name the agent carries (`MCPTool.server`) and invoke a tool on it.
    /// The AgentEngine uses this — it writes its OWN per-step proof-of-execution receipt for the
    /// call, so `recordReceipt` defaults to false here to avoid a duplicate connector entry. A
    /// server the buyer has since removed resolves to nil (the agent surfaces an honest miss).
    @discardableResult
    func callTool(serverName: String, tool: String, arguments: [String: Any],
                  recordReceipt: Bool = false) async -> (text: String, isError: Bool)? {
        guard let server = servers.first(where: { $0.name == serverName }) else { return nil }
        return await callTool(server: server, tool: tool, arguments: arguments, recordReceipt: recordReceipt)
    }

    // MARK: Demo + wipe (parity with every other store — ship-no-data)

    /// Demo Mode: show a couple of clearly-labeled SAMPLE servers in memory only. Never persisted,
    /// never connected (no network in demo) — status stays idle so nothing is faked as "connected".
    func seedDemo() {
        demoEphemeral = true
        servers = DemoSeed.mcpServers
        toolsByServer = DemoSeed.mcpTools
        status = [:]
    }
    func endDemo() {
        demoEphemeral = false
        servers = MCPConfigStore.load(from: configURL)
        toolsByServer = [:]
        status = [:]
    }
    /// Delete-all (App Store 5.1.1(v)): drop every configured server, every catalog-connector token in
    /// the private credential store, and the on-disk config file.
    func wipeAll() {
        demoEphemeral = false
        let configuredAccounts = servers.compactMap(\.secretRef).flatMap { [$0, "\($0).oauth"] }
        servers = []; toolsByServer = [:]; status = [:]
        ConnectorSecrets.wipeAll(additionalAccounts: configuredAccounts)
        OAuthClientStore.wipeAll()      // non-secret OAuth client_ids + token endpoints (UserDefaults)
        try? FileManager.default.removeItem(at: configURL)
    }
}
#endif // circuit-convert


// MARK: - Agent bridge — expose the buyer's discovered MCP tools to the multi-step AgentEngine

/// Turns the buyer's REAL discovered `MCPTool`s into Anthropic tool-use definitions the agent's
/// External loop can call, and maps the model-facing tool name back to (server, tool) for dispatch.
/// Pure + static → unit-tested with NO network. Nothing here invents a tool: every def is built
/// from a tool the buyer's own server actually advertised. This is what makes "Integrations via
/// MCP" a real agent capability (the operator gains the buyer's tools), not just a manual runner.
enum MCPAgentBridge {
    /// Marks a model-facing tool name as an MCP connector call, so the agent's dispatch can route it.
    static let prefix = "mcp__"

    /// Anthropic tool names must match `^[a-zA-Z0-9_-]{1,64}$`. MCP tools are "server::tool" and a
    /// server label is free buyer text, so sanitize both halves to that charset, prefix, and bound
    /// to 64. `existing` guarantees uniqueness after sanitize/truncate (two distinct tools never
    /// collapse onto one model-facing name — the later one gets the smallest free numeric suffix).
    /// Pure → testable.
    static func safeName(server: String, tool: String, existing: Set<String>) -> String {
        func clean(_ s: String) -> String {
            String(String.UnicodeScalarView(s.unicodeScalars.map { sc in
                let ok = (sc >= "a" && sc <= "z") || (sc >= "A" && sc <= "Z") ||
                         (sc >= "0" && sc <= "9") || sc == "_" || sc == "-"
                return ok ? sc : Unicode.Scalar("_")
            }))
        }
        var base = prefix + clean(server) + "__" + clean(tool)
        if base.count > 64 { base = String(base.prefix(64)) }
        guard existing.contains(base) else { return base }
        var i = 2
        while true {
            let suffix = "_\(i)"
            let candidate = String(base.prefix(64 - suffix.count)) + suffix
            if !existing.contains(candidate) { return candidate }
            i += 1
        }
    }

    /// Reconstruct a valid JSON-Schema `input_schema` from the metadata captured at discovery
    /// (`paramNames`/`paramTypes`/`requiredParams`). Honest: only the params the server declared,
    /// typed as it declared them, never an invented field. Pure → testable.
    static func inputSchema(for tool: MCPTool) -> [String: Any] {
        var props: [String: Any] = [:]
        for name in tool.paramNames { props[name] = ["type": tool.paramTypes[name] ?? "string"] }
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !tool.requiredParams.isEmpty { schema["required"] = tool.requiredParams }
        return schema
    }

    /// Build the Anthropic tool defs + the dispatch routes for a set of discovered tools. Returns
    /// (defs sent to External, routes: model-facing-name -> (server, tool)). Pure → testable.
    static func build(from tools: [MCPTool]) -> (defs: [[String: Any]],
                                                 routes: [String: (server: String, tool: String)]) {
        var defs: [[String: Any]] = []
        var routes: [String: (server: String, tool: String)] = [:]
        var used = Set<String>()
        for t in tools {
            let name = safeName(server: t.server, tool: t.name, existing: used)
            used.insert(name)
            routes[name] = (server: t.server, tool: t.name)
            let desc = t.desc.isEmpty
                ? "Tool \u{201C}\(t.name)\u{201D} from your connected MCP server \u{201C}\(t.server)\u{201D}."
                : "\(t.desc) (via your MCP server \u{201C}\(t.server)\u{201D}.)"
            defs.append(["name": name, "description": desc, "input_schema": inputSchema(for: t)])
        }
        return (defs, routes)
    }
}
