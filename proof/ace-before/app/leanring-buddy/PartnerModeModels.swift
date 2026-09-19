import Foundation

nonisolated enum PartnerSessionPhase: String, Codable, Sendable {
    case inactive
    case ready
    case listening
    case processing
    case speaking
    case waiting
    case muted
    case error
}

nonisolated enum PartnerModeCommand: Equatable, Sendable {
    case activate
    case end
    case wait
    case mute
    case resume
    case requestScreenContext
    case correctMemory
    case undoMemory
    case forgetMemory
}

nonisolated enum PartnerVoiceProfile: String, CaseIterable, Codable, Sendable {
    case anchor
    case mercer
    case sterling
    case theo
    case rowan
    case aria
    case claire
    case sage

    var displayName: String {
        switch self {
        case .anchor:
            return "Nora"
        case .mercer:
            return "Jasper"
        case .sterling:
            return "Leo"
        case .theo:
            return "Hugo"
        case .rowan:
            return "Rosie"
        case .aria:
            return "Kiki"
        case .claire:
            return "Bella"
        case .sage:
            return "Bruno"
        }
    }

    var deliveryDescription: String {
        switch self {
        case .anchor:
            return "Warm, patient, and natural."
        case .mercer:
            return "Warm, conversational, and emotionally aware."
        case .sterling:
            return "Crisp, executive, and direct."
        case .theo:
            return "Younger, energetic, and informal."
        case .rowan:
            return "Neutral, measured, and analytical."
        case .aria:
            return "Natural, confident, and composed."
        case .claire:
            return "Clear, confident, and concise."
        case .sage:
            return "Soft, reflective, and neutral."
        }
    }

    var preferredSystemVoiceIdentifiers: [String] {
        switch self {
        case .anchor:
            return ["ace.voice.kokoro.v0_19.sid3"]
        case .mercer:
            return ["ace.voice.kokoro.v0_19.sid6"]
        case .sterling:
            return ["ace.voice.kokoro.v0_19.sid5"]
        case .theo:
            return ["ace.voice.kokoro.v0_19.sid10"]
        case .rowan:
            return ["ace.voice.kokoro.v0_19.sid7"]
        case .aria:
            return ["ace.voice.kokoro.v0_19.sid1"]
        case .claire:
            return ["ace.voice.kokoro.v0_19.sid2"]
        case .sage:
            return ["ace.voice.kokoro.v0_19.sid9"]
        }
    }

    var defaultSpeakingRate: Double {
        switch self {
        case .anchor:
            return 0.45
        case .mercer:
            return 0.48
        case .sterling:
            return 0.53
        case .theo:
            return 0.56
        case .rowan:
            return 0.47
        case .aria:
            return 0.43
        case .claire:
            return 0.51
        case .sage:
            return 0.41
        }
    }

    var defaultWarmth: Double {
        switch self {
        case .anchor:
            return 0.86
        case .mercer:
            return 0.84
        case .sterling:
            return 0.35
        case .theo:
            return 0.66
        case .rowan:
            return 0.48
        case .aria:
            return 0.62
        case .claire:
            return 0.58
        case .sage:
            return 0.78
        }
    }

    var defaultEnergy: Double {
        switch self {
        case .anchor:
            return 0.42
        case .mercer:
            return 0.52
        case .sterling:
            return 0.58
        case .theo:
            return 0.82
        case .rowan:
            return 0.38
        case .aria:
            return 0.32
        case .claire:
            return 0.61
        case .sage:
            return 0.26
        }
    }

    var previewSentence: String {
        PartnerIdentityPreferences.sharedPreviewSentence
    }
}

