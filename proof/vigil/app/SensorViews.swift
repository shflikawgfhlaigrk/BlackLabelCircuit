#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Vigil — the Sense hub (existing sensing tech, unchanged) + the Sensors
// section: the own-brand Node/Sentry/Pulse line (store, onboarding, management).
// The sensing pipeline is real; the sensor line is the $25/$39/$59 hardware that
// lights up the through-wall layer. Checkout stays on the owner's storefront —
// this app links out, it never builds the website.

#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
import Foundation

// MARK: - Sense hub (folds the four sensing tabs)

struct SenseHubView: View {
    enum Lens: String, CaseIterable { case house = "House", sonar = "Room Sonar", body = "Live 3D", csi = "CSI Reader", wifi = "Live WiFi" }
    @State private var lens: Lens = .house

    /// Map each lens to its honest availability class (HF-4): mic + camera ship
    /// on-device today; WiFi-CSI / through-wall is early access until the boards ship.
    private func modality(_ l: Lens) -> SenseModality {
        switch l {
        case .house: return .csiThroughWall
        case .sonar: return .acousticSonar
        case .body:  return .cameraPose
        case .csi:   return .csiThroughWall
        case .wifi:  return .liveWiFi
        }
    }

    private var runsAppleSiliconSlice: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Sense").font(.system(size: 16, weight: .bold)).foregroundColor(Palette.gold)
                Text("WiFi · acoustic · camera").font(.system(size: 10)).foregroundColor(Palette.dim)
                Spacer()
                ForEach(Lens.allCases, id: \.self) { l in
                    Button(l.rawValue) { lens = l }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: lens == l ? .semibold : .regular))
                        .foregroundColor(lens == l ? Palette.gold : Palette.dim)
                        .padding(.horizontal, 6)
                }
            }.padding(.horizontal, 18).padding(.vertical, 11)
            .background(Color(red: 0.051, green: 0.051, blue: 0.059))
            .overlay(Rectangle().frame(height: 1).foregroundColor(Palette.stroke), alignment: .bottom)
            availabilityStrip
            switch lens {
            case .house: VigilHouseView()
            case .sonar: SonarView()
            case .body: LiveBody3DView()
            case .csi: CSIReaderView()
            case .wifi: LiveSenseView()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Honest availability banner for the selected lens (HF-4 / §5.1). Never lets
    // through-wall/CSI read as a shipping consumer feature: it's real and built,
    // but early access until a ~$9 Vigil node is in hand.
    @ViewBuilder private var availabilityStrip: some View {
        let m = modality(lens)
        HStack(spacing: 8) {
            Image(systemName: m.isEarlyAccess ? "clock.badge" : "checkmark.seal.fill")
                .font(.system(size: 11))
                .foregroundColor(m.isEarlyAccess ? Palette.gold : .green)
            Text(m.availabilityLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(m.isEarlyAccess ? Palette.goldTxt : .green)
            if m.isEarlyAccess {
                Text("— real & built; needs a ~$9 Vigil node")
                    .font(.system(size: 11)).foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if m == .csiThroughWall,
               let notice = VigilPlatform.csiBoundaryMessage(isAppleSilicon: runsAppleSiliconSlice) {
                Text(notice)
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.goldTxt)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 18).padding(.vertical, 7)
        .background(m.isEarlyAccess ? Palette.goldInk : Color(red: 0.04, green: 0.06, blue: 0.05))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Palette.stroke), alignment: .bottom)
    }
}

// MARK: - Sensors (own-brand line)

struct SensorsView: View {
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var engine: Engine
    @State private var onboard: SensorTier? = nil
    @State private var relayDraft: String = ""      // GAP#G off-device relay editor (transient; never persisted here)
    /// "HH:mm" for the relay delivery-health line (matches EnergyViews' inline-formatter style).
    private static func relayClock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    @State private var showRelayEditor: Bool = false
    @State private var relayError: Bool = false

