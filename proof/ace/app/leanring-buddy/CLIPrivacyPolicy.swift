import Foundation

/// The process boundary shared by every bundled Codex and Claude invocation.
/// It suppresses only optional diagnostics, feedback, and update traffic; the
/// provider request itself and the buyer's normal authentication remain intact.
nonisolated enum CLIPrivacyPolicy {
    private static let codexFileCredentialOverride =
        "cli_auth_credentials_store=\"file\""

    private static let removedEnvironmentKeys: Set<String> = [
        "CLAUDE_CODE_ENABLE_TELEMETRY",
        "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA",
        "CLAUDE_CODE_SEND_FEEDBACK",
        "CLAUDE_CODE_ENABLE_FEEDBACK_SURVEY_FOR_OTEL",
        "OTEL_LOG_USER_PROMPTS",
        "OTEL_LOG_ASSISTANT_RESPONSES",
        "OTEL_LOG_TOOL_DETAILS",
        "OTEL_LOG_TOOL_CONTENT",
        "OTEL_LOG_RAW_API_BODIES",
    ]

    private static let forcedEnvironment: [String: String] = [
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1",
        "DISABLE_FEEDBACK_COMMAND": "1",
        "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1",
        "DO_NOT_TRACK": "1",
        "DISABLE_AUTOUPDATER": "1",
        "DISABLE_UPDATES": "1",
        "OTEL_SDK_DISABLED": "true",
        "OTEL_LOGS_EXPORTER": "none",
        "OTEL_METRICS_EXPORTER": "none",
        "OTEL_TRACES_EXPORTER": "none",
    ]

    /// Codex 0.146.0 global configuration. These pairs precede the command so
    /// login, version checks, proof calls, Gold, Red, and Silver all receive the
    /// same nonessential-egress policy.
    ///
    /// Model capability does not belong in this global privacy prefix. It is
    /// resolved from a real answer for this packaged executable and the
    /// buyer's current account by CodexModelResolver.
    static let codexConfigurationArguments: [String] = [
        "-c", "analytics.enabled=false",
        "-c", "feedback.enabled=false",
        "-c", "check_for_update_on_startup=false",
        "-c", "otel.exporter=\"none\"",
        "-c", "otel.metrics_exporter=\"none\"",
        "-c", "otel.trace_exporter=\"none\"",
        "-c", "otel.log_user_prompt=false",
    ]

    private static var codexRequiredGlobalArguments: [String] {
        ["-c", codexFileCredentialOverride]
            + codexConfigurationArguments
    }

    /// Applies the exact Codex global prefix once. Any pre-existing global
    /// `-c value` pairs are replaced rather than inherited, so no caller can
    /// duplicate or weaken the file-credential and privacy settings.
    static func codexArguments(_ arguments: [String]) -> [String] {
        var commandStart = 0
        while commandStart + 1 < arguments.count,
              arguments[commandStart] == "-c" {
            commandStart += 2
        }
        let command = sanitizedCommandArguments(
            Array(arguments.dropFirst(commandStart))
        )
        return codexRequiredGlobalArguments
            + command
    }

    /// Returns the command only when the complete, ordered global policy is
    /// present exactly once. Proof validators use this before inspecting the
    /// `exec` sandbox/tool shape.
    static func codexCommandArguments(
        from arguments: [String]
    ) -> [String]? {
        guard arguments.starts(with: codexRequiredGlobalArguments) else {
            return nil
        }
        let command = Array(
            arguments.dropFirst(codexRequiredGlobalArguments.count)
        )
        guard command.first != "-c",
              postPrefixOverridesAreAllowed(in: command) else { return nil }
        return command
    }

    /// Only reasoning effort and the private Ace answer contract vary per turn. Keeping
    /// a literal allowlist here prevents a second feedback/analytics/OTel/auth
    /// override after `exec` from weakening the audited global prefix.
    private static func postPrefixOverridesAreAllowed(
        in command: [String]
    ) -> Bool {
        var index = command.startIndex
        while index < command.endIndex {
            let token = command[index]
            guard token == "-c" else {
                guard token != "--config",
                      !token.hasPrefix("--config="),
                      !token.hasPrefix("-c") else { return false }
                index = command.index(after: index)
                continue
            }
            let valueIndex = command.index(after: index)
            guard valueIndex < command.endIndex,
                  isAllowedPerTurnOverride(command[valueIndex]) else {
                return false
            }
            index = command.index(after: valueIndex)
        }
        return true
    }

    private static func isAllowedPerTurnOverride(_ value: String) -> Bool {
        if value.hasPrefix("model_reasoning_effort=") { return true }
        if value == "web_search=\"disabled\"" { return true }
        let prefix = "model_instructions_file="
        guard value.hasPrefix(prefix),
              !value.contains("\n"), !value.contains("\r"),
              let data = String(value.dropFirst(prefix.count)).data(using: .utf8),
              let path = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]
              ) as? String,
              path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value < 32 }),
              !path.split(separator: "/").contains("..") else {
            return false
        }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        let directoryPrefix = "blacklabel-brain-"
        return url.lastPathComponent == "ace-answer-instructions.txt"
            && parent.hasPrefix(directoryPrefix)
            && UUID(uuidString: String(parent.dropFirst(directoryPrefix.count))) != nil
    }

    /// A caller cannot accidentally append a second Codex configuration after
    /// the command and weaken the global boundary. Only the audited per-turn
    /// reasoning control and private answer contract survive. Validators reject malformed input;
    /// this sanitizer prevents it from reaching a production process at all.
    private static func sanitizedCommandArguments(
        _ command: [String]
    ) -> [String] {
        var sanitized: [String] = []
        var index = command.startIndex
        while index < command.endIndex {
            let token = command[index]
            if token == "-c" || token == "--config" {
                let valueIndex = command.index(after: index)
                guard valueIndex < command.endIndex else { break }
                let value = command[valueIndex]
                if token == "-c", isAllowedPerTurnOverride(value) {
                    sanitized.append(token)
                    sanitized.append(value)
                }
                index = command.index(after: valueIndex)
                continue
            }
            if token.hasPrefix("--config=")
                || token.hasPrefix("-c") {
                index = command.index(after: index)
                continue
            }
            sanitized.append(token)
            index = command.index(after: index)
        }
        return sanitized
    }

    static func applying(
        to parentEnvironment: [String: String]
    ) -> [String: String] {
        var environment = parentEnvironment
        for key in removedEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        for key in Array(environment.keys)
            where key.hasPrefix("OTEL_EXPORTER_OTLP") {
            environment.removeValue(forKey: key)
        }
        for (key, value) in forcedEnvironment {
            environment[key] = value
        }
        return environment
    }
}
