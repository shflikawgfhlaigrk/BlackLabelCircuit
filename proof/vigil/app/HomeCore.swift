// Vigil — smart-home core model + pure logic (Foundation only, no SwiftUI).
//
// Everything here is deterministic and unit-testable: the device/room/scene/
// automation model, the automation evaluator, the security state machine, the
// sensor-tier recognition, and the persisted-state Codable round-trip. The
// SwiftUI stores (HomeStore.swift) wrap these types; the views render them.
//
// Honesty rule (Black Label binding): this model ships EMPTY. No fabricated
// devices, rooms, or readings — the home is whatever the user's own LAN and
// sensors actually present.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Device taxonomy

enum DeviceKind: String, Codable, CaseIterable, Identifiable {
    case light, lock, thermostat, camera, speaker, plug, toggle, sensor, fan, blind, garage, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "Light";       case .lock: return "Lock"
        case .thermostat: return "Thermostat"; case .camera: return "Camera"
        case .speaker: return "Speaker";    case .plug: return "Plug"
        case .toggle: return "Switch";      case .sensor: return "Sensor"
        case .fan: return "Fan";            case .blind: return "Blind"
        case .garage: return "Garage";      case .other: return "Device"
        }
    }
    var plural: String { label + "s" }
    var symbol: String {
        switch self {
        case .light: return "lightbulb.fill";          case .lock: return "lock.fill"
        case .thermostat: return "thermometer.medium";  case .camera: return "video.fill"
        case .speaker: return "hifispeaker.fill";       case .plug: return "powerplug.fill"
        case .toggle: return "switch.2";                case .sensor: return "sensor.fill"
        case .fan: return "fan.fill";                   case .blind: return "blinds.horizontal.closed"
        case .garage: return "door.garage.closed";      case .other: return "square.grid.2x2.fill"
        }
    }
    /// Primary capability used by tiles to pick the control affordance.
    var isSwitchable: Bool { [.light, .plug, .toggle, .fan, .speaker].contains(self) }
}

/// How a device got into the home — drives the honest "control vs. pair" state.
enum DeviceSource: String, Codable {
    case manual          // user added by hand
    case bonjour         // discovered via mDNS/Bonjour
    case ssdp            // discovered via SSDP/UPnP
    case cast            // Google Cast / AirPlay target
    case simulated       // created by the local simulation fallback — never a real radio
    var label: String {
        switch self {
        case .manual: return "Added manually"
        case .bonjour: return "Found on your network"
        case .ssdp: return "Found on your network"
        case .cast: return "Cast/AirPlay target"
        case .simulated: return "Simulated (no hardware)"
        }
    }
}

/// Whether Vigil can actuate the device, or only sees it (honest empty/over).
enum ControlState: String, Codable {
    case controllable    // we can change its state right now
    case pairRequired    // discovered, but needs pairing/commissioning we can't do under adhoc sig
    case readOnly        // we can read but not control (e.g. a sensor)
    case simulated       // local simulation fallback — actuation is local-only and honestly labelled
    case unavailable     // known device that currently cannot be served at all
}

/// The five-way truthful device label (VIGIL-3 / DOD-4.3): every device is exactly one of
/// simulated / discovered / connected / unavailable / actively controlled. The label is
/// DERIVED from stored state (`control` + `reachable`) — it cannot be set independently of
/// the truth it reports, so an offline device can never render as controlled, and a
/// simulated device can never masquerade as hardware.
enum DevicePresence: String, Codable, CaseIterable {
    case simulated           // local simulation — usable with no hardware, badged as such
    case discovered          // seen on the network, not yet paired/commissioned
    case connected           // live and readable, but Vigil does not actuate it
    case unavailable         // previously known, currently unreachable or unservable
    case activelyControlled  // live, and Vigil can change its state right now
    var label: String {
        switch self {
        case .simulated: return "Simulated"
        case .discovered: return "Discovered"
        case .connected: return "Connected"
        case .unavailable: return "Unavailable"
        case .activelyControlled: return "Actively controlled"
        }
    }
}

struct DeviceState: Codable, Equatable {
    var on: Bool?            // lights, plugs, switches, fans, speakers
    var brightness: Double?  // 0…1
    var locked: Bool?        // locks
    var targetTempF: Double? // thermostats
    var currentTempF: Double?
    var playing: Bool?       // media
    var watts: Double?       // energy-reporting plugs
    var openPct: Double?     // blinds / garage (0 closed … 1 open)
    static let empty = DeviceState()
}

struct HFDevice: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var kind: DeviceKind
    var roomID: UUID?
    var source: DeviceSource
    var control: ControlState
    var reachable: Bool = true
    var host: String?        // LAN address if any
    var model: String?       // advertised model string
    var favorite: Bool = false
    var state: DeviceState = .empty

    /// Five-way truth label — see `DevicePresence`. Pure derivation, unit-locked.
    var presence: DevicePresence {
        if control == .simulated { return .simulated }        // simulation is its own honest class
        if control == .unavailable || !reachable { return .unavailable }
        switch control {
        case .controllable: return .activelyControlled
        case .readOnly:     return .connected
        case .pairRequired: return .discovered
        case .simulated, .unavailable: return .unavailable    // covered above; keep exhaustive
        }
    }
    /// A device whose primary control affordance actually works (locally for simulated).
    var isActuatable: Bool { control == .controllable || control == .simulated }
}

/// §5.1 control honesty: `.controllable` is a claim ("Actively controlled") that must be
/// backed by a transport that can actually drive the device. The local switch transport
/// speaks WLED / Shelly / Tasmota / Kasa relay dialects — locks, blinds, garages,
/// thermostats, cameras and sensors have NO local control dialect here, so a device of
/// those kinds must never be stored as `.controllable` (a flipped "Locked" with no
/// command sent is a fabricated hardware state). Pure + unit-locked.
enum DeviceControlPolicy {
    /// Kinds the local LAN switch transport can drive. `.other` is included so a
    /// user-supplied open HTTP relay endpoint keeps working as a switch.
    static func hasSwitchTransport(_ kind: DeviceKind) -> Bool {
        kind.isSwitchable || kind == .other
    }

    /// Honest control state for a manually added device: a LAN address grants
    /// `.controllable` only for kinds the transport can drive; everything else is
    /// tracked without a control claim (readable kinds read-only, the rest pairing).
    static func manualControl(kind: DeviceKind, hasHost: Bool) -> ControlState {
        guard hasHost else { return .pairRequired }
        if hasSwitchTransport(kind) { return .controllable }
        return kind == .camera || kind == .sensor ? .readOnly : .pairRequired
    }

    /// Demote any stored device claiming `.controllable` for a kind the transport
    /// cannot drive (legacy saved states + imported configs). Idempotent.
    static func demotingUncontrollable(_ devices: [HFDevice]) -> [HFDevice] {
        devices.map { d in
            guard d.control == .controllable, !hasSwitchTransport(d.kind) else { return d }
            var fixed = d
            fixed.control = (d.kind == .camera || d.kind == .sensor) ? .readOnly : .pairRequired
            return fixed
        }
    }
}

struct HFRoom: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var symbol: String = "square.split.bottomrightquarter"
}

// MARK: - Simulated home (DOD-4.1 / VIGIL-1)

/// A functional local simulation fallback for EVERY supported hardware class, usable
/// immediately with no hardware. Pure factory — nothing is fabricated on its own: the
/// devices exist only after the user explicitly asks for them, every one is stored as
/// `source: .simulated` + `control: .simulated`, renders the SIMULATED label
/// (`DevicePresence.simulated`), and actuates purely locally (no radio, no LAN call).
/// This is the honesty rule kept intact: a simulated home is a labelled simulation,
/// never fake hardware.
enum SimulatedHome {
    /// Deterministic starting state per hardware class so the simulation is instantly
    /// exercisable: lights start off, locks start locked, thermostats hold 70°F, etc.
    static func initialState(_ kind: DeviceKind) -> DeviceState {
        var s = DeviceState.empty
        switch kind {
        case .light:      s.on = false; s.brightness = 0.5
        case .lock:       s.locked = true
        case .thermostat: s.targetTempF = 70; s.currentTempF = 68
        case .camera:     break                          // read-surface only, like real cameras
        case .speaker:    s.on = false; s.playing = false
        case .plug:       s.on = false; s.watts = 0
        case .toggle:     s.on = false
        case .sensor:     break                          // sensors report, they are not actuated
        case .fan:        s.on = false
        case .blind:      s.openPct = 0
        case .garage:     s.openPct = 0
        case .other:      s.on = false
        }
        return s
    }

    /// One simulated device for every supported hardware class (`DeviceKind.allCases`,
    /// so a newly added kind is covered by construction — the coverage test locks this).
    static func devices(roomID: UUID? = nil) -> [HFDevice] {
        DeviceKind.allCases.map { kind in
            HFDevice(name: "Simulated \(kind.label)", kind: kind, roomID: roomID,
                     source: .simulated, control: .simulated,
                     host: nil, model: "Vigil simulation",
                     state: initialState(kind))
        }
    }
}

// MARK: - Scenes

struct SceneAction: Codable, Equatable {
    var deviceID: UUID
    var state: DeviceState
}

struct HFScene: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var symbol: String = "wand.and.stars"
    var actions: [SceneAction] = []
}

enum SceneModel {
    /// Apply a scene to a device set, returning the updated devices. Pure.
    static func apply(_ scene: HFScene, to devices: [HFDevice]) -> [HFDevice] {
        var out = devices
        for act in scene.actions {
            guard let i = out.firstIndex(where: { $0.id == act.deviceID }) else { continue }
            var s = out[i].state
            if let v = act.state.on { s.on = v }
            if let v = act.state.brightness { s.brightness = v }
            if let v = act.state.locked { s.locked = v }
            if let v = act.state.targetTempF { s.targetTempF = v }
            if let v = act.state.playing { s.playing = v }
            if let v = act.state.openPct { s.openPct = v }
            out[i].state = s
        }
        return out
    }
}

// MARK: - Security

enum SecurityMode: String, Codable, CaseIterable, Identifiable {
    case home, away, night, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: return "Home"; case .away: return "Away"
        case .night: return "Night"; case .off: return "Off"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house.fill";  case .away: return "figure.walk.departure"
        case .night: return "moon.stars.fill"; case .off: return "shield.slash"
        }
    }
    /// Armed modes treat sensed presence as an event worth alerting on.
    var isArmed: Bool { self == .away || self == .night }
}

enum SecurityModel {
    /// Intrusion = an armed mode plus sensed presence somewhere monitored. Pure.
    /// (Instantaneous check — the runtime uses `phase(…)` below, which adds the
    /// exit/entry delays every trustworthy alarm system has.)
    static func isIntrusion(mode: SecurityMode, occupiedRooms: Set<UUID>, anyPresence: Bool) -> Bool {
        guard mode.isArmed else { return false }
        return anyPresence || !occupiedRooms.isEmpty
    }

    // MARK: exit / entry delays (false-alarm honesty)
    //
    // Without these, the machine alarms on the OWNER by design: click "Away" while
    // still inside → your own presence trips the alarm instantly; walk back in the
    // door → alarm before you can reach the app. A security mode that cries wolf on
    // its own household is not trustworthy, and an untrustworthy alarm gets turned
    // off. Industry-standard fix, expressed as a pure time-injected state machine:
    //
    //   exitGrace    — after arming, sensed presence is expected (you're leaving);
    //                  quiet until the grace expires. Away 60s; Night 30s.
    //   entryPending — first presence past the grace under Away starts a 30s
    //                  disarm window (log + notify, no siren yet). Disarm in time
    //                  → no alarm. Night skips this: nobody "returns home" into a
    //                  house that's asleep — presence past grace alarms at once.
    //   alarm        — presence held past its window (or any presence under Night).

    static let exitDelayAwayS: TimeInterval = 60
    static let exitDelayNightS: TimeInterval = 30
    static let entryDelayS: TimeInterval = 30

    static func exitDelay(_ mode: SecurityMode) -> TimeInterval {
        switch mode {
        case .away: return exitDelayAwayS
        case .night: return exitDelayNightS
        case .home, .off: return 0
        }
    }

    enum AlarmPhase: Equatable {
        case quiet
        case exitGrace(until: Date)     // armed moments ago — leave now, presence ignored
        case entryPending(until: Date)  // presence while armed Away — disarm before `until`
        case alarm                      // intrusion: presence held past its window
    }

    /// The full alarm decision. Pure — every clock input is a parameter.
    ///   armedAt       when the current armed mode was set (nil = armed before this
    ///                  process started → no grace; the safe side is monitoring, not
    ///                  an indefinite grace).
    ///   presenceSince when the current continuous presence began (nil = none sensed).
    static func phase(mode: SecurityMode,
                      anyPresence: Bool,
                      occupiedRooms: Set<UUID>,
                      armedAt: Date?,
                      presenceSince: Date?,
                      now: Date) -> AlarmPhase {
        guard mode.isArmed else { return .quiet }
        let graceEnd = armedAt.map { $0.addingTimeInterval(exitDelay(mode)) }
        if let graceEnd, now < graceEnd { return .exitGrace(until: graceEnd) }
        guard anyPresence || !occupiedRooms.isEmpty else { return .quiet }
        if mode == .night { return .alarm }
        // Away: the 30s disarm window opens when presence starts COUNTING — at the
        // presence edge, or at grace expiry if the presence never cleared (you armed
        // Away and failed to leave: gentle pending first, siren only if it holds).
        let countedFrom = Swift.max(presenceSince ?? now, graceEnd ?? .distantPast)
        let deadline = countedFrom.addingTimeInterval(entryDelayS)
        return now < deadline ? .entryPending(until: deadline) : .alarm
    }
}

