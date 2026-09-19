#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Vigil — Black Label's WiFi-sensing smart-home hub.
//
// Centerpiece: a live 3D skeleton + presence radar + vitals driven by the
// WiFi-CSI sensing engine (clean-room Python port of WiFi-DensePose, MIT).
// Architected to grow into a full house hub: locks, speakers, cameras.
//
// This file compiles together with ../Shared/BLShell.swift (Palette, Card, etc.).

#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
import Foundation
#if canImport(SceneKit) && !CIRCUIT_WINDOWS_SIM
import SceneKit
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(CoreWLAN) && !CIRCUIT_WINDOWS_SIM
import CoreWLAN
#endif
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(Vision) && !CIRCUIT_WINDOWS_SIM
import Vision
#endif
#if canImport(simd) && !CIRCUIT_WINDOWS_SIM
import simd
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CircuitPortKit

private func homefrontSupportDirectory() -> URL {
    let fm = FileManager.default
    let override = ProcessInfo.processInfo.environment["HOMEFRONT_DATA_DIR"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let dir = override ?? base.appendingPathComponent("Homefront", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    return dir
}

private func homefrontLogURL(_ name: String) -> URL {
    homefrontSupportDirectory().appendingPathComponent(name)
}

private func homefrontLocalPort(_ environmentKey: String, default defaultPort: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[environmentKey],
          let value = Int(raw), (1...65_535).contains(value) else {
        return defaultPort
    }
    return value
}

private func readLogTail(_ url: URL, maxBytes: Int = 8192) -> String {
    guard let data = try? Data(contentsOf: url) else { return "" }
    let tail = data.count > maxBytes ? data.suffix(maxBytes) : data[...]
    return String(decoding: tail, as: UTF8.self)
}

// MARK: - Engine wire format

struct Keypoint: Decodable, Identifiable {
    let name: String
    let x: Double
    let y: Double
    let reliability: Double
    var id: String { name }
}

struct SensingFrame: Decodable {
    let tick: Int
    let source: String
    let live: Bool
    let model: String
    let model_pck50: Double
    let present: Bool
    let motion: Double
    let breathing_bpm: Double?
    let heart_bpm: Double?
    let breathing_strength: Double
    let heart_strength: Double
    let pose_ready: Bool
    let keypoints: [Keypoint]
    let edges: [[Int]]
    let range_profile: [Double]?
    let range_res_m: Double?
    let range_peak_m: Double?
    let range_strength: Double?
    let csi_connected: Bool?
    let csi_frames: Int?
    let csi_tier: String?       // advertised Vigil sensor tier ("Homefront-Sentry"…), if any
    let demo: Bool?             // true when the data is the synthetic replay/sim (vitals suppressed)
    // Vigil fleet (source=vigil): per-room links, occupant election, self-map
    let rooms: [String: RoomLink]?
    let occupant_room: String?
    let occupant_mode: String?  // "live" (excess now) | "holding" (still — belief held, dot doctrine)
    let events: [EngineEvent]?  // engine door/appliance/safety feed, newest first
    let map: HouseMap?
    let home: LearnedHome?      // F5 self-learned + self-labeled home
}

struct SentinelSnapshot: Decodable, Equatable {
    let ts: Double
    let uptimeS: Double
    let nodeCount: Int
    let onlineCount: Int
    let anyPresent: Bool
    let nodes: [SentinelNode]

    enum CodingKeys: String, CodingKey {
        case ts, nodes
        case uptimeS = "uptime_s"
        case nodeCount = "node_count"
        case onlineCount = "online_count"
        case anyPresent = "any_present"
    }
}

struct SentinelNode: Decodable, Identifiable, Equatable {
    let nodeID: String
    let room: String?
    let tier: String?
    let online: Bool
    let frames: Int
    let rssi: Int?
    let lastRxAgeS: Double?
    let present: Bool
    let moving: Bool
    let motion: Double
    let calibrated: Bool
    let calibrating: Double
    let breathingBPM: Double?
    let breathingConf: Int?
    let heartBPM: Double?
    let demo: Bool?
    let fall: SentinelFall?
    let movingNow: Bool?

    var id: String { nodeID }
    var sensorTier: SensorTier { SensorTier.recognize(tier) ?? .node }
    var real: Bool { demo != true }

    enum CodingKeys: String, CodingKey {
        case room, tier, online, frames, rssi, present, moving, motion, calibrated, calibrating, demo, fall
        case nodeID = "node_id"
        case lastRxAgeS = "last_rx_age_s"
        case breathingBPM = "breathing_bpm"
        case breathingConf = "breathing_conf"
        case heartBPM = "heart_bpm"
        case movingNow = "moving_now"
    }
}

struct SentinelFall: Decodable, Equatable {
    let state: String
    let alert: SentinelFallAlert?
    let lastMotionS: Double?
    let lastBreathS: Double?

    enum CodingKeys: String, CodingKey {
        case state, alert
        case lastMotionS = "last_motion_s"
        case lastBreathS = "last_breath_s"
    }
}

struct SentinelFallAlert: Decodable, Equatable {
    let kind: String?
    let message: String?
    let sinceS: Double?
    let acknowledged: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, message, acknowledged
        case sinceS = "since_s"
    }
}

// MARK: - Engine controller (spawns the Python sidecar + polls the stream)

@MainActor
final class Engine: ObservableObject {
    @Published var frame: SensingFrame?
    @Published var connected = false
    @Published var statusLine = "Starting sensing engine…"
    /// False when the Python host can't run (no interpreter / no numpy). The
    /// native sensors (sonar, camera, WiFi) still work without it; only the
    /// CSI/through-wall layer needs it. Drives an honest message instead of an
    /// endless "Connecting…".
    @Published var available = true
    /// Predictive eldercare state from the sidecar (:8799 /anomaly + /baseline),
    /// polled on a SLOW timer (anomalies are minutes-scale). nil until the first
    /// successful read; a decode failure degrades silently — never fabricated (§5.1).
    @Published var anomaly: AnomalyState?
    @Published var baseline: BaselineState?
    /// Eldercare fall/emergency state from the sidecar (:8799 /fall), polled on the
    /// same slow timer. nil until the first read; ships INACTIVE on the buyer's empty
    /// LAN and degrades silently on decode failure — never a fabricated state (§5.1).
    @Published var fallState: FallState?
    @Published var sentinel: SentinelSnapshot?

    // QA can select isolated loopback ports for a second, staged instance without
    // stopping the installed app. Production receives the historical defaults.
    private let port = homefrontLocalPort("VIGIL_ENGINE_PORT", default: 8799)
    private let sentinelPort = homefrontLocalPort("VIGIL_SENTINEL_PORT", default: 8790)
    private let sentinelCSIPort = homefrontLocalPort("VIGIL_SENTINEL_CSI_PORT", default: 5005)
    private let vigilFleetPort = homefrontLocalPort("VIGIL_FLEET_PORT", default: 5566)
    private var sentinelBaseURL: URL { URL(string: "http://127.0.0.1:\(sentinelPort)")! }
    private var task: Process?
    /// The Sentinel multi-node hub (UDP 5005 in → :8790 status), auto-spawned from the
    /// bundle when nothing is serving :8790 — "Start Sentinel" must not be a dead
    /// instruction on a buyer's Mac. One attempt per run; an externally-run Sentinel
    /// (dev launchd) keeps the port and wins, so doubles can't happen.
    private var hubTask: Process?
    private var hubSpawnAttempted = false
    private var timer: Timer?
    private var anomalyTimer: Timer?
    private var sentinelTimer: Timer?
    /// R7 (§5.1): when the last :8799 /frame poll SUCCEEDED. A frozen frame must not keep
    /// showing live vitals after the engine stops answering — see `FrameGate`.
    private var lastFrameAt = Date.distantPast
    /// R7c (§5.1): the CURRENT connection generation. Bumped on every teardown and every
    /// (re)connect — `stop()`, a sidecar spawn, a sidecar that exited. The time gate alone
    /// asks only "how recent"; a sidecar that dies and respawns inside `frameStale` would
    /// otherwise leave the previous connection's last frame both present and clock-fresh,
    /// rendering vitals from a process that no longer exists. Starts at 1 so the cold
    /// `frameGeneration` (0) can never match before a poll has ever succeeded.
    private var connectionGeneration: UInt64 = 1
    /// The connection generation that produced the frame currently held in `frame`.
    /// Stamped on every successful poll; never equal to `connectionGeneration` until a
    /// poll of THIS connection has landed.
    private var frameGeneration: UInt64 = 0
    private weak var store: HomeStore?
    // Presence→alarm ingest and the minute tick run in THIS engine's own poll loop
    // (main RunLoop), not in the window's view. Vigil keeps running in the menu bar
    // after the window closes, so view-scoped ingest would silently stop detecting
    // while the shield still shows "armed". sonarRef lets the poll OR in the Mac's
    // own acoustic presence without a view subscription.
    private weak var sonarRef: AcousticSonar?
    private var started = false
    private var minuteTimer: Timer?
    private var anomalyLatch = AnomalyLatch()
    private var fallLatch = FallLatch()
    /// Last time the 10 Hz display poll actually fetched+published a frame. Used to throttle the
    /// map's on-screen refresh to ~1 Hz while the app is NOT the active app (nobody is watching),
    /// so an idle/hidden window doesn't burn a core re-rendering the House Canvas. Display-only.
    private var lastDisplayPoll = Date.distantPast

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var sentinelOnlineNodes: [SentinelNode] { sentinel?.nodes.filter(\.online) ?? [] }
    var sentinelPresent: Bool { sentinel?.anyPresent ?? false }

    /// R7 (§5.1) render-time freshness gate for vitals views: `frame` only while a poll
    /// succeeded within `FrameGate.frameStale`, nil once stale. Belt-and-suspenders to
    /// `poll()`'s catch — a vitals view reads vitals through THIS so a frozen frame blanks
    /// even if the poll Timer was invalidated while the view stayed mounted.
    /// R7c: gated on provenance too — a frame stamped by a PREVIOUS connection generation
    /// reads nil even when its timestamp is inside `frameStale` (sidecar died + respawned,
    /// stop()/start(), any reconnect). Recency is not provenance.
    var liveFrame: SensingFrame? {
        FrameGate.liveFrame(frame, lastFrameAt: lastFrameAt, now: Date(),
                            frameGeneration: frameGeneration,
                            currentGeneration: connectionGeneration)
    }

    /// R7c (§5.1): end the current connection generation. Any frame still held was
    /// produced by the connection that just ended, so it is dead by identity: drop it,
    /// reset the liveness stamp, and bump the generation so a frame that arrives late
    /// from the OLD connection (an in-flight poll landing after teardown) can never be
    /// mistaken for live. Called on teardown AND on every (re)connect.
    private func invalidateConnection() {
        connectionGeneration &+= 1
        frame = nil
        lastFrameAt = .distantPast
        connected = false
    }

    func start(store: HomeStore? = nil, sonar: AcousticSonar? = nil) {
        // Idempotent: the window's onAppear may fire again after a close/reopen, but
        // sensing already runs for the app's lifetime — a second start() would spawn
        // duplicate poll timers. Refresh the collaborator refs and return.
        if let store { self.store = store }
        if let sonar { self.sonarRef = sonar }
        guard !started else { return }
        started = true
        // Clean shutdown on REAL app quit (not window close): terminate the child
        // sidecar/hub processes and invalidate timers. Replaces the old window-close
        // teardown, which wrongly killed sensing while the menu-bar app kept running.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        spawnSidecar()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        // Anomalies are minutes-scale: poll /anomaly + /baseline slowly so the dedup
        // burden stays low and the sidecar isn't hammered at the 0.1s frame cadence.
        anomalyTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { await self?.pollAnomaly() }
        }
        sentinelTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { await self?.pollSentinel() }
        }
        // Minute tick drives schedule-based automations + re-evaluates the arm/alarm
        // state machine. Lives here (not in the view) so it keeps ticking with the
        // window closed.
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let store = self?.store else { return }
                let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
                store.minuteTick((c.hour ?? 0) * 60 + (c.minute ?? 0))
            }
        }
        Task { await pollSentinel() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        anomalyTimer?.invalidate(); anomalyTimer = nil
        sentinelTimer?.invalidate(); sentinelTimer = nil
        minuteTimer?.invalidate(); minuteTimer = nil
        task?.terminate(); task = nil
        hubTask?.terminate(); hubTask = nil
        started = false
        // R7c (§5.1): the poll Timer is gone, so poll()'s catch will NEVER run to nil a
        // stale frame. Without this, a stop()/start() (or a menu-bar app whose window
        // reopens) inside frameStale re-shows the previous connection's last vitals as
        // live. End the generation explicitly instead of trusting a clock.
        invalidateConnection()
    }

    /// Feed presence + sensor liveness from a fresh /frame into the store. When a
    /// Sentinel node fleet exists, the sentinel poll owns presence (below) and this
    /// no-ops — mirrors the previous view logic exactly, but runs in the poll loop.
    private func ingestFrame(_ f: SensingFrame?) {
        guard let store else { return }
        // Monitor mode (VG-27 eldercare vitals watch) feeds off the primary sensing
        // frame's gate-passed vitals, independent of the Sentinel fleet. This is the
        // ONLY caller of stepVitalsMonitor — without it the caregiver "pages on an
        // abnormal vital" promise was never wired. No-ops unless enabled; a nil BPM
        // is a sensor gap and can never page (§5.1).
        store.stepVitalsMonitor(VitalsSample(present: f?.present ?? false,
                                             breathingBPM: f?.breathing_bpm,
                                             heartBPM: f?.heart_bpm))
        guard sentinel?.nodeCount ?? 0 == 0 else { return }
        store.ingestPresence(present: (f?.present ?? false) || (sonarRef?.present ?? false))
        if let f, f.csi_connected == true {
            store.upsertSensor(tier: SensorTier.recognize(f.csi_tier) ?? .node,
                               online: true, frames: f.csi_frames ?? 0)
        }
    }

    /// Feed presence + per-node liveness from a fresh Sentinel /nodes snapshot.
    private func ingestSentinel(_ snap: SentinelSnapshot?) {
        guard let store, let snap else { return }
        store.ingestPresence(present: snap.anyPresent || (sonarRef?.present ?? false))
        for node in snap.nodes where node.real {
            store.upsertSensor(tier: node.sensorTier, online: node.online, frames: node.frames)
        }
    }

    /// Interpreter for the Python engine processes, in priority order: the Python
    /// bundled inside the app (distribution builds ship a locked universal2
    /// Python+numpy+scipy runtime); the build.sh venv (dev machines); then the
    /// system python3. The bundle is preferred on both architectures so a buyer's
    /// unrelated user/site packages can never determine whether sensing boots.
    private func enginePython() -> String? {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let venvPy = support?.appendingPathComponent("Homefront/.venv/bin/python3").path
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("python/bin/python3").path
        let candidates = [bundled, venvPy, "/usr/bin/python3"].compactMap { $0 }
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) })
    }

    /// Python must treat the signed app bundle as immutable. State, cache, and
    /// temporary files all live in a private Application Support subtree (or the
    /// caller's HOMEFRONT_DATA_DIR test workspace). -B remains on argv as a second
    /// independent bytecode-write gate.
    private func pythonRuntimeEnvironment() -> [String: String] {
        let fm = FileManager.default
        let dataRoot = homefrontSupportDirectory()
        let runtimeRoot = dataRoot.appendingPathComponent("Runtime", isDirectory: true)
        let pycache = runtimeRoot.appendingPathComponent("python-cache", isDirectory: true)
        let cache = runtimeRoot.appendingPathComponent("cache", isDirectory: true)
        let temporary = runtimeRoot.appendingPathComponent("tmp", isDirectory: true)
        let sentinelData = dataRoot.appendingPathComponent("sentinel", isDirectory: true)
        for directory in [runtimeRoot, pycache, cache, temporary, sentinelData] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        var environment = ProcessInfo.processInfo.environment
        // Never allow a shell's Python configuration to inject host packages into
        // the bundled, version-locked runtime.
        environment.removeValue(forKey: "PYTHONHOME")
        environment.removeValue(forKey: "PYTHONPATH")
        environment["HOMEFRONT_DATA_DIR"] = dataRoot.path
        // sentinel.py historically defaulted to ~/.homefront and therefore
        // escaped HOMEFRONT_DATA_DIR during QA cold launches. Pin its legacy
        // HF_DATA surface under the same private workspace.
        environment["HF_DATA"] = sentinelData.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONPYCACHEPREFIX"] = pycache.path
        environment["XDG_CACHE_HOME"] = cache.path
        environment["TMPDIR"] = temporary.path
        return environment
    }

    /// Spawn the bundled Sentinel hub when :8790 answers nothing. Called from the
    /// pollSentinel failure path, ONCE per app run: if the spawn also fails the
    /// Sensors page keeps its honest "waiting for real ESP32 CSI" empty state —
    /// never a retry storm, never a fake "hub running" claim.
    private func spawnHubIfNeeded() {
        guard !hubSpawnAttempted, hubTask == nil else { return }
        hubSpawnAttempted = true
        guard let res = Bundle.main.resourceURL else { return }
        let script = res.appendingPathComponent("engine/sentinel.py")
        guard FileManager.default.fileExists(atPath: script.path),
              let py = enginePython() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        // Parity with the launchd/dev invocation. -B/PYTHONDONTWRITEBYTECODE: never
        // write .pyc into the signed bundle (codesign-seal fatal on a buyer's Mac).
        // Bind the app-spawned hub to loopback: the only client is this app (URLSession
        // to 127.0.0.1). Exposing it on the LAN is an explicit operator choice via
        // deploy/install_hub.sh (which also sets HOMEFRONT_TOKEN). Belt-and-suspenders
        // to the engine's own loopback default.
        p.arguments = ["-B", "-s", script.path, "--csi-port", "\(sentinelCSIPort)",
                       "--http-host", "127.0.0.1", "--http-port", "\(sentinelPort)"]
        p.currentDirectoryURL = res.appendingPathComponent("engine")
        p.environment = pythonRuntimeEnvironment()
        let outURL = homefrontLogURL("sentinel.out.log")
        let errURL = homefrontLogURL("sentinel.err.log")
        try? Data().write(to: outURL, options: .atomic)
        try? Data().write(to: errURL, options: .atomic)
        let outHandle = try? FileHandle(forWritingTo: outURL)
        let errHandle = try? FileHandle(forWritingTo: errURL)
        if let outHandle {
            p.standardOutput = outHandle
        } else {
            p.standardOutput = nil
        }
        if let errHandle {
            p.standardError = errHandle
        } else {
            p.standardError = nil
        }
        // A hub that dies (port already bound by an external Sentinel that raced us,
        // missing numpy on a venv host, …) just stays dead for this run — pollSentinel
        // keeps answering honestly from whatever IS serving :8790, or shows empty.
        p.terminationHandler = { [weak self] _ in
            if let outHandle { try? outHandle.close() }
            if let errHandle { try? errHandle.close() }
            Task { @MainActor in self?.hubTask = nil }
        }
        do { try p.run(); hubTask = p } catch { hubTask = nil }
    }

    private func spawnSidecar() {
        // R7c (§5.1): a NEW sidecar process is a NEW connection. Anything still held came
        // from the previous one and must not survive the respawn — a fresh process has a
        // fresh signal, and its predecessor's breathing_bpm is not evidence about it.
        invalidateConnection()
        guard let res = Bundle.main.resourceURL else { return }
        let engineDir = res.appendingPathComponent("engine")
        let script = engineDir.appendingPathComponent("home_engine.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            available = false
            // Error copy contract (what happened / what's preserved / next action).
            statusLine = "Sensing engine is missing from this copy of Vigil — through-wall sensing is off. Your rooms, devices and automations are untouched; native sensors still work. Reinstall Vigil to restore it."
            return
        }
        // Interpreter selection is shared with the Sentinel hub (enginePython()):
        // locked bundled universal2 Python → dev venv → system python3.
        guard let py = enginePython() else {
            available = false
            statusLine = "Through-wall engine needs a Python host — native sensors still work."
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        // -B + PYTHONDONTWRITEBYTECODE: the bundled interpreter must NEVER write
        // .pyc back into the signed, read-only app bundle. First-run bytecode
        // regeneration adds files under Resources/python/.../__pycache__, which
        // invalidates the codesign seal (Gatekeeper-fatal on a buyer's Mac).
        // Sentinel owns the real ESP32 ingress on UDP 5005. Keep this legacy
        // single-node sidecar off that port so the visible app cannot steal the
        // hardware stream or fall back to the old replay-oriented path.
        p.arguments = ["-B", "-s", script.path, "--source", "vigil",
                       "--port", "\(port)", "--vigil-port", "\(vigilFleetPort)", "--rate", "12"]
        p.currentDirectoryURL = engineDir
        p.environment = pythonRuntimeEnvironment()
        // Keep stderr visible for failure diagnosis without a pipe that can fill
        // and stall a noisy live sidecar.
        let errURL = homefrontLogURL("home_engine.err.log")
        try? Data().write(to: errURL, options: .atomic)
        let errHandle = try? FileHandle(forWritingTo: errURL)
        p.standardOutput = nil
        if let errHandle {
            p.standardError = errHandle
        } else {
            p.standardError = nil
        }
        p.terminationHandler = { [weak self] proc in
            if let errHandle { try? errHandle.close() }
            let err = readLogTail(errURL)
            Task { @MainActor in
                guard let self else { return }
                // R7c (§5.1): the process that produced every held frame has exited — the
                // connection is over regardless of HOW it exited (a clean status 0 exit is
                // just as dead as a crash). End the generation here so the last frame can
                // never be rendered as live during the window before the 0.1 s poll's catch
                // notices, or at all if that Timer is not running.
                self.invalidateConnection()
                guard proc.terminationStatus != 0 else { return }
                self.available = false
                if err.contains("ModuleNotFoundError") || err.lowercased().contains("numpy") {
                    self.statusLine = "Sensing engine needs numpy — see Sensors. Native sensors still work."
                } else if !err.isEmpty {
                    self.statusLine = "Sensing engine stopped. Native sensors still work."
                }
            }
        }
        do { try p.run(); task = p } catch {
            available = false
            // EBADARCH (arch-incompatible interpreter) or any other launch failure.
            // Error copy contract (what happened / what's preserved / next action).
            statusLine = "Couldn't launch the sensing engine — through-wall sensing is off. Your home setup is untouched; native sensors still work. Quit and reopen Vigil, or reinstall if this repeats."
        }
    }

    private func poll() async {
        // Display-only throttle (perf, §5.9 idle-CPU): this 10 Hz poll updates ONLY self.frame —
        // the live map + vitals shown on screen. When the app is not the active app, nobody is
        // watching, so refresh at ~1 Hz instead of 10 Hz; an idle/hidden window was re-rendering
        // the House Canvas ~12×/s regardless of focus (~a full core on a home with learned map
        // data). SAFETY-NEUTRAL: fall / anomaly / security alerting run on the independent 1 s /
        // 2 s timers (pollSentinel / pollAnomaly → store.logCritical), never on this poll. With
        // FrameGate.frameStale = 3 s, a ~1 Hz cadence keeps the frame displayable (no blank), and
        // the moment the app is reactivated the 10 Hz cadence resumes.
        if !NSApplication.shared.isActive, Date().timeIntervalSince(lastDisplayPoll) < 0.9 { return }
        lastDisplayPoll = Date()
        var req = URLRequest(url: baseURL.appendingPathComponent("frame"))
        req.timeoutInterval = 1.5
        // R7c: the generation this request belongs to. If the connection is invalidated
        // while the await is in flight, this reply is from the OLD engine — publishing it
        // would re-stamp a dead frame as live under the NEW generation.
        let generationAtRequest = connectionGeneration
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let f = try JSONDecoder().decode(SensingFrame.self, from: data)
            guard generationAtRequest == connectionGeneration else { return }
            self.frame = f
            self.lastFrameAt = Date()              // R7: stamp poll liveness for the staleness gate
            self.frameGeneration = generationAtRequest  // R7c: bind the frame to its connection
            self.connected = true
            self.available = true
            self.statusLine = f.live ? "Live sensing" : "Replay demo — not sensing this room"
            self.ingestFrame(f)                    // presence→alarm ingest (window-independent)
        } catch {
            self.connected = false
            // R7 (§5.1): the poll stopped succeeding (engine died / CSI unplugged / host
            // slept). Hold a single transient miss for anti-flicker, but once no frame has
            // arrived within frameStale, DROP the stale one so its breathing_bpm/heart_bpm/
            // csi_connected can't keep reading "live" — the vitals fall back to "—"/"no
            // signal" and the CSI view to "Waiting for a CSI reader" (§5.2 honest empty).
            if !FrameGate.isFresh(lastFrameAt: lastFrameAt, now: Date()) { self.frame = nil }
            // Don't override an honest "engine unavailable" reason with a hopeful
            // "connecting" that will never resolve.
            if available { self.statusLine = "Connecting to engine…" }
        }
    }

    private func pollSentinel() async {
        var req = URLRequest(url: sentinelBaseURL.appendingPathComponent("nodes"))
        req.timeoutInterval = 1.5
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            self.sentinel = try JSONDecoder().decode(SentinelSnapshot.self, from: data)
            self.ingestSentinel(self.sentinel)    // presence→alarm ingest (window-independent)
        } catch {
            self.sentinel = nil
            // Nothing serving :8790 → bring up the bundled hub (once per run) so the
            // Sensors onboarding is real on a buyer's Mac, not a dead instruction.
            spawnHubIfNeeded()
        }
    }

    /// Poll the predictive eldercare endpoints on the slow timer. /baseline drives
    /// the honest "learning night N of M" state; /anomaly is logged to History on
    /// TRANSITION ONLY (the sidecar latches one event per episode but this poll
    /// re-observes it — AnomalyLatch dedups so History isn't spammed, the GAP #D
    /// failure mode). Both degrade silently on decode failure — never fabricate (§5.1).
    private func pollAnomaly() async {
        var bReq = URLRequest(url: baseURL.appendingPathComponent("baseline"))
        bReq.timeoutInterval = 1.5
        if let (data, _) = try? await URLSession.shared.data(for: bReq),
           let b = try? JSONDecoder().decode(BaselineState.self, from: data) {
            self.baseline = b
        }
        // Eldercare fall/emergency: co-poll /fall on the same slow timer, BEFORE the
        // anomaly guard-return below so a failed anomaly decode can't starve the fall
        // surface. Logged on TRANSITION ONLY (FallLatch dedups the engine's latched
        // alert, same as the anomaly path). Decode failure degrades silently (§5.1).
        var fReq = URLRequest(url: baseURL.appendingPathComponent("fall"))
        fReq.timeoutInterval = 1.5
        if let (data, _) = try? await URLSession.shared.data(for: fReq),
           let f = try? JSONDecoder().decode(FallState.self, from: data) {
            self.fallState = f
            if fallLatch.shouldLog(f) { store?.logCritical(.fall, f.logMessage, resident: store?.state.soleResident()) }
        }
        var aReq = URLRequest(url: baseURL.appendingPathComponent("anomaly"))
        aReq.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: aReq),
              let a = try? JSONDecoder().decode(AnomalyState.self, from: data) else { return }
        self.anomaly = a
        if anomalyLatch.shouldLog(a) { store?.logCritical(.anomaly, a.logMessage, resident: store?.state.soleResident()) }
    }
}

