#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// ReportCard.swift — SS-16: one readable, titled per-master card that composes the chain's own
// measured before/after numbers (integrated LUFS, true peak dBTP, loudness range, crest) plus the
// plain-English chain notes into a single surface you can export to text or render to an image.
//
// Measurement only — the same rule as the PSR read (SS-19): it STATES what the numbers are, it never
// tells the buyer what they "should" do. Every value traces to LoudnessMeter / CrestMeter on the
// buyer's own audio; nothing is fabricated and there are no advice-imperatives.

import Foundation

struct ReportCard {

    /// One before→after row. `delta` is the signed change (after − before), pre-formatted.
    struct Metric: Identifiable {
        var id: String { label }
        var label: String
        var unit: String
        var before: String
        var after: String
        var delta: String
    }

    var title: String
    var metrics: [Metric]
    var chainNotes: [String]

    /// The export-to-text rendering (also what an image render draws from).
    var text: String

    /// Compose a card from a finished master. `label` is the track name shown in the title.
    static func compose(master: MasterResult, label: String) -> ReportCard {
        let b = master.before, a = master.after

        func row(_ name: String, _ unit: String, _ before: Double, _ after: Double,
                 fmt: String = "%.1f") -> Metric {
            let d = after - before
            return Metric(label: name, unit: unit,
                          before: fin(before) ? String(format: fmt, before) : "—",
                          after: fin(after) ? String(format: fmt, after) : "—",
                          delta: (fin(before) && fin(after)) ? String(format: "%+.1f", d) : "—")
        }

        var metrics: [Metric] = [
            row("Integrated loudness", "LUFS", b.integratedLUFS, a.integratedLUFS),
            row("True peak", "dBTP", b.truePeakDBTP, a.truePeakDBTP),
            row("Loudness range", "LU", b.loudnessRangeLU, a.loudnessRangeLU)
        ]
        // Crest (punch) is measured input→output by CrestMeter; only shown when it has real data.
        if master.crest.hasData {
            metrics.append(Metric(label: "Crest (peak-to-RMS)", unit: "dB",
                                  before: String(format: "%.1f", master.crest.inputCrestDB),
                                  after:  String(format: "%.1f", master.crest.outputCrestDB),
                                  delta:  String(format: "%+.1f", master.crest.deltaDB)))
        }

        let title = "Sunset Report Card — \(label)"
        var lines: [String] = [title, String(repeating: "─", count: min(60, max(24, title.count))), ""]
        let nameW = metrics.map { $0.label.count }.max() ?? 20
        func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
            s.count >= w ? s : (right ? s + String(repeating: " ", count: w - s.count)
                                      : String(repeating: " ", count: w - s.count) + s)
        }
        for m in metrics {
            let name = pad(m.label, nameW, right: true)
            lines.append("\(name)   \(pad(m.before, 8)) → \(pad(m.after, 8)) \(pad(m.unit, 5, right: true))  (\(m.delta))")
        }
        lines.append("")
        lines.append("Chain (measured):")
        for note in master.notes { lines.append("  • " + note) }
        lines.append("")
        lines.append("All values measured on your own audio by Sunset's local DSP (BS.1770 loudness, "
                     + "oversampled true-peak, peak-to-RMS crest). No numbers are estimated.")

        return ReportCard(title: title, metrics: metrics, chainNotes: master.notes,
                          text: lines.joined(separator: "\n"))
    }

    private static func fin(_ x: Double) -> Bool { !x.isNaN && !x.isInfinite }
}
#endif // circuit-convert