    private var sentinelNodes: [SentinelNode] {
        engine.sentinel?.nodes.filter(\.real) ?? []
    }
    private var onlineSentinelNodes: [SentinelNode] {
        sentinelNodes.filter(\.online)
    }
    /// The WIRED room fleet (engine /frame, UDP :5566) — the real deployed
    /// nodes. Sentinel (:5005) is the separate single-sensor product path;
    /// when it has nothing real this page must show the actual fleet, never
    /// a stale registration (Founder-caught: read as injected data).
    private var fleetRooms: [(room: String, link: RoomLink)] {
        (engine.frame?.rooms ?? [:]).sorted(by: { $0.key < $1.key })
            .map { (room: $0.key, link: $0.value) }
    }
    private var fleetLiveCount: Int { fleetRooms.filter(\.link.live).count }
    private var liveTier: SensorTier? {
        if let node = onlineSentinelNodes.first { return node.sensorTier }
        guard engine.frame?.csi_connected == true else { return nil }
        return SensorTier.recognize(engine.frame?.csi_tier) ?? .node
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Vigil Sensors").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                Text("Our own-brand presence radios — early access. One firmware, three jobs. ~$9 hardware → $25/$39/$59. A node in each room brings whole-home, through-wall sensing with no cameras — it goes live when the boards ship. Mic + camera sensing works on this Mac today.")
                    .font(.system(size: 12)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)

                // live connection banner
                liveBanner

                // predictive eldercare watch — the moat made visible + honest learning state
                eldercareCard

                // fall / no-breathing emergency watch — the engine emits /fall; surface it (§5.1 honest)
                fallCard

                // store line
                HStack(spacing: 14) {
                    ForEach(SensorTier.allCases) { tier in
                        SensorStoreCard(tier: tier, live: onlineSentinelNodes.contains { $0.sensorTier == tier }) { onboard = tier }
                    }
                }

                // registered nodes — the WIRED fleet first, always real
                Card(title: "Your ESP32 nodes",
                     subtitle: !fleetRooms.isEmpty
                        ? "\(fleetLiveCount)/\(fleetRooms.count) online · live CSI on :5566"
                        : (sentinelNodes.isEmpty ? "none online"
                           : "\(onlineSentinelNodes.count)/\(sentinelNodes.count) online")) {
                    if !fleetRooms.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(fleetRooms, id: \.room) { entry in
                                FleetNodeRow(room: entry.room, link: entry.link)
                            }
                        }
                    } else if !sentinelNodes.isEmpty {
                        VStack(spacing: 8) { ForEach(sentinelNodes) { SentinelNodeRow(node: $0) } }
                    } else if store.state.sensors.isEmpty {
                        Text("No real Vigil ESP32 nodes are streaming yet.")
                            .font(.system(size: 11)).foregroundColor(Palette.dim)
                    } else {
                        VStack(spacing: 8) { ForEach(store.state.sensors) { NodeRow(node: $0) } }
                    }
                }

                if sentinelNodes.isEmpty && fleetRooms.isEmpty {
                Card(title: "Sentinel", subtitle: "waiting for real ESP32 CSI") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("The Sentinel hub starts with the app — it listens on UDP 5005 and serves live node status on port 8790. Plug in and flash the ESP32s; this page fills from real node packets only.")
                            .font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                        Text("http://127.0.0.1:8790/nodes")
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.goldTxt)
                            .padding(8).background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
                }
            }.padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).flashyBackground()
        .sheet(item: $onboard) { tier in SensorOnboardSheet(tier: tier) }
    }

    @ViewBuilder private var eldercareCard: some View {
        Card(title: "Eldercare watch", subtitle: "predictive — learns your home’s rhythm") {
            if let b = engine.baseline, !b.ready {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(b.learningLine).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldTxt)
                }
                Text("Watches for an abnormal bed-exit or an unusually long inactivity gap once it has learned 3 nights. Nothing is flagged before then — no false alarms on day one.")
                    .font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
            } else if engine.baseline?.ready == true {
                if let a = engine.anomaly, a.isAnomaly {
                    Text(a.logMessage).font(.system(size: 12, weight: .semibold)).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Baseline learned — watching, all nominal.").font(.system(size: 12)).foregroundColor(Palette.goldTxt)
                }
                let recent = store.state.activity.filter { $0.kind == .anomaly }.prefix(5)
                if recent.isEmpty {
                    Text("No anomalies logged.").font(.system(size: 11)).foregroundColor(Palette.dim)
                } else {
                    VStack(spacing: 0) { ForEach(Array(recent)) { AttributedActivityRow(event: $0) } }
                }
            } else {
                Text("Predictive watch starts when the sensing engine is running. Native sensors still work.")
                    .font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // The fall/emergency moat made visible. The engine emits /fall but nothing consumed
    // it — a buyer got the detector with no way to SEE it. Honest states only (§5.1):
    // calibrating/empty/inactive are surfaced as such, never "safe"; a real, gated alert
    // shows the engine's message verbatim in red and is logged once per episode.
    // DG — the emergency channel's HONEST delivery state, read from the OS auth status
    // (HomeStore.notifAuth). For a fall-detection safety product an alert that can
    // silently die is the worst failure: show whether a fall will actually reach the
    // caregiver, and never claim "on" when the OS would drop it (§5.1).
    @ViewBuilder private var notifDeliveryRow: some View {
        let auth = store.notifAuth
        HStack(spacing: 8) {
            Image(systemName: auth.alertsDeliver ? "bell.badge.fill" : "bell.slash")
                .foregroundColor(auth.alertsDeliver ? .green : (auth == .denied ? .red : Palette.gold))
            Text(auth.cardLabel).font(.system(size: 11)).foregroundColor(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if auth.canEnableInApp {
                GhostButton(title: "Enable") { store.requestNotifications() }
            } else if auth == .denied {
                // Once denied the OS won't re-prompt — deep-link the Notifications pane
                // instead of leaving only a text path to retype (DOD-3.3).
                GhostButton(title: "Open System Settings") {
                    NSWorkspace.shared.open(SystemSettingsPane.notifications.url)
                }
            }
        }
    }

    // GAP#G — the OFF-DEVICE relay's HONEST config + state. A local notification only
    // reaches THIS Mac; in a retirement-home pilot the caregiver isn't here. The buyer
    // brings their OWN webhook (ntfy / Slack / Make / Zapier / generic POST); a gated
    // fall is POSTed there in addition to the banner. Ships EMPTY — never claims remote
    // reach without a real, validated endpoint (§5.1/§5.2).
    @ViewBuilder private var remoteRelayRow: some View {
        let relay = store.state.relay
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: relay.isConfigured ? "antenna.radiowaves.left.and.right" : "wifi.slash")
                    .foregroundColor(relay.isConfigured ? .green : Palette.gold)
                Text(relay.statusLabel).font(.system(size: 11)).foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                GhostButton(title: showRelayEditor ? "Close" : (relay.isConfigured ? "Edit" : "Add relay")) {
                    relayDraft = relay.webhook; relayError = false; showRelayEditor.toggle()
                }
            }
            // At-a-glance relay DELIVERY HEALTH: configured != proven-working. Derives ONLY
            // from the real last-POST outcome (RelayHealth.forCard). Unconfigured -> no line.
            if let health = RelayHealth.forCard(isConfigured: relay.isConfigured, last: relay.lastDelivery) {
                HStack(spacing: 6) {
                    Image(systemName: health.symbol).font(.system(size: 10))
                        .foregroundColor(health.ok ? .green : (health == .noneSent ? Palette.dim : .red))
                    Text(health.text(clock: health.at.map(Self.relayClock) ?? ""))
                        .font(.system(size: 10))
                        .foregroundColor(health == .noneSent ? Palette.dim : (health.ok ? Palette.dim : .red))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                }
            }
            if showRelayEditor {
                TextField("https://ntfy.sh/your-topic  (or any webhook URL you control)", text: $relayDraft)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                if relayError {
                    Text("That isn’t a valid http(s) URL — not saved.")
                        .font(.system(size: 10)).foregroundColor(.red)
                }
                HStack(spacing: 8) {
                    GhostButton(title: "Save") {
                        if store.setRelayWebhook(relayDraft) { relayError = false; showRelayEditor = false }
                        else { relayError = true }
                    }
                    if relay.isConfigured {
                        GhostButton(title: "Remove") {
                            store.clearRelayWebhook(); relayDraft = ""; relayError = false; showRelayEditor = false
                        }
                    }
                    Spacer()
                }
                Text("Vigil POSTs the same fall/emergency alert here in addition to the desktop banner. Your endpoint, your control — Vigil runs no server of its own.")
                    .font(.system(size: 10)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var fallCard: some View {
        Card(title: "Fall & emergency watch", subtitle: "no-motion / no-breathing — accurate-or-nothing") {
            notifDeliveryRow
            remoteRelayRow
            if !sentinelNodes.isEmpty {
                let alerts = sentinelNodes.compactMap { node -> (SentinelNode, SentinelFallAlert)? in
                    guard let alert = node.fall?.alert else { return nil }
                    return (node, alert)
                }
                if alerts.isEmpty {
                    Text("Sentinel live — \(onlineSentinelNodes.count)/\(sentinelNodes.count) ESP32 nodes reporting fall state.")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldTxt)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(alerts, id: \.0.nodeID) { node, alert in
                            HStack(spacing: 8) {
                                Image(systemName: "figure.fall").foregroundColor(.red)
                                Text("\(node.sensorTier.productName): \(alert.message ?? alert.kind ?? "fall alert")")
                                    .font(.system(size: 12, weight: .bold)).foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sentinelNodes) { node in
                        Text("\(node.sensorTier.productName) · \(node.fall?.state ?? (node.online ? "ONLINE" : "OFFLINE")) · \(node.online ? "\(node.frames) frames" : "offline")")
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.dim)
                    }
                }
            } else if let f = engine.fallState, f.active {
                if f.isAlert {
                    HStack(spacing: 8) {
                        Image(systemName: "figure.fall").foregroundColor(.red)
                        Text(f.displayLine).font(.system(size: 13, weight: .bold)).foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(f.displayLine).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldTxt)
                }
                Text("Watches a bedside node for a fall, an abnormally long no-motion gap, or no movement-and-breathing. Conservative by design — minutes-scale, so a calm sleeper is never flagged.")
                    .font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                let recent = store.state.activity.filter { $0.kind == .fall }.prefix(5)
                if recent.isEmpty {
                    Text("No fall or emergency alerts logged.").font(.system(size: 11)).foregroundColor(Palette.dim)
                } else {
                    VStack(spacing: 0) { ForEach(Array(recent)) { AttributedActivityRow(event: $0) } }
                }
            } else {
                Text(engine.fallState?.note ?? "Fall watch starts when a node is sensing this room live. It never claims all-clear without a real signal — only a real, gated emergency raises an alert, sent as a desktop notification when you’ve enabled them.")
                    .font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { store.requestNotificationsIfNeeded() }   // request auth at the Fall/Sense eldercare moment
    }

    @ViewBuilder private var liveBanner: some View {
        if let snap = engine.sentinel, !sentinelNodes.isEmpty {
            HStack(spacing: 10) {
                Circle().fill(snap.onlineCount > 0 ? Color.green : Palette.dim).frame(width: 9, height: 9)
                Text("Real ESP32 Sentinel — \(snap.onlineCount)/\(snap.nodeCount) online · \(sentinelNodes.reduce(0) { $0 + $1.frames }) CSI frames")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldTxt)
                Spacer()
                Text("REAL CSI").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.goldInk).foregroundColor(Palette.gold).clipShape(Capsule())
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.gold.opacity(0.5)))
        } else
        if let t = liveTier {
            let isDemo = engine.frame?.demo ?? false
            HStack(spacing: 10) {
                Circle().fill(isDemo ? Palette.gold : Color.green).frame(width: 9, height: 9)
                Text(isDemo ? "DEMO — synthetic capture (\(engine.frame?.csi_frames ?? 0) frames), vitals suppressed"
                            : "\(t.productName) live — \(engine.frame?.csi_frames ?? 0) CSI frames")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldTxt)
                Spacer()
                Text(isDemo ? "DEMO" : "THROUGH-WALL").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.goldInk).foregroundColor(Palette.gold).clipShape(Capsule())
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.gold.opacity(0.5)))
        }
    }
}

