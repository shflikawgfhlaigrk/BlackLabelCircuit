// Sovereign — the daemon-backed TOOL BUS the chat brain calls through.
//
// The native app owns the chat brain (on-device / Ornith-Ollama / local server); the
// Python daemon (com.sovereign.daemon, loopback :8765) owns the real host tools —
// the desktop, the vision analyzer, the web, devices, the filesystem, the shell.
// This client is the single seam between them. Every call hits 127.0.0.1 only
// (the app's network.client entitlement permits localhost), returns a structured
// result or an ACTIONABLE error, and NEVER fabricates.
//
// Load-bearing: this is what removes the "switch to a vision-capable brain" dead
// end. When the active brain can't see an image, the app captures the desktop and
// routes the PNG here (`analyzeDesktop`) — the daemon reads it with Apple Vision +
// the window graph and returns observations the text brain reasons over.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An actionable tool failure — carries a human message the UI shows verbatim
/// (never a dead-end; always says what to do). Conforms to Error so it flows
/// through Swift's Result type; ExpressibleByString* so a message literal (even
/// with interpolation) can be returned directly as `.failure("…")`.
struct ToolError: Error, LocalizedError, CustomStringConvertible,
                   ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let message: String
    init(message: String) { self.message = message }
    init(stringLiteral value: String) { self.message = value }
    init(stringInterpolation: StringInterpolation) { self.message = stringInterpolation.text }
    var errorDescription: String? { message }
    var description: String { message }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ literal: String) { text += literal }
        mutating func appendInterpolation<T>(_ value: T) { text += String(describing: value) }
    }
}

// MARK: - Structured results

/// Structured desktop observations from the daemon's on-device vision analyzer
/// (Quartz window graph + Apple Vision OCR). Mirrors sovereign/desktop/vision.py.
struct DesktopObservations: Decodable {
    struct Window: Decodable { let app: String?; let title: String?; let frontmost: Bool? }
    struct ActiveWindow: Decodable { let app: String?; let title: String? }
    struct Control: Decodable { let label: String; let kind: String? }

    let ok: Bool
    let path: String?
    let visibleApps: [String]
    let windows: [Window]
    let activeWindow: ActiveWindow?
    let textSeen: [String]
    let actionableControls: [Control]
    let likelyUserTask: String?
    let confidence: Double?
    let ocrSource: String?
    let windowSource: String?
    let notes: [String]
    let reason: String?   // present when ok == false

    enum CodingKeys: String, CodingKey {
        case ok, path, reason, notes, windows, confidence
        case visibleApps = "visible_apps"
        case activeWindow = "active_window"
        case textSeen = "text_seen"
        case actionableControls = "actionable_controls"
        case likelyUserTask = "likely_user_task"
        case ocrSource = "ocr_source"
        case windowSource = "window_source"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        path = try? c.decodeIfPresent(String.self, forKey: .path)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        visibleApps = (try? c.decode([String].self, forKey: .visibleApps)) ?? []
        windows = (try? c.decode([Window].self, forKey: .windows)) ?? []
        activeWindow = try? c.decodeIfPresent(ActiveWindow.self, forKey: .activeWindow)
        textSeen = (try? c.decode([String].self, forKey: .textSeen)) ?? []
        actionableControls = (try? c.decode([Control].self, forKey: .actionableControls)) ?? []
        likelyUserTask = try? c.decodeIfPresent(String.self, forKey: .likelyUserTask)
        confidence = try? c.decodeIfPresent(Double.self, forKey: .confidence)
        ocrSource = try? c.decodeIfPresent(String.self, forKey: .ocrSource)
        windowSource = try? c.decodeIfPresent(String.self, forKey: .windowSource)
        notes = (try? c.decode([String].self, forKey: .notes)) ?? []
    }

