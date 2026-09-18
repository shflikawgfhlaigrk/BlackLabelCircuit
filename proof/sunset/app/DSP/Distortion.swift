// Distortion.swift — oversampled distortion (overdrive / fuzz / hard clip) with post-shape tone.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`) are a bit-transparent passthrough. Deterministic. The
// nonlinearity always runs ≥4× oversampled through NonlinearStage (Saturation.swift), so
// harmonics generated above the audio band are filtered instead of aliasing back.
//
// Modes:
//   • overdrive — atan soft clip, normalized to unity small-signal gain (drive sets how hard
//                 the knee is hit, not the level). Odd harmonics, smooth.
//   • fuzz      — exponential-approach clipper sign(x)·(1 − e^(−d|x|)), normalized so a
//                 full-scale input maps to full scale. Aggressive, dense odd harmonics and a
//                 raised small-signal gain — the classic fuzz "everything slams the ceiling".
//   • hardClip  — clamp(d·x, ±1)/d: a true hard clipper whose ceiling sits at 1/drive.
//
// `toneHz` is a post-shape one-pole low-pass tilt (the familiar distortion-pedal tone knob):
// lower = darker. `mix` is a dry/wet crossfade; the wet path is delay-compensated.

import Foundation

enum DistortionMode: String, Codable, CaseIterable, Sendable {
    case overdrive, fuzz, hardClip
}

struct DistortionSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    var mode: DistortionMode
    /// Input gain into the shaper, dB. Clamped 0…36.
    var driveDB: Double
    /// Post-shape low-pass tone corner, Hz. Clamped 500…20000.
    var toneHz: Double
    /// Wet blend 0…1.
    var mix: Double
    /// Oversampling factor for the nonlinearity. 4 minimum.
    var oversample: Int

    init(enabled: Bool, mode: DistortionMode = .overdrive, driveDB: Double = 12,
         toneHz: Double = 6000, mix: Double = 1.0, oversample: Int = 4) {
        self.enabled = enabled
        self.mode = mode
        self.driveDB = min(max(driveDB, 0), 36)
        self.toneHz = min(max(toneHz, 500), 20_000)
        self.mix = min(max(mix, 0), 1)
        self.oversample = max(4, min(oversample, 8))
    }

    static let bypassed = DistortionSettings(enabled: false)
}

final class Distortion {
    let settings: DistortionSettings
    let sampleRate: Double

    init(settings: DistortionSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let os = settings.oversample
        let d = max(1.0, pow(10.0, settings.driveDB / 20.0))
        let mix = settings.mix

        // Memoryless transfer for the selected mode.
        let transfer: (Double) -> Double
        switch settings.mode {
        case .overdrive:
            transfer = { atan(d * $0) / d }                       // unity small-signal gain
        case .fuzz:
            let norm = 1.0 - exp(-d)                              // f(±1) → ±1
            transfer = { x in
                let a = 1.0 - exp(-d * abs(x))
                return (x < 0 ? -a : a) / norm
            }
        case .hardClip:
            transfer = { min(max(d * $0, -1.0), 1.0) / d }        // ceiling at 1/drive
        }

        // Post-shape one-pole low-pass tone coefficient.
        let toneCoeff = exp(-2.0 * Double.pi * settings.toneHz / sampleRate)

        var out = s.channels
        for c in 0..<s.channelCount {
            let dry = s.channels[c]
            var wet = NonlinearStage.shape(dry, oversample: os, transfer: transfer)
            var lp = 0.0
            for i in 0..<wet.count {
                lp = toneCoeff * lp + (1.0 - toneCoeff) * Double(wet[i])
                wet[i] = Float(lp)
            }
            var y = dry
            let n = min(dry.count, wet.count)
            for i in 0..<n {
                let v = Double(dry[i]) * (1.0 - mix) + Double(wet[i]) * mix
                y[i] = Float(min(max(v, -4.0), 4.0))
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}
