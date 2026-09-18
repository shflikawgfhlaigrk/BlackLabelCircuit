#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Whole-reel color grading — a non-destructive grade applied to EVERY frame source the
// renderer composites (still-photo backgrounds and footage-clip frames) in preview, poster,
// and .mp4 export, layered on top of the existing per-scene photo filter.
//
// Presets are just slider settings: picking one fills the sliders, and the buyer can keep
// tuning from there. Defaults are neutral — a project with no grade renders byte-identically
// to before this feature existed (filteredPhoto keeps its no-op fast path).
import Foundation
#if canImport(CoreImage) && !CIRCUIT_WINDOWS_SIM
import CoreImage
#endif

struct ReelColorGrade: Codable, Hashable {
    var exposure: Double = 0        // EV, -1 … 1
    var contrast: Double = 1        // 0.6 … 1.4 (1 = neutral)
    var saturation: Double = 1      // 0 … 2 (1 = neutral)
    var temperature: Double = 0     // -100 … 100 (+ warms, - cools)
    var tint: Double = 0            // -100 … 100 (+ magenta, - green)
    var vibrance: Double = 0        // -1 … 1

    var isNeutral: Bool {
        exposure == 0 && contrast == 1 && saturation == 1 &&
        temperature == 0 && tint == 0 && vibrance == 0
    }

    /// Stable token for render caches — two grades with the same values share cached frames.
    var cacheToken: String {
        String(format: "g%.3f|%.3f|%.3f|%.1f|%.1f|%.3f",
               exposure, contrast, saturation, temperature, tint, vibrance)
    }