    /// The plain-observations grounding block a text-only brain reads INSTEAD of the
    /// raw image. Every line is real signal (window graph / OCR) or an honest
    /// "not available" note — never an instruction to fabricate.
    var promptBlock: String {
        var lines: [String] = ["DESKTOP VISION OBSERVATIONS (captured + analyzed on-device just now):"]
        if !visibleApps.isEmpty {
            lines.append("- Visible apps: " + visibleApps.prefix(12).joined(separator: ", "))
        }
        if let aw = activeWindow, let app = aw.app, !app.isEmpty {
            let t = (aw.title?.isEmpty == false) ? " — \"\(aw.title!)\"" : ""
            lines.append("- Active window: \(app)\(t)")
        }
        if !windows.isEmpty {
            lines.append("- Open windows (\(windows.count)):")
            for w in windows.prefix(10) {
                let app = w.app ?? "?"
                let t = (w.title?.isEmpty == false) ? " — \"\(w.title!)\"" : ""
                lines.append("    • \(app)\(t)")
            }
        }
        if !actionableControls.isEmpty {
            lines.append("- Likely controls on screen: "
                + actionableControls.prefix(12).map { $0.label }.joined(separator: ", "))
        }
        if !textSeen.isEmpty {
            var joined = textSeen.prefix(60).joined(separator: " | ")
            if joined.count > 1800 { joined = String(joined.prefix(1800)) + " …" }
            lines.append("- Text read on screen (OCR): \(joined)")
        } else if let src = ocrSource, src.hasPrefix("unavailable") {
            lines.append("- On-screen text: not available (\(src))")
        }
        lines.append("- Best guess at task: \(likelyUserTask ?? "unclear")")
        lines.append("- Analysis confidence: \(confidence ?? 0)")
        return lines.joined(separator: "\n")
    }
}

/// One web result (title + real URL + snippet). Never fabricated.
struct WebResult: Decodable, Identifiable {
    let title: String
    let url: String
    let snippet: String?
    var id: String { url }
}

/// One fetched page's readable text (real URL + title + extracted body) from the daemon's keyless
/// `url_context` tool. Never fabricated — an unreadable page surfaces an honest error instead.
struct URLContext: Decodable, Equatable {
    let url: String
    let title: String
    let text: String
    let chars: Int
    let truncated: Bool
}

/// PURE routing for the local-brain WEB capabilities (parity with Open WebUI / Msty): decide whether
/// a chat turn should read the exact URL(s) the buyer pasted (`url_context`, grounded + cited), run a
/// live web SEARCH (`web_search`, grounded + cited), or neither. The single source of truth the chat
/// send-path and the tests share, so "which web capability fires?" is verifiable with no network.
/// §5.1: never invents a query or a source.
enum WebCapability: Equatable {
    case readURLs([String])
    case search(query: String)
    case none

    /// Classify a prompt. Explicit http(s) URLs win the url_context path (read exactly what was
    /// pasted); otherwise an explicit search phrasing or Research mode triggers web_search; else
    /// nothing. PURE. `explicitSearch` is the caller's phrasing-detector result (nil = no phrasing).
    static func route(prompt: String, researchMode: Bool, explicitSearch: String?) -> WebCapability {
        let urls = extractURLs(prompt)
        if !urls.isEmpty { return .readURLs(urls) }
        if let q = explicitSearch?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            return .search(query: q)
        }
        if researchMode {
            let q = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? .none : .search(query: q)
        }
        return .none
    }

    /// Extract http/https URLs from free text (deduped, order-preserving, punctuation-trimmed). PURE.
    static func extractURLs(_ text: String) -> [String] {
        var out: [String] = []
        for tok in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let t = String(tok).trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}<>,\"'`"))
            guard t.hasPrefix("http://") || t.hasPrefix("https://") else { continue }
            if let u = URL(string: t), let h = u.host, !h.isEmpty, !out.contains(t) { out.append(t) }
        }
        return out
    }
}

/// A cited research answer: the sources the daemon actually fetched + a
/// citation-numbered context digest the brain summarizes from.
struct ResearchResult: Decodable {
    struct Source: Decodable, Identifiable {
        let n: Int; let title: String; let url: String
        var id: Int { n }
    }
    let ok: Bool
    let query: String?
    let provider: String?
    let sources: [Source]
    let context: String
    let error: String?
}

/// Whether web research is connected + which provider is active (backs the UI badge).
struct ResearchStatus: Decodable {
    struct Provider: Decodable, Identifiable {
        let id: String; let name: String; let configured: Bool; let setup: String
    }
    let connected: Bool
    let activeProvider: String?
    let providers: [Provider]
    let note: String?
    enum CodingKeys: String, CodingKey {
        case connected, providers, note
        case activeProvider = "active_provider"
    }
}

// MARK: - The client

/// Talks to the loopback daemon. All methods are best-effort and return honest
/// errors; the host is always 127.0.0.1 (loopback-only by construction).
struct ToolClient {
    static let shared = ToolClient()

