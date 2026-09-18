// Widener.swift — Haas widener (L/R micro-delay) with a measured mono-compatibility report.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`) are a bit-transparent passthrough, as is any input with
// fewer than 2 channels. Deterministic.
//
// The Haas effect: delaying one channel by ~1–30 ms widens the image without a level cue.
// The cost is mono compatibility — the delay is a comb filter on the mono fold. That cost
// is MEASURED here, never hidden: `lastReport` carries
//   • correlation     — normalized L/R correlation of the widened output (1 = mono,
//                       0 = decorrelated, negative = anti-phase);
//   • monoSumDeltaDB  — RMS change of the mono fold (out vs in), dB: how much the mono
//                       listener loses (or comb-gains) when this widener is on;
// so the UI can warn before a buyer ships a master that folds badly to mono.

import Foundation

struct WidenerSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    /// Haas delay, ms. Clamped 0.1…30.
    var delayMs: Double
    /// Which channel is delayed: 0 = left, 1 = right.
    var delayedChannel: Int
    /// Blend of the delayed copy into the delayed channel, 0…1 (1 = fully delayed).
    var mix: Double

    init(enabled: Bool, delayMs: Double = 12, delayedChannel: Int = 1, mix: Double = 1.0) {
        self.enabled = enabled
        self.delayMs = min(max(delayMs, 0.1), 30)
        self.delayedChannel = delayedChannel == 0 ? 0 : 1
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = WidenerSettings(enabled: false)
}

/// What the widener measurably did to mono safety — all computed from the actual samples.
struct WidenerReport: Equatable {
    var hasData: Bool
    /// Normalized L/R correlation of the widened output.
    var correlation: Double
    /// Mono-fold RMS delta (widened vs original), dB.
    var monoSumDeltaDB: Double

    static let empty = WidenerReport(hasData: false, correlation: 0, monoSumDeltaDB: 0)
}

final class HaasWidener {
    let settings: WidenerSettings
    let sampleRate: Double
    private(set) var lastReport: WidenerReport = .empty

    init(settings: WidenerSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount >= 2, s.frameCount > 0 else {
            lastReport = .empty
            return s
        }
        let n = min(s.channels[0].count, s.channels[1].count)
        let D = max(1, Int(settings.delayMs * 0.001 * sampleRate))
        let mix = settings.mix
        let dc = settings.delayedChannel

        var out = s.channels
        var delayed = s.channels[dc]
        let src = s.channels[dc]
        for i in 0..<n {
            let echo = i >= D ? Double(src[i - D]) : 0.0
            delayed[i] = Float(Double(src[i]) * (1.0 - mix) + echo * mix)
        }
        out[dc] = delayed

        // ---- measured mono-compatibility report ----
        var sLR = 0.0, sLL = 0.0, sRR = 0.0
        var monoInSq = 0.0, monoOutSq = 0.0
        for i in 0..<n {
            let lo = Double(out[0][i]), ro = Double(out[1][i])
            sLR += lo * ro; sLL += lo * lo; sRR += ro * ro
            let mi = (Double(s.channels[0][i]) + Double(s.channels[1][i])) * 0.5
            let mo = (lo + ro) * 0.5
            monoInSq += mi * mi
            monoOutSq += mo * mo
        }
        let denom = (sLL * sRR).squareRoot()
        let corr = denom > 1e-12 ? sLR / denom : 0
        let deltaDB: Double
        if monoInSq > 1e-18 && monoOutSq > 1e-18 {
            deltaDB = 10.0 * log10(monoOutSq / monoInSq)
        } else if monoInSq > 1e-18 {
            deltaDB = -120.0    // mono fold vanished entirely
        } else {
            deltaDB = 0
        }
        lastReport = WidenerReport(hasData: true, correlation: corr, monoSumDeltaDB: deltaDB)

        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}
