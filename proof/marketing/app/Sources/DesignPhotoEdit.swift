#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — non-destructive photo editing for Design Canvas image layers.
//
// Before this file the canvas could do exactly two things to a buyer's photo: round its corners
// and BAKE one of four preset "looks" into its pixels. There was no crop, no flip, and no
// adjustment control at all — while the reel side already shipped a full grading stack
// (`ReelColorGrade`: exposure / white balance / contrast / saturation / vibrance) that the canvas
// simply could not reach.
//
// `DesignPhotoEdit` is that missing stack, stored ON the element and applied at RENDER time:
//   • crop      — normalized insets from each edge of the source image
//   • flip      — horizontal / vertical
//   • grade     — the existing, proven ReelColorGrade (reused, NOT reimplemented)
//   • sharpen / blur / vignette — one CoreImage filter each
//
// Two bindings this file keeps:
//   1. NON-DESTRUCTIVE. The buyer's original bytes in `element.imageData` are never rewritten.
//      Every value is reversible by dragging the slider back; "Reset" restores the import exactly.
//      (The legacy `Look` buttons still bake — they are unchanged and left alone.)
//   2. NEUTRAL == UNCHANGED. `isNeutral` short-circuits the whole pipeline, so a document that
//      never touched these controls renders through the identical code path it did before this
//      file existed — byte-for-byte, in both the editor preview and the export.
//
// All local Apple frameworks (CoreImage). No network, no paid API (§5.5).
import Foundation
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
#if canImport(CoreImage) && !CIRCUIT_WINDOWS_SIM
import CoreImage
#endif

// MARK: - Model

/// The non-destructive edit stack for one image/logo layer. Value type, Codable, and stored
/// inline on `DesignElement` so a design document stays a single self-contained blob.
struct DesignPhotoEdit: Codable, Hashable {

    // Crop — fraction of the SOURCE image trimmed from each edge (0 = no trim).
    // Normalized rather than pixel-based so a crop survives the buyer re-importing at a
    // different resolution, and so it composes with the frame's aspect-fill unchanged.
    var cropTop: Double = 0
    var cropLeading: Double = 0
    var cropBottom: Double = 0
    var cropTrailing: Double = 0

    var flipHorizontal: Bool = false
    var flipVertical: Bool = false

    /// Reused verbatim from the reel renderer — exposure, temperature/tint, contrast,
    /// saturation, vibrance. One grading implementation for the whole app.
    var grade = ReelColorGrade()

    var sharpen: Double = 0      // 0 … 2   (CISharpenLuminance)
    var blur: Double = 0         // 0 … 24  px radius (CIGaussianBlur)
    var vignette: Double = 0     // 0 … 2   (CIVignette intensity)

    /// At most 90% may be trimmed off either axis, so a crop can never collapse the image.
    static let maxCropPerAxis: Double = 0.9

    // MARK: Codable — decodeIfPresent evolution, matching DesignElement/DesignFormat.
    //
    // Synthesized Codable would use `decode` for these non-optional fields, so a payload written
    // by ANY build with a different field set would throw — and because this struct is nested
    // inside DesignElement, that throw would take the whole element (and therefore the buyer's
    // document) down with it. Every field is optional-with-default on the way in instead, and the
    // grade falls back to neutral rather than propagating a decode error.

    private enum CodingKeys: String, CodingKey {
        case cropTop, cropLeading, cropBottom, cropTrailing
        case flipHorizontal, flipVertical, grade, sharpen, blur, vignette
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cropTop         = try c.decodeIfPresent(Double.self, forKey: .cropTop) ?? 0
        cropLeading     = try c.decodeIfPresent(Double.self, forKey: .cropLeading) ?? 0
        cropBottom      = try c.decodeIfPresent(Double.self, forKey: .cropBottom) ?? 0
        cropTrailing    = try c.decodeIfPresent(Double.self, forKey: .cropTrailing) ?? 0
        flipHorizontal  = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical    = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        grade           = (try? c.decode(ReelColorGrade.self, forKey: .grade)) ?? ReelColorGrade()
        sharpen         = try c.decodeIfPresent(Double.self, forKey: .sharpen) ?? 0
        blur            = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        vignette        = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        clamp()   // a hand-edited or corrupted document can never hand the renderer a wild value
    }

