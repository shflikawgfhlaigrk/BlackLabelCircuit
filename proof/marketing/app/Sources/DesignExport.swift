#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — pixel-exact Design Canvas export.
//
// Renders a DesignDocument into a CGBitmapContext at EXACTLY the document's pixel size (never the
// on-screen window resolution), so an IG Post document exports a true 1080×1080 PNG. Text is laid
// out with CoreText (same wrapping rules at any scale), images draw aspect-fill exactly like the
// editor preview, rotation/opacity/z-order all match the canvas.
//
// "Resize for all formats" re-lays a document into every preset with a proportional
// scale-and-center transform (fonts, strokes and corner radii scale with it) and writes one file
// per format to a buyer-chosen folder (NSOpenPanel, macOS).
import Foundation
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
#if canImport(CoreText) && !CIRCUIT_WINDOWS_SIM
import CoreText
#endif
#if canImport(ImageIO) && !CIRCUIT_WINDOWS_SIM
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif
#if os(macOS)
import AppKit
#endif

enum DesignExportError: LocalizedError {
    case renderFailed
    case encodeFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderFailed: return "The design could not be rendered."
        case .encodeFailed: return "The rendered image could not be encoded."
        case .writeFailed(let reason): return "The export could not be written: \(reason)"
        }
    }
}

enum DesignExport {

    // MARK: - Render (CGContext, exact pixels)

