#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// VigilHouseView — the flagship live surface: the house, as the fleet sees it.
//
// Renders the SELF-MEASURED map (mesh RSSI → MDS, engine /frame "map") with
// per-room live state (motion glow, presence), the occupant highlight, link
// lattice, vitals (accuracy-or-nothing: numbers only when the engine gates
// pass, "listening…" otherwise) and the fall-monitor state. Everything shown
// here is a live measurement from the ESP32 fleet — no demo data exists in
// this path (shipped default source = vigil).
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tracks whether THIS app is the frontmost-focused application. macOS SwiftUI `scenePhase`
/// does NOT leave `.active` when the app merely loses focus (only when its window is closed or
/// minimized) — so a `scenePhase`-only pause lets the live House map's TimelineView(.animation)
/// keep redrawing at full rate while the app sits unfocused in the background: pure idle CPU
/// (measured ~40% on one core). NSApplication's active/resign notifications DO fire on focus
/// change, so the map pauses the instant the user switches away and resumes when they return.
/// (Same app-active gating pattern used to kill the Marketing app's idle-animation spin.)
final class AppActive: ObservableObject {
    @Published var isActive: Bool = NSApplication.shared.isActive
    private var tokens: [NSObjectProtocol] = []
    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                     object: nil, queue: .main) { [weak self] _ in self?.isActive = true })
        tokens.append(nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                     object: nil, queue: .main) { [weak self] _ in self?.isActive = false })
    }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

// MARK: - Decode (optional extensions of the /frame payload)

struct RoomLink: Decodable, Equatable {
    let node_id: Int
    let live: Bool
    let rate_hz: Double?
    let rssi: Int?
    let motion: Double
    let baseline: Double?
    let present: Bool
}

/// One engine feed entry (door swing, hvac cycle, steam, appliance signature).
/// Rendered verbatim from the engine's `events` — the UI never synthesizes one.
struct EngineEvent: Decodable, Equatable, Identifiable {
    let t: Double
    let node_id: Int
    let kind: String
    let value: Double?
    var id: String { "\(t)·\(kind)" }
}

struct HouseMapNode: Decodable, Equatable {
    let room: String
    let pos: [Double]
    let role: String?
}

struct HouseMap: Decodable, Equatable {
    let measured_at: String?
    let source: String?
    let error_envelope: String?
    let nodes: [String: HouseMapNode]
    let links: [String: Int]?
}

// F5–F7 self-learned home: adjacency from motion handoffs, behavioral room
// labels, fused metric-ish geometry, physics-classified WALLS, occupancy
// belief and habit prediction. All fields beyond the F5 core are optional —
// the view renders whatever the engine has honestly earned so far.
struct HomeNode: Decodable, Equatable {
    let label: String
    let display: String
    let confidence: Double
    let pos: [Double]
    let cell: [[Double]]?          // Voronoi room polygon (unit coords)
    let placement: Double?         // 0..1 how pinned-down this node is
}
struct HomeEdge: Decodable, Equatable {
    let a: Int
    let b: Int
    let w: Double
}
struct HomeWall: Decodable, Equatable {
    let a: Int
    let b: Int
    let kind: String               // wall+door | open-passage | wall | open
    let boundary: [[Double]]
    let segments: [[[Double]]]?    // drawable wall pieces (door gap carved)
    let loss_db: Double?
    let material_hint: String?
}
struct HomeDoor: Decodable, Equatable {
    let a: Int
    let b: Int
    let pos: [Double]
    let traffic: Double?
    let walk_s: Double?
    let peak_hour: Int?
}
struct HomeOccupancyBest: Decodable, Equatable {
    let room: String
    let confidence: Double
}
struct HomeTrackPoint: Decodable, Equatable {
    let node: Int
    let room: String
    let confidence: Double
}
struct HomeOccupancy: Decodable, Equatable {
    let best: HomeOccupancyBest?
    let posterior: [String: Double]?
    let track: [HomeTrackPoint]?
    // Room-level multi-occupancy (F5+ 2026-07-05). count = distinct occupied
    // ROOMS = a FLOOR on how many people are home (two bodies in one room read
    // as one; this RF fleet has no per-person signal). Never an exact headcount.
    let count: Int?
    let rooms_present: [String]?
    let multi: Bool?
}
struct HomePredict: Decodable, Equatable {
    let node: Int
    let p: Double
    let room: String?
}
struct HomeRTI: Decodable, Equatable {
    let grid: Int
    let image: [[Double]]
    let z: Double?
    let localized: Bool
    let peak: [Double]?              // unit coords, only when localized
    let links_significant: Int?
}
struct HomeUserWall: Codable, Equatable {
    let a: [Double]
    let b: [Double]
}
struct HomeScanRoom: Decodable, Equatable {
    let name: String
    let polygon: [[Double]]
}
struct HomeScanLayer: Decodable, Equatable {
    let source: String?
    let walls: [[[Double]]]?
    let rooms: [HomeScanRoom]?
}
struct LearnedHome: Decodable, Equatable {
    let source: String?
    let envelope: String?
    let learning: Bool
    let pulses: Int
    let handoffs: Int
    let metric: Bool?
    let nodes: [String: HomeNode]
    let edges: [HomeEdge]
    let walls: [HomeWall]?
    let outline: [[Double]]?
    let doors: [HomeDoor]?
    let occupancy: HomeOccupancy?
    let predict: [HomePredict]?
    let scan: HomeScanLayer?
    let rti: HomeRTI?
    let user_walls: [HomeUserWall]?
    let dot: HomeDot?
    let dots: [HomeDot]?      // room-level multi-occupancy: one per occupied room
}
struct HomeDot: Decodable, Equatable {
    let pos: [Double]
    let mode: String          // live | holding | room
    let node: Int?
    let kind: String?         // primary (tracked occupant) | presence (other occupied room)
}

// MARK: - The House lens

