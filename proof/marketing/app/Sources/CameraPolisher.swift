#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — deterministic local finishing for footage captured in Reel Studio.
#if os(macOS)
import Foundation
import AppKit
import AVFoundation
import QuartzCore

enum MarketingCameraFraming: String, CaseIterable, Identifiable {
    case fillCrop
    case preserve

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fillCrop: return "Keep it readable"
        case .preserve: return "Show entire source"
        }
    }
    var detail: String {
        switch self {
        case .fillCrop: return "Default. Fills the reel so the subject stays large and readable; trims the outer edges."
        case .preserve: return "Keeps every edge. Wide footage will look smaller inside vertical or square reels."
        }
    }

    /// Pure framing geometry shared by the normal polish and the virtual-set renderer. Fill/crop is
    /// the presentation default so landscape footage does not collapse into an unreadable strip in
    /// a vertical reel. Full-source preservation remains an explicit choice when every edge matters.
    static func contentRect(sourceSize: CGSize, renderSize: CGSize,
                            framing: MarketingCameraFraming) -> CGRect {
        let sourceWidth = max(1, sourceSize.width)
        let sourceHeight = max(1, sourceSize.height)
        let widthRatio = renderSize.width / sourceWidth
        let heightRatio = renderSize.height / sourceHeight
        let scale = framing == .preserve ? min(widthRatio, heightRatio) : max(widthRatio, heightRatio)
        let fitted = CGSize(width: sourceWidth * scale, height: sourceHeight * scale)
        return CGRect(x: (renderSize.width - fitted.width) / 2,
                      y: (renderSize.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}

struct MarketingRecordingFinish {
    let format: ReelFormat
    let accentHex: UInt32
    let title: String
    let subtitle: String
    var sourceLabel = "ON CAMERA"
    var includeLowerThird = false
    var virtualBackground: MarketingVirtualBackground? = nil
    var framing: MarketingCameraFraming = .fillCrop
    /// Opt-in: transcribe the take on-device (Speech framework, nothing uploaded) and burn
    /// the timed caption lines into the polished output. Off by default — existing polish
    /// calls render byte-identically.
    var autoCaptions = false
    /// When auto captions run, also write a matching SubRip sidecar next to the finished
    /// .mp4 (same basename, .srt) for platforms that take caption files.
    var exportCaptionSidecar = false
    /// Internal hand-off: captions already transcribed for this take, so the virtual-set
    /// re-entry path never transcribes twice. Populated by the polisher, not by callers.
    var resolvedCaptions: [TimedCaption]? = nil

    var resolvedLowerThird: (title: String, subtitle: String)? {
        guard includeLowerThird else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty || !cleanSubtitle.isEmpty else { return nil }
        return (cleanTitle, cleanSubtitle)
    }
}

enum MarketingRecordingPolisher {
    enum PolishError: LocalizedError {
        case missingVideo, composition, exporter, export(String)
        var errorDescription: String? {
            switch self {
            case .missingVideo: return "The recording does not contain a video track."
            case .composition: return "The recording could not be assembled for finishing."
            case .exporter: return "The finished video exporter could not start."
            case .export(let reason): return "The finished video could not be exported: \(reason)"
            }
        }
    }

    static func polish(sourceURL: URL, finish: MarketingRecordingFinish, outputURL: URL,
                       completion: @escaping (Result<URL, Error>) -> Void) {
        // Auto-caption pre-pass: transcribe ONCE on the original take (before any virtual-set
        // re-encode) and re-enter with the resolved lines. Opt-in, and an honest failure —
        // the buyer asked for captions, so a clip that cannot be captioned fails with the
        // reason instead of silently exporting without them.
        if finish.autoCaptions && finish.resolvedCaptions == nil {
            SpeechCaptionEngine.transcribe(videoURL: sourceURL) { result in
                switch result {
                case .success(let captions):
                    var captioned = finish
                    captioned.resolvedCaptions = captions
                    polish(sourceURL: sourceURL, finish: captioned, outputURL: outputURL, completion: completion)
                case .failure(let error): completion(.failure(error))
                }
            }
            return
        }
        if let background = finish.virtualBackground {
            MarketingVirtualBackgroundVideoProcessor.process(sourceURL: sourceURL, background: background,
                                                               renderSize: finish.format.size,
                                                               framing: finish.framing) { result in
                switch result {
                case .success(let stagedURL):
                    // Copy-and-clear keeps every other finish option (captions included)
                    // flowing into the staged pass.
                    var stagedFinish = finish
                    stagedFinish.virtualBackground = nil
                    polish(sourceURL: stagedURL, finish: stagedFinish, outputURL: outputURL) { polished in
                        try? FileManager.default.removeItem(at: stagedURL)
                        completion(polished)
                    }
                case .failure(let error): completion(.failure(error))
                }
            }
            return
        }
        let source = AVURLAsset(url: sourceURL)
        guard let sourceVideo = source.tracks(withMediaType: .video).first else {
            completion(.failure(PolishError.missingVideo)); return
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(.failure(PolishError.composition)); return
        }
        do {
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: source.duration),
                                           of: sourceVideo, at: .zero)
            if let sourceAudio = source.tracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid) {
                try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: source.duration),
                                               of: sourceAudio, at: .zero)
            }
        } catch {
            completion(.failure(error)); return
        }

        let renderSize = finish.format.size
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: source.duration)
        instruction.backgroundColor = NSColor.black.cgColor
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(cameraTransform(for: sourceVideo, renderSize: renderSize,
                                                      framing: finish.framing), at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        let parentLayer = CALayer()
        parentLayer.frame = videoLayer.frame
        parentLayer.addSublayer(videoLayer)
        addBrandFinish(to: parentLayer, size: renderSize, finish: finish)
        if let captions = finish.resolvedCaptions, !captions.isEmpty {
            addTimedCaptions(captions, to: parentLayer, size: renderSize,
                             aboveLowerThird: finish.resolvedLowerThird != nil)
        }
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer
        )

        try? FileManager.default.removeItem(at: outputURL)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(PolishError.exporter)); return
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = videoComposition
        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                if exporter.status == .completed {
                    if finish.exportCaptionSidecar, let captions = finish.resolvedCaptions, !captions.isEmpty {
                        let sidecar = captionSidecarURL(for: outputURL)
                        do { try SpeechCaptionEngine.writeSRT(captions, to: sidecar) }
                        catch { blmCameraLog("caption sidecar write failed → \(error.localizedDescription)") }
                    }
                    completion(.success(outputURL))
                } else {
                    completion(.failure(PolishError.export(exporter.error?.localizedDescription ?? "unknown export error")))
                }
            }
        }
    }

    private static func cameraTransform(for track: AVAssetTrack, renderSize: CGSize,
                                        framing: MarketingCameraFraming) -> CGAffineTransform {
        let sourceRect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform).standardized
        let sourceSize = sourceRect.size
        let target = MarketingCameraFraming.contentRect(sourceSize: sourceSize, renderSize: renderSize,
                                                        framing: framing)
        let scale = target.width / max(1, sourceSize.width)
        var transform = track.preferredTransform
        transform = transform.concatenating(CGAffineTransform(translationX: -sourceRect.minX, y: -sourceRect.minY))
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(CGAffineTransform(translationX: target.minX, y: target.minY))
        return transform
    }

    private static func addBrandFinish(to parent: CALayer, size: CGSize, finish: MarketingRecordingFinish) {
        let accent = cgColor(finish.accentHex)
        let shade = CAGradientLayer()
        shade.frame = parent.bounds
        shade.colors = [
            NSColor.black.withAlphaComponent(0.22).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.78).cgColor
        ]
        shade.locations = [0, 0.52, 1]
        shade.startPoint = CGPoint(x: 0.5, y: 1)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        parent.addSublayer(shade)

        let border = CAShapeLayer()
        let inset = max(20, size.width * 0.025)
        border.path = CGPath(roundedRect: parent.bounds.insetBy(dx: inset, dy: inset),
                             cornerWidth: max(20, size.width * 0.028),
                             cornerHeight: max(20, size.width * 0.028), transform: nil)
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = accent.copy(alpha: 0.72)
        border.lineWidth = max(3, size.width * 0.004)
        parent.addSublayer(border)

        let cleanSourceLabel = finish.sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let brand = textLayer("BLACK LABEL  •  \(cleanSourceLabel.isEmpty ? "VIDEO" : cleanSourceLabel.uppercased())",
                              size: size.width * 0.026,
                              weight: .bold, color: accent, alignment: .left)
        brand.frame = CGRect(x: size.width * 0.075, y: size.height * 0.90,
                             width: size.width * 0.75, height: size.height * 0.045)
        parent.addSublayer(brand)

        if let lowerThird = finish.resolvedLowerThird {
            if !lowerThird.title.isEmpty {
                let title = textLayer(lowerThird.title, size: size.width * 0.070, weight: .heavy,
                                      color: NSColor.white.cgColor, alignment: .left)
                title.isWrapped = true
                title.frame = CGRect(x: size.width * 0.075, y: size.height * 0.105,
                                     width: size.width * 0.85, height: size.height * 0.14)
                parent.addSublayer(title)
            }
            if !lowerThird.subtitle.isEmpty {
                let subtitle = textLayer(lowerThird.subtitle, size: size.width * 0.032, weight: .semibold,
                                         color: NSColor.white.withAlphaComponent(0.88).cgColor, alignment: .left)
                subtitle.isWrapped = true
                subtitle.frame = CGRect(x: size.width * 0.075, y: size.height * 0.055,
                                        width: size.width * 0.85, height: size.height * 0.055)
                parent.addSublayer(subtitle)
            }

            let accentBar = CALayer()
            accentBar.backgroundColor = accent
            accentBar.cornerRadius = max(2, size.width * 0.004)
            accentBar.frame = CGRect(x: size.width * 0.075, y: size.height * 0.245,
                                     width: size.width * 0.13, height: max(5, size.height * 0.004))
            parent.addSublayer(accentBar)
        }
    }

    /// Where a polished output's caption sidecar lives (same basename, .srt).
    static func captionSidecarURL(for outputURL: URL) -> URL {
        outputURL.deletingPathExtension().appendingPathExtension("srt")
    }

    /// Burn timed caption lines into the finish. Each line is a centered white-on-scrim pill
    /// (the lower-third's white-on-shade language, sized between its subtitle and title) that
    /// appears exactly on its recognizer word timing via an export-timeline opacity window.
    private static func addTimedCaptions(_ captions: [TimedCaption], to parent: CALayer, size: CGSize,
                                         aboveLowerThird: Bool) {
        let fontSize = max(13, size.width * 0.034)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let maxTextWidth = size.width * 0.78
        let padX = fontSize * 0.85
        let padY = fontSize * 0.55
        // Sit above the lower-third block (accent bar tops out at 0.245 heights) when it is
        // shown; otherwise take the classic caption position in the bottom shade.
        let bottomY = size.height * (aboveLowerThird ? 0.285 : 0.09)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let measureAttrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]

        for caption in captions {
            let measured = (caption.text as NSString).boundingRect(
                with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: measureAttrs, context: nil)
            let textWidth = min(maxTextWidth, ceil(measured.width))
            let textHeight = ceil(measured.height)
            let pillWidth = textWidth + padX * 2
            let pillHeight = textHeight + padY * 2

            let pill = CALayer()
            pill.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
            pill.cornerRadius = min(pillHeight / 2, fontSize * 0.8)
            pill.frame = CGRect(x: (size.width - pillWidth) / 2, y: bottomY,
                                width: pillWidth, height: pillHeight)
            pill.opacity = 0

            let text = CATextLayer()
            text.string = NSAttributedString(string: caption.text, attributes: [
                .font: font,
                .foregroundColor: NSColor.white.cgColor,
                .paragraphStyle: paragraph
            ])
            text.isWrapped = true
            text.alignmentMode = .center
            text.contentsScale = 2
            text.frame = CGRect(x: padX, y: padY, width: textWidth, height: textHeight)
            pill.addSublayer(text)

            pill.add(captionTiming(start: caption.start, duration: max(0.2, caption.duration)),
                     forKey: "captionTiming")
            parent.addSublayer(pill)
        }
    }

    /// Export-timeline visibility window with a short fade at each edge. Inside the export
    /// animation tool a beginTime of literal 0 means "now", so time zero must be expressed
    /// as AVCoreAnimationBeginTimeAtZero.
    private static func captionTiming(start: TimeInterval, duration: TimeInterval) -> CAKeyframeAnimation {
        let fade = min(0.12, duration * 0.3)
        let edge = fade / duration
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0] as [NSNumber]
        animation.keyTimes = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        animation.beginTime = start <= 0 ? AVCoreAnimationBeginTimeAtZero : start
        animation.duration = duration
        animation.isRemovedOnCompletion = false
        return animation
    }

    private static func textLayer(_ string: String, size: CGFloat, weight: NSFont.Weight,
                                  color: CGColor, alignment: CATextLayerAlignmentMode) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = string
        layer.font = NSFont.systemFont(ofSize: size, weight: weight)
        layer.fontSize = size
        layer.foregroundColor = color
        layer.alignmentMode = alignment
        layer.contentsScale = 2
        layer.truncationMode = .end
        return layer
    }

    private static func cgColor(_ hex: UInt32) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
#endif // circuit-convert
