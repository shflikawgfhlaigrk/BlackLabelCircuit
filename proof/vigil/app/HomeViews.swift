#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Vigil — smart-home UI surface. Sidebar nav (Home · Rooms · Automations ·
// Security · Sense · Sensors · Activity · Settings). The existing sensing tabs
// fold under "Sense" unchanged. Everything binds to HomeStore (real, persisted)
// and the sensing engine (real presence). Honest empty states throughout — no
// fabricated devices or readings.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif

// MARK: - Root with sidebar

enum HFSection: String, CaseIterable, Identifiable {
    case home = "Home", rooms = "Rooms", automations = "Automations",
         security = "Security", sense = "Sense", cameras = "Watch", sensors = "Sensors", residents = "Residents", energy = "Energy", climate = "Climate",
         activity = "Activity", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: return "house.fill";       case .rooms: return "square.split.2x2.fill"
        case .automations: return "wand.and.stars"; case .security: return "shield.fill"
        case .sense: return "dot.radiowaves.left.and.right"
        case .cameras: return "video.fill"
        case .sensors: return "cpu.fill"
        case .residents: return "person.2.fill"
        case .energy: return "bolt.fill"
        case .climate: return "thermometer.medium"
        case .activity: return "list.bullet.rectangle.fill"; case .settings: return "gearshape.fill"
        }
    }
}

struct AppRootView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var sonar: AcousticSonar
    @EnvironmentObject var store: HomeStore
    @State private var section: HFSection = .home
    /// Shown once on a fresh install so a first-time buyer knows what Vigil is,
    /// that it works on the Mac alone, and where optional nodes fit — instead of
    /// being dropped cold onto the dashboard.
    @AppStorage("vigil.welcomed") private var welcomed = false

    var body: some View {
        VStack(spacing: 0) {
            // Persistence health: a corrupt state on load or a failing save is a
            // caregiver-visible event, never a silent empty home (§5.1).
            if let warning = store.persistenceWarning {
                persistenceBanner(warning)
            }
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Palette.stroke)
                content
            }
        }
        .frame(minWidth: 1060, minHeight: 720)
        .background(Palette.bg.ignoresSafeArea())
        .sheet(isPresented: Binding(get: { !welcomed }, set: { if !$0 { welcomed = true } })) {
            WelcomeSheet(onStart: { welcomed = true },
                         onSetUpNode: { welcomed = true; section = .sensors },
                         onArmWithSonar: {                       // VG-21 one-tap sonar arm
                             welcomed = true
                             sonar.start()                       // start the Mac's own acoustic sonar (auto-calibrates)
                             store.setSecurityMode(.away)        // arm — exit delay covers the walk-out
                             section = .security                 // land on Security to watch the live arm
                         })
        }
        // Presence + minute-tick ingest lives in Engine's poll loop (Engine.ingestFrame /
        // ingestSentinel / minuteTimer), NOT here: Vigil keeps sensing in the menu bar after
        // the window closes, so a view-scoped subscription would silently stop alarm/fall
        // evaluation while the shield still reads "armed". The engine holds the store + sonar
        // refs and drives ingest for the app's lifetime.
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let ns = bundleLogo() {
                    Image(nsImage: ns).resizable().scaledToFill().frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.goldDk, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Vigil").font(.system(size: 15, weight: .bold)).foregroundColor(Palette.gold)
                    Text("Smart home + sensing").font(.system(size: 9)).foregroundColor(Palette.dim)
                }
            }.padding(.bottom, 14).padding(.horizontal, 6)

            ForEach(HFSection.allCases) { s in
                Button { section = s } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.symbol).frame(width: 18).font(.system(size: 13))
                        Text(s.rawValue).font(.system(size: 13, weight: section == s ? .semibold : .regular))
                        Spacer()
                    }
                    .foregroundColor(section == s ? Palette.gold : Palette.dim)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(section == s ? Palette.goldInk : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            Spacer()
            securityBadge
        }
        .padding(12).frame(width: 210)
        .background(Color(red: 0.043, green: 0.043, blue: 0.051))
    }

    private func persistenceBanner(_ warning: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 13)).foregroundColor(.red)
            Text(warning).font(.system(size: 11, weight: .medium)).foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { store.acknowledgePersistenceWarning() } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(Palette.dim)
            }.buttonStyle(.plain).help("Dismiss (a new failure shows this again)")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.red.opacity(0.14))
        .overlay(Rectangle().frame(height: 1).foregroundColor(.red.opacity(0.4)), alignment: .bottom)
    }

    private var securityBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: store.state.securityMode.symbol).foregroundColor(Palette.gold)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.state.securityMode.label).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Text("security").font(.system(size: 9)).foregroundColor(Palette.dim)
            }
            Spacer()
        }
        .padding(10).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(store.state.securityMode.isArmed ? Palette.gold.opacity(0.5) : Palette.stroke))
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .home: DashboardView(go: { section = $0 })
        case .rooms: RoomsView()
        case .automations: AutomationsView()
        case .security: SecurityView()
        case .sense: SenseHubView()
        case .cameras: CamerasView()
        case .sensors: SensorsView()
        case .residents: ResidentsView()
        case .energy: EnergyView()
        case .climate: ClimateView()
        case .activity: ActivityView()
        case .settings: SettingsView()
        }
    }
}

// MARK: - First-run welcome (what is Vigil?)

