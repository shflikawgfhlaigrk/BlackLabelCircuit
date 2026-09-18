// Dither: TPDF dither with 2nd-order error-feedback noise shaping before final quantization.
import Foundation

enum Dither {

    /// Deterministic 32-bit xorshift PRNG → reproducible dither noise (seed per channel).
    private struct XorShift {
        var state: UInt32
        init(seed: UInt32) { state = seed == 0 ? 0x1234_5678 : seed }
        mutating func nextUnit() -> Double { // uniform in [0,1)
            var x = state
            x ^= x << 13
            x ^= x >> 17
            x ^= x << 5
            state = x
            return Double(x) / Double(UInt32.max)
        }
    }

    /// Add TPDF dither (±1 LSB at target bit depth) with a simple 2nd-order highpass
    /// noise-shaping error feedback, then round-quantize to the target grid. Output stays
    /// Float (the file writer performs the actual bit conversion). 16-bit gets full-weight
    /// dither; 24-bit gets light dither; anything else is returned unchanged.
    static func apply(_ s: AudioSignal, targetBitDepth: Int) -> AudioSignal {
        guard s.frameCount > 0, s.channelCount > 0 else { return s }

        // Dither weight: meaningful at 16-bit, light touch at 24-bit, none otherwise.
        let weight: Double
        switch targetBitDepth {
        case 16: weight = 1.0
        case 24: weight = 0.5
        default: return s
        }

        // LSB step for a signed integer grid of `targetBitDepth` bits over [-1, 1].
        let maxCode = Double(1 << (targetBitDepth - 1)) // e.g. 32768 for 16-bit
        let lsb = 1.0 / maxCode

        // 2nd-order highpass error-feedback shaping (pushes noise toward high freq).
        let c1 = 2.0, c2 = -1.0

        var out = s.channels
        for ch in 0..<s.channelCount {
            let src = s.channels[ch]
            let n = src.count
            var dst = [Float](repeating: 0, count: n)

            // Per-channel seed → reproducible, decorrelated across channels.
            var rng = XorShift(seed: 0x9E37_79B9 &+ UInt32(ch) &* 0x0000_2545)
            var e1 = 0.0, e2 = 0.0 // previous quantization errors

            for i in 0..<n {
                // TPDF = sum of two independent uniforms, spanning ±1 LSB.
                let tpdf = (rng.nextUnit() - rng.nextUnit()) * lsb * weight

                // Feed shaped past error back into the signal, then add dither.
                let shaped = c1 * e1 + c2 * e2
                let x = Double(src[i]) + shaped + tpdf

                // Quantize to the target grid (what the writer will store).
                let q = (x * maxCode).rounded() / maxCode

                // Error = input+shaping (pre-dither) minus stored value; propagate.
                e2 = e1
                e1 = (Double(src[i]) + shaped) - q

                dst[i] = Float(max(-1.0, min(1.0, q)))
            }
            out[ch] = dst
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}
