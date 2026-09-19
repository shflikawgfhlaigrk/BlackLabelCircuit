#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
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

/// First-run brain AUTO-SETUP — the one place that turns a fresh install into a working local brain
/// WITHOUT sending a non-technical buyer into Settings. It drives the honest flow
///   detect Ollama → (guide the one free helper install) → live-progress pull → select,
/// and — dad-simple — AUTO-CONTINUES the instant Ollama appears, so the buyer only ever taps
/// "Download". §5.1: every state reflects a real probe/pull. `.ready` is published ONLY after Ollama
/// confirms the model is actually installed; nothing here is ever faked or optimistic.
///
/// Ornith is Sovereign's shipped default brain (Founder 2026-07-09): there is NO engine-selection
/// step on the main path — reaching this step just sets Ornith up. The buyer's own Claude/Codex
/// account stays available as a documented ADVANCED route (a small secondary link), never in the way.
@MainActor
final class OrnithSetupModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case checking                       // probing the buyer's own Ollama daemon (:11434)
        case needsHelper(reason: String)    // Ollama not running yet — show the one free-helper install
        case pulling                        // downloading the Ornith GGUF into the buyer's Ollama
        case ready(model: String)           // confirmed installed + selected — the "you're ready" state
        case failed(reason: String)         // an honest error the buyer can retry from
    }

    @Published var phase: Phase = .idle
    @Published var progress = OllamaBrain.PullProgress()

    private let ollama = OllamaBrain()
    private var pollTask: Task<Void, Never>?

    /// PURE, unit-testable decision: given a liveness-probe result, which phase do we move to next?
    /// Reachable ⇒ pull straight away; unreachable ⇒ guide the free-helper install first. No
    /// fabrication — an unreachable daemon never yields anything but `.needsHelper`.
    static func nextPhase(reachable: Bool, reason: String = "") -> Phase {
        reachable
            ? .pulling
            : .needsHelper(reason: reason.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Sovereign is waiting for the free helper to finish installing."
                : reason)
    }

    /// True while a probe or download is actively running (used to debounce taps).
    var isBusy: Bool {
        switch phase { case .checking, .pulling: return true; default: return false }
    }

    /// Honest one-line status under the progress bar: Ollama's own phase text + real byte counts.
    /// Never fabricated — if the daemon hasn't reported a total yet, we just show its phase word.
    var progressLabel: String {
        let p = progress
        let phaseText = p.status.isEmpty ? "starting…" : p.status
        if p.total > 0 {
            let f = ByteCountFormatter(); f.countStyle = .file
            let pct = Int((p.fraction ?? 0) * 100)
            return "\(phaseText) — \(f.string(fromByteCount: p.completed)) / \(f.string(fromByteCount: p.total)) (\(pct)%)"
        }
        return phaseText
    }

    /// Begin the whole flow. Probes Ollama; if it's up, pulls Ornith immediately; if not, shows the
    /// free-helper guide AND starts an auto-detect poll so the buyer only has to install the helper —
    /// Sovereign continues to the download on its own the moment the helper is running.
    func begin(settings: AppSettings, brain: BrainRouter) {
        guard !isBusy else { return }
        pollTask?.cancel()
        phase = .checking
        progress = OllamaBrain.PullProgress()
        Task { @MainActor in
            let up = await OllamaBrain.quickReachable()
            if up {
                await pull(settings: settings, brain: brain)
            } else {
                phase = .needsHelper(reason: "")
                startAutoDetect(settings: settings, brain: brain)
            }
        }
    }

    /// Manual retry (also the "I installed it" button). Cancels any poll and restarts the probe.
    func retry(settings: AppSettings, brain: BrainRouter) {
        pollTask?.cancel()
        phase = .idle
        begin(settings: settings, brain: brain)
    }

    /// Stop the background auto-detect poll (called when the onboarding step goes away).
    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    /// While waiting on the free-helper install, re-probe every few seconds and auto-continue to the
    /// pull the instant Ollama answers — the buyer never has to press a "retry" button.
    private func startAutoDetect(settings: AppSettings, brain: BrainRouter) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)   // 3s between probes
                if Task.isCancelled { return }
                guard case .needsHelper = phase else { return }     // buyer moved on / retried
                if await OllamaBrain.quickReachable() {
                    await pull(settings: settings, brain: brain)
                    return
                }
            }
        }
    }

    /// Pull the fitting Ornith tag via /api/pull (streaming real progress), confirm it's actually
    /// installed, then select it as the active brain. Never claims success on faith.
    private func pull(settings: AppSettings, brain: BrainRouter) async {
        let variant = settings.ornithVariant
        let tag = variant.ollamaTag
        phase = .pulling
        do {
            try await ollama.pull(model: tag) { p in
                Task { @MainActor in self.progress = p }
            }
            let installed = (try? await ollama.listModels()) ?? []
            let match = installed.first(where: { $0.name == tag })
                ?? installed.first(where: { OrnithRecommended.matches($0.name) && OrnithRecommended.variantHint($0.name) == variant })
                ?? installed.first(where: { OrnithRecommended.matches($0.name) })
            guard let picked = match else {
                phase = .failed(reason: "The download finished but the model isn't listed in Ollama yet. Click Try again.")
                return
            }
            settings.ollamaModel = picked.name
            settings.brainProvider = .ollama    // Ornith is the shipped default — select it, no picker
            brain.resolve()
            phase = .ready(model: picked.name)
        } catch {
            let msg = (error as? OllamaBrain.Failure)?.message ?? error.localizedDescription
            phase = .failed(reason: msg)
        }
    }
}
#endif // circuit-convert