// MARK: - Local siren (VG-13)

/// VG-13 — local siren. Vigil ships NO siren hardware of its own (§5.5); on an intrusion
/// alarm it actuates a device the buyer ALREADY controls — a favorited, controllable LAN
/// device (strobe a light / toggle a plug / sound a speaker) — as a visible/audible
/// deterrent. Pure selection so the "which device fires / honest none" decision is
/// unit-lockable with no network. Honesty rails live in HomeStore.driveSiren: a siren is
/// logged as SOUNDED only on a real success from the device; a device that never answered
/// is never claimed as a siren that fired (§5.1).
enum SirenSelector {
    /// Pick the device to drive as the siren on intrusion: a FAVORITED, controllable,
    /// switchable device with a real LAN endpoint we can actually actuate. Returns nil →
    /// the honest "no siren device connected" state (never a fabricated siren, §5.2).
    static func pick(from devices: [HFDevice]) -> HFDevice? {
        devices.first { $0.favorite
            && $0.control == .controllable
            && $0.kind.isSwitchable
            && ($0.host?.isEmpty == false) }
    }

    /// Honest one-line status for the Security siren row. Never claims a siren is armed
    /// when nothing controllable is favorited.
    static func statusLabel(for device: HFDevice?) -> String {
        guard let d = device else {
            return "No siren device connected — favorite a controllable light, plug or speaker and Vigil will sound it on an alarm."
        }
        return "On an alarm, Vigil drives “\(d.name)” (\(d.kind.label.lowercased())) as a local siren."
    }
}

// MARK: - Exclusion zones (VG-26)

/// VG-26 — draw-your-room EXCLUSION ZONES. A buyer masks a rectangular area of the room
/// map (a couch pile, a curtain over a vent, a fan) whose motion should NOT count as a
/// person — designing out the "pillows are people" false-positive. Pure + value-typed so
/// suppression is unit-lockable with no view: a presence point inside any zone is
/// suppressed; a point outside passes; zones round-trip through Codable.
struct ExclusionZone: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var minX: Double, minY: Double, maxX: Double, maxY: Double   // unit coords, 0…1

    enum CodingKeys: String, CodingKey { case id, minX, minY, maxX, maxY }

    init(id: UUID = UUID(), minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.id = id
        self.minX = Swift.min(minX, maxX); self.maxX = Swift.max(minX, maxX)
        self.minY = Swift.min(minY, maxY); self.maxY = Swift.max(minY, maxY)
    }

    /// Build from two opposite corners (unit coords). nil when the rectangle is degenerate
    /// (a stray single tap) so a zero-area zone can never silently suppress the whole map.
    init?(cornerA a: [Double], cornerB b: [Double]) {
        guard a.count == 2, b.count == 2 else { return nil }
        func clamp(_ v: Double) -> Double { Swift.min(1.0, Swift.max(0.0, v)) }
        let x0 = clamp(a[0]), y0 = clamp(a[1]), x1 = clamp(b[0]), y1 = clamp(b[1])
        guard abs(x0 - x1) > 0.02, abs(y0 - y1) > 0.02 else { return nil }
        self.init(minX: x0, minY: y0, maxX: x1, maxY: y1)
    }

    /// Inclusive-of-edge containment in unit coords.
    func contains(_ p: [Double]) -> Bool {
        guard p.count == 2 else { return false }
        return p[0] >= minX && p[0] <= maxX && p[1] >= minY && p[1] <= maxY
    }
}

enum ExclusionZones {
    /// True when a presence point falls inside ANY exclusion zone → its motion is
    /// suppressed (not counted as a person). With no zones nothing is suppressed (§5.2 —
    /// the map ships with zero masks and shows every real disturbance until the buyer
    /// draws one).
    static func suppresses(_ point: [Double], zones: [ExclusionZone]) -> Bool {
        zones.contains { $0.contains(point) }
    }

    /// Keep only the presence points OUTSIDE every exclusion zone.
    static func passing(_ points: [[Double]], zones: [ExclusionZone]) -> [[Double]] {
        points.filter { !suppresses($0, zones: zones) }
    }
}

// MARK: - Install spots (VG-27)

/// VG-27 — INSTALL SPOTS: owner-planned mounting positions on the house map — where a
/// camera goes, where a lock goes, where every device kind Vigil models gets installed.
/// A spot is an owner ANNOTATION exactly like user walls and exclusion zones: it never
/// fabricates a device row, a reading, or presence (§5.1). The buyer plans placements
/// on the learned map (works even before any hardware arrives), then flips a spot to
/// "installed" once the physical device is actually mounted.
struct InstallSpot: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var kind: DeviceKind
    var pos: [Double]            // unit coords 0…1 on the learned map
    var installed: Bool = false

    init(id: UUID = UUID(), kind: DeviceKind, pos: [Double], installed: Bool = false) {
        self.id = id; self.kind = kind; self.pos = pos; self.installed = installed
    }

    /// Build from a tapped point (unit coords), clamped on-map. nil for a malformed or
    /// non-finite point — a spot can never land off the map (ExclusionZone's contract).
    init?(kind: DeviceKind, at p: [Double]) {
        guard p.count == 2, p[0].isFinite, p[1].isFinite else { return nil }
        func clamp(_ v: Double) -> Double { Swift.min(1.0, Swift.max(0.0, v)) }
        self.init(kind: kind, pos: [clamp(p[0]), clamp(p[1])])
    }
}

enum InstallPlan {
    /// The spot nearest a tapped point, within `radius` (unit coords) — the hit-test
    /// behind tap-to-toggle. nil when nothing is close enough, so a tap on empty
    /// floor can never mutate a distant spot.
    static func nearest(to p: [Double], in spots: [InstallSpot], within radius: Double) -> InstallSpot? {
        guard p.count == 2 else { return nil }
        var best: (spot: InstallSpot, d2: Double)? = nil
        for s in spots where s.pos.count == 2 {
            let dx = s.pos[0] - p[0], dy = s.pos[1] - p[1]
            let d2 = dx * dx + dy * dy
            if d2 <= radius * radius, d2 < (best?.d2 ?? .infinity) { best = (s, d2) }
        }
        return best?.spot
    }

    /// Nearest learned-room label for a spot — display only ("Camera · bedroom").
    /// nil when no learned rooms exist yet: the plan NEVER invents a room (§5.1).
    static func nearestRoom(to p: [Double], rooms: [(label: String, pos: [Double])]) -> String? {
        guard p.count == 2 else { return nil }
        var best: (label: String, d2: Double)? = nil
        for r in rooms where r.pos.count == 2 {
            let dx = r.pos[0] - p[0], dy = r.pos[1] - p[1]
            let d2 = dx * dx + dy * dy
            if d2 < (best?.d2 ?? .infinity) { best = (r.label, d2) }
        }
        return best?.label
    }

    /// Honest progress over the plan: (installed, total). Zero spots = (0, 0).
    static func progress(_ spots: [InstallSpot]) -> (installed: Int, total: Int) {
        (spots.filter(\.installed).count, spots.count)
    }
}

// MARK: - Automations

enum TriggerKind: String, Codable, CaseIterable, Identifiable {
    case presenceEnter   // someone enters a room (from sensing)
    case presenceLeave   // a room goes empty
    case timeOfDay       // a specific minute of the day
    case sunrise, sunset
    case securityMode    // mode changed to X
    case deviceOn        // a device turned on (real LAN/control state edge)
    case deviceOff       // a device turned off
    case sensorOnline    // a Vigil sensor node came online
    case sensorOffline   // a Vigil sensor node dropped offline
    case geofenceArrive  // the buyer's device entered the home geofence (real CoreLocation crossing)
    case geofenceDepart  // the buyer's device left the home geofence
    var id: String { rawValue }
    var label: String {
        switch self {
        case .presenceEnter: return "When a room becomes occupied"
        case .presenceLeave: return "When a room becomes empty"
        case .timeOfDay: return "At a time of day"
        case .sunrise: return "At sunrise"
        case .sunset: return "At sunset"
        case .securityMode: return "When security mode changes"
        case .deviceOn: return "When a device turns on"
        case .deviceOff: return "When a device turns off"
        case .sensorOnline: return "When a sensor node comes online"
        case .sensorOffline: return "When a sensor node goes offline"
        case .geofenceArrive: return "When I arrive home"
        case .geofenceDepart: return "When I leave home"
        }
    }
}

struct Trigger: Codable, Equatable {
    var kind: TriggerKind
    var roomID: UUID? = nil      // presence triggers
    var minuteOfDay: Int? = nil  // timeOfDay (0…1439)
    var mode: SecurityMode? = nil
    var deviceID: UUID? = nil    // device-state triggers (nil = any device)
    var tier: SensorTier? = nil  // sensor triggers (nil = any tier)
}

// MARK: - Automation conditions (the "→ conditions →" middle of the spine)

/// A guard the automation must satisfy at fire time, evaluated against a snapshot
/// of the home. The standard calls for a triggers → conditions → actions evaluator;
/// conditions are pure AND-combined gates so the same trigger can be narrowed
/// (e.g. "only when armed Away", "only after sunset", "only if no one is home").
enum ConditionKind: String, Codable, CaseIterable, Identifiable {
    case securityModeIs   // home is in security mode X
    case timeWindow       // current minute is within [start, end] (wraps midnight)
    case presenceIs       // someone is / is not home
    case deviceIsOn       // a specific device is currently on
    var id: String { rawValue }
    var label: String {
        switch self {
        case .securityModeIs: return "Only when security mode is"
        case .timeWindow: return "Only between two times"
        case .presenceIs: return "Only when someone is / isn't home"
        case .deviceIsOn: return "Only when a device is on"
        }
    }
}

struct Condition: Codable, Equatable {
    var kind: ConditionKind
    var mode: SecurityMode? = nil   // securityModeIs
    var startMinute: Int? = nil     // timeWindow (0…1439)
    var endMinute: Int? = nil       // timeWindow (0…1439)
    var present: Bool? = nil        // presenceIs (true = someone home)
    var deviceID: UUID? = nil       // deviceIsOn
}

/// A point-in-time snapshot of the home the condition evaluator reads. Pure value
/// type so conditions stay deterministic and unit-testable with no live store.
struct HomeSnapshot: Equatable {
    var securityMode: SecurityMode
    var minuteOfDay: Int
    var homePresent: Bool
    var deviceOnByID: [UUID: Bool]

    init(securityMode: SecurityMode = .off, minuteOfDay: Int = 0,
         homePresent: Bool = false, deviceOnByID: [UUID: Bool] = [:]) {
        self.securityMode = securityMode
        self.minuteOfDay = minuteOfDay
        self.homePresent = homePresent
        self.deviceOnByID = deviceOnByID
    }
}

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case runScene
    case setSecurityMode
    case setDeviceOn
    case setDeviceOff
    case notify
    var id: String { rawValue }
}

struct HomeAction: Codable, Equatable {
    var kind: ActionKind
    var sceneID: UUID? = nil
    var deviceID: UUID? = nil
    var mode: SecurityMode? = nil
    var message: String? = nil
}

struct HFAutomation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var enabled: Bool = true
    var trigger: Trigger
    var conditions: [Condition] = []   // AND-combined guards; empty = always passes
    var actions: [HomeAction] = []

    // Backward-compatible decode: older home.json has no `conditions` key.
    enum CodingKeys: String, CodingKey { case id, name, enabled, trigger, conditions, actions }
    init(id: UUID = UUID(), name: String, enabled: Bool = true,
         trigger: Trigger, conditions: [Condition] = [], actions: [HomeAction] = []) {
        self.id = id; self.name = name; self.enabled = enabled
        self.trigger = trigger; self.conditions = conditions; self.actions = actions
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        conditions = try c.decodeIfPresent([Condition].self, forKey: .conditions) ?? []
        actions = try c.decodeIfPresent([HomeAction].self, forKey: .actions) ?? []
    }
}

/// Events the home reacts to. Produced by sensing + the clock.
enum HomeEvent: Equatable {
    case presenceEntered(roomID: UUID)
    case presenceLeft(roomID: UUID)
    case minuteTick(minuteOfDay: Int)
    case sunrise
    case sunset
    case securityModeChanged(SecurityMode)
    case deviceTurnedOn(deviceID: UUID)
    case deviceTurnedOff(deviceID: UUID)
    case sensorCameOnline(tier: SensorTier)
    case sensorWentOffline(tier: SensorTier)
    case geofenceEntered    // a real CoreLocation crossing INTO the configured home region
    case geofenceLeft       // a real CoreLocation crossing OUT of the configured home region
}

