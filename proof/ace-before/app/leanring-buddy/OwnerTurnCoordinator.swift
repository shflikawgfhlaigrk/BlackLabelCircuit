//
//  OwnerTurnCoordinator.swift
//  Ace
//
//  One admitted owner request becomes one local process control or one Gold
//  turn. App names, action categories, and provider names never create extra
//  execution lanes.
//

import Foundation

nonisolated enum OwnerLocalProcessControl: Equatable, Sendable {
    case stop
    case enterStealth
    case exitStealth
    case presence
    case workStatus
    case capabilities
    case stealthHelp
    case installedIdentity
    case updateDownload
    case explicitMemory
    case deviceWeather
    case explicitWeather(String)
    case locationAccess
    case providerSetup(BrainCLI)
    case partner(PartnerModeCommand)
    case notesStart
    case tradingMode
    case notesStop
    case mailSetup
    case repeatResponse
    case mailRead
    case mailCompose
    case websiteOpen(String)
    case websiteOpenInBrowser(url: String, bundleIdentifier: String)
    case webSearch(query: String, opensTopResult: Bool)
    case appSwitch(String)
    case appSwitchOnDisplay(application: String, display: String)
    case openAndType(application: String, text: String)
    case point(String)
    case click(String)
    case typeText(String)
    case typeLastResponse
    case typeLastResponseInApplication(String)
    case pressKey(String)
    case closeAllWindows
}

nonisolated enum OwnerTurnDisposition: Equatable, Sendable {
    case local(OwnerLocalProcessControl)
    case gold(normalizedRequest: String)
}

