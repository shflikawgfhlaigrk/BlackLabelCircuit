#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — native ScreenCaptureKit recording for Reel Studio.
// Captured pixels and audio stay on this Mac until the buyer exports or publishes.
#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import AVKit
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import CoreVideo
import UniformTypeIdentifiers

enum MarketingCaptureMode: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case screen = "Screen"
    case split = "You + Screen"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .camera: return "video.fill"
        case .screen: return "rectangle.inset.filled.and.person.filled"
        case .split: return "rectangle.split.2x1.fill"
        }
    }
}

struct MarketingScreenCaptureSource: Identifiable {
    enum Kind {
        case display(SCDisplay)
        case window(SCWindow)
    }

    let id: String
    let title: String
    let detail: String
    let kind: Kind

    var isDisplay: Bool {
        if case .display = kind { return true }
        return false
    }
}

enum MarketingScreenCaptureSizing {
    /// H.264 screen recordings stay inside a high-quality 4K envelope so a 5K/6K display does
    /// not make ScreenCaptureKit's recording output reject the stream.
    static func h264Size(contentRect: CGRect, pointPixelScale: CGFloat) -> CGSize {
        let rawWidth = max(2, contentRect.width * max(1, pointPixelScale))
        let rawHeight = max(2, contentRect.height * max(1, pointPixelScale))
        let longLimit: CGFloat = 3840
        let shortLimit: CGFloat = 2160
        let longEdge = max(rawWidth, rawHeight)
        let shortEdge = min(rawWidth, rawHeight)
        let scale = min(1, longLimit / longEdge, shortLimit / shortEdge)
        return CGSize(width: even(rawWidth * scale), height: even(rawHeight * scale))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        CGFloat(max(2, Int(value.rounded(.down)) / 2 * 2))
    }
}

