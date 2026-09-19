//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
import Foundation

nonisolated enum BuddyTranscriptRevisionPolicy {
    static func shouldReplace(_ retained: String, with candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        guard !retained.isEmpty else { return true }
        func words(_ text: String) -> [String] {
            text.split(whereSeparator: \Character.isWhitespace).map {
                $0.trimmingCharacters(in: .punctuationCharacters).lowercased()
            }.filter { !$0.isEmpty }
        }
        let candidateWords = words(candidate)
        let retainedWords = words(retained)
        guard !candidateWords.isEmpty else { return false }
        // Apple can compact a longer provisional phrase into "7+5" or "5:30".
        // Length does not measure completeness. Preserve an observed suffix
        // only when the new result is the same words cut off at a boundary.
        let isTruncatedPrefix = candidateWords.count < retainedWords.count
            && retainedWords.starts(with: candidateWords)
        let isTruncatedSuffix = candidateWords.count < retainedWords.count
            && Array(retainedWords.suffix(candidateWords.count)) == candidateWords
        return !isTruncatedPrefix && !isTruncatedSuffix
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptInactivityDelaySeconds: TimeInterval { get }
    var finalTranscriptHardMaximumDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}
#endif // circuit-convert

nonisolated enum BuddyTranscriptionStartupError: LocalizedError {
    case bufferUnavailable
    var errorDescription: String? {
        "Speech recognition took too long to start. No partial command was sent. Try again."
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Holds only the beginning of an explicitly requested capture while the
/// recognizer starts. Release is retained, so a short command may finish before
/// Speech is ready without losing its audio or its finalization request.
nonisolated final class BuddyStartupTranscriptionSession:
    BuddyStreamingTranscriptionSession, @unchecked Sendable
{
    private let lock = NSRecursiveLock()
    private var destination: (any BuddyStreamingTranscriptionSession)?
    private var buffers: [AVAudioPCMBuffer] = []
    private var bufferedBytes = 0
    private var bufferedSeconds: TimeInterval = 0
    private var ended = false
    private var cancelled = false

    var finalTranscriptInactivityDelaySeconds: TimeInterval {
        lock.withLock { destination?.finalTranscriptInactivityDelaySeconds ?? 2.4 }
    }
    var finalTranscriptHardMaximumDelaySeconds: TimeInterval {
        lock.withLock { destination?.finalTranscriptHardMaximumDelaySeconds ?? 8 }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !cancelled, !ended else { return }
            if let destination { destination.appendAudioBuffer(buffer); return }
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let bytes = source.reduce(0) { $0 + Int($1.mDataByteSize) }
            let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
            guard seconds.isFinite, seconds >= 0,
                  bufferedSeconds + seconds <= 8,
                  bufferedBytes + bytes <= 4 * 1024 * 1024,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                             frameCapacity: buffer.frameLength) else {
                cancel()
                return
            }
            copy.frameLength = buffer.frameLength
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            guard source.count == target.count else { cancel(); return }
            for index in source.indices {
                guard let input = source[index].mData, let output = target[index].mData,
                      target[index].mDataByteSize >= source[index].mDataByteSize else {
                    cancel()
                    return
                }
                memcpy(output, input, Int(source[index].mDataByteSize))
            }
            buffers.append(copy)
            bufferedBytes += bytes
            bufferedSeconds += seconds
        }
    }

    @discardableResult
    func connect(_ session: any BuddyStreamingTranscriptionSession) -> Bool {
        lock.withLock {
            guard !cancelled, destination == nil else { session.cancel(); return false }
            destination = session
            for buffer in buffers {
                guard !cancelled else { break }
                session.appendAudioBuffer(buffer)
            }
            clearBuffers()
            guard !cancelled else { return false }
            if ended { session.requestFinalTranscript() }
            return true
        }
    }

    func requestFinalTranscript() {
        lock.withLock {
            guard !cancelled, !ended else { return }
            ended = true
            destination?.requestFinalTranscript()
        }
    }

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            destination?.cancel()
            destination = nil
            clearBuffers()
        }
    }

    private func clearBuffers() {
        for buffer in buffers {
            for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
            }
        }
        buffers.removeAll()
        bufferedBytes = 0
        bufferedSeconds = 0
    }

    deinit { cancel() }
}
#endif // circuit-convert