@MainActor
struct OwnerTurnCoordinator {
    func disposition(
        for envelope: OwnerRequestEnvelope,
        stealthIsActive: Bool,
        stealthEnterMatched: Bool,
        stealthExitMatched: Bool,
        partnerModeIsActive: Bool = false,
        notesCaptureIsActive: Bool = false,
        hasRecentEmailRead: Bool = false,
        appCandidateIsResolvable: (String) -> Bool = { _ in true }
    ) -> OwnerTurnDisposition {
        let request = envelope.normalizedRequest.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        // These reasoning verbs do not describe a local process control.
        // Skip unrelated mail/app grammars, retaining the original request for
        // the same provider and screen-context pipeline.
        let firstWord = request.prefix { !$0.isWhitespace }.lowercased()
        if Self.reasoningVerbs.contains(firstWord),
           !stealthEnterMatched, !stealthExitMatched {
            return .gold(normalizedRequest: request)
        }
        let normalized = Self.normalizedGrammar(request)

        if Self.isStopRequest(request) {
            if notesCaptureIsActive && normalized == "stop" {
                return .local(.notesStop)
            }
            return .local(.stop)
        }
        if stealthExitMatched || (stealthIsActive && Self.isStealthExit(normalized)) {
            return .local(.exitStealth)
        }
        if stealthEnterMatched {
            return .local(.enterStealth)
        }
        if Self.negatedControlExpression.firstMatch(
            in: request, range: NSRange(request.startIndex..., in: request)
        ) != nil {
            return .gold(normalizedRequest: request)
        }
        if CrossAppActionPolicy.isRepeatResponseRequest(request) {
            return .local(.repeatResponse)
        }
        if let typing = Self.typeLastResponseRequest(request) {
            return .local(typing)
        }
        if hasRecentEmailRead, CrossAppActionPolicy.isEmailSummaryFollowUp(request) {
            return .local(.mailRead)
        }
        if request.range(of: #"(?i)^\s*(?:please\s+)?close\s+(?:all(?:\s+(?:of\s+)?my)?\s+windows|every\s+window)\s*[.!]?\s*$"#,
                         options: .regularExpression) != nil {
            return .local(.closeAllWindows)
        }
        if let target = Self.exactPointTarget(from: request) {
            if Self.pointTargetNeedsReasoning(target) {
                return .gold(normalizedRequest: request)
            }
            return .local(.point(target))
        }
        if let navigation = NativeWebNavigationIntentPolicy.navigation(
            from: request
        ) {
            if let browser = navigation.browserBundleIdentifier {
                return .local(.websiteOpenInBrowser(url: navigation.url, bundleIdentifier: browser))
            }
            return .local(.websiteOpen(navigation.url))
        }
        // Classification normalizes and checks the full local grammar once.
        // Preserve its priority before any provider, mail, or desktop action.
        switch LocalIntentPolicy.classify(request) {
        case .presence: return .local(.presence)
        case .workStatus: return .local(.workStatus)
        case .capabilities: return .local(.capabilities)
        case .stealthHelp: return .local(.stealthHelp)
        case .installedIdentity: return .local(.installedIdentity)
        case .updateDownload: return .local(.updateDownload)
        case .explicitMemory:
            // Partner's current structured-memory receipt keeps its existing
            // "forget that" meaning while that session is active.
            if partnerModeIsActive,
               LocalIntentPolicy.explicitMemoryIntent(request) == .forgetLast,
               let command = PartnerModePolicy.routableCommand(for: request, sessionIsActive: true) {
                return .local(.partner(command))
            }
            return .local(.explicitMemory)
        case .workflow, nil: break
        }
        if Self.deviceWeatherPhrases.contains(normalized) {
            return .local(.deviceWeather)
        }
        // Weather is an app-owned wrapper with its own location handling. A
        // spoken place ("what's the weather in Pensacola, FL") or a contraction
        // ("what's the weather like today?") must never reach a provider that
        // would fetch a weather page and read its markup back.
        switch NativeLocationIntentPolicy.classify(request) {
        case .weather(let locality?):
            return .local(.explicitWeather(locality))
        case .weather(nil):
            return .local(.deviceWeather)
        case .requestAccess:
            return .local(.locationAccess)
        case .none:
            break
        }
        if let provider = Self.providerSetupTarget(normalized) {
            return .local(.providerSetup(provider))
        }
        if let command = PartnerModePolicy.routableCommand(
            for: request,
            sessionIsActive: partnerModeIsActive
        ) {
            return .local(.partner(command))
        }
        if CrossAppActionPolicy.isUnambiguousNotesStopRequest(
            request,
            captureIsActive: notesCaptureIsActive
        ) {
            return .local(.notesStop)
        }
        if LocalIntentPolicy.tradingModeActivation(for: request) != nil {
            return .local(.tradingMode)
        }
        if CrossAppActionPolicy.isUnambiguousNotesStartRequest(request) {
            return .local(.notesStart)
        }
        if Self.isExplicitMailSetupRequest(normalized) {
            return .local(.mailSetup)
        }
        if Self.isMailEffectQuestionOrNegation(normalized) {
            return .gold(normalizedRequest: request)
        }
        if Self.isMailMutationRequest(normalized) {
            return .gold(normalizedRequest: request)
        }
        if Self.isSupplementalMailReadRequest(normalized) {
            return .local(.mailRead)
        }
        if Self.isExplicitMailDraftRequest(normalized) {
            return .local(.mailCompose)
        }
        if CrossAppActionPolicy.isExplicitEmailAuthoringRequest(request)
            || CrossAppActionPolicy.isOutboundEmailRequest(request) {
            return .local(.mailCompose)
        }
        switch CrossAppActionPolicy.emailReadRoutingDecision(request) {
        case .unifiedAppleMail, .gmail:
            return .local(.mailRead)
        case .unsupportedAccount:
            return .gold(normalizedRequest: request)
        case .notReadRequest:
            break
        }
        if let arguments = CrossAppActionPolicy
            .directWebSearchActionArguments(request) {
            let opensTopResult = arguments.first == "--open-first"
            let queryIndex = opensTopResult ? 1 : 0
            guard arguments.indices.contains(queryIndex) else {
                return .gold(normalizedRequest: request)
            }
            return .local(
                .webSearch(
                    query: arguments[queryIndex],
                    opensTopResult: opensTopResult
                )
            )
        }
        if let compound = Self.openAndTypeRequest(from: request),
           appCandidateIsResolvable(compound.application) {
            guard let payload = Self.typingPayload(compound.text) else {
                return .gold(normalizedRequest: request)
            }
            // A requested submit is an action, not part of the literal text.
            // The executor owns the full sequence and its final observation.
            if !payload.isQuoted, compound.text.range(
                of: #"(?i)(?:[.!?;,]\s*|\s+(?:and\s+)?(?:then\s+)?)(?:hit|press|click)\s+(?:the\s+)?(?:submit|send|enter|return)(?:\s+(?:button|key))?[.!?]?\s*$|\s+(?:and\s+)?(?:then\s+)?(?:submit|send)(?:\s+(?:it|the\s+(?:chat|message|prompt)))?[.!?]?\s*$"#,
                options: .regularExpression
            ) != nil {
                return .gold(normalizedRequest: request)
            }
            return .local(
                .openAndType(
                    application: compound.application,
                    text: payload.text
                )
            )
        }
        if let placement = NativeAppSwitchIntentPolicy.displayQualifiedRequest(from: request),
           appCandidateIsResolvable(placement.application) {
            return .local(.appSwitchOnDisplay(application: placement.application, display: placement.display))
        }
        if let appTarget = NativeAppSwitchIntentPolicy.candidate(
            from: request
        ), appCandidateIsResolvable(appTarget) {
            return .local(.appSwitch(appTarget))
        }
        if let text = Self.exactTextToType(from: request) {
            return .local(.typeText(text))
        }
        if let key = Self.exactKeyToPress(from: request) {
            return .local(.pressKey(key))
        }
        if let target = Self.exactClickTarget(from: request) {
            return .local(.click(target))
        }
        return .gold(normalizedRequest: request)
    }

