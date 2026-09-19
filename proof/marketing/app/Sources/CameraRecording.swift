#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — native Mac camera capture + branded recording finish.
// Camera and microphone data stay on this Mac. Nothing is uploaded by this workflow.
import Foundation
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit
#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import AVKit
import QuartzCore
import CoreImage
import UniformTypeIdentifiers

/// Timestamped line to the camera diagnostic log — the OS redacts AVFoundation
/// errors, so the app records its own record/start/fail trail here.
func blmCameraLog(_ line: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BlackLabelMarketing", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
    let url = dir.appendingPathComponent("camera.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
    } else {
        try? entry.data(using: .utf8)?.write(to: url)
    }
}

/// A file can contain an AAC track and still be completely silent (for example when macOS input
/// volume is zero). Inspect decoded PCM, not just track presence, before the UI calls a take usable.
enum MarketingRecordingAudioProbe {
    enum Result: Equatable { case audible, silent, missing }

    static func inspect(_ url: URL) -> Result {
        let asset = AVURLAsset(url: url)
        var audioTrack: AVAssetTrack?
        let trackReady = DispatchSemaphore(value: 0)
        Task {
            audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
            trackReady.signal()
        }
        _ = trackReady.wait(timeout: .now() + 10)
        guard let audioTrack else { return .missing }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard let reader = try? AVAssetReader(asset: asset) else { return .missing }
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .missing }
        reader.add(output)
        guard reader.startReading() else { return .missing }

        // 128 / Int16.max is about -48 dBFS: safely above codec dither/noise, far below speech.
        // Exit on the first audible sample so even a long take is cheap to validate.
        let audibleFloor: Int16 = 128
        while let sample = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sample) }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var bytes: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &bytes) == kCMBlockBufferNoErr,
                  let bytes, length >= MemoryLayout<Int16>.size else { continue }
            let samples = UnsafeRawPointer(bytes).bindMemory(to: Int16.self,
                                                              capacity: length / MemoryLayout<Int16>.size)
            for index in 0..<(length / MemoryLayout<Int16>.size) {
                let value = samples[index]
                if value > audibleFloor || value < -audibleFloor {
                    reader.cancelReading()
                    return .audible
                }
            }
        }
        return .silent
    }
}

