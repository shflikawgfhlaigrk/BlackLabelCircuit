// LowEndAnalyzer.swift — measured low-end clarity read-out for the analysis panel.
//
// Analyses the BUYER'S OWN track only (Charter §5.2 / §5.1). Every value is measured
// from the sample data — the fundamental, the sub-rumble, the mud band, the harshness
// band, and the stereo behaviour of the lows. Nothing is prescriptive: each surfaced
// flag is phrased as a measurement ("−3.2 dB correlation below 120 Hz"), never a
// judgment or an invented recommendation.

import Foundation

/// One labelled measurement for display; `flagged` = the value crossed a neutral threshold.
struct AnalysisRow: Identifiable, Equatable {
    var label: String
    var value: String
    var flagged: Bool
    var id: String { label }
}

/// Measured low-end clarity of a signal. All fields come from real DSP over the audio.
struct LowEndReport {
    var hasData: Bool
    var fundamentalHz: Double        // strongest low-frequency partial, 30–200 Hz
    var subBelow30RelDB: Double      // energy < 30 Hz relative to the 30–120 Hz band
    var rumbleFlag: Bool
    var mudBandRelDB: Double         // 200–350 Hz density relative to the 100–1500 Hz average
    var mudFlag: Bool
    var harshnessRelDB: Double       // 6–8 kHz density relative to the 1–4 kHz average
    var harshFlag: Bool
    var lowCorrelation: Double       // L/R correlation below 120 Hz (+1 = mono, 0 = wide)
    var lowSideMidDB: Double         // side-to-mid energy below 120 Hz, dB
    var wideSubFlag: Bool
    var isMono: Bool

    /// Display rows (label → measured value), the flagged ones highlighted in the UI.
    var rows: [AnalysisRow]
    /// Neutral measurement statements worth surfacing (only the flagged findings).
    var flags: [String]