    /// True when this stack is a no-op. Callers MUST check it and fall back to the raw
    /// image path — that is what keeps untouched documents rendering identically.
    var isNeutral: Bool {
        cropTop == 0 && cropLeading == 0 && cropBottom == 0 && cropTrailing == 0 &&
        !flipHorizontal && !flipVertical &&
        grade.isNeutral && sharpen == 0 && blur == 0 && vignette == 0
    }

    var hasCrop: Bool { cropTop != 0 || cropLeading != 0 || cropBottom != 0 || cropTrailing != 0 }

    /// Stable identity for the render cache — two elements with equal edits share a rendered frame.
    var cacheToken: String {
        String(format: "c%.4f,%.4f,%.4f,%.4f|f%d%d|%@|s%.3f|b%.2f|v%.3f",
               cropTop, cropLeading, cropBottom, cropTrailing,
               flipHorizontal ? 1 : 0, flipVertical ? 1 : 0,
               grade.cacheToken, sharpen, blur, vignette)
    }

    /// Clamp every field into its legal range. Called after any inspector edit so a bad value
    /// can never reach the renderer (and never persists into the document).
    mutating func clamp() {
        cropTop      = min(max(cropTop, 0), Self.maxCropPerAxis)
        cropBottom   = min(max(cropBottom, 0), Self.maxCropPerAxis)
        cropLeading  = min(max(cropLeading, 0), Self.maxCropPerAxis)
        cropTrailing = min(max(cropTrailing, 0), Self.maxCropPerAxis)
        // Opposite edges must still leave 10% of the axis alive.
        let vertical = cropTop + cropBottom
        if vertical > Self.maxCropPerAxis {
            let scale = Self.maxCropPerAxis / vertical
            cropTop *= scale; cropBottom *= scale
        }
        let horizontal = cropLeading + cropTrailing
        if horizontal > Self.maxCropPerAxis {
            let scale = Self.maxCropPerAxis / horizontal
            cropLeading *= scale; cropTrailing *= scale
        }
        grade.exposure    = min(max(grade.exposure, -1), 1)
        grade.contrast    = min(max(grade.contrast, 0.6), 1.4)
        grade.saturation  = min(max(grade.saturation, 0), 2)
        grade.temperature = min(max(grade.temperature, -100), 100)
        grade.tint        = min(max(grade.tint, -100), 100)
        grade.vibrance    = min(max(grade.vibrance, -1), 1)
        sharpen  = min(max(sharpen, 0), 2)
        blur     = min(max(blur, 0), 24)
        vignette = min(max(vignette, 0), 2)
    }

    // MARK: crop presets

    /// Centre-crop the source to a target aspect (width/height), trimming only the long axis.
    /// `sourceAspect` is the image's own width/height.
    mutating func setCenterCrop(targetAspect: Double, sourceAspect: Double) {
        guard targetAspect > 0, sourceAspect > 0 else { return }
        cropTop = 0; cropBottom = 0; cropLeading = 0; cropTrailing = 0
        if sourceAspect > targetAspect {
            // Source is too wide — trim left/right.
            let keep = targetAspect / sourceAspect
            let trim = (1 - keep) / 2
            cropLeading = trim; cropTrailing = trim
        } else if sourceAspect < targetAspect {
            // Source is too tall — trim top/bottom.
            let keep = sourceAspect / targetAspect
            let trim = (1 - keep) / 2
            cropTop = trim; cropBottom = trim
        }
        clamp()
    }

    mutating func clearCrop() {
        cropTop = 0; cropLeading = 0; cropBottom = 0; cropTrailing = 0
    }
}

// MARK: - Renderer

/// Applies a `DesignPhotoEdit` to image bytes and returns a CGImage. The SAME function backs the
/// editor preview and the exporter — that is what keeps "what you see" equal to "what you export".
enum DesignPhotoRenderer {

