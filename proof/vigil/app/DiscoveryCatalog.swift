// Vigil — pure, Foundation-only discovery catalog + parsers.
//
// The Bonjour service-type coverage matrix, the candidate builder (with
// Vigil sensor tier-name recognition), and the SSDP/UPnP response parser
// live here as pure, deterministic functions so they are unit-testable without
// NWBrowser, a live LAN, or SwiftUI. Discovery.swift wraps these with the actual
// NWBrowser browses and the UDP M-SEARCH socket.
//
// Honesty rule (Black Label binding §5.1/§5.2): every candidate comes from a
// REAL advertisement — a Bonjour browse result or a parsed SSDP datagram. An
// empty network yields no candidates ("no devices found"), never a fabricated
// device. Service types we don't understand are dropped, not invented.

import Foundation

/// A device genuinely seen on the user's own network. Carries an honest control
/// state (can we actuate it, only read it, or does it need pairing we can't do
/// under an adhoc signature?).
struct DiscoveredDevice: Identifiable, Equatable {
    let id: String          // service name + type (stable per advertisement)
    let name: String
    let kind: DeviceKind
    let serviceType: String
    let control: ControlState
    let note: String        // honest one-liner about control
    var source: DeviceSource = .bonjour
}

enum DiscoveryCatalog {
    /// One row per Bonjour service type Vigil browses — the coverage matrix.
    /// (type, guessed kind, control reality, honest note)
    static let services: [(type: String, kind: DeviceKind, control: ControlState, note: String)] = [
        ("_hap._tcp",            .other,   .pairRequired, "HomeKit accessory — pair in Apple Home"),
        ("_matter._tcp",         .other,   .pairRequired, "Matter device — needs commissioning"),
        ("_matterc._udp",        .other,   .pairRequired, "Matter (commissionable)"),
        ("_googlecast._tcp",     .speaker, .pairRequired, "Google Cast target"),
        ("_airplay._tcp",        .speaker, .pairRequired, "AirPlay target"),
        ("_raop._tcp",           .speaker, .pairRequired, "AirPlay audio"),
        ("_spotify-connect._tcp",.speaker, .pairRequired, "Spotify Connect"),
        ("_hue._tcp",            .light,   .pairRequired, "Philips Hue bridge"),
        ("_wled._tcp",           .light,   .controllable, "WLED — controllable over local HTTP"),
        ("_rtsp._tcp",           .camera,  .readOnly,     "RTSP camera stream"),
        ("_onvif._tcp",          .camera,  .readOnly,     "ONVIF camera"),
        ("_axis-video._tcp",     .camera,  .readOnly,     "Axis camera"),
        ("_homekit._tcp",        .other,   .pairRequired, "HomeKit"),
        ("_ipp._tcp",            .other,   .readOnly,     "Printer"),
        ("_printer._tcp",        .other,   .readOnly,     "Printer"),
        ("_homefront._tcp",      .sensor,  .readOnly,     "Vigil sensor node"),
    ]

    /// Every Bonjour service type we browse — used by Discovery to spin up one
    /// NWBrowser per type, and by the coverage test to prove none were dropped.
    static var serviceTypes: [String] { services.map(\.type) }

    static func row(for serviceType: String) -> (type: String, kind: DeviceKind, control: ControlState, note: String)? {
        services.first { $0.type == serviceType }
    }

    /// True for the Bonjour service types that are Cast/AirPlay targets, so the
    /// stored device records `.cast` rather than `.bonjour` as its source.
    static func isCast(_ serviceType: String) -> Bool {
        let s = serviceType.lowercased()
        return s.contains("cast") || s.contains("airplay") || s.contains("raop")
    }

