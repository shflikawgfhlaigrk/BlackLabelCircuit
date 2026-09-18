#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  ClaudeAPI.swift
//  Model transport for Ace. Customer builds use the Codex CLI bundled inside
//  Ace and authenticate with the customer's own ChatGPT account. The private
//  founder cohort can instead use Black Label's entitlement-gated hosted lane.
//  No model API key ships in the app.
//
//  The type name, initializer, and method signatures are intentionally unchanged
//  so CompanionManager (the 1000-line state machine) is not touched at all.
//

import Foundation

/// Keeps private filesystem work off the caller's actor. In particular, a
/// screenshot write or answer read can never hold the MainActor ahead of the
/// visibility wall queued by X.
nonisolated enum ClaudePrivateIOWorker {
    static func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Value, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try operation()
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func schedule(
        _ operation: @escaping @Sendable () -> Void
    ) {
        DispatchQueue.global(qos: .utility).async(
            execute: operation
        )
    }
}

/// Selects the customer-authorized subscription CLI persisted during setup.
/// Partner reasoning remains sandboxed and capability-free; any requested Mac
/// effect must cross Ace's typed native capability and confirmation gates.
nonisolated enum BrainSelectionPolicy {
    /// A successful setup probe writes the customer's provider choice. That
    /// choice is runtime configuration, not a 15-minute setup credential: it
    /// must survive receipt expiry and an Ace upgrade or a working Claude buyer
    /// is silently redirected to a signed-out Codex runtime. Fresh proof still
    /// chooses a provider when no valid choice has ever been persisted.
    static func selectedCLI(
        persistedRawValue: String?,
        codexHasFreshProof: Bool,
        claudeHasFreshProof: Bool,
        qwenHasFreshProof: Bool = false
    ) -> BrainCLI {
        if let persistedRawValue,
           let persisted = BrainCLI(rawValue: persistedRawValue),
           BrainCLI.customerChoices.contains(persisted) {
            return persisted
        }
        if codexHasFreshProof { return .codex }
        if claudeHasFreshProof { return .claude }
        if qwenHasFreshProof { return .qwen }
        return .codex
    }
}