// AutomationEvaluator lives in Automation.swift (the focused, deeply-tested
// triggers → conditions → actions evaluator per the architecture directive).

// MARK: - Sensor line (own-brand hardware)

enum SensorTier: String, Codable, CaseIterable, Identifiable {
    case node, sentry, pulse
    var id: String { rawValue }
    var productName: String {
        switch self {
        case .node: return "Vigil Node"
        case .sentry: return "Vigil Sentry"
        case .pulse: return "Vigil Pulse"
        }
    }
    var priceUSD: Int {
        switch self { case .node: return 25; case .sentry: return 39; case .pulse: return 59 }
    }
    var job: String {
        switch self {
        case .node: return "Presence & occupancy — one per room"
        case .sentry: return "Through-wall intrusion security"
        case .pulse: return "Breathing & heart vitals, safety alerts"
        }
    }
    var unlocks: String {
        switch self {
        case .node: return "Room presence + motion; lights & climate follow you."
        case .sentry: return "Arms with Away; presence in an empty house → alert, no camera."
        case .pulse: return "Vitals (accurate-or-nothing) + no-motion / fall alerts."
        }
    }
    var symbol: String {
        switch self {
        case .node: return "dot.radiowaves.left.and.right"
        case .sentry: return "shield.lefthalf.filled"
        case .pulse: return "waveform.path.ecg"
        }
    }
    /// The string the firmware advertises (UDP "tier" field / Bonjour TXT).
    var advertised: String { "Homefront-" + rawValue.capitalized }

    /// Recognize one of OUR nodes from its advertised model/tier string. Pure.
    static func recognize(_ advertised: String?) -> SensorTier? {
        guard let a = advertised?.lowercased() else { return nil }
        if a.contains("sentry") { return .sentry }
        if a.contains("pulse") { return .pulse }
        if a.contains("node") || a.contains("homefront") || a.contains("vigil") { return .node }
        return nil
    }

    /// The own-brand boards are EARLY ACCESS: real designs on one firmware, but not
    /// yet in buyers' hands. In-app copy must say so (§5.1) — never imply a buyer can
    /// use through-wall sensing today without the hardware. HF-4.
    var isEarlyAccess: Bool { true }
    static let earlyAccessBadge = "EARLY ACCESS"
}

// MARK: - Sense modality availability (honest in-app labels, HF-4 / §5.1)

/// Which Vigil sensing modalities run TODAY, on-device, on any Mac (microphone
/// acoustic sonar + camera 3D pose / rPPG) vs which are EARLY ACCESS — real and
/// built, but gated on the ~$9 ESP32 CSI hardware that isn't in buyers' hands yet.
/// This drives honest in-app labels: through-wall / WiFi-CSI must NOT read as a
/// shipping consumer feature until the boards ship (§5.1). Pure + unit-tested.
enum SenseModality: String, CaseIterable {
    case acousticSonar     // microphone ranging — ships now, on-device
    case cameraPose        // camera: Vision 3D pose + rPPG — ships now, on-device
    case csiThroughWall    // WiFi-CSI through-wall reader — early access (needs a node)
    case liveWiFi          // WiFi-CSI presence radar — early access (needs a node)

    enum Availability: Equatable { case shippingOnDevice, earlyAccessHardware }

    var availability: Availability {
        switch self {
        case .acousticSonar, .cameraPose: return .shippingOnDevice
        case .csiThroughWall, .liveWiFi:  return .earlyAccessHardware
        }
    }
    var isEarlyAccess: Bool { availability == .earlyAccessHardware }

    /// The honest availability badge shown next to the sense view.
    var availabilityLabel: String {
        switch availability {
        case .shippingOnDevice:    return "On-device now"
        case .earlyAccessHardware: return "Early access · ships with the hardware"
        }
    }
    /// A one-line honest explainer for an early-access modality's empty state —
    /// real and built, but not a live reading until a node streams.
    var earlyAccessNote: String {
        "Real and built — but through-wall WiFi-CSI needs a Vigil node (a ~$9 ESP32). "
        + "It goes live the moment a node streams; until the boards ship, this is early access, not a live reading."
    }
}

enum VigilPlatform {
    static let intelCSINotice = "WiFi sensing requires Apple Silicon; sonar + camera sensing work on this Mac."

    static func csiBoundaryMessage(isAppleSilicon: Bool) -> String? {
        isAppleSilicon ? nil : intelCSINotice
    }
}

struct HFSensorNode: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var tier: SensorTier
    var name: String
    var roomID: UUID?
    var online: Bool = false
    var framesSeen: Int = 0
}

// MARK: - Presence debounce (Schmitt-trigger hysteresis)

/// Confirms whole-home presence transitions with asymmetric dwell. The raw
/// sensing signal (CSI / sonar / camera fusion) can chatter many times per
/// second as a person moves through detection range; committing a transition on
/// every raw edge is GAP #D — it floods the 500-event activity ring with
/// "Presence detected"/"Room clear" pairs (live store: 250+250 in ~36 min,
/// median 0.4s apart) and evicts every device/scene/security/anomaly event.
///
/// `step` commits a transition ONLY after the signal has been stably in the new
/// state for the dwell window, so the caller logs / fires / arms exactly once.
/// Hysteresis is intentional: `enterDwell` is short (presence feels responsive)
/// and `leaveDwell` is long (a brief CSI dropout must NOT clear an occupied room
/// and flap eco/security). Pure + value-typed → unit-testable on synthetic
/// timestamps with no clock. §5.1: presence events stay real; this only
/// suppresses physically-impossible sub-second toggles, never invents presence.
struct PresenceDebouncer: Equatable {
    private(set) var confirmed: Bool
    private var candidate: Bool?
    private var candidateSince: Date?
    let enterDwell: TimeInterval
    let leaveDwell: TimeInterval

    init(confirmed: Bool = false, enterDwell: TimeInterval = 3, leaveDwell: TimeInterval = 30) {
        self.confirmed = confirmed
        self.enterDwell = enterDwell
        self.leaveDwell = leaveDwell
    }

    /// Feed one raw sensed value. Returns the new confirmed state on a committed
    /// transition (caller acts once); nil while the signal agrees with the
    /// confirmed state or a candidate flip is still settling.
    mutating func step(raw: Bool, now: Date) -> Bool? {
        if raw == confirmed {            // signal agrees → cancel any pending flip
            candidate = nil
            candidateSince = nil
            return nil
        }
        if candidate != raw {            // new disagreement → (re)start the dwell timer
            candidate = raw
            candidateSince = now
            return nil
        }
        let dwell = raw ? enterDwell : leaveDwell
        guard let since = candidateSince, now.timeIntervalSince(since) >= dwell else { return nil }
        confirmed = raw
        candidate = nil
        candidateSince = nil
        return confirmed
    }
}

// MARK: - Activity log

enum ActivityKind: String, Codable {
    case presence, device, scene, security, sensor, alert, system, anomaly, fall
    var symbol: String {
        switch self {
        case .presence: return "figure.walk"; case .device: return "switch.2"
        case .scene: return "wand.and.stars"; case .security: return "shield.fill"
        case .sensor: return "antenna.radiowaves.left.and.right"
        case .alert: return "exclamationmark.triangle.fill"; case .system: return "gearshape.fill"
        case .anomaly: return "waveform.path.ecg"
        case .fall: return "figure.fall"
        }
    }
    /// Critical eldercare/security events that must never be silently evicted from
    /// the bounded activity ring (see ActivityRing.trimmed) and render red in the UI.
    var isCritical: Bool { self == .alert || self == .anomaly || self == .fall }
}

/// Pure decision for escalating a logged event to a DESKTOP NOTIFICATION — the
/// §5.1-honest, isCritical-gated contract that the live store (HomeStore.logCritical)
/// and the eldercare poller share. The single most critical product event (a fall)
/// must reach a caregiver who isn't looking at the app; this names *what* gets pushed
/// and *whether* it should be. Returns nil for any non-critical kind, so routine
/// device/presence/scene events can never raise a notification (no spam). The resident
/// NAME is included ONLY when one is positively known (HomeState.soleResident); a nil
/// resident yields an UNNAMED body — never a guessed occupant. Pure + value-typed so
/// the transition→notify contract is unit-lockable without a live UNUserNotificationCenter.
enum CriticalAlert {
    /// Notification title for a critical kind (caller gates on isCritical first).
    static func title(for kind: ActivityKind) -> String {
        switch kind {
        case .fall:    return "Vigil — fall / emergency"
        case .anomaly: return "Vigil — eldercare anomaly"
        case .alert:   return "Vigil — security"
        default:       return "Vigil"
        }
    }
    /// The (title, body) to deliver, or nil when `kind` is not critical. Body carries
    /// the resident name only when `resident` is non-nil (§5.1 — no guessed occupant).
    static func notice(for kind: ActivityKind, message: String, resident: Resident?) -> (title: String, body: String)? {
        guard kind.isCritical else { return nil }
        let body: String
        if let name = resident?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            body = "\(name): \(message)"
        } else {
            body = message
        }
        return (title(for: kind), body)
    }
}

/// Pure mapping from the OS notification-authorization status to the HONEST state
/// Vigil's Fall/emergency card shows. For a fall-detection SAFETY product the
/// delivery path's truth IS the product: the card must NEVER claim alerts are
/// "armed/on" when the OS would silently drop them (`.notDetermined`) or has denied
/// them. Value-typed and unit-lockable WITHOUT a live UNUserNotificationCenter
/// (mirrors CriticalAlert) — a test builds it from a raw status and asserts the card
/// label + whether alerts actually deliver. The live store maps
/// `UNNotificationSettings.authorizationStatus.rawValue` through `from(rawValue:)`,
/// keeping HomeCore free of a hard UserNotifications dependency.
enum NotifAuthState: Equatable {
    case unknown        // not yet queried (cold boot, before getNotificationSettings returns)
    case notDetermined  // never asked — the OS SILENTLY DROPS every alert until enabled
    case denied         // buyer/OS turned alerts off — alerts will not deliver
    case authorized     // alerts deliver
    case provisional    // quiet/provisional delivery — still reaches the caregiver

    /// Map a UNAuthorizationStatus rawValue: 0 notDetermined / 1 denied /
    /// 2 authorized / 3 provisional / 4 ephemeral (treated as provisional = live).
    /// Any unrecognized value defaults to notDetermined — the SAFE side (never a
    /// false "on").
    static func from(rawValue: Int) -> NotifAuthState {
        switch rawValue {
        case 1:    return .denied
        case 2:    return .authorized
        case 3, 4: return .provisional
        default:   return .notDetermined
        }
    }

    /// True ONLY when a critical alert will actually be delivered. The card may claim
    /// "on" only here — never on `.notDetermined` (that is the silent-drop trap).
    var alertsDeliver: Bool { self == .authorized || self == .provisional }

    /// Honest one-line status for the Fall/emergency card. Never a fabricated "on".
    var cardLabel: String {
        switch self {
        case .unknown:                   return "Checking notification permission…"
        case .authorized, .provisional:  return "Alerts on — a gated fall or emergency notifies you here."
        case .notDetermined:             return "Alerts off — enable notifications so a fall reaches you when you’re not watching."
        case .denied:                    return "Alerts denied — turn them on in System Settings ▸ Notifications ▸ Vigil."
        }
    }

    /// Whether the in-app "Enable" action can still raise the system prompt. Once the
    /// status is determined (authorized/denied) the OS will not re-prompt, so the UI
    /// routes the buyer to System Settings instead of offering a dead button.
    var canEnableInApp: Bool { self == .unknown || self == .notDetermined }
}

/// Buyer-supplied OFF-DEVICE relay endpoint for critical alerts. Vigil is own-it /
/// §5.5: we run NO hosted push service. Instead the buyer brings their OWN endpoint —
/// an ntfy / Slack / Telegram-bridge / Make/Zapier / n8n / generic webhook URL they
/// control — and Vigil POSTs the SAME (title, body) it shows locally, IN ADDITION
/// to the desktop banner, so a fall reaches a caregiver who is not at this Mac. Ships
/// EMPTY (no default endpoint, ever — §5.2). A blank or malformed URL is "not
/// configured": the app never claims remote alerting is on without a real, validated
/// endpoint (§5.1).
struct RemoteRelayConfig: Codable, Equatable {
    /// The buyer's webhook URL. Empty by default; never shipped with a value.
    var webhook: String = ""

    /// Outcome of the LAST off-device relay POST, persisted so the Fall card can show
    /// at-a-glance whether the relay is actually reaching the caregiver (configured ≠
    /// proven-working). Written ONLY by HomeStore.sendRemoteRelay from the real URLSession
    /// result; nil = nothing sent yet (honest empty, §5.2). Reset whenever the endpoint
    /// changes so stale health never rides onto a new relay (§5.1).
    var lastDelivery: RelayDelivery? = nil

    /// The validated endpoint, or nil when blank/malformed. ONLY absolute http(s) URLs
    /// with a host are accepted — a malformed string is REJECTED (never silently kept
    /// as if it were a working relay). The single source of "configured".
    var endpointURL: URL? { RemoteRelayConfig.validate(webhook) }

