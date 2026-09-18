// RingMod.swift — ring modulator: multiply by a carrier oscillator.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`) are a bit-transparent passthrough. Deterministic — the
// carrier is a sine starting at phase 0.
//
// y = x · sin(2π·carrierHz·t). For a tone at f the fully-wet output is the sideband pair
// f ± carrier with the original suppressed — the classic metallic/bell character. `mix`
// crossfades dry/wet.

import Foundation

struct RingModSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    /// Carrier frequency, Hz. Clamped 1…10000.
    var carrierHz: Double
    /// Wet blend 0…1.
    var mix: Double

    init(enabled: Bool, carrierHz: Double = 440, mix: Double = 1.0) {
        self.enabled = enabled
        self.carrierHz = min(max(carrierHz, 1), 10_000)
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = RingModSettings(enabled: false)
}

final class RingModulator {
    let settings: RingModSettings
    let sampleRate: Double

    init(settings: RingModSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let w = 2.0 * Double.pi * settings.carrierHz / sampleRate
        let mix = settings.mix
        var out = s.channels
        for c in 0..<s.channelCount {
            var y = s.channels[c]
            for i in 0..<y.count {
                let x = Double(y[i])
                let v = x * (1.0 - mix) + (x * sin(w * Double(i))) * mix
                y[i] = Float(v)
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}
