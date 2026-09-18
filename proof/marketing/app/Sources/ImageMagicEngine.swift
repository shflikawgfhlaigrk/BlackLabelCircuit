// Black Label Marketing — on-device image magic for the Design Canvas.
//
// Three capabilities, ALL local Apple frameworks (no paid API, §5.5):
//   (a) Background removal for any subject via Vision's foreground instance mask
//       (VNGenerateForegroundInstanceMaskRequest, macOS 14+/iOS 17+). Honest error when the
//       OS is too old or Vision finds no subject — never a silently unchanged image.
//   (b) AI image generation via Apple Intelligence Image Playground (ImageCreator). Guarded by
//       BOTH #if canImport(ImagePlayground) and #available; when unsupported the caller gets an
//       honest "unavailable on this Mac" error — NO fabricated fallback imagery (§5.1).
//   (c) Local CoreImage filter looks (vivid / warm / cool / mono) built from
//       CIColorControls / CIColorMatrix / CIPhotoEffectMono — self-contained, no ReelEngine
//       internals imported.
import Foundation
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
#if canImport(CoreImage) && !CIRCUIT_WINDOWS_SIM
import CoreImage
#endif
#if canImport(ImageIO) && !CIRCUIT_WINDOWS_SIM
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif
#if canImport(Vision) && !CIRCUIT_WINDOWS_SIM
import Vision
#endif
#if canImport(ImagePlayground)
import ImagePlayground
#endif

// MARK: - Errors (honest, buyer-facing)

enum ImageMagicError: LocalizedError {
    case unreadableImage
    case backgroundRemovalUnavailable
    case noSubjectFound
    case visionFailed(String)
    case emptyPrompt
    case generationUnavailable
    case generationFailed(String)
    case filterFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "That image could not be read."
        case .backgroundRemovalUnavailable:
            return "Background removal needs macOS 14 or later."
        case .noSubjectFound:
            return "No subject was found in this image, so there is nothing to cut out."
        case .visionFailed(let reason):
            return "Background removal failed: \(reason)"
        case .emptyPrompt:
            return "Type a prompt first."
        case .generationUnavailable:
            return "Apple Intelligence image generation unavailable on this Mac."
        case .generationFailed(let reason):
            return "Image generation failed: \(reason)"
        case .filterFailed:
            return "The image filter could not be applied."
        }
    }
}