    /// True only when a real, validated endpoint is set — the only state in which the
    /// UI may say remote alerts are on (§5.1). A non-empty-but-malformed webhook is NOT
    /// configured.
    var isConfigured: Bool { endpointURL != nil }

    /// Honest one-line status for the relay row. Never a fabricated "armed".
    var statusLabel: String {
        if isConfigured { return "Remote alerts on — a gated fall is also POSTed to your relay." }
        if webhook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Remote alerts: not configured — add a webhook URL to reach a caregiver off this Mac."
        }
        return "Remote alerts off — that URL isn’t a valid http(s) endpoint."
    }

    /// Validate a raw string into an endpoint URL. nil (rejected) unless it is an
    /// absolute http/https URL with a non-empty host.
    static func validate(_ raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = URL(string: t),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty else { return nil }
        return u
    }
}

/// One off-device relay POST outcome, persisted on RemoteRelayConfig so the Fall card can
/// show whether the LAST critical alert actually reached the buyer's relay. `ok` is true
/// ONLY on a real 2xx; a non-2xx or a transport error is `ok == false`. Never fabricated —
/// written solely by HomeStore.sendRemoteRelay from the URLSession result.
struct RelayDelivery: Codable, Equatable {
    var at: Date
    var ok: Bool
}

/// Pure mapping of the relay's last-delivery outcome -> the at-a-glance health line on the
/// Fall card (configured != proven-working). Value-typed + pure so the
/// (last-POST-outcome -> card-label) contract is unit-lockable WITHOUT a live network
/// (mirrors CriticalAlert.notice / NotifAuthState). Honesty baked in: an UNCONFIGURED relay
/// has NO health line (nil — never imply a channel that isn't there, §5.2); a non-2xx or
/// transport failure can NEVER read as delivered (§5.1).
enum RelayHealth: Equatable {
    case reached(Date)   // the last critical POST got a real 2xx
    case failed(Date)    // the last POST returned non-2xx OR hit a transport error
    case noneSent        // configured, but no critical alert has been POSTed yet (honest empty)

    /// The ONLY constructor — nil means render NO health line (the relay is not
    /// configured). Otherwise the three honest states. The view never builds a case directly.
    static func forCard(isConfigured: Bool, last: RelayDelivery?) -> RelayHealth? {
        guard isConfigured else { return nil }
        guard let d = last else { return .noneSent }
        return d.ok ? .reached(d.at) : .failed(d.at)
    }

    /// SF Symbol for the row. A failure is a warning triangle, NEVER the success check.
    var symbol: String {
        switch self {
        case .reached:  return "checkmark.circle.fill"
        case .failed:   return "exclamationmark.triangle.fill"
        case .noneSent: return "minus.circle"
        }
    }

    /// True ONLY for a delivered (2xx) state — drives the green tint. A .failed state is
    /// never "ok" (§5.1: a non-2xx can never read as delivered).
    var ok: Bool { if case .reached = self { return true } else { return false } }

    /// The timestamp the view should render (· HH:mm), or nil for the empty state.
    var at: Date? {
        switch self {
        case .reached(let d), .failed(let d): return d
        case .noneSent:                       return nil
        }
    }

    /// The card text. `clock` is a pre-formatted "HH:mm" the view supplies from `at`
    /// (empty for .noneSent). Wording is the honest ceiling: "reached relay", never
    /// "delivered to caregiver".
    func text(clock: String) -> String {
        switch self {
        case .reached:  return "Last alert reached relay · \(clock)"
        case .failed:   return "Last alert FAILED to reach relay · \(clock)"
        case .noneSent: return "No alert sent yet"
        }
    }
}

// MARK: - Geofence (arrive/leave-home automation triggers, §2 spine)

/// A raw region crossing as the OS reports it. Pure value so the
/// (crossing → HomeEvent) contract is unit-lockable without a live CLLocationManager.
enum GeofenceCrossing: Equatable { case entered, left }

/// The buyer's HOME region for the arrive/leave-home automation triggers. Vigil is
/// own-it/§5.5 — no hosted location service: the buyer's OWN device monitors a single
/// region (a coordinate + radius they set, typically "to my current location"). Ships
/// EMPTY (radius 0 = not configured, §5.2). The app never claims geofencing is on
/// without a real, valid region (§5.1); an out-of-range coordinate is REJECTED, and the
/// (0,0) coordinate is the unset sentinel — never a configured home.
struct GeofenceRegion: Codable, Equatable {
    var latitude: Double = 0
    var longitude: Double = 0
    var radiusMeters: Double = 0    // 0 (the default) = not configured — ships empty
    var label: String = ""          // optional human label, e.g. "Home"

    /// Valid only when the coordinate is a real lat/lon AND the radius is positive. The
    /// single source of "configured": a UI may say arrive/leave triggers are live only here.
    var isConfigured: Bool {
        radiusMeters > 0
            && latitude  >= -90  && latitude  <= 90
            && longitude >= -180 && longitude <= 180
            && !(latitude == 0 && longitude == 0)
    }

    /// Honest one-line status for the trigger row. Never a fabricated "monitoring".
    var statusLabel: String {
        guard isConfigured else {
            return "Home region not set — set it to your current location so arrive/leave can trigger."
        }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = name.isEmpty ? "your home region" : "\u{201C}\(name)\u{201D}"
        return "Monitoring \(place) · \(Int(radiusMeters)) m radius."
    }
}

/// Honest CoreLocation authorization state for the geofence trigger — mirrors
/// NotifAuthState. When access is missing the trigger surfaces a "Location access
/// needed" state and emits NO arrive/leave event; it can never fabricate a crossing the
/// OS didn't report (§5.1, fail-closed like Automation.swift).
enum GeofenceAuthState: Equatable {
    case unknown        // not yet queried (cold boot)
    case notDetermined  // never asked — no region events until granted
    case restricted     // MDM/parental restriction — cannot use location
    case denied         // buyer/OS turned location off — no arrive/leave events
    case authorized     // can monitor the home region

    /// Map a CLAuthorizationStatus rawValue: 0 notDetermined / 1 restricted / 2 denied /
    /// 3 authorizedAlways / 4 authorizedWhenInUse. Always (3) and WhenInUse (4) both
    /// monitor while the app runs → authorized. Any unrecognized value defaults to
    /// notDetermined — the SAFE side (never a false "on").
    static func from(rawValue: Int) -> GeofenceAuthState {
        switch rawValue {
        case 1:    return .restricted
        case 2:    return .denied
        case 3, 4: return .authorized
        default:   return .notDetermined
        }
    }

    /// True ONLY when the home region can actually be monitored. The trigger may claim
    /// "monitoring" only here — never on notDetermined/denied/restricted.
    var monitoringEligible: Bool { self == .authorized }

    /// Honest one-line status for the trigger row. Never a fabricated "on".
    var cardLabel: String {
        switch self {
        case .unknown:        return "Checking location permission…"
        case .authorized:     return "Location access on — arrive/leave can trigger."
        case .notDetermined:  return "Location access needed — grant it so arriving/leaving home can trigger automations."
        case .denied:         return "Location access denied — turn it on in System Settings ▸ Privacy & Security ▸ Location Services ▸ Vigil."
        case .restricted:     return "Location access is restricted on this Mac — arrive/leave can't be monitored."
        }
    }

    /// Whether the in-app "Grant" action can still raise the system prompt. Once the
    /// status is determined the OS won't re-prompt, so the UI routes to System Settings
    /// instead of offering a dead button (§5.8 — no dead control).
    var canRequestInApp: Bool { self == .unknown || self == .notDetermined }
}

/// Pure decision: a raw region crossing maps to a HomeEvent ONLY when geofencing is
/// actually live (authorized AND a configured region). Missing permission or no region →
/// NO event — the trigger can never fabricate an arrive/leave (§5.1, fail-closed). This is
/// the load-bearing seam the live CLLocationManager delegate routes through, so the
/// denied/unconfigured honesty is unit-lockable without a real GPS crossing.
enum GeofenceModel {
    static func event(for crossing: GeofenceCrossing,
                      auth: GeofenceAuthState,
                      isConfigured: Bool) -> HomeEvent? {
        guard auth.monitoringEligible, isConfigured else { return nil }
        switch crossing {
        case .entered: return .geofenceEntered
        case .left:    return .geofenceLeft
        }
    }
}

/// A fully-built off-device POST for one critical event — value-typed so the
/// transition→relay contract is unit-lockable WITHOUT a live network (mirrors
/// CriticalAlert / NotifAuthState). The live store (HomeStore.sendRemoteRelay) turns
/// `urlRequest` into a URLSession task; the body it carries is identical to what
/// `RemoteRelay.request` produced from `CriticalAlert.notice`, so the off-device alert
/// and the local banner can never disagree.
struct RemoteRelayRequest: Equatable {
    let url: URL
    let title: String   // == CriticalAlert.notice title
    let body: String    // == CriticalAlert.notice body (carries resident attribution)

    /// Generic JSON payload most webhook relays accept (ntfy / Slack-bridge / Make /
    /// Zapier / n8n / custom): title + message + a stable source tag.
    var jsonBody: Data {
        let obj: [String: String] = ["title": title, "message": body, "source": "Vigil"]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    /// ntfy-honored headers so the free, no-account phone path (ntfy.sh) renders a clean,
    /// high-priority, TITLED lock-screen alert instead of a raw JSON blob. These are plain
    /// HTTP headers: ntfy reads them; every other relay (Slack-bridge / Make / Zapier / n8n
    /// / Apple Shortcuts / custom) ignores unknown headers and still receives the JSON body.
    /// Additive by design — the structured body is unchanged, so no existing consumer
    /// breaks. `Title` values here are ASCII (latin-1 safe for an HTTP header field).
    /// Proven against a live ntfy topic before ship (DOCUMENTATION.md ▸ Away Alerts).
    var ntfyHeaders: [String: String] {
        ["Title": title, "Priority": "high", "Tags": "warning"]
    }

    /// The POST the live store fires. JSON body (for programmable relays) PLUS ntfy headers
    /// (for a clean phone notification). 10 s timeout — a fall alert must not hang.
    var urlRequest: URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in ntfyHeaders { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = jsonBody
        r.timeoutInterval = 10
        return r
    }
}

/// Pure builder for the off-device relay POST — the SAME isCritical gate as the local
/// banner (CriticalAlert.notice), plus the configured-endpoint gate. Returns nil (NO
/// POST) for any non-critical kind (no spam) AND for an unconfigured/invalid endpoint
/// (ship-no-data: an empty relay never fires). Pure + value-typed: a test builds the
/// request and asserts it equals the local notice without touching the network.
enum RemoteRelay {
    static func request(for kind: ActivityKind, message: String, resident: Resident?,
                        config: RemoteRelayConfig) -> RemoteRelayRequest? {
        // Gate 1: identical to the local banner — non-critical never leaves the box.
        guard let n = CriticalAlert.notice(for: kind, message: message, resident: resident) else { return nil }
        // Gate 2: ship-no-data — an unconfigured/malformed endpoint produces NO request.
        guard let url = config.endpointURL else { return nil }
        return RemoteRelayRequest(url: url, title: n.title, body: n.body)
    }

    /// The Away-Alerts "Test alert" POST. The buyer presses Test to PROVE their relay
    /// actually reaches their phone BEFORE they trust it with a real fall — the honest
    /// analogue of a monitoring company's periodic test signal (which Vigil, being
    /// self-monitored, does NOT have). Gated the same as a real alert: an
    /// unconfigured/malformed endpoint produces NO request (ship-no-data, §5.2). The body
    /// is unmistakably a test so a caregiver can never confuse it for a live emergency
    /// (§5.1). Pure/value-typed so the (config → test-request) contract is unit-lockable
    /// without a live network.
    static func testRequest(config: RemoteRelayConfig) -> RemoteRelayRequest? {
        guard let url = config.endpointURL else { return nil }
        return RemoteRelayRequest(url: url, title: AwayAlerts.testAlertTitle, body: AwayAlerts.testAlertBody)
    }
}

/// Away Alerts — the first-class, self-monitored off-device alerting feature built on the
/// buyer's own relay (RemoteRelayConfig / RemoteRelay). Copy lives here as canonical
/// constants so the in-app card, the test payload, and the honesty tests all reference the
/// SAME words — the disclaimer can never drift out of sync with what the app actually does
/// (§5.1). Vigil is self-monitored: it POSTs to an endpoint the buyer controls and NEVER
/// calls a monitoring center or dispatches emergency services — this is stated plainly, not
/// buried, so no buyer mistakes Vigil for a professionally-monitored alarm.
enum AwayAlerts {
    /// The load-bearing honesty line. Rendered verbatim in the Away Alerts card and
    /// echoed in DOCUMENTATION.md + the storefront so the same promise is made everywhere.
    static let selfMonitoredDisclaimer =
        "Self-monitored — Vigil does not call a monitoring center or dispatch emergency services. "
        + "Critical alerts are POSTed to an endpoint you control (your phone, a caregiver, a chat)."

