#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Vigil — real LAN device discovery and a real, free, local HTTP control
// path. Two lanes, both honest:
//   • Bonjour / mDNS via NWBrowser (one browser per service type)
//   • SSDP / UPnP via a UDP M-SEARCH multicast
// No cloud, no vendor SDK, no fabricated devices: this lists what is genuinely
// advertised on the user's own network and honestly marks whether Vigil can
// control it or only see it. The pure parsing/coverage logic lives in
// DiscoveryCatalog.swift (Foundation-only, unit-tested); this file is just the
// NWBrowser / NWConnection plumbing that feeds it.

import Foundation
#if canImport(Network) && !CIRCUIT_WINDOWS_SIM
import Network
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CircuitPortKit

@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var found: [DiscoveredDevice] = []
    @Published private(set) var scanning = false

    private var browsers: [NWBrowser] = []
    private var ssdp: NWConnection?

    func start() {
        guard browsers.isEmpty else { return }
        scanning = true
        // Lane 1 — Bonjour: one browser per declared service type.
        for type in DiscoveryCatalog.serviceTypes {
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: .init())
            b.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.absorbBonjour(results, type: type) }
            }
            b.start(queue: .main)
            browsers.append(b)
        }
        // Lane 2 — SSDP/UPnP: a single M-SEARCH multicast.
        startSSDP()
    }

    func stop() {
        browsers.forEach { $0.cancel() }; browsers.removeAll()
        ssdp?.cancel(); ssdp = nil
        scanning = false
    }

    // MARK: - Bonjour

    private func absorbBonjour(_ results: Set<NWBrowser.Result>, type: String) {
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint,
                  let cand = DiscoveryCatalog.candidate(serviceName: name, serviceType: type),
                  !found.contains(where: { $0.id == cand.id })
            else { continue }
            found.append(cand)
        }
        // Drop entries no longer advertised for this Bonjour type.
        let liveIDs = Set(results.compactMap { r -> String? in
            if case let .service(n, _, _, _) = r.endpoint { return "\(n)|\(type)" }; return nil
        })
        found.removeAll { $0.serviceType == type && $0.source != .ssdp && !liveIDs.contains($0.id) }
        sortFound()
    }

    // MARK: - SSDP / UPnP

    private func startSSDP() {
        let host = NWEndpoint.Host(SSDP.multicastHost)
        let port = NWEndpoint.Port(rawValue: SSDP.port)!
        let conn = NWConnection(host: host, port: port, using: .udp)
        ssdp = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            conn.send(content: SSDP.searchDatagram(), completion: .contentProcessed { _ in })
            Task { @MainActor in self?.receiveSSDP() }
        }
        conn.start(queue: .main)
    }

    private func receiveSSDP() {
        ssdp?.receiveMessage { [weak self] data, _, _, error in
            if let data, let raw = String(data: data, encoding: .utf8) {
                Task { @MainActor in self?.absorbSSDP(raw) }
            }
            if error == nil { Task { @MainActor in self?.receiveSSDP() } }
        }
    }

    private func absorbSSDP(_ raw: String) {
        guard let cand = SSDP.parse(raw),
              !found.contains(where: { $0.id == cand.id }) else { return }
        found.append(cand)
        sortFound()
    }

    private func sortFound() {
        found.sort { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Build a store device from a discovered one (delegates to the pure catalog).
    static func makeDevice(from d: DiscoveredDevice) -> HFDevice {
        DiscoveryCatalog.makeDevice(from: d)
    }
}

// MARK: - Real local control for open-API devices (OWN-IT, free, no cloud)

/// The open switch dialects Vigil can drive locally — the SAME device families the
/// Energy tab already reads (Shelly / Tasmota / Kasa) plus WLED (the one dialect
/// discovery itself marks controllable). Success is a VERIFIED acknowledgement:
/// each dialect's response is parsed for its own ack shape, never inferred from a
/// bare HTTP 200 (a Tasmota answers 200 to unknown paths — §5.1, no fabricated ok).
enum LANControl {
    enum SwitchProto: String, CaseIterable {
        case wled, tasmota, shellyGen2, shellyGen1, kasa
    }

    /// Confirmed dialect per host so repeat commands go straight to the right
    /// endpoint instead of re-probing every dialect. In-memory only — a relaunch
    /// re-probes, which also survives a device being re-flashed.
    private actor ProtoCache {
        static let shared = ProtoCache()
        private var byHost: [String: SwitchProto] = [:]
        func confirmed(_ host: String) -> SwitchProto? { byHost[host] }
        func remember(_ host: String, _ p: SwitchProto) { byHost[host] = p }
        func forget(_ host: String) { byHost.removeValue(forKey: host) }
    }

    /// Strip scheme + path from a stored host/URL down to the bare host[:port].
    static func bareHost(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "http://", with: "")
                          .replacingOccurrences(of: "https://", with: "")
        return stripped.split(separator: "/").first.map(String.init) ?? stripped
    }

    /// Switch a device on/off over its local open API. Probes the dialects in
    /// order until one gives a verified ack (then remembers it for the host).
    /// Returns true ONLY on a verified device acknowledgement.
    static func setSwitch(host: String, on: Bool) async -> Bool {
        if let known = await ProtoCache.shared.confirmed(host) {
            if await sendVerified(known, host: host, on: on) { return true }
            // The remembered dialect stopped answering (offline or re-flashed) —
            // drop it and re-probe once before reporting failure.
            await ProtoCache.shared.forget(host)
        }
        for p in SwitchProto.allCases {
            if await sendVerified(p, host: host, on: on) {
                await ProtoCache.shared.remember(host, p)
                return true
            }
        }
        return false
    }

    /// Brightness for dialects with a local dimmer verb (implies on, like the
    /// physical dimmers do). Returns true on a verified ack; false when nothing
    /// acked; nil when the host's confirmed dialect has no brightness verb — the
    /// caller must NOT keep a fabricated brightness in that case.
    static func setBrightness(host: String, level01: Double) async -> Bool? {
        if await ProtoCache.shared.confirmed(host) == nil {
            // One on-command both identifies the dialect and turns the light on.
            guard await setSwitch(host: host, on: true) else { return false }
        }
        guard let p = await ProtoCache.shared.confirmed(host) else { return false }
        let clamped = max(0.0, min(1.0, level01))
        let pct = Int((clamped * 100).rounded())
        switch p {
        case .wled:
            let a = Int((clamped * 255).rounded())
            guard let body = await getBody("http://\(host)/win&T=1&A=\(a)") else { return false }
            return body.contains("<vs>")
        case .tasmota:
            guard let body = await getBody("http://\(host)/cm?cmnd=Dimmer%20\(pct)"),
                  let o = jsonObject(body) else { return false }
            return o["Dimmer"] != nil
        case .shellyGen2:
            guard let body = await getBody("http://\(host)/rpc/Light.Set?id=0&on=true&brightness=\(pct)"),
                  let o = jsonObject(body) else { return false }
            return o["was_on"] != nil
        case .shellyGen1:
            guard let body = await getBody("http://\(host)/light/0?turn=on&brightness=\(pct)"),
                  let o = jsonObject(body) else { return false }
            return (o["ison"] as? Bool) == true
        case .kasa:
            return nil     // plug relay — no dimmer verb
        }
    }

    /// One dialect's on/off command with its own ack verification.
    private static func sendVerified(_ p: SwitchProto, host: String, on: Bool) async -> Bool {
        switch p {
        case .wled:
            // /win&T= answers the XML state document; anything else is not WLED.
            guard let body = await getBody("http://\(host)/win&T=\(on ? 1 : 0)") else { return false }
            return body.contains("<vs>")
        case .tasmota:
            guard let body = await getBody("http://\(host)/cm?cmnd=Power%20\(on ? "On" : "Off")"),
                  let o = jsonObject(body) else { return false }
            let want = on ? "ON" : "OFF"
            return (o["POWER"] as? String)?.uppercased() == want
                || (o["POWER1"] as? String)?.uppercased() == want
        case .shellyGen2:
            guard let body = await getBody("http://\(host)/rpc/Switch.Set?id=0&on=\(on)"),
                  let o = jsonObject(body) else { return false }
            return o["was_on"] != nil
        case .shellyGen1:
            guard let body = await getBody("http://\(host)/relay/0?turn=\(on ? "on" : "off")"),
                  let o = jsonObject(body) else { return false }
            return (o["ison"] as? Bool) == on
        case .kasa:
            return await KasaControl.setRelay(host: host, on: on)
        }
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func getBody(_ s: String) async -> String? {
        guard let url = URL(string: s) else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 4
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch { return nil }
    }
}

/// TP-Link Kasa relay control over its local TCP :9999 API, using the SAME pure
/// KasaCipher the Energy reader uses. ok = the device's own err_code 0 ack.
enum KasaControl {
    static func setRelay(host: String, on: Bool, port: UInt16 = 9999, timeout: TimeInterval = 4) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let query = "{\"system\":{\"set_relay_state\":{\"state\":\(on ? 1 : 0)}}}"
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock(); var finished = false
            func finish(_ ok: Bool) {
                lock.lock(); let already = finished; finished = true; lock.unlock()
                if already { return }
                conn.cancel(); cont.resume(returning: ok)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(KasaCipher.frame(query)), completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                            guard let data, data.count > 4 else { finish(false); return }
                            let decoded = KasaCipher.decrypt(Array(data.dropFirst(4)))
                            guard let jd = decoded.data(using: .utf8),
                                  let o = (try? JSONSerialization.jsonObject(with: jd)) as? [String: Any],
                                  let sys = o["system"] as? [String: Any],
                                  let ack = sys["set_relay_state"] as? [String: Any],
                                  let ec = ack["err_code"] as? NSNumber
                            else { finish(false); return }
                            finish(ec.intValue == 0)
                        }
                    })
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
    }
}
#endif // circuit-convert
