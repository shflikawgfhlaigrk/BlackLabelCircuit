#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  AceLocalBrain.swift
//  Ace
//
//  Ace's third brain provider. Qwen runs as a direct child process through the
//  llama.cpp runtime and GGUF weights sealed inside Ace.app. There is no local
//  service, HTTP endpoint, account, package-manager lookup, or external model
//  installation in this lane.
//
//  Authority note: this lane adds no authority. It produces the same Gold
//  envelope admitted by GoldResponseEnvelope.decode; the admitted owner
//  request and Red remain the only effect boundary.
//

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

nonisolated enum AceLocalBrainError: LocalizedError, Equatable {
    case notEnabled
    case unsupportedArchitecture
    case runtimeMissing
    case modelMissing
    case invalidResponse
    case processFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "Ace's embedded Qwen brain is not selected."
        case .unsupportedArchitecture:
            return "Ace's embedded Qwen brain requires Apple silicon."
        case .runtimeMissing:
            return "Ace's embedded llama.cpp runtime is missing. Reinstall Ace to repair it."
        case .modelMissing:
            return "Ace's embedded Qwen3 model is missing. Reinstall Ace to repair it."
        case .invalidResponse:
            return "Ace's embedded Qwen brain returned an invalid response."
        case .processFailed(let message):
            return message
        }
    }
}