// MARK: - Live WiFi sensor (CoreWLAN) — real, no-hardware RF anomaly detection

struct RFIrregularity: Identifiable {
    let id = UUID()
    let at: Date
    let kind: String        // "RSSI", "Noise", "Link"
    let magnitude: Double    // z-score
}

@MainActor
final class WiFiSensor: ObservableObject {
    @Published var ssid = "—"
    @Published var iface = "en0"
    @Published var rssi = 0
    @Published var noise = 0
    @Published var txRate = 0.0
    @Published var samples: [Double] = []       // recent RSSI, for the graph
    @Published var baselineMean = 0.0
    @Published var baselineStd = 0.0
    @Published var disturbance = 0.0            // 0..1 smoothed deviation
    @Published var irregular = false
    @Published var calibrating = true
    @Published var calibrationProgress = 0.0
    @Published var events: [RFIrregularity] = []
    @Published var irregularityCount = 0
    @Published var available = true

    private var fastEMA = 0.0, slowEMA = 0.0, activityEMA = 0.0, lastR = 0.0

    private let client = CWWiFiClient.shared()
    private var timer: Timer?
    private var ssidTimer: Timer?
    private let bufMax = 240                      // 24 s at 10 Hz
    private var sinceEvent = 0
    private var lastWifiLog = Date.distantPast

