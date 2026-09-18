#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// PlaybackEngine: in-app A/B audition of the original vs the master.
//
// Loads an AudioSignal into a PCM buffer and plays it through AVAudioEngine.
// The point is instant A/B: play the original, flip to the master at the same
// playhead, and hear exactly what the chain did. Position is reported so the
// waveform can draw a playhead.

import Foundation
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif

@MainActor
final class PlaybackEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var isPlaying = false
    private var totalFrames: AVAudioFramePosition = 0
    private var seekFrame: AVAudioFramePosition = 0

    init() { engine.attach(player) }

    /// Build a float PCM buffer from a deinterleaved AudioSignal, starting at frame `from`.
    /// (AVAudioPlayerNode.scheduleBuffer plays a whole buffer, so seeking = copy from the
    /// seek point into a fresh buffer.) `gain` is the static equal-loudness match multiplier
    /// applied at copy time — 1.0 leaves the signal byte-identical.
    private func makeBuffer(_ signal: AudioSignal, from: Int, gain: Float) -> AVAudioPCMBuffer? {
        let chCount = max(1, signal.channelCount)
        let sr = signal.sampleRate > 0 ? signal.sampleRate : 44100
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr,
                                      channels: AVAudioChannelCount(chCount)) else { return nil }
        let count = max(0, signal.frameCount - from)
        let n = AVAudioFrameCount(count)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
        buf.frameLength = n
        guard let data = buf.floatChannelData else { return nil }
        let applyGain = gain != 1.0
        for c in 0..<chCount {
            let src = signal.channels[min(c, signal.channelCount - 1)]
            let dst = data[c]
            for i in 0..<Int(n) {
                let idx = from + i
                let s = idx < src.count ? src[idx] : 0
                dst[i] = applyGain ? s * gain : s
            }
        }
        return buf
    }

    /// Play `signal` starting at `fromFraction` (0…1), scaled by the static equal-loudness match
    /// `gain` (1.0 = unchanged). `onFinish` fires on the main actor at natural end. Safe to call
    /// repeatedly — it restarts cleanly.
    func play(_ signal: AudioSignal, fromFraction: Double, gain: Float = 1.0,
              onFinish: @escaping @Sendable () -> Void) {
        stop()
        totalFrames = AVAudioFramePosition(signal.frameCount)
        let frac = min(max(fromFraction, 0), 0.999)
        seekFrame = AVAudioFramePosition(Double(signal.frameCount) * frac)
        guard let buf = makeBuffer(signal, from: Int(seekFrame), gain: gain) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: buf.format)
        do { try engine.start() } catch { return }

        player.scheduleBuffer(buf, at: nil, options: []) {
            Task { @MainActor in onFinish() }
        }
        player.play()
        isPlaying = true
    }

    func stop() {
        if engine.isRunning { player.stop(); engine.stop() }
        isPlaying = false
    }

    /// Current playhead as a fraction 0…1 (best-effort from the render clock).
    var fraction: Double {
        guard isPlaying, totalFrames > 0,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        let pos = seekFrame + playerTime.sampleTime
        return min(max(Double(pos) / Double(totalFrames), 0), 1)
    }
}
#endif // circuit-convert
