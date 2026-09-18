import Foundation

nonisolated enum OwnerCorrectionKind: String, Codable, Equatable, Sendable {
    case retry
    case amendment
}

/// Exact, app-owned continuation data. Executable corrections have a separate
/// limit from terminal summaries and are rejected, never truncated.
nonisolated struct OwnerCorrectionContext: Codable, Equatable, Sendable {
    static let maximumFieldCharacters = 1_200
    static let maximumOwnerCorrectionCharacters = 8_000
    static let maximumExecutableRequestCharacters = 32_000

    let kind: OwnerCorrectionKind
    let ownerCorrection: String
    let priorTerminalOutcome: String?
    let priorTerminalVerification: String?
    let priorTerminalReason: String?

    var isValid: Bool {
        !ownerCorrection.isEmpty
            && ownerCorrection.count <= Self.maximumOwnerCorrectionCharacters
            && (priorTerminalOutcome?.count ?? 0)
                <= Self.maximumFieldCharacters
            && (priorTerminalVerification?.count ?? 0)
                <= Self.maximumFieldCharacters
            && (priorTerminalReason?.count ?? 0)
                <= Self.maximumFieldCharacters
    }

    func executionInstruction(objective: String) -> String {
        var fields = [
            "ORIGINAL OBJECTIVE:\n" + objective,
            "OWNER CORRECTION KIND:\n" + kind.rawValue,
            "OWNER CORRECTION:\n" + ownerCorrection,
        ]
        if let priorTerminalOutcome {
            fields.append(
                "PRIOR APP-OBSERVED OUTCOME:\n" + priorTerminalOutcome
            )
        }
        if let priorTerminalVerification {
            fields.append(
                "PRIOR APP-OBSERVED VERIFICATION:\n"
                    + priorTerminalVerification
            )
        }
        if let priorTerminalReason {
            fields.append(
                "PRIOR APP-OBSERVED REASON:\n" + priorTerminalReason
            )
        }
        fields.append(
            kind == .retry
                ? "Continue the same exact work lineage. Re-read the bound target before retrying and preserve any completed steps. If a prior effect is present or its outcome is uncertain, report the evidence and stop instead of repeating that effect. Retry only the remaining original objective and verify the result."
                : "Continue the same exact work lineage and apply the owner's correction to the original objective. Re-read the bound target's current state and preserve steps already completed. A request to submit an existing draft changes its prior leave-unsent instruction; do not retype or duplicate the draft. If submission already occurred or its outcome is unclear, report that state instead of submitting again."
        )
        return fields.joined(separator: "\n\n")
    }
}
