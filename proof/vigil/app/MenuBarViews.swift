#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Vigil — the macOS menu-bar dropdown (MenuBarExtra content).
//
// Renders MenuBarModel (pure, MenuBar.swift) over the live HomeStore: quick
// security-mode switching, the current MEASURED power draw, and one-tap
// favorites. Every control routes to the store's existing actuators
// (setSecurityMode / primaryToggle) — no new control path, no fabricated state.
// The "now drawing" figure is honest: it shows "—" unless a fresh measured
// sample exists (the freshness gate lives in MenuBarModel.nowDrawingWatts).

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif

struct MenuBarPanel: View {
    @EnvironmentObject var store: HomeStore
    /// Scene-level reopen for the main window: after the user closes it (the
    /// designed menu-bar-persistent flow) NSApp.windows holds nothing to front,
    /// so "Open Vigil" must go through the WindowGroup id to re-create it.
    @Environment(\.openWindow) private var openWindow
    /// Re-evaluates the draw-freshness gate while the panel is open.
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var summary: MenuBarSummary { MenuBarModel.summary(store.state, now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(Palette.stroke)
            modeRow
            drawRow
            Divider().overlay(Palette.stroke)
            favoritesSection
            Divider().overlay(Palette.stroke)
            footer
        }
        .padding(12)
        .frame(width: 286)
        .background(Palette.bg)
        .onReceive(tick) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "house.fill").foregroundColor(Palette.gold)
            Text("Vigil").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
            Spacer()
            Image(systemName: summary.securityMode.symbol)
                .foregroundColor(summary.securityMode.isArmed ? Palette.gold : Palette.dim)
            Text(summary.securityMode.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(summary.securityMode.isArmed ? Palette.goldTxt : Palette.dim)
        }
    }

    private var modeRow: some View {
        HStack(spacing: 6) {
            ForEach(SecurityMode.allCases) { m in
                ModeChip(mode: m, selected: store.state.securityMode == m) { store.setSecurityMode(m) }
            }
        }
    }

    private var drawRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").foregroundColor(summary.hasLiveDraw ? Palette.gold : Palette.dim)
            Text("Now drawing").font(.system(size: 12)).foregroundColor(Palette.dim)
            Spacer()
            Text(MenuBarModel.wattsLabel(summary.nowDrawingWatts))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(summary.hasLiveDraw ? .white : Palette.dim)
        }
        .help(summary.hasLiveDraw ? "Latest measured total draw across your metered plugs"
                                  : "No fresh reading — open Energy to scan your metered plugs")
    }

    @ViewBuilder private var favoritesSection: some View {
        if summary.hasFavorites {
            VStack(alignment: .leading, spacing: 6) {
                Text("FAVORITES").font(.system(size: 10, weight: .bold)).foregroundColor(Palette.dim).kerning(0.6)
                ForEach(summary.favorites) { fav in favoriteRow(fav) }
            }
        } else {
            Text("Star a device to put quick controls here.")
                .font(.system(size: 11)).foregroundColor(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func favoriteRow(_ fav: MenuBarFavorite) -> some View {
        HStack(spacing: 8) {
            Image(systemName: fav.symbol).foregroundColor(Palette.goldTxt).frame(width: 18)
            Text(fav.name).font(.system(size: 12)).foregroundColor(.white).lineLimit(1)
            Spacer()
            if fav.menuActionable, let on = fav.isOn {
                // Switchable: a real toggle that drives the device through the store.
                Toggle("", isOn: Binding(get: { on }, set: { _ in store.primaryToggle(fav.id) }))
                    .labelsHidden().tint(Palette.gold).controlSize(.mini)
            } else if fav.menuActionable {
                // Lock / blind / garage: a button labeled with the real state.
                Button(fav.stateLabel) { store.primaryToggle(fav.id) }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain).foregroundColor(Palette.gold)
            } else {
                // Read-only / pairing-required: honest state, no dead control.
                Text(fav.stateLabel).font(.system(size: 11)).foregroundColor(Palette.dim)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { openVigil() } label: {
                Label("Open Vigil", systemImage: "macwindow")
                    .font(.system(size: 12)).foregroundColor(Palette.goldTxt)
            }.buttonStyle(.plain)
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 12)).foregroundColor(Palette.dim)
            }.buttonStyle(.plain).help("Quit Vigil")
        }
    }

    private func openVigil() {
        openWindow(id: VigilApp.mainWindowID)   // fronts the window, or re-creates a closed one
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
#endif // circuit-convert
