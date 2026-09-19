#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  OwnerTurnLifecycleCoordinator.swift
//  Ace
//
//  Manager-owned admission and async callback binding for one frozen owner
//  context. Core Location never consults mutable global turn state directly.
//

import Foundation

nonisolated struct OwnerTurnBinding: Equatable, Sendable {
    let context: OwnerTurnContext
    let envelope: OwnerRequestEnvelope
    let correlationID: UUID
}

/// One independently admitted panel click and the private Mail/Messages route
/// it may recover. The click always owns its own context and terminal; only the
/// preserved parent can own the later app-action outcome.
nonisolated struct OwnerTurnControlBinding: Equatable, Sendable {
    let control: OwnerTurnBinding
    let preservedPrivateParent: OwnerTurnBinding?
}

nonisolated enum OwnerTurnCompoundDispatchStep: Equatable, Sendable {
    case locate(String)
    case appSwitch(String)
}

@MainActor
final class OwnerTurnLifecycleCoordinator {
    private let eventBus: AceEventBus
    private let observeContext: (OwnerTurnContext) -> Void
    private(set) var activeBinding: OwnerTurnBinding?
    private var pendingLocalitySessionID: UUID?
    private var activeLocationRequestID: UUID?
    private var locationCompletionInProgressCorrelationID: UUID?
    private var bindingsByCorrelationID: [UUID: OwnerTurnBinding] = [:]
    private var startedDispatches: Set<UUID> = []
    private var asynchronousDispatches: Set<UUID> = []
    private var locationTransferredDispatches: Set<UUID> = []
    private var terminalDispatches: Set<UUID> = []
    private var preservedPrivateRecoveryBinding: OwnerTurnBinding?
    private var privateParentByControlCorrelationID:
        [UUID: OwnerTurnBinding] = [:]
    private var claimedAutomationParentCorrelationIDs: Set<UUID> = []
    private var nonDestructiveInquiryParentByCorrelationID:
        [UUID: OwnerTurnBinding] = [:]

    /// A delayed voice completion must not open a new automatic capture turn
    /// while a native action still owns the current asynchronous result.
    var hasPendingAsynchronousManagerDispatch: Bool {
        guard let binding = activeBinding else { return false }
        return asynchronousDispatches.contains(binding.correlationID)
            && !terminalDispatches.contains(binding.correlationID)
    }

    convenience init(
        observeContext: @escaping (OwnerTurnContext) -> Void = { _ in }
    ) {
        self.init(
            eventBus: .shared,
            observeContext: observeContext
        )
    }

    init(
        eventBus: AceEventBus,
        observeContext: @escaping (OwnerTurnContext) -> Void = { _ in }
    ) {
        self.eventBus = eventBus
        self.observeContext = observeContext
    }

