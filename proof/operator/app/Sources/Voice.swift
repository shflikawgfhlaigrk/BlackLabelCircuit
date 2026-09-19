// Sovereign — voice OUTPUT (speech synthesis). Real, on-device, no entitlement required
// (AVSpeechSynthesizer uses no microphone). When the buyer enables voice in Settings,
// the assistant speaks its replies aloud using a system voice they choose. The voice
// list is the REAL set of voices installed on THIS Mac — nothing fabricated.
//
// Voice INPUT (dictation/STT) lives in Dictation.swift and stays inert unless the running
// bundle declares microphone + Speech usage strings. Minimal-entitlement builds show the
// honest unavailable state instead of a dead mic.
import Foundation
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class VoiceEngine: ObservableObject {
    @Published var speaking = false
    private let synth = AVSpeechSynthesizer()
    private let delegate = SpeechDelegate()

    init() {
        delegate.onStart = { [weak self] in self?.speaking = true }
        delegate.onFinish = { [weak self] in self?.speaking = false }
        synth.delegate = delegate
    }

    /// Real installed voices on this device (English first, then the rest), de-duplicated by name.
    static func availableVoices() -> [VoiceOption] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let sorted = all.sorted { a, b in
            let ae = a.language.hasPrefix("en"), be = b.language.hasPrefix("en")
            if ae != be { return ae }
            return a.name < b.name
        }
        return sorted.map { VoiceOption(id: $0.identifier, name: "\($0.name) · \($0.language)") }
    }

    func speak(_ text: String, voiceID: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: clean)
        if !voiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceID) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier) ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        speaking = false
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onStart: () -> Void = {}
    var onFinish: () -> Void = {}
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { Task { @MainActor in onStart() } }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { Task { @MainActor in onFinish() } }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { Task { @MainActor in onFinish() } }
}
#endif // circuit-convert

// MARK: - Voice OPERATOR: the one hands-free path (wake → STT → tool-loop → TTS).
//
// The wake word, on-device dictation (STT), the local brain + its tool-loop, and speech synthesis
// (TTS) are ONE shipped path, not four disconnected halves: the buyer says the wake phrase, speaks a
// request, the LOCAL brain answers (running host tools through the loopback daemon when it needs
// them), and the reply is spoken back — then the wake loop re-arms. This type is the pure, unit-
// tested spine of that path: a deterministic stage machine + an auto-send gate. The audio/brain I/O
// lives in WakeEngine/DictationEngine/VoiceEngine + ChatScreen; the DECISIONS live here so they are
// verifiable with no microphone and no network.

/// One stage of a hands-free voice turn. Linear by design: idle → listening → thinking → speaking → idle.
enum VoiceStage: Equatable {
    case idle        // no hands-free turn in flight
    case listening   // wake fired; on-device STT is capturing the request
    case thinking    // the transcript went to the LOCAL brain; the tool-loop may be running
    case speaking    // the brain's reply is being spoken back (TTS)
}

/// What advances the pipeline. Each is a REAL observed event (a recognizer match, a final transcript,
/// a completed brain reply, the synthesizer finishing) — never a fabricated step.
enum VoiceEvent: Equatable {
    case wakeHeard
    case transcriptFinal(String)
    case replyReady
    case speechFinished
    case cancelled
    case failed
}

enum VoiceOperator {
    /// Pure state machine — the single source of truth for "what happens next" in a hands-free turn.
    /// Unit-tested with no audio and no network. Out-of-order events are absorbed (stay put) rather
    /// than crashing the loop, so a stray recognizer callback can't derail the operator. §5.1.
    static func next(_ stage: VoiceStage, on event: VoiceEvent) -> VoiceStage {
        switch event {
        case .cancelled, .failed:
            return .idle
        case .wakeHeard:
            // A wake hit opens a turn from idle; while a turn is mid-flight it's ignored (no re-entry).
            return stage == .idle ? .listening : stage
        case .transcriptFinal:
            return stage == .listening ? .thinking : stage
        case .replyReady:
            return stage == .thinking ? .speaking : stage
        case .speechFinished:
            return stage == .speaking ? .idle : stage
        }
    }

