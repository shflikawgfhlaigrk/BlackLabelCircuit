// Reverb.swift — 8-line feedback-delay-network (FDN) reverb with Householder feedback.
//
// Contract: offline block processing on AudioSignal; output has identical shape (the tail
// lives inside the input's frame count — this is an insert, not a tail-extending renderer).
// Bypassed settings (`enabled == false`) are a bit-transparent passthrough. Deterministic:
// all line lengths, diffusion delays and tap signs are fixed constants — no randomness.
//
// Topology: input → mono fold → predelay → 4 series allpass diffusers → injected into 8
// delay lines (alternating signs). Feedback is the Householder reflection
// (v_i = out_i − (2/N)·Σ out), which is lossless by construction, so the decay rate is set
// ENTIRELY by the per-line gains g_i = 10^(−3·D_i / (RT60·sr)) — every line decays 60 dB in
// `decaySeconds`, which is what makes the measured RT60 land on the setting. A one-pole
// low-pass (dampingHz) inside each loop rolls the highs off faster, like air/walls do.
// Two ±-sign tap sets decorrelate the L and R wet outputs.
//
// Presets choose line-length ranges + diffusion character: room (short), hall (long),
// plate (dense, bright), chamber (between), spring (a longer chain of short allpasses for
// the dispersive "boing" color — a best-effort approximation of real spring dispersion,
// not a physical model). `reverse` renders reverse-reverb: reverse → reverb → reverse.

import Foundation

enum ReverbPreset: String, Codable, CaseIterable, Sendable {
    case room, hall, plate, chamber, spring
}

struct ReverbSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    var preset: ReverbPreset
    /// RT60 decay target, seconds. Clamped 0.1…20.
    var decaySeconds: Double
    var predelayMs: Double
    /// Scales the delay-line lengths (0.5…2 — small to big space).
    var size: Double
    /// In-loop low-pass corner, Hz — lower = darker, faster HF decay.
    var dampingHz: Double
    /// Wet blend 0…1 (0 = dry only, 1 = wet only).
    var mix: Double
    /// Reverse-reverb render mode: reverse → reverb → reverse.
    var reverse: Bool

    init(enabled: Bool, preset: ReverbPreset = .hall, decaySeconds: Double = 1.8,
         predelayMs: Double = 20, size: Double = 1.0, dampingHz: Double = 6000,
         mix: Double = 0.3, reverse: Bool = false) {
        self.enabled = enabled
        self.preset = preset
        self.decaySeconds = min(max(decaySeconds, 0.1), 20)
        self.predelayMs = min(max(predelayMs, 0), 500)
        self.size = min(max(size, 0.5), 2)
        self.dampingHz = min(max(dampingHz, 500), 20_000)
        self.mix = min(max(mix, 0), 1)
        self.reverse = reverse
    }

    static let bypassed = ReverbSettings(enabled: false)
}

final class Reverb {
    let settings: ReverbSettings
    let sampleRate: Double