    /// Apply the grade as a CoreImage chain. Order mirrors a conventional grading stack:
    /// exposure → white balance → contrast/saturation → vibrance.
    func apply(to input: CIImage) -> CIImage {
        guard !isNeutral else { return input }
        var out = input
        if exposure != 0 {
            out = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposure])
        }
        if temperature != 0 || tint != 0 {
            // targetNeutral below 6500K compensates toward warm; above toward cool.
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - temperature * 22, y: tint * 1.5)
            ])
        }
        if contrast != 1 || saturation != 1 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: contrast,
                kCIInputSaturationKey: saturation,
                kCIInputBrightnessKey: 0
            ])
        }
        if vibrance != 0 {
            out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": vibrance])
        }
        return out
    }

    // MARK: - presets (slider settings, not baked filters — fully editable after picking)

    enum Preset: String, CaseIterable, Identifiable {
        case none = "None"
        case cinematic = "Cinematic"
        case goldenHour = "Golden Hour"
        case coolSteel = "Cool Steel"
        case fadedFilm = "Faded Film"
        case punchy = "Punchy"
        case noir = "Noir"
        var id: String { rawValue }

        var grade: ReelColorGrade {
            switch self {
            case .none:       return ReelColorGrade()
            case .cinematic:  return ReelColorGrade(exposure: -0.05, contrast: 1.12, saturation: 0.92,
                                                    temperature: 12, tint: 0, vibrance: 0.12)
            case .goldenHour: return ReelColorGrade(exposure: 0.06, contrast: 1.04, saturation: 1.05,
                                                    temperature: 38, tint: 4, vibrance: 0.10)
            case .coolSteel:  return ReelColorGrade(exposure: 0, contrast: 1.10, saturation: 0.88,
                                                    temperature: -30, tint: -2, vibrance: 0.05)
            case .fadedFilm:  return ReelColorGrade(exposure: 0.04, contrast: 0.86, saturation: 0.78,
                                                    temperature: 8, tint: 2, vibrance: -0.08)
            case .punchy:     return ReelColorGrade(exposure: 0.03, contrast: 1.18, saturation: 1.22,
                                                    temperature: 0, tint: 0, vibrance: 0.25)
            case .noir:       return ReelColorGrade(exposure: 0, contrast: 1.16, saturation: 0,
                                                    temperature: 0, tint: 0, vibrance: 0)
            }
        }

        /// The preset whose slider settings exactly match `grade`, if any — keeps the preset
        /// picker honest after manual tuning (falls back to nil = "Custom").
        static func matching(_ grade: ReelColorGrade) -> Preset? {
            allCases.first { $0.grade == grade }
        }
    }

    // MARK: - one-tap auto grade (measured from the buyer's own media, never a canned look)

    /// Computes the corrective grade for the buyer's actual media (picked backgrounds +
    /// footage frames): pools luminance, contrast, color cast, and colorfulness statistics,
    /// then nudges each toward neutral. Returns nil when there is nothing to read.
    ///
    /// Deliberately conservative: casts inside a small deadband stay untouched, every
    /// correction is clamped well inside the manual slider ranges, and monochrome media
    /// (an intentional B&W look) gets NO color moves — only exposure/contrast.
    static func auto(analyzing images: [CGImage]) -> ReelColorGrade? {
        var lumas: [Double] = []
        var rMean = 0.0, gMean = 0.0, bMean = 0.0, chromaMean = 0.0
        var pixels = 0
        let side = 32
        let space = CGColorSpaceCreateDeviceRGB()
        for image in images {
            guard let ctx = CGContext(data: nil, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            guard let raw = ctx.data else { continue }
            let px = raw.bindMemory(to: UInt8.self, capacity: side * side * 4)
            for i in stride(from: 0, to: side * side * 4, by: 4) {
                let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
                lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
                rMean += r; gMean += g; bMean += b
                chromaMean += max(r, max(g, b)) - min(r, min(g, b))
                pixels += 1
            }
        }
        guard pixels > 0 else { return nil }
        let n = Double(pixels)
        rMean /= n; gMean /= n; bMean /= n; chromaMean /= n
        let meanL = lumas.reduce(0, +) / n
        let sigma = (lumas.reduce(0) { $0 + ($1 - meanL) * ($1 - meanL) } / n).squareRoot()

        func deadband(_ v: Double, _ width: Double) -> Double { abs(v) < width ? 0 : v }
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
        func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

        var out = ReelColorGrade()
        // Exposure: pull mean luminance toward mid-gray at 60% strength — a nudge, not HDR.
        let ev = log2(0.5 / clamp(meanL, 0.05, 0.95)) * 0.6
        out.exposure = round2(clamp(deadband(ev, 0.04), -0.35, 0.35))
        // Contrast: pull the luminance spread toward a healthy σ ≈ 0.20.
        let c = 1 + (0.20 - sigma) * 1.4
        out.contrast = round2(1 + clamp(deadband(c - 1, 0.04), -0.15, 0.25))

        let monochrome = chromaMean < 0.03
        if !monochrome {
            // White balance: cancel the average cast (temperature R↔B, tint G↔magenta).
            out.temperature = clamp(deadband((bMean - rMean) * 220, 4), -35, 35).rounded()
            out.tint = clamp(deadband((gMean - (rMean + bMean) / 2) * 220, 3), -20, 20).rounded()
            // Colorfulness: lift muted media with vibrance (protects skin tones); rein in
            // oversaturated media with a small saturation trim.
            if chromaMean < 0.17 {
                out.vibrance = round2(clamp(deadband((0.17 - chromaMean) * 1.6, 0.04), 0, 0.30))
            } else if chromaMean > 0.28 {
                out.saturation = round2(1 + clamp(deadband(-(chromaMean - 0.28) * 1.2, 0.03), -0.15, 0))
            }
        }
        return out
    }

    /// Human-readable description of what this grade does — the studio toast shows it after
    /// Auto so the buyer sees exactly what was measured and moved.
    var summary: String {
        var parts: [String] = []
        if exposure != 0 { parts.append(String(format: "%+.2f EV", exposure)) }
        if contrast != 1 { parts.append(String(format: "contrast %+.0f%%", (contrast - 1) * 100)) }
        if temperature != 0 {
            parts.append(temperature > 0 ? String(format: "warmer +%.0f", temperature)
                                         : String(format: "cooler %.0f", temperature))
        }
        if tint != 0 { parts.append(String(format: "tint %+.0f", tint)) }
        if saturation != 1 { parts.append(String(format: "saturation %+.0f%%", (saturation - 1) * 100)) }
        if vibrance != 0 { parts.append(String(format: "vibrance %+.2f", vibrance)) }
        return parts.isEmpty ? "neutral" : parts.joined(separator: " · ")
    }
}
#endif // circuit-convert
