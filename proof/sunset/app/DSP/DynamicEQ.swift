// DynamicEQ.swift — N-band dynamic EQ: each band is a biquad (bell/shelf) whose gain is
// driven by an envelope follower on the band-filtered signal.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`, or zero bands) are a bit-transparent passthrough.
// Deterministic. Bands are applied in series in declaration order.
//
// Per band:
//   • detector — the input band-filtered (bell → constant-0 dB-peak bandpass at freq/Q;
//     lowShelf → low-pass at freq; highShelf → high-pass at freq), stereo-linked max-abs,
//     smoothed by an attack/release envelope follower.
//   • gain computer —
//       .cut   : level OVER threshold pulls the band DOWN by (over × (1 − 1/ratio)),
//                capped at maxGainDB (a de-harsher / resonance tamer);
//       .boost : level UNDER threshold lifts the band UP by (under × (1 − 1/ratio)),
//                capped at maxGainDB (upward — fills the band in when it is missing).
//   • apply — a stateful biquad whose coefficients are recomputed every 16 samples from the
//     smoothed gain (the envelope already smooths the trajectory, so the small coefficient
//     steps stay artifact-free). At 0 dB the RBJ bell/shelf reduces to identity.

import Foundation

enum DynamicEQShape: String, Codable, CaseIterable, Sendable {
    case bell, lowShelf, highShelf
}

enum DynamicEQMode: String, Codable, CaseIterable, Sendable {
    case cut, boost
}

struct DynamicEQBand: Equatable, Codable {
    var shape: DynamicEQShape
    var freq: Double
    var q: Double
    var thresholdDB: Double
    var ratio: Double
    var attackMs: Double
    var releaseMs: Double
    /// Maximum gain magnitude this band may apply, dB (always positive).
    var maxGainDB: Double
    var mode: DynamicEQMode

    init(shape: DynamicEQShape = .bell, freq: Double, q: Double = 1.0,
         thresholdDB: Double = -30, ratio: Double = 2, attackMs: Double = 5,
         releaseMs: Double = 80, maxGainDB: Double = 6, mode: DynamicEQMode = .cut) {
        self.shape = shape
        self.freq = max(20, freq)
        self.q = min(max(q, 0.1), 18)
        self.thresholdDB = thresholdDB
        self.ratio = max(1.0, ratio)
        self.attackMs = max(0.1, attackMs)
        self.releaseMs = max(1.0, releaseMs)
        self.maxGainDB = min(max(maxGainDB, 0), 24)
        self.mode = mode
    }
}

struct DynamicEQSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    var bands: [DynamicEQBand]

    init(enabled: Bool, bands: [DynamicEQBand] = []) {
        self.enabled = enabled
        self.bands = bands
    }

    static let bypassed = DynamicEQSettings(enabled: false)
}

final class DynamicEQ {
    let settings: DynamicEQSettings
    let sampleRate: Double
    /// Max gain magnitude each band actually applied on the last pass, dB (measured, per band).
    private(set) var lastBandGainDB: [Double] = []

    init(settings: DynamicEQSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, !settings.bands.isEmpty,
              s.channelCount > 0, s.frameCount > 0 else { return s }
        var work = s
        lastBandGainDB = []
        for band in settings.bands {
            var maxApplied = 0.0
            work = processBand(work, band: band, maxAppliedDB: &maxApplied)
            lastBandGainDB.append(maxApplied)
        }
        return work
    }

    // MARK: - one band

    private func processBand(_ s: AudioSignal, band: DynamicEQBand,
                             maxAppliedDB: inout Double) -> AudioSignal {
        let ch = s.channelCount
        let n = s.frameCount
        let ny = sampleRate * 0.49
        let f = min(band.freq, ny)

        // Detector filters (one per channel, fresh state — offline pass).
        let detCoeffs: BiquadCoeffs
        switch band.shape {
        case .bell:      detCoeffs = DynamicEQ.bandpass(freq: f, q: band.q, sampleRate: sampleRate)
        case .lowShelf:  detCoeffs = BiquadCoeffs.make(.lowPass, freq: f, sampleRate: sampleRate, q: 0.707)
        case .highShelf: detCoeffs = BiquadCoeffs.make(.highPass, freq: f, sampleRate: sampleRate, q: 0.707)
        }
        let detectors = (0..<ch).map { _ in Biquad(detCoeffs) }

        // Apply filters (one per channel; coefficients updated per block from the gain).
        let applyKind: FilterKind = band.shape == .bell ? .peaking
                                  : (band.shape == .lowShelf ? .lowShelf : .highShelf)
        let appliers = (0..<ch).map { _ in
            Biquad(BiquadCoeffs.make(applyKind, freq: f, sampleRate: sampleRate, q: band.q, gainDB: 0))
        }

        let aC = DynamicEQ.coeff(ms: band.attackMs, sampleRate: sampleRate)
        let rC = DynamicEQ.coeff(ms: band.releaseMs, sampleRate: sampleRate)
        let slope = 1.0 - 1.0 / band.ratio
        let block = 16
        var env = 0.0                       // linear detector envelope
        var currentGainDB = 0.0

        var out = s.channels
        var i = 0
        while i < n {
            let end = min(i + block, n)
            for j in i..<end {
                // Stereo-linked band-filtered detector.
                var det = 0.0
                for c in 0..<ch {
                    let v = abs(detectors[c].process(Double(s.channels[c][j])))
                    if v > det { det = v }
                }
                env = det > env ? aC * env + (1 - aC) * det : rC * env + (1 - rC) * det
            }
            // Gain from the smoothed envelope at block rate.
            let envDB = 20.0 * log10(max(env, 1e-12))
            let gainDB: Double
            switch band.mode {
            case .cut:
                let over = envDB - band.thresholdDB
                gainDB = over > 0 ? -min(band.maxGainDB, over * slope) : 0
            case .boost:
                let under = band.thresholdDB - envDB
                gainDB = under > 0 ? min(band.maxGainDB, under * slope) : 0
            }
            if abs(gainDB - currentGainDB) > 0.01 {
                currentGainDB = gainDB
                let c = BiquadCoeffs.make(applyKind, freq: f, sampleRate: sampleRate,
                                          q: band.q, gainDB: currentGainDB)
                for a in appliers { a.c = c }
            }
            if abs(currentGainDB) > maxAppliedDB { maxAppliedDB = abs(currentGainDB) }
            for c in 0..<ch {
                for j in i..<end {
                    out[c][j] = Float(appliers[c].process(Double(s.channels[c][j])))
                }
            }
            i = end
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    // MARK: - helpers

    /// RBJ constant-0 dB-peak bandpass (b = [α, 0, −α]) — the bell band's detector.
    static func bandpass(freq: Double, q: Double, sampleRate: Double) -> BiquadCoeffs {
        let w0 = 2.0 * Double.pi * min(freq, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2.0 * max(q, 0.0001))
        let a0 = 1 + alpha
        return BiquadCoeffs.raw(b0: alpha / a0, b1: 0, b2: -alpha / a0,
                                a1: -2 * cos(w0) / a0, a2: (1 - alpha) / a0)
    }

    static func coeff(ms: Double, sampleRate: Double) -> Double {
        exp(-1.0 / (max(0.01, ms) * 0.001 * max(1.0, sampleRate)))
    }
}