    private static let context: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false,
                            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
    }()

    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    /// Render `data` through `edit`.
    /// - Parameter maxPixel: when set, the source is downscaled so its longest side is at most
    ///   this many pixels BEFORE filtering. The editor passes a screen-sized bound so dragging a
    ///   slider stays interactive on a 40-megapixel import; the exporter passes nil for full res.
    /// - Returns: the edited image, or nil if the bytes are unreadable. A neutral `edit` returns
    ///   the decoded source untouched.
    static func render(imageData data: Data, edit: DesignPhotoEdit, maxPixel: CGFloat? = nil) -> CGImage? {
        guard let source = ImageMagicEngine.cgImage(from: data) else { return nil }
        guard !edit.isNeutral else { return source }

        var ci = CIImage(cgImage: source)

        // 0 — optional downscale for interactive preview (before the expensive filters).
        if let maxPixel, maxPixel > 0 {
            let longest = max(ci.extent.width, ci.extent.height)
            if longest > maxPixel {
                let s = maxPixel / longest
                ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
            }
        }

        // 1 — crop. CoreImage is y-UP, so `cropTop` trims the HIGH-y edge.
        if edit.hasCrop {
            let e = ci.extent
            guard e.width > 0, e.height > 0 else { return nil }
            let x = e.minX + e.width * CGFloat(edit.cropLeading)
            let y = e.minY + e.height * CGFloat(edit.cropBottom)
            let w = e.width * CGFloat(1 - edit.cropLeading - edit.cropTrailing)
            let h = e.height * CGFloat(1 - edit.cropTop - edit.cropBottom)
            guard w >= 1, h >= 1 else { return nil }
            ci = ci.cropped(to: CGRect(x: x, y: y, width: w, height: h))
            // Re-origin so downstream filters and the final render see a 0-based extent.
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX,
                                                      y: -ci.extent.minY))
        }

        // 2 — flip about the image centre.
        if edit.flipHorizontal || edit.flipVertical {
            let e = ci.extent
            var t = CGAffineTransform(scaleX: edit.flipHorizontal ? -1 : 1,
                                      y: edit.flipVertical ? -1 : 1)
            t = t.concatenating(CGAffineTransform(translationX: edit.flipHorizontal ? e.width : 0,
                                                  y: edit.flipVertical ? e.height : 0))
            ci = ci.transformed(by: t)
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX,
                                                      y: -ci.extent.minY))
        }

        // 3 — colour grade (shared with the reel renderer).
        ci = edit.grade.apply(to: ci)

        // 4 — sharpen.
        if edit.sharpen > 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": edit.sharpen])
        }

        // 5 — blur. Clamp first so the edges don't go transparent, then restore the extent.
        if edit.blur > 0 {
            let keep = ci.extent
            ci = ci.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": edit.blur])
                .cropped(to: keep)
        }

        // 6 — vignette.
        if edit.vignette > 0 {
            ci = ci.applyingFilter("CIVignette", parameters: [
                "inputIntensity": edit.vignette,
                "inputRadius": 1.5,
            ])
        }

        let extent = ci.extent
        guard extent.width >= 1, extent.height >= 1, extent.isInfinite == false else { return nil }
        return context.createCGImage(ci, from: extent,
                                     format: .RGBA8,
                                     colorSpace: outputColorSpace)
    }
}

// MARK: - Preview cache

/// Keyed by element + byte count + edit token + preview bound, so dragging a LAYER never
/// re-renders, and dragging a SLIDER re-renders exactly once per value.
enum DesignPhotoCache {
    private static let cache: NSCache<NSString, CGImageBox> = {
        let c = NSCache<NSString, CGImageBox>()
        c.countLimit = 48
        return c
    }()

    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    static func image(for id: UUID, data: Data, edit: DesignPhotoEdit, maxPixel: CGFloat?) -> CGImage? {
        let key = "\(id.uuidString)|\(data.count)|\(edit.cacheToken)|\(Int(maxPixel ?? 0))" as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        guard let rendered = DesignPhotoRenderer.render(imageData: data, edit: edit, maxPixel: maxPixel) else {
            return nil
        }
        cache.setObject(CGImageBox(rendered), forKey: key)
        return rendered
    }

    static func purge() { cache.removeAllObjects() }
}
#endif // circuit-convert
