// DeEsser.swift — sibilance-band detector driving wideband or split-band gain reduction.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`) are a bit-transparent passthrough. Deterministic.
//
// Detector: the input filtered to the sibilance band (default 4–10 kHz; 4th-order edges:
// HP×2 at bandLowHz + LP×2 at bandHighHz), stereo-linked max-abs, smoothed by a fast
// attack / medium release follower. A compressor-style computer turns level over threshold
// into gain reduction, capped at maxReductionDB.
//
// Modes:
//   • .wideband  — the whole signal ducks while an ess is hot (classic broadband de-esser).
//   • .splitBand — a phase-coherent Linkwitz-Riley (LR4) crossover at bandLowHz splits the
//     signal; only the HIGH branch rides the gain (out = low + g·high). LR4 sums allpass-flat,
//     so at unity gain the split imposes no magnitude coloring — the detector still listens
//     to the narrower 4–10 kHz band, but the reduction lands on everything above the split
//     (the standard split de-esser topology).
//
// (SpeechLeveler was reviewed for reusable sibilance detection; its detection is
// block-loudness voice-activity classing, not band-envelope work, so nothing genuinely fits.)

import Foundation

enum DeEsserMode: String, Codable, CaseIterable, Sendable {
    case wideband, splitBand
}

struct DeEsserSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    var mode: DeEsserMode
    var bandLowHz: Double
    var bandHighHz: Double
    var thresholdDB: Double
    var ratio: Double
    var attackMs: Double
    var releaseMs: Double
    /// Cap on the reduction, dB (a de-esser should tame, not delete).
    var maxReductionDB: Double

    init(enabled: Bool, mode: DeEsserMode = .splitBand, bandLowHz: Double = 4000,
         bandHighHz: Double = 10_000, thresholdDB: Double = -30, ratio: Double = 4,
         attackMs: Double = 1, releaseMs: Double = 60, maxReductionDB: Double = 12) {
        self.enabled = enabled
        self.mode = mode
        self.bandLowHz = min(max(bandLowHz, 1000), 12_000)
        self.bandHighHz = min(max(bandHighHz, self.bandLowHz + 500), 16_000)
        self.thresholdDB = thresholdDB
        self.ratio = max(1.0, ratio)
        self.attackMs = max(0.05, attackMs)
        self.releaseMs = max(1.0, releaseMs)
        self.maxReductionDB = min(max(maxReductionDB, 0), 24)
    }

    static let bypassed = DeEsserSettings(enabled: false)
}

final class DeEsser {
    let settings: DeEsserSettings
    let sampleRate: Double
    /// Deepest reduction actually applied on the last pass, dB ≥ 0 (measured).
    private(set) var lastReductionDB: Double = 0

    init(settings: DeEsserSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let ch = s.channelCount
        let n = s.frameCount
        let ny = sampleRate * 0.49
        let lo = min(settings.bandLowHz, ny)
        let hi = min(settings.bandHighHz, ny)

        // Detector band per channel: HP×2 at lo + LP×2 at hi (4th-order edges).
        let hpC = BiquadCoeffs.make(.highPass, freq: lo, sampleRate: sampleRate, q: 0.707)
        let lpC = BiquadCoeffs.make(.lowPass, freq: hi, sampleRate: sampleRate, q: 0.707)
        var band = [[Float]](repeating: [Float](repeating: 0, count: n), count: ch)
        for c in 0..<ch {
            let h1 = Biquad(hpC), h2 = Biquad(hpC), l1 = Biquad(lpC), l2 = Biquad(lpC)
            for i in 0..<n {
                var v = Double(s.channels[c][i])
                v = h2.process(h1.process(v))
                v = l2.process(l1.process(v))
                band[c][i] = Float(v)
            }
        }

        // Split-band mode: phase-coherent LR4 crossover at bandLowHz (low + high sum flat).
        var low = [[Double]](repeating: [], count: ch)
        var high = [[Double]](repeating: [], count: ch)
        if settings.mode == .splitBand {
            for c in 0..<ch {
                var lo2 = [Double](repeating: 0, count: n)
                var hi2 = [Double](repeating: 0, count: n)
                let l1 = Biquad(BiquadCoeffs.make(.lowPass, freq: lo, sampleRate: sampleRate, q: 0.707))
                let l2 = Biquad(BiquadCoeffs.make(.lowPass, freq: lo, sampleRate: sampleRate, q: 0.707))
                let h1 = Biquad(BiquadCoeffs.make(.highPass, freq: lo, sampleRate: sampleRate, q: 0.707))
                let h2 = Biquad(BiquadCoeffs.make(.highPass, freq: lo, sampleRate: sampleRate, q: 0.707))
                for i in 0..<n {
                    let x = Double(s.channels[c][i])
                    lo2[i] = l2.process(l1.process(x))
                    hi2[i] = h2.process(h1.process(x))
                }
                low[c] = lo2
                high[c] = hi2
            }
        }

        let aC = exp(-1.0 / (settings.attackMs * 0.001 * sampleRate))
        let rC = exp(-1.0 / (settings.releaseMs * 0.001 * sampleRate))
        let slope = 1.0 - 1.0 / settings.ratio
        var env = 0.0
        var maxRed = 0.0

        var out = s.channels
        for i in 0..<n {
            var det = 0.0
            for c in 0..<ch {
                let a = abs(Double(band[c][i]))
                if a > det { det = a }
            }
            env = det > env ? aC * env + (1 - aC) * det : rC * env + (1 - rC) * det

            let envDB = 20.0 * log10(max(env, 1e-12))
            let over = envDB - settings.thresholdDB
            let redDB = over > 0 ? min(settings.maxReductionDB, over * slope) : 0
            if redDB > maxRed { maxRed = redDB }
            let g = pow(10.0, -redDB / 20.0)

            switch settings.mode {
            case .wideband:
                for c in 0..<ch {
                    out[c][i] = Float(Double(s.channels[c][i]) * g)
                }
            case .splitBand:
                for c in 0..<ch {
                    out[c][i] = Float(low[c][i] + g * high[c][i])
                }
            }
        }
        lastReductionDB = maxRed
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}
