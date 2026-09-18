#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// CameraViews.swift — the WATCH wall: live camera tiles + what the house's
// machines are doing right now (Founder ask 2026-07-26: "an area where you can
// see cameras when you add them, you can monitor ac unit all yards").
//
// HONESTY ENVELOPE (§5.1) — what a camera can and cannot show here:
//   * HTTP snapshot / MJPEG  — played natively, live. Nearly every IP camera,
//     doorbell and ONVIF device exposes one of these.
//   * HLS (.m3u8)            — played natively via AVPlayer.
//   * RTSP                   — AVFoundation cannot play RTSP, and this product
//     ships no transcoder and buys no service. A camera that ONLY speaks RTSP
//     says so on its tile, with its URL ready to copy — it never shows a fake
//     "connecting…" spinner that will not resolve.
// A tile shows a real decoded frame or an honest reason it cannot; it never
// shows a placeholder image that could be mistaken for a live view.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(AVKit) && !CIRCUIT_WINDOWS_SIM
import AVKit
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Stream kinds

enum CameraStreamKind: String, Codable, CaseIterable, Identifiable {
    case snapshot   // still image URL, polled
    case mjpeg      // multipart/x-mixed-replace, continuous
    case hls        // .m3u8 via AVPlayer
    case rtsp       // not natively playable — honest state
    var id: String { rawValue }
    var label: String {
        switch self {
        case .snapshot: return "Snapshot"
        case .mjpeg: return "MJPEG"
        case .hls: return "HLS"
        case .rtsp: return "RTSP"
        }
    }
    /// Best-effort classification from the URL alone. Used to pre-fill the
    /// picker when the owner pastes a link; always user-overridable.
    static func infer(from url: String) -> CameraStreamKind {
        let u = url.lowercased()
        if u.hasPrefix("rtsp://") { return .rtsp }
        if u.contains(".m3u8") { return .hls }
        if u.contains("mjpg") || u.contains("mjpeg") || u.contains("video.cgi")
            || u.contains("stream") { return .mjpeg }
        return .snapshot
    }
}

/// Owner-entered camera feed config, stored beside the home state so it
/// survives restarts. Keyed by device id.
struct CameraFeedConfig: Codable, Equatable, Identifiable {
    var id: UUID                 // HFDevice.id
    var url: String
    var kind: CameraStreamKind
    var label: String
}

// MARK: - Feed engine

/// One camera's live pixels. Snapshot polls; MJPEG parses the multipart
/// boundary stream. Both publish decoded frames on the main actor, and both
/// publish an honest error string instead of silently showing nothing.
@MainActor
final class CameraFeed: ObservableObject {
    @Published var image: NSImage?
    @Published var error: String?
    @Published var fps: Double = 0

    private var task: Task<Void, Never>?
    private let cfg: CameraFeedConfig
    private var frameStamps: [Date] = []

    init(_ cfg: CameraFeedConfig) { self.cfg = cfg }

