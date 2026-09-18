// Exciter.swift — band-split harmonic exciter (presence + air) blended back into the dry path.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`, or both amounts 0) are a bit-transparent passthrough.
// Deterministic.
//
// Two generator bands are split off the input:
//   • presence — HP at presenceHz, then LP at airHz (the body/bite band);
//   • air      — HP at airHz (the sheen band);
// each is driven through the shared oversampled asymmetric shaper (biased tanh → both even
// and odd harmonics, the "exciter" character; ≥4× oversampled so nothing folds back),
// DC-blocked, and then the CLEAN band is subtracted from the shaped band (shaped − band =
// generated harmonics only — phase-aligned because the shaper is zero-latency) before the
// residual is added back to the untouched dry signal at its own amount. The dry path is
// never filtered — an exciter only adds harmonics, it does not re-boost the band itself.

import Foundation

struct ExciterSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    /// Presence band lower edge, Hz.
    var presenceHz: Double
    /// Air band lower edge, Hz (also the presence band's upper edge).
    var airHz: Double
    var presenceDriveDB: Double
    var airDriveDB: Double
    /// Blend of generated presence harmonics, 0…1.
    var presenceAmount: Double
    /// Blend of generated air harmonics, 0…1.
    var airAmount: Double
    /// Oversampling factor for the shaper. 4 minimum.
    var oversample: Int

    init(enabled: Bool, presenceHz: Double = 3000, airHz: Double = 8000,
         presenceDriveDB: Double = 12, airDriveDB: Double = 12,
         presenceAmount: Double = 0.2, airAmount: Double = 0.2, oversample: Int = 4) {
        self.enabled = enabled
        self.presenceHz = min(max(presenceHz, 500), 10_000)
        self.airHz = min(max(airHz, self.presenceHz + 500), 16_000)
        self.presenceDriveDB = min(max(presenceDriveDB, 0), 24)
        self.airDriveDB = min(max(airDriveDB, 0), 24)
        self.presenceAmount = min(max(presenceAmount, 0), 1)
        self.airAmount = min(max(airAmount, 0), 1)
        self.oversample = max(4, min(oversample, 8))
    }

    static let bypassed = ExciterSettings(enabled: false)
}

final class Exciter {
    let settings: ExciterSettings
    let sampleRate: Double

    init(settings: ExciterSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0,
              settings.presenceAmount > 0 || settings.airAmount > 0 else { return s }
        let ny = sampleRate * 0.49
        let pHz = min(settings.presenceHz, ny)
        let aHz = min(settings.airHz, ny)
        let os = settings.oversample

        var out = s.channels
        for c in 0..<s.channelCount {
            let dry = s.channels[c]
            var y = dry

            if settings.presenceAmount > 0 {
                var band = Saturator.biquadPass(dry, .highPass, freq: pHz, gainDB: 0, sampleRate: sampleRate)
                band = Saturator.biquadPass(band, .lowPass, freq: aHz, gainDB: 0, sampleRate: sampleRate)
                let shaped = Exciter.harmonics(band, driveDB: settings.presenceDriveDB,
                                               oversample: os, sampleRate: sampleRate)
                let amt = settings.presenceAmount
                for i in 0..<min(y.count, min(shaped.count, band.count)) {
                    let residual = Double(shaped[i]) - Double(band[i])     // harmonics only
                    y[i] = Float(min(max(Double(y[i]) + amt * residual, -4.0), 4.0))
                }
            }
            if settings.airAmount > 0 {
                let band = Saturator.biquadPass(dry, .highPass, freq: aHz, gainDB: 0, sampleRate: sampleRate)
                let shaped = Exciter.harmonics(band, driveDB: settings.airDriveDB,
                                               oversample: os, sampleRate: sampleRate)
                let amt = settings.airAmount
                for i in 0..<min(y.count, min(shaped.count, band.count)) {
                    let residual = Double(shaped[i]) - Double(band[i])     // harmonics only
                    y[i] = Float(min(max(Double(y[i]) + amt * residual, -4.0), 4.0))
                }
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    /// Oversampled biased-tanh harmonic generator (even + odd), DC-blocked.
    static func harmonics(_ x: [Float], driveDB: Double, oversample: Int,
                          sampleRate: Double) -> [Float] {
        let d = max(1.0, pow(10.0, driveDB / 20.0))
        let bias = 0.2
        let k = tanh(d * bias)
        let norm = d * (1.0 - k * k)
        let shaped = NonlinearStage.shape(x, oversample: oversample) {
            (tanh(d * ($0 + bias)) - k) / norm
        }
        return Saturator.dcBlock(shaped, sampleRate: sampleRate)
    }
}
