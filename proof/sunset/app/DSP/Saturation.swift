// Saturation.swift — oversampled multi-mode saturator (tape / tube / console / transformer).
//
// Contract: offline block processing on AudioSignal. `process` returns a signal of identical
// shape (frames + channels). Bypassed settings (`enabled == false`) are a bit-transparent
// passthrough — the input arrays are returned untouched. Deterministic: same input + settings
// → same output, no randomness anywhere.
//
// Every nonlinearity runs at ≥4× oversampling through the same windowed-sinc polyphase
// up/decimate pair the SoftClipper uses (zero net latency — integer group delay of the
// up+down FIR pair cancels exactly), so shaper harmonics above the audio band are filtered
// instead of folding back as aliasing.
//
// Modes (all waveshapers normalized to unity small-signal gain, so drive controls how hard
// the curve is hit, not the overall level):
//   • tape        — symmetric tanh with high-shelf pre-emphasis around 3.15 kHz before the
//                   shaper and the complementary de-emphasis after (models tape's stronger
//                   HF saturation). Odd harmonics.
//   • tube        — asymmetric biased tanh (even + odd harmonics), DC-blocked after the
//                   shaper so the bias never leaks a DC offset into the mix.
//   • console     — cubic soft-clip (x − x³/3, clamped): a harder knee than tanh. Odd harmonics.
//   • transformer — complementary low/high split at 250 Hz (highs = input − LP(input), so the
//                   idle split sums back exactly); the low band is driven ~3× harder than the
//                   high band, approximating core saturation being strongest at low frequencies.

import Foundation

// MARK: - shared oversampled memoryless waveshaper

/// One reusable oversampled nonlinear stage: upsample ×os (windowed-sinc polyphase, reusing
/// SoftClipper.prototype), apply a memoryless transfer curve at the high rate, decimate back
/// delay-compensated. Zero net latency, deterministic.
enum NonlinearStage {
    static func shape(_ x: [Float], oversample: Int, transfer: (Double) -> Double) -> [Float] {
        let n = x.count
        guard n > 0 else { return x }
        let os = max(4, oversample)
        let (h, center) = SoftClipper.prototype(oversample: os)
        let L = h.count
        let twoC = 2 * center
        let hiLen = n * os + twoC + L
        var up = [Double](repeating: 0, count: hiLen)
        for q in 0..<n {
            let xv = Double(x[q]) * Double(os)
            if xv == 0 { continue }
            let base = q * os
            for k in 0..<L { up[base + k] += xv * h[k] }
        }
        for m in 0..<hiLen { up[m] = transfer(up[m]) }
        var y = [Float](repeating: 0, count: n)
        for j in 0..<n {
            var acc = 0.0
            let hiBase = j * os + twoC
            for k in 0..<L {
                let idx = hiBase - k
                if idx >= 0 && idx < hiLen { acc += up[idx] * h[k] }
            }
            y[j] = Float(acc)
        }
        return y
    }
}

// MARK: - settings

enum SaturationMode: String, Codable, CaseIterable, Sendable {
    case tape, tube, console, transformer
}

struct SaturationSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    var mode: SaturationMode
    /// Input gain into the shaper, dB. 0 dB already engages the curve gently; clamped 0…24.
    var driveDB: Double
    /// Wet blend 0…1 (dry/wet crossfade — the wet path is delay-compensated, so no comb).
    var mix: Double
    /// Output trim, dB, applied after the blend.
    var outputTrimDB: Double
    /// Oversampling factor for the nonlinearity. 4 minimum.
    var oversample: Int

    init(enabled: Bool, mode: SaturationMode = .tape, driveDB: Double = 6,
         mix: Double = 1.0, outputTrimDB: Double = 0, oversample: Int = 4) {
        self.enabled = enabled
        self.mode = mode
        self.driveDB = min(max(driveDB, 0), 24)
        self.mix = min(max(mix, 0), 1)
        self.outputTrimDB = min(max(outputTrimDB, -24), 24)
        self.oversample = max(4, min(oversample, 8))
    }

    static let bypassed = SaturationSettings(enabled: false)
}