    func start() {
        guard task == nil, let url = URL(string: cfg.url) else {
            if URL(string: cfg.url) == nil { error = "That URL isn't valid" }
            return
        }
        switch cfg.kind {
        case .snapshot: task = Task { await self.pollSnapshots(url) }
        case .mjpeg:    task = Task { await self.readMJPEG(url) }
        case .hls, .rtsp: break      // handled by the view (AVPlayer / honest state)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func note(_ img: NSImage) {
        image = img
        error = nil
        let now = Date()
        frameStamps.append(now)
        frameStamps.removeAll { now.timeIntervalSince($0) > 4 }
        fps = Double(frameStamps.count) / 4.0
    }

    /// Poll a still-image endpoint. 2 fps is plenty for watching a driveway or
    /// an AC unit and stays kind to the camera's little web server.
    private func pollSnapshots(_ url: URL) async {
        let cfgSession = URLSessionConfiguration.ephemeral
        cfgSession.timeoutIntervalForRequest = 8
        cfgSession.urlCache = nil
        let session = URLSession(configuration: cfgSession)
        while !Task.isCancelled {
            do {
                var req = URLRequest(url: url)
                req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let (data, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                    error = "Camera returned HTTP \(http.statusCode)"
                } else if let img = NSImage(data: data) {
                    note(img)
                } else {
                    error = "That URL didn't return an image"
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// multipart/x-mixed-replace: frames separated by a boundary, each with its
    /// own headers. We scan for JPEG SOI/EOI markers, which is boundary-agnostic
    /// and survives the many cameras that get their own headers subtly wrong.
    private func readMJPEG(_ url: URL) async {
        let cfgSession = URLSessionConfiguration.ephemeral
        cfgSession.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfgSession)
        do {
            let (bytes, resp) = try await session.bytes(from: url)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                error = "Camera returned HTTP \(http.statusCode)"
                return
            }
            var buf = [UInt8]()
            buf.reserveCapacity(256 * 1024)
            var prev: UInt8 = 0
            var inFrame = false
            for try await b in bytes {
                if Task.isCancelled { return }
                if !inFrame {
                    if prev == 0xFF && b == 0xD8 {          // SOI
                        inFrame = true
                        buf.removeAll(keepingCapacity: true)
                        buf.append(0xFF); buf.append(0xD8)
                    }
                } else {
                    buf.append(b)
                    if prev == 0xFF && b == 0xD9 {          // EOI
                        inFrame = false
                        if let img = NSImage(data: Data(buf)) { note(img) }
                        if buf.count > 8 * 1024 * 1024 { buf.removeAll(keepingCapacity: true) }
                    }
                }
                prev = b
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

// MARK: - The wall

struct CamerasView: View {
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var engine: Engine

    @State private var configs: [CameraFeedConfig] = []
    @State private var editing: UUID? = nil
    @State private var draftURL = ""
    @State private var draftKind: CameraStreamKind = .snapshot
    @State private var focused: UUID? = nil

    private var cameras: [HFDevice] { store.state.devices.filter { $0.kind == .camera } }
    private var configURL: URL { VigilPaths.url("camera_feeds.json") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                machineStrip
                if cameras.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                              spacing: 12) {
                        ForEach(cameras) { cam in
                            CameraTile(device: cam,
                                       config: configs.first { $0.id == cam.id },
                                       isEditing: editing == cam.id,
                                       draftURL: $draftURL,
                                       draftKind: $draftKind,
                                       onEdit: { beginEdit(cam) },
                                       onSave: { saveEdit(cam) },
                                       onCancel: { editing = nil },
                                       onFocus: { focused = cam.id })
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(Palette.bg)
        .onAppear { configs = readConfigs() }
        .sheet(item: Binding(get: { focused.map { FocusID(id: $0) } },
                             set: { focused = $0?.id })) { f in
            if let cam = cameras.first(where: { $0.id == f.id }) {
                CameraFocusView(device: cam, config: configs.first { $0.id == cam.id }) {
                    focused = nil
                }
            }
        }
    }

    private struct FocusID: Identifiable { let id: UUID }

    private var header: some View {
        HStack(spacing: 10) {
            Text("WATCH").font(.system(size: 13, weight: .heavy)).tracking(2.2)
                .foregroundColor(Palette.goldTxt)
            Text("cameras you've added · what the house's machines are doing")
                .font(.system(size: 10)).foregroundColor(Palette.dim)
            Spacer()
            Text("\(cameras.count) camera\(cameras.count == 1 ? "" : "s")")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.dim)
        }
    }

    /// The AC / appliance half of the ask. These are the engine's OWN detections
    /// (hvac cycle onset across rooms, steam, appliance signatures) — no camera
    /// needed and nothing inferred beyond what the sensing layer already proved.
    private var machineStrip: some View {
        let events = engine.frame?.events ?? []
        let now = Date().timeIntervalSince1970
        let hvacOn = events.first { $0.kind.hasPrefix("hvac_cycle_on") }
        let hvacOff = events.first { $0.kind == "hvac_cycle_off" }
        let running = (hvacOn?.t ?? 0) > (hvacOff?.t ?? 0)
        let last = max(hvacOn?.t ?? 0, hvacOff?.t ?? 0)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AIR / HEAT").font(.system(size: 9, weight: .bold)).tracking(1.6)
                    .foregroundColor(Palette.dim)
                Text(last == 0 ? "not seen yet" : (running ? "RUNNING" : "off"))
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(running ? Color.green.opacity(0.9) : Palette.dim)
                Text(last == 0
                     ? "detected from correlated airflow across rooms"
                     : "last change \(Self.ago(now - last))")
                    .font(.system(size: 9)).foregroundColor(Palette.dim)
            }
            Divider().frame(height: 34).overlay(Palette.stroke)
            VStack(alignment: .leading, spacing: 3) {
                Text("APPLIANCES").font(.system(size: 9, weight: .bold)).tracking(1.6)
                    .foregroundColor(Palette.dim)
                let appliance = events.first { $0.kind.hasPrefix("appliance:") || $0.kind == "steam" }
                Text(appliance.map { $0.kind.replacingOccurrences(of: "appliance:", with: "").capitalized } ?? "quiet")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(appliance == nil ? Palette.dim : Palette.goldTxt)
                Text(appliance.map { "last seen \(Self.ago(now - $0.t))" } ?? "nothing running that we can hear")
                    .font(.system(size: 9)).foregroundColor(Palette.dim)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.055, green: 0.055, blue: 0.066)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.stroke, lineWidth: 1))
    }

    static func ago(_ s: Double) -> String {
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86_400)) d ago"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No cameras yet").font(.system(size: 15, weight: .bold))
                .foregroundColor(Palette.goldTxt)
            Text("""
                 Cameras you add in Rooms show up here. Vigil finds RTSP, ONVIF \
                 and Axis cameras on your network by itself — or add one by hand \
                 with its address. Point one at the AC unit or the yard and it \
                 lives on this wall.
                 """)
                .font(.system(size: 11)).foregroundColor(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text("Snapshot, MJPEG and HLS feeds play here directly. RTSP-only cameras can't be decoded without a transcoder, and Vigil says so on the tile rather than spinning forever.")
                .font(.system(size: 9)).foregroundColor(Palette.dim.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.055, green: 0.055, blue: 0.066)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.stroke, lineWidth: 1))
    }

