// Dynamics.swift — real feed-forward compressor, 3-band Linkwitz-Riley multiband, and lookahead true-peak limiter.

import Foundation

// MARK: - small helpers

@inline(__always) private func clampd(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    return x < lo ? lo : (x > hi ? hi : x)
}
@inline(__always) private func dbToGain(_ db: Double) -> Double { pow(10.0, db / 20.0) }
@inline(__always) private func gainToDb(_ g: Double) -> Double { 20.0 * log10(max(g, 1e-12)) }
// one-pole smoothing coefficient for a given time constant (ms). 0 => instant.
@inline(__always) private func smoothCoeff(ms: Double, sampleRate: Double) -> Double {
    if ms <= 0 || sampleRate <= 0 { return 0 }
    return exp(-1.0 / (ms * 0.001 * sampleRate))
}

// MARK: - Compressor

struct CompressorSettings: Equatable, Codable {
    var thresholdDB: Double
    var ratio: Double
    var attackMs: Double
    var releaseMs: Double
    var kneeDB: Double
    var makeupDB: Double

    init(thresholdDB: Double = -18, ratio: Double = 3, attackMs: Double = 10,
         releaseMs: Double = 120, kneeDB: Double = 6, makeupDB: Double = 0) {
        self.thresholdDB = thresholdDB
        self.ratio = max(1.0, ratio)               // ratio < 1 would expand — clamp
        self.attackMs = max(0.0, attackMs)
        self.releaseMs = max(0.0, releaseMs)
        self.kneeDB = max(0.0, kneeDB)
        self.makeupDB = makeupDB
    }
}

extension CompressorSettings {
    /// Bus-glue preset: slow attack (lets transients through), low 2:1 ratio, wide knee,
    /// moderate release — the "make the bus breathe together" setting, not a leveler.
    static let busGlue = CompressorSettings(thresholdDB: -16, ratio: 2.0, attackMs: 30,
                                            releaseMs: 250, kneeDB: 8, makeupDB: 0)
}

/// Stereo-linked feed-forward compressor. Detector = max-abs across channels,
/// smoothed attack/release envelope, soft-knee log-domain gain computer, makeup gain.
final class Compressor {
    private(set) var settings: CompressorSettings
    let sampleRate: Double

    private var envGR: Double = 0        // current smoothed gain reduction, dB (<= 0)
    private(set) var lastGainReductionDB: Double = 0   // max GR applied this pass, dB (>= 0)

