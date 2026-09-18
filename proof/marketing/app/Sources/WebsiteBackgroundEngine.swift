#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — local person segmentation + virtual background video rendering.
#if os(macOS)
import Foundation
import AppKit
import AVFoundation
import CoreImage
import Vision

enum MarketingPageFraming: String, CaseIterable, Identifiable {
    case fullPage
    case fillCrop

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fullPage: return "Show full page"
        case .fillCrop: return "Fill canvas (crop)"
        }
    }
    var detail: String {
        switch self {
        case .fullPage:
            return "Shows the complete captured page. A soft copy fills the rest of the reel."
        case .fillCrop:
            return "Fills the canvas by cropping the page around its center."
        }
    }
}

struct MarketingVirtualBackground {
    var image: CGImage
    var pageFraming: MarketingPageFraming = .fullPage
    var zoom: CGFloat = 1
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var blur: CGFloat = 0
    var dim: CGFloat = 0.12
    var edgeSoftness: CGFloat = 4
}

/// The writer callback may be invoked again after `markAsFinished`. Claiming the terminal path is
/// atomic so a second callback cannot ask an already-completed AVAssetReader for another sample —
/// AVFoundation raises an Objective-C exception for that misuse and would otherwise abort the app.
final class MarketingRenderDrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func claimFinish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

enum MarketingVirtualBackgroundRenderer {
    static let context = CIContext(options: [.cacheIntermediates: true])
    static let fullPageInset: CGFloat = 28

    /// Returns the camera subject over the customized website plate. If Vision cannot find a
    /// person in a frame, the original frame is preserved rather than making the speaker vanish.
    static func composite(frame: CIImage, background: MarketingVirtualBackground) -> CIImage {
        let extent = frame.extent.integral
        guard extent.width > 0, extent.height > 0 else { return frame }
        let plate = preparedPlate(background, extent: extent)
        let safeFallback = frame.composited(over: plate).cropped(to: extent)
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(ciImage: frame, orientation: .up).perform([request])
            guard let observation = request.results?.first else { return safeFallback }
            var mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
            let maskExtent = mask.extent
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: extent.width / max(1, maskExtent.width),
                y: extent.height / max(1, maskExtent.height)
            ))
            mask = mask.transformed(by: CGAffineTransform(translationX: extent.minX - mask.extent.minX,
                                                          y: extent.minY - mask.extent.minY))
            if background.edgeSoftness > 0 {
                mask = mask.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: background.edgeSoftness])
                    .cropped(to: extent)
            }
            return frame.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: plate,
                kCIInputMaskImageKey: mask
            ]).cropped(to: extent)
        } catch {
            return safeFallback
        }
    }

    static func fullPageRect(sourceSize: CGSize, extent: CGRect,
                             inset: CGFloat = fullPageInset) -> CGRect {
        let safeInset = min(max(0, inset), min(extent.width, extent.height) / 2)
        let available = extent.insetBy(dx: safeInset, dy: safeInset)
        let scale = min(available.width / max(1, sourceSize.width),
                        available.height / max(1, sourceSize.height))
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: extent.midX - size.width / 2,
                      y: extent.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func ambientFillRect(sourceSize: CGSize, extent: CGRect, zoom: CGFloat,
                                offsetX: CGFloat, offsetY: CGFloat) -> CGRect {
        let scale = max(extent.width / max(1, sourceSize.width),
                        extent.height / max(1, sourceSize.height)) * max(1, zoom)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: extent.midX - size.width / 2 + offsetX * extent.width * 0.5,
                      y: extent.midY - size.height / 2 + offsetY * extent.height * 0.5,
                      width: size.width, height: size.height)
    }

    static func preparedPlate(_ background: MarketingVirtualBackground, extent: CGRect) -> CIImage {
        let source = CIImage(cgImage: background.image)
        let fillRect = ambientFillRect(sourceSize: source.extent.size, extent: extent,
                                       zoom: background.zoom, offsetX: background.offsetX,
                                       offsetY: background.offsetY)
        var plate: CIImage
        switch background.pageFraming {
        case .fullPage:
            var ambient = positioned(source, in: fillRect)
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(28, background.blur)])
                .cropped(to: extent)
            let ambientShade = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.38))
                .cropped(to: extent)
            ambient = ambientShade.composited(over: ambient)

            var page = positioned(source, in: fullPageRect(sourceSize: source.extent.size, extent: extent))
            if background.blur > 0 {
                let pageExtent = page.extent
                page = page.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: background.blur])
                    .cropped(to: pageExtent)
            }
            plate = page.composited(over: ambient).cropped(to: extent)
        case .fillCrop:
            plate = positioned(source, in: fillRect)
            if background.blur > 0 {
                plate = plate.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: background.blur])
            }
            plate = plate.cropped(to: extent)
        }
        if background.dim > 0 {
            let shade = CIImage(color: CIColor(red: 0, green: 0, blue: 0,
                                               alpha: min(0.75, max(0, background.dim))))
                .cropped(to: extent)
            plate = shade.composited(over: plate)
        }
        return plate
    }

    private static func positioned(_ image: CIImage, in rect: CGRect) -> CIImage {
        let scale = rect.width / max(1, image.extent.width)
        var result = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        result = result.transformed(by: CGAffineTransform(translationX: rect.minX - result.extent.minX,
                                                          y: rect.minY - result.extent.minY))
        return result
    }
}

