// Delay.swift — stereo delay: slapback / ping-pong / tape / multi-tap.
//
// Contract: offline block processing on AudioSignal; output has identical shape. Bypassed
// settings (`enabled == false`) are a bit-transparent passthrough. Deterministic — the tape
// wow LFO starts at a fixed phase, so the same input + settings always render the same echo.
//
// Modes:
//   • slapback — one clean repeat per channel at timeMs; no recirculation (the '50s vocal
//                doubler). The feedback/filter parameters are ignored by design.
//   • pingPong — mono-folded input feeds the LEFT line; the feedback path crosses L→R→L,
//                echoes alternating sides, filtered by the feedback-path HP/LP each pass.
//   • tape     — per-channel recirculating delay whose feedback passes through the HP/LP
//                (repeats get darker/thinner each pass, like worn tape) with subtle wow:
//                a slow LFO (0.5 Hz, fixed phase) modulates the read position ±0.1% of the
//                delay time (fractional read, linear interp).
//   • multiTap — four feedforward taps at 1×, 1.5×, 2×, 3× timeMs with falling gains
//                (1.0 / 0.7 / 0.5 / 0.35); no recirculation.
//
// Feedback is clamped to 0.95 so recirculating modes always decay.

import Foundation

enum DelayMode: String, Codable, CaseIterable, Sendable {
    case slapback, pingPong, tape, multiTap
}

struct DelaySettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    var mode: DelayMode
    /// Base delay time, ms. Clamped 10…2000.
    var timeMs: Double
    /// Recirculation amount 0…0.95 (pingPong + tape).
    var feedback: Double
    /// High-pass in the feedback path, Hz (thins repeats).
    var feedbackHPHz: Double
    /// Low-pass in the feedback path, Hz (darkens repeats).
    var feedbackLPHz: Double
    /// Wet blend 0…1.
    var mix: Double

    init(enabled: Bool, mode: DelayMode = .tape, timeMs: Double = 350,
         feedback: Double = 0.35, feedbackHPHz: Double = 120,
         feedbackLPHz: Double = 8000, mix: Double = 0.3) {
        self.enabled = enabled
        self.mode = mode
        self.timeMs = min(max(timeMs, 10), 2000)
        self.feedback = min(max(feedback, 0), 0.95)
        self.feedbackHPHz = min(max(feedbackHPHz, 20), 2000)
        self.feedbackLPHz = min(max(feedbackLPHz, 500), 20_000)
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = DelaySettings(enabled: false)
}

final class StereoDelay {
    let settings: DelaySettings
    let sampleRate: Double

    init(settings: DelaySettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, s.channelCount > 0, s.frameCount > 0 else { return s }
        let n = s.frameCount
        let ch = s.channelCount
        let D = max(1, Int(settings.timeMs * 0.001 * sampleRate))
        let mix = settings.mix

        // Wet render per mode (channel count preserved; mono input → mono wet).
        var wet = [[Double]](repeating: [Double](repeating: 0, count: n), count: ch)

        switch settings.mode {
        case .slapback:
            for c in 0..<ch {
                let src = s.channels[c]
                for i in 0..<min(n, src.count) where i >= D {
                    wet[c][i] = Double(src[i - D])
                }
            }

        case .multiTap:
            let taps: [(mult: Double, gain: Double)] = [(1.0, 1.0), (1.5, 0.7), (2.0, 0.5), (3.0, 0.35)]
            for c in 0..<ch {
                let src = s.channels[c]
                let m = min(n, src.count)
                for (mult, gain) in taps {
                    let d = max(1, Int(Double(D) * mult))
                    for i in d..<m { wet[c][i] += gain * Double(src[i - d]) }
                }
            }

        case .pingPong:
            // Mono fold drives the left line; feedback crosses L→R→L through the HP/LP.
            var mono = [Double](repeating: 0, count: n)
            for c in 0..<ch {
                let src = s.channels[c]
                for i in 0..<min(n, src.count) { mono[i] += Double(src[i]) }
            }
            let norm = 1.0 / Double(ch)
            for i in 0..<n { mono[i] *= norm }

            var bufL = [Double](repeating: 0, count: D)
            var bufR = [Double](repeating: 0, count: D)
            var idx = 0
            var fbFilter = FeedbackFilter(hpHz: settings.feedbackHPHz, lpHz: settings.feedbackLPHz,
                                          sampleRate: sampleRate, channels: 2)
            for i in 0..<n {
                let outL = bufL[idx]
                let outR = bufR[idx]
                bufL[idx] = mono[i] + settings.feedback * fbFilter.run(outR, channel: 0)
                bufR[idx] = settings.feedback * fbFilter.run(outL, channel: 1)
                idx = (idx + 1) % D
                wet[0][i] = outL
                if ch > 1 { wet[1][i] = outR }
            }

        case .tape:
            let wowRate = 0.5                                   // Hz, fixed
            let wowDepth = max(1.0, Double(D) * 0.001)          // ±0.1% of the delay time
            var fbFilter = FeedbackFilter(hpHz: settings.feedbackHPHz, lpHz: settings.feedbackLPHz,
                                          sampleRate: sampleRate, channels: ch)
            let bufLen = D + Int(wowDepth) + 4
            for c in 0..<ch {
                let src = s.channels[c]
                let m = min(n, src.count)
                var buf = [Double](repeating: 0, count: bufLen)
                var w = 0
                for i in 0..<m {
                    // Wow: modulated fractional read position behind the write head.
                    let lfo = sin(2.0 * Double.pi * wowRate * Double(i) / sampleRate)
                    let readOffset = Double(D) + wowDepth * lfo
                    let rp = Double(w) - readOffset
                    let rWrapped = rp - (rp / Double(bufLen)).rounded(.down) * Double(bufLen)
                    let i0 = Int(rWrapped) % bufLen
                    let frac = rWrapped - Double(Int(rWrapped))
                    let i1 = (i0 + 1) % bufLen
                    let echo = buf[i0] + (buf[i1] - buf[i0]) * frac
                    buf[w] = Double(src[i]) + settings.feedback * fbFilter.run(echo, channel: c)
                    w = (w + 1) % bufLen
                    wet[c][i] = echo
                }
            }
        }

        var out = s.channels
        for c in 0..<ch {
            var y = s.channels[c]
            let m = min(n, y.count)
            for i in 0..<m {
                let v = Double(y[i]) * (1.0 - mix) + wet[c][i] * mix
                y[i] = Float(min(max(v, -4.0), 4.0))
            }
            out[c] = y
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}

/// One-pole HP + LP pair in a delay's feedback path (per-channel state).
private struct FeedbackFilter {
    private let hpC: Double
    private let lpC: Double
    private var hpState: [Double]
    private var lpState: [Double]

    init(hpHz: Double, lpHz: Double, sampleRate: Double, channels: Int) {
        hpC = exp(-2.0 * Double.pi * hpHz / sampleRate)
        lpC = exp(-2.0 * Double.pi * min(lpHz, sampleRate * 0.49) / sampleRate)
        hpState = [Double](repeating: 0, count: max(1, channels))
        lpState = [Double](repeating: 0, count: max(1, channels))
    }

    mutating func run(_ x: Double, channel: Int) -> Double {
        // HP = input minus its low-passed self; then LP.
        hpState[channel] = hpC * hpState[channel] + (1 - hpC) * x
        let hp = x - hpState[channel]
        lpState[channel] = lpC * lpState[channel] + (1 - lpC) * hp
        return lpState[channel]
    }
}
