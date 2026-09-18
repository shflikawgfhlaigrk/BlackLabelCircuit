// LoudnessMeter.swift — ITU-R BS.1770-4 integrated loudness + EBU R128 + true peak.
//
// This is the measurement backbone of the whole product: every loudness claim,
// the limiter's target gain, and the per-platform report all read from here.
// Implemented from the standard (K-weighting pre-filter + gated block loudness),
// with sample-rate-correct filter coefficients derived the libebur128 way so it
// is accurate at 44.1k and 48k, not just the tabulated 48k values.

import Foundation
import Accelerate

struct LoudnessResult {
    var integratedLUFS: Double       // gated integrated loudness
    var shortTermMaxLUFS: Double      // max 3 s short-term
    var loudnessRangeLU: Double       // EBU R128 LRA
    var truePeakDBTP: Double          // max true peak, dBTP
    var samplePeakDBFS: Double
}

final class LoudnessMeter {
    let sampleRate: Double

    // K-weighting: two cascaded biquads (high-shelf "pre" + RLB high-pass), per channel.
    private var pre: [Biquad]
    private var rlb: [Biquad]
    private let channels: Int

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        let (preC, rlbC) = LoudnessMeter.kWeightingCoeffs(sampleRate: sampleRate)
        self.pre = (0..<channels).map { _ in Biquad(preC) }
        self.rlb = (0..<channels).map { _ in Biquad(rlbC) }
    }

    /// Derive the two K-weighting biquads for an arbitrary sample rate.
    /// (Stage 1 high-shelf + stage 2 RLB high-pass; analog prototype from BS.1770.)
    static func kWeightingCoeffs(sampleRate fs: Double) -> (BiquadCoeffs, BiquadCoeffs) {
        // Stage 1 — high shelf
        let f0 = 1681.974450955533
        let G  = 3.999843853973347
        let Q1 = 0.7071752369554196
        let K1 = tan(Double.pi * f0 / fs)
        let Vh = pow(10.0, G / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)
        let a0_ = 1.0 + K1 / Q1 + K1 * K1
        let pb0 = (Vh + Vb * K1 / Q1 + K1 * K1) / a0_
        let pb1 = 2.0 * (K1 * K1 - Vh) / a0_
        let pb2 = (Vh - Vb * K1 / Q1 + K1 * K1) / a0_
        let pa1 = 2.0 * (K1 * K1 - 1.0) / a0_
        let pa2 = (1.0 - K1 / Q1 + K1 * K1) / a0_
        let pre = BiquadCoeffs.raw(b0: pb0, b1: pb1, b2: pb2, a1: pa1, a2: pa2)

        // Stage 2 — RLB high-pass
        let f0h = 38.13547087602444
        let Qh  = 0.5003270373238773
        let Kh  = tan(Double.pi * f0h / fs)
        let a0h = 1.0 + Kh / Qh + Kh * Kh
        let hb0 = 1.0
        let hb1 = -2.0
        let hb2 = 1.0
        let ha1 = 2.0 * (Kh * Kh - 1.0) / a0h
        let ha2 = (1.0 - Kh / Qh + Kh * Kh) / a0h
        let rlb = BiquadCoeffs.raw(b0: hb0, b1: hb1, b2: hb2, a1: ha1, a2: ha2)
        return (pre, rlb)
    }

    /// Measure a full deinterleaved signal (channels × samples).
    func measure(_ channelsData: [[Float]]) -> LoudnessResult {
        let ch = min(channels, channelsData.count)
        guard ch > 0, let n = channelsData.first?.count, n > 0 else {
            return LoudnessResult(integratedLUFS: -70, shortTermMaxLUFS: -70,
                                  loudnessRangeLU: 0, truePeakDBTP: -120, samplePeakDBFS: -120)
        }

        // --- K-weight every channel ---
        var kw = [[Double]](repeating: [Double](repeating: 0, count: n), count: ch)
        var samplePeak: Float = 0
        for c in 0..<ch {
            pre[c].reset(); rlb[c].reset()
            let src = channelsData[c]
            for i in 0..<n {
                let x = Double(src[i])
                kw[c][i] = rlb[c].process(pre[c].process(x))
                let a = abs(src[i]); if a > samplePeak { samplePeak = a }
            }
        }

        // --- Gated block loudness (BS.1770): 400 ms blocks, 100 ms hop ---
        let blockLen = Int(0.4 * sampleRate)
        let hop = Int(0.1 * sampleRate)
        guard blockLen > 0, n >= blockLen else {
            let peakTP = truePeak(channelsData, ch: ch)
            return LoudnessResult(integratedLUFS: -70, shortTermMaxLUFS: -70, loudnessRangeLU: 0,
                                  truePeakDBTP: peakTP, samplePeakDBFS: db(Double(samplePeak)))
        }
        let G: [Double] = channelWeights(ch)

        var blockZ = [Double]()        // per-block channel-weighted mean square
        blockZ.reserveCapacity((n - blockLen) / hop + 1)
        var pos = 0
        while pos + blockLen <= n {
            var z = 0.0
            for c in 0..<ch {
                var s = 0.0
                let seg = kw[c]
                for i in pos..<pos + blockLen { s += seg[i] * seg[i] }
                z += G[c] * (s / Double(blockLen))
            }
            blockZ.append(z)
            pos += hop
        }

        func loudness(_ z: Double) -> Double { z > 0 ? -0.691 + 10 * log10(z) : -.infinity }

        // absolute gate at -70 LUFS
        let absKept = blockZ.filter { loudness($0) >= -70 }
        guard !absKept.isEmpty else {
            let peakTP = truePeak(channelsData, ch: ch)
            return LoudnessResult(integratedLUFS: -70, shortTermMaxLUFS: -70, loudnessRangeLU: 0,
                                  truePeakDBTP: peakTP, samplePeakDBFS: db(Double(samplePeak)))
        }
        // relative gate: mean of kept, threshold -10 LU below that
        let meanAbs = absKept.reduce(0, +) / Double(absKept.count)
        let relThresh = loudness(meanAbs) - 10.0
        let relKept = blockZ.filter { loudness($0) >= relThresh }
        let gatedMean = (relKept.isEmpty ? absKept : relKept).reduce(0, +) / Double(relKept.isEmpty ? absKept.count : relKept.count)
        let integrated = loudness(gatedMean)

        // --- Short-term (3 s window, 1 s hop) max ---
        let stLen = Int(3.0 * sampleRate)
        var shortMax = -Double.infinity
        if n >= stLen {
            var p = 0
            let stHop = Int(1.0 * sampleRate)
            while p + stLen <= n {
                var z = 0.0
                for c in 0..<ch {
                    var s = 0.0; let seg = kw[c]
                    for i in p..<p + stLen { s += seg[i] * seg[i] }
                    z += G[c] * (s / Double(stLen))
                }
                shortMax = max(shortMax, loudness(z))
                p += stHop
            }
        } else { shortMax = integrated }

        // --- LRA (EBU R128): 10th–95th percentile of gated short-term (3s/0.1s) ---
        let lra = loudnessRange(kw: kw, ch: ch, G: G)

        let peakTP = truePeak(channelsData, ch: ch)
        return LoudnessResult(integratedLUFS: integrated,
                              shortTermMaxLUFS: shortMax.isFinite ? shortMax : integrated,
                              loudnessRangeLU: lra,
                              truePeakDBTP: peakTP,
                              samplePeakDBFS: db(Double(samplePeak)))
    }

    private func channelWeights(_ ch: Int) -> [Double] {
        // stereo/mono: 1.0 each. (Surround Ls/Rs would be 1.41; not used here.)
        [Double](repeating: 1.0, count: ch)
    }

    private func loudnessRange(kw: [[Double]], ch: Int, G: [Double]) -> Double {
        let win = Int(3.0 * sampleRate), hop = Int(0.1 * sampleRate)
        let n = kw[0].count
        guard win > 0, n >= win else { return 0 }
        var stl = [Double]()
        var p = 0
        while p + win <= n {
            var z = 0.0
            for c in 0..<ch {
                var s = 0.0; let seg = kw[c]
                for i in p..<p + win { s += seg[i] * seg[i] }
                z += G[c] * (s / Double(win))
            }
            let l = z > 0 ? -0.691 + 10 * log10(z) : -.infinity
            if l >= -70 { stl.append(l) }
            p += hop
        }
        guard stl.count > 1 else { return 0 }
        // relative gate -20 LU below mean of absolute-gated
        let mean = stl.reduce(0, +) / Double(stl.count)
        let gated = stl.filter { $0 >= mean - 20 }.sorted()
        guard gated.count > 1 else { return 0 }
        func pct(_ p: Double) -> Double {
            let idx = min(gated.count - 1, max(0, Int(p * Double(gated.count - 1))))
            return gated[idx]
        }
        return pct(0.95) - pct(0.10)
    }

    // --- True peak: 4× oversampling via a short polyphase windowed-sinc ---
    private static let osKernel: [[Double]] = LoudnessMeter.makePolyphase(taps: 32, phases: 4)
    private func truePeak(_ data: [[Float]], ch: Int) -> Double {
        var peak = 0.0
        let kernel = LoudnessMeter.osKernel
        let taps = kernel[0].count
        for c in 0..<ch {
            let x = data[c]
            let n = x.count
            for i in 0..<n {
                for ph in 0..<kernel.count {
                    var acc = 0.0
                    for t in 0..<taps {
                        let idx = i - t
                        if idx >= 0 { acc += Double(x[idx]) * kernel[ph][t] }
                    }
                    peak = max(peak, abs(acc))
                }
            }
        }
        return db(peak)
    }

    private static func makePolyphase(taps: Int, phases: Int) -> [[Double]] {
        // Windowed-sinc low-pass at Nyquist/phases, split into polyphase branches.
        let total = taps * phases
        var proto = [Double](repeating: 0, count: total)
        let fc = 1.0 / Double(phases)   // normalized cutoff (×π)
        let center = Double(total - 1) / 2.0
        for i in 0..<total {
            let m = Double(i) - center
            let sinc = m == 0 ? fc : sin(Double.pi * fc * m) / (Double.pi * m)
            // Hamming window
            let w = 0.54 - 0.46 * cos(2 * Double.pi * Double(i) / Double(total - 1))
            proto[i] = sinc * w
        }
        // normalize DC gain to `phases` (so interpolation preserves amplitude)
        let sum = proto.reduce(0, +)
        if sum != 0 { for i in 0..<total { proto[i] *= Double(phases) / sum } }
        var branches = [[Double]](repeating: [Double](repeating: 0, count: taps), count: phases)
        for ph in 0..<phases {
            for t in 0..<taps {
                let idx = t * phases + ph
                branches[ph][t] = idx < total ? proto[idx] : 0
            }
        }
        return branches
    }

    private func db(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -120 }
}
