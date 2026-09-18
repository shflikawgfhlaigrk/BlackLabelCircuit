// Vigil — pure, Foundation-only energy monitoring (Tier-3).
//
// Real per-plug power reading from smart plugs that expose energy on the LAN
// for free, with NO cloud account and NO paid SDK (Black Label own-it §5.5):
//   • Shelly Gen2+  — GET /rpc/Shelly.GetStatus  → switch:0.apower / aenergy.total
//   • Shelly Gen1   — GET /status                → meters[0].power / total
//   • Tasmota       — GET /cm?cmnd=Status%208    → StatusSNS.ENERGY.{Power,Today,Total}
//   • TP-Link Kasa  — TCP :9999 autokey JSON     → emeter.get_realtime.{power_mw,total_wh}
//
// The parsers, the Kasa autokey cipher, and the cost model are pure and
// deterministic so they unit-test without a live LAN, NWConnection, or SwiftUI.
// EnergyViews.swift wraps these with the actual URLSession / TCP transport.
//
// Honesty rule (Black Label binding §5.1/§5.2 — the same accuracy-or-nothing
// stance as the vitals gate): every watt comes from a REAL device response.
// A plug that does not report energy, a malformed payload, or a non-finite /
// negative number yields NO reading — never a fabricated or interpolated watt.
// The view shows an honest "no metered devices found" empty state instead.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One real power reading from one device on the user's own network.
struct EnergyReading: Identifiable, Equatable {
    let id: String          // stable per device (host)
    let name: String
    let host: String
    let proto: EnergyProto
    let watts: Double            // instantaneous power draw, W (finite, ≥ 0)
    let todayKWh: Double?        // energy used today, kWh — only if the device reports it
    let totalKWh: Double?        // lifetime energy, kWh — only if the device reports it
}

/// The local energy protocols Vigil can read, all free + accountless.
enum EnergyProto: String, CaseIterable, Identifiable {
    case shellyGen2, shellyGen1, tasmota, kasa
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shellyGen2: return "Shelly (Gen2+)"
        case .shellyGen1: return "Shelly (Gen1)"
        case .tasmota:    return "Tasmota"
        case .kasa:       return "TP-Link Kasa"
        }
    }
    /// HTTP GET path for the protocols that speak plain HTTP. Kasa is raw TCP (nil).
    var httpPath: String? {
        switch self {
        case .shellyGen2: return "/rpc/Shelly.GetStatus"
        case .shellyGen1: return "/status"
        case .tasmota:    return "/cm?cmnd=Status%208"
        case .kasa:       return nil
        }
    }
    var isHTTP: Bool { httpPath != nil }
    /// HTTP protocols probed in order (most common / most specific first).
    static var httpProbeOrder: [EnergyProto] { [.shellyGen2, .shellyGen1, .tasmota] }
}

// MARK: - Pure parsers (Data → EnergyReading?)

enum EnergyParser {
    /// Parse a device payload for the given protocol. Returns nil for anything
    /// that is not a real, finite, non-negative reading (no fabrication).
    static func parse(_ data: Data, proto: EnergyProto, id: String, name: String, host: String) -> EnergyReading? {
        switch proto {
        case .shellyGen2: return shellyGen2(data, id: id, name: name, host: host)
        case .shellyGen1: return shellyGen1(data, id: id, name: name, host: host)
        case .tasmota:    return tasmota(data, id: id, name: name, host: host)
        case .kasa:       return kasa(data, id: id, name: name, host: host)
        }
    }