    /// The unmistakable test-alert title/body. \"TEST\" is first so a caregiver's lock-screen
    /// preview reads as a test, never a live fall (§5.1).
    static let testAlertTitle = "Vigil TEST alert"
    static let testAlertBody =
        "TEST — this is a Vigil Away Alerts test. Your relay is reaching this device. "
        + "No emergency. Real alerts look like this."
}

struct ActivityEvent: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var at: Date
    var kind: ActivityKind
    var message: String
    /// Eldercare attribution: the resident this event concerns, when known. Optional
    /// and decode-tolerant (nil = unattributed) — never a fabricated occupant (§5.1).
    var residentID: UUID? = nil
}

// MARK: - Fused event confidence + modality (VG-31)

/// The sensing modality an activity event originated from, for the fused timeline
/// (VG-29). Derived straight from the event `kind` — never guessed. Sensing kinds
/// (sensor/anomaly/fall) come from the real gated sensing layer; presence is fused
/// occupancy; device/scene/security/system/alert are the control + relay plane.
extension ActivityKind {
    var modalityLabel: String {
        switch self {
        case .sensor:   return "Sensing (CSI/sonar)"
        case .anomaly:  return "Predictive baseline"
        case .fall:     return "Fall monitor"
        case .presence: return "Fused occupancy"
        case .device:   return "Device"
        case .scene:    return "Scene"
        case .security: return "Security"
        case .system:   return "System"
        case .alert:    return "Alert relay"
        }
    }
}

extension ActivityEvent {
    /// Confidence recorded IN the event's own message when the sidecar stamped one
    /// (e.g. an anomaly line carrying "(conf 0.87)"), else nil. It is parsed, never
    /// fabricated — an event with no recorded confidence returns nil so the fused
    /// timeline renders "—" (unknown) rather than a made-up certainty (§5.1,
    /// accuracy-or-nothing). Only values in [0,1] are accepted.
    var recordedConfidence: Double? {
        guard let r = message.range(of: #"conf(?:idence)?\s+([01](?:\.[0-9]+)?)"#,
                                    options: .regularExpression) else { return nil }
        let matched = message[r]
        guard let num = matched.range(of: #"[01](?:\.[0-9]+)?"#, options: .regularExpression),
              let v = Double(matched[num]), v >= 0, v <= 1 else { return nil }
        return v
    }

    /// Display string for the fused timeline: a real percentage when recorded, else
    /// an honest em dash. Never invents a number.
    var confidenceLabel: String {
        recordedConfidence.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }
}

// MARK: - Elder / solo vitals monitor mode (VG-27)

/// One fused vitals observation for monitor mode. Every field is a GATE-PASSING reading
/// or nil — the caller passes `breathingBPM`/`heartBPM` ONLY after RPPGGate / BreathingDSP /
/// FrameGate have already cleared them (§5.1 accuracy-or-nothing). A nil vital means
/// "no reliable reading right now", NEVER a fabricated zero. `present` is the fused
/// occupancy (CSI / sonar / camera) — a body actually sensed, not assumed.
struct VitalsSample: Equatable {
    var present: Bool          // fused occupancy confirmed a body is here
    var breathingBPM: Double?  // gate-passed breathing rate (br/min), else nil
    var heartBPM: Double?      // gate-passed heart rate (bpm), else nil

    init(present: Bool, breathingBPM: Double? = nil, heartBPM: Double? = nil) {
        self.present = present; self.breathingBPM = breathingBPM; self.heartBPM = heartBPM
    }
}

/// The instantaneous concern a fused vitals sample raises. Only a POSITIVE gate-passing
/// reading in a danger band produces a concern — an ABSENT reading never does (a nil BPM
/// is a sensor gap, not an apnea we can defend). Each concern carries the REAL number that
/// tripped it so the caregiver alert quotes a fact, never a diagnosis (§5.1).
enum VitalsConcern: Equatable {
    case none
    case breathingLow(Double), breathingHigh(Double)
    case heartLow(Double), heartHigh(Double)

    var isConcern: Bool { self != .none }

    /// The measured value that tripped the concern (nil for `.none`).
    var value: Double? {
        switch self {
        case .none: return nil
        case .breathingLow(let v), .breathingHigh(let v), .heartLow(let v), .heartHigh(let v): return v
        }
    }

    /// Honest caregiver-alert body for a DESIGNATED CONTACT. Names the real reading, never
    /// diagnoses, and ALWAYS carries the not-a-medical-device / no-dispatch disclaimer so a
    /// buyer can never mistake Vigil for a medical alarm (§5.1). nil for `.none`.
    func alertBody(resident name: String?) -> String? {
        let who = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let subject = who ?? "the person being monitored"
        let reading: String
        switch self {
        case .none: return nil
        case .breathingLow(let v):  reading = "breathing rate reading is unusually low (\(Int(v.rounded())) br/min)"
        case .breathingHigh(let v): reading = "breathing rate reading is unusually high (\(Int(v.rounded())) br/min)"
        case .heartLow(let v):      reading = "heart rate reading is unusually low (\(Int(v.rounded())) bpm)"
        case .heartHigh(let v):     reading = "heart rate reading is unusually high (\(Int(v.rounded())) bpm)"
        }
        return "Monitor mode: \(subject)'s \(reading). Please check on them. "
             + "Vigil is not a medical device and does not contact emergency services."
    }
}

/// Elder / solo monitor mode (VG-27). Fuses gate-passing breathing + heart readings with
/// fused presence into a single CONCERN state, debounced over a 20s window (Nanit-style) so
/// a one-off out-of-band reading — or a transient sensor blip — never pages a caregiver.
/// A concern is raised ONLY from a real gate-passing vital reading in a danger band while a
/// body is actually present; it is NEVER raised from a fabricated or absent number (§5.1
/// accuracy-or-nothing). NOT A MEDICAL DEVICE: it does not diagnose and never contacts
/// emergency services — it nudges a DESIGNATED CONTACT through the buyer-owned Away Alerts
/// relay. Pure + value-typed → unit-testable on synthetic samples with no clock or sensor.
struct VitalsMonitor: Equatable {
    /// Safe-band thresholds. Defaults are conservative resting-adult ranges; wide enough
    /// that a normal reading never pages, and Vigil never claims these are clinical limits.
    struct Bands: Equatable {
        var breathingLow: Double = 8,  breathingHigh: Double = 25   // br/min
        var heartLow: Double = 40,     heartHigh: Double = 130       // bpm
        init() {}
    }

    let bands: Bands
    /// The 20s debounce window: a concern must persist this long to page, and to clear.
    let dwell: TimeInterval
    private(set) var confirmed: VitalsConcern
    private var candidate: VitalsConcern?
    private var candidateSince: Date?

    init(bands: Bands = Bands(), dwell: TimeInterval = 20, confirmed: VitalsConcern = .none) {
        self.bands = bands; self.dwell = dwell; self.confirmed = confirmed
    }

    /// Classify one fused sample into an INSTANTANEOUS concern (pure, pre-debounce). Requires
    /// real fused presence AND a positive gate-passing reading in a danger band — no presence
    /// or no reading is `.none`, never an invented concern (§5.1).
    static func classify(_ s: VitalsSample, bands: Bands) -> VitalsConcern {
        guard s.present else { return .none }               // no body sensed → nothing to watch
        if let br = s.breathingBPM {
            if br < bands.breathingLow  { return .breathingLow(br) }
            if br > bands.breathingHigh { return .breathingHigh(br) }
        }
        if let hr = s.heartBPM {
            if hr < bands.heartLow  { return .heartLow(hr) }
            if hr > bands.heartHigh { return .heartHigh(hr) }
        }
        return .none
    }

    /// Feed one fused sample. Returns a COMMITTED concern transition (the caller pages the
    /// designated contact exactly once) or nil while a change is still settling inside the
    /// 20s window. Mirrors PresenceDebouncer's dwell-commit so a transient reading can never
    /// page, and a recovered reading clears the concern only after it has held for `dwell`.
    mutating func step(_ s: VitalsSample, now: Date) -> VitalsConcern? {
        let raw = Self.classify(s, bands: bands)
        if raw == confirmed { candidate = nil; candidateSince = nil; return nil }
        if candidate != raw { candidate = raw; candidateSince = now; return nil }
        guard let since = candidateSince, now.timeIntervalSince(since) >= dwell else { return nil }
        confirmed = raw
        candidate = nil; candidateSince = nil
        return confirmed
    }
}

/// Persisted monitor-mode configuration (VG-27). Ships DISABLED and empty (§5.2): monitor
/// mode is off, no designated contact, no resident. Alerts route through the SAME buyer-owned
/// Away Alerts relay (RemoteRelayConfig) — Vigil runs no hosted paging service (§5.5).
struct MonitorConfig: Codable, Equatable {
    var enabled: Bool = false
    /// The DESIGNATED CONTACT's name, shown in the alert body. Empty by default; the relay
    /// endpoint (RemoteRelayConfig) is the channel that actually reaches them.
    var designatedContact: String = ""
    /// The resident under watch, when one is chosen (else the alert reads unattributed —
    /// never a fabricated occupant, §5.1).
    var residentID: UUID? = nil
    init() {}

    /// Honest one-line status. Monitor mode may claim "on" ONLY when it is enabled AND a
    /// real relay endpoint exists to reach the contact — enabled with no relay is a dead
    /// channel and says so (§5.1).
    func statusLabel(relayConfigured: Bool) -> String {
        guard enabled else { return "Monitor mode is off." }
        if !relayConfigured { return "Monitor mode is on, but no Away Alerts relay is set — a concern can't reach your contact yet." }
        let who = designatedContact.trimmingCharacters(in: .whitespacesAndNewlines)
        return who.isEmpty
            ? "Monitor mode on — a debounced vitals concern pages your Away Alerts relay. Not a medical device."
            : "Monitor mode on — a debounced vitals concern pages \(who) via Away Alerts. Not a medical device."
    }
}

// MARK: - Fused presence modality surface (VG-23)

/// Which sensing modality is CARRYING presence right now (VG-23). Vigil fuses several
/// independent presence sources; after the FP2 "sees people that aren't there" pain the
/// honest question a buyer asks is *which* sensor is asserting presence — and how sure the
/// fused estimate is. These names come from REAL live signals only; when nothing clears its
/// floor the modality is nil and the UI shows "—" (never a guessed modality, §5.1).
enum PresenceModality: String, Equatable {
    case csi        // WiFi-CSI / through-wall sensor node
    case sonar      // on-device acoustic sonar (speaker + mic)
    case camera     // camera 3D pose / rPPG face

    var label: String {
        switch self {
        case .csi:    return "CSI node"
        case .sonar:  return "Acoustic sonar"
        case .camera: return "Camera pose"
        }
    }
}

/// One live presence contributor: whether it currently asserts presence and its REAL sensed
/// strength (0…1, e.g. clamped motion magnitude or a binary face sighting). A contributor
/// that is not asserting presence, or whose strength is ≤ 0, contributes nothing — its
/// strength is never fabricated to force a winner (§5.1).
struct PresenceVote: Equatable {
    var modality: PresenceModality
    var present: Bool
    var strength: Double
    init(modality: PresenceModality, present: Bool, strength: Double) {
        self.modality = modality; self.present = present; self.strength = strength
    }
}

enum FusedPresence {
    /// The modality carrying presence right now = the asserting contributor with the highest
    /// REAL strength. Honest nil when NONE asserts presence (the UI then shows "—") — never a
    /// fabricated modality (§5.1). Ties resolve to the first in input order (stable).
    static func carrying(_ votes: [PresenceVote]) -> PresenceModality? {
        var best: PresenceVote?
        for v in votes where v.present && v.strength > 0 {
            if best == nil || v.strength > best!.strength { best = v }
        }
        return best?.modality
    }

    /// Render a recorded fused confidence as an honest percentage, or "—" when the engine has
    /// not earned one (nil) or it is out of [0,1]. Never invents a certainty (§5.1) — mirrors
    /// ActivityEvent.confidenceLabel.
    static func confidenceLabel(_ confidence: Double?) -> String {
        guard let c = confidence, c >= 0, c <= 1 else { return "—" }
        return String(format: "%.0f%%", c * 100)
    }
}

// MARK: - Nightly digest (VG-28) — an honest story of a night from REAL events only

/// One segment of a night's story. It is EITHER a span of real logged events, OR an
/// explicit GAP where nothing was recorded — there is no third "inferred" case. The
/// digest never synthesizes, interpolates, or smooths a reading it did not see, so a
/// quiet-looking stretch is reported as "no data recorded", never as a fabricated
/// "all quiet" (§5.1).
struct NightDigestSegment: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case events, gap }
    var id: UUID = UUID()
    var kind: Kind
    var start: Date
    var end: Date
    var summary: String
    var eventCount: Int          // real count for .events; always 0 for a .gap

    static func == (a: NightDigestSegment, b: NightDigestSegment) -> Bool {
        a.kind == b.kind && a.start == b.start && a.end == b.end
            && a.summary == b.summary && a.eventCount == b.eventCount
    }
}

