// Sovereign — CONNECT VIA CLI: run the assistant on the buyer's own External SUBSCRIPTION
// (Pro/Max), not an Anthropic API key. No per-token billing, no key stored anywhere.
//
// HOW IT WORKS (honest):
//   The buyer runs `external login` ONCE in Terminal (OAuth → their own External account). That
//   session lives in the CLI's own store (~/.external) — Sovereign never sees, copies, or stores
//   the token. Sovereign just shells out to `external -p "<prompt>" --output-format json`, which
//   reaches External under the buyer's logged-in subscription. It is the buyer's OWN External login,
//   on the buyer's OWN machine. Nothing bundled, nothing billed by Black Label.
//
//   We invoke the CLI as a CLEAN chat brain, not External Code: `--strict-mcp-config` (don't load
//   the buyer's MCP servers), tools disallowed (a pure text completion, never agentic file/shell
//   actions), `--system-prompt` set, `--output-format json` parsed for the final `result`.
//
// PLATFORM SPLIT: this is macOS-only — iOS sandboxed apps cannot spawn a subprocess. On iOS the
// `external` CLI path is unavailable and the UI honestly routes the buyer to the API-key path (or
// "connect on your Mac"). The iOS shell below compiles but reports unavailable; it never fakes a
// connection.
//
// HONESTY: "connected" is only ever shown after a REAL `external -p` invocation returns success —
// never on faith. A missing CLI, a not-logged-in CLI, or a failed round-trip surfaces an honest
// message, never an invented reply.
import Foundation

struct BrainAccountLoginPlan: Equatable {
    let executablePath: String
    let arguments: [String]
}

/// The two buyer-owned AI accounts reachable from the Connectors screen. This is deliberately
/// separate from `ConnectorCatalog`: Claude and Codex are brains, not MCP tool servers, but buyers
/// still need one obvious account-connect surface beside MCP.
enum BrainAccountConnector: String, CaseIterable, Identifiable, Equatable {
    case claude
    case codex

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
    var commandTemplate: String {
        switch self {
        case .claude: return "claude -p {prompt}"
        case .codex: return "codex exec {prompt}"
        }
    }
    var loginArguments: [String] {
        switch self {
        case .claude: return ["auth", "login"]
        case .codex: return ["login"]
        }
    }

    func loginPlan(executablePath rawPath: String) -> BrainAccountLoginPlan? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return BrainAccountLoginPlan(executablePath: path, arguments: loginArguments)
    }

    var installedExecutablePath: String? {
        switch self {
        case .claude: return ExternalCLI.resolvePath()
        case .codex: return SecondaryCLI.resolvePath()
        }
    }

    static func connectedProvider(for kind: ExternalCredentialKind?) -> BrainAccountConnector? {
        switch kind {
        case .cli: return .claude
        case .secondaryCLI: return .codex
        default: return nil
        }
    }
}

/// The result of probing the `external` CLI on this machine.
enum CLIProbeResult: Equatable {
    case ok(path: String)             // CLI found + a real round-trip succeeded
    case notInstalled                 // no `external` binary on disk
    case notLoggedIn(path: String)    // CLI present but `external login` hasn't run (auth missing)
    case failed(path: String, message: String)   // CLI present but the round-trip errored
    case unsupportedPlatform          // iOS — cannot spawn a subprocess
    case sandboxed                    // App Store / sandboxed Mac build — can't spawn a subprocess

