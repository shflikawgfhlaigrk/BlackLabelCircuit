//
//  SpeechRecognitionRecoveryPolicy.swift
//  Ace
//
//  Pure same-turn recovery and content-free waveform observability contracts.
//

import Foundation

@MainActor
enum SpeechProviderSwitchBoundary {
    static var handler: (() -> Void)?

    static func cancelActiveSpeechTurn() {
        handler?()
    }
}

nonisolated enum SpeechRecognitionProvider: Equatable, Sendable {
    case appleSpeech
    case other
}

nonisolated enum BuddyAudioReplayEligibility: Equatable, Sendable {
    case authorized
    case missing
    case cancelled
    case wrongTurn
    case expired
    case alreadyReplayed
    case incomplete
}

nonisolated enum SpeechRecognitionRecoveryAction: Equatable, Sendable {
    case replayOnce
    case submitRetainedText(String)
    case failVisible(String)
}

nonisolated struct SpeechRecognitionRecoveryRequest: Equatable, Sendable {
    var provider: SpeechRecognitionProvider
    var errorDomain: String
    var errorCode: Int
    var isFinalizing: Bool
    var retainedText: String
    var replayAttemptCount: Int
    var audioEligibility: BuddyAudioReplayEligibility
}

/// Apple Speech may terminate an on-device request with error 1110 after
/// `endAudio()` even though the captured PCM remains valid. Only that exact,
/// content-free failure shape can consume the turn's one in-memory replay.
nonisolated enum SpeechRecognitionRecoveryPolicy {
    static let appleNoTextErrorDomain = "kAFAssistantErrorDomain"
    static let appleNoTextErrorCode = 1110
    static let noSpeechMessage =
        "No speech was recognized. Hold Command and Shift while speaking, "
        + "then release. You can also type your request."
    static let releasedBeforeReadyMessage =
        "The shortcut was released before the microphone was ready. "
        + "Hold Command and Shift, wait for the listening waveform, "
        + "then speak and release. You can also type your request."

    static func action(
        for request: SpeechRecognitionRecoveryRequest
    ) -> SpeechRecognitionRecoveryAction {
        let retainedText = request.retainedText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let audioWasInvalidated = [
            BuddyAudioReplayEligibility.cancelled,
            .wrongTurn,
            .expired,
        ].contains(request.audioEligibility)
        if request.isFinalizing,
           !audioWasInvalidated,
           !retainedText.isEmpty {
            return .submitRetainedText(retainedText)
        }

        guard request.provider == .appleSpeech,
              request.errorDomain == appleNoTextErrorDomain,
              request.errorCode == appleNoTextErrorCode,
              request.isFinalizing,
              request.replayAttemptCount == 0,
              request.audioEligibility == .authorized else {
            return .failVisible(noSpeechMessage)
        }
        return .replayOnce
    }
}

// MARK: - Typed contextual vocabulary

nonisolated enum SpeechContextualTermSource: Equatable, Sendable {
    case ownerApprovedName
    case productTerm
    case selectedProvider
    case selectedModel
    case visibleApplication
    case typedClientScope
    case pendingLocalSlot

    case goldMemory
    case screenContent
    case mailBody
    case messagesBody
    case messagesRecipient
    case secret
    case durableTranscript

    var isAllowedAtCaptureStart: Bool {
        switch self {
        case .ownerApprovedName, .productTerm, .selectedProvider,
             .selectedModel, .visibleApplication, .typedClientScope,
             .pendingLocalSlot:
            return true
        case .goldMemory, .screenContent, .mailBody, .messagesBody,
             .messagesRecipient, .secret, .durableTranscript:
            return false
        }
    }
}

nonisolated struct SpeechContextualTerm: Equatable, Sendable {
    let value: String
    let source: SpeechContextualTermSource
}