/// The rolled-up story of one overnight window, built ONLY from events that actually
/// fall inside it. `totalEvents` is the real in-window count; `isEmpty` drives the
/// UI's honest empty state (never a fabricated night).
struct NightDigest: Equatable {
    let night: DateInterval
    let segments: [NightDigestSegment]
    let totalEvents: Int
    var isEmpty: Bool { totalEvents == 0 }

    /// One-line headline. An empty night says so plainly — it is never dressed up as
    /// "all quiet / all safe" (which would imply sensed-and-still, a claim we cannot make).
    var headline: String {
        if isEmpty { return "No activity recorded overnight." }
        return "\(totalEvents) event\(totalEvents == 1 ? "" : "s") recorded overnight."
    }
}

/// Pure builder for the nightly digest (VG-28). Foundation-only + value-typed so the
/// honesty invariants (empty-log, no-interpolation, window-exclusion) are unit-tested
/// without a UI or a clock.
enum NightDigestBuilder {
    /// The overnight window that ENDS on the morning of `reference` (local). Defaults to
    /// 9pm the prior evening → 9am. Deterministic given a calendar, so tests can pin it.
    static func window(endingOn reference: Date,
                       calendar: Calendar = .current,
                       startHour: Int = 21,
                       endHour: Int = 9) -> DateInterval {
        let dayStart = calendar.startOfDay(for: reference)
        let end = calendar.date(byAdding: .hour, value: endHour, to: dayStart) ?? dayStart
        // Previous evening's startHour.
        let prevDay = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        let start = calendar.date(byAdding: .hour, value: startHour, to: prevDay) ?? prevDay
        return DateInterval(start: start, end: max(start, end))
    }

    /// Build the digest from REAL events only. Events outside `window` are dropped (never
    /// pulled into the night). The window is walked hour-by-hour: contiguous hours with at
    /// least one event coalesce into an `.events` segment; contiguous empty hours coalesce
    /// into an explicit `.gap` segment. No event is ever manufactured — the sum of every
    /// segment's `eventCount` equals the in-window event count exactly.
    static func build(events: [ActivityEvent],
                      window: DateInterval,
                      calendar: Calendar = .current) -> NightDigest {
        let inWindow = events.filter { window.contains($0.at) }.sorted { $0.at < $1.at }
        guard !inWindow.isEmpty else {
            return NightDigest(night: window, segments: [], totalEvents: 0)
        }

        // Hour slots across the window (last slot clamped to window.end).
        var slots: [(start: Date, end: Date, events: [ActivityEvent])] = []
        var cursor = window.start
        while cursor < window.end {
            let next = min(calendar.date(byAdding: .hour, value: 1, to: cursor) ?? window.end, window.end)
            let evs = inWindow.filter { $0.at >= cursor && $0.at < next }
            slots.append((cursor, next, evs))
            cursor = next
        }

        // Coalesce contiguous slots that share emptiness into segments.
        var segments: [NightDigestSegment] = []
        var i = 0
        while i < slots.count {
            let hasEvents = !slots[i].events.isEmpty
            var j = i
            var bucket: [ActivityEvent] = []
            while j < slots.count, (!slots[j].events.isEmpty) == hasEvents {
                bucket.append(contentsOf: slots[j].events)
                j += 1
            }
            let segStart = slots[i].start
            let segEnd = slots[j - 1].end
            if hasEvents {
                segments.append(NightDigestSegment(kind: .events, start: segStart, end: segEnd,
                                                   summary: eventSummary(bucket, calendar: calendar),
                                                   eventCount: bucket.count))
            } else {
                segments.append(NightDigestSegment(kind: .gap, start: segStart, end: segEnd,
                                                   summary: "no data recorded", eventCount: 0))
            }
            i = j
        }

        return NightDigest(night: window, segments: segments, totalEvents: inWindow.count)
    }

    /// Compact, human line for an events segment — real times + kinds, capped so a busy
    /// stretch stays readable. Every entry is a real logged event (no synthesis).
    static func eventSummary(_ events: [ActivityEvent], calendar: Calendar = .current) -> String {
        guard !events.isEmpty else { return "no data recorded" }
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "h:mm a"
        let parts = events.prefix(3).map { "\($0.kind.rawValue) \(fmt.string(from: $0.at))" }
        var s = parts.joined(separator: ", ")
        if events.count > 3 { s += " +\(events.count - 3) more" }
        return s
    }
}

// MARK: - Predictive eldercare (mirrors the :8799 /anomaly + /baseline payloads)

/// One reading from the sidecar's predictive detector (`engine/predict.py`
/// `Detector.update()`), decoded from `GET /anomaly`. Optionals are honest: a
/// learning or nominal reading carries no `state`, and a missing/garbled field
/// degrades to nil rather than a fabricated anomaly (§5.1, accuracy-or-nothing).
struct AnomalyState: Codable, Equatable {
    let ts: Double
    let bucket: Int?
    let nights_observed: Int?
    let nights_required: Int?
    let state: String?          // "bed-exit" | "inactivity-anomaly" | nil
    let status: String          // "learning_baseline" | "anomaly" | "nominal"
    let confidence: Double?
    let detail: String?

    /// True only for a genuine, latched anomaly episode (status anomaly + a state).
    var isAnomaly: Bool { status == "anomaly" && state != nil }

    /// Human-readable History line; only meaningful when `isAnomaly`.
    var logMessage: String {
        let label: String
        switch state {
        case "bed-exit":           label = "Bed-exit detected"
        case "inactivity-anomaly": label = "Inactivity anomaly detected"
        default:                   label = "Anomaly detected"
        }
        let conf = confidence.map { String(format: " (conf %.2f)", $0) } ?? ""
        let why  = detail.map { " — \($0)" } ?? ""
        return "\(label)\(conf)\(why)"
    }
}

/// The predictive baseline's learning progress (`GET /baseline`,
/// `BaselineModel.summary()`). Drives the honest "Learning your home — night N of
/// M" state so the buyer sees the moat is real and learning, not broken (§5.2).
struct BaselineState: Codable, Equatable {
    let ready: Bool
    let nights_observed: Int
    let nights_required: Int
    let rest_buckets: [Int]?
    let active_buckets: [Int]?

    var learningLine: String { "Learning your home — night \(nights_observed) of \(nights_required)" }
}

/// Transition-only dedup gate for anomaly logging. The sidecar latches one event
/// per episode, but the app's slow poll re-observes the SAME latched reading many
/// times before it clears — logging each would spam History (the exact failure
/// mode GAP #D showed with presence). `shouldLog` returns true only the FIRST time
/// a given `(ts, state)` anomaly is seen. Pure + value-typed → unit-testable.
struct AnomalyLatch: Equatable {
    private var lastTs: Double?
    private var lastState: String?

    mutating func shouldLog(_ a: AnomalyState) -> Bool {
        guard a.isAnomaly, let s = a.state else { return false }   // learning/nominal never log
        if lastTs == a.ts && lastState == s { return false }       // same episode re-observed
        lastTs = a.ts; lastState = s
        return true                                                // first sight of a new episode
    }
}

/// One latched alert from the sidecar's fall/emergency monitor (`engine/fall_detect.py`
/// `FallMonitor`), nested in `GET /fall`. `since_s` is the elapsed time since the
/// episode latched (grows on every poll — NOT the episode identity; see FallLatch).
struct FallAlert: Codable, Equatable {
    let kind: String          // "FALL" | "NO_MOTION" | "NO_BREATHING"
    let message: String
    let since_s: Double
    let acknowledged: Bool
}

/// One reading of the eldercare fall/emergency layer, decoded from `GET /fall`
/// (`FallMonitor.update()` + the engine's `active`/`note` overlay). Honest by
/// construction (CHARTER §5.1): the monitor ships INACTIVE on a buyer's empty LAN,
/// CALIBRATING during room warmup, and only an `alert` with a `kind` raised on REAL
/// gated sensing is an emergency — absence of a reliable signal is reported as such,
/// never as "all safe". Unknown timings stay nil (never coerced to 0); a missing field
/// degrades to nil rather than a fabricated state.
struct FallState: Codable, Equatable {
    let active: Bool          // false = monitor not running on real sensing (no CSI / synthetic)
    let state: String         // EMPTY|ACTIVE|RESTING|STILL|CALIBRATING|FALL|NO_MOTION|NO_BREATHING|INACTIVE
    let alert: FallAlert?
    let last_motion_s: Double?
    let last_breath_s: Double?
    let note: String?

    /// True ONLY for a live, latched emergency: the monitor is running on real sensing
    /// AND the engine raised an alert. An inactive/calibrating monitor is never an alert.
    var isAlert: Bool { active && alert != nil }

    /// History line for a real alert — humanized kind + the engine's `message` verbatim.
    /// Only meaningful when `isAlert`.
    var logMessage: String {
        guard let a = alert else { return "Eldercare alert" }
        let label: String
        switch a.kind {
        case "FALL":         label = "Possible fall"
        case "NO_MOTION":    label = "No motion — possible incapacitation"
        case "NO_BREATHING": label = "No movement or breathing — check now"
        default:             label = "Eldercare alert"
        }
        return "\(label) — \(a.message)"
    }

    /// The honest one-line state for the eldercare card. Calibration, empty and inactive
    /// are reported as what they are — NEVER as "safe" / "all clear" (§5.1).
    var displayLine: String {
        if let a = alert { return a.message }            // live emergency: engine message verbatim
        switch state {
        case "CALIBRATING": return "Calibrating — learning this room"
        case "INACTIVE":    return "Monitoring inactive — no live sensing"
        case "EMPTY":       return "No one detected"
        case "ACTIVE":      return "Up and moving"
        case "RESTING":     return "Resting — present and breathing"
        case "STILL":       return "Still — present, watching"
        default:            return "—"
        }
    }
}

/// Transition-only dedup gate for fall/emergency logging. The engine LATCHES one alert
/// per episode (the `alert` dict persists until acknowledged/cleared), but the app's slow
/// poll re-observes the SAME latched alert many times — logging each would spam History
/// (the GAP #D / anomaly failure mode). `shouldLog` returns true only the FIRST time a
/// given alert `kind` appears, RE-ARMS when the alert clears (a fresh episode logs again),
/// and re-logs on an ESCALATION to a different kind (FALL->NO_BREATHING). Pure → testable.
struct FallLatch: Equatable {
    private var lastKind: String?

    mutating func shouldLog(_ f: FallState) -> Bool {
        guard f.isAlert, let kind = f.alert?.kind else {
            lastKind = nil                          // no live alert → re-arm for the next episode
            return false
        }
        if lastKind == kind { return false }        // same latched episode re-observed
        lastKind = kind
        return true                                 // first sight of a new/escalated alert
    }
}

/// Camera-HR (rPPG) display gate — accuracy-or-nothing applied to the forehead pulse
/// (CHARTER §5.1 + the Vigil vitals accuracy-or-nothing standard). The rPPG ring
/// holds up to 14 s of forehead RGB, so after a person LEAVES the frame `estimateBPM`
/// keeps returning a valid periodic lock off residual samples and refreshes the lock
/// timestamp — which would display "Live pulse 72" for an empty chair (a heart rate
/// attributed to nobody). This gate requires a face to have been actually seen within
/// `faceStale` of `now` (one or two frame intervals at the 0.35 s cadence), so a held
/// pulse can never outlive the face. A present, freshly-locked face still reports its
/// BPM (the moat); a stale or absent face reports nil → the card falls back to the
/// honest "No face detected" line. The original 4 s lock-hold (anti-flicker) is kept.
/// Pure → unit-testable, no camera needed.
enum RPPGGate {
    /// Max age of the last real face sighting before a held pulse is suppressed (s).
    static let faceStale: TimeInterval = 1.0

    /// The BPM to display on the heart card, or nil to show the honest no-face/measuring state.
    /// - smoothed: the smoothed BPM estimate (0 = none locked yet).
    /// - lastGood: when a BPM last cleared the SNR/median lock (anti-flicker hold).
    /// - lastFace: when a face was last ACTUALLY present in frame (the §5.1 freshness gate).
    static func displayBPM(smoothed: Double, lastGood: Date, lastFace: Date,
                           now: Date, faceStale: TimeInterval = RPPGGate.faceStale) -> Int? {
        guard smoothed > 0 else { return nil }                            // nothing locked yet
        guard now.timeIntervalSince(lastFace) < faceStale else { return nil }  // face gone → no held pulse
        guard now.timeIntervalSince(lastGood) < 4 else { return nil }     // lock too old (existing hold)
        return Int(smoothed.rounded())
    }
}

/// R7: a live sensing frame must not outlive the engine that produced it. The :8799
/// poll runs every 0.1 s and writes `Engine.frame` on a successful decode — but on
/// FAILURE (the Python sidecar died, the CSI node was unplugged, the host slept) the
/// catch path used to leave the LAST frame in place. Its `breathing_bpm`/`heart_bpm`/
/// `csi_connected` would then read "Live CSI · THROUGH-WALL · 18 br/min" forever — a
/// vital sign attributed to a dead signal. That is the exact symmetric §5.1 leak
/// `RPPGGate` closes for the camera pulse (a held reading outliving its source). This
/// gate keeps a frame displayable only while a poll has succeeded within `frameStale`:
/// a single transient miss still holds it (no flicker), but a stopped engine drops the
/// frame so the vitals fall back to the honest "—" / "no signal" / "Waiting for a CSI
/// reader" empty state (§5.2). Pure → unit-testable, no network needed.
enum FrameGate {
    /// Max age of the last successfully-polled :8799 frame before it is treated as
    /// stale (s). ~2 missed 1.5 s-timeout polls, so a single transient timeout still
    /// holds the last frame (anti-flicker), but a dead engine blanks within ~3 s.
    static let frameStale: TimeInterval = 3.0

