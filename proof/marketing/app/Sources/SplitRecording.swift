#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  SplitRecording.swift
//  Black Label Marketing — "You + Screen" recording layouts.
//
//  Records the camera and screen at the same time, then stitches them into one .mp4.
//  The buyer can stay as a full-frame segmented cutout over the screen or use a small
//  camera picture-in-picture tile in the bottom-left corner. Reuses the app's existing
//  camera + screen recorders and AVFoundation.
//
//  PLATFORM: macOS-only — it composes the macOS-only MarketingCameraRecorder /
//  MarketingScreenRecorder / virtual-set stack (all themselves #if os(macOS)), and its only
//  UI mount (ReelStudioScreen's "Record in Marketing" panel) is already macOS-gated.
#if os(macOS)

import AVFoundation
import SwiftUI
import CoreImage
import CoreVideo
import Vision

// MARK: - Layout setting

enum MarketingYouScreenLayout: String, CaseIterable, Identifiable {
    case fullScreenCutout = "full-screen-cutout"
    case bottomLeftCorner = "bottom-left-corner"

    static let defaultsKey = "reelStudio.youScreen.layout"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullScreenCutout: return "Full-screen cutout"
        case .bottomLeftCorner: return "Bottom-left corner"
        }
    }

    var detail: String {
        switch self {
        case .fullScreenCutout:
            return "Your screen fills the frame and your camera background is removed, so you can move over it."
        case .bottomLeftCorner:
            return "Your screen fills the frame and your camera stays visible in a small bottom-left picture-in-picture tile."
        }
    }

    var recordingMessage: String {
        switch self {
        case .fullScreenCutout: return "Recording you over your screen…"
        case .bottomLeftCorner: return "Recording your screen with your camera in the bottom-left corner…"
        }
    }

    var compositingMessage: String {
        switch self {
        case .fullScreenCutout: return "Compositing you over your screen…"
        case .bottomLeftCorner: return "Compositing your bottom-left camera tile over the screen…"
        }
    }

    var finishedMessage: String {
        switch self {
        case .fullScreenCutout:
            return "Done — you over your full screen. Move anywhere; your screen fills the frame."
        case .bottomLeftCorner:
            return "Done — your screen fills the frame with your camera in the bottom-left corner."
        }
    }
}

// MARK: - Side-by-side compositor

