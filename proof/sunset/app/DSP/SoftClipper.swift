// SoftClipper.swift — pre-limiter oversampled soft-clip stage.
//
// A dedicated clipper that sits BEFORE the brickwall limiter in the master chain
// (… > soft clip > limiter > ceiling). Clipping-for-loudness: it softly rounds the
// tallest transient peaks so the limiter has less to do, preserving punch that a
// limiter alone would pump away. The classic club / tech-house move ("soft clip over
// compression on the drum bus").
//
// Honesty first (Charter §5.1): the "dB clipped" readout is MEASURED from the actual
// peak reduction the clip curve imposed on this signal — never asserted. Bypassed by
// default so the out-of-box master is byte-for-byte unchanged from build 2; it only
// engages when the user turns it on or a profile (Club / Tech-House) asks for it.
//
// Aliasing control: the nonlinearity is applied at 4× (min) via a windowed-sinc
// polyphase up/decimate pair, so the harmonics the clip generates above the audio
// band are filtered instead of folding back as aliasing. Zero net latency —
// the integer group delay of the up+down FIR pair is compensated exactly.

import Foundation

/// Settings for the pre-limiter soft-clip stage.
struct SoftClipSettings: Equatable {
    /// When false the stage is a true bypass (output == input, 0 dB clipped).
    var enabled: Bool
    /// How much peak reduction the clipper aims for, dB. Range 0.5–3 is the design
    /// intent (gentle punch); clamped to 0…4. 0 (or disabled) = no clipping.
    var driveDB: Double
    /// Soft-knee width below the clip ceiling, dB. Larger = rounder/softer clip.
    var kneeDB: Double
    /// Oversampling factor for the nonlinearity. 4 minimum (spec).
    var oversample: Int

    init(enabled: Bool, driveDB: Double, kneeDB: Double = 3.0, oversample: Int = 4) {
        self.enabled = enabled
        self.driveDB = min(max(driveDB, 0.0), 4.0)
        self.kneeDB = min(max(kneeDB, 0.5), 12.0)
        self.oversample = max(4, min(oversample, 8))
    }

    /// True bypass — the shipped default. Out-of-box master is unchanged.
    static let bypassed = SoftClipSettings(enabled: false, driveDB: 0.0)
    /// Gentle engaged default (~1.25 dB of peak reduction), 4× oversampled.
    static let gentle   = SoftClipSettings(enabled: true, driveDB: 1.25)
}

/// What the clip stage actually did to this signal — all measured.
struct SoftClipResult: Equatable {
    var enabled: Bool
    var dBClipped: Double        // measured peak reduction (dB) the clip curve imposed
    var percentClipped: Double   // % of samples that entered the clip (knee) region
    var driveDB: Double
    static let bypassed = SoftClipResult(enabled: false, dBClipped: 0, percentClipped: 0, driveDB: 0)
}

/// Oversampled soft clipper. Stateless per call (deterministic: same input+settings → same output).
final class SoftClipper {
    let settings: SoftClipSettings
    let sampleRate: Double
    private(set) var lastResult: SoftClipResult = .bypassed

