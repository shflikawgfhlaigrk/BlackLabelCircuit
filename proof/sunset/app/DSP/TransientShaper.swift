// TransientShaper.swift — dual-envelope (fast/slow) difference drives attack/sustain gain.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`, or both gains 0) are a bit-transparent passthrough.
// Deterministic.
//
// Core: two followers run on the same stereo-linked max-abs detector — a fast one (sub-ms
// attack) that jumps on every onset and a slow one that tracks the body of the sound. Where
// the fast envelope LEADS the slow one, the material is transient (attack); where it LAGS,
// the material is sustain/decay. Each region gets its own user gain in dB:
//
//   attackGainDB  > 0 sharpens hits, < 0 softens them;
//   sustainGainDB > 0 pulls up tails/room, < 0 tightens them.
//
// The lead/lag distance in dB is mapped through a 6 dB soft window into 0…1 weights, so the
// applied gain fades in with how strongly transient/sustained the moment actually is (no
// hard switching). The gain smoother is asymmetric: near-instant downward (so a sustain
// boost never bleeds into the next hit's attack) and 1 ms upward (kills zipper noise).

import Foundation

struct TransientShaperSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    /// Gain applied to transient (attack) regions, dB. Clamped ±18.
    var attackGainDB: Double
    /// Gain applied to sustain/decay regions, dB. Clamped ±18.
    var sustainGainDB: Double

    init(enabled: Bool, attackGainDB: Double = 0, sustainGainDB: Double = 0) {
        self.enabled = enabled
        self.attackGainDB = min(max(attackGainDB, -18), 18)
        self.sustainGainDB = min(max(sustainGainDB, -18), 18)
    }

    static let bypassed = TransientShaperSettings(enabled: false)
}

final class TransientShaper {
    let settings: TransientShaperSettings
    let sampleRate: Double

    init(settings: TransientShaperSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0,
              abs(settings.attackGainDB) > 0.01 || abs(settings.sustainGainDB) > 0.01
        else { return s }

        let ch = s.channelCount
        let n = s.frameCount
        let fastA = TransientShaper.coeff(ms: 0.5, sampleRate: sampleRate)
        let fastR = TransientShaper.coeff(ms: 20, sampleRate: sampleRate)
        let slowA = TransientShaper.coeff(ms: 25, sampleRate: sampleRate)
        let slowR = TransientShaper.coeff(ms: 150, sampleRate: sampleRate)
        let smoothUp = TransientShaper.coeff(ms: 1.0, sampleRate: sampleRate)
        let smoothDown = TransientShaper.coeff(ms: 0.05, sampleRate: sampleRate)
        let window = 6.0                                    // dB of lead/lag → full weight

        var fast = 0.0, slow = 0.0, gSm = 1.0
        var out = s.channels
        for i in 0..<n {
            var det = 0.0
            for c in 0..<ch {
                let a = abs(Double(s.channels[c][i]))
                if a > det { det = a }
            }
            fast = det > fast ? fastA * fast + (1 - fastA) * det : fastR * fast + (1 - fastR) * det
            slow = det > slow ? slowA * slow + (1 - slowA) * det : slowR * slow + (1 - slowR) * det

            let diffDB = 20.0 * log10(max(fast, 1e-12)) - 20.0 * log10(max(slow, 1e-12))
            let attackW = min(max(diffDB / window, 0), 1)     // fast leads → transient
            let sustainW = min(max(-diffDB / window, 0), 1)   // fast lags  → sustain
            let gainDB = settings.attackGainDB * attackW + settings.sustainGainDB * sustainW
            let g = pow(10.0, gainDB / 20.0)
            gSm = g + (gSm - g) * (g < gSm ? smoothDown : smoothUp)

            for c in 0..<ch {
                let v = Double(s.channels[c][i]) * gSm
                out[c][i] = Float(min(max(v, -4.0), 4.0))
            }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    static func coeff(ms: Double, sampleRate: Double) -> Double {
        exp(-1.0 / (max(0.01, ms) * 0.001 * max(1.0, sampleRate)))
    }
}