    private static func context(
        for disposition: OwnerTurnDisposition,
        envelope: OwnerRequestEnvelope
    ) -> OwnerTurnContext {
        let scope: OwnerContextScope
        let route: String
        var resolvedSlots: [String: String] = [:]

        switch disposition {
        case .local(.stop):
            scope = .ownerPersonal
            route = "owner.stop"
        case .local(.enterStealth):
            scope = .ownerPersonal
            route = "native.stealth-enter"
        case .local(.exitStealth):
            scope = .ownerPersonal
            route = "native.stealth-exit"
        case .local(.presence):
            scope = .ownerPersonal
            route = "native.presence"
        case .local(.workStatus):
            scope = .ownerPersonal
            route = "native.work-status"
        case .local(.capabilities):
            scope = .ownerPersonal
            route = "native.capabilities"
        case .local(.stealthHelp):
            scope = .ownerPersonal
            route = "native.stealth-help"
        case .local(.installedIdentity):
            scope = .ownerPersonal
            route = "native.installed-identity"
        case .local(.updateDownload):
            scope = .ownerPersonal
            route = "native.update-download"
        case .local(.explicitMemory):
            scope = .ownerPersonal
            route = "native.memory"
        case .local(.deviceWeather):
            scope = .deviceCurrent
            route = "native.weather.device-current"
        case .local(.explicitWeather(let locality)):
            scope = .ownerPersonal
            route = "native.weather.explicit-locality"
            resolvedSlots["locality"] = locality
        case .local(.locationAccess):
            scope = .ownerPersonal
            route = "native.location.access"
        case .local(.providerSetup(let provider)):
            scope = .ownerPersonal
            route = "provider.sign-in"
            resolvedSlots["provider"] = provider.rawValue
        case .local(.partner):
            scope = .ownerPersonal
            route = "native.partner-command"
        case .local(.tradingMode):
            scope = .ownerPersonal
            route = "native.trading-mode"
        case .local(.notesStart):
            scope = .ownerPersonal
            route = "native.notes-start"
        case .local(.notesStop):
            scope = .ownerPersonal
            route = "native.notes-stop"
        case .local(.mailSetup):
            scope = .ownerPersonal
            route = "native.mail.setup"
        case .local(.repeatResponse):
            scope = .ownerPersonal
            route = "native.response-repeat"
        case .local(.mailRead):
            scope = .ownerPersonal
            route = "native.mail.read"
            resolvedSlots["resolvedInstruction"] =
                envelope.normalizedRequest
        case .local(.mailCompose):
            scope = .ownerPersonal
            route = "native.mail.compose"
            resolvedSlots["resolvedInstruction"] =
                envelope.normalizedRequest
        case .local(.websiteOpen(let url)):
            scope = .ownerPersonal
            route = "native.web-open"
            resolvedSlots["url"] = url
        case .local(.websiteOpenInBrowser(let url, let bundleIdentifier)):
            scope = .ownerPersonal
            route = "native.web-open"
            resolvedSlots["url"] = url
            resolvedSlots["browserBundleIdentifier"] = bundleIdentifier
        case .local(.webSearch(let query, let opensTopResult)):
            scope = .unspecified
            route = "native.web-search"
            resolvedSlots["query"] = query
            resolvedSlots["opensTopResult"] = opensTopResult ? "true" : "false"
        case .local(.appSwitch(let appTarget)):
            scope = .ownerPersonal
            route = "native.app-switch"
            resolvedSlots["appTarget"] = appTarget
        case .local(.appSwitchOnDisplay(let application, let display)):
            scope = .ownerPersonal
            route = "native.app-switch"
            resolvedSlots["appTarget"] = application
            resolvedSlots["displayTarget"] = display
        case .local(.openAndType(let application, let text)):
            scope = .ownerPersonal
            route = "native.open-and-type"
            resolvedSlots["appTarget"] = application
            resolvedSlots["instruction"] = text
        case .local(.point(let target)):
            scope = .ownerPersonal
            route = "native.point"
            resolvedSlots["target"] = target
        case .local(.click(let target)):
            scope = .ownerPersonal
            route = "native.click"
            resolvedSlots["target"] = target
        case .local(.typeText(let text)):
            scope = .ownerPersonal
            route = "native.type"
            resolvedSlots["instruction"] = text
        case .local(.typeLastResponse):
            scope = .ownerPersonal
            route = "native.response-type"
        case .local(.typeLastResponseInApplication(let application)):
            scope = .ownerPersonal
            route = "native.response-type"
            resolvedSlots["appTarget"] = application
        case .local(.closeAllWindows):
            scope = .ownerPersonal
            route = "native.window-close-all"
        case .local(.pressKey(let key)):
            scope = .ownerPersonal
            route = "native.key-press"
            resolvedSlots["key"] = key
        case .gold(let normalizedRequest):
            scope = .ownerPersonal
            route = "provider.reasoning"
            resolvedSlots["resolvedInstruction"] = normalizedRequest
        }

        return OwnerTurnContext(
            sessionID: envelope.sessionID,
            turnID: envelope.turnID,
            exactInput: envelope.exactTranscript,
            scope: scope,
            pendingSlot: nil,
            resolvedSlots: resolvedSlots,
            selectedRoute: route
        )
    }

    /// Spelled-out US states plus the two-letter codes that are not ordinary
    /// English words. Speech transcription rarely inserts the comma in
    /// "Pensacola, FL", so a city followed by one of these is a locality answer.
    private static let spokenStateSuffixes: Set<String> = [
        "alabama", "alaska", "arizona", "arkansas", "california", "colorado",
        "connecticut", "delaware", "florida", "georgia", "hawaii", "idaho",
        "illinois", "indiana", "iowa", "kansas", "kentucky", "louisiana", "maine",
        "maryland", "massachusetts", "michigan", "minnesota", "mississippi",
        "missouri", "montana", "nebraska", "nevada", "new hampshire", "new jersey",
        "new mexico", "new york", "north carolina", "north dakota", "ohio",
        "oklahoma", "oregon", "pennsylvania", "rhode island", "south carolina",
        "south dakota", "tennessee", "texas", "utah", "vermont", "virginia",
        "washington", "west virginia", "wisconsin", "wyoming",
        "district of columbia", "puerto rico",
        "ak", "az", "ar", "ca", "ct", "fl", "ga", "ia", "il", "ks", "ky", "md",
        "mi", "mn", "mt", "nc", "nd", "ne", "nh", "nj", "nm", "nv", "ny", "ri",
        "sc", "sd", "tn", "tx", "ut", "va", "vt", "wa", "wi", "wv", "wy", "dc", "pr",
    ]

