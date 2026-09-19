import Foundation

nonisolated enum RecentOwnerWorkLane: String, Equatable, Sendable {
    case direct
    case gold
    case partner
    case hq
    case red
    case silver
    case notes
    case trading
    case briefing
}

nonisolated enum RecentOwnerWorkStatus: String, Equatable, Sendable {
    case awaitingConfirmation
    case running
    case completed
    case blocked
    case failed
    case cancelled

    fileprivate var isRunningReferenceCandidate: Bool {
        self == .awaitingConfirmation || self == .running
    }

    fileprivate var isCompletedReferenceCandidate: Bool {
        self == .completed
    }
}

/// The buyer-facing projection of one admitted request. This is intentionally
/// app-owned: provider prose can never decide whether work was accepted,
/// delegated, completed, or recoverable.
nonisolated struct AceBuyerWorkReceipt: Identifiable, Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case accepted
        case clarifying
        case processing
        case executing
        case completed
        case blocked
        case failed
        case cancelled
    }

    let id: UUID
    let boundedTaskDescription: String
    let owningLane: RecentOwnerWorkLane
    let phase: Phase
    let acceptedAt: Date
    let updatedAt: Date
    let mostRecentRealProgress: String
    let terminalResult: String?
    let recoveryAction: String?

    var durableWorkID: String { id.uuidString.lowercased() }

    var isTerminal: Bool {
        switch phase {
        case .completed, .blocked, .failed, .cancelled:
            return true
        case .accepted, .clarifying, .processing, .executing:
            return false
        }
    }

    /// Running receipts report live elapsed time. A terminal receipt freezes at
    /// the instant its terminal projection was saved; otherwise opening the
    /// panel hours later falsely makes completed work look hours slow.
    func elapsedSeconds(at timestamp: Date = Date()) -> Int {
        let elapsedThrough = isTerminal ? updatedAt : timestamp
        return max(
            0,
            Int(
                elapsedThrough.timeIntervalSince(acceptedAt)
                    .rounded(.down)
            )
        )
    }

    var spokenAcceptance: String {
        "Got it."
    }

    /// A status answer is intentionally conversational. The complete immutable
    /// ID and audit fields remain visible in Work Receipts; reading them aloud
    /// before the useful answer made ordinary voice turns sound like debug
    /// output and repeated the owner's entire request.
    func spokenStatus(at timestamp: Date = Date()) -> String {
        let elapsedSeconds = elapsedSeconds(at: timestamp)
        let phaseDescription: String
        switch phase {
        case .accepted:
            phaseDescription = "accepted it"
        case .clarifying:
            phaseDescription = "is waiting for one required detail"
        case .processing:
            phaseDescription = "is processing it"
        case .executing:
            phaseDescription = "is executing it"
        case .completed:
            phaseDescription = "completed it"
        case .blocked:
            phaseDescription = "is blocked"
        case .failed:
            phaseDescription = "failed"
        case .cancelled:
            phaseDescription = "cancelled it"
        }
        var text = "The task is \(boundedTaskDescription). "
            + "\(owningLane.buyerLabel) \(phaseDescription) after "
            + "\(elapsedSeconds) seconds. "
            + "Latest: \(mostRecentRealProgress)"
        if let terminalResult, terminalResult != mostRecentRealProgress {
            text += ". Result: \(terminalResult)"
        }
        if let recoveryAction {
            text += ". Next: \(recoveryAction)"
        }
        return text
    }
}

extension RecentOwnerWorkLane {
    nonisolated var buyerLabel: String {
        switch self {
        case .direct: return "Ace"
        case .gold: return "Default brain"
        case .partner: return "Partner"
        case .hq: return "Ace HQ"
        case .red: return "Red"
        case .silver: return "Silver"
        case .notes: return "Meeting Notes"
        case .trading: return "Trading"
        case .briefing: return "Morning Briefing"
        }
    }
}

nonisolated enum OwnerWorkReferenceKind: String, Equatable, Sendable {
    case none
    case pronoun
    case lastThing
    case localityAnchor
    case localityClarification
}

nonisolated enum OwnerWorkResolutionStatus: String, Equatable, Sendable {
    case direct
    case resolved
}

/// The app-owned request for one admitted owner turn. The current transcript
/// remains exact and immutable even when bounded reference grammar creates a
/// more explicit request for routing.
nonisolated struct OwnerWorkContinuationAdmission: Equatable, Sendable {
    let turnIdentifier: UUID
    let correlationIdentifier: UUID
}