    // MARK: config persistence

    private func readConfigs() -> [CameraFeedConfig] {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode([CameraFeedConfig].self, from: data)
        else { return [] }
        return decoded
    }

    private func writeConfigs(_ next: [CameraFeedConfig]) {
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let out = try? enc.encode(next) {
            try? out.write(to: configURL, options: .atomic)
            configs = next
        }
    }

    private func beginEdit(_ cam: HFDevice) {
        let existing = configs.first { $0.id == cam.id }
        // Pre-fill a sensible guess for a discovered camera: most expose a
        // snapshot on the usual paths. The owner still confirms it.
        draftURL = existing?.url ?? cam.host.map { "http://\($0)/snapshot.jpg" } ?? ""
        draftKind = existing?.kind ?? CameraStreamKind.infer(from: draftURL)
        editing = cam.id
    }

    private func saveEdit(_ cam: HFDevice) {
        let url = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = configs.filter { $0.id != cam.id }
        if !url.isEmpty {
            next.append(CameraFeedConfig(id: cam.id, url: url,
                                         kind: draftKind, label: cam.name))
        }
        writeConfigs(next)
        editing = nil
    }
}

// MARK: - One tile

private struct CameraTile: View {
    let device: HFDevice
    let config: CameraFeedConfig?
    let isEditing: Bool
    @Binding var draftURL: String
    @Binding var draftKind: CameraStreamKind
    let onEdit: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onFocus: () -> Void