enum MarketingSideBySideCompositor {
    /// Stitches a camera take (left half) and a screen take (right half) into one
    /// 1920×1080 side-by-side .mp4. Audio comes from the camera take (the mic).
    static func composite(cameraURL: URL, screenURL: URL, outputURL: URL) async throws {
        let cameraAsset = AVURLAsset(url: cameraURL)
        let screenAsset = AVURLAsset(url: screenURL)

        guard let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first,
              let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "SplitComposite", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "One of the takes has no video."])
        }

        let cameraDuration = try await cameraAsset.load(.duration)
        let screenDuration = try await screenAsset.load(.duration)
        let duration = min(cameraDuration, screenDuration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)

        let composition = AVMutableComposition()
        guard let compCamera = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compScreen = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "SplitComposite", code: -2, userInfo: [NSLocalizedDescriptionKey: "Couldn't build the composition."])
        }
        try compCamera.insertTimeRange(timeRange, of: cameraTrack, at: .zero)
        try compScreen.insertTimeRange(timeRange, of: screenTrack, at: .zero)

        if let cameraAudio = try await cameraAsset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(timeRange, of: cameraAudio, at: .zero)
        }

        let renderSize = CGSize(width: 1920, height: 1080)

        let cameraNatural = try await cameraTrack.load(.naturalSize)
        let cameraPreferred = try await cameraTrack.load(.preferredTransform)
        let screenNatural = try await screenTrack.load(.naturalSize)
        let screenPreferred = try await screenTrack.load(.preferredTransform)

        // Stack: your screen across the TOP (full width, shown WHOLE — an ultra-wide
        // desktop fills the top band edge-to-edge), you in a strip along the BOTTOM.
        // The band split follows the screen's aspect so a 2.39:1 desktop fills the top
        // with no side bars, capped so you always get a usable bottom strip. This
        // AVVideoComposition space is TOP-left origin (y=0 is the TOP, verified against
        // a rendered frame), so the screen rect sits at y=0 and the camera rect below.
        let screenDisplayed = CGRect(origin: .zero, size: screenNatural).applying(screenPreferred)
        let screenAspect = (abs(screenDisplayed.width) > 0 && abs(screenDisplayed.height) > 0)
            ? abs(screenDisplayed.width / screenDisplayed.height) : 16.0 / 9.0
        let screenBandHeight = min((renderSize.width / screenAspect).rounded(), 820)
        let cameraBandHeight = renderSize.height - screenBandHeight
        let screenRect = CGRect(x: 0, y: 0, width: renderSize.width, height: screenBandHeight)
        let cameraRect = CGRect(x: 0, y: screenBandHeight, width: renderSize.width, height: cameraBandHeight)

        let cameraInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compCamera)
        let (cameraTransform, cameraCrop) = layout(
            natural: cameraNatural, preferred: cameraPreferred, into: cameraRect, fill: true)
        cameraInstruction.setTransform(cameraTransform, at: .zero)
        cameraInstruction.setCropRectangle(cameraCrop, at: .zero)

        let screenInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compScreen)
        let (screenTransform, screenCrop) = layout(
            natural: screenNatural, preferred: screenPreferred, into: screenRect, fill: false)
        screenInstruction.setTransform(screenTransform, at: .zero)
        screenInstruction.setCropRectangle(screenCrop, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        instruction.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        instruction.layerInstructions = [cameraInstruction, screenInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "SplitComposite", code: -3, userInfo: [NSLocalizedDescriptionKey: "Couldn't create the exporter."])
        }
        export.videoComposition = videoComposition
        export.outputURL = outputURL
        export.outputFileType = .mp4
        try? FileManager.default.removeItem(at: outputURL)
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? NSError(domain: "SplitComposite", code: -4,
                                          userInfo: [NSLocalizedDescriptionKey: "Export failed."])
        }
    }

    /// Your live screen fills the whole 1920×1080 frame. Depending on `layout`, the camera
    /// becomes either a full-frame segmented cutout or a small bottom-left picture-in-picture
    /// tile. Audio comes from the camera take (the mic).
    static func compositeScreenBackground(cameraURL: URL, screenURL: URL, outputURL: URL,
                                          layout: MarketingYouScreenLayout) async throws {
        let cameraAsset = AVURLAsset(url: cameraURL)
        let screenAsset = AVURLAsset(url: screenURL)

        guard let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first,
              let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "SplitComposite", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "One of the takes has no video."])
        }

        let cameraDuration = try await cameraAsset.load(.duration)
        let screenDuration = try await screenAsset.load(.duration)
        let duration = min(cameraDuration, screenDuration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)

        let composition = AVMutableComposition()
        guard let compCamera = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compScreen = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "SplitComposite", code: -2, userInfo: [NSLocalizedDescriptionKey: "Couldn't build the composition."])
        }
        try compCamera.insertTimeRange(timeRange, of: cameraTrack, at: .zero)
        try compScreen.insertTimeRange(timeRange, of: screenTrack, at: .zero)

        if let cameraAudio = try await cameraAsset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(timeRange, of: cameraAudio, at: .zero)
        }

        let cameraPreferred = try await cameraTrack.load(.preferredTransform)
        let screenPreferred = try await screenTrack.load(.preferredTransform)

        let instruction = MarketingScreenBackgroundInstruction(
            timeRange: timeRange,
            cameraTrackID: compCamera.trackID, screenTrackID: compScreen.trackID,
            cameraTransform: cameraPreferred, screenTransform: screenPreferred,
            layout: layout)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = MarketingScreenBackgroundCompositor.self
        videoComposition.renderSize = CGSize(width: 1920, height: 1080)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "SplitComposite", code: -3, userInfo: [NSLocalizedDescriptionKey: "Couldn't create the exporter."])
        }
        export.videoComposition = videoComposition
        export.outputURL = outputURL
        export.outputFileType = .mp4
        try? FileManager.default.removeItem(at: outputURL)
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? NSError(domain: "SplitComposite", code: -4,
                                          userInfo: [NSLocalizedDescriptionKey: "Screen-background export failed."])
        }
    }

    /// Scale+center a track of `natural` size (after its `preferred` orientation)
    /// into `rect`, returning the transform AND a source-space crop rect. With
    /// `fill: true` the content aspect-FILLS `rect` (overflow cropped to `rect`);
    /// with `fill: false` it aspect-FITS (whole content visible, letterboxed by the
    /// composition's black background inside `rect`).
    ///
    /// Two subtleties this must handle (both bit the first ship):
    /// - A preferred transform can leave the content at a negative origin (the Mac
    ///   camera writes a flip-x transform with NO translation), so the displayed
    ///   bounds must be normalized back to (0,0) or the layer lands off-screen.
    /// - setTransform alone never clips: an aspect-filled layer overflows its region
    ///   and covers the other track, so the overflow must be cropped in the track's
    ///   original coordinate space (the pre-image of `rect` under the transform). For
    ///   the fit case that same crop is a superset of the content, so it clips nothing.
    static func layout(natural: CGSize, preferred: CGAffineTransform, into rect: CGRect, fill: Bool) -> (CGAffineTransform, CGRect) {
        let displayed = CGRect(origin: .zero, size: natural).applying(preferred)
        guard displayed.width > 0, displayed.height > 0 else {
            return (preferred, CGRect(origin: .zero, size: natural))
        }
        let normalized = preferred.concatenating(
            CGAffineTransform(translationX: -displayed.minX, y: -displayed.minY))
        let scale = fill
            ? max(rect.width / displayed.width, rect.height / displayed.height)
            : min(rect.width / displayed.width, rect.height / displayed.height)
        let scaledWidth = displayed.width * scale, scaledHeight = displayed.height * scale
        let transform = normalized
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.origin.x + (rect.width - scaledWidth) / 2,
                                             y: rect.origin.y + (rect.height - scaledHeight) / 2))
        let crop = rect.applying(transform.inverted())
        return (transform, crop)
    }
}