final class MarketingCameraRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate,
                                     AVCaptureVideoDataOutputSampleBufferDelegate {
    enum State: Equatable {
        case idle, requestingAccess, preparing, ready, recording, recorded, failed
    }

    let session = AVCaptureSession()
    @Published private(set) var state: State = .idle
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastRecordingDate: Date?
    @Published private(set) var cameraName = "Mac camera"
    @Published private(set) var message = "Camera and microphone stay on this Mac."
    @Published private(set) var segmentedPreview: CGImage?
    @Published private(set) var recordedAudio: MarketingRecordingAudioProbe.Result = .missing

    private let movieOutput = AVCaptureMovieFileOutput()
    private let previewOutput = AVCaptureVideoDataOutput()
    /// ONE preview layer owned by the recorder, attached to the session exactly once
    /// (in configureAndStart, on the session queue). The SwiftUI view only HOSTS it —
    /// mounting/unmounting never touches the session, which previously caused both a
    /// main-thread deadlock (dealloc committing config) and an AVError -11806 (adding
    /// the layer mid-record on a Retake). Session config lives on one queue, full stop.
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let sessionQueue = DispatchQueue(label: "com.blacklabel.marketing.camera.session", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "com.blacklabel.marketing.camera.virtual-preview", qos: .userInitiated)
    private let backgroundLock = NSLock()
    private var virtualBackground: MarketingVirtualBackground?
    private var lastPreviewTime = CMTime.zero
    private var configured = false

    var isLive: Bool { state == .ready || state == .recording }
    var cameraNeedsSettings: Bool { needsSettings(for: .video) }
    var microphoneNeedsSettings: Bool { needsSettings(for: .audio) }

    func requestAccessAndStart() {
        guard state != .requestingAccess && state != .preparing && state != .recording else { return }
        NSApp.activate(ignoringOtherApps: true)
        if cameraNeedsSettings || microphoneNeedsSettings {
            state = .failed
            message = blockedPermissionMessage()
            openFirstBlockedSettings()
            return
        }
        state = .requestingAccess
        message = "Requesting camera and microphone access…"
        authorize(.video) { [weak self] cameraOK in
            guard let self else { return }
            self.authorize(.audio) { [weak self] microphoneOK in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard cameraOK && microphoneOK else {
                        self.state = .failed
                        self.message = self.blockedPermissionMessage()
                        self.openFirstBlockedSettings()
                        return
                    }
                    self.configureAndStart()
                }
            }
        }
    }

    func startRecording() {
        guard configured, state == .ready || state == .recorded else { return }
        lastRecordingURL = nil
        lastRecordingDate = nil
        recordedAudio = .missing
        message = "Recording locally…"
        state = .recording
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blm-camera-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        blmCameraLog("startRecording requested → \(url.lastPathComponent)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning { self.session.startRunning() }
            let hasConnection = self.movieOutput.connection(with: .video) != nil
            if let connection = self.movieOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
            blmCameraLog("movieOutput.startRecording (sessionRunning=\(self.session.isRunning) movieConnection=\(hasConnection) inputs=\(self.session.inputs.count) outputs=\(self.session.outputs.count))")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        message = "Finishing recording…"
        sessionQueue.async { [weak self] in self?.movieOutput.stopRecording() }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }


    func setVirtualBackground(_ background: MarketingVirtualBackground?) {
        backgroundLock.lock(); virtualBackground = background; backgroundLock.unlock()
        if background == nil { segmentedPreview = nil }
    }

    private func authorize(_ mediaType: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: mediaType, completionHandler: completion)
        default: completion(false)
        }
    }

    private func needsSettings(for mediaType: AVMediaType) -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .denied, .restricted: return true
        default: return false
        }
    }

    private func blockedPermissionMessage() -> String {
        if cameraNeedsSettings && microphoneNeedsSettings {
            return "Camera and microphone are blocked. Marketing opened Camera settings; enable it, then enable Microphone below."
        }
        if cameraNeedsSettings {
            return "Camera access is blocked. Marketing opened System Settings → Privacy & Security → Camera."
        }
        if microphoneNeedsSettings {
            return "Microphone access is blocked. Marketing opened System Settings → Privacy & Security → Microphone."
        }
        return "Camera and microphone permission was not granted. Click Enable camera & mic to try again."
    }

    func openCameraSettings() { openPrivacySettings("Privacy_Camera") }
    func openMicrophoneSettings() { openPrivacySettings("Privacy_Microphone") }

    private func openFirstBlockedSettings() {
        if cameraNeedsSettings { openCameraSettings() }
        else if microphoneNeedsSettings { openMicrophoneSettings() }
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    private func configureAndStart() {
        state = .preparing
        message = "Starting the studio camera…"
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.configured {
                    try self.configureSession()
                    self.configured = true
                }
                // Attach the persistent preview layer to the session ONCE, here on the
                // session queue — never from the view. After this the SwiftUI preview
                // only hosts the layer; it never mutates session config again.
                if self.previewLayer.session == nil {
                    self.previewLayer.session = self.session
                    self.previewLayer.videoGravity = .resizeAspectFill
                    if let connection = self.previewLayer.connection, connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = true
                    }
                }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    self.state = .ready
                    self.message = "Camera and microphone ready. Frame yourself inside the guide, then record."
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed
                    self.message = "Camera setup failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }

        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard let camera else {
            throw NSError(domain: "BlackLabelMarketing.Camera", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera was found on this Mac."])
        }
        let videoInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(videoInput) else {
            throw NSError(domain: "BlackLabelMarketing.Camera", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The selected camera could not be connected."])
        }
        session.addInput(videoInput)
        DispatchQueue.main.async { self.cameraName = camera.localizedName }

        if let microphone = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: microphone)
            if session.canAddInput(audioInput) { session.addInput(audioInput) }
        }
        guard session.canAddOutput(movieOutput) else {
            throw NSError(domain: "BlackLabelMarketing.Camera", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The movie recorder could not be connected."])
        }
        session.addOutput(movieOutput)
        previewOutput.alwaysDiscardsLateVideoFrames = true
        previewOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        previewOutput.setSampleBufferDelegate(self, queue: previewQueue)
        if session.canAddOutput(previewOutput) {
            session.addOutput(previewOutput)
            if let connection = previewOutput.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }

        do {
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { camera.whiteBalanceMode = .continuousAutoWhiteBalance }
            camera.unlockForConfiguration()
        } catch {
            // Capture remains usable when a particular camera does not expose manual locks.
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let nsError = error as NSError?
        blmCameraLog("didFinishRecording \(outputFileURL.lastPathComponent) error=\(nsError.map { "\($0.domain) \($0.code): \($0.localizedDescription)" } ?? "none")")
        let audioResult = error == nil ? MarketingRecordingAudioProbe.inspect(outputFileURL) : .missing
        blmCameraLog("audioProbe \(outputFileURL.lastPathComponent) result=\(String(describing: audioResult))")
        DispatchQueue.main.async {
            if let error {
                self.state = .failed
                self.message = "Recording failed: \(error.localizedDescription)"
            } else {
                self.lastRecordingURL = outputFileURL
                self.lastRecordingDate = Date()
                self.recordedAudio = audioResult
                self.state = .recorded
                switch audioResult {
                case .audible:
                    self.message = "Take recorded with live microphone audio. Review it, then apply the Black Label finish."
                case .silent:
                    self.message = "This take's microphone track is silent. Raise the Mac input volume and retake, or explicitly approve a silent clip."
                case .missing:
                    self.message = "This take has no readable microphone audio. Retake after checking the microphone, or explicitly approve a silent clip."
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeGetSeconds(CMTimeSubtract(time, lastPreviewTime)) >= 0.12 else { return }
        backgroundLock.lock(); let background = virtualBackground; backgroundLock.unlock()
        guard let background, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPreviewTime = time
        let frame = CIImage(cvPixelBuffer: buffer)
        let composite = MarketingVirtualBackgroundRenderer.composite(frame: frame, background: background)
        guard let image = MarketingVirtualBackgroundRenderer.context.createCGImage(composite, from: composite.extent) else { return }
        DispatchQueue.main.async { self.segmentedPreview = image }
    }
}

final class MarketingCameraPreviewNSView: NSView {
    private weak var hosted: AVCaptureVideoPreviewLayer?

    /// A camera frame has its own pixel dimensions, but those dimensions must never
    /// become a sizing request for SwiftUI's surrounding NavigationSplitView. The
    /// container owns our size; the preview layer only paints inside it.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    /// Host the recorder's persistent preview layer. Pure CALayer geometry on the main
    /// thread — never touches the AVCaptureSession, so mounting/unmounting is always safe.
    func host(_ previewLayer: AVCaptureVideoPreviewLayer) {
        guard hosted !== previewLayer else { return }
        hosted?.removeFromSuperlayer()
        previewLayer.removeFromSuperlayer()   // in case another view hosted it
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        layer?.addSublayer(previewLayer)
        CATransaction.commit()
        hosted = previewLayer
    }
}

struct MarketingCameraPreview: NSViewRepresentable {
    let recorder: MarketingCameraRecorder

    // The recorder owns ONE preview layer, attached to the session once on the session
    // queue (see MarketingCameraRecorder.previewLayer). The view just hosts it, so
    // there is NO session mutation here at all — no main-thread deadlock, and no
    // AVError -11806 when the preview remounts on a Retake.
    func makeNSView(context: Context) -> MarketingCameraPreviewNSView {
        let view = MarketingCameraPreviewNSView()
        view.host(recorder.previewLayer)
        return view
    }

    func updateNSView(_ view: MarketingCameraPreviewNSView, context: Context) {
        view.host(recorder.previewLayer)
    }
}

struct MarketingRecordingPlayer: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url { view.player = AVPlayer(url: url) }
    }
}


struct CameraCapturePanel: View {
    @ObservedObject var recorder: MarketingCameraRecorder
    let format: ReelFormat
    let accentHex: UInt32
    let title: String
    let subtitle: String
    let onFinished: (URL) -> Void
    let onMessage: (String) -> Void
    let onError: (String) -> Void

    @State private var polishing = false
    @StateObject private var virtualSet = MarketingVirtualSetModel()
    @State private var cameraFraming: MarketingCameraFraming = .fillCrop
    @State private var showLowerTitle = false
    @StateObject private var prompter = TeleprompterModel()
    @State private var prompterOn = false
    @State private var prompterEditorOpen = false
    @State private var allowSilentTake = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black)
                if let url = recorder.lastRecordingURL, recorder.state == .recorded {
                    MarketingRecordingPlayer(url: url)
                } else if virtualSet.enabled, let image = recorder.segmentedPreview {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else if recorder.isLive || recorder.state == .preparing {
                    MarketingCameraPreview(recorder: recorder)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(BLTheme.goldText)
                        Text("Film without leaving Marketing").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text("Your camera and microphone stay local.").font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }

                if recorder.isLive {
                    framingGuide
                    VStack {
                        HStack {
                            Label(recorder.state == .recording ? "REC" : recorder.cameraName,
                                  systemImage: recorder.state == .recording ? "record.circle.fill" : "camera.fill")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(recorder.state == .recording ? .white : BLTheme.gold)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background((recorder.state == .recording ? Color.red : Color.black).opacity(0.78), in: Capsule())
                            Spacer()
                            Text(format.label.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 5).background(Color.black.opacity(0.65), in: Capsule())
                        }
                        Spacer()
                    }.padding(12)
                }

                // Teleprompter — a screen-side reading aid over the preview only.
                // The movie output records raw camera frames, so the script can
                // never be burned into the recording.
                if prompterOn && recorder.isLive {
                    TeleprompterOverlay(model: prompter) { prompterEditorOpen = true }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))

            MarketingVirtualSetEditor(model: virtualSet, canvasSize: format.size)

            VStack(alignment: .leading, spacing: 6) {
                Text("CAMERA FRAMING")
                    .font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.7)
                Picker("Camera framing", selection: $cameraFraming) {
                    ForEach(MarketingCameraFraming.allCases) { framing in
                        Text(framing.label).tag(framing)
                    }
                }
                .pickerStyle(.segmented)
                Text(cameraFraming.detail)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                Toggle("Show lower title", isOn: $showLowerTitle)
                    .toggleStyle(.switch)
                    .tint(BLTheme.gold)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Toggle("Prompter", isOn: $prompterOn)
                    .toggleStyle(.switch)
                    .tint(BLTheme.gold)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                if prompterOn {
                    GhostButton(label: "Edit script", icon: "square.and.pencil") { prompterEditorOpen = true }
                }
                Spacer(minLength: 0)
            }
            Text(showLowerTitle
                 ? "Adds the Reel Studio name and topic as a lower-third."
                 : "Off by default. The finished video keeps the page, speaker, border, and top Black Label mark only.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            if prompterOn {
                Text(prompter.hasScript
                     ? "The script scrolls over the preview and rolls automatically when recording starts. On screen only — never in the video."
                     : "Add a script — it scrolls over the preview while you record. On screen only — never in the video.")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                switch recorder.state {
                case .idle, .failed:
                    GoldButton(label: "Enable camera & mic", fill: true, icon: "video.fill") { recorder.requestAccessAndStart() }
                case .requestingAccess, .preparing:
                    ProgressView().controlSize(.small).tint(BLTheme.gold)
                    Text("Opening studio…").font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                case .ready:
                    GoldButton(label: "Start recording", fill: true, icon: "record.circle") {
                        allowSilentTake = false
                        recorder.startRecording()
                    }
                case .recording:
                    Button { recorder.stopRecording() } label: {
                        Label("Stop recording", systemImage: "stop.circle.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9).background(Color.red, in: Capsule())
                    }.buttonStyle(.plain)
                case .recorded:
                    GhostButton(label: "Retake", icon: "arrow.counterclockwise") {
                        allowSilentTake = false
                        recorder.startRecording()
                    }
                    GoldButton(label: polishing ? "Applying finish…" : "Polish & use as reel", fill: true,
                               icon: "wand.and.stars") { polishRecording() }
                        .disabled(polishing || (recorder.recordedAudio != .audible && !allowSilentTake))
                    GhostButton(label: "Save original", icon: "square.and.arrow.down") { saveOriginal() }
                }
            }

            if recorder.state == .recorded, recorder.recordedAudio != .audible {
                Toggle("Use this take as an intentionally silent clip", isOn: $allowSilentTake)
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).tint(BLTheme.gold)
                Text("Marketing detected no audible microphone samples. Polishing is blocked until you retake or explicitly approve silence.")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true)
            }

            if polishing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(BLTheme.gold)
                    Text(cameraFraming == .preserve
                         ? "Keeping every edge, styling, and exporting a polished .mp4…"
                         : "Keeping the subject large, styling, and exporting a polished .mp4…")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                }
            } else {
                Text(recorder.message).font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(recorder.state == .failed ||
                                     (recorder.state == .recorded && recorder.recordedAudio != .audible)
                                     ? BLTheme.danger : BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if recorder.state == .failed && (recorder.cameraNeedsSettings || recorder.microphoneNeedsSettings) {
                HStack(spacing: 8) {
                    if recorder.cameraNeedsSettings {
                        GhostButton(label: "Open Camera Settings", icon: "camera.fill") { recorder.openCameraSettings() }
                    }
                    if recorder.microphoneNeedsSettings {
                        GhostButton(label: "Open Microphone Settings", icon: "mic.fill") { recorder.openMicrophoneSettings() }
                    }
                }
            }

            HStack(spacing: 12) {
                Label("Auto focus + exposure", systemImage: "viewfinder")
                Label("Camera audio", systemImage: "waveform")
                Label(showLowerTitle
                      ? (cameraFraming == .preserve ? "Entire source + title" : "Readable crop + title")
                      : (cameraFraming == .preserve ? "Entire source · no lower title" : "Readable crop · no lower title"),
                      systemImage: "sparkles")
                if virtualSet.enabled { Label("Homepage virtual set", systemImage: "person.crop.rectangle") }
                if prompterOn { Label("Prompter on screen only", systemImage: "text.viewfinder") }
            }
            .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
        }
        .onAppear { recorder.setVirtualBackground(virtualSet.background) }
        .onReceive(virtualSet.objectWillChange) { _ in
            DispatchQueue.main.async { recorder.setVirtualBackground(virtualSet.background) }
        }
        .onChangeCompat(of: prompterOn) { on in
            if on {
                // Opening move: prefill from the newest AI reel plan when one exists,
                // then open the script editor if the buyer hasn't written anything yet.
                let wasEmpty = prompter.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                prompter.seedFromLatestPlanIfEmpty()
                if wasEmpty { prompterEditorOpen = true }
            } else {
                prompter.pause()
            }
        }
        .onChangeCompat(of: recorder.state) { state in
            guard prompterOn else { return }
            if state == .recording { prompter.restartFromTop() } else { prompter.pause() }
        }
        .sheet(isPresented: $prompterEditorOpen) {
            TeleprompterScriptEditor(model: prompter, brand: title, topic: subtitle)
        }
        .onDisappear { recorder.stopSession(); prompter.pause() }
    }

    private var framingGuide: some View {
        GeometryReader { proxy in
            let ratio = format.size.width / format.size.height
            let maxHeight = proxy.size.height * 0.82
            let maxWidth = proxy.size.width * 0.88
            let width = min(maxWidth, maxHeight * ratio)
            let height = min(maxHeight, maxWidth / ratio)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BLTheme.gold.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .frame(width: width, height: height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .overlay {
                    Path { path in
                        let x = (proxy.size.width - width) / 2
                        let y = (proxy.size.height - height) / 2
                        path.move(to: CGPoint(x: x, y: y + height / 3))
                        path.addLine(to: CGPoint(x: x + width, y: y + height / 3))
                        path.move(to: CGPoint(x: x, y: y + height * 2 / 3))
                        path.addLine(to: CGPoint(x: x + width, y: y + height * 2 / 3))
                    }.stroke(Color.white.opacity(0.2), lineWidth: 0.7)
                }
        }
        .allowsHitTesting(false)
    }

    private func polishRecording() {
        guard let source = recorder.lastRecordingURL else { return }
        polishing = true
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finish = MarketingRecordingFinish(
            format: format,
            accentHex: accentHex,
            title: cleanTitle.isEmpty ? "On camera" : cleanTitle,
            subtitle: subtitle,
            includeLowerThird: showLowerTitle,
            virtualBackground: virtualSet.background,
            framing: cameraFraming
        )
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("blm-finished-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        MarketingRecordingPolisher.polish(sourceURL: source, finish: finish, outputURL: output) { result in
            polishing = false
            switch result {
            case .success(let url):
                onFinished(url)
                onMessage("Recording polished into a branded \(format.label.lowercased()) .mp4 — ready to export or publish.")
            case .failure(let error):
                // A speech-permission denial gets the exact Settings pane opened for it (same
                // "Marketing opened System Settings" pattern as camera/microphone). The take
                // itself is untouched — polishing can be retried once the permission is granted.
                if case SpeechCaptionEngine.CaptionError.permissionDenied = error {
                    SpeechCaptionEngine.openSpeechRecognitionSettings()
                    onError("Speech recognition is blocked, so captions couldn't be transcribed. Marketing opened System Settings → Privacy & Security → Speech Recognition — enable it, then polish again. Your recording is untouched.")
                } else {
                    onError(error.localizedDescription)
                }
            }
        }
    }

    private func saveOriginal() {
        guard let source = recorder.lastRecordingURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.movie]
        panel.nameFieldStringValue = "marketing-camera-take.mov"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let destination = panel.url {
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                onMessage("Saved original camera take as \(destination.lastPathComponent).")
            } catch { onError("Couldn't save the original take: \(error.localizedDescription)") }
        }
    }
}
#endif
#endif // circuit-convert