nonisolated struct ContextualOwnerRequest: Equatable, Sendable {
    let originalOwnerTranscript: String
    let resolvedRequest: String
    let correctionContext: OwnerCorrectionContext?
    let sourceSessionIdentifier: UUID
    let sourceTurnIdentifier: UUID
    let sourceCorrelationIdentifier: UUID
    let parentWorkCorrelationIdentifier: UUID?
    let childWorkCorrelationIdentifier: UUID
    let referenceKind: OwnerWorkReferenceKind
    let resolutionStatus: OwnerWorkResolutionStatus
    let continuationAdmission: OwnerWorkContinuationAdmission?

    init(
        originalOwnerTranscript: String,
        resolvedRequest: String,
        correctionContext: OwnerCorrectionContext? = nil,
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        sourceCorrelationIdentifier: UUID,
        parentWorkCorrelationIdentifier: UUID?,
        childWorkCorrelationIdentifier: UUID,
        referenceKind: OwnerWorkReferenceKind,
        resolutionStatus: OwnerWorkResolutionStatus,
        continuationAdmission: OwnerWorkContinuationAdmission? = nil
    ) {
        self.originalOwnerTranscript = originalOwnerTranscript
        self.resolvedRequest = resolvedRequest
        self.correctionContext = correctionContext
        self.sourceSessionIdentifier = sourceSessionIdentifier
        self.sourceTurnIdentifier = sourceTurnIdentifier
        self.sourceCorrelationIdentifier = sourceCorrelationIdentifier
        self.parentWorkCorrelationIdentifier =
            parentWorkCorrelationIdentifier
        self.childWorkCorrelationIdentifier =
            childWorkCorrelationIdentifier
        self.referenceKind = referenceKind
        self.resolutionStatus = resolutionStatus
        self.continuationAdmission = continuationAdmission
    }

    var executionInstruction: String {
        correctionContext?.executionInstruction(
            objective: resolvedRequest
        ) ?? resolvedRequest
    }
}

nonisolated enum RecentOwnerWorkResolution: Equatable, Sendable {
    case route(ContextualOwnerRequest)
    case clarification(String)
}

