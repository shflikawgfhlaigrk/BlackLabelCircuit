// Sovereign — CUSTOM CLI BRAIN: point Sovereign at ANY prompt-capable command on your PATH.
//
// The site promises "any prompt-capable CLI on PATH as the brain." `external` and `secondary` ship as
// built-in presets with their own JSON parsers (see ExternalCLI.swift) — those are UNCHANGED. This is
// the general path: the buyer supplies a command line, Sovereign feeds it the prompt (substituted at
// a `{prompt}` placeholder, or piped on stdin when no placeholder is present) and returns the
// command's stdout verbatim. No bundled binary, no key — it runs the buyer's OWN tool, on the
// buyer's OWN machine.
//
// PLATFORM: like the external/secondary CLI brains, this spawns a subprocess, so it is Developer-ID /
// Mac-download ONLY. A sandboxed App Store build can't spawn a subprocess; the probe returns
// .sandboxed and the UI routes the buyer to the API-key path or the Mac download — never a dead
// toggle (§5.1, no fabrication).
//
// HONESTY: "connected" is shown only after a REAL round-trip returns output. A missing binary, a
// non-zero exit, or empty output surfaces the command's own stderr — never a fabricated reply.
import Foundation

/// The buyer's custom-CLI configuration. `command` is a shell-style command line; the prompt is
/// substituted at the `{prompt}` placeholder, or piped on stdin when no placeholder is present.
/// `{system}` is an optional second placeholder for the system prompt. NOTE: this carries NO secret
/// — it's a non-sensitive command template — but it lives in the same Keychain credential slot as the
/// other CLI connections so the brain has one place to resolve "how do I run the user's CLI".
struct CustomCLISpec: Codable, Equatable {
    var command: String              // e.g. "llm -m llama3"  or  "mycli --prompt {prompt}"

    /// The display name (the binary's last path component). Honest, never a secret.
    var displayName: String {
        let tokens = CustomCLIInvocation.tokenize(command)
        guard let first = tokens.first, !first.isEmpty else { return "custom CLI" }
        return (first as NSString).lastPathComponent
    }

    /// JSON round-trip used to stash the spec in the credential `secret` slot.
    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return command }
        return String(data: data, encoding: .utf8) ?? command
    }

    /// Decode a stored spec. Back-compat: a bare command string (not JSON) is treated as the command.
    static func decode(_ raw: String) -> CustomCLISpec? {
        if let data = raw.data(using: .utf8),
           let spec = try? JSONDecoder().decode(CustomCLISpec.self, from: data) { return spec }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : CustomCLISpec(command: t)
    }
}

/// Pure construction of the actual process invocation from a command template + system + prompt.
/// This is the heart of GAP B — tested directly, with NO subprocess. Platform-agnostic so the iOS
/// shell (which only needs `displayName`) compiles too.
enum CustomCLIInvocation {
    static let promptToken = "{prompt}"
    static let systemToken = "{system}"

