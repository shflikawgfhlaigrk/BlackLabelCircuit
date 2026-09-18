// GateExpander.swift — noise gate + downward expander on one shared envelope core.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`) are a bit-transparent passthrough. Deterministic.
//
// Shared core: a stereo-linked max-abs detector smoothed by an attack/release follower feeds
// a static gain computer; the gain trajectory then gets its own opening (attack) / closing
// (release) smoothing plus a hold timer so short dips between words/hits don't chatter.
//
//   • .gate     — binary target: detector at/above threshold → open (0 dB); below → closed
//                 (−rangeDB). holdMs keeps the gate open after the level falls.
//   • .expander — downward: every dB below threshold is pushed down by (ratio − 1) more dB,
//                 capped at rangeDB. ratio 2 = gentle, 10 ≈ gate-like.

import Foundation

enum GateExpanderMode: String, Codable, CaseIterable, Sendable {
    case gate, expander
}

struct GateExpanderSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    var mode: GateExpanderMode
    /// Open/close level, dBFS on the detector envelope.
    var thresholdDB: Double
    /// Expander slope (used by .expander only). 1 = no expansion.
    var ratio: Double
    var attackMs: Double
    /// Time the gate stays fully open after the detector falls below threshold.
    var holdMs: Double
    var releaseMs: Double
    /// Maximum attenuation, dB (the gate's closed floor / the expander's cap).
    var rangeDB: Double

    init(enabled: Bool, mode: GateExpanderMode = .gate, thresholdDB: Double = -40,
         ratio: Double = 4, attackMs: Double = 1, holdMs: Double = 50,
         releaseMs: Double = 120, rangeDB: Double = 60) {
        self.enabled = enabled
        self.mode = mode
        self.thresholdDB = thresholdDB
        self.ratio = max(1.0, ratio)
        self.attackMs = max(0.05, attackMs)
        self.holdMs = max(0, holdMs)
        self.releaseMs = max(1.0, releaseMs)
        self.rangeDB = min(max(rangeDB, 0), 90)
    }

    static let bypassed = GateExpanderSettings(enabled: false)
}

final class GateExpander {
    let settings: GateExpanderSettings
    let sampleRate: Double
    /// Deepest attenuation actually applied on the last pass, dB ≥ 0 (measured).
    private(set) var lastMaxAttenuationDB: Double = 0

    init(settings: GateExpanderSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let ch = s.channelCount
        let n = s.frameCount

        // Detector follower: fast rise so onsets open the gate promptly, moderate fall.
        let detA = GateExpander.coeff(ms: 0.2, sampleRate: sampleRate)
        let detR = GateExpander.coeff(ms: 30, sampleRate: sampleRate)
        // Gain smoothing: attack = opening speed, release = closing speed.
        let openC = GateExpander.coeff(ms: settings.attackMs, sampleRate: sampleRate)
        let closeC = GateExpander.coeff(ms: settings.releaseMs, sampleRate: sampleRate)
        let holdSamples = Int(settings.holdMs * 0.001 * sampleRate)
        let thrLin = pow(10.0, settings.thresholdDB / 20.0)
        let slope = settings.ratio - 1.0

        var env = 0.0
        var gainDB = -settings.rangeDB          // start closed: silence before audio stays gated
        var holdCounter = 0
        var maxAtten = 0.0

        var out = s.channels
        for i in 0..<n {
            var det = 0.0
            for c in 0..<ch {
                let a = abs(Double(s.channels[c][i]))
                if a > det { det = a }
            }
            env = det > env ? detA * env + (1 - detA) * det : detR * env + (1 - detR) * det

            // Static target from the shared envelope.
            let targetDB: Double
            if env >= thrLin {
                targetDB = 0
                holdCounter = holdSamples
            } else if holdCounter > 0 {
                holdCounter -= 1
                targetDB = 0
            } else {
                switch settings.mode {
                case .gate:
                    targetDB = -settings.rangeDB
                case .expander:
                    let envDB = 20.0 * log10(max(env, 1e-12))
                    let under = settings.thresholdDB - envDB
                    targetDB = -min(settings.rangeDB, under * slope)
                }
            }

            // Opening rises with the attack coefficient, closing falls with release.
            let c = targetDB > gainDB ? openC : closeC
            gainDB = targetDB + (gainDB - targetDB) * c
            if -gainDB > maxAtten { maxAtten = -gainDB }

            let g = pow(10.0, gainDB / 20.0)
            for cc in 0..<ch {
                out[cc][i] = Float(Double(s.channels[cc][i]) * g)
            }
        }
        lastMaxAttenuationDB = maxAtten
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    static func coeff(ms: Double, sampleRate: Double) -> Double {
        exp(-1.0 / (max(0.01, ms) * 0.001 * max(1.0, sampleRate)))
    }
}