nonisolated struct BuddyDictationFinalizationCoordinator {
    enum Completion: Equatable {
        case submit(String)
        case finishWithoutTranscript
        case cancelledForRestart
    }

    enum DeadlineReason: Equatable {
        case appleFinal
        case inactivity
        case hardMaximum
    }

    enum DeadlineDecision: Equatable {
        case notReleased
        case wait(until: TimeInterval)
        case complete(Completion, reason: DeadlineReason)
        case finished
    }

    let sessionIdentifier: UUID

    private let startedAt: TimeInterval
    private var inactivityDelaySeconds: TimeInterval
    private var hardMaximumDelaySeconds: TimeInterval
    private var releasedAt: TimeInterval?
    private var lastProgressAt: TimeInterval?
    private var hardMaximumAt: TimeInterval?
    private var retainedTranscript = ""
    private var receivedFinal = false
    private var completion: Completion?
    private var recognitionStartupIsPending = false

    init(
        sessionIdentifier: UUID,
        startedAt: TimeInterval,
        inactivityDelaySeconds: TimeInterval = 2.4,
        hardMaximumDelaySeconds: TimeInterval = 8
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.startedAt = startedAt
        self.inactivityDelaySeconds = max(inactivityDelaySeconds, 0)
        self.hardMaximumDelaySeconds = max(hardMaximumDelaySeconds, 0)
    }

    var latestCoherentTranscript: String {
        retainedTranscript
    }

    var hasReceivedFinalTranscript: Bool { receivedFinal }

    @discardableResult
    mutating func configureFinalizationTiming(
        inactivityDelaySeconds: TimeInterval,
        hardMaximumDelaySeconds: TimeInterval
    ) -> Bool {
        guard releasedAt == nil, completion == nil else { return false }
        self.inactivityDelaySeconds = max(inactivityDelaySeconds, 0)
        self.hardMaximumDelaySeconds = max(
            hardMaximumDelaySeconds,
            0
        )
        return true
    }

    @discardableResult
    mutating func recordPartial(
        _ transcript: String,
        at now: TimeInterval
    ) -> Bool {
        guard completion == nil, !receivedFinal else { return false }
        let coherentTranscript = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !coherentTranscript.isEmpty,
              coherentTranscript != retainedTranscript else {
            return false
        }

        retainedTranscript = coherentTranscript
        lastProgressAt = max(now, startedAt)
        return true
    }

    @discardableResult
    mutating func markReleased(
        at now: TimeInterval,
        awaitingRecognitionStartup: Bool = false
    ) -> DeadlineDecision {
        guard completion == nil else { return .finished }
        if releasedAt == nil {
            let boundedReleaseTime = max(now, startedAt)
            releasedAt = boundedReleaseTime
            hardMaximumAt = boundedReleaseTime + hardMaximumDelaySeconds
            recognitionStartupIsPending = awaitingRecognitionStartup
        }

        if receivedFinal {
            let completedTranscript = completeFromRetainedTranscript()
            return .complete(completedTranscript, reason: .appleFinal)
        }
        return deadlineDecision(at: now)
    }

    /// Recognition inactivity starts only after the recognizer can consume the
    /// captured audio. The original release deadline still bounds cold startup.
    mutating func markRecognitionReady(
        at now: TimeInterval,
        inactivityDelaySeconds: TimeInterval,
        hardMaximumDelaySeconds: TimeInterval
    ) -> DeadlineDecision {
        guard completion == nil else { return .finished }
        self.inactivityDelaySeconds = max(inactivityDelaySeconds, 0)
        self.hardMaximumDelaySeconds = max(hardMaximumDelaySeconds, 0)
        if recognitionStartupIsPending, let releasedAt, let hardMaximumAt {
            let readyAt = max(now, releasedAt)
            lastProgressAt = max(lastProgressAt ?? releasedAt, readyAt)
            self.hardMaximumAt = min(
                hardMaximumAt, readyAt + self.hardMaximumDelaySeconds
            )
        }
        recognitionStartupIsPending = false
        return deadlineDecision(at: now)
    }

    @discardableResult
    mutating func recordFinal(
        _ transcript: String,
        at now: TimeInterval
    ) -> Completion? {
        guard completion == nil, !receivedFinal else { return nil }
        let candidate = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if BuddyTranscriptRevisionPolicy.shouldReplace(
            retainedTranscript, with: candidate
        ) {
            retainedTranscript = candidate
            lastProgressAt = max(now, startedAt)
        }
        receivedFinal = true
        guard releasedAt != nil else { return nil }
        return completeFromRetainedTranscript()
    }

    mutating func deadlineDecision(at now: TimeInterval) -> DeadlineDecision {
        guard completion == nil else { return .finished }
        guard let releasedAt, let hardMaximumAt else { return .notReleased }

        let inactivityReference = max(lastProgressAt ?? releasedAt, releasedAt)
        let inactivityDeadline = inactivityReference + inactivityDelaySeconds
        let nextDeadline = recognitionStartupIsPending
            ? hardMaximumAt : min(inactivityDeadline, hardMaximumAt)
        guard now >= nextDeadline else {
            return .wait(until: nextDeadline)
        }

        let reason: DeadlineReason = recognitionStartupIsPending
            || hardMaximumAt <= inactivityDeadline
            ? .hardMaximum
            : .inactivity
        let completedTranscript = completeFromRetainedTranscript()
        return .complete(completedTranscript, reason: reason)
    }

    @discardableResult
    mutating func cancelForRestart() -> Completion? {
        guard completion == nil else { return nil }
        completion = .cancelledForRestart
        return completion
    }

    private mutating func completeFromRetainedTranscript() -> Completion {
        let completedTranscript = retainedTranscript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let resolvedCompletion: Completion = completedTranscript.isEmpty
            ? .finishWithoutTranscript
            : .submit(completedTranscript)
        completion = resolvedCompletion
        return resolvedCompletion
    }
}