    init(settings: ReverbSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    // Base line lengths in samples at 44.1 kHz — mutually prime so modes don't stack.
    private static func baseDelays(_ preset: ReverbPreset) -> [Int] {
        switch preset {
        case .room:    return [571, 647, 809, 887, 1013, 1153, 1259, 1409]
        case .hall:    return [1031, 1327, 1523, 1801, 2053, 2311, 2617, 2903]
        case .plate:   return [389, 503, 613, 727, 839, 953, 1069, 1181]
        case .chamber: return [769, 907, 1049, 1201, 1361, 1499, 1657, 1811]
        case .spring:  return [449, 587, 701, 823, 941, 1063, 1187, 1301]
        }
    }

    // Series allpass diffuser delays (samples at 44.1 kHz) + gain per preset.
    private static func diffusion(_ preset: ReverbPreset) -> (delays: [Int], gain: Double) {
        switch preset {
        case .room:    return ([107, 142, 277, 379], 0.62)
        case .hall:    return ([113, 179, 293, 401], 0.70)
        case .plate:   return ([73, 101, 139, 181, 227, 269], 0.74)
        case .chamber: return ([109, 151, 283, 383], 0.68)
        // Spring: a longer chain of short allpasses = the chirpy dispersive smear.
        case .spring:  return ([61, 79, 97, 113, 131, 149, 167, 181, 199, 223, 239, 257], 0.68)
        }
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        if settings.reverse {
            let rev = Reverb.reversed(s)
            let wet = renderForward(rev)
            return Reverb.reversed(wet)
        }
        return renderForward(s)
    }

    private func renderForward(_ s: AudioSignal) -> AudioSignal {
        let n = s.frameCount
        let ch = s.channelCount
        let srScale = sampleRate / 44_100.0
        let mix = settings.mix

        // Mono-fold input drive.
        var input = [Double](repeating: 0, count: n)
        for c in 0..<ch {
            let src = s.channels[c]
            let m = min(n, src.count)
            for i in 0..<m { input[i] += Double(src[i]) }
        }
        let chNorm = 1.0 / Double(ch)
        for i in 0..<n { input[i] *= chNorm }

        // Predelay.
        let pre = Int(settings.predelayMs * 0.001 * sampleRate)

        // Diffusers (series allpasses): y[n] = −g·x[n] + x[n−D] + g·y[n−D].
        let (difDelays, difGain) = Reverb.diffusion(settings.preset)
        var difBufX = difDelays.map { [Double](repeating: 0, count: max(1, Int(Double($0) * srScale))) }
        var difBufY = difDelays.map { [Double](repeating: 0, count: max(1, Int(Double($0) * srScale))) }
        var difIdx = [Int](repeating: 0, count: difDelays.count)

        // FDN lines.
        let N = 8
        let delays = Reverb.baseDelays(settings.preset).map {
            max(2, Int(Double($0) * settings.size * srScale))
        }
        var lines = delays.map { [Double](repeating: 0, count: $0) }
        var lineIdx = [Int](repeating: 0, count: N)
        // 60 dB in decaySeconds: g_i = 10^(−3·D_i/(RT60·sr)).
        let gains = delays.map { pow(10.0, -3.0 * Double($0) / (settings.decaySeconds * sampleRate)) }
        // In-loop damping one-pole LP state per line.
        let dampC = exp(-2.0 * Double.pi * min(settings.dampingHz, sampleRate * 0.49) / sampleRate)
        var dampState = [Double](repeating: 0, count: N)

        // Injection + output tap signs (fixed): decorrelate lines and L/R.
        let inject: [Double] = [1, -1, 1, -1, 1, -1, 1, -1]
        let tapL: [Double] = [1, 0, 1, 0, -1, 0, -1, 0]
        let tapR: [Double] = [0, 1, 0, -1, 0, 1, 0, -1]
        let outNorm = 0.5

        var wetL = [Double](repeating: 0, count: n)
        var wetR = [Double](repeating: 0, count: n)

        for i in 0..<n {
            // Predelayed, diffused drive.
            var drive = i >= pre ? input[i - pre] : 0.0
            for a in 0..<difBufX.count {
                let D = difBufX[a].count
                let idx = difIdx[a]
                let xD = difBufX[a][idx]
                let yD = difBufY[a][idx]
                let y = -difGain * drive + xD + difGain * yD
                difBufX[a][idx] = drive
                difBufY[a][idx] = y
                difIdx[a] = (idx + 1) % D
                drive = y
            }

            // Read line outputs.
            var outs = [Double](repeating: 0, count: N)
            var sum = 0.0
            for l in 0..<N {
                outs[l] = lines[l][lineIdx[l]]
                sum += outs[l]
            }
            let hh = 2.0 / Double(N) * sum

            // Wet taps.
            var wl = 0.0, wr = 0.0
            for l in 0..<N {
                wl += tapL[l] * outs[l]
                wr += tapR[l] * outs[l]
            }
            wetL[i] = wl * outNorm
            wetR[i] = wr * outNorm

            // Householder feedback + damping + per-line decay gain, write back.
            for l in 0..<N {
                let fb = outs[l] - hh                                   // lossless reflection
                dampState[l] = dampC * dampState[l] + (1 - dampC) * fb  // in-loop LP
                lines[l][lineIdx[l]] = inject[l] * drive + gains[l] * dampState[l]
                lineIdx[l] = (lineIdx[l] + 1) % lines[l].count
            }
        }

        // Blend: stereo wet over the dry input (mono wet duplicated if the input is mono).
        var out = s.channels
        for c in 0..<ch {
            let wet = (c == 0 || ch == 1) ? wetL : wetR
            var y = s.channels[c]
            let m = min(n, y.count)
            for i in 0..<m {
                let v = Double(y[i]) * (1.0 - mix) + wet[i] * mix
                y[i] = Float(min(max(v, -4.0), 4.0))
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    static func reversed(_ s: AudioSignal) -> AudioSignal {
        AudioSignal(channels: s.channels.map { Array($0.reversed()) }, sampleRate: s.sampleRate)
    }
}