    private func wifiLog(_ s: String) {
        #if DEBUG
        // Dev telemetry ONLY. Never in release: this line carries live presence/RSSI
        // signals and /tmp is world-readable — any other local user/process could read
        // a resident's presence, contradicting Vigil's "nothing leaves your Mac" posture.
        let line = s + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/homefront_wifi.log"
        if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(data); try? fh.close() }
        else { try? line.write(toFile: path, atomically: false, encoding: .utf8) }
        #endif
    }

    var snr: Int { rssi - noise }

    func start() {
        // Idempotent: invalidate any prior timers first, so a re-entrant onAppear (lens re-shown)
        // never leaks a second 10 Hz sampler firing forever.
        timer?.invalidate(); ssidTimer?.invalidate()
        refreshSSID()
        ssidTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSSID() } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() } }
    }
    func stop() { timer?.invalidate(); timer = nil; ssidTimer?.invalidate(); ssidTimer = nil }

    func recalibrate() {
        calibrating = true; calibrationProgress = 0
        slowEMA = 0; fastEMA = 0; activityEMA = 0
        samples.removeAll(); events.removeAll(); irregularityCount = 0; disturbance = 0
    }

    private func sample() {
        guard let i = client.interface() else { available = false; return }
        available = true
        iface = i.interfaceName ?? "en0"
        let r = Double(i.rssiValue())
        let n = Double(i.noiseMeasurement())
        if r == 0 { return }                      // interface momentarily unavailable
        rssi = Int(r); noise = Int(n); txRate = i.transmitRate()

        samples.append(r); if samples.count > bufMax { samples.removeFirst() }

        // Self-calibrating fast-vs-slow EMA. This NEVER freezes: the slow average
        // is the room's quiet baseline, the fast average tracks the moment, and any
        // movement that perturbs RSSI spikes (fast - slow) or the instantaneous
        // rate-of-change. Detection runs forever; the count is monotonic.
        if slowEMA == 0 { slowEMA = r; fastEMA = r; lastR = r }
        let warm = samples.count < 40
        calibrationProgress = min(1.0, Double(samples.count) / 40.0)
        calibrating = warm

        fastEMA = 0.5 * fastEMA + 0.5 * r
        slowEMA = 0.02 * r + 0.98 * slowEMA
        let dRate = abs(r - lastR); lastR = r
        activityEMA = 0.7 * activityEMA + 0.3 * dRate

        // rolling baseline + std for the display band
        let recent = samples.suffix(80)
        let rm = recent.reduce(0, +) / Double(recent.count)
        baselineMean = slowEMA
        baselineStd = max(0.6, (recent.map { ($0 - rm) * ($0 - rm) }.reduce(0, +) / Double(recent.count)).squareRoot())

        let dev = abs(fastEMA - slowEMA)
        let score = dev + activityEMA * 0.8           // baseline shift + instantaneous motion
        disturbance = 0.55 * disturbance + 0.45 * min(1.0, score / 4.0)
        if Date().timeIntervalSince(lastWifiLog) > 0.5 {
            lastWifiLog = Date()
            wifiLog("rssi=\(rssi) fast=\(String(format: "%.1f", fastEMA)) slow=\(String(format: "%.1f", slowEMA)) dev=\(String(format: "%.2f", dev)) act=\(String(format: "%.2f", activityEMA)) score=\(String(format: "%.2f", score)) irr=\(irregular ? 1 : 0) cnt=\(irregularityCount) warm=\(warm ? 1 : 0)")
        }
        if warm { return }

        sinceEvent += 1
        if score > 1.6 && sinceEvent > 3 {
            irregular = true; sinceEvent = 0; irregularityCount += 1
            events.insert(RFIrregularity(at: Date(), kind: "RSSI", magnitude: score), at: 0)
            if events.count > 50 { events.removeLast() }   // display list capped; the COUNT is not
        } else if score < 0.7 {
            irregular = false
        }
    }

    private func refreshSSID() {
        // CoreWLAN ssid() needs Location auth on recent macOS; ipconfig does not.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        p.arguments = ["getsummary", iface]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = nil
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let out = String(data: data, encoding: .utf8) {
                for line in out.split(separator: "\n") where line.contains(" SSID :") {
                    ssid = line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ssid
                    break
                }
            }
        } catch { /* keep last */ }
    }
}

// MARK: - Live 3D body pose from the camera (Apple Vision) — real, no hardware