    var connectedPath: String? { if case .ok(let p) = self { return p }; return nil }
    /// Honest, human-readable status for the UI. Never claims success it didn't prove. Each state
    /// names the detected path and the next action, so "not installed" vs "not signed in" vs
    /// "connected" are visibly different states (no brand names — the path is the proof).
    var message: String {
        switch self {
        case .ok(let p): return "Connected — your CLI subscription answered from \(p)."
        case .notInstalled: return "Your provider's command-line app isn't installed on this Mac. Install it, sign in once in Terminal, then press Detect."
        case .notLoggedIn(let p): return "Found your CLI at \(p), but it isn't signed in yet. Sign in once in Terminal, then press Detect."
        case .failed(_, let m): return m
        case .unsupportedPlatform: return "The CLI subscription path runs on Mac only (iOS can't launch a subprocess). On iPhone/iPad, connect with an API key — or connect on your Mac."
        case .sandboxed: return "CLI connect requires the direct Mac download build. This sandboxed build cannot launch external CLIs."
        }
    }
}

enum ExternalCLI {
    /// True when this process runs inside the App Sandbox (the Mac App Store / TestFlight build).
    /// A sandboxed process cannot spawn the `external` subprocess and cannot read it outside the
    /// container, so the CLI-subscription path is genuinely unavailable — the UI must say so
    /// honestly rather than offer a dead toggle. Detection: the sandbox sets the
    /// APP_SANDBOX_CONTAINER_ID env var for every sandboxed process, and the app's own bundle path
    /// lives under ~/Library/Containers when sandboxed. Either signal is conclusive.
    static var isSandboxed: Bool {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return true }
        #if os(macOS)
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/Library/Containers/") { return true }
        #endif
        return false
    }

    /// Candidate locations for the `claude` binary, in priority order. A sandboxed Mac App Store
    /// build can't read most of these, which is fine: the CLI path is offered for the Developer-ID
    /// / direct build where the user runs their own tools. GUI apps get a minimal PATH
    /// (/usr/bin:/bin:...), so the real user install locations must be probed explicitly.
    static func candidatePaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            home + "/.local/bin/claude",        // standard claude installer target
            "/opt/homebrew/bin/claude",         // Homebrew (Apple Silicon)
            "/usr/local/bin/claude",            // Homebrew (Intel) / manual installs
            home + "/.claude/local/claude",     // legacy CLI layout
            home + "/.npm-global/bin/claude",   // npm global prefix installs
            "/usr/bin/claude",
        ]
    }

    /// Resolve the first existing, executable `external` binary. nil if none is found OR if we're
    /// sandboxed (a sandboxed process can't read the binary outside its container and can't spawn
    /// it — resolving "success" here would be a lie that produces a dead connect button).
    static func resolvePath() -> String? {
        if isSandboxed { return nil }
        let fm = FileManager.default
        for p in candidatePaths() where fm.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }
}

/// The result of probing the `secondary` CLI on this machine.
enum SecondaryCLIProbeResult: Equatable {
    case ok(path: String)
    case notInstalled
    case notLoggedIn(path: String)
    case failed(path: String, message: String)
    case unsupportedPlatform
    case sandboxed

    var connectedPath: String? { if case .ok(let p) = self { return p }; return nil }
    var message: String {
        switch self {
        case .ok(let p): return "Connected — your secondary CLI answered from \(p)."
        case .notInstalled: return "The secondary CLI isn't installed on this Mac. Install it, sign in once in Terminal, then press Detect."
        case .notLoggedIn(let p): return "Found the secondary CLI at \(p), but it isn't signed in yet. Sign in once in Terminal, then press Detect."
        case .failed(_, let m): return m
        case .unsupportedPlatform: return "The secondary CLI path runs on Mac only."
        case .sandboxed: return "Secondary CLI connect requires the direct Mac download build. This sandboxed build cannot launch external CLIs."
        }
    }
}

enum SecondaryCLI {
    static var isSandboxed: Bool { ExternalCLI.isSandboxed }

    /// Candidate locations for the `codex` binary (the buyer's Codex-account session).
    static func candidatePaths() -> [String] {
        let home = NSHomeDirectory()
        return [
            home + "/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home + "/.npm-global/bin/codex",
            "/usr/bin/codex",
        ]
    }

    static func resolvePath() -> String? {
        if isSandboxed { return nil }
        let fm = FileManager.default
        for p in candidatePaths() where fm.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }
}