    static let empty = LowEndReport(
        hasData: false, fundamentalHz: 0, subBelow30RelDB: -120, rumbleFlag: false,
        mudBandRelDB: -120, mudFlag: false, harshnessRelDB: -120, harshFlag: false,
        lowCorrelation: 1, lowSideMidDB: -120, wideSubFlag: false, isMono: true,
        rows: [], flags: [])
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum LowEndAnalyzer {

    // Neutral thresholds — chosen to flag disproportion, not to prescribe a fix.
    private static let rumbleThreshDB = -10.0   // sub-30 within 10 dB of the kick band
    private static let mudThreshDB    = 3.0     // 200–350 Hz 3 dB hotter than the broadband average
    private static let harshThreshDB  = 3.0     // 6–8 kHz 3 dB hotter than the presence average
    private static let wideSubCorr    = 0.6     // below this, the lows are measurably not near-mono

    /// Measure the low-end clarity of the buyer's own signal.
    static func analyze(_ s: AudioSignal) -> LowEndReport {
        let n = s.frameCount
        let ch = s.channelCount
        let sr = s.sampleRate > 0 ? s.sampleRate : 44_100
        guard n > 0, ch > 0 else { return .empty }

        // --- spectral fingerprint of the mono sum (fine low-freq resolution) ---
        let mono = monoSum(s)
        let fftSize = 16_384
        let analyzer = FFTAnalyzer(size: fftSize)
        let power = analyzer.averagePower(mono)           // linear power per bin
        let size = analyzer.size

        // Fundamental: strongest partial in 30–200 Hz, parabolically interpolated.
        let fundamentalHz = peakFrequency(power: power, sampleRate: sr, fftSize: size, lo: 30, hi: 200)

        // Band densities (mean power per bin → fair narrow-vs-wide comparison).
        let sub    = bandMeanPower(power, sr: sr, size: size, lo: 8,    hi: 30)
        let kick   = bandMeanPower(power, sr: sr, size: size, lo: 30,   hi: 120)
        let mud    = bandMeanPower(power, sr: sr, size: size, lo: 200,  hi: 350)
        let broad  = bandMeanPower(power, sr: sr, size: size, lo: 100,  hi: 1500)
        let harsh  = bandMeanPower(power, sr: sr, size: size, lo: 6000, hi: 8000)
        let presence = bandMeanPower(power, sr: sr, size: size, lo: 1000, hi: 4000)

        let subRelDB   = ratioDB(sub, kick)
        let mudRelDB   = ratioDB(mud, broad)
        let harshRelDB = ratioDB(harsh, presence)

        let rumbleFlag = subRelDB >= rumbleThreshDB
        let mudFlag    = mudRelDB >= mudThreshDB
        let harshFlag  = harshRelDB >= harshThreshDB

        // --- stereo behaviour of the lows: correlation + side/mid below 120 Hz ---
        let isMono = ch < 2
        let (lowCorr, sideMidDB) = lowStereo(s, cutoffHz: 120, sampleRate: sr)
        let wideSubFlag = !isMono && lowCorr < wideSubCorr

        // --- assemble measured display rows + neutral flag statements ---
        var rows: [AnalysisRow] = []
        var flags: [String] = []

        rows.append(AnalysisRow(label: "Low fundamental", value: String(format: "%.0f Hz", fundamentalHz), flagged: false))
        rows.append(AnalysisRow(label: "Sub < 30 Hz", value: String(format: "%+.1f dB vs 30–120 Hz", subRelDB), flagged: rumbleFlag))
        rows.append(AnalysisRow(label: "Mud 200–350 Hz", value: String(format: "%+.1f dB vs broadband", mudRelDB), flagged: mudFlag))
        rows.append(AnalysisRow(label: "Harsh 6–8 kHz", value: String(format: "%+.1f dB vs presence", harshRelDB), flagged: harshFlag))
        if isMono {
            rows.append(AnalysisRow(label: "Lows < 120 Hz", value: "mono source", flagged: false))
        } else {
            rows.append(AnalysisRow(label: "Correlation < 120 Hz", value: String(format: "%.2f", lowCorr), flagged: wideSubFlag))
            rows.append(AnalysisRow(label: "Side/mid < 120 Hz", value: String(format: "%+.1f dB", sideMidDB), flagged: wideSubFlag))
        }

        if rumbleFlag {
            flags.append(String(format: "Energy below 30 Hz measures %+.1f dB relative to the 30–120 Hz kick band.", subRelDB))
        }
        if mudFlag {
            flags.append(String(format: "The 200–350 Hz band sits %+.1f dB above the 100–1500 Hz broadband average.", mudRelDB))
        }
        if harshFlag {
            flags.append(String(format: "The 6–8 kHz band sits %+.1f dB above the 1–4 kHz presence average.", harshRelDB))
        }
        if wideSubFlag {
            flags.append(String(format: "Correlation below 120 Hz is %.2f (side/mid %+.1f dB) — the lows are not near-mono.", lowCorr, sideMidDB))
        }

        return LowEndReport(
            hasData: true, fundamentalHz: fundamentalHz,
            subBelow30RelDB: subRelDB, rumbleFlag: rumbleFlag,
            mudBandRelDB: mudRelDB, mudFlag: mudFlag,
            harshnessRelDB: harshRelDB, harshFlag: harshFlag,
            lowCorrelation: lowCorr, lowSideMidDB: sideMidDB, wideSubFlag: wideSubFlag,
            isMono: isMono, rows: rows, flags: flags)
    }

    // MARK: - helpers

    /// Average all channels to a mono Float buffer (analysis only).
    static func monoSum(_ s: AudioSignal) -> [Float] {
        let n = s.frameCount
        guard n > 0, s.channelCount > 0 else { return [] }
        if s.channelCount == 1 { return s.channels[0] }
        var out = [Float](repeating: 0, count: n)
        let inv = 1.0 / Double(s.channelCount)
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            let m = min(n, src.count)
            for i in 0..<m { out[i] += Float(Double(src[i]) * inv) }
        }
        return out
    }

