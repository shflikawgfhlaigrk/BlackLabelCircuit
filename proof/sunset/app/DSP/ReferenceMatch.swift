#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// ReferenceMatch.swift — Matchering-style reference matcher: impose a reference track's tonal balance + loudness on the target.

// This is the "make my track sound like the reference" brain. It is pure,
// explainable DSP: compare third-octave spectral fingerprints of the two
// signals, turn the per-band difference into a small corrective peaking EQ,
// and read level/width/loudness targets straight off the reference. Nothing
// is fabricated — every number traces back to the two audio signals or, in
// the reference-less path, to a hand-tuned GenreTarget preset.

import Foundation
#if canImport(Accelerate) && !CIRCUIT_WINDOWS_SIM
import Accelerate
#endif

/// Everything the mastering chain needs to make `target` sound like `reference`.
struct MatchResult {
    var bands: [EQBand]          // corrective EQ imposing the reference tonal balance
    var gainDB: Double           // broadband level match (target -> reference)
    var targetLUFS: Double       // integrated loudness to master to
    var truePeakDBTP: Double     // ceiling
    var stereoWidth: Double      // 1.0 = unchanged
    var lowMonoHz: Double        // fold below this to mono
    var notes: [String]          // plain-English "what changed and why"
}

/// A persistable "Reference DNA" — the exact numbers `match` reads off a reference,
/// captured once so the same reference character can be re-applied later without the
/// original audio file. This is the ONLY thing a saved DNA profile stores: a third-octave
/// tonal fingerprint plus the reference's own loudness / peak / stereo-width stats. No
/// audio samples are kept; a fresh match against the live reference and a match from this
/// captured DNA produce byte-for-byte identical corrective targets (proven in the regression).
struct ReferenceDNA: Codable, Equatable {
    var fingerprint: [Float]     // reference third-octave band dB (FreqBands.centers order)
    var integratedLUFS: Double   // reference integrated loudness (LUFS)
    var truePeakDBTP: Double     // reference true peak (dBTP)
    var sideMidRatio: Double     // reference side/mid RMS ratio (stereo-width proxy)
}

enum ReferenceMatcher {

    // Musically-sensible anchor frequencies the corrective EQ is fit at.
    private static let anchors: [Double] = [60, 120, 250, 500, 1000, 2000, 4000, 8000, 12000]

    /// Average power spectrum of a signal (both channels averaged), as third-octave band dB.
    /// This is the spectral signature two tracks are compared on.
    static func fingerprint(_ s: AudioSignal, analyzer: FFTAnalyzer) -> [Float] {
        let n = FreqBands.centers.count
        guard s.frameCount > 0, s.channelCount > 0 else { return [Float](repeating: -120, count: n) }

        // Average the per-channel power spectra so the fingerprint is a mono tonal view.
        var acc = [Float](repeating: 0, count: analyzer.size / 2)
        var chUsed = 0
        for ch in s.channels where !ch.isEmpty {
            let p = analyzer.averagePower(ch)
            let m = min(acc.count, p.count)
            for k in 0..<m { acc[k] += p[k] }
            chUsed += 1
        }
        if chUsed > 1 {
            let inv = Float(1.0) / Float(chUsed)
            for k in 0..<acc.count { acc[k] *= inv }
        }
        return FreqBands.toBandsDB(power: acc, sampleRate: s.sampleRate, fftSize: analyzer.size)
    }

    /// Capture a reference's DNA: its tonal fingerprint + loudness/peak/width stats.
    /// This is what a saved DNA profile persists — no audio, just the numbers `match` reads.
    static func captureDNA(_ reference: AudioSignal,
                           meter: (AudioSignal) -> LoudnessResult) -> ReferenceDNA {
        let analyzer = FFTAnalyzer(size: 4096)
        let rFP = fingerprint(reference, analyzer: analyzer)
        let rLoud = meter(reference)
        return ReferenceDNA(fingerprint: rFP,
                            integratedLUFS: rLoud.integratedLUFS,
                            truePeakDBTP: rLoud.truePeakDBTP,
                            sideMidRatio: sideMidRatio(reference))
    }

