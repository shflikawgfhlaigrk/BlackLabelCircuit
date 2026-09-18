#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — reference-driven reel ingestion and deterministic local rendering.
// Accepts a local movie, a direct media URL, an Instagram reel URL, or an Instagram CDN poster
// URL carrying ig_cache_key. The reference audio remains the soundtrack; buyer-supplied websites,
// images, and installed-app marks become the visual sequence.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import CoreText

struct ReferenceReelAsset: Identifiable {
    enum Kind: String { case website = "Website", appIcon = "App", image = "Image", textCard = "Text card" }
    let id = UUID()
    var name: String
    var subtitle: String
    var restriction: String
    let kind: Kind
    let image: CGImage?

    init(name: String, kind: Kind, image: CGImage, subtitle: String = "", restriction: String = "") {
        self.name = name
        self.subtitle = subtitle
        self.restriction = restriction
        self.kind = kind
        self.image = image
    }

    init(titleCard name: String, subtitle: String = "") {
        self.name = name
        self.subtitle = subtitle
        self.restriction = ""
        self.kind = .textCard
        self.image = nil
    }
}

struct ReferenceReelRenderOptions {
    var introURL: URL? = nil
    var secondsPerVisual: Double = 1.5
    var endCardSeconds: Double = 4.0
    var extendToShowEverything = true
    var loopSoundtrack = true
    var fitToViralPacing = false
}

enum ReferenceReelError: LocalizedError {
    case invalidURL
    case unsupportedReference
    case instagramCode
    case instagramVideo
    case download(String)
    case noVisuals
    case writer(String)
    case audioMux

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid reference or website URL."
        case .unsupportedReference: return "Use a local movie, direct movie URL, Instagram reel URL, or Instagram CDN poster URL."
        case .instagramCode: return "The Instagram reel code could not be recovered from that link."
        case .instagramVideo: return "Instagram did not expose a playable reference movie for that link."
        case .download(let reason): return "The reference could not be downloaded: \(reason)"
        case .noVisuals: return "Add at least one website capture, image, or app mark."
        case .writer(let reason): return "The reference-style reel could not be rendered: \(reason)"
        case .audioMux: return "The reference soundtrack could not be attached to the finished reel."
        }
    }
}

enum InstagramReferenceResolver {
    private static let shortcodeAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func shortcode(from url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        if let marker = components.firstIndex(where: { $0 == "reel" || $0 == "p" }), marker + 1 < components.count {
            return components[marker + 1]
        }
        guard let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = parsed.queryItems?.first(where: { $0.name == "ig_cache_key" })?.value,
              let base64 = encoded.split(separator: ".").first,
              let data = Data(base64Encoded: String(base64)),
              let mediaID = String(data: data, encoding: .utf8).flatMap(UInt64.init) else { return nil }
        return shortcode(mediaID: mediaID)
    }

    static func shortcode(mediaID: UInt64) -> String {
        if mediaID == 0 { return String(shortcodeAlphabet[0]) }
        var value = mediaID
        var output = ""
        while value > 0 {
            output.insert(shortcodeAlphabet[Int(value % 64)], at: output.startIndex)
            value /= 64
        }
        return output
    }