/// One honest first-launch card. No account wall, no config gate — a buyer can
/// read three sentences and dismiss. States plainly that Vigil works on the Mac
/// alone and that sensor nodes are optional, so the zero-hardware experience is
/// framed, not a mystery. Shown once (@AppStorage "vigil.welcomed").
struct WelcomeSheet: View {
    var onStart: () -> Void
    var onSetUpNode: () -> Void
    var onArmWithSonar: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let ns = bundleLogo() {
                    Image(nsImage: ns).resizable().scaledToFill().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.goldDk, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Vigil").font(.system(size: 20, weight: .bold)).foregroundColor(Palette.gold)
                    Text("A private home-security and room-sensing hub that runs on the Mac you already own.")
                        .font(.system(size: 12)).foregroundColor(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().overlay(Palette.stroke)
            // VG-25 — LEAD with the emotional privacy answer. The reason someone reaches
            // for Vigil over a Ring/Nest is the feeling of a camera watching them in their
            // own home. State the truthful camera-free story first (§5.1): presence AND
            // breathing are sensed with no camera and no image ever formed — while being
            // honest that the camera is an OPTIONAL modality the buyer turns on themselves,
            // and that the accuracy envelope is unchanged.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "eye.slash").font(.system(size: 16)).foregroundColor(Palette.gold).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Presence sensing without a camera").font(.system(size: 14, weight: .bold)).foregroundColor(Palette.gold)
                        Text("If being watched by a camera in your own home makes you uneasy, this is the answer: Vigil senses that someone is present — and even their breathing — with no camera and no image of you ever formed.")
                            .font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("How: the Mac's acoustic sonar and the Vigil nodes run with the camera OFF. The camera turns on only when you enable optional pose or heart-rate sensing — never on its own, and never for basic presence or security.")
                    .font(.system(size: 10)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true).padding(.leading, 34)
                Text("Same honest envelope: camera-free sensing sees motion and breathing in the room, not through walls, can't identify who is there, and a fan or a pet reads as motion.")
                    .font(.system(size: 10)).foregroundColor(Palette.dim.opacity(0.85)).fixedSize(horizontal: false, vertical: true).padding(.leading, 34)
            }
            Divider().overlay(Palette.stroke)
            welcomeRow("checkmark.shield", "Works right now — no hardware needed",
                       "Your Mac's own sensing detects presence and arms Security. Nothing to buy first.")
            welcomeRow("dot.radiowaves.left.and.right", "Add nodes for the full house map",
                       "Optional Vigil sensor nodes (ESP32) unlock the live through-wall map, per-room presence and vitals. Set one up anytime under Sensors.")
            welcomeRow("lock.shield", "Nothing leaves your Mac",
                       "No account, no cloud. Vigil ships empty and fills only with your own home — it never shows invented devices or readings.")
            Divider().overlay(Palette.stroke)
            // VG-21 — sonar-first onboarding. The fastest path to a live, armed home is the
            // Mac's OWN acoustic sonar: one-tap arm, auto-calibrated, in about 30 seconds —
            // no node, no account. The accuracy envelope is stated honestly up front so the
            // buyer knows exactly what sonar can and can't detect (§5.1).
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "dot.radiowaves.up.forward").font(.system(size: 16)).foregroundColor(Palette.gold).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Arm with sonar — a 30-second start").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        Text("One-tap arm: your Mac emits an inaudible 20 kHz tone and listens for the echo, auto-calibrating a baseline of the quiet room over the first ~30 seconds. No hardware, no setup.")
                            .font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("What sonar sees: motion and breathing in THIS room, line-of-sight, out to ~5 m, in the dark. What it can't: it does not see through walls (that needs a Vigil node), can't identify who is there, and a fan or a pet reads as motion — mask those later with an exclusion zone on the map.")
                    .font(.system(size: 10)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 34)
                Button(action: onArmWithSonar) {
                    HStack(spacing: 8) {
                        Image(systemName: "shield.righthalf.filled").font(.system(size: 12))
                        Text("Arm with sonar").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.gold))
                }.buttonStyle(.plain).padding(.leading, 34)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(action: onSetUpNode) {
                    Text("Set up a node").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.goldTxt)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.goldDk))
                }.buttonStyle(.plain)
                Button(action: onStart) {
                    Text("Get started").font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.gold))
                }.buttonStyle(.plain)
            }
        }
        .padding(26).frame(width: 520).background(Palette.bg)
    }
    private func welcomeRow(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(Palette.gold).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Text(text).font(.system(size: 11)).foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

// MARK: - Dashboard (Home)

struct DashboardView: View {
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var sonar: AcousticSonar
    var go: (HFSection) -> Void

    private var present: Bool { (engine.frame?.present ?? false) || sonar.present }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // HERO: the live, self-mapped house — the product. This is what
                // the fleet sees the moment the app opens: rooms mapped from the
                // nodes' own radio survey, who is in which room, vitals, falls.
                VigilHouseView(onConnectNode: { go(.sensors) })
                    .frame(minHeight: 560)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Palette.ink))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.stroke, lineWidth: 1))

                // security mode quick switch
                // VG-25 — the security surface leads with the camera-free privacy story:
                // arming this house watches for presence with no camera and no image formed.
                Card(title: "Security", subtitle: "armed by presence sensing — no extra sensors") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ForEach(SecurityMode.allCases) { m in
                                ModeChip(mode: m, selected: store.state.securityMode == m) { store.setSecurityMode(m) }
                            }
                        }
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "eye.slash").font(.system(size: 10)).foregroundColor(Palette.gold)
                            Text("This armed home is watched with no camera and no image formed — sonar and node sensing detect presence and breathing camera-off. The camera is used only if you turn on optional pose or heart-rate sensing.")
                                .font(.system(size: 10)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // favorites
                if store.state.favorites().isEmpty {
                    EmptyCard(icon: "star", title: "No favorites yet",
                              message: "Mark devices as favorites in Rooms to control them from here.",
                              cta: "Open Rooms") { go(.rooms) }
                } else {
                    Card(title: "Favorites", subtitle: "\(store.state.favorites().count) quick controls") {
                        LazyVGrid(columns: grid, spacing: 12) {
                            ForEach(store.state.favorites()) { d in DeviceTile(device: d) }
                        }
                    }
                }

                // scenes
                if !store.state.scenes.isEmpty {
                    Card(title: "Scenes", subtitle: "one tap, many devices") {
                        HStack(spacing: 10) {
                            ForEach(store.state.scenes) { s in
                                Button { store.runScene(s.id) } label: {
                                    HStack(spacing: 7) { Image(systemName: s.symbol); Text(s.name) }
                                        .font(.system(size: 12, weight: .medium)).foregroundColor(Palette.goldTxt)
                                        .padding(.horizontal, 13).padding(.vertical, 9)
                                        .background(Palette.ink).clipShape(Capsule())
                                        .overlay(Capsule().stroke(Palette.goldDk))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }

                // at-a-glance counts
                HStack(spacing: 12) {
                    GlanceTile(icon: "square.split.2x2.fill", n: store.state.rooms.count, label: "Rooms") { go(.rooms) }
                    GlanceTile(icon: "square.grid.2x2.fill", n: store.state.devices.count, label: "Devices") { go(.rooms) }
                    GlanceTile(icon: "cpu.fill", n: store.state.sensors.count, label: "Sensors") { go(.sensors) }
                    GlanceTile(icon: "wand.and.stars", n: store.state.automations.count, label: "Automations") { go(.automations) }
                }

                Text("Vigil fuses WiFi-CSI, acoustic and camera sensing into whole-home presence, then drives lights, locks, climate and security off it — on hardware you own, fully on-device.")
                    .font(.system(size: 10)).foregroundColor(Palette.dim)
            }.padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).flashyBackground()
    }

    private var grid: [GridItem] { [GridItem(.adaptive(minimum: 150), spacing: 12)] }
    private var presenceDot: some View {
        HStack(spacing: 7) {
            Circle().fill(present ? Color.green : Palette.dim).frame(width: 9, height: 9)
            Text(present ? "LIVE" : "CLEAR").font(.system(size: 10, weight: .bold)).foregroundColor(present ? .green : Palette.dim)
        }.padding(.horizontal, 10).padding(.vertical, 6).background(Palette.panel).clipShape(Capsule())
    }
}

struct GlanceTile: View {
    let icon: String; let n: Int; let label: String; let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon).foregroundColor(Palette.gold).font(.system(size: 16))
                Text("\(n)").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.white)
                Text(label).font(.system(size: 11)).foregroundColor(Palette.dim)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.stroke))
        }.buttonStyle(.plain)
    }
}

struct ModeChip: View {
    let mode: SecurityMode; let selected: Bool; let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) { Image(systemName: mode.symbol); Text(mode.label) }
                .font(.system(size: 12, weight: selected ? .bold : .regular))
                .foregroundColor(selected ? Palette.goldInk : Palette.goldTxt)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(selected ? AnyView(LinearGradient(colors: [Palette.gold, Palette.goldDk], startPoint: .top, endPoint: .bottom)) : AnyView(Palette.ink))
                .clipShape(Capsule()).overlay(Capsule().stroke(Palette.goldDk))
        }.buttonStyle(.plain)
    }
}

struct EmptyCard: View {
    let icon: String; let title: String; let message: String; var cta: String? = nil; var tap: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundColor(Palette.dim)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(Palette.goldTxt)
            Text(message).font(.system(size: 12)).foregroundColor(Palette.dim).multilineTextAlignment(.center)
            if let cta, let tap { GhostButton(title: cta, action: tap).padding(.top, 2) }
        }
        .padding(26).frame(maxWidth: .infinity)
        .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.stroke))
    }
}

// MARK: - Device tile + detail

struct DeviceTile: View {
    @EnvironmentObject var store: HomeStore
    let device: HFDevice
    private var isOn: Bool {
        switch device.kind {
        case .lock: return !(device.state.locked ?? true)   // "active" = unlocked highlight
        case .blind, .garage: return (device.state.openPct ?? 0) > 0.5
        default: return device.state.on ?? false
        }
    }
    @State private var detail = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: 18))
                    .foregroundColor(device.isActuatable && isOn ? Palette.gold : Palette.dim)
                // Honest class badge (VIGIL-3): a simulation or an offline device announces
                // itself on the tile — it can never render indistinguishable from live hardware.
                if device.presence == .simulated || device.presence == .unavailable {
                    Text(device.presence.label.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Palette.ink).foregroundColor(Palette.dim)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Palette.stroke))
                }
                Spacer()
                Button { store.toggleFavorite(device.id) } label: {
                    Image(systemName: device.favorite ? "star.fill" : "star").font(.system(size: 11))
                        .foregroundColor(device.favorite ? Palette.gold : Palette.dim)
                }.buttonStyle(.plain)
            }
            Text(device.name).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
            // Five-way truth label (VIGIL-3): simulated / discovered / connected /
            // unavailable / actively controlled — derived, never stored independently.
            Text("\(stateText) · \(device.presence.label)")
                .font(.system(size: 10)).foregroundColor(Palette.dim).lineLimit(1)
            if device.isActuatable {
                Button { store.primaryToggle(device.id) } label: {
                    Text(actionLabel).font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(isOn ? Palette.goldInk : Palette.ink)
                        .foregroundColor(isOn ? Palette.gold : Palette.goldTxt)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.goldDk.opacity(0.6)))
                }.buttonStyle(.plain)
            } else {
                Text({ () -> String in
                       switch device.presence {
                       case .discovered:  return "Pairing required"
                       case .unavailable: return "Unavailable"
                       default:           return "Read-only"
                       } }())
                    .font(.system(size: 10, weight: .medium)).foregroundColor(Palette.dim)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isOn && device.isActuatable ? Palette.gold.opacity(0.45) : Palette.stroke))
        .onTapGesture(count: 2) { detail = true }
        .contextMenu {
            Button("Details…") { detail = true }
            Button(device.favorite ? "Unfavorite" : "Favorite") { store.toggleFavorite(device.id) }
            Divider()
            Button("Remove", role: .destructive) { store.removeDevice(device.id) }
        }
        .sheet(isPresented: $detail) { DeviceDetailSheet(device: device) }
    }
    private var stateText: String {
        switch device.kind {
        case .lock: return (device.state.locked ?? false) ? "Locked" : "Unlocked"
        case .thermostat:
            if let t = device.state.targetTempF { return "Set \(Int(t))°" }; return "—"
        case .blind, .garage: return (device.state.openPct ?? 0) > 0.5 ? "Open" : "Closed"
        default: return (device.state.on ?? false) ? "On" : "Off"
        }
    }
    private var actionLabel: String {
        switch device.kind {
        case .lock: return (device.state.locked ?? false) ? "Unlock" : "Lock"
        case .blind, .garage: return (device.state.openPct ?? 0) > 0.5 ? "Close" : "Open"
        default: return isOn ? "Turn off" : "Turn on"
        }
    }
}

