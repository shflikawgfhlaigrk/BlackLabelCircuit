// Biquad.swift — RBJ transposed-direct-form-II biquad + parametric EQ.
//
// One Biquad = one second-order section with per-channel state. ParametricEQ
// chains several. Coefficient formulas are the standard Audio-EQ-Cookbook
// (Robert Bristow-Johnson). Used by the tonal EQ, the K-weighting loudness
// filter, and the crossover in the multiband compressor.

import Foundation

enum FilterKind {
    case peaking, lowShelf, highShelf, highPass, lowPass
}

struct BiquadCoeffs {
    var b0: Double = 1, b1: Double = 0, b2: Double = 0
    var a1: Double = 0, a2: Double = 0   // a0 normalized to 1

    /// RBJ cookbook. `gainDB` used only for peaking/shelf.
    static func make(_ kind: FilterKind, freq: Double, sampleRate: Double,
                     q: Double = 0.707, gainDB: Double = 0) -> BiquadCoeffs {
        let w0 = 2.0 * Double.pi * min(freq, sampleRate * 0.49) / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2.0 * max(q, 0.0001))
        let A = pow(10.0, gainDB / 40.0)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch kind {
        case .peaking:
            b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
        case .lowShelf:
            let ap = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cw + ap)
            b1 = 2 * A * ((A - 1) - (A + 1) * cw)
            b2 = A * ((A + 1) - (A - 1) * cw - ap)
            a0 = (A + 1) + (A - 1) * cw + ap
            a1 = -2 * ((A - 1) + (A + 1) * cw)
            a2 = (A + 1) + (A - 1) * cw - ap
        case .highShelf:
            let ap = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cw + ap)
            b1 = -2 * A * ((A - 1) + (A + 1) * cw)
            b2 = A * ((A + 1) + (A - 1) * cw - ap)
            a0 = (A + 1) - (A - 1) * cw + ap
            a1 = 2 * ((A - 1) - (A + 1) * cw)
            a2 = (A + 1) - (A - 1) * cw - ap
        case .highPass:
            b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .lowPass:
            b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        }
        return BiquadCoeffs(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// Raw coefficients (already a0-normalized) — used by the loudness K-filter.
    static func raw(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) -> BiquadCoeffs {
        BiquadCoeffs(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
    }

    /// Magnitude response (linear) at frequency `f` — used to render the EQ curve.
    func magnitude(at f: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * f / sampleRate
        let cw1 = cos(w), cw2 = cos(2 * w), sw1 = sin(w), sw2 = sin(2 * w)
        let numRe = b0 + b1 * cw1 + b2 * cw2
        let numIm = -(b1 * sw1 + b2 * sw2)
        let denRe = 1 + a1 * cw1 + a2 * cw2
        let denIm = -(a1 * sw1 + a2 * sw2)
        let num = sqrt(numRe * numRe + numIm * numIm)
        let den = sqrt(denRe * denRe + denIm * denIm)
        return den > 0 ? num / den : 1
    }
}

/// Stateful biquad, transposed direct form II (one instance per channel).
final class Biquad {
    var c: BiquadCoeffs
    private var z1 = 0.0, z2 = 0.0
    init(_ c: BiquadCoeffs) { self.c = c }
    func reset() { z1 = 0; z2 = 0 }

    @inline(__always) func process(_ x: Double) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

/// A parametric-EQ band description (what the engine decides + what the UI shows).
struct EQBand: Identifiable, Codable, Equatable {
    var id = UUID()
    var kindRaw: Int            // maps to FilterKind
    var freq: Double
    var gainDB: Double
    var q: Double
    var enabled: Bool = true

    var kind: FilterKind {
        switch kindRaw {
        case 1: return .lowShelf
        case 2: return .highShelf
        case 3: return .highPass
        case 4: return .lowPass
        default: return .peaking
        }
    }
    static func peak(_ f: Double, _ g: Double, _ q: Double = 1.0) -> EQBand {
        EQBand(kindRaw: 0, freq: f, gainDB: g, q: q)
    }
    static func lowShelf(_ f: Double, _ g: Double) -> EQBand { EQBand(kindRaw: 1, freq: f, gainDB: g, q: 0.707) }
    static func highShelf(_ f: Double, _ g: Double) -> EQBand { EQBand(kindRaw: 2, freq: f, gainDB: g, q: 0.707) }
    static func highPass(_ f: Double, _ q: Double = 0.707) -> EQBand { EQBand(kindRaw: 3, freq: f, gainDB: 0, q: q) }
    static func lowPass(_ f: Double, _ q: Double = 0.707) -> EQBand { EQBand(kindRaw: 4, freq: f, gainDB: 0, q: q) }
}

/// A chain of parametric bands processed per channel.
final class ParametricEQ {
    private var bands: [(coeffs: BiquadCoeffs, filters: [Biquad])] = []
    let channels: Int
    let sampleRate: Double

    init(bands eqBands: [EQBand], sampleRate: Double, channels: Int) {
        self.channels = channels
        self.sampleRate = sampleRate
        for b in eqBands where b.enabled {
            let c = BiquadCoeffs.make(b.kind, freq: b.freq, sampleRate: sampleRate, q: b.q, gainDB: b.gainDB)
            bands.append((c, (0..<channels).map { _ in Biquad(c) }))
        }
    }

    @inline(__always) func process(_ x: Double, channel: Int) -> Double {
        var v = x
        for band in bands { v = band.filters[channel].process(v) }
        return v
    }

    func reset() { bands.forEach { $0.filters.forEach { $0.reset() } } }

    /// Combined magnitude response in dB across the fixed FreqBands centers — for the UI curve.
    static func responseDB(_ eqBands: [EQBand], sampleRate: Double) -> [Float] {
        FreqBands.centers.map { f in
            var mag = 1.0
            for b in eqBands where b.enabled {
                let c = BiquadCoeffs.make(b.kind, freq: b.freq, sampleRate: sampleRate, q: b.q, gainDB: b.gainDB)
                mag *= c.magnitude(at: f, sampleRate: sampleRate)
            }
            return Float(20 * log10(max(mag, 1e-6)))
        }
    }
}