nonisolated enum BuddySequencedRecognitionUpdate: Equatable, Sendable {
    case progress(String)
    case final(String)
    case ignored
}

/// Reduces native Speech callbacks before they cross into MainActor. Apple may
/// deliver a regressive partial, an empty final, or a callback queued behind a
/// final. Sequence and terminal state are consumed here so those callback
/// shapes cannot truncate or reopen the owner turn. Compact corrections remain
/// authoritative even when normalization reduces their word or character count.
nonisolated struct BuddySequencedRecognitionReducer: Sendable {
    private var latestSequence: UInt64?
    private var retainedTranscript = ""
    private var isFinal = false

    mutating func observe(
        sequence: UInt64,
        transcript: String,
        isFinal: Bool
    ) -> BuddySequencedRecognitionUpdate {
        guard !self.isFinal else { return .ignored }
        if let latestSequence, sequence <= latestSequence {
            return .ignored
        }
        latestSequence = sequence

        let candidate = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if isFinal {
            self.isFinal = true
            if BuddyTranscriptRevisionPolicy.shouldReplace(
                retainedTranscript, with: candidate
            ) {
                retainedTranscript = candidate
            }
            return .final(retainedTranscript)
        }

        guard !candidate.isEmpty,
              candidate != retainedTranscript,
              BuddyTranscriptRevisionPolicy.shouldReplace(
                retainedTranscript, with: candidate
              ) else {
            return .ignored
        }
        retainedTranscript = candidate
        return .progress(candidate)
    }

}

nonisolated struct BuddyDictationPhysicalGenerationGate {
    private var activeGenerationIdentifier: UUID?

    mutating func claim(_ generationIdentifier: UUID) -> Bool {
        guard activeGenerationIdentifier == nil else { return false }
        activeGenerationIdentifier = generationIdentifier
        return true
    }

    @discardableResult
    mutating func release(_ generationIdentifier: UUID) -> Bool {
        guard activeGenerationIdentifier == generationIdentifier else {
            return false
        }
        activeGenerationIdentifier = nil
        return true
    }
}