struct SentinelNodeRow: View {
    let node: SentinelNode
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.sensorTier.symbol)
                .foregroundColor(node.online ? Palette.gold : Palette.dim)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.sensorTier.productName)
                    .font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                Text("\(node.nodeID) · \(node.online ? "\(node.frames) frames" : "offline") · RSSI \(node.rssi.map(String.init) ?? "—")")
                    .font(.system(size: 10)).foregroundColor(Palette.dim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(node.demo == true ? "DEMO" : "REAL")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(node.demo == true ? Palette.gold : .green)
                Text(node.online ? (node.moving ? "moving" : "online") : "offline")
                    .font(.system(size: 10)).foregroundColor(Palette.dim)
            }
        }.padding(9).background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// Eldercare attribution surfaced on the caregiver's fall/anomaly feed: a now-non-silent
// alert is only useful if it says WHO/WHERE. Renders the attributed resident (+ room) when
// the event carries one, "Resident: unknown" when the attributed person was since removed,
// and nothing when unattributed — never a fabricated occupant (§5.1). Reads the exact
// HomeState.attribution(for:) the reglock pins.
struct AttributedActivityRow: View {
    @EnvironmentObject var store: HomeStore
    let event: ActivityEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ActivityRow(event: event)
            if let who = store.state.attribution(for: event) {
                HStack(spacing: 5) {
                    Image(systemName: "person.fill").font(.system(size: 9)).foregroundColor(Palette.dim)
                    Text("Resident: \(who)").font(.system(size: 10)).foregroundColor(Palette.goldTxt)
                }.padding(.leading, 28)
            }
        }
    }
}