// MARK: - Split recorder (drives both, then composites)

@MainActor
final class MarketingSplitRecorder: ObservableObject {
    /// Single source of truth for the split canvas: the virtual-set capture viewport is derived
    /// from it, so the page can never be captured at one shape and rendered into another.
    static let renderSize = CGSize(width: 1280, height: 720)

    let camera = MarketingCameraRecorder()
    let screen = MarketingScreenRecorder()

    enum Phase: Equatable { case idle, recording, compositing, done, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var message = "Ready to record your camera and screen together."
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastRecordingDate: Date?
    private var recordingLayout: MarketingYouScreenLayout = .fullScreenCutout

    /// Optional website (or image) to place behind you on the camera half, baked
    /// in before the side-by-side stitch. Set from the panel before recording.
    var virtualBackground: MarketingVirtualBackground?

    var isRecording: Bool { phase == .recording }

    func prepare() {
        camera.requestAccessAndStart()
        screen.requestAccessAndLoadSources()
    }

    func start(layout: MarketingYouScreenLayout) {
        guard phase != .recording, phase != .compositing else { return }
        recordingLayout = layout
        Self.log("start requested: layout=\(layout.rawValue) camState=\(camera.state) scrState=\(screen.state) scrSource=\(screen.selectedSourceID.isEmpty ? "none" : "set")")
        phase = .recording
        message = "Getting ready…"
        Task {
            // Wait for both capture engines to be ready (they prepare asynchronously).
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                let cameraReady = (camera.state == .ready || camera.state == .recorded)
                let screenReady = !screen.selectedSourceID.isEmpty && (screen.state == .ready || screen.state == .recorded)
                if cameraReady && screenReady { break }
                if screen.selectedSourceID.isEmpty { screen.refreshSources() }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard camera.state == .ready || camera.state == .recorded else {
                phase = .failed; message = "Camera isn't ready — grant Camera access and try again."
                Self.log("ABORT: camera not ready (\(camera.state))"); return
            }
            guard !screen.selectedSourceID.isEmpty else {
                phase = .failed; message = "Screen isn't ready — enable Screen Recording for this app, then reopen it."
                Self.log("ABORT: screen not ready (\(screen.state), no source)"); return
            }
            screen.startRecording(capturesSystemAudio: false, capturesMicrophone: false,
                                  showsCursor: true, showMouseClicks: true)
            camera.startRecording()
            try? await Task.sleep(nanoseconds: 400_000_000)
            Self.log("started: camState=\(camera.state) scrState=\(screen.state)")
            message = recordingLayout.recordingMessage

            // Verify BOTH engines actually engaged. A wedged SCStream (startCapture
            // hangs → screen stuck .preparing) or an interrupted camera otherwise
            // records NOTHING while the UI says "Recording…" for the whole take. Catch
            // it in a few seconds and abort with an actionable message instead.
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard phase == .recording else { return }
            if camera.state != .recording || screen.state != .recording {
                Self.log("ABORT after start: capture didn't engage (camState=\(camera.state) scrState=\(screen.state))")
                camera.stopRecording()
                screen.stopRecording()
                phase = .failed
                message = "Capture didn't start (camera \(camera.state), screen \(screen.state)). Quit and reopen Marketing, then record again."
            }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        Self.log("stop requested")
        camera.stopRecording()
        screen.stopRecording()
        phase = .compositing
        message = recordingLayout.compositingMessage
        Task { await waitThenComposite() }
    }

    private func waitThenComposite() async {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let cameraURL = camera.lastRecordingURL, camera.state == .recorded,
               let screenURL = screen.lastRecordingURL, screen.state == .recorded {
                Self.log("both takes ready cam=\(cameraURL.lastPathComponent) scr=\(screenURL.lastPathComponent)")
                await runComposite(cameraURL: cameraURL, screenURL: screenURL, layout: recordingLayout)
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        phase = .failed
        message = "A take didn't finish (camera \(camera.state), screen \(screen.state))."
        Self.log("TIMEOUT: camState=\(camera.state) camURL=\(camera.lastRecordingURL != nil) scrState=\(screen.state) scrURL=\(screen.lastRecordingURL != nil)")
    }

    private func runComposite(cameraURL: URL, screenURL: URL,
                              layout: MarketingYouScreenLayout) async {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("blm-split-\(UUID().uuidString)").appendingPathExtension("mp4")
        message = layout.compositingMessage
        Self.log("compositeScreenBackground begin layout=\(layout.rawValue)")
        do {
            try await MarketingSideBySideCompositor.compositeScreenBackground(
                cameraURL: cameraURL, screenURL: screenURL, outputURL: output,
                layout: layout)
            lastRecordingURL = output
            lastRecordingDate = Date()
            phase = .done
            message = layout.finishedMessage
            Self.log("composite DONE layout=\(layout.rawValue) \(output.lastPathComponent)")
        } catch {
            phase = .failed
            message = "Couldn't stitch the take: \(error.localizedDescription)"
            Self.log("composite FAILED \(error.localizedDescription)")
        }
    }

    private func applyBackground(_ background: MarketingVirtualBackground, to cameraURL: URL) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            MarketingVirtualBackgroundVideoProcessor.process(
                sourceURL: cameraURL, background: background,
                renderSize: Self.renderSize
            ) { result in
                switch result {
                case .success(let url): continuation.resume(returning: url)
                case .failure: continuation.resume(returning: nil)
                }
            }
        }
    }