final class BodyPose3D: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var joints: [Int: SCNVector3] = [:]
    @Published var detected = false
    @Published var status = "Starting camera…"
    @Published var authorized = false
    @Published var fps = 0
    // rPPG heart rate (from forehead skin-color pulsation)
    @Published var heartBPM: Int? = nil
    @Published var heartStatus = "Face the camera to read your pulse"
    @Published var heartProgress = 0.0
    @Published var heartTrace: [Double] = []
    // diagnostics so we can see WHY a pulse does/doesn't lock
    @Published var faceFound = false
    @Published var hrSamples = 0
    @Published var hrSNR = 0.0
    @Published var hrRawBPM: Int? = nil

    // 17 joints in a fixed order; bones reference these indices.
    static let order: [VNHumanBodyPose3DObservation.JointName] = [
        .root, .spine, .centerShoulder, .centerHead, .topHead,
        .leftShoulder, .leftElbow, .leftWrist,
        .rightShoulder, .rightElbow, .rightWrist,
        .leftHip, .leftKnee, .leftAnkle,
        .rightHip, .rightKnee, .rightAnkle,
    ]
    static let bones: [(Int, Int)] = [
        (0,1),(1,2),(2,3),(3,4),
        (2,5),(5,6),(6,7),
        (2,8),(8,9),(9,10),
        (0,11),(11,12),(12,13),
        (0,14),(14,15),(15,16),
    ]

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "homefront.vision")
    // 2D pose request, NOT VNDetectHumanBodyPose3DRequest: the 3D detector
    // SEGFAULTS inside Apple's AltruisticBodyPoseKit on macOS 27
    // (Vigil-2026-07-03-031843.ips: abpk::Human::updateFromRawJointArray)
    // and a Vision crash kills the whole app ("can't even click on it" —
    // Founder-caught live). 2D is the mature pipeline; depth is flattened
    // and the UI says so.
    private let request = VNDetectHumanBodyPoseRequest()
    private let faceReq = VNDetectFaceRectanglesRequest()
    private var lastSeen = Date.distantPast
    private var frameCount = 0
    private var fpsStamp = Date()
    // rPPG buffers (timestamped forehead RGB means, for the POS algorithm)
    private var rppgT: [Double] = []
    private var rppgR: [Double] = []
    private var rppgG: [Double] = []
    private var rppgB: [Double] = []
    private var lastHR = Date.distantPast
    // BPM stabilizer (median + EMA + outlier reject + hold)
    private var bpmHist: [Int] = []
    private var bpmSmoothed = 0.0
    private var lastGoodBPM = Date.distantPast
    private var lastFaceSeen = Date.distantPast   // R4: when a face was last ACTUALLY in frame (§5.1 rPPG freshness gate)
    private var lastRawBPM: Int? = nil
    private var lastRawSNR = 0.0
    private var lastLog = Date.distantPast

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true; configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    self.authorized = ok
                    if ok { self.configure() } else { self.status = "Camera access denied" }
                }
            }
        default:
            status = "Camera access denied — System Settings ▸ Privacy ▸ Camera ▸ Vigil"
        }
    }

    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    private func configure() {
        queue.async {
            // Idempotent: build the input/output graph only once. A re-entrant start() (the pose
            // lens re-shown after stop()) must NOT re-add inputs — AVCaptureSession rejects a second
            // video input and the camera would fail to restart. On re-entry we only startRunning().
            if self.session.inputs.isEmpty {
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                    ?? AVCaptureDevice.default(for: .video)
                guard let device = dev, let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    DispatchQueue.main.async { self.status = "No camera available" }; return
                }
                self.session.addInput(input)
                let out = AVCaptureVideoDataOutput()
                out.alwaysDiscardsLateVideoFrames = true
                out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
                out.setSampleBufferDelegate(self, queue: self.queue)
                if self.session.canAddOutput(out) { self.session.addOutput(out) }
                self.session.commitConfiguration()
                // let AE/AWB settle, then lock them — slow brightness drift corrupts rPPG
                self.queue.asyncAfter(deadline: .now() + 1.8) {
                    try? device.lockForConfiguration()
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                    if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                    device.unlockForConfiguration()
                }
            }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.status = "Camera live — step into frame" }
        }
    }

    private func rppgLog(_ s: String) {
        #if DEBUG
        // Dev telemetry ONLY (logs live raw/stable heart BPM). Never in release —
        // world-readable /tmp would leak a resident's heart rate. See wifiLog.
        let line = s + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/homefront_rppg.log"
        if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(data); try? fh.close() }
        else { try? line.write(toFile: path, atomically: false, encoding: .utf8) }
        #endif
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        try? handler.perform([request, faceReq])

        // ---- rPPG heart rate from the forehead ----
        let faceBox = (faceReq.results?.first as? VNFaceObservation)?.boundingBox
        let hasFace = faceBox != nil
        let tsec = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if let face = faceBox,
           let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
           let rgb = foreheadRGB(pb, face), tsec.isFinite {
            rppgT.append(tsec); rppgR.append(rgb.0); rppgG.append(rgb.1); rppgB.append(rgb.2)
            while let f = rppgT.first, tsec - f > 14 {
                rppgT.removeFirst(); rppgR.removeFirst(); rppgG.removeFirst(); rppgB.removeFirst()
            }
        }
        let nowD = Date()
        if hasFace { lastFaceSeen = nowD }   // R4: stamp face presence for the rPPG display gate
        if nowD.timeIntervalSince(lastHR) > 0.35 {
            lastHR = nowD
            if let (bpm, snr) = estimateBPM() {
                lastRawBPM = bpm; lastRawSNR = snr
                if snr > 3.0 {                                   // whitened-peak confidence gate
                    let med0 = bpmHist.isEmpty ? bpm : bpmHist.sorted()[bpmHist.count/2]
                    if bpmHist.count < 2 || abs(bpm - med0) <= 14 {
                        bpmHist.append(bpm); if bpmHist.count > 8 { bpmHist.removeFirst() }
                    }
                    if bpmHist.count >= 2 {
                        let med = bpmHist.sorted()[bpmHist.count/2]
                        bpmSmoothed = bpmSmoothed == 0 ? Double(med) : 0.78*bpmSmoothed + 0.22*Double(med)
                        lastGoodBPM = nowD
                    }
                }
            }
        }
        // stable display value: held 4s after the last good lock (no flicker), AND only while a
        // face was actually just seen — a buffered lock must not outlive the face (R4, §5.1).
        let stableBPM: Int? = RPPGGate.displayBPM(smoothed: bpmSmoothed, lastGood: lastGoodBPM,
                                                  lastFace: lastFaceSeen, now: nowD)
        if bpmSmoothed > 0 && (nowD.timeIntervalSince(lastGoodBPM) >= 6
            || nowD.timeIntervalSince(lastFaceSeen) >= RPPGGate.faceStale) { bpmHist.removeAll(); bpmSmoothed = 0 }
        let span = (rppgT.last ?? 0) - (rppgT.first ?? 0)
        let prog = min(1.0, span / 9.0)
        let traceTail = Array(rppgG.suffix(120))
        let diagFace = hasFace, diagSamples = rppgT.count, diagSNR = lastRawSNR, diagRaw = lastRawBPM
        if nowD.timeIntervalSince(lastLog) > 0.5 {
            lastLog = nowD
            rppgLog("face=\(hasFace ? 1 : 0) n=\(rppgT.count) span=\(String(format: "%.1f", span)) snr=\(String(format: "%.2f", lastRawSNR)) raw=\(lastRawBPM.map(String.init) ?? "-") stable=\(stableBPM.map(String.init) ?? "-") hist=\(bpmHist)")
        }

        // ---- pose (2D landmarks -> scene space; depth flattened, see above) ----
        var pts: [Int: SCNVector3] = [:]
        if let obs = request.results?.first as? VNHumanBodyPoseObservation {
            func jp(_ j: VNHumanBodyPoseObservation.JointName) -> SCNVector3? {
                guard let r = try? obs.recognizedPoint(j), r.confidence > 0.25 else { return nil }
                return SCNVector3(Float(r.location.x - 0.5) * 2.2,
                                  Float(r.location.y - 0.5) * 2.2, 0)
            }
            let root = jp(.root), neck = jp(.neck), head = jp(.nose)
            let spine: SCNVector3? = (root != nil && neck != nil)
                ? SCNVector3((root!.x + neck!.x) / 2, (root!.y + neck!.y) / 2, 0) : nil
            let mapping: [Int: SCNVector3?] = [
                0: root, 1: spine, 2: neck, 3: head, 4: head,
                5: jp(.leftShoulder), 6: jp(.leftElbow), 7: jp(.leftWrist),
                8: jp(.rightShoulder), 9: jp(.rightElbow), 10: jp(.rightWrist),
                11: jp(.leftHip), 12: jp(.leftKnee), 13: jp(.leftAnkle),
                14: jp(.rightHip), 15: jp(.rightKnee), 16: jp(.rightAnkle),
            ]
            for (i, v) in mapping { if let v = v { pts[i] = v } }
        }
        frameCount += 1
        let elapsed = nowD.timeIntervalSince(fpsStamp)
        let f = elapsed >= 1 ? Int(Double(frameCount) / elapsed) : self.fps
        if elapsed >= 1 { frameCount = 0; fpsStamp = nowD }

        DispatchQueue.main.async {
            self.joints = pts; self.detected = !pts.isEmpty; self.fps = f
            if !pts.isEmpty { self.lastSeen = nowD }
            self.status = pts.isEmpty ? "No person in frame"
                : "Tracking \(pts.count) joints (2D pose — macOS 3D detector disabled: unstable)"
            self.heartProgress = prog
            self.heartTrace = traceTail
            self.faceFound = diagFace; self.hrSamples = diagSamples
            self.hrSNR = diagSNR; self.hrRawBPM = diagRaw
            if let b = stableBPM {
                self.heartBPM = b; self.heartStatus = "Live pulse"
            } else {
                self.heartBPM = nil
                if !diagFace { self.heartStatus = "No face detected — center your face, add light" }
                else if prog < 1 { self.heartStatus = "Measuring pulse… hold still (~10s)" }
                else { self.heartStatus = "Reading… hold still, steady light" }
            }
        }
    }

    /// Mean (R,G,B) over a forehead ROI (BGRA pixel buffer). Vision boundingBox is
    /// normalized with a bottom-left origin.
    private func foreheadRGB(_ pb: CVPixelBuffer, _ face: CGRect) -> (Double, Double, Double)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rb = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let cxN = face.midX
        let cyN = face.maxY - face.height * 0.12          // forehead band, just under hairline
        let px = Int(cxN * Double(w)), py = Int((1 - cyN) * Double(h))   // to top-left origin
        let hw = max(2, Int(face.width * 0.16 * Double(w))), hh = max(2, Int(face.height * 0.06 * Double(h)))
        let y0 = max(0, py - hh), y1 = min(h, py + hh)
        let x0 = max(0, px - hw), x1 = min(w, px + hw)
        if y0 >= y1 || x0 >= x1 { return nil }
        var sr = 0.0, sg = 0.0, sb = 0.0, cnt = 0
        for y in y0..<y1 {
            let row = y * rb
            for x in x0..<x1 {                              // BGRA
                let o = row + x*4
                sb += Double(ptr[o]); sg += Double(ptr[o+1]); sr += Double(ptr[o+2]); cnt += 1
            }
        }
        if cnt == 0 { return nil }
        return (sr/Double(cnt), sg/Double(cnt), sb/Double(cnt))
    }

    /// POS (Plane-Orthogonal-to-Skin, Wang 2017) pulse extraction + periodogram.
    /// Illumination-robust: normalizes RGB, projects onto a skin-orthogonal plane,
    /// high-passes slow drift, then finds the cardiac peak. Returns (BPM, SNR).
    private func estimateBPM() -> (Int, Double)? {
        let n = rppgG.count
        guard n >= 80, let t0 = rppgT.first, (rppgT.last! - t0) >= 8 else { return nil }
        let ts = rppgT.map { $0 - t0 }

        // temporal mean-normalize each channel (POS step 1)
        func norm(_ a: [Double]) -> [Double] { let m = a.reduce(0,+)/Double(n); return m > 1e-6 ? a.map { $0/m } : a }
        let rn = norm(rppgR), gn = norm(rppgG), bn = norm(rppgB)

        // POS projection
        var s1 = [Double](repeating: 0, count: n), s2 = [Double](repeating: 0, count: n)
        for i in 0..<n { s1[i] = gn[i] - bn[i]; s2[i] = gn[i] + bn[i] - 2*rn[i] }
        func std(_ a: [Double]) -> Double { let m = a.reduce(0,+)/Double(a.count); return (a.map{($0-m)*($0-m)}.reduce(0,+)/Double(a.count)).squareRoot() }
        let alpha = std(s2) > 1e-9 ? std(s1)/std(s2) : 1.0
        let sig = (0..<n).map { s1[$0] + alpha * s2[$0] }

        // Resample onto a uniform 30 Hz grid (frame timestamps are uneven).
        let fsU = 30.0
        let dur = ts.last!
        let m = Int(dur * fsU)
        guard m > 50 else { return nil }
        var u = [Double](repeating: 0, count: m)
        var j = 0
        for k in 0..<m {
            let tk = Double(k) / fsU
            while j < n - 1 && ts[j + 1] < tk { j += 1 }
            if j >= n - 1 { u[k] = sig[n - 1] }
            else { let f = (tk - ts[j]) / max(1e-6, ts[j + 1] - ts[j]); u[k] = sig[j] * (1 - f) + sig[j + 1] * f }
        }
        // High-pass (subtract ~1.0 s moving average) to kill breathing/exposure drift.
        let win = Int(fsU * 1.0)
        var hp = [Double](repeating: 0, count: m); var acc = 0.0
        for i in 0..<m {
            acc += u[i]; if i >= win { acc -= u[i - win] }
            let lo = i >= win ? acc / Double(win) : acc / Double(i + 1)
            hp[i] = u[i] - lo
        }
        let mu = hp.reduce(0, +) / Double(m); for i in 0..<m { hp[i] -= mu }
        let sd = (hp.map { $0 * $0 }.reduce(0, +) / Double(m)).squareRoot() + 1e-9
        for i in 0..<m { hp[i] /= sd }

        // Autocorrelation over plausible cardiac lags (0.8–2.5 Hz). The ACF peak is the
        // FUNDAMENTAL period — immune to the harmonic-doubling that read 112 bpm.
        let lagMin = Int(fsU / 2.5), lagMax = min(m - 1, Int(fsU / 0.8))
        guard lagMax > lagMin else { return nil }
        var acf = [Double](repeating: 0, count: lagMax + 1)
        for lag in lagMin...lagMax {
            var s = 0.0; for i in 0..<(m - lag) { s += hp[i] * hp[i + lag] }
            acf[lag] = s / Double(m - lag)
        }
        // Pick the strongest LOCAL maximum (the fundamental cardiac period), NOT the
        // global max — which sits at the shortest lag (high-freq noise) and read 150 bpm.
        var bestLag = -1, bestAcf = 0.0
        for lag in (lagMin + 1)..<lagMax {
            if acf[lag] > acf[lag - 1], acf[lag] >= acf[lag + 1], acf[lag] > bestAcf {
                bestAcf = acf[lag]; bestLag = lag
            }
        }
        guard bestLag > 0, bestAcf > 0.3 else { return nil }   // need a real periodic peak
        var lagF = Double(bestLag)
        if bestLag > lagMin && bestLag < lagMax {              // parabolic sub-sample peak
            let y0 = acf[bestLag - 1], y1 = acf[bestLag], y2 = acf[bestLag + 1]
            let den = y0 - 2 * y1 + y2
            if abs(den) > 1e-9 { lagF = Double(bestLag) + 0.5 * (y0 - y2) / den }
        }
        let bpm = 60.0 * fsU / lagF
        if bpm < 45 || bpm > 160 { return nil }
        return (Int(bpm.rounded()), bestAcf * 8.0)   // confidence; caller gates >3 (acf>0.375)
    }
}

struct LiveBody3DScene: NSViewRepresentable {
    var joints: [Int: SCNVector3]

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = context.coordinator.scene
        v.backgroundColor = NSColor(calibratedRed: 0.031, green: 0.031, blue: 0.039, alpha: 1)
        v.allowsCameraControl = true
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = true
        return v
    }
    func updateNSView(_ v: SCNView, context: Context) { context.coordinator.update(joints) }
    func makeCoordinator() -> Coord { Coord() }

    final class Coord {
        let scene = SCNScene()
        var spheres: [SCNNode] = []
        let bones = SCNNode()
        let gold = NSColor(calibratedRed: 0.851, green: 0.714, blue: 0.361, alpha: 1)

        init() {
            let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera?.fieldOfView = 45
            cam.position = SCNVector3(0, 0, 3.2); scene.rootNode.addChildNode(cam)
            let key = SCNNode(); key.light = SCNLight(); key.light?.type = .omni
            key.position = SCNVector3(2, 3, 4); scene.rootNode.addChildNode(key)
            let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient
            amb.light?.intensity = 240
            amb.light?.color = NSColor(calibratedRed: 0.18, green: 0.16, blue: 0.11, alpha: 1)
            scene.rootNode.addChildNode(amb)
            let floor = SCNFloor(); floor.reflectivity = 0.05
            floor.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)
            let fn = SCNNode(geometry: floor); fn.position = SCNVector3(0, -1.0, 0)
            scene.rootNode.addChildNode(fn)
            for _ in 0..<17 {
                let s = SCNSphere(radius: 0.05); s.firstMaterial?.diffuse.contents = gold
                s.firstMaterial?.emission.contents = gold
                let n = SCNNode(geometry: s); n.opacity = 0
                spheres.append(n); scene.rootNode.addChildNode(n)
            }
            scene.rootNode.addChildNode(bones)
        }

        func update(_ joints: [Int: SCNVector3]) {
            guard let root = joints[0] ?? joints.first?.value else {
                spheres.forEach { $0.opacity = 0 }; bones.childNodes.forEach { $0.removeFromParentNode() }; return
            }
            // center on root, scale & flip Y (Vision +Y is up; SceneKit +Y up too, but camera-relative needs flip on Z for orbit feel)
            func place(_ p: SCNVector3) -> SCNVector3 {
                SCNVector3((p.x - root.x) * 1.4, (p.y - root.y) * 1.4, (p.z - root.z) * 1.4)
            }
            for i in 0..<17 {
                if let p = joints[i] { spheres[i].position = place(p); spheres[i].opacity = 1 }
                else { spheres[i].opacity = 0 }
            }
            bones.childNodes.forEach { $0.removeFromParentNode() }
            for (a, b) in BodyPose3D.bones {
                guard let pa = joints[a], let pb = joints[b] else { continue }
                bones.addChildNode(cylinder(place(pa), place(pb)))
            }
        }

        private func cylinder(_ a: SCNVector3, _ b: SCNVector3) -> SCNNode {
            let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
            let len = max(0.0001, sqrt(dx*dx + dy*dy + dz*dz))
            let c = SCNCylinder(radius: 0.02, height: CGFloat(len))
            c.firstMaterial?.diffuse.contents = gold
            c.firstMaterial?.emission.contents = NSColor(calibratedRed: 0.5, green: 0.42, blue: 0.18, alpha: 1)
            let node = SCNNode(geometry: c)
            node.position = SCNVector3((a.x+b.x)/2, (a.y+b.y)/2, (a.z+b.z)/2)
            let up = simd_float3(0, 1, 0)
            let dir = simd_normalize(simd_float3(Float(dx), Float(dy), Float(dz)))
            let dot = simd_dot(up, dir)
            if dot < 0.9999 && dot > -0.9999 {
                let axis = simd_normalize(simd_cross(up, dir))
                let angle = acos(dot)
                node.rotation = SCNVector4(axis.x, axis.y, axis.z, angle)
            } else if dot <= -0.9999 {
                node.rotation = SCNVector4(1, 0, 0, Float.pi)
            }
            return node
        }
    }
}

