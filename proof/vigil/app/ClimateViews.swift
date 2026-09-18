// Vigil — Climate dashboard UI (Tier-3). The sidebar "Climate" tab.
//
// A climate-intelligence layer over the user's OWN thermostats: real ambient
// temperature read from free local device APIs (Shelly / Tasmota) where a device
// exposes one, a per-zone mode + setpoint + daily schedule the user owns, and
// presence-driven ECO that relaxes the target when the home is sensed empty —
// off the SAME real sensing the rest of Vigil runs on. The parsing,
// schedule resolver, deadband demand, and eco math are pure in Climate.swift;
// this file is the thin URLSession transport + SwiftUI surface.
//
// Honest throughout: no thermostat → "add one in Rooms"; a zone whose device
// exposes no readable temperature shows "—" (never a fabricated temperature);
// direct setpoint push to a cloud/commissioned thermostat is labeled "pairing
// required" rather than faked. The schedule + eco are the user's local plan.

#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
import Foundation

// MARK: - Per-zone climate config (user-owned, persisted)

/// The user's climate plan for one thermostat zone. Codable so it persists to
/// UserDefaults keyed by the device id — survives relaunch, ships with nothing.
struct ClimateConfig: Codable, Equatable {
    var mode: HVACMode = .auto
    var setpointF: Double = 70
    var deadbandF: Double = 1.0
    var scheduleEnabled: Bool = false
    var schedule: [ClimateBlock] = ClimateSchedule.defaultSchedule
    var ecoEnabled: Bool = false
    var ecoSetbackF: Double = 4.0
}

// MARK: - Store (persists configs + runs the real temperature read)

@MainActor
final class ClimateStore: ObservableObject {
    @Published private(set) var configs: [UUID: ClimateConfig] = [:]
    @Published private(set) var readings: [String: ClimateReading] = [:]   // by host
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date? = nil

    private static let key = "hf_climate_configs"
    private let http = ClimateHTTPPoller()

    init() { load() }

    func config(for id: UUID) -> ClimateConfig { configs[id] ?? ClimateConfig() }

    func update(_ id: UUID, _ mutate: (inout ClimateConfig) -> Void) {
        var c = config(for: id); mutate(&c); configs[id] = c; save()
    }

    /// Read real ambient temperature from every thermostat zone that carries a
    /// LAN host. A device that returns nothing parseable produces NO reading.
    func scan(devices: [HFDevice]) async {
        let targets: [(host: String, name: String)] = devices.compactMap { d in
            guard d.kind == .thermostat, let raw = d.host, !raw.isEmpty else { return nil }
            let host = raw.replacingOccurrences(of: "http://", with: "")
                          .replacingOccurrences(of: "https://", with: "")
                          .split(separator: "/").first.map(String.init) ?? raw
            return (host, d.name)
        }
        scanning = true
        defer { scanning = false; lastScan = Date() }
        var found: [String: ClimateReading] = [:]
        for t in targets {
            if let r = await http.poll(host: t.host, name: t.name) { found[t.host] = r }
        }
        readings = found
    }