nonisolated enum BrainBackend {
    /// Kept for source compatibility with older call sites. This must remain
    /// true: changing a defaults key cannot grant a model shell authority.
    static var prefersClaude: Bool {
        selectedCLI == .claude
    }

    /// The saved customer choice survives the short-lived setup proof. Setup
    /// itself still requires a fresh real answer before it can save a choice.
    /// The founder-hosted route bypasses this property and uses HostedBrainClient.
    static var selectedCLI: BrainCLI {
        let persistedRawValue = UserDefaults.standard.string(
            forKey: "SelectedBrainCLI"
        )
        if let persistedRawValue,
           let persisted = BrainCLI(rawValue: persistedRawValue) {
            return persisted
        }
        return BrainSelectionPolicy.selectedCLI(
            persistedRawValue: nil,
            codexHasFreshProof: BrainConnectionProof.hasAnsweredRealProbe(
                for: .codex
            ),
            claudeHasFreshProof: BrainConnectionProof.hasAnsweredRealProbe(
                for: .claude
            ),
            qwenHasFreshProof: BrainCLI.includesQwen
                && BrainConnectionProof.hasAnsweredRealProbe(for: .qwen)
        )
    }

    /// Kept for diagnostics and older UI bindings. Runtime overrides and stale
    /// bundled values are intentionally ignored.
    static func resolvedBackendName() -> String {
        selectedCLI.rawValue
    }

    static func claudeExecutableCandidates(
        homePath _: String
    ) -> [String] {
        guard let resources = Bundle.main.resourceURL else { return [] }
#if arch(arm64)
        let architectureDirectory = "darwin-arm64"
#elseif arch(x86_64)
        let architectureDirectory = "darwin-x64"
#else
        return []
#endif
        return [
            resources
                .appendingPathComponent("claude", isDirectory: true)
                .appendingPathComponent(
                    architectureDirectory,
                    isDirectory: true
                )
                .appendingPathComponent("claude", isDirectory: false)
                .path,
        ]
    }

    /// Resolve only the Claude Code runtime shipped inside this exact Ace app.
    /// A machine-global CLI must never satisfy setup or inherit runtime proof.
    static func resolveClaudeExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return claudeExecutableCandidates(
            homePath: home
        ).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func codexExecutableCandidates(
        homePath _: String
    ) -> [String] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        return [
            resources
                .appendingPathComponent("codex", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("codex", isDirectory: false)
                .path,
        ]
    }

    /// Resolve only the Codex runtime shipped inside this exact Ace app.
    /// A machine-global CLI must never satisfy setup or inherit runtime proof.
    static func resolveCodexExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = codexExecutableCandidates(
            homePath: home
        )
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The executable for whichever brain is selected.
    static func resolveExecutable(for cli: BrainCLI) -> String? {
        switch cli {
        case .claude: return resolveClaudeExecutable()
        case .codex: return resolveCodexExecutable()
        case .qwen: return AceLocalBrain.resolveBundledExecutable()
        }
    }

    /// Force Codex browser authentication into Ace's private CODEX_HOME file.
    /// The upstream executable links macOS Keychain support even when unused;
    /// this override keeps every Ace-launched Codex path prompt-free.
    static func codexFileCredentialArguments(
        _ arguments: [String]
    ) -> [String] {
        privacyArguments(for: .codex, arguments)
    }

    static var codexAuthFilePath: String? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent(
            "BlackLabel/Codex/auth.json",
            isDirectory: false
        ).path
    }

    /// Every customer-owned Codex lane awaits this shared live capability
    /// boundary before it constructs argv. A returning process therefore never
    /// falls through to an unverified provider default while the memory cache is
    /// empty.
    static func resolveCodexModel(
        executablePath: String,
        entryLatch: StealthEntryLatch = .shared
    ) async throws -> String {
        guard let authFilePath = codexAuthFilePath else {
            throw CodexModelCapabilityError.authenticationRequired
        }
        let resolution = try await CodexModelCapabilityPreflight.shared.resolve(
            executablePath: executablePath,
            authFilePath: authFilePath
        ) { model in
            await BrainConnectionProbe.codexCapabilityObservation(
                executablePath: executablePath,
                model: model,
                entryLatch: entryLatch
            )
        }
        switch resolution {
        case let .supported(model, _, _):
            return model
        case .authenticationRequired:
            throw CodexModelCapabilityError.authenticationRequired
        case let .temporarilyUnavailable(reason):
            throw CodexModelCapabilityError.temporarilyUnavailable(reason)
        case let .unsupported(candidatesTried):
            throw CodexModelCapabilityError.unsupported(candidatesTried)
        }
    }

    /// Adds one model already proven for this executable/account capability.
    /// There is intentionally no empty-cache overload.
    static func codexExecutionArguments(
        _ arguments: [String],
        resolvedModel: String
    ) -> [String] {
        var isolatedArguments = arguments
        if let boundary = isolatedArguments.firstIndex(
            of: "--ignore-rules"
        ) {
            isolatedArguments.insert(
                contentsOf: [
                    "--disable", "remote_models",
                    "--disable", "plugins",
                    "--disable", "apps",
                    "--disable", "plugin_sharing",
                    "-c", "mcp_servers={}",
                    "-c", "plugins={}",
                    "-c", "apps._default.enabled=false",
                ],
                at: isolatedArguments.index(after: boundary)
            )
        }
        return codexFileCredentialArguments(
            CodexModelResolver.arguments(
                for: resolvedModel,
                command: isolatedArguments
            )
        )
    }

    /// One argument gateway for every bundled provider process. Claude's
    /// nonessential-egress controls live in the shared environment; Codex also
    /// requires an exact global `-c` prefix before every command.
    static func privacyArguments(
        for cli: BrainCLI,
        _ arguments: [String]
    ) -> [String] {
        switch cli {
        case .codex:
            return CLIPrivacyPolicy.codexArguments(arguments)
        case .claude:
            return arguments
        case .qwen:
            return arguments
        }
    }

    /// FULL-ACCESS Codex invocation. `exec` is the non-interactive mode and `-`
    /// makes it read the prompt from stdin, matching how every lane here already
    /// pipes its prompt (the prompt never becomes an argv entry, so it cannot
    /// leak through the process table).
    ///
    /// 2026-07-31 founder ruling: Codex is the main brain and the lanes get real
    /// tools. `--dangerously-bypass-approvals-and-sandbox` is what that means on
    /// this CLI. Codex was previously excluded here precisely BECAUSE its
    /// read-only sandbox still exposed a model-driven shell — that objection is
    /// moot once the selected lane grants shell deliberately.
    ///
    /// The customer-owned Codex route deliberately exposes the complete Codex
    /// agent. Hosted founder traffic is isolated in the server lane instead.
    static func codexFullAccessArguments(
        resolvedModel: String
    ) -> [String] {
        codexExecutionArguments([
            "exec",
            "--dangerously-bypass-approvals-and-sandbox",
            "--skip-git-repo-check",
            "--color", "never",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "-",
        ], resolvedModel: resolvedModel)
    }

    /// Codex with its own sandbox left ON — the buyer-safe shape.
    static func codexSandboxedArguments(
        resolvedModel: String
    ) -> [String] {
        codexExecutionArguments([
            "exec",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--color", "never",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "-",
        ], resolvedModel: resolvedModel)
    }

    /// Flags shared by EVERY claude invocation so a brain call can never inherit
    /// the owner's interactive Claude Code environment: `--setting-sources ""`
    /// skips user/project settings (their hooks, permission defaults, and model
    /// choice must not apply to voice calls), and `--strict-mcp-config` with no
    /// config supplied stops every configured MCP server from spawning.
    /// The model is a required typed parameter so every lane makes an
    /// explicit choice: the owner's picker selection where it applies, or a
    /// documented pin — never an invisible hard-coded default.
    nonisolated static func isolatedBaseArguments(
        model: AceClaudeModel
    ) -> [String] {
        [
            "-p",
            "--model", model.argvValue,
            "--output-format", "text",
            "--setting-sources", "",
            "--strict-mcp-config",
        ]
    }

    /// Authentication and private summarization probes need one text-only
    /// turn. This is not a Red lane and carries no execution authority.
    nonisolated static func isolatedZeroToolClaudeArguments(
        model: AceClaudeModel
    ) -> [String] {
        privacyArguments(for: .claude, isolatedBaseArguments(model: model) + [
            "--safe-mode",
            "--disable-slash-commands",
            "--no-chrome",
            "--no-session-persistence",
            "--permission-mode", "dontAsk",
            "--tools", "",
        ])
    }

    /// Complete, fail-closed argument set for screenshot-aware answers. An
    /// allowlist is used instead of a denylist so a newly added Claude tool is
    /// not silently enabled by a future CLI update.
    static func readOnlyClaudeArguments(
        model: AceClaudeModel
    ) -> [String] {
        privacyArguments(for: .claude, isolatedBaseArguments(model: model) + [
            "--safe-mode",
            "--disable-slash-commands",
            "--no-chrome",
            "--no-session-persistence",
            "--permission-mode", "dontAsk",
            "--tools", "Read",
            // `--tools` limits what the model can see, but does not scope that
            // tool. `dontAsk` plus this one pre-approved relative rule means
            // only files under the per-turn screenshot working directory can
            // be read; every other path is denied without a prompt. Claude's
            // symlink checks require both link and target to match the rule.
            "--allowedTools", "Read(./**)",
        ])
    }

    /// Fast path for image-free conversational answers (Partner turns, spoken
    /// questions with no screen context). Same isolation and same fail-closed
    /// posture as the screenshot path — strictly fewer capabilities and exactly
    /// one model turn, so no tool-negotiation round trip is spent on a turn
    /// that has nothing to read.
    static func conversationalClaudeArguments(
        model: AceClaudeModel
    ) -> [String] {
        privacyArguments(for: .claude, isolatedBaseArguments(model: model) + [
            "--safe-mode",
            "--disable-slash-commands",
            "--no-chrome",
            "--no-session-persistence",
            "--permission-mode", "dontAsk",
            "--max-turns", "1",
        ])
    }

    /// Gold tool-lane arguments for Claude: the typed contract arrives as three
    /// MCP tools served by Ace's own binary, so the runtime owns the response
    /// shape. `--safe-mode` is deliberately absent here and only here — it
    /// refuses to spawn any MCP server, including the one turn-local server
    /// that carries the contract. Every guarantee safe-mode provided is
    /// reproduced explicitly: `--setting-sources ""` (no CLAUDE.md, skills,
    /// hooks, or user config), `--strict-mcp-config` (only the turn's own
    /// config can spawn), the neutral per-turn working directory, `dontAsk`
    /// permissions, and a closed tool allowlist.
    static func goldToolClaudeArguments(
        mcpConfigFilePath: String,
        model: AceClaudeModel
    ) -> [String] {
        privacyArguments(for: .claude, [
            "-p",
            "--model", model.argvValue,
            "--output-format", "stream-json",
            "--verbose",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--mcp-config", mcpConfigFilePath,
            "--disable-slash-commands",
            "--no-chrome",
            "--no-session-persistence",
            "--permission-mode", "dontAsk",
            "--tools", "Read",
            "--allowedTools",
            "Read(./**),mcp__ace__\(AceGoldToolServer.replyToolName),"
                + "mcp__ace__\(AceGoldToolServer.clarifyToolName),"
                + "mcp__ace__\(AceGoldToolServer.executeToolName),"
                + "mcp__ace__\(AceGoldToolServer.foregroundToolName)",
            "--max-turns", "8",
        ])
    }

    /// Screenshot answers must use the selected CLI's own argv grammar. Passing
    /// Claude's `-p`/`--tools` flags to Codex makes Codex parse `-p` as a
    /// profile option and exit with status 2 before it can answer.
    static func screenshotAnswerArguments(
        for cli: BrainCLI,
        answerFilePath: String,
        imageFilePaths: [String],
        model: AceClaudeModel,
        resolvedCodexModel: String?,
        responseFormat:
            ClaudeBrainResponseFormat = .conversational,
        structuredOutputSchemaFilePath: String? = nil,
        answerInstructionsFilePath: String? = nil,
        interactiveLatencyProfile:
            InteractiveProviderLatencyProfile? = nil
    ) -> [String] {
        switch cli {
        case .claude:
            // TAIL latency, not median (measured 2026-08-07, 3 paired runs:
            // medians 4.54s tool-loop vs 4.45s single-turn — indistinguishable,
            // so this is NOT a median speedup and must not be sold as one).
            // What it does buy: a turn with no screenshot has nothing for Read
            // to open, yet `--max-turns 8` still lets the model burn up to
            // eight round trips probing a tool that can never help. brain.log's
            // worst turn was 27.70s against a 30s spoken-failure cliff. No
            // images ⇒ no tool, exactly one turn: the tail is bounded and the
            // capability surface shrinks. Gold/Partner answers are
            // capability-free by design (AGENTS.md) — this removes work, never
            // authority.
            if imageFilePaths.isEmpty {
                return conversationalClaudeArguments(model: model)
            }
            return readOnlyClaudeArguments(model: model) + [
                "--max-turns", "8",
            ]
        case .codex:
            guard let resolvedCodexModel else {
                preconditionFailure(
                    "Codex capability must resolve before screenshot argv"
                )
            }
            // Each conversation mode receives its own native schema. Generic
            // workflow planning must not inherit a conversation envelope.
            let outputSchemaFilePath: String? = {
                switch responseFormat {
                case .typedDelegationJSON, .partnerJSON, .localMultipleChoicePointing:
                    return structuredOutputSchemaFilePath
                case .conversational, .strictJSON, .localPointingJSON:
                    return nil
                }
            }()
            let reasoningEffort: String
            if let interactiveLatencyProfile {
                reasoningEffort =
                    interactiveLatencyProfile.reasoningEffort.rawValue
            } else if outputSchemaFilePath != nil {
                reasoningEffort = "medium"
            } else {
                reasoningEffort = responseFormat.usesStructuredJSON
                    ? "high" : "medium"
            }
            var arguments = codexExecutionArguments([
                "exec",
                "--sandbox", "read-only",
                "--skip-git-repo-check",
                "--color", "never",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "-c", "model_reasoning_effort=\"\(reasoningEffort)\"",
                "--output-last-message", answerFilePath,
            ], resolvedModel: resolvedCodexModel)
            if let answerInstructionsFilePath,
               interactiveLatencyProfile != nil {
                arguments += InteractiveProviderLatencyPolicy
                    .codexAnswerDisabledFeatures.flatMap { ["--disable", $0] }
                arguments += [
                    "-c", "web_search=\"disabled\"",
                    "-c", "model_instructions_file="
                        + ClaudeAPI.quotedJSONString(answerInstructionsFilePath),
                ]
            }
            if let outputSchemaFilePath {
                arguments += ["--output-schema", outputSchemaFilePath]
            }
            for imageFilePath in imageFilePaths {
                arguments += ["-i", imageFilePath]
            }
            return arguments
        case .qwen:
            return AceLocalBrain.cliAnswerArguments(
                json: responseFormat.usesStructuredJSON
            )
        }
    }

    static func resolvedCodexScreenshotAnswerArguments(
        executablePath: String,
        answerFilePath: String,
        imageFilePaths: [String],
        model: AceClaudeModel,
        responseFormat:
            ClaudeBrainResponseFormat = .conversational,
        structuredOutputSchemaFilePath: String? = nil,
        answerInstructionsFilePath: String? = nil,
        interactiveLatencyProfile:
            InteractiveProviderLatencyProfile? = nil,
        resolveModel:
            @escaping @Sendable (String) async throws -> String = {
                try await BrainBackend.resolveCodexModel(
                    executablePath: $0
                )
            }
    ) async throws -> [String] {
        let resolvedModel = try await resolveModel(executablePath)
        return screenshotAnswerArguments(
            for: .codex,
            answerFilePath: answerFilePath,
            imageFilePaths: imageFilePaths,
            model: model,
            resolvedCodexModel: resolvedModel,
            responseFormat: responseFormat,
            structuredOutputSchemaFilePath:
                structuredOutputSchemaFilePath,
            answerInstructionsFilePath: answerInstructionsFilePath,
            interactiveLatencyProfile:
                interactiveLatencyProfile
        )
    }

    /// Claude prints only its answer to stdout, so the app captures that stream.
    /// Codex writes the final answer through `--output-last-message`; its normal
    /// stdout and stderr are diagnostic streams that must stay out of speech.
    static func screenshotAnswerCapturesStandardOutput(
        for cli: BrainCLI
    ) -> Bool {
        cli != .codex
    }

    /// Environment for every bundled model subprocess: the parent environment
    /// after the shared privacy/credential boundary, plus a PATH that starts
    /// with the selected binary's own directory — its helper
    /// subprocesses resolve by name, and a Finder-launched GUI app's PATH lacks
    /// every user-level install directory.
    static func processEnvironment(
        executablePath: String,
        parentEnvironment: [String: String],
        codexHomePath: String,
        claudeConfigPath: String,
        bundledToolsPath: String?
    ) -> [String: String] {
        var environment = CLIPrivacyPolicy.applying(
            to: parentEnvironment
        )
        // A model subprocess must never inherit an app-owned mutation receipt.
        // Deterministic effect tools receive approvals directly from app code;
        // no Claude lane is an approval bearer.
        environment.removeValue(forKey: "ACE_APP_MUTATION_APPROVED")
        environment.removeValue(forKey: "ACE_APP_MUTATION_TOKEN_PATH")
        environment.removeValue(forKey: "BROWSER")
        // Ace's Codex identity is the customer's browser-authenticated ChatGPT
        // session in a private Ace-owned directory. API credentials from a
        // shell, launcher, or management profile must never change that owner.
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        // The customer must authenticate Claude in its own browser session.
        // Launcher/service credentials and cloud-provider routing are never
        // inherited by either local customer brain.
        for key in [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY",
            "AWS_BEARER_TOKEN_BEDROCK",
            "ANTHROPIC_BASE_URL",
        ] {
            environment.removeValue(forKey: key)
        }
        environment["CODEX_HOME"] = codexHomePath
        environment["CLAUDE_CONFIG_DIR"] = claudeConfigPath
        if let bundledToolsPath, !bundledToolsPath.isEmpty {
            let providerBrowserOpenPath = (bundledToolsPath as NSString)
                .appendingPathComponent("provider-browser-open")
            environment["BROWSER"] = providerBrowserOpenPath
        }
        let executableDirectory = (executablePath as NSString).deletingLastPathComponent
        let runtimePaths = [executableDirectory, bundledToolsPath]
            .compactMap { path -> String? in
                guard let path, !path.isEmpty else { return nil }
                return path
            }
        environment["PATH"] = (runtimePaths + [
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]).joined(separator: ":")
        return environment
    }

    static func processEnvironment(claudeExecutablePath: String) -> [String: String] {
        let blackLabelSupportURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/BlackLabel",
                isDirectory: true
            )
        let codexHomeURL = blackLabelSupportURL
            .appendingPathComponent("Codex", isDirectory: true)
        let claudeConfigURL = blackLabelSupportURL
            .appendingPathComponent("Claude", isDirectory: true)
        try? PrivateSupportDirectory.ensure(at: codexHomeURL)
        try? PrivateSupportDirectory.ensure(at: claudeConfigURL)
        return processEnvironment(
            executablePath: claudeExecutablePath,
            parentEnvironment: ProcessInfo.processInfo.environment,
            codexHomePath: codexHomeURL.path,
            claudeConfigPath: claudeConfigURL.path,
            bundledToolsPath: Bundle.main.resourceURL?
                .appendingPathComponent("tools", isDirectory: true).path
        )
    }
}