    static func embeddedVideoURL(for sourceURL: URL) async throws -> URL {
        guard let code = shortcode(from: sourceURL) else { throw ReferenceReelError.instagramCode }
        guard let embed = URL(string: "https://www.instagram.com/reel/\(code)/embed/") else {
            throw ReferenceReelError.instagramCode
        }
        var request = URLRequest(url: embed)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        // A reference reel URL the buyer pasted — the declared `userDirectedFetch` lane.
        let (data, response) = try await ConsentedEgress.sendUngated(request, lane: .userDirectedFetch)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { throw ReferenceReelError.instagramVideo }

        let patterns = [#"\\\"video_url\\\":\\\"(.*?)\\\""#, #"\"video_url\":\"(.*?)\""#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            var value = String(html[range])
            value = replacingRegex(#"\\+/"#, in: value, with: "/")
            value = replacingRegex(#"\\+u00253D"#, in: value, with: "%3D")
            value = replacingRegex(#"\\+u0026"#, in: value, with: "&")
            value = replacingRegex(#"\\+u0025"#, in: value, with: "%")
            value = value.replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: value) { return url }
        }
        throw ReferenceReelError.instagramVideo
    }

    private static func replacingRegex(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
    }
}

enum ReferenceMediaLoader {
    static func stageLocalMovie(_ source: URL) throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let destination = try newReferenceURL(extension: source.pathExtension.isEmpty ? "mp4" : source.pathExtension)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    static func loadRemote(_ raw: String) async throws -> URL {
        guard let source = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = source.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw ReferenceReelError.invalidURL
        }
        let ext = source.pathExtension.lowercased()
        let mediaURL: URL
        if ["mp4", "mov", "m4v"].contains(ext) {
            mediaURL = source
        } else if source.host?.localizedCaseInsensitiveContains("instagram") == true ||
                    URLComponents(url: source, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "ig_cache_key" }) == true {
            mediaURL = try await InstagramReferenceResolver.embeddedVideoURL(for: source)
        } else {
            throw ReferenceReelError.unsupportedReference
        }

        var request = URLRequest(url: mediaURL)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        let (temporary, response) = try await ConsentedEgress.downloadUngated(request, lane: .userDirectedFetch)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ReferenceReelError.download("server rejected the request")
        }
        let destination = try newReferenceURL(extension: mediaURL.pathExtension.isEmpty ? "mp4" : mediaURL.pathExtension)
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { throw ReferenceReelError.download(error.localizedDescription) }
        return destination
    }

    private static func newReferenceURL(extension ext: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("BlackLabelMarketing/ReferenceReels", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("reference-\(UUID().uuidString).\(ext)")
    }
}

enum InstalledMarketingAppMarks {
    static let preferredNames = [
        "Black Label HQ", "Black Label Marketing", "Black Label Sovereign", "Black Label Trading",
        "Black Label Academy", "Black Label Real Estate", "Sunset", "Vigil"
    ]

    static func load() -> [ReferenceReelAsset] {
        preferredNames.compactMap { name in
            let url = URL(fileURLWithPath: "/Applications/\(name).app")
            guard FileManager.default.fileExists(atPath: url.path),
                  let image = cgImage(from: NSWorkspace.shared.icon(forFile: url.path)) else { return nil }
            return ReferenceReelAsset(name: name, kind: .appIcon, image: image)
        }
    }

    static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

enum ReferenceReelRenderer {
    static let outputSize = CGSize(width: 720, height: 1280)
    static let fps = 30

    struct TextCue {
        let start: Double
        let end: Double
        let lines: [String]
        let tint: NSColor
    }

    static let cues = [
        TextCue(start: 0.01, end: 0.08, lines: ["PRESSURE"], tint: NSColor(calibratedRed: 0.85, green: 0.94, blue: 0.97, alpha: 1)),
        TextCue(start: 0.28, end: 0.36, lines: ["CHANGES", "EVERYTHING"], tint: NSColor(calibratedRed: 0.85, green: 0.94, blue: 0.97, alpha: 1)),
        TextCue(start: 0.44, end: 0.52, lines: ["FOCUS"], tint: NSColor(calibratedRed: 0.85, green: 0.94, blue: 0.97, alpha: 1)),
        TextCue(start: 0.56, end: 0.65, lines: ["AT WILL"], tint: .white),
        TextCue(start: 0.66, end: 0.72, lines: ["DELIVER"], tint: NSColor(calibratedRed: 0.85, green: 0.94, blue: 0.97, alpha: 1)),
        TextCue(start: 0.72, end: 0.805, lines: ["ON A DEADLINE"], tint: .white)
    ]

