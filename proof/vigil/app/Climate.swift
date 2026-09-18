// Vigil — pure, Foundation-only climate intelligence (Tier-3).
//
// A climate layer over the user's OWN thermostats and temperature sensors with
// NO cloud account and NO paid SDK (Black Label own-it §5.5). Ambient
// temperature is read from the same free local device APIs Vigil already
// speaks for energy:
//   • Shelly Gen2+  — GET /rpc/Shelly.GetStatus  → temperature:N.{tF,tC}
//   • Shelly Gen1   — GET /status                → tmp.{tF,tC} / ext_temperature
//   • Tasmota       — GET /cm?cmnd=Status%208    → StatusSNS.<sensor>.Temperature (+ TempUnit)
//
// The differentiator (Vigil's moat) is presence-driven ECO: setpoints relax
// when the home is sensed UNOCCUPIED — driven by the WiFi-CSI / acoustic sensing,
// never a fabricated occupancy. The thermostat brain (demand with hysteresis),
// the schedule resolver, the eco setback, and the temperature parsers are all
// pure and deterministic so they unit-test without a live LAN or SwiftUI.
// ClimateViews.swift wraps these with the actual URLSession transport + UI.
//
// Honesty rule (Black Label binding §5.1/§5.2 — the same accuracy-or-nothing
// stance as the vitals and energy gates): every temperature comes from a REAL
// device response within a plausible indoor band. A malformed payload, a
// non-finite value, or a reading outside [40,110]°F yields NO reading — never a
// fabricated or interpolated temperature. With no real temp the system reports
// `idle`, never a guessed heat/cool demand.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - HVAC mode + demand

/// The user-selected operating mode for a thermostat zone.
enum HVACMode: String, Codable, CaseIterable, Identifiable {
    case heat, cool, auto, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .heat: return "Heat"; case .cool: return "Cool"
        case .auto: return "Auto"; case .off: return "Off"
        }
    }
    var symbol: String {
        switch self {
        case .heat: return "flame.fill";        case .cool: return "snowflake"
        case .auto: return "thermometer.medium"; case .off: return "power"
        }
    }
}

/// What the HVAC should be doing right now — the derived call, not a setting.
enum HVACDemand: String, Equatable {
    case heating, cooling, idle, off
    var label: String {
        switch self {
        case .heating: return "Heating"; case .cooling: return "Cooling"
        case .idle: return "Idle";       case .off: return "Off"
        }
    }
    var symbol: String {
        switch self {
        case .heating: return "flame.fill"; case .cooling: return "snowflake"
        case .idle: return "pause.circle";  case .off: return "power"
        }
    }
}

// MARK: - Pure climate engine

enum ClimateEngine {
    /// Plausible indoor temperature band (°F). A reading outside this is treated
    /// as a bad/garbage sensor value and discarded — never shown (no fabrication).
    static let minPlausibleF = 40.0
    static let maxPlausibleF = 110.0

    static func isPlausible(_ f: Double) -> Bool {
        f.isFinite && f >= minPlausibleF && f <= maxPlausibleF
    }

    /// The live HVAC call from a REAL current temperature vs the setpoint, with a
    /// symmetric deadband (hysteresis) so the system doesn't chatter at the edge.
    /// With no real, plausible temperature the call is `.idle` — Vigil never
    /// guesses a heat/cool demand from a missing reading.
    static func demand(mode: HVACMode, currentF: Double?, setpointF: Double, deadbandF: Double = 1.0) -> HVACDemand {
        guard mode != .off else { return .off }
        guard let c = currentF, isPlausible(c) else { return .idle }
        let half = max(0, deadbandF) / 2
        switch mode {
        case .heat: return c < setpointF - half ? .heating : .idle
        case .cool: return c > setpointF + half ? .cooling : .idle
        case .auto:
            if c < setpointF - half { return .heating }
            if c > setpointF + half { return .cooling }
            return .idle
        case .off: return .off
        }
    }
}

/// Celsius/Fahrenheit conversion (pure). Devices report in either; the app is °F.
enum TempScale {
    static func cToF(_ c: Double) -> Double { c * 9.0 / 5.0 + 32.0 }
    static func fToC(_ f: Double) -> Double { (f - 32.0) * 5.0 / 9.0 }
}