extension AceProviderTurn {
    /// Reads the mutable picker exactly once. Every async stage receives this
    /// value instead of consulting UserDefaults again during the same turn.
    nonisolated static func capture() -> AceProviderTurn {
        capture { BrainBackend.selectedCLI }
    }
}

/// Screenshot-aware answering, backed by an isolated local Claude Code CLI.
nonisolated enum ClaudeBrainResponseFormat: Equatable, Sendable {
    case conversational
    case strictJSON
    case partnerJSON
    case typedDelegationJSON
    case localPointingJSON
    case localMultipleChoicePointing

    var usesStructuredJSON: Bool {
        switch self {
        case .strictJSON, .partnerJSON, .typedDelegationJSON, .localPointingJSON:
            return true
        case .conversational, .localMultipleChoicePointing:
            return false
        }
    }

    var diagnosticLane: String {
        switch self {
        case .conversational: return "conversation"
        case .strictJSON: return "partner-planner"
        case .partnerJSON: return "partner-conversation"
        case .typedDelegationJSON: return "gold-delegation"
        case .localPointingJSON: return "screen-point"
        case .localMultipleChoicePointing: return "multiple-choice-screen-point"
        }
    }

    var hostedRequestKind: HostedBrainRequestKind {
        switch self {
        case .conversational:
            return .answer
        case .strictJSON, .partnerJSON, .typedDelegationJSON, .localPointingJSON,
             .localMultipleChoicePointing:
            // The existing planner lane is zero-tool and its HQ relay adds a
            // final JSON-only instruction. Partner still validates the returned
            // envelope locally before any text is shown, spoken, or persisted.
            return .planner
        }
    }
}

class ClaudeAPI {
    /// Kept only for source compatibility with the original interface. Runtime
    /// arguments pin the supported Claude model family.
    var model: String

    /// The currently running model process (if any), reachable across threads so
    /// the MainActor "stop" route (or a new question) can terminate an in-flight
    /// gold answer. Mirrors BackgroundAgent's RunningProcessBox — Task.cancel()
    /// alone can't interrupt the blocking subprocess, so an abandoned CLI would
    /// otherwise run its full duration (up to 150s) and rapid re-asks would stack
    /// concurrent model processes.
    private let runningProcessBox: RunningProcessBox
    private let modelProcessAdmission: StealthModelProcessAdmission
    private let entryLatch: StealthEntryLatch