    /// Whether a finalized STT transcript should be auto-sent to the brain. A hands-free turn sends
    /// only REAL speech: never an empty capture, and never a bare echo of the wake phrase itself
    /// (which would loop the operator forever). PURE.
    static func shouldAutoSend(transcript: String, wakePhrase: String) -> Bool {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        // Strip a leading wake-phrase echo ("Sovereign, what's the weather" → "what's the weather").
        let stripped = strippingLeadingWake(t, phrase: wakePhrase)
        return !stripped.isEmpty
    }

    /// Remove a leading occurrence of the wake phrase (and trailing punctuation) so the request the
    /// brain sees is just the command. If the transcript IS only the wake phrase, returns "". PURE.
    static func strippingLeadingWake(_ transcript: String, phrase: String) -> String {
        let normPhrase = WakeMatch.normalize(phrase)
        guard !normPhrase.isEmpty else { return transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map(String.init)
        let target = normPhrase.split(separator: " ").map(String.init)
        guard words.count >= target.count else {
            // whole thing might be the phrase with punctuation
            return WakeMatch.normalize(transcript) == normPhrase ? "" : transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lead = words.prefix(target.count).map { WakeMatch.normalize($0) }.joined(separator: " ")
        if lead == normPhrase {
            let rest = words.dropFirst(target.count).joined(separator: " ")
            // drop a leading comma/colon the recognizer often inserts after the name
            return rest.trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;-")).trimmingCharacters(in: .whitespaces)
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The offline voice pipeline's EGRESS POLICY, machine-checkable. On a LOCAL brain every outbound
/// request a hands-free turn makes reaches loopback ONLY — the buyer's own Ollama (127.0.0.1:11434)
/// and the on-device tool daemon (127.0.0.1:8765–8785). Nothing the turn does leaves the machine.
/// This is the spine behind the no-network test (which also source-scans the voice files) and the
/// honest "offline" claim. PURE — no I/O.
enum VoiceEgress {
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
    static let ollamaPort = 11434
    static let daemonPortRange = 8765...8785

    /// SV-23: the INPUT leg's guarantee lives in DictationPolicy — speech-to-text runs ON-DEVICE or
    /// not at all (never a cloud STT fallback), so no part of a hands-free turn (mic → brain → TTS)
    /// leaves the machine on a local brain. Mirrored here so the whole voice lane's egress posture is
    /// one truth the no-network test pins across both files. PURE.
    static let sttRequiresOnDeviceRecognition = DictationPolicy.requiresOnDeviceRecognition

    /// Where a given outbound URL goes, from the offline voice turn's point of view.
    enum Destination: Equatable { case ollama, daemon, external, malformed }

    /// Classify an outbound URL string. Loopback + Ollama's port → `.ollama`; loopback + a daemon
    /// port → `.daemon`; any non-loopback host → `.external`; unparseable → `.malformed`. PURE.
    static func classify(_ urlString: String) -> Destination {
        guard let comps = URLComponents(string: urlString),
              let host = comps.host, !host.isEmpty else { return .malformed }
        guard loopbackHosts.contains(host) else { return .external }
        let port = comps.port ?? (comps.scheme == "https" ? 443 : 80)
        if port == ollamaPort { return .ollama }
        if daemonPortRange.contains(port) { return .daemon }
        // A loopback host on some other port is still on-device, but not a voice-pipeline endpoint.
        return .daemon
    }

    /// True when a URL is a permitted loopback destination for an offline voice turn. PURE.
    static func isLoopbackOnly(_ urlString: String) -> Bool {
        switch classify(urlString) { case .ollama, .daemon: return true; case .external, .malformed: return false }
    }

    /// Which brain providers run a fully-offline voice turn (loopback-only or no network at all).
    /// The external (own-Claude) provider reaches api.anthropic.com by design — it is NOT the offline
    /// path, and the operator says so honestly rather than pretending it's local. PURE.
    static func isOfflineProvider(_ provider: BrainProvider) -> Bool {
        switch provider {
        case .ollama, .localEndpoint, .onDevice, .auto: return true   // auto resolves to on-device/Ollama
        case .external: return false
        }
    }

    // MARK: - SV-12: the FULL hands-free turn's egress guarantee (runtime seam, mirrors DictationPolicy)

    /// The egress verdict for a whole wake → STT → tool-loop → TTS turn. A turn has three legs:
    ///   · STT — on-device only (DictationPolicy.requiresOnDeviceRecognition; SV-23). Never egresses.
    ///   · TTS — AVSpeechSynthesizer, entirely on-device. Never egresses.
    ///   · Brain + tool-loop — the ONLY leg that opens a socket; on a local provider it reaches
    ///     loopback only (Ollama :11434 + the on-device daemon).
    /// So the turn's egress reduces to the brain leg's endpoints, and this verdict names it honestly.
    enum TurnEgress: Equatable {
        case fullyOnDevice           // local brain, every endpoint loopback — nothing leaves the machine
        case brainReachesCloud       // the external own-Claude route — honest, NOT the offline path
        case egressDetected(String)  // a non-loopback endpoint leaked into a local-brain turn (a BUG)

        /// True only when the turn is provably contained to the machine.
        var isFullyOnDevice: Bool { self == .fullyOnDevice }
    }

    /// THE RUNTIME SEAM. Given the running brain provider and the exact endpoints a turn would hit,
    /// decide the turn's egress posture. FAILS CLOSED: on a local (offline) provider, the FIRST
    /// endpoint that is not loopback returns `.egressDetected` — so a regression that points the
    /// voice transport off-box is caught by the live app (and the test), not shipped as "offline".
    /// PURE — mirrors DictationPolicy.availability so both legs' guarantees are one decision each.
    static func turnEgress(provider: BrainProvider, endpoints: [String]) -> TurnEgress {
        guard isOfflineProvider(provider) else { return .brainReachesCloud }
        for e in endpoints where !isLoopbackOnly(e) {
            let host = URLComponents(string: e)?.host ?? e
            return .egressDetected(host)
        }
        return .fullyOnDevice
    }

    /// The endpoints a local-brain voice turn actually reaches — the brain (Ollama :11434) and the
    /// on-device tool daemon. Both loopback by construction; the seam re-checks them at runtime so the
    /// "fully on-device" claim is enforced against the real constants, never merely asserted in copy.
    static func localTurnEndpoints(daemonPort: Int = 8765) -> [String] {
        ["http://127.0.0.1:\(ollamaPort)/api/chat", "http://127.0.0.1:\(daemonPort)/api/tools/call"]
    }

    /// Convenience the running app + UI read to show the honest posture for the current provider.
    static func offlineTurnPosture(provider: BrainProvider, daemonPort: Int = 8765) -> TurnEgress {
        turnEgress(provider: provider, endpoints: localTurnEndpoints(daemonPort: daemonPort))
    }

    /// A one-line honest description of the posture — surfaced in receipts + settings, never inflated.
    static func postureDescription(_ posture: TurnEgress) -> String {
        switch posture {
        case .fullyOnDevice:
            return "The core voice path is on-device for this local brain: speech-to-text, local inference, local tool-loop, and text-to-speech use loopback or device frameworks. Web research or connected tools may make network requests when you use them."
        case .brainReachesCloud:
            return "Speech-to-text and text-to-speech stay on-device; the reply is processed by your connected provider or CLI according to that route."
        case .egressDetected(let host):
            return "A voice turn on this local brain would reach \(host) — that is not loopback. Egress guard tripped; the turn is NOT offline."
        }
    }
}

// MARK: - SV-12: the WHOLE hands-free turn, executed as ONE unit (wake → STT → local brain → optional gated tool → TTS)
//
// The per-leg seam above (VoiceEgress.turnEgress / offlineTurnPosture) answers "given a fixed set of
// endpoints, is this posture on-device?" — but it was fed a HARD-CODED endpoint list, so a regression
// that pointed one leg (say the gated tool call) off-box while the brain stayed loopback would slip
// past it. This executes the ACTUAL turn: it drives the same VoiceOperator state machine the live
// operator uses, records the endpoint EVERY leg reaches into a ledger, and computes ONE whole-turn
// egress verdict over the UNION of what the turn really touched — a whole-turn assertion, not per-leg.
// PURE — no audio, no network, no microphone. §5.1 (the "offline" claim is enforced, never asserted).

/// One leg of a hands-free turn. wake / STT / TTS never open a socket (local audio, on-device
/// recognition per DictationPolicy, and AVSpeechSynthesizer are all on-device by construction); the
/// brain leg and an OPTIONAL gated tool leg are the only two that can reach an endpoint. A turn is
/// proven on-device across ALL of them together.
enum VoiceTurnLeg: String, Equatable, CaseIterable {
    case wake, stt, brain, tool, tts
}

/// A single recorded step of a turn: which leg ran, the pipeline stage it ran in, and the exact
/// endpoint it reached — `nil` means this leg opens no socket, so it stays on the machine by
/// construction (never a fabricated "it's local" — a nil endpoint is a leg that provably has none).
struct VoiceTurnStep: Equatable {
    let leg: VoiceTurnLeg
    let stage: VoiceStage
    let endpoint: String?
}

/// Everything the runner needs to execute a whole turn with NO audio and NO network. Injected in
/// tests; assembled from the real running brain provider + daemon at runtime. wake/STT/TTS carry no
/// endpoint; the brain leg reaches `brainEndpoint`; if the turn invokes a (gated) tool, that leg
/// reaches `toolEndpoint` (nil = no tool this turn).
struct VoiceTurnPlan: Equatable {
    var provider: BrainProvider
    var brainEndpoint: String
    var toolEndpoint: String?
    var transcript: String
    var wakePhrase: String

    /// The real LOCAL-brain plan the app runs: brain → the buyer's own Ollama on loopback, and an
    /// optional gated tool → the on-device daemon on loopback. Nothing off-box by construction; the
    /// runner re-checks it against the real constants so the guarantee is enforced, not merely stated.
    static func local(daemonPort: Int = 8765, callsTool: Bool = true,
                      transcript: String = "what's on my calendar today",
                      wakePhrase: String = "Sovereign") -> VoiceTurnPlan {
        VoiceTurnPlan(provider: .ollama,
                      brainEndpoint: "http://127.0.0.1:\(VoiceEgress.ollamaPort)/api/chat",
                      toolEndpoint: callsTool ? "http://127.0.0.1:\(daemonPort)/api/tools/call" : nil,
                      transcript: transcript, wakePhrase: wakePhrase)
    }

    /// The plan the LIVE app builds from the running brain provider. For a local provider the brain
    /// leg is loopback (verified by the runner); for the external route the runner short-circuits to
    /// the honest cloud posture regardless of the endpoint, so the value is never used to fake local.
    static func forProvider(_ provider: BrainProvider, daemonPort: Int = 8765,
                            callsTool: Bool = true) -> VoiceTurnPlan {
        VoiceTurnPlan(provider: provider,
                      brainEndpoint: "http://127.0.0.1:\(VoiceEgress.ollamaPort)/api/chat",
                      toolEndpoint: callsTool ? "http://127.0.0.1:\(daemonPort)/api/tools/call" : nil,
                      transcript: "what's on my calendar today", wakePhrase: "Sovereign")
    }
}

/// The result of running a whole turn: the ordered leg trace, the stage path the state machine
/// walked (idle → listening → thinking → speaking → idle), and ONE egress verdict computed over the
/// UNION of every endpoint the turn touched.
struct VoiceTurnResult: Equatable {
    let steps: [VoiceTurnStep]
    let stages: [VoiceStage]
    let egress: VoiceEgress.TurnEgress
    /// True when STT produced real speech and the turn ran end-to-end (wake → … → speaking → idle);
    /// false when an empty/echo capture ended it before the brain leg.
    let completed: Bool

    /// Every endpoint the turn actually reached — the no-socket legs contribute nothing.
    var endpoints: [String] { steps.compactMap { $0.endpoint } }
    /// True only when the WHOLE turn is provably contained to the machine.
    var wholeTurnOnDevice: Bool { egress.isFullyOnDevice }
}

enum VoiceTurn {
    /// Execute the FULL hands-free turn as one unit. Drives the SAME pure VoiceOperator state machine
    /// the live operator uses (so the stage path is REAL, not asserted), records each leg's endpoint,
    /// and returns ONE whole-turn egress verdict over the union of endpoints. The turn proceeds past
    /// STT only if the transcript is real speech (shouldAutoSend) — an empty capture or a bare wake
    /// echo ends the turn before the brain leg, and a turn that made zero calls is honestly on-device.
    /// FAILS CLOSED: on a local brain, the FIRST non-loopback endpoint across ANY leg (the brain OR
    /// the gated tool) makes the whole turn `.egressDetected`. PURE.
    static func run(_ plan: VoiceTurnPlan) -> VoiceTurnResult {
        var stage: VoiceStage = .idle
        var stages: [VoiceStage] = [stage]
        var steps: [VoiceTurnStep] = []

        // Leg 1 — WAKE: opens the turn from idle. Local audio, no endpoint.
        stage = VoiceOperator.next(stage, on: .wakeHeard); stages.append(stage)
        steps.append(VoiceTurnStep(leg: .wake, stage: stage, endpoint: nil))

        // Leg 2 — STT: on-device recognition (DictationPolicy, SV-23). No endpoint. Only a REAL
        // transcript advances the turn; an empty capture or a bare wake echo ends it here — before
        // the brain ever opens a socket — so the operator never loops on its own wake phrase.
        guard VoiceOperator.shouldAutoSend(transcript: plan.transcript, wakePhrase: plan.wakePhrase) else {
            steps.append(VoiceTurnStep(leg: .stt, stage: stage, endpoint: nil))   // captured in .listening
            stage = VoiceOperator.next(stage, on: .cancelled); stages.append(stage) // → idle, no brain leg
            return VoiceTurnResult(steps: steps, stages: stages,
                                   egress: VoiceEgress.turnEgress(provider: plan.provider, endpoints: []),
                                   completed: false)
        }
        steps.append(VoiceTurnStep(leg: .stt, stage: stage, endpoint: nil))       // captured in .listening
        stage = VoiceOperator.next(stage, on: .transcriptFinal(plan.transcript)); stages.append(stage) // → thinking

        // Leg 3 — BRAIN: the reply leg. The only always-present networked leg (loopback on a local brain).
        steps.append(VoiceTurnStep(leg: .brain, stage: stage, endpoint: plan.brainEndpoint))

        // Leg 4 — TOOL (optional, gated): only if the turn calls one; reaches the on-device daemon.
        if let tool = plan.toolEndpoint {
            steps.append(VoiceTurnStep(leg: .tool, stage: stage, endpoint: tool))
        }

        // Reply ready → speak it back, then the wake loop re-arms.
        stage = VoiceOperator.next(stage, on: .replyReady); stages.append(stage)   // → speaking
        // Leg 5 — TTS: AVSpeechSynthesizer, entirely on-device. No endpoint.
        steps.append(VoiceTurnStep(leg: .tts, stage: stage, endpoint: nil))
        stage = VoiceOperator.next(stage, on: .speechFinished); stages.append(stage) // → idle (re-armed)

        // WHOLE-TURN egress: ONE verdict over the UNION of every endpoint the turn touched — brain AND
        // the gated tool — so a regression in EITHER leg is caught, not just the brain's transport.
        let egress = VoiceEgress.turnEgress(provider: plan.provider, endpoints: steps.compactMap { $0.endpoint })
        return VoiceTurnResult(steps: steps, stages: stages, egress: egress, completed: true)
    }

    /// The honest one-line posture for a completed whole turn — surfaced as a receipt when the wake
    /// lane arms. Never a fabricated "offline" claim: the cloud route says the turn uses the buyer's
    /// connected account, and a tripped egress guard names the leaked host. §5.1.
    static func describe(_ result: VoiceTurnResult) -> String {
        switch result.egress {
        case .fullyOnDevice:
            let toolNote = result.steps.contains { $0.leg == .tool } ? " (including the gated tool call)" : ""
            return "This hands-free turn's core path used on-device or loopback processing: wake, speech-to-text, the local brain\(toolNote), and text-to-speech. Web research or connected tools may make separate network requests when used."
        case .brainReachesCloud:
            return "This hands-free turn uses your connected route: speech-to-text and text-to-speech stay on-device, while the provider or CLI you configured processes the reply."
        case .egressDetected(let host):
            return "Egress guard tripped: a leg of this local-brain turn would reach \(host), which is not loopback — the turn is NOT offline and was flagged instead of shipped as such."
        }
    }
}