struct PulseTrace: View {
    let samples: [Double]
    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 2 else { return }
            let w = size.width, h = size.height
            let lo = samples.min() ?? 0, hi = samples.max() ?? 1
            let span = max(1e-6, hi - lo)
            var p = Path(); let dx = w / CGFloat(samples.count - 1)
            for (i, v) in samples.enumerated() {
                let y = h - CGFloat((v - lo) / span) * h
                let pt = CGPoint(x: dx * CGFloat(i), y: y)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(Palette.gold), style: .init(lineWidth: 1.6, lineJoin: .round))
        }
    }
}

struct LiveBody3DView: View {
    @EnvironmentObject var body3d: BodyPose3D
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(body3d.detected ? Color.green : Palette.dim).frame(width: 8, height: 8)
                Text(body3d.status).font(.system(size: 12)).foregroundColor(Palette.goldTxt)
                Spacer()
                if body3d.detected { Text("\(body3d.fps) fps").font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.dim) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke))

            HStack(spacing: 14) {
                Card(title: "Live 3D Body", subtitle: "real-time pose from your camera · drag to orbit") {
                    ZStack {
                        LiveBody3DScene(joints: body3d.joints)
                            .frame(minHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke))
                        if !body3d.authorized {
                            VStack(spacing: 8) {
                                Image(systemName: "camera.fill").font(.system(size: 30)).foregroundColor(Palette.gold)
                                Text("Allow camera access to see your live 3D pose").foregroundColor(Palette.goldTxt)
                            }
                        } else if !body3d.detected {
                            Text("Step into the camera's view").font(.system(size: 13)).foregroundColor(Palette.dim)
                        }
                    }
                }
                heartCard.frame(width: 270)
            }
            Text("Real, live, on-device from your Mac camera (Apple Vision): 3D body pose + heart rate via rPPG (pulse from forehead skin-color change). Line-of-sight — pair with WiFi presence; a $9 CSI node adds through-wall.")
                .font(.system(size: 10)).foregroundColor(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .flashyBackground()
        // Perf: run the camera + Vision (VNDetectHumanBodyPose3DRequest) + ANE pipeline ONLY while
        // this lens is on screen. body3d is consumed by nothing else, so this changes no behavior —
        // the pose/heart view works identically when shown, and the multi-core spin is gone when it
        // is not. Also honours the app's "request camera auth at the Sense moment" design.
        .onAppear { body3d.start() }
        .onDisappear { body3d.stop() }
    }

    private var heartCard: some View {
        Card(title: "Heart Rate", subtitle: "camera pulse (rPPG) · on-device") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "heart.fill")
                        .foregroundColor(body3d.heartBPM != nil ? Palette.gold : Palette.dim)
                    // Accurate-or-nothing: only the gated, stabilized lock shows a number.
                    // No raw/approximate fallback — a marginal estimate is shown as "—".
                    if let bpm = body3d.heartBPM {
                        Text("\(bpm)").font(.system(size: 46, weight: .bold, design: .rounded)).foregroundColor(Palette.gold)
                    } else {
                        Text("—").font(.system(size: 46, weight: .bold, design: .rounded)).foregroundColor(Palette.dim)
                    }
                    Text("BPM").font(.system(size: 13)).foregroundColor(Palette.dim)
                }
                Text(body3d.heartStatus).font(.system(size: 11)).foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if body3d.heartBPM == nil {
                    ProgressView(value: body3d.heartProgress).tint(Palette.gold)
                }
                PulseTrace(samples: body3d.heartTrace).frame(height: 54)
                    .background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
                // live diagnostics
                Text("face \(body3d.faceFound ? "✓" : "✗")  ·  samples \(body3d.hrSamples)  ·  signal \(String(format: "%.1f", body3d.hrSNR))")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.dim)
            }
        }
    }
}

// MARK: - 3D skeleton (SceneKit)

struct SkeletonScene: NSViewRepresentable {
    var frame: SensingFrame?

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = context.coordinator.buildScene()
        v.backgroundColor = NSColor(calibratedRed: 0.031, green: 0.031, blue: 0.039, alpha: 1)
        v.allowsCameraControl = true
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = true
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        context.coordinator.update(frame: frame)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let scene = SCNScene()
        var joints: [SCNNode] = []
        var boneNode = SCNNode()
        var edges: [[Int]] = []
        let gold = NSColor(calibratedRed: 0.851, green: 0.714, blue: 0.361, alpha: 1)

        func buildScene() -> SCNScene {
            scene.background.contents = NSColor(calibratedRed: 0.031, green: 0.031, blue: 0.039, alpha: 1)

            // camera
            let cam = SCNNode(); cam.camera = SCNCamera()
            cam.camera?.fieldOfView = 42
            cam.position = SCNVector3(0, 0.1, 4.4)
            scene.rootNode.addChildNode(cam)

            // lights
            let key = SCNNode(); key.light = SCNLight(); key.light?.type = .omni
            key.light?.color = NSColor(calibratedRed: 1, green: 0.93, blue: 0.78, alpha: 1)
            key.position = SCNVector3(2, 3, 4); scene.rootNode.addChildNode(key)
            let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient
            amb.light?.intensity = 220
            amb.light?.color = NSColor(calibratedRed: 0.2, green: 0.18, blue: 0.12, alpha: 1)
            scene.rootNode.addChildNode(amb)

            // floor grid
            let floor = SCNFloor(); floor.reflectivity = 0.04
            floor.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.07, alpha: 1)
            let floorNode = SCNNode(geometry: floor)
            floorNode.position = SCNVector3(0, -1.7, 0)
            scene.rootNode.addChildNode(floorNode)

            // 17 joint spheres
            for i in 0..<17 {
                let s = SCNSphere(radius: 0.055)
                s.firstMaterial?.diffuse.contents = gold
                s.firstMaterial?.emission.contents = gold
                let n = SCNNode(geometry: s)
                n.opacity = 0
                joints.append(n); scene.rootNode.addChildNode(n)
                _ = i
            }
            scene.rootNode.addChildNode(boneNode)
            return scene
        }

        // map normalized (x,y in [0,1]) into scene space; (0,0)=top-left -> centered
        private func pos(_ kp: Keypoint) -> SCNVector3 {
            let sx = (kp.x - 0.5) * 2.6
            let sy = (0.5 - kp.y) * 3.0
            return SCNVector3(sx, sy, 0)
        }

        private var smoothPts: [SCNVector3] = []
        // Joints below this per-joint model reliability are NOISE for this
        // net (shipped PCK@50 0.185; left_ear reliability 0.03) — rendering
        // them at full strength fakes precision the model does not have.
        private let minReliability = 0.2

        func update(frame: SensingFrame?) {
            guard let f = frame, f.pose_ready, f.keypoints.count == 17 else {
                for n in joints { n.opacity = 0 }; boneNode.childNodes.forEach { $0.removeFromParentNode() }
                return
            }
            edges = f.edges
            let raw = f.keypoints.map { pos($0) }
            // EMA smoothing: the regressor jitters frame-to-frame far beyond
            // real body motion; a 0.7 hold reads as a body, not static.
            if smoothPts.count != raw.count { smoothPts = raw }
            for i in raw.indices {
                smoothPts[i] = SCNVector3(0.7 * smoothPts[i].x + 0.3 * raw[i].x,
                                          0.7 * smoothPts[i].y + 0.3 * raw[i].y,
                                          0.7 * smoothPts[i].z + 0.3 * raw[i].z)
            }
            let pts = smoothPts
            for (i, kp) in f.keypoints.enumerated() {
                joints[i].position = pts[i]
                if kp.reliability < minReliability {
                    joints[i].opacity = 0.06          // ghost, honestly faint
                    joints[i].scale = SCNVector3(0.5, 0.5, 0.5)
                    continue
                }
                let r = CGFloat(0.25 + kp.reliability)
                joints[i].opacity = min(1.0, r)
                joints[i].scale = SCNVector3(0.6 + r, 0.6 + r, 0.6 + r)
            }
            // bones only between joints the model actually trusts
            boneNode.childNodes.forEach { $0.removeFromParentNode() }
            for e in edges where e.count == 2
                && f.keypoints[e[0]].reliability >= minReliability
                && f.keypoints[e[1]].reliability >= minReliability {
                let a = pts[e[0]], b = pts[e[1]]
                boneNode.addChildNode(cylinder(from: a, to: b))
            }
        }

        private func cylinder(from a: SCNVector3, to b: SCNVector3) -> SCNNode {
            let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
            let len = max(0.0001, sqrt(dx*dx + dy*dy + dz*dz))
            let cyl = SCNCylinder(radius: 0.018, height: CGFloat(len))
            cyl.firstMaterial?.diffuse.contents = gold
            cyl.firstMaterial?.emission.contents = NSColor(calibratedRed: 0.5, green: 0.42, blue: 0.18, alpha: 1)
            let node = SCNNode(geometry: cyl)
            node.position = SCNVector3((a.x+b.x)/2, (a.y+b.y)/2, (a.z+b.z)/2)
            // orient +Y axis along (b-a)
            let up = SCNVector3(0, 1, 0)
            let dir = SCNVector3(dx/len, dy/len, dz/len)
            node.orientation = quaternion(from: up, to: dir)
            return node
        }

        // shortest-arc quaternion rotating `from` onto `to`
        private func quaternion(from: SCNVector3, to: SCNVector3) -> SCNQuaternion {
            let d = from.x*to.x + from.y*to.y + from.z*to.z
            if d > 0.99999 { return SCNQuaternion(0, 0, 0, 1) }
            if d < -0.99999 { return SCNQuaternion(1, 0, 0, 0) }
            let c = SCNVector3(from.y*to.z - from.z*to.y,
                               from.z*to.x - from.x*to.z,
                               from.x*to.y - from.y*to.x)
            let s = sqrt((1 + d) * 2)
            return SCNQuaternion(c.x/s, c.y/s, c.z/s, s/2)
        }
    }
}

// MARK: - Acoustic sonar (speaker + mic) — REAL room motion/presence/breathing, no hardware

final class AcousticSonar: NSObject, ObservableObject {
    enum Mode: String, CaseIterable { case cw = "Motion + Breathing", fmcw = "Range Map", radar = "Radar" }
    @Published var mode: Mode = .cw
    @Published var running = false
    @Published var status = "Tap Start — sense the room with sound"
    @Published var motion = 0.0
    @Published var present = false
    @Published var breathingBPM: Int? = nil
    @Published var trace: [Double] = []            // CW echo trace
    @Published var rangeProfile: [Double] = []     // FMCW echo energy per range bin
    @Published var nearestM: Double? = nil
    @Published var movProfile: [Double] = []       // radar: moving (clutter-cancelled) energy per range bin
    @Published var targetRange: Double? = nil
    @Published var targetApproaching = false       // Doppler sign at the target
    let maxRangeM = 5.0

    private let engine = AVAudioEngine()
    private var src: AVAudioSourceNode?
    private let lock = NSLock()
    private var logCount = 0
    private var motionEMA = 0.0
    private var phaseBuf: [Double] = [], tBuf: [Double] = []
    // R6 vitals-honesty: K-window persistence history for breathing (Hz); a null
    // window clears it so a transient can't carry a stale BPM forward (mirrors CSI _confirm).
    private var breathHist: [Double] = []
    private let breathPersistK = 3
    private var inSR = 48000.0
    // CW
    private let toneHz = 20000.0
    private var cwIdx = 0
    private var ampBuf: [Double] = []
    private var prevAmp = 0.0, prevPhase = 0.0
    // FMCW
    private let bins = 64
    private let maxBeat = 3000.0
    private var ref: [Float] = []
    private var nChirp = 1920
    private var win: [Float] = []
    private var bg: [Double] = []
    private var winCount = 0
    // Time-zero anchor: lag of the direct speaker→mic path inside the chop
    // window. Without it the dechirp reference is misaligned by IO latency
    // + an arbitrary buffer offset, so absolute range is biased and drifts
    // per session. Re-estimated every ~5 s; a material change clears the
    // breathing history (phase reference moved).
    private var alignLag = -1
    private var alignCountdown = 0
    // Dual accumulation per 8-chirp block: coherent complex (breathing phase
    // SNR ×√8 on slow targets) + incoherent magnitude (walkers decohere
    // across chirps — coherent-only would suppress the very mover we track).
    private let cohBlock = 8
    private var cohRe: [Double] = [], cohIm: [Double] = []
    private var magAcc: [Double] = []
    private var cohN = 0
    // Breathing bin is STICKY on the last MOVER: falling back to the
    // strongest static reflector read a wall's phase noise as breath.
    private var breathBin = -1
    // Radar (clutter-cancelled range-Doppler)
    private let radarR = 48, radarM = 24
    private var profilesRing: [[Double]] = []   // complex range profiles, each [2*radarR]