nonisolated struct PartnerVoiceConfiguration:
    Codable,
    Equatable,
    Sendable
{
    static let bundledVoiceIdentifier = "ace.voice.kokoro.v0_19.sid3"
    static let allowedVoiceIdentifiers: Set<String> = Set([
        "ace.voice.kokoro.v0_19.sid1",
        "ace.voice.kokoro.v0_19.sid2",
        "ace.voice.kokoro.v0_19.sid3",
        "ace.voice.kokoro.v0_19.sid5",
        "ace.voice.kokoro.v0_19.sid6",
        "ace.voice.kokoro.v0_19.sid7",
        "ace.voice.kokoro.v0_19.sid9",
        "ace.voice.kokoro.v0_19.sid10",
    ]).union(AceLanguage.multilingualVoiceIdentifiers)

    let profile: PartnerVoiceProfile
    let preferredVoiceIdentifiers: [String]
    let speakingRate: Double

    var previewSentence: String {
        AceLanguage.allCases.first(where: {
            $0 != .system && $0.voiceIdentifier.map(preferredVoiceIdentifiers.contains) == true
        })?.previewSentence ?? PartnerIdentityPreferences.sharedPreviewSentence
    }

    init(
        profile: PartnerVoiceProfile,
        requestedVoiceIdentifiers: [String],
        speakingRate: Double
    ) {
        self.profile = profile
        preferredVoiceIdentifiers =
            requestedVoiceIdentifiers.reduce(into: []) {
                approvedIdentifiers,
                candidate in
                guard Self.allowedVoiceIdentifiers
                    .contains(candidate),
                      !approvedIdentifiers
                        .contains(candidate) else {
                    return
                }
                approvedIdentifiers.append(candidate)
            }
        self.speakingRate = min(max(speakingRate, 0.35), 0.65)
    }

    static func forProfile(
        _ profile: PartnerVoiceProfile,
        language: AceLanguage = .current
    ) -> PartnerVoiceConfiguration {
        PartnerVoiceConfiguration(
            profile: profile,
            requestedVoiceIdentifiers:
                language.resolved().voiceIdentifier.map { [$0] }
                    ?? profile.preferredSystemVoiceIdentifiers,
            speakingRate: profile.defaultSpeakingRate
        )
    }

    static func from(
        _ preferences: PartnerIdentityPreferences
    ) -> PartnerVoiceConfiguration {
        PartnerVoiceConfiguration(
            profile: preferences.voiceProfile,
            requestedVoiceIdentifiers:
                AceLanguage.current.voiceIdentifier.map { [$0] }
                    ?? preferences.voiceProfile.preferredSystemVoiceIdentifiers,
            speakingRate: preferences.speakingRate
        )
    }
}

nonisolated enum AceVoiceModePolicy {
    static var standardConfiguration: PartnerVoiceConfiguration {
        PartnerVoiceConfiguration(
            profile: .anchor,
            requestedVoiceIdentifiers: AceLanguage.current.voiceIdentifier.map { [$0] }
                ?? ([PartnerVoiceConfiguration.bundledVoiceIdentifier]
                    + PartnerVoiceProfile.anchor.preferredSystemVoiceIdentifiers),
            speakingRate:
                PartnerVoiceProfile.anchor.defaultSpeakingRate
        )
    }
}

nonisolated struct PartnerIdentityPreferences:
    Codable,
    Equatable,
    Sendable
{
    static let assistantName = "Ace"
    static let sharedPreviewSentence =
        "I’m Ace. I’ll think with you, remember what matters, and prove what happens next."

    var identityDescription: String
    var subjectPronouns: String
    var objectPronouns: String
    var possessivePronoun: String
    var voiceProfile: PartnerVoiceProfile
    var speakingRate: Double
    var warmth: Double
    var energy: Double

    init(
        identityDescription: String,
        subjectPronouns: String,
        objectPronouns: String,
        possessivePronoun: String,
        voiceProfile: PartnerVoiceProfile,
        speakingRate: Double,
        warmth: Double,
        energy: Double
    ) {
        self.identityDescription =
            identityDescription.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        self.subjectPronouns =
            subjectPronouns.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        self.objectPronouns =
            objectPronouns.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        self.possessivePronoun =
            possessivePronoun.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        self.voiceProfile = voiceProfile
        self.speakingRate = min(max(speakingRate, 0.35), 0.65)
        self.warmth = min(max(warmth, 0), 1)
        self.energy = min(max(energy, 0), 1)
    }

    static let genericDefault = PartnerIdentityPreferences(
        identityDescription: "",
        subjectPronouns: "",
        objectPronouns: "",
        possessivePronoun: "",
        voiceProfile: .anchor,
        speakingRate: PartnerVoiceProfile.anchor.defaultSpeakingRate,
        warmth: PartnerVoiceProfile.anchor.defaultWarmth,
        energy: PartnerVoiceProfile.anchor.defaultEnergy
    )

    static let founderDefault = PartnerIdentityPreferences(
        identityDescription: "male",
        subjectPronouns: "he",
        objectPronouns: "him",
        possessivePronoun: "his",
        voiceProfile: .anchor,
        speakingRate: PartnerVoiceProfile.anchor.defaultSpeakingRate,
        warmth: PartnerVoiceProfile.anchor.defaultWarmth,
        energy: PartnerVoiceProfile.anchor.defaultEnergy
    )
}

