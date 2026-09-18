// DeltaAudition.swift — SS-18 "Hear What Changed": the residual between the buyer's original and
// the finished master, so the chain's work is audible, not just charted.
//
// Honest by construction:
//   1. Sample-align — the limiter's look-ahead and the filters shift the master a few samples; we
//      find the integer lag that maximizes normalized cross-correlation and undo it, so the
//      subtraction lines up. Without this, a pure delay would masquerade as a huge "difference".
//   2. Gain-match — we scale the master to the ORIGINAL's integrated loudness (BS.1770) BEFORE
//      subtracting, routed through DSP/LoudnessMatch so a louder master can't fake a bigger delta.
//   3. Subtract — residual[i] = original[i] − matchedMaster[i+lag]. What's left is exactly what the
//      chain added or removed. A bypassed (identity) master cancels to near-silence; a real chain
//      leaves an audible residual. Every number is measured; nothing is prescribed.

import Foundation

enum DeltaAudition {

    struct Residual {
        var signal: AudioSignal          // the difference signal, ready to audition
        var lagSamples: Int              // integer alignment applied to the master (+ = master lags)
        var matchGainDB: Double          // loudness match applied to the master before subtracting
        var residualRMSDBFS: Double      // measured level of what changed (−200 = silence)
        var hasData: Bool                // false when either source is empty/undefined
    }

    /// Compute the residual of `master` against `original`. `maxLagSamples` bounds the alignment
    /// search (±); the default comfortably covers a few-ms limiter look-ahead at 48 kHz.
    static func residual(original: AudioSignal, master: AudioSignal,
                         maxLagSamples: Int = 512) -> Residual {
        let ch = min(original.channelCount, master.channelCount)
        let n = min(original.frameCount, master.frameCount)
        guard ch > 0, n > 0 else {
            return Residual(signal: AudioSignal(channels: [], sampleRate: original.sampleRate),
                            lagSamples: 0, matchGainDB: 0, residualRMSDBFS: -200, hasData: false)
        }
        let sr = original.sampleRate > 0 ? original.sampleRate : (master.sampleRate > 0 ? master.sampleRate : 44100)

        // 1. Align: best integer lag by normalized cross-correlation on the mono sums.
        let origMono = monoSum(original, frames: n)
        let mstrMono = monoSum(master, frames: n)
        let lag = bestLag(origMono, mstrMono, maxLag: min(maxLagSamples, max(1, n / 4)))

        // 2. Gain-match the master to the ORIGINAL's loudness (via LoudnessMatch — measured, never guessed).
        let origLUFS = LoudnessMeter(sampleRate: sr, channels: max(1, original.channelCount))
            .measure(original.channels).integratedLUFS
        let mstrLUFS = LoudnessMeter(sampleRate: sr, channels: max(1, master.channelCount))
            .measure(master.channels).integratedLUFS
        let matchDB = LoudnessMatch.gainDB(sourceLUFS: mstrLUFS, targetLUFS: origLUFS)
        let g = Float(pow(10.0, matchDB / 20.0))

        // 3. Subtract the aligned, loudness-matched master from the original.
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: ch)
        var sumSq = 0.0
        var count = 0
        for c in 0..<ch {
            let o = original.channels[c]
            let m = master.channels[c]
            for i in 0..<n {
                let mi = i + lag
                let mv: Float = (mi >= 0 && mi < m.count) ? m[mi] * g : 0
                let ov: Float = i < o.count ? o[i] : 0
                let d = ov - mv
                out[c][i] = d
                sumSq += Double(d) * Double(d)
                count += 1
            }
        }
        let rms = count > 0 ? (sumSq / Double(count)).squareRoot() : 0
        let rmsDB = rms > 1e-10 ? max(-200, 20 * log10(rms)) : -200
        let hasData = origLUFS.isFinite && mstrLUFS.isFinite && origLUFS > -70 && mstrLUFS > -70

        return Residual(signal: AudioSignal(channels: out, sampleRate: sr),
                        lagSamples: lag, matchGainDB: matchDB,
                        residualRMSDBFS: rmsDB, hasData: hasData)
    }

    // MARK: - helpers

    private static func monoSum(_ s: AudioSignal, frames: Int) -> [Float] {
        let n = min(frames, s.frameCount)
        guard n > 0, s.channelCount > 0 else { return [] }
        if s.channelCount == 1 { return Array(s.channels[0].prefix(n)) }
        var out = [Float](repeating: 0, count: n)
        let inv = 1.0 / Double(s.channelCount)
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            let m = min(n, src.count)
            for i in 0..<m { out[i] += Float(Double(src[i]) * inv) }
        }
        return out
    }

    /// Integer lag (applied to `b`) that maximizes normalized cross-correlation with `a`, searched
    /// over ±maxLag on a bounded window for speed. Positive lag means `b` trails `a`.
    private static func bestLag(_ a: [Float], _ b: [Float], maxLag: Int) -> Int {
        let n = min(a.count, b.count)
        guard n > 8, maxLag > 0 else { return 0 }
        let window = min(n, 200_000)
        var bestLag = 0
        var bestScore = -Double.infinity
        for lag in -maxLag...maxLag {
            var dot = 0.0, ea = 0.0, eb = 0.0
            var i = 0
            while i < window {
                let bi = i + lag
                if bi >= 0 && bi < n {
                    let x = Double(a[i]), y = Double(b[bi])
                    dot += x * y; ea += x * x; eb += y * y
                }
                i += 1
            }
            let denom = (ea * eb).squareRoot()
            let score = denom > 1e-12 ? dot / denom : 0
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        return bestLag
    }
}