    /// Build a discovered-device candidate from a Bonjour advertisement. Pure.
    /// For our own `_homefront._tcp` nodes we recognize the advertised tier
    /// (Node / Sentry / Pulse) from the instance name and label it honestly, so
    /// the user can tell OUR hardware from a parts-bin ESP32. An unknown service
    /// type returns nil (dropped, never invented).
    static func candidate(serviceName: String, serviceType: String) -> DiscoveredDevice? {
        guard let r = row(for: serviceType) else { return nil }
        let id = "\(serviceName)|\(serviceType)"
        if serviceType == "_homefront._tcp", let tier = SensorTier.recognize(serviceName) {
            return DiscoveredDevice(
                id: id, name: serviceName, kind: .sensor, serviceType: serviceType,
                control: .readOnly,
                note: "\(tier.productName) — your own sensor (\(tier.job.lowercased()))",
                source: .bonjour)
        }
        return DiscoveredDevice(
            id: id, name: serviceName, kind: r.kind, serviceType: serviceType,
            control: r.control, note: r.note,
            source: isCast(serviceType) ? .cast : .bonjour)
    }

    /// Map a discovered device into a stored device, carrying the honest control
    /// state and source over unchanged. Pure.
    static func makeDevice(from d: DiscoveredDevice) -> HFDevice {
        HFDevice(name: d.name, kind: d.kind, roomID: nil, source: d.source,
                 control: d.control, model: d.serviceType)
    }
}

// MARK: - SSDP / UPnP (the second discovery lane the standard requires)

/// Pure SSDP/UPnP helpers: the M-SEARCH datagram Vigil broadcasts and the
/// parser that turns a search-response / NOTIFY datagram into a device
/// candidate. The actual UDP multicast socket lives in Discovery.swift; this
/// part is pure so it can be unit-tested against canned datagrams.
enum SSDP {
    static let multicastHost = "239.255.255.250"
    static let port: UInt16 = 1900

    /// The M-SEARCH datagram we multicast to enumerate UPnP root devices.
    static func searchDatagram(mx: Int = 2) -> Data {
        let body = [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(multicastHost):\(port)",
            "MAN: \"ssdp:discover\"",
            "MX: \(mx)",
            "ST: ssdp:all",
            "", ""
        ].joined(separator: "\r\n")
        return Data(body.utf8)
    }

    /// Case-insensitive header map from a raw SSDP/HTTP datagram. Pure.
    static func parseHeaders(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in raw.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !val.isEmpty { out[key] = val }
        }
        return out
    }

    /// Parse an SSDP search-response / NOTIFY datagram into a candidate. Pure.
    /// Returns nil for a malformed or device-less datagram (honest: a datagram
    /// that names no device produces no device). If the SERVER/USN advertises
    /// one of OUR sensor tiers, it is recognized as a Vigil node.
    static func parse(_ raw: String) -> DiscoveredDevice? {
        let h = parseHeaders(raw)
        let usn = h["usn"]
        let location = h["location"]
        guard usn != nil || location != nil else { return nil }
        let st = h["st"] ?? h["nt"] ?? "upnp:rootdevice"
        let server = h["server"]
        let id = (usn ?? location ?? st) + "|ssdp"

        if let tier = SensorTier.recognize(server) ?? SensorTier.recognize(usn) {
            return DiscoveredDevice(
                id: id, name: tier.advertised, kind: .sensor, serviceType: st,
                control: .readOnly,
                note: "\(tier.productName) — your own sensor (SSDP)",
                source: .ssdp)
        }
        return DiscoveredDevice(
            id: id, name: friendlyName(location: location, server: server, usn: usn),
            kind: kind(forST: st), serviceType: st, control: .readOnly,
            note: "UPnP device — \(st)", source: .ssdp)
    }

    static func kind(forST st: String) -> DeviceKind {
        let s = st.lowercased()
        if s.contains("mediarenderer") || s.contains("mediaserver") || s.contains("dial") { return .speaker }
        if s.contains("camera") || s.contains("basicvideo") { return .camera }
        if s.contains("dimmablelight") || s.contains("binarylight") { return .light }
        return .other
    }

    static func friendlyName(location: String?, server: String?, usn: String?) -> String {
        if let server, !server.isEmpty { return server }
        if let host = location.flatMap({ URL(string: $0)?.host }), !host.isEmpty { return host }
        if let usn, !usn.isEmpty { return usn }
        return "UPnP device"
    }
}
