// Sovereign — WAKE WORD: always-listening voice activation, fully on-device.
//
// The buyer trains the wake phrase once during setup (three real recognitions of the phrase,
// never a fake "trained" state), then Sovereign listens continuously and activates chat +
// dictation the moment it hears the phrase. Recognition uses Apple's Speech framework with
// on-device mode whenever this Mac supports it — audio never leaves the machine.
//
// §5.8 (restricted entitlements gated): exactly like DictationEngine, this engine NEVER touches
// the microphone unless the RUNNING bundle declares NSMicrophoneUsageDescription +
// NSSpeechRecognitionUsageDescription. Minimal-entitlement builds report `available == false`
// and the UI shows the honest "not in this build" state — never a dead control.
//
// §5.1 (zero fabrication): a training pass succeeds only when the recognizer REALLY heard the
// phrase; the wake loop fires only on a real match. Errors are surfaced, never painted over.
import Foundation
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

/// Posted when the wake phrase is heard — ChatScreen answers by starting dictation hands-free.
extension Notification.Name {
    static let sovereignWake = Notification.Name("com.blacklabel.sovereign.wake")
}

// MARK: - Pure wake-phrase matching (unit-tested without any audio).

enum WakeMatch {
    /// Normalize a transcript or phrase for matching: lowercase, punctuation stripped,
    /// whitespace collapsed. PURE.
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// True when the transcript contains the wake phrase as WHOLE WORDS, case- and
    /// punctuation-insensitive: "Hey, Sovereign!" wakes "sovereign"; "sovereignty" never does.
    /// Multi-word phrases must appear as a contiguous word run. PURE.
    static func heard(_ transcript: String, phrase: String) -> Bool {
        let words = normalize(transcript).split(separator: " ").map(String.init)
        let target = normalize(phrase).split(separator: " ").map(String.init)
        guard !target.isEmpty, words.count >= target.count else { return false }
        for start in 0...(words.count - target.count) {
            if Array(words[start..<(start + target.count)]) == target { return true }
        }
        return false
    }
}

