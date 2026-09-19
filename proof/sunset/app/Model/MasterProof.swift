// MasterProof.swift — SS-21: the unified Explainable-Master Proof surface.
//
// Composes the four proof primitives Sunset already computes on the buyer's own audio into ONE titled,
// exportable proof:
//   • Report Card (SS-16) — measured before→after LUFS / true-peak / range / crest + chain notes
//   • Gain-matched A/B (SS-17) — equal-loudness compare (tone, not level)
//   • Hear-what-changed delta (SS-18) — the sample-aligned, loudness-matched residual
//   • PSR over-limit read (SS-19) — true-peak minus short-term LUFS, with the measured <8 dB flag
//
// Measurement + chain notes only. Like the Report Card and the PSR read, it STATES the numbers and what
// the chain did — it never prescribes (no advice-imperatives; Charter §5.1, the SS-16 rule).

import Foundation

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct MasterProof {
    var title: String
    var reportCard: ReportCard
    var psr: PSRReport
    var abLine: String
    var deltaLine: String
    /// The single exportable proof rendering (report card + PSR + the two audition proofs).
    var text: String

    static func compose(master: MasterResult, label: String) -> MasterProof {
        let card = ReportCard.compose(master: master, label: label)
        let psr = master.psr
        let ab = "Equal-loudness A/B — original and master are compared at a matched integrated LUFS "
               + "(the louder path is attenuated by a measured offset), so the comparison is tone, not level."
        let delta = "Hear what changed — the residual (master minus original, sample-aligned and "
                  + "loudness-matched) isolates exactly what the chain added or removed."

        let title = "Explainable Master — Proof — \(label)"
        var lines: [String] = [title, String(repeating: "═", count: min(64, max(28, title.count))), ""]

        // 1. Report Card — the measured before→after table and the chain moves.
        lines.append(card.text)
        lines.append("")

        // 2. PSR — the loudness-aware over-limit read (measurement; the <8 dB flag is a measured fact).
        lines.append("Dynamics (PSR):")
        lines.append("  • " + (psr.hasData ? psr.note : "No measurable loudness — PSR not computed."))
        lines.append("")

        // 3 + 4. The two audition proofs the buyer can play in-app for this same master.
        lines.append("Listen for yourself (in-app):")
        lines.append("  • " + ab)
        lines.append("  • " + delta)
        lines.append("")

        lines.append("Every value above is measured on your own audio by Sunset's local DSP "
                     + "(BS.1770 loudness, oversampled true-peak, peak-to-RMS crest, PSR). Nothing is "
                     + "estimated; nothing is uploaded.")

        return MasterProof(title: title, reportCard: card, psr: psr, abLine: ab, deltaLine: delta,
                           text: lines.joined(separator: "\n"))
    }
}
#endif // circuit-convert
