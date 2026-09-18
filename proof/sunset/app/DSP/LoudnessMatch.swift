// LoudnessMatch.swift — equal-loudness A/B: gain-match audition sources so you compare TONE, not level.
//
// The whole point of an honest A/B is that "louder" cannot masquerade as "better" — the
// oldest trick in mastering. Given the MEASURED integrated LUFS (BS.1770) of the audition
// sources, we pick the QUIETEST as the match target and attenuate every louder path down to
// it. Attenuation only: a match can never boost a path and so can never add clipping.
//
// Pure, deterministic measurement + one static gain per source. No advice, no fabricated
// numbers — every offset is (targetLUFS − sourceLUFS) in dB, traceable to the meter.

import Foundation

enum LoudnessMatch {
    /// Match target = the quietest valid integrated LUFS among the audition sources, so every
    /// other source is attenuated down to it (never boosted). `nil` when nothing valid to match.
    static func targetLUFS(_ candidates: [Double]) -> Double? {
        candidates.filter { $0.isFinite && $0 > -70 }.min()
    }

    /// Static match gain (dB) to bring `sourceLUFS` to `targetLUFS`. ≤ 0 when the target is the
    /// quietest source. Returns 0 (an honest no-op) when either value is invalid — silence/undefined.
    static func gainDB(sourceLUFS: Double, targetLUFS: Double) -> Double {
        guard sourceLUFS.isFinite, targetLUFS.isFinite, sourceLUFS > -70, targetLUFS > -70 else { return 0 }
        return targetLUFS - sourceLUFS
    }

    /// Linear multiplier form of `gainDB`, ready to scale samples at audition time.
    static func linearGain(sourceLUFS: Double, targetLUFS: Double) -> Double {
        pow(10.0, gainDB(sourceLUFS: sourceLUFS, targetLUFS: targetLUFS) / 20.0)
    }
}
