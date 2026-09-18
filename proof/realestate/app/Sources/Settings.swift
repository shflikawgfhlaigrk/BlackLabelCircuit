// Black Label Real Estate — SETTINGS / CUSTOMIZATION store.
// A real, deeply-tailorable, persisted settings surface. Nothing here is hardcoded into the
// UI: data sources/counties, probate + builder target criteria, 3-mile/ARV parameters, route
// & canvass options, branding/identity (workspace name, accent, mono/serif toggle, motion),
// and saved profiles. Persisted as Codable snapshots in the Postgres workspace (own data, no Utah).
import Foundation
import CircuitPortKit
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Accent options the buyer can theme the whole app with (premium palette only).
// Each maps to a (primary, highlight, dim) triple in BLAccent; selecting one re-themes the
// entire premium chrome (headlines, buttons, panel borders, badges, route pins), not just .tint.
enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case gold, champagne, burgundy, cyan
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// (primary, highlight, dim) — the live accent triple this choice installs.
    var triple: (Color, Color, Color) {
        switch self {
        case .gold:      return BLAccent.goldTriple
        case .champagne: return BLAccent.champagneTriple
        case .burgundy:  return BLAccent.burgundyTriple
        case .cyan:      return BLAccent.cyanTriple
        }
    }
    var color: Color { triple.0 }   // fixed swatch for the picker (does NOT read the live accent)
    var hi: Color { triple.1 }
}
#endif // circuit-convert