nonisolated enum SpeechContextualBackendSelection: Equatable, Sendable {
    case codex(resolvedModelLabel: String?)
    case claude(currentModelLabel: String)
    case qwen(modelLabel: String)

    fileprivate var typedTerms: [SpeechContextualTerm] {
        switch self {
        case .codex(let resolvedModelLabel):
            var terms = [
                SpeechContextualTerm(
                    value: "Codex CLI",
                    source: .selectedProvider
                ),
            ]
            if let resolvedModelLabel {
                terms.append(
                    SpeechContextualTerm(
                        value: resolvedModelLabel,
                        source: .selectedModel
                    )
                )
            }
            return terms
        case .claude(let currentModelLabel):
            return [
                SpeechContextualTerm(
                    value: "Claude Code",
                    source: .selectedProvider
                ),
                SpeechContextualTerm(
                    value: currentModelLabel,
                    source: .selectedModel
                ),
            ]
        case .qwen(let modelLabel):
            return [
                SpeechContextualTerm(
                    value: "Qwen3 Abliterated",
                    source: .selectedProvider
                ),
                SpeechContextualTerm(
                    value: modelLabel,
                    source: .selectedModel
                ),
            ]
        }
    }
}

nonisolated enum SpeechContextualCaptureScope: Equatable, Sendable {
    case owner
    case explicitClient(String)

    fileprivate var typedTerm: SpeechContextualTerm? {
        guard case .explicitClient(let identifier) = self else { return nil }
        return SpeechContextualTerm(
            value: identifier,
            source: .typedClientScope
        )
    }
}

nonisolated enum SpeechContextualPendingLocalSlot:
    String,
    Equatable,
    Sendable
{
    case locality = "Locality"
    case mailSender = "Mail sender"
    case messageRecipient = "Message recipient"
    case actionTarget = "Action target"

    fileprivate var typedTerm: SpeechContextualTerm {
        SpeechContextualTerm(value: rawValue, source: .pendingLocalSlot)
    }
}

/// The only input accepted by the live vocabulary producer. It is created at
/// microphone admission and then consumed by that exact capture; it cannot
/// consult a previous lifecycle binding after capture has begun.
nonisolated struct SpeechContextualCaptureContext: Equatable, Sendable {
    let ownerApprovedName: String?
    let backend: SpeechContextualBackendSelection
    let scope: SpeechContextualCaptureScope
    let pendingLocalSlot: SpeechContextualPendingLocalSlot?
    let visibleApplications: [String]

    init(
        ownerApprovedName: String? = nil,
        backend: SpeechContextualBackendSelection,
        scope: SpeechContextualCaptureScope = .owner,
        pendingLocalSlot: SpeechContextualPendingLocalSlot? = nil,
        visibleApplications: [String] = []
    ) {
        self.ownerApprovedName = ownerApprovedName
        self.backend = backend
        self.scope = scope
        self.pendingLocalSlot = pendingLocalSlot
        self.visibleApplications = visibleApplications
    }
}

/// Builds recognition bias only from explicitly typed, bounded sources. It is
/// intentionally incapable of accepting a Gold bundle, screen capture, draft,
/// recipient, secret store, or durable transcript as an unlabelled `[String]`.
nonisolated struct SpeechContextualVocabulary:
    Equatable,
    RandomAccessCollection,
    Sendable
{
    typealias Index = Int
    typealias Element = String

    static let maximumTermCount = 64
    static let maximumTermLength = 80

    private let storage: [String]

    var startIndex: Int { storage.startIndex }
    var endIndex: Int { storage.endIndex }
    subscript(position: Int) -> String { storage[position] }

    /// The Apple bridge can read the already validated result but has no API
    /// that accepts an arbitrary untyped string array.
    var requestStrings: [String] { storage }

    private static let fixedProductTerms = [
        "Ace",
        "Black Label",
        "Black Label Assistant",
        "Black Label Tech",
        "Black Label Bots",
        "blacklabeltec.com",
        "blacklabelbots.com",
        "gem motion",
        "gem animation",
        "Living Ink",
        "LG monitor",
        "Command Shift",
        "go stealth",
        "wake up",
        "exit stealth",
        "trading",
        "trading mode",
        "activate trading mode",
        "take notes",
        "stop taking notes",
        "agent",
        "Mail",
        "Apple Mail",
        "email",
        "Gmail",
        "send email",
        "draft email",
        "Messages",
        "Stealth",
        "Partner Mode",
        "be my partner",
        "red agent",
        "assign red agent",
        "background agent",
        "Replay Tour",
        "Safari",
        "Stop Work",
    ]

    static func validated(
        capture: SpeechContextualCaptureContext,
        additionalTypedTerms: [SpeechContextualTerm] = []
    ) -> SpeechContextualVocabulary {
        var captureTerms: [SpeechContextualTerm] = []
        if let ownerApprovedName = capture.ownerApprovedName {
            captureTerms.append(
                SpeechContextualTerm(
                    value: ownerApprovedName,
                    source: .ownerApprovedName
                )
            )
        }
        captureTerms.append(contentsOf: capture.backend.typedTerms)
        if let scopeTerm = capture.scope.typedTerm {
            captureTerms.append(scopeTerm)
        }
        if let pendingLocalSlot = capture.pendingLocalSlot {
            captureTerms.append(pendingLocalSlot.typedTerm)
        }
        captureTerms.append(
            contentsOf: capture.visibleApplications.map {
                SpeechContextualTerm(
                    value: $0,
                    source: .visibleApplication
                )
            }
        )
        return validated(from: captureTerms + additionalTypedTerms)
    }

    static func validated(
        from contextualTerms: [SpeechContextualTerm]
    ) -> SpeechContextualVocabulary {
        let fixed = fixedProductTerms.map {
            SpeechContextualTerm(value: $0, source: .productTerm)
        }
        var seen: Set<String> = []
        var result: [String] = []

        for term in fixed + contextualTerms {
            guard term.source.isAllowedAtCaptureStart else { continue }
            let trimmed = term.value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty,
                  trimmed.count <= maximumTermLength else { continue }
            let normalized = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(normalized).inserted else { continue }
            result.append(trimmed)
            if result.count == maximumTermCount { break }
        }
        return SpeechContextualVocabulary(storage: result)
    }
}