#if os(macOS)
import AppKit

enum BrainAccountLoginResult: Equatable {
    case succeeded
    case notInstalled
    case failed(String)
}

enum BrainAccountProbeResult: Equatable {
    case ready(path: String)
    case notInstalled
    case notLoggedIn
    case failed(String)
}

enum BrainAccountConnectionOutcome: Equatable {
    case connected(path: String)
    case notInstalled
    case failed(String)
}

/// Probe first, authenticate only when the provider says the buyer is signed out, then probe again.
/// The second probe is the proof boundary: closing a browser tab or receiving an OAuth callback alone
/// can never paint a provider as connected.
enum BrainAccountConnectionFlow {
    static func connect(
        probe: () async -> BrainAccountProbeResult,
        signIn: () async -> BrainAccountLoginResult
    ) async -> BrainAccountConnectionOutcome {
        let first = await probe()
        switch first {
        case .ready(let path): return .connected(path: path)
        case .notInstalled: return .notInstalled
        case .failed(let message): return .failed(message)
        case .notLoggedIn:
            break
        }

        switch await signIn() {
        case .notInstalled: return .notInstalled
        case .failed(let message): return .failed(message)
        case .succeeded:
            break
        }

        switch await probe() {
        case .ready(let path): return .connected(path: path)
        case .notInstalled: return .notInstalled
        case .notLoggedIn:
            return .failed("Sign-in finished, but the provider CLI still reports no authenticated account.")
        case .failed(let message): return .failed(message)
        }
    }
}

/// Runs the provider CLI's own browser-auth flow. Sovereign never receives the account token: the
/// CLI stores its session, then the normal probe must still return a real answer before the account
/// is shown as connected.
enum BrainAccountLogin {
    static func signIn(_ connector: BrainAccountConnector) async -> BrainAccountLoginResult {
        if ExternalCLI.isSandboxed {
            return .failed("Account sign-in through Claude or Codex requires the direct Mac download build.")
        }
        guard let path = connector.installedExecutablePath,
              let plan = connector.loginPlan(executablePath: path) else { return .notInstalled }
        return await run(plan)
    }

    static func run(_ plan: BrainAccountLoginPlan) async -> BrainAccountLoginResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: plan.executablePath)
                process.arguments = plan.arguments
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                process.environment = ProcessInfo.processInfo.environment
                process.standardInput = FileHandle.nullDevice
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failed("Couldn't launch provider sign-in: \(error.localizedDescription)"))
                    return
                }

                var stderr = Data()
                let stderrGroup = DispatchGroup()
                stderrGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    stderrGroup.leave()
                }
                let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                stderrGroup.wait()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    let err = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let out = String(data: stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let detail = !err.isEmpty ? err : out
                    let message = detail.isEmpty
                        ? "Provider sign-in exited with status \(process.terminationStatus)."
                        : String(detail.prefix(400))
                    continuation.resume(returning: .failed(message))
                    return
                }
                continuation.resume(returning: .succeeded)
            }
        }
    }
}