    /// Split a command line into argv, honoring single/double quotes (a small shell-style tokenizer).
    /// We never run the command through a shell — argv goes straight to Process — so a prompt with
    /// spaces or shell metacharacters can't inject; it's just data in one argument or on stdin.
    static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var quote: Character? = nil
        var hasCurrent = false
        for ch in command {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; hasCurrent = true
            } else if ch == " " || ch == "\t" || ch == "\n" {
                if hasCurrent { tokens.append(cur); cur = ""; hasCurrent = false }
            } else {
                cur.append(ch); hasCurrent = true
            }
        }
        if hasCurrent { tokens.append(cur) }
        return tokens
    }

    /// Compose system + prompt into one block for when the system must ride inside the prompt (no
    /// dedicated {system} slot, or the prompt is piped on stdin).
    static func compose(system: String, prompt: String) -> String {
        let s = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return prompt }
        return "System instructions:\n\(s)\n\nUser request:\n\(prompt)"
    }

    /// A resolved process invocation.
    struct Plan: Equatable {
        let executable: String       // tokens[0] (PATH resolution happens at spawn time)
        let arguments: [String]
        let stdin: String?           // when non-nil, the prompt is piped here (no {prompt} placeholder)
    }

    /// Build the invocation plan. Rules:
    ///  • If any token contains {prompt}, substitute the prompt there. The system rides inside that
    ///    value UNLESS a {system} placeholder also exists. Nothing is piped on stdin.
    ///  • If no {prompt} placeholder exists, the composed system+prompt is piped on stdin; any
    ///    {system} placeholders are still substituted in the args.
    static func plan(command: String, system: String, prompt: String) -> Plan? {
        let tokens = tokenize(command)
        guard let exe = tokens.first, !exe.isEmpty else { return nil }
        let argTokens = Array(tokens.dropFirst())
        let hasPrompt = tokens.contains { $0.contains(promptToken) }
        let hasSystem = tokens.contains { $0.contains(systemToken) }
        let promptValue = hasSystem ? prompt : compose(system: system, prompt: prompt)
        let args = argTokens.map { tok -> String in
            var t = tok
            if t.contains(promptToken) { t = t.replacingOccurrences(of: promptToken, with: promptValue) }
            if t.contains(systemToken) { t = t.replacingOccurrences(of: systemToken, with: system) }
            return t
        }
        let stdin = hasPrompt ? nil : compose(system: system, prompt: prompt)
        return Plan(executable: exe, arguments: args, stdin: stdin)
    }

    /// Resolve a binary name to an executable path via PATH (+ the usual install dirs). An absolute
    /// or relative path is honored directly. nil when nothing executable is found.
    static func resolveExecutable(_ name: String) -> String? {
        let fm = FileManager.default
        if name.contains("/") {
            return fm.isExecutableFile(atPath: name) ? name : nil
        }
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let p = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

#if os(macOS)
import AppKit

/// macOS implementation — spawns the buyer's own command as a clean, text-only chat brain.
actor CustomCLIBrain {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    static var isSandboxed: Bool { ExternalCLI.isSandboxed }

    /// Probe: validate the command resolves + a REAL round-trip returns output. Honest result; the
    /// caller stores "connected" only on `.ok`.
    static func probe(spec: CustomCLISpec) async -> CLIProbeResult {
        if isSandboxed { return .sandboxed }
        let tokens = CustomCLIInvocation.tokenize(spec.command)
        guard let exe = tokens.first, !exe.isEmpty else {
            return .failed(path: spec.command, message: "Enter a command — e.g. `llm -m llama3` or `mycli --prompt {prompt}`.")
        }
        guard let resolved = CustomCLIInvocation.resolveExecutable(exe) else { return .notInstalled }
        do {
            let text = try await runOnce(spec: spec, system: "", prompt: "Reply with exactly: OK")
            if !text.isEmpty { return .ok(path: resolved) }
            return .failed(path: resolved, message: "`\(spec.displayName)` ran but returned no output.")
        } catch let e as Failure {
            return .failed(path: resolved, message: e.message)
        } catch {
            return .failed(path: resolved, message: error.localizedDescription)
        }
    }

    /// Run ONE completion: spawn the resolved binary with the planned args, feed stdin if planned,
    /// return trimmed stdout. Throws Failure (with the command's own stderr) on any non-success.
    static func runOnce(spec: CustomCLISpec, system: String, prompt: String) async throws -> String {
        guard let plan = CustomCLIInvocation.plan(command: spec.command, system: system, prompt: prompt) else {
            throw Failure(message: "That command is empty or invalid.")
        }
        guard let exe = CustomCLIInvocation.resolveExecutable(plan.executable) else {
            throw Failure(message: "Couldn't find `\(plan.executable)` on your PATH. Use a full path, or install it and try again.")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = plan.arguments
        // Neutral working dir + the user's own env (so the CLI finds its own config/login).
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        proc.environment = ProcessInfo.processInfo.environment

        let inPipe = Pipe(); let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let stdinText = plan.stdin
        let name = spec.displayName

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try proc.run()
                    if let s = stdinText, let d = s.data(using: .utf8) {
                        inPipe.fileHandleForWriting.write(d)
                    }
                    inPipe.fileHandleForWriting.closeFile()
                } catch {
                    cont.resume(throwing: Failure(message: "Couldn't launch `\(exe)`: \(error.localizedDescription)"))
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
                if proc.terminationStatus != 0 {
                    let msg = Self.errorText(stdout: stdout, stderr: stderr, status: proc.terminationStatus, name: name)
                    cont.resume(throwing: Failure(message: msg.isEmpty ? "`\(name)` exited with status \(proc.terminationStatus)." : msg))
                    return
                }
                if let reply = Self.parseResult(stdout) {
                    cont.resume(returning: reply)
                } else {
                    let msg = Self.errorText(stdout: stdout, stderr: stderr, status: 0, name: name)
                    cont.resume(throwing: Failure(message: msg.isEmpty ? "`\(name)` returned no output." : msg))
                }
            }
        }
    }

    /// The reply is the command's stdout, trimmed. PURE. nil when the command printed nothing.
    static func parseResult(_ stdout: String) -> String? {
        let t = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Pull an honest error out of the command's output — its own stderr first, then stdout. PURE.
    static func errorText(stdout: String, stderr: String, status: Int32, name: String) -> String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return "\(name): \(e.prefix(400))" }
        let o = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { return "\(name): \(o.prefix(400))" }
        return status != 0 ? "`\(name)` exited with status \(status)." : ""
    }

    func stream(spec: CustomCLISpec, system: String, prompt: String,
                onToken: @escaping (String) -> Void) async throws -> String {
        let text = try await Self.runOnce(spec: spec, system: system, prompt: prompt)
        onToken(text)
        return text
    }

    func complete(spec: CustomCLISpec, system: String, prompt: String) async throws -> String {
        try await Self.runOnce(spec: spec, system: system, prompt: prompt)
    }
}
#else
// iOS: subprocesses are not permitted in the sandbox. The custom-CLI path is unavailable; the UI
// routes the buyer to the API-key path. This shell keeps call sites compiling and is HONEST (never
// reports a connection).
actor CustomCLIBrain {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func probe(spec: CustomCLISpec) async -> CLIProbeResult { .unsupportedPlatform }
    func stream(spec: CustomCLISpec, system: String, prompt: String,
                onToken: @escaping (String) -> Void) async throws -> String {
        throw Failure(message: CLIProbeResult.unsupportedPlatform.message)
    }
    func complete(spec: CustomCLISpec, system: String, prompt: String) async throws -> String {
        throw Failure(message: CLIProbeResult.unsupportedPlatform.message)
    }
}
#endif