// MARK: - processor

final class Saturator {
    let settings: SaturationSettings
    let sampleRate: Double

    init(settings: SaturationSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let os = settings.oversample
        let d = max(1.0, pow(10.0, settings.driveDB / 20.0))
        let mix = settings.mix
        let trim = pow(10.0, settings.outputTrimDB / 20.0)

        var out = s.channels
        for c in 0..<s.channelCount {
            let dry = s.channels[c]
            var work = dry

            // Tape: emphasize highs into the shaper, restore after (complementary shelf).
            if settings.mode == .tape {
                work = Saturator.biquadPass(work, .highShelf, freq: 3150, gainDB: 4.0, sampleRate: sampleRate)
            }

            var wet: [Float]
            switch settings.mode {
            case .tape:
                wet = NonlinearStage.shape(work, oversample: os) { tanh(d * $0) / d }
                wet = Saturator.biquadPass(wet, .highShelf, freq: 3150, gainDB: -4.0, sampleRate: sampleRate)
            case .tube:
                let bias = 0.15
                let k = tanh(d * bias)
                let norm = d * (1.0 - k * k)          // small-signal derivative → unity gain
                wet = NonlinearStage.shape(work, oversample: os) { (tanh(d * ($0 + bias)) - k) / norm }
                wet = Saturator.dcBlock(wet, sampleRate: sampleRate)
            case .console:
                wet = NonlinearStage.shape(work, oversample: os) { Saturator.cubic(d * $0) / d }
            case .transformer:
                // Complementary split: lows = LP2(x), highs = x − lows (sums back exactly at idle).
                let lows = Saturator.biquadPass(work, .lowPass, freq: 250, gainDB: 0, sampleRate: sampleRate)
                var highs = work
                for i in 0..<highs.count { highs[i] -= lows[i] }
                let dLow = d * 1.8, dHigh = max(1.0, d * 0.6)
                let sLow = NonlinearStage.shape(lows, oversample: os) { tanh(dLow * $0) / dLow }
                let sHigh = NonlinearStage.shape(highs, oversample: os) { tanh(dHigh * $0) / dHigh }
                wet = sLow
                for i in 0..<wet.count where i < sHigh.count { wet[i] += sHigh[i] }
            }

            var y = dry
            let n = min(dry.count, wet.count)
            for i in 0..<n {
                let v = (Double(dry[i]) * (1.0 - mix) + Double(wet[i]) * mix) * trim
                y[i] = Float(min(max(v, -4.0), 4.0))
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    // MARK: - helpers

    /// Cubic soft clip: identity slope at 0, clamps to ±2/3 beyond |u| = 1.
    @inline(__always) static func cubic(_ u: Double) -> Double {
        if u > 1 { return 2.0 / 3.0 }
        if u < -1 { return -2.0 / 3.0 }
        return u - u * u * u / 3.0
    }

    /// One biquad pass over a channel (fresh state — offline, deterministic).
    static func biquadPass(_ x: [Float], _ kind: FilterKind, freq: Double,
                           gainDB: Double, sampleRate: Double) -> [Float] {
        let c = BiquadCoeffs.make(kind, freq: freq, sampleRate: sampleRate, q: 0.707, gainDB: gainDB)
        let bq = Biquad(c)
        var out = x
        for i in 0..<out.count { out[i] = Float(bq.process(Double(x[i]))) }
        return out
    }

    /// One-pole DC blocker (~5 Hz corner) — removes the offset an asymmetric shaper introduces.
    static func dcBlock(_ x: [Float], sampleRate: Double) -> [Float] {
        let r = 1.0 - (2.0 * Double.pi * 5.0 / max(1.0, sampleRate))
        var out = x
        var x1 = 0.0, y1 = 0.0
        for i in 0..<out.count {
            let xv = Double(x[i])
            let y = xv - x1 + r * y1
            x1 = xv; y1 = y
            out[i] = Float(y)
        }
        return out
    }
}