// MARK: - Content-free waveform receipt contract

nonisolated enum WaveformShortcutState: String, Equatable, Sendable {
    case inactive
    case pressed
    case released
}

nonisolated enum WaveformRecordingState: String, Equatable, Sendable {
    case idle
    case preparing
    case recording
    case finalizing
}

nonisolated enum WaveformVoicePhase: String, Equatable, Hashable, Sendable {
    case idle
    case listening
    case processing
    case responding
}

nonisolated enum WaveformObservationSource: String, Equatable, Sendable {
    case commandShift = "command-shift"
    case partner
    case replayTour = "replay-tour"
}

nonisolated enum WaveformPresentation: Equatable, Sendable {
    case hidden
    case gem
    case waveform
    case spinner
}

nonisolated enum WaveformTerminalReason: String, Equatable, Sendable {
    case completed
    case cancelled
    case failed
    case stop
    case providerSwitch = "provider-switch"
    case privateMode = "private-mode"
    case timeout
    case turnReplacement = "turn-replacement"
}

nonisolated struct WaveformDisplayDescriptor: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let scale: Double
}

nonisolated enum WaveformDisplayFingerprint {
    static func make(
        from displays: [WaveformDisplayDescriptor]
    ) -> String {
        let canonical = displays.sorted {
            if $0.x != $1.x { return $0.x < $1.x }
            if $0.y != $1.y { return $0.y < $1.y }
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.height != $1.height { return $0.height < $1.height }
            return $0.scale < $1.scale
        }.map {
            [
                $0.x, $0.y, $0.width, $0.height, $0.scale,
            ].map { String(format: "%.3f", $0) }.joined(separator: ",")
        }.joined(separator: ";")

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

nonisolated struct WaveformStateObservation: Equatable, Sendable {
    var source: WaveformObservationSource
    var shortcutState: WaveformShortcutState
    var recordingState: WaveformRecordingState
    var voicePhase: WaveformVoicePhase
    var overlayVisibility: WaveformOverlayVisibility
    var displayHash: String
    var partnerMode: Bool
    var privateMode: Bool
    var reducedMotion: Bool
    var nonzeroWaveformSampleCount: Int
}

nonisolated struct WaveformOverlayVisibility: Equatable, Sendable {
    let trackedScreenCount: Int
    let visibleScreenCount: Int
    let nonzeroOpacityScreenCount: Int

    var isLiveVisible: Bool {
        trackedScreenCount > 0
            && visibleScreenCount > 0
            && nonzeroOpacityScreenCount > 0
    }
}

/// Mirrors the current OverlayWindow presentation predicates without changing
/// the window, drawing, or ordering implementation. Task 11 compares this
/// content-free contract with the installed pixels on the exact candidate.
nonisolated enum WaveformStatePolicy {
    static func presentation(
        for observation: WaveformStateObservation
    ) -> WaveformPresentation {
        guard observation.overlayVisibility.isLiveVisible,
              !observation.privateMode else { return .hidden }
        if observation.partnerMode { return .gem }
        switch observation.voicePhase {
        case .idle, .responding:
            return .gem
        case .listening:
            return .waveform
        case .processing:
            return .spinner
        }
    }
}

nonisolated struct WaveformTurnStateTracker: Sendable {
    let turnID: UUID

    private var latestObservation: WaveformStateObservation?
    private var observedPhases: [WaveformVoicePhase] = []
    private var maximumNonzeroWaveformSampleCount = 0
    private var didFinish = false

    init(turnID: UUID) {
        self.turnID = turnID
    }

    mutating func observe(_ observation: WaveformStateObservation) {
        guard !didFinish else { return }
        latestObservation = observation
        maximumNonzeroWaveformSampleCount = max(
            maximumNonzeroWaveformSampleCount,
            max(observation.nonzeroWaveformSampleCount, 0)
        )
        if observation.voicePhase != .idle,
           !observedPhases.contains(observation.voicePhase) {
            observedPhases.append(observation.voicePhase)
        }
    }

    mutating func finish(
        reason: WaveformTerminalReason
    ) -> String? {
        guard !didFinish, let latestObservation else { return nil }
        didFinish = true
        let phases = observedPhases.map(\.rawValue).joined(separator: ",")
        return [
            "WAVEFORM",
            "turn=\(turnID.uuidString.lowercased())",
            "source=\(latestObservation.source.rawValue)",
            "shortcut=\(latestObservation.shortcutState.rawValue)",
            "recording=\(latestObservation.recordingState.rawValue)",
            "voice=\(latestObservation.voicePhase.rawValue)",
            "overlay=\(latestObservation.overlayVisibility.isLiveVisible ? "visible" : "hidden")",
            "screens=\(max(latestObservation.overlayVisibility.trackedScreenCount, 0))",
            "visibleScreens=\(max(latestObservation.overlayVisibility.visibleScreenCount, 0))",
            "opaqueScreens=\(max(latestObservation.overlayVisibility.nonzeroOpacityScreenCount, 0))",
            "display=\(latestObservation.displayHash)",
            "partner=\(latestObservation.partnerMode)",
            "private=\(latestObservation.privateMode)",
            "reducedMotion=\(latestObservation.reducedMotion)",
            "samples=\(maximumNonzeroWaveformSampleCount)",
            "phases=\(phases.isEmpty ? "none" : phases)",
            "terminal=\(reason.rawValue)",
        ].joined(separator: " ")
    }
}

/// The state publisher used by CompanionManager. Tests inject the receipt sink
/// and exercise the same producer/observer boundary as the app; stale turn
/// observations and duplicate terminal calls are rejected here.
@MainActor
final class CompanionWaveformLifecyclePublisher {
    private let receiptSink: (String) -> Void
    private var tracker: WaveformTurnStateTracker?

    init(receiptSink: @escaping (String) -> Void) {
        self.receiptSink = receiptSink
    }

    var activeTurnID: UUID? { tracker?.turnID }

    func begin(
        turnID: UUID,
        source: WaveformObservationSource,
        initialObservation: WaveformStateObservation
    ) {
        if let previousTurnID = tracker?.turnID {
            finish(turnID: previousTurnID, reason: .turnReplacement)
        }
        var sourceBoundObservation = initialObservation
        sourceBoundObservation.source = source
        var next = WaveformTurnStateTracker(turnID: turnID)
        next.observe(sourceBoundObservation)
        tracker = next
    }

    func observe(
        turnID: UUID,
        observation: WaveformStateObservation
    ) {
        guard var tracker, tracker.turnID == turnID else { return }
        tracker.observe(observation)
        self.tracker = tracker
    }

    func finish(turnID: UUID, reason: WaveformTerminalReason) {
        guard var tracker, tracker.turnID == turnID else { return }
        if let receipt = tracker.finish(reason: reason) {
            receiptSink(receipt)
        }
        self.tracker = nil
    }
}
