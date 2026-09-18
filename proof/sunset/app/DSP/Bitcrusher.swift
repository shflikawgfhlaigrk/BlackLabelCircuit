// Bitcrusher.swift — bit-depth reduction + sample-rate decimation (sample-and-hold).
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`) are a bit-transparent passthrough. Deterministic — the
// quantizer is a plain round (no dither noise, so the same input always crushes the same way).
//
// The aliasing and quantization grit this produces are the EFFECT — deliberately NOT
// oversampled or anti-aliased (unlike the saturation/distortion stages, whose spec rule
// covers musical nonlinearities, not lo-fi decimators).
//
//   • bits       — quantization depth 2…24; each sample snaps to the nearest of 2^bits levels.
//   • downsample — hold factor 1…64; every Nth sample is sampled, then held (zero-order hold).
//   • mix        — dry/wet crossfade (both paths sample-aligned; the crush adds no latency).

import Foundation

struct BitcrusherSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    /// Quantization depth, bits. Clamped 2…24.
    var bits: Int
    /// Sample-hold factor. 1 = no decimation. Clamped 1…64.
    var downsample: Int
    /// Wet blend 0…1.
    var mix: Double

    init(enabled: Bool, bits: Int = 8, downsample: Int = 4, mix: Double = 1.0) {
        self.enabled = enabled
        self.bits = min(max(bits, 2), 24)
        self.downsample = min(max(downsample, 1), 64)
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = BitcrusherSettings(enabled: false)
}

final class Bitcrusher {
    let settings: BitcrusherSettings

    init(settings: BitcrusherSettings) {
        self.settings = settings
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let levels = pow(2.0, Double(settings.bits - 1))    // ± levels around zero
        let hold = settings.downsample
        let mix = settings.mix

        var out = s.channels
        for c in 0..<s.channelCount {
            let dry = s.channels[c]
            var y = dry
            var held = 0.0
            for i in 0..<dry.count {
                if i % hold == 0 {                           // sample …
                    let x = Double(dry[i])
                    held = (x * levels).rounded() / levels   // … quantize …
                }
                //                                            … and hold.
                let v = Double(dry[i]) * (1.0 - mix) + held * mix
                y[i] = Float(min(max(v, -1.0), 1.0))
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}