    /// Whether a frame stamped at `lastFrameAt` is still fresh enough to display at
    /// `now`. Strict `<` so exactly `frameStale` old already counts as stale.
    static func isFresh(lastFrameAt: Date, now: Date,
                        frameStale: TimeInterval = FrameGate.frameStale) -> Bool {
        now.timeIntervalSince(lastFrameAt) < frameStale
    }

    /// R7 (§5.1) belt-and-suspenders: the frame a VIEW should read at render time —
    /// the raw frame only while it is still fresh, else nil. `Engine.poll()`'s catch
    /// nils a stale frame, but ONLY while the 0.1 s poll Timer keeps firing; if that
    /// Timer is invalidated (`stop()`, app suspension, a RunLoop that stops servicing
    /// it) while a vitals view stays mounted, `frame` freezes with its last live
    /// breathing_bpm/heart_bpm — a vital sign outliving its source. Reading vitals
    /// through this gate means any render that happens after the engine went quiet
    /// shows "—"/"no signal" regardless of whether a poll ever ran to clear it. Generic
    /// so HomeCore (no SwiftUI, no `SensingFrame`) can both define and unit-test it.
    static func liveFrame<Frame>(_ frame: Frame?, lastFrameAt: Date, now: Date,
                                 frameStale: TimeInterval = FrameGate.frameStale) -> Frame? {
        isFresh(lastFrameAt: lastFrameAt, now: now, frameStale: frameStale) ? frame : nil
    }

    /// R7c (§5.1) CONNECTION-GENERATION INVALIDATION — closes the hole the time gate
    /// alone cannot: `isFresh` only asks "how long ago", never "from WHICH connection".
    /// The sidecar dying and respawning, `stop()` + `start()`, or any reconnect inside
    /// `frameStale` leaves the LAST frame of the OLD connection both present and (by the
    /// clock) fresh — so a vitals view renders a breathing_bpm/heart_bpm produced by a
    /// process that no longer exists as if it were live. Every teardown/(re)connect bumps
    /// a monotonic generation counter and each polled frame is stamped with the generation
    /// that produced it; a frame whose stamp is not the CURRENT generation is dead by
    /// identity, no matter how recent its timestamp. This is the frame-level analogue of
    /// "version ≠ identity": recency is not provenance.
    static func isCurrentGeneration(frameGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        frameGeneration == currentGeneration
    }

    /// The frame a VIEW should read at render time, gated on BOTH provenance and recency:
    /// nil unless the frame was stamped by the connection that is live right now AND it
    /// polled within `frameStale`. Generation is checked FIRST — a stale-by-identity frame
    /// can never be rescued by a recent timestamp.
    static func liveFrame<Frame>(_ frame: Frame?, lastFrameAt: Date, now: Date,
                                 frameGeneration: UInt64, currentGeneration: UInt64,
                                 frameStale: TimeInterval = FrameGate.frameStale) -> Frame? {
        guard isCurrentGeneration(frameGeneration: frameGeneration,
                                  currentGeneration: currentGeneration) else { return nil }
        return liveFrame(frame, lastFrameAt: lastFrameAt, now: now, frameStale: frameStale)
    }
}

/// Deep links into the System Settings privacy/notification panes (DOD-3.3). Once an
/// authorization is determined the OS never re-prompts, so a denial surface must offer
/// a REAL "Open System Settings" action — a text path the buyer has to retype by hand
/// is a dead end. URL construction is pure Foundation so the pane routing stays
/// unit-lockable here; the AppKit `NSWorkspace.shared.open(...)` call lives in the views.
enum SystemSettingsPane: String, CaseIterable {
    case camera
    case microphone
    case localNetwork
    case locationServices
    case notifications

    /// The `x-apple.systempreferences:` deep link macOS resolves to the exact pane.
    var url: URL {
        let target: String
        switch self {
        case .camera:           target = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .microphone:       target = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .localNetwork:     target = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        case .locationServices: target = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        case .notifications:    target = "x-apple.systempreferences:com.apple.notifications"
        }
        return URL(string: target)!
    }
}

/// Privacy-safe support diagnostics text (DOD-7.6/DOD-11.5). Pure assembly from values
/// the caller explicitly passes — this renderer can never reach into the Keychain, the
/// fleet PSK file, resident records, or the home model on its own, so what it CANNOT
/// leak is structural, not reviewed-per-call. The view layer gathers the inputs and
/// writes the file the buyer chooses.
enum DiagnosticsReport {
    static func render(appVersion: String, build: String, osVersion: String,
                       engineStatus: String, engineConnected: Bool,
                       notifStatus: String, locationStatus: String,
                       roomCount: Int, deviceCount: Int, residentCount: Int,
                       logTails: [(name: String, tail: String)],
                       generatedAt: Date = Date()) -> String {
        let fmt = ISO8601DateFormatter()
        var out: [String] = []
        out.append("Vigil diagnostics — generated \(fmt.string(from: generatedAt))")
        out.append("This report contains app/engine status and recent engine log excerpts.")
        out.append("It contains no credentials or keys. Review it before sharing.")
        out.append("")
        out.append("App version:     \(appVersion) (build \(build))")
        out.append("macOS:           \(osVersion)")
        out.append("Sensing engine:  \(engineConnected ? "connected" : "not connected") — \(engineStatus)")
        out.append("Notifications:   \(notifStatus)")
        out.append("Location:        \(locationStatus)")
        out.append("Home model:      \(roomCount) room(s), \(deviceCount) device(s), \(residentCount) resident(s) — counts only, no names")
        for entry in logTails {
            out.append("")
            out.append("--- \(entry.name) (tail) ---")
            out.append(entry.tail.isEmpty ? "(empty)" : entry.tail)
        }
        out.append("")
        return out.joined(separator: "\n")
    }
}

/// Bounded activity ring with protected retention for critical events. The store
/// keeps the most-recent `cap` events, but an eldercare bed-exit or security alert
/// must survive a flood of routine presence/device events (live: ~500 presence
/// events in ~36 min would otherwise evict a 3 a.m. anomaly before breakfast). So
/// when trimming, the most-recent `keepCritical` `.alert`/`.anomaly` events in the
/// overflow are retained on top of the cap. Pure → unit-testable. §5.1: this only
/// RETAINS real logged events, it never invents one. (`events` is newest-first.)
enum ActivityRing {
    static func trimmed(_ events: [ActivityEvent], cap: Int = 500, keepCritical: Int = 50) -> [ActivityEvent] {
        guard events.count > cap else { return events }
        let head = Array(events.prefix(cap))                       // newest cap by recency
        let rescued = events[cap...].filter { $0.kind.isCritical }.prefix(keepCritical)
        return rescued.isEmpty ? head : head + rescued
    }
}

// MARK: - Local backup / restore

/// The local-first portable JSON backup contract. Exporting a config without an
/// equally honest restore path is not recoverable data ownership: a buyer can save a
/// file but cannot prove it will come back. This validator rejects structurally broken
/// imports before `HomeStore` replaces the live home, so a corrupt backup cannot silently
/// erase room/device links, scenes, automations, or geofence state.
enum HomeConfigBackup {
    static func encode(_ state: HomeState) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(state)
    }

    static func decode(_ data: Data) throws -> HomeState {
        let state = try JSONDecoder().decode(HomeState.self, from: data)
        let found = issues(for: state)
        guard found.isEmpty else { throw HomeConfigBackupError.invalid(found) }
        return state
    }

    static func issues(for state: HomeState) -> [String] {
        var out: [String] = []
        let roomIDs = Set(state.rooms.map(\.id))
        let deviceIDs = Set(state.devices.map(\.id))
        let sceneIDs = Set(state.scenes.map(\.id))

        appendDuplicateIssue(ids: state.rooms.map(\.id), label: "rooms", into: &out)
        appendDuplicateIssue(ids: state.devices.map(\.id), label: "devices", into: &out)
        appendDuplicateIssue(ids: state.scenes.map(\.id), label: "scenes", into: &out)
        appendDuplicateIssue(ids: state.automations.map(\.id), label: "automations", into: &out)
        appendDuplicateIssue(ids: state.sensors.map(\.id), label: "sensors", into: &out)
        appendDuplicateIssue(ids: state.residents.map(\.id), label: "residents", into: &out)

        for d in state.devices where d.roomID.map({ !roomIDs.contains($0) }) == true {
            out.append("Device \"\(d.name)\" points to a missing room.")
        }
        for s in state.sensors where s.roomID.map({ !roomIDs.contains($0) }) == true {
            out.append("Sensor \"\(s.name)\" points to a missing room.")
        }
        for r in state.residents where r.roomID.map({ !roomIDs.contains($0) }) == true {
            out.append("Resident \"\(r.name)\" points to a missing room.")
        }
        for scene in state.scenes {
            for action in scene.actions where !deviceIDs.contains(action.deviceID) {
                out.append("Scene \"\(scene.name)\" controls a missing device.")
            }
        }
        for automation in state.automations {
            let name = automation.name
            if automation.trigger.roomID.map({ !roomIDs.contains($0) }) == true {
                out.append("Automation \"\(name)\" triggers from a missing room.")
            }
            if automation.trigger.deviceID.map({ !deviceIDs.contains($0) }) == true {
                out.append("Automation \"\(name)\" triggers from a missing device.")
            }
            for condition in automation.conditions where condition.deviceID.map({ !deviceIDs.contains($0) }) == true {
                out.append("Automation \"\(name)\" checks a missing device.")
            }
            for action in automation.actions {
                if action.sceneID.map({ !sceneIDs.contains($0) }) == true {
                    out.append("Automation \"\(name)\" runs a missing scene.")
                }
                if action.deviceID.map({ !deviceIDs.contains($0) }) == true {
                    out.append("Automation \"\(name)\" controls a missing device.")
                }
            }
        }
        if !state.geofence.isConfigured && state.geofence != GeofenceRegion() {
            out.append("Home region is present but invalid.")
        }
        return out
    }

    static func summary(for state: HomeState) -> String {
        let critical = state.activity.filter(\.kind.isCritical).count
        return [
            count(state.rooms.count, "room"),
            count(state.devices.count, "device"),
            count(state.scenes.count, "scene"),
            count(state.automations.count, "automation"),
            count(state.sensors.count, "sensor"),
            count(state.residents.count, "resident"),
            count(critical, "critical event")
        ].joined(separator: ", ")
    }

    private static func appendDuplicateIssue(ids: [UUID], label: String, into out: inout [String]) {
        if Set(ids).count != ids.count { out.append("Backup contains duplicate \(label).") }
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

enum HomeConfigBackupError: LocalizedError, Equatable {
    case invalid([String])

    var errorDescription: String? {
        switch self {
        case .invalid(let issues):
            return "Backup rejected: \(issues.prefix(3).joined(separator: " "))"
        }
    }
}

// MARK: - Residents (eldercare)

/// One person under care in the home — the unit a facility/eldercare pilot is
/// organized around (per-resident, not just per-room). A resident may be tied to a
/// room so fall/anomaly events sensed there attribute to them; the link is optional
/// and honest — an un-roomed resident attributes to "Unassigned", a home with no
/// residents shows the empty state, never a fabricated occupant (CHARTER §5.2).
struct Resident: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var roomID: UUID? = nil
    var note: String = ""
}

// MARK: - Persisted root

/// The whole home, serialized into the local Vigil `workspace.sqlite3` store.
struct HomeState: Codable, Equatable {
    var rooms: [HFRoom] = []
    var devices: [HFDevice] = []
    var scenes: [HFScene] = []
    var automations: [HFAutomation] = []
    var sensors: [HFSensorNode] = []
    var residents: [Resident] = []           // eldercare: people under care (ships empty)
    var relay: RemoteRelayConfig = RemoteRelayConfig()   // buyer-supplied off-device alert endpoint (ships empty, §5.2)
    var geofence: GeofenceRegion = GeofenceRegion()      // buyer's home region for arrive/leave triggers (ships empty, §5.2)
    var monitor: MonitorConfig = MonitorConfig()         // VG-27 elder/solo monitor mode (ships disabled + empty, §5.2)
    var activity: [ActivityEvent] = []
    var securityMode: SecurityMode = .off
    var energyHistory: [EnergySample] = []   // persisted real draw samples -> kWh trends

    static let empty = HomeState()

    init() {}

