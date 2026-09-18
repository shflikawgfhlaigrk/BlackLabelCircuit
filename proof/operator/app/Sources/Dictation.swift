// Sovereign — REAL on-device dictation (speech-to-text) for the chat composer.
//
// Voice INPUT done the local-private way: Apple's Speech framework with on-device
// recognition (requiresOnDeviceRecognition) whenever this device supports it — the captured
// audio never leaves the machine, no cloud, no Black Label backend. The buyer must
// EXPLICITLY grant microphone + speech-recognition access at the system prompt; nothing is
// captured until they do.
//
// §5.8 (restricted entitlements gated): this engine NEVER touches the microphone unless the
// RUNNING bundle actually declares NSMicrophoneUsageDescription + NSSpeechRecognitionUsage-
// Description. A build that omits those keys reports `available == false` and the UI shows an
// honest "voice input isn't in this build" state — never a dead or crashing mic control. So
// the same source ships safely in a minimal-entitlement build and lights up in a provisioned one.
//
// §5.1 (zero fabrication): partial/final transcripts are exactly what the recognizer returns.
// On denied access, an unsupported locale, or a capture failure the caller gets an honest
// error — never fabricated text.
import Foundation
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class DictationEngine: ObservableObject {
    enum Access: Equatable { case notDetermined, denied, granted }

    @Published private(set) var listening = false
    @Published private(set) var partial = ""
    @Published private(set) var access: Access = .notDetermined
    @Published private(set) var lastError: String?
    /// When `lastError` is a TCC denial, the exact System Settings pane that fixes it — so the UI
    /// can offer the deep link instead of describing the navigation. Nil for non-permission errors.
    @Published private(set) var deniedPane: PrivacyPane?

    /// Set by RootView so a grant/denial and each dictation session leave a real receipt.
    weak var activity: ActivityLog?

    #if canImport(Speech)
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    #endif

    /// §5.8 gate: the feature only exists when THIS bundle carries the mic + speech usage strings.
    /// Keyed on the running Info.plist, so a build without the entitlement is honestly inert.
    var entitled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil &&
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    /// True only when dictation can really be offered: an entitled build, a working recognizer, AND
    /// on-device recognition support (SV-23 hard guarantee — see DictationPolicy). No on-device
    /// support → false → honest "not available" surface, the mic is NEVER touched and audio never
    /// goes to the cloud.
    var available: Bool {
        #if canImport(Speech)
        return DictationPolicy.isAvailable(entitled: entitled,
                                           recognizerAvailable: recognizer?.isAvailable ?? false,
                                           onDeviceSupported: recognizer?.supportsOnDeviceRecognition ?? false)
        #else
        return false
        #endif
    }

    /// Honest one-line reason the feature is off, for the UI to show instead of a dead control.
    var unavailableReason: String {
        #if canImport(Speech)
        return DictationPolicy.unavailableReason(
            DictationPolicy.availability(entitled: entitled,
                                         recognizerAvailable: recognizer?.isAvailable ?? false,
                                         onDeviceSupported: recognizer?.supportsOnDeviceRecognition ?? false))
        #else
        return "Speech recognition isn't available on this system."
        #endif
    }

    /// Whether on-device (private) recognition will be used. Reported honestly in the UI.
    var onDevice: Bool {
        #if canImport(Speech)
        return recognizer?.supportsOnDeviceRecognition ?? false
        #else
        return false
        #endif
    }

    // MARK: Control

    /// Toggle dictation. `onText` receives the full running transcript on each partial result.
    func toggle(onText: @escaping (String) -> Void) {
        if listening { stop() } else { start(onText: onText) }
    }

    func start(onText: @escaping (String) -> Void) {
        #if canImport(Speech)
        guard available else { lastError = unavailableReason; return }
        lastError = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                switch status {
                case .authorized:
                    self.access = .granted
                    self.deniedPane = nil
                    self.requestMicThenRun(onText: onText)
                case .denied, .restricted:
                    self.access = .denied
                    self.lastError = "Speech-recognition access is off (System Settings → Privacy → Speech Recognition)."
                    self.deniedPane = .speechRecognition
                    self.activity?.record(kind: .connector, title: "Dictation",
                                          detail: "Speech-recognition access denied.", outcome: .info)
                case .notDetermined:
                    self.access = .notDetermined
                @unknown default:
                    self.access = .denied
                }
            }
        }
        #else
        lastError = unavailableReason
        #endif
    }

    func stop() {
        #if canImport(Speech)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        stopEngine()
        #endif
        if listening {
            listening = false
            activity?.record(kind: .connector, title: "Dictation",
                             detail: "Dictation session ended.", outcome: .success)
        }
        partial = ""
    }

    // MARK: Internals

    #if canImport(Speech)
    private func requestMicThenRun(onText: @escaping (String) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                guard granted else {
                    self.access = .denied
                    self.lastError = "Microphone access is off (System Settings → Privacy → Microphone)."
                    self.deniedPane = .microphone
                    self.activity?.record(kind: .connector, title: "Dictation",
                                          detail: "Microphone access denied.", outcome: .info)
                    return
                }
                self.deniedPane = nil   // both permissions granted — stale link would mislead
                self.runRecognition(onText: onText)
            }
        }
    }

    private func runRecognition(onText: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognition isn't available right now."
            return
        }
        // SV-23 HARD offline guarantee: on-device recognition is REQUIRED, not optional. If this Mac
        // can't recognize on-device we refuse rather than fall back to Apple's cloud speech servers —
        // the buyer's audio never leaves the machine. `available` already gates on this, so reaching
        // here without support means a race; we still refuse. §5.5 (own it) / §5.1.
        guard recognizer.supportsOnDeviceRecognition else {
            lastError = DictationPolicy.unavailableReason(.noOnDevice)
            stopEngine(); listening = false
            return
        }
        do {
            stopEngine()  // tear down any prior session
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = DictationPolicy.requiresOnDeviceRecognition  // always true — no cloud fallback, ever
            request = req

            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()
            listening = true
            partial = ""
            activity?.record(kind: .connector, title: "Dictation",
                             detail: recognizer.supportsOnDeviceRecognition
                                 ? "On-device dictation started (audio stays on this device)."
                                 : "Dictation started.", outcome: .info)

            task = recognizer.recognitionTask(with: req) { result, error in
                Task { @MainActor in
                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.partial = text
                        onText(text)
                        if result.isFinal { self.stop() }
                    }
                    if let error {
                        // A normal end-of-audio surfaces as an error too; only report real failures.
                        if self.listening { self.lastError = error.localizedDescription }
                        self.stop()
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            stopEngine()
            listening = false
        }
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
    #endif
}
#endif // circuit-convert

// MARK: - SV-23: the STT lane's HARD offline guarantee (machine-checkable, no microphone)
//
// Dictation is offered ONLY when this Mac can recognize speech ON-DEVICE. If on-device recognition
// is unsupported, voice input stays honestly OFF — Sovereign NEVER falls back to Apple's cloud
// speech servers, so the buyer's audio never leaves the machine. That is the whole promise of
// SV-23: unlimited on-device voice, no 15-minute cloud cap, no per-minute bill, no egress. The
// decision is a PURE function so the no-network test can prove it with no hardware and no mic.
// §5.5 (own it — no paid/cloud dependency) / §5.1 (no fabricated capability).
enum DictationPolicy {
    /// Why dictation is (un)available. `.noOnDevice` is the SV-23 guarantee in action: rather than
    /// silently streaming to the cloud, the feature stays off and says so honestly.
    enum Availability: Equatable { case ready, notEntitled, noRecognizer, noOnDevice }

    /// On-device recognition is MANDATORY for every dictation session — the engine sets the
    /// recognizer flag to THIS constant unconditionally (never `false`, never conditional). Exposed
    /// so the guarantee lives as one named truth the source-scan test can pin.
    static let requiresOnDeviceRecognition = true

    /// The hard gate. Voice input is `.ready` only when the bundle is entitled, a recognizer exists,
    /// AND this device supports on-device recognition. No on-device support → `.noOnDevice` (OFF),
    /// never a cloud fallback. PURE.
    static func availability(entitled: Bool, recognizerAvailable: Bool, onDeviceSupported: Bool) -> Availability {
        if !entitled { return .notEntitled }
        if !recognizerAvailable { return .noRecognizer }
        if !onDeviceSupported { return .noOnDevice }   // HARD: refuse rather than use cloud STT
        return .ready
    }

    /// Convenience: dictation is offerable only in the `.ready` state.
    static func isAvailable(entitled: Bool, recognizerAvailable: Bool, onDeviceSupported: Bool) -> Bool {
        availability(entitled: entitled, recognizerAvailable: recognizerAvailable, onDeviceSupported: onDeviceSupported) == .ready
    }

    /// The honest one-liner the UI shows instead of a dead mic when voice input is off. PURE.
    static func unavailableReason(_ a: Availability) -> String {
        switch a {
        case .ready:        return ""
        case .notEntitled:  return "Voice input isn't included in this build — it needs the microphone entitlement."
        case .noRecognizer: return "Speech recognition isn't available on this device right now."
        #if os(iOS)
        case .noOnDevice:   return "On-device dictation isn't ready on this device — turn on Dictation (Settings → General → Keyboard → Enable Dictation) so iOS downloads on-device speech. Sovereign won't send your voice to the cloud, so voice input stays off until then."
        #else
        case .noOnDevice:   return "On-device dictation isn't ready on this Mac — turn on Dictation (System Settings → Keyboard → Dictation) so macOS downloads on-device speech. Sovereign won't send your voice to the cloud, so voice input stays off until then."
        #endif
        }
    }
}