    static func log(_ message: String) {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabelMarketing", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("split.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }
}

// MARK: - Panel

struct SplitCapturePanel: View {
    @ObservedObject var recorder: MarketingSplitRecorder
    @StateObject private var virtualSet = MarketingVirtualSetModel()
    @AppStorage(MarketingYouScreenLayout.defaultsKey)
    private var savedLayout = MarketingYouScreenLayout.fullScreenCutout.rawValue
    var onFinished: (URL) -> Void
    var onMessage: (String) -> Void
    var onError: (String) -> Void

    private var selectedLayout: MarketingYouScreenLayout {
        MarketingYouScreenLayout(rawValue: savedLayout) ?? .fullScreenCutout
    }

    private var layoutSelection: Binding<MarketingYouScreenLayout> {
        Binding(
            get: { selectedLayout },
            set: { savedLayout = $0.rawValue }
        )
    }

    private var layoutIsLocked: Bool {
        recorder.phase == .recording || recorder.phase == .compositing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record your camera and screen together, then choose how your camera appears in the finished video.")
                .font(.system(size: 11.5))
                .foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)

            Picker("You + Screen layout", selection: layoutSelection) {
                ForEach(MarketingYouScreenLayout.allCases) { layout in
                    Text(layout.label).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .disabled(layoutIsLocked)

            Text("Next take: \(selectedLayout.detail)")
                .font(.system(size: 10.5))
                .foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)

            // Live "you" preview — same as Camera mode (segmented onto the website
            // when a background is set, otherwise the raw camera).
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black)
                if recorder.phase == .done, let url = recorder.lastRecordingURL {
                    MarketingRecordingPlayer(url: url)
                } else if selectedLayout == .fullScreenCutout,
                          virtualSet.enabled, let image = recorder.camera.segmentedPreview {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else if recorder.camera.isLive || recorder.camera.state == .preparing {
                    MarketingCameraPreview(recorder: recorder.camera)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "video.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(BLTheme.gold)
                        Text("Camera warming up…").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                    }
                }
                if recorder.camera.isLive && recorder.phase != .done {
                    VStack {
                        HStack {
                            Text(recorder.isRecording ? "REC" : "YOU")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(recorder.isRecording ? .white : BLTheme.gold)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background((recorder.isRecording ? Color.red : Color.black).opacity(0.75), in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }.padding(10)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if !recorder.screen.sources.isEmpty {
                Picker("Screen", selection: Binding(
                    get: { recorder.screen.selectedSourceID },
                    set: { recorder.screen.selectedSourceID = $0 }
                )) {
                    ForEach(recorder.screen.sources) { source in
                        Text(source.title).tag(source.id)
                    }
                }
                .labelsHidden()
                .tint(BLTheme.gold)
                .disabled(recorder.isRecording)
            }

            // A virtual set is meaningful only for the segmented full-screen cutout. The
            // bottom-left export deliberately keeps the complete camera frame as a truthful tile.
            if selectedLayout == .fullScreenCutout {
                MarketingVirtualSetEditor(model: virtualSet, canvasSize: MarketingSplitRecorder.renderSize)
            } else {
                Label("Bottom-left uses your complete camera view. Switch to Full-screen cutout for a virtual set.",
                      systemImage: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if recorder.isRecording {
                GoldButton(label: "Stop", fill: true, icon: "stop.fill") { recorder.stop() }
            } else if recorder.phase == .compositing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(BLTheme.gold)
                    Text(recorder.message)
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                }
            } else if recorder.phase == .done, let url = recorder.lastRecordingURL {
                HStack(spacing: 10) {
                    GhostButton(label: "Retake", icon: "arrow.counterclockwise") {
                        recorder.virtualBackground = selectedLayout == .fullScreenCutout && virtualSet.enabled
                            ? virtualSet.background : nil
                        recorder.start(layout: selectedLayout)
                    }
                    GoldButton(label: "Use this take", fill: true, icon: "checkmark.circle.fill") {
                        onFinished(url)
                    }
                }
            } else {
                GoldButton(label: "Record you + screen", fill: true, icon: "record.circle.fill") {
                    recorder.virtualBackground = selectedLayout == .fullScreenCutout && virtualSet.enabled
                        ? virtualSet.background : nil
                    recorder.start(layout: selectedLayout)
                }
            }

            Text(recorder.message)
                .font(.system(size: 11))
                .foregroundColor(recorder.phase == .failed ? Color.red.opacity(0.85) : BLTheme.sub)
        }
        .onAppear {
            recorder.prepare()
            recorder.camera.setVirtualBackground(
                selectedLayout == .fullScreenCutout && virtualSet.enabled ? virtualSet.background : nil)
        }
        .onReceive(virtualSet.objectWillChange) { _ in
            DispatchQueue.main.async {
                recorder.camera.setVirtualBackground(
                    selectedLayout == .fullScreenCutout && virtualSet.enabled ? virtualSet.background : nil)
            }
        }
        .onChange(of: savedLayout) { _ in
            recorder.camera.setVirtualBackground(
                selectedLayout == .fullScreenCutout && virtualSet.enabled ? virtualSet.background : nil)
        }
        // No auto-commit: the finished take is shown for review and the buyer chooses
        // Retake or "Use this take" (which fires onFinished), matching Camera mode.
    }
}

// MARK: - Screen-as-background custom compositor

/// Carries the two source tracks (camera + screen) and their preferred transforms to
/// the custom compositor for every output frame.
final class MarketingScreenBackgroundInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let cameraTrackID: CMPersistentTrackID
    let screenTrackID: CMPersistentTrackID
    let cameraTransform: CGAffineTransform
    let screenTransform: CGAffineTransform
    let layout: MarketingYouScreenLayout

