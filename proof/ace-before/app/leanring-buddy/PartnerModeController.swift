#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import Foundation
import CircuitPortKit

nonisolated enum PartnerPreparedTurnPublicationBoundary {
    /// Persistence runs before the injected Stealth admission and therefore
    /// never holds the event-tap latch. If X wins while persistence is blocked,
    /// publication is refused when the writer returns.
    static func persistThenPublish(
        persist: () throws -> Void,
        performUnlessRaised:
            (_ body: @escaping () -> Bool) -> Bool?,
        onPersistenceFailure: @escaping (Error) -> Void = { _ in },
        publish: @escaping () -> Bool
    ) -> Bool {
        do {
            try persist()
        } catch {
            _ = performUnlessRaised {
                onPersistenceFailure(error)
                return true
            }
            return false
        }
        return performUnlessRaised { publish() } ?? false
    }
}

nonisolated enum PartnerSessionEndReason:
    String,
    Sendable
{
    case userEnded
    case stop
    case stealth
    case permissionLost
    case uncertainRecovery
}

nonisolated enum PartnerModeControllerError:
    Error,
    Equatable
{
    case inactiveSession
    case noUndoableReceipt
}

/// A Partner answer whose encrypted profile effects are staged but whose
/// observable controller/UI state has not been published yet. CompanionManager
/// commits this only after the correlated Gold terminal is durable.
nonisolated struct PartnerPreparedTurnCompletion: Equatable, Sendable {
    let sessionIdentifier: UUID
    let profile: PartnerProfile
    let visibleMemoryReceipt: PartnerMemoryReceipt?
    let summaryDelta: String?
    let timestamp: Date
    let sourceTurnIdentifier: UUID
    let sourceSessionIdentifier: UUID?
    let sourceCorrelationIdentifier: UUID?
    let userTranscript: String?
    let assistantResponse: String?
}

@MainActor
final class PartnerModeController: ObservableObject {
    @Published private(set) var phase: PartnerSessionPhase =
        .inactive
    @Published private(set) var userActivatedSession = false
    @Published private(set) var isMicrophoneMuted = false
    @Published private(set) var profile: PartnerProfile
    @Published private(set) var visibleMemoryReceipt:
        PartnerMemoryReceipt?
    @Published private(set) var temporaryCaption = ""
    @Published var screenContextEnabledForSession = false
    @Published private(set) var lastErrorDescription: String?

    private let store: any PartnerProfileStoring
    private var activeSessionIdentifier: UUID?
    private var pendingSessionSummaryDeltas: [String] = []
    private var conversationHistory = PartnerConversationHistory()

    var activeSessionID: UUID? {
        activeSessionIdentifier
    }

    var conversationPromptTurns: [(
        userPlaceholder: String,
        assistantResponse: String
    )] {
        conversationHistory.promptTurns
    }

    init(
        profileIdentifier: UUID,
        store: any PartnerProfileStoring =
            PartnerSecureStore()
    ) throws {
        self.store = store
        try store.removeAbandonedTemporaryMaterial()
        profile = try store.loadProfile(
            profileIdentifier: profileIdentifier
        )
        // Saved preferences and agenda are data, never authority to listen.
        phase = .inactive
        userActivatedSession = false
    }

    func activate() throws {
        activeSessionIdentifier = UUID()
        pendingSessionSummaryDeltas.removeAll(
            keepingCapacity: false
        )
        conversationHistory.clearSession()
        temporaryCaption = ""
        visibleMemoryReceipt = nil
        screenContextEnabledForSession = false
        lastErrorDescription = nil
        userActivatedSession = true
        isMicrophoneMuted = false
        phase = .ready
    }

    func updateIdentityPreferences(
        _ identityPreferences: PartnerIdentityPreferences,
        timestamp: Date = Date()
    ) throws {
        var updatedProfile = profile
        updatedProfile.identityPreferences = identityPreferences
        updatedProfile.updatedAt = timestamp
        try store.saveProfile(updatedProfile)
        profile = updatedProfile
        lastErrorDescription = nil
    }

    @discardableResult
    func beginListeningIfAllowed(
        stealthBlocked: Bool,
        microphoneReady: Bool,
        speechRecognitionReady: Bool
    ) -> Bool {
        guard !isMicrophoneMuted,
              PartnerModePolicy.mayOpenMicrophone(
            phase: phase,
            userActivatedSession: userActivatedSession,
            stealthBlocked: stealthBlocked,
            microphoneReady: microphoneReady,
            speechRecognitionReady: speechRecognitionReady
        ) else {
            return false
        }
        phase = .listening
        temporaryCaption = ""
        return true
    }

    func updateTemporaryCaption(_ caption: String) {
        guard userActivatedSession,
              phase == .listening
                || phase == .processing else {
            return
        }
        temporaryCaption = String(caption.prefix(8_000))
    }

    func beginProcessing() {
        guard userActivatedSession else {
            return
        }
        phase = .processing
        lastErrorDescription = nil
    }

    func beginSpeaking() {
        guard userActivatedSession else {
            return
        }
        phase = .speaking
        lastErrorDescription = nil
    }