    /// Full reference match against a LIVE reference signal. Captures the reference's DNA
    /// and delegates to `matchDNA`, so a live match and a saved-DNA re-apply are identical.
    static func match(target: AudioSignal,
                      reference: AudioSignal,
                      targetLUFS: Double?,
                      meter: (AudioSignal) -> LoudnessResult) -> MatchResult {
        let dna = captureDNA(reference, meter: meter)
        return matchDNA(target: target, dna: dna, targetLUFS: targetLUFS, meter: meter)
    }

    /// Full reference match from a captured `ReferenceDNA` — the reusable Reference-DNA path.
    /// Fits corrective EQ + level + width + loudness against the target using the stored
    /// reference fingerprint/stats. Every number still traces to real signals (the target's
    /// live fingerprint/loudness and the reference's captured DNA); nothing is fabricated.
    static func matchDNA(target: AudioSignal,
                         dna: ReferenceDNA,
                         targetLUFS: Double?,
                         meter: (AudioSignal) -> LoudnessResult) -> MatchResult {

        let analyzer = FFTAnalyzer(size: 4096)
        let tFP = fingerprint(target, analyzer: analyzer)
        let rFP = dna.fingerprint
        let centers = FreqBands.centers
        let n = min(tFP.count, rFP.count)

        // Per-band difference (reference - target) in dB: where the ref has more/less energy.
        var diff = [Double](repeating: 0, count: n)
        for i in 0..<n { diff[i] = Double(rFP[i] - tFP[i]) }

        // Smooth the difference with a small moving average so the curve is gentle,
        // not a jagged bin-by-bin chase, then clamp each move to +/-6 dB.
        let smooth = movingAverage(diff, radius: 2).map { clamp($0, -6.0, 6.0) }

        // Fit a compact peaking EQ: each anchor takes the smoothed difference at its freq.
        var bands: [EQBand] = []
        var moves: [(Double, Double)] = []   // (freq, gainDB) for note-building
        for f in anchors {
            let g = sampleCurve(smooth, centers: centers, freq: f)
            let gc = clamp(g, -6.0, 6.0)
            // Skip near-zero moves — keeps the EQ honest and readable.
            if abs(gc) < 0.4 { continue }
            bands.append(.peak(f, gc, 1.0))
            moves.append((f, gc))
        }

        // Broadband level match: difference of integrated loudness (ref - target).
        let tLoud = meter(target)
        let rIntegratedLUFS = dna.integratedLUFS
        let levelGain = clamp(rIntegratedLUFS - tLoud.integratedLUFS, -24.0, 24.0)

        // Stereo width from side/mid energy ratio (reference vs target). >1 = ref is wider.
        let tSM = sideMidRatio(target)
        let rSM = dna.sideMidRatio
        var width = 1.0
        if tSM > 1e-9 { width = clamp(rSM / tSM, 0.8, 1.4) }

        // Loudness target: caller override wins, else the reference's own integrated loudness.
        let outLUFS = targetLUFS ?? rIntegratedLUFS
        // Ceiling: honour the reference's true peak but never above -1 dBTP.
        let ceiling = min(-1.0, dna.truePeakDBTP)

        // Low-mono fold: keep the low end tight if the reference isn't wide down low.
        let lowMono = width >= 1.15 ? 120.0 : 100.0

        // Plain-English explanations, all derived above.
        var notes: [String] = []
        notes.append(String(format: "Level: %+.1f dB to match reference loudness (%.1f LUFS vs your %.1f LUFS).",
                            levelGain, rIntegratedLUFS, tLoud.integratedLUFS))
        if moves.isEmpty {
            notes.append("Tonal balance already close to the reference — no corrective EQ needed.")
        } else {
            for (f, g) in moves {
                let verb = g >= 0 ? "Boost" : "Cut"
                notes.append(String(format: "%@ %.1f dB @ %@ — reference has %@ energy there.",
                                    verb, abs(g), fmtHz(f), g >= 0 ? "more" : "less"))
            }
        }
        if width > 1.02 {
            notes.append(String(format: "Widen stereo image x%.2f — reference is wider than your mix.", width))
        } else if width < 0.98 {
            notes.append(String(format: "Narrow stereo image x%.2f — reference is more mono than your mix.", width))
        } else {
            notes.append("Stereo width left unchanged — already matches the reference.")
        }
        notes.append(String(format: "Master to %.1f LUFS, ceiling %.1f dBTP; low end folded to mono below %.0f Hz.",
                            outLUFS, ceiling, lowMono))

        return MatchResult(bands: bands, gainDB: levelGain, targetLUFS: outLUFS,
                          truePeakDBTP: ceiling, stereoWidth: width, lowMonoHz: lowMono, notes: notes)
    }

