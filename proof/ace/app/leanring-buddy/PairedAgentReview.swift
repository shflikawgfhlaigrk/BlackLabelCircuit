import Foundation

nonisolated enum PairedAgentReviewPolicy {
    static func isRequested(in request: String) -> Bool {
        let normalized = request.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard normalized.range(
            of: #"\b(?:without|not\s+using|do\s+not\s+use|don't\s+use|never\s+use|instead\s+of|avoid)\b"#,
            options: .regularExpression
        ) == nil else { return false }
        guard normalized.range(
            of: #"\b(?:red(?:\s+agent)?\s+(?:and|&)\s+(?:the\s+)?silver|silver(?:\s+agent)?\s+(?:and|&)\s+(?:the\s+)?red)\b"#,
            options: .regularExpression
        ) != nil, let action = normalized.range(
            of: #"\b(?:scan|review|audit|inspect|check)\s+(?:yourself|ace|your\s+(?:own\s+)?(?:app|runtime|transcript|behavior))\b"#,
            options: .regularExpression
        ) else { return false }
        let prefix = String(normalized[..<action.lowerBound])
        return prefix.range(
            of: #"\b(?:don't|do not|never|not|why|when|did|explain|describe|how\s+to)\b"#,
            options: .regularExpression
        ) == nil
    }

    static func canReserveBoth(
        primarySlot: BackgroundExecutionSlot?,
        silverAgentIsActive: Bool,
        silverWorkflowIsActive: Bool,
        silverIsReserved: Bool
    ) -> Bool {
        primarySlot == .red && !silverAgentIsActive
            && !silverWorkflowIsActive && !silverIsReserved
    }

    static func instruction(ownerRequest: String, slot: BackgroundExecutionSlot) -> String {
        let focus = slot == .red
            ? "Trace the latest owner transcript failures through the current installed runtime, command routing, speech timing, and execution receipts."
            : "Independently inspect the current installed UI, pointing and motion behavior, conversation continuity, and cancellation boundaries against the latest owner transcript."
        return """
        The owner explicitly requested independent Red and Silver reviews of Ace. You are the \(slot.rawValue) reviewer; the app runs the other reviewer separately.
        \(focus)
        This is a read-only review. Read current local evidence; do not change source, settings, files, accounts, or UI, start a build, send messages, or spawn another agent. Identify the current /Applications/Ace.app build and distinguish observed installed failures from source-only findings. Do not inspect secrets. Prioritize concrete defects with exact supporting receipts. Never claim that Ace is perfect or that a repair passed without an observed result.
        Return OWNER with your most useful finding in at most two complete short sentences and 300 characters. EVIDENCE must retain the full findings and exact evidence. Name only your own completed review.
        Owner request:
        \(ownerRequest)
        """
    }

    static func combined(
        red: BackgroundAgentTerminalResult,
        silver: BackgroundAgentTerminalResult
    ) -> BackgroundAgentTerminalResult {
        if red.kind == .cancelled || silver.kind == .cancelled {
            return BackgroundAgentDeliveryPolicy.cancelled(
                reason: "The owner stopped the paired Red and Silver review."
            )
        }
        let evidence = "Red [\(red.kind.rawValue)]:\n\(red.reason)\n\nSilver [\(silver.kind.rawValue)]:\n\(silver.reason)"
        let summary = "Red: \(red.spokenSummary ?? red.reason) Silver: \(silver.spokenSummary ?? silver.reason)"
        let completed = red.kind == .completed && silver.kind == .completed
        return BackgroundAgentTerminalResult(
            kind: completed ? .completed : .failed,
            outcome: completed ? "completed.paired-review" : "failed.incomplete-paired-review",
            verification: completed ? "reported" : "none",
            reason: evidence,
            spokenSummary: completed ? summary : "The paired review is incomplete. " + summary
        )
    }
}

@MainActor
enum PairedAgentReviewRunner {
    static func run(
        isCurrent: @escaping @MainActor () -> Bool,
        red: @escaping @MainActor () async -> BackgroundAgentTerminalResult,
        silver: @escaping @MainActor () async -> BackgroundAgentTerminalResult
    ) async -> BackgroundAgentTerminalResult {
        guard isCurrent(), !Task.isCancelled else {
            return BackgroundAgentDeliveryPolicy.cancelled()
        }
        async let redResult = runIfCurrent(isCurrent, operation: red)
        async let silverResult = runIfCurrent(isCurrent, operation: silver)
        let results = await (redResult, silverResult)
        guard isCurrent(), !Task.isCancelled else {
            return BackgroundAgentDeliveryPolicy.cancelled()
        }
        return PairedAgentReviewPolicy.combined(red: results.0, silver: results.1)
    }

    private static func runIfCurrent(
        _ isCurrent: @MainActor () -> Bool,
        operation: @MainActor () async -> BackgroundAgentTerminalResult
    ) async -> BackgroundAgentTerminalResult {
        guard isCurrent(), !Task.isCancelled else {
            return BackgroundAgentDeliveryPolicy.cancelled()
        }
        return await operation()
    }
}
