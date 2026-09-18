// Vocoder.swift — classic band vocoder (SUNSET-EFFECTS-STANDARD row 28): the modulator's
// per-band envelope is imposed on a carrier.
//
// Contract: offline block processing on AudioSignal; output has identical shape to the
// modulator. Bypassed settings (`enabled == false`) are a bit-transparent passthrough.
// Deterministic: the noise carrier uses a fixed-seed xorshift generator, the saw carrier
// starts at phase 0.
//
// Filterbank choice (vs FFT): a time-domain bank of 4th-order bandpass filters
// (two cascaded RBJ constant-peak biquads per band) — no framing latency, no spectral
// smearing of transients, per-SAMPLE envelope response, and trivially deterministic.
// 16–32 bands, geometrically spaced 80 Hz → 12 kHz; Q derived from the spacing ratio
// (Q = √r/(r−1)) so adjacent bands cross near their −3 dB points.
//
// Per band: bandpass(modulator) → attack/release envelope follower → bandpass(carrier)
// NORMALIZED to unit band RMS (measured over the render; bands where the carrier has no
// energy are skipped rather than noise-boosted) × envelope → summed. So the modulator
// envelope sets the absolute level and the carrier only contributes timbre. A final
// measured level-match gain (modulator RMS / raw output RMS, clamped ±24 dB) trims the
// residual — measured on the actual render, never asserted. A silent modulator yields
// EXACT zeros (follower state starts at 0 and 0-input keeps it there).
//
// Carrier: a second AudioSignal when routed, else the built-in saw (or seeded noise).
// In an insert slot there is no second source, so the built-in carrier is the v1 default.

import Foundation

/// Carrier source when no external carrier signal is routed.
enum VocoderCarrier: Equatable, Codable {
    case saw(freqHz: Double)
    case noise

    static let `default` = VocoderCarrier.saw(freqHz: 110)
}

struct VocoderSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == modulator, untouched).
    var enabled: Bool
    /// Analysis/synthesis band count, clamped 16…32.
    var bands: Int
    /// Built-in carrier used when no external carrier is routed.
    var carrier: VocoderCarrier
    /// Envelope follower attack, ms.
    var attackMs: Double
    /// Envelope follower release, ms.
    var releaseMs: Double
    /// Wet blend 0…1 (dry = the modulator).
    var mix: Double

    init(enabled: Bool, bands: Int = 24, carrier: VocoderCarrier = .default,
         attackMs: Double = 4, releaseMs: Double = 60, mix: Double = 1.0) {
        self.enabled = enabled
        self.bands = min(max(bands, 16), 32)
        self.carrier = carrier
        self.attackMs = min(max(attackMs, 0.1), 100)
        self.releaseMs = min(max(releaseMs, 1), 500)
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = VocoderSettings(enabled: false)

    private enum CodingKeys: String, CodingKey { case enabled, bands, carrier, attackMs, releaseMs, mix }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  bands: try c.decodeIfPresent(Int.self, forKey: .bands) ?? 24,
                  carrier: try c.decodeIfPresent(VocoderCarrier.self, forKey: .carrier) ?? .default,
                  attackMs: try c.decodeIfPresent(Double.self, forKey: .attackMs) ?? 4,
                  releaseMs: try c.decodeIfPresent(Double.self, forKey: .releaseMs) ?? 60,
                  mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1.0)
    }
}

final class Vocoder {
    let settings: VocoderSettings
    let sampleRate: Double
    static let bandLowHz = 80.0
    static let bandHighHz = 12_000.0
    /// Residual level-match gain applied on the last pass, dB — measured, clamped ±24.
    private(set) var lastMatchedGainDB: Double = 0