nonisolated enum PartnerMemoryDomain:
    String,
    CaseIterable,
    Codable,
    Sendable
{
    case identityAndLifeHistory
    case valuesAndNonnegotiables
    case goalsAndAmbitions
    case relationshipsAndCommitments
    case healthEnergyAndCapacity
    case moneyObligationsAndRisk
    case workProjectsAndCompany
    case decisionsAndReasons
    case communicationAndExecutionPreferences
    case conflictsAndUnresolvedQuestions
    case beliefChanges
    case sessionSummaries
}

nonisolated enum PartnerMemoryConfirmationState:
    String,
    Codable,
    Sendable
{
    case confirmed
    case inferred
    case unconfirmed
}

nonisolated struct PartnerMemoryRecordVersion:
    Codable,
    Equatable,
    Sendable
{
    let normalizedContent: String
    let userVisibleWording: String
    let confirmationState: PartnerMemoryConfirmationState
    let replacedAt: Date
    let sourceSessionIdentifier: UUID
    let sourceTurnIdentifier: UUID
}

nonisolated struct PartnerMemoryRecord:
    Identifiable,
    Codable,
    Equatable,
    Sendable
{
    let identifier: UUID
    var domain: PartnerMemoryDomain
    let stableKey: String
    var normalizedContent: String
    var userVisibleWording: String
    var confidence: Double
    var confirmationState: PartnerMemoryConfirmationState
    var linkedRecordIdentifiers: [UUID]
    let sourceSessionIdentifier: UUID
    var sourceTurnIdentifier: UUID
    let firstLearnedAt: Date
    var lastUpdatedAt: Date
    var lastConfirmedAt: Date?
    var correctionHistory: [PartnerMemoryRecordVersion]

    var id: UUID {
        identifier
    }
}

nonisolated struct PartnerContradictionRecord:
    Identifiable,
    Codable,
    Equatable,
    Sendable
{
    enum Status: String, Codable, Sendable {
        case unresolved
        case resolved
    }

    let identifier: UUID
    let stableKey: String
    let existingRecordIdentifier: UUID
    let existingContent: String
    let conflictingContent: String
    let sourceSessionIdentifier: UUID
    let sourceTurnIdentifier: UUID
    let createdAt: Date
    var status: Status

    var id: UUID {
        identifier
    }
}

nonisolated struct PartnerAgendaItem:
    Identifiable,
    Codable,
    Equatable,
    Sendable
{
    let identifier: UUID
    let topic: String
    let reason: String
    let createdAt: Date
    var resolvedAt: Date?

    var id: UUID {
        identifier
    }
}

nonisolated struct PartnerGoalRecord:
    Identifiable,
    Codable,
    Equatable,
    Sendable
{
    enum Status: String, Codable, Sendable {
        case proposed
        case active
        case paused
        case completed
        case abandoned
    }

    let identifier: UUID
    let stableKey: String
    var userAuthoredStatement: String
    var normalizedOutcome: String
    var targetDate: Date?
    var currentBaseline: String?
    var successCondition: String?
    var proofSource: String?
    var motivation: String?
    var priority: Int
    var status: Status
    var nextAction: String?
    var dependencies: [String]
    var blockers: [String]
    var acceptableTradeoffs: [String]
    var prohibitedSacrifices: [String]
    var sourceSessionIdentifier: UUID
    var confidence: Double
    let firstLearnedAt: Date
    var lastUpdatedAt: Date
    var lastConfirmedAt: Date?

    var id: UUID {
        identifier
    }
}

