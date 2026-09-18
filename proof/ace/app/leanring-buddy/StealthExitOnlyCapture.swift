#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  StealthExitOnlyCapture.swift
//  Ace
//
//  One explicit, hold-bound, on-device Apple Speech session for leaving
//  Stealth. It has no draft callback, transcript callback, history callback,
//  event bus, model, network, analytics, or UI surface by construction.
//

#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
import Foundation
#if canImport(Speech) && !CIRCUIT_WINDOWS_SIM
import Speech
#endif

private final class StealthExitOnlyRequestAppender: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let queue = DispatchQueue(
        label: "com.blacklabel.ace.stealth-exit-only-audio",
        qos: .userInteractive
    )

    func install(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock { self.request = request }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.request?.append(buffer) }
        }
    }

    func endAudio() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.request?.endAudio() }
        }
    }

    func clear() {
        lock.withLock { request = nil }
    }
}

@MainActor
protocol StealthExitOnlyCaptureBackend: AnyObject {
    func start(
        onFinal: @escaping (String) -> Void,
        onFailure: @escaping (StealthExitOnlyRejectionReason) -> Void
    ) throws
    func stop()
    func cancel()
}

@MainActor
final class AppleStealthExitOnlyCaptureBackend:
    StealthExitOnlyCaptureBackend {
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioTapIsInstalled = false
    private var hasDeliveredTerminalResult = false
    private var retainedRecognizedText = ""
    private let requestAppender = StealthExitOnlyRequestAppender()

    init(locale: Locale = Locale(identifier: AceLanguage.current.localeIdentifier)) {
        speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    func start(
        onFinal: @escaping (String) -> Void,
        onFailure: @escaping (StealthExitOnlyRejectionReason) -> Void
    ) throws {
        cancel()
        guard AVCaptureDevice.authorizationStatus(for: .audio)
                == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw StealthExitOnlyCaptureError(.permissionUnavailable)
        }
        guard let speechRecognizer,
              speechRecognizer.isAvailable,
              speechRecognizer.supportsOnDeviceRecognition else {
            throw StealthExitOnlyCaptureError(
                .onDeviceRecognizerUnavailable
            )
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .confirmation
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = StealthExitOnlyPolicy.allowedPhrases
        recognitionRequest = request
        requestAppender.install(request)
        hasDeliveredTerminalResult = false
        retainedRecognizedText = ""

        recognitionTask = speechRecognizer.recognitionTask(
            with: request
        ) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, !self.hasDeliveredTerminalResult else {
                    return
                }
                if let result {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self.retainedRecognizedText = text
                    }
                    if result.isFinal {
                        self.hasDeliveredTerminalResult = true
                        onFinal(self.retainedRecognizedText)
                        self.tearDown()
                        return
                    }
                }
                if error != nil {
                    self.hasDeliveredTerminalResult = true
                    let retained = self.retainedRecognizedText
                    if retained.isEmpty {
                        onFailure(.recognitionFailed)
                    } else {
                        onFinal(retained)
                    }
                    self.tearDown()
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            tearDown()
            throw StealthExitOnlyCaptureError(.audioUnavailable)
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { [weak self] buffer, _ in
            // No buffer ever leaves this process or survives the recognition
            // request. The request is hard-pinned to on-device recognition.
            self?.requestAppender.append(buffer)
        }
        audioTapIsInstalled = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            tearDown()
            throw StealthExitOnlyCaptureError(.audioUnavailable)
        }
    }

    func stop() {
        if audioEngine.isRunning { audioEngine.stop() }
        removeAudioTapIfNeeded()
        // The end marker is serialized behind every buffer accepted by the
        // tap. Release cannot overtake the last word of "come back."
        requestAppender.endAudio()
    }

    func cancel() {
        hasDeliveredTerminalResult = true
        tearDown()
    }

    private func tearDown() {
        if audioEngine.isRunning { audioEngine.stop() }
        removeAudioTapIfNeeded()
        recognitionTask?.cancel()
        recognitionTask = nil
        requestAppender.clear()
        recognitionRequest = nil
        retainedRecognizedText = ""
    }

    private func removeAudioTapIfNeeded() {
        guard audioTapIsInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioTapIsInstalled = false
    }
}

struct StealthExitOnlyCaptureError: Error {
    let reason: StealthExitOnlyRejectionReason

    init(_ reason: StealthExitOnlyRejectionReason) {
        self.reason = reason
    }
}