/// A bounded typed record of owner work. No assistant response, model summary,
/// prompt, or tool output is accepted by this type. The concise description is
/// produced only from the app-resolved owner request at record time.
nonisolated struct RecentOwnerWorkEntry: Equatable, Sendable {
    let originalOwnerTranscript: String
    let appOwnedRequestDescription: String
    let sourceSessionIdentifier: UUID
    let sourceTurnIdentifier: UUID
    let sourceCorrelationIdentifier: UUID
    let parentWorkCorrelationIdentifier: UUID?
    let workCorrelationIdentifier: UUID
    private(set) var lane: RecentOwnerWorkLane
    private(set) var status: RecentOwnerWorkStatus
    let createdAt: Date
    private(set) var updatedAt: Date

    fileprivate init(
        originalOwnerTranscript: String,
        appOwnedRequestDescription: String,
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        sourceCorrelationIdentifier: UUID,
        parentWorkCorrelationIdentifier: UUID?,
        workCorrelationIdentifier: UUID,
        lane: RecentOwnerWorkLane,
        status: RecentOwnerWorkStatus,
        createdAt: Date
    ) {
        self.originalOwnerTranscript = originalOwnerTranscript
        self.appOwnedRequestDescription = appOwnedRequestDescription
        self.sourceSessionIdentifier = sourceSessionIdentifier
        self.sourceTurnIdentifier = sourceTurnIdentifier
        self.sourceCorrelationIdentifier = sourceCorrelationIdentifier
        self.parentWorkCorrelationIdentifier =
            parentWorkCorrelationIdentifier
        self.workCorrelationIdentifier = workCorrelationIdentifier
        self.lane = lane
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    fileprivate mutating func transition(
        lane: RecentOwnerWorkLane,
        status: RecentOwnerWorkStatus,
        at timestamp: Date
    ) {
        self.lane = lane
        self.status = status
        updatedAt = max(timestamp, createdAt)
    }
}

/// In-memory on purpose. This is routing context for one live Ace process, not
/// conversational memory and not a durable instruction store.
nonisolated struct RecentOwnerWorkStore: Sendable {
    private static let maximumOwnerTranscriptCharacters = 8_000
    private static let maximumDescriptionCharacters = 1_200
    private static let maximumClarificationLabelCharacters = 96

    let maximumEntries: Int
    let maximumReferenceAge: TimeInterval
    private(set) var entries: [RecentOwnerWorkEntry] = []

    init(
        maximumEntries: Int = 24,
        maximumReferenceAge: TimeInterval = 30 * 60
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumReferenceAge = max(1, maximumReferenceAge)
    }

    /// Production and tests share this resolver. It consumes only admitted,
    /// app-owned candidates and produces one typed continuation decision.
    mutating func resolveAndRecord(
        admittedOwnerTranscript: String,
        normalizedRequest: String,
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        sourceCorrelationIdentifier: UUID,
        childWorkCorrelationIdentifier: UUID = UUID(),
        at timestamp: Date = Date()
    ) -> RecentOwnerWorkResolution {
        let exactOwnerTranscript = boundedOwnerTranscript(
            admittedOwnerTranscript
        )
        let directRequest = boundedDescription(normalizedRequest)

        let decision = resolutionDecision(
            normalizedRequest: directRequest,
            sourceSessionIdentifier: sourceSessionIdentifier,
            at: timestamp
        )
        switch decision {
        case let .clarification(question):
            return .clarification(question)
        case let .resolved(
            resolvedRequest,
            parent,
            referenceKind
        ):
            let request = ContextualOwnerRequest(
                originalOwnerTranscript: exactOwnerTranscript,
                resolvedRequest: resolvedRequest,
                sourceSessionIdentifier: sourceSessionIdentifier,
                sourceTurnIdentifier: sourceTurnIdentifier,
                sourceCorrelationIdentifier:
                    sourceCorrelationIdentifier,
                parentWorkCorrelationIdentifier:
                    parent?.workCorrelationIdentifier,
                childWorkCorrelationIdentifier:
                    childWorkCorrelationIdentifier,
                referenceKind: referenceKind,
                resolutionStatus:
                    referenceKind == .none ? .direct : .resolved
            )
            _ = recordExecution(
                originalOwnerTranscript:
                    request.originalOwnerTranscript,
                resolvedRequest: request.resolvedRequest,
                sourceSessionIdentifier:
                    request.sourceSessionIdentifier,
                sourceTurnIdentifier:
                    request.sourceTurnIdentifier,
                sourceCorrelationIdentifier:
                    request.sourceCorrelationIdentifier,
                parentWorkCorrelationIdentifier:
                    request.parentWorkCorrelationIdentifier,
                workCorrelationIdentifier:
                    request.childWorkCorrelationIdentifier,
                lane: .direct,
                status: .running,
                at: timestamp
            )
            return .route(request)
        }
    }
    /// Adds a typed lane request or advances an existing entry with the same
    /// exact identity. A correlation cannot be rebound to different owner bytes.
    @discardableResult
    mutating func recordExecution(
        originalOwnerTranscript: String,
        resolvedRequest: String,
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        sourceCorrelationIdentifier: UUID,
        parentWorkCorrelationIdentifier: UUID?,
        workCorrelationIdentifier: UUID,
        lane: RecentOwnerWorkLane,
        status: RecentOwnerWorkStatus,
        at timestamp: Date = Date()
    ) -> Bool {
        let exactOwnerTranscript = boundedOwnerTranscript(
            originalOwnerTranscript
        )
        let description = boundedDescription(resolvedRequest)
        guard !exactOwnerTranscript.isEmpty,
              !description.isEmpty else {
            return false
        }

        if let existingIndex = entries.firstIndex(where: {
            $0.workCorrelationIdentifier == workCorrelationIdentifier
        }) {
            let existing = entries[existingIndex]
            guard existing.originalOwnerTranscript
                    == exactOwnerTranscript,
                  existing.appOwnedRequestDescription
                    == description,
                  existing.sourceSessionIdentifier
                    == sourceSessionIdentifier,
                  existing.sourceTurnIdentifier
                    == sourceTurnIdentifier,
                  existing.sourceCorrelationIdentifier
                    == sourceCorrelationIdentifier,
                  existing.parentWorkCorrelationIdentifier
                    == parentWorkCorrelationIdentifier else {
                return false
            }
            entries[existingIndex].transition(
                lane: lane,
                status: status,
                at: timestamp
            )
            return true
        }

        entries.append(
            RecentOwnerWorkEntry(
                originalOwnerTranscript: exactOwnerTranscript,
                appOwnedRequestDescription: description,
                sourceSessionIdentifier: sourceSessionIdentifier,
                sourceTurnIdentifier: sourceTurnIdentifier,
                sourceCorrelationIdentifier:
                    sourceCorrelationIdentifier,
                parentWorkCorrelationIdentifier:
                    parentWorkCorrelationIdentifier,
                workCorrelationIdentifier:
                    workCorrelationIdentifier,
                lane: lane,
                status: status,
                createdAt: timestamp
            )
        )
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        return true
    }

    /// Status and lane are the only mutable fields. Every authority-bearing
    /// identity remains unchanged across routing and terminal receipts.
    @discardableResult
    mutating func transition(
        workCorrelationIdentifier: UUID,
        lane: RecentOwnerWorkLane,
        status: RecentOwnerWorkStatus,
        at timestamp: Date = Date()
    ) -> Bool {
        guard let index = entries.firstIndex(where: {
            $0.workCorrelationIdentifier == workCorrelationIdentifier
        }) else {
            return false
        }
        entries[index].transition(
            lane: lane,
            status: status,
            at: timestamp
        )
        return true
    }

    func entry(
        workCorrelationIdentifier: UUID
    ) -> RecentOwnerWorkEntry? {
        entries.first {
            $0.workCorrelationIdentifier == workCorrelationIdentifier
        }
    }

    func entry(
        sourceSessionIdentifier: UUID,
        sourceTurnIdentifier: UUID,
        sourceCorrelationIdentifier: UUID
    ) -> RecentOwnerWorkEntry? {
        entries.last {
            $0.sourceSessionIdentifier == sourceSessionIdentifier
                && $0.sourceTurnIdentifier == sourceTurnIdentifier
                && $0.sourceCorrelationIdentifier
                    == sourceCorrelationIdentifier
        }
    }

    /// Read-only, labeled input for the one authoritative turn resolver.
    /// Candidate retrieval never creates a child, changes a status, or chooses
    /// a route. Only current-session bounded work is exposed.
    func nonauthoritativeCandidates(
        sourceSessionIdentifier: UUID,
        at timestamp: Date = Date()
    ) -> [OwnerContextCandidate] {
        preferredCandidates(
            sourceSessionIdentifier: sourceSessionIdentifier,
            at: timestamp
        ).map { entry in
            OwnerContextCandidate(
                sourceLabel: "recent-work candidate",
                request: entry.appOwnedRequestDescription,
                sourceSessionID: entry.sourceSessionIdentifier,
                workCorrelationID: entry.workCorrelationIdentifier,
                updatedAt: entry.updatedAt,
                continuationUnavailableReason:
                    "The exact saved instructions are unavailable. Enter the full remaining request."
            )
        }
    }

    private enum Decision {
        case resolved(
            request: String,
            parent: RecentOwnerWorkEntry?,
            referenceKind: OwnerWorkReferenceKind
        )
        case clarification(String)
    }

    private func resolutionDecision(
        normalizedRequest: String,
        sourceSessionIdentifier: UUID,
        at timestamp: Date
    ) -> Decision {
        let reference = explicitReference(in: normalizedRequest)
        if let reference {
            let candidates = preferredCandidates(
                sourceSessionIdentifier: sourceSessionIdentifier,
                at: timestamp
            )
            switch reference {
            case .lastThing:
                guard let parent = singleNewestCandidate(candidates) else {
                    return candidates.isEmpty
                        ? .clarification(
                            "Which recent request do you mean by the last thing?"
                        )
                        : .clarification(
                            clarificationQuestion(for: candidates)
                        )
                }
                return .resolved(
                    request: parent.appOwnedRequestDescription,
                    parent: parent,
                    referenceKind: .lastThing
                )
            case .pronoun:
                guard candidates.count == 1,
                      let parent = candidates.first else {
                    return candidates.isEmpty
                        ? .clarification(
                            "Which recent request do you mean?"
                        )
                        : .clarification(
                            clarificationQuestion(for: candidates)
                        )
                }
                return .resolved(
                    request: parent.appOwnedRequestDescription,
                    parent: parent,
                    referenceKind: .pronoun
                )
            default:
                break
            }
        }

        if isLocalWeatherRequest(normalizedRequest),
           explicitLocality(in: normalizedRequest) == nil {
            let localityCandidates = preferredCandidates(
                sourceSessionIdentifier: sourceSessionIdentifier,
                at: timestamp
            ).filter {
                explicitLocality(
                    in: $0.appOwnedRequestDescription
                ) != nil
            }
            if localityCandidates.count == 1,
               let parent = localityCandidates.first,
               let locality = explicitLocality(
                   in: parent.appOwnedRequestDescription
               ) {
                return .resolved(
                    request: "weather in " + locality,
                    parent: parent,
                    referenceKind: .localityAnchor
                )
            }
            if localityCandidates.count > 1 {
                return .clarification(
                    localityClarificationQuestion(
                        for: localityCandidates
                    )
                )
            }
        }

        if let locality = explicitLocality(in: normalizedRequest),
           isLocalityOnlyRequest(normalizedRequest) {
            let weatherCandidates = preferredCandidates(
                sourceSessionIdentifier: sourceSessionIdentifier,
                at: timestamp
            ).filter {
                isLocalWeatherRequest(
                    $0.appOwnedRequestDescription
                ) && explicitLocality(
                    in: $0.appOwnedRequestDescription
                ) == nil
            }
            if weatherCandidates.count == 1,
               let parent = weatherCandidates.first {
                return .resolved(
                    request: "weather in " + locality,
                    parent: parent,
                    referenceKind: .localityClarification
                )
            }
            if weatherCandidates.count > 1 {
                return .clarification(
                    clarificationQuestion(for: weatherCandidates)
                )
            }
        }

        return .resolved(
            request: normalizedRequest,
            parent: nil,
            referenceKind: .none
        )
    }

    private func preferredCandidates(
        sourceSessionIdentifier: UUID,
        at timestamp: Date
    ) -> [RecentOwnerWorkEntry] {
        let current = entries.filter { entry in
            let age = timestamp.timeIntervalSince(entry.createdAt)
            return entry.sourceSessionIdentifier
                    == sourceSessionIdentifier
                && age >= 0
                && age <= maximumReferenceAge
                && (entry.status.isRunningReferenceCandidate
                    || entry.status.isCompletedReferenceCandidate)
        }
        let running = current.filter {
            $0.status.isRunningReferenceCandidate
        }
        let preferred = running.isEmpty
            ? current.filter { $0.status.isCompletedReferenceCandidate }
            : running
        return preferred.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.createdAt > $1.createdAt
        }
    }

    private func singleNewestCandidate(
        _ candidates: [RecentOwnerWorkEntry]
    ) -> RecentOwnerWorkEntry? {
        guard let newest = candidates.first else { return nil }
        if candidates.count > 1,
           candidates[1].createdAt == newest.createdAt,
           candidates[1].updatedAt == newest.updatedAt {
            return nil
        }
        return newest
    }

    private func clarificationQuestion(
        for candidates: [RecentOwnerWorkEntry]
    ) -> String {
        let labels = candidates.prefix(2).map {
            clarificationLabel($0.appOwnedRequestDescription)
        }
        guard labels.count == 2 else {
            return "Which recent request do you mean?"
        }
        return "Did you mean \u{201C}"
            + labels[0]
            + "\u{201D} or \u{201C}"
            + labels[1]
            + "\u{201D}?"
    }

    private func localityClarificationQuestion(
        for candidates: [RecentOwnerWorkEntry]
    ) -> String {
        let localities = candidates.compactMap {
            explicitLocality(in: $0.appOwnedRequestDescription)
        }
        guard localities.count >= 2 else {
            return "Which location should I use for the weather?"
        }
        return "Should I use "
            + localities[0]
            + " or "
            + localities[1]
            + " for the weather?"
    }

    private func clarificationLabel(_ value: String) -> String {
        let singleLine = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return String(
            singleLine.prefix(
                Self.maximumClarificationLabelCharacters
            )
        )
    }

    private func boundedOwnerTranscript(_ value: String) -> String {
        String(
            value.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).prefix(Self.maximumOwnerTranscriptCharacters)
        )
    }

    private func boundedDescription(_ value: String) -> String {
        let singleLine = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
        return String(
            singleLine.prefix(Self.maximumDescriptionCharacters)
        )
    }

    private func explicitReference(
        in request: String
    ) -> OwnerWorkReferenceKind? {
        var normalized = normalizedGrammarText(request)
        // Company-work commands may wrap the same bounded owner reference in
        // one anchored singular delegation prefix. Only the exact imperative
        // grammar is stripped; questions, history, negation, and arbitrary
        // "agent" prose remain direct requests.
        let delegatedReferencePrefix =
            #"^(?:please )?(?:task|assign|ask|request|have) the agent (?:to )?(?:do )?"#
        if normalized.range(
            of: delegatedReferencePrefix,
            options: .regularExpression
        ) != nil {
            normalized = normalized.replacingOccurrences(
                of: delegatedReferencePrefix,
                with: "",
                options: .regularExpression
            )
        }
        let lastThingPatterns: Set<String> = [
            "the last thing",
            "do the last thing",
            "the last thing as well",
            "also the last thing",
            "also do the last thing",
        ]
        if lastThingPatterns.contains(normalized) {
            return .lastThing
        }
        let pronounPatterns: Set<String> = [
            "that",
            "it",
            "do that",
            "do it",
            "that as well",
            "it as well",
            "also do that",
            "also do it",
        ]
        if pronounPatterns.contains(normalized) {
            return .pronoun
        }
        return nil
    }

    private func normalizedGrammarText(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
    }

    private func isLocalWeatherRequest(_ request: String) -> Bool {
        let normalized = normalizedGrammarText(request)
        let hasWeatherNoun = normalized.range(
            of: #"\b(weather|forecast|temperature)\b"#,
            options: .regularExpression
        ) != nil
        let isLocal = normalized.range(
            of: #"\b(local|here|near me|current)\b"#,
            options: .regularExpression
        ) != nil
        return hasWeatherNoun && isLocal
    }

    private func isLocalityOnlyRequest(_ request: String) -> Bool {
        guard let locality = explicitLocality(in: request) else {
            return false
        }
        let trimmed = request.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        return normalizedGrammarText(trimmed)
            == normalizedGrammarText(locality)
    }

    private func explicitLocality(in request: String) -> String? {
        let trimmed = request.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard trimmed.count <= 100,
              trimmed.range(
                  of: #"^[A-Za-z][A-Za-z .'-]*(?:,\s*|\s+)[A-Za-z]{2,20}$"#,
                  options: .regularExpression
              ) != nil else {
            return nil
        }

        let stateNames = Self.stateNames.sorted {
            $0.count > $1.count
        }
        let lowercased = trimmed.lowercased()
        for stateName in stateNames {
            let suffix = " " + stateName
            let commaSuffix = ", " + stateName
            if lowercased.hasSuffix(suffix)
                || lowercased.hasSuffix(commaSuffix) {
                let cityEnd = trimmed.index(
                    trimmed.endIndex,
                    offsetBy: -stateName.count
                )
                let city = trimmed[..<cityEnd]
                    .trimmingCharacters(
                        in: CharacterSet(
                            charactersIn: " ,"
                        )
                    )
                guard !city.isEmpty,
                      city.split(separator: " ").count <= 5 else {
                    return nil
                }
                return trimmed
            }
        }

        let words = trimmed.split(separator: " ")
        guard words.count >= 2,
              words.count <= 6,
              let finalWord = words.last else {
            return nil
        }
        let abbreviation = finalWord
            .trimmingCharacters(
                in: CharacterSet(charactersIn: ",")
            )
        guard abbreviation.count == 2,
              abbreviation == abbreviation.uppercased(),
              Self.stateAbbreviations.contains(abbreviation) else {
            return nil
        }
        return trimmed
    }

    private static let stateNames: Set<String> = [
        "alabama", "alaska", "arizona", "arkansas", "california",
        "colorado", "connecticut", "delaware", "florida", "georgia",
        "hawaii", "idaho", "illinois", "indiana", "iowa", "kansas",
        "kentucky", "louisiana", "maine", "maryland", "massachusetts",
        "michigan", "minnesota", "mississippi", "missouri", "montana",
        "nebraska", "nevada", "new hampshire", "new jersey",
        "new mexico", "new york", "north carolina", "north dakota",
        "ohio", "oklahoma", "oregon", "pennsylvania", "rhode island",
        "south carolina", "south dakota", "tennessee", "texas", "utah",
        "vermont", "virginia", "washington", "west virginia",
        "wisconsin", "wyoming", "district of columbia",
    ]

    private static let stateAbbreviations: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA",
        "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
        "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
        "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
        "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
        "DC",
    ]
}
