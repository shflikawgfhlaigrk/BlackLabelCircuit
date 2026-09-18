// Modulation.swift — shared LFO core + Chorus, Flanger, Phaser, Tremolo, Vibrato, AutoPan.
//
// Contract: every processor here does offline block processing on AudioSignal; output has
// identical shape. Bypassed settings (`enabled == false`) are a bit-transparent passthrough.
// Deterministic — every LFO starts at a fixed phase (0 unless a voice offset is documented),
// so the same input + settings always render the same output.
//
//   • Chorus  — two modulated-delay voices per channel (base ~18 ms, quarter-phase offsets,
//               opposite-channel offset for width), blended with the dry path.
//   • Flanger — one short modulated delay (base ~1 ms) with feedback: the swept comb.
//   • Phaser  — 4 or 8 first-order allpass stages swept exponentially between two corner
//               frequencies, optional feedback, half-wet blend for the classic notches.
//   • Tremolo — pure amplitude modulation: gain 1−depth … 1 (sine).
//   • Vibrato — 100% wet modulated delay = pure pitch modulation.
//   • AutoPan — equal-power pan law swept by the LFO; the L/R gain pair keeps
//               gL² + gR² constant (unity at center).

import Foundation

// MARK: - shared LFO

/// Deterministic sine LFO: value(i) = sin(2π·(rate·i/sr + phase)). Phase is in cycles (0…1).
struct LFO {
    var rateHz: Double
    var phase: Double

    init(rateHz: Double, phase: Double = 0) {
        self.rateHz = max(0, rateHz)
        self.phase = phase
    }

    @inline(__always) func value(at sample: Int, sampleRate: Double) -> Double {
        sin(2.0 * Double.pi * (rateHz * Double(sample) / sampleRate + phase))
    }
}

// MARK: - modulated fractional delay read (shared by chorus/flanger/vibrato)

@inline(__always)
private func fracRead(_ buf: [Double], writeIndex: Int, delay: Double) -> Double {
    let len = Double(buf.count)
    var rp = Double(writeIndex) - delay
    rp -= (rp / len).rounded(.down) * len
    let i0 = Int(rp) % buf.count
    let frac = rp - Double(Int(rp))
    let i1 = (i0 + 1) % buf.count
    return buf[i0] + (buf[i1] - buf[i0]) * frac
}

// MARK: - Chorus

struct ChorusSettings: Equatable, Codable {
    var enabled: Bool
    var rateHz: Double
    var depthMs: Double
    var baseDelayMs: Double
    var mix: Double

    init(enabled: Bool, rateHz: Double = 0.8, depthMs: Double = 5,
         baseDelayMs: Double = 18, mix: Double = 0.5) {
        self.enabled = enabled
        self.rateHz = min(max(rateHz, 0.05), 10)
        self.depthMs = min(max(depthMs, 0.1), 15)
        self.baseDelayMs = min(max(baseDelayMs, 5), 40)
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = ChorusSettings(enabled: false)
}

final class Chorus {
    let settings: ChorusSettings
    let sampleRate: Double