/// macOS implementation — spawns the `external` CLI as a clean chat brain on the buyer's subscription.
actor CLIBrain {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    /// Probe: find the CLI and PROVE a real round-trip with a tiny prompt. Returns an honest result.
    /// This is what the Settings "Connect" button calls — connection is only "ok" if External actually
    /// answered. Never returns .ok without a successful invocation.
    static func probe() async -> CLIProbeResult {
        // Honest first: a sandboxed (App Store / TestFlight) build cannot spawn the CLI at all.
        // Report .sandboxed so the UI routes the buyer to the API-key path or the Mac download —
        // never a dead toggle that silently does nothing.
        if ExternalCLI.isSandboxed { return .sandboxed }
        guard let path = ExternalCLI.resolvePath() else { return .notInstalled }
        do {
            let text = try await runOnce(cliPath: path, system: "", prompt: "Reply with exactly: OK", model: nil, maxOutputHint: 16)
            if text.uppercased().contains("OK") || !text.isEmpty { return .ok(path: path) }
            return .failed(path: path, message: "The legacy external CLI returned an empty reply.")
        } catch let e as Failure {
            // Distinguish "not logged in" from a generic failure so the UI can guide the user.
            let m = e.message.lowercased()
            if m.contains("login") || m.contains("not authenticated") || m.contains("unauthorized") || m.contains("log in") {
                return .notLoggedIn(path: path)
            }
            return .failed(path: path, message: e.message)
        } catch {
            return .failed(path: path, message: error.localizedDescription)
        }
    }

    /// Run ONE non-streaming completion via `external -p ... --output-format json`. Parses the
    /// terminal `{"type":"result","subtype":"success","result":"..."}` event for the clean text.
    /// Throws Failure (with the CLI's own stderr/error text) on any non-success — never a fake reply.
    static func runOnce(cliPath: String, system: String, prompt: String, model: String?, maxOutputHint: Int? = nil) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        var args = ["-p", prompt, "--output-format", "json", "--strict-mcp-config"]
        // Pure chat: forbid agentic tool execution so this is a text completion, not External Code
        // running tools on the buyer's machine. (The CLI still answers normally.)
        args += ["--disallowed-tools", "Bash,Edit,Write,Read,WebFetch,WebSearch,Task,NotebookEdit"]
        if !system.isEmpty { args += ["--system-prompt", system] }
        if let model = model, !model.isEmpty { args += ["--model", model] }
        proc.arguments = args

        // Run from a neutral dir so no project CLAUDE.md/context leaks in. Inherit the user's env
        // (so the CLI finds its own ~/.external session) but ensure no API key is injected — this is
        // the SUBSCRIPTION path, on purpose.
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")   // force the logged-in subscription, not a key
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        // Run + drain off the calling thread so a large reply can't deadlock the 64KB pipe buffer,
        // and the async caller never blocks the main actor. We read BOTH pipes to end BEFORE
        // waitUntilExit returns control, then read the exit status.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try proc.run()
                    inPipe.fileHandleForWriting.closeFile()
                }
                catch {
                    cont.resume(throwing: Failure(message: "Couldn't launch the legacy external CLI: \(error.localizedDescription)"))
                    return
                }
                // Drain stderr concurrently so a full stderr buffer can't deadlock the stdout read
                // (and vice-versa). readDataToEndOfFile blocks until the child closes each pipe.
                var err = Data()
                let errGroup = DispatchGroup()
                errGroup.enter()
                DispatchQueue.global(qos: .utility).async { err = errHandle.readDataToEndOfFile(); errGroup.leave() }
                let out = outHandle.readDataToEndOfFile()
                errGroup.wait()
                proc.waitUntilExit()
                let stdout = String(data: out, encoding: .utf8) ?? ""
                let stderr = String(data: err, encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 {
                    let msg = Self.errorText(stdout: stdout, stderr: stderr, status: proc.terminationStatus)
                    cont.resume(throwing: Failure(message: msg.isEmpty ? "The legacy external CLI exited with status \(proc.terminationStatus)." : msg))
                    return
                }
                if let text = Self.parseResult(stdout) {
                    cont.resume(returning: text)
                } else {
                    let msg = Self.errorText(stdout: stdout, stderr: stderr, status: 0)
                    cont.resume(throwing: Failure(message: msg.isEmpty ? "The legacy external CLI returned an unexpected response." : msg))
                }
            }
        }
    }

    /// Parse the JSON-array output of `external -p --output-format json` for the final result text.
    /// The terminal event is `{"type":"result","subtype":"success","is_error":false,"result":"..."}`.
    static func parseResult(_ stdout: String) -> String? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        // Output is a JSON array of events.
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            // Prefer the explicit success result event.
            for evt in arr.reversed() {
                if evt["type"] as? String == "result", (evt["is_error"] as? Bool) != true,
                   let r = evt["result"] as? String { return r }
            }
            // Fallback: concatenate assistant text blocks.
            var text = ""
            for evt in arr where evt["type"] as? String == "assistant" {
                if let msg = evt["message"] as? [String: Any],
                   let content = msg["content"] as? [[String: Any]] {
                    for block in content where block["type"] as? String == "text" {
                        text += (block["text"] as? String ?? "")
                    }
                }
            }
            return text.isEmpty ? nil : text
        }
        // Some versions emit a single result object (not an array).
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let r = obj["result"] as? String { return r }
        return nil
    }

    /// Pull an honest error message out of the CLI's output (it reports auth/usage errors in the
    /// `result` event with is_error, or on stderr). Never invent — surface the CLI's own words.
    static func errorText(stdout: String, stderr: String, status: Int32) -> String {
        let t = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = t.data(using: .utf8) {
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for evt in arr.reversed() where evt["type"] as? String == "result" {
                    if let r = evt["result"] as? String, !r.isEmpty { return "External CLI: \(r)" }
                    if let sub = evt["subtype"] as? String { return "External CLI ended: \(sub)." }
                }
            }
        }
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return "External CLI: \(e.prefix(400))" }
        return status != 0 ? "The legacy external CLI exited with status \(status)." : ""
    }

    /// STREAMING seam for the BrainRouter. The CLI's plain `json` mode returns the whole reply at
    /// once (no token stream without `stream-json`, which interleaves tool events we don't want),
    /// so we run the single-shot completion and deliver the final text as one update. Honest: the
    /// UI shows a thinking state, then the full reply — never a fabricated partial.
    func stream(model: String?, system: String, prompt: String, cliPath: String,
                onToken: @escaping (String) -> Void) async throws -> String {
        let text = try await Self.runOnce(cliPath: cliPath, system: system, prompt: prompt, model: model)
        onToken(text)
        return text
    }

    func complete(model: String?, system: String, prompt: String, cliPath: String) async throws -> String {
        try await Self.runOnce(cliPath: cliPath, system: system, prompt: prompt, model: model)
    }
}

