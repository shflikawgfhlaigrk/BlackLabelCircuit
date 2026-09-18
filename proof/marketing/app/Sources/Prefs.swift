// Black Label Marketing — buyer customization surface (persisted).
// Everything the buyer can tailor: brand identity, accent, default market/vertical,
// site template + palette, caption tone, sender identity for spotlights, motion.
// Persisted as Codable snapshots in the app-support SQLite workspace. Ships EMPTY (no seeded
// values, no Michael data) — defaults are neutral product defaults, not personal data.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Customizable enums

enum SiteTemplate: String, CaseIterable, Identifiable, Codable {
    case bold = "Bold", classic = "Classic", minimal = "Minimal"
    var id: String { rawValue }
    var blurb: String {
        switch self {
        case .bold:    return "Split hero, service visual, high-contrast action rail."
        case .classic: return "Serif headline, editorial spacing, premium trust section."
        case .minimal: return "Tight type, lean sections, restrained accents."
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension Prefs {
    func workspaceSnapshot() -> MarketingPrefsSnapshot {
        MarketingPrefsSnapshot(prefs: self)
    }

    func applyWorkspacePrefs(_ snapshot: MarketingPrefsSnapshot) {
        loading = true
        brandName = snapshot.brandName
        tagline = snapshot.tagline
        accent = snapshot.accent
        logoData = snapshot.logoData
        defaultMarket = snapshot.defaultMarket
        defaultVertical = snapshot.defaultVertical
        siteTemplate = snapshot.siteTemplate
        sitePalette = snapshot.sitePalette
        captionTone = snapshot.captionTone
        captionHashtag = snapshot.captionHashtag
        senderName = snapshot.senderName
        senderEmail = snapshot.senderEmail
        formEndpoint = snapshot.formEndpoint
        contactEmail = snapshot.contactEmail
        motionEnabled = snapshot.motionEnabled
        leadScoreWeights = snapshot.leadScoreWeights
        holoTheme = snapshot.holoTheme
        holoBackgroundData = snapshot.holoBackgroundData
        holoPresets = snapshot.holoPresets
        profiles = snapshot.profiles
        loading = false
        save()
    }
}
#endif // circuit-convert

enum SitePalette: String, CaseIterable, Identifiable, Codable {
    case gold = "Black & Gold", slate = "Slate", emerald = "Emerald", crimson = "Crimson", royal = "Royal"
    var id: String { rawValue }
    /// (accent, accent2, bg, panel) as web hex.
    var hexes: (String, String, String, String) {
        switch self {
        case .gold:    return ("#D9B65C", "#B8923A", "#0B0B0D", "#141416")
        case .slate:   return ("#8FB3D9", "#5E89B8", "#0C0F13", "#15191F")
        case .emerald: return ("#5FCf95", "#2E9D67", "#0A0F0C", "#121A15")
        case .crimson: return ("#E0606A", "#B83A44", "#120A0C", "#1A1215")
        case .royal:   return ("#9A8FE0", "#6453C0", "#0C0B14", "#161526")
        }
    }
    /// The accent as a packed RGB UInt32 (for the native reel renderer).
    var accentRGB: UInt32 {
        switch self {
        case .gold:    return 0xD9B65C
        case .slate:   return 0x8FB3D9
        case .emerald: return 0x5FCF95
        case .crimson: return 0xE0606A
        case .royal:   return 0x9A8FE0
        }
    }
}

enum CaptionTone: String, CaseIterable, Identifiable, Codable {
    case punchy = "Punchy", professional = "Professional", friendly = "Friendly", luxury = "Luxury"
    var id: String { rawValue }
}

// MARK: - Accent (drives the in-app gold accent so the buyer can rebrand the UI)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum AccentChoice: String, CaseIterable, Identifiable, Codable {
    case gold = "Gold", champagne = "Champagne", cyan = "Cyan", burgundy = "Burgundy", emerald = "Emerald"
    var id: String { rawValue }
    var hex: UInt32 {
        switch self {
        case .gold: return 0xD9B65C
        case .champagne: return 0xD4C5A0
        case .cyan: return 0x4FD7FF
        case .burgundy: return 0xC76A78
        case .emerald: return 0x5FCF95
        }
    }
    var color: Color { Color(hex: hex) }
}
#endif // circuit-convert

// MARK: - Saved profile (a complete saved configuration the buyer can switch between)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct BrandProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var brandName: String = ""
    var tagline: String = ""
    var accent: AccentChoice = .gold
    var market: String = ""          // default city/market label
    var vertical: String = ""        // default industry
    var siteTemplate: SiteTemplate = .bold
    var sitePalette: SitePalette = .gold
    var captionTone: CaptionTone = .punchy
}
#endif // circuit-convert

// MARK: - Prefs (the live, persisted customization object)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
final class Prefs: ObservableObject {
    // Brand identity
    @Published var brandName: String = ""        { didSet { save() } }
    @Published var tagline: String = ""          { didSet { save() } }
    @Published var accent: AccentChoice = .gold  { didSet { save() } }
    @Published var logoData: Data? = nil         { didSet { save() } }   // buyer's own logo (PNG/JPG)

