import Foundation

/// Retained fail-closed boundary for older remote-transcription receipts and
/// their regression tests. The current shipping recognizer is on-device, but a
/// stale or future provider must never transmit after either stop signal.
nonisolated enum AssemblyAITransmissionPolicy {
    static func allowsSend(
        stealthEntryIsRaised: Bool,
        sessionIsStopped: Bool
    ) -> Bool {
        !stealthEntryIsRaised && !sessionIsStopped
    }
}