    func finishVerifiedSpeech() {
        guard userActivatedSession,
              phase == .speaking else {
            return
        }
        phase = isMicrophoneMuted ? .muted : .ready
    }

    func speechWasInterrupted() {
        guard userActivatedSession,
              phase == .speaking else {
            return
        }
        phase = isMicrophoneMuted ? .muted : .ready
    }

    func speechDidNotComplete() {
        guard userActivatedSession else {
            return
        }
        phase = .error
        lastErrorDescription =
            "Ace's response did not finish speaking."
    }

    func listeningDidNotStart(_ explanation: String) {
        guard userActivatedSession,
              phase == .listening
                || phase == .ready else {
            return
        }
        phase = .error
        lastErrorDescription = explanation
        temporaryCaption = ""
    }

    func turnDidFail(_ explanation: String) {
        guard userActivatedSession else { return }
        phase = .error
        lastErrorDescription = explanation
        temporaryCaption = ""
    }

    func finishSilentListeningWindow() {
        guard userActivatedSession,
              phase == .listening else {
            return
        }
        phase = isMicrophoneMuted ? .muted : .ready
        temporaryCaption = ""
    }

    func enterWaiting() {
        guard userActivatedSession else {
            return
        }
        phase = .waiting
        temporaryCaption = ""
    }

    func mute() {
        guard userActivatedSession else {
            return
        }
        isMicrophoneMuted = true
        phase = .muted
        temporaryCaption = ""
    }

    func resume() {
        guard userActivatedSession,
              isMicrophoneMuted
                || phase == .waiting
                || phase == .muted
                || phase == .error else {
            return
        }
        isMicrophoneMuted = false
        // Explicit resume may arrive while a muted typed turn is still active.
        // Its processing/speech phase must continue to own the microphone gate.
        if phase == .waiting || phase == .muted || phase == .error {
            phase = .ready
        }
        lastErrorDescription = nil
    }

    func resumeAfterMicrophoneHandoff() {
        guard userActivatedSession,
              phase == .waiting || phase == .error else { return }
        phase = isMicrophoneMuted ? .muted : .ready
        lastErrorDescription = nil
    }

    func finishTurn(
        response: PartnerTurnResponse,
        sourceTurnIdentifier: UUID,
        sourceSessionIdentifier: UUID? = nil,
        sourceCorrelationIdentifier: UUID? = nil,
        userTranscript: String? = nil,
        assistantResponse: String? = nil,
        timestamp: Date = Date()
    ) throws {
        do {
            let prepared = try prepareTurnCompletion(
                response: response,
                sourceTurnIdentifier: sourceTurnIdentifier,
                sourceSessionIdentifier: sourceSessionIdentifier,
                sourceCorrelationIdentifier:
                    sourceCorrelationIdentifier,
                userTranscript: userTranscript,
                assistantResponse: assistantResponse,
                timestamp: timestamp
            )
            try persistPreparedTurnCompletion(prepared)
            guard publishPreparedTurnCompletion(prepared) else {
                throw PartnerModeControllerError.inactiveSession
            }
        } catch {
            temporaryCaption = ""
            phase = .error
            lastErrorDescription =
                PartnerSecureStore.ownerFacingFailure(error)
            throw error
        }
    }

    /// Performs validation and any required encrypted profile write without
    /// exposing a receipt, conversation turn, or ready state.
    func prepareTurnCompletion(
        response: PartnerTurnResponse,
        sourceTurnIdentifier: UUID,
        sourceSessionIdentifier: UUID? = nil,
        sourceCorrelationIdentifier: UUID? = nil,
        userTranscript: String? = nil,
        assistantResponse: String? = nil,
        timestamp: Date = Date()
    ) throws -> PartnerPreparedTurnCompletion {
        guard userActivatedSession,
              let activeSessionIdentifier else {
            throw PartnerModeControllerError.inactiveSession
        }

        let reduction = try PartnerMemoryReducer.applying(
            response.memoryMutations,
            to: profile,
            sourceSessionIdentifier: activeSessionIdentifier,
            sourceTurnIdentifier: sourceTurnIdentifier,
            timestamp: timestamp
        )
        let visibleReceipt = reduction.receipt.visibleChanges.isEmpty
            ? nil : reduction.receipt
        let summary = response.sessionSummaryDelta
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PartnerPreparedTurnCompletion(
            sessionIdentifier: activeSessionIdentifier,
            profile: reduction.profile,
            visibleMemoryReceipt: visibleReceipt,
            summaryDelta: summary.isEmpty
                ? nil : String(summary.prefix(1_200)),
            timestamp: timestamp,
            sourceTurnIdentifier: sourceTurnIdentifier,
            sourceSessionIdentifier: sourceSessionIdentifier,
            sourceCorrelationIdentifier:
                sourceCorrelationIdentifier,
            userTranscript: userTranscript,
            assistantResponse: assistantResponse
        )
    }