struct SensorStoreCard: View {
    let tier: SensorTier; let live: Bool; let setup: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: tier.symbol).font(.system(size: 20)).foregroundColor(Palette.gold)
                Spacer()
                if live {
                    Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundColor(.green)
                } else if tier.isEarlyAccess {
                    // Honest tile badge (HF-4): the boards aren't in buyers' hands yet.
                    Text(SensorTier.earlyAccessBadge).font(.system(size: 8, weight: .bold))
                        .foregroundColor(Palette.gold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.goldInk).clipShape(Capsule())
                }
            }
            Text(tier.productName).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
            Text("$\(tier.priceUSD)").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(Palette.gold)
            Text(tier.job).font(.system(size: 11, weight: .medium)).foregroundColor(Palette.goldTxt)
            Text(tier.unlocks).font(.system(size: 10)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                GoldButton(title: "Get") { openStore(tier) }
                GhostButton(title: "I have one") { setup() }
            }
        }
        .padding(15).frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(live ? Palette.gold.opacity(0.55) : Palette.stroke))
    }
    private func openStore(_ tier: SensorTier) {
        let base = (Bundle.main.object(forInfoDictionaryKey: "BLStoreURL") as? String) ?? "https://blacklabelbots.com"
        if let u = URL(string: base) { NSWorkspace.shared.open(u) }
    }
}