enum MarketingVirtualBackgroundVideoProcessor {
    enum ProcessorError: LocalizedError {
        case missingVideo, reader, writer, pixelBuffer, export(String)
        var errorDescription: String? {
            switch self {
            case .missingVideo: return "The camera take has no video track."
            case .reader: return "The virtual-set reader could not start."
            case .writer: return "The virtual-set video writer could not start."
            case .pixelBuffer: return "The virtual-set frame buffer could not be created."
            case .export(let reason): return "The virtual-set render failed: \(reason)"
            }
        }
    }

    static func process(sourceURL: URL, background: MarketingVirtualBackground, renderSize: CGSize,
                        framing: MarketingCameraFraming = .preserve,
                        completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let source = AVURLAsset(url: sourceURL)
                guard let track = source.tracks(withMediaType: .video).first else { throw ProcessorError.missingVideo }
                let videoOnly = FileManager.default.temporaryDirectory
                    .appendingPathComponent("blm-virtual-video-\(UUID().uuidString).mp4")
                try? FileManager.default.removeItem(at: videoOnly)
                let reader = try AVAssetReader(asset: source)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw ProcessorError.reader }
                reader.add(output)

                let writer = try AVAssetWriter(outputURL: videoOnly, fileType: .mp4)
                let width = max(2, Int(renderSize.width.rounded()))
                let height = max(2, Int(renderSize.height.rounded()))
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000]
                ])
                input.expectsMediaDataInRealTime = false
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ])
                guard writer.canAdd(input) else { throw ProcessorError.writer }
                writer.add(input)
                guard writer.startWriting(), reader.startReading() else { throw ProcessorError.writer }
                writer.startSession(atSourceTime: .zero)

                let queue = DispatchQueue(label: "com.blacklabel.marketing.virtual-background", qos: .userInitiated)
                let drainGate = MarketingRenderDrainGate()
                let finishDrain = {
                    guard drainGate.claimFinish() else { return }
                    input.markAsFinished()
                    if reader.status == .failed || reader.status == .cancelled {
                        writer.cancelWriting()
                        let reason = reader.error?.localizedDescription ?? "reader stopped"
                        DispatchQueue.main.async { completion(.failure(ProcessorError.export(reason))) }
                        return
                    }
                    writer.finishWriting {
                        if writer.status == .completed {
                            mergeOriginalAudio(videoURL: videoOnly, sourceURL: sourceURL) { result in
                                try? FileManager.default.removeItem(at: videoOnly)
                                DispatchQueue.main.async { completion(result) }
                            }
                        } else {
                            let reason = writer.error?.localizedDescription ?? "writer stopped"
                            DispatchQueue.main.async { completion(.failure(ProcessorError.export(reason))) }
                        }
                    }
                }
                input.requestMediaDataWhenReady(on: queue) {
                    guard !drainGate.isFinished else { return }
                    while input.isReadyForMoreMediaData && !drainGate.isFinished {
                        guard reader.status == .reading else {
                            finishDrain()
                            return
                        }
                        guard let sample = output.copyNextSampleBuffer() else {
                            finishDrain()
                            return
                        }
                        autoreleasepool {
                            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample),
                                  let pool = adaptor.pixelBufferPool else { return }
                            var destination: CVPixelBuffer?
                            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
                                  let destination else { return }
                            let framed = fittedFrame(CIImage(cvPixelBuffer: sourceBuffer), track: track,
                                                     renderSize: renderSize, framing: framing)
                            let composited = MarketingVirtualBackgroundRenderer.composite(frame: framed,
                                                                                           background: background)
                            MarketingVirtualBackgroundRenderer.context.render(composited, to: destination,
                                                                               bounds: CGRect(origin: .zero, size: renderSize),
                                                                               colorSpace: CGColorSpaceCreateDeviceRGB())
                            _ = adaptor.append(destination, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sample))
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func fittedFrame(_ image: CIImage, track: AVAssetTrack, renderSize: CGSize,
                                    framing: MarketingCameraFraming) -> CIImage {
        var oriented = image.transformed(by: track.preferredTransform)
        oriented = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX,
                                                               y: -oriented.extent.minY))
        return canvasAlignedFrame(oriented, renderSize: renderSize, framing: framing)
    }

    /// Places an already-oriented camera frame on the reel canvas and returns it cropped to EXACTLY
    /// that canvas.
    ///
    /// The crop is the contract, not a tidy-up. Fill/crop framing scales landscape footage wider
    /// than the reel, and `composited(over:)` returns the UNION of both extents — so before this,
    /// a 16:9 take in a square reel produced an extent of (-420, 0, 1920, 1080) instead of
    /// (0, 0, 1080, 1080). `composite()` derives the website plate's layout from that extent, so
    /// the plate was sized to the camera's overflow and only its middle slice reached the writer:
    /// the page came out cropped regardless of the shape it was captured at.
    static func canvasAlignedFrame(_ oriented: CIImage, renderSize: CGSize,
                                   framing: MarketingCameraFraming) -> CIImage {
        let target = MarketingCameraFraming.contentRect(sourceSize: oriented.extent.size,
                                                        renderSize: renderSize, framing: framing)
        let scale = target.width / max(1, oriented.extent.width)
        var scaled = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        scaled = scaled.transformed(by: CGAffineTransform(translationX: target.minX - scaled.extent.minX,
                                                          y: target.minY - scaled.extent.minY))
        let canvas = CGRect(origin: .zero, size: renderSize)
        return scaled.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: canvas)).cropped(to: canvas)
    }

    private static func mergeOriginalAudio(videoURL: URL, sourceURL: URL,
                                           completion: @escaping (Result<URL, Error>) -> Void) {
        let videoAsset = AVURLAsset(url: videoURL)
        let original = AVURLAsset(url: sourceURL)
        guard let video = videoAsset.tracks(withMediaType: .video).first else {
            completion(.failure(ProcessorError.missingVideo)); return
        }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(.failure(ProcessorError.writer)); return
        }
        do {
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoAsset.duration), of: video, at: .zero)
            if let audio = original.tracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid) {
                try audioTrack.insertTimeRange(CMTimeRange(start: .zero,
                                                           duration: CMTimeMinimum(videoAsset.duration, original.duration)),
                                               of: audio, at: .zero)
            }
        } catch { completion(.failure(error)); return }
        let merged = FileManager.default.temporaryDirectory
            .appendingPathComponent("blm-virtual-merged-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: merged)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(ProcessorError.writer)); return
        }
        exporter.outputURL = merged; exporter.outputFileType = .mp4; exporter.shouldOptimizeForNetworkUse = true
        exporter.exportAsynchronously {
            if exporter.status == .completed { completion(.success(merged)) }
            else { completion(.failure(ProcessorError.export(exporter.error?.localizedDescription ?? "audio merge stopped"))) }
        }
    }
}
#endif
#endif // circuit-convert