    init(settings: VocoderSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    /// Vocode `modulator` through `carrier` (external signal, or the built-in source when nil).
    func process(modulator: AudioSignal, carrier external: AudioSignal? = nil) -> AudioSignal {
        guard settings.enabled, modulator.channelCount > 0, modulator.frameCount > 0 else {
            return modulator
        }
        let n = modulator.frameCount
        let chCount = modulator.channelCount

        // Band centers: geometric 80 Hz → 12 kHz (clamped under Nyquist), shared Q.
        let bandCount = settings.bands
        let hi = min(Vocoder.bandHighHz, sampleRate * 0.45)
        let ratio = pow(hi / Vocoder.bandLowHz, 1.0 / Double(bandCount - 1))
        let q = max(0.5, ratio.squareRoot() / (ratio - 1))
        var centers = [Double](repeating: 0, count: bandCount)
        for b in 0..<bandCount { centers[b] = Vocoder.bandLowHz * pow(ratio, Double(b)) }

        // Envelope follower coefficients.
        let atk = exp(-1.0 / (sampleRate * settings.attackMs / 1000.0))
        let rel = exp(-1.0 / (sampleRate * settings.releaseMs / 1000.0))

        // Carrier samples per channel (built-in sources are mono, shared across channels).
        let carrierChannels: [[Float]]
        if let ext = external, ext.frameCount > 0, ext.channelCount > 0 {
            var chans: [[Float]] = []
            for c in 0..<chCount {
                let src = ext.channels.indices.contains(c) ? ext.channels[c] : ext.channels[0]
                var padded = [Float](repeating: 0, count: n)
                for i in 0..<min(n, src.count) { padded[i] = src[i] }
                chans.append(padded)
            }
            carrierChannels = chans
        } else {
            let mono = Vocoder.builtInCarrier(settings.carrier, frames: n, sampleRate: sampleRate)
            carrierChannels = [[Float]](repeating: mono, count: chCount)
        }

        // Per-channel, per-band: env(bp(mod)) × unit-RMS bp(carrier), summed.
        var wet = [[Double]](repeating: [Double](repeating: 0, count: n), count: chCount)
        for c in 0..<chCount {
            let mod = modulator.channels[c]
            let car = carrierChannels[c]
            for b in 0..<bandCount {
                let coeffs = Vocoder.bandpass(centerHz: centers[b], q: q, sampleRate: sampleRate)
                // Pass 1: carrier band + its RMS (normalizes the carrier to unit band level).
                let c1 = Biquad(coeffs), c2 = Biquad(coeffs)
                var carBand = [Double](repeating: 0, count: n)
                var carSumSq = 0.0
                for i in 0..<n {
                    let v = c2.process(c1.process(Double(car[i])))
                    carBand[i] = v
                    carSumSq += v * v
                }
                let carRMS = (carSumSq / Double(n)).squareRoot()
                // No carrier energy in this band → skip it (never boost the numeric floor).
                guard carRMS > 1e-6 else { continue }
                // Pass 2: modulator band envelope drives the normalized carrier band.
                let m1 = Biquad(coeffs), m2 = Biquad(coeffs)
                var env = 0.0
                for i in 0..<n {
                    let bm = m2.process(m1.process(Double(mod[i])))
                    let a = abs(bm)
                    let coef = a > env ? atk : rel
                    env = coef * env + (1 - coef) * a
                    wet[c][i] += carBand[i] / carRMS * env
                }
            }
        }

        // Measured residual level match toward the modulator's RMS (clamped ±24 dB).
        var modSumSq = 0.0, wetSumSq = 0.0
        var count = 0
        for c in 0..<chCount {
            for i in 0..<n {
                let m = Double(modulator.channels[c][i])
                modSumSq += m * m
                wetSumSq += wet[c][i] * wet[c][i]
            }
            count += n
        }
        var matchGain = 1.0
        if modSumSq > 1e-18 && wetSumSq > 1e-18 {
            let raw = (modSumSq / wetSumSq).squareRoot()
            let cap = pow(10.0, 24.0 / 20.0)
            matchGain = min(max(raw, 1.0 / cap), cap)
            lastMatchedGainDB = 20 * log10(matchGain)
        } else {
            lastMatchedGainDB = 0
        }

        var out: [[Float]] = []
        let mix = settings.mix
        for c in 0..<chCount {
            var ch = [Float](repeating: 0, count: n)
            let dry = modulator.channels[c]
            for i in 0..<n {
                let v = Double(dry[i]) * (1 - mix) + wet[c][i] * matchGain * mix
                ch[i] = Float(min(max(v, -4.0), 4.0))
            }
            out.append(ch)
        }
        return AudioSignal(channels: out, sampleRate: modulator.sampleRate)
    }

    /// RBJ constant-0dB-peak bandpass.
    static func bandpass(centerHz: Double, q: Double, sampleRate: Double) -> BiquadCoeffs {
        let fc = min(max(centerHz, 10), sampleRate * 0.49)
        let w0 = 2 * Double.pi * fc / sampleRate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return BiquadCoeffs.raw(b0: alpha / a0, b1: 0, b2: -alpha / a0,
                                a1: -2 * cos(w0) / a0, a2: (1 - alpha) / a0)
    }

    /// Deterministic built-in carrier: naive saw at fixed phase, or fixed-seed xorshift noise.
    static func builtInCarrier(_ kind: VocoderCarrier, frames: Int, sampleRate: Double) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        switch kind {
        case .saw(let freqHz):
            let f = min(max(freqHz, 20), sampleRate * 0.25)
            let inc = f / sampleRate
            var phase = 0.0
            for i in 0..<frames {
                out[i] = Float(2.0 * phase - 1.0) * 0.5
                phase += inc
                if phase >= 1.0 { phase -= 1.0 }
            }
        case .noise:
            var state: UInt64 = 0x5EED_1234_ABCD_0001
            for i in 0..<frames {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                // Map the top 32 bits to −0.5…0.5.
                let v = Double(state >> 32) / Double(UInt32.max) - 0.5
                out[i] = Float(v)
            }
        }
        return out
    }
}