    init(settings: ChorusSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let n = s.frameCount
        let base = settings.baseDelayMs * 0.001 * sampleRate
        let depth = settings.depthMs * 0.001 * sampleRate
        let bufLen = Int(base + depth) + 4
        let mix = settings.mix

        var out = s.channels
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            let m = min(n, src.count)
            // Two voices, quarter-phase apart; opposite channels offset half a cycle.
            let voices = [LFO(rateHz: settings.rateHz, phase: c == 0 ? 0.0 : 0.5),
                          LFO(rateHz: settings.rateHz, phase: c == 0 ? 0.25 : 0.75)]
            var buf = [Double](repeating: 0, count: bufLen)
            var w = 0
            var y = src
            for i in 0..<m {
                buf[w] = Double(src[i])
                var wetV = 0.0
                for v in voices {
                    let d = base + depth * 0.5 * (1.0 + v.value(at: i, sampleRate: sampleRate))
                    wetV += fracRead(buf, writeIndex: w, delay: d)
                }
                wetV *= 0.5
                w = (w + 1) % bufLen
                y[i] = Float(Double(src[i]) * (1.0 - mix) + wetV * mix)
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}

// MARK: - Flanger

struct FlangerSettings: Equatable, Codable {
    var enabled: Bool
    var rateHz: Double
    var depthMs: Double
    var baseDelayMs: Double
    var feedback: Double
    var mix: Double

    init(enabled: Bool, rateHz: Double = 0.25, depthMs: Double = 2,
         baseDelayMs: Double = 1, feedback: Double = 0.5, mix: Double = 0.5) {
        self.enabled = enabled
        self.rateHz = min(max(rateHz, 0.02), 5)
        self.depthMs = min(max(depthMs, 0.1), 10)
        self.baseDelayMs = min(max(baseDelayMs, 0.1), 10)
        self.feedback = min(max(feedback, -0.9), 0.9)
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = FlangerSettings(enabled: false)
}

final class Flanger {
    let settings: FlangerSettings
    let sampleRate: Double

    init(settings: FlangerSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let n = s.frameCount
        let base = settings.baseDelayMs * 0.001 * sampleRate
        let depth = settings.depthMs * 0.001 * sampleRate
        let bufLen = Int(base + depth) + 4
        let mix = settings.mix
        let lfo = LFO(rateHz: settings.rateHz)

        var out = s.channels
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            let m = min(n, src.count)
            var buf = [Double](repeating: 0, count: bufLen)
            var w = 0
            var y = src
            for i in 0..<m {
                let d = base + depth * 0.5 * (1.0 + lfo.value(at: i, sampleRate: sampleRate))
                let echo = fracRead(buf, writeIndex: w, delay: max(1.0, d))
                buf[w] = Double(src[i]) + settings.feedback * echo
                w = (w + 1) % bufLen
                y[i] = Float(Double(src[i]) * (1.0 - mix) + echo * mix)
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}

// MARK: - Phaser

struct PhaserSettings: Equatable, Codable {
    var enabled: Bool
    /// Allpass stage count: 4 or 8.
    var stages: Int
    var rateHz: Double
    var minHz: Double
    var maxHz: Double
    var feedback: Double
    var mix: Double

    init(enabled: Bool, stages: Int = 4, rateHz: Double = 0.3, minHz: Double = 300,
         maxHz: Double = 3000, feedback: Double = 0.2, mix: Double = 0.5) {
        self.enabled = enabled
        self.stages = stages >= 8 ? 8 : 4
        self.rateHz = min(max(rateHz, 0.02), 5)
        self.minHz = min(max(minHz, 40), 10_000)
        self.maxHz = min(max(maxHz, self.minHz + 10), 16_000)
        self.feedback = min(max(feedback, 0), 0.9)
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = PhaserSettings(enabled: false)
}

final class Phaser {
    let settings: PhaserSettings
    let sampleRate: Double

    init(settings: PhaserSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let n = s.frameCount
        let mix = settings.mix
        let lfo = LFO(rateHz: settings.rateHz)
        let ratio = settings.maxHz / settings.minHz

        var out = s.channels
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            let m = min(n, src.count)
            var z = [Double](repeating: 0, count: settings.stages)   // one state per stage
            var fbSample = 0.0
            var y = src
            for i in 0..<m {
                // Exponential sweep between the corners.
                let pos = 0.5 * (1.0 + lfo.value(at: i, sampleRate: sampleRate))
                let fc = settings.minHz * pow(ratio, pos)
                let t = tan(Double.pi * min(fc, sampleRate * 0.49) / sampleRate)
                let a = (t - 1.0) / (t + 1.0)

                var v = Double(src[i]) + settings.feedback * fbSample
                for st in 0..<settings.stages {
                    // First-order allpass: y = a·x + z;  z' = x − a·y.
                    let yAP = a * v + z[st]
                    z[st] = v - a * yAP
                    v = yAP
                }
                fbSample = v
                y[i] = Float(Double(src[i]) * (1.0 - mix) + v * mix)
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}

// MARK: - Tremolo

struct TremoloSettings: Equatable, Codable {
    var enabled: Bool
    var rateHz: Double
    /// Modulation depth 0…1: gain swings 1−depth … 1.
    var depth: Double

    init(enabled: Bool, rateHz: Double = 5, depth: Double = 0.6) {
        self.enabled = enabled
        self.rateHz = min(max(rateHz, 0.05), 20)
        self.depth = min(max(depth, 0), 1)
    }

    static let bypassed = TremoloSettings(enabled: false)
}

final class Tremolo {
    let settings: TremoloSettings
    let sampleRate: Double

    init(settings: TremoloSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, settings.depth > 0, s.channelCount > 0, s.frameCount > 0 else { return s }
        let lfo = LFO(rateHz: settings.rateHz)
        let half = settings.depth * 0.5
        var out = s.channels
        for c in 0..<s.channelCount {
            var y = s.channels[c]
            for i in 0..<y.count {
                let g = 1.0 - half + half * lfo.value(at: i, sampleRate: sampleRate)
                y[i] = Float(Double(y[i]) * g)
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}

// MARK: - Vibrato

struct VibratoSettings: Equatable, Codable {
    var enabled: Bool
    var rateHz: Double
    /// Delay modulation depth, ms (sets the pitch-bend width).
    var depthMs: Double

    init(enabled: Bool, rateHz: Double = 5, depthMs: Double = 2) {
        self.enabled = enabled
        self.rateHz = min(max(rateHz, 0.1), 12)
        self.depthMs = min(max(depthMs, 0.1), 8)
    }

    static let bypassed = VibratoSettings(enabled: false)
}

final class Vibrato {
    let settings: VibratoSettings
    let sampleRate: Double

    init(settings: VibratoSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let base = (settings.depthMs + 1.0) * 0.001 * sampleRate
        let depth = settings.depthMs * 0.001 * sampleRate
        let bufLen = Int(base + depth) + 4
        let lfo = LFO(rateHz: settings.rateHz)

        var out = s.channels
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            var buf = [Double](repeating: 0, count: bufLen)
            var w = 0
            var y = src
            for i in 0..<src.count {
                buf[w] = Double(src[i])
                let d = base + depth * 0.5 * lfo.value(at: i, sampleRate: sampleRate)
                y[i] = Float(fracRead(buf, writeIndex: w, delay: max(1.0, d)))   // 100% wet
                w = (w + 1) % bufLen
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}

// MARK: - AutoPan

struct AutoPanSettings: Equatable, Codable {
    var enabled: Bool
    var rateHz: Double
    /// Pan sweep width 0…1 (1 = full left↔right).
    var depth: Double

    init(enabled: Bool, rateHz: Double = 1, depth: Double = 0.8) {
        self.enabled = enabled
        self.rateHz = min(max(rateHz, 0.05), 10)
        self.depth = min(max(depth, 0), 1)
    }

    static let bypassed = AutoPanSettings(enabled: false)
}

final class AutoPan {
    let settings: AutoPanSettings
    let sampleRate: Double

    init(settings: AutoPanSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, settings.depth > 0, s.channelCount >= 2, s.frameCount > 0 else { return s }
        let lfo = LFO(rateHz: settings.rateHz)
        let root2 = 2.0.squareRoot()
        var out = s.channels
        var l = s.channels[0]
        var r = s.channels[1]
        let m = min(l.count, r.count)
        for i in 0..<m {
            let pan = settings.depth * lfo.value(at: i, sampleRate: sampleRate)   // −1…1
            let theta = (pan + 1.0) * 0.25 * Double.pi
            // √2-normalized equal-power pair: unity at center, gL²+gR² constant.
            let gL = root2 * cos(theta)
            let gR = root2 * sin(theta)
            l[i] = Float(Double(l[i]) * gL)
            r[i] = Float(Double(r[i]) * gR)
        }
        out[0] = l
        out[1] = r
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}