    static func render(referenceURL: URL, assets: [ReferenceReelAsset], outputURL: URL,
                       title: String = "BUILT UNDER PRESSURE.", options: ReferenceReelRenderOptions = .init(),
                       progress: @escaping (Double) -> Void = { _ in }) throws {
        guard !assets.isEmpty else { throw ReferenceReelError.noVisuals }
        let referenceDuration = max(1.0, mediaDuration(referenceURL))
        let pacedDuration = Double(assets.count) * max(0.5, options.secondsPerVisual) + max(1.0, options.endCardSeconds)
        // A viral cut deliberately trims the recovered soundtrack to the hook/proof/CTA timeline.
        // The audio is still the exact reference track; it simply stops with the finished cut.
        // Standard remakes retain the original duration behavior for backward compatibility.
        let duration = options.fitToViralPacing
            ? max(8.0, pacedDuration)
            : (options.extendToShowEverything ? max(referenceDuration, pacedDuration) : referenceDuration)
        let silent = outputURL.deletingLastPathComponent().appendingPathComponent("silent-\(UUID().uuidString).mp4")
        let main = options.introURL == nil ? outputURL : outputURL.deletingLastPathComponent()
            .appendingPathComponent("main-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: silent)
            if main != outputURL { try? FileManager.default.removeItem(at: main) }
        }
        try renderSilent(duration: duration, referenceDuration: referenceDuration, assets: assets,
                         outputURL: silent, title: title, endCardSeconds: options.endCardSeconds,
                         fullBleed: options.fitToViralPacing,
                         progress: progress)

        if mediaHasAudio(referenceURL) {
            try? FileManager.default.removeItem(at: main)
            let ok = ReelAudio.mux(videoURL: silent,
                                   tracks: [ReelAudio.Stem(url: referenceURL, gain: 1, fade: false,
                                                           loop: options.loopSoundtrack && duration > referenceDuration + 0.05)],
                                   to: main)
            guard ok else { throw ReferenceReelError.audioMux }
        } else {
            try? FileManager.default.removeItem(at: main)
            try FileManager.default.moveItem(at: silent, to: main)
        }
        if let introURL = options.introURL {
            try ReferenceReelAssembler.prependIntro(introURL, to: main, outputURL: outputURL,
                                                     fullBleed: options.fitToViralPacing)
        }
        progress(1)
    }

    static func mediaDuration(_ url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        var result = 0.0
        let semaphore = DispatchSemaphore(value: 0)
        Task { result = (try? await asset.load(.duration).seconds) ?? 0; semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 15)
        return result.isFinite ? result : 0
    }