struct DeviceDetailSheet: View {
    @EnvironmentObject var store: HomeStore
    @Environment(\.dismiss) var dismiss
    let device: HFDevice
    private let noRoomTag = UUID()
    @State private var brightness = 0.5
    @State private var temp = 70.0
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: device.kind.symbol).font(.system(size: 20)).foregroundColor(Palette.gold)
                Text(device.name).font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Palette.dim) }.buttonStyle(.plain)
            }
            Text("\(device.kind.label) · \(store.state.roomName(device.roomID)) · \(device.source.label) · \(device.presence.label)")
                .font(.system(size: 11)).foregroundColor(Palette.dim)
            Divider().overlay(Palette.stroke)

            if device.isActuatable {
                if device.kind == .light {
                    Text("Brightness").font(.system(size: 11)).foregroundColor(Palette.dim)
                    Slider(value: $brightness, in: 0...1) { _ in store.setBrightness(device.id, brightness) }.tint(Palette.gold)
                }
                if device.kind == .thermostat {
                    Text("Target \(Int(temp))°F").font(.system(size: 11)).foregroundColor(Palette.dim)
                    Slider(value: $temp, in: 50...85, step: 1) { _ in store.setTarget(device.id, tempF: temp) }.tint(Palette.gold)
                }
                GoldButton(title: "Toggle") { store.primaryToggle(device.id) }
            } else {
                Text({ () -> String in
                       switch device.presence {
                       case .discovered:
                           return "Vigil sees this device on your network but pairing/commissioning happens in its own app or hub. It's tracked here for status and automations."
                       case .unavailable:
                           return "This device is currently unavailable — Vigil knows it but cannot reach it right now. Its last known state is shown, not a live reading."
                       default:
                           return "This device is read-only — Vigil can show it but not control it."
                       } }())
                    .font(.system(size: 12)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Palette.stroke)
            HStack {
                Picker("Room", selection: Binding(
                    get: { device.roomID ?? noRoomTag },
                    set: { newID in store.assign(device.id, toRoom: newID == noRoomTag ? nil : newID) })) {
                    Text("Unassigned").tag(noRoomTag)
                    ForEach(store.state.rooms) { r in Text(r.name).tag(r.id) }
                }.frame(width: 220)
                Spacer()
                Button("Remove", role: .destructive) { store.removeDevice(device.id); dismiss() }
            }
        }
        .padding(22).frame(width: 420).background(Palette.bg)
        .onAppear { brightness = device.state.brightness ?? 0.5; temp = device.state.targetTempF ?? 70 }
    }
}

// MARK: - Rooms

struct RoomsView: View {
    @EnvironmentObject var store: HomeStore
    @State private var addRoom = false
    @State private var addDevice = false
    @State private var newRoom = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Rooms").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    GhostButton(title: "Add Device…") { addDevice = true }
                    GoldButton(title: "Add Room") { addRoom = true }
                }
                if store.state.rooms.isEmpty && store.state.devices.isEmpty {
                    EmptyCard(icon: "square.split.2x2",
                              title: "No rooms or devices yet",
                              message: "Create a room, then add devices found on your network. Vigil starts empty — it only ever shows your real home.",
                              cta: "Add Room") { addRoom = true }
                }
                ForEach(store.state.rooms) { room in
                    roomSection(room)
                }
                let unassigned = store.state.devices.filter { $0.roomID == nil }
                if !unassigned.isEmpty {
                    Card(title: "Unassigned", subtitle: "\(unassigned.count) devices") {
                        LazyVGrid(columns: grid, spacing: 12) { ForEach(unassigned) { DeviceTile(device: $0) } }
                    }
                }
            }.padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).flashyBackground()
        .sheet(isPresented: $addDevice) { AddDeviceSheet() }
        .alert("New room", isPresented: $addRoom) {
            TextField("Room name", text: $newRoom)
            Button("Add") { if !newRoom.isEmpty { store.addRoom(newRoom); newRoom = "" } }
            Button("Cancel", role: .cancel) { newRoom = "" }
        }
    }
    private var grid: [GridItem] { [GridItem(.adaptive(minimum: 160), spacing: 12)] }
    private func roomSection(_ room: HFRoom) -> some View {
        let devices = store.state.devices(in: room.id)
        return Card(title: room.name, subtitle: devices.isEmpty ? "No devices" : "\(devices.count) devices") {
            if devices.isEmpty {
                Text("Add a device and assign it here.").font(.system(size: 11)).foregroundColor(Palette.dim)
            } else {
                LazyVGrid(columns: grid, spacing: 12) { ForEach(devices) { DeviceTile(device: $0) } }
            }
        }
        .contextMenu { Button("Delete room", role: .destructive) { store.deleteRoom(room.id) } }
    }
}

struct AddDeviceSheet: View {
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var discovery: Discovery
    @Environment(\.dismiss) var dismiss
    @State private var manualName = ""
    @State private var manualKind: DeviceKind = .light
    @State private var manualHost = ""
    @State private var manualDupNote = false
    /// Honest control claim for the manual form: only kinds the local switch
    /// transport can drive get "controllable" wording (§5.1 — the stored control
    /// state comes from the same DeviceControlPolicy, so copy and code agree).
    private var manualControlHint: String {
        if manualHost.isEmpty { return "No control URL → tracked for status only" }
        return DeviceControlPolicy.hasSwitchTransport(manualKind)
            ? "Controllable over local HTTP (WLED / Shelly / Tasmota / Kasa)"
            : "Tracked for status — \(manualKind.label.lowercased()) control needs its own app or hub"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Add a device").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Palette.dim) }.buttonStyle(.plain)
            }
            // discovered
            HStack(spacing: 7) {
                Circle().fill(discovery.scanning ? Color.green : Palette.dim).frame(width: 8, height: 8)
                Text(discovery.scanning ? "Scanning your network…" : "Scan stopped")
                    .font(.system(size: 11)).foregroundColor(Palette.dim)
                Spacer()
                Text("\(discovery.found.count) found").font(.system(size: 11)).foregroundColor(Palette.goldTxt)
            }
            if discovery.found.isEmpty {
                Text("No devices advertised on your LAN yet. Open-API devices (WLED, etc.) and HomeKit/Matter/Cast accessories appear here as they come online. You can also add one manually below.")
                    .font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(discovery.found) { d in
                            let added = store.isDuplicateDevice(Discovery.makeDevice(from: d))
                            HStack(spacing: 10) {
                                Image(systemName: d.kind.symbol).foregroundColor(Palette.gold).frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(d.name).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                                    Text(d.note).font(.system(size: 10)).foregroundColor(Palette.dim)
                                }
                                Spacer()
                                if added {
                                    Label("Added", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 11)).foregroundColor(.green).labelStyle(.titleAndIcon)
                                } else {
                                    GhostButton(title: "Add") { store.addDevice(Discovery.makeDevice(from: d)) }
                                }
                            }
                            .padding(9).background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(maxHeight: 200)
            }
            Divider().overlay(Palette.stroke)
            // manual
            Text("Add manually").font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldTxt)
            HStack {
                Field(placeholder: "Name", text: $manualName)
                Picker("", selection: $manualKind) { ForEach(DeviceKind.allCases) { Text($0.label).tag($0) } }.frame(width: 130)
            }
            Field(placeholder: "Optional local URL (e.g. http://192.168.1.50 for WLED/HTTP)", text: $manualHost)
            HStack {
                Text(manualControlHint)
                    .font(.system(size: 10)).foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                GoldButton(title: "Add device") {
                    guard !manualName.isEmpty else { return }
                    let host = manualHost.isEmpty ? nil : manualHost
                    let added = store.addDevice(HFDevice(
                        name: manualName, kind: manualKind, roomID: nil,
                        source: .manual,
                        control: DeviceControlPolicy.manualControl(kind: manualKind, hasHost: host != nil),
                        host: host, model: "manual"))
                    if added { manualName = ""; manualHost = ""; manualDupNote = false }
                    else { manualDupNote = true }
                }
            }
            if manualDupNote {
                Text("Already tracked — a device with this address exists in Rooms.")
                    .font(.system(size: 10)).foregroundColor(Palette.goldTxt)
            }
            Divider().overlay(Palette.stroke)
            // Simulated home (DOD-4.1/VIGIL-1): a functional local fallback for every
            // hardware class, usable with no hardware. Every device it creates is badged
            // SIMULATED on its tile and in its details — never disguised as hardware.
            Text("No hardware yet?").font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldTxt)
            HStack {
                Text(store.hasSimulatedDevices
                     ? "Simulated devices are active — each is badged SIMULATED."
                     : "Add one simulated device per hardware class to try every control with no hardware.")
                    .font(.system(size: 10)).foregroundColor(Palette.dim)
                Spacer()
                if store.hasSimulatedDevices {
                    GhostButton(title: "Remove simulated") { store.removeSimulatedDevices() }
                } else {
                    GhostButton(title: "Add simulated home") { store.addSimulatedDevices() }
                }
            }
        }
        .padding(22).frame(width: 460).background(Palette.bg)
        .onAppear { discovery.start() }
    }
}