// MARK: - Engine

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum ImageMagicEngine {
    /// One shared CIContext — creating one per filter call is the classic CoreImage perf trap.
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: (a) Background removal — Vision foreground instance mask

    /// True when this OS can run the foreground-instance mask request at all.
    static var backgroundRemovalAvailable: Bool {
        if #available(macOS 14.0, iOS 17.0, *) { return true }
        return false
    }

    /// Cut the subject out of the buyer's image. Returns a CGImage with alpha (the cutout).
    /// Throws an honest error when the OS is too old or Vision finds no subject.
    static func removeBackground(from image: CGImage) throws -> CGImage {
        guard #available(macOS 14.0, iOS 17.0, *) else { throw ImageMagicError.backgroundRemovalUnavailable }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ImageMagicError.visionFailed(error.localizedDescription)
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ImageMagicError.noSubjectFound
        }
        let masked: CVPixelBuffer
        do {
            masked = try observation.generateMaskedImage(ofInstances: observation.allInstances,
                                                         from: handler,
                                                         croppedToInstancesExtent: false)
        } catch {
            throw ImageMagicError.visionFailed(error.localizedDescription)
        }
        let ci = CIImage(cvPixelBuffer: masked)
        guard let out = ciContext.createCGImage(ci, from: ci.extent) else {
            throw ImageMagicError.filterFailed
        }
        return out
    }

    /// Data-in/data-out convenience for canvas image elements (PNG out so alpha survives).
    static func removeBackground(fromImageData data: Data) throws -> Data {
        guard let cg = cgImage(from: data) else { throw ImageMagicError.unreadableImage }
        let cutout = try removeBackground(from: cg)
        guard let png = pngData(cutout) else { throw ImageMagicError.filterFailed }
        return png
    }

    // MARK: (b) AI image generation — Image Playground / Apple Intelligence

    enum GenerationStyle: String, CaseIterable, Identifiable {
        case animation = "Animation", illustration = "Illustration", sketch = "Sketch"
        var id: String { rawValue }
    }

    /// True when the ImagePlayground API exists on this build/OS. The device may STILL decline at
    /// generation time (Apple Intelligence off/unsupported) — that path throws
    /// `.generationUnavailable`, surfaced honestly in the UI.
    static var imageGenerationAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(macOS 15.4, iOS 18.4, *) { return true }
        return false
        #else
        return false
        #endif
    }

    /// Generate one image from the buyer's own prompt, fully on-device via Apple Intelligence.
    /// Throws `.generationUnavailable` (honest empty state) whenever the capability is absent —
    /// never substitutes fabricated fallback imagery.
    static func generateImage(prompt: String, style: GenerationStyle) async throws -> CGImage {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImageMagicError.emptyPrompt }
        #if canImport(ImagePlayground)
        guard #available(macOS 15.4, iOS 18.4, *) else { throw ImageMagicError.generationUnavailable }
        do {
            let creator = try await ImageCreator()
            let wanted: ImagePlaygroundStyle
            switch style {
            case .animation:    wanted = .animation
            case .illustration: wanted = .illustration
            case .sketch:       wanted = .sketch
            }
            // Only styles the device actually offers; fall back to its first available style.
            let available = creator.availableStyles
            let chosen = available.first { $0.id == wanted.id } ?? available.first ?? wanted
            let images = creator.images(for: [.text(trimmed)], style: chosen, limit: 1)
            for try await created in images {
                return created.cgImage
            }
            throw ImageMagicError.generationFailed("No image was produced.")
        } catch ImageCreator.Error.notSupported {
            throw ImageMagicError.generationUnavailable
        } catch let error as ImageMagicError {
            throw error
        } catch {
            throw ImageMagicError.generationFailed(error.localizedDescription)
        }
        #else
        throw ImageMagicError.generationUnavailable
        #endif
    }

    // MARK: (c) Filter looks — local CoreImage only

    enum Look: String, CaseIterable, Identifiable {
        case vivid = "Vivid", warm = "Warm", cool = "Cool", mono = "Mono"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .vivid: return "sun.max.fill"
            case .warm: return "flame"
            case .cool: return "snowflake"
            case .mono: return "circle.lefthalf.filled"
            }
        }
    }

    static func apply(_ look: Look, to image: CGImage) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let output: CIImage
        switch look {
        case .vivid:
            output = input.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.32,
                kCIInputContrastKey: 1.06,
                kCIInputBrightnessKey: 0.015,
            ])
        case .warm:
            output = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.08, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1.02, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.90, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        case .cool:
            output = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.92, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1.08, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        case .mono:
            output = input.applyingFilter("CIPhotoEffectMono")
        }
        guard let out = ciContext.createCGImage(output, from: input.extent) else {
            throw ImageMagicError.filterFailed
        }
        return out
    }

    /// Data-in/data-out convenience for canvas image elements (PNG so alpha survives).
    static func apply(_ look: Look, toImageData data: Data) throws -> Data {
        guard let cg = cgImage(from: data) else { throw ImageMagicError.unreadableImage }
        let filtered = try apply(look, to: cg)
        guard let png = pngData(filtered) else { throw ImageMagicError.filterFailed }
        return png
    }

    // MARK: shared codecs (ImageIO — identical on macOS and iOS)

    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Pixel dimensions straight from the codec (never NSImage points).
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let cg = cgImage(from: data) else { return nil }
        return (cg.width, cg.height)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
#endif // circuit-convert