    private static func mediaHasAudio(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        var result = false
        let semaphore = DispatchSemaphore(value: 0)
        Task { result = ((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false); semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 15)
        return result
    }

    private static func renderSilent(duration: Double, referenceDuration: Double,
                                     assets: [ReferenceReelAsset], outputURL: URL,
                                     title: String, endCardSeconds: Double,
                                     fullBleed: Bool,
                                     progress: @escaping (Double) -> Void) throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4) }
        catch { throw ReferenceReelError.writer(error.localizedDescription) }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width), AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_200_000,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: Int(outputSize.width),
                                         kCVPixelBufferHeightKey as String: Int(outputSize.height)]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw ReferenceReelError.writer("video input rejected") }
        writer.add(input)
        guard writer.startWriting() else { throw ReferenceReelError.writer(writer.error?.localizedDescription ?? "start failed") }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int((duration * Double(fps)).rounded()))
        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pixelBuffer = makePixelBuffer(pool: adaptor.pixelBufferPool) else {
                throw ReferenceReelError.writer("pixel buffer allocation failed")
            }
            let seconds = Double(frame) / Double(fps)
            draw(pixelBuffer: pixelBuffer, seconds: seconds, duration: duration,
                 referenceDuration: referenceDuration, endCardSeconds: endCardSeconds,
                 assets: assets, title: title, frame: frame, fullBleed: fullBleed)
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
                throw ReferenceReelError.writer(writer.error?.localizedDescription ?? "frame append failed")
            }
            if frame % 6 == 0 { progress(Double(frame) / Double(totalFrames)) }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + max(30, duration * 3))
        guard writer.status == .completed else {
            throw ReferenceReelError.writer(writer.error?.localizedDescription ?? "finish failed")
        }
    }

    private static func makePixelBuffer(pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess { return buffer }
        CVPixelBufferCreate(nil, Int(outputSize.width), Int(outputSize.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        return buffer
    }

    private static func draw(pixelBuffer: CVPixelBuffer, seconds: Double, duration: Double,
                             referenceDuration: Double, endCardSeconds: Double,
                             assets: [ReferenceReelAsset], title: String, frame: Int,
                             fullBleed: Bool) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(data: base, width: Int(outputSize.width), height: Int(outputSize.height),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                              CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let visualDuration = max(0.25, duration - max(1.0, endCardSeconds))
        if seconds >= visualDuration {
            drawFinalCard(ctx: ctx, title: title)
            drawGrain(ctx: ctx, frame: frame, light: true)
            return
        }

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: outputSize))
        let visualProgress = min(0.999_999, max(0, seconds / visualDuration))
        let exact = visualProgress * Double(assets.count)
        let index = min(assets.count - 1, max(0, Int(exact)))
        let local = exact - floor(exact)
        let asset = assets[index]
        if asset.kind == .textCard {
            drawTextCard(asset, ctx: ctx)
        } else if let image = asset.image {
            if fullBleed {
                drawAspectFill(image, in: CGRect(origin: .zero, size: outputSize),
                               zoom: 1 + CGFloat(local) * 0.055, ctx: ctx)
                drawBottomScrim(ctx: ctx)
                drawAssetLabels(asset, ctx: ctx, fullBleed: true)
            } else {
                let card = CGRect(x: 60, y: 452.5, width: 600, height: 375)
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: card, cornerWidth: 24, cornerHeight: 24, transform: nil))
                ctx.clip()
                drawAspectFill(image, in: card, zoom: 1 + CGFloat(local) * 0.045, ctx: ctx)
                ctx.restoreGState()
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
                ctx.setLineWidth(1)
                ctx.addPath(CGPath(roundedRect: card, cornerWidth: 24, cornerHeight: 24, transform: nil))
                ctx.strokePath()
                drawAssetLabels(asset, ctx: ctx, fullBleed: false)
            }
        }

        let audioNormalized = (seconds.truncatingRemainder(dividingBy: max(1, referenceDuration))) / max(1, referenceDuration)
        if asset.kind != .textCard,
           let cue = cues.first(where: { audioNormalized >= $0.start && audioNormalized <= $0.end }) {
            drawCue(cue, ctx: ctx)
        }
        if !fullBleed {
            drawCentered("BLACK LABEL / REFERENCE REEL", y: 350, size: 18, color: .white.withAlphaComponent(0.42),
                         fontName: "Helvetica Neue", tracking: 4, ctx: ctx)
        }
        drawVignette(ctx: ctx)
        drawGrain(ctx: ctx, frame: frame, light: false)
    }

    private static func drawAssetLabels(_ asset: ReferenceReelAsset, ctx: CGContext, fullBleed: Bool) {
        let name = asset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = asset.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let restriction = asset.restriction.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameY: CGFloat = fullBleed ? (restriction.isEmpty ? 150 : 235) : 405
        let subtitleY: CGFloat = fullBleed ? (restriction.isEmpty ? 108 : 198) : 374
        if !name.isEmpty {
            drawCentered(name.uppercased(), y: nameY, size: fullBleed ? 38 : 31, color: .white,
                         fontName: "Didot", tracking: 2, ctx: ctx)
        }
        if !subtitle.isEmpty {
            drawCentered(subtitle.uppercased(), y: subtitleY, size: fullBleed ? 17 : 15,
                         color: .white.withAlphaComponent(fullBleed ? 0.82 : 0.62),
                         fontName: "Helvetica Neue", tracking: 4, ctx: ctx)
        }
        if !restriction.isEmpty {
            let box = CGRect(x: 44, y: fullBleed ? 64 : 260, width: 632,
                             height: fullBleed ? 104 : 92)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.92).cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.88).cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(box)
            drawCentered(restriction.uppercased(), y: fullBleed ? 105 : 297,
                         size: fullBleed ? 23 : 21, color: .white,
                         fontName: "Helvetica Neue", tracking: 2, ctx: ctx)
        }
    }

    private static func drawBottomScrim(ctx: CGContext) {
        let colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.94).cgColor]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors as CFArray, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 360, y: 520),
                               end: CGPoint(x: 360, y: 0), options: [])
    }

    private static func drawTextCard(_ asset: ReferenceReelAsset, ctx: CGContext) {
        let title = asset.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let subtitle = asset.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        drawCentered(title, y: subtitle.isEmpty ? 625 : 660, size: title.count > 16 ? 64 : 94,
                     color: .white, fontName: "Didot", tracking: 4, ctx: ctx)
        if !subtitle.isEmpty {
            drawCentered(subtitle, y: 575, size: 28, color: .white.withAlphaComponent(0.72),
                         fontName: "Helvetica Neue", tracking: 6, ctx: ctx)
        }
    }

    private static func drawAspectFill(_ image: CGImage, in rect: CGRect, zoom: CGFloat, ctx: CGContext) {
        let source = CGSize(width: image.width, height: image.height)
        let scale = max(rect.width / source.width, rect.height / source.height) * zoom
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        let destination = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                 width: size.width, height: size.height)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: destination)
    }

    private static func drawCue(_ cue: TextCue, ctx: CGContext) {
        let size: CGFloat = cue.lines.count > 1 ? 58 : (cue.lines[0].count > 10 ? 54 : 78)
        let gap = size * 0.95
        let base = 640 + CGFloat(cue.lines.count - 1) * gap / 2
        for (index, line) in cue.lines.enumerated() {
            drawCentered(line, y: base - CGFloat(index) * gap, size: size, color: cue.tint,
                         fontName: "Didot", tracking: 2, ctx: ctx)
        }
    }

    private static func drawFinalCard(ctx: CGContext, title: String) {
        ctx.setFillColor(NSColor(calibratedWhite: 0.94, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: outputSize))
        drawCentered("JULY 2026", y: 730, size: 28, color: .black, fontName: "Didot", tracking: 6, ctx: ctx)
        let words = title.uppercased().replacingOccurrences(of: ".", with: "")
        let lines = words == "BUILT UNDER PRESSURE" ? ["BUILT UNDER", "PRESSURE."] : [words]
        for (index, line) in lines.enumerated() {
            drawCentered(line, y: 650 - CGFloat(index) * 84, size: index == 0 ? 62 : 76,
                         color: .black, fontName: "Didot", tracking: 2, ctx: ctx)
        }
        drawCentered("BLACK LABEL MARKETING", y: 485, size: 18, color: .black.withAlphaComponent(0.68),
                     fontName: "Helvetica Neue", tracking: 5, ctx: ctx)
        drawVignette(ctx: ctx, dark: false)
    }

    private static func drawCentered(_ text: String, y: CGFloat, size: CGFloat, color: NSColor,
                                     fontName: String, tracking: CGFloat, ctx: CGContext) {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            .kern: tracking
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: (outputSize.width - width) / 2, y: y)
        CTLineDraw(line, ctx)
    }

    private static func drawVignette(ctx: CGContext, dark: Bool = true) {
        let colors = dark
            ? [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.52).cgColor]
            : [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.10).cgColor]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                        locations: [0.35, 1]) else { return }
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 360, y: 640), startRadius: 120,
                               endCenter: CGPoint(x: 360, y: 640), endRadius: 760,
                               options: [.drawsAfterEndLocation])
    }

    private static func drawGrain(ctx: CGContext, frame: Int, light: Bool) {
        var state = UInt64(frame &* 1103515245 &+ 12345)
        ctx.setFillColor((light ? NSColor.black : NSColor.white).withAlphaComponent(light ? 0.025 : 0.035).cgColor)
        for _ in 0..<180 {
            state = state &* 6364136223846793005 &+ 1
            let x = CGFloat(state % 720)
            state = state &* 6364136223846793005 &+ 1
            let y = CGFloat(state % 1280)
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
}

enum ReferenceReelAssembler {
    static func prependIntro(_ introURL: URL, to mainURL: URL, outputURL: URL,
                             fullBleed: Bool = false) throws {
        let intro = AVURLAsset(url: introURL)
        let main = AVURLAsset(url: mainURL)
        guard let introVideo = firstTrack(intro, .video), let mainVideo = firstTrack(main, .video) else {
            throw ReferenceReelError.writer("the intro or rendered reel did not contain video")
        }
        let introDuration = duration(intro)
        let mainDuration = duration(main)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ReferenceReelError.writer("the intro composition could not create video")
        }
        do {
            try video.insertTimeRange(CMTimeRange(start: .zero, duration: introDuration), of: introVideo, at: .zero)
            try video.insertTimeRange(CMTimeRange(start: .zero, duration: mainDuration), of: mainVideo, at: introDuration)
            if let audio = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
                if let introAudio = firstTrack(intro, .audio) {
                    try audio.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration(intro), introDuration)),
                                              of: introAudio, at: .zero)
                }
                if let mainAudio = firstTrack(main, .audio) {
                    try audio.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration(main), mainDuration)),
                                              of: mainAudio, at: introDuration)
                }
            }
        } catch { throw ReferenceReelError.writer(error.localizedDescription) }

        let introInstruction = AVMutableVideoCompositionInstruction()
        introInstruction.timeRange = CMTimeRange(start: .zero, duration: introDuration)
        introInstruction.backgroundColor = NSColor.black.cgColor
        let introLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        introLayer.setTransform(fullBleed
            ? aspectFillTransform(for: introVideo, target: CGRect(origin: .zero, size: ReferenceReelRenderer.outputSize))
            : aspectFitCardTransform(for: introVideo), at: .zero)
        introInstruction.layerInstructions = [introLayer]

        let mainInstruction = AVMutableVideoCompositionInstruction()
        mainInstruction.timeRange = CMTimeRange(start: introDuration, duration: mainDuration)
        mainInstruction.backgroundColor = NSColor.black.cgColor
        let mainLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        mainLayer.setTransform(fitTransform(for: mainVideo, target: CGRect(origin: .zero, size: ReferenceReelRenderer.outputSize)),
                               at: introDuration)
        mainInstruction.layerInstructions = [mainLayer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [introInstruction, mainInstruction]
        videoComposition.renderSize = ReferenceReelRenderer.outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(ReferenceReelRenderer.fps))

        try? FileManager.default.removeItem(at: outputURL)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ReferenceReelError.writer("the intro exporter could not start")
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.videoComposition = videoComposition
        let semaphore = DispatchSemaphore(value: 0)
        export.exportAsynchronously { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 180)
        guard export.status == .completed else {
            throw ReferenceReelError.writer(export.error?.localizedDescription ?? "intro export failed")
        }
    }

    private static func aspectFitCardTransform(for track: AVAssetTrack) -> CGAffineTransform {
        fitTransform(for: track, target: CGRect(x: 30, y: 454, width: 660, height: 371))
    }

    private static func aspectFillTransform(for track: AVAssetTrack, target: CGRect) -> CGAffineTransform {
        transformed(track, target: target, scale: { source, destination in
            max(destination.width / max(1, source.width), destination.height / max(1, source.height))
        })
    }

    private static func fitTransform(for track: AVAssetTrack, target: CGRect) -> CGAffineTransform {
        transformed(track, target: target, scale: { source, destination in
            min(destination.width / max(1, source.width), destination.height / max(1, source.height))
        })
    }

    private static func transformed(_ track: AVAssetTrack, target: CGRect,
                                    scale scaleFor: (CGSize, CGSize) -> CGFloat) -> CGAffineTransform {
        let sourceRect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform).standardized
        let scale = scaleFor(sourceRect.size, target.size)
        let fitted = CGSize(width: sourceRect.width * scale, height: sourceRect.height * scale)
        let offset = CGPoint(x: target.midX - fitted.width / 2, y: target.midY - fitted.height / 2)
        var transform = track.preferredTransform
        transform = transform.concatenating(CGAffineTransform(translationX: -sourceRect.minX, y: -sourceRect.minY))
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
        return transform
    }

    private static func firstTrack(_ asset: AVURLAsset, _ type: AVMediaType) -> AVAssetTrack? {
        var result: AVAssetTrack?
        let semaphore = DispatchSemaphore(value: 0)
        Task { result = try? await asset.loadTracks(withMediaType: type).first; semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 15)
        return result
    }

    private static func duration(_ asset: AVURLAsset) -> CMTime {
        var result = CMTime.zero
        let semaphore = DispatchSemaphore(value: 0)
        Task { result = (try? await asset.load(.duration)) ?? .zero; semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 15)
        return result
    }
}
#endif
#endif // circuit-convert