    // Defaults for the generators
    @Published var defaultMarket: String = ""    { didSet { save() } }
    @Published var defaultVertical: String = ""  { didSet { save() } }
    @Published var siteTemplate: SiteTemplate = .bold   { didSet { save() } }
    @Published var sitePalette: SitePalette = .gold     { didSet { save() } }
    @Published var captionTone: CaptionTone = .punchy   { didSet { save() } }
    @Published var captionHashtag: String = ""   { didSet { save() } }   // brand hashtag, no default

    // Spotlight email sender identity (buyer's own — used by the spotlight engine)
    @Published var senderName: String = ""       { didSet { save() } }
    @Published var senderEmail: String = ""      { didSet { save() } }

    // Landing-page lead capture (buyer's own form endpoint + contact email)
    @Published var formEndpoint: String = ""     { didSet { save() } }   // POST URL for site forms
    @Published var contactEmail: String = ""     { didSet { save() } }   // mailto fallback for site forms

    // UI motion (mirrors prefers-reduced-motion). P2-14: default OFF for new profiles — motion caused
    // visible lag on the 2026-07-08 tester's machine; the toggle stays for opt-in.
    @Published var motionEnabled: Bool = false   { didSet { save() } }

    // Lead-scoring weights (buyer-tunable; transparent point math, no opaque model)
    @Published var leadScoreWeights: LeadScoreWeights = .default { didSet { save() } }

    // Holographic Theme / Appearance Studio — the live look the whole FX kit reads. Persisted.
    // P2-14: a fresh profile opens on the calm (effects-off) default; presets remain one tap away.
    @Published var holoTheme: HoloTheme = .calmDefault { didSet { save() } }
    @Published var holoBackgroundData: Data? = nil { didSet { save() } }   // buyer's own app-wide background image
    // The buyer's own saved holographic looks (alongside the built-in presets).
    @Published var holoPresets: [HoloPreset] = [] { didSet { save() } }

    // Saved profiles (switchable complete configurations)
    @Published var profiles: [BrandProfile] = [] { didSet { save() } }
    /// Custom brand accent (0 = use the preset `accent`). Set from the color picker or extracted
    /// from the buyer's logo/site — the "custom colors" the website promises.
    @Published var customAccentHex: UInt32 = 0   { didSet { save() } }
    /// Colors extracted from the buyer's logo / scraped from their site (for the brand kit palette).
    @Published var brandColors: [UInt32] = []    { didSet { save() } }
    /// Deliverability warmup pacing applied to journey/newsletter sends.
    @Published var warmup: WarmupSchedule = .default { didSet { save() } }
    /// Buyer's own analytics/ad account IDs (provider key → account/property id). Configuring one is
    /// the buyer connecting THEIR own source; KPIs stay empty until real data syncs (no fabrication).
    @Published var analyticsAccounts: [String: String] = [:] { didSet { save() } }

    /// Live accent color the whole UI reads. Buyer-controlled; custom hex wins over the preset.
    var accentColor: Color { customAccentHex != 0 ? Color(hex: customAccentHex) : accent.color }
    /// The accent RGB every generator (reels, sites) should use — honors the custom color.
    var brandAccentRGB: UInt32 { customAccentHex != 0 ? customAccentHex : sitePalette.accentRGB }

    /// The brand mark shown in the sidebar/auth, or nil to use the app icon.
    var logoImage: NSImage? { logoData.flatMap { NSImage(data: $0) } }