    /// Reference-less path: use a GenreTarget curve so the app still works with no reference.
    static func fromGenre(_ g: GenreTarget) -> MatchResult {
        var notes: [String] = []
        notes.append("No reference supplied — using the \"\(g.name)\" tonal target.")
        notes.append(String(format: "Master to %.1f LUFS, ceiling %.1f dBTP.", g.targetLUFS, g.truePeakDBTP))
        if g.stereoWidth > 1.02 {
            notes.append(String(format: "Widen stereo image x%.2f for genre feel.", g.stereoWidth))
        } else if g.stereoWidth < 0.98 {
            notes.append(String(format: "Narrow stereo image x%.2f for genre feel.", g.stereoWidth))
        }
        notes.append(String(format: "Low end folded to mono below %.0f Hz for a tight, translatable bottom.", g.lowMonoHz))
        for b in g.bands where b.enabled && abs(b.gainDB) >= 0.4 {
            let verb = b.gainDB >= 0 ? "Boost" : "Cut"
            notes.append(String(format: "%@ %.1f dB @ %@ (%@).", verb, abs(b.gainDB), fmtHz(b.freq), kindName(b.kind)))
        }
        // No signal to level-match against; the mastering chain drives to targetLUFS instead.
        return MatchResult(bands: g.bands, gainDB: 0.0, targetLUFS: g.targetLUFS,
                          truePeakDBTP: g.truePeakDBTP, stereoWidth: g.stereoWidth,
                          lowMonoHz: g.lowMonoHz, notes: notes)
    }

    // MARK: - Helpers

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }

    /// Symmetric moving average over bands (radius in bands).
    private static func movingAverage(_ v: [Double], radius: Int) -> [Double] {
        guard !v.isEmpty, radius > 0 else { return v }
        var out = [Double](repeating: 0, count: v.count)
        for i in 0..<v.count {
            let lo = max(0, i - radius)
            let hi = min(v.count - 1, i + radius)
            var s = 0.0
            for j in lo...hi { s += v[j] }
            out[i] = s / Double(hi - lo + 1)
        }
        return out
    }

    /// Read the smoothed band curve at an arbitrary frequency via log-domain interpolation.
    private static func sampleCurve(_ curve: [Double], centers: [Double], freq: Double) -> Double {
        guard !curve.isEmpty else { return 0 }
        let n = min(curve.count, centers.count)
        if n == 0 { return 0 }
        if freq <= centers[0] { return curve[0] }
        if freq >= centers[n - 1] { return curve[n - 1] }
        let lf = log(freq)
        for i in 0..<(n - 1) {
            let f0 = centers[i], f1 = centers[i + 1]
            if freq >= f0 && freq <= f1 {
                let t = (lf - log(f0)) / (log(f1) - log(f0))
                return curve[i] + (curve[i + 1] - curve[i]) * t
            }
        }
        return curve[n - 1]
    }

    /// RMS ratio of side to mid energy (stereo width proxy). Mono -> ~0.
    private static func sideMidRatio(_ s: AudioSignal) -> Double {
        guard s.channelCount >= 2 else { return 0 }
        let l = s.channels[0], r = s.channels[1]
        let n = min(l.count, r.count)
        guard n > 0 else { return 0 }
        var midE = 0.0, sideE = 0.0
        for i in 0..<n {
            let mid = (Double(l[i]) + Double(r[i])) * 0.5
            let side = (Double(l[i]) - Double(r[i])) * 0.5
            midE += mid * mid
            sideE += side * side
        }
        let midRMS = (midE / Double(n)).squareRoot()
        let sideRMS = (sideE / Double(n)).squareRoot()
        return midRMS > 1e-9 ? sideRMS / midRMS : 0
    }

    private static func fmtHz(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.1f kHz", f / 1000) : String(format: "%.0f Hz", f)
    }

    private static func kindName(_ k: FilterKind) -> String {
        switch k {
        case .peaking:   return "peak"
        case .lowShelf:  return "low shelf"
        case .highShelf: return "high shelf"
        case .highPass:  return "high-pass"
        case .lowPass:   return "low-pass"
        }
    }
}
#endif // circuit-convert
