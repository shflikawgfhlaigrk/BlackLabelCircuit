#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Vigil — Energy monitoring UI (Tier-3). The sidebar "Energy" tab.
//
// Reads REAL power draw from the user's own smart plugs (Shelly / Tasmota /
// TP-Link Kasa) over their free local APIs and shows live watts + a cost
// estimate from the user's own $/kWh rate. The parsing, cipher, and cost math
// are pure in Energy.swift; this file is the thin transport + SwiftUI surface.
//
// Honest empty state throughout: no metered device → "add a smart plug"; a
// scan that finds nothing → "none reported energy" (never a fabricated watt).

#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(Network) && !CIRCUIT_WINDOWS_SIM
import Network
#endif
import Foundation

// MARK: - Store (orchestrates the real network read + holds the user's rate)

@MainActor
final class EnergyStore: ObservableObject {
    @Published private(set) var readings: [EnergyReading] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date? = nil
    @Published private(set) var probed = 0
    @Published var ratePerKWh: Double { didSet { UserDefaults.standard.set(ratePerKWh, forKey: Self.rateKey) } }

    private static let rateKey = "hf_energy_rate_usd"
    private let http = EnergyHTTPPoller()

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.rateKey)
        ratePerKWh = saved > 0 ? saved : 0.17     // US avg ≈ $0.17/kWh; fully user-editable
    }

    /// Probe every device that carries a LAN host for a real power reading. A
    /// device that returns nothing parseable produces NO reading (no fabrication).
    func scan(devices: [HFDevice]) async {
        let targets: [(host: String, name: String)] = devices.compactMap { d in
            guard let raw = d.host, !raw.isEmpty else { return nil }
            let host = raw.replacingOccurrences(of: "http://", with: "")
                          .replacingOccurrences(of: "https://", with: "")
                          .split(separator: "/").first.map(String.init) ?? raw
            return (host, d.name)
        }
        scanning = true; probed = targets.count
        defer { scanning = false; lastScan = Date() }
        var found: [EnergyReading] = []
        for t in targets {
            if let r = await http.poll(host: t.host, name: t.name) { found.append(r); continue }
            if let r = await KasaReader.read(host: t.host, name: t.name) { found.append(r) }
        }
        readings = found
    }
}

// MARK: - Kasa TCP transport (real read over :9999 using the pure KasaCipher)

enum KasaReader {
    static func read(host: String, name: String, port: UInt16 = 9999, timeout: TimeInterval = 4) async -> EnergyReading? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<EnergyReading?, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock(); var finished = false
            func finish(_ r: EnergyReading?) {
                lock.lock(); let already = finished; finished = true; lock.unlock()
                if already { return }
                conn.cancel(); cont.resume(returning: r)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let frame = Data(KasaCipher.frame(KasaCipher.realtimeQuery))
                    conn.send(content: frame, completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                            guard let data, data.count > 4 else { finish(nil); return }
                            let payload = Array(data.dropFirst(4))
                            guard let jd = KasaCipher.decrypt(payload).data(using: .utf8),
                                  let r = EnergyParser.parse(jd, proto: .kasa, id: host, name: name, host: host)
                            else { finish(nil); return }
                            finish(r)
                        }
                    })
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
    }
}

// MARK: - View