@MainActor
final class StealthExitOnlyCapture {
    private let backendFactory: @MainActor () -> any StealthExitOnlyCaptureBackend
    private var activeBackend: (any StealthExitOnlyCaptureBackend)?
    private let audioSessionCoordinator: AudioSessionCoordinator?
    private var coordinator = StealthExitOnlyCoordinator()
    private var activeGeneration: UUID?
    private var completion:
        ((StealthExitOnlyCompletion) -> Void)?
    private var stealthIsActive = false
    private var finalFallbackTask: Task<Void, Never>?

    init(
        backend: any StealthExitOnlyCaptureBackend,
        audioSessionCoordinator: AudioSessionCoordinator? = nil
    ) {
        backendFactory = { backend }
        self.audioSessionCoordinator = audioSessionCoordinator
    }

    init(
        backendFactory: @escaping @MainActor () -> any StealthExitOnlyCaptureBackend,
        audioSessionCoordinator: AudioSessionCoordinator? = nil
    ) {
        self.backendFactory = backendFactory
        self.audioSessionCoordinator = audioSessionCoordinator
    }

    convenience init(
        audioSessionCoordinator: AudioSessionCoordinator? = nil
    ) {
        self.init(
            backendFactory: { AppleStealthExitOnlyCaptureBackend() },
            audioSessionCoordinator: audioSessionCoordinator
        )
    }

    var isCapturing: Bool { activeGeneration != nil }

    func enterStealth(epoch: UUID) {
        cancel()
        stealthIsActive = true
        coordinator.enterStealth(epoch: epoch)
    }

    func leaveStealth() {
        cancel()
        stealthIsActive = false
        coordinator.leaveStealth()
    }

    @discardableResult
    func beginPushToTalk(
        completion: @escaping (StealthExitOnlyCompletion) -> Void
    ) -> Bool {
        guard stealthIsActive else {
            completion(.rejected(.inactive))
            return false
        }
        let generation = UUID()
        guard coordinator.beginPushToTalk(generation: generation) else {
            completion(.rejected(.captureAlreadyActive))
            return false
        }
        if let audioSessionCoordinator {
            let decision = audioSessionCoordinator.acquireCapture(
                .stealthExitOnly
            )
            switch decision {
            case .acquired, .alreadyOwned:
                break
            case .refused, .interruptedMeetingNotes, .resumedMeetingNotes,
                 .released:
                coordinator.cancel(generation: generation)
                completion(.rejected(.audioUnavailable))
                return false
            }
        }
        activeGeneration = generation
        self.completion = completion
        let backend = backendFactory()
        activeBackend = backend
        do {
            try backend.start(
                onFinal: { [weak self] text in
                    self?.finish(
                        generation: generation,
                        transcript: text
                    )
                },
                onFailure: { [weak self] reason in
                    self?.fail(generation: generation, reason: reason)
                }
            )
            return true
        } catch let error as StealthExitOnlyCaptureError {
            fail(generation: generation, reason: error.reason)
            return false
        } catch {
            fail(generation: generation, reason: .audioUnavailable)
            return false
        }
    }

    func endPushToTalk() {
        guard let generation = activeGeneration else { return }
        activeBackend?.stop()
        finalFallbackTask?.cancel()
        finalFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.fail(generation: generation, reason: .recognitionFailed)
        }
    }

    func cancel() {
        finalFallbackTask?.cancel()
        finalFallbackTask = nil
        guard let generation = activeGeneration else {
            activeBackend?.cancel()
            activeBackend = nil
            completion = nil
            return
        }
        coordinator.cancel(generation: generation)
        activeGeneration = nil
        completion = nil
        activeBackend?.cancel()
        activeBackend = nil
        releaseAudioSession()
    }

    private func finish(generation: UUID, transcript: String) {
        guard generation == activeGeneration else { return }
        finalFallbackTask?.cancel()
        finalFallbackTask = nil
        let terminal = coordinator.complete(
            generation: generation,
            finalTranscript: transcript,
            stealthIsActive: stealthIsActive
        )
        activeGeneration = nil
        let callback = completion
        completion = nil
        activeBackend?.cancel()
        activeBackend = nil
        releaseAudioSession()
        callback?(terminal)
    }

    private func fail(
        generation: UUID,
        reason: StealthExitOnlyRejectionReason
    ) {
        guard generation == activeGeneration else { return }
        finalFallbackTask?.cancel()
        finalFallbackTask = nil
        coordinator.cancel(generation: generation)
        activeGeneration = nil
        let callback = completion
        completion = nil
        activeBackend?.cancel()
        activeBackend = nil
        releaseAudioSession()
        callback?(.rejected(reason))
    }

    private func releaseAudioSession() {
        guard audioSessionCoordinator?.snapshot.captureOwner
                == .stealthExitOnly else { return }
        _ = audioSessionCoordinator?.releaseCapture(.stealthExitOnly)
    }

}
#endif // circuit-convert