    private func sonarLog(_ s: String) {
        #if DEBUG
        // Dev telemetry ONLY (logs live range/motion/breathing). Never in release —
        // world-readable /tmp would leak a resident's presence/vitals. See wifiLog.
        let line = s + "\n"; guard let data = line.data(using: .utf8) else { return }
        let path = "/tmp/homefront_sonar.log"
        if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(data); try? fh.close() }
        else { try? line.write(toFile: path, atomically: false, encoding: .utf8) }
        #endif
    }

    func toggle() { running ? stop() : start() }
    func setMode(_ m: Mode) {
        guard m != mode else { return }
        let was = running; if was { stop() }; mode = m; if was { start() }
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                if ok { self.begin() } else { self.status = "Microphone access denied — System Settings ▸ Privacy ▸ Microphone" }
            }
        }
    }

    private func begin() {
        let out = engine.outputNode
        let sr = out.outputFormat(forBus: 0).sampleRate > 0 ? out.outputFormat(forBus: 0).sampleRate : 48000
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let input = engine.inputNode
        inSR = input.inputFormat(forBus: 0).sampleRate
        phaseBuf.removeAll(); tBuf.removeAll(); ampBuf.removeAll(); win.removeAll(); winCount = 0; cwIdx = 0; motionEMA = 0

        if mode == .cw {
            var ph = 0.0; let inc = 2 * Double.pi * toneHz / sr
            let node = AVAudioSourceNode { _, _, frameCount, abl in
                let bufs = UnsafeMutableAudioBufferListPointer(abl)
                for f in 0..<Int(frameCount) {
                    let v = Float(0.25 * sin(ph)); ph += inc; if ph > 2 * Double.pi { ph -= 2 * Double.pi }
                    for b in bufs { b.mData!.assumingMemoryBound(to: Float.self)[f] = v }
                }
                return noErr
            }
            src = node; engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: fmt)
            let w = 2 * Double.pi * toneHz / inSR
            input.installTap(onBus: 0, bufferSize: 4096, format: input.inputFormat(forBus: 0)) { [weak self] buf, _ in
                guard let self = self, let d = buf.floatChannelData?[0] else { return }
                let n = Int(buf.frameLength); var I = 0.0, Q = 0.0
                for i in 0..<n { let s = Double(d[i]); let a = w * Double(self.cwIdx + i); I += s * cos(a); Q += s * sin(a) }
                self.cwIdx += n
                self.processCW(amp: sqrt(I*I + Q*Q) / Double(n), phase: atan2(Q, I))
            }
        } else {
            nChirp = Int(sr * (mode == .radar ? 0.02 : 0.04))   // radar uses faster chirps
            profilesRing.removeAll()
            alignLag = -1; alignCountdown = 0; breathBin = -1
            cohRe = []; cohIm = []; magAcc = []; cohN = 0
            let f0 = 18000.0, f1 = 22000.0, T = Double(nChirp) / sr, k = (f1 - f0) / T
            ref = (0..<nChirp).map { i in let t = Double(i) / sr; return Float(sin(2 * .pi * (f0 * t + 0.5 * k * t * t))) }
            bg = [Double](repeating: 0, count: bins)
            var txIdx = 0
            let node = AVAudioSourceNode { [weak self] _, _, frameCount, abl in
                guard let self = self, !self.ref.isEmpty else { return noErr }
                let bufs = UnsafeMutableAudioBufferListPointer(abl)
                for f in 0..<Int(frameCount) { let v = self.ref[txIdx % self.nChirp] * 0.3; txIdx += 1; for b in bufs { b.mData!.assumingMemoryBound(to: Float.self)[f] = v } }
                return noErr
            }
            src = node; engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: fmt)
            input.installTap(onBus: 0, bufferSize: 2048, format: input.inputFormat(forBus: 0)) { [weak self] buf, _ in
                guard let self = self, let d = buf.floatChannelData?[0] else { return }
                for i in 0..<Int(buf.frameLength) {
                    self.win.append(d[i])
                    if self.win.count >= self.nChirp {
                        let w = self.win; self.win.removeAll(keepingCapacity: true)
                        self.mode == .radar ? self.onRadarChirp(w) : self.processFMCW(w)
                    }
                }
            }
        }
        do { try engine.start(); running = true; status = mode == .cw ? "Listening to the room…" : "Mapping the room…" }
        catch { status = "Audio error: \(error.localizedDescription)" }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        if let s = src { engine.detach(s); src = nil }
        running = false; status = "Stopped"; motion = 0; present = false; breathingBPM = nil; breathHist.removeAll()
        trace = []; rangeProfile = []; nearestM = nil
    }

    // CW: single-tone Doppler -> whole-room motion + breathing.
    private func processCW(amp: Double, phase: Double) {
        lock.lock()
        let now = Double(cwIdx) / inSR
        ampBuf.append(amp); phaseBuf.append(phase); tBuf.append(now)
        while let f = tBuf.first, now - f > 15 { ampBuf.removeFirst(); phaseBuf.removeFirst(); tBuf.removeFirst() }
        let dAmp = abs(amp - prevAmp) / (amp + 1e-6)
        var dPh = phase - prevPhase; while dPh > .pi { dPh -= 2 * .pi }; while dPh < -.pi { dPh += 2 * .pi }
        prevAmp = amp; prevPhase = phase
        motionEMA = 0.8 * motionEMA + 0.2 * min(1.0, dAmp * 3 + abs(dPh) * 0.8)
        let br: Int?
        if motionEMA < 0.08 && phaseBuf.count > 60 { br = breathing() } else { breathHist.removeAll(); br = nil }
        let traceTail = Array(ampBuf.suffix(140)); let mo = motionEMA
        logCount += 1
        if logCount % 5 == 0 { sonarLog("[cw] amp=\(String(format: "%.6f", amp)) motion=\(String(format: "%.3f", mo)) br=\(br.map(String.init) ?? "-")") }
        lock.unlock()
        DispatchQueue.main.async {
            self.motion = mo; self.present = mo > 0.05; self.breathingBPM = br; self.trace = traceTail
            self.status = self.present ? "Motion detected in the room" : "Room quiet"
        }
    }

    // Direct-path lag: decimated circular cross-correlation of the received
    // window against the reference chirp (coarse stride 4, full-res refine).
    // The strongest static correlation IS the speaker→mic direct path — the
    // one arrival guaranteed present in every room.
    private func estimateLag(_ w: [Float]) -> Int {
        let n = min(w.count, ref.count)
        guard n > 64 else { return 0 }
        var bestLag = 0, bestV = -Double.infinity
        var lag = 0
        while lag < n {
            var s = 0.0
            var i = 0
            while i < n { s += Double(w[(i + lag) % n]) * Double(ref[i]); i += 4 }
            if abs(s) > bestV { bestV = abs(s); bestLag = lag }
            lag += 4
        }
        var fineBest = bestLag, fineV = -Double.infinity
        for l in (bestLag - 3)...(bestLag + 3) {
            let ll = ((l % n) + n) % n
            var s = 0.0
            for i in 0..<n { s += Double(w[(i + ll) % n]) * Double(ref[i]) }
            if abs(s) > fineV { fineV = abs(s); fineBest = ll }
        }
        return fineBest
    }

    private func aligned(_ w: [Float]) -> [Float] {
        // TX is periodic, so a circular rotation puts the received chirp's
        // direct-path start at sample 0 -> beats become ABSOLUTE delays.
        if alignLag < 0 || alignCountdown <= 0 {
            let lag = estimateLag(w)
            if alignLag >= 0 && abs(lag - alignLag) > 8 {
                breathHist.removeAll(); phaseBuf.removeAll(); tBuf.removeAll()
            }
            alignLag = lag
            alignCountdown = 125            // re-anchor every ~5 s of chirps
        }
        alignCountdown -= 1
        let n = w.count
        guard alignLag > 0, n > 0 else { return w }
        let l = alignLag % n
        return Array(w[l...]) + Array(w[..<l])
    }

    // FMCW: time-zero-anchored dechirp -> echo energy vs ABSOLUTE distance.
    private func processFMCW(_ w0: [Float]) {
        lock.lock()
        let w = aligned(w0)
        let n = min(w.count, ref.count)
        if cohRe.count != bins {
            cohRe = [Double](repeating: 0, count: bins)
            cohIm = [Double](repeating: 0, count: bins)
            magAcc = [Double](repeating: 0, count: bins)
            cohN = 0
        }
        for kbin in 0..<bins {
            let fb = Double(kbin) * (maxBeat / Double(bins))
            var re = 0.0, im = 0.0
            for i in 0..<n { let dd = Double(w[i]) * Double(ref[i]); let a = 2 * .pi * fb * Double(i) / inSR; re += dd * cos(a); im += dd * sin(a) }
            cohRe[kbin] += re / Double(n)
            cohIm[kbin] += im / Double(n)
            magAcc[kbin] += sqrt(re * re + im * im) / Double(n)
        }
        cohN += 1
        winCount += 1
        guard cohN >= cohBlock else { lock.unlock(); return }
        // incoherent magnitude keeps walking energy; coherent phase below
        let mag = magAcc.map { $0 / Double(cohN) }
        var movSum = 0.0, mov = [Double](repeating: 0, count: bins)
        for b in 0..<bins { bg[b] = 0.9 * bg[b] + 0.1 * mag[b]; mov[b] = abs(mag[b] - bg[b]); movSum += mov[b] }
        motionEMA = 0.8 * motionEMA + 0.2 * min(1.0, movSum * 25)
        var movBin = 1, movMax = 0.0
        for b in 1..<bins { if mov[b] > movMax { movMax = mov[b]; movBin = b } }
        let hasMover = movMax > 0.0003
        if hasMover { breathBin = movBin }       // sticky: breath reads YOUR bin
        var nb = movBin
        if !hasMover {
            if breathBin >= 0 { nb = breathBin } // a still body is where it stopped
            else { var p = 0.0; for b in 1..<bins { if mag[b] > p { p = mag[b]; nb = b } } }
        }
        let nearM = Double(nb) * (maxRangeM / Double(bins))
        // breathing: COHERENT phase (×√block SNR on a slow chest) at the
        // sticky mover bin — never a static wall's phase noise.
        let now = Double(winCount) * (Double(nChirp) / inSR)
        if breathBin >= 0 {
            phaseBuf.append(atan2(cohIm[breathBin], cohRe[breathBin]))
            tBuf.append(now)
            while let f = tBuf.first, now - f > 15 { phaseBuf.removeFirst(); tBuf.removeFirst() }
        }
        for b in 0..<bins { cohRe[b] = 0; cohIm[b] = 0; magAcc[b] = 0 }
        cohN = 0
        let br: Int?
        if motionEMA < 0.1 && phaseBuf.count > 12 { br = breathing() } else { breathHist.removeAll(); br = nil }
        let mx = mag.max() ?? 1; let prof = mx > 0 ? mag.map { $0 / mx } : mag
        let mo = motionEMA
        logCount += 1
        if logCount % 3 == 0 {
            sonarLog("nearest=\(String(format: "%.2f", nearM))m lag=\(alignLag) motion=\(String(format: "%.3f", mo)) movSum=\(String(format: "%.4f", movSum)) br=\(br.map(String.init) ?? "-")")
        }
        lock.unlock()
        DispatchQueue.main.async {
            self.motion = mo; self.present = mo > 0.06; self.breathingBPM = br
            self.rangeProfile = prof; self.nearestM = nearM
            self.status = self.present ? "Motion at ~\(String(format: "%.1f", nearM)) m" : (self.running ? "Room mapped — still" : "Stopped")
        }
    }

    // Radar: collect a burst of complex range profiles, then clutter-cancel.
    private func onRadarChirp(_ w0: [Float]) {
        lock.lock()
        let w = aligned(w0)     // absolute time-zero for radar ranges too
        lock.unlock()
        let n = min(w.count, ref.count)
        var prof = [Double](repeating: 0, count: 2 * radarR)
        for k in 0..<radarR {
            let fb = Double(k) * (maxBeat / Double(radarR)); var re = 0.0, im = 0.0
            for i in 0..<n { let dd = Double(w[i]) * Double(ref[i]); let a = 2 * .pi * fb * Double(i) / inSR; re += dd * cos(a); im += dd * sin(a) }
            prof[2*k] = re / Double(n); prof[2*k+1] = im / Double(n)
        }
        lock.lock()
        profilesRing.append(prof); if profilesRing.count > radarM { profilesRing.removeFirst() }
        let ring = profilesRing.count == radarM ? profilesRing : []
        lock.unlock()
        if !ring.isEmpty { processRadar(ring) }
    }

    private func processRadar(_ ring: [[Double]]) {
        let M = ring.count, R = radarR
        var stat = [Double](repeating: 0, count: R), mov = [Double](repeating: 0, count: R)
        var tb = 2, tp = 0.0
        for k in 2..<R {
            var mr = 0.0, mi = 0.0; for p in ring { mr += p[2*k]; mi += p[2*k+1] }; mr /= Double(M); mi /= Double(M)
            stat[k] = sqrt(mr*mr + mi*mi)
            var v = 0.0; for p in ring { let dr = p[2*k]-mr, di = p[2*k+1]-mi; v += dr*dr + di*di }; mov[k] = sqrt(v / Double(M))
            if mov[k] > tp { tp = mov[k]; tb = k }
        }
        // Doppler sign at target = mean phase rotation of the residual across the burst
        var prevAng = 0.0, dsum = 0.0, first = true
        for p in ring {
            let ang = atan2(p[2*tb+1], p[2*tb])
            if !first { var dd = ang - prevAng; while dd > .pi { dd -= 2 * .pi }; while dd < -.pi { dd += 2 * .pi }; dsum += dd }
            prevAng = ang; first = false
        }
        let targetR = Double(tb) * (maxRangeM / Double(R))
        let movTot = mov.reduce(0, +), statTot = stat.reduce(0, +)
        let ratio = movTot / (statTot + 1e-9)
        let detected = ratio > 0.02 && tp > 0
        let smx = stat.max() ?? 1; let statN = smx > 0 ? stat.map { $0 / smx } : stat
        let mmx = mov.max() ?? 1; let movN = mmx > 0 ? mov.map { $0 / mmx } : mov
        motionEMA = 0.7 * motionEMA + 0.3 * min(1.0, ratio * 8)
        let mo = motionEMA, approaching = dsum < 0
        logCount += 1
        if logCount % 2 == 0 { sonarLog("[radar] target=\(String(format: "%.2f", targetR))m mov/stat=\(String(format: "%.3f", ratio)) motion=\(String(format: "%.3f", mo)) det=\(detected)") }
        DispatchQueue.main.async {
            self.rangeProfile = statN; self.movProfile = movN
            self.targetRange = detected ? targetR : nil; self.targetApproaching = approaching
            self.motion = mo; self.present = detected
            self.status = detected ? "Tracking \(approaching ? "approach" : "motion") @ \(String(format: "%.1f", targetR)) m" : (self.running ? "Room mapped — no movers" : "Stopped")
        }
    }

    // R6: per-window breathing candidate (Hz) with the three accuracy-or-nothing
    // guards a bare prominence gate lacked (mirrors engine/home_engine.py):
    //   R6.1  Hann window kills rectangular side-lobe leakage of sub-physiological
    //         drift (0.05-0.13 Hz) into the lowest in-band (0.15 Hz) bin;
    //   R6.3  the noise floor is the median of INDEPENDENT bins (step = 1/T true
    //         Rayleigh resolution) excluding the peak's neighbourhood -- the old
    //         0.01-Hz-oversampled median was deflated by correlated bins and
    //         cleared the gate on pure noise ~70% of the time;
    //   R5    a sub-physiological reference band [0.03,0.15) that, when the peak
    //         sits in the lowest in-band bin AND that band carries comparable-or-
    //         greater energy, rejects drift bleed as an honest null.
    // R6 breathing peak — pure DSP + accuracy-or-nothing guards extracted to
    // BreathingDSP (HomeCore.swift) so the §5.1 guards are unit-testable without a mic.
    private func breathingCandidate() -> Double? { BreathingDSP.peakHz(phase: phaseBuf, t: tBuf) }

    // R2 persistence: only publish a BPM after K consecutive windows agree within
    // tolerance; any null window clears the streak (a real breath persists, noise
    // and one-off drift artifacts do not).
    private func breathing() -> Int? {
        guard let f = breathingCandidate() else { breathHist.removeAll(); return nil }
        breathHist.append(f)
        if breathHist.count > breathPersistK { breathHist.removeFirst() }
        guard breathHist.count >= breathPersistK, let lo = breathHist.min(), let hi = breathHist.max(),
              hi - lo <= 0.06 else { return nil }
        let s = breathHist.sorted()
        return Int((s[s.count / 2] * 60).rounded())
    }
}