struct EnergyView: View {
    @EnvironmentObject var store: HomeStore
    @StateObject private var energy = EnergyStore()
    @State private var rateText = ""
    /// Re-evaluates the scan-freshness gate while the tab stays open (same
    /// pattern as MenuBarPanel) so "now" can honestly age out into a timestamp.
    @State private var now = Date()
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var meterable: [HFDevice] { store.state.devices.filter { !($0.host ?? "").isEmpty } }
    private var totalW: Double { EnergyModel.totalWatts(energy.readings) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                rateCard
                if energy.readings.isEmpty {
                    emptyState
                } else {
                    totalsCard
                    ForEach(energy.readings) { r in readingRow(r) }
                }
                historyCard
                footnote
            }
            .padding(20)
        }
        .onAppear { rateText = String(format: "%.2f", energy.ratePerKWh); now = Date() }
        .onReceive(tick) { now = $0 }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Energy").font(.system(size: 26, weight: .bold)).foregroundColor(.white)
                Text(headerSubtitle).font(.system(size: 12)).foregroundColor(Palette.dim)
            }
            Spacer()
            if energy.scanning {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Scanning \(energy.probed)…").font(.system(size: 11)).foregroundColor(Palette.dim)
                }
            } else if !meterable.isEmpty {
                GhostButton(title: "Scan \(meterable.count) device\(meterable.count == 1 ? "" : "s")") {
                    Task { await runScan() }
                }
            }
        }
    }
    private var headerSubtitle: String {
        guard let scanned = energy.lastScan else { return "Reads real power from your own smart plugs — never estimated" }
        // "now" only inside the same freshness window the menu bar honors; an old
        // scan is shown with its clock time, never as current (§5.1).
        if now.timeIntervalSince(scanned) <= MenuBarModel.defaultFreshness {
            return "\(energy.readings.count) metered · \(wattsStr(totalW)) now"
        }
        return "\(energy.readings.count) metered · \(wattsStr(totalW)) as of \(Self.clock(scanned)) — scan again for fresh numbers"
    }
    private static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    private var rateCard: some View {
        Card(title: "Electricity rate", subtitle: "used to estimate cost from measured watts") {
            HStack(spacing: 10) {
                Text("$").foregroundColor(Palette.dim)
                Field(placeholder: "0.17", text: $rateText).frame(width: 90)
                Text("per kWh").font(.system(size: 11)).foregroundColor(Palette.dim)
                GhostButton(title: "Apply") {
                    if let v = Double(rateText.trimmingCharacters(in: .whitespaces)), v >= 0 { energy.ratePerKWh = v }
                    rateText = String(format: "%.2f", energy.ratePerKWh)
                }
                Spacer()
            }
        }
    }

    private var emptyState: some View {
        EmptyCard(
            icon: "bolt.slash",
            title: meterable.isEmpty ? "No metered devices yet"
                 : (energy.lastScan == nil ? "Ready to scan" : "No energy reported"),
            message: emptyMessage,
            cta: (meterable.isEmpty || energy.scanning) ? nil : "Scan \(meterable.count) device\(meterable.count == 1 ? "" : "s")",
            tap: (meterable.isEmpty || energy.scanning) ? nil : { Task { await runScan() } }
        )
    }
    private var emptyMessage: String {
        if meterable.isEmpty {
            return "Add a smart plug with energy metering — Shelly, Tasmota, or TP-Link Kasa — in Rooms with its LAN address, and Vigil reads its real power draw here. Readings come from your own devices, never estimated."
        }
        if energy.lastScan == nil {
            return "\(meterable.count) device\(meterable.count == 1 ? " has" : "s have") a LAN address. Scan to read live power from any that expose energy locally (Shelly / Tasmota / Kasa)."
        }
        return "Scanned \(energy.probed) device\(energy.probed == 1 ? "" : "s"); none reported energy. Vigil only shows power a plug actually measures — no fabricated watts."
    }

    private var totalsCard: some View {
        Card(title: "Now drawing",
             // Stamped, not "live": the readings are from the last scan and stay on
             // screen after it — the stamp keeps the claim true at any age.
             subtitle: "\(energy.readings.count) metered device\(energy.readings.count == 1 ? "" : "s") · measured \(energy.lastScan.map(Self.clock) ?? "—")") {
            VStack(alignment: .leading, spacing: 12) {
                Text(wattsStr(totalW)).font(.system(size: 30, weight: .bold)).foregroundColor(Palette.gold)
                HStack(alignment: .top, spacing: 24) {
                    stat("Projected today", costStr(EnergyModel.projectedDailyCost(watts: totalW, ratePerKWh: energy.ratePerKWh)))
                    stat("Projected / month", costStr(EnergyModel.projectedMonthlyCost(watts: totalW, ratePerKWh: energy.ratePerKWh)))
                    if let today = EnergyModel.measuredTodayKWh(energy.readings) {
                        stat("Measured today", String(format: "%.2f kWh", today))
                    }
                }
            }
        }
    }
    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            Text(k).font(.system(size: 10)).foregroundColor(Palette.dim)
        }
    }

    private func readingRow(_ r: EnergyReading) -> some View {
        HStack {
            Image(systemName: "powerplug.fill").foregroundColor(Palette.gold).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Text("\(r.proto.label) · \(r.host)").font(.system(size: 10)).foregroundColor(Palette.dim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(wattsStr(r.watts)).font(.system(size: 14, weight: .semibold)).foregroundColor(Palette.goldTxt)
                if let t = r.totalKWh { Text(String(format: "%.1f kWh total", t)).font(.system(size: 10)).foregroundColor(Palette.dim) }
                else if let d = r.todayKWh { Text(String(format: "%.2f kWh today", d)).font(.system(size: 10)).foregroundColor(Palette.dim) }
            }
        }
        .padding(13).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.stroke))
    }

    private var footnote: some View {
        Text("Power is read directly from each device's local API (no cloud, no account). Cost figures are estimates from your rate × measured watts.")
            .font(.system(size: 10)).foregroundColor(Palette.dim).padding(.top, 2)
    }

    private func wattsStr(_ w: Double) -> String {
        w >= 1000 ? String(format: "%.2f kW", w / 1000) : String(format: "%.0f W", w)
    }
    private func costStr(_ c: Double) -> String { String(format: "$%.2f", c) }
    private func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }

    // MARK: - History / trends (persisted real samples -> measured kWh per day)

    /// Run a scan, then persist the measured total as a history sample — but only
    /// when the scan actually read a device, so we never record a fabricated 0.
    private func runScan() async {
        await energy.scan(devices: store.state.devices)
        if !energy.readings.isEmpty {
            store.recordEnergy(totalWatts: EnergyModel.totalWatts(energy.readings))
        }
    }

    private var energyDays: [EnergyDay] { EnergyHistory.dailyKWh(store.state.energyHistory) }

    private var historyCard: some View {
        Card(title: "History", subtitle: "measured kWh per day — from your own readings") {
            Group {
                if energyDays.isEmpty {
                    Text("No history yet. Each scan records the live total; daily energy appears here once Vigil has two readings spanning time. Never an estimate.")
                        .font(.system(size: 11)).foregroundColor(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    historyChart
                }
            }
        }
    }

    private var historyChart: some View {
        let days = energyDays
        let recent = Array(days.suffix(14))
        let maxK = max(recent.map(\.kWh).max() ?? 0, 0.0001)
        let total = days.reduce(0) { $0 + $1.kWh }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(recent) { d in
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3).fill(Palette.gold)
                            .frame(height: max(3, CGFloat(d.kWh / maxK) * 88))
                        Text(dayLabel(d.day)).font(.system(size: 8)).foregroundColor(Palette.dim)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 108)
            Text("\(fmt2(total)) kWh over \(days.count) day\(days.count == 1 ? "" : "s") · ~\(costStr(EnergyModel.cost(kWh: total, ratePerKWh: energy.ratePerKWh))) at \(costStr(energy.ratePerKWh))/kWh")
                .font(.system(size: 10)).foregroundColor(Palette.dim)
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d"; return f.string(from: d)
    }
}
#endif // circuit-convert
