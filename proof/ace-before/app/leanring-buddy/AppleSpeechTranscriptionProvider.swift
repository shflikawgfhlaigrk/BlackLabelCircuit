//
//  AppleSpeechTranscriptionProvider.swift
//  leanring-buddy
//
//  Local fallback transcription provider backed by Apple's Speech framework.
//

#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
import Foundation
#if canImport(Speech) && !CIRCUIT_WINDOWS_SIM
@preconcurrency import Speech
#endif

/// The complete local-dictation verdict used by both setup and the live
/// transcription path. `SFSpeechRecognizer.isAvailable` alone is not enough:
/// it can be true before the owner has granted Speech Recognition access, and
/// it says nothing about whether the on-device recognizer Ace requires exists.
enum AppleSpeechRecognitionReadiness: Equatable {
    case ready(localeIdentifier: String)
    case authorizationNotDetermined
    case authorizationDenied
    case authorizationRestricted
    case authorizationUnavailable
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var hasSpeechRecognitionAuthorization: Bool {
        switch self {
        case .ready, .recognizerUnavailable, .onDeviceRecognitionUnavailable:
            return true
        case .authorizationNotDetermined, .authorizationDenied,
             .authorizationRestricted, .authorizationUnavailable:
            return false
        }
    }

    var unavailableExplanation: String? {
        switch self {
        case .ready:
            return nil
        case .authorizationNotDetermined:
            return "speech recognition permission hasn't been granted yet."
        case .authorizationDenied:
            return "speech recognition permission is turned off for Ace."
        case .authorizationRestricted:
            return "speech recognition is restricted on this Mac."
        case .authorizationUnavailable:
            return "speech recognition authorization isn't available on this Mac."
        case .recognizerUnavailable:
            return "dictation isn't available on this Mac yet."
        case .onDeviceRecognitionUnavailable:
            return "on-device dictation isn't available on this Mac yet."
        }
    }
}

/// A value-only capability snapshot keeps the readiness policy deterministic
/// and testable without starting a recognition task or prompting for consent.
struct AppleSpeechRecognizerCapabilities: Equatable {
    let localeIdentifier: String
    let isAvailable: Bool
    let supportsOnDeviceRecognition: Bool
}