struct NodeRow: View {
    @EnvironmentObject var store: HomeStore
    let node: HFSensorNode
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.tier.symbol).foregroundColor(node.online ? Palette.gold : Palette.dim).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                Text("\(node.tier.productName) · \(store.state.roomName(node.roomID))\(node.online ? " · \(node.framesSeen) frames" : " · offline")")
                    .font(.system(size: 10)).foregroundColor(Palette.dim)
            }
            Spacer()
            Picker("", selection: Binding(get: { node.roomID ?? noRoom }, set: { assign($0) })) {
                Text("Unassigned").tag(noRoom)
                ForEach(store.state.rooms) { r in Text(r.name).tag(r.id) }
            }.labelsHidden().frame(width: 150)
            Button(role: .destructive) { store.deleteSensor(node.id) } label: { Image(systemName: "trash").foregroundColor(Palette.dim) }.buttonStyle(.plain)
        }.padding(9).background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private let noRoom = UUID()
    private func assign(_ id: UUID) {
        store.assignSensor(node.id, toRoom: id == noRoom ? nil : id)
    }
}

struct SensorOnboardSheet: View {
    @EnvironmentObject var engine: Engine
    @Environment(\.dismiss) var dismiss
    let tier: SensorTier
    @State private var selectedFQBN = "esp32:esp32:esp32"
    @State private var serialPort = "auto"
    @State private var wifiSSID = ""
    @State private var wifiPassword = ""
    @State private var macIP = ""
    @State private var statusText = "Ready to flash in app. Enter the Wi-Fi password for this flash run."
    @State private var runLog = ""
    @State private var isFlashing = false
    @State private var receiptText = ""