    @StateObject private var feedHolder = FeedHolder()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(feedHolder.feed?.image != nil ? Color.green : Palette.dim)
                    .frame(width: 5, height: 5)
                Text(device.name).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.goldTxt).lineLimit(1)
                Spacer(minLength: 2)
                if let f = feedHolder.feed, f.fps > 0 {
                    Text(String(format: "%.1f fps", f.fps))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(Palette.dim)
                }
                Button(action: onEdit) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .bold)).foregroundColor(Palette.dim)
                }
                .buttonStyle(.plain)
                .help("Set this camera's stream address")
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55))
                content
            }
            .frame(height: 168)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { if config != nil { onFocus() } }

            if isEditing { editor }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.055, green: 0.055, blue: 0.066)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.stroke, lineWidth: 1))
        .onAppear { feedHolder.sync(config) }
        .onChange(of: config) { _, new in feedHolder.sync(new) }
        .onDisappear { feedHolder.sync(nil) }
    }

    @ViewBuilder private var content: some View {
        if config == nil {
            VStack(spacing: 5) {
                Image(systemName: "video.badge.plus")
                    .font(.system(size: 20)).foregroundColor(Palette.dim)
                Text("Add this camera's stream address")
                    .font(.system(size: 10)).foregroundColor(Palette.dim)
                if let h = device.host {
                    Text(h).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Palette.dim.opacity(0.8))
                }
            }
        } else if config?.kind == .rtsp {
            VStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18)).foregroundColor(Palette.goldDk)
                Text("RTSP can't be decoded here")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.goldDk)
                Text("Most cameras also serve a snapshot or MJPEG URL — use that one.")
                    .font(.system(size: 9)).foregroundColor(Palette.dim)
                    .multilineTextAlignment(.center).padding(.horizontal, 12)
            }
        } else if config?.kind == .hls {
            if let p = feedHolder.player {
                VideoPlayer(player: p)     // holder-owned: survives body re-evaluation
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 16)).foregroundColor(Palette.dim)
                    Text("That URL isn't valid").font(.system(size: 9)).foregroundColor(Palette.dim)
                }
            }
        } else if let img = feedHolder.feed?.image {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        } else if let err = feedHolder.feed?.error {
            VStack(spacing: 4) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 16)).foregroundColor(Palette.dim)
                Text(err).font(.system(size: 9)).foregroundColor(Palette.dim)
                    .multilineTextAlignment(.center).padding(.horizontal, 10).lineLimit(3)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("http://camera/snapshot.jpg", text: $draftURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .onChange(of: draftURL) { _, v in draftKind = CameraStreamKind.infer(from: v) }
            Picker("", selection: $draftKind) {
                ForEach(CameraStreamKind.allCases) { k in Text(k.label).tag(k) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 8) {
                Button("Save", action: onSave).buttonStyle(.borderedProminent).controlSize(.small)
                Button("Cancel", action: onCancel).buttonStyle(.bordered).controlSize(.small)
                Spacer()
            }
        }
    }

    /// Owns the feed's lifetime so a tile scrolling off screen stops its
    /// network work instead of hammering the camera forever. Also owns the HLS
    /// AVPlayer: the tile body re-evaluates at up to 10 Hz under the engine's
    /// republishes, so the player must be built ONCE per config here — an
    /// AVPlayer constructed inline in body is replaced unbuffered every pass
    /// and the stream can never start.
    @MainActor final class FeedHolder: ObservableObject {
        @Published var feed: CameraFeed?
        @Published var player: AVPlayer?
        private var current: CameraFeedConfig?
        func sync(_ cfg: CameraFeedConfig?) {
            guard cfg != current else { return }
            current = cfg
            feed?.stop(); feed = nil
            player?.pause(); player = nil
            guard let cfg else { return }
            switch cfg.kind {
            case .snapshot, .mjpeg:
                let f = CameraFeed(cfg)
                feed = f
                f.start()
            case .hls:
                if let u = URL(string: cfg.url) {
                    let p = AVPlayer(url: u)
                    p.play()
                    player = p
                }
            case .rtsp:
                break      // honest state rendered by the view; nothing to play
            }
        }
    }
}

// MARK: - Fullscreen

private struct CameraFocusView: View {
    let device: HFDevice
    let config: CameraFeedConfig?
    let onClose: () -> Void
    @StateObject private var holder = CameraTile.FeedHolder()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(device.name).font(.system(size: 15, weight: .heavy))
                    .foregroundColor(Palette.goldTxt)
                Spacer()
                Button("Close", action: onClose).buttonStyle(.bordered).controlSize(.small)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black)
                if config?.kind == .rtsp {
                    // Same honest state as the tile — a focus view must never show a
                    // "connecting…" that cannot resolve (this file's header rule).
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 22)).foregroundColor(Palette.goldDk)
                        Text("RTSP can't be decoded here")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldDk)
                        Text("Most cameras also serve a snapshot or MJPEG URL — use that one.")
                            .font(.system(size: 10)).foregroundColor(Palette.dim)
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                        if let u = config?.url {
                            Text(u).font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Palette.dim.opacity(0.85)).textSelection(.enabled)
                        }
                    }
                } else if config?.kind == .hls {
                    if let p = holder.player {
                        VideoPlayer(player: p)     // holder-owned: survives body re-evaluation
                    } else {
                        Text("That URL isn't valid").font(.system(size: 11)).foregroundColor(Palette.dim)
                    }
                } else if let img = holder.feed?.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text(holder.feed?.error ?? "connecting…")
                        .font(.system(size: 11)).foregroundColor(Palette.dim)
                }
            }
            .frame(minWidth: 640, minHeight: 400)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(16)
        .background(Palette.bg)
        .onAppear { holder.sync(config) }
        .onDisappear { holder.sync(nil) }
    }
}
#endif // circuit-convert