struct SonarScope: View {
    let profile: [Double]
    let maxRangeM: Double
    let nearestM: Double?
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            // range rings (every 1 m)
            for r in 1...max(1, Int(maxRangeM)) {
                let x = CGFloat(Double(r) / maxRangeM) * w
                var g = Path(); g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: h - 12))
                ctx.stroke(g, with: .color(Palette.stroke), style: .init(lineWidth: 1, dash: [3, 3]))
                ctx.draw(Text("\(r)m").font(.system(size: 9)).foregroundColor(Palette.dim), at: CGPoint(x: x, y: h - 5))
            }
            guard profile.count > 1 else { return }
            let dx = w / CGFloat(profile.count - 1)
            let top = h - 16
            var fill = Path(); fill.move(to: CGPoint(x: 0, y: top))
            for (i, v) in profile.enumerated() { fill.addLine(to: CGPoint(x: dx * CGFloat(i), y: top - CGFloat(v) * top * 0.9)) }
            fill.addLine(to: CGPoint(x: w, y: top)); fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [Palette.gold.opacity(0.55), Palette.gold.opacity(0.04)]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: top)))
            var line = Path()
            for (i, v) in profile.enumerated() { let pt = CGPoint(x: dx * CGFloat(i), y: top - CGFloat(v) * top * 0.9); if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) } }
            ctx.stroke(line, with: .color(Palette.gold), style: .init(lineWidth: 1.6, lineJoin: .round))
            if let nm = nearestM {
                let x = CGFloat(min(maxRangeM, nm) / maxRangeM) * w
                var mk = Path(); mk.move(to: CGPoint(x: x, y: 0)); mk.addLine(to: CGPoint(x: x, y: top))
                ctx.stroke(mk, with: .color(.green), style: .init(lineWidth: 2))
            }
        }
    }
}

struct RadarScope: View {
    let staticProfile: [Double]
    let movProfile: [Double]
    let maxRangeM: Double
    let targetM: Double?
    private let red = Color(red: 0.96, green: 0.45, blue: 0.22)
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, top = h - 16
            for r in 1...max(1, Int(maxRangeM)) {
                let x = CGFloat(Double(r) / maxRangeM) * w
                var g = Path(); g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: top))
                ctx.stroke(g, with: .color(Palette.stroke), style: .init(lineWidth: 1, dash: [3, 3]))
                ctx.draw(Text("\(r)m").font(.system(size: 9)).foregroundColor(Palette.dim), at: CGPoint(x: x, y: h - 5))
            }
            func curve(_ p: [Double]) -> Path {
                var path = Path(); guard p.count > 1 else { return path }
                let dx = w / CGFloat(p.count - 1)
                for (i, v) in p.enumerated() { let pt = CGPoint(x: dx * CGFloat(i), y: top - CGFloat(v) * top * 0.9); if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) } }
                return path
            }
            ctx.stroke(curve(staticProfile), with: .color(Palette.goldDk), style: .init(lineWidth: 1.2))   // room (static)
            ctx.stroke(curve(movProfile), with: .color(red), style: .init(lineWidth: 2, lineJoin: .round)) // you (moving)
            if let tm = targetM {
                let x = CGFloat(min(maxRangeM, tm) / maxRangeM) * w
                var mk = Path(); mk.move(to: CGPoint(x: x, y: 0)); mk.addLine(to: CGPoint(x: x, y: top))
                ctx.stroke(mk, with: .color(red), style: .init(lineWidth: 2))
            }
        }
    }
}

struct SonarView: View {
    @EnvironmentObject var sonar: AcousticSonar
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(sonar.running ? (sonar.present ? Palette.gold : Color.green) : Palette.dim).frame(width: 9, height: 9)
                Text(sonar.status).font(.system(size: 12)).foregroundColor(Palette.goldTxt)
                Spacer()
                Picker("", selection: Binding(get: { sonar.mode }, set: { sonar.setMode($0) })) {
                    ForEach(AcousticSonar.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 340)
                GoldButton(title: sonar.running ? "Stop" : "Start") { sonar.toggle() }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke))

            if sonar.mode == .fmcw {
                Card(title: "Room Sonar Map", subtitle: "FMCW chirp · echo energy vs distance · green = nearest reflector") {
                    SonarScope(profile: sonar.rangeProfile, maxRangeM: sonar.maxRangeM, nearestM: sonar.nearestM)
                        .frame(height: 200)
                        .background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.stroke))
                }
                HStack(spacing: 14) {
                    Card(title: "Motion", subtitle: "moving reflector") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(sonar.present ? "Moving @ \(sonar.nearestM.map { String(format: "%.1f m", $0) } ?? "—")" : (sonar.running ? "Room still" : "Sonar off"))
                                .font(.system(size: 14, weight: .semibold)).foregroundColor(sonar.present ? Palette.gold : Palette.dim)
                            ProgressView(value: min(1, sonar.motion)).tint(Palette.gold)
                            Text("motion \(Int(sonar.motion * 100))%").font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.dim)
                        }
                    }
                    Card(title: "Nearest", subtitle: "distance") {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(sonar.nearestM.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundColor(Palette.gold)
                            Text("m").font(.system(size: 12)).foregroundColor(Palette.dim)
                        }
                    }.frame(width: 130)
                    Card(title: "Breathing", subtitle: "hold still") {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(sonar.breathingBPM.map { "\($0)" } ?? "—").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundColor(sonar.breathingBPM != nil ? Palette.gold : Palette.dim)
                            Text("/min").font(.system(size: 11)).foregroundColor(Palette.dim)
                        }
                    }.frame(width: 130)
                }
                Text("FMCW Range Map: your Mac sweeps an inaudible 18–22 kHz chirp; the mic times the echoes to map reflectors by distance (gold curve) and flags the moving one (green). Real room ranging, no hardware. Line-of-sound — this room only.")
                    .font(.system(size: 10)).foregroundColor(Palette.dim).frame(maxWidth: .infinity, alignment: .leading)
            } else if sonar.mode == .radar {
                Card(title: "Room Radar", subtitle: "clutter-cancelled · gold = static room · red = you (moving)") {
                    RadarScope(staticProfile: sonar.rangeProfile, movProfile: sonar.movProfile, maxRangeM: sonar.maxRangeM, targetM: sonar.targetRange)
                        .frame(height: 200)
                        .background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.stroke))
                }
                HStack(spacing: 14) {
                    Card(title: "Moving target", subtitle: "Doppler-isolated from clutter") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(sonar.present ? "Mover @ \(sonar.targetRange.map { String(format: "%.1f m", $0) } ?? "—") · \(sonar.targetApproaching ? "approaching" : "receding")" : (sonar.running ? "No movers — static room" : "Radar off"))
                                .font(.system(size: 14, weight: .semibold)).foregroundColor(sonar.present ? Palette.gold : Palette.dim)
                            ProgressView(value: min(1, sonar.motion)).tint(Palette.gold)
                            Text("motion energy \(Int(sonar.motion * 100))%").font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.dim)
                        }
                    }
                    Card(title: "Distance", subtitle: "to mover") {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(sonar.targetRange.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundColor(Palette.gold)
                            Text("m").font(.system(size: 12)).foregroundColor(Palette.dim)
                        }
                    }.frame(width: 150)
                }
                Text("Radar (experimental — the far edge of acoustic sensing): bursts of chirps separate MOVING reflectors (you, red) from STATIC clutter (walls/desk, gold) by Doppler, and track the mover's distance. Acoustic velocity aliases, so it reports movement + range + approach/recede, not exact speed.")
                    .font(.system(size: 10)).foregroundColor(Palette.dim).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 14) {
                    Card(title: "Room Motion", subtitle: "20 kHz echo off your body · on-device") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(sonar.present ? "Someone is moving" : (sonar.running ? "Room is still" : "Sonar off"))
                                .font(.system(size: 15, weight: .semibold)).foregroundColor(sonar.present ? Palette.gold : Palette.dim)
                            ProgressView(value: min(1, sonar.motion)).tint(Palette.gold)
                            Text("motion \(Int(sonar.motion * 100))%").font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.dim)
                            PulseTrace(samples: sonar.trace).frame(height: 90)
                                .background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    Card(title: "Breathing", subtitle: "hold still to read · acoustic") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(sonar.breathingBPM.map { "\($0)" } ?? "—")
                                    .font(.system(size: 40, weight: .bold, design: .rounded))
                                    .foregroundColor(sonar.breathingBPM != nil ? Palette.gold : Palette.dim)
                                Text("/min").font(.system(size: 12)).foregroundColor(Palette.dim)
                            }
                            Text(sonar.breathingBPM != nil ? "chest motion from the echo" : "stay still a few seconds")
                                .font(.system(size: 10)).foregroundColor(Palette.dim)
                        }
                    }.frame(width: 220)
                }
                Text("CW Sonar: a single inaudible 20 kHz tone; motion shifts the echo so it senses the whole room (not just the camera's view), no hardware. Switch to Range Map for distance.")
                    .font(.system(size: 10)).foregroundColor(Palette.dim).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .flashyBackground()
    }
}

// MARK: - Live WiFi sensing view (real, no hardware)

struct RSSISparkline: View {
    let samples: [Double]
    let mean: Double
    let std: Double
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let lo = (samples.min() ?? -90) - 2, hi = (samples.max() ?? -30) + 2
            let span = max(1.0, hi - lo)
            func y(_ v: Double) -> CGFloat { h - CGFloat((v - lo) / span) * h }
            if std > 0 {
                let top = y(mean + 3*std), bot = y(mean - 3*std)
                ctx.fill(Path(CGRect(x: 0, y: top, width: w, height: max(1, bot - top))),
                         with: .color(Palette.gold.opacity(0.10)))
                var ml = Path(); ml.move(to: CGPoint(x: 0, y: y(mean))); ml.addLine(to: CGPoint(x: w, y: y(mean)))
                ctx.stroke(ml, with: .color(Palette.goldDk.opacity(0.7)), style: .init(lineWidth: 1, dash: [4, 3]))
            }
            if samples.count > 1 {
                var p = Path(); let dx = w / CGFloat(samples.count - 1)
                p.move(to: CGPoint(x: 0, y: y(samples[0])))
                for i in 1..<samples.count { p.addLine(to: CGPoint(x: dx * CGFloat(i), y: y(samples[i]))) }
                ctx.stroke(p, with: .color(Palette.gold), style: .init(lineWidth: 1.6, lineJoin: .round))
            }
        }
    }
}