    private let fqbnChoices = ["esp32:esp32:esp32", "esp32:esp32:esp32s3"]
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: tier.symbol).font(.system(size: 20)).foregroundColor(Palette.gold)
                Text("Set up \(tier.productName)").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Palette.dim) }.buttonStyle(.plain)
            }
            Text(tier.unlocks).font(.system(size: 11)).foregroundColor(Palette.dim)
            Divider().overlay(Palette.stroke)
            HStack(spacing: 9) {
                Button { revealFirmware() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder")
                        Text("Reveal firmware file")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.goldTxt)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.goldDk))
                }
                .buttonStyle(.plain)
                Text("Contents/Resources/firmware/flash_node.sh")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.dim)
                    .lineLimit(1).truncationMode(.middle)
            }
            step("1", "\(tier.productName) is flashed by running the bundled script in-app. No repo, arduino-cli install, or terminal is required.")
            step("2", "Wi-Fi fields are passed only to this flash run. Enter the password explicitly; Vigil never looks it up automatically.")
            step("3", "Flash with Auto mode, then wait for a live node receipt from /nodes. Streaming CSI to UDP 5005 is visible at http://127.0.0.1:8790/nodes.")
            Divider().overlay(Palette.stroke)
            HStack {
                Field(placeholder: "Wi-Fi SSID (optional)", text: $wifiSSID)
                Spacer()
                if !detectedSerialPorts().isEmpty {
                    Menu {
                        Button("auto") { serialPort = "auto" }
                        // Name the element explicitly: inside `Button(_:action:)` the
                        // trailing closure is the ACTION (zero arguments), so a bare `$0`
                        // there does not resolve to the ForEach element and fails to
                        // typecheck. Binding `port` keeps both uses unambiguous.
                        ForEach(detectedSerialPorts(), id: \.self) { port in
                            Button(port) { serialPort = port }
                        }
                    } label: {
                        Text("Port: \(serialPort)").font(.system(size: 12)).foregroundColor(Palette.goldTxt)
                            .padding(.horizontal, 11).padding(.vertical, 8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.goldDk))
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.plain)
                } else {
                    Field(placeholder: "Serial port", text: $serialPort)
                }
            }
            HStack {
                SecureField("Wi-Fi password", text: $wifiPassword)
                Picker("FQBN", selection: $selectedFQBN) {
                    ForEach(fqbnChoices, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
            }
            HStack {
                Field(placeholder: "Engine IP (optional, leave blank to auto-detect)", text: $macIP)
                Text("Auto detect").font(.system(size: 10)).foregroundColor(Palette.dim).frame(width: 80, alignment: .trailing)
            }
            Divider().overlay(Palette.stroke)
            Text(statusText).font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
            if !runLog.isEmpty { OutputPane(text: runLog).frame(height: 168) }
            if !receiptText.isEmpty {
                Text(receiptText).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isFlashing {
                    ProgressView().controlSize(.small)
                    Text("Flashing…").font(.system(size: 11)).foregroundColor(Palette.dim)
                }
                Spacer()
                GhostButton(title: "Cancel") { dismiss() }
                GoldButton(title: isFlashing ? "Running…" : "Flash this node in app") {
                    guard !isFlashing else { return }
                    Task { await runFlashFlow() }
                }
            }
            if receiptText.isEmpty && !isFlashing {
                Text("No receipt yet. Run flash to start guided hardware validation.").font(.system(size: 10)).foregroundColor(Palette.dim)
            }
        }.padding(22).frame(width: 560).background(Palette.bg)
    }

    private func firmwareScript() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("firmware/flash_node.sh")
    }

    private func revealFirmware() {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("firmware") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func detectedSerialPorts() -> [String] {
        let candidates: [String] = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")
            .filter { s in s.hasPrefix("cu.usbserial") || s.hasPrefix("cu.SLAB_USBtoUART") || s.hasPrefix("cu.wchusbserial") || s.hasPrefix("cu.usbmodem") }
            .sorted()
            .map { "/dev/\($0)" } ) ?? []
        return candidates
    }

    @MainActor
    private func runFlashFlow() async {
        guard !isFlashing else { return }
        guard let script = firmwareScript() else {
            statusText = "Firmware toolchain missing from this Vigil build."
            return
        }
        let ssid = wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = wifiPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let portArg = serialPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "auto" : serialPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let macIPArg = macIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let fqbn = selectedFQBN

        isFlashing = true
        runLog = ""
        statusText = "Running in-app flash flow…"
        receiptText = ""

        let flashResult = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            let process = Process()
            if FileManager.default.isExecutableFile(atPath: script.path) {
                process.executableURL = script
            } else {
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [script.path]
            }
            if process.arguments == nil {
                process.arguments = [portArg, tier.advertised]
            } else {
                process.arguments?.append(contentsOf: [portArg, tier.advertised])
            }

            process.currentDirectoryURL = script.deletingLastPathComponent()
            var env = ProcessInfo.processInfo.environment
            env["HF_SSID"] = ssid
            env["HF_WIFI_PW"] = pass
            if !macIPArg.isEmpty { env["HF_ENGINE_IP"] = macIPArg }
            env["HF_FQBN"] = fqbn
            env["HF_MAC_PORT"] = "5005"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let log = String(decoding: data, as: UTF8.self)
                return (process.terminationStatus, log)
            } catch {
                return (-1, "Error: \(error.localizedDescription)")
            }
        }.value

        isFlashing = false
        let output = flashResult.1
        runLog = output
        if flashResult.0 == 0 && !output.contains("ERROR:") && !output.contains("Error:") {
            statusText = "Flash completed. Waiting for live node receipt from this Mac's Sentinel stream…"
            let receipt = await findReceipt()
            if let receipt {
                receiptText = "Hardware receipt: \(receipt.nodeID) (tier \(tier.advertised)) — \(receipt.frames) live frames."
                statusText = "Done. This node is now showing live CSI to Sentinel."
            } else {
                statusText = "Flash completed, but no live node receipt landed yet. If the board is plugged in, check power/restart and retry."
                receiptText = "No receipt yet."
            }
            return
        }

        if !output.isEmpty { statusText = output }
    }

    private func findReceipt() async -> SentinelNode? {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let node = await MainActor.run(body: {
                let candidates = (engine.sentinel?.nodes ?? [])
                    .filter { $0.real && $0.sensorTier == self.tier && $0.online && $0.frames > 0 }
                return candidates.max { $0.frames < $1.frames }
            }) {
                return node
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    private func step(_ n: String, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(n).font(.system(size: 11, weight: .bold)).foregroundColor(Palette.gold).frame(width: 14)
            Text(t).font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One wired fleet node (engine /frame rooms) — real link state only.
struct FleetNodeRow: View {
    let room: String
    let link: RoomLink
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(link.live ? Color.green : Palette.dim)
                .frame(width: 7, height: 7)
                .shadow(color: link.live ? .green.opacity(0.7) : .clear, radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(room).font(.system(size: 12, weight: .semibold))
                    .foregroundColor(link.live ? .white : Palette.dim)
                Text("node \(link.node_id) · \(link.live ? "\(Int(link.rate_hz ?? 0)) Hz CSI" : "offline")\(link.rssi.map { " · RSSI \($0)" } ?? "")")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(Palette.dim)
            }
            Spacer()
            Text(link.present ? "presence" : (link.live ? "clear" : "—"))
                .font(.system(size: 9, weight: .bold)).tracking(1.2)
                .foregroundColor(link.present ? Palette.gold : Palette.dim)
        }
        .padding(.vertical, 2)
    }
}
#endif // circuit-convert