// MARK: - The always-listening engine.

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class WakeEngine: ObservableObject {
    enum Mode: Equatable { case off, wake, training }

    @Published private(set) var mode: Mode = .off
    @Published private(set) var heardPartial = ""     // live transcript, honest recognizer output
    @Published private(set) var lastError: String?
    /// When `lastError` is a TCC denial, the exact System Settings pane that fixes it — so the UI
    /// can offer the deep link instead of describing the navigation. Nil for non-permission errors.
    @Published private(set) var deniedPane: PrivacyPane?

    /// Fired on a real wake-phrase match while in `.wake` mode. Set by RootView.
    var onWake: () -> Void = {}
    weak var activity: ActivityLog?

    private var phrase = ""

    #if canImport(Speech)
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var recycleTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var trainingContinuation: CheckedContinuation<Bool, Never>?
    private var trainingTimeoutTask: Task<Void, Never>?
    #endif

    /// §5.8 gate — identical to DictationEngine's: the feature exists only in an entitled build.
    var entitled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil &&
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    var available: Bool {
        #if canImport(Speech)
        return entitled && (recognizer?.isAvailable ?? false)
        #else
        return false
        #endif
    }

    var unavailableReason: String {
        #if canImport(Speech)
        if !entitled { return "Wake word isn't included in this build — it needs the microphone entitlement." }
        if recognizer?.isAvailable != true { return "Speech recognition isn't available on this device right now." }
        return ""
        #else
        return "Speech recognition isn't available on this system."
        #endif
    }

    var onDevice: Bool {
        #if canImport(Speech)
        return recognizer?.supportsOnDeviceRecognition ?? false
        #else
        return false
        #endif
    }

    // MARK: Wake loop

    /// Start continuous listening for the phrase. Requests speech + mic access honestly
    /// (system prompts) on first use; on any grant failure the engine reports the real reason.
    func startWakeLoop(phrase: String) {
        #if canImport(Speech)
        guard available else { lastError = unavailableReason; return }
        guard mode != .wake else { return }
        self.phrase = phrase
        lastError = nil
        mode = .wake
        requestAccessThenRun()
        #else
        lastError = unavailableReason
        #endif
    }

    /// Pause listening without forgetting the phrase (used while dictation owns the mic).
    func pause() {
        #if canImport(Speech)
        guard mode == .wake else { return }
        teardownAudio()
        restartTask?.cancel(); recycleTask?.cancel()
        mode = .off
        #endif
    }

    func stop() {
        #if canImport(Speech)
        teardownAudio()
        restartTask?.cancel(); recycleTask?.cancel()
        trainingTimeoutTask?.cancel()
        if let c = trainingContinuation { trainingContinuation = nil; c.resume(returning: false) }
        if mode == .wake {
            activity?.record(kind: .connector, title: "Wake word",
                             detail: "Wake-word listening stopped.", outcome: .info)
        }
        mode = .off
        heardPartial = ""
        #endif
    }

    // MARK: Training

    /// ONE real training pass: listen up to `timeout` seconds and succeed only if the
    /// recognizer genuinely heard the phrase. The live transcript streams to `heardPartial`.
    func trainPass(phrase: String, timeout: TimeInterval = 8) async -> Bool {
        #if canImport(Speech)
        guard available else { lastError = unavailableReason; return false }
        stop()
        self.phrase = phrase
        mode = .training
        heardPartial = ""
        lastError = nil
        let heard = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            trainingContinuation = c
            requestAccessThenRun()
            trainingTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.finishTraining(success: false)
            }
        }
        return heard
        #else
        lastError = unavailableReason
        return false
        #endif
    }

    // MARK: Internals

    #if canImport(Speech)
    private func finishTraining(success: Bool) {
        guard mode == .training else { return }
        trainingTimeoutTask?.cancel()
        teardownAudio()
        mode = .off
        if let c = trainingContinuation { trainingContinuation = nil; c.resume(returning: success) }
    }

    private func requestAccessThenRun() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.lastError = "Speech-recognition access is off (System Settings → Privacy → Speech Recognition)."
                    self.deniedPane = .speechRecognition
                    if self.mode == .training { self.finishTraining(success: false) } else { self.mode = .off }
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.lastError = "Microphone access is off (System Settings → Privacy → Microphone)."
                            self.deniedPane = .microphone
                            if self.mode == .training { self.finishTraining(success: false) } else { self.mode = .off }
                            return
                        }
                        self.deniedPane = nil   // both permissions granted — stale link would mislead
                        self.runRecognition()
                    }
                }
            }
        }
    }

    private func runRecognition() {
        guard mode != .off else { return }
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognition isn't available right now."
            if mode == .training { finishTraining(success: false) } else { mode = .off }
            return
        }
        // SV-23 HARD offline guarantee (wake too): on-device recognition is REQUIRED — the
        // always-listening wake mic never falls back to Apple's cloud speech servers. If this Mac
        // can't recognize on-device yet (Siri/Dictation off), refuse with the honest remedy
        // instead of silently uploading audio.
        guard recognizer.supportsOnDeviceRecognition else {
            lastError = "On-device speech isn't ready on this Mac — turn on Dictation (System Settings → Keyboard → Dictation) so macOS downloads it, then try again. Your voice never leaves this Mac."
            if mode == .training { finishTraining(success: false) } else { mode = .off }
            return
        }
        do {
            teardownAudio()
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = true   // always — no cloud fallback, ever
            request = req

            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()

            if mode == .wake {
                // Apple caps a single recognition task's duration — recycle before it expires
                // so the loop stays honest and continuous.
                recycleTask?.cancel()
                recycleTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    guard let self, !Task.isCancelled, self.mode == .wake else { return }
                    self.runRecognition()
                }
            }

            task = recognizer.recognitionTask(with: req) { result, error in
                Task { @MainActor in
                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.heardPartial = text
                        if WakeMatch.heard(text, phrase: self.phrase) { self.handleHit() }
                        else if result.isFinal, self.mode == .wake { self.scheduleWakeRestart() }
                    }
                    if error != nil, self.mode == .wake { self.scheduleWakeRestart() }
                }
            }
        } catch {
            lastError = error.localizedDescription
            if mode == .training { finishTraining(success: false) }
            else if mode == .wake { scheduleWakeRestart() }
        }
    }

    private func handleHit() {
        switch mode {
        case .training:
            finishTraining(success: true)
        case .wake:
            activity?.record(kind: .connector, title: "Wake word",
                             detail: "Wake phrase heard — activating chat.", outcome: .success)
            teardownAudio()
            heardPartial = ""
            onWake()
            scheduleWakeRestart(after: 1.5)   // resume listening after the hand-off
        case .off:
            break
        }
    }

    /// Condition-based loop resilience: restart the recognizer only while still in wake mode.
    private func scheduleWakeRestart(after seconds: TimeInterval = 0.7) {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.mode == .wake else { return }
            self.runRecognition()
        }
    }

    private func teardownAudio() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
    #endif
}
#endif // circuit-convert