    /// `proxyURL` is ignored — there is no proxy anymore. The parameter stays so
    /// the existing `ClaudeAPI(proxyURL:model:)` call sites keep compiling.
    init(
        proxyURL: String,
        model: String = "claude-sonnet-4-6",
        entryLatch: StealthEntryLatch = .shared
    ) {
        let runningProcessBox = RunningProcessBox()
        self.model = model
        self.runningProcessBox = runningProcessBox
        self.entryLatch = entryLatch
        modelProcessAdmission = StealthModelProcessAdmission(
            entryLatch: entryLatch
        )
        // No model subprocess is prewarmed. Each call receives a fresh,
        // non-persistent, explicitly tool-scoped Claude session.
    }

    /// Terminates an in-flight gold answer. Called when the user says
    /// "stop" or asks a new question, so the abandoned model process doesn't keep
    /// running after the user has moved on (and can't pile up).
    func cancelInFlightAnswer() {
        CodexModelCapabilityPreflight.shared.invalidate(
            reason: .cancellation
        )
        modelProcessAdmission.cancelAll()
        runningProcessBox.terminate()
    }

    /// Streaming entry point used by the main push-to-talk pipeline. The CLI
    /// returns the whole answer at once, so we deliver it as a single
    /// chunk — the call site only uses this to drive progressive display, which
    /// still works with one update.
    /// `persistLogs: false` suppresses every brain.log receipt for this call.
    /// Private Mode reads must leave no prompt, no answer and no screenshot
    /// reference on disk — the mode's promise is that nothing about what was on
    /// screen is written down, and a debug log would quietly break exactly that.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        responseFormat:
            ClaudeBrainResponseFormat = .conversational,
        providerTurn: AceProviderTurn = .capture(),
        interactiveLatencyProfile:
            InteractiveProviderLatencyProfile? = nil,
        persistLogs: Bool = true,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        guard let processGeneration =
            modelProcessAdmission.claimGeneration() else {
            throw CancellationError()
        }
        let modelProcessAdmission = self.modelProcessAdmission
        defer {
            modelProcessAdmission.finish(
                generation: processGeneration
            )
            runningProcessBox.clear(generation: processGeneration)
        }
        let startTime = Date()
        AceProviderInvocationReceiptStore.recordStarted(providerTurn)
        let answerText: String
        do {
            answerText = try await runBrainAnswer(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                persistLogs: persistLogs,
                userPrompt: userPrompt,
                responseFormat: responseFormat,
                providerTurn: providerTurn,
                interactiveLatencyProfile:
                    interactiveLatencyProfile,
                processGeneration: processGeneration
            )
        } catch is CancellationError {
            AceProviderInvocationReceiptStore.recordFinished(
                providerTurn,
                phase: .cancelled
            )
            throw CancellationError()
        } catch {
            AceProviderInvocationReceiptStore.recordFinished(
                providerTurn,
                phase: .failed
            )
            throw error
        }
        let didPublishText = await MainActor.run {
            guard modelProcessAdmission.isCurrent(
                generation: processGeneration
            ) else {
                return false
            }
            onTextChunk(answerText)
            return modelProcessAdmission.isCurrent(
                generation: processGeneration
            )
        }
        guard didPublishText,
              modelProcessAdmission.isCurrent(
                generation: processGeneration
              ) else {
            throw CancellationError()
        }
        AceProviderInvocationReceiptStore.recordFinished(
            providerTurn,
            phase: .completed
        )
        return (
            text: answerText,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    /// Non-streaming variant used for validation requests.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        providerTurn: AceProviderTurn = .capture(),
        interactiveLatencyProfile:
            InteractiveProviderLatencyProfile? = nil
    ) async throws -> (text: String, duration: TimeInterval) {
        guard let processGeneration =
            modelProcessAdmission.claimGeneration() else {
            throw CancellationError()
        }
        let modelProcessAdmission = self.modelProcessAdmission
        defer {
            modelProcessAdmission.finish(
                generation: processGeneration
            )
            runningProcessBox.clear(generation: processGeneration)
        }
        let startTime = Date()
        let answerText = try await runBrainAnswer(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            providerTurn: providerTurn,
            interactiveLatencyProfile:
                interactiveLatencyProfile,
            processGeneration: processGeneration
        )
        guard modelProcessAdmission.isCurrent(
            generation: processGeneration
        ) else {
            throw CancellationError()
        }
        return (
            text: answerText,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    /// Converts one natural-language app request into value-only JSON. This is
    /// deliberately separate from every conversational transport: no warm
    /// thread, history, screenshot, tool, MCP server, browser, approval token,
    /// or executable path enters the turn. The returned text is still
    /// untrusted; AppActionPlanner and AppActionBroker validate it before any
    /// confirmation can be requested.
    func proposeAppActionPlan(
        systemPrompt: String,
        userRequest: String
    ) async throws -> String {
        let providerTurn = AceProviderTurn.capture()
        guard let processGeneration =
            modelProcessAdmission.claimGeneration() else {
            throw CancellationError()
        }
        let modelProcessAdmission = self.modelProcessAdmission
        defer {
            modelProcessAdmission.finish(
                generation: processGeneration
            )
            runningProcessBox.clear(generation: processGeneration)
        }
        let startedAt = Date()
        let usesHostedBrain = AceBrainRoute.current == .founderHosted
        do {
            return try await performAppActionPlan(
                systemPrompt: systemPrompt, userRequest: userRequest,
                providerTurn: providerTurn, processGeneration: processGeneration,
                usesHostedBrain: usesHostedBrain
            )
        } catch {
            if !usesHostedBrain, !(error is CancellationError), !Task.isCancelled,
               modelProcessAdmission.isCurrent(generation: processGeneration) {
                AceProviderInvocationReceiptStore.recordRuntimeFailure(
                    providerTurn, startedAt: startedAt,
                    cause: AceReasoningRecoveryPolicy.failureCause(
                        errorTypeName: String(describing: type(of: error)),
                        errorDescription: error.localizedDescription
                    )
                )
            }
            throw error
        }
    }

    private func performAppActionPlan(
        systemPrompt: String, userRequest: String,
        providerTurn: AceProviderTurn, processGeneration: UInt64,
        usesHostedBrain: Bool
    ) async throws -> String {
        let modelProcessAdmission = self.modelProcessAdmission
        let temporaryDirectory =
            try await ClaudePrivateIOWorker.perform {
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                let temporaryDirectory =
                    try Self.createPrivateTemporaryDirectory(
                        prefix: "ace-action-planner"
                    )
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    try? FileManager.default.removeItem(
                        at: temporaryDirectory
                    )
                    throw CancellationError()
                }
                return temporaryDirectory
            }
        defer {
            ClaudePrivateIOWorker.schedule {
                try? FileManager.default.removeItem(
                    at: temporaryDirectory
                )
            }
        }

        let prompt: String =
            try await ClaudePrivateIOWorker.perform {
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                let localClockFormatter = DateFormatter()
                localClockFormatter.locale =
                    Locale(identifier: "en_US_POSIX")
                localClockFormatter.timeZone = .current
                localClockFormatter.dateFormat =
                    "yyyy-MM-dd HH:mm:ss ZZZZ"
                let encodedRequest =
                    Self.quotedJSONString(userRequest)
                let prompt = """
                \(systemPrompt)

                Current local clock: \(localClockFormatter.string(from: Date()))
                User request as a JSON string: \(encodedRequest)
                """
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                return prompt
            }

        if usesHostedBrain {
            let output = try await HostedBrainClient.complete(
                kind: .planner,
                prompt: prompt,
                isCurrent: { modelProcessAdmission.isCurrent(generation: processGeneration) }
            )
            guard modelProcessAdmission.isCurrent(
                generation: processGeneration
            ) else {
                throw CancellationError()
            }
            return output
        }

        let selectedCLI = providerTurn.provider
        if selectedCLI == .qwen {
            let local = try await AceLocalBrain.envelopeText(
                images: [],
                systemPrompt: systemPrompt,
                userPrompt: prompt,
                responseFormat: .strictJSON,
                timeout: 180,
                entryLatch: entryLatch
            )
            guard modelProcessAdmission.isCurrent(
                generation: processGeneration
            ) else {
                throw CancellationError()
            }
            return local.text
        }
        let executablePath: String =
            try await ClaudePrivateIOWorker.perform {
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                guard let executablePath =
                    BrainBackend.resolveExecutable(for: selectedCLI) else {
                    throw NSError(
                        domain: "AceAppActionPlanner",
                        code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "the isolated Claude planner is not installed",
                        ]
                    )
                }
                return executablePath
            }
        let answerFileURL = temporaryDirectory
            .appendingPathComponent("plan-\(UUID().uuidString).json")
        // This is a value parser, not an agent lane. Giving it the Red lane's
        // full-access argv made simple app/site commands pay agent startup and
        // reasoning costs before Ace could perform one native action. Codex
        // receives one ephemeral, read-only, low-reasoning turn and writes only
        // its final JSON. Claude receives the existing isolated one-turn,
        // no-tool conversational shape.
        let arguments: [String]
        let standardOutputFileURL: URL?
        switch selectedCLI {
        case .codex:
            let resolvedModel = try await BrainBackend.resolveCodexModel(
                executablePath: executablePath
            )
            arguments = BrainBackend.codexExecutionArguments([
                "exec",
                "--sandbox", "read-only",
                "--skip-git-repo-check",
                "--color", "never",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "-c", "model_reasoning_effort=\"low\"",
                "--output-last-message", answerFileURL.path,
                "-",
            ], resolvedModel: resolvedModel)
            standardOutputFileURL = nil
        case .claude:
            arguments = BrainBackend.conversationalClaudeArguments(
                model: AceClaudeModel.currentSelection
            )
            standardOutputFileURL = answerFileURL
        case .qwen:
            preconditionFailure("Qwen action planning uses its local API")
        }
        guard modelProcessAdmission.isCurrent(
            generation: processGeneration
        ) else {
            throw CancellationError()
        }
        try await runProcessToCompletion(
            executablePath: executablePath,
            arguments: arguments,
            standardInput: prompt,
            workingDirectory: temporaryDirectory,
            timeout: 20,
            standardOutputFileURL: standardOutputFileURL,
            environment: BrainBackend.processEnvironment(
                claudeExecutablePath: executablePath
            ),
            processGeneration: processGeneration
        )

        try Task.checkCancellation()
        let output: String =
            try await ClaudePrivateIOWorker.perform {
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                let output = (try? String(
                    contentsOf: answerFileURL,
                    encoding: .utf8
                ))?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                return output
            }
        guard !output.isEmpty else {
            throw NSError(
                domain: "AceAppActionPlanner",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "the isolated planner returned no JSON",
                ]
            )
        }
        return output
    }

    /// Writes captured monitor images to an isolated temporary directory, gives
    /// Claude only its built-in Read tool, and returns the spoken answer.
    private func runBrainAnswer(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        persistLogs: Bool = true,
        userPrompt: String,
        responseFormat:
            ClaudeBrainResponseFormat = .conversational,
        providerTurn: AceProviderTurn,
        interactiveLatencyProfile:
            InteractiveProviderLatencyProfile?,
        processGeneration: UInt64
    ) async throws -> String {
        let startedAt = Date()
        let usesHostedBrain = AceBrainRoute.current == .founderHosted
        do {
            return try await performBrainAnswer(
                images: images, systemPrompt: systemPrompt,
                conversationHistory: conversationHistory, persistLogs: persistLogs,
                userPrompt: userPrompt, responseFormat: responseFormat,
                providerTurn: providerTurn, interactiveLatencyProfile: interactiveLatencyProfile,
                usesHostedBrain: usesHostedBrain, processGeneration: processGeneration
            )
        } catch {
            if !usesHostedBrain, !(error is CancellationError), !Task.isCancelled,
               modelProcessAdmission.isCurrent(generation: processGeneration) {
                AceProviderInvocationReceiptStore.recordRuntimeFailure(
                    providerTurn, startedAt: startedAt,
                    cause: AceReasoningRecoveryPolicy.failureCause(
                        errorTypeName: String(describing: type(of: error)),
                        errorDescription: error.localizedDescription
                    )
                )
            }
            throw error
        }
    }

    private func performBrainAnswer(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        persistLogs: Bool = true,
        userPrompt: String,
        responseFormat:
            ClaudeBrainResponseFormat = .conversational,
        providerTurn: AceProviderTurn,
        interactiveLatencyProfile:
            InteractiveProviderLatencyProfile?,
        usesHostedBrain: Bool,
        processGeneration: UInt64
    ) async throws -> String {
        let modelProcessAdmission = self.modelProcessAdmission
        try await ClaudePrivateIOWorker.perform {
            guard modelProcessAdmission.isCurrent(
                generation: processGeneration
            ) else {
                throw CancellationError()
            }
            Self.appendBrainLog(
                persistLogs: persistLogs,
                "REQUEST transcriptChars=\(userPrompt.count) images=\(images.count)"
                    + (interactiveLatencyProfile.map {
                        " interactiveBudget=\(Int($0.hardTimeoutSeconds))s"
                    } ?? "")
            )
            // The transcript is written at the utterance intake and at the
            // voice queue instead — those two see deterministic routes as well,
            // and recording here too would double every model-bound turn.
            guard modelProcessAdmission.isCurrent(
                generation: processGeneration
            ) else {
                throw CancellationError()
            }
        }

        if usesHostedBrain {
            let composedPrompt = Self.composePrompt(
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                imageLabels: images.map(\.label),
                userPrompt: userPrompt,
                responseFormat: responseFormat
            )
            let answerText = try await HostedBrainClient.complete(
                kind: responseFormat.hostedRequestKind,
                prompt: composedPrompt,
                images: images.map {
                    HostedBrainImage(data: $0.data, label: $0.label)
                },
                isCurrent: { modelProcessAdmission.isCurrent(generation: processGeneration) }
            )
            guard modelProcessAdmission.isCurrent(
                generation: processGeneration
            ) else {
                throw CancellationError()
            }
            try await ClaudePrivateIOWorker.perform {
                Self.appendBrainLog(
                    persistLogs: persistLogs,
                    "HQ-CLI answered chars=\(answerText.count)"
                )
            }
            return answerText
        }

        if providerTurn.provider == .qwen {
            let local = try await AceLocalBrain.envelopeText(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                responseFormat: responseFormat,
                entryLatch: entryLatch
            )
            guard modelProcessAdmission.isCurrent(
                generation: processGeneration
            ) else {
                throw CancellationError()
            }
            try await ClaudePrivateIOWorker.perform {
                Self.appendBrainLog(
                    persistLogs: persistLogs,
                    "QWEN answered chars=\(local.text.count)"
                )
            }
            return local.text
        }

        let temporaryDirectory =
            try await ClaudePrivateIOWorker.perform {
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                let temporaryDirectory =
                    try Self.createPrivateTemporaryDirectory(
                        prefix: "blacklabel-brain"
                    )
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    try? FileManager.default.removeItem(
                        at: temporaryDirectory
                    )
                    throw CancellationError()
                }
                return temporaryDirectory
            }
        defer {
            ClaudePrivateIOWorker.schedule {
                try? FileManager.default.removeItem(
                    at: temporaryDirectory
                )
            }
        }

        // Attach each monitor's screenshot. Keep the label→file order so the
        // prompt can tell Claude which image is which screen, matching the
        // [POINT:x,y:label:screenN] contract the overlay parses.
        var imageFilePaths: [String] = []
        for (imageIndex, image) in images.enumerated() {
            let isPNG = image.data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            let imageFileURL = temporaryDirectory
                .appendingPathComponent("screen\(imageIndex + 1).\(isPNG ? "png" : "jpg")")
            let didWritePrivateImage =
                try await ClaudePrivateIOWorker.perform {
                    try Self.writePrivateTemporaryData(
                        image.data,
                        to: imageFileURL,
                        generation: processGeneration,
                        admission: modelProcessAdmission
                    )
                }
            guard didWritePrivateImage else {
                throw CancellationError()
            }
            imageFilePaths.append(imageFileURL.path)
        }

        do {
            let turnStartedAt = Date()
            let answerText = try await runClaudeAnswer(
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt,
                images: images,
                imageFilePaths: imageFilePaths,
                temporaryDirectory: temporaryDirectory,
                responseFormat: responseFormat,
                persistLogs: persistLogs,
                providerTurn: providerTurn,
                interactiveLatencyProfile:
                    interactiveLatencyProfile,
                processGeneration: processGeneration
            )
            let seconds = String(
                format: "%.2f",
                Date().timeIntervalSince(turnStartedAt)
            )
            try await ClaudePrivateIOWorker.perform {
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                Self.appendBrainLog(
                    persistLogs: persistLogs,
                    "PROVIDER \(providerTurn.provider.rawValue) answered in \(seconds)s"
                )
                Self.appendBrainLog(
                    persistLogs: persistLogs,
                    "ANSWER chars=\(answerText.count)"
                )
                // Ace's side is recorded once, at the voice queue.
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
            }
            return answerText
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled
                || !modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) {
                throw CancellationError()
            }
            try? await ClaudePrivateIOWorker.perform {
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    return
                }
                Self.appendBrainLog(
                    persistLogs: persistLogs,
                    "ERROR \(providerTurn.provider.displayName) run failed: \(error.localizedDescription)"
                )
            }
            throw error
        }
    }

    /// Runs one gold answer through the Claude CLI. Claude has no image
    /// attachment flag, so the screenshots are referenced by file path in the
    /// prompt and claude views them with its Read tool (never permission-
    /// gated). Stdout is captured into answer.txt; stderr stays on a
    /// separate drain so a CLI warning can never leak into a spoken answer.
    private func runClaudeAnswer(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        images: [(data: Data, label: String)],
        imageFilePaths: [String],
        temporaryDirectory: URL,
        responseFormat: ClaudeBrainResponseFormat,
        persistLogs: Bool,
        providerTurn: AceProviderTurn,
        interactiveLatencyProfile:
            InteractiveProviderLatencyProfile?,
        processGeneration: UInt64
    ) async throws -> String {
        let modelProcessAdmission = self.modelProcessAdmission
        let selectedCLI = providerTurn.provider
        let laneReceipt: String
        switch selectedCLI {
        case .codex:
            laneReceipt =
                " reasoning="
                + (interactiveLatencyProfile?.reasoningEffort.rawValue
                    ?? (responseFormat.usesStructuredJSON
                        ? "high" : "medium"))
                + " sandbox=read-only auth=file"
        case .claude:
            laneReceipt =
                " reasoning=provider-default sandbox=provider-isolated"
                + " auth=subscription-cli"
        case .qwen:
            laneReceipt =
                " reasoning=local sandbox=typed-capabilities auth=none"
        }
        Self.appendBrainLog(
            persistLogs: persistLogs,
            "LANE cli=\(selectedCLI.rawValue) mode="
                + responseFormat.diagnosticLane
                + laneReceipt
        )
        let claudeExecutablePath: String =
            try await ClaudePrivateIOWorker.perform {
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                guard let claudeExecutablePath =
                    BrainBackend.resolveExecutable(for: selectedCLI) else {
                    throw NSError(
                        domain: "ClaudeBrain",
                        code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Ace's bundled \(selectedCLI.displayName) runtime is missing. Reinstall Ace to repair it.",
                        ]
                    )
                }
                return claudeExecutablePath
            }

        let composedPrompt: String =
            try await ClaudePrivateIOWorker.perform {
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                let imageFileReferences =
                    zip(images.map(\.label), imageFilePaths)
                    .map { (label: $0.0, path: $0.1) }
                let composedPrompt = Self.composePrompt(
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    imageLabels: images.map(\.label),
                    userPrompt: userPrompt,
                    responseFormat: responseFormat,
                    imageFileReferences: imageFileReferences,
                    provider: selectedCLI
                )
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                return composedPrompt
            }

        let answerFileURL = temporaryDirectory.appendingPathComponent("answer.txt")
        var answerInstructionsFilePath: String?
        if selectedCLI == .codex, interactiveLatencyProfile != nil {
            let instructionsURL = temporaryDirectory
                .appendingPathComponent("ace-answer-instructions.txt")
            let written = try await ClaudePrivateIOWorker.perform {
                try Self.writePrivateTemporaryData(
                    Data(InteractiveProviderLatencyPolicy.codexAnswerInstructions.utf8),
                    to: instructionsURL,
                    generation: processGeneration,
                    admission: modelProcessAdmission
                )
            }
            guard written else { throw CancellationError() }
            answerInstructionsFilePath = instructionsURL.path
        }
        // Codex enforces the selected app-owned envelope natively. A failed
        // write passes nil and the existing fail-closed decoder remains the
        // backstop.
        var structuredOutputSchemaFilePath: String?
        if selectedCLI == .codex {
            let schemaFileURL = temporaryDirectory
                .appendingPathComponent("output-schema.json")
            let schemaData: Data?
            switch responseFormat {
            case .partnerJSON:
                schemaData = Data(PartnerResponseSchema.outputSchemaJSON.utf8)
            case .typedDelegationJSON:
                schemaData = Data(
                    GoldResponseEnvelope.outputSchemaJSON.utf8
                )
            case .localMultipleChoicePointing:
                schemaData = try? JSONSerialization.data(
                    withJSONObject: AceLocalPointingOutput.jsonSchema,
                    options: [.sortedKeys]
                )
            case .conversational, .strictJSON, .localPointingJSON:
                schemaData = nil
            }
            if let schemaData {
                let written: Bool =
                    (try? await ClaudePrivateIOWorker.perform {
                        try schemaData.write(
                            to: schemaFileURL,
                            options: .atomic
                        )
                        return true
                    }) ?? false
                if written {
                    structuredOutputSchemaFilePath = schemaFileURL.path
                }
            }
        }
        // Claude carries the gold contract as typed tools served by Ace's own
        // binary. A failed config write falls back to the free-text envelope
        // lane, which the decoder's salvage already guards.
        var goldToolMCPConfigFilePath: String?
        if selectedCLI == .claude, responseFormat == .typedDelegationJSON,
           let serverExecutablePath = Bundle.main.executablePath {
            let configFileURL = temporaryDirectory
                .appendingPathComponent("gold-mcp.json")
            let configObject: [String: Any] = [
                "mcpServers": [
                    "ace": [
                        "command": serverExecutablePath,
                        "args": [AceGoldToolServer.launchFlag],
                    ]
                ]
            ]
            let written: Bool = (try? await ClaudePrivateIOWorker.perform {
                let data = try JSONSerialization.data(
                    withJSONObject: configObject
                )
                try data.write(to: configFileURL, options: .atomic)
                return true
            }) ?? false
            if written {
                goldToolMCPConfigFilePath = configFileURL.path
            }
        }
        // The owner's picker selection becomes real argv here — the closed
        // enum maps the stored identifier and falls back to Sonnet for any
        // value this build cannot represent.
        let selectedClaudeModel = AceClaudeModel(storedModelID: model)
        let brainArguments: [String]
        if selectedCLI == .codex {
            brainArguments = try await BrainBackend
                .resolvedCodexScreenshotAnswerArguments(
                    executablePath: claudeExecutablePath,
                    answerFilePath: answerFileURL.path,
                    imageFilePaths: imageFilePaths,
                    model: selectedClaudeModel,
                    responseFormat: responseFormat,
                    structuredOutputSchemaFilePath:
                        structuredOutputSchemaFilePath,
                    answerInstructionsFilePath: answerInstructionsFilePath,
                    interactiveLatencyProfile:
                        interactiveLatencyProfile,
                    resolveModel: { [entryLatch] executablePath in
                        try await BrainBackend.resolveCodexModel(
                            executablePath: executablePath,
                            entryLatch: entryLatch
                        )
                    }
                )
            guard modelProcessAdmission.isCurrent(
                generation: processGeneration
            ) else {
                throw CancellationError()
            }
        } else if selectedCLI == .qwen {
            brainArguments = AceLocalBrain.cliAnswerArguments(
                json: responseFormat.usesStructuredJSON
            )
        } else if let goldToolMCPConfigFilePath {
            brainArguments = BrainBackend.goldToolClaudeArguments(
                mcpConfigFilePath: goldToolMCPConfigFilePath,
                model: selectedClaudeModel
            )
        } else {
            brainArguments = BrainBackend.screenshotAnswerArguments(
                for: selectedCLI,
                answerFilePath: answerFileURL.path,
                imageFilePaths: imageFilePaths,
                model: selectedClaudeModel,
                resolvedCodexModel: nil,
                responseFormat: responseFormat,
                structuredOutputSchemaFilePath: structuredOutputSchemaFilePath,
                interactiveLatencyProfile:
                    interactiveLatencyProfile
            )
        }
        let standardOutputFileURL =
            BrainBackend.screenshotAnswerCapturesStandardOutput(
                for: selectedCLI
            ) ? answerFileURL : nil

        try await runProcessToCompletion(
            executablePath: claudeExecutablePath,
            arguments: brainArguments,
            standardInput: composedPrompt,
            // The screenshot temp dir (not $HOME) keeps stray CLAUDE.md
            // project context out of the call — the composed prompt is the
            // whole framing.
            workingDirectory: temporaryDirectory,
            timeout: interactiveLatencyProfile?
                .hardTimeoutSeconds ?? 150,
            standardOutputFileURL: standardOutputFileURL,
            environment: BrainBackend.processEnvironment(
                claudeExecutablePath: claudeExecutablePath
            ),
            processGeneration: processGeneration
        )

        let answerText: String =
            try await ClaudePrivateIOWorker.perform {
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                let answerText = (try? String(
                    contentsOf: answerFileURL,
                    encoding: .utf8
                ))?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) ?? ""
                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    throw CancellationError()
                }
                return answerText
            }
        guard !answerText.isEmpty else {
            throw NSError(domain: "ClaudeBrain", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "\(selectedCLI.displayName) returned an empty answer.",
            ])
        }
        if goldToolMCPConfigFilePath != nil {
            // The tool-lane transcript is stream-json; translate the typed
            // calls into the exact envelope text the gold decoder admits. A
            // turn with no typed call hands back the model's free text for
            // the decoder's salvage, exactly like the pre-tool lane.
            return GoldToolEventTranslation.envelopeText(
                fromStreamJSON: answerText
            ) ?? answerText
        }
        if selectedCLI == .codex,
           responseFormat == .localMultipleChoicePointing {
            guard let rendered = AceLocalPointingOutput.renderedResponse(
                from: answerText,
                privateAnswer: true
            ) else {
                throw NSError(domain: "AcePrivateAnswer", code: -3, userInfo: [
                    NSLocalizedDescriptionKey: "The provider returned a malformed private answer envelope.",
                ])
            }
            return rendered
        }
        return answerText
    }

    /// Composes the single prompt a brain turn receives. Claude receives
    /// `imageFileReferences` so each screenshot is referenced by its temporary
    /// on-disk path and can be viewed through the only allowed tool, Read.
    nonisolated static func composePrompt(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        imageLabels: [String],
        userPrompt: String,
        responseFormat:
            ClaudeBrainResponseFormat = .conversational,
        imageFileReferences: [(label: String, path: String)]? = nil,
        provider: BrainCLI = .claude
    ) -> String {
        var promptSections: [String] = [systemPrompt]
        if !conversationHistory.isEmpty {
            let priorTurns = conversationHistory
                .map { "User: \($0.userPlaceholder)\nYou: \($0.assistantResponse)" }
                .joined(separator: "\n")
            promptSections.append("Earlier in this conversation:\n\(priorTurns)")
        }
        if provider == .claude,
           let imageFileReferences, !imageFileReferences.isEmpty {
            let screenFileDescription = imageFileReferences.enumerated()
                .map { "Attached image \($0.offset + 1) is \($0.element.label): view the file \($0.element.path) with your Read tool before answering." }
                .joined(separator: " ")
            promptSections.append(screenFileDescription)
        } else if !imageLabels.isEmpty {
            let screenIndexDescription = imageLabels.enumerated()
                .map { "Attached image \($0.offset + 1) is \($0.element)." }
                .joined(separator: " ")
            promptSections.append(screenIndexDescription)
        }
        promptSections.append(
            "The current owner request admitted by Ace"
                + " (and deterministically resolved only when it contains"
                + " bounded continuation wording): \(userPrompt)"
        )
        switch responseFormat {
        case .conversational:
            promptSections.append(
                "Answer them directly and conversationally in 1-3 sentences, like a teacher sitting next to them. "
                + "Do NOT run any shell commands or write any files — only look at the attached screenshots and answer. "
                + "Follow the [POINT:...] instructions above so the on-screen cursor can point at what you mention."
            )
        case .typedDelegationJSON:
            promptSections.append(
                "When the typed reply, clarify, open_on_screen, and execute_objective tools are available, call exactly one and stop immediately after its result. "
                    + "Do not call a second tool, add prose, or report that execution completed. "
                    + "Only when those typed tools are unavailable, return the single JSON object required by the system contract without Markdown or surrounding prose."
            )
        case .strictJSON, .partnerJSON, .localPointingJSON:
            promptSections.append(
                "Return only the JSON value required by the system contract. "
                    + "Do not add Markdown fences, commentary, or prose "
                    + "outside that JSON value."
            )
        case .localMultipleChoicePointing:
            promptSections.append(
                "Return only the multiple-choice result required by the system contract. Do not add conversational prose or any second answer format."
            )
        }
        return promptSections.joined(separator: "\n\n")
    }

    fileprivate nonisolated static func quotedJSONString(
        _ value: String
    ) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: [value],
            options: [.withoutEscapingSlashes]
        ),
        let encoded = String(data: data, encoding: .utf8),
        encoded.count >= 2 else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }

    /// Claude needs real files for its scoped Read lane, but those files must
    /// never inherit the process's ordinary 0755/0644 defaults. A second local
    /// account cannot inspect a live or crash-stranded screenshot/answer.
    private nonisolated static func createPrivateTemporaryDirectory(
        prefix: String
    ) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directoryURL
    }

    /// Normal completion removes each scoped directory with `defer`. A hard
    /// kill cannot run that cleanup, so the next launch removes only Ace's
    /// UUID-suffixed private-input directories from this user's temporary
    /// root. Symlinks and non-directories are never followed or removed.
    static func purgePrivateTemporaryInputsFromPriorRuns() {
        let temporaryRoot = FileManager.default.temporaryDirectory
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let allowedDirectoryPrefixes = [
            "blacklabel-brain-",
            "ace-action-planner-",
        ]
        let privateInputFilePrefix = "ace-model-input-"
        for candidate in candidates {
            let isAllowedDirectory =
                allowedDirectoryPrefixes.contains(
                    where: {
                        candidate.lastPathComponent.hasPrefix($0)
                    }
                )
            let isAllowedPrivateInputFile =
                candidate.lastPathComponent.hasPrefix(
                    privateInputFilePrefix
                )
            guard isAllowedDirectory
                    || isAllowedPrivateInputFile,
                  let values = try? candidate.resourceValues(
                    forKeys: keys
                  ),
                  values.isSymbolicLink != true else {
                continue
            }
            if isAllowedDirectory {
                guard values.isDirectory == true else { continue }
            } else {
                guard values.isRegularFile == true else { continue }
            }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private nonisolated static func writePrivateTemporaryData(
        _ data: Data,
        to fileURL: URL,
        generation: UInt64,
        admission: StealthModelProcessAdmission
    ) throws -> Bool {
        guard admission.isCurrent(generation: generation) else {
            return false
        }
        let fileDescriptor = fileURL.path.withCString {
            open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard fileDescriptor >= 0 else {
            throw NSError(
                domain: "ClaudeBrain",
                code: -4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "could not create a private temporary input file.",
                ]
            )
        }
        let didWriteAllData =
            StealthPrivateDataStager.writeChunksIfCurrent(
                data,
                generation: generation,
                admission: admission
            ) { chunkBytes in
                while true {
                    let result = Darwin.write(
                        fileDescriptor,
                        chunkBytes.baseAddress,
                        chunkBytes.count
                    )
                    if result < 0, errno == EINTR {
                        continue
                    }
                    return result
                }
            }
        close(fileDescriptor)
        guard didWriteAllData,
              admission.isCurrent(generation: generation) else {
            try? FileManager.default.removeItem(at: fileURL)
            if admission.isCurrent(generation: generation) {
                throw NSError(
                    domain: "ClaudeBrain",
                    code: -4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "could not write a private temporary input file.",
                    ]
                )
            }
            return false
        }
        return true
    }

    /// Durable, readable proof channel: append each brain call and its answer to a
    /// file so end-to-end behavior can be verified by job output rather than a
    /// "it worked" self-report. os_log does not reliably surface from release builds.
    /// Internal for the app's local observability paths.
    /// `persistLogs: false` makes this a no-op, so a Private Mode read creates no
    /// durable log. Its 0600 model-input copy is separately deleted at request
    /// completion and purged on the next launch after a hard kill.
    nonisolated static func appendBrainLog(
        persistLogs: Bool = true,
        _ message: String
    ) {
        guard persistLogs else { return }
        guard let supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true) else { return }
        // 0700 or the bundled tools all fail closed — see LifecycleLog.append.
        try? PrivateSupportDirectory.ensure(at: supportDirectory)
        let logFileURL = supportDirectory.appendingPathComponent("brain.log")
        let safeMessage = message
            .components(separatedBy: .newlines)
            .joined(separator: "\\n")
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
        let line =
            "\(ISO8601DateFormatter().string(from: Date())) \(safeMessage)\n"
        guard let lineData = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        } else {
            try? lineData.write(to: logFileURL, options: .atomic)
        }
    }

    /// Runs a subprocess off the main thread, feeds it `standardInput`, drains its
    /// output so the pipe never blocks, and enforces a hard timeout so a hung
    /// model process can never freeze the assistant.
    private func runProcessToCompletion(
        executablePath: String,
        arguments: [String],
        standardInput: String,
        workingDirectory: URL,
        timeout timeoutSeconds: TimeInterval,
        standardOutputFileURL: URL? = nil,
        environment: [String: String]? = nil,
        processGeneration: UInt64
    ) async throws {
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        [modelProcessAdmission, runningProcessBox] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.environment = environment
                    ?? BrainBackend.processEnvironment(
                        claudeExecutablePath: executablePath
                    )

                let outputPipe = Pipe()

                let privateInputFileHandle: FileHandle
                do {
                    guard let stagedInput =
                        try PrivateModelStandardInput.stage(
                            standardInput: standardInput,
                            generation: processGeneration,
                            admission: modelProcessAdmission
                        ) else {
                        continuation.resume(
                            throwing: CancellationError()
                        )
                        return
                    }
                    privateInputFileHandle = stagedInput
                    process.standardInput = privateInputFileHandle
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // When a capture file is given (the claude transport), stdout
                // IS the answer and goes to that file, while stderr drains on
                // the pipe so warnings never mix into the spoken text. Without
                // one, both streams drain together.
                var answerCaptureFileHandle: FileHandle?
                if let standardOutputFileURL {
                    guard modelProcessAdmission.isCurrent(
                        generation: processGeneration
                    ) else {
                        try? privateInputFileHandle.close()
                        continuation.resume(
                            throwing: CancellationError()
                        )
                        return
                    }
                    let captureFileDescriptor =
                        standardOutputFileURL.path.withCString {
                            open(
                                $0,
                                O_WRONLY
                                    | O_CREAT
                                    | O_EXCL
                                    | O_NOFOLLOW,
                                mode_t(0o600)
                            )
                        }
                    guard captureFileDescriptor >= 0 else {
                        try? privateInputFileHandle.close()
                        runningProcessBox.clear(
                            generation: processGeneration
                        )
                        continuation.resume(throwing: NSError(
                            domain: "ClaudeBrain",
                            code: -3,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "could not create the private answer capture file.",
                            ]
                        ))
                        return
                    }
                    answerCaptureFileHandle = FileHandle(
                        fileDescriptor: captureFileDescriptor,
                        closeOnDealloc: true
                    )
                    guard modelProcessAdmission.isCurrent(
                        generation: processGeneration
                    ) else {
                        try? privateInputFileHandle.close()
                        try? answerCaptureFileHandle?.close()
                        try? FileManager.default.removeItem(
                            at: standardOutputFileURL
                        )
                        continuation.resume(
                            throwing: CancellationError()
                        )
                        return
                    }
                    process.standardOutput =
                        answerCaptureFileHandle
                    process.standardError = outputPipe
                } else {
                    process.standardOutput = outputPipe
                    process.standardError = outputPipe
                }

                let wasLaunched: Bool
                do {
                    wasLaunched =
                        try modelProcessAdmission.launchAndPublishIfCurrent(
                            generation: processGeneration,
                            launch: {
                                try process.run()
                                return process.processIdentifier
                            },
                            publish: { _ in
                                runningProcessBox.register(
                                    process,
                                    generation: processGeneration
                                )
                            }
                        )
                } catch {
                    try? privateInputFileHandle.close()
                    try? answerCaptureFileHandle?.close()
                    runningProcessBox.clear(generation: processGeneration)
                    continuation.resume(throwing: error)
                    return
                }
                guard wasLaunched else {
                    try? privateInputFileHandle.close()
                    try? answerCaptureFileHandle?.close()
                    runningProcessBox.clear(
                        generation: processGeneration
                    )
                    continuation.resume(
                        throwing: CancellationError()
                    )
                    return
                }
                try? privateInputFileHandle.close()

                // Drain stdout on a background handler instead of blocking on
                // readDataToEndOfFile(): even in this read-only path a CLI can
                // spawn a child that inherits this pipe, and a surviving
                // grandchild keeps the write end open so EOF never arrives — the
                // old blocking read would then wedge this continuation forever.
                // We resume on process EXIT below, not on pipe EOF; the handler
                // only keeps the buffer from filling (which would stall it).
                let outputHandle = outputPipe.fileHandleForReading
                outputHandle.readabilityHandler = { handle in _ = handle.availableData }

                // Timeout watchdog: SIGTERM first, then escalate to SIGKILL if
                // the process ignores it, so a hung CLI can never freeze the
                // assistant even when it (or a child) swallows the term signal.
                let timeoutWatchdog = DispatchWorkItem {
                    if process.isRunning {
                        RunningProcessBox.terminateProcessTree(process)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWatchdog)

                process.waitUntilExit()
                timeoutWatchdog.cancel()
                outputHandle.readabilityHandler = nil
                try? answerCaptureFileHandle?.close()
                modelProcessAdmission.retireProcess(
                    generation: processGeneration
                )
                runningProcessBox.clear(generation: processGeneration)

                guard modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) else {
                    continuation.resume(
                        throwing: CancellationError()
                    )
                    return
                }
                if process.terminationStatus != 0 {
                    let executableName = (executablePath as NSString).lastPathComponent
                    continuation.resume(throwing: NSError(
                        domain: "ClaudeBrain",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "\(executableName) exited with status \(process.terminationStatus)."]
                    ))
                } else {
                    continuation.resume(returning: ())
                }
            }
                }
            } onCancel: {
                [modelProcessAdmission, runningProcessBox] in
                // Task cancellation must kill the actual CLI tree, including
                // the Process.run → register race. Generation scoping prevents
                // an old cancelled turn from killing a newer answer.
                modelProcessAdmission.cancel(
                    generation: processGeneration
                )
                runningProcessBox.terminate(
                    generation: processGeneration
                )
            }
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled
                || !modelProcessAdmission.isCurrent(
                    generation: processGeneration
                ) {
                throw CancellationError()
            }
            throw error
        }
    }
}
#endif // circuit-convert