    /// Candidate ports: the daemon publishes its bound port to ~/.sovereign/dashboard.port
    /// (it may fall back off 8765 if Ace/Tailscale holds it); we try that first, then scan.
    private var candidatePorts: [Int] {
        var ports: [Int] = []
        // The published-port file lives in the buyer's macOS home (~/.sovereign/dashboard.port).
        // `homeDirectoryForCurrentUser` is macOS-only; on iOS there is no loopback daemon and no
        // such file (see the iOS engine-gap ruling), so we skip straight to the scan range.
        #if os(macOS)
        let portFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sovereign/dashboard.port")
        if let s = try? String(contentsOf: portFile, encoding: .utf8),
           let p = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            ports.append(p)
        }
        #endif
        for p in 8765...8785 where !ports.contains(p) { ports.append(p) }
        return ports
    }

    private func session(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 5
        // Authenticate to our own loopback daemon. It now requires a per-install token on /api/*
        // (this is what shuts out other local UIDs, drive-by web pages, and DNS-rebind from the tool
        // bus). The token is a 0600 file the daemon writes in the owner's home; as the same UID we read
        // it and attach it to every request. Absent (daemon not started yet, or an older daemon) → no
        // header, identical to prior behavior.
        if let token = Self.daemonToken {
            cfg.httpAdditionalHeaders = ["X-Sovereign-Token": token]
        }
        return URLSession(configuration: cfg)
    }

    /// The daemon's loopback auth token (`~/.sovereign/dashboard_token`, mode 0600), read best-effort.
    /// macOS-only — there is no loopback daemon on iOS. nil when the file is absent or unreadable, in
    /// which case requests go out un-tokened (an older daemon ignores the header; a new one 403s with
    /// an actionable error surfaced by the caller).
    static var daemonToken: String? {
        #if os(macOS)
        let f = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sovereign/dashboard_token")
        guard let s = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
        #else
        return nil
        #endif
    }

    /// Resolve the base URL by probing /api/health on each candidate port. nil if
    /// the daemon isn't reachable on any (the caller shows an actionable message).
    func resolveBase() async -> URL? {
        for port in candidatePorts {
            guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else { continue }
            var req = URLRequest(url: url); req.timeoutInterval = 1.5
            if let (data, resp) = try? await session(timeout: 2).data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["ok"] as? Bool) == true {
                return URL(string: "http://127.0.0.1:\(port)")
            }
        }
        return nil
    }

    private func daemonDownError() -> ToolError {
        // Honest on a Mac that never had the daemon: the kit is a SEPARATE install, this app does
        // not bundle it, and no amount of reinstalling the app can produce it. Chat + the local
        // brain work without it; only connected tools need it.
        ToolError(message: "This action needs the Sovereign background service, which isn't running on "
            + "this Mac. Connected tools (desktop, files, research, devices) come with the Sovereign "
            + "daemon kit — chat and your brain work fine without it. If the kit is installed, start it "
            + "with `sov start` in Terminal; if not, this build simply doesn't include those tools.")
    }

    // MARK: Desktop vision

    /// Route a captured screenshot through the daemon's on-device vision analyzer.
    /// Returns structured observations a text brain can reason over — the handoff
    /// that replaces the old "switch to a vision-capable brain" dead end.
    func analyzeDesktop(path: String) async -> Result<DesktopObservations, ToolError> {
        guard let base = await resolveBase() else { return .failure(daemonDownError()) }
        guard let url = URL(string: base.absoluteString + "/api/desktop/analyze") else {
            return .failure("Could not form the vision-analyzer URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["path": path])
        // Vision can take up to ~2 min on the machine's first-ever OCR; the daemon
        // bounds each attempt but give it room.
        do {
            let (data, resp) = try await session(timeout: 95).data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obs = try JSONDecoder().decode(DesktopObservations.self, from: data)
            if obs.ok { return .success(obs) }
            return .failure(ToolError(message: obs.reason ?? "The vision analyzer could not read the screenshot (HTTP \(code))."))
        } catch {
            return .failure("Vision analysis failed: \(error.localizedDescription)")
        }
    }

    // MARK: Web research

    /// One-shot cited research: the daemon searches, reads the top pages, and returns
    /// the sources it actually fetched + a citation-numbered context for the brain.
    func research(query: String) async -> Result<ResearchResult, ToolError> {
        guard let base = await resolveBase() else { return .failure(daemonDownError()) }
        guard let url = URL(string: base.absoluteString + "/api/research/answer") else {
            return .failure("Could not form the research URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "count": 5, "read_top": 3])
        do {
            let (data, _) = try await session(timeout: 95).data(for: req)
            let res = try JSONDecoder().decode(ResearchResult.self, from: data)
            if res.ok { return .success(res) }
            return .failure(ToolError(message: res.error ?? "Web research returned no usable sources."))
        } catch {
            return .failure("Web research failed: \(error.localizedDescription)")
        }
    }

    /// Is web research connected, and via which provider? Backs the UI badge.
    func researchStatus() async -> ResearchStatus? {
        guard let base = await resolveBase() else { return nil }
        guard let url = URL(string: base.absoluteString + "/api/research/status") else { return nil }
        guard let (data, _) = try? await session(timeout: 6).data(for: URLRequest(url: url)) else { return nil }
        return try? JSONDecoder().decode(ResearchStatus.self, from: data)
    }

    /// A plain search (title/url/snippet), via the daemon's browser.search_google tool.
    func searchWeb(query: String, count: Int = 6) async -> Result<[WebResult], ToolError> {
        let out = await callTool(name: "browser.search_google", args: ["query": query, "count": count])
        switch out {
        case .failure(let e): return .failure(e)
        case .success(let obj):
            let root = (obj["result"] as? [String: Any]) ?? obj
            guard let raw = root["results"] as? [[String: Any]] else {
                if let err = root["error"] as? String { return .failure(ToolError(message: err)) }
                return .failure("Search returned no results.")
            }
            let results = raw.compactMap { r -> WebResult? in
                guard let t = r["title"] as? String, let u = r["url"] as? String else { return nil }
                return WebResult(title: t, url: u, snippet: r["snippet"] as? String)
            }
            return .success(results)
        }
    }

    /// Fetch a specific URL's readable text via the daemon's keyless `url_context` tool (SSRF-guarded
    /// HTTP + readability extraction, no API key, nothing stored). Backs the "read this page and
    /// answer" capability with a real, citable source. Honest failure — never a fabricated page.
    func readURL(_ url: String, maxChars: Int = 6000) async -> Result<URLContext, ToolError> {
        // Apply the SAME SSRF guard the in-process WebFetch tool uses BEFORE handing the URL to the
        // daemon's url_context fetcher. Without it the agent could be talked into making the DAEMON hit
        // the buyer's LAN / loopback / cloud-metadata endpoint (169.254.169.254), bypassing the
        // Swift-side check entirely.
        guard WebFetch.isAllowed(url) else {
            return .failure(ToolError(message: "That URL isn't allowed (only public http/https pages)."))
        }
        guard !WebFetch.resolvedHostContainsPrivateIP(url) else {
            return .failure(ToolError(message: "That URL resolves to a private or loopback address — blocked."))
        }
        let out = await callTool(name: "url_context", args: ["url": url, "max_chars": maxChars])
        switch out {
        case .failure(let e): return .failure(e)
        case .success(let obj):
            let root = (obj["result"] as? [String: Any]) ?? obj
            if let ok = root["ok"] as? Bool, ok == false {
                return .failure(ToolError(message: (root["error"] as? String) ?? "The page could not be read."))
            }
            guard let text = (root["text"] as? String), !text.isEmpty else {
                return .failure("The page returned no readable text.")
            }
            return .success(URLContext(
                url: (root["url"] as? String) ?? url,
                title: (root["title"] as? String) ?? "",
                text: text,
                chars: (root["chars"] as? Int) ?? text.count,
                truncated: (root["truncated"] as? Bool) ?? false))
        }
    }

    // MARK: Devices

    /// Real attached devices/displays via the daemon (devices.list tool).
    func devices() async -> Result<[[String: Any]], ToolError> {
        let out = await callTool(name: "devices.list", args: [:])
        switch out {
        case .failure(let e): return .failure(e)
        case .success(let obj):
            let root = (obj["result"] as? [String: Any]) ?? obj
            if let list = root["devices"] as? [[String: Any]] { return .success(list) }
            return .failure(ToolError(message: root["error"] as? String ?? "No device data returned."))
        }
    }

    // MARK: Generic tool call

    /// Call any daemon tool by name. Returns the raw JSON object (which is either the
    /// tool's result or an actionable {ok:false,error} envelope) or a transport error.
    func callTool(name: String, args: [String: Any]) async -> Result<[String: Any], ToolError> {
        guard let base = await resolveBase() else { return .failure(daemonDownError()) }
        guard let url = URL(string: base.absoluteString + "/api/tools/call") else {
            return .failure("Could not form the tool URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "args": args])
        do {
            let (data, _) = try await session(timeout: 95).data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("The tool returned an unreadable response.")
            }
            return .success(obj)
        } catch {
            return .failure("Tool call failed: \(error.localizedDescription)")
        }
    }

    /// The registered tool names (for the Settings 'Test tools' surface).
    func listToolNames() async -> [String] {
        guard let base = await resolveBase() else { return [] }
        guard let url = URL(string: base.absoluteString + "/api/tools/list") else { return [] }
        guard let (data, _) = try? await session(timeout: 6).data(for: URLRequest(url: url)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = obj["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { $0["name"] as? String }
    }

    /// True if the daemon is reachable (the app's tool bus is live).
    func daemonReachable() async -> Bool { await resolveBase() != nil }
}