// MARK: - Automations + Scenes

// VG-30 — the template-first starter automation library: a non-technical buyer applies a
// ready-made recipe in one tap (no config language). Recipes come from the pure, tested
// AutomationTemplate.library; applying calls store.applyTemplate (idempotent by name).
struct TemplateLibraryCard: View {
    @EnvironmentObject var store: HomeStore
    var body: some View {
        Card(title: "Starter automations", subtitle: "one-tap recipes — no setup, edit them anytime") {
            VStack(spacing: 8) {
                ForEach(AutomationTemplate.library) { t in
                    let applied = store.isTemplateApplied(t)
                    HStack(spacing: 10) {
                        Image(systemName: icon(t.category)).foregroundColor(Palette.gold).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                            Text(t.detail).font(.system(size: 10)).foregroundColor(Palette.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if applied {
                            Label("Added", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11)).foregroundColor(.green).labelStyle(.titleAndIcon)
                        } else {
                            GhostButton(title: "Apply") { store.applyTemplate(t) }
                        }
                    }.padding(9).background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    private func icon(_ c: AutomationTemplate.Category) -> String {
        switch c {
        case .presence: return "figure.walk"
        case .security: return "shield.fill"
        case .vitals:   return "waveform.path.ecg"
        }
    }
}

struct AutomationsView: View {
    @EnvironmentObject var store: HomeStore
    @State private var newAuto = false
    @State private var newScene = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Automations").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    GhostButton(title: "New Scene") { newScene = true }
                    GoldButton(title: "New Automation") { newAuto = true }
                }
                Card(title: "Scenes", subtitle: "one tap sets many devices") {
                    if store.state.scenes.isEmpty {
                        Text("No scenes yet. A scene captures a set of device states — “Good Night”, “Movie”.")
                            .font(.system(size: 11)).foregroundColor(Palette.dim)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(store.state.scenes) { s in
                                HStack {
                                    Image(systemName: s.symbol).foregroundColor(Palette.gold)
                                    Text(s.name).font(.system(size: 13)).foregroundColor(.white)
                                    Text("\(s.actions.count) devices").font(.system(size: 10)).foregroundColor(Palette.dim)
                                    Spacer()
                                    GhostButton(title: "Run") { store.runScene(s.id) }
                                    Button(role: .destructive) { store.deleteScene(s.id) } label: { Image(systemName: "trash").foregroundColor(Palette.dim) }.buttonStyle(.plain)
                                }.padding(9).background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                TemplateLibraryCard()
                Card(title: "Routines", subtitle: "triggers → actions, driven by presence sensing + time") {
                    if store.state.automations.isEmpty {
                        Text("No automations yet. Tap a starter automation above, or build your own.")
                            .font(.system(size: 11)).foregroundColor(Palette.dim)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(store.state.automations) { a in AutomationRow(auto: a) }
                        }
                    }
                }
            }.padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).flashyBackground()
        .sheet(isPresented: $newAuto) { NewAutomationSheet() }
        .sheet(isPresented: $newScene) { NewSceneSheet() }
    }
}

struct AutomationRow: View {
    @EnvironmentObject var store: HomeStore
    let auto: HFAutomation
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: auto.trigger.kind == .timeOfDay ? "clock.fill" : "sensor.tag.radiowaves.forward.fill")
                .foregroundColor(auto.enabled ? Palette.gold : Palette.dim)
            VStack(alignment: .leading, spacing: 1) {
                Text(auto.name).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                Text(describe(auto)).font(.system(size: 10)).foregroundColor(Palette.dim)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { auto.enabled }, set: { _ in store.toggleAutomation(auto.id) })).labelsHidden().tint(Palette.gold)
            Button(role: .destructive) { store.deleteAutomation(auto.id) } label: { Image(systemName: "trash").foregroundColor(Palette.dim) }.buttonStyle(.plain)
        }.padding(9).background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func describe(_ a: HFAutomation) -> String {
        let trig: String
        let room = a.trigger.roomID == nil ? "any room" : store.state.roomName(a.trigger.roomID)
        func devName(_ id: UUID?) -> String {
            guard let id, let d = store.state.devices.first(where: { $0.id == id }) else { return "any device" }
            return d.name
        }
        switch a.trigger.kind {
        case .presenceEnter: trig = "When \(room) is occupied"
        case .presenceLeave: trig = "When \(room) is empty"
        case .timeOfDay: let m = a.trigger.minuteOfDay ?? 0; trig = String(format: "At %02d:%02d", m/60, m%60)
        case .sunrise: trig = "At sunrise"; case .sunset: trig = "At sunset"
        case .securityMode: trig = "When security → \(a.trigger.mode?.label ?? "any")"
        case .deviceOn: trig = "When \(devName(a.trigger.deviceID)) turns on"
        case .deviceOff: trig = "When \(devName(a.trigger.deviceID)) turns off"
        case .sensorOnline: trig = "When \(a.trigger.tier?.productName ?? "a sensor") comes online"
        case .sensorOffline: trig = "When \(a.trigger.tier?.productName ?? "a sensor") goes offline"
        case .geofenceArrive: trig = "When I arrive home"
        case .geofenceDepart: trig = "When I leave home"
        }
        var cond = ""
        if let c = a.conditions.first {
            switch c.kind {
            case .securityModeIs: cond = " · only when \(c.mode?.label ?? "?")"
            case .presenceIs: cond = c.present == true ? " · only when home" : " · only when empty"
            case .timeWindow:
                let s = c.startMinute ?? 0, e = c.endMinute ?? 0
                cond = String(format: " · only %02d:00–%02d:00", s/60, e/60)
            case .deviceIsOn: cond = " · only if \(devName(c.deviceID)) on"
            }
            if a.conditions.count > 1 { cond += " (+\(a.conditions.count - 1))" }
        }
        return "\(trig)\(cond) → \(a.actions.count) action\(a.actions.count == 1 ? "" : "s")"
    }
}

struct NewSceneSheet: View {
    @EnvironmentObject var store: HomeStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var picked: Set<UUID> = []
    @State private var turnOn = true
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New scene").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
            Field(placeholder: "Scene name (e.g. Good Night)", text: $name)
            Toggle("Set chosen devices ON (off = turn them off)", isOn: $turnOn).tint(Palette.gold).foregroundColor(Palette.goldTxt).font(.system(size: 12))
            Text("Devices in this scene").font(.system(size: 11)).foregroundColor(Palette.dim)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.state.devices) { d in
                        Button { if picked.contains(d.id) { picked.remove(d.id) } else { picked.insert(d.id) } } label: {
                            HStack {
                                Image(systemName: picked.contains(d.id) ? "checkmark.circle.fill" : "circle").foregroundColor(picked.contains(d.id) ? Palette.gold : Palette.dim)
                                Text(d.name).font(.system(size: 12)).foregroundColor(.white); Spacer()
                            }.padding(8).background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                    if store.state.devices.isEmpty { Text("Add devices first.").font(.system(size: 11)).foregroundColor(Palette.dim) }
                }
            }.frame(maxHeight: 220)
            HStack {
                Spacer()
                GhostButton(title: "Cancel") { dismiss() }
                GoldButton(title: "Create") {
                    guard !name.isEmpty else { return }
                    let acts = picked.map { SceneAction(deviceID: $0, state: DeviceState(on: turnOn)) }
                    store.addScene(HFScene(name: name, actions: acts)); dismiss()
                }
            }
        }.padding(22).frame(width: 440).background(Palette.bg)
    }
}

