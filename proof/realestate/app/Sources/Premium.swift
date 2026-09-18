#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — PREMIUM / HOLOGRAPHIC design layer.
// SwiftUI translation of the storefront's dark-luxury language (see PREMIUM-DESIGN-SPEC.md):
// black + gold + champagne, Cormorant Garamond display, glass cards with a slow gold
// border-pulse + light sheen-sweep, shimmer-gradient headlines, a faint drifting HUD grid,
// and conic-foil premium badges. Motion is slow & expensive (8–20s ambient, 0.2–0.3s press)
// and honors BOTH system Reduce Motion AND an in-app Settings toggle.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Live accent (so the Settings "Accent" picker re-themes the WHOLE app, not just .tint).
// The entire premium chrome reads its primary accent from `BL.gold` / `BL.goldHi` / `BL.goldDim`
// / `BL.goldGrad`. Those are computed from this single, process-global triple, which `SettingsStore`
// keeps in sync with the buyer's persisted `AccentChoice`. Default is true gold (identical look until
// the buyer changes it). No data, no Utah — just the live theme primitive.
enum BLAccent {
    // Per-accent triples (primary, glint highlight, dim). Gold is the spec default.
    static let goldTriple      = (Color(hex: 0xC9A961), Color(hex: 0xF9E27D), Color(hex: 0x8A7340))
    static let champagneTriple = (Color(hex: 0xD4C5A0), Color(hex: 0xEFE6C9), Color(hex: 0xA8966F))
    static let burgundyTriple  = (Color(hex: 0x8B3A4A), Color(hex: 0xB85666), Color(hex: 0x6B2D3E))
    static let cyanTriple      = (Color(hex: 0x4FD7FF), Color(hex: 0x9CE9FF), Color(hex: 0x2E9BBF))

    static var primary: Color = goldTriple.0
    static var hi: Color      = goldTriple.1
    static var dim: Color     = goldTriple.2

    /// Swap the live accent triple (called by SettingsStore when the buyer changes the accent).
    static func set(primary p: Color, hi h: Color, dim d: Color) { primary = p; hi = h; dim = d }
}

// MARK: - Exact palette (from spec)
enum BL {
    // Backgrounds
    static let base   = Color(hex: 0x050505)   // near-black canvas
    static let bg1    = Color(hex: 0x0B0B0B)
    static let bg2v   = Color(hex: 0x121212)
    static let hair1  = Color(hex: 0x1F1F1F)
    static let hair2  = Color(hex: 0x2A2A2A)
    // Text
    static let text   = Color(hex: 0xE8E6E1)
    // LEGIBILITY: secondary text bumped from 0x8A8680 (≈5.2:1) to 0x9E9A92 (≈6.7:1 on dark panels)
    // so small labels/subtitles read crisply at a glance. Still muted/premium, comfortably WCAG-AA.
    static let dim    = Color(hex: 0x9E9A92)
    static let mute   = Color(hex: 0x6E6A62)
    // Accents — `gold*` now resolve from the LIVE accent (BLAccent) so every call-site re-themes
    // when the buyer picks a different accent in Settings. The fixed swatch values stay available
    // on AccentChoice for the picker itself.
    static var gold     : Color { BLAccent.primary }
    static var goldDim  : Color { BLAccent.dim }
    static var goldHi   : Color { BLAccent.hi }   // glint highlight
    static let champagne = Color(hex: 0xD4C5A0)
    static let burgundy  = Color(hex: 0x8B3A4A)
    static let burgundyDeep = Color(hex: 0x6B2D3E)
    static let cyan     = Color(hex: 0x4FD7FF)   // holo highlight — sparingly
    static let ink      = Color(hex: 0x140E03)   // text on gold fills
    static let danger   = Color(hex: 0xFF6B6B)
    static let ok       = Color(hex: 0x6FD08C)