    private struct Box: Codable {
        var brandName, tagline: String
        var accent: AccentChoice
        var logoData: Data?
        var defaultMarket, defaultVertical: String
        var siteTemplate: SiteTemplate
        var sitePalette: SitePalette
        var captionTone: CaptionTone
        var captionHashtag: String
        var senderName, senderEmail: String
        var formEndpoint, contactEmail: String?
        var motionEnabled: Bool
        var profiles: [BrandProfile]
        var leadScoreWeights: LeadScoreWeights?
        // Optional so a settings.json saved before the Theme Studio existed still loads.
        var holoTheme: HoloTheme?
        var holoBackgroundData: Data?
        var holoPresets: [HoloPreset]?
        var customAccentHex: UInt32?
        var brandColors: [UInt32]?
        var warmup: WarmupSchedule?
        var analyticsAccounts: [String: String]?
    }
    private var database: WorkspaceDatabase
    private var legacyURL: URL
    private var loading = false

    /// Legacy JSON prefs used only for first-run migration/fallback. Demo writes to a SEPARATE file
    /// so the demo brand can never overwrite the buyer's real customization.
    private static func legacyStoreURL(demo: Bool) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelMarketing", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(demo ? "prefs-demo.json" : "prefs.json")
    }

    init() {
        database = WorkspaceDatabase(demo: DemoMode.active)
        legacyURL = Prefs.legacyStoreURL(demo: DemoMode.active)
        load()
    }

    /// Repoint at the isolated demo prefs file and reset to clean defaults so the
    /// demo brand seed starts from a known state. Never touches the real workspace database.
    func enterDemo() {
        database = WorkspaceDatabase(demo: true)
        legacyURL = Prefs.legacyStoreURL(demo: true)
        try? database.deleteBlob(named: WorkspaceDatabase.prefsBlobName)
        try? FileManager.default.removeItem(at: legacyURL)
        resetAll()   // clean defaults; DemoData.seedPrefs then sets the demo brand
    }

    /// Leave demo mode: repoint at the real workspace database and load the buyer's own brand
    /// (clean defaults on first run). The demo prefs database is left untouched on disk, and
    /// the real workspace database is NEVER overwritten here — we reset memory then load from disk,
    /// so a returning buyer keeps their saved customization.
    func exitDemo() {
        database = WorkspaceDatabase(demo: false)
        legacyURL = Prefs.legacyStoreURL(demo: false)
        // Clear the demo brand from memory only (no save — guarded by loading=true).
        loading = true
        brandName = ""; tagline = ""; accent = .gold; logoData = nil
        defaultMarket = ""; defaultVertical = ""; siteTemplate = .bold; sitePalette = .gold
        captionTone = .punchy; captionHashtag = ""; senderName = ""; senderEmail = ""
        formEndpoint = ""; contactEmail = ""
        motionEnabled = false; profiles = []
        leadScoreWeights = .default
        holoTheme = .calmDefault; holoBackgroundData = nil; holoPresets = []
        customAccentHex = 0; brandColors = []; warmup = .default; analyticsAccounts = [:]
        loading = false
        load()   // load the buyer's real prefs (clean defaults remain if none on disk)
    }