nonisolated struct PartnerSessionSummary:
    Identifiable,
    Codable,
    Equatable,
    Sendable
{
    let identifier: UUID
    let sessionIdentifier: UUID
    let summary: String
    let createdAt: Date

    var id: UUID {
        identifier
    }
}

nonisolated struct PartnerProfile:
    Codable,
    Equatable,
    Sendable
{
    let schemaVersion: Int
    let profileIdentifier: UUID
    var userDisplayName: String
    var identityPreferences: PartnerIdentityPreferences
    var memoryRecords: [PartnerMemoryRecord]
    var goalRecords: [PartnerGoalRecord]
    var contradictions: [PartnerContradictionRecord]
    var agenda: [PartnerAgendaItem]
    var sessionSummaries: [PartnerSessionSummary]
    let createdAt: Date
    var updatedAt: Date

    static func empty(
        profileIdentifier: UUID,
        timestamp: Date = Date()
    ) -> PartnerProfile {
        PartnerProfile(
            schemaVersion: 1,
            profileIdentifier: profileIdentifier,
            userDisplayName: "",
            identityPreferences: .genericDefault,
            memoryRecords: [],
            goalRecords: [],
            contradictions: [],
            agenda: [],
            sessionSummaries: [],
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }
}

nonisolated struct PartnerMemoryReceipt: Equatable, Sendable {
    let identifier: UUID
    let visibleChanges: [String]
    let createdAt: Date
    let profileBeforeChanges: PartnerProfile?
}

nonisolated struct PartnerMemoryReduction: Equatable, Sendable {
    let profile: PartnerProfile
    let receipt: PartnerMemoryReceipt
}

nonisolated struct PartnerMemoryMutation:
    Codable,
    Equatable,
    Sendable
{
    enum Operation: String, Codable, Sendable {
        case upsert
        case correct
        case forget
        case contradict
    }

    let operation: Operation
    let domain: PartnerMemoryDomain
    let stableKey: String
    let normalizedContent: String
    let userVisibleWording: String
    let confidence: Double
    let confirmationState: PartnerMemoryConfirmationState
    let linkedRecordIdentifiers: [UUID]

    private enum CodingKeys: String, CodingKey {
        case operation
        case domain
        case stableKey = "stable_key"
        case normalizedContent = "normalized_content"
        case userVisibleWording = "user_visible_wording"
        case confidence
        case confirmationState = "confirmation_state"
        case linkedRecordIdentifiers =
            "linked_record_identifiers"
    }
}

/// Shared by the provider prompt and native structured-output backends.
/// Memory fields must be specified before asking a provider to author them.
nonisolated enum PartnerResponseSchema {
    static var jsonSchema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["kind", "spoken_response", "objective", "memory_mutations",
                     "screen_context_needed", "session_summary_delta"],
        "properties": [
            "kind": ["type": "string", "enum": ["reply", "clarify", "execute"]],
            "spoken_response": ["type": "string", "maxLength": 4_000],
            "objective": ["type": ["string", "null"], "maxLength": 1_200],
            "screen_context_needed": ["type": "boolean"],
            "session_summary_delta": ["type": "string", "maxLength": 1_200],
            "memory_mutations": [
                "type": "array", "maxItems": 12,
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["operation", "domain", "stable_key", "normalized_content",
                                 "user_visible_wording", "confidence", "confirmation_state",
                                 "linked_record_identifiers"],
                    "properties": [
                        "operation": ["type": "string", "enum": ["upsert", "correct", "forget", "contradict"]],
                        "domain": ["type": "string", "enum": PartnerMemoryDomain.allCases.map(\.rawValue)],
                        "stable_key": ["type": "string", "minLength": 1],
                        "normalized_content": ["type": "string", "minLength": 1],
                        "user_visible_wording": ["type": "string", "minLength": 1],
                        "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                        "confirmation_state": ["type": "string", "enum": ["confirmed", "inferred", "unconfirmed"]],
                        "linked_record_identifiers": ["type": "array", "items": ["type": "string", "format": "uuid"]],
                    ],
                ],
            ],
        ],
    ] }

    static var outputSchemaJSON: String {
        // This schema contains only app-owned JSON primitives.
        let data = try! JSONSerialization.data(withJSONObject: jsonSchema, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