    /// Mean power (linear) over the [lo, hi] Hz bin range of an FFT power spectrum.
    static func bandMeanPower(_ power: [Float], sr: Double, size: Int, lo: Double, hi: Double) -> Double {
        let half = power.count
        let loBin = max(1, Int(lo * Double(size) / sr))
        let hiBin = min(half - 1, Int(hi * Double(size) / sr))
        guard hiBin >= loBin else { return 1e-20 }
        var sum = 0.0
        for k in loBin...hiBin { sum += Double(power[k]) }
        return sum / Double(hiBin - loBin + 1)
    }

    /// 10·log10(a/b) with a floor so silence never produces NaN/±inf.
    static func ratioDB(_ a: Double, _ b: Double) -> Double {
        let num = max(a, 1e-20), den = max(b, 1e-20)
        return max(-120.0, min(120.0, 10.0 * log10(num / den)))
    }

    /// Parabolically-interpolated frequency (Hz) of the strongest bin in [lo, hi].
    static func peakFrequency(power: [Float], sampleRate sr: Double, fftSize size: Int, lo: Double, hi: Double) -> Double {
        let half = power.count
        let loBin = max(1, Int(lo * Double(size) / sr))
        let hiBin = min(half - 2, Int(hi * Double(size) / sr))
        guard hiBin > loBin else { return lo }
        var bestBin = loBin
        var bestVal = Double(power[loBin])
        for k in loBin...hiBin where Double(power[k]) > bestVal { bestVal = Double(power[k]); bestBin = k }
        // parabolic interpolation over the log-magnitude neighbourhood
        let ym1 = log(max(Double(power[bestBin - 1]), 1e-20))
        let y0  = log(max(Double(power[bestBin]),     1e-20))
        let yp1 = log(max(Double(power[bestBin + 1]), 1e-20))
        let denom = (ym1 - 2 * y0 + yp1)
        let delta = abs(denom) > 1e-12 ? 0.5 * (ym1 - yp1) / denom : 0.0
        let bin = Double(bestBin) + max(-0.5, min(0.5, delta))
        return bin * sr / Double(size)
    }

    /// Correlation and side/mid ratio (dB) of the content below `cutoffHz`.
    /// Both channels are low-passed (24 dB/oct) before the stereo maths, so the
    /// result describes only the lows. Mono input → (1.0, −120 dB).
    static func lowStereo(_ s: AudioSignal, cutoffHz: Double, sampleRate sr: Double) -> (correlation: Double, sideMidDB: Double) {
        guard s.channelCount >= 2, s.frameCount > 0 else { return (1.0, -120.0) }
        let n = min(s.channels[0].count, s.channels[1].count)
        guard n > 0 else { return (1.0, -120.0) }

        let coeffs = BiquadCoeffs.make(.lowPass, freq: cutoffHz, sampleRate: sr, q: 0.707)
        let lpL1 = Biquad(coeffs), lpL2 = Biquad(coeffs)   // cascade = 24 dB/oct
        let lpR1 = Biquad(coeffs), lpR2 = Biquad(coeffs)

        var sumLR = 0.0, sumLL = 0.0, sumRR = 0.0
        var sumMid = 0.0, sumSide = 0.0
        for i in 0..<n {
            let l = lpL2.process(lpL1.process(Double(s.channels[0][i])))
            let r = lpR2.process(lpR1.process(Double(s.channels[1][i])))
            sumLR += l * r; sumLL += l * l; sumRR += r * r
            let mid = (l + r) * 0.5, side = (l - r) * 0.5
            sumMid += mid * mid; sumSide += side * side
        }
        let denom = (sumLL * sumRR).squareRoot()
        let corr = denom > 1e-12 ? max(-1.0, min(1.0, sumLR / denom)) : 1.0
        let sideMidDB = ratioDB(sumSide / Double(n), sumMid / Double(n))
        return (corr, sideMidDB)
    }
}
#endif // circuit-convert