struct LiveSenseView: View {
    @EnvironmentObject var wifi: WiFiSensor

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                Card(title: "Why this can't sense your motion", subtitle: "the honest limit") {
                    Text("Your Mac's WiFi only reports one number — signal strength (RSSI) — and it's integer-quantized to ±1 dBm, which is noise, not body motion (measured live: dead flat while you move). macOS also caches multi-AP scans, and hides the per-subcarrier CSI that *could* see motion. So WiFi-on-a-Mac is telemetry only. For real room motion use the Room Sonar tab; for through-wall, the CSI Reader tab + a $9 ESP32.")
                        .font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                }
                Card(title: "Live signal", subtitle: "real telemetry from your connection") {
                    RSSISparkline(samples: wifi.samples, mean: wifi.baselineMean, std: wifi.baselineStd)
                        .frame(height: 110)
                }
                statRow
            }.padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .flashyBackground()
        // Perf: the 10 Hz RSSI sampler runs ONLY while this lens is shown (wifi has no other
        // consumer), instead of firing for the whole app session.
        .onAppear { wifi.start() }
        .onDisappear { wifi.stop() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi").foregroundColor(Palette.gold)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sensing on \(wifi.ssid)").font(.system(size: 14, weight: .semibold)).foregroundColor(Palette.goldTxt)
                Text("interface \(wifi.iface) · \(Int(wifi.txRate)) Mbps link").font(.system(size: 10)).foregroundColor(Palette.dim)
            }
            Spacer()
            GhostButton(title: "Recalibrate") { wifi.recalibrate() }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke))
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            stat("RSSI", "\(wifi.rssi)", "dBm")
            stat("NOISE", "\(wifi.noise)", "dBm")
            stat("SNR", "\(wifi.snr)", "dB")
            stat("LINK", "\(Int(wifi.txRate))", "Mbps")
        }
    }
    private func stat(_ l: String, _ v: String, _ u: String) -> some View {
        VStack(spacing: 2) {
            Text(l).font(.system(size: 9, weight: .bold)).foregroundColor(Palette.dim)
            Text(v).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(Palette.gold)
            Text(u).font(.system(size: 9)).foregroundColor(Palette.dim)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke))
    }

}

// MARK: - Sensing dashboard

struct SensingView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 14) {
            banner
            HStack(spacing: 14) {
                Card(title: "Live Skeleton", subtitle: "WiFi-CSI 17-keypoint pose · drag to orbit") {
                    SkeletonScene(frame: engine.frame)
                        .frame(minHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke))
                }
                VStack(spacing: 14) {
                    presenceCard
                    vitalsCard
                }.frame(width: 280)
            }
            modelFootnote
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .flashyBackground()
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Circle().fill(engine.connected ? Color.green : Palette.dim).frame(width: 8, height: 8)
            Text(engine.statusLine).font(.system(size: 12)).foregroundColor(Palette.goldTxt)
            Spacer()
            if let f = engine.frame, !f.live {
                Text("REPLAY").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.goldInk).foregroundColor(Palette.gold)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke))
    }

    private var presenceCard: some View {
        Card(title: "Presence", subtitle: "motion energy from CSI") {
            let f = engine.frame
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(f?.present == true ? "Someone is present" : "Room appears empty")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(f?.present == true ? Palette.gold : Palette.dim)
                    Spacer()
                }
                let m = f?.motion ?? 0
                ProgressView(value: min(1, m)).tint(Palette.gold)
                Text("motion \(String(format: "%.0f", m * 100))%")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.dim)
            }
        }
    }

    private var vitalsCard: some View {
        Card(title: "Vitals", subtitle: "band-power · null until a real signal") {
            // R7 (§5.1) belt-and-suspenders: read vitals through the freshness gate on a
            // SwiftUI-driven 1 Hz clock so a frozen frame blanks even if the engine poll
            // Timer was invalidated while this view stayed mounted (the poll catch can't
            // re-nil it then). engine.liveFrame == nil once stale → vital(...) shows "—".
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let f = engine.liveFrame
                HStack(spacing: 18) {
                    vital("BREATH", f?.breathing_bpm, "br/min")
                    vital("HEART", f?.heart_bpm, "bpm")
                }
            }
        }
    }

    private func vital(_ label: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(Palette.dim)
            Text(value != nil ? String(format: "%.0f", value!) : "—")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(value != nil ? Palette.gold : Palette.dim)
            Text(value != nil ? unit : "no signal").font(.system(size: 10)).foregroundColor(Palette.dim)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelFootnote: some View {
        Text("Pose model: WiFi-DensePose pose_v1 (MIT, clean-room numpy port) · PCK@50 ≈ 18.5% — coarse torso pose, strongest at hips. Replay data demonstrates the pipeline; connect an ESP32-S3 CSI node for live through-wall sensing.")
            .font(.system(size: 10)).foregroundColor(Palette.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - CSI Reader (our own reader: live through-wall sensing from a streamed radio)

struct CSIReaderView: View {
    @EnvironmentObject var engine: Engine
    private var runsAppleSiliconSlice: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
    var body: some View {
        let snap = engine.sentinel
        let nodes = snap?.nodes.filter(\.real) ?? []
        let online = nodes.filter(\.online)
        // Scrolls like the sibling lenses: several streaming nodes stack the node
        // list + per-node motion rows past the window height, and a fixed VStack
        // would clip the lower cards and the source footnote unreachably.
        return ScrollView { VStack(spacing: 14) {
            if let notice = VigilPlatform.csiBoundaryMessage(isAppleSilicon: runsAppleSiliconSlice) {
                HStack(spacing: 10) {
                    Image(systemName: "cpu").foregroundColor(Palette.gold)
                    Text(notice)
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldTxt)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.gold.opacity(0.45)))
            }
            HStack(spacing: 10) {
                Circle().fill(online.isEmpty ? Palette.dim : Color.green).frame(width: 9, height: 9)
                Text(nodes.isEmpty ? "Waiting for real ESP32 Sentinel nodes on udp:5005"
                                   : "Real ESP32 Sentinel — \(online.count)/\(nodes.count) online · \(nodes.reduce(0) { $0 + $1.frames }) frames")
                    .font(.system(size: 12)).foregroundColor(Palette.goldTxt)
                Spacer()
                if !nodes.isEmpty { Text("REAL CSI").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.goldInk).foregroundColor(Palette.gold).clipShape(Capsule()) }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.stroke))

            if !nodes.isEmpty {
                HStack(spacing: 14) {
                    Card(title: "ESP32 Nodes", subtitle: "from Sentinel /nodes") {
                        VStack(spacing: 8) {
                            ForEach(nodes) { node in
                                sentinelNodeLine(node)
                            }
                        }
                    }
                    VStack(spacing: 14) {
                        Card(title: "Presence", subtitle: "from CSI") {
                            Text(snap?.anyPresent == true ? "Someone present" : "Room empty")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(snap?.anyPresent == true ? Palette.gold : Palette.dim)
                        }
                        Card(title: "Vitals", subtitle: "from live Sentinel nodes") {
                            let breath = online.compactMap(\.breathingBPM).first
                            let heart = online.compactMap(\.heartBPM).first
                            HStack(spacing: 16) {
                                vital("BREATH", breath, "br/min")
                                vital("HEART", heart, "bpm")
                            }
                        }
                        Card(title: "Motion", subtitle: "per-node live energy") {
                            VStack(spacing: 8) {
                                ForEach(nodes) { node in
                                    HStack {
                                        Text(node.sensorTier.productName).font(.system(size: 10)).foregroundColor(Palette.dim)
                                        Spacer()
                                        Text("\(Int(node.motion * 100))%").font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.goldTxt)
                                    }
                                    ProgressView(value: min(1, max(0, node.motion))).tint(Palette.gold)
                                }
                            }
                        }
                    }.frame(width: 230)
                }
            } else {
                Card(title: "Connect Sentinel", subtitle: "real ESP32 packets only") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 26)).foregroundColor(Palette.gold)
                            Text("Vigil runs the Sentinel hub for you (CSI in on UDP 5005, status on port 8790). Stream ESP32 CSI at this Mac and this screen fills from `/nodes`; replay/demo frames are not shown as real nodes.")
                                .font(.system(size: 12)).foregroundColor(Palette.goldTxt).fixedSize(horizontal: false, vertical: true)
                        }
                        Divider().background(Palette.stroke)
                        step("1", "Flash firmware/esp32_csi_homefront.ino onto any ESP32 (S3/C6/WROOM).")
                        step("2", "Set your WiFi + this Mac's IP (Terminal: ipconfig getifaddr en0).")
                        step("3", "It streams CSI to udp:5005; Sentinel exposes live status at http://127.0.0.1:8790/nodes.")
                    }
                }
            }
            Text("Source: Vigil Sentinel /nodes. Demo/replay frames are not counted as real ESP32 nodes.")
                .font(.system(size: 10)).foregroundColor(Palette.dim).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .flashyBackground()
    }

    private func sentinelNodeLine(_ node: SentinelNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: node.sensorTier.symbol).foregroundColor(node.online ? Palette.gold : Palette.dim).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.sensorTier.productName).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Text("\(node.nodeID) · \(node.frames) frames · RSSI \(node.rssi.map(String.init) ?? "—")")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.dim)
            }
            Spacer()
            Text(node.online ? "ONLINE" : "OFFLINE")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(node.online ? .green : Palette.dim)
        }
        .padding(9).background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func vital(_ l: String, _ v: Double?, _ u: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l).font(.system(size: 9, weight: .bold)).foregroundColor(Palette.dim)
            Text(v != nil ? String(format: "%.0f", v!) : "—").font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(v != nil ? Palette.gold : Palette.dim)
            Text(u).font(.system(size: 9)).foregroundColor(Palette.dim)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func step(_ n: String, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(.system(size: 11, weight: .bold)).foregroundColor(Palette.gold).frame(width: 14, alignment: .leading)
            Text(t).font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - App entry

/// Bundled user guides for the Help menu (Resources/guides, DOD-3.7/DOD-11.3).
/// Only guides present in THIS build are offered — a menu item for a missing
/// file would be a dead control (§5.8).
enum HelpGuides {
    static let items: [(title: String, file: String)] = [
        ("Vigil — First Run", "FIRST-RUN.md"),
        ("Vigil — Features", "FEATURES.md"),
        ("Vigil — Permissions", "PERMISSIONS.md"),
        ("Vigil — Sensor Integration", "INTEGRATION.md"),
        ("Vigil — Backup & Recovery", "RECOVERY.md"),
        ("Vigil — Uninstall", "UNINSTALL.md"),
    ]
    static func url(_ file: String) -> URL? {
        guard let u = Bundle.main.resourceURL?
            .appendingPathComponent("guides", isDirectory: true)
            .appendingPathComponent(file),
            FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }
    static var available: [(title: String, file: String)] {
        items.filter { url($0.file) != nil }
    }
    static func open(_ file: String) {
        if let u = url(file) { NSWorkspace.shared.open(u) }
    }
}

@main
struct VigilApp: App {
    /// The main WindowGroup's scene id — the menu bar's "Open Vigil" reopens the
    /// window through this after the user has closed it.
    static let mainWindowID = "vigil-main"
    @StateObject private var engine = Engine()
    @StateObject private var wifi = WiFiSensor()
    @StateObject private var body3d = BodyPose3D()
    @StateObject private var sonar = AcousticSonar()
    @StateObject private var store = HomeStore()
    @StateObject private var discovery = Discovery()
    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            AppRootView()
                .environmentObject(engine)
                .environmentObject(wifi)
                .environmentObject(body3d)
                .environmentObject(sonar)
                .environmentObject(store)
                .environmentObject(discovery)
                // Perf (§5.9 idle-CPU): the camera+Vision+ANE pose pipeline (body3d) and the
                // 10 Hz WiFi sampler (wifi) are started by their OWN lenses' onAppear (LiveBody3DView /
                // LiveSenseView), NOT globally — otherwise the camera + Vision run for the whole app
                // session regardless of which tab is shown, pegging multiple cores while idle. This
                // matches sonar, which is already user-toggled. The .stop() calls here stay as a
                // belt-and-suspenders teardown at window close (no-ops if already stopped).
                .onAppear { engine.start(store: store, sonar: sonar); discovery.start(); store.refreshNotifAuth() }
                // Deliberately NO teardown on window close: Vigil persists in the menu
                // bar (MenuBarExtra) with a live armed shield, so sensing/alarm/fall
                // detection MUST keep running when the window closes. engine.start() is
                // idempotent and the poll loop drives ingest independent of any view.
                // Full teardown happens on real app termination (willTerminate observer
                // registered in Engine.start()).
        }
        .windowStyle(.hiddenTitleBar)
        // Help menu → the guides bundled in Resources/guides (DOD-3.7/DOD-11.3).
        // Only guides present in this build appear; an empty Help menu on a
        // guide-less dev build is honest, a dead item would not be.
        .commands {
            CommandGroup(replacing: .help) {
                ForEach(HelpGuides.available, id: \.file) { guide in
                    Button(guide.title) { HelpGuides.open(guide.file) }
                }
            }
        }

        // Menu-bar quick controls: at-a-glance security mode + the current
        // MEASURED draw + one-tap favorites. The label reflects the armed state.
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
                .environmentObject(engine)
        } label: {
            Image(systemName: store.state.securityMode.symbol)
                .accessibilityLabel("Vigil security: \(store.state.securityMode.label)")
        }
        .menuBarExtraStyle(.window)
    }
}
#endif // circuit-convert