    private static func exactClickTarget(from request: String) -> String? {
        capture(
            #"(?i)^\s*(?:please\s+)?(?:can\s+you\s+)?(?:click|press|select|choose)\s+(?:the\s+)?(.+?)[.!?]?\s*$"#,
            in: request
        )
    }

    /// Pointing is read-only and must bind an exact visible Accessibility
    /// target. Anchoring the grammar keeps descriptive questions on Gold while
    /// making the filming commands deterministic and coordinate-grounded.
    private static func exactPointTarget(from request: String) -> String? {
        if let target = capture(
            #"(?i)^\s*(?:look\s+at|read|check)\s+(?:the\s+)?(?:current|visible)\s+.+?\s+and\s+point\s+(?:at|to)\s+(?:the\s+)?(.+?)\s*[.!?]*$"#,
            in: request
        ) { return target }
        return capture(
            #"(?i)^\s*(?:please\s+)?(?:can\s+you\s+)?(?:point\s+(?:at|to)\s+(?:the\s+)?|show\s+me\s+where\s+(?:the\s+)?)(.+?)(?:\s+is)?[.!?]?\s*$"#,
            in: request
        )
    }

    private static let reasoningVerbs: Set<String> = [
        "calculate", "solve", "evaluate", "simplify", "factor",
        "differentiate", "integrate", "translate", "proofread", "rewrite",
    ]

    private static let negatedControlExpression = try! NSRegularExpression(
        pattern: #"(?i)^\s*(?:do\s+not|don['’]?t|never|not(?=\s+\S)|can(?:not|'t|’t))\b"#
    )

    private static let reasoningPointExpression = try! NSRegularExpression(
        pattern: #"(?i)\b(?:answers?|solutions?|correct|incorrect|mistakes?|questions?|problems?|equations?|which|(?:right|best|wrong)\s+(?:one|choice|option)|one\s+(?:i|we)\s+should\s+(?:choose|pick|select))\b|^(?:it|this|that|these|those)$"#
    )

    static func pointTargetNeedsReasoning(_ target: String) -> Bool {
        reasoningPointExpression.firstMatch(
            in: target, range: NSRange(target.startIndex..., in: target)
        ) != nil
    }

    static func requiresOpenAndTypeExecution(for request: String) -> Bool {
        openAndTypeRequest(from: request) != nil
    }

