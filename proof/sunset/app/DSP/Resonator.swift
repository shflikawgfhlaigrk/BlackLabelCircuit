// Resonator.swift — small tuned comb/modal bank: each voice rings at its own frequency.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`, or zero voices) are a bit-transparent passthrough.
// Deterministic.
//
// Each voice is a feedback comb tuned to freqHz: period P = sr/freq (fractional, linear-
// interpolated read so tuning stays accurate between integer sample periods), feedback
// g = 10^(−3·P/(decay·sr)) so the ring decays 60 dB in `decaySeconds`. Voices are summed
// with their per-voice gains and crossfaded with the dry path by `mix`.

import Foundation

struct ResonatorVoice: Equatable, Codable {
    var freqHz: Double
    var decaySeconds: Double
    var gain: Double

    init(freqHz: Double, decaySeconds: Double = 0.8, gain: Double = 1.0) {
        self.freqHz = min(max(freqHz, 20), 8000)
        self.decaySeconds = min(max(decaySeconds, 0.05), 10)
        self.gain = min(max(gain, 0), 2)
    }
}

struct ResonatorSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    var voices: [ResonatorVoice]
    /// Wet blend 0…1.
    var mix: Double

    init(enabled: Bool, voices: [ResonatorVoice] = [], mix: Double = 0.5) {
        self.enabled = enabled
        self.voices = Array(voices.prefix(8))          // "small bank" — cap at 8
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = ResonatorSettings(enabled: false)
}

final class Resonator {
    let settings: ResonatorSettings
    let sampleRate: Double

    init(settings: ResonatorSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, !settings.voices.isEmpty,
              s.channelCount > 0, s.frameCount > 0 else { return s }
        let n = s.frameCount
        let mix = settings.mix
        let voiceNorm = 1.0 / Double(settings.voices.count)

        var out = s.channels
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            let m = min(n, src.count)
            var wet = [Double](repeating: 0, count: m)

            for voice in settings.voices {
                let period = sampleRate / voice.freqHz                       // fractional
                let g = pow(10.0, -3.0 * period / (voice.decaySeconds * sampleRate))
                let bufLen = Int(period) + 4
                var buf = [Double](repeating: 0, count: bufLen)
                var w = 0
                for i in 0..<m {
                    // Fractional feedback read at the tuned period.
                    var rp = Double(w) - period
                    rp -= (rp / Double(bufLen)).rounded(.down) * Double(bufLen)
                    let i0 = Int(rp) % bufLen
                    let frac = rp - Double(Int(rp))
                    let i1 = (i0 + 1) % bufLen
                    let fb = buf[i0] + (buf[i1] - buf[i0]) * frac
                    let y = Double(src[i]) + g * fb
                    buf[w] = y
                    w = (w + 1) % bufLen
                    wet[i] += voice.gain * y * voiceNorm
                }
            }

            var y = src
            for i in 0..<m {
                let v = Double(src[i]) * (1.0 - mix) + wet[i] * mix
                y[i] = Float(min(max(v, -4.0), 4.0))
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}
