// Sovereign — on-device AI engine via Apple FoundationModels.
// Guarded so the app compiles and runs regardless of OS / framework availability.
// When unavailable, the UI shows an HONEST "not available" state — never a fake reply.
//
// Capabilities: streaming token-by-token responses, cancellation, session prewarm,
// per-conversation persona/instructions, grounding context from the buyer's own data,
// and a structured single-shot helper used by Skills/Automations. Nothing is fabricated:
// if the model is unavailable, callers receive an honest error, never invented text.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIAvailability: Equatable {
    case ready
    case unavailable(String)
}

/// A simple string-carrying error so `complete()` can return a human-readable failure
/// via `Result`. The message is always honest (a real framework error or "unavailable").
struct AIError: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

@MainActor
final class AIEngine: ObservableObject {
    @Published var availability: AIAvailability = .unavailable("Checking on-device model…")
    @Published var thinking = false
    @Published var lastError: String?

    // A stored property cannot be typed as a @available-only type — cache as Any?
    // and cast to LanguageModelSession only inside the @available guarded branch.
    private var sessionBox: Any?
    private var streamTask: Task<Void, Never>?

    var isReady: Bool { if case .ready = availability { return true } else { return false } }

    init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                availability = .ready
            case .unavailable(let reason):
                availability = .unavailable(Self.describe(reason))
            @unknown default:
                availability = .unavailable("On-device model not available on this device.")
            }
        } else {
            #if os(macOS)
            availability = .unavailable("On-device AI requires macOS 26 or later. This Mac runs an earlier version.")
            #else
            availability = .unavailable("On-device AI requires iOS 26 or later. This device runs an earlier version.")
            #endif
        }
        #else
        availability = .unavailable("On-device model not available on this device.")
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac isn't eligible for Apple Intelligence on-device models."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to use Sovereign's on-device AI."
        case .modelNotReady:
            return "The on-device model is downloading or preparing. Try again shortly."
        @unknown default:
            return "On-device model not available on this device."
        }
    }

    // The buyer's effective system prompt the session was built with. When the buyer
    // edits their persona/instructions in Settings, we rebuild the session.
    private var currentInstructions = ""

    @available(macOS 26, iOS 26, *)
    private func session(instructions: String) -> LanguageModelSession {
        if let s = sessionBox as? LanguageModelSession, instructions == currentInstructions { return s }
        let s = LanguageModelSession(instructions: instructions)
        sessionBox = s
        currentInstructions = instructions
        return s
    }
    #endif

    /// Warm the model so the first token arrives faster. Safe no-op when unavailable.
    func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), isReady {
            session(instructions: currentInstructions.isEmpty ? "You are a helpful on-device assistant." : currentInstructions).prewarm()
        }
        #endif
    }

    private func buildInstructions(system: String, grounding: String) -> String {
        grounding.isEmpty
            ? system
            : system + "\n\nGrounding context (the user's own private notes & documents — use only if relevant, never invent):\n" + grounding
    }

    /// STREAMING response. `onToken` fires repeatedly with the cumulative text so far;
    /// `onDone` fires once with the final text (or nil if cancelled/failed — lastError is set on failure).
    func stream(prompt: String, system: String, grounding: String = "",
                onToken: @escaping (String) -> Void,
                onDone: @escaping (String?) -> Void) {
        lastError = nil
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), isReady {
            thinking = true
            let instructions = buildInstructions(system: system, grounding: grounding)
            let session = self.session(instructions: instructions)
            streamTask?.cancel()
            streamTask = Task { @MainActor in
                var full = ""
                do {
                    let stream = session.streamResponse(to: prompt)
                    for try await snapshot in stream {
                        if Task.isCancelled { break }
                        full = snapshot.content   // cumulative for <String> streams
                        onToken(full)
                    }
                    self.thinking = false
                    if Task.isCancelled { onDone(full.isEmpty ? nil : full) }
                    else { onDone(full) }
                } catch is CancellationError {
                    self.thinking = false; onDone(full.isEmpty ? nil : full)
                } catch {
                    self.thinking = false
                    self.lastError = "The on-device model couldn't complete that request: \(error.localizedDescription)"
                    onDone(nil)
                }
            }
            return
        }
        #endif
        lastError = "On-device model not available on this device."
        onDone(nil)
    }

    /// Non-streaming single-shot — used by Skills/Automations that need a complete result.
    /// Uses a FRESH ephemeral session so it never pollutes the chat session's context.
    func complete(prompt: String, system: String, onResult: @escaping (Result<String, AIError>) -> Void) {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), isReady {
            Task { @MainActor in
                do {
                    let s = LanguageModelSession(instructions: system)
                    let r = try await s.respond(to: prompt)
                    onResult(.success(r.content))
                } catch {
                    onResult(.failure(AIError(message: "The on-device model couldn't complete that request: \(error.localizedDescription)")))
                }
            }
            return
        }
        #endif
        onResult(.failure(AIError(message: "On-device model not available on this device.")))
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        thinking = false
    }

    func resetSession() {
        cancel()
        sessionBox = nil
        currentInstructions = ""
    }
}

// MARK: - SV-21 first-run availability probe + honest gate copy

extension AIEngine {
    /// The single, honest, buyer-facing line shown when Apple's on-device model can't be the
    /// ZERO-SETUP first-run default. It names the REAL requirement (Apple Intelligence on Apple
    /// silicon) and states the free-local-brain fallback — it NEVER implies that offline Apple
    /// AI is available on unsupported hardware, and it never calls the download "bundled".
    /// §5.1 no fabricated capability.
    nonisolated static let appleUnavailableFallbackNote =
        "Apple\u{2019}s on-device model needs Apple Intelligence on Apple silicon — setting up the free local brain (a one-time download) instead."

    /// Is Apple's FoundationModels on-device brain usable RIGHT NOW (Apple silicon + Apple
    /// Intelligence enabled + model ready)? This is the one probe the first-run default decision
    /// reads to choose the zero-setup Apple path vs. the bundled-local Ornith fallback.
    var foundationModelsAvailable: Bool { isReady }
}