    init(settings: SoftClipSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    // MARK: - Static transfer curve (pure, testable)

    /// The memoryless soft-clip transfer function. Unity below the knee, smoothly
    /// asymptoting toward `ceiling` above it. Continuous with unit slope at the knee
    /// (C¹), monotonic, and strictly bounded by `ceiling`.
    /// - Parameters:
    ///   - x: input sample (linear).
    ///   - ceiling: absolute output ceiling (linear, > 0).
    ///   - kneeDB: how far below the ceiling the rounding begins.
    @inline(__always)
    static func shape(_ x: Double, ceiling: Double, kneeDB: Double) -> Double {
        guard ceiling > 1e-12 else { return 0 }
        let a = abs(x)
        let kneeStart = ceiling * pow(10.0, -abs(kneeDB) / 20.0)
        if a <= kneeStart { return x }
        let range = ceiling - kneeStart
        guard range > 1e-12 else { return x < 0 ? -ceiling : ceiling }
        let over = a - kneeStart
        let shaped = kneeStart + range * tanh(over / range)   // → ceiling, slope 1 at knee
        return x < 0 ? -shaped : shaped
    }

    // MARK: - Process

    /// Soft-clip every channel through the oversampled curve. The clip ceiling is set
    /// `driveDB` below the signal's own peak, so the loudest peaks are shaved by ~driveDB
    /// (measured) while quieter material passes untouched. Returns a time-aligned signal
    /// of identical shape; records the measured clip depth + percent in `lastResult`.
    func process(_ s: AudioSignal) -> AudioSignal {
        let ch = s.channelCount, n = s.frameCount
        guard settings.enabled, settings.driveDB > 1e-6, ch > 0, n > 0 else {
            lastResult = SoftClipResult(enabled: false, dBClipped: 0, percentClipped: 0, driveDB: settings.driveDB)
            return s
        }

        // Pre-clip peak (linear) across all channels → sets the clip ceiling.
        var peak = 0.0
        for c in 0..<ch {
            for v in s.channels[c] { let a = abs(Double(v)); if a > peak { peak = a } }
        }
        guard peak > 1e-9 else {   // silence: nothing to clip
            lastResult = SoftClipResult(enabled: true, dBClipped: 0, percentClipped: 0, driveDB: settings.driveDB)
            return s
        }

        let os = settings.oversample
        let ceiling = peak * pow(10.0, -settings.driveDB / 20.0)      // clip the top driveDB off
        let kneeStart = ceiling * pow(10.0, -settings.kneeDB / 20.0)  // for the percent-clipped meter
        let (h, center) = SoftClipper.prototype(oversample: os)       // symmetric windowed-sinc, DC gain 1
        let L = h.count
        let twoC = 2 * center                                        // total up+down group delay (hi-rate)

        var outPeak = 0.0
        var clippedSamples = 0
        var out = s.channels

        for c in 0..<ch {
            let x = s.channels[c]
            // --- 1. upsample ×os (polyphase windowed-sinc, gain os) into `up` ---
            let hiLen = n * os + twoC + L
            var up = [Double](repeating: 0, count: hiLen)
            for q in 0..<n {
                let xv = Double(x[q]) * Double(os)
                if xv == 0 { continue }
                let base = q * os
                for k in 0..<L {
                    let m = base + k
                    up[m] += xv * h[k]
                }
            }
            // --- 2. shape (clip) at the high rate ---
            for m in 0..<hiLen { up[m] = SoftClipper.shape(up[m], ceiling: ceiling, kneeDB: settings.kneeDB) }
            // --- 3. decimate back to the base rate, delay-compensated by twoC (integer) ---
            var y = [Float](repeating: 0, count: n)
            for j in 0..<n {
                var acc = 0.0
                let hiBase = j * os + twoC
                for k in 0..<L {
                    let idx = hiBase - k
                    if idx >= 0 && idx < hiLen { acc += up[idx] * h[k] }
                }
                y[j] = Float(acc)
                let a = abs(acc)
                if a > outPeak { outPeak = a }
                if abs(Double(x[j])) > kneeStart { clippedSamples += 1 }
            }
            out[c] = y
        }

        let depth = outPeak > 1e-9 ? max(0.0, 20.0 * log10(peak / outPeak)) : settings.driveDB
        let pct = 100.0 * Double(clippedSamples) / Double(max(1, n * ch))
        lastResult = SoftClipResult(enabled: true, dBClipped: depth, percentClipped: pct, driveDB: settings.driveDB)
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    // MARK: - Oversampling prototype

    /// Symmetric windowed-sinc low-pass prototype for the up/decimate pair.
    /// Cutoff = Nyquist/os, Blackman window, ODD length so the group delay is an
    /// integer (`center`) — letting the up+down delay cancel exactly with no smear.
    /// DC gain normalized to 1 (the upsample path scales by os separately).
    /// Returns (coefficients, center-tap index = group delay in hi-rate samples).
    static func prototype(oversample os: Int, tapsPerPhase: Int = 16) -> ([Double], Int) {
        let L = os * tapsPerPhase + 1           // odd → symmetric, integer center
        let center = L / 2
        let fc = 1.0 / Double(os)               // cutoff as fraction of hi-rate Nyquist
        var h = [Double](repeating: 0, count: L)
        var sum = 0.0
        for i in 0..<L {
            let m = Double(i - center)
            let sinc = m == 0 ? fc : sin(Double.pi * fc * m) / (Double.pi * m)
            // Blackman window (better stopband than Hamming → less aliasing)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(L - 1))
                         + 0.08 * cos(4 * Double.pi * Double(i) / Double(L - 1))
            h[i] = sinc * w
            sum += h[i]
        }
        if abs(sum) > 1e-12 { for i in 0..<L { h[i] /= sum } }   // DC gain → 1
        return (h, center)
    }
}