    static var goldGrad: LinearGradient {
        LinearGradient(colors: [goldHi, gold, goldDim], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    // LEGIBILITY (owner feedback: text read fuzzy even with no .blur()): card reading surfaces are
    // now near-OPAQUE so the moving aurora never shows through behind body text/labels/numbers. The
    // `.ultraThinMaterial` under a HoloCard still frosts the aurora (premium glass look), but the
    // text sits on this solid tint — high contrast, razor-sharp. (Was 0.62 → reads fuzzy over aurora.)
    static var glassFill: Color { Color(.sRGB, red: 8/255, green: 11/255, blue: 16/255, opacity: 0.96) }
    static var glassFillStrong: Color { Color(.sRGB, red: 7/255, green: 10/255, blue: 15/255, opacity: 0.985) }
    /// Fully opaque reading panel — for any region that holds dense body text (forms, lists, detail
    /// panes) where even a hint of aurora bleed-through would soften the text. WCAG-AA safe base.
    static var readingFill: Color { Color(.sRGB, red: 9/255, green: 12/255, blue: 17/255, opacity: 1.0) }
    // Shimmer headline gradient: gold → champagne → cyan → gold (spec component 4).
    static var shimmerStops: [Color] { [gold, champagne, goldHi, cyan, champagne, gold] }
}

// MARK: - Bundled OFL typography (own-it: free Google Fonts, OFL)
enum BLFont {
    // Internal family names verified from the bundled TTFs.
    static let displayFamily = "Cormorant Garamond"     // serif luxury signature
    static let bodyFamily    = "Instrument Sans"
    static let monoFamily    = "JetBrains Mono"
    private static var registered = false

    /// Register the bundled variable fonts with the Core Text font manager so
    /// `Font.custom` resolves them under sandbox. Safe to call repeatedly.
    static func registerIfNeeded() {
        guard !registered else { return }; registered = true
        for f in ["CormorantGaramond", "JetBrainsMono", "InstrumentSans"] {
            if let url = Bundle.main.url(forResource: f, withExtension: "ttf") ??
                         Bundle.main.url(forResource: f, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
    /// True if the display serif actually resolved (else callers fall back to New York).
    static var displayAvailable: Bool {
        NSFontManager.shared.availableFontFamilies.contains(displayFamily)
    }

    // Every call site passes a size authored on the desktop canvas; BLScale shrinks it to whatever
    // screen is actually running (identity on macOS/iPad, ~0.87 on an iPhone SE).
    // Display serif headline. Falls back to system serif (New York) if bundling failed.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let s = BLScale.f(size)
        return displayAvailable ? .custom(displayFamily, size: s).weight(weight)
                                : .system(size: s, weight: weight, design: .serif)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let s = BLScale.f(size)
        return NSFontManager.shared.availableFontFamilies.contains(bodyFamily)
            ? .custom(bodyFamily, size: s).weight(weight)
            : .system(size: s, weight: weight, design: .rounded)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let s = BLScale.f(size)
        return NSFontManager.shared.availableFontFamilies.contains(monoFamily)
            ? .custom(monoFamily, size: s).weight(weight)
            : .system(size: s, weight: weight, design: .monospaced)
    }
}

// MARK: - Motion gate (system Reduce Motion + in-app toggle)
// Default OFF so the app is STATIC-by-default everywhere (founder fleet motion directive
// 2026-07-09): any view rendered outside RootView's `\.blMotion` injection ships calm. RootView
// always overrides this with the live computed value (in-app toggle && !ReduceMotion && …), so
// the real motion state is unchanged — this only hardens the fallback for detached/preview hosts.
struct MotionEnabledKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True when ambient animations should run (in-app toggle is ON *and* system Reduce Motion is OFF).
    var blMotion: Bool {
        get { self[MotionEnabledKey.self] }
        set { self[MotionEnabledKey.self] = newValue }
    }
}

// MARK: - Shimmer headline (spec component 4): moving multi-stop gradient masked to text.
struct ShimmerText: View {
    let text: String
    var size: CGFloat = 30
    var weight: Font.Weight = .regular
    @Environment(\.blMotion) private var motion
    var body: some View {
        Text(text)
            .font(BLFont.display(size, weight))
            .overlay(
                // Pausable TimelineView shimmer — wall-clock phase, no uncancelable repeatForever.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !motion)) { tl in
                    let phase = motion ? -1 + 2 * FXClock.pingPong(tl.date, 20) : 0
                    GeometryReader { geo in
                        LinearGradient(colors: BL.shimmerStops, startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 2.2)
                            .offset(x: phase * geo.size.width * 1.2)
                    }
                    .mask(Text(text).font(BLFont.display(size, weight)))
                }
                .allowsHitTesting(false)
            )
            .accessibilityLabel(text)
    }
}

// NOTE: `HoloCard` / `.holoCard()` now live in the canonical FX kit `Holographic.swift`
// (consolidated there with pointer 3D tilt + diagonal sweep + iridescent animated border, all
// driven by the live `HoloTheme`). The call-site API `.holoCard(radius:sweep:)` is unchanged.

// MARK: - HUD grid backdrop (spec component 6): faint ~48px drifting grid behind hero areas.
struct HUDGrid: View {
    var spacing: CGFloat = 48
    var tint: Color = BL.gold
    @Environment(\.blMotion) private var motion
    var body: some View {
        // Drift is a wall-clock sawtooth over a pausable TimelineView (the grid repeats every
        // `spacing` px, so a 0→spacing loop is seamless). 10fps is plenty for a 60s drift.
        TimelineView(.animation(minimumInterval: 1.0 / 10.0, paused: !motion)) { tl in
            let drift = motion ? spacing * FXClock.loop(tl.date, 60) : 0
            Canvas { ctx, size in
                var path = Path()
                var x: CGFloat = drift.truncatingRemainder(dividingBy: spacing) - spacing
                while x < size.width + spacing { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
                var y: CGFloat = drift.truncatingRemainder(dividingBy: spacing) - spacing
                while y < size.height + spacing { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
                ctx.stroke(path, with: .color(tint.opacity(0.05)), lineWidth: 0.6)
            }
        }
        // Decorative grid — click-through, baked at the body ROOT (last modifier) so it can never
        // intercept a button click regardless of placement behind hero areas.
        .allowsHitTesting(false)
    }
}

// MARK: - Conic foil badge (spec component 7): iridescent ring, premium accents only.
struct FoilBadge: View {
    let text: String
    var icon: String = ""
    @Environment(\.blMotion) private var motion
    var body: some View {
        HStack(spacing: 6) {
            if !icon.isEmpty { Image(systemName: icon).font(.blSystem(size: 10, weight: .bold)) }
            Text(text.uppercased()).font(BLFont.mono(9.5, .bold)).tracking(1.0)
        }
        .foregroundColor(BL.text)
        .padding(.vertical, 5).padding(.horizontal, 11)
        .background(BL.glassFillStrong)
        .clipShape(Capsule())
        .overlay(
            // Ring spin via pausable TimelineView — no uncancelable repeatForever.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !motion)) { tl in
                Capsule().strokeBorder(
                    AngularGradient(colors: [BL.gold, BL.cyan, BL.champagne, BL.burgundy, BL.gold],
                                    center: .center, angle: .degrees(motion ? 360 * FXClock.loop(tl.date, 14) : 0)),
                    lineWidth: 1.2)
            }
            .allowsHitTesting(false)
        )
        .shadow(color: BL.gold.opacity(0.18), radius: 8)
    }
}

// MARK: - Atmospheric backdrop (spec: HUD mesh + radial gold/burgundy washes on near-black).
struct PremiumBackdrop: View {
    var grid: Bool = true
    var body: some View {
        ZStack {
            BL.base.ignoresSafeArea()
            RadialGradient(colors: [Color(hex: 0x16130A).opacity(0.6), .clear], center: .topTrailing, startRadius: 0, endRadius: 760).ignoresSafeArea()
            RadialGradient(colors: [Color(hex: 0x120A0E).opacity(0.45), .clear], center: .bottomLeading, startRadius: 0, endRadius: 640).ignoresSafeArea()
            if grid { HUDGrid().opacity(0.9).ignoresSafeArea() }
        }
    }
}
#endif // circuit-convert
