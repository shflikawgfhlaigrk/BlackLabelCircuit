#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MaskingDetector.swift — cross-stem frequency-masking analysis for the MIX stage.
//
// Two stems "mask" when they both carry strong energy in the same third-octave
// band: the ear can't separate them and the mix turns muddy. We find those
// collisions deterministically, rank which stem matters more, and hand the
// LESS important stem a narrow EQ carve so the more important one cuts through.

import Foundation

enum MaskingDetector {

    struct MaskingIssue {
        let stemA: String        // the stem that keeps its band (more important)
        let stemB: String        // the stem that gets carved (less important)
        let freqHz: Double
        let severity: Double     // 0..1 — how badly they collide
        let suggestion: String
    }

    struct MaskingReport {
        let issues: [MaskingIssue]
        // Per stem name → the peaking cuts to apply to reduce collisions.
        let suggestedCarves: [String: [EQBand]]
    }

    // --- tuning constants (WHY inline) ---
    private static let excessThreshDB: Float = 3.0   // a band is "hot" if >3 dB over the stem's own mean
    private static let excessNormDB: Float  = 12.0   // 12 dB over mean ≈ maximally hot (→ 1.0)
    private static let minSeverity: Double  = 0.15   // ignore trivial overlaps
    private static let carveQ: Double       = 2.0    // narrow, surgical
    // Words that mark a stem as sonically important — it wins collisions.
    private static let leadKeywords = ["vocal", "vox", "lead", "voice", "melody", "hook", "topline"]

    /// Analyze a set of named stems for pairwise band masking.
    static func analyze(stems: [(name: String, signal: AudioSignal)],
                        analyzer: FFTAnalyzer) -> MaskingReport {
        guard stems.count >= 2 else {
            return MaskingReport(issues: [], suggestedCarves: [:])
        }

        let fftSize = analyzer.size
        let centers = FreqBands.centers
        let nBands = centers.count

        // Per stem: band energy (dB), the per-band excess over the stem's own
        // mean (its "hot" profile), and an overall importance score.
        struct StemProfile {
            let name: String
            let sampleRate: Double
            let excessDB: [Float]     // bandDB - meanDB, per band
            let importance: Double    // higher = keeps its bands
        }

        var profiles: [StemProfile] = []
        profiles.reserveCapacity(stems.count)

        for stem in stems {
            let sig = stem.signal
            guard sig.frameCount > 0, sig.channelCount > 0 else {
                profiles.append(StemProfile(name: stem.name,
                                            sampleRate: sig.sampleRate,
                                            excessDB: [Float](repeating: 0, count: nBands),
                                            importance: 0))
                continue
            }

            // Mono downmix for spectral content.
            let mono = downmix(sig)
            let power = analyzer.averagePower(mono)
            let bandsDB = FreqBands.toBandsDB(power: power,
                                              sampleRate: sig.sampleRate,
                                              fftSize: fftSize)

            // Mean level across bands that carry real signal (ignore the -120 floor).
            var sum: Float = 0
            var cnt: Int = 0
            for v in bandsDB where v > -119 { sum += v; cnt += 1 }
            let mean = cnt > 0 ? sum / Float(cnt) : -120
            let excess = bandsDB.map { $0 > -119 ? $0 - mean : -120 }

            // Overall loudness (RMS dB) drives importance when the name is unknown.
            let rmsDB = rmsDBFS(mono)
            let importance = nameImportance(stem.name) + Double(rmsDB) / 100.0

            profiles.append(StemProfile(name: stem.name,
                                        sampleRate: sig.sampleRate,
                                        excessDB: excess,
                                        importance: importance))
        }

        var issues: [MaskingIssue] = []
        // stemName → bandIndex → strongest severity seen (so we carve once, deepest).
        var carveSeverity: [String: [Int: Double]] = [:]

        for i in 0..<profiles.count {
            for j in (i + 1)..<profiles.count {
                let a = profiles[i]
                let b = profiles[j]
                for band in 0..<nBands {
                    let ea = a.excessDB[band]
                    let eb = b.excessDB[band]
                    // Both must be genuinely hot in this band to collide.
                    guard ea > excessThreshDB, eb > excessThreshDB else { continue }

                    // Severity ~ overlap of the two hot amounts (the weaker one
                    // bounds how much they actually fight).
                    let na = min(1.0, Double(ea / excessNormDB))
                    let nb = min(1.0, Double(eb / excessNormDB))
                    let severity = min(na, nb)
                    guard severity >= minSeverity else { continue }

                    // Louder/named-lead stem keeps its band; the other yields.
                    let winner: StemProfile
                    let loser: StemProfile
                    if a.importance >= b.importance { winner = a; loser = b }
                    else { winner = b; loser = a }

                    let fc = centers[band]
                    let cutDB = carveGainDB(severity)   // -2..-4
                    let suggestion = String(format:
                        "%@ masks %@ at %@ — cut %@ by %.1f dB (Q %.1f).",
                        loser.name, winner.name, freqLabel(fc),
                        loser.name, -cutDB, carveQ)

                    issues.append(MaskingIssue(stemA: winner.name,
                                               stemB: loser.name,
                                               freqHz: fc,
                                               severity: severity,
                                               suggestion: suggestion))

                    let prev = carveSeverity[loser.name]?[band] ?? 0
                    if severity > prev {
                        carveSeverity[loser.name, default: [:]][band] = severity
                    }
                }
            }
        }

        // Materialize carves: one peaking cut per (stem, band), deepest severity wins.
        var carves: [String: [EQBand]] = [:]
        for (stem, bands) in carveSeverity {
            var eqs: [EQBand] = []
            for (band, sev) in bands.sorted(by: { $0.key < $1.key }) {
                let fc = centers[band]
                let gain = carveGainDB(sev)   // negative
                eqs.append(EQBand.peak(fc, gain, carveQ))
            }
            if !eqs.isEmpty { carves[stem] = eqs }
        }

        // Most severe first — stable, explainable ordering.
        issues.sort { $0.severity > $1.severity }
        return MaskingReport(issues: issues, suggestedCarves: carves)
    }

    // MARK: - helpers

    /// Average all channels into one mono track for spectral analysis.
    private static func downmix(_ sig: AudioSignal) -> [Float] {
        let ch = sig.channels
        guard let first = ch.first else { return [] }
        if ch.count == 1 { return first }
        let n = first.count
        var out = [Float](repeating: 0, count: n)
        for c in ch {
            let m = min(n, c.count)
            for i in 0..<m { out[i] += c[i] }
        }
        let inv = Float(1.0) / Float(ch.count)
        for i in 0..<n { out[i] *= inv }
        return out
    }

    /// RMS level in dBFS (clamped to a sane floor).
    private static func rmsDBFS(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return -120 }
        var acc: Double = 0
        for v in x { acc += Double(v) * Double(v) }
        let rms = (acc / Double(x.count)).squareRoot()
        return Float(20.0 * log10(max(rms, 1e-9)))
    }

    /// Name-based importance boost: leads/vocals win collisions.
    private static func nameImportance(_ name: String) -> Double {
        let lower = name.lowercased()
        for kw in leadKeywords where lower.contains(kw) { return 1.0 }
        return 0.0
    }

    /// Map severity 0..1 → cut of -2..-4 dB.
    private static func carveGainDB(_ severity: Double) -> Double {
        let s = min(max(severity, 0), 1)
        return -(2.0 + 2.0 * s)
    }

    private static func freqLabel(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1f kHz", hz / 1000.0)
                   : String(format: "%.0f Hz", hz)
    }
}
#endif // circuit-convert