struct VigilHouseView: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.scenePhase) private var phase
    @StateObject private var appActive = AppActive()
    /// Optional path to node setup, wired from the dashboard. When the live map
    /// has no contributing sensor node yet (the common first-run / hardware-not-
    /// arrived case) the honest empty state offers a "Set up a node" CTA. nil in
    /// the Sense-hub embedding (no dashboard nav there) → CTA hidden, copy stays.
    var onConnectNode: (() -> Void)? = nil

    private var rooms: [String: RoomLink] { engine.frame?.rooms ?? [:] }
    private var home: LearnedHome? { engine.frame?.home }
    private var occupant: String? { engine.frame?.occupant_room }

    // VG-23 — the per-modality presence votes, built from the REAL per-modality fields of
    // the live fused sensing frame (never fabricated to force a winner, §5.1): CSI liveness,
    // camera pose readiness, acoustic-sonar range strength. A modality that isn't asserting
    // presence contributes nothing; FusedPresence.carrying picks the strongest real source.
    private var presenceVotes: [PresenceVote] {
        guard let f = engine.frame, f.present else { return [] }
        func clamp01(_ v: Double) -> Double { min(1.0, max(0.0, v)) }
        return [
            PresenceVote(modality: .csi,    present: f.csi_connected == true, strength: clamp01(f.motion)),
            PresenceVote(modality: .camera, present: f.pose_ready,             strength: clamp01(f.model_pck50)),
            PresenceVote(modality: .sonar,  present: (f.range_strength ?? 0) > 0, strength: clamp01(f.range_strength ?? 0)),
        ]
    }
    /// The honest one-line answer to "which modality is carrying presence right now?" with the
    /// engine's recorded fused confidence — or "—" when nothing clears its floor.
    private var fusedModalityLine: String {
        guard let m = FusedPresence.carrying(presenceVotes) else { return "—  (no modality above baseline)" }
        let conf = FusedPresence.confidenceLabel(home?.occupancy?.best?.confidence)
        return "\(m.label)  ·  fused confidence \(conf)"
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            HStack(alignment: .top, spacing: 14) {
                mapCard
                    .frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    occupantCard
                    vitalsCard
                    fallCard
                    activityCard
                    if !installSpots.isEmpty { installPlanCard }
                }
                .frame(width: 250)
            }
            roomStrip
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.bg)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(engine.frame?.live == true ? Color.green : Palette.dim)
                .frame(width: 7, height: 7)
                .shadow(color: engine.frame?.live == true ? .green.opacity(0.8) : .clear, radius: 4)
            Text("YOUR HOME").font(.system(size: 13, weight: .heavy)).tracking(2.2)
                .foregroundColor(Palette.goldTxt)
            if let h = home, !h.learning {
                let walled = (h.walls ?? []).contains { $0.kind == "wall" || $0.kind == "wall+door" }
                Text(walled ? "self-mapped · self-named · walls measured"
                            : (h.metric == true ? "self-mapped · self-named · metric"
                                                : "self-mapped · self-named"))
                    .font(.system(size: 10))
                    .foregroundColor(Palette.goldDk)
            } else if hasSensingNode {
                Text("learning from movement").font(.system(size: 10))
                    .foregroundColor(Palette.dim)
            } else {
                Text("no node connected").font(.system(size: 10))
                    .foregroundColor(Palette.dim)
            }
            Spacer()
            Text("\(rooms.values.filter(\.live).count) nodes live")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.dim)
        }
    }

    // MARK: the SELF-LEARNED home (F5) — no manual setup, no ranging

    private var learningState: Bool { (home?.learning ?? true) }
    /// True once at least one sensor node is actually contributing (a live room
    /// link, or nodes present in the learned map). False = no hardware connected
    /// yet, so the map genuinely cannot learn — say so honestly instead of a
    /// "Learning your home" state that would never progress without a node.
    private var hasSensingNode: Bool {
        rooms.values.contains(where: { $0.live }) || (home.map { !$0.nodes.isEmpty } ?? false)
    }

    @State private var addWallMode = false
    @State private var deleteWallMode = false      // tap a wall to remove it
    @State private var wallDraft: CGPoint? = nil   // first tap, view coords
    @State private var renamingRoom: String? = nil // room card being renamed
    @State private var renameDraft = ""
    @State private var userWalls: [HomeUserWall] = []
    // VG-26 — draw-your-room EXCLUSION ZONES: rectangular masks where sensed motion is a
    // couch pile / a fan / a curtain, NOT a person. A dot inside a zone is suppressed on the
    // map (designs out the "pillows are people" false-positive). Persisted like userWalls.
    @State private var addExclusionMode = false
    @State private var exclusionDraft: CGPoint? = nil   // first corner, view coords
    @State private var exclusionZones: [ExclusionZone] = []
    // VG-27 — INSTALL SPOTS: owner-planned mounting positions for cameras and every
    // other device kind. Pick a kind from the "Add device" menu, tap the plan where it
    // goes; tap the spot later (or use the Install-plan card) to flip planned →
    // installed. Persisted like userWalls; an annotation, never a fabricated device.
    @State private var placeSpotKind: DeviceKind? = nil
    @State private var installSpots: [InstallSpot] = []
    /// 3D house mode — SceneKit volume render of the same learned map.
    /// Persisted; defaults ON (the flagship look). "Add wall" tap-to-draw
    /// stays a Plan-mode tool, so entering 3D cancels a draft.
    @AppStorage("vigil.house.3d") private var map3D = true

    private var house3DSnapshot: House3DSnapshot {
        House3DSnapshot(home: home,
                        occupantLabel: occupant,
                        liveLabels: Set(rooms.filter { $0.value.live }.map(\.key)),
                        userWalls: mergedUserWalls(engineWalls: home?.user_walls),
                        installSpots: installSpots)
    }

    private func unitPoint(_ p: CGPoint, in size: CGSize) -> [Double] {
        let inset: CGFloat = 52
        let x = (p.x - inset) / max(size.width - 2 * inset, 1)
        let y = 1.0 - (p.y - inset) / max(size.height - 2 * inset, 1)
        return [Double(min(max(x, 0), 1)), Double(min(max(y, 0), 1))]
    }

    // Routed through VigilPaths so VIGIL_HOME / HOMEFRONT_DATA_DIR can redirect the whole
    // state surface. A raw "~/.vigil/…" literal here would escape the override and let a QA
    // pass write into the owner's LIVE map (burned 2026-07-12).
    private var userWallURL: URL { VigilPaths.url("user_walls.json") }

    private func normalizedWall(a: [Double], b: [Double]) -> HomeUserWall? {
        guard a.count == 2, b.count == 2 else { return nil }
        func clamp(_ v: Double) -> Double { min(1.0, max(0.0, v)) }
        let aa = [clamp(a[0]), clamp(a[1])]
        let bb = [clamp(b[0]), clamp(b[1])]
        guard abs(aa[0] - bb[0]) > 0.0005 || abs(aa[1] - bb[1]) > 0.0005 else { return nil }
        return HomeUserWall(a: aa, b: bb)
    }

    private func wallKey(_ w: HomeUserWall) -> String {
        (w.a + w.b).map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    private func readUserWalls() -> [HomeUserWall] {
        guard let data = try? Data(contentsOf: userWallURL),
              let decoded = try? JSONDecoder().decode([HomeUserWall].self, from: data) else { return [] }
        var seen = Set<String>()
        var out: [HomeUserWall] = []
        for w in decoded {
            guard let clean = normalizedWall(a: w.a, b: w.b) else { continue }
            let key = wallKey(clean)
            if seen.insert(key).inserted { out.append(clean) }
        }
        return out
    }

    private func writeUserWalls(_ walls: [HomeUserWall]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: userWallURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(walls).write(to: userWallURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func mergedUserWalls(engineWalls: [HomeUserWall]?) -> [HomeUserWall] {
        var seen = Set<String>()
        var out: [HomeUserWall] = []
        for w in (engineWalls ?? []) + userWalls {
            guard let clean = normalizedWall(a: w.a, b: w.b) else { continue }
            let key = wallKey(clean)
            if seen.insert(key).inserted { out.append(clean) }
        }
        return out
    }

    private func appendUserWall(a: [Double], b: [Double]) {
        guard let wall = normalizedWall(a: a, b: b) else { return }
        var walls = readUserWalls()
        if !walls.contains(where: { wallKey($0) == wallKey(wall) }) {
            walls.append(wall)
        }
        if writeUserWalls(walls) {
            userWalls = walls
        }
    }

    /// Perpendicular distance from a unit-box point to a wall segment — the
    /// hit test for tap-to-delete (Founder ask 2026-07-26: walls must be
    /// removable individually, not just undone newest-first).
    private static func distanceToWall(_ pt: [Double], _ w: HomeUserWall) -> Double {
        let ax = w.a[0], ay = w.a[1], bx = w.b[0], by = w.b[1]
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        guard len2 > 1e-12 else { return hypot(pt[0] - ax, pt[1] - ay) }
        var t = ((pt[0] - ax) * dx + (pt[1] - ay) * dy) / len2
        t = min(1.0, max(0.0, t))
        return hypot(pt[0] - (ax + t * dx), pt[1] - (ay + t * dy))
    }

    /// Remove the owner-drawn wall nearest a tap. Engine-derived (measured)
    /// walls are not owner data and are never deleted here — only the walls
    /// the owner drew, which is exactly what `user_walls.json` holds.
    private func deleteUserWall(near pt: [Double], within: Double = 0.05) {
        let walls = readUserWalls()
        guard !walls.isEmpty else { return }
        var bestIdx = -1
        var bestD = within
        for (i, w) in walls.enumerated() {
            let d = Self.distanceToWall(pt, w)
            if d <= bestD { bestD = d; bestIdx = i }
        }
        guard bestIdx >= 0 else { return }
        var next = walls
        next.remove(at: bestIdx)
        if writeUserWalls(next) {
            userWalls = next
        }
    }

    // MARK: room rename (Founder ask 2026-07-26 — names must be editable)
    //
    // Truth for room labels is the fleet manifest the engine reads at each
    // map tick; the node also stores its own room string (control cmd 0x08
    // SET_ROOM) so a re-pair or a fresh engine keeps the name. Write both:
    // manifest first (what the app renders), node second (best-effort).
    private func commitRename(nodeId: Int) {
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingRoom = nil
        renameDraft = ""
        guard !name.isEmpty, name.count <= 32 else { return }
        let url = VigilPaths.url("fleet.json")
        guard let data = try? Data(contentsOf: url),
              var fleet = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return }
        for i in fleet.indices where (fleet[i]["node_id"] as? Int) == nodeId {
            fleet[i]["room"] = name
        }
        if let out = try? JSONSerialization.data(withJSONObject: fleet,
                                                 options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url, options: .atomic)
        }
        pushRoomToNode(nodeId: nodeId, room: name, fleet: fleet)
    }

    /// Control-plane SET_ROOM (0xA5 0x5C 0x08 | room utf-8) so the node
    /// carries its own name. Fire-and-forget: the manifest is the truth the
    /// app renders, and a node that misses this keeps sensing regardless.
    private func pushRoomToNode(nodeId: Int, room: String, fleet: [[String: Any]]) {
        guard let entry = fleet.first(where: { ($0["node_id"] as? Int) == nodeId }),
              let ip = entry["ip"] as? String, !ip.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var payload = Data([0xA5, 0x5C, 0x08])
            payload.append(contentsOf: Array(room.utf8))
            let sock = socket(AF_INET, SOCK_DGRAM, 0)
            guard sock >= 0 else { return }
            defer { close(sock) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(5567).bigEndian
            addr.sin_addr.s_addr = inet_addr(ip)
            _ = payload.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) { ap in
                    ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(sock, buf.baseAddress, buf.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func undoUserWall() {
        var walls = readUserWalls()
        guard !walls.isEmpty else { return }
        walls.removeLast()
        if writeUserWalls(walls) {
            userWalls = walls
        }
    }

    // MARK: VG-26 exclusion zones (persisted like user walls)
    private var exclusionZoneURL: URL { VigilPaths.url("exclusion_zones.json") }
    private func readExclusionZones() -> [ExclusionZone] {
        guard let data = try? Data(contentsOf: exclusionZoneURL),
              let decoded = try? JSONDecoder().decode([ExclusionZone].self, from: data) else { return [] }
        return decoded
    }
    @discardableResult
    private func writeExclusionZones(_ zones: [ExclusionZone]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: exclusionZoneURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(zones).write(to: exclusionZoneURL, options: .atomic)
            return true
        } catch { return false }
    }
    /// Add a zone from two opposite corners (unit coords). A degenerate rectangle (a stray
    /// single tap) is dropped so a zero-area mask can never silently suppress the whole map.
    private func appendExclusionZone(cornerA a: [Double], cornerB b: [Double]) {
        guard let zone = ExclusionZone(cornerA: a, cornerB: b) else { return }
        var zones = readExclusionZones(); zones.append(zone)
        if writeExclusionZones(zones) { exclusionZones = zones }
    }
    private func undoExclusionZone() {
        var zones = readExclusionZones()
        guard !zones.isEmpty else { return }
        zones.removeLast()
        if writeExclusionZones(zones) { exclusionZones = zones }
    }

    // MARK: VG-27 install spots (persisted like user walls / exclusion zones)
    private var installSpotURL: URL { VigilPaths.url("install_spots.json") }
    private func readInstallSpots() -> [InstallSpot] {
        guard let data = try? Data(contentsOf: installSpotURL),
              let decoded = try? JSONDecoder().decode([InstallSpot].self, from: data) else { return [] }
        return decoded.filter { $0.pos.count == 2 }
    }
    @discardableResult
    private func writeInstallSpots(_ spots: [InstallSpot]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: installSpotURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(spots).write(to: installSpotURL, options: .atomic)
            return true
        } catch { return false }
    }
    private func appendInstallSpot(kind: DeviceKind, at p: [Double]) {
        guard let spot = InstallSpot(kind: kind, at: p) else { return }
        var spots = readInstallSpots(); spots.append(spot)
        if writeInstallSpots(spots) { installSpots = spots }
    }
    private func toggleInstallSpot(_ id: UUID) {
        var spots = readInstallSpots()
        guard let i = spots.firstIndex(where: { $0.id == id }) else { return }
        spots[i].installed.toggle()
        if writeInstallSpots(spots) { installSpots = spots }
    }
    private func removeInstallSpot(_ id: UUID) {
        var spots = readInstallSpots()
        spots.removeAll { $0.id == id }
        if writeInstallSpots(spots) { installSpots = spots }
    }
    private func undoInstallSpot() {
        var spots = readInstallSpots()
        guard !spots.isEmpty else { return }
        spots.removeLast()
        if writeInstallSpots(spots) { installSpots = spots }
    }
    /// Arm tap-to-place for one device kind: drops into Plan mode and cancels any
    /// draw mode so the next map tap can only place the chosen spot.
    private func armSpotPlacement(_ kind: DeviceKind) {
        if map3D { map3D = false }
        addWallMode = false; wallDraft = nil
        addExclusionMode = false; exclusionDraft = nil
        placeSpotKind = kind
    }
    /// Named learned rooms only — a spot is labeled from what the map has honestly
    /// earned; with no learned home the spot just says "on the plan" (§5.1).
    private var learnedRoomList: [(label: String, pos: [Double])] {
        (home?.nodes ?? [:]).values
            .filter { $0.label != "unlabeled" }
            .map { ($0.display, $0.pos) }
    }
    private func spotRoom(_ s: InstallSpot) -> String? {
        InstallPlan.nearestRoom(to: s.pos, rooms: learnedRoomList)
    }
    private static let installedGreen = Color(red: 0.35, green: 0.78, blue: 0.45)

    private func rfRun(node: Int?) {
        var url = "http://127.0.0.1:8799/recalibrate"
        if let n = node { url += "?node=\(n)" }
        if let u = URL(string: url) {
            URLSession.shared.dataTask(with: u).resume()
        }
    }

    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
            ZStack {
                if map3D {
                    VigilHouse3D(snapshot: house3DSnapshot)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                                            paused: phase != .active || !appActive.isActive)) { tl in
                        Canvas { ctx, size in
                            drawLearnedHome(ctx: &ctx, size: size,
                                            t: tl.date.timeIntervalSinceReferenceDate)
                        }
                    }
                }
                if let d = wallDraft {
                    Circle().stroke(Palette.gold, lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                        .position(d)
                }
                if let d = exclusionDraft {   // VG-26 first corner of the exclusion rectangle
                    Rectangle().stroke(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: 12, height: 12)
                        .position(d)
                }
                if !hasSensingNode && placeSpotKind == nil {
                    // Zero-hardware first run (most common: buyer opens Vigil
                    // before any node arrives). Room mapping draws from Vigil
                    // sensor nodes, so with none connected the map genuinely
                    // cannot learn. Say so honestly — and point to the sensing
                    // that DOES run on the Mac alone — instead of a false
                    // "Learning your home" that never progresses. The card steps
                    // aside while an install spot is being placed (VG-27) so the
                    // whole map is visible to tap.
                    VStack(spacing: 9) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 30)).foregroundColor(Palette.goldDk)
                        Text("Connect a node to map your home")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Palette.goldTxt)
                        Text("This live map draws itself from Vigil sensor nodes as they\nsurvey your rooms — add one to begin. Meanwhile your Mac is\nalready sensing presence: Security arms from it, no extra hardware.")
                            .font(.system(size: 10)).foregroundColor(Palette.dim)
                            .multilineTextAlignment(.center)
                        if let onConnectNode {
                            Button(action: onConnectNode) {
                                Text("Set up a node")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Palette.goldTxt)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.goldDk))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                        if installSpots.isEmpty {
                            // VG-27 friendliness — the pre-hardware buyer's first win:
                            // plan where the cameras (and everything else) will mount
                            // before a single node arrives.
                            Button { armSpotPlacement(.camera) } label: {
                                Label("Plan where your cameras go", systemImage: "video.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Palette.goldTxt)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.goldDk))
                            }
                            .buttonStyle(.plain)
                            .help("Drop an install spot for a camera — pick any other device kind from “Add device” below the map")
                            Text("locks, thermostats, speakers & more — “Add device” below the map")
                                .font(.system(size: 8)).foregroundColor(Palette.dim.opacity(0.85))
                        }
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.55)))
                } else if learningState && hasSensingNode && placeSpotKind == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "figure.walk.motion")
                            .font(.system(size: 30)).foregroundColor(Palette.goldDk)
                        Text("Learning your home").font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Palette.goldTxt)
                        Text("Walk from room to room. Vigil learns which rooms\nconnect from your movement — and names them from\nhow you use them. No setup, no floor plan.")
                            .font(.system(size: 10)).foregroundColor(Palette.dim)
                            .multilineTextAlignment(.center)
                        if let h = home, h.pulses > 0 {
                            Text("\(h.pulses) movements seen · \(h.handoffs) room links forming")
                                .font(.system(size: 9, design: .monospaced)).foregroundColor(Palette.goldDk)
                        }
                    }
                }
                if let kind = placeSpotKind {
                    // VG-27 friendliness — while placement is armed the map itself says
                    // exactly what to do next, with an obvious way out. Top-most layer;
                    // its own tap gesture swallows stray taps so the banner can never
                    // place a spot underneath itself.
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Palette.gold)
                            Text("Tap the map where the \(kind.label.lowercased()) goes")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Palette.goldTxt)
                            Button { placeSpotKind = nil } label: {
                                Text("Cancel")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Palette.dim)
                            }
                            .buttonStyle(.plain)
                            .help("Stop placing — nothing is added")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Color.black.opacity(0.78)))
                        .overlay(Capsule().stroke(Palette.goldDk.opacity(0.8), lineWidth: 1))
                        .onTapGesture { }
                        Spacer()
                    }
                    .padding(.top, 10)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                if let kind = placeSpotKind {   // VG-27: drop the armed install spot here
                    appendInstallSpot(kind: kind, at: unitPoint(p, in: geo.size))
                    placeSpotKind = nil
                    return
                }
                if addExclusionMode {   // VG-26: two-corner rectangle
                    if let start = exclusionDraft {
                        appendExclusionZone(cornerA: unitPoint(start, in: geo.size),
                                            cornerB: unitPoint(p, in: geo.size))
                        exclusionDraft = nil
                        addExclusionMode = false
                    } else {
                        exclusionDraft = p
                    }
                    return
                }
                if deleteWallMode {
                    deleteUserWall(near: unitPoint(p, in: geo.size))
                    return
                }
                guard addWallMode else {
                    // VG-27: a plain tap on an existing spot flips planned ↔ installed.
                    // The hit-test radius is small and nearest-only, so a tap on empty
                    // floor mutates nothing.
                    if !map3D, let hit = InstallPlan.nearest(to: unitPoint(p, in: geo.size),
                                                             in: installSpots, within: 0.045) {
                        toggleInstallSpot(hit.id)
                    }
                    return
                }
                if let start = wallDraft {
                    appendUserWall(a: unitPoint(start, in: geo.size),
                                   b: unitPoint(p, in: geo.size))
                    wallDraft = nil
                    addWallMode = false
                } else {
                    wallDraft = p
                }
            }
            }
            .frame(minHeight: 320)
            HStack(spacing: 10) {
                Button {
                    map3D.toggle()
                    addWallMode = false
                    deleteWallMode = false
                    wallDraft = nil
                } label: {
                    Label(map3D ? "Plan" : "3D",
                          systemImage: map3D ? "square.grid.2x2" : "cube.transparent")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Palette.gold)
                }
                .buttonStyle(.plain)
                .help(map3D ? "Switch to the flat plan view" : "Switch to the 3D house view (drag to orbit)")
                // VG-27 — THE primary map tool: place an INSTALL SPOT. Pick the device
                // kind (camera, lock, thermostat — every kind Vigil models), then tap
                // the plan where it should be mounted. Gold so it reads as the main
                // action; the banner over the map carries the how-to while armed.
                Menu {
                    ForEach(DeviceKind.allCases) { kind in
                        Button { armSpotPlacement(kind) } label: {
                            Label(kind.label, systemImage: kind.symbol)
                        }
                    }
                    if placeSpotKind != nil {
                        Divider()
                        Button("Cancel placement") { placeSpotKind = nil }
                    }
                } label: {
                    Label(placeSpotKind != nil ? "placing…" : "Add device",
                          systemImage: placeSpotKind?.symbol ?? "plus.viewfinder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Palette.gold)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Plan where to install a camera or any other device: pick a kind, tap the map. Tap a spot later to mark it installed.")
                if !installSpots.isEmpty {
                    Button {
                        undoInstallSpot()
                        placeSpotKind = nil
                    } label: {
                        Label("Undo spot", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Palette.dim)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the most recently placed install spot")
                }
                Button {
                    if map3D {
                        map3D = false
                        addWallMode = true
                    } else {
                        addWallMode.toggle()
                    }
                    wallDraft = nil
                } label: {
                    Label(addWallMode ? "tap wall start, then end" : "Add wall",
                          systemImage: "pencil.line")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(addWallMode ? Palette.gold : Palette.dim)
                }
                .buttonStyle(.plain)
                if !mergedUserWalls(engineWalls: home?.user_walls).isEmpty {
                    Button {
                        undoUserWall()
                        wallDraft = nil
                        addWallMode = false
                        deleteWallMode = false
                    } label: {
                        Label("Undo wall", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Palette.dim)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the most recent owner-drawn wall")
                    Button {
                        if map3D { map3D = false }
                        deleteWallMode.toggle()
                        addWallMode = false
                        wallDraft = nil
                    } label: {
                        Label(deleteWallMode ? "tap a wall to delete" : "Delete wall",
                              systemImage: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(deleteWallMode ? Color.red.opacity(0.9) : Palette.dim)
                    }
                    .buttonStyle(.plain)
                    .help("Tap any wall you drew to remove just that one")
                }
                // VG-26 — draw an EXCLUSION ZONE: tap two opposite corners to mask an area
                // (a couch, a fan) whose motion should not read as a person.
                Button {
                    if map3D {
                        map3D = false
                        addExclusionMode = true
                    } else {
                        addExclusionMode.toggle()
                    }
                    addWallMode = false; deleteWallMode = false
                    wallDraft = nil; exclusionDraft = nil
                } label: {
                    Label(addExclusionMode ? "tap zone corner, then opposite" : "Exclude zone",
                          systemImage: "rectangle.dashed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(addExclusionMode ? .red : Palette.dim)
                }
                .buttonStyle(.plain)
                .help("Mask an area (a couch, a fan) so its motion isn't counted as presence")
                if !exclusionZones.isEmpty {
                    Button {
                        undoExclusionZone()
                        exclusionDraft = nil
                        addExclusionMode = false
                    } label: {
                        Label("Undo zone", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Palette.dim)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the most recent exclusion zone")
                }
                Button {
                    rfRun(node: nil)
                } label: {
                    Label("RF run", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Palette.dim)
                }
                .buttonStyle(.plain)
                .help("Re-run RF calibration for the whole house (keep it quiet ~2 min)")
                Spacer()
                if let rti = home?.rti, rti.localized {
                    Text("dot: \(rti.links_significant ?? 0) links agree · z \(String(format: "%.1f", rti.z ?? 0))")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(Palette.goldDk)
                }
            }
            Text(home?.envelope ?? "learned from movement — no manual setup, no ranging, no floor plan")
                .font(.system(size: 9)).foregroundColor(Palette.dim.opacity(0.8))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.055, green: 0.055, blue: 0.066)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.stroke, lineWidth: 1))
        .onAppear { userWalls = readUserWalls(); exclusionZones = readExclusionZones(); installSpots = readInstallSpots() }
    }

    private func drawLearnedHome(ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let inset: CGFloat = 52
        func pt(_ p: [Double]) -> CGPoint {
            CGPoint(x: inset + CGFloat(p[0]) * (size.width - 2 * inset),
                    y: inset + CGFloat(1.0 - p[1]) * (size.height - 2 * inset))
        }
        func poly(_ pts: [[Double]]) -> Path {
            var path = Path()
            guard pts.count >= 2 else { return path }
            path.move(to: pt(pts[0]))
            for q in pts.dropFirst() { path.addLine(to: pt(q)) }
            path.closeSubpath()
            return path
        }
        let ownerWalls = mergedUserWalls(engineWalls: home?.user_walls)
        func drawOwnerWalls() {
            for w in ownerWalls where w.a.count == 2 && w.b.count == 2 {
                var path = Path()
                path.move(to: pt(w.a)); path.addLine(to: pt(w.b))
                ctx.stroke(path, with: .color(Color.white.opacity(0.45)), lineWidth: 3)
            }
        }
        // VG-26 — draw the owner's EXCLUSION ZONES as translucent masked rectangles so it's
        // visible where presence is being suppressed.
        func drawExclusionZones() {
            for z in exclusionZones {
                let a = pt([z.minX, z.maxY]), b = pt([z.maxX, z.minY])   // top-left, bottom-right in view coords
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                  width: abs(b.x - a.x), height: abs(b.y - a.y))
                ctx.fill(Path(rect), with: .color(Color.red.opacity(0.10)))
                ctx.stroke(Path(rect), with: .color(Color.red.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ctx.draw(ctx.resolve(Text("excluded").font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Color.red.opacity(0.8))),
                         at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
        }
        // VG-27 — draw the owner's INSTALL SPOTS: planned mounts are dashed gold, an
        // installed mount is a solid green ring. Drawn even before any home is learned —
        // planning where hardware goes is exactly the pre-hardware use case.
        func drawInstallSpots() {
            for s in installSpots where s.pos.count == 2 {
                let p = pt(s.pos)
                let c: Color = s.installed ? Self.installedGreen : Palette.gold
                let r: CGFloat = 9
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.55)))
                if s.installed {
                    ctx.stroke(Path(ellipseIn: rect), with: .color(c.opacity(0.95)), lineWidth: 1.5)
                } else {
                    ctx.stroke(Path(ellipseIn: rect), with: .color(c.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
                ctx.draw(ctx.resolve(Text("\(Image(systemName: s.kind.symbol))")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(c)),
                         at: p, anchor: .center)
                ctx.draw(ctx.resolve(Text(s.kind.label.uppercased() + (s.installed ? "" : " · PLANNED"))
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundColor(s.installed ? c.opacity(0.85) : Palette.dim)),
                         at: CGPoint(x: p.x, y: p.y + r + 8), anchor: .center)
            }
        }
        guard let h = home, !h.nodes.isEmpty else {
            drawOwnerWalls()
            drawExclusionZones()
            drawInstallSpots()
            return
        }
        let posterior = h.occupancy?.posterior ?? [:]

        // 0) owner-scanned RoomPlan layer (real architecture, faint reference)
        if let scan = h.scan, let sw = scan.walls {
            for seg in sw where seg.count == 2 {
                var path = Path()
                path.move(to: pt(seg[0])); path.addLine(to: pt(seg[1]))
                ctx.stroke(path, with: .color(Color.white.opacity(0.10)), lineWidth: 1)
            }
        }
        // 1) learned room cells — fill heat = occupancy belief for that room
        for (nid, node) in h.nodes {
            guard let cell = node.cell, cell.count >= 3 else { continue }
            let belief = posterior[nid] ?? 0
            let cellPath = poly(cell)
            ctx.fill(cellPath, with: .color(Palette.goldDk.opacity(0.05 + 0.30 * belief)))
            ctx.stroke(cellPath, with: .color(Palette.stroke.opacity(0.6)), lineWidth: 0.7)
        }
        // 1b) RTI motion heat — where the fleet's crossed links see the body
        if let rti = h.rti, rti.image.count == rti.grid {
            let g = CGFloat(rti.grid)
            let cw = (size.width - 2 * inset) / g
            let ch = (size.height - 2 * inset) / g
            for (r, row) in rti.image.enumerated() {
                for (c, v) in row.enumerated() where v >= 0.3 {
                    let rect = CGRect(x: inset + CGFloat(c) * cw,
                                      y: inset + (CGFloat(rti.grid - 1 - r)) * ch,
                                      width: cw + 0.5, height: ch + 0.5)
                    ctx.fill(Path(rect),
                             with: .color(Palette.gold.opacity(0.05 + 0.22 * v)))
                }
            }
        }
        // 2) sensing-coverage outline (honest footprint, not architecture)
        if let outline = h.outline, outline.count >= 3 {
            ctx.stroke(poly(outline), with: .color(Palette.goldDk.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        // 2b) owner-drawn wall corrections — labeled layer, never "measured"
        drawOwnerWalls()
        // 3) WALLS — measured physics: solid pieces, door gaps already carved
        for w in h.walls ?? [] {
            switch w.kind {
            case "wall", "wall+door":
                for seg in w.segments ?? [] where seg.count == 2 {
                    var path = Path()
                    path.move(to: pt(seg[0])); path.addLine(to: pt(seg[1]))
                    ctx.stroke(path, with: .color(Palette.goldTxt.opacity(0.55)),
                               lineWidth: 3.5)
                }
            case "open-passage":
                var path = Path()
                if w.boundary.count == 2 {
                    path.move(to: pt(w.boundary[0])); path.addLine(to: pt(w.boundary[1]))
                    ctx.stroke(path, with: .color(Palette.dim.opacity(0.3)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }
            default:
                break
            }
        }
        // 4) doors — walked openings, ring size hints traffic
        for d in h.doors ?? [] {
            let p = pt(d.pos)
            let r: CGFloat = 3.5
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r*2, height: r*2)),
                       with: .color(Palette.gold.opacity(0.8)), lineWidth: 1.2)
        }
        // 5) recent trajectory — the walked path, fading into the past
        if let track = h.occupancy?.track, track.count >= 2 {
            let pts: [CGPoint] = track.compactMap { h.nodes[String($0.node)].map { pt($0.pos) } }
            if pts.count >= 2 {
                for i in 1..<pts.count {
                    let age = Double(i) / Double(pts.count - 1)   // 0 old → 1 new
                    var path = Path()
                    path.move(to: pts[i - 1]); path.addLine(to: pts[i])
                    ctx.stroke(path, with: .color(Palette.gold.opacity(0.08 + 0.30 * age)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 3]))
                }
            }
        }
        // 5a2) owner exclusion zones — drawn under the dots so a suppressed area reads clearly.
        drawExclusionZones()
        // 5a3) VG-27 install spots — the owner's mounting plan, under the live dots.
        drawInstallSpots()
        // 5b) THE DOTS — room-level multi-occupancy. Tracked occupant
        // (kind "primary") is the GREEN you-are-here ping (Founder ask
        // 2026-07-26 — gold made "me" indistinguishable from node markers);
        // every OTHER occupied room is cyan. One dot per occupied ROOM, not
        // per person (same-room bodies read as one). Falls back to the
        // single legacy `dot`.
        let occCyan = Color(red: 0.36, green: 0.78, blue: 0.98)
        let youGreen = Color(red: 0.20, green: 0.95, blue: 0.45)
        // VG-26 — a dot whose position falls inside an exclusion zone is NOT counted as a
        // person (couch pile / fan). Suppressed here so the map shows only real presence.
        let dots: [HomeDot] = ((h.dots?.isEmpty == false) ? h.dots! : [h.dot].compactMap { $0 })
            .filter { !ExclusionZones.suppresses($0.pos, zones: exclusionZones) }
        for (i, dot) in dots.enumerated() where dot.pos.count == 2 {
            let p = pt(dot.pos)
            let isPrimary = i == 0 && (dot.kind ?? "primary") == "primary"
            let c: Color = isPrimary ? youGreen : occCyan
            let live = dot.mode == "live"
            let pulse = 0.5 + 0.5 * sin(t * (live ? 2.4 : 1.2))
            let rr: CGFloat = (live ? 10 : 7) + CGFloat(pulse) * (live ? 4 : 2)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr,
                                            width: rr * 2, height: rr * 2)),
                     with: .radialGradient(Gradient(colors: [
                        c.opacity(live ? 0.5 : 0.3), .clear]),
                        center: p, startRadius: 1, endRadius: rr))
            if isPrimary {
                // sonar ping: an expanding, fading green ring so "me" reads
                // at a glance — faster while moving, calm while holding
                let ph = (t * (live ? 1.1 : 0.55)).truncatingRemainder(dividingBy: 1.0)
                let ringR: CGFloat = 7 + CGFloat(ph) * (live ? 22 : 14)
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - ringR, y: p.y - ringR,
                                                  width: ringR * 2, height: ringR * 2)),
                           with: .color(c.opacity(0.9 * (1.0 - ph))), lineWidth: 2)
            }
            if dot.mode == "room" {
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6,
                                                  width: 12, height: 12)),
                           with: .color(c.opacity(0.9)), lineWidth: 1.5)
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5,
                                                width: 9, height: 9)),
                         with: .color(c))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5,
                                                  width: 9, height: 9)),
                           with: .color(.black.opacity(0.6)), lineWidth: 1)
            }
        }
        // 6) learned handoff edges — subdued once real walls exist
        let hasWalls = (h.walls ?? []).contains { $0.kind == "wall" || $0.kind == "wall+door" }
        let maxW = max(1.0, h.edges.map(\.w).max() ?? 1.0)
        for e in h.edges {
            guard let a = h.nodes[String(e.a)], let b = h.nodes[String(e.b)] else { continue }
            let f = e.w / maxW
            var path = Path()
            path.move(to: pt(a.pos)); path.addLine(to: pt(b.pos))
            let dimmer: Double = hasWalls ? 0.4 : 1.0
            ctx.stroke(path, with: .color(Palette.gold.opacity((0.18 + 0.5 * f) * dimmer)),
                       lineWidth: (1 + CGFloat(f) * 3) * (hasWalls ? 0.6 : 1.0))
        }
        // rooms
        for (nid, node) in h.nodes {
            let p = pt(node.pos)
            let link = rooms[node.label] ?? rooms.values.first(where: { $0.node_id == Int(nid) })
            let isOccupant = occupant != nil && (node.label == occupant || link?.node_id == occupantNode)
            let baseFloor = link?.baseline ?? 0
            let motion = CGFloat(baseFloor > 0
                ? min(1.0, max(0.0, (link?.motion ?? 0) / baseFloor - 1.0)) : 0)
            let live = link?.live ?? false
            let pulse = 0.5 + 0.5 * sin(t * 1.8 + Double((Int(nid) ?? 0)))
            let glowR = 16 + motion * 26 + CGFloat(pulse) * 4
            if live {
                let glow = Path(ellipseIn: CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR*2, height: glowR*2))
                ctx.fill(glow, with: .radialGradient(Gradient(colors: [
                    (isOccupant ? Palette.gold : Palette.goldDk).opacity(0.22 + 0.4 * motion), .clear]),
                    center: p, startRadius: 2, endRadius: glowR))
            }
            let core = Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
            ctx.fill(core, with: .color(live ? Palette.gold : Palette.dim))
            if isOccupant {
                let rr: CGFloat = 15 + CGFloat(pulse) * 3
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr*2, height: rr*2)),
                           with: .color(Palette.gold), lineWidth: 1.5)
            }
            // self-assigned name + confidence dot
            let named = node.label != "unlabeled" && node.confidence >= 0.15
            let name = Text(node.display.uppercased())
                .font(.system(size: 10, weight: isOccupant ? .bold : .semibold))
                .foregroundColor(isOccupant ? Palette.goldTxt : (named ? Palette.goldTxt.opacity(0.85) : Palette.dim))
            ctx.draw(ctx.resolve(name), at: CGPoint(x: p.x, y: p.y + glowR + 10), anchor: .center)
            if !named {
                let q = Text("learning…").font(.system(size: 8)).foregroundColor(Palette.dim.opacity(0.7))
                ctx.draw(ctx.resolve(q), at: CGPoint(x: p.x, y: p.y + glowR + 22), anchor: .center)
            }
        }
    }

    private var occupantNode: Int? {
        guard let occ = occupant else { return nil }
        return rooms[occ]?.node_id
    }

    // MARK: occupant

    private var occupantCard: some View {
        let belief = home?.occupancy?.best
        let predictTop = (home?.predict ?? []).first
        return VStack(alignment: .leading, spacing: 4) {
            Text("YOU ARE IN").font(.system(size: 9, weight: .bold)).tracking(1.8)
                .foregroundColor(Palette.dim)
            Text(occupant?.uppercased() ?? "—")
                .font(.system(size: 24, weight: .heavy))
                .foregroundColor(occupant != nil ? Palette.goldTxt : Palette.dim)
                .contentTransition(.opacity)
            if occupant != nil, let mode = engine.frame?.occupant_mode {
                Text(mode == "holding" ? "still — position held" : "moving — live fix")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(mode == "holding" ? Palette.goldDk : Color.green.opacity(0.85))
            }
            if let dm = home?.dot?.mode, dm == "tracking" {
                Text("tracking between nodes")
                    .font(.system(size: 9))
                    .foregroundColor(Color.green.opacity(0.7))
            }
            if let b = belief, b.room != "away", b.confidence >= 0.5 {
                Text("belief \(Int((b.confidence * 100).rounded()))% · learned-home tracking")
                    .font(.system(size: 9)).foregroundColor(Palette.goldDk)
            } else {
                Text(occupant != nil ? "strongest live disturbance" : "no presence above baseline")
                    .font(.system(size: 9)).foregroundColor(Palette.dim)
            }
            // Room-level multi-occupancy — honest FLOOR on headcount (two
            // bodies in one room read as one; this RF fleet has no per-person
            // signal). Only shown when ≥2 rooms are independently occupied.
            if let occ = home?.occupancy, let c = occ.count, c >= 2 {
                Divider().overlay(Palette.stroke).padding(.vertical, 2)
                Text("\(c) ROOMS ACTIVE").font(.system(size: 9, weight: .bold)).tracking(1.6)
                    .foregroundColor(Color(red: 0.5, green: 0.82, blue: 1.0))
                Text("≥\(c) people home · " + (occ.rooms_present ?? []).joined(separator: " · "))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(red: 0.5, green: 0.82, blue: 1.0).opacity(0.85))
                Text("floor on headcount — two in one room read as one")
                    .font(.system(size: 8)).foregroundColor(Palette.dim.opacity(0.85))
            }
            if let p = predictTop, let room = p.room, p.p >= 0.4, occupant != nil {
                Divider().overlay(Palette.stroke).padding(.vertical, 2)
                Text("LIKELY NEXT").font(.system(size: 8, weight: .bold)).tracking(1.6)
                    .foregroundColor(Palette.dim)
                Text("\(room)  ·  \(Int((p.p * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.goldTxt.opacity(0.9))
            }
            // VG-23 — WHICH MODALITY is carrying presence right now + the engine's per-mode
            // fused confidence. Answers the FP2 "sees people that aren't there" pain honestly:
            // the buyer sees the real sensor asserting presence, and an honest "—" when none is.
            Divider().overlay(Palette.stroke).padding(.vertical, 2)
            Text("CARRYING PRESENCE").font(.system(size: 8, weight: .bold)).tracking(1.6)
                .foregroundColor(Palette.dim)
            Text(fusedModalityLine)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(FusedPresence.carrying(presenceVotes) != nil ? Palette.goldTxt.opacity(0.9) : Palette.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.055, green: 0.055, blue: 0.066)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(
            occupant != nil ? Palette.goldDk.opacity(0.7) : Palette.stroke, lineWidth: 1))
        .animation(.easeInOut(duration: 0.5), value: occupant)
    }

    // MARK: live activity — the engine's door/appliance/safety feed (Founder ask
    // 2026-07-26: "should show things like when the ac turns on or a fan or the
    // stove"). The engine already emits these (door swings, hvac cycles, steam,
    // appliance signatures) — this card is pure surfacing; nothing is synthesized.

    private var activityCard: some View {
        let feed = Array((engine.frame?.events ?? []).prefix(8))
        let roomOf = Dictionary(rooms.map { ($0.value.node_id, $0.key) },
                                uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: 5) {
            Text("ACTIVITY").font(.system(size: 9, weight: .bold)).tracking(1.8)
                .foregroundColor(Palette.dim)
            if feed.isEmpty {
                Text("quiet — doors, air and appliances appear here as they happen")
                    .font(.system(size: 9)).foregroundColor(Palette.dim)
            } else {
                ForEach(feed) { ev in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.eventLabel(ev, roomOf: roomOf))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Palette.goldTxt.opacity(0.9))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Self.eventAge(ev.t))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Palette.dim)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.055, green: 0.055, blue: 0.066)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.stroke, lineWidth: 1))
    }

    private static func eventLabel(_ ev: EngineEvent, roomOf: [Int: String]) -> String {
        let room = roomOf[ev.node_id].map { " · \($0)" } ?? ""
        if ev.kind == "door_open" { return "Door opened" + room }
        if ev.kind == "door_close" { return "Door closed" + room }
        if ev.kind.hasPrefix("hvac_cycle_on") {
            let scope = ev.kind.split(separator: ":").dropFirst().first.map { " · \($0)" } ?? ""
            return "Air / heat came on" + scope
        }
        if ev.kind == "hvac_cycle_off" {
            let mins = Int((ev.value ?? 0) / 60.0)
            return mins > 0 ? "Air / heat off · ran \(mins) min" : "Air / heat off"
        }
        if ev.kind == "steam" { return "Steam / hot water" + room }
        if ev.kind.hasPrefix("appliance:") {
            let label = String(ev.kind.dropFirst("appliance:".count))
            return (label == "unknown" || label.isEmpty
                    ? "Appliance running" : "\(label.capitalized) running") + room
        }
        return ev.kind.replacingOccurrences(of: "_", with: " ") + room
    }

    private static func eventAge(_ t: Double) -> String {
        let s = max(0, Date().timeIntervalSince1970 - t)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        return "\(Int(s / 3600))h"
    }

    // MARK: vitals — accuracy-or-nothing

    private var vitalsCard: some View {
        // R7/R7c (§5.1): the SHIPPING house view reads vitals through the
        // generation-gated `engine.liveFrame`, NEVER the raw `engine.frame`.
        //
        // Reading `engine.frame?.breathing_bpm` directly was safe only by accident:
        // `invalidateConnection()` happens to nil `frame` on teardown, so the raw read
        // was protected by nil-ing rather than by PROVENANCE. That is the wrong
        // invariant to depend on — any future path that bumps the generation without
        // nil-ing the frame (or an in-flight poll of the OLD connection landing after
        // teardown) would render a breathing/heart rate produced by a process that no
        // longer exists as if it were live. `liveFrame` checks generation FIRST, so a
        // stale-by-identity frame can never be rescued by a recent timestamp.
        //
        // TimelineView gives the same 1 Hz render clock the dashboard vitals card uses
        // (Homefront.swift `vitalsCard`), so the readout blanks to "listening…" on the
        // clock even if the 10 Hz poll Timer was invalidated while this view stayed
        // mounted — the poll's own catch cannot re-nil the frame in that case.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let f = engine.liveFrame
            VStack(alignment: .leading, spacing: 10) {
                vitalRow(label: "BREATHING", bpm: f?.breathing_bpm,
                         strength: f?.breathing_strength ?? 0, unit: "br/min")
                Divider().overlay(Palette.stroke)
                vitalRow(label: "HEART", bpm: f?.heart_bpm,
                         strength: f?.heart_strength ?? 0, unit: "bpm")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.055, green: 0.055, blue: 0.066)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.stroke, lineWidth: 1))
    }

    private func vitalRow(label: String, bpm: Double?, strength: Double, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 9, weight: .bold)).tracking(1.8)
                    .foregroundColor(Palette.dim)
                if let v = bpm {
                    Text("\(Int(v.rounded()))").font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundColor(Palette.goldTxt)
                    + Text("  \(unit)").font(.system(size: 10)).foregroundColor(Palette.dim)
                } else {
                    Text("listening…").font(.system(size: 15, weight: .medium))
                        .foregroundColor(Palette.dim)
                }
            }
            Spacer()
            SignalMeter(strength: strength)
        }
        // VoiceOver speaks the same truth the eye sees — a measured value, or the
        // honest listening state. Never a fabricated number (§5.1, DOD-6.5).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bpm.map { "\(label.capitalized): \(Int($0.rounded())) \(unit)" }
                            ?? "\(label.capitalized): listening, no measurement yet")
    }

    // MARK: VG-27 install plan card — the checklist behind the map's spots

    private var installPlanCard: some View {
        let prog = InstallPlan.progress(installSpots)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("INSTALL PLAN").font(.system(size: 9, weight: .bold)).tracking(1.8)
                    .foregroundColor(Palette.dim)
                Spacer()
                Text("\(prog.installed)/\(prog.total) installed")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(prog.installed == prog.total && prog.total > 0
                                     ? Self.installedGreen : Palette.goldDk)
            }
            ForEach(installSpots) { s in
                HStack(spacing: 6) {
                    Image(systemName: s.kind.symbol)
                        .font(.system(size: 10))
                        .foregroundColor(s.installed ? Self.installedGreen : Palette.gold)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.kind.label).font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Palette.goldTxt)
                        Text(spotRoom(s).map { "near \($0)" } ?? "on the plan")
                            .font(.system(size: 8)).foregroundColor(Palette.dim)
                    }
                    Spacer(minLength: 4)
                    Button { toggleInstallSpot(s.id) } label: {
                        Text(s.installed ? "Installed ✓" : "Mark installed")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(s.installed ? Self.installedGreen : Palette.goldTxt)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.4)))
                            .overlay(Capsule().stroke(
                                s.installed ? Self.installedGreen.opacity(0.7)
                                            : Palette.goldDk.opacity(0.7), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(s.installed ? "Flip back to planned" : "The physical device is mounted at this spot")
                    Button { removeInstallSpot(s.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Palette.dim.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Remove this spot from the plan")
                }
            }
            Text("tap a spot on the map — or the button here — to mark it installed")
                .font(.system(size: 7.5)).foregroundColor(Palette.dim.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.055, green: 0.055, blue: 0.066)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.stroke, lineWidth: 1))
    }

    // MARK: fall monitor

    private var fallCard: some View {
        let fall = engine.fallState
        let state = fall?.state ?? "—"
        let alarmed = (fall?.alert != nil)
        return VStack(alignment: .leading, spacing: 4) {
            Text("FALL MONITOR").font(.system(size: 9, weight: .bold)).tracking(1.8)
                .foregroundColor(Palette.dim)
            Text(state).font(.system(size: 16, weight: .heavy))
                .foregroundColor(alarmed ? .red : (fall?.active == true ? Palette.goldTxt : Palette.dim))
            if let note = fall?.note {
                Text(note).font(.system(size: 9)).foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(
            alarmed ? Color.red.opacity(0.12) : Color(red: 0.055, green: 0.055, blue: 0.066)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(
            alarmed ? .red : Palette.stroke, lineWidth: 1))
    }

    // MARK: per-room strip

    private var roomStrip: some View {
        HStack(spacing: 10) {
            ForEach(rooms.sorted(by: { $0.key < $1.key }), id: \.key) { room, link in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle().fill(link.live ? Color.green : Palette.dim)
                            .frame(width: 5, height: 5)
                        if renamingRoom == room {
                            TextField("room name", text: $renameDraft, onCommit: {
                                commitRename(nodeId: link.node_id)
                            })
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Palette.goldTxt)
                            .frame(maxWidth: 110)
                            Button {
                                renamingRoom = nil; renameDraft = ""
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(Palette.dim)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel rename")
                        } else {
                            Text(room).font(.system(size: 11, weight: .semibold))
                                .foregroundColor(room == occupant ? Palette.goldTxt : Palette.dim)
                                .onTapGesture(count: 2) {
                                    renamingRoom = room
                                    // strip the "· zone" qualifier the engine adds
                                    // for multi-node rooms — the owner renames the
                                    // ROOM, zones stay the engine's business
                                    renameDraft = room.components(separatedBy: " · ").first ?? room
                                }
                                .help("Double-click to rename this room")
                        }
                        Spacer(minLength: 2)
                        if renamingRoom != room {
                            Button {
                                renamingRoom = room
                                renameDraft = room.components(separatedBy: " · ").first ?? room
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(Palette.dim)
                            }
                            .buttonStyle(.plain)
                            .help("Rename this room")
                        }
                        Button {
                            rfRun(node: link.node_id)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Palette.dim)
                        }
                        .buttonStyle(.plain)
                        .help("RF run: re-calibrate this room's quiet floor (~2 min, keep it still)")
                    }
                    MotionBar(motion: link.motion, baseline: link.baseline ?? 0)
                    Text(link.rssi.map { "\($0) dBm · \(Int(link.rate_hz ?? 0)) Hz" } ?? "—")
                        .font(.system(size: 8, design: .monospaced)).foregroundColor(Palette.dim)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.055, green: 0.055, blue: 0.066)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                    room == occupant ? Palette.goldDk.opacity(0.7) : Palette.stroke, lineWidth: 1))
            }
        }
    }
}

