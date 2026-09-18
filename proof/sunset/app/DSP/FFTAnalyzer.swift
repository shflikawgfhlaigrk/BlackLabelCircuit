// FFTAnalyzer.swift — real-FFT spectral analysis on Accelerate/vDSP.
//
// Two jobs:
//   1. Live magnitude spectrum for the UI analyzer (single windowed frame).
//   2. Averaged power-spectral-density (Welch) over a whole signal — the
//      spectral "fingerprint" the reference-matcher and genre-target use.
//
// All math is Float; Apple-Silicon vDSP handles the heavy lifting.

import Foundation
import Accelerate

final class FFTAnalyzer {
    let size: Int          // FFT length (power of two)
    let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private let half: Int

    init(size: Int = 4096) {
        // round down to a power of two
        var n = 1
        while n * 2 <= size { n *= 2 }
        self.size = n
        self.half = n / 2
        self.log2n = vDSP_Length(log2(Double(n)).rounded())
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Magnitude spectrum (linear) of one frame of `size` samples.
    /// Returns `size/2` bins. Short input is zero-padded.
    func magnitude(_ frame: [Float]) -> [Float] {
        var windowed = [Float](repeating: 0, count: size)
        let count = min(frame.count, size)
        for i in 0..<count { windowed[i] = frame[i] }
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(size))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // zrip packs Nyquist into imag[0]; zero it so bin 0 is pure DC magnitude.
                split.imagp[0] = 0
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        // vDSP real FFT scales by 2; normalize to amplitude.
        var scale = Float(1.0) / Float(size)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(half))
        return mags
    }

    /// Welch-averaged power spectrum (magnitude², linear) over the whole signal.
    /// 50%-overlap Hann windows. This is the spectral fingerprint used for
    /// reference-matching and tonal-balance targets. Returns `size/2` bins.
    func averagePower(_ signal: [Float]) -> [Float] {
        guard signal.count >= size else {
            let m = magnitude(signal)
            return m.map { $0 * $0 }
        }
        let hop = size / 2
        var acc = [Float](repeating: 0, count: half)
        var frames = 0
        var pos = 0
        while pos + size <= signal.count {
            let frame = Array(signal[pos..<pos + size])
            let m = magnitude(frame)
            var sq = [Float](repeating: 0, count: half)
            vDSP_vsq(m, 1, &sq, 1, vDSP_Length(half))
            vDSP_vadd(acc, 1, sq, 1, &acc, 1, vDSP_Length(half))
            frames += 1
            pos += hop
        }
        if frames > 0 {
            var inv = Float(1.0) / Float(frames)
            vDSP_vsmul(acc, 1, &inv, &acc, 1, vDSP_Length(half))
        }
        return acc
    }

    /// Center frequency (Hz) of bin `i` at the given sample rate.
    func binFrequency(_ i: Int, sampleRate: Double) -> Double {
        Double(i) * sampleRate / Double(size)
    }
}

/// Fixed logarithmic frequency bands used for spectral fingerprints and the
/// reference match curve. 1/3-octave-ish from 20 Hz to ~20 kHz.
enum FreqBands {
    static let centers: [Double] = {
        var f = [Double]()
        var hz = 20.0
        while hz < 20000 {
            f.append(hz)
            hz *= pow(2.0, 1.0 / 3.0)   // third-octave steps
        }
        return f
    }()

    /// Average an FFT power spectrum into the fixed log bands (returns dB per band).
    static func toBandsDB(power: [Float], sampleRate: Double, fftSize: Int) -> [Float] {
        let half = power.count
        var out = [Float](repeating: -120, count: centers.count)
        for (bi, fc) in centers.enumerated() {
            let lo = fc / pow(2.0, 1.0 / 6.0)
            let hi = fc * pow(2.0, 1.0 / 6.0)
            let loBin = max(1, Int(lo * Double(fftSize) / sampleRate))
            let hiBin = min(half - 1, Int(hi * Double(fftSize) / sampleRate))
            if hiBin < loBin { continue }
            var sum: Float = 0
            for k in loBin...hiBin { sum += power[k] }
            let mean = sum / Float(hiBin - loBin + 1)
            out[bi] = 10 * log10(max(mean, 1e-12))
        }
        return out
    }
}