struct AppleSpeechTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
final class AppleSpeechTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Apple Speech"
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true
    let recoveryProvider = SpeechRecognitionProvider.appleSpeech
    var unavailableExplanation: String? {
        Self.currentReadiness.unavailableExplanation
    }

    /// The exact same predicate enforced immediately before a live recognition
    /// task starts. Setup must read this instead of treating `isAvailable` as a
    /// complete readiness signal.
    static var currentReadiness: AppleSpeechRecognitionReadiness {
        makeReadinessAssessment().readiness
    }

    /// Apple Speech uses these as recognition bias, not replacements. Preserve
    /// Ace's command vocabulary and include the caller's product, app, and
    /// identity terms instead of silently discarding them.
    static func contextualStrings(
        vocabulary: SpeechContextualVocabulary
    ) -> [String] {
        vocabulary.requestStrings
    }

    /// Requests Speech Recognition consent only when macOS has not asked yet,
    /// then returns the full local-dictation verdict. The on-device model may
    /// still be downloading after authorization, so `.authorized` is not
    /// converted into `.ready` without re-running the capability gates.
    static func requestAuthorizationIfNeeded() async -> AppleSpeechRecognitionReadiness {
        let currentAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
        guard currentAuthorizationStatus == .notDetermined else {
            return makeReadinessAssessment(
                authorizationStatus: currentAuthorizationStatus
            ).readiness
        }

        let resolvedAuthorizationStatus = await withCheckedContinuation {
            (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                continuation.resume(returning: authorizationStatus)
            }
        }
        return makeReadinessAssessment(
            authorizationStatus: resolvedAuthorizationStatus
        ).readiness
    }

    func startStreamingSession(
        vocabulary: SpeechContextualVocabulary,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let readinessAssessment = Self.makeReadinessAssessment()
        guard readinessAssessment.readiness.isReady,
              let speechRecognizer = readinessAssessment.speechRecognizer else {
            throw AppleSpeechTranscriptionProviderError(
                message: readinessAssessment.readiness.unavailableExplanation
                    ?? "dictation isn't available on this Mac."
            )
        }

        return try AppleSpeechTranscriptionSession(
            speechRecognizer: speechRecognizer,
            vocabulary: vocabulary,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    /// Pure policy used by focused tests and by the live recognizer assessment.
    /// A fallback locale that is fully local wins over a preferred locale that
    /// exists but would require server recognition.
    static func evaluateReadiness(
        authorizationStatus: SFSpeechRecognizerAuthorizationStatus,
        recognizerCapabilities: [AppleSpeechRecognizerCapabilities]
    ) -> AppleSpeechRecognitionReadiness {
        switch authorizationStatus {
        case .notDetermined:
            return .authorizationNotDetermined
        case .denied:
            return .authorizationDenied
        case .restricted:
            return .authorizationRestricted
        case .authorized:
            break
        @unknown default:
            return .authorizationUnavailable
        }

        if let readyRecognizer = recognizerCapabilities.first(where: {
            $0.isAvailable && $0.supportsOnDeviceRecognition
        }) {
            return .ready(localeIdentifier: readyRecognizer.localeIdentifier)
        }

        guard recognizerCapabilities.contains(where: \.isAvailable) else {
            return .recognizerUnavailable
        }

        // At least one recognizer could accept work, but none can honor the
        // hard local-only contract. Never allow Speech to fall back to servers.
        return .onDeviceRecognitionUnavailable
    }

    private struct SpeechRecognizerCandidate {
        let speechRecognizer: SFSpeechRecognizer
        let capabilities: AppleSpeechRecognizerCapabilities
    }

    private struct ReadinessAssessment {
        let readiness: AppleSpeechRecognitionReadiness
        let speechRecognizer: SFSpeechRecognizer?
    }

    private static func makeReadinessAssessment(
        authorizationStatus: SFSpeechRecognizerAuthorizationStatus =
            SFSpeechRecognizer.authorizationStatus()
    ) -> ReadinessAssessment {
        guard authorizationStatus == .authorized else {
            return ReadinessAssessment(
                readiness: evaluateReadiness(
                    authorizationStatus: authorizationStatus,
                    recognizerCapabilities: []
                ),
                speechRecognizer: nil
            )
        }

        let recognizerCandidates = makeSpeechRecognizerCandidates()
        let readiness = evaluateReadiness(
            authorizationStatus: authorizationStatus,
            recognizerCapabilities: recognizerCandidates.map(\.capabilities)
        )

        guard case .ready(let localeIdentifier) = readiness else {
            return ReadinessAssessment(readiness: readiness, speechRecognizer: nil)
        }

        let readySpeechRecognizer = recognizerCandidates.first {
            $0.capabilities.localeIdentifier == localeIdentifier
                && $0.capabilities.isAvailable
                && $0.capabilities.supportsOnDeviceRecognition
        }?.speechRecognizer
        return ReadinessAssessment(
            readiness: readiness,
            speechRecognizer: readySpeechRecognizer
        )
    }

    static func makeSelectedOnDeviceRecognizer() -> SFSpeechRecognizer? {
        makeReadinessAssessment().speechRecognizer
    }

    private static func makeSpeechRecognizerCandidates() -> [SpeechRecognizerCandidate] {
        let preferredLocales = [Locale(identifier: AceLanguage.current.localeIdentifier)]
        var seenLocaleIdentifiers: Set<String> = []
        var recognizerCandidates: [SpeechRecognizerCandidate] = []

        for preferredLocale in preferredLocales {
            if let speechRecognizer = SFSpeechRecognizer(locale: preferredLocale) {
                appendRecognizerCandidate(
                    speechRecognizer,
                    seenLocaleIdentifiers: &seenLocaleIdentifiers,
                    recognizerCandidates: &recognizerCandidates
                )
            }
        }

        return recognizerCandidates
    }

    private static func appendRecognizerCandidate(
        _ speechRecognizer: SFSpeechRecognizer,
        seenLocaleIdentifiers: inout Set<String>,
        recognizerCandidates: inout [SpeechRecognizerCandidate]
    ) {
        let localeIdentifier = speechRecognizer.locale.identifier
        guard seenLocaleIdentifiers.insert(localeIdentifier).inserted else { return }
        recognizerCandidates.append(
            SpeechRecognizerCandidate(
                speechRecognizer: speechRecognizer,
                capabilities: AppleSpeechRecognizerCapabilities(
                    localeIdentifier: localeIdentifier,
                    isAvailable: speechRecognizer.isAvailable,
                    supportsOnDeviceRecognition: speechRecognizer.supportsOnDeviceRecognition
                )
            )
        )
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
private final class AppleSpeechTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    let finalTranscriptInactivityDelaySeconds: TimeInterval = 2.4
    let finalTranscriptHardMaximumDelaySeconds: TimeInterval = 8

    private let recognitionRequest: SFSpeechAudioBufferRecognitionRequest
    private let audioNormalizer = BuddySpeechAudioNormalizer()
    private let transcriptionInputBoundary =
        BuddySerializedTranscriptionInputBoundary(
            label: "com.blacklabel.ace.apple-speech-input"
        )
    private let recognitionStateLock = NSLock()
    private var recognitionTask: SFSpeechRecognitionTask?
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private var latestRecognizedText = ""
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var recognitionSequence: UInt64 = 0
    private var recognitionReducer = BuddySequencedRecognitionReducer()

    init(
        speechRecognizer: SFSpeechRecognizer,
        vocabulary: SpeechContextualVocabulary,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        super.init()

        // Recheck at the task boundary. The shared assessment selected this
        // recognizer moments ago, but availability is live state and the
        // request flag is only honored while on-device support remains true.
        guard speechRecognizer.isAvailable else {
            throw AppleSpeechTranscriptionProviderError(
                message: AppleSpeechRecognitionReadiness.recognizerUnavailable
                    .unavailableExplanation ?? "dictation isn't available on this Mac."
            )
        }
        guard speechRecognizer.supportsOnDeviceRecognition else {
            throw AppleSpeechTranscriptionProviderError(
                message: AppleSpeechRecognitionReadiness.onDeviceRecognitionUnavailable
                    .unavailableExplanation ?? "on-device dictation isn't available on this Mac."
            )
        }

        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true
        recognitionRequest.contextualStrings =
            AppleSpeechTranscriptionProvider.contextualStrings(
                vocabulary: vocabulary
            )

        // The provider's shared readiness assessment proved this capability.
        // Keep the request itself fail-closed too, so Speech can never silently
        // route a later task to Apple's servers if availability changes.
        recognitionRequest.requiresOnDeviceRecognition = true

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            self?.handleRecognitionEvent(result: result, error: error)
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        transcriptionInputBoundary.append {
            if let normalized = audioNormalizer.normalize(audioBuffer) {
                recognitionRequest.append(normalized)
            }
        }
    }

    func requestFinalTranscript() {
        transcriptionInputBoundary.endAudio { [self] in
            self.recognitionStateLock.withLock {
                self.hasRequestedFinalTranscript = true
            }
            self.recognitionRequest.endAudio()
        }
    }

    func cancel() {
        transcriptionInputBoundary.cancel()
        let taskToCancel = recognitionStateLock.withLock {
            let taskToCancel = recognitionTask
            recognitionTask = nil
            return taskToCancel
        }
        taskToCancel?.cancel()
    }

    private func handleRecognitionEvent(
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        if let result {
            // Alternatives are hypotheses, not additional owner commands.
            // Promoting a lower-ranked "stop"/"go stealth" hypothesis here
            // overwrote unrelated best transcriptions before routing.
            let formattedString = result.bestTranscription.formattedString
            var transcriptUpdate: String?
            var finalTranscript: String?
            recognitionStateLock.withLock {
                recognitionSequence &+= 1
                switch recognitionReducer.observe(
                    sequence: recognitionSequence,
                    transcript: formattedString,
                    isFinal: result.isFinal
                ) {
                case .progress(let transcript):
                    latestRecognizedText = transcript
                    transcriptUpdate = transcript
                case .final(let transcript):
                    hasDeliveredFinalTranscript = true
                    latestRecognizedText = transcript
                    finalTranscript = transcript
                case .ignored:
                    break
                }
            }
            if let transcriptUpdate {
                onTranscriptUpdate(transcriptUpdate)
            }

            if let finalTranscript {
                onFinalTranscriptReady(finalTranscript)
                return
            }
        }

        guard let error else { return }

        let errorDelivery = recognitionStateLock.withLock { () -> (transcript: String?, error: Bool) in
            guard !hasDeliveredFinalTranscript else { return (nil, false) }
            guard hasRequestedFinalTranscript,
                  !latestRecognizedText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty else {
                return (nil, true)
            }
            hasDeliveredFinalTranscript = true
            return (latestRecognizedText, false)
        }
        if let retainedFinalTranscript = errorDelivery.transcript {
            onFinalTranscriptReady(retainedFinalTranscript)
        } else if errorDelivery.error {
            onError(error)
        }
    }

    deinit {
        cancel()
    }
}
#endif // circuit-convert