    /// One explicit owner utterance can open an installed app and type literal
    /// text into that app's verified editable surface. Keeping this grammar
    /// anchored prevents general multi-step prose from becoming desktop input.
    private static func openAndTypeRequest(
        from request: String
    ) -> (application: String, text: String)? {
        guard let expression = try? NSRegularExpression(
            pattern:
                #"(?i)^\s*(?:is[\s,]+(?=(?:please[\s,]+)?(?:open|launch|start|bring\s+up|pull\s+up|switch\s+to)\b))?(?:hey[\s,]+)?(?:ace[\s,]+)?(?:please\s+)?(?:(?:can|could|would|will)\s+you(?:\s+please)?\s+)?(?:open(?:\s+up)?|launch|start|bring\s+up|pull\s+up|switch\s+to)\s+(?:the\s+|my\s+)?(?:app(?:lication)?\s+)?(.+?)\s+(?:and\s+)?(?:then\s+)?(?:type\s+out|type|dictate)\s+(.+?)\s*$"#
        ), let match = expression.firstMatch(
            in: request,
            range: NSRange(request.startIndex..., in: request)
        ), let applicationRange = Range(
            match.range(at: 1),
            in: request
        ), let textRange = Range(match.range(at: 2), in: request) else {
            return nil
        }
        let application = String(request[applicationRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = String(request[textRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard application.count >= 2,
              !text.isEmpty,
              text.count <= 16_384 else {
            return nil
        }
        return (application, text)
    }

    private static func exactTextToType(from request: String) -> String? {
        let target =
            #"(?:(?:the|this|that|my)\s+)?(?:(?:focused|selected|current|active|open)\s+)?(?:text\s+box|caption\s+box|field|box|area|input|form|document|doc|safari|chrome|browser|app)"#
        let patterns = [
            #"(?i)^\s*(?:please\s+)?(?:can\s+you\s+)?(?:type\s+out|type|dictate)\s+(.+?)(?:\s+(?:into|in|onto|on)\s+\#(target))?[.!?]?\s*$"#,
            #"(?i)^\s*(?:please\s+)?(?:can\s+you\s+)?(?:enter|input)\s+(.+?)(?:(?:\s+(?:into|in|onto|on)\s+\#(target))|\s+here)?[.!?]?\s*$"#,
            #"(?i)^\s*(?:please\s+)?(?:can\s+you\s+)?(?:put|place)\s+(.+?)\s+(?:into|in|onto|on)\s+\#(target)(?:\s+here)?[.!?]?\s*$"#,
            #"(?i)^\s*(?:please\s+)?(?:can\s+you\s+)?fill\s+(?:in\s+)?\#(target)\s+with\s+(.+?)[.!?]?\s*$"#,
        ]
        for pattern in patterns {
            guard let instruction = capture(pattern, in: request),
                  let payload = typingPayload(instruction) else {
                continue
            }
            return payload.text
        }
        return nil
    }

    private static func typeLastResponseRequest(_ request: String) -> OwnerLocalProcessControl? {
        let reference =
            #"(?:this|that|it|(?:the|your)\s+(?:last\s+)?(?:answer|response|reply)|the\s+caption)"#
        let target =
            #"(?:(?:the|this|that|my)\s+)?(?:(?:focused|selected|current|active|open)\s+)?(?:text\s+box|caption\s+box|field|box|area|input|form|document|doc|(safari|chrome)|browser|app)"#
        let patterns = [
            #"(?i)^\s*(?:please\s+)?(?:can\s+)?(?:(?:can|could|would|will)\s+you(?:\s+please)?\s+)?(?:type|paste|enter|input)\s+\#(reference)(?:\s+out)?(?:(?:\s+(?:into|in|onto|on)\s+\#(target))|\s+here)?(?:\s+like\s+i\s+told\s+you)?[.!?]?\s*$"#,
            #"(?i)^\s*(?:please\s+)?(?:can\s+)?(?:(?:can|could|would|will)\s+you(?:\s+please)?\s+)?(?:put|place)\s+\#(reference)\s+(?:into|in|onto|on)\s+\#(target)(?:\s+like\s+i\s+told\s+you)?[.!?]?\s*$"#,
            #"(?i)^\s*(?:please\s+)?(?:can\s+)?(?:(?:can|could|would|will)\s+you(?:\s+please)?\s+)?fill\s+(?:in\s+)?\#(target)\s+with\s+\#(reference)(?:\s+like\s+i\s+told\s+you)?[.!?]?\s*$"#,
        ]
        for pattern in patterns {
            guard let expression = routingExpression(pattern),
                  let match = expression.firstMatch(
                in: request,
                range: NSRange(request.startIndex..., in: request)
            ) else { continue }
            if let applicationRange = Range(match.range(at: 1), in: request) {
                let application = request[applicationRange].lowercased() == "safari"
                    ? "Safari" : "Chrome"
                return .typeLastResponseInApplication(application)
            }
            return .typeLastResponse
        }
        return nil
    }

    private static func typingPayload(
        _ instruction: String
    ) -> (text: String, isQuoted: Bool)? {
        let value = instruction.replacingOccurrences(
            of: #"(?i)^exactly\s+"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opening = value.first else { return nil }
        let closing: Character
        switch opening {
        case "\"": closing = "\""
        case "'": closing = "'"
        case "“": closing = "”"
        case "‘": closing = "’"
        default: return (value, false)
        }
        // Additional directions after a quotation belong to the full request.
        // Let Gold interpret them instead of pasting them into the target app.
        guard let endOfLiteral = value.dropFirst().firstIndex(of: closing),
              value[value.index(after: endOfLiteral)...]
                .trimmingCharacters(
                    in: CharacterSet(charactersIn: ".!?")
                        .union(.whitespacesAndNewlines)
                ).isEmpty else { return nil }
        let text = String(value[value.index(after: value.startIndex)..<endOfLiteral])
        guard !text.isEmpty else { return nil }
        return (text, true)
    }

    private static func exactKeyToPress(from request: String) -> String? {
        guard let key = capture(
            #"(?i)^\s*(?:please\s+)?(?:press|hit)\s+(?:the\s+)?(enter|return|tab|escape|space)(?:\s+key)?[.!?]?\s*$"#,
            in: request
        ) else { return nil }
        return key.lowercased()
    }

    private static var routingExpressions: [String: NSRegularExpression] = [:]

    private static func routingExpression(_ pattern: String) -> NSRegularExpression? {
        if let cached = routingExpressions[pattern] { return cached }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        routingExpressions[pattern] = expression
        return expression
    }

    private static func capture(
        _ pattern: String,
        in request: String
    ) -> String? {
        guard let expression = Self.routingExpression(pattern),
              let match = expression.firstMatch(
            in: request,
            range: NSRange(request.startIndex..., in: request)
        ), let range = Range(match.range(at: 1), in: request) else {
            return nil
        }
        let value = String(request[range]).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? nil : value
    }

    private static let deviceWeatherPhrases: Set<String> = [
        "local weather",
        "my local weather",
        "the local weather",
        "what is the local weather",
        "what is my local weather",
        "weather",
        "weather here",
        "weather right now",
        "what is the weather",
        "what is the weather here",
        "what is the weather right now",
    ]

    private static func normalizedGrammar(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9\s]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isStopRequest(_ request: String) -> Bool {
        let localizedStop = request.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if AceLanguage.current != .english,
           localizedStop == AceLanguage.current.stopPhrase.folding(
               options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) {
            return true
        }
        let value = normalizedGrammar(request).replacingOccurrences(
            of: #"^(?:(?:okay|ok|please) )+"#,
            with: "", options: .regularExpression
        )
        if [
            "stop", "stop it", "stop that", "stop talking",
            "stop scanning", "be quiet", "quiet", "shush", "hush",
            "shut up", "silence", "never mind", "nevermind",
            "cancel", "cancel that", "cancel it", "forget it",
            "that s enough", "enough",
        ].contains(value) { return true }
        // “Sask” is the observed speech transcription in the owner's exact
        // stop-both-background-tasks request. This is a whole local stop,
        // never a general process-name or shell instruction.
        return value.range(
            of: #"^(?:stop|cancel|end|cut off|shut down) (?:(?:(?:both|all)(?: of)? (?:the )?|the )?background (?:tasks?|agents?|workers?|work|sask)|(?:both|all) (?:agents|tasks|workers))(?: (?:right )?now)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isStealthExit(_ value: String) -> Bool {
        value.range(
            of: #"^(?:exit|leave|end|disable|stop) (?:stealth|ghost|private)(?: mode)?$|^(?:turn off) (?:stealth|ghost|private)(?: mode)?$|^(?:stealth|ghost|private) mode off$"#,
            options: .regularExpression
        ) != nil
    }

    private static func providerSetupTarget(_ value: String) -> BrainCLI? {
        if value.range(
            of: #"^(?:(?:sign|log)(?: me)? in(?: to| with)?|(?:connect|reconnect)(?: me)?(?: to| with)?) (?:codex|chatgpt|openai)$"#,
            options: .regularExpression
        ) != nil {
            return .codex
        }
        if value.range(
            of: #"^(?:(?:sign|log)(?: me)? in(?: to| with)?|(?:connect|reconnect)(?: me)?(?: to| with)?) (?:claude|anthropic)$"#,
            options: .regularExpression
        ) != nil {
            return .claude
        }
        if value.range(
            of: #"^(?:(?:connect|reconnect|verify|check)(?: me)?(?: to| with)?) qwen(?:3)?$"#,
            options: .regularExpression
        ) != nil {
            return .qwen
        }
        return nil
    }

    /// Opens only macOS's account-setup surface. Keeping this grammar typed and
    /// anchored prevents a setup request from falling through to Gold or being
    /// mistaken for authority to compose, send, or change any message.
    private static func isExplicitMailSetupRequest(_ value: String) -> Bool {
        value.range(
            of: #"^(?:please )?(?:(?:can|could|would|will) you )?(?:help me )?(?:add|connect|set up|setup|configure)(?: my| an| the)? (?:email|mail)(?: account)?(?: for me)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isExplicitMailDraftRequest(_ value: String) -> Bool {
        value.range(
            of: #"^(?:please )?(?:(?:can|could|would|will) you )?(?:prepare|create)(?: me)? (?:an? )?(?:email|mail)(?:(?: to| for| about| with| saying| that says) .+)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isMailEffectQuestionOrNegation(
        _ value: String
    ) -> Bool {
        let hasMailTarget = value.range(
            of: #"\b(?:email|emails|mail|inbox|mailbox)\b"#,
            options: .regularExpression
        ) != nil
        let namesMailEffect = value.range(
            of: #"\b(?:add|connect|setup|configure|prepare|create|draft|write|send|reply|forward|delete|remove|erase|trash|empty|archive|move|mark|flag|unflag)\b|\bset up\b"#,
            options: .regularExpression
        ) != nil
        guard hasMailTarget && namesMailEffect else { return false }
        return value.range(
            of: #"^(?:please )?(?:do not|don t|dont|never)\b|^(?:how|why|when|where|what)\b|^(?:do|does|did|have|has|was|were|are) (?:you|we|i)\b|^(?:can|could|should|would) i\b|^should you\b"#,
            options: .regularExpression
        ) != nil
    }

    /// Keep the full objective out of the read-only shortcut so the general
    /// executor can choose a tool that supports the requested operation.
    private static func isMailMutationRequest(
        _ value: String
    ) -> Bool {
        guard value.count <= 180,
              value.range(
                of: #"^(?:please )?(?:do not|don t|dont|never)\b"#,
                options: .regularExpression
              ) == nil,
              value.range(
                of: #"^(?:how|why|when|where|what)\b|^(?:do|does|did|have|has|was|were|are) (?:you|we|i)\b|^(?:can|could|should|would) i\b|^should you\b"#,
                options: .regularExpression
              ) == nil else {
            return false
        }
        let hasMailTarget = value.range(
            of: #"\b(?:email|emails|mail|inbox|mailbox)\b"#,
            options: .regularExpression
        ) != nil
        let hasUnsupportedMutation = value.range(
            of: #"\b(?:delete|remove|erase|trash|empty|archive|move|mark|flag|unflag)\b"#,
            options: .regularExpression
        ) != nil
        return hasMailTarget && hasUnsupportedMutation
    }

    private static func isSupplementalMailReadRequest(
        _ value: String
    ) -> Bool {
        let qualifiers =
            #"(?:(?:my|the|latest|last|newest|new|unread|read|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|[0-9]+) )*"#
        let target = #"(?:email|emails|mail|inbox|mailbox)(?: messages?)?"#
        let inspect =
            #"^(?:please )?(?:(?:can|could|would|will) you )?(?:scan|summarize|review) "#
                + qualifiers + target + #"$"#
        let tellMe = #"^tell me about "# + qualifiers + target + #"$"#
        let availability =
            #"^(?:do i have|have i got) (?:(?:any|new|unread|latest) )*"#
                + target + #"$"#
        return [inspect, tellMe, availability].contains { pattern in
            value.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

nonisolated enum OwnerVisibleResponseRetention: Equatable, Sendable {
    case standard
    case mailReadResult
}

/// Successful inbox previews carry several lines and need a stable filming and
/// reading window. Other transient responses keep the existing compact life.
nonisolated enum OwnerVisibleResponseRetentionPolicy {
    static let standardSeconds: UInt64 = 12
    static let mailReadResultSeconds: UInt64 = 30

    static func seconds(
        for retention: OwnerVisibleResponseRetention
    ) -> UInt64 {
        switch retention {
        case .standard:
            return standardSeconds
        case .mailReadResult:
            return mailReadResultSeconds
        }
    }
}