@MainActor
final class MarketingScreenRecorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle, requestingAccess, loadingSources, ready, preparing, recording, finishing, recorded, failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var sources: [MarketingScreenCaptureSource] = []
    @Published var selectedSourceID = ""
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var lastRecordingDate: Date?
    @Published private(set) var elapsed = 0
    @Published private(set) var message = "Choose a display or app window. Screen pixels stay on this Mac."

    private var shareableContent: SCShareableContent?
    private var retainedSession: AnyObject?
    private var stopActiveSession: (() -> Void)?
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?

    var selectedSource: MarketingScreenCaptureSource? {
        sources.first { $0.id == selectedSourceID }
    }

    var screenNeedsSettings: Bool { !CGPreflightScreenCaptureAccess() }

    var microphoneNeedsSettings: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: return true
        default: return false
        }
    }

    var isRecording: Bool { state == .recording || state == .finishing }

    func prepareIfAuthorized() {
        guard #available(macOS 15.0, *) else {
            state = .failed
            message = "Native screen recording requires macOS 15 or newer."
            return
        }
        guard CGPreflightScreenCaptureAccess() else { return }
        refreshSources()
    }

    func requestAccessAndLoadSources() {
        guard #available(macOS 15.0, *) else {
            state = .failed
            message = "Native screen recording requires macOS 15 or newer."
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        state = .requestingAccess
        message = "Requesting Screen & System Audio Recording access…"
        let granted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        guard granted else {
            state = .failed
            message = "Screen recording is blocked. Marketing opened System Settings → Privacy & Security → Screen & System Audio Recording. Enable it, quit and reopen Marketing if macOS asks, then click Recheck access."
            openScreenSettings()
            return
        }
        refreshSources()
    }

    func refreshSources() {
        guard !isRecording else { return }
        guard CGPreflightScreenCaptureAccess() else {
            state = .failed
            message = "Screen recording access is not enabled yet."
            return
        }
        state = .loadingSources
        message = "Finding displays and app windows…"
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                apply(content)
            } catch {
                fail(permissionAwareMessage(for: error))
            }
        }
    }

    func startRecording(capturesSystemAudio: Bool, capturesMicrophone: Bool,
                        showsCursor: Bool, showMouseClicks: Bool) {
        guard #available(macOS 15.0, *) else {
            fail("Native screen recording requires macOS 15 or newer.")
            return
        }
        guard !isRecording else { return }
        guard CGPreflightScreenCaptureAccess() else {
            requestAccessAndLoadSources()
            return
        }
        guard let source = selectedSource, let content = shareableContent else {
            message = "Choose a display or app window first."
            refreshSources()
            return
        }

        state = .preparing
        lastRecordingURL = nil
        lastRecordingDate = nil
        elapsed = 0
        message = "Preparing \(source.title)…"

        Task {
            if capturesMicrophone {
                let microphoneGranted = await requestMicrophoneAccess()
                guard microphoneGranted else {
                    fail("Microphone access is blocked. Enable it in System Settings → Privacy & Security → Microphone, or turn off Include microphone.")
                    openMicrophoneSettings()
                    return
                }
            }

            do {
                let filter = contentFilter(for: source, content: content)
                blmScreenLog("startRecording: source=\(source.id) title=\(source.title) isDisplay=\(source.isDisplay) sysAudio=\(capturesSystemAudio) mic=\(capturesMicrophone)")
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("blm-screen-\(UUID().uuidString)")
                    .appendingPathExtension("mp4")
                let session = MarketingModernScreenCaptureSession(
                    filter: filter,
                    outputURL: output,
                    capturesSystemAudio: capturesSystemAudio,
                    capturesMicrophone: capturesMicrophone,
                    showsCursor: showsCursor,
                    showMouseClicks: showMouseClicks,
                    onStarted: { [weak self] in
                        Task { @MainActor in self?.recordingDidStart(sourceTitle: source.title) }
                    },
                    onFinished: { [weak self] url in
                        Task { @MainActor in self?.recordingDidFinish(url: url) }
                    },
                    onFailed: { [weak self] error in
                        Task { @MainActor in self?.fail(self?.permissionAwareMessage(for: error) ?? error.localizedDescription) }
                    }
                )
                retainedSession = session
                stopActiveSession = { [weak session] in
                    Task { await session?.stop() }
                }
                try await session.start()
            } catch {
                fail(permissionAwareMessage(for: error))
            }
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        state = .finishing
        message = "Finishing the screen recording…"
        stopElapsedTimer()
        stopActiveSession?()
    }

    func openScreenSettings() {
        openPrivacySettings("Privacy_ScreenCapture")
    }

    func openMicrophoneSettings() {
        openPrivacySettings("Privacy_Microphone")
    }

    private func apply(_ content: SCShareableContent) {
        shareableContent = content
        let currentBundleID = Bundle.main.bundleIdentifier
        let screenNames: [CGDirectDisplayID: String] = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                else { return nil }
                return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
            }
        )

        var nextSources = content.displays.enumerated().map { index, display in
            let title = screenNames[display.displayID] ?? "Display \(index + 1)"
            return MarketingScreenCaptureSource(
                id: "display-\(display.displayID)",
                title: title,
                detail: "\(display.width) × \(display.height) display · Marketing controls are excluded",
                kind: .display(display)
            )
        }

        let windows = content.windows
            .filter { window in
                guard window.isOnScreen, window.frame.width >= 320, window.frame.height >= 180,
                      let app = window.owningApplication else { return false }
                return app.bundleIdentifier != currentBundleID
            }
            .sorted {
                let left = "\($0.owningApplication?.applicationName ?? "") \($0.title ?? "")"
                let right = "\($1.owningApplication?.applicationName ?? "") \($1.title ?? "")"
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
            .prefix(80)

        nextSources.append(contentsOf: windows.map { window in
            let app = window.owningApplication?.applicationName ?? "App"
            let windowTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = windowTitle.isEmpty ? app : "\(app) — \(windowTitle)"
            return MarketingScreenCaptureSource(
                id: "window-\(window.windowID)",
                title: title,
                detail: "\(Int(window.frame.width)) × \(Int(window.frame.height)) app window",
                kind: .window(window)
            )
        })

        sources = nextSources
        if !sources.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = sources.first?.id ?? ""
        }
        if sources.isEmpty {
            fail("No recordable displays or app windows were found.")
        } else {
            state = lastRecordingURL == nil ? .ready : .recorded
            message = "Ready. Choose a source, then start recording."
        }
    }

    @available(macOS 15.0, *)
    private func contentFilter(for source: MarketingScreenCaptureSource,
                               content: SCShareableContent) -> SCContentFilter {
        switch source.kind {
        case .display(let display):
            // The app's own windows stay IN the capture: the flagship use is demoing
            // this app (Ace presenting the product + website in one You+Screen take).
            // Excluding them left a static desktop where the demo was happening.
            return SCContentFilter(display: display, excludingWindows: [])
        case .window(let window):
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    private func recordingDidStart(sourceTitle: String) {
        state = .recording
        message = "Recording \(sourceTitle) locally…"
        recordingStartedAt = Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.recordingStartedAt else { return }
                self.elapsed = max(0, Int(Date().timeIntervalSince(started).rounded(.down)))
            }
        }
    }

    private func recordingDidFinish(url: URL) {
        stopElapsedTimer()
        retainedSession = nil
        stopActiveSession = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("ScreenCaptureKit stopped without writing a movie.")
            return
        }
        lastRecordingURL = url
        lastRecordingDate = Date()
        state = .recorded
        message = "Screen recording ready. Review it, then polish or save the original."
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if let started = recordingStartedAt {
            elapsed = max(elapsed, Int(Date().timeIntervalSince(started).rounded()))
        }
        recordingStartedAt = nil
    }

    private func fail(_ text: String) {
        stopElapsedTimer()
        retainedSession = nil
        stopActiveSession = nil
        state = .failed
        message = text
    }

    private func permissionAwareMessage(for error: Error) -> String {
        if !CGPreflightScreenCaptureAccess() {
            return "Screen recording access is blocked. Enable Black Label Marketing in System Settings → Privacy & Security → Screen & System Audio Recording, quit and reopen Marketing if macOS asks, then click Recheck access."
        }
        return "Screen recording failed: \(error.localizedDescription)"
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Appends a timestamped line to the screen-capture diagnostic log. The OS
/// redacts SCK errors in the unified log (`<private>`), so the app records its
/// own start/stop/error trail here to make "stuck preparing" diagnosable.
func blmScreenLog(_ line: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BlackLabelMarketing", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
    let entry = "\(stamp) \(line)\n"
    let url = dir.appendingPathComponent("screen.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(entry.utf8))
        try? handle.close()
    } else {
        try? entry.data(using: .utf8)?.write(to: url)
    }
}

@available(macOS 15.0, *)
private final class MarketingModernScreenCaptureSession: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private let outputURL: URL
    private var stream: SCStream!
    private var recordingOutput: SCRecordingOutput!
    private let onStarted: () -> Void
    private let onFinished: (URL) -> Void
    private let onFailed: (Error) -> Void
    private let terminalLock = NSLock()
    private var terminalDelivered = false
    private var stopping = false
    private var didStartRecording = false
    private var startWatchdog: Task<Void, Never>?

    init(filter: SCContentFilter, outputURL: URL,
         capturesSystemAudio: Bool, capturesMicrophone: Bool,
         showsCursor: Bool, showMouseClicks: Bool,
         onStarted: @escaping () -> Void,
         onFinished: @escaping (URL) -> Void,
         onFailed: @escaping (Error) -> Void) {
        self.outputURL = outputURL
        self.onStarted = onStarted
        self.onFinished = onFinished
        self.onFailed = onFailed

        let info = SCShareableContent.info(for: filter)
        let outputSize = MarketingScreenCaptureSizing.h264Size(
            contentRect: info.contentRect,
            pointPixelScale: CGFloat(info.pointPixelScale)
        )
        let configuration = SCStreamConfiguration()
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // Do NOT set backgroundColor: on macOS 26, SCStreamConfiguration.copyWithZone
        // crashes (EXC_BREAKPOINT in CGColorCreateCopy/CFRetain) whenever a
        // backgroundColor has been assigned. The default is fine for our captures.
        configuration.showsCursor = showsCursor
        configuration.showMouseClicks = showMouseClicks
        configuration.capturesAudio = capturesSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = false
        configuration.captureMicrophone = capturesMicrophone

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.videoCodecType = .h264
        recordingConfiguration.outputFileType = .mp4
        super.init()
        self.recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    func start() async throws {
        try? FileManager.default.removeItem(at: outputURL)
        blmScreenLog("session.start: adding recording output")
        do {
            try stream.addRecordingOutput(recordingOutput)
        } catch {
            blmScreenLog("session.start: addRecordingOutput FAILED: \(error)")
            throw error
        }
        blmScreenLog("session.start: calling startCapture")
        // Arm the watchdog BEFORE startCapture. On macOS 26, a SECOND SCStream's
        // startCapture completion can NEVER fire — the whole call hangs — after a prior
        // take. If the watchdog were armed inside the completion (as before) a hung
        // startCapture would slip past it and leave the recorder stuck in .preparing
        // forever. Arming here catches BOTH a hung startCapture and a missing 1st frame.
        armStartWatchdog()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    blmScreenLog("session.start: startCapture ERROR: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    blmScreenLog("session.start: startCapture OK — capture is live, awaiting recordingOutputDidStartRecording")
                    continuation.resume()
                }
            }
        }
    }

    /// If the recording output does not begin writing within a few seconds — because
    /// startCapture hung or no frame ever arrived (the macOS 26 SCK wedge that hits the
    /// SECOND take after a good one) — reset the recorder with an actionable error
    /// instead of hanging forever. Delivers the failure FIRST so state resets even if
    /// the teardown itself blocks.
    private func armStartWatchdog() {
        startWatchdog?.cancel()
        startWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.terminalLock.lock()
            let started = self.didStartRecording
            self.terminalLock.unlock()
            guard !started else { return }
            blmScreenLog("session.start: WATCHDOG — screen capture never started within 6s (startCapture hung or no frames); resetting")
            self.deliverFailure(NSError(
                domain: "MarketingScreenCapture", code: -100,
                userInfo: [NSLocalizedDescriptionKey: "Screen capture didn't start — macOS ScreenCaptureKit wedged after a prior take. Quit and reopen Marketing, then record again."]))
            await self.stop()
        }
    }

    func stop() async {
        guard !stopping else { return }
        stopping = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stream.stopCapture { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            deliverFailure(error)
        }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        terminalLock.lock()
        didStartRecording = true
        terminalLock.unlock()
        startWatchdog?.cancel()
        blmScreenLog("recordingOutputDidStartRecording — screen is now recording")
        onStarted()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        blmScreenLog("recordingOutputDidFinishRecording — file written: \(outputURL.lastPathComponent)")
        terminalLock.lock()
        let shouldDeliver = !terminalDelivered
        terminalDelivered = true
        terminalLock.unlock()
        if shouldDeliver { onFinished(outputURL) }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        blmScreenLog("recordingOutput didFailWithError: \(error)")
        deliverFailure(error)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        blmScreenLog("stream didStopWithError (stopping=\(stopping)): \(error)")
        if !stopping { deliverFailure(error) }
    }

    private func deliverFailure(_ error: Error) {
        terminalLock.lock()
        let shouldDeliver = !terminalDelivered
        terminalDelivered = true
        terminalLock.unlock()
        if shouldDeliver { onFailed(error) }
    }
}

