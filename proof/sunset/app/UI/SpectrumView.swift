#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// SpectrumView: log-frequency spectrum plot — before (dim) vs after (gold) with the applied EQ curve overlaid.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// Draws the before/after magnitude spectra and the corrective EQ curve on a shared
/// log-frequency X axis. All arrays come straight off MasterResult; empty state is honest.
struct SpectrumView: View {
    let before: [Float]      // spectrumBeforeDB — band dB, dim line
    let after: [Float]       // spectrumAfterDB  — band dB, gold line
    let eqCurve: [Float]     // eqCurveDB        — corrective EQ, gold outline, own dB scale

    private var hasData: Bool { !before.isEmpty || !after.isEmpty || !eqCurve.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Spectrum").font(.system(size: 14, weight: .semibold)).foregroundColor(Palette.goldTxt)
                Spacer()
                legend
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Palette.ink)
                RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke)
                if hasData {
                    Canvas { ctx, size in draw(ctx, size) }
                        .padding(10)
                } else {
                    Text("Run a master to see the spectrum.")
                        .font(.system(size: 12)).foregroundColor(Palette.dim)
                }
            }
            .frame(minHeight: 220)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.stroke))
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("Before", Palette.dim)
            legendItem("After", Palette.gold)
            legendItem("EQ", Palette.goldDk)
        }
    }
    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 10)).foregroundColor(Palette.dim)
        }
    }

    // MARK: - Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        guard w > 4, h > 4 else { return }

        // dB range for the spectra: auto-fit the top, keep a fixed 90 dB window below it.
        let spectra = before + after
        let top = (spectra.max().map { Double($0) } ?? 0).rounded(.up)
        let dbMax = max(top + 3, 0)
        let dbMin = dbMax - 90

        func x(_ frac: Double) -> CGFloat { CGFloat(frac) * w }
        func ySpectrum(_ db: Double) -> CGFloat {
            let t = (dbMax - db) / (dbMax - dbMin)
            return CGFloat(min(max(t, 0), 1)) * h
        }

        // Frequency gridlines at decade marks (mapped by fraction across the band axis).
        let n = max(before.count, after.count, FreqBands.centers.count)
        if n > 1 {
            let centers = FreqBands.centers
            let logLo = log(centers.first ?? 20), logHi = log(centers.last ?? 20000)
            for f in [100.0, 1000.0, 10000.0] {
                let frac = (log(f) - logLo) / (logHi - logLo)
                guard frac >= 0, frac <= 1 else { continue }
                var line = Path(); line.move(to: CGPoint(x: x(frac), y: 0)); line.addLine(to: CGPoint(x: x(frac), y: h))
                ctx.stroke(line, with: .color(Palette.stroke.opacity(0.6)), lineWidth: 1)
                let label = f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
                ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(Palette.dim),
                         at: CGPoint(x: x(frac) + 10, y: h - 8))
            }
        }

        // Spectra: index-fraction across the axis (both are third-octave band arrays).
        if !before.isEmpty {
            ctx.stroke(spectrumPath(before, x: x, y: ySpectrum), with: .color(Palette.dim), lineWidth: 1.4)
        }
        if !after.isEmpty {
            ctx.stroke(spectrumPath(after, x: x, y: ySpectrum), with: .color(Palette.gold), lineWidth: 1.8)
        }

        // EQ curve on its own symmetric dB scale, centred on a faint zero line.
        if !eqCurve.isEmpty {
            let eqRange = max(6.0, (eqCurve.map { abs(Double($0)) }.max() ?? 6).rounded(.up))
            var zero = Path(); zero.move(to: CGPoint(x: 0, y: h / 2)); zero.addLine(to: CGPoint(x: w, y: h / 2))
            ctx.stroke(zero, with: .color(Palette.stroke.opacity(0.5)), lineWidth: 1)
            func yEQ(_ db: Double) -> CGFloat { h / 2 - CGFloat(db / eqRange) * (h / 2 * 0.9) }
            ctx.stroke(spectrumPath(eqCurve, x: x, y: yEQ), with: .color(Palette.goldDk), lineWidth: 1.6)
        }
    }

    /// Build a polyline path for a dB array spread evenly across the log-frequency axis.
    private func spectrumPath(_ vals: [Float], x: (Double) -> CGFloat, y: (Double) -> CGFloat) -> Path {
        var p = Path()
        let count = vals.count
        guard count > 0 else { return p }
        for i in 0..<count {
            let frac = count == 1 ? 0.5 : Double(i) / Double(count - 1)
            let pt = CGPoint(x: x(frac), y: y(Double(vals[i])))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
#endif // circuit-convert
