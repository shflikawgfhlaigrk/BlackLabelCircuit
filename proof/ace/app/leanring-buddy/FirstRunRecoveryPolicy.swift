import Foundation

/// Value-only first-run decisions shared by setup and their offline recovery
/// tests. Keeping these predicates outside AppKit makes the clean-install
/// failure modes deterministic.
nonisolated enum FirstRunRecoveryPolicy {
    static let bundledVoiceIdentifier = "ace.voice.kokoro.v0_19.sid3"
    static let voiceInstructionName =
        "Ace Voice — built in"

    /// The signed app owns the voice runtime and model. A clean Mac must never
    /// be sent into System Settings or asked to download a speech asset.
    static let requiresExternalVoiceSettings = false

    static func shouldInterruptWithFailureAlert(
        interruptRequested: Bool,
        setupWindowIsVisible: Bool,
        walkthroughIsRunning: Bool,
        failureWasAlreadyAlerted: Bool,
        alertPresentationIsInFlight: Bool = false
    ) -> Bool {
        _ = (
            interruptRequested,
            setupWindowIsVisible,
            walkthroughIsRunning,
            failureWasAlreadyAlerted,
            alertPresentationIsInFlight
        )
        return false
    }

    static func requiredInteractionPermissionsAreReady(
        accessibility: Bool,
        screenRecording: Bool,
        microphone: Bool,
        screenContent: Bool,
        onDeviceSpeech: Bool
    ) -> Bool {
        accessibility
            && screenRecording
            && microphone
            && screenContent
            && onDeviceSpeech
    }

    static func isBundledVoiceReceipt(identifier: String) -> Bool {
        identifier == bundledVoiceIdentifier
    }

    static func visibleResponse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}