// MARK: - Schedule (per-zone setpoint by time of day)

/// One setpoint block in a daily schedule (e.g. Wake 68° at 6:00, Sleep 62° at 22:00).
struct ClimateBlock: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var startMinute: Int          // 0…1439 (minute of day the block begins)
    var setpointF: Double
    var label: String

    /// "6:00 AM" style label for the block's start.
    var startLabel: String {
        let m = ((startMinute % 1440) + 1440) % 1440
        let h24 = m / 60, mm = m % 60
        let ampm = h24 < 12 ? "AM" : "PM"
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        return String(format: "%d:%02d %@", h12, mm, ampm)
    }
}

enum ClimateSchedule {
    /// The block in effect at `minute`, wrapping across midnight: before the first
    /// block of the day the previous day's last block is still active. Pure +
    /// deterministic. Returns nil only for an empty schedule.
    static func activeBlock(_ blocks: [ClimateBlock], at minute: Int) -> ClimateBlock? {
        guard !blocks.isEmpty else { return nil }
        let sorted = blocks.sorted { $0.startMinute < $1.startMinute }
        let m = ((minute % 1440) + 1440) % 1440
        var active = sorted.last!                 // wrap-around default
        for b in sorted {
            if b.startMinute <= m { active = b } else { break }
        }
        return active
    }

    /// The scheduled setpoint at `minute`, or nil for an empty schedule.
    static func setpoint(_ blocks: [ClimateBlock], at minute: Int) -> Double? {
        activeBlock(blocks, at: minute)?.setpointF
    }

    /// A sensible default 4-block comfort schedule, fully user-editable in the UI.
    static var defaultSchedule: [ClimateBlock] {
        [ClimateBlock(startMinute: 6 * 60,  setpointF: 70, label: "Wake"),
         ClimateBlock(startMinute: 9 * 60,  setpointF: 66, label: "Day"),
         ClimateBlock(startMinute: 17 * 60, setpointF: 71, label: "Evening"),
         ClimateBlock(startMinute: 22 * 60, setpointF: 63, label: "Sleep")]
    }
}

// MARK: - Eco (presence-driven setback — the sensing moat tie-in)

enum ClimateEco {
    /// Relax the setpoint by `setbackF` when the home is sensed UNOCCUPIED, to
    /// save energy: heat targets drop, cool targets rise. Occupied → unchanged.
    /// Driven ONLY by real sensed presence — no fabricated occupancy ever moves
    /// the setpoint. `auto`/`off` are left alone (don't second-guess the band).
    static func effectiveSetpoint(base: Double, mode: HVACMode, occupied: Bool, setbackF: Double) -> Double {
        guard !occupied, setbackF > 0 else { return base }
        switch mode {
        case .heat: return base - setbackF
        case .cool: return base + setbackF
        case .auto, .off: return base
        }
    }

    /// True only when eco is enabled AND the home is genuinely sensed empty —
    /// the one condition under which Vigil has applied a setback.
    static func isActive(enabled: Bool, occupied: Bool, setbackF: Double) -> Bool {
        enabled && !occupied && setbackF > 0
    }
}

// MARK: - Real temperature reading (pure parsers, Data → °F?)

/// One real ambient temperature reading (°F) from one device on the user's LAN.
struct ClimateReading: Identifiable, Equatable {
    let id: String          // stable per device (host)
    let name: String
    let host: String
    let proto: EnergyProto  // reuse the Shelly/Tasmota/Kasa protocol taxonomy
    let currentF: Double    // finite + within the plausible indoor band
}

enum ClimateParser {
    /// Parse an ambient temperature in °F from a device payload, or nil for
    /// anything that is not a real, finite, plausible reading (no fabrication).
    static func temperatureF(_ data: Data, proto: EnergyProto, id: String, name: String, host: String) -> ClimateReading? {
        let f: Double?
        switch proto {
        case .shellyGen2: f = shellyGen2F(data)
        case .shellyGen1: f = shellyGen1F(data)
        case .tasmota:    f = tasmotaF(data)
        case .kasa:       f = nil          // Kasa plugs don't expose ambient temp
        }
        guard let temp = f, ClimateEngine.isPlausible(temp) else { return nil }
        return ClimateReading(id: id, name: name, host: host, proto: proto, currentF: temp)
    }