    /// Render the document at `scale`× its pixel size (1 = exact export pixels; small values make
    /// fast thumbnails). Top-left-origin document coordinates are mapped directly into the bitmap.
    static func render(_ doc: DesignDocument, scale: CGFloat = 1) -> CGImage? {
        let w = max(1, Int((CGFloat(doc.format.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(doc.format.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // Flip into top-left-origin, y-down document space so element frames draw directly.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)

        if !doc.background.transparent {
            ctx.setFillColor(cgColor(doc.background.colorHex))
            ctx.fill(CGRect(origin: .zero, size: doc.pixelSize))
        }
        for element in doc.sortedElements {
            draw(element, in: ctx)
        }
        return ctx.makeImage()
    }

    private static func draw(_ el: DesignElement, in ctx: CGContext) {
        guard el.frame.width > 0, el.frame.height > 0 else { return }
        ctx.saveGState()
        ctx.setAlpha(CGFloat(max(0, min(1, el.opacity))))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // so alpha applies to fill+stroke as one
        // Rotate about the element center. In this flipped (y-down) space a positive angle appears
        // clockwise — matching SwiftUI's rotationEffect in the editor.
        let center = CGPoint(x: el.frame.midX, y: el.frame.midY)
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: CGFloat(el.rotation) * .pi / 180)
        ctx.translateBy(x: -center.x, y: -center.y)

        switch el.kind {
        case .shape:        drawShape(el, in: ctx)
        case .image, .logo: drawImage(el, in: ctx)
        case .text:         drawText(el, in: ctx)
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawShape(_ el: DesignElement, in ctx: CGContext) {
        let rect = el.frame
        let path: CGPath
        switch el.shape {
        case .rectangle:
            path = CGPath(rect: rect, transform: nil)
        case .rounded:
            let r = min(CGFloat(el.cornerRadius), min(rect.width, rect.height) / 2)
            path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .ellipse:
            path = CGPath(ellipseIn: rect, transform: nil)
        case .line:
            // A line is a horizontal bar centered in its frame; thickness = stroke width when set,
            // else the frame height. Same rule as the editor preview.
            let t = max(1, min(rect.height, el.strokeWidth > 0 ? CGFloat(el.strokeWidth) : rect.height))
            let bar = CGRect(x: rect.minX, y: rect.midY - t / 2, width: rect.width, height: t)
            path = CGPath(roundedRect: bar, cornerWidth: t / 2, cornerHeight: t / 2, transform: nil)
        }
        if el.fillEnabled {
            ctx.addPath(path)
            ctx.setFillColor(cgColor(el.fillHex))
            ctx.fillPath()
        }
        if el.strokeWidth > 0, el.shape != .line {
            ctx.addPath(path)
            ctx.setStrokeColor(cgColor(el.strokeHex))
            ctx.setLineWidth(CGFloat(el.strokeWidth))
            ctx.strokePath()
        }
    }

    private static func drawImage(_ el: DesignElement, in ctx: CGContext) {
        guard let data = el.imageData else { return }
        // Full-resolution render of the layer's non-destructive edits (crop / flip / grade /
        // sharpen / blur / vignette). A neutral stack hands back the decoded source untouched, so
        // an unedited layer exports through the identical path it did before photo editing existed.
        // If an edit somehow yields nothing renderable we fall back to the buyer's original bytes
        // rather than silently dropping the layer.
        guard let image = DesignPhotoRenderer.render(imageData: data, edit: el.photo, maxPixel: nil)
                ?? ImageMagicEngine.cgImage(from: data) else { return }
        let rect = el.frame
        ctx.saveGState()
        // Corner-radius clip, exactly like the editor's clipShape.
        let r = min(CGFloat(el.cornerRadius), min(rect.width, rect.height) / 2)
        if r > 0 {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        } else {
            ctx.addPath(CGPath(rect: rect, transform: nil))
        }
        ctx.clip()
        // Aspect-FILL inside the frame (matches .scaledToFill().clipped() in the editor).
        let iw = CGFloat(max(1, image.width)), ih = CGFloat(max(1, image.height))
        let s = max(rect.width / iw, rect.height / ih)
        let drawSize = CGSize(width: iw * s, height: ih * s)
        let drawRect = CGRect(x: rect.midX - drawSize.width / 2,
                              y: rect.midY - drawSize.height / 2,
                              width: drawSize.width, height: drawSize.height)
        // CGContext.draw expects y-up space; flip locally so the image renders upright.
        ctx.translateBy(x: drawRect.minX, y: drawRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: drawRect.size))
        ctx.restoreGState()
    }

    private static func drawText(_ el: DesignElement, in ctx: CGContext) {
        let string = el.text
        guard !string.isEmpty else { return }
        let rect = el.frame
        let font = ctFont(family: el.fontFamily, size: CGFloat(el.fontSize), weight: el.fontWeight)

        var ctAlignment: CTTextAlignment
        switch el.alignment {
        case .leading: ctAlignment = .left
        case .center: ctAlignment = .center
        case .trailing: ctAlignment = .right
        }
        let paragraph = withUnsafeBytes(of: &ctAlignment) { raw -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment,
                                                  valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: raw.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(el.textColorHex),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let fullRange = CFRange(location: 0, length: attributed.length)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, fullRange, nil,
            CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)

        ctx.saveGState()
        // CoreText draws y-up from the top of its path rect; flip locally, then shift the path so
        // the text BLOCK is vertically centered in the element frame (matches the editor).
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let yOffset = (fitted.height - rect.height) / 2   // shifts the path top down by the slack/2
        let path = CGPath(rect: CGRect(x: 0, y: yOffset, width: rect.width, height: rect.height),
                          transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, fullRange, path, nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    /// CoreText font for a family name (or the system face when empty) at an exact pixel size.
    static func ctFont(family: String, size: CGFloat, weight: DesignFontWeight) -> CTFont {
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight.ctWeight]
        var attrs: [CFString: Any] = [kCTFontTraitsAttribute: traits]
        let trimmed = family.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { attrs[kCTFontFamilyNameAttribute] = trimmed }
        let descriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static func cgColor(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    // MARK: - Encode

    static func pngData(_ image: CGImage) -> Data? {
        encode(image, type: .png, properties: nil)
    }

    /// JPEG (no alpha — a transparent background flattens onto black; export PNG to keep alpha).
    static func jpegData(_ image: CGImage, quality: CGFloat = 0.92) -> Data? {
        encode(image, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]?) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Render + encode a document at its exact pixel size.
    static func imageData(_ doc: DesignDocument, asJPEG: Bool) throws -> Data {
        guard let image = render(doc) else { throw DesignExportError.renderFailed }
        guard let data = asJPEG ? jpegData(image) : pngData(image) else { throw DesignExportError.encodeFailed }
        return data
    }

    // MARK: - Resize for all formats (proportional scale-and-center re-layout)

    /// Re-lay a document into another format: every element scales by the minimum axis ratio
    /// (fonts, strokes, corner radii included) and the whole composition is centered in the new
    /// canvas. Pure — returns a new document, the original is untouched.
    static func relayout(_ doc: DesignDocument, to format: DesignFormat) -> DesignDocument {
        guard format != doc.format, doc.format.width > 0, doc.format.height > 0 else {
            var same = doc; same.format = format; return same
        }
        let sx = CGFloat(format.width) / CGFloat(doc.format.width)
        let sy = CGFloat(format.height) / CGFloat(doc.format.height)
        let s = min(sx, sy)
        let dx = (CGFloat(format.width) - CGFloat(doc.format.width) * s) / 2
        let dy = (CGFloat(format.height) - CGFloat(doc.format.height) * s) / 2
        var out = doc
        out.format = format
        out.elements = doc.elements.map { el in
            var e = el
            e.frame = CGRect(x: el.frame.minX * s + dx,
                             y: el.frame.minY * s + dy,
                             width: el.frame.width * s,
                             height: el.frame.height * s)
            e.fontSize *= Double(s)
            e.strokeWidth *= Double(s)
            e.cornerRadius *= Double(s)
            return e
        }
        return out
    }

    /// Render the document into EVERY preset format and write one file per format into `folder`.
    /// Returns the written URLs (in preset order).
    @discardableResult
    static func exportAllFormats(_ doc: DesignDocument, to folder: URL, asJPEG: Bool = false) throws -> [URL] {
        var written: [URL] = []
        let base = safeFileName(doc.name)
        for format in DesignFormat.presets {
            let variant = relayout(doc, to: format)
            let data = try imageData(variant, asJPEG: asJPEG)
            let url = folder.appendingPathComponent("\(base)-\(format.fileSuffix).\(asJPEG ? "jpg" : "png")")
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw DesignExportError.writeFailed(error.localizedDescription)
            }
            written.append(url)
        }
        return written
    }

    static func safeFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = trimmed.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-").lowercased()
        return collapsed.isEmpty ? "design" : collapsed
    }

    #if os(macOS)
    /// One-click multi-export: buyer picks a folder, we write every preset. Returns the written
    /// URLs, or nil when the buyer cancelled the panel.
    @MainActor
    static func chooseFolderAndExportAll(_ doc: DesignDocument, asJPEG: Bool = false) throws -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for all formats"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        return try exportAllFormats(doc, to: folder, asJPEG: asJPEG)
    }
    #endif
}
#endif // circuit-convert