/// Serializes the final accepted microphone buffer with `endAudio()`. Apple
/// Speech does not make concurrent mutation of its audio request safe, and an
/// asynchronous copy would outlive AVAudioEngine's reusable render buffer.
nonisolated final class BuddySerializedTranscriptionInputBoundary:
    @unchecked Sendable
{
    private final class EndAudioReceipt: @unchecked Sendable {
        var didEndAudio = false
    }

    private enum State {
        case acceptingAudio
        case ended
        case cancelled
    }

    private let inputQueue: DispatchQueue
    private var state: State = .acceptingAudio

    init(label: String) {
        inputQueue = DispatchQueue(label: label, qos: .userInitiated)
    }

    @discardableResult
    func append(_ operation: () -> Void) -> Bool {
        inputQueue.sync {
            guard state == .acceptingAudio else { return false }
            operation()
            return true
        }
    }

    @discardableResult
    func endAudio(
        waitTimeoutSeconds: TimeInterval = 0.25,
        _ operation: @escaping () -> Void
    ) -> Bool {
        let receipt = EndAudioReceipt()
        let workItem = DispatchWorkItem { [self] in
            guard state == .acceptingAudio else { return }
            state = .ended
            operation()
            receipt.didEndAudio = true
        }
        inputQueue.async(execute: workItem)

        let finiteWait = waitTimeoutSeconds.isFinite
            ? max(waitTimeoutSeconds, 0)
            : 0.25
        let timeoutNanoseconds = Int(
            min(finiteWait * 1_000_000_000, Double(Int.max))
        )
        guard workItem.wait(
            timeout: .now() + .nanoseconds(timeoutNanoseconds)
        ) == .success else {
            // The end marker remains queued behind every accepted buffer. The
            // caller stays latency-bounded while Speech still receives the
            // entire tail before `endAudio()` executes.
            return false
        }
        return receipt.didEndAudio
    }

    func cancel() {
        inputQueue.sync {
            guard state == .acceptingAudio else { return }
            state = .cancelled
        }
    }
}

nonisolated enum BuddyDictationReleasePolicy {
    static func shouldSubmitImmediately(
        sourceIsKeyboardShortcut: Bool,
        automaticallySubmits: Bool,
        recognizedText: String,
        isInstantCommand: Bool
    ) -> Bool {
        sourceIsKeyboardShortcut
            && automaticallySubmits
            && !recognizedText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && isInstantCommand
    }
}

/// Exact safety and privacy-boundary utterances may bypass Apple's bounded
/// final tail. Privacy entry must be immediate: waiting for the recognizer's
/// final callback made a complete "go stealth" command look broken for seconds.
nonisolated enum BuddyDictationPartialSubmissionPolicy {
    private static let exactImmediateCommands: Set<String> = [
        "stop",
        "stop it",
        "stop that",
        "stop talking",
        "stop scanning",
        "be quiet",
        "quiet",
        "shush",
        "hush",
        "shut up",
        "silence",
        "never mind",
        "nevermind",
        "cancel",
        "cancel that",
        "cancel it",
        "forget it",
        "thats enough",
        "enough",
        "go stealth",
    ]

    static func admits(_ transcript: String) -> Bool {
        let folded = transcript.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let wordsOnly = folded.replacingOccurrences(
            of: #"[^a-z0-9\s]"#,
            with: " ",
            options: .regularExpression
        )
        let normalized = wordsOnly.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return exactImmediateCommands.contains(normalized)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }
    var recoveryProvider: SpeechRecognitionProvider { get }

    func startStreamingSession(
        vocabulary: SpeechContextualVocabulary,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension BuddyTranscriptionProvider {
    var recoveryProvider: SpeechRecognitionProvider { .other }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum BuddyTranscriptionProviderFactory {
    /// LOCKED to Apple on-device speech: audio never leaves this Mac.
    ///
    /// This used to be a preference-driven resolver that could pick AssemblyAI
    /// or OpenAI. Those branches were already unreachable, but the transports
    /// still compiled in -- shipping the ability to stream a buyer's microphone
    /// to a third party, plus a placeholder proxy URL, for a path nothing could
    /// select. The providers and the resolver are gone, so off-device
    /// transcription is now impossible by construction rather than by policy.
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = AppleSpeechTranscriptionProvider()
        print("🎙️ Transcription: using \(provider.displayName) (on-device, locked)")
        return provider
    }
}
#endif // circuit-convert
