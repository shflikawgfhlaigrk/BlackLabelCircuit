// Sidechain.swift — envelope-driven ducking + transient shaping for the mix stage.
//
// This is the core of the sound the artist asked for:
//   • bass sits UNDER the kick (ducks when the kick hits) → "low, strong, without taking over",
//     and because the two never stack at full level, the low end can't overload / distort;
//   • the music bed ducks UNDER the vocal → "vocals clear, not overwhelming";
//   • risers / FX duck to the kick and stay controlled → they don't run away with the peak;
//   • the kick gets its transient snapped → "strong kick, quick".
// All deterministic, all explainable.

import Foundation

/// User-facing settings for the generalized any-source → any-target ducker.
/// depthDB = max attenuation at a full trigger hit; attack/release shape the pump.
struct DuckerSettings: Equatable, Codable {
    var depthDB: Double
    var attackMs: Double
    var releaseMs: Double

    init(depthDB: Double = 6, attackMs: Double = 5, releaseMs: Double = 120) {
        self.depthDB = min(max(depthDB, 0), 36)
        self.attackMs = max(0, attackMs)
        self.releaseMs = max(1, releaseMs)
    }
}

enum Sidechain {

    /// Generalized ducker: ANY trigger source ducks ANY target (vocal ducks a bed, a lead
    /// ducks a pad, …). Same engine as the kick→bass path below — this is the settings-struct
    /// entry point; the positional overload keeps every existing call site working unchanged.
    static func duck(_ target: AudioSignal, by trigger: AudioSignal,
                     settings: DuckerSettings, sampleRate: Double) -> AudioSignal {
        duck(target, by: trigger, depthDB: settings.depthDB,
             attackMs: settings.attackMs, releaseMs: settings.releaseMs,
             sampleRate: sampleRate)
    }

    /// Duck `target` whenever `trigger` is loud. `depthDB` = max attenuation at a full trigger hit.
    /// attack = how fast the duck engages, release = how fast it recovers (the classic pump).
    static func duck(_ target: AudioSignal, by trigger: AudioSignal,
                     depthDB: Double, attackMs: Double, releaseMs: Double,
                     sampleRate: Double) -> AudioSignal {
        let n = target.frameCount
        guard n > 0, target.channelCount > 0, trigger.frameCount > 0, depthDB > 0.01 else { return target }

        // Trigger detection envelope: rectified max across trigger channels, peak-normalized.
        let trig = monoRect(trigger, length: n)
        var trigPeak = 1e-9
        for v in trig where v > trigPeak { trigPeak = v }
        let invPeak = 1.0 / trigPeak

        // Envelope follower with separate attack/release coefficients.
        let aC = coeff(ms: attackMs, sampleRate: sampleRate)
        let rC = coeff(ms: releaseMs, sampleRate: sampleRate)
        var env = 0.0
        var gain = [Double](repeating: 1, count: n)
        let depthLin = 1.0 - dbToGain(-depthDB)   // fraction removed at env == 1
        for i in 0..<n {
            let x = trig[i] * invPeak            // 0…1
            env = x > env ? aC * env + (1 - aC) * x : rC * env + (1 - rC) * x
            gain[i] = 1.0 - depthLin * min(max(env, 0), 1)
        }

        var out = target.channels
        for c in 0..<out.count {
            let cnt = out[c].count
            for i in 0..<min(cnt, n) { out[c][i] = Float(Double(out[c][i]) * gain[i]) }
        }
        return AudioSignal(channels: out, sampleRate: target.sampleRate)
    }

    /// Emphasize attacks ("strong kick, quick"): boost where a fast envelope outruns a slow one.
    static func transientPunch(_ s: AudioSignal, amount: Double, sampleRate: Double) -> AudioSignal {
        guard amount > 0.01, s.frameCount > 0 else { return s }
        let n = s.frameCount
        let rect = monoRect(s, length: n)
        let fastA = coeff(ms: 0.5, sampleRate: sampleRate), fastR = coeff(ms: 12, sampleRate: sampleRate)
        let slowA = coeff(ms: 12, sampleRate: sampleRate),  slowR = coeff(ms: 90, sampleRate: sampleRate)
        var fast = 0.0, slow = 0.0
        var g = [Double](repeating: 1, count: n)
        for i in 0..<n {
            let x = rect[i]
            fast = x > fast ? fastA * fast + (1 - fastA) * x : fastR * fast + (1 - fastR) * x
            slow = x > slow ? slowA * slow + (1 - slowA) * x : slowR * slow + (1 - slowR) * x
            // transient strength when the fast envelope leads the slow one
            let t = slow > 1e-6 ? (fast / slow) - 1.0 : 0.0
            g[i] = 1.0 + amount * min(max(t, 0), 1.5)
        }
        var out = s.channels
        for c in 0..<out.count {
            for i in 0..<min(out[c].count, n) { out[c][i] = Float(Double(out[c][i]) * g[i]) }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    /// Gentle asymmetric-free soft saturation — adds density/harmonics so the bass reads "strong"
    /// without the hard edges of clipping ("not distorted"). Parallel-blended.
    static func warmth(_ s: AudioSignal, drive: Double, mix: Double) -> AudioSignal {
        let d = max(0.1, drive), m = clampd(mix, 0, 1), dry = 1 - m, norm = 1 / d
        var out = s.channels
        for c in 0..<out.count {
            for i in 0..<out[c].count {
                let x = Double(out[c][i])
                out[c][i] = Float(clampd(dry * x + m * (tanh(d * x) * norm), -4, 4))
            }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    // MARK: - helpers

    /// Rectified mono detection signal (max |.| across channels), length-clamped.
    private static func monoRect(_ s: AudioSignal, length n: Int) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            let m = min(n, src.count)
            for i in 0..<m { let a = abs(Double(src[i])); if a > out[i] { out[i] = a } }
        }
        return out
    }

    /// One-pole smoothing coefficient for a given time constant.
    private static func coeff(ms: Double, sampleRate: Double) -> Double {
        let t = max(0.01, ms) * 0.001
        return exp(-1.0 / (t * max(1, sampleRate)))
    }
    @inline(__always) private static func dbToGain(_ db: Double) -> Double { pow(10, db / 20) }
    @inline(__always) private static func clampd(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        x < lo ? lo : (x > hi ? hi : x)
    }
}