    /// Forward-compatible decode: every field degrades to its default when its key is
    /// absent, so adding a field (e.g. `residents`) never silently wipes an existing
    /// saved home on upgrade. Synthesized Codable requires every key — that was a latent
    /// reset-on-schema-change landmine; this closes it (§5.2: an upgrade must not look
    /// like data loss). encode(to:) stays synthesized, so writes always carry every key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rooms         = try c.decodeIfPresent([HFRoom].self,        forKey: .rooms)         ?? []
        devices       = try c.decodeIfPresent([HFDevice].self,      forKey: .devices)       ?? []
        scenes        = try c.decodeIfPresent([HFScene].self,       forKey: .scenes)        ?? []
        automations   = try c.decodeIfPresent([HFAutomation].self,  forKey: .automations)   ?? []
        sensors       = try c.decodeIfPresent([HFSensorNode].self,  forKey: .sensors)       ?? []
        residents     = try c.decodeIfPresent([Resident].self,      forKey: .residents)     ?? []
        relay         = try c.decodeIfPresent(RemoteRelayConfig.self, forKey: .relay)         ?? RemoteRelayConfig()
        geofence      = try c.decodeIfPresent(GeofenceRegion.self,   forKey: .geofence)      ?? GeofenceRegion()
        monitor       = try c.decodeIfPresent(MonitorConfig.self,    forKey: .monitor)       ?? MonitorConfig()
        activity      = try c.decodeIfPresent([ActivityEvent].self, forKey: .activity)      ?? []
        securityMode  = try c.decodeIfPresent(SecurityMode.self,    forKey: .securityMode)  ?? .off
        energyHistory = try c.decodeIfPresent([EnergySample].self,  forKey: .energyHistory) ?? []
    }

    func roomName(_ id: UUID?) -> String {
        guard let id else { return "Unassigned" }
        return rooms.first(where: { $0.id == id })?.name ?? "Unassigned"
    }
    func devices(in room: UUID) -> [HFDevice] { devices.filter { $0.roomID == room } }
    func favorites() -> [HFDevice] { devices.filter { $0.favorite } }

    /// The resident assigned to a room, if any. Honest nil when the room has no
    /// resident or the home has none — never a fabricated occupant (§5.1).
    func resident(inRoom id: UUID?) -> Resident? {
        guard let id else { return nil }
        return residents.first(where: { $0.roomID == id })
    }
    /// Display name for the resident in a room (drives "Resident: —" honesty), or nil.
    func residentName(inRoom id: UUID?) -> String? { resident(inRoom: id)?.name }
    /// Best-effort honest attribution for a room-agnostic sensor event (the :8799
    /// fall/anomaly sidecar carries no room yet): attribute ONLY when unambiguous —
    /// exactly one resident — else nil. Never guess among several (§5.1). Keys on the
    /// sensed room once per-room sensing lands.
    func soleResident() -> Resident? { residents.count == 1 ? residents.first : nil }

    /// The resident an attributed event concerns, if the id still resolves. Honest nil
    /// when the event is unattributed OR the resident was since removed — never a
    /// fabricated occupant (§5.1).
    func resident(byID id: UUID?) -> Resident? {
        guard let id else { return nil }
        return residents.first(where: { $0.id == id })
    }

    /// Caregiver-facing attribution string for an activity event — honest by construction
    /// so a now-non-silent fall/anomaly alert can say WHO/WHERE without ever guessing:
    ///   • unattributed (residentID == nil)        -> nil      (the row omits the line)
    ///   • attributed + resident resolves, no room  -> "Ada"
    ///   • attributed + resident resolves, w/ room   -> "Ada · Bedroom"
    ///   • attributed but the resident was removed   -> "unknown" (never re-guess a name)
    /// Optionals degrade to nil/"unknown", never 0 or "" (§5.1).
    func attribution(for event: ActivityEvent) -> String? {
        guard let id = event.residentID else { return nil }
        guard let r = residents.first(where: { $0.id == id }) else { return "unknown" }
        let room = roomName(r.roomID)
        return room == "Unassigned" ? r.name : "\(r.name) · \(room)"
    }
}


// MARK: - Acoustic breathing DSP (pure, unit-testable; §5.1 vitals accuracy-or-nothing)

/// Least-squares line fit (slope, intercept). Pure — shared by the breathing detrend.
func linfit(_ x: [Double], _ y: [Double]) -> (Double, Double) {
    let n = Double(x.count); let sx = x.reduce(0, +); let sy = y.reduce(0, +)
    let sxx = zip(x, x).map(*).reduce(0, +); let sxy = zip(x, y).map(*).reduce(0, +)
    let d = n * sxx - sx * sx; if abs(d) < 1e-9 { return (0, sy / n) }
    let slope = (n * sxy - sx * sy) / d; return (slope, (sy - slope * sx) / n)
}

/// R6 acoustic-breathing peak detector — the pure DSP behind `AcousticSonar.breathingCandidate()`,
/// extracted so the accuracy-or-nothing guards are unit-testable without a microphone (CHARTER §5.1
/// + the Vigil vitals accuracy-or-nothing standard). Given an unwrapped-able phase series and
/// its sample timestamps it returns the dominant in-band respiratory frequency (Hz), or nil when no
/// breath can be defended. Guards, in order: R6.1 Hann (side-lobe leakage), R6.3 independent-bin SNR
/// floor, R5 sub-physiological drift dominance, and R6.4 the surfaceable lower-edge floor.
enum BreathingDSP {
    /// Lowest respiratory frequency the card will surface (Hz). 0.17 Hz ~= 10.2 br/min.
    /// R6.4 (§5.1 fabrication fix): the fine sweep starts at the 0.15 Hz band floor, so a clean
    /// periodicity pinned to that boundary (a ~0.15 Hz HVAC/fan tone, or DFT-floor leakage from a
    /// true sub-0.15 Hz drift aliased onto the lowest bin) would surface round(0.15*60)=9 br/min — a
    /// clinically alarming bradypnea that, at this sensor's Rayleigh resolution (binW ~= 4 br/min over
    /// a 15 s window), cannot be told apart from artifact. Accuracy-or-nothing: a peak below this
    /// floor is reported as no-reading (—), never as a number we cannot defend. A real >=10.2 br/min
    /// breath is unaffected.
    static let surfaceFloorHz = 0.17

    static func peakHz(phase: [Double], t: [Double], surfaceFloor: Double = BreathingDSP.surfaceFloorHz) -> Double? {
        let n = phase.count
        guard n > 40, let t0 = t.first, let tLast = t.last, (tLast - t0) > 6 else { return nil }
        var u = phase
        for i in 1..<n { var dd = u[i] - u[i-1]; while dd > .pi { dd -= 2 * .pi }; while dd < -.pi { dd += 2 * .pi }; u[i] = u[i-1] + dd }
        let tt = (0..<n).map { Double($0) }
        let (sl, ic) = linfit(tt, u); for i in 0..<n { u[i] -= sl * tt[i] + ic }
        if n > 1 { for i in 0..<n { u[i] *= 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) } }   // R6.1 Hann
        func power(_ fr: Double) -> Double {
            var re = 0.0, im = 0.0
            for i in 0..<n { let a = 2 * .pi * fr * (t[i] - t0); re += u[i] * cos(a); im += u[i] * sin(a) }
            return re*re + im*im
        }
        var bestP = -1.0, bestF = 0.0
        var fr = 0.15
        while fr <= 0.5 { let pw = power(fr); if pw > bestP { bestP = pw; bestF = fr }; fr += 0.01 }   // fine sweep -> peak
        if bestP <= 0 { return nil }
        let span = tLast - t0
        let binW = span > 0 ? 1.0 / span : 0.067                                                      // true Rayleigh resolution
        var refPow: [Double] = []                                                                     // R6.3 independent-bin floor
        var rf = 0.05
        while rf <= 0.80 { if abs(rf - bestF) > 1.5 * binW { refPow.append(power(rf)) }; rf += binW }
        refPow.sort()
        let floor = (refPow.isEmpty ? bestP : refPow[refPow.count / 2]) + 1e-9
        if bestP / floor < 50 { return nil }                                                          // SNR vs honest floor
        if (bestF - 0.15) <= 1.0 * binW {                                                             // R5 sub-physio drift guard
            var subMax = 0.0
            var sf = 0.03
            while sf < 0.15 { subMax = max(subMax, power(sf)); sf += binW }
            if subMax >= 0.8 * bestP { return nil }
        }
        if bestF < surfaceFloor { return nil }                                                       // R6.4 band-edge floor (§5.1): a peak pinned to the 0.15 Hz DFT floor is not a defensible 9 br/min
        return bestF
    }
}

// MARK: - VigilPaths — the ONE resolver for the ~/.vigil state surface (QA-isolatable)
//
// WHY THIS EXISTS (burned 2026-07-12): the map/zone state used to be resolved with
// `NSString(string: "~/.vigil/…").expandingTildeInPath`, which goes through
// NSHomeDirectory() → getpwuid() and **ignores the $HOME environment variable**. A QA pass
// launched under `env HOME=/tmp/vgqa-…` therefore wrote `exclusion_zones.json` into the
// OWNER'S REAL ~/.vigil while his live Vigil was running — and on a security product a stray
// exclusion zone silently SUPPRESSES real presence dots (ExclusionZones.suppresses). There was
// no safe way to exercise the map surface at all. `env HOME=` is NOT isolation for this app.
//
// Resolution order (first match wins):
//   1. VIGIL_HOME          — explicit override; the isolation knob for QA/tests.
//   2. HOMEFRONT_DATA_DIR  — the existing workspace override (VigilDatabase.baseURL): one env
//      var isolates the WHOLE state surface, so a harness that already isolated the SQLite
//      workspace can no longer leak the map into the owner's home.
//   3. ~/.vigil            — unchanged legacy behaviour. With neither var set the resolved
//      path is byte-identical to the old literal, so the owner's live install is untouched.
//
// Pure: resolution NEVER creates a directory (callers create on write, as they already did),
// so merely resolving a path in a test cannot materialise ~/.vigil in a real home.
// Reads the environment with getenv() rather than ProcessInfo so an in-process setenv() from a
// test is observed immediately — the override is provable in both directions.
enum VigilPaths {
    static let overrideKey = "VIGIL_HOME"
    static let workspaceKey = "HOMEFRONT_DATA_DIR"

    private static func env(_ key: String) -> String? {
        guard let raw = getenv(key) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    /// The base directory holding user_walls.json / exclusion_zones.json and siblings.
    static func base() -> URL {
        if let dir = env(overrideKey) {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        if let dir = env(workspaceKey) {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("vigil", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".vigil", isDirectory: true)
    }

    /// A named state file inside the base directory. The ONLY way app code names a
    /// ~/.vigil file — a raw "~/.vigil/…" literal anywhere else escapes the override.
    static func url(_ name: String) -> URL {
        base().appendingPathComponent(name)
    }
}

// MARK: - Relay send — the REAL network round-trip, in one testable seam
//
// WHY THIS EXISTS: every one of the 619 tests covered only the PURE builder
// (RemoteRelay.request / .testRequest). The part a buyer actually stakes a fall on — the
// URLSession POST and the (HTTP status → "did it reach the relay?") decision — was executed
// by nobody but the shipped app. `RemoteRelaySender` holds that decision, so the 200 / 500 /
// transport-error / unconfigured legs are exercised against a real socket by test.sh.
// HomeStore.sendRemoteRelay is now a thin adapter over this: it logs and records, it does not
// decide. §5.1: a non-2xx can NEVER be rendered as delivered.

/// The outcome of one real relay POST, classified from the live URLSession result.
enum RelayPostResult: Equatable {
    case delivered(code: Int)     // a genuine 2xx — the ONLY state that may read as delivered
    case rejected(code: Int)      // reached the endpoint, but it answered non-2xx
    case transportError(String)   // never reached the endpoint (DNS/refused/timeout)

    /// The single source of truth for RelayDelivery.ok — true ONLY on a real 2xx (§5.1).
    var ok: Bool {
        if case .delivered = self { return true }
        return false
    }

    /// The History line the buyer reads. A failure NEVER contains "delivered".
    func logLine(label: String) -> String {
        switch self {
        case .delivered(let code):    return "\(label) delivered to relay (HTTP \(code))."
        case .rejected(let code):     return "\(label) delivery failed: relay returned HTTP \(code)."
        case .transportError(let m):  return "\(label) delivery failed: \(m)."
        }
    }
}

/// Performs the off-device relay POST. The network path the "Send test alert" button reaches.
enum RemoteRelaySender {
    /// Classify a URLSession result. Pure — a missing/non-HTTP response can never pass as 2xx.
    static func classify(response: URLResponse?, error: Error?) -> RelayPostResult {
        if let error = error { return .transportError(error.localizedDescription) }
        guard let code = (response as? HTTPURLResponse)?.statusCode else {
            return .transportError("relay returned no HTTP response")
        }
        return (200...299).contains(code) ? .delivered(code: code) : .rejected(code: code)
    }

    /// Fire the real POST. `session` is injectable only so a test can use an ephemeral,
    /// cache-free session against a local listener — the shipped app passes .shared.
    static func send(_ req: RemoteRelayRequest,
                     session: URLSession = .shared,
                     completion: @escaping (RelayPostResult) -> Void) {
        session.dataTask(with: req.urlRequest) { _, response, error in
            completion(classify(response: response, error: error))
        }.resume()
    }
}