// MARK: - small pieces

struct SignalMeter: View {
    let strength: Double
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Double(i) / 5.0 < strength ? Palette.gold : Palette.stroke)
                    .frame(width: 3, height: 6 + CGFloat(i) * 3)
            }
        }
    }
}

struct MotionBar: View {
    let motion: Double
    let baseline: Double
    /// FLOOR-RELATIVE render (Founder-caught: raw amplitude pegged every bar
    /// in a still house). The bar is excess over the learned quiet floor —
    /// full at 2× floor; the tick marks the 1.3× presence threshold. Until a
    /// floor is learned the bar shows a calibrating shimmer, never a level.
    private var fraction: Double {
        guard baseline > 0 else { return 0 }
        return min(1.0, max(0.0, (motion / baseline - 1.0)))
    }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.stroke).frame(height: 3)
                if baseline > 0 {
                    Capsule().fill(Palette.gold)
                        .frame(width: max(2, geo.size.width * CGFloat(fraction)), height: 3)
                    Rectangle().fill(Palette.dim)
                        .frame(width: 1, height: 7)
                        .offset(x: geo.size.width * 0.3)   // 1.3× floor = presence
                } else {
                    Capsule().fill(Palette.dim.opacity(0.35))
                        .frame(width: geo.size.width * 0.25, height: 3)
                }
            }
        }
        .frame(height: 7)
        .animation(.easeOut(duration: 0.3), value: motion)
    }
}
#endif // circuit-convert
