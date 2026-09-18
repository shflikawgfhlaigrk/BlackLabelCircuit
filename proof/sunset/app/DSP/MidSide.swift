// MidSide.swift — M/S encode/decode with per-M/S gain, per-M/S EQ, and solo audition.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`) are a bit-transparent passthrough, as is any input with
// fewer than 2 channels (M/S needs a stereo pair). Deterministic.
//
// Encode: M = (L+R)/2, S = (L−R)/2. Decode: L = M+S, R = M−S — an exact reconstruction
// pair, so neutral settings differ from the input only by float rounding (the enabled
// flag is what guarantees bit-transparency, and tests hold neutral-but-enabled to ≤1e−6).
//
// Per-side processing: gain in dB and an optional ParametricEQ chain (EQBand — the same
// band type the master EQ uses), applied independently to M and S. Solo audition:
//   .mid  → S muted (what's in the center);  .side → M muted (what's in the edges).

import Foundation

enum MidSideSolo: String, Codable, CaseIterable, Sendable {
    case stereo, mid, side
}

struct MidSideSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    var midGainDB: Double
    var sideGainDB: Double
    var midEQ: [EQBand]
    var sideEQ: [EQBand]
    var solo: MidSideSolo

    init(enabled: Bool, midGainDB: Double = 0, sideGainDB: Double = 0,
         midEQ: [EQBand] = [], sideEQ: [EQBand] = [], solo: MidSideSolo = .stereo) {
        self.enabled = enabled
        self.midGainDB = min(max(midGainDB, -24), 24)
        self.sideGainDB = min(max(sideGainDB, -24), 24)
        self.midEQ = midEQ
        self.sideEQ = sideEQ
        self.solo = solo
    }

    static let bypassed = MidSideSettings(enabled: false)
}

final class MidSideProcessor {
    let settings: MidSideSettings
    let sampleRate: Double

    init(settings: MidSideSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount >= 2, s.frameCount > 0 else { return s }
        let n = min(s.channels[0].count, s.channels[1].count)

        // Encode.
        var mid = [Double](repeating: 0, count: n)
        var side = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let l = Double(s.channels[0][i])
            let r = Double(s.channels[1][i])
            mid[i] = (l + r) * 0.5
            side[i] = (l - r) * 0.5
        }

        // Per-side gain.
        let gM = pow(10.0, settings.midGainDB / 20.0)
        let gS = pow(10.0, settings.sideGainDB / 20.0)
        if gM != 1.0 { for i in 0..<n { mid[i] *= gM } }
        if gS != 1.0 { for i in 0..<n { side[i] *= gS } }

        // Per-side EQ (mono chains).
        if settings.midEQ.contains(where: { $0.enabled }) {
            let eq = ParametricEQ(bands: settings.midEQ, sampleRate: sampleRate, channels: 1)
            for i in 0..<n { mid[i] = eq.process(mid[i], channel: 0) }
        }
        if settings.sideEQ.contains(where: { $0.enabled }) {
            let eq = ParametricEQ(bands: settings.sideEQ, sampleRate: sampleRate, channels: 1)
            for i in 0..<n { side[i] = eq.process(side[i], channel: 0) }
        }

        // Solo audition.
        switch settings.solo {
        case .stereo: break
        case .mid:    for i in 0..<n { side[i] = 0 }
        case .side:   for i in 0..<n { mid[i] = 0 }
        }

        // Decode.
        var out = s.channels
        var l = s.channels[0]
        var r = s.channels[1]
        for i in 0..<n {
            l[i] = Float(min(max(mid[i] + side[i], -4.0), 4.0))
            r[i] = Float(min(max(mid[i] - side[i], -4.0), 4.0))
        }
        out[0] = l
        out[1] = r
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}
