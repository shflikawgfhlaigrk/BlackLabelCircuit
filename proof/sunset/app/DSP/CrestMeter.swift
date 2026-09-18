// CrestMeter.swift — punch / crest-factor read-out, input vs output.
//
// Crest factor = peak − RMS (dB): how far the loudest instants sit above the average
// level. High crest = punchy, dynamic; low crest = flat, limited. Sunset measures it on
// the buyer's INPUT and on the finished master so the buyer can see exactly how much
// punch the chain kept or spent.
//
// The one editorial call — encoded as MEASUREMENT, not advice (Charter §5.1): when the
// INPUT crest is already low, the loudness was baked in upstream (the mix bus was
// smashed before it reached mastering), so there is little transient left to preserve.
// Sunset states that as a measured fact; it does not tell the buyer what to do about it.

import Foundation

/// Measured crest factor of input vs output, with a neutral note about upstream limiting.
struct CrestReport {
    var hasData: Bool
    var inputCrestDB: Double     // peak − RMS of the buyer's input
    var outputCrestDB: Double    // peak − RMS of the finished master
    var deltaDB: Double          // output − input (negative = crest spent by the chain)
    var inputHeavilyLimited: Bool
    var rows: [AnalysisRow]
    var note: String             // neutral measurement statement (empty if nothing notable)

    static let empty = CrestReport(hasData: false, inputCrestDB: 0, outputCrestDB: 0,
                                   deltaDB: 0, inputHeavilyLimited: false, rows: [], note: "")
}

enum CrestMeter {

    /// Below this crest (dB), the input's loudness was measurably limited upstream.
    /// A dynamic mix runs 12–20 dB; a smashed master bus can sit near a full-scale
    /// sine's 3 dB. 6 dB is a conservative line between the two.
    static let limitedThresholdDB = 6.0

    /// Overall crest factor (peak dBFS − RMS dBFS) across all channels of a signal.
    static func crestDB(_ s: AudioSignal) -> Double {
        let peak = s.peakDBFS()
        let rms = overallRMSDBFS(s)
        guard peak > -199, rms > -199 else { return 0 }
        return max(0.0, peak - rms)
    }

    /// RMS (dBFS) over every sample of every channel.
    static func overallRMSDBFS(_ s: AudioSignal) -> Double {
        var sumSq = 0.0
        var count = 0
        for ch in s.channels {
            for v in ch { let d = Double(v); sumSq += d * d }
            count += ch.count
        }
        guard count > 0 else { return -200 }
        let rms = (sumSq / Double(count)).squareRoot()
        return rms > 1e-12 ? max(-200, 20 * log10(rms)) : -200
    }

    /// Measure input vs output crest and produce the neutral read-out.
    static func measure(input: AudioSignal, output: AudioSignal) -> CrestReport {
        guard input.frameCount > 0, output.frameCount > 0 else { return .empty }
        let inC = crestDB(input)
        let outC = crestDB(output)
        let delta = outC - inC
        let limited = inC < limitedThresholdDB

        var rows: [AnalysisRow] = [
            AnalysisRow(label: "Input crest", value: String(format: "%.1f dB", inC), flagged: limited),
            AnalysisRow(label: "Output crest", value: String(format: "%.1f dB", outC), flagged: false),
            AnalysisRow(label: "Δ crest", value: String(format: "%+.1f dB", delta), flagged: false),
        ]

        var note = ""
        if limited {
            note = String(format: "Input crest factor is %.1f dB (peak-to-RMS). Values this low mean the loudness was already limited upstream — little transient is left to preserve.", inC)
            rows[0].flagged = true
        }
        return CrestReport(hasData: true, inputCrestDB: inC, outputCrestDB: outC,
                           deltaDB: delta, inputHeavilyLimited: limited, rows: rows, note: note)
    }
}

// MARK: - PSR (Peak to Short-term loudness Ratio)
//
// PSR is the loudness-aware dynamics read used across modern mastering (Music-Mastering /
// AES streaming-loudness practice). Unlike raw crest (peak − RMS), PSR measures the finished
// master's true peak against its LOUDEST 3 s of K-weighted short-term loudness:
//
//     PSR = truePeak(dBTP) − shortTermMax(LUFS)
//
// A master that kept its transients runs PSR ≳ 8 dB; below ~8 the loudness was pushed at the
// cost of punch — the honest signature of over-limiting ("crushed"/"robotic" masters, the most-
// repeated complaint about one-click cloud mastering). Sunset states PSR as a MEASUREMENT and
// raises the <8 flag as a measured fact — never advice, never a fabricated number (Charter §5.1).

/// Measured PSR of the finished master, with the honest over-limit flag.
struct PSRReport {
    var hasData: Bool
    var psrDB: Double         // truePeak(dBTP) − shortTermMax(LUFS)
    var truePeakDBTP: Double
    var shortTermLUFS: Double
    var overLimited: Bool     // psrDB < PunchGate.psrWarnDB
    var row: AnalysisRow
    var note: String

    static let empty = PSRReport(hasData: false, psrDB: 0, truePeakDBTP: 0, shortTermLUFS: 0,
                                 overLimited: false,
                                 row: AnalysisRow(label: "PSR", value: "—", flagged: false), note: "")
}

enum PunchGate {

    /// Below this PSR (dB) the master is measurably over-limited (crushed dynamics).
    /// 8 dB is the widely used mastering line between a "loud but breathing" master and a
    /// smashed one; labeled as industry practice, not an official spec (⛔H5).
    static let psrWarnDB = 8.0

    /// Compute PSR from the finished master's BS.1770 loudness read. Returns `.empty` when the
    /// master carries no measurable loudness (silence / no input) so nothing is fabricated.
    static func psr(master: LoudnessResult) -> PSRReport {
        guard master.truePeakDBTP > -120, master.shortTermMaxLUFS > -70 else { return .empty }
        let value = master.truePeakDBTP - master.shortTermMaxLUFS
        let over = value < psrWarnDB
        let note: String
        if over {
            note = String(format: "PSR is %.1f dB (true peak %.1f dBTP − short-term %.1f LUFS). Under 8 dB (industry practice) means the master is over-limited — loudness was pushed at the cost of transients.",
                          value, master.truePeakDBTP, master.shortTermMaxLUFS)
        } else {
            note = String(format: "PSR is %.1f dB (true peak %.1f dBTP − short-term %.1f LUFS) — transients preserved (target ≳ 8 dB, industry practice).",
                          value, master.truePeakDBTP, master.shortTermMaxLUFS)
        }
        let row = AnalysisRow(label: "PSR", value: String(format: "%.1f dB", value), flagged: over)
        return PSRReport(hasData: true, psrDB: value, truePeakDBTP: master.truePeakDBTP,
                         shortTermLUFS: master.shortTermMaxLUFS, overLimited: over, row: row, note: note)
    }
}
