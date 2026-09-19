#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation

/// The worker can request only these fixed data scripts, with literal argv.
/// No caller-supplied path, script, environment, or desktop action crosses here.
@MainActor
enum BackgroundDataAdapter {
    static let allowedTools: Set<String> = [
        "note-create", "calendar-today", "calendar-add",
        "reminder-add", "contact-find", "email-read",
    ]

    static func execute(
        _ request: [String: Any], isAllowed: () -> Bool
    ) async -> [String: Any] {
        guard !Task.isCancelled, isAllowed(),
              Set(request.keys) == ["operation", "tool", "arguments"],
              request["operation"] as? String == "data-adapter",
              let name = request["tool"] as? String, allowedTools.contains(name),
              let arguments = request["arguments"] as? [String],
              arguments.count <= 5,
              arguments.allSatisfy({ !$0.contains("\0") }),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 60_000,
              let resources = Bundle.main.resourceURL else {
            return failure("The task's data adapter request was rejected. Nothing ran.")
        }
        let tool = resources.appendingPathComponent("tools").appendingPathComponent(name)
        guard tool.resolvingSymlinksInPath().path == tool.standardizedFileURL.path,
              FileManager.default.isExecutableFile(atPath: tool.path) else {
            return failure("The signed data adapter is unavailable. Nothing ran.")
        }
        do {
            let authority = try OwnerTurnEffectAuthority.issue()
            defer { authority.destroy() }
            // Derive authority from Ace, never from the network request or worker.
            var environment = authority.wrapperEnvironment().filter { key, _ in
                ["ACE_APP_MUTATION_APPROVED", "ACE_APP_MUTATION_TOKEN_PATH",
                 "ACE_EFFECT_GUARD_SUPPORT_DIRECTORY", "ACE_STEALTH_MARKER",
                 "ACE_STEALTH_INTENT"].contains(key)
            }
            environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["LANG"] = "en_US.UTF-8"
            guard !Task.isCancelled, isAllowed() else {
                return failure("The task stopped before the data operation started.")
            }
            let result = await BrainConnectionProbe.runProcess(
                executablePath: "/bin/bash", arguments: [tool.path] + arguments,
                standardInput: nil, environment: environment, timeout: 125
            )
            guard !Task.isCancelled, isAllowed(), !result.timedOut else {
                return failure("The data operation stopped without a verified result. Check its destination before retrying.")
            }
            let output = result.standardOutput + result.standardError
            guard output.utf8.count <= 180_000 else {
                return failure("The data result exceeded the response limit. Check its destination before retrying.")
            }
            return ["status": result.exitCode == 0 ? "verified" : "failed",
                    "output": output, "exitCode": result.exitCode]
        } catch {
            return failure("The task's data authority is unavailable. Nothing ran.")
        }
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["status": "failed", "message": message]
    }
}
#endif // circuit-convert
