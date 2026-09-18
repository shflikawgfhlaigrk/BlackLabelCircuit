// Vigil — Menu-bar quick-controls model (pure, Foundation-only, Tier-3).
//
// The data behind the macOS menu-bar widget: at-a-glance security mode, the
// current MEASURED power draw, and one-tap favorites. Pure + deterministic so
// it unit-tests without SwiftUI or AppKit; MenuBarViews.swift renders it and
// VigilApp hosts it as a MenuBarExtra.
//
// Honesty rule (Black Label §5.1/§5.2 — the same accuracy-or-nothing stance as
// the live Energy reading and the vitals gate): the "now drawing" watts is
// surfaced ONLY when it comes from a FRESH measured sample. A stale sample (the
// app hasn't scanned recently), a future-dated sample (clock skew), or a
// non-finite value yields NO number — the widget shows "—", never a stale or
// fabricated watt. Favorites carry the device's real state, or an honest "—".

import Foundation

/// One favorite device as the menu-bar widget needs it: enough to render a row
/// and drive a one-tap control, with no SwiftUI dependency.
struct MenuBarFavorite: Identifiable, Equatable {
    let id: UUID
    let name: String
    let kind: DeviceKind
    let symbol: String        // SF Symbol for the device kind
    let controllable: Bool    // Vigil can actuate it (control == .controllable)
    let isOn: Bool?           // current on-state for switchables; nil when N/A or unknown
    let stateLabel: String    // honest human label: "On"/"Off"/"Locked"/"Open"/"—"

    /// True when a single menu tap maps cleanly to `HomeStore.primaryToggle` —
    /// switchables (on/off) plus locks, blinds and garages. Everything else
    /// (thermostats, cameras, sensors, un-paired devices) is read-only here.
    var menuActionable: Bool {
        guard controllable else { return false }
        switch kind {
        case .lock, .blind, .garage: return true
        default: return kind.isSwitchable
        }
    }
}

/// The whole menu-bar snapshot at one instant.
struct MenuBarSummary: Equatable {
    var securityMode: SecurityMode
    var nowDrawingWatts: Double?    // nil → no fresh measurement (honest "—")
    var favorites: [MenuBarFavorite]
    var hasFavorites: Bool { !favorites.isEmpty }
    var hasLiveDraw: Bool { nowDrawingWatts != nil }
}

enum MenuBarModel {
    /// How old the latest energy sample may be and still count as "now". Beyond
    /// this the widget shows "—" rather than a stale draw.
    static let defaultFreshness: TimeInterval = 10 * 60   // 10 minutes

    /// The latest MEASURED total draw (W), but only if it is a fresh, finite,
    /// non-negative sample. Otherwise nil — accuracy-or-nothing. Pure.
    static func nowDrawingWatts(history: [EnergySample],
                                now: Date,
                                maxAge: TimeInterval = defaultFreshness) -> Double? {
        guard let last = history.max(by: { $0.ts < $1.ts }) else { return nil }   // no samples
        guard last.watts.isFinite, last.watts >= 0 else { return nil }            // not a real watt
        let age = now.timeIntervalSince(last.ts)
        guard age >= 0, age <= maxAge else { return nil }                         // stale / future-dated
        return last.watts
    }

    /// Display string for a watts value: honest "—" when there is no fresh reading.
    static func wattsLabel(_ watts: Double?) -> String {
        guard let w = watts else { return "—" }
        return "\(Int(w.rounded())) W"
    }

    /// Map one device to its menu-bar row representation. Pure. A simulated device is
    /// actuatable from the menu bar too (local-only state; badged SIMULATED in-app).
    /// Hardware is actionable only for kinds the local switch transport can drive
    /// (DeviceControlPolicy) — a stored `.controllable` lock/blind/garage must never
    /// get a menu button that would flip state no command backs (§5.1).
    static func favorite(from d: HFDevice) -> MenuBarFavorite {
        let controllable = d.control == .simulated
            || (d.control == .controllable && DeviceControlPolicy.hasSwitchTransport(d.kind))
        let isOn: Bool?
        let label: String
        switch d.kind {
        case .lock:
            if let locked = d.state.locked { label = locked ? "Locked" : "Unlocked" } else { label = "—" }
            isOn = nil
        case .blind, .garage:
            if let open = d.state.openPct { label = open >= 0.5 ? "Open" : "Closed" } else { label = "—" }
            isOn = nil
        default:
            if d.kind.isSwitchable, let on = d.state.on { isOn = on; label = on ? "On" : "Off" }
            else { isOn = nil; label = "—" }
        }
        return MenuBarFavorite(id: d.id, name: d.name, kind: d.kind, symbol: d.kind.symbol,
                               controllable: controllable, isOn: isOn, stateLabel: label)
    }

    /// All favorite devices as menu-bar rows, in stored order. Pure.
    static func favorites(_ devices: [HFDevice]) -> [MenuBarFavorite] {
        devices.filter { $0.favorite }.map(favorite(from:))
    }

    /// Build the full snapshot from the persisted home state + the clock. Pure.
    static func summary(_ state: HomeState,
                        now: Date,
                        maxAge: TimeInterval = defaultFreshness) -> MenuBarSummary {
        MenuBarSummary(securityMode: state.securityMode,
                       nowDrawingWatts: nowDrawingWatts(history: state.energyHistory, now: now, maxAge: maxAge),
                       favorites: favorites(state.devices))
    }
}