struct NewAutomationSheet: View {
    @EnvironmentObject var store: HomeStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var triggerKind: TriggerKind = .presenceEnter
    @State private var room: UUID? = nil
    @State private var hour = 23
    @State private var minute = 0
    @State private var device: UUID? = nil
    @State private var tier: SensorTier = .node
    @State private var actionKind: ActionKind = .runScene
    @State private var scene: UUID? = nil
    @State private var mode: SecurityMode = .away
    // Optional "only when" condition (the triggers → CONDITIONS → actions spine).
    @State private var condEnabled = false
    @State private var condKind: ConditionKind = .securityModeIs
    @State private var condMode: SecurityMode = .away
    @State private var condPresent = false
    @State private var condStartHour = 22
    @State private var condEndHour = 6
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New automation").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
            Field(placeholder: "Name", text: $name)
            Text("WHEN").font(.system(size: 10, weight: .bold)).foregroundColor(Palette.dim)
            Picker("", selection: $triggerKind) { ForEach(TriggerKind.allCases) { Text($0.label).tag($0) } }.labelsHidden()
            if triggerKind == .presenceEnter || triggerKind == .presenceLeave {
                Picker("Room", selection: Binding(get: { room ?? noRoom }, set: { room = $0 == noRoom ? nil : $0 })) {
                    Text("Any room").tag(noRoom)
                    ForEach(store.state.rooms) { r in Text(r.name).tag(r.id) }
                }
            }
            if triggerKind == .timeOfDay {
                HStack {
                    Stepper("Hour \(hour)", value: $hour, in: 0...23)
                    Stepper("Min \(minute)", value: $minute, in: 0...59, step: 5)
                }.foregroundColor(Palette.goldTxt).font(.system(size: 12))
            }
            if triggerKind == .deviceOn || triggerKind == .deviceOff {
                Picker("Device", selection: Binding(get: { device ?? noRoom }, set: { device = $0 == noRoom ? nil : $0 })) {
                    Text("Any device").tag(noRoom)
                    ForEach(store.state.devices) { d in Text(d.name).tag(d.id) }
                }
            }
            if triggerKind == .sensorOnline || triggerKind == .sensorOffline {
                Picker("Tier", selection: $tier) { ForEach(SensorTier.allCases) { Text($0.productName).tag($0) } }
            }
            if triggerKind == .geofenceArrive || triggerKind == .geofenceDepart {
                VStack(alignment: .leading, spacing: 6) {
                    // Honest permission + region state — never a fabricated "monitoring" (§5.1).
                    Text(store.geofenceAuth.cardLabel)
                        .font(.system(size: 11)).foregroundColor(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(store.state.geofence.statusLabel)
                        .font(.system(size: 11)).foregroundColor(Palette.goldTxt)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if store.geofenceAuth.canRequestInApp {
                            GhostButton(title: "Grant location access") { store.requestGeofenceAccess() }
                        }
                        if store.geofenceAuth == .denied || store.geofenceAuth == .restricted {
                            // Once denied/restricted the OS won't re-prompt — deep-link the
                            // exact pane instead of a dead "Grant" button (DOD-3.3).
                            GhostButton(title: "Open System Settings") {
                                NSWorkspace.shared.open(SystemSettingsPane.locationServices.url)
                            }
                        }
                        if store.geofenceAuth.monitoringEligible {
                            GhostButton(title: "Set home to here") { store.setHomeRegionToCurrentLocation() }
                        }
                        if store.state.geofence.isConfigured {
                            GhostButton(title: "Clear region") { store.clearHomeRegion() }
                        }
                    }
                }
                .padding(10)
                .background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.stroke))
            }

            // OPTIONAL condition gate — narrows the trigger ("only when armed Away").
            Toggle(isOn: $condEnabled) {
                Text("ONLY WHEN…").font(.system(size: 10, weight: .bold)).foregroundColor(Palette.dim)
            }.toggleStyle(.switch).tint(Palette.gold)
            if condEnabled {
                Picker("", selection: $condKind) { ForEach(ConditionKind.allCases) { Text($0.label).tag($0) } }.labelsHidden()
                if condKind == .securityModeIs {
                    Picker("Mode", selection: $condMode) { ForEach(SecurityMode.allCases) { Text($0.label).tag($0) } }
                }
                if condKind == .presenceIs {
                    Picker("", selection: $condPresent) { Text("Someone is home").tag(true); Text("Home is empty").tag(false) }.labelsHidden()
                }
                if condKind == .timeWindow {
                    HStack {
                        Stepper("From \(condStartHour):00", value: $condStartHour, in: 0...23)
                        Stepper("To \(condEndHour):00", value: $condEndHour, in: 0...23)
                    }.foregroundColor(Palette.goldTxt).font(.system(size: 12))
                }
                if condKind == .deviceIsOn {
                    Picker("Device", selection: Binding(get: { device ?? noRoom }, set: { device = $0 == noRoom ? nil : $0 })) {
                        Text("—").tag(noRoom)
                        ForEach(store.state.devices) { d in Text(d.name).tag(d.id) }
                    }
                }
            }
            Divider().overlay(Palette.stroke)
            Text("DO").font(.system(size: 10, weight: .bold)).foregroundColor(Palette.dim)
            Picker("", selection: $actionKind) {
                Text("Run a scene").tag(ActionKind.runScene)
                Text("Set security mode").tag(ActionKind.setSecurityMode)
                Text("Notify me").tag(ActionKind.notify)
            }.labelsHidden()
            if actionKind == .runScene {
                Picker("Scene", selection: Binding(get: { scene ?? noRoom }, set: { scene = $0 })) {
                    Text("—").tag(noRoom); ForEach(store.state.scenes) { s in Text(s.name).tag(s.id) }
                }
            }
            if actionKind == .setSecurityMode {
                Picker("Mode", selection: $mode) { ForEach(SecurityMode.allCases) { Text($0.label).tag($0) } }
            }
            HStack {
                Spacer(); GhostButton(title: "Cancel") { dismiss() }
                GoldButton(title: "Create") { create() }
            }
        }.padding(22).frame(width: 440).background(Palette.bg)
    }
    private let noRoom = UUID()
    private func create() {
        guard !name.isEmpty else { return }
        var t = Trigger(kind: triggerKind)
        switch triggerKind {
        case .presenceEnter, .presenceLeave: t.roomID = room
        case .timeOfDay: t.minuteOfDay = hour*60 + minute
        case .deviceOn, .deviceOff: t.deviceID = device
        case .sensorOnline, .sensorOffline: t.tier = tier
        default: break
        }
        var conditions: [Condition] = []
        if condEnabled {
            var c = Condition(kind: condKind)
            switch condKind {
            case .securityModeIs: c.mode = condMode
            case .presenceIs: c.present = condPresent
            case .timeWindow: c.startMinute = condStartHour*60; c.endMinute = condEndHour*60
            case .deviceIsOn: c.deviceID = (device == noRoom ? nil : device)
            }
            conditions.append(c)
        }
        var a = HomeAction(kind: actionKind)
        switch actionKind {
        case .runScene: a.sceneID = (scene == noRoom ? nil : scene)
        case .setSecurityMode: a.mode = mode
        case .notify: a.message = "\(name) fired"
        default: break
        }
        store.addAutomation(HFAutomation(name: name, trigger: t, conditions: conditions, actions: [a])); dismiss()
    }
}

// MARK: - Security