    // -- helpers --
    private static func obj(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    /// A finite Double from a JSON number (Int/Double/NSNumber). Rejects NaN/∞.
    private static func num(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
    /// A finite, non-negative watt value, else nil (a negative/NaN watt is not real).
    private static func watts(_ v: Any?) -> Double? {
        guard let d = num(v), d >= 0 else { return nil }
        return d
    }

    // -- Shelly Gen2+ : /rpc/Shelly.GetStatus --
    static func shellyGen2(_ data: Data, id: String, name: String, host: String) -> EnergyReading? {
        guard let o = obj(data) else { return nil }
        for key in ["switch:0", "switch:1", "pm1:0"] {
            guard let comp = o[key] as? [String: Any], let w = watts(comp["apower"]) else { continue }
            var total: Double? = nil
            if let ae = comp["aenergy"] as? [String: Any], let wh = num(ae["total"]), wh >= 0 {
                total = wh / 1000.0       // Wh → kWh
            }
            return EnergyReading(id: id, name: name, host: host, proto: .shellyGen2,
                                 watts: w, todayKWh: nil, totalKWh: total)
        }
        return nil
    }

    // -- Shelly Gen1 : /status --
    static func shellyGen1(_ data: Data, id: String, name: String, host: String) -> EnergyReading? {
        guard let o = obj(data) else { return nil }
        // Plug/1PM: meters[].power (W), meters[].total (Watt-minutes).
        if let meters = o["meters"] as? [[String: Any]], let m = meters.first, let w = watts(m["power"]) {
            let total = num(m["total"]).flatMap { $0 >= 0 ? $0 / 60000.0 : nil }   // Wmin → kWh
            return EnergyReading(id: id, name: name, host: host, proto: .shellyGen1,
                                 watts: w, todayKWh: nil, totalKWh: total)
        }
        // EM: emeters[].power (W), emeters[].total (Wh).
        if let ems = o["emeters"] as? [[String: Any]], let e = ems.first, let w = watts(e["power"]) {
            let total = num(e["total"]).flatMap { $0 >= 0 ? $0 / 1000.0 : nil }    // Wh → kWh
            return EnergyReading(id: id, name: name, host: host, proto: .shellyGen1,
                                 watts: w, todayKWh: nil, totalKWh: total)
        }
        return nil
    }

    // -- Tasmota : /cm?cmnd=Status 8 → StatusSNS.ENERGY --
    static func tasmota(_ data: Data, id: String, name: String, host: String) -> EnergyReading? {
        guard let o = obj(data),
              let sns = o["StatusSNS"] as? [String: Any],
              let e = sns["ENERGY"] as? [String: Any],
              let w = watts(e["Power"]) else { return nil }
        let today = num(e["Today"]).flatMap { $0 >= 0 ? $0 : nil }   // already kWh
        let total = num(e["Total"]).flatMap { $0 >= 0 ? $0 : nil }   // already kWh
        return EnergyReading(id: id, name: name, host: host, proto: .tasmota,
                             watts: w, todayKWh: today, totalKWh: total)
    }

    // -- TP-Link Kasa : decrypted emeter.get_realtime JSON --
    static func kasa(_ data: Data, id: String, name: String, host: String) -> EnergyReading? {
        guard let o = obj(data),
              let em = o["emeter"] as? [String: Any],
              let rt = em["get_realtime"] as? [String: Any] else { return nil }
        if let ec = num(rt["err_code"]), ec != 0 { return nil }
        // Modern fw: power_mw (milliwatts); legacy fw: power (W).
        let w: Double?
        if let mw = num(rt["power_mw"]) { w = mw >= 0 ? mw / 1000.0 : nil }
        else { w = watts(rt["power"]) }
        guard let power = w else { return nil }
        // Modern: total_wh (Wh); legacy: total (kWh).
        let total: Double?
        if let wh = num(rt["total_wh"]) { total = wh >= 0 ? wh / 1000.0 : nil }
        else { total = num(rt["total"]).flatMap { $0 >= 0 ? $0 : nil } }
        return EnergyReading(id: id, name: name, host: host, proto: .kasa,
                             watts: power, todayKWh: nil, totalKWh: total)
    }
}

// MARK: - TP-Link Kasa "autokey" cipher (pure, in-house — no paid SDK)

/// Kasa's local TCP API obfuscates its JSON with an autokey XOR stream seeded at
/// 0xAB, length-prefixed by a 4-byte big-endian count. Pure + reversible so the
/// round-trip is unit-testable; the NWConnection transport lives in the view layer.
enum KasaCipher {
    static let realtimeQuery = "{\"emeter\":{\"get_realtime\":{}}}"

    static func encrypt(_ s: String) -> [UInt8] {
        var key: UInt8 = 0xAB
        var out: [UInt8] = []
        for b in Array(s.utf8) { let a = key ^ b; out.append(a); key = a }
        return out
    }
    static func decrypt(_ bytes: [UInt8]) -> String {
        var key: UInt8 = 0xAB
        var out: [UInt8] = []
        for b in bytes { out.append(key ^ b); key = b }
        return String(decoding: out, as: UTF8.self)
    }
    /// A full TCP frame: 4-byte big-endian length prefix + ciphertext.
    static func frame(_ s: String) -> [UInt8] {
        let c = encrypt(s)
        let n = UInt32(c.count)
        return [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                UInt8(truncatingIfNeeded: n >> 8),  UInt8(truncatingIfNeeded: n)] + c
    }
}

// MARK: - Cost model (pure)

/// Aggregation + cost projection over a set of real readings. All defensive:
/// negative inputs clamp to 0; an empty reading set yields an honest zero/nil.
enum EnergyModel {
    static func totalWatts(_ rs: [EnergyReading]) -> Double { rs.reduce(0) { $0 + max(0, $1.watts) } }

    /// Measured today's kWh summed over devices that actually report it (else nil).
    static func measuredTodayKWh(_ rs: [EnergyReading]) -> Double? {
        let vals = rs.compactMap(\.todayKWh)
        return vals.isEmpty ? nil : vals.reduce(0, +)
    }

    /// Project a day of kWh from an instantaneous watt draw (W → kWh/day).
    static func projectedDailyKWh(watts: Double) -> Double { max(0, watts) / 1000.0 * 24.0 }

    static func cost(kWh: Double, ratePerKWh: Double) -> Double { max(0, kWh) * max(0, ratePerKWh) }

    static func projectedDailyCost(watts: Double, ratePerKWh: Double) -> Double {
        cost(kWh: projectedDailyKWh(watts: watts), ratePerKWh: ratePerKWh)
    }
    static func projectedMonthlyCost(watts: Double, ratePerKWh: Double) -> Double {
        cost(kWh: projectedDailyKWh(watts: watts) * 30.0, ratePerKWh: ratePerKWh)
    }
}

// MARK: - HTTP poller (Foundation/URLSession — the real network read)

/// Probes a host across the HTTP energy protocols and returns the first real
/// reading. Kasa (TCP) is handled separately in the view layer. No fabrication:
/// a host that answers nothing parseable yields nil.
struct EnergyHTTPPoller {
    var session: URLSession = .shared
    var timeout: TimeInterval = 4

    func poll(host: String, name: String) async -> EnergyReading? {
        for proto in EnergyProto.httpProbeOrder {
            guard let path = proto.httpPath, let url = URL(string: "http://\(host)\(path)") else { continue }
            var req = URLRequest(url: url); req.timeoutInterval = timeout
            guard let (data, resp) = try? await session.data(for: req),
                  let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { continue }
            if let r = EnergyParser.parse(data, proto: proto, id: host, name: name, host: host) { return r }
        }
        return nil
    }
}


// MARK: - Energy history / trends (pure, persisted, accuracy-or-nothing)

/// One timestamped snapshot of the total measured draw (W) across the user's
/// metered devices. Persisted to the local store so Vigil can show real
/// energy *trends* — every sample is a measurement, never an estimate.
struct EnergySample: Codable, Equatable {
    let ts: Date
    let watts: Double            // total instantaneous draw at `ts`, finite >= 0
}

/// One calendar day's measured energy, for the trend chart.
struct EnergyDay: Identifiable, Equatable {
    let day: Date
    let kWh: Double
    var id: Date { day }
}

/// Pure history math: integrates the sampled watt series into kWh, honest about
/// gaps. Same accuracy-or-nothing stance as the live reading and the vitals
/// gate — a dark period (app closed / no samples) longer than `maxGap` is NOT
/// integrated. Vigil under-reports rather than fabricate energy it never
/// measured. Pure + deterministic so it unit-tests with fixed timestamps.
enum EnergyHistory {
    static let defaultMaxGap: TimeInterval = 15 * 60      // 15 min between samples
    static let defaultRetainDays = 30

    /// Trapezoidal integral of W over time -> kWh. Intervals longer than
    /// `maxGap` are skipped; empty / single-sample series -> 0 (honest zero).
    static func kWh(_ samples: [EnergySample], maxGap: TimeInterval = defaultMaxGap) -> Double {
        guard samples.count >= 2 else { return 0 }
        let s = samples.sorted { $0.ts < $1.ts }
        var wh = 0.0
        for i in 1..<s.count {
            let dt = s[i].ts.timeIntervalSince(s[i - 1].ts)
            guard dt > 0, dt <= maxGap else { continue }
            let avgW = (max(0, s[i].watts) + max(0, s[i - 1].watts)) / 2
            wh += avgW * (dt / 3600.0)                    // W -> W*h
        }
        return wh / 1000.0                                // W*h -> kWh
    }

    /// kWh bucketed per calendar day, sorted ascending. Each interval's energy
    /// is attributed to the day of its earlier sample (gap-clamped as in `kWh`).
    static func dailyKWh(_ samples: [EnergySample],
                         calendar: Calendar = .current,
                         maxGap: TimeInterval = defaultMaxGap) -> [EnergyDay] {
        guard samples.count >= 2 else { return [] }
        let s = samples.sorted { $0.ts < $1.ts }
        var buckets: [Date: Double] = [:]
        for i in 1..<s.count {
            let dt = s[i].ts.timeIntervalSince(s[i - 1].ts)
            guard dt > 0, dt <= maxGap else { continue }
            let avgW = (max(0, s[i].watts) + max(0, s[i - 1].watts)) / 2
            let day = calendar.startOfDay(for: s[i - 1].ts)
            buckets[day, default: 0] += avgW * (dt / 3600.0) / 1000.0
        }
        return buckets.map { EnergyDay(day: $0.key, kWh: $0.value) }.sorted { $0.day < $1.day }
    }

    /// Append a new sample and prune anything older than `retainDays` before it.
    /// Pure -> testable; the store calls it on each scan.
    static func appended(_ history: [EnergySample], sample: EnergySample,
                         retainDays: Int = defaultRetainDays,
                         calendar: Calendar = .current) -> [EnergySample] {
        var h = history
        h.append(sample)
        h.sort { $0.ts < $1.ts }
        guard let cutoff = calendar.date(byAdding: .day, value: -retainDays, to: sample.ts) else { return h }
        return h.filter { $0.ts >= cutoff }
    }
}