    init(timeRange: CMTimeRange, cameraTrackID: CMPersistentTrackID, screenTrackID: CMPersistentTrackID,
         cameraTransform: CGAffineTransform, screenTransform: CGAffineTransform,
         layout: MarketingYouScreenLayout) {
        self.timeRange = timeRange
        self.cameraTrackID = cameraTrackID
        self.screenTrackID = screenTrackID
        self.cameraTransform = cameraTransform
        self.screenTransform = screenTransform
        self.layout = layout
        self.requiredSourceTrackIDs = [NSNumber(value: cameraTrackID), NSNumber(value: screenTrackID)]
        super.init()
    }
}

/// Fills the frame with the screen, then draws either the Vision-segmented person or
/// the bottom-left camera tile on top — per output frame.
final class MarketingScreenBackgroundCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: Any]? =
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] =
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let renderQueue = DispatchQueue(label: "com.blacklabel.marketing.screen-bg-compositor")
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            guard let instruction = request.videoCompositionInstruction as? MarketingScreenBackgroundInstruction,
                  let outBuffer = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "ScreenBG", code: -1))
                return
            }
            let bounds = CGRect(origin: .zero, size: request.renderContext.size)

            // Background = your live screen, aspect-filled to cover the whole frame.
            var plate = CIImage(color: .black).cropped(to: bounds)
            if let screenBuf = request.sourceFrame(byTrackID: instruction.screenTrackID) {
                let img = CIImage(cvPixelBuffer: screenBuf).transformed(by: instruction.screenTransform)
                plate = Self.aspectFill(img, into: bounds).cropped(to: bounds)
            }

            // Foreground = either the existing full-frame segmented cutout or a small,
            // unsegmented picture-in-picture tile pinned to the bottom-left.
            var result = plate
            if let camBuf = request.sourceFrame(byTrackID: instruction.cameraTrackID) {
                let camera = CIImage(cvPixelBuffer: camBuf).transformed(by: instruction.cameraTransform)
                switch instruction.layout {
                case .fullScreenCutout:
                    let fullFrameCamera = Self.aspectFill(camera, into: bounds).cropped(to: bounds)
                    result = Self.blendPerson(fullFrameCamera, over: plate, bounds: bounds)
                case .bottomLeftCorner:
                    result = Self.blendPictureInPicture(camera, over: plate, bounds: bounds)
                }
            }

            self.context.render(result, to: outBuffer, bounds: bounds, colorSpace: self.colorSpace)
            request.finish(withComposedVideoFrame: outBuffer)
        }
    }

    /// Scale an image to COVER `rect` (aspect-fill), centered.
    private static func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, e.width.isFinite, e.height.isFinite else { return image }
        let scale = max(rect.width / e.width, rect.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let se = scaled.extent
        return scaled.transformed(by: CGAffineTransform(translationX: rect.midX - se.midX,
                                                        y: rect.midY - se.midY))
    }

    /// Uses the same default geometry as Reel Studio's presenter overlay: 26% of the frame
    /// width with a 5.5%-of-short-edge inset. The camera remains an unsegmented tile;
    /// Vision segmentation belongs only to the full-screen cutout layout.
    private static func blendPictureInPicture(_ camera: CIImage, over background: CIImage,
                                              bounds: CGRect) -> CIImage {
        let extent = camera.extent
        let sourceAspect = Double(extent.width / max(1, extent.height))
        let overlay = ReelPresenterOverlay(corner: .bottomLeft)
        let tileRect = overlay.tileRect(in: bounds.size, sourceAspect: sourceAspect)
            .offsetBy(dx: bounds.minX, dy: bounds.minY)
        guard tileRect.width > 2, tileRect.height > 2 else { return background }

        let tile = aspectFill(camera, into: tileRect).cropped(to: tileRect)
        let radius = overlay.cornerRadius(for: tileRect)
        guard let tileMask = roundedRectangleMask(bounds: bounds, rect: tileRect, radius: radius) else {
            return tile.composited(over: background).cropped(to: bounds)
        }

        // Match the existing presenter-tile treatment with a subtle Black Label gold hairline.
        let borderWidth = max(1.5, bounds.width * 0.0022)
        let borderRect = tileRect.insetBy(dx: -borderWidth, dy: -borderWidth)
        var plate = background
        if let borderMask = roundedRectangleMask(
            bounds: bounds, rect: borderRect, radius: radius + borderWidth
        ) {
            let gold = CIImage(color: CIColor(red: 217.0 / 255.0, green: 182.0 / 255.0,
                                              blue: 92.0 / 255.0, alpha: 0.55))
                .cropped(to: bounds)
            plate = gold.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: borderMask
            ]).cropped(to: bounds)
        }

        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: bounds)
        let tileCanvas = tile.composited(over: transparent).cropped(to: bounds)
        return tileCanvas.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: plate,
            kCIInputMaskImageKey: tileMask
        ]).cropped(to: bounds)
    }

    private static func roundedRectangleMask(bounds: CGRect, rect: CGRect,
                                             radius: CGFloat) -> CIImage? {
        guard let rounded = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        ])?.outputImage else { return nil }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: bounds)
        return rounded.cropped(to: rect).composited(over: black).cropped(to: bounds)
    }

    /// Segment the person from `person` and composite them over `background`. If Vision
    /// can't find a person, the plain background shows (never a frozen/garbage frame).
    private static func blendPerson(_ person: CIImage, over background: CIImage, bounds: CGRect) -> CIImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(ciImage: person, orientation: .up).perform([request])
            guard let observation = request.results?.first else { return background }
            var mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
            let me = mask.extent
            guard me.width > 0, me.height > 0 else { return background }
            mask = mask.transformed(by: CGAffineTransform(scaleX: bounds.width / me.width,
                                                          y: bounds.height / me.height))
            mask = mask.transformed(by: CGAffineTransform(translationX: bounds.minX - mask.extent.minX,
                                                          y: bounds.minY - mask.extent.minY))
            return person.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask
            ]).cropped(to: bounds)
        } catch {
            return background
        }
    }
}
#endif
#endif // circuit-convert