struct SecurityView: View {
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var sonar: AcousticSonar
    @State private var showAwaySetup = false      // VG-12 guided phone-alerts wizard
    private var present: Bool { (engine.frame?.present ?? false) || sonar.present }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Security").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                Card(title: "Mode", subtitle: "armed modes treat sensed presence as an intrusion") {
                    HStack(spacing: 10) {
                        ForEach(SecurityMode.allCases) { m in
                            ModeChip(mode: m, selected: store.state.securityMode == m) { store.setSecurityMode(m) }
                        }
                    }
                    alarmPhaseBanner
                }
                Card(title: "Live status", subtitle: "from your sensing layer") {
                    HStack(spacing: 16) {
                        statusBlock(icon: present ? "figure.walk" : "house",
                                    title: present ? "Presence detected" : "All clear",
                                    color: present ? (store.state.securityMode.isArmed ? .red : Palette.gold) : Palette.dim)
                        statusBlock(icon: store.state.securityMode.symbol, title: store.state.securityMode.label, color: Palette.gold)
                        let sentries = store.state.sensors.filter { $0.tier == .sentry && $0.online }.count
                        statusBlock(icon: "shield.lefthalf.filled", title: "\(sentries) Sentry online", color: sentries > 0 ? Palette.gold : Palette.dim)
                    }
                    if case .alarm = store.alarmPhase {
                        Text("⚠︎ Presence while armed \(store.state.securityMode.label) — logged to Activity.")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.red).padding(.top, 6)
                    }
                }
                // First-class Away Alerts — the self-monitored off-device alerting story
                // (relay + real test POST + honest disclaimer). Closes the #1 buyer
                // objection: "what reaches me when I'm not home?"
                AwayAlertsCard()
                // VG-12 — guided "Away Alerts to your phone" setup: pick a provider
                // (ntfy / Pushover / Apple Shortcuts phone webhook), validate the endpoint,
                // fire a real test, read honest delivery status. Productizes the relay path.
                Button { showAwaySetup = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 13)).foregroundColor(.black)
                        Text(store.state.relay.isConfigured ? "Away Alerts on your phone — review setup" : "Set up Away Alerts on your phone")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.black)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.gold))
                }.buttonStyle(.plain)
                // VG-27 — elder/solo monitor mode: fused breathing+HR+presence, 20s debounce,
                // pages a designated contact via the same Away Alerts relay. Not a medical device.
                MonitorModeCard()
                // VG-13 — local siren: on an intrusion alarm Vigil drives a favorited
                // controllable device (light/plug/speaker) as a deterrent. Honest "none"
                // when nothing controllable is favorited; never claims a siren that didn't fire.
                sirenCard
                Card(title: "Through-wall security", subtitle: "early access — ships with the Sentry hardware") {
                    Text("With a Vigil Sentry placed in a room, CSI presence in an empty, dark house triggers an alert — no camera, no line of sight. Arm to Away and the sensing layer becomes a perimeter you can't see but it can. Early access: this goes live when a Sentry node streams — today's mic + camera sensing on this Mac already feeds the armed modes.")
                        .font(.system(size: 12)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                }
                let alerts = store.state.activity.filter { $0.kind.isCritical }.prefix(8)
                Card(title: "Recent alerts", subtitle: alerts.isEmpty ? "none" : "\(alerts.count)") {
                    if alerts.isEmpty { Text("No alerts.").font(.system(size: 11)).foregroundColor(Palette.dim) }
                    else { ForEach(Array(alerts)) { ActivityRow(event: $0) } }
                }
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).flashyBackground()
        .sheet(isPresented: $showAwaySetup) {
            AwayAlertsSetupSheet(onClose: { showAwaySetup = false }).environmentObject(store)
        }
    }
    private func statusBlock(icon: String, title: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 22)).foregroundColor(color)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(.white).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 8).background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 9))
    }

    /// VG-13 — the local-siren card. Shows which controllable device Vigil will drive on an
    /// alarm (or the honest "no siren device connected" when none is favorited/controllable).
    /// Vigil owns no siren hardware — it reuses a device the buyer already controls (§5.5).
    private var sirenCard: some View {
        let siren = SirenSelector.pick(from: store.state.devices)
        return Card(title: "Local siren", subtitle: "drive a device you own when the alarm fires") {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: siren != nil ? "speaker.wave.3.fill" : "speaker.slash.fill")
                    .font(.system(size: 13)).foregroundColor(siren != nil ? Palette.gold : Palette.dim)
                Text(SirenSelector.statusLabel(for: siren))
                    .font(.system(size: 11)).foregroundColor(siren != nil ? Palette.goldTxt : Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
            }
            Text("On an intrusion alarm Vigil turns the favorited device on and logs the real result to Activity — it never reports a siren that the device didn’t actually acknowledge.")
                .font(.system(size: 10)).foregroundColor(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The exit-grace / entry-delay countdown (SecurityModel.phase). A trustworthy
    /// alarm tells you what it is about to do: arming shows the time you have to
    /// leave; presence-while-armed shows the disarm window before the alarm sounds.
    /// Quiet renders nothing — no fake "all systems nominal" chrome.
    @ViewBuilder private var alarmPhaseBanner: some View {
        switch store.alarmPhase {
        case .quiet:
            EmptyView()
        case .exitGrace(let until):
            phaseRow(icon: "figure.walk.departure", tint: Palette.gold,
                     label: "Exit delay — arms in", deadline: until)
        case .entryPending(let until):
            phaseRow(icon: "exclamationmark.shield.fill", tint: .orange,
                     label: "Presence detected — disarm within", deadline: until)
        case .alarm:
            HStack(spacing: 8) {
                Image(systemName: "bell.and.waves.left.and.right.fill").font(.system(size: 13)).foregroundColor(.red)
                Text("INTRUSION — presence while armed \(store.state.securityMode.label)")
                    .font(.system(size: 12, weight: .bold)).foregroundColor(.red)
                Spacer()
            }.padding(.top, 8)
        }
    }

    private func phaseRow(icon: String, tint: Color, label: String, deadline: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).foregroundColor(tint)
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(tint)
            Text(deadline, style: .timer)
                .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(tint)
            Spacer()
        }.padding(.top, 8)
    }
}

// VG-12 — guided "Away Alerts to your phone" setup. Productizes the EXISTING buyer-owned
// relay (RemoteRelayConfig / store.setRelayWebhook / store.sendTestAlert) into a one-screen
// wizard: pick a provider, get provider-specific guidance, paste + VALIDATE the endpoint,
// fire a REAL test POST, and read HONEST delivery status. Native APNs is a separate ASC lane
// (~/HomefrontGuardian) — this ships today over any webhook the buyer controls. Honesty
// (§5.1/§5.2): endpoint is validated (a bad URL is rejected, not silently kept); the test is
// a real POST with a real outcome; status says "posted to your endpoint", NEVER "delivered to
// your phone" — Vigil confirms the POST left the box, not that a handset rang.
struct AwayAlertsSetupSheet: View {
    @EnvironmentObject var store: HomeStore
    var onClose: () -> Void

    enum Provider: String, CaseIterable, Identifiable {
        case ntfy, pushover, shortcuts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ntfy: return "ntfy"
            case .pushover: return "Pushover"
            case .shortcuts: return "Shortcuts"
            }
        }
        var placeholder: String {
            switch self {
            case .ntfy: return "https://ntfy.sh/your-private-topic"
            case .pushover: return "https://your-bridge.example/pushover"
            case .shortcuts: return "https://your-phone-webhook.example/hook"
            }
        }
        var guidance: String {
            switch self {
            case .ntfy:
                return "Free and direct. Install the ntfy app, subscribe to a private topic, and paste that topic's URL. Vigil POSTs the alert straight to it and it arrives as a push on your phone."
            case .pushover:
                return "Pushover's API needs a token + user, not a plain webhook, so point Vigil at a webhook bridge (Make / Zapier / n8n) that forwards Vigil's POST to Pushover. Vigil confirms it reached the bridge — the bridge delivers to your phone."
            case .shortcuts:
                return "Use an Apple Shortcuts phone webhook: a shortcut (or any URL your phone can receive) that takes Vigil's POST and shows a notification. Paste that phone webhook URL below."
            }
        }
    }

    @State private var provider: Provider = .ntfy
    @State private var draft: String = ""
    @State private var invalid = false

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 18)).foregroundColor(Palette.gold)
                Text("Away Alerts to your phone").font(.system(size: 18, weight: .bold)).foregroundColor(Palette.gold)
                Spacer()
            }
            Text(AwayAlerts.selfMonitoredDisclaimer)
                .font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Palette.stroke)

            Text("1 · Pick how alerts reach your phone").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            Picker("", selection: $provider) {
                ForEach(Provider.allCases) { p in Text(p.title).tag(p) }
            }.pickerStyle(.segmented).labelsHidden()
            Text(provider.guidance)
                .font(.system(size: 11)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)

            Text("2 · Paste your endpoint").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            TextField(provider.placeholder, text: $draft)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            if invalid {
                Text("That isn't a valid http(s) URL — not saved.").font(.system(size: 10)).foregroundColor(.red)
            }
            HStack(spacing: 8) {
                GhostButton(title: "Save endpoint") {
                    if store.setRelayWebhook(draft) { invalid = false } else { invalid = true }
                }
                if store.state.relay.isConfigured {
                    GhostButton(title: "Remove") { store.clearRelayWebhook(); draft = ""; invalid = false }
                }
                Spacer()
            }
            Text(store.state.relay.statusLabel).font(.system(size: 10)).foregroundColor(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            if store.state.relay.isConfigured {
                Divider().overlay(Palette.stroke)
                Text("3 · Prove it reaches you").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                HStack(spacing: 8) {
                    if store.testAlertInFlight {
                        ProgressView().controlSize(.small)
                        Text("Posting a test alert to your endpoint…").font(.system(size: 11)).foregroundColor(Palette.goldTxt)
                    } else {
                        GhostButton(title: "Send test alert") { store.sendTestAlert() }
                        Text("Fires a real, clearly-labelled TEST POST to your endpoint.")
                            .font(.system(size: 10)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                if let health = RelayHealth.forCard(isConfigured: store.state.relay.isConfigured,
                                                    last: store.state.relay.lastDelivery) {
                    Text(health.text(clock: health.at.map(Self.clock) ?? ""))
                        .font(.system(size: 10))
                        .foregroundColor(health.ok ? .green : (health == .noneSent ? Palette.dim : .red))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Status reflects the POST reaching your endpoint — not that your phone rang. Vigil can't see your handset (§5.1).")
                    .font(.system(size: 9)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(action: onClose) {
                    Text("Done").font(.system(size: 12, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.gold))
                }.buttonStyle(.plain)
            }
        }
        .padding(24).frame(width: 480).background(Palette.bg)
        .onAppear { draft = store.state.relay.webhook }
    }
}

// MARK: - Activity

struct ActivityRow: View {
    let event: ActivityEvent
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.kind.symbol).foregroundColor(event.kind.isCritical ? .red : Palette.gold).frame(width: 18).font(.system(size: 12))
            Text(event.message).font(.system(size: 12)).foregroundColor(.white).lineLimit(2)
            Spacer()
            Text(event.at, style: .time).font(.system(size: 10)).foregroundColor(Palette.dim)
        }.padding(.vertical, 5)
    }
}

