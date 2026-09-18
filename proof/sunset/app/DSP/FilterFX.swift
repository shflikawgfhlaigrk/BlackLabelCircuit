// FilterFX.swift — swept filter effect: HP / LP / BP / comb, driven by an LFO or an
// envelope follower.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`) are a bit-transparent passthrough. Deterministic — the LFO
// starts at phase 0 and the envelope source is peak-normalized against the input itself.
//
// Sweep position (0…1) → cutoff mapped exponentially minHz…maxHz:
//   • .none     — parked at maxHz (set minHz == maxHz for a fixed filter);
//   • .lfo      — sine sweep at rateHz;
//   • .envelope — attack/release follower on the stereo-linked input, peak-normalized, so
//                 louder playing opens the filter (the auto-wah/env-filter behavior).
//
// HP/LP/BP are RBJ biquads (resonance = Q), coefficients recomputed every 16 samples along
// the sweep (states kept — small steps stay artifact-free). Comb is a feedback comb whose
// delay sweeps sr/maxHz…sr/minHz (fractional read), fixed 0.85 feedback for a strong series
// of notches/peaks.

import Foundation

enum FilterFXShape: String, Codable, CaseIterable, Sendable {
    case lowPass, highPass, bandPass, comb
}

enum FilterFXSweepSource: String, Codable, CaseIterable, Sendable {
    case none, lfo, envelope
}

struct FilterFXSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    var shape: FilterFXShape
    var sweep: FilterFXSweepSource
    var minHz: Double
    var maxHz: Double
    /// LFO sweep rate, Hz.
    var rateHz: Double
    /// Envelope-sweep attack/release, ms.
    var envAttackMs: Double
    var envReleaseMs: Double
    /// Filter resonance (Q) for HP/LP/BP.
    var resonance: Double
    /// Wet blend 0…1.
    var mix: Double

    init(enabled: Bool, shape: FilterFXShape = .lowPass, sweep: FilterFXSweepSource = .lfo,
         minHz: Double = 200, maxHz: Double = 8000, rateHz: Double = 0.5,
         envAttackMs: Double = 5, envReleaseMs: Double = 120,
         resonance: Double = 2, mix: Double = 1.0) {
        self.enabled = enabled
        self.shape = shape
        self.sweep = sweep
        self.minHz = min(max(minHz, 20), 16_000)
        self.maxHz = min(max(maxHz, self.minHz), 16_000)
        self.rateHz = min(max(rateHz, 0.02), 10)
        self.envAttackMs = max(0.1, envAttackMs)
        self.envReleaseMs = max(1.0, envReleaseMs)
        self.resonance = min(max(resonance, 0.5), 12)
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = FilterFXSettings(enabled: false)
}

final class FilterFX {
    let settings: FilterFXSettings
    let sampleRate: Double

    init(settings: FilterFXSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let ch = s.channelCount
        let n = s.frameCount
        let mix = settings.mix
        let ny = sampleRate * 0.49
        let lo = min(settings.minHz, ny)
        let hi = min(max(settings.maxHz, lo), ny)
        let ratio = hi / lo

        // ---- sweep source: 0…1 per sample ----
        var pos = [Double](repeating: 1.0, count: n)
        switch settings.sweep {
        case .none:
            break                                            // parked at maxHz
        case .lfo:
            let lfo = LFO(rateHz: settings.rateHz)
            for i in 0..<n { pos[i] = 0.5 * (1.0 + lfo.value(at: i, sampleRate: sampleRate)) }
        case .envelope:
            // Stereo-linked rectified detector, peak-normalized (deterministic).
            var det = [Double](repeating: 0, count: n)
            var peak = 1e-9
            for c in 0..<ch {
                let src = s.channels[c]
                for i in 0..<min(n, src.count) {
                    let a = abs(Double(src[i]))
                    if a > det[i] { det[i] = a }
                    if a > peak { peak = a }
                }
            }
            let aC = exp(-1.0 / (settings.envAttackMs * 0.001 * sampleRate))
            let rC = exp(-1.0 / (settings.envReleaseMs * 0.001 * sampleRate))
            var env = 0.0
            let inv = 1.0 / peak
            for i in 0..<n {
                let x = det[i] * inv
                env = x > env ? aC * env + (1 - aC) * x : rC * env + (1 - rC) * x
                pos[i] = min(max(env, 0), 1)
            }
        }

        var out = s.channels

        if settings.shape == .comb {
            // Feedback comb, delay swept sr/hi … sr/lo (pos 0 → lowest cutoff → longest delay).
            let dMin = sampleRate / hi
            let dMax = sampleRate / lo
            let bufLen = Int(dMax) + 4
            let fb = 0.85
            for c in 0..<ch {
                let src = s.channels[c]
                let m = min(n, src.count)
                var buf = [Double](repeating: 0, count: bufLen)
                var w = 0
                var y = src
                for i in 0..<m {
                    let d = dMax + (dMin - dMax) * pos[i]
                    var rp = Double(w) - d
                    rp -= (rp / Double(bufLen)).rounded(.down) * Double(bufLen)
                    let i0 = Int(rp) % bufLen
                    let frac = rp - Double(Int(rp))
                    let i1 = (i0 + 1) % bufLen
                    let echo = buf[i0] + (buf[i1] - buf[i0]) * frac
                    let v = Double(src[i]) + fb * echo
                    buf[w] = v
                    w = (w + 1) % bufLen
                    let blended = Double(src[i]) * (1.0 - mix) + v * 0.5 * mix
                    y[i] = Float(min(max(blended, -4.0), 4.0))
                }
                out[c] = y
            }
            return AudioSignal(channels: out, sampleRate: s.sampleRate)
        }

        // ---- biquad shapes, coefficients re-derived every 16 samples along the sweep ----
        let kind: FilterKind? = settings.shape == .lowPass ? .lowPass
                              : settings.shape == .highPass ? .highPass : nil
        func coeffs(_ fc: Double) -> BiquadCoeffs {
            if let k = kind {
                return BiquadCoeffs.make(k, freq: fc, sampleRate: sampleRate, q: settings.resonance)
            }
            return DynamicEQ.bandpass(freq: fc, q: settings.resonance, sampleRate: sampleRate)
        }
        let filters = (0..<ch).map { _ in Biquad(coeffs(lo * pow(ratio, pos[0]))) }
        let block = 16
        var i = 0
        while i < n {
            let end = min(i + block, n)
            let fc = lo * pow(ratio, pos[i])
            let c = coeffs(fc)
            for f in filters { f.c = c }
            for cc in 0..<ch {
                let src = s.channels[cc]
                for j in i..<min(end, src.count) {
                    let wet = filters[cc].process(Double(src[j]))
                    let v = Double(src[j]) * (1.0 - mix) + wet * mix
                    out[cc][j] = Float(min(max(v, -4.0), 4.0))
                }
            }
            i = end
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}