// Route engine personality the buyer picks for canvassing.
enum RouteMode: String, Codable, CaseIterable, Identifiable {
    case canvasser, fleet2, fleet3
    var id: String { rawValue }
    var label: String {
        switch self { case .canvasser: return "Canvasser (1 driver, value-first)"
        case .fleet2: return "Fleet — 2 vehicles"; case .fleet3: return "Fleet — 3 vehicles" }
    }
    var config: RouteConfig {
        switch self { case .canvasser: return .canvasser
        case .fleet2: return .fleet(2); case .fleet3: return .fleet(3) }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// A saved configuration profile (e.g. "Atlanta probate", "North GA fleet").
struct SettingsProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = "Profile"
    var snapshot: SettingsData = SettingsData()
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// The full persisted settings payload.
struct SettingsData: Codable, Hashable {
    // Branding / identity
    var workspaceName: String = "Black Label Real Estate"
    var tagline: String = "Your deal pipeline — analysis, probate leads, financing."
    var accent: AccentChoice = .gold
    var motionEnabled: Bool = false   // default OFF for new profiles (founder directive 2026-07-08); user opts in under Appearance
    var useSerifDisplay: Bool = true

    // Data sources / counties (free OSM markets the finder targets; plus the user's own county list)
    var targetCounties: [String] = []           // e.g. ["Harris", "Houston", "Hall"]
    var preferredMarket: String = "Atlanta, GA"  // default metro label for the area finder

    // Probate target criteria
    var probateSources: [String] = ["Probate notice", "Estate sale", "Pre-foreclosure"]
    var minLeadScoreNote: String = ""            // free-form qualifier the buyer keys on

    // Builder target criteria (new-construction leads)
    var builderMinUnits: Int = 1
    var builderRadiusMi: Double = 25

    // 3-mile radius / ARV parameters
    var radiusMiles: Double = 3.0
    var maoPercent: Double = 70.0                // 70% rule — fully adjustable
    var arvSourceNote: String = "County-assessed / fair-market value"

    // Route / canvass options
    var routeMode: RouteMode = .canvasser
    var depotAddress: String = ""                // start point for routes (the buyer's office)
    var avgSpeedMph: Double = 30.0

    // Holographic look — the live FX theme the whole app reads (Theme/Appearance Studio).
    // Persisted with everything else so a saved profile captures the look too.
    var holo: HoloTheme = .goldVault

    static let counterFree = ["maoPercent", "radiusMiles"]  // doc anchor for adjustable params
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Observable settings backbone — single source of truth, persisted on every change.
final class SettingsStore: ObservableObject {
    @Published var data: SettingsData { didSet { applyAccent(); save() } }
    @Published var profiles: [SettingsProfile] { didSet { save() } }
    /// User-saved holographic looks (alongside the built-in HoloTheme.presets).
    @Published var holoPresets: [HoloPreset] { didSet { save() } }

    private struct Box: Codable { var data: SettingsData; var profiles: [SettingsProfile]; var holoPresets: [HoloPreset]? }
    private let database: RealEstateLocalDatabase
    /// Set only while a bulk reset is rewriting every @Published at once, so the didSet chain cannot
    /// re-persist a half-erased snapshot on top of the blob we are about to delete.
    private var suppressSave = false

    init() {
        database = RealEstateLocalDatabase()
        if let d = try? database.readBlob(named: RealEstateLocalDatabase.settings),
           let box = try? JSONDecoder().decode(Box.self, from: d) {
            data = box.data; profiles = box.profiles; holoPresets = box.holoPresets ?? []
        } else {
            data = SettingsData(); profiles = []; holoPresets = []
        }
        applyAccent()   // install the persisted accent into the live theme at launch
    }

    /// Push the chosen accent into the process-global live palette so every BL.gold / BLTheme.gold
    /// call-site re-themes. The HoloTheme accent is the source of truth (the legacy AccentChoice
    /// picker and the Theme Studio both write into data.holo). Bumps objectWillChange so all views
    /// redraw with the new accent immediately.
    func applyAccent() {
        BLAccent.set(primary: data.holo.accent, hi: data.holo.accentHi, dim: data.holo.accentDim)
        objectWillChange.send()
    }

    /// Replace the whole holographic look (preset apply or live edit). Keeps BLAccent in sync.
    func setHolo(_ t: HoloTheme) { data.holo = t }     // didSet → applyAccent + save

    private func save() {
        guard !suppressSave else { return }
        if let d = try? JSONEncoder().encode(Box(data: data, profiles: profiles, holoPresets: holoPresets)) {
            try? database.writeBlob(d, named: RealEstateLocalDatabase.settings)
        }
    }

    /// DESTRUCTIVE — the account-deletion path (Settings → Account → "Delete account & local data").
    /// Resets every live setting, saved profile and saved look to factory defaults AND deletes the
    /// persisted settings blob, so nothing survives a relaunch. Writes are suppressed while the
    /// @Published values are being reset so the didSet chain can't rewrite the blob after we delete
    /// it; the accent is re-applied at the end so the UI visibly snaps back to the default theme.
    func eraseAll() {
        suppressSave = true
        data = SettingsData()
        profiles = []
        holoPresets = []
        suppressSave = false
        // Delete the persisted blob, then IMMEDIATELY write the factory-default one back. The
        // rewrite is not cosmetic: LocalDatabase.readBlob treats a missing blob as a cue to lift the
        // same-named row out of the legacy workspace.sqlite3 store and re-persist it, so a bare
        // delete would hand the user their "erased" settings back on the next launch. Writing
        // defaults destroys the content AND shadows the legacy row permanently.
        try? database.deleteBlob(named: RealEstateLocalDatabase.settings)
        save()
        applyAccent()
    }
    // Settings-profile management (captures the holo look too).
    func saveCurrentAsProfile(named name: String) {
        profiles.insert(SettingsProfile(name: name.isEmpty ? "Profile \(profiles.count + 1)" : name, snapshot: data), at: 0)
    }
    func apply(_ p: SettingsProfile) { data = p.snapshot }
    func deleteProfile(_ p: SettingsProfile) { profiles.removeAll { $0.id == p.id } }

    // Holographic-look (Theme Studio) preset management.
    func saveHoloPreset(named name: String) {
        holoPresets.insert(HoloPreset(name: name.isEmpty ? "My Look \(holoPresets.count + 1)" : name, theme: data.holo), at: 0)
    }
    func applyHolo(_ p: HoloPreset) { setHolo(p.theme) }
    func deleteHoloPreset(_ p: HoloPreset) { holoPresets.removeAll { $0.id == p.id } }

    /// Whether ambient premium motion should run (in-app toggle AND system Reduce Motion).
    func motionActive(systemReduceMotion: Bool) -> Bool { data.motionEnabled && !systemReduceMotion && data.holo.motion != .off }
}
#endif // circuit-convert