struct ActivityView: View {
    @EnvironmentObject var store: HomeStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Activity").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                Card(title: "Energy", subtitle: "from devices that report power") {
                    // Real current draw from the latest energy scan sample (device.state.watts was
                    // never populated — the live total lives in energyHistory, written by recordEnergy).
                    // "now" only through the SAME freshness gate the menu bar uses — a sample from a
                    // scan days ago is shown with its timestamp, never as current (§5.1).
                    if let fresh = MenuBarModel.nowDrawingWatts(history: store.state.energyHistory, now: Date()), fresh > 0 {
                        Text("\(Int(fresh)) W now").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(Palette.gold)
                    } else if let last = store.state.energyHistory.last, last.watts > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(Int(last.watts)) W").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(Palette.gold)
                            (Text("measured ") + Text(last.ts, style: .relative) + Text(" ago — open Energy and scan for a fresh reading"))
                                .font(.system(size: 10)).foregroundColor(Palette.dim)
                        }
                    } else {
                        Text("No energy-reporting devices yet. Add a smart plug that exposes wattage and it shows here — real numbers only.")
                            .font(.system(size: 11)).foregroundColor(Palette.dim)
                    }
                }

                // VG-28: last night rolled into an honest story from REAL events only.
                NightlyDigestCard(events: store.state.activity)

                // VG-29 + VG-31: a thumb-scrubbable timeline of fused events, each showing
                // its source modality + recorded confidence, with real gaps drawn as gaps.
                Card(title: "Fused timeline",
                     subtitle: store.state.activity.isEmpty ? "nothing yet" : "\(store.state.activity.count) events — scrub to inspect") {
                    if store.state.activity.isEmpty {
                        Text("Device changes, presence, scenes and security events appear here — with the sensing modality and confidence that produced each one.")
                            .font(.system(size: 11)).foregroundColor(Palette.dim)
                    } else {
                        EventTimeline(events: Array(store.state.activity.prefix(200)))
                    }
                }
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).flashyBackground()
    }
}

/// VG-28 — the nightly household digest. Rolls the REAL activity log for the most recent
/// overnight window into a short story ("6:40 AM motion", with quiet spans shown as
/// explicit "no data recorded" gaps). Never synthesizes a night: an empty window shows an
/// honest empty state, and gap segments are drawn as gaps, never as a fabricated "all quiet".
struct NightlyDigestCard: View {
    let events: [ActivityEvent]
    private var digest: NightDigest {
        NightDigestBuilder.build(events: events,
                                 window: NightDigestBuilder.window(endingOn: Date()))
    }
    var body: some View {
        let d = digest
        Card(title: "Nightly summary", subtitle: windowLabel(d.night)) {
            if d.isEmpty {
                Text(d.headline + " Sensing writes real events here; nothing about the night is assumed.")
                    .font(.system(size: 11)).foregroundColor(Palette.dim)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(d.headline).font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.goldTxt)
                    ForEach(d.segments) { seg in
                        HStack(alignment: .top, spacing: 8) {
                            Text(spanLabel(seg))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(Palette.dim).frame(width: 92, alignment: .leading)
                            if seg.kind == .gap {
                                Text("— no data recorded")
                                    .font(.system(size: 11)).foregroundColor(Palette.dim.opacity(0.75)).italic()
                            } else {
                                Text(seg.summary)
                                    .font(.system(size: 11)).foregroundColor(.white)
                            }
                        }
                    }
                }
            }
        }
    }
    private func windowLabel(_ i: DateInterval) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return "overnight · \(f.string(from: i.start)) → \(f.string(from: i.end))"
    }
    private func spanLabel(_ s: NightDigestSegment) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return "\(f.string(from: s.start))–\(f.string(from: s.end))"
    }
}

/// VG-29 / VG-31 — a thumb-scrubbable timeline of fused events. The slider thumb scrubs
/// across events in time order; the selected event shows its source modality and the
/// confidence that was actually recorded (or "—" when none was, never a fabricated number).
/// Real time gaps between consecutive events are drawn as explicit gap bands.
struct EventTimeline: View {
    let events: [ActivityEvent]
    @State private var pos: Double = 0

    /// Chronological (oldest→newest) so scrubbing left→right walks time forward.
    private var ordered: [ActivityEvent] { events.sorted { $0.at < $1.at } }
    private var idx: Int { min(max(Int(pos.rounded()), 0), max(ordered.count - 1, 0)) }
    /// A "gap" precedes the selected event when >30 min passed since the previous one.
    private var precedingGap: TimeInterval? {
        guard idx > 0 else { return nil }
        let dt = ordered[idx].at.timeIntervalSince(ordered[idx - 1].at)
        return dt > 1800 ? dt : nil
    }

    var body: some View {
        let evs = ordered
        let sel = evs[idx]
        VStack(alignment: .leading, spacing: 10) {
            // Scrub track with per-event ticks (critical events flagged red).
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.ink).frame(height: 4)
                    ForEach(Array(evs.enumerated()), id: \.element.id) { i, e in
                        Circle()
                            .fill(e.kind.isCritical ? Color.red : Palette.gold.opacity(i == idx ? 1 : 0.5))
                            .frame(width: i == idx ? 9 : 5, height: i == idx ? 9 : 5)
                            .offset(x: evs.count <= 1 ? 0 : (w - 9) * CGFloat(i) / CGFloat(evs.count - 1))
                    }
                }.frame(height: 12)
            }.frame(height: 12)

            // The thumb-scrubbable control.
            Slider(value: $pos, in: 0...Double(max(evs.count - 1, 1)), step: 1)
                .tint(Palette.gold)

            if let gap = precedingGap {
                Text("↳ gap · no recorded events for \(Self.humanGap(gap)) before this")
                    .font(.system(size: 10)).foregroundColor(Palette.dim.opacity(0.8)).italic()
            }

            // The selected fused event: modality + real confidence (VG-31).
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: sel.kind.symbol)
                        .foregroundColor(sel.kind.isCritical ? .red : Palette.gold)
                        .font(.system(size: 13)).frame(width: 18)
                    Text(sel.message).font(.system(size: 13, weight: .medium)).foregroundColor(.white).lineLimit(2)
                    Spacer()
                    Text(sel.at, style: .time).font(.system(size: 10)).foregroundColor(Palette.dim)
                }
                HStack(spacing: 12) {
                    Label(sel.kind.modalityLabel, systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 10)).foregroundColor(Palette.dim)
                    Text("confidence \(sel.confidenceLabel)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(sel.recordedConfidence == nil ? Palette.dim : Palette.goldTxt)
                }
                Text("event \(idx + 1) of \(evs.count)").font(.system(size: 9)).foregroundColor(Palette.dim.opacity(0.7))
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private static func humanGap(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(m) min" }
        let h = m / 60, rem = m % 60
        return rem == 0 ? "\(h)h" : "\(h)h \(rem)m"
    }
}

// MARK: - Residents (eldercare — the people under care)

/// The per-resident eldercare config surface. The attribution MODEL + poller shipped
/// already (256e0d4 / f382daf) but had NO SwiftUI surface, so on a buyer box `residents`
/// stayed empty and every fall/anomaly logged unattributed — the moat was invisible.
/// This makes the mutators reachable: add/assign/remove residents so soleResident() /
/// resident(inRoom:) can actually fire. Ships empty + honest (§5.2) — never a fabricated
/// roster, never a guessed occupant.
struct ResidentsView: View {
    @EnvironmentObject var store: HomeStore
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Residents").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                Text("People under care in this home. A fall or anomaly sensed for a resident is attributed to them, so a caregiver alert can say who and where. Add residents to enable per-person attribution — nothing is assumed about who lives here.")
                    .font(.system(size: 12)).foregroundColor(Palette.dim).fixedSize(horizontal: false, vertical: true)

                Card(title: "Add a resident", subtitle: "name only — assign a room below") {
                    HStack(spacing: 10) {
                        Field(placeholder: "Resident name (e.g. Ada)", text: $newName)
                        GoldButton(title: "Add") {
                            let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !n.isEmpty else { return }
                            store.addResident(n); newName = ""
                        }
                    }
                }

                if store.state.residents.isEmpty {
                    EmptyCard(icon: "person.2",
                              title: "No residents yet",
                              message: "Add a resident to enable per-person fall and anomaly attribution. With exactly one resident every alert is attributed to them; with several, an alert is attributed only when the sensed room identifies who — never guessed.")
                } else {
                    Card(title: "Residents", subtitle: residentsSubtitle) {
                        VStack(spacing: 8) { ForEach(store.state.residents) { ResidentRow(resident: $0) } }
                    }
                }
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).flashyBackground()
    }

    private var residentsSubtitle: String {
        let c = store.state.residents.count
        if c == 1 { return "1 — every alert attributes to them" }
        return "\(c) — alerts attribute only when the room identifies who"
    }
}