private struct MarketingScreenRecordingPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player = AVPlayer(url: url)
        }
    }
}

struct ScreenCapturePanel: View {
    @ObservedObject var recorder: MarketingScreenRecorder
    let format: ReelFormat
    let accentHex: UInt32
    let title: String
    let subtitle: String
    let onFinished: (URL) -> Void
    let onMessage: (String) -> Void
    let onError: (String) -> Void

    @State private var capturesSystemAudio = true
    @State private var capturesMicrophone = false
    @State private var showsCursor = true
    @State private var showMouseClicks = true
    @State private var framing: MarketingCameraFraming = .fillCrop
    @State private var showLowerTitle = false
    @State private var polishing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black)
                if let url = recorder.lastRecordingURL, recorder.state == .recorded {
                    MarketingScreenRecordingPlayer(url: url)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: recorder.state == .recording ? "record.circle.fill" : "rectangle.dashed")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(recorder.state == .recording
                                             ? AnyShapeStyle(Color.red)
                                             : AnyShapeStyle(BLTheme.goldText))
                        Text(recorder.state == .recording ? "Screen recording in progress" : "Record a display or app window")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(BLTheme.text)
                        Text(recorder.selectedSource?.title ?? "Marketing will ask which screen source to use.")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.sub)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                }

                if recorder.state == .recording || recorder.state == .finishing {
                    VStack {
                        HStack {
                            Label(recorder.state == .finishing ? "FINISHING" : "REC \(elapsedLabel)",
                                  systemImage: "record.circle.fill")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(Color.red.opacity(0.88), in: Capsule())
                            Spacer()
                            Text(format.label.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.black.opacity(0.65), in: Capsule())
                        }
                        Spacer()
                    }
                    .padding(12)
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))

            if !recorder.sources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("CAPTURE SOURCE")
                            .font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.7)
                        Spacer()
                        Button { recorder.refreshSources() } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(BLTheme.gold)
                        .disabled(recorder.isRecording)
                    }
                    Picker("Capture source", selection: $recorder.selectedSourceID) {
                        ForEach(recorder.sources) { source in
                            Label(source.title, systemImage: source.isDisplay ? "display" : "macwindow")
                                .tag(source.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(BLTheme.gold)
                    .disabled(recorder.isRecording)
                    Text(recorder.selectedSource?.detail ?? "")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(BLTheme.sub)
                }
            }

            HStack(spacing: 16) {
                Toggle("System audio", isOn: $capturesSystemAudio)
                Toggle("Microphone", isOn: $capturesMicrophone)
                Toggle("Cursor", isOn: $showsCursor)
                Toggle("Click rings", isOn: $showMouseClicks)
            }
            .toggleStyle(.switch)
            .tint(BLTheme.gold)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .disabled(recorder.isRecording)

            VStack(alignment: .leading, spacing: 6) {
                Text("SCREEN FRAMING")
                    .font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.7)
                Picker("Screen framing", selection: $framing) {
                    ForEach(MarketingCameraFraming.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text(framing.detail)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Show lower title", isOn: $showLowerTitle)
                .toggleStyle(.switch)
                .tint(BLTheme.gold)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .disabled(recorder.isRecording)

            HStack(spacing: 8) {
                switch recorder.state {
                case .idle, .failed:
                    GoldButton(label: recorder.screenNeedsSettings ? "Enable screen recording" : "Load screen sources",
                               fill: true, icon: "rectangle.dashed.badge.record") {
                        recorder.requestAccessAndLoadSources()
                    }
                case .requestingAccess, .loadingSources, .preparing:
                    ProgressView().controlSize(.small).tint(BLTheme.gold)
                    Text(recorder.state == .preparing ? "Starting capture…" : "Loading screen sources…")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.sub)
                case .ready:
                    GoldButton(label: "Start screen recording", fill: true, icon: "record.circle") {
                        startRecording()
                    }
                    .disabled(recorder.selectedSource == nil)
                case .recording:
                    Button { recorder.stopRecording() } label: {
                        Label("Stop recording", systemImage: "stop.circle.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Color.red, in: Capsule())
                    }
                    .buttonStyle(.plain)
                case .finishing:
                    ProgressView().controlSize(.small).tint(BLTheme.gold)
                    Text("Writing the .mp4…")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.sub)
                case .recorded:
                    GhostButton(label: "Retake", icon: "arrow.counterclockwise") { startRecording() }
                    GoldButton(label: polishing ? "Applying finish…" : "Polish & use as reel", fill: true,
                               icon: "wand.and.stars") { polishRecording() }
                        .disabled(polishing)
                    GhostButton(label: "Save original", icon: "square.and.arrow.down") { saveOriginal() }
                }
            }

            if polishing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(BLTheme.gold)
                    Text("Styling the screen recording and exporting a polished .mp4…")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.gold)
                }
            } else {
                Text(recorder.message)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(recorder.state == .failed ? BLTheme.danger : BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if recorder.state == .failed {
                HStack(spacing: 8) {
                    if recorder.screenNeedsSettings {
                        GhostButton(label: "Open Screen Recording Settings", icon: "gearshape.fill") {
                            recorder.openScreenSettings()
                        }
                    }
                    if capturesMicrophone && recorder.microphoneNeedsSettings {
                        GhostButton(label: "Open Microphone Settings", icon: "mic.fill") {
                            recorder.openMicrophoneSettings()
                        }
                    }
                    GhostButton(label: "Recheck access", icon: "arrow.clockwise") {
                        recorder.requestAccessAndLoadSources()
                    }
                }
            }

            HStack(spacing: 12) {
                Label("ScreenCaptureKit", systemImage: "display")
                if capturesSystemAudio { Label("System audio", systemImage: "speaker.wave.2.fill") }
                if capturesMicrophone { Label("Microphone", systemImage: "mic.fill") }
                Label(showsCursor ? "Cursor shown" : "Cursor hidden", systemImage: "cursorarrow")
                Label("Local .mp4", systemImage: "lock.fill")
            }
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundColor(BLTheme.sub)
        }
        .onAppear { recorder.prepareIfAuthorized() }
        .onDisappear {
            if recorder.state == .recording { recorder.stopRecording() }
        }
    }

    private var elapsedLabel: String {
        String(format: "%02d:%02d", recorder.elapsed / 60, recorder.elapsed % 60)
    }

    private func startRecording() {
        recorder.startRecording(
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            showsCursor: showsCursor,
            showMouseClicks: showMouseClicks
        )
    }

    private func polishRecording() {
        guard let source = recorder.lastRecordingURL else { return }
        polishing = true
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finish = MarketingRecordingFinish(
            format: format,
            accentHex: accentHex,
            title: cleanTitle.isEmpty ? "Screen recording" : cleanTitle,
            subtitle: subtitle,
            sourceLabel: "SCREEN RECORDING",
            includeLowerThird: showLowerTitle,
            framing: framing
        )
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("blm-screen-finished-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        MarketingRecordingPolisher.polish(sourceURL: source, finish: finish, outputURL: output) { result in
            polishing = false
            switch result {
            case .success(let url):
                onFinished(url)
                onMessage("Screen recording polished into a branded \(format.label.lowercased()) .mp4 — ready to export or publish.")
            case .failure(let error):
                // A speech-permission denial gets the exact Settings pane opened for it (same
                // "Marketing opened System Settings" pattern as microphone/screen recording).
                // The recording itself is untouched — polishing can be retried after granting.
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
        panel.allowedContentTypes = [.mpeg4Movie, .movie]
        panel.nameFieldStringValue = "marketing-screen-recording.mp4"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let destination = panel.url {
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                onMessage("Saved original screen recording as \(destination.lastPathComponent).")
            } catch {
                onError("Couldn't save the screen recording: \(error.localizedDescription)")
            }
        }
    }
}
#endif
#endif // circuit-convert