    /// The real measured temperature for a device, or nil (never a guess).
    func currentF(for d: HFDevice) -> Double? {
        guard let raw = d.host, !raw.isEmpty else { return nil }
        let host = raw.replacingOccurrences(of: "http://", with: "")
                      .replacingOccurrences(of: "https://", with: "")
                      .split(separator: "/").first.map(String.init) ?? raw
        return readings[host]?.currentF
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([UUID: ClimateConfig].self, from: data) else { return }
        configs = decoded
    }
    private func save() {
        if let data = try? JSONEncoder().encode(configs) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

// MARK: - View

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct ClimateView: View {
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var sonar: AcousticSonar
    @StateObject private var climate = ClimateStore()

    private var thermostats: [HFDevice] { store.state.devices.filter { $0.kind == .thermostat } }
    private var present: Bool { (engine.frame?.present ?? false) || sonar.present }
    private var scannable: [HFDevice] { thermostats.filter { !($0.host ?? "").isEmpty } }

    /// The minute of day, for schedule resolution (refreshed by the app's clock tick).
    private var nowMinute: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if thermostats.isEmpty {
                    emptyState
                } else {
                    ecoCard
                    ForEach(thermostats) { zoneCard($0) }
                }
                footnote
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Climate").font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                Text(headerSubtitle).font(.system(size: 12)).foregroundColor(Palette.dim)
            }
            Spacer()
            if climate.scanning {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Reading…").font(.system(size: 11)).foregroundColor(Palette.dim)
                }
            } else if !scannable.isEmpty {
                GhostButton(title: "Read \(scannable.count) zone\(scannable.count == 1 ? "" : "s")") {
                    Task { await climate.scan(devices: store.state.devices) }
                }
            }
        }
    }
    private var headerSubtitle: String {
        guard !thermostats.isEmpty else { return "Real temperature + presence-driven eco from your own devices" }
        // Readings live until the next manual scan — stamp them instead of
        // claiming "now" indefinitely (§5.1).
        if let avg = avgTemp {
            return "\(thermostats.count) zone\(thermostats.count == 1 ? "" : "s") · \(tempStr(avg)) average, read \(scanStamp)"
        }
        return "\(thermostats.count) zone\(thermostats.count == 1 ? "" : "s") · no temperature read yet"
    }
    private var scanStamp: String { climate.lastScan.map(Self.clock) ?? "—" }
    private static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    private var avgTemp: Double? { ClimateModel.averageF(Array(climate.readings.values)) }

    private var emptyState: some View {
        EmptyCard(
            icon: "thermometer.medium.slash",
            title: "No thermostats yet",
            message: "Add a thermostat or a temperature sensor in Rooms with its LAN address. Vigil reads its real ambient temperature (Shelly / Tasmota, no cloud, no account) and lets you set a schedule and presence-driven eco here. Temperatures come from your own devices — never estimated.",
            cta: nil, tap: nil
        )
    }

    // -- Eco (presence-driven) --
    private var ecoCard: some View {
        Card(title: "Presence eco",
             subtitle: present ? "Someone is home — sensed live" : "No presence detected — eco zones set back") {
            HStack(spacing: 12) {
                Image(systemName: present ? "house.fill" : "figure.walk.departure")
                    .foregroundColor(present ? Palette.gold : Palette.dim).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(present ? "Home occupied" : "Home empty")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    Text("Eco zones relax their target when Vigil senses the house is empty — off the same WiFi/acoustic sensing, never a guess.")
                        .font(.system(size: 10)).foregroundColor(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    // -- One thermostat zone --
    private func zoneCard(_ d: HFDevice) -> some View {
        let cfg = climate.config(for: d.id)
        let current = climate.currentF(for: d)
        // base setpoint = schedule (if on) else the manual setpoint; then eco setback.
        let base = (cfg.scheduleEnabled ? ClimateSchedule.setpoint(cfg.schedule, at: nowMinute) : nil) ?? cfg.setpointF
        let effective = ClimateEco.effectiveSetpoint(base: base, mode: cfg.mode, occupied: present, setbackF: cfg.ecoEnabled ? cfg.ecoSetbackF : 0)
        let demand = ClimateEngine.demand(mode: cfg.mode, currentF: current, setpointF: effective, deadbandF: cfg.deadbandF)
        let ecoActive = ClimateEco.isActive(enabled: cfg.ecoEnabled, occupied: present, setbackF: cfg.ecoSetbackF)

        return Card(title: d.name, subtitle: store.state.roomName(d.roomID)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current == nil ? "—" : tempStr(current!))
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(current == nil ? Palette.dim : Palette.gold)
                        Text(current == nil ? "no reading" : "measured \(scanStamp)").font(.system(size: 10)).foregroundColor(Palette.dim)
                    }
                    demandBadge(demand)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("target \(tempStr(effective))").font(.system(size: 14, weight: .semibold)).foregroundColor(Palette.goldTxt)
                        if cfg.scheduleEnabled, let blk = ClimateSchedule.activeBlock(cfg.schedule, at: nowMinute) {
                            Text("\(blk.label) · \(blk.startLabel)").font(.system(size: 10)).foregroundColor(Palette.dim)
                        } else if ecoActive {
                            Text("eco −\(Int(cfg.ecoSetbackF))°").font(.system(size: 10)).foregroundColor(Palette.dim)
                        }
                    }
                }

                modePicker(d, cfg)
                if !cfg.scheduleEnabled { setpointStepper(d, cfg) }
                ecoToggle(d, cfg)
                scheduleToggle(d, cfg)

                if d.control == .pairRequired {
                    Text("Vigil reads this zone but can't push its setpoint under the current pairing — control requires pairing/commissioning. Mode, schedule, and eco here drive the live demand readout.")
                        .font(.system(size: 10)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func demandBadge(_ d: HVACDemand) -> some View {
        let color: Color = d == .heating ? Color(red: 0.92, green: 0.55, blue: 0.25)
                         : d == .cooling ? Color(red: 0.40, green: 0.68, blue: 0.95)
                         : Palette.dim
        return HStack(spacing: 5) {
            Image(systemName: d.symbol).font(.system(size: 11))
            Text(d.label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.12)).clipShape(Capsule())
        .overlay(Capsule().stroke(color.opacity(0.4)))
    }

    private func modePicker(_ d: HFDevice, _ cfg: ClimateConfig) -> some View {
        HStack(spacing: 6) {
            ForEach(HVACMode.allCases) { m in
                Button { climate.update(d.id) { $0.mode = m } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: m.symbol).font(.system(size: 10))
                        Text(m.label).font(.system(size: 11, weight: cfg.mode == m ? .semibold : .regular))
                    }
                    .foregroundColor(cfg.mode == m ? Palette.gold : Palette.dim)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(cfg.mode == m ? Palette.goldInk : Palette.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(cfg.mode == m ? Palette.gold.opacity(0.4) : Palette.stroke))
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func setpointStepper(_ d: HFDevice, _ cfg: ClimateConfig) -> some View {
        HStack(spacing: 10) {
            Text("Setpoint").font(.system(size: 11)).foregroundColor(Palette.dim)
            GhostButton(title: "−") { climate.update(d.id) { $0.setpointF = max(45, $0.setpointF - 1) } }
            Text(tempStr(cfg.setpointF)).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).frame(width: 52)
            GhostButton(title: "+") { climate.update(d.id) { $0.setpointF = min(95, $0.setpointF + 1) } }
            Spacer()
        }
    }

    private func ecoToggle(_ d: HFDevice, _ cfg: ClimateConfig) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { cfg.ecoEnabled }, set: { v in climate.update(d.id) { $0.ecoEnabled = v } })) {
                Text("Presence eco (−\(Int(cfg.ecoSetbackF))° when empty)").font(.system(size: 11)).foregroundColor(Palette.dim)
            }.toggleStyle(.switch).tint(Palette.gold)
            Spacer()
        }
    }

    private func scheduleToggle(_ d: HFDevice, _ cfg: ClimateConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { cfg.scheduleEnabled }, set: { v in climate.update(d.id) { $0.scheduleEnabled = v } })) {
                    Text("Daily schedule").font(.system(size: 11)).foregroundColor(Palette.dim)
                }.toggleStyle(.switch).tint(Palette.gold)
                Spacer()
            }
            if cfg.scheduleEnabled {
                HStack(spacing: 6) {
                    ForEach(cfg.schedule.sorted { $0.startMinute < $1.startMinute }) { b in
                        VStack(spacing: 1) {
                            Text(b.label).font(.system(size: 9, weight: .semibold)).foregroundColor(Palette.goldTxt)
                            Text(tempStr(b.setpointF)).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                            Text(b.startLabel).font(.system(size: 8)).foregroundColor(Palette.dim)
                        }
                        .padding(.vertical, 6).frame(maxWidth: .infinity)
                        .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.stroke))
                    }
                }
            }
        }
    }

    private var footnote: some View {
        Text("Temperature is read directly from each device's local API (no cloud, no account). Setpoint, schedule, and eco are your own plan and drive the live heat/cool demand. With no real reading a zone shows “—” — never a fabricated temperature.")
            .font(.system(size: 10)).foregroundColor(Palette.dim).padding(.top, 2)
    }

    private func tempStr(_ f: Double) -> String { String(format: "%.0f°F", f) }
}
#endif // circuit-convert