    init(settings: CompressorSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func reset() { envGR = 0; lastGainReductionDB = 0 }

    /// static gain computer: given input level in dB, return gain change (dB, <= 0) with soft knee.
    private func computeGainDB(_ inDB: Double) -> Double {
        let t = settings.thresholdDB
        let over = inDB - t
        let knee = settings.kneeDB
        let outDB: Double
        if knee > 0 && (2 * over) > -knee && (2 * over) < knee {
            // quadratic interpolation through the knee region
            let x = over + knee / 2
            outDB = inDB + (1.0 / settings.ratio - 1.0) * x * x / (2 * knee)
        } else if 2 * over >= knee {
            outDB = t + over / settings.ratio
        } else {
            outDB = inDB                      // below knee: unity
        }
        return outDB - inDB
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        let ch = s.channelCount
        let n = s.frameCount
        guard ch > 0, n > 0 else { return s }

        var out = s.channels
        let aC = smoothCoeff(ms: settings.attackMs, sampleRate: sampleRate)
        let rC = smoothCoeff(ms: settings.releaseMs, sampleRate: sampleRate)
        let makeup = settings.makeupDB
        var maxGR = 0.0

        for i in 0..<n {
            // stereo-linked detector: max abs across channels
            var det = 0.0
            for c in 0..<ch {
                let a = abs(Double(s.channels[c][i]))
                if a > det { det = a }
            }
            let inDB = gainToDb(det)
            let targetGR = computeGainDB(inDB)        // <= 0

            // attack when more reduction is needed (target more negative), release otherwise
            let coeff = (targetGR < envGR) ? aC : rC
            envGR = targetGR + (envGR - targetGR) * coeff

            if -envGR > maxGR { maxGR = -envGR }

            let gainLin = dbToGain(clampd(envGR + makeup, -60.0, 24.0))
            for c in 0..<ch {
                out[c][i] = Float(clampd(Double(s.channels[c][i]) * gainLin, -4.0, 4.0))
            }
        }
        lastGainReductionDB = maxGR
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}

// MARK: - Linkwitz-Riley 4th-order filter (two cascaded Butterworth biquads)

private final class LR4Filter {
    private var stages: [[Biquad]]   // [channel][2]
    init(kind: FilterKind, freq: Double, sampleRate: Double, channels: Int) {
        let c = BiquadCoeffs.make(kind, freq: freq, sampleRate: sampleRate, q: 0.707)
        stages = (0..<max(1, channels)).map { _ in [Biquad(c), Biquad(c)] }
    }
    @inline(__always) func process(_ x: Double, channel: Int) -> Double {
        var v = x
        v = stages[channel][0].process(v)
        v = stages[channel][1].process(v)
        return v
    }
    func reset() { for ch in stages { for b in ch { b.reset() } } }
}

// MARK: - MultibandCompressor

/// 3-band multiband compressor. LR4 crossovers split the signal; the low band is
/// allpass-compensated through the upper crossover so the bands sum flat when idle.
final class MultibandCompressor {
    let sampleRate: Double
    let crossovers: [Double]      // two frequencies, low->mid and mid->high
    private(set) var lastGainReductionDB: Double = 0

    init(sampleRate: Double, crossovers: [Double] = [120, 2500]) {
        self.sampleRate = max(1.0, sampleRate)
        // sanitize: two ascending crossovers below Nyquist
        let ny = self.sampleRate / 2
        var f = crossovers.count >= 2 ? [crossovers[0], crossovers[1]] : [120, 2500]
        f[0] = clampd(f[0], 20, ny - 1)
        f[1] = clampd(f[1], f[0] + 1, ny - 1)
        self.crossovers = f
    }

    func reset() { lastGainReductionDB = 0 }

    func process(_ s: AudioSignal, band settings: [CompressorSettings]) -> AudioSignal {
        let ch = s.channelCount
        let n = s.frameCount
        guard ch > 0, n > 0 else { return s }

        // exactly three band settings; pad/truncate defensively
        var bs = settings
        while bs.count < 3 { bs.append(CompressorSettings()) }
        if bs.count > 3 { bs = Array(bs.prefix(3)) }

        let f1 = crossovers[0], f2 = crossovers[1]
        let lpF1 = LR4Filter(kind: .lowPass,  freq: f1, sampleRate: sampleRate, channels: ch)
        let hpF1 = LR4Filter(kind: .highPass, freq: f1, sampleRate: sampleRate, channels: ch)
        let lpF2 = LR4Filter(kind: .lowPass,  freq: f2, sampleRate: sampleRate, channels: ch)
        let hpF2 = LR4Filter(kind: .highPass, freq: f2, sampleRate: sampleRate, channels: ch)
        // allpass compensation of the low band through the f2 network
        let lpF2c = LR4Filter(kind: .lowPass,  freq: f2, sampleRate: sampleRate, channels: ch)
        let hpF2c = LR4Filter(kind: .highPass, freq: f2, sampleRate: sampleRate, channels: ch)

        var low  = Array(repeating: [Float](repeating: 0, count: n), count: ch)
        var mid  = Array(repeating: [Float](repeating: 0, count: n), count: ch)
        var high = Array(repeating: [Float](repeating: 0, count: n), count: ch)

        for c in 0..<ch {
            for i in 0..<n {
                let x = Double(s.channels[c][i])
                let l1 = lpF1.process(x, channel: c)
                let h1 = hpF1.process(x, channel: c)
                mid[c][i]  = Float(lpF2.process(h1, channel: c))
                high[c][i] = Float(hpF2.process(h1, channel: c))
                // low through both halves of the f2 crossover = allpass, phase-aligned to mid/high
                let lC = lpF2c.process(l1, channel: c) + hpF2c.process(l1, channel: c)
                low[c][i] = Float(lC)
            }
        }

        let cLow  = Compressor(settings: bs[0], sampleRate: sampleRate)
        let cMid  = Compressor(settings: bs[1], sampleRate: sampleRate)
        let cHigh = Compressor(settings: bs[2], sampleRate: sampleRate)
        let oLow  = cLow.process(AudioSignal(channels: low,  sampleRate: s.sampleRate))
        let oMid  = cMid.process(AudioSignal(channels: mid,  sampleRate: s.sampleRate))
        let oHigh = cHigh.process(AudioSignal(channels: high, sampleRate: s.sampleRate))

        lastGainReductionDB = max(cLow.lastGainReductionDB, max(cMid.lastGainReductionDB, cHigh.lastGainReductionDB))

        var out = Array(repeating: [Float](repeating: 0, count: n), count: ch)
        for c in 0..<ch {
            for i in 0..<n {
                let v = Double(oLow.channels[c][i]) + Double(oMid.channels[c][i]) + Double(oHigh.channels[c][i])
                out[c][i] = Float(clampd(v, -4.0, 4.0))
            }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}

// MARK: - Parallel (NY) blend

/// Dry/wet crossfade for parallel (New York) compression: run a compressor hard on a copy,
/// then blend it under the untouched dry path. wetMix 0 returns the dry signal untouched
/// (bit-transparent); wetMix 1 returns the wet signal. Sample-aligned inputs assumed
/// (the Compressor adds no latency).
enum ParallelBlend {
    static func blend(dry: AudioSignal, wet: AudioSignal, wetMix: Double) -> AudioSignal {
        let m = clampd(wetMix, 0.0, 1.0)
        if m <= 0 { return dry }
        if m >= 1 { return wet }
        let ch = min(dry.channelCount, wet.channelCount)
        guard ch > 0 else { return dry }
        var out = dry.channels
        for c in 0..<ch {
            let n = min(dry.channels[c].count, wet.channels[c].count)
            for i in 0..<n {
                let v = Double(dry.channels[c][i]) * (1.0 - m) + Double(wet.channels[c][i]) * m
                out[c][i] = Float(clampd(v, -4.0, 4.0))
            }
        }
        return AudioSignal(channels: out, sampleRate: dry.sampleRate)
    }
}

// MARK: - Limiter

struct LimiterSettings {
    var ceilingDBTP: Double
    var lookaheadMs: Double
    var releaseMs: Double
    init(ceilingDBTP: Double = -1.0, lookaheadMs: Double = 2, releaseMs: Double = 60) {
        self.ceilingDBTP = min(0.0, ceilingDBTP)
        self.lookaheadMs = max(0.1, lookaheadMs)
        self.releaseMs = max(1.0, releaseMs)
    }
}

/// Lookahead brickwall limiter. Offline: builds a 4x-oversampled true-peak envelope,
/// takes a sliding-min of the ceiling/peak target gain over the lookahead window (so the
/// gain is already down when a peak arrives), then releases gradually. Output TP <= ceiling.
final class Limiter {
    private(set) var settings: LimiterSettings
    let sampleRate: Double
    private(set) var lastGainReductionDB: Double = 0

    init(settings: LimiterSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func reset() { lastGainReductionDB = 0 }

    func process(_ s: AudioSignal) -> AudioSignal {
        let ch = s.channelCount
        let n = s.frameCount
        guard ch > 0, n > 0 else { return s }

        let ceiling = dbToGain(settings.ceilingDBTP)
        let L = max(1, Int((settings.lookaheadMs * 0.001 * sampleRate).rounded()))
        let os = 4

        // Per-sample TRUE-peak estimate via 4x SINC oversampling. Linear interpolation
        // (the previous approach) can never exceed the sample values, so it only reveals
        // sample peaks and lets real inter-sample overshoots leak over the ceiling. A
        // windowed-sinc fractional-delay reconstruction actually surfaces them, so the
        // limiter now pulls gain enough to hold true peak, not just sample peak.
        let taps = 24
        let branches = Limiter.polyphase(taps: taps, phases: os)
        var tp = [Double](repeating: 0, count: n)
        for c in 0..<ch {
            let x = s.channels[c]
            for i in 0..<n {
                var localMax = abs(Double(x[i]))          // the on-grid sample itself
                for ph in 1..<os {                        // phase 0 ≈ identity; check the 3 fractional positions
                    var acc = 0.0
                    let br = branches[ph]
                    let start = i - taps + 1
                    for t in 0..<taps {
                        let idx = start + t
                        if idx >= 0 && idx < n { acc += Double(x[idx]) * br[t] }
                    }
                    let a = abs(acc)
                    if a > localMax { localMax = a }
                }
                if localMax > tp[i] { tp[i] = localMax }
            }
        }

        // per-sample target gain to bring peak to ceiling
        var gTarget = [Double](repeating: 1, count: n)
        for i in 0..<n {
            gTarget[i] = tp[i] > 1e-9 ? min(1.0, ceiling / tp[i]) : 1.0
        }

        // sliding-window min over [i, i+L] (monotonic deque) => attack anticipates the peak
        var gMin = [Double](repeating: 1, count: n)
        var dq = [Int]()  // indices, increasing gTarget
        dq.reserveCapacity(L + 1)
        // preload first window [0, L]
        for j in 0...min(L, n - 1) {
            while let last = dq.last, gTarget[last] >= gTarget[j] { dq.removeLast() }
            dq.append(j)
        }
        for i in 0..<n {
            // window is [i, i+L]; drop indices that fell behind i
            while let first = dq.first, first < i { dq.removeFirst() }
            gMin[i] = gTarget[dq[0]]
            // extend window front to i+L+1 for next iteration
            let add = i + L + 1
            if add < n {
                while let last = dq.last, gTarget[last] >= gTarget[add] { dq.removeLast() }
                dq.append(add)
            }
        }

        // release smoothing: instant attack (gMin already anticipates), gradual recovery
        let rC = smoothCoeff(ms: settings.releaseMs, sampleRate: sampleRate)
        var gEnv = 1.0
        var minGain = 1.0
        var out = s.channels
        for i in 0..<n {
            let desired = gMin[i]
            if desired < gEnv {
                gEnv = desired                                   // attack: instant
            } else {
                gEnv = desired + (gEnv - desired) * rC           // release: ease up (stays <= gMin, safe)
            }
            if gEnv < minGain { minGain = gEnv }
            for c in 0..<ch {
                let v = Double(s.channels[c][i]) * gEnv
                out[c][i] = Float(clampd(v, -ceiling, ceiling))  // hard safety at ceiling
            }
        }
        lastGainReductionDB = -gainToDb(minGain)
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    /// Polyphase windowed-sinc fractional-delay filters (one branch per oversampling phase),
    /// each normalized to unity DC gain so a branch reconstructs the signal at delay p/phases.
    static func polyphase(taps: Int, phases: Int) -> [[Double]] {
        var branches = [[Double]](repeating: [Double](repeating: 0, count: taps), count: phases)
        let center = Double(taps / 2 - 1)
        for p in 0..<phases {
            let delay = Double(p) / Double(phases)
            var sum = 0.0
            for t in 0..<taps {
                let m = Double(t) - center - delay
                let sinc = abs(m) < 1e-9 ? 1.0 : sin(Double.pi * m) / (Double.pi * m)
                let w = 0.54 - 0.46 * cos(2 * Double.pi * Double(t) / Double(taps - 1))  // Hamming
                let v = sinc * w
                branches[p][t] = v
                sum += v
            }
            if abs(sum) > 1e-12 { for t in 0..<taps { branches[p][t] /= sum } }
        }
        return branches
    }
}
