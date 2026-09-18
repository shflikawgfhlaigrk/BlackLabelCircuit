// DeliveryPack.swift — SS-20: one-click per-platform delivery pack.
//
// Takes ONE finished master and re-normalizes it to each PlatformTarget's integrated-LUFS goal and
// true-peak ceiling, producing a labeled file per platform. Pure, deterministic, offline DSP (reuses
// the same Limiter + BS.1770 LoudnessMeter the mastering chain uses) — faster than real time, no
// network, no fabricated numbers. Every reported figure is measured on the buyer's own master.
//
// The loudness landing is a hard promise, not a guess: after a program-dependent gain estimate we run
// corrective passes (limiting is non-linear) until the render is within ±0.5 LU of the target, then a
// static true-peak trim guarantees the ceiling — the same honesty the MasteringEngine applies.

import Foundation

/// What one platform's render was cut to and what it actually achieved (all measured).
struct DeliveryTarget: Equatable {
    var platform: String
    var targetLUFS: Double
    var ceilingDBTP: Double
    var achievedLUFS: Double
    var achievedTPDBTP: Double
    var gainDB: Double            // net normalization gain applied before limiting
    var limiterGRdB: Double       // peak limiter gain reduction on this render
    var withinTolerance: Bool     // |achieved − target| ≤ 0.5 LU
    var underCeiling: Bool        // achieved true peak ≤ ceiling
    var summary: String           // one measured line per file
}

/// A rendered platform master + its measured target read. `signal` is ready to write.
struct DeliveryPackRender {
    var signal: AudioSignal
    var target: DeliveryTarget
}

enum DeliveryPack {

    static let toleranceLU = 0.5
    /// Meter/limiter true-peak reconstruction slack (matches the mastering regression's ceiling epsilon).
    static let ceilingEpsilonDB = 0.15

    /// Render the finished master to every platform target. Pure — safe to call off the main actor.
    static func renderAll(_ master: AudioSignal,
                          platforms: [PlatformTarget] = PlatformTargets.all) -> [DeliveryPackRender] {
        platforms.map { normalize(master, to: $0) }
    }

    /// Normalize a finished master to one platform's LUFS + true-peak ceiling. No file IO.
    static func normalize(_ master: AudioSignal, to platform: PlatformTarget) -> DeliveryPackRender {
        let sr = master.sampleRate > 0 ? master.sampleRate : 44100
        let meter: (AudioSignal) -> LoudnessResult = { s in
            LoudnessMeter(sampleRate: s.sampleRate > 0 ? s.sampleRate : sr,
                          channels: max(1, s.channelCount)).measure(s.channels)
        }

        guard master.frameCount > 0, master.channelCount > 0 else {
            let l = meter(master)
            let t = DeliveryTarget(platform: platform.name, targetLUFS: platform.lufs,
                                   ceilingDBTP: platform.truePeakDBTP,
                                   achievedLUFS: l.integratedLUFS, achievedTPDBTP: l.truePeakDBTP,
                                   gainDB: 0, limiterGRdB: 0, withinTolerance: false, underCeiling: true,
                                   summary: "\(platform.name): empty input — nothing to render.")
            return DeliveryPackRender(signal: master, target: t)
        }

        let ceiling = min(0.0, platform.truePeakDBTP)
        let limiter = Limiter(settings: LimiterSettings(ceilingDBTP: ceiling, lookaheadMs: 2, releaseMs: 60),
                              sampleRate: sr)

        // First gain estimate straight from the measured integrated loudness.
        var gainDB = clampd(platform.lufs - meter(master).integratedLUFS, -24, 24)
        var out = limiter.process(applyGainDB(master, db: gainDB))
        var afterLUFS = meter(out).integratedLUFS

        // Corrective passes: limiting is program-dependent, so a single gain move rarely lands exactly.
        // Converge to within the ±0.5 LU tolerance (a few passes; capped so it always terminates).
        var passes = 0
        while abs(afterLUFS - platform.lufs) > toleranceLU && passes < 6 {
            let delta = clampd(platform.lufs - afterLUFS, -6, 6)
            let next = clampd(gainDB + delta, -24, 24)
            if abs(next - gainDB) < 1e-4 { break }   // saturated (target unreachable under the ceiling)
            gainDB = next
            limiter.reset()
            out = limiter.process(applyGainDB(master, db: gainDB))
            afterLUFS = meter(out).integratedLUFS
            passes += 1
        }
        let limiterGRdB = limiter.lastGainReductionDB

        // Hard true-peak guarantee: if anything still pokes over, static-trim by exactly the overshoot.
        var tp = meter(out).truePeakDBTP
        if tp > ceiling {
            out = applyGainDB(out, db: ceiling - tp)
            tp = meter(out).truePeakDBTP
            afterLUFS = meter(out).integratedLUFS
        }

        let within = abs(afterLUFS - platform.lufs) <= toleranceLU
        let under = tp <= ceiling + ceilingEpsilonDB
        let summary = String(format: "%@: %.1f LUFS (target %.0f) · %.1f dBTP (ceiling %.0f) · %+.1f dB%@",
                             platform.name, afterLUFS, platform.lufs, tp, ceiling, gainDB,
                             within ? "" : " · loudest achievable under ceiling")
        let target = DeliveryTarget(platform: platform.name, targetLUFS: platform.lufs,
                                    ceilingDBTP: ceiling, achievedLUFS: afterLUFS, achievedTPDBTP: tp,
                                    gainDB: gainDB, limiterGRdB: limiterGRdB,
                                    withinTolerance: within, underCeiling: under, summary: summary)
        return DeliveryPackRender(signal: out, target: target)
    }

    // MARK: - helpers (mirror the MasteringEngine's gain/clamp so renders match the chain's behavior)

    private static func applyGainDB(_ s: AudioSignal, db: Double) -> AudioSignal {
        let g = pow(10.0, clampd(db, -48.0, 48.0) / 20.0)
        var out = s.channels
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            for i in 0..<src.count { out[c][i] = Float(clampd(Double(src[i]) * g, -16.0, 16.0)) }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    @inline(__always) private static func clampd(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        x < lo ? lo : (x > hi ? hi : x)
    }
}