    private func load() {
        if let data = try? database.readBlob(named: WorkspaceDatabase.prefsBlobName),
           let b = try? JSONDecoder().decode(Box.self, from: data) {
            apply(b)
            return
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let b = try? JSONDecoder().decode(Box.self, from: data) else { return }
        apply(b)
        try? database.writeBlob(data, named: WorkspaceDatabase.prefsBlobName)
    }

    private func apply(_ b: Box) {
        loading = true
        // Brand isolation: a retired placeholder clears to empty so the buyer sets their own
        // brand — never rewrite a workspace to carry the app-maker's brand.
        let retiredPlaceholderBrand = b.brandName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "vector"
        brandName = retiredPlaceholderBrand ? "" : b.brandName
        tagline = b.tagline; accent = b.accent; logoData = b.logoData
        defaultMarket = b.defaultMarket; defaultVertical = b.defaultVertical
        siteTemplate = b.siteTemplate; sitePalette = b.sitePalette
        captionTone = b.captionTone; captionHashtag = b.captionHashtag
        senderName = b.senderName; senderEmail = b.senderEmail
        formEndpoint = b.formEndpoint ?? ""; contactEmail = b.contactEmail ?? ""
        motionEnabled = b.motionEnabled; profiles = b.profiles
        leadScoreWeights = b.leadScoreWeights ?? .default
        holoTheme = b.holoTheme ?? .goldVault
        holoBackgroundData = b.holoBackgroundData
        holoPresets = b.holoPresets ?? []
        customAccentHex = b.customAccentHex ?? 0
        brandColors = b.brandColors ?? []
        warmup = b.warmup ?? .default
        analyticsAccounts = b.analyticsAccounts ?? [:]
        loading = false
        if retiredPlaceholderBrand { save() }
    }

    // P1-9: instant save-state feedback. Every autosaved edit stamps this; the Settings screen
    // observes it to flash a "Saved" confirmation so the buyer knows their change persisted.
    @Published var lastSaveAt: Date? = nil

    private func save() {
        guard !loading else { return }
        let b = Box(brandName: brandName, tagline: tagline, accent: accent, logoData: logoData,
                    defaultMarket: defaultMarket, defaultVertical: defaultVertical,
                    siteTemplate: siteTemplate, sitePalette: sitePalette,
                    captionTone: captionTone, captionHashtag: captionHashtag,
                    senderName: senderName, senderEmail: senderEmail,
                    formEndpoint: formEndpoint, contactEmail: contactEmail,
                    motionEnabled: motionEnabled, profiles: profiles,
                    leadScoreWeights: leadScoreWeights,
                    holoTheme: holoTheme, holoBackgroundData: holoBackgroundData, holoPresets: holoPresets,
                    customAccentHex: customAccentHex, brandColors: brandColors, warmup: warmup,
                    analyticsAccounts: analyticsAccounts)
        guard let data = try? JSONEncoder().encode(b) else { return }
        do {
            try database.writeBlob(data, named: WorkspaceDatabase.prefsBlobName)
        } catch {
            try? data.write(to: legacyURL, options: .atomic)
        }
        lastSaveAt = Date()
    }

    /// Display brand name for the UI and generated content. Falls back to a neutral
    /// placeholder when unset — buyer output must never inherit the app-maker's brand.
    var displayBrand: String { brandName.trimmingCharacters(in: .whitespaces).isEmpty ? "Your Brand" : brandName }

    // Profile management
    func saveCurrentAsProfile(named name: String) {
        let p = BrandProfile(name: name.isEmpty ? "Profile \(profiles.count + 1)" : name,
                             brandName: brandName, tagline: tagline, accent: accent,
                             market: defaultMarket, vertical: defaultVertical,
                             siteTemplate: siteTemplate, sitePalette: sitePalette, captionTone: captionTone)
        profiles.insert(p, at: 0)
    }
    func apply(_ p: BrandProfile) {
        loading = true
        brandName = p.brandName; tagline = p.tagline; accent = p.accent
        defaultMarket = p.market; defaultVertical = p.vertical
        siteTemplate = p.siteTemplate; sitePalette = p.sitePalette; captionTone = p.captionTone
        loading = false; save()
    }
    func deleteProfile(_ p: BrandProfile) { profiles.removeAll { $0.id == p.id } }

    // MARK: Holographic Theme / Appearance Studio management

    /// Apply a built-in or computed look. Applies app-wide instantly (Prefs is observed).
    func applyHoloTheme(_ t: HoloTheme) { holoTheme = t }

    /// Save the current look as a named custom preset (lives alongside the built-ins).
    func saveCurrentHoloPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let p = HoloPreset(name: trimmed.isEmpty ? "Look \(holoPresets.count + 1)" : trimmed, theme: holoTheme)
        holoPresets.insert(p, at: 0)
    }
    /// Load a saved custom preset's look into the live theme.
    func applyHoloPreset(_ p: HoloPreset) { holoTheme = p.theme }
    func deleteHoloPreset(_ p: HoloPreset) { holoPresets.removeAll { $0.id == p.id } }

    /// Reset only the holographic look to the default (Gold Vault), keeping other settings.
    func resetHoloTheme() { holoTheme = .goldVault }
    func clearHoloBackground() { holoBackgroundData = nil; holoTheme.background = .aurora }

    /// Reset everything to neutral product defaults (App Store deletion / clean-slate).
    func resetAll() {
        loading = true
        brandName = ""; tagline = ""; accent = .gold; logoData = nil
        defaultMarket = ""; defaultVertical = ""; siteTemplate = .bold; sitePalette = .gold
        captionTone = .punchy; captionHashtag = ""; senderName = ""; senderEmail = ""
        formEndpoint = ""; contactEmail = ""
        motionEnabled = false; profiles = []
        leadScoreWeights = .default
        // Clear the persisted holographic look + the buyer's custom presets back to the default.
        holoTheme = .calmDefault; holoBackgroundData = nil; holoPresets = []
        customAccentHex = 0; brandColors = []; warmup = .default; analyticsAccounts = [:]
        loading = false; save()
    }
}
#endif // circuit-convert
