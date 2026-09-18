#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// Persistent recovery surface for failures whose modal alert is intentionally
/// suppressed while setup or another guided walkthrough is already visible.
/// Every card invokes the exact handler owned by `FirstRunFailureReporter`.
struct FirstRunFailureRecoveryView: View {
    @ObservedObject var reporter: FirstRunFailureReporter
    var compact = false

    var body: some View {
        if !reporter.activeFailures.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                ForEach(reporter.activeFailures) { failure in
                    recoveryCard(for: failure)
                }
            }
            .padding(.horizontal, compact ? 16 : 28)
            .padding(.vertical, compact ? 10 : 12)
            .accessibilityIdentifier("ace.first-run-failures")
        }
    }

    private func recoveryCard(for failure: FirstRunFailure) -> some View {
        let repairState = reporter.repairState(for: failure.id)
        // A repair can hold this button inert for minutes (the install poll
        // runs up to 600s). Build 64 kept it drawn at full accent strength the
        // whole time, so an owner clicking a live-looking primary button got
        // nothing back. The disabled state is now visible, not just enforced.
        let repairIsInert = repairState.isRunning || repairState.proof != nil
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                .foregroundColor(DS.Colors.warning)

            VStack(alignment: .leading, spacing: 3) {
                Text(failure.summary)
                    .font(.system(
                        size: compact ? 11 : 12,
                        weight: .semibold
                    ))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let remedy = failure.remedy {
                    Text(remedy)
                        .font(.system(size: compact ? 10 : 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let visibleRepairStatus = repairState.visibleStatus {
                    HStack(spacing: 6) {
                        if repairState.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(visibleRepairStatus)
                            .font(.system(
                                size: compact ? 10 : 11,
                                weight: .semibold
                            ))
                            .foregroundColor(
                                repairState.proof == nil
                                    ? DS.Colors.warning
                                    : DS.Colors.success
                            )
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "ace.recovery.\(failure.id).state"
                    )
                    .accessibilityValue(
                        repairState.accessibilityValue
                    )
                }
            }

            Spacer(minLength: 8)

            if let actionTitle = reporter.repairButtonTitle(
                for: failure.id
            ) {
                AceTrackedButton(action: {
                        // The Bool is load-bearing. Build 64 fixed the alert
                        // caller and left this one discarding it — and this is
                        // the ONLY repair surface during first run, because
                        // alerts are suppressed while setup is on screen. A
                        // refused click has to say so on screen, not just in a
                        // log nobody opens.
                        if !reporter.performRepair(identifier: failure.id) {
                            reporter.publishRepairNotAdmitted(
                                identifier: failure.id
                            )
                        }
                    }) {
                    Text(actionTitle)
                        .font(.system(
                            size: compact ? 10 : 11,
                            weight: .semibold
                        ))
                        .foregroundColor(
                            repairIsInert
                                ? DS.Colors.textTertiary
                                : DS.Colors.textOnAccent
                        )
                        .padding(.horizontal, compact ? 10 : 12)
                        .padding(.vertical, compact ? 7 : 8)
                        .background(
                            Capsule().fill(
                                repairIsInert
                                    ? DS.Colors.surface4
                                    : DS.Colors.accent
                            )
                        )
                }
                .accessibilityIdentifier(
                    "ace.recovery.\(failure.id)"
                )
                .disabled(repairIsInert)
                .accessibilityValue(
                    repairState.accessibilityValue
                )
            }
        }
        .padding(compact ? 10 : 12)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 12)
                .fill(DS.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 10 : 12)
                        .stroke(DS.Colors.warning.opacity(0.35), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "ace.first-run-failure.\(failure.id)"
        )
    }
}
#endif // circuit-convert