    private static func isBoundedLocality(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 96 else { return false }
        if trimmed.range(
            of: #"^[A-Za-z][A-Za-z .'-]{0,60}(?:,\s*[A-Za-z]{2,20})$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        let words = trimmed.lowercased()
            .replacingOccurrences(of: #"[.,!?]+$"#, with: "", options: .regularExpression)
            .split(separator: " ").map(String.init)
        guard (2...6).contains(words.count),
              words.allSatisfy({
                  $0.range(of: #"^[a-z][a-z'-]*$"#, options: .regularExpression) != nil
              }) else { return false }
        return (1...3).contains { suffixLength in
            words.count > suffixLength
                && spokenStateSuffixes.contains(
                    words.suffix(suffixLength).joined(separator: " ")
                )
        }
    }

    private enum CandidateContinuation {
        case none
        case resolved(
            instruction: String,
            parent: OwnerContextCandidate,
            referenceKind: OwnerWorkReferenceKind,
            correctionKind: OwnerCorrectionKind?
        )
        case clarification(String)
    }

    private static func candidateContinuation(
        for normalizedRequest: String,
        sessionID: UUID,
        candidates: [OwnerContextCandidate],
        requiredWorkID: UUID?,
        partnerModeIsActive: Bool
    ) -> CandidateContinuation {
        let grammar = normalizedRequest
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9' ]+"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let simpleReferences: Set<String> = [
            "that", "it", "do that", "do it", "the last thing",
            "do the last thing", "what i told you",
            "what i just told you",
        ]
        let delegatedReferences: Set<String> = [
            "yes hand it off to red", "yes hand that off to red",
            "yes give it to red", "hand it off to red",
            "give it to red", "have red do that",
        ]
        let retries: Set<String> = [
            "retry", "retry that", "retry it", "try that again",
            "try it again", "do that again", "do it again",
            "that didn't work", "that did not work",
            "it didn't work", "it did not work",
        ]
        let submissionFollowUps: Set<String> = [
            "send it", "send that", "submit it", "submit that",
            "send the message", "submit the message",
            "go ahead and send it", "go ahead and submit it",
            "hit send", "hit submit",
        ]
        let isBareYes = ["yes", "yeah", "yep"].contains(grammar)
        let kind: (delegated: Bool, correction: OwnerCorrectionKind?)?
        if delegatedReferences.contains(grammar) {
            kind = (true, nil)
        } else if retries.contains(grammar) {
            kind = (false, .retry)
        } else if submissionFollowUps.contains(grammar) {
            // Retain the app-bound target and exact prior request, while
            // keeping the new submit instruction separate from that objective.
            kind = (false, .amendment)
        } else if simpleReferences.contains(grammar) {
            kind = (false, nil)
        } else if isBareYes,
                  requiredWorkID != nil || partnerModeIsActive {
            kind = (partnerModeIsActive, nil)
        } else {
            kind = nil
        }
        guard let kind else { return .none }

        var unique: [UUID: OwnerContextCandidate] = [:]
        for candidate in candidates
        where candidate.sourceSessionID == sessionID {
            if let current = unique[candidate.workCorrelationID] {
                if candidate.updatedAt > current.updatedAt {
                    unique[candidate.workCorrelationID] = candidate
                }
            } else {
                unique[candidate.workCorrelationID] = candidate
            }
        }
        var eligible = Array(unique.values)
        if let requiredWorkID {
            eligible = eligible.filter {
                $0.workCorrelationID == requiredWorkID
            }
        }
        eligible.sort {
            if $0.updatedAt == $1.updatedAt {
                return $0.workCorrelationID.uuidString
                    < $1.workCorrelationID.uuidString
            }
            return $0.updatedAt > $1.updatedAt
        }
        guard let parent = eligible.first else {
            return .clarification(
                requiredWorkID == nil
                    ? "Which recent request should I continue?"
                    : "That required work receipt is no longer available. Use Retry on its visible receipt."
            )
        }
        if eligible.count > 1,
           eligible[1].updatedAt == parent.updatedAt {
            return .clarification(
                "Which visible work receipt should I continue?"
            )
        }
        if let reason = parent.continuationUnavailableReason {
            return .clarification(reason)
        }
        let instruction = kind.delegated
            ? "Complete this admitted owner request: " + parent.request
            : parent.request
        return .resolved(
            instruction: instruction,
            parent: parent,
            referenceKind:
                simpleReferences.contains(grammar) || kind.delegated
                    ? .lastThing : .pronoun,
            correctionKind: kind.correction
        )
    }

    @discardableResult
    func admit(
        _ admittedEvent: AceEvent,
        pending: OwnerPendingSlotState? = nil,
        goldClarificationIsPending: Bool = false,
        privateMailClarificationRequest: String? = nil,
        candidates: [OwnerContextCandidate] = [],
        actionTargets: [String] = [],
        requiredCandidateWorkID: UUID? = nil,
        selectedReceiptRetry: OwnerContextCandidate? = nil,
        allowsImplicitLocateFollowUp: Bool = false,
        partnerModeIsActive: Bool = false,
        stealthIsActive: Bool = false,
        stealthEnterMatched: Bool = false,
        stealthExitMatched: Bool = false,
        notesCaptureIsActive: Bool = false,
        hasRecentEmailRead: Bool = false
    ) -> OwnerTurnBinding {
        let origin: OwnerRequestOrigin
        switch admittedEvent.payloadType {
        case .directHumanUIAction:
            origin = .directControl
        case .developerInjection:
            origin = .panel
        default:
            origin = .microphone
        }
        let envelope = OwnerRequestNormalizer.makeEnvelope(
            sessionID: admittedEvent.sessionID,
            turnID: admittedEvent.turnID,
            correlationID: admittedEvent.correlationID,
            origin: origin,
            exactTranscript: admittedEvent.payload,
            admittedAt: admittedEvent.timestamp,
            recentExactTarget:
                actionTargets.count == 1 ? actionTargets.first : nil
        )
        let disposition = OwnerTurnCoordinator().disposition(
            for: envelope,
            stealthIsActive: stealthIsActive,
            stealthEnterMatched: stealthEnterMatched,
            stealthExitMatched: stealthExitMatched,
            partnerModeIsActive: partnerModeIsActive,
            notesCaptureIsActive: notesCaptureIsActive,
            hasRecentEmailRead: hasRecentEmailRead,
            appCandidateIsResolvable: { candidate in
                AppSwitcher.installedAppName(matching: candidate) != nil
            }
        )
        let preservedInquiryParent: OwnerTurnBinding?
        if disposition == .local(.workStatus)
            || disposition == .local(.stealthHelp)
            || disposition == .local(.repeatResponse) {
            preservedInquiryParent = activeBinding
        } else {
            preservedInquiryParent = nil
            cancelReplacedDispatchIfNeeded()
            retireActiveBindingState()
        }
        var context: OwnerTurnContext
        if pendingLocalitySessionID == admittedEvent.sessionID,
           case .gold = disposition,
           Self.isBoundedLocality(envelope.normalizedRequest) {
            pendingLocalitySessionID = nil
            context = OwnerTurnContext(
                sessionID: envelope.sessionID,
                turnID: envelope.turnID,
                exactInput: envelope.exactTranscript,
                scope: .ownerPersonal,
                pendingSlot: .locality,
                resolvedSlots: ["locality": envelope.normalizedRequest],
                selectedRoute: "native.weather.spoken-locality"
            )
        } else {
            if pendingLocalitySessionID != nil {
                pendingLocalitySessionID = nil
            }
            context = Self.context(
                for: disposition,
                envelope: envelope
            )
        }
        if let parent = selectedReceiptRetry,
           admittedEvent.payloadType == .directHumanUIAction {
            var slots = [
                "resolvedInstruction": parent.request,
                "parentWorkCorrelationIdentifier": parent.workCorrelationID.uuidString.lowercased(),
                "referenceKind": "pronoun", "correctionKind": "retry",
                "selectedReceiptRetry": "true",
            ]
            slots["priorTerminalOutcome"] = parent.terminalOutcome
            slots["priorTerminalVerification"] = parent.terminalVerification
            slots["priorTerminalReason"] = parent.terminalReason
            slots["clarificationQuestion"] = parent.continuationUnavailableReason
            context = OwnerTurnContext(
                sessionID: envelope.sessionID, turnID: envelope.turnID,
                exactInput: envelope.exactTranscript, scope: .ownerPersonal,
                pendingSlot: nil, resolvedSlots: slots,
                selectedRoute: parent.continuationUnavailableReason == nil
                    ? "provider.reasoning" : "native.context-clarification"
            )
        } else if let privateMailClarificationRequest,
           case .gold = disposition {
            context = OwnerTurnContext(
                sessionID: envelope.sessionID,
                turnID: envelope.turnID,
                exactInput: envelope.exactTranscript,
                scope: .ownerPersonal,
                pendingSlot: nil,
                resolvedSlots: [
                    "resolvedInstruction": privateMailClarificationRequest,
                    "privateMailContinuation": "true",
                ],
                selectedRoute: "native.mail.compose"
            )
        } else if goldClarificationIsPending,
           !OwnerTurnDispatchPolicy
                .preservesNativeControlDuringGoldClarification(
                    selectedRoute: context.selectedRoute
                ) {
            context = OwnerTurnContext(
                sessionID: envelope.sessionID,
                turnID: envelope.turnID,
                exactInput: envelope.exactTranscript,
                scope: .ownerPersonal,
                pendingSlot: .goldClarification,
                resolvedSlots: [
                    "clarificationAnswer": envelope.normalizedRequest
                ],
                selectedRoute: "provider.reasoning"
            )
        } else if let pending,
                  !OwnerTurnDispatchPolicy
                    .preservesNativeControlDuringGoldClarification(
                        selectedRoute: context.selectedRoute
                    ) {
            let normalized = envelope.normalizedRequest
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let exactMatches = pending.allowedValues.filter {
                $0.compare(
                    normalized,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
            var slots = context.resolvedSlots
            if exactMatches.count == 1,
               let selectedValue = exactMatches.first {
                slots["pendingExactValue"] = selectedValue
                context = OwnerTurnContext(
                    sessionID: envelope.sessionID,
                    turnID: envelope.turnID,
                    exactInput: envelope.exactTranscript,
                    scope: .ownerPersonal,
                    pendingSlot: pending.slot,
                    resolvedSlots: slots,
                    selectedRoute: "native.pending-selection"
                )
            } else {
                slots["clarificationQuestion"] =
                    "Choose one of the exact values shown in Ace."
                context = OwnerTurnContext(
                    sessionID: envelope.sessionID,
                    turnID: envelope.turnID,
                    exactInput: envelope.exactTranscript,
                    scope: .ownerPersonal,
                    pendingSlot: pending.slot,
                    resolvedSlots: slots,
                    selectedRoute: "native.context-clarification"
                )
            }
        } else if case .gold = disposition,
                  allowsImplicitLocateFollowUp,
                  actionTargets.count == 1,
                  let target = actionTargets.first,
                  !envelope.normalizedRequest.isEmpty {
            context = OwnerTurnContext(
                sessionID: envelope.sessionID,
                turnID: envelope.turnID,
                exactInput: envelope.exactTranscript,
                scope: .ownerPersonal,
                pendingSlot: .actionTarget,
                resolvedSlots: [
                    "actionTarget": target,
                    "resolvedInstruction":
                        "find " + envelope.normalizedRequest,
                ],
                selectedRoute: "native.locate.follow-up"
            )
        } else if case .gold = disposition {
            switch Self.candidateContinuation(
                for: envelope.normalizedRequest,
                sessionID: envelope.sessionID,
                candidates: candidates,
                requiredWorkID: requiredCandidateWorkID,
                partnerModeIsActive: partnerModeIsActive
            ) {
            case .none:
                if let candidate = candidates.first {
                    var slots = context.resolvedSlots
                    slots["candidateRequest"] = candidate.request
                    slots["candidateSource"] = candidate.sourceLabel
                    context = OwnerTurnContext(
                        sessionID: context.sessionID,
                        turnID: context.turnID,
                        exactInput: context.exactInput,
                        scope: context.scope,
                        pendingSlot: context.pendingSlot,
                        resolvedSlots: slots,
                        selectedRoute: context.selectedRoute
                    )
                }
            case let .clarification(question):
                context = OwnerTurnContext(
                    sessionID: envelope.sessionID,
                    turnID: envelope.turnID,
                    exactInput: envelope.exactTranscript,
                    scope: .ownerPersonal,
                    pendingSlot: .actionTarget,
                    resolvedSlots: ["clarificationQuestion": question],
                    selectedRoute: "native.context-clarification"
                )
            case let .resolved(
                instruction,
                parent,
                referenceKind,
                correctionKind
            ):
                var slots = context.resolvedSlots
                slots["resolvedInstruction"] = instruction
                slots["parentWorkCorrelationIdentifier"] =
                    parent.workCorrelationID.uuidString.lowercased()
                slots["referenceKind"] = referenceKind.rawValue
                slots["candidateRequest"] = parent.request
                slots["candidateSource"] = parent.sourceLabel
                slots["priorTerminalOutcome"] = parent.terminalOutcome
                slots["priorTerminalVerification"] =
                    parent.terminalVerification
                slots["priorTerminalReason"] = parent.terminalReason
                if let correctionKind {
                    slots["correctionKind"] = correctionKind.rawValue
                }
                context = OwnerTurnContext(
                    sessionID: context.sessionID,
                    turnID: context.turnID,
                    exactInput: context.exactInput,
                    scope: context.scope,
                    pendingSlot: context.pendingSlot,
                    resolvedSlots: slots,
                    selectedRoute: "provider.reasoning"
                )
            }
        }
        let binding = OwnerTurnBinding(
            context: context,
            envelope: envelope,
            correlationID: admittedEvent.correlationID
        )
        if let preservedInquiryParent {
            nonDestructiveInquiryParentByCorrelationID[
                binding.correlationID
            ] = preservedInquiryParent
        }
        activeBinding = binding
        bindingsByCorrelationID[binding.correlationID] = binding
        observeContext(context)
        return binding
    }

    @discardableResult
    func admitDirectControl(
        sessionID: UUID,
        turnID: UUID,
        correlationID: UUID,
        controlID: String,
        preservingPrivateParent expectedParent:
            OwnerTurnBinding? = nil
    ) -> OwnerTurnControlBinding {
        let preservedParent = startedPrivateRecoveryBinding(expectedParent)
        if let preservedParent {
            if let activeBinding,
               activeBinding != preservedParent {
                _ = finishManagerDispatch(
                    for: activeBinding,
                    status: .cancelled,
                    outcome: "replaced"
                )
                retireBindingState(activeBinding)
            }
            preservedPrivateRecoveryBinding = preservedParent
        } else {
            cancelReplacedDispatchIfNeeded()
            retireActiveBindingState()
        }
        let boundedID = String(
            controlID.lowercased().filter {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "."
            }.prefix(80)
        )
        let context = OwnerTurnContext(
            sessionID: sessionID,
            turnID: turnID,
            exactInput: controlID,
            scope: .ownerPersonal,
            pendingSlot: nil,
            resolvedSlots: [:],
            selectedRoute: "native.control." + boundedID
        )
        let envelope = OwnerRequestNormalizer.makeEnvelope(
            sessionID: sessionID,
            turnID: turnID,
            correlationID: correlationID,
            origin: .directControl,
            exactTranscript: controlID,
            admittedAt: Date(),
            recentExactTarget: nil
        )
        let binding = OwnerTurnBinding(
            context: context,
            envelope: envelope,
            correlationID: correlationID
        )
        activeBinding = binding
        bindingsByCorrelationID[binding.correlationID] = binding
        if let preservedParent {
            privateParentByControlCorrelationID[binding.correlationID] =
                preservedParent
        }
        observeContext(context)
        beginManagerDispatch(for: binding)
        return OwnerTurnControlBinding(
            control: binding,
            preservedPrivateParent: preservedParent
        )
    }

    /// Opens the one canonical route lifecycle on the admitted event's own
    /// correlation. Real manager handlers and async location callbacks all
    /// resolve this same lifecycle; there is no proof-only second terminal.
    func beginManagerDispatch(for binding: OwnerTurnBinding) {
        guard bindingsByCorrelationID[binding.correlationID] == binding,
              startedDispatches.insert(binding.correlationID).inserted else {
            return
        }
        _ = eventBus.publishOutbound(
            source: .system,
            state: .routed,
            payloadType: .executionReceipt,
            payload:
                "owner-turn-route.selected."
                    + binding.context.selectedRoute,
            turnID: binding.context.turnID,
            correlationID: binding.correlationID
        )
    }

    /// A synchronous handler that did not publish a more specific outcome
    /// still closes its canonical route lifecycle. Async native work marks
    /// the binding first and is closed only by the frozen callback.
    func finishManagerDispatchIfSynchronous(
        for binding: OwnerTurnBinding
    ) {
        guard !asynchronousDispatches.contains(binding.correlationID) else {
            return
        }
        let state: AceEventState =
            binding.context.selectedRoute == "owner.stop"
                ? .cancelled : .completed
        _ = finishManagerDispatch(
            for: binding,
            status: state,
            outcome:
                binding.context.selectedRoute == "owner.stop"
                    ? "cancelled" : "dispatched"
        )
    }

    /// Transfers the admitted lifecycle to a real async native outcome. The
    /// top-level manager defer will then leave the canonical correlation open
    /// until the app-action/location completion resolves it.
    @discardableResult
    func deferManagerDispatch(
        for context: OwnerTurnContext
    ) -> Bool {
        guard let binding = activeBinding,
              binding.context == context else {
            return false
        }
        return deferManagerDispatch(for: binding)
    }

    /// Transfers only a still-active, already-started frozen binding. Private
    /// recovery controls use this identity form so a later UI correlation can
    /// never replace the Mail/Messages route that owns the eventual effect.
    @discardableResult
    func deferManagerDispatch(
        for binding: OwnerTurnBinding
    ) -> Bool {
        guard activeBinding == binding
                || preservedPrivateRecoveryBinding == binding,
              startedDispatches.contains(binding.correlationID),
              !terminalDispatches.contains(binding.correlationID) else {
            return false
        }
        asynchronousDispatches.insert(binding.correlationID)
        if locationCompletionInProgressCorrelationID
            == binding.correlationID {
            locationTransferredDispatches.insert(binding.correlationID)
        }
        return true
    }

    /// Returns the original private route only while it still owns one live,
    /// started asynchronous lifecycle. Stop or any replacement admission
    /// retires it, making a stale recovery control fail closed.
    func startedPrivateRecoveryBinding(
        _ expected: OwnerTurnBinding?
    ) -> OwnerTurnBinding? {
        guard let expected,
              activeBinding == expected
                || preservedPrivateRecoveryBinding == expected,
              ["native.mail.compose", "native.messages.compose"]
                .contains(expected.context.selectedRoute),
              startedDispatches.contains(expected.correlationID),
              asynchronousDispatches.contains(expected.correlationID),
              !terminalDispatches.contains(expected.correlationID) else {
            return nil
        }
        return expected
    }

    /// Runs an optional Automation probe only after one single-use claim has
    /// atomically bound the still-active click to its live private parent. A
    /// replacement before launch returns without invoking `operation`; a
    /// replacement while it is suspended rejects the stale result.
    func performPrivateRecoveryAutomationLaunch<Result>(
        for controlBinding: OwnerTurnControlBinding,
        operation: (OwnerTurnBinding) async -> Result
    ) async -> Result? {
        let control = controlBinding.control
        guard activeBinding == control,
              startedDispatches.contains(control.correlationID),
              !terminalDispatches.contains(control.correlationID),
              let parent = controlBinding.preservedPrivateParent,
              privateParentByControlCorrelationID[
                control.correlationID
              ] == parent,
              startedPrivateRecoveryBinding(parent) == parent,
              claimedAutomationParentCorrelationIDs.insert(
                parent.correlationID
              ).inserted else {
            return nil
        }
        let result = await operation(parent)
        guard activeBinding == control,
              startedDispatches.contains(control.correlationID),
              !terminalDispatches.contains(control.correlationID),
              privateParentByControlCorrelationID[
                control.correlationID
              ] == parent,
              startedPrivateRecoveryBinding(parent) == parent else {
            return nil
        }
        return result
    }

    /// Closes only the independently admitted click lifecycle. If its private
    /// parent is still live, that parent resumes as the active route and stays
    /// open for the eventual Mail/Messages app-action outcome.
    @discardableResult
    func finishDirectControl(
        _ controlBinding: OwnerTurnControlBinding,
        status: AceEventState,
        outcome: String
    ) -> Bool {
        let control = controlBinding.control
        guard control.context.selectedRoute.hasPrefix("native.control.")
        else { return false }
        return finishManagerDispatch(
            for: control,
            status: status,
            outcome: outcome
        )
    }

    /// The single private-recovery launch gate. The execute closure runs only
    /// after the original Mail/Messages correlation is still live and has
    /// successfully retained asynchronous ownership.
    @discardableResult
    func dispatchPrivateRecoveryAppAction(
        for expected: OwnerTurnBinding?,
        execute: (OwnerTurnBinding) -> Void
    ) -> Bool {
        guard let binding = startedPrivateRecoveryBinding(expected),
              deferManagerDispatch(for: binding) else {
            return false
        }
        execute(binding)
        return true
    }

    /// The single terminal publisher for one admitted manager route. Passing
    /// an already-resolved binding is preferred; this identity form lets the
    /// manager's existing async completion sites retain their frozen IDs.
    @discardableResult
    func finishManagerDispatch(
        turnID: UUID?,
        correlationID: UUID?,
        status: AceEventState,
        outcome: String
    ) -> Bool {
        guard let turnID, let correlationID,
              let binding = bindingsByCorrelationID[correlationID],
              binding.context.turnID == turnID else {
            return false
        }
        return finishManagerDispatch(
            for: binding,
            status: status,
            outcome: outcome
        )
    }

    /// Compound execution order comes only from admission-frozen slots. The
    /// manager consumes these typed steps and never reparses `exactInput`.
    func compoundDispatchSteps(
        for binding: OwnerTurnBinding
    ) -> [OwnerTurnCompoundDispatchStep]? {
        let context = binding.context
        guard ["native.locate-action", "provider.reasoning"]
                .contains(context.selectedRoute),
              context.resolvedSlots["actionRoute"]
                == "native.app-switch",
              let locate = context.resolvedSlots["locateInstruction"],
              let appTarget = context.resolvedSlots["appTarget"] else {
            return nil
        }
        return [.locate(locate), .appSwitch(appTarget)]
    }

    /// Executes only the admission-frozen app candidate. The instruction text
    /// is deliberately unavailable to this boundary, so downstream code has
    /// nothing it can reparse into a different target.
    @discardableResult
    func dispatchAppSwitch(
        for binding: OwnerTurnBinding,
        execute: (String) -> Void
    ) -> Bool {
        guard activeBinding == binding,
              ["native.app-switch", "provider.reasoning"].contains(
                binding.context.selectedRoute
              ),
              let appTarget = binding.context.resolvedSlots["appTarget"],
              !appTarget.isEmpty else {
            return false
        }
        execute(appTarget)
        return true
    }

    /// Production weather fallback transition. The frozen active binding—not
    /// mutable manager globals—owns the immediately following locality slot.
    @discardableResult
    func transitionToSpokenLocality(
        for context: OwnerTurnContext
    ) -> Bool {
        guard activeBinding?.context == context else { return false }
        pendingLocalitySessionID = context.sessionID
        return true
    }

    func clear() {
        cancelReplacedDispatchIfNeeded()
        pendingLocalitySessionID = nil
        activeBinding = nil
        preservedPrivateRecoveryBinding = nil
        activeLocationRequestID = nil
        locationCompletionInProgressCorrelationID = nil
        bindingsByCorrelationID.removeAll(keepingCapacity: false)
        startedDispatches.removeAll(keepingCapacity: false)
        asynchronousDispatches.removeAll(keepingCapacity: false)
        locationTransferredDispatches.removeAll(keepingCapacity: false)
        terminalDispatches.removeAll(keepingCapacity: false)
        privateParentByControlCorrelationID.removeAll(
            keepingCapacity: false
        )
        nonDestructiveInquiryParentByCorrelationID.removeAll(
            keepingCapacity: false
        )
        claimedAutomationParentCorrelationIDs.removeAll(
            keepingCapacity: false
        )
    }

    /// Starts one injected or live Core Location request on a frozen binding.
    /// If another owner turn is admitted before completion, the callback is
    /// reported stale and cannot reach the manager's effect/terminal closure.
    func startLocationRequest(
        for binding: OwnerTurnBinding,
        requiringSpokenLocalityOnFailure: Bool = false,
        request: (
            @escaping (NativeLocationRequestOutcome) -> Void
        ) -> Void,
        receive: @escaping (
            OwnerTurnBinding,
            NativeLocationRequestOutcome
        ) -> Void,
        stale: @escaping (OwnerTurnBinding) -> Void = { _ in }
    ) {
        asynchronousDispatches.insert(binding.correlationID)
        let requestID = UUID()
        activeLocationRequestID = requestID
        request { [weak self] outcome in
            guard let self else { return }
            guard self.activeLocationRequestID == requestID,
                  self.activeBinding == binding else {
                stale(binding)
                return
            }
            self.activeLocationRequestID = nil
            self.locationCompletionInProgressCorrelationID =
                binding.correlationID
            defer {
                self.locationCompletionInProgressCorrelationID = nil
            }
            if requiringSpokenLocalityOnFailure,
               !Self.locationOutcomeIsReady(outcome) {
                self.pendingLocalitySessionID =
                    binding.context.sessionID
            }
            receive(binding, outcome)
            if self.locationTransferredDispatches.remove(
                binding.correlationID
            ) != nil {
                return
            }
            _ = self.finishManagerDispatch(
                for: binding,
                status: Self.locationOutcomeIsReady(outcome)
                    ? .completed : .failed,
                outcome: Self.locationOutcomeIsReady(outcome)
                    ? "location-ready" : "location-unavailable"
            )
        }
    }

    @discardableResult
    private func finishManagerDispatch(
        for binding: OwnerTurnBinding,
        status: AceEventState,
        outcome: String
    ) -> Bool {
        guard status.isTerminal,
              startedDispatches.contains(binding.correlationID),
              terminalDispatches.insert(binding.correlationID).inserted else {
            return false
        }
        let published = eventBus.publishTerminalWork(
            source: .system,
            state: status,
            payloadType: .executionReceipt,
            payload: "owner-turn-route." + outcome,
            turnID: binding.context.turnID,
            correlationID: binding.correlationID
        )
        guard published else {
            terminalDispatches.remove(binding.correlationID)
            return false
        }
        asynchronousDispatches.remove(binding.correlationID)
        locationTransferredDispatches.remove(binding.correlationID)
        if preservedPrivateRecoveryBinding == binding {
            preservedPrivateRecoveryBinding = nil
            claimedAutomationParentCorrelationIDs.remove(
                binding.correlationID
            )
        }
        if binding.context.selectedRoute.hasPrefix("native.control.") {
            let parent = privateParentByControlCorrelationID.removeValue(
                forKey: binding.correlationID
            )
            if activeBinding == binding {
                if let parent,
                   startedPrivateRecoveryBinding(parent) == parent {
                    activeBinding = parent
                } else {
                    activeBinding = nil
                }
            }
            retireBindingState(binding)
        } else if binding.context.selectedRoute == "native.work-status"
            || binding.context.selectedRoute == "native.stealth-help"
            || binding.context.selectedRoute == "native.response-repeat" {
            let parent = nonDestructiveInquiryParentByCorrelationID.removeValue(
                forKey: binding.correlationID
            )
            if activeBinding == binding {
                activeBinding = parent
            }
            retireBindingState(binding)
        }
        return true
    }

    private func cancelReplacedDispatchIfNeeded() {
        var bindings: [OwnerTurnBinding] = []
        if let activeBinding {
            bindings.append(activeBinding)
        }
        if let preservedPrivateRecoveryBinding,
           !bindings.contains(preservedPrivateRecoveryBinding) {
            bindings.append(preservedPrivateRecoveryBinding)
        }
        for binding in bindings
        where startedDispatches.contains(binding.correlationID)
            && !terminalDispatches.contains(binding.correlationID) {
                _ = finishManagerDispatch(
                    for: binding,
                    status: .cancelled,
                    outcome: "replaced"
                )
            }
    }

    /// Only the active route and its possible duplicate callback need retained
    /// lifecycle state. A newly admitted turn first terminalizes the prior
    /// route, then retires its content-free identifiers.
    private func retireActiveBindingState() {
        var bindings: [OwnerTurnBinding] = []
        if let activeBinding {
            bindings.append(activeBinding)
        }
        if let preservedPrivateRecoveryBinding,
           !bindings.contains(preservedPrivateRecoveryBinding) {
            bindings.append(preservedPrivateRecoveryBinding)
        }
        for binding in bindings {
            retireBindingState(binding)
        }
        activeBinding = nil
        preservedPrivateRecoveryBinding = nil
        privateParentByControlCorrelationID.removeAll(
            keepingCapacity: false
        )
        nonDestructiveInquiryParentByCorrelationID.removeAll(
            keepingCapacity: false
        )
    }

    private func retireBindingState(_ binding: OwnerTurnBinding) {
        bindingsByCorrelationID.removeValue(
            forKey: binding.correlationID
        )
        startedDispatches.remove(binding.correlationID)
        asynchronousDispatches.remove(binding.correlationID)
        locationTransferredDispatches.remove(binding.correlationID)
        terminalDispatches.remove(binding.correlationID)
        privateParentByControlCorrelationID.removeValue(
            forKey: binding.correlationID
        )
        nonDestructiveInquiryParentByCorrelationID.removeValue(
            forKey: binding.correlationID
        )
        claimedAutomationParentCorrelationIDs.remove(
            binding.correlationID
        )
    }

    private nonisolated static func locationOutcomeIsReady(
        _ outcome: NativeLocationRequestOutcome
    ) -> Bool {
        if case .ready = outcome { return true }
        return false
    }
}
#endif // circuit-convert