/// macOS implementation — spawns the installed Secondary CLI as a clean, text-only chat brain.
actor SecondaryCLIBrain {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    static func probe() async -> SecondaryCLIProbeResult {
        if SecondaryCLI.isSandboxed { return .sandboxed }
        guard let path = SecondaryCLI.resolvePath() else { return .notInstalled }
        do {
            let text = try await runOnce(cliPath: path, system: "", prompt: "Reply with exactly: OK", maxOutputHint: 16)
            if text.uppercased().contains("OK") || !text.isEmpty { return .ok(path: path) }
            return .failed(path: path, message: "The legacy external CLI returned an empty reply.")
        } catch let e as Failure {
            let m = e.message.lowercased()
            if m.contains("login") || m.contains("not authenticated") || m.contains("unauthorized")
                || m.contains("api key") || m.contains("openai") {
                return .notLoggedIn(path: path)
            }
            return .failed(path: path, message: e.message)
        } catch {
            return .failed(path: path, message: error.localizedDescription)
        }
    }

    static func runOnce(cliPath: String, system: String, prompt: String, maxOutputHint: Int? = nil) async throws -> String {
        let runID = UUID().uuidString
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("sovereign-external-\(runID)", isDirectory: true)
        let outputURL = workDir.appendingPathComponent("last-message.txt")
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            throw Failure(message: "Couldn't prepare a legacy external CLI workspace: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: workDir) }

        let fullPrompt = Self.composePrompt(system: system, prompt: prompt)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = Self.execArguments(workDir: workDir, outputURL: outputURL, prompt: fullPrompt)
        proc.currentDirectoryURL = workDir
        proc.environment = ProcessInfo.processInfo.environment

        let inPipe = Pipe()
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try proc.run()
                    inPipe.fileHandleForWriting.closeFile()
                }
                catch {
                    cont.resume(throwing: Failure(message: "Couldn't launch the legacy external CLI: \(error.localizedDescription)"))
                    return
                }
                var err = Data()
                let errGroup = DispatchGroup()
                errGroup.enter()
                DispatchQueue.global(qos: .utility).async { err = errHandle.readDataToEndOfFile(); errGroup.leave() }
                let out = outHandle.readDataToEndOfFile()
                errGroup.wait()
                proc.waitUntilExit()
                let stdout = String(data: out, encoding: .utf8) ?? ""
                let stderr = String(data: err, encoding: .utf8) ?? ""
                let outputText = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                if proc.terminationStatus != 0 {
                    let msg = Self.errorText(stdout: stdout, stderr: stderr, status: proc.terminationStatus)
                    cont.resume(throwing: Failure(message: msg.isEmpty ? "The legacy external CLI exited with status \(proc.terminationStatus)." : msg))
                    return
                }
                if let text = Self.parseResult(stdout: stdout, outputText: outputText) {
                    cont.resume(returning: text)
                } else {
                    let msg = Self.errorText(stdout: stdout, stderr: stderr, status: 0)
                    cont.resume(throwing: Failure(message: msg.isEmpty ? "The legacy external CLI returned an empty response." : msg))
                }
            }
        }
    }

    static func composePrompt(system: String, prompt: String) -> String {
        if system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return prompt
        }
        return "System instructions:\n\(system)\n\nUser request:\n\(prompt)"
    }

    static func execArguments(workDir: URL, outputURL: URL, prompt: String) -> [String] {
        [
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox", "read-only",
            "--color", "never",
            "-C", workDir.path,
            "-o", outputURL.path,
            prompt
        ]
    }

    static func parseResult(stdout: String, outputText: String) -> String? {
        let fileText = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fileText.isEmpty { return fileText }
        let stdoutText = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdoutText.isEmpty ? nil : stdoutText
    }

    static func errorText(stdout: String, stderr: String, status: Int32) -> String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return "External CLI: \(e.prefix(400))" }
        let o = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { return "External CLI: \(o.prefix(400))" }
        return status != 0 ? "The legacy external CLI exited with status \(status)." : ""
    }

    func stream(system: String, prompt: String, cliPath: String,
                onToken: @escaping (String) -> Void) async throws -> String {
        let text = try await Self.runOnce(cliPath: cliPath, system: system, prompt: prompt)
        onToken(text)
        return text
    }

    func complete(system: String, prompt: String, cliPath: String) async throws -> String {
        try await Self.runOnce(cliPath: cliPath, system: system, prompt: prompt)
    }
}
#else
// iOS: subprocesses are not permitted in the sandbox. The CLI subscription path is unavailable;
// the UI routes the buyer to the API-key path. This shell keeps call sites compiling and is HONEST
// (it never reports a connection).
actor CLIBrain {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func probe() async -> CLIProbeResult { .unsupportedPlatform }
    func stream(model: String?, system: String, prompt: String, cliPath: String,
                onToken: @escaping (String) -> Void) async throws -> String {
        throw Failure(message: CLIProbeResult.unsupportedPlatform.message)
    }
    func complete(model: String?, system: String, prompt: String, cliPath: String) async throws -> String {
        throw Failure(message: CLIProbeResult.unsupportedPlatform.message)
    }
}
actor SecondaryCLIBrain {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func probe() async -> SecondaryCLIProbeResult { .unsupportedPlatform }
    func stream(system: String, prompt: String, cliPath: String,
                onToken: @escaping (String) -> Void) async throws -> String {
        throw Failure(message: SecondaryCLIProbeResult.unsupportedPlatform.message)
    }
    func complete(system: String, prompt: String, cliPath: String) async throws -> String {
        throw Failure(message: SecondaryCLIProbeResult.unsupportedPlatform.message)
    }
}
#endif
