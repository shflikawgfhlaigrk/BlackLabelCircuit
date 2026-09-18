#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MetersView: loudness readouts (LUFS/TP/LRA/peak, before -> after) and a per-platform playback report.
//
// Rendered inside the dashboard's "Meters" StudioPanel, usually at half the center-column
// width — so this view speaks the SD studio idiom (no legacy Card chrome, which doubled the
// headers in a foreign theme) and uses flexible rows only: fixed column widths clipped the
// values at the 1180pt minimum window.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// Numeric mastering report. Reads the before/after LoudnessResult and the platform table
/// off MasterResult; flags true peak red when it exceeds the selected platform's ceiling.
struct MetersView: View {
    let result: MasterResult
    let platform: PlatformTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionCaption("Loudness — before → after (BS.1770)")
            VStack(spacing: 6) {
                row("Integrated", result.before.integratedLUFS, result.after.integratedLUFS, "LUFS")
                row("Short-term max", result.before.shortTermMaxLUFS, result.after.shortTermMaxLUFS, "LUFS")
                row("Loudness range", result.before.loudnessRangeLU, result.after.loudnessRangeLU, "LU")
                // True peak turns red when the finished master sits above the platform ceiling.
                row("True peak", result.before.truePeakDBTP, result.after.truePeakDBTP, "dBTP",
                    afterIsHot: result.after.truePeakDBTP > platform.truePeakDBTP + 0.01)
                row("Sample peak", result.before.samplePeakDBFS, result.after.samplePeakDBFS, "dBFS")
            }
            Text("Target \(fmt(platform.lufs)) LUFS · ceiling \(fmt(platform.truePeakDBTP)) dBTP — \(platform.name)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(SD.dim)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(SD.line)

            sectionCaption("How platforms will play this")
            platformTable
        }
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .foregroundColor(SD.dim)
    }

    // MARK: - Loudness row

    private func row(_ label: String, _ before: Double, _ after: Double, _ unit: String,
                     afterIsHot: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(SD.text)
            Spacer(minLength: 6)
            (Text("\(fmt(before)) → ").foregroundColor(SD.dim)
             + Text(fmt(after)).foregroundColor(afterIsHot ? SD.red : SD.gold)
             + Text(" \(unit)").foregroundColor(SD.dim))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .lineLimit(1)
        }
    }

    // MARK: - Platform table

    private var platformTable: some View {
        VStack(alignment: .leading, spacing: 7) {
            if result.platformReport.isEmpty {
                Text("No platform report.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(SD.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(result.platformReport.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(r.platform)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(SD.goldText)
                            Spacer(minLength: 6)
                            Text("\(fmt(r.willPlayAtLUFS)) LUFS")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(SD.gold)
                                .lineLimit(1)
                        }
                        // The action gets its own line so it never clips at narrow widths.
                        Text(r.action)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(SD.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func fmt(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        return String(format: "%+.1f", v)
    }
}
#endif // circuit-convert
