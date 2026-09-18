#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// WaveformView: a peak-envelope waveform with a scrubbable playhead.
//
// Draws a precomputed peak array (built once when a signal loads — never per frame,
// so the playhead animates cheaply). Click or drag anywhere to seek: the gesture maps
// x/width to a 0…1 fraction and calls `onSeek`. Used for BOTH the original and the
// master so you can see and hear the before/after at the same playhead.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct WaveformView: View {
    let peaks: [Float]          // precomputed 0…1 magnitudes, one per bin
    var playhead: Double = 0    // 0…1
    var tint: Color = Palette.gold
    var height: CGFloat = 56
    var onSeek: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(ctx, size) }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let f = min(max(v.location.x / max(geo.size.width, 1), 0), 1)
                            onSeek?(f)
                        }
                )
        }
        .frame(height: height)
        .background(Palette.ink)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.stroke, lineWidth: 1))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let midY = size.height / 2
        guard !peaks.isEmpty else {
            var base = Path()
            base.move(to: CGPoint(x: 0, y: midY))
            base.addLine(to: CGPoint(x: size.width, y: midY))
            ctx.stroke(base, with: .color(Palette.stroke), lineWidth: 1)
            return
        }
        // played portion tinted brighter, unplayed dimmer — reads like a real transport
        let playX = CGFloat(min(max(playhead, 0), 1)) * size.width
        let n = peaks.count
        let w = max(1, Int(size.width))
        var played = Path(), ahead = Path()
        for x in 0..<w {
            let idx = min(n - 1, Int(Double(x) / Double(w) * Double(n)))
            let h = CGFloat(peaks[idx]) * (size.height / 2 - 1)
            let fx = CGFloat(x)
            let seg = { (p: inout Path) in
                p.move(to: CGPoint(x: fx, y: midY - h))
                p.addLine(to: CGPoint(x: fx, y: midY + max(h, 0.5)))
            }
            if fx <= playX { seg(&played) } else { seg(&ahead) }
        }
        ctx.stroke(ahead, with: .color(tint.opacity(0.35)), lineWidth: 1)
        ctx.stroke(played, with: .color(tint.opacity(0.95)), lineWidth: 1)

        var ph = Path()
        ph.move(to: CGPoint(x: playX, y: 0))
        ph.addLine(to: CGPoint(x: playX, y: size.height))
        ctx.stroke(ph, with: .color(.white.opacity(0.9)), lineWidth: 1.4)
    }

    /// Downsample a signal to `bins` peak magnitudes (call once, off the render path).
    static func envelope(_ s: AudioSignal, bins: Int = 1400) -> [Float] {
        let n = s.frameCount
        guard n > 0, bins > 0, s.channelCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: bins)
        let per = max(1, n / bins)
        for b in 0..<bins {
            let start = b * per
            let end = min(n, start + per)
            if start >= end { break }
            var peak: Float = 0
            for c in 0..<s.channelCount {
                let src = s.channels[c]
                var i = start
                while i < end { let a = abs(src[i]); if a > peak { peak = a }; i += 1 }
            }
            out[b] = min(peak, 1)
        }
        return out
    }
}
#endif // circuit-convert