    /// Potentially blocking encryption/Keychain/filesystem work. The caller must
    /// run this outside StealthEntryLatch; it publishes no controller state.
    func persistPreparedTurnCompletion(
        _ prepared: PartnerPreparedTurnCompletion
    ) throws {
        guard userActivatedSession,
              activeSessionIdentifier
                == prepared.sessionIdentifier else {
            throw PartnerModeControllerError.inactiveSession
        }
        if prepared.visibleMemoryReceipt != nil {
            try store.saveProfile(prepared.profile)
        }
    }

    /// Pure in-memory publication after both the Gold terminal and any profile
    /// mutation are durable. Safe inside the short Stealth publication latch.
    @discardableResult
    func publishPreparedTurnCompletion(
        _ prepared: PartnerPreparedTurnCompletion
    ) -> Bool {
        guard userActivatedSession,
              activeSessionIdentifier
                == prepared.sessionIdentifier else {
            return false
        }
        profile = prepared.profile
        visibleMemoryReceipt = prepared.visibleMemoryReceipt
        if let summaryDelta = prepared.summaryDelta {
            pendingSessionSummaryDeltas.append(summaryDelta)
        }
        if let userTranscript = prepared.userTranscript,
           let assistantResponse = prepared.assistantResponse {
            conversationHistory.append(
                userTranscript: userTranscript,
                assistantResponse: assistantResponse
            )
        }
        temporaryCaption = ""
        phase = isMicrophoneMuted ? .muted : .ready
        lastErrorDescription = nil
        return true
    }

    @discardableResult
    func recordNativeExchange(
        sessionIdentifier: UUID,
        userTranscript: String,
        assistantResponse: String
    ) -> Bool {
        guard userActivatedSession,
              activeSessionIdentifier == sessionIdentifier else { return false }
        conversationHistory.append(
            userTranscript: userTranscript,
            assistantResponse: assistantResponse
        )
        return true
    }

    @discardableResult
    func recordExecutionAssignment(
        userTranscript: String,
        objective: String,
        workerName: String,
        workCorrelationIdentifier: UUID
    ) -> Bool {
        guard userActivatedSession,
              activeSessionIdentifier != nil else { return false }
        conversationHistory.appendExecutionAssignment(
            userTranscript: userTranscript,
            objective: objective,
            workerName: workerName,
            workCorrelationIdentifier: workCorrelationIdentifier
        )
        return true
    }

    @discardableResult
    func recordExecutionTerminal(
        workerName: String,
        workCorrelationIdentifier: UUID,
        outcome: String,
        verification: String,
        exactResult: String
    ) -> Bool {
        guard userActivatedSession,
              activeSessionIdentifier != nil else { return false }
        return conversationHistory.appendExecutionTerminal(
            workerName: workerName,
            workCorrelationIdentifier: workCorrelationIdentifier,
            outcome: outcome,
            verification: verification,
            exactResult: exactResult
        )
    }

    func undoLastMemoryReceipt(
        timestamp: Date = Date()
    ) throws {
        guard let visibleMemoryReceipt,
              visibleMemoryReceipt.profileBeforeChanges != nil else {
            throw PartnerModeControllerError.noUndoableReceipt
        }
        let reduction = try PartnerMemoryReducer.undo(
            receipt: visibleMemoryReceipt,
            in: profile,
            timestamp: timestamp
        )
        try store.saveProfile(reduction.profile)
        profile = reduction.profile
        self.visibleMemoryReceipt = reduction.receipt
    }

    func clearVisibleMemoryReceipt() {
        visibleMemoryReceipt = nil
    }

    func resetProfile() throws {
        let resetProfile = try store.resetProfile(
            profileIdentifier: profile.profileIdentifier
        )
        closeEphemeralSessionState()
        profile = resetProfile
        lastErrorDescription = nil
    }

    func enableScreenContextForSession() {
        guard userActivatedSession else {
            return
        }
        screenContextEnabledForSession = true
    }

    func endSession(reason: PartnerSessionEndReason) {
        if reason == .userEnded,
           let activeSessionIdentifier,
           !pendingSessionSummaryDeltas.isEmpty {
            let summary = pendingSessionSummaryDeltas
                .joined(separator: " ")
            var profileWithSummary = profile
            profileWithSummary.sessionSummaries.append(
                PartnerSessionSummary(
                    identifier: UUID(),
                    sessionIdentifier:
                        activeSessionIdentifier,
                    summary: String(summary.prefix(4_000)),
                    createdAt: Date()
                )
            )
            profileWithSummary.updatedAt = Date()
            do {
                try store.saveProfile(profileWithSummary)
                profile = profileWithSummary
            } catch {
                lastErrorDescription =
                    PartnerSecureStore.ownerFacingFailure(error)
            }
        }
        closeEphemeralSessionState()
    }

    func suspendSynchronouslyForStealth() {
        closeEphemeralSessionState()
    }

    private func closeEphemeralSessionState() {
        phase = .inactive
        userActivatedSession = false
        isMicrophoneMuted = false
        activeSessionIdentifier = nil
        temporaryCaption = ""
        visibleMemoryReceipt = nil
        screenContextEnabledForSession = false
        pendingSessionSummaryDeltas.removeAll(
            keepingCapacity: false
        )
        conversationHistory.clearSession()
    }
}