    // -- helpers --
    private static func obj(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func num(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    // -- Shelly Gen2+ : /rpc/Shelly.GetStatus → temperature:N --
    static func shellyGen2F(_ data: Data) -> Double? {
        guard let o = obj(data) else { return nil }
        // Dedicated temperature component (add-on / H&T): temperature:0.{tF,tC}.
        for key in ["temperature:0", "temperature:1"] {
            if let t = o[key] as? [String: Any] {
                if let tf = num(t["tF"]) { return tf }
                if let tc = num(t["tC"]) { return TempScale.cToF(tc) }
            }
        }
        return nil
    }

    // -- Shelly Gen1 : /status → tmp.{tF,tC} (H&T) or ext_temperature[0].tC --
    static func shellyGen1F(_ data: Data) -> Double? {
        guard let o = obj(data) else { return nil }
        if let t = o["tmp"] as? [String: Any] {
            if let tf = num(t["tF"]) { return tf }
            if let tc = num(t["tC"]) { return TempScale.cToF(tc) }
        }
        if let ext = o["ext_temperature"] as? [String: Any],
           let first = ext.values.compactMap({ $0 as? [String: Any] }).first {
            if let tf = num(first["tF"]) { return tf }
            if let tc = num(first["tC"]) { return TempScale.cToF(tc) }
        }
        return nil
    }

    // -- Tasmota : /cm?cmnd=Status 8 → StatusSNS.<sensor>.Temperature, unit per TempUnit --
    static func tasmotaF(_ data: Data) -> Double? {
        guard let o = obj(data), let sns = o["StatusSNS"] as? [String: Any] else { return nil }
        let unit = (sns["TempUnit"] as? String)?.uppercased() ?? "C"
        func convert(_ raw: Double) -> Double { unit == "F" ? raw : TempScale.cToF(raw) }
        // A temperature can sit at the top of StatusSNS or under a named sensor block.
        if let t = num(sns["Temperature"]) { return convert(t) }
        for (k, v) in sns {
            guard k != "TempUnit", let block = v as? [String: Any], let t = num(block["Temperature"]) else { continue }
            return convert(t)
        }
        return nil
    }
}

// MARK: - Aggregation (pure)

enum ClimateModel {
    /// Mean ambient temperature over devices that actually reported a plausible
    /// reading, or nil when none did (honest empty — never a fabricated average).
    static func averageF(_ rs: [ClimateReading]) -> Double? {
        let vs = rs.map(\.currentF).filter(ClimateEngine.isPlausible)
        return vs.isEmpty ? nil : vs.reduce(0, +) / Double(vs.count)
    }

    /// Count of zones currently calling for each demand, across the readings.
    static func tally(_ demands: [HVACDemand]) -> (heating: Int, cooling: Int, idle: Int, off: Int) {
        var h = 0, c = 0, i = 0, o = 0
        for d in demands {
            switch d { case .heating: h += 1; case .cooling: c += 1; case .idle: i += 1; case .off: o += 1 }
        }
        return (h, c, i, o)
    }
}

// MARK: - HTTP poller (Foundation/URLSession — the real network read)

/// Probes a host across the HTTP-speaking protocols for a real temperature and
/// returns the first plausible reading. No fabrication: a host that answers
/// nothing parseable yields nil. The transport mirrors EnergyHTTPPoller.
struct ClimateHTTPPoller {
    var session: URLSession = .shared
    var timeout: TimeInterval = 4

    func poll(host: String, name: String) async -> ClimateReading? {
        for proto in EnergyProto.httpProbeOrder {
            guard let path = proto.httpPath, let url = URL(string: "http://\(host)\(path)") else { continue }
            var req = URLRequest(url: url); req.timeoutInterval = timeout
            guard let (data, resp) = try? await session.data(for: req),
                  let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { continue }
            if let r = ClimateParser.temperatureF(data, proto: proto, id: host, name: name, host: host) { return r }
        }
        return nil
    }
}
