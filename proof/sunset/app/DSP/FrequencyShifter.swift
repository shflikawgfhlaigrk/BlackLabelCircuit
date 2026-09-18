// FrequencyShifter.swift — single-sideband frequency shifter via a Hilbert-transform FIR.
//
// Contract: offline block processing on AudioSignal; output has identical shape and is
// time-aligned (the FIR group delay is compensated). Bypassed settings (`enabled == false`,
// or shift 0) are a bit-transparent passthrough. Deterministic.
//
// Unlike a pitch shifter, a frequency shifter moves every component by the SAME Δf in Hz,
// destroying harmonic ratios — small shifts phase/detune, large shifts go inharmonic.
// Method: build the analytic signal with a 127-tap windowed (Blackman) FIR Hilbert
// transformer (Q) against a matching pure delay (I), then heterodyne:
//   y = I·cos(2πΔt) − Q·sin(2πΔt)   (positive Δ shifts up, negative shifts down — the sign
// flows straight through the trig, no separate path needed).

import Foundation

struct FrequencyShifterSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    /// Shift, Hz (±5000). 0 = passthrough.
    var shiftHz: Double
    /// Wet blend 0…1.
    var mix: Double

    init(enabled: Bool, shiftHz: Double = 0, mix: Double = 1.0) {
        self.enabled = enabled
        self.shiftHz = min(max(shiftHz, -5000), 5000)
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = FrequencyShifterSettings(enabled: false)
}

final class FrequencyShifter {
    let settings: FrequencyShifterSettings
    let sampleRate: Double
    static let taps = 127                    // odd → integer group delay (taps−1)/2

    init(settings: FrequencyShifterSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, abs(settings.shiftHz) > 1e-9,
              s.channelCount > 0, s.frameCount > 0 else { return s }
        let n = s.frameCount
        let h = FrequencyShifter.hilbertKernel(taps: FrequencyShifter.taps)
        let center = FrequencyShifter.taps / 2
        let w = 2.0 * Double.pi * settings.shiftHz / sampleRate
        let mix = settings.mix

        var out = s.channels
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            let m = min(n, src.count)
            var y = src
            for i in 0..<m {
                // Group-delay-compensated: output sample i is built from input around i,
                // reading `center` samples AHEAD for the causal FIR (offline, so we can).
                let j = i + center                       // virtual "now" of the FIR output
                // I path: pure delay of `center` → the input sample at j − center = i.
                let iPath = Double(src[i])
                // Q path: Hilbert FIR over src[j − taps + 1 … j].
                var q = 0.0
                for t in stride(from: 1, through: center, by: 2) {
                    // Kernel is odd-symmetric with zeros at even offsets — sum only odd taps.
                    let k = h[center + t]
                    let hiIdx = j - (center - t)         // = i + t
                    let loIdx = j - (center + t)         // = i − t
                    let hiV = hiIdx < m ? Double(src[hiIdx]) : 0.0
                    let loV = loIdx >= 0 ? Double(src[loIdx]) : 0.0
                    q += k * (loV - hiV)                 // odd symmetry: h[c+t] = −h[c−t]
                }
                let ph = w * Double(i)
                let shifted = iPath * cos(ph) - q * sin(ph)
                let v = iPath * (1.0 - mix) + shifted * mix
                y[i] = Float(min(max(v, -4.0), 4.0))
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    /// Blackman-windowed FIR Hilbert transformer, odd length. h[center+m] = 2/(πm)·sin²(πm/2)·w(m):
    /// zero at even m, odd-symmetric around the center tap.
    static func hilbertKernel(taps: Int) -> [Double] {
        let center = taps / 2
        var h = [Double](repeating: 0, count: taps)
        for i in 0..<taps {
            let m = i - center
            guard m != 0, m % 2 != 0 else { continue }
            let ideal = 2.0 / (Double.pi * Double(m))
            let win = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(taps - 1))
                          + 0.08 * cos(4 * Double.pi * Double(i) / Double(taps - 1))
            h[i] = ideal * win
        }
        return h
    }
}
