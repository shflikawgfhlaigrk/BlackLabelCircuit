// StereoImager: mid/side width control with low-frequency mono fold for club-safe masters.
import Foundation

final class StereoImager {

    /// Widen/narrow the stereo image via mid/side, keeping lows mono below `monoBelowHz`.
    /// mid=(L+R)/2, side=(L-R)/2; side scaled by width, and the side signal is
    /// high-passed below monoBelowHz so bass stays centered on mono/club systems.
    /// Mono input is returned unchanged.
    func process(_ s: AudioSignal, width: Double, monoBelowHz: Double, sampleRate: Double) -> AudioSignal {
        // Mono (or empty) — nothing to image.
        guard s.channelCount >= 2, s.frameCount > 0 else { return s }

        let n = s.frameCount
        let L = s.channels[0]
        let R = s.channels[1]

        // Clamp width to a musical, safe range (0 = full mono, 2 = very wide).
        let w = max(0.0, min(width, 2.0))

        // High-pass the SIDE channel so lows fold to mono. 0 or negative disables.
        let hpEnabled = monoBelowHz > 0 && monoBelowHz < sampleRate * 0.5
        let hpCoeffs = BiquadCoeffs.make(.highPass, freq: monoBelowHz, sampleRate: sampleRate, q: 0.707)
        let sideHP = Biquad(hpCoeffs)

        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)

        for i in 0..<n {
            let l = Double(L[i])
            let r = Double(R[i])
            let mid = (l + r) * 0.5
            var side = (l - r) * 0.5

            // Roll side off below monoBelowHz (removed lows collapse to mono via mid).
            if hpEnabled {
                side = sideHP.process(side)
            }
            // Apply width to the (possibly high-passed) side.
            side *= w

            let newL = mid + side
            let newR = mid - side
            outL[i] = Float(max(-1.0, min(1.0, newL)))
            outR[i] = Float(max(-1.0, min(1.0, newR)))
        }

        // Preserve any channels beyond stereo untouched.
        var chans = s.channels
        chans[0] = outL
        chans[1] = outR
        return AudioSignal(channels: chans, sampleRate: sampleRate)
    }

    /// Phase correlation of the stereo field, -1 (out of phase) .. +1 (mono), 0 = wide.
    /// Mono input returns 1.0.
    static func correlation(_ s: AudioSignal) -> Double {
        guard s.channelCount >= 2, s.frameCount > 0 else { return 1.0 }
        let L = s.channels[0]
        let R = s.channels[1]
        let n = min(L.count, R.count)
        guard n > 0 else { return 1.0 }

        var sumLR = 0.0, sumLL = 0.0, sumRR = 0.0
        for i in 0..<n {
            let l = Double(L[i])
            let r = Double(R[i])
            sumLR += l * r
            sumLL += l * l
            sumRR += r * r
        }
        let denom = (sumLL * sumRR).squareRoot()
        guard denom > 1e-12 else { return 1.0 } // silence → treat as coherent
        return max(-1.0, min(1.0, sumLR / denom))
    }
}