nonisolated enum AceLocalBrain {
    // MARK: - Sealed runtime identity

    static let runtimeVersion = "llama.cpp 9840"
    static let modelTag = "Qwen3 Abliterated 30B-A3B Q4_K_M"
    static let modelFileName =
        "qwen3-abliterated-30b-a3b-q4_k_m.gguf"
    static let modelSHA256 =
        "11b3b371aedb6c43d438ec010e66f9dfaa92127d64c22499891d9013ab7a6ee6"
    static let modelBytes: Int64 = 18_556_685_856
    static let resourceDirectoryName = "qwen"

    static var isEnabled: Bool {
        UserDefaults.standard.string(forKey: "SelectedBrainCLI") == "qwen"
    }

    static func resolveBundledExecutable(
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) -> String? {
#if arch(arm64)
        guard let bundleResourceURL else { return nil }
        let executableURL = bundleResourceURL
            .appendingPathComponent(resourceDirectoryName, isDirectory: true)
            .appendingPathComponent("darwin-arm64", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("llama-cli", isDirectory: false)
        return isRegularFile(executableURL, executable: true)
            ? executableURL.path : nil
#else
        return nil
#endif
    }

    static func resolveBundledModel(
        bundleResourceURL: URL? = Bundle.main.resourceURL
    ) -> String? {
#if arch(arm64)
        guard let bundleResourceURL else { return nil }
        let modelURL = bundleResourceURL
            .appendingPathComponent(resourceDirectoryName, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelFileName, isDirectory: false)
        guard isRegularFile(modelURL, executable: false),
              let values = try? modelURL.resourceValues(
                forKeys: [.fileSizeKey]
              ),
              Int64(values.fileSize ?? -1) == modelBytes else {
            return nil
        }
        return modelURL.path
#else
        return nil
#endif
    }

    private static func isRegularFile(
        _ url: URL,
        executable: Bool
    ) -> Bool {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        return !executable
            || FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Probe argv retained for the shared zero-tool invocation policy. Normal
    /// turns use private prompt/contract files so owner text never enters argv.
    static func cliAnswerArguments(json: Bool = false) -> [String] {
        var arguments = baseArguments(
            modelPath: resolveBundledModel()
                ?? "/__ace_missing_embedded_qwen_model__",
            contextTokens: 4_096,
            maximumOutputTokens: 32
        )
        if json {
            arguments += ["--grammar", jsonGrammar]
        }
        return arguments
    }

    /// This pinned llama.cpp build accepts GBNF directly but throws while
    /// initializing its JSON-Schema sampler. Constrain the bytes to a JSON
    /// object with the built-in grammar, put the exact schema in the private
    /// system prompt, then let Ace's typed decoders enforce shape and values.
    static let jsonGrammar = #"""
        root ::= ws object ws
        object ::= "{" ws (string ":" ws value ("," ws string ":" ws value)*)? "}" ws
        array ::= "[" ws (value ("," ws value)*)? "]" ws
        value ::= object | array | string | number | ("true" | "false" | "null") ws
        string ::= "\"" ([^"\\] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F]))* "\"" ws
        number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [+-]? [0-9]+)? ws
        ws ::= [ \t\n]*
        """#

    static func processEnvironment(
        executablePath: String,
        parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = BrainBackend.processEnvironment(
            executablePath: executablePath,
            parentEnvironment: parent,
            codexHomePath: "/dev/null",
            claudeConfigPath: "/dev/null",
            bundledToolsPath: Bundle.main.resourceURL?
                .appendingPathComponent("tools", isDirectory: true).path
        )
        // The staged executable carries an @executable_path rpath, so no DYLD
        // override or package-manager prefix is inherited by the child.
        for key in environment.keys where key.hasPrefix("DYLD_") {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = [
            (executablePath as NSString).deletingLastPathComponent,
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        environment["NO_COLOR"] = "1"
        return environment
    }

    // MARK: - Gold contract

    static var grammarSchemaObject: [String: Any] {
        guard let data = GoldResponseEnvelope.outputSchemaJSON
                .data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let stripped = strippingMaxLength(object) as? [String: Any]
        else { return [:] }
        return stripped
    }

    private static func strippingMaxLength(_ node: Any) -> Any {
        if let object = node as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in object where key != "maxLength" {
                result[key] = strippingMaxLength(value)
            }
            return result
        }
        if let array = node as? [Any] {
            return array.map(strippingMaxLength)
        }
        return node
    }

    static var localLaneContractText: String {
        decisionRulesText
    }

    static let decisionRulesText = """
        decision rules:
        - the owner's own mail, calendar, reminders, notes, and files are NOT things you know. never answer about them from memory and never invent their contents. request execution using one objective that is a bounded projection of the owner's words.
        - creating, adding, sending, writing, moving, changing, opening, searching, starting, or stopping anything is always execute. never reply that you did it and never reply instead of doing it.
        - reply only for general knowledge, or for what is plainly visible in supplied OCR screen context.
        - clarify only when a required destination or value cannot be bound from the owner's words, supplied OCR screen context, or recent conversation. otherwise execute without asking for confirmation or permission.
        - execute provides only an objective string. never provide a capability, lane, command, path, environment, approval, identity, or work ID.
        """

    // MARK: - Typed turn

    static func envelopeText(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(
            userPlaceholder: String,
            assistantResponse: String
        )] = [],
        userPrompt: String,
        responseFormat:
            ClaudeBrainResponseFormat = .typedDelegationJSON,
        timeout: TimeInterval = 180,
        entryLatch: StealthEntryLatch = .shared
    ) async throws -> (text: String, duration: TimeInterval) {
        guard isEnabled else { throw AceLocalBrainError.notEnabled }
        let started = Date()
        let ocrContext = try await AceLocalVisionOCR.promptContext(
            images: images
        )

        if responseFormat == .localPointingJSON {
            let centerBandOnly = systemPrompt.contains(
                "x must be between 20% and 80%"
            )
            let semanticPrompt = AceLocalSemanticPointing.semanticPrompt(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                ocrContext: ocrContext,
                centerBandOnly: centerBandOnly
            )
            var lastFailure: Error = AceLocalBrainError.invalidResponse
            for attempt in 1...2 {
                try Task.checkCancellation()
                do {
                    let reasoning = try await runInference(
                        systemPrompt:
                            "Choose exactly one supplied OCR target. Follow the requested final-line format.",
                        userPrompt: semanticPrompt
                            + (attempt == 1
                                ? ""
                                : "\n\nThe prior answer had no valid final target. Return the two required final lines exactly."),
                        jsonSchema: nil,
                        contextTokens: 16_384,
                        maximumOutputTokens: 512,
                        timeout: timeout,
                        entryLatch: entryLatch
                    )
                    if let rendered =
                        AceLocalSemanticPointing.renderedResponse(
                            reasoning: reasoning,
                            ocrContext: ocrContext,
                            centerBandOnly: centerBandOnly
                        ) {
                        return (
                            text: rendered,
                            duration: Date().timeIntervalSince(started)
                        )
                    }
                    lastFailure = AceLocalBrainError.invalidResponse
                } catch {
                    lastFailure = error
                }
            }
            throw lastFailure
        }

        if responseFormat == .localMultipleChoicePointing {
            let reasoning = try await runInference(
                systemPrompt: systemPrompt,
                userPrompt:
                    AceLocalMultipleChoicePointing.semanticPrompt(
                        ocrContext: ocrContext
                    ),
                jsonSchema: nil,
                contextTokens: 16_384,
                maximumOutputTokens: 2_048,
                timeout: timeout,
                entryLatch: entryLatch
            )
            guard let rendered =
                AceLocalMultipleChoicePointing.renderedResponse(
                    reasoning: reasoning,
                    ocrContext: ocrContext
                ) else {
                throw AceLocalBrainError.invalidResponse
            }
            return (
                text: rendered,
                duration: Date().timeIntervalSince(started)
            )
        }

        var promptSections: [String] = []
        if !conversationHistory.isEmpty {
            let history = conversationHistory.map {
                "User: \($0.userPlaceholder)\nAssistant: \($0.assistantResponse)"
            }.joined(separator: "\n\n")
            promptSections.append("Earlier conversation:\n\(history)")
        }
        if !ocrContext.isEmpty {
            promptSections.append(
                "Private on-device screen OCR. Use the exact capture and display identities from each screen label. POINT coordinates use the image pixel space and should target the center of the chosen OCR box:\n\(ocrContext)"
            )
        }
        promptSections.append("Current owner request:\n\(userPrompt)")
        if responseFormat.usesStructuredJSON {
            promptSections.append(
                "Return only the JSON value required by the system contract, without Markdown or commentary."
            )
        }

        let effectiveSystemPrompt: String
        switch responseFormat {
        case .typedDelegationJSON:
            effectiveSystemPrompt = systemPrompt + "\n\n" + localLaneContractText
        case .localPointingJSON:
            effectiveSystemPrompt = systemPrompt + "\n\n"
                + AceLocalPointingOutput.systemContract
        case .conversational, .strictJSON, .partnerJSON, .localMultipleChoicePointing:
            effectiveSystemPrompt = systemPrompt
        }
        let schema: [String: Any]?
        switch responseFormat {
        case .typedDelegationJSON:
            schema = grammarSchemaObject
        case .partnerJSON:
            schema = PartnerResponseSchema.jsonSchema
        case .strictJSON:
            schema = [
                "type": "object",
                "additionalProperties": true,
            ]
        case .localPointingJSON:
            schema = AceLocalPointingOutput.jsonSchema
        case .conversational, .localMultipleChoicePointing:
            schema = nil
        }
        let rawAnswer = try await runInference(
            systemPrompt: effectiveSystemPrompt,
            userPrompt: promptSections.joined(separator: "\n\n"),
            jsonSchema: schema,
            contextTokens: 16_384,
            maximumOutputTokens: responseFormat.usesStructuredJSON
                ? 4_096 : 2_048,
            timeout: timeout,
            entryLatch: entryLatch
        )
        let answer: String
        if responseFormat == .localPointingJSON {
            guard let rendered = AceLocalPointingOutput.renderedResponse(
                from: rawAnswer
            ) else {
                throw AceLocalBrainError.invalidResponse
            }
            answer = rendered
        } else {
            answer = rawAnswer
        }
        return (
            text: answer,
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - App-owned local agent loop

    static func agentText(
        systemPrompt: String,
        userPrompt: String,
        workingDirectory: URL,
        toolRoutingObjective: String? = nil,
        browserEnvironment: [String: String] = [:],
        timeout: TimeInterval = 300,
        maximumToolCalls: Int = 12
    ) async throws -> String {
        guard isEnabled else { throw AceLocalBrainError.notEnabled }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["reply", "shell"]],
                "text": ["type": "string"],
                "command": ["type": "string"],
            ],
            "required": ["kind", "text", "command"],
            "additionalProperties": false,
        ]
        let agentSystem = systemPrompt + """

            You work through one app-owned tool named shell. Return exactly one JSON object on every turn.
            To run work: {"kind":"shell","text":"","command":"the exact shell script"}.
            To finish: {"kind":"reply","text":"the concise result grounded in tool output","command":""}.
            Ace's bundled tools are available directly by name. Run at most one mutating bundled tool in each shell turn; Ace issues a fresh one-use authority for every admitted turn.
            Never claim a command ran until its real result appears in the transcript.
            """
        var transcript = "Owner task:\n\(userPrompt)"
        var toolCallCount = 0
        var formatRetryCount = 0

        while toolCallCount <= maximumToolCalls {
            let rawDecision: String
            do {
                rawDecision = try await runInference(
                    systemPrompt: agentSystem,
                    userPrompt: transcript,
                    jsonSchema: schema,
                    contextTokens: 32_768,
                    maximumOutputTokens: 2_048,
                    timeout: timeout
                )
            } catch let error as AceLocalBrainError {
                guard error == .invalidResponse,
                      formatRetryCount < 2 else { throw error }
                formatRetryCount += 1
                transcript += Self.localAgentFormatCorrection
                continue
            }
            guard let decision = AceLocalAgentDecision.decode(
                from: rawDecision
            ) else {
                guard formatRetryCount < 2 else {
                    throw AceLocalBrainError.invalidResponse
                }
                formatRetryCount += 1
                transcript += Self.localAgentFormatCorrection
                continue
            }
            formatRetryCount = 0
            if decision.kind == .reply {
                return decision.text
            }
            guard toolCallCount < maximumToolCalls else {
                throw AceLocalBrainError.processFailed(
                    message: "Qwen reached Ace's bounded local tool-call limit."
                )
            }
            toolCallCount += 1
            let result: BrainConnectionProbe.ProcessRun
            switch RedAgentCommandRoutingPolicy.disposition(
                command: decision.command,
                ownerObjective: toolRoutingObjective ?? ""
            ) {
            case .execute:
                result = try await runAgentShellCommand(
                    decision.command,
                    workingDirectory: workingDirectory,
                    browserEnvironment: browserEnvironment,
                    timeout: min(timeout, 120)
                )
            case .rejectForNotes:
                result = BrainConnectionProbe.ProcessRun(
                    exitCode: 2,
                    standardOutput: "",
                    standardError:
                        "Use note-create only for Apple Note creation. Use desktop-action to open or operate Notes.",
                    timedOut: false
                )
            case .rejectMalformedNoteCreate:
                result = BrainConnectionProbe.ProcessRun(
                    exitCode: 2,
                    standardOutput: "",
                    standardError: "note-create does not accept --title or --text. Do not stop. First run exactly: note-create --targets. After the real target list, run exactly: note-create '<exact-account>' '<exact-folder>' '<title>' '<body>'.",
                    timedOut: false
                )
            case .rejectMissingNoteDestination:
                result = BrainConnectionProbe.ProcessRun(
                    exitCode: 2,
                    standardOutput: "",
                    standardError: "The owner did not name both an exact Notes account and folder. Do not invent either value. Run exactly: note-create --default '<title>' '<body>'. If that reports no iCloud/Notes destination, run note-create --targets and ask the owner to choose.",
                    timedOut: false
                )
            }
            transcript += "\n\nAssistant requested shell:\n\(decision.command)"
            transcript += "\n\nReal shell result:\nexit=\(result.exitCode) timed_out=\(result.timedOut)\n"
            let toolOutput = [result.standardError, result.standardOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            transcript += String(toolOutput.prefix(40_000))
            if transcript.count > 120_000 {
                transcript = String(transcript.suffix(120_000))
            }
        }
        throw AceLocalBrainError.processFailed(
            message: "Qwen reached Ace's bounded local tool-call limit."
        )
    }

    private static let localAgentFormatCorrection = """


        Ace rejected the previous response because it was not one complete
        tool decision. Nothing new ran. Return exactly one JSON object now:
        {"kind":"shell","text":"","command":"exact command"}
        or {"kind":"reply","text":"truthful result","command":""}.
        """

    private static func runAgentShellCommand(
        _ command: String,
        workingDirectory: URL,
        browserEnvironment: [String: String],
        timeout: TimeInterval
    ) async throws -> BrainConnectionProbe.ProcessRun {
        let approval: OwnerTurnEffectAuthority
        do {
            approval = try OwnerTurnEffectAuthority.issue()
        } catch {
            throw RedProviderExecutionProfileError
                .supportDirectoryUnavailable
        }
        defer { approval.destroy() }
        let approvedEnvironment = approval.wrapperEnvironment()
        let trustedAceEnvironment = approvedEnvironment.filter {
            $0.key == "ACE_APP_MUTATION_APPROVED"
                || $0.key == "ACE_APP_MUTATION_TOKEN_PATH"
        }
        guard let resourcesURL = Bundle.main.resourceURL,
              let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
              ).first else {
            throw RedProviderExecutionProfileError
                .supportDirectoryUnavailable
        }
        var toolEnvironment = try RedProviderExecutionProfilePolicy
            .processEnvironment(
                resourcesURL: resourcesURL,
                supportDirectoryURL: applicationSupportURL
                    .appendingPathComponent(
                        "BlackLabel",
                        isDirectory: true
                    ),
                executablePath: "/bin/zsh",
                parent: ProcessInfo.processInfo.environment,
                trustedTurnAuthority: trustedAceEnvironment
            )
        toolEnvironment.merge(browserEnvironment.filter {
            ["ACE_BACKGROUND_BROWSER_PORT", "ACE_BACKGROUND_BROWSER_AUTH"].contains($0.key)
        }) { _, trusted in trusted }
        let backendLaunch = try RedProviderExecutionProfilePolicy.backendProcessLaunch(
            executablePath: "/bin/zsh", arguments: ["-f"]
        )
        return await BrainConnectionProbe.runProcess(
            executablePath: backendLaunch.executablePath,
            arguments: backendLaunch.arguments,
            standardInput: command,
            workingDirectory: workingDirectory,
            environment: toolEnvironment,
            timeout: timeout
        )
    }

    // MARK: - Runtime process

    static func probe() async -> Result<String, AceLocalBrainError> {
#if !arch(arm64)
        return .failure(.unsupportedArchitecture)
#else
        guard resolveBundledExecutable() != nil else {
            return .failure(.runtimeMissing)
        }
        guard resolveBundledModel() != nil else {
            return .failure(.modelMissing)
        }
        do {
            let answer = try await runInference(
                systemPrompt: "Follow the owner's exact output instruction.",
                userPrompt: "Reply with exactly one lowercase word: ready",
                jsonSchema: nil,
                contextTokens: 4_096,
                maximumOutputTokens: 16,
                timeout: 180
            )
            guard answer.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased() == "ready" else {
                return .failure(.invalidResponse)
            }
            return .success("\(modelTag) · \(runtimeVersion)")
        } catch let error as AceLocalBrainError {
            return .failure(error)
        } catch {
            return .failure(.processFailed(
                message: error.localizedDescription
            ))
        }
#endif
    }

    private static func runInference(
        systemPrompt: String,
        userPrompt: String,
        jsonSchema: [String: Any]?,
        contextTokens: Int,
        maximumOutputTokens: Int,
        timeout: TimeInterval,
        entryLatch: StealthEntryLatch = .shared
    ) async throws -> String {
#if !arch(arm64)
        throw AceLocalBrainError.unsupportedArchitecture
#else
        guard let executablePath = resolveBundledExecutable() else {
            throw AceLocalBrainError.runtimeMissing
        }
        guard let modelPath = resolveBundledModel() else {
            throw AceLocalBrainError.modelMissing
        }
        let directory = try createPrivateTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let systemURL = directory.appendingPathComponent("system.txt")
        let promptURL = directory.appendingPathComponent("prompt.txt")
        var effectiveSystemPrompt = systemPrompt
        var structuredOutputRequested = false
        if let jsonSchema {
            let schemaData = try JSONSerialization.data(
                withJSONObject: jsonSchema,
                options: [.sortedKeys]
            )
            guard let schemaText = String(
                data: schemaData,
                encoding: .utf8
            ) else {
                throw AceLocalBrainError.invalidResponse
            }
            effectiveSystemPrompt += """


                REQUIRED STRUCTURED OUTPUT JSON SCHEMA:
                \(schemaText)
                Return exactly one JSON object matching that schema. Do not add Markdown or prose.
                """
            structuredOutputRequested = true
        }
        try writePrivate(effectiveSystemPrompt, to: systemURL)
        try writePrivate(userPrompt, to: promptURL)

        var arguments = baseArguments(
            modelPath: modelPath,
            contextTokens: contextTokens,
            maximumOutputTokens: maximumOutputTokens
        ) + [
            "--system-prompt-file", systemURL.path,
            "--file", promptURL.path,
        ]
        if structuredOutputRequested {
            let grammarURL = directory.appendingPathComponent("json.gbnf")
            try writePrivate(jsonGrammar, to: grammarURL)
            arguments += ["--grammar-file", grammarURL.path]
        }

        let run = await BrainConnectionProbe.runProcess(
            executablePath: executablePath,
            arguments: arguments,
            standardInput: nil,
            workingDirectory: directory,
            environment: processEnvironment(
                executablePath: executablePath
            ),
            timeout: timeout,
            entryLatch: entryLatch
        )
        guard !run.timedOut else {
            throw AceLocalBrainError.processFailed(
                message: "Ace's embedded Qwen brain timed out."
            )
        }
        guard run.exitCode == 0 else {
            let diagnostic = [run.standardError, run.standardOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw AceLocalBrainError.processFailed(
                message: diagnostic.isEmpty
                    ? "Ace's embedded Qwen runtime exited \(run.exitCode)."
                    : String(diagnostic.suffix(600))
            )
        }
        let answer = AceLocalBrainOutputParser.answer(
            from: run.standardOutput,
            echoedPrompt: userPrompt
        )
        guard !answer.isEmpty else {
            throw AceLocalBrainError.invalidResponse
        }
        if structuredOutputRequested {
            guard let json = AceLocalBrainOutputParser
                .structuredJSONObject(from: answer) else {
                throw AceLocalBrainError.invalidResponse
            }
            return json
        }
        return answer
#endif
    }

    private static func baseArguments(
        modelPath: String,
        contextTokens: Int,
        maximumOutputTokens: Int
    ) -> [String] {
        [
            "--model", modelPath,
            "--offline",
            "--simple-io",
            "--conversation",
            "--single-turn",
            "--no-display-prompt",
            "--no-show-timings",
            "--log-disable",
            "--reasoning", "off",
            "--temp", "0",
            "--ctx-size", String(contextTokens),
            "--n-predict", String(maximumOutputTokens),
        ]
    }

    private static func createPrivateTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "blacklabel-brain-qwen-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private static func writePrivate(
        _ value: String,
        to url: URL
    ) throws {
        guard let data = value.data(using: .utf8) else {
            throw AceLocalBrainError.invalidResponse
        }
        try writePrivate(data, to: url)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw AceLocalBrainError.processFailed(
                message: "Ace could not stage a private Qwen input."
            )
        }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw AceLocalBrainError.processFailed(
                        message: "Ace could not write a private Qwen input."
                    )
                }
                written += count
            }
        }
    }
}
#endif // circuit-convert