struct ResidentRow: View {
    @EnvironmentObject var store: HomeStore
    let resident: Resident
    private let noRoom = UUID()
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill").foregroundColor(Palette.gold).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(resident.name).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                Text(store.state.roomName(resident.roomID)).font(.system(size: 10)).foregroundColor(Palette.dim)
            }
            Spacer()
            Picker("", selection: Binding(get: { resident.roomID ?? noRoom }, set: { assign($0) })) {
                Text("Unassigned").tag(noRoom)
                ForEach(store.state.rooms) { r in Text(r.name).tag(r.id) }
            }.labelsHidden().frame(width: 150)
            Button(role: .destructive) { store.removeResident(resident.id) } label: {
                Image(systemName: "trash").foregroundColor(Palette.dim)
            }.buttonStyle(.plain)
        }.padding(9).background(Palette.ink).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func assign(_ id: UUID) {
        store.assignResident(resident.id, toRoom: id == noRoom ? nil : id)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: HomeStore
    @EnvironmentObject var engine: Engine
    @State private var backupStatus: String? = nil
    @State private var backupError: String? = nil
    @State private var updateStatus: String? = nil
    @State private var checkingUpdates = false
    @State private var updateOffersDownload = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                Card(title: "Notifications", subtitle: "security + automation alerts") {
                    VStack(alignment: .leading, spacing: 8) {
                        // Honest permission state + a LIVE affordance for it: once denied the
                        // OS never re-prompts, so "Enable" would be a dead button (§5.8) — the
                        // deep link into the exact Settings pane is the real action (DOD-3.3).
                        Text(store.notifAuth.cardLabel)
                            .font(.system(size: 11)).foregroundColor(Palette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        if store.notifAuth.canEnableInApp {
                            GhostButton(title: "Enable notifications") { store.requestNotifications() }
                        } else if store.notifAuth == .denied {
                            GhostButton(title: "Open System Settings") {
                                NSWorkspace.shared.open(SystemSettingsPane.notifications.url)
                            }
                        }
                    }
                }
                Card(title: "Sensing engine", subtitle: "on-device sidecar") {
                    HStack(spacing: 8) {
                        Circle().fill(engine.connected ? Color.green : Palette.dim).frame(width: 8, height: 8)
                        Text(engine.statusLine).font(.system(size: 11)).foregroundColor(Palette.dim)
                    }
                }
                Card(title: "Your home, your data", subtitle: "local-first, no cloud") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Everything Vigil knows lives on this Mac. Export a backup of your rooms, devices, scenes, automations, residents and alert history, or restore a validated backup onto this Mac.")
                            .font(.system(size: 11)).foregroundColor(Palette.dim)
                        HStack(spacing: 8) {
                            GhostButton(title: "Export config…") { exportConfig() }
                            GhostButton(title: "Import config…") { importConfig() }
                        }
                        if let backupStatus {
                            Text(backupStatus).font(.system(size: 10)).foregroundColor(Palette.goldTxt)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let backupError {
                            Text(backupError).font(.system(size: 10)).foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Card(title: "Support", subtitle: "diagnostics you can read before sharing") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Save a plain-text report of app + sensing-engine status and recent engine log excerpts. It contains no credentials or keys, and the home model appears as counts only — review it before sharing.")
                            .font(.system(size: 11)).foregroundColor(Palette.dim)
                        GhostButton(title: "Export diagnostics…") { exportDiagnostics() }
                    }
                }
                Card(title: "Updates", subtitle: "check for a newer build") {
                    VStack(alignment: .leading, spacing: 8) {
                        // DOD-9.5 (mechanism half): compare the published manifest build
                        // against THIS build. Honest states all the way down: a stale or
                        // missing manifest is said plainly and never offers a downgrade;
                        // an unreachable service is never claimed as "up to date".
                        Text("Vigil checks the update service and compares the published build against this one. Nothing downloads automatically — updates install through your account on the download page.")
                            .font(.system(size: 11)).foregroundColor(Palette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            GhostButton(title: checkingUpdates ? "Checking…" : "Check for updates") { checkForUpdates() }
                            if updateOffersDownload {
                                GhostButton(title: "Open download page") {
                                    NSWorkspace.shared.open(UpdaterModel.downloadPageURL)
                                }
                            }
                        }
                        if let updateStatus {
                            Text(updateStatus).font(.system(size: 10)).foregroundColor(Palette.goldTxt)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Card(title: "Guides", subtitle: "help that ships inside the app") {
                    VStack(alignment: .leading, spacing: 8) {
                        if availableGuides.isEmpty {
                            // Honest empty state — never a dead button (§5.8): this build was
                            // assembled before guides were bundled into Resources/guides.
                            Text("This build doesn't include the bundled guides yet — they ship inside the app from the next build. Nothing else is affected.")
                                .font(.system(size: 11)).foregroundColor(Palette.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Open a guide (plain-text, opens in your default text app):")
                                .font(.system(size: 11)).foregroundColor(Palette.dim)
                            ForEach(availableGuides, id: \.file) { guide in
                                GhostButton(title: guide.title) {
                                    NSWorkspace.shared.open(guide.url)
                                }
                            }
                        }
                    }
                }
                Card(title: "About", subtitle: "Vigil") {
                    Text("Smart-home control + WiFi/acoustic presence sensing, on hardware you own. Pose model: WiFi-DensePose (MIT). No subscriptions, no cloud lock-in.")
                        .font(.system(size: 11)).foregroundColor(Palette.dim)
                }
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).flashyBackground()
    }
    /// Bundled user guides (Resources/guides, DOD-3.7/DOD-11.3). Only files that
    /// actually exist in THIS build are offered — an entry for a missing file would
    /// be a dead control.
    private var availableGuides: [(title: String, file: String, url: URL)] {
        let entries: [(String, String)] = [
            ("First run", "FIRST-RUN.md"), ("Features", "FEATURES.md"),
            ("Permissions", "PERMISSIONS.md"), ("Sensor integration", "INTEGRATION.md"),
            ("Backup & recovery", "RECOVERY.md"), ("Uninstall", "UNINSTALL.md"),
        ]
        return entries.compactMap { title, file in
            guard let url = Bundle.main.resourceURL?
                .appendingPathComponent("guides", isDirectory: true)
                .appendingPathComponent(file),
                FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (title, file, url)
        }
    }

    /// The engine's Application Support log directory — mirrors Homefront.swift's
    /// homefrontSupportDirectory() (incl. the HOMEFRONT_DATA_DIR QA override) without
    /// widening that private helper's surface.
    private func engineLogDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["HOMEFRONT_DATA_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Homefront", isDirectory: true)
    }

    private func logTail(_ name: String, maxBytes: Int = 8192) -> (name: String, tail: String) {
        let url = engineLogDirectory().appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return (name, "") }
        let tail = data.count > maxBytes ? data.suffix(maxBytes) : data[...]
        return (name, String(decoding: tail, as: UTF8.self))
    }

    /// DOD-7.6/DOD-11.5: a user-reachable, privacy-safe diagnostics export. The report
    /// text is assembled by the unit-locked DiagnosticsReport renderer from explicitly
    /// passed values — status lines, permission labels, model COUNTS, and engine log
    /// tails. No credentials, no PSK, no resident names.
    private func exportDiagnostics() {
        let info = Bundle.main.infoDictionary ?? [:]
        let report = DiagnosticsReport.render(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            engineStatus: engine.statusLine,
            engineConnected: engine.connected,
            notifStatus: store.notifAuth.cardLabel,
            locationStatus: store.geofenceAuth.cardLabel,
            roomCount: store.state.rooms.count,
            deviceCount: store.state.devices.count,
            residentCount: store.state.residents.count,
            logTails: ["home_engine.err.log", "sentinel.out.log", "sentinel.err.log"].map { logTail($0) })
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vigil-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            backupError = nil
            backupStatus = "Diagnostics saved as \(url.lastPathComponent) — status + engine log excerpts only, no credentials. Review before sharing."
        } catch {
            backupStatus = nil
            backupError = "Diagnostics export failed: \(error.localizedDescription). Nothing was written and your home data is untouched — try saving to a different folder."
        }
    }

    /// DOD-9.5 (mechanism half): one manifest check, decided by the unit-locked
    /// UpdaterModel. See Updater.swift for the decision rule and honesty rails.
    private func checkForUpdates() {
        guard !checkingUpdates else { return }
        guard let build = UpdaterModel.currentBuild() else {
            updateOffersDownload = false
            updateStatus = "This build carries no readable build number — cannot compare against the published release."
            return
        }
        checkingUpdates = true
        Task {
            let result = await UpdaterModel.check(currentBuild: build)
            await MainActor.run {
                checkingUpdates = false
                if case .decision(.updateAvailable) = result { updateOffersDownload = true }
                else { updateOffersDownload = false }
                updateStatus = UpdaterModel.statusLine(result)
            }
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "homefront-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportConfig(to: url)
            backupError = nil
            backupStatus = "Exported \(HomeConfigBackup.summary(for: store.state))."
        } catch {
            backupStatus = nil
            backupError = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let summary = try store.importConfig(from: url)
            backupError = nil
            backupStatus = "Imported \(summary)."
        } catch {
            backupStatus = nil
            backupError = error.localizedDescription
        }
    }
}
#endif // circuit-convert
