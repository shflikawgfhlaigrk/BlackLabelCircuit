#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Premium / Holographic design layer.
// Translates the storefront's blb-* CSS techniques into native SwiftUI:
// shimmer headlines, animated gold border-pulse, sheen sweep, gold glow,
// drifting HUD grid, conic-foil premium badges. All free / own-it.
// Motion honors the system Reduce-Motion accessibility setting AND the in-app
// Settings toggle (Prefs.motionEnabled), per the spec.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreText) && !CIRCUIT_WINDOWS_SIM
import CoreText
#endif

// MARK: - Font registration (bundled OFL fonts — Cormorant Garamond + JetBrains Mono)

enum BLFonts {
    /// True once the bundled OFL fonts are registered with CoreText.
    private(set) static var cormorantAvailable = false
    private(set) static var jetBrainsAvailable = false

    static let cormorantFamily = "Cormorant Garamond"
    static let jetBrainsFamily = "JetBrains Mono"

    /// Register the bundled variable fonts. Safe to call repeatedly. Falls back
    /// silently to system serif / mono if a font is missing (spec-sanctioned).
    static func register() {
        cormorantAvailable = registerOne("CormorantGaramond", family: cormorantFamily)
        jetBrainsAvailable = registerOne("JetBrainsMono", family: jetBrainsFamily)
    }

    private static func registerOne(_ resource: String, family: String) -> Bool {
        // Already installed on the system?
        if NSFontManager.shared.availableFontFamilies.contains(family) { return true }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf",
                                        subdirectory: "Fonts")
              ?? Bundle.main.url(forResource: resource, withExtension: "ttf") else { return false }
        var err: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
        if !ok, let e = err?.takeUnretainedValue() {
            // "already registered" is a success for our purposes.
            let code = CFErrorGetCode(e)
            if code == CTFontManagerError.alreadyRegistered.rawValue { return true }
            return false
        }
        return ok
    }

    /// Cormorant Garamond at a given size/weight, or New York serif fallback.
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if cormorantAvailable { return .custom(cormorantFamily, size: size).weight(weight) }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// JetBrains Mono at a given size, or SF Mono fallback.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if jetBrainsAvailable { return .custom(jetBrainsFamily, size: size).weight(weight) }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Motion preference (system Reduce-Motion OR in-app toggle disables fx)

/// Single source of truth for "should ambient motion run?". Reads the in-app
/// Prefs toggle; the system accessibility setting is honored at the call site
/// via @Environment(\.accessibilityReduceMotion).
struct MotionGate {
    static func ambientEnabled(systemReduceMotion: Bool, prefMotion: Bool) -> Bool {
        !systemReduceMotion && prefMotion
    }
}

// MARK: - Premium palette (exact spec hex)

extension BLTheme {
    static let champagne   = Color(hex: 0xD4C5A0)
    static let champagneHi = Color(hex: 0xE8E6E1)
    static let burgundy    = Color(hex: 0x8B3A4A)
    static let burgundyDeep = Color(hex: 0x6B2D3E)
    static let holoCyan    = Color(hex: 0x4FD7FF)
    static let inkBase     = Color(hex: 0x050505)   // deepest spec background

    /// Holographic headline gradient: gold → champagne → cyan → gold.
    static var holoText: [Color] { [gold, champagne, holoCyan, champagne, gold] }
}

// MARK: - Shimmer (holographic) headline — fx-holo-text

/// A headline whose fill is a slowly moving multi-stop gradient
/// (gold→champagne→cyan→gold), ~20s shimmer. Falls back to a static gold
/// gradient under reduced motion.
struct ShimmerText: View {
    let text: String
    var size: CGFloat = 26
    var weight: Font.Weight = .semibold
    var serif: Bool = true
    @Environment(\.blMotion) private var blMotion   // pref + Reduce Motion + app-active, injected at root

    private var animate: Bool { blMotion }

    var body: some View {
        let font: Font = serif ? BLFonts.display(size, weight: weight)
                                : .system(size: size, weight: weight, design: .rounded)
        Text(text)
            .font(font)
            .overlay(
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animate)) { tl in
                    let phase = -1 + 0.9 * FXClock.pingPong(tl.date, 20)
                    GeometryReader { geo in
                        LinearGradient(colors: BLTheme.holoText, startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 3)
                            .offset(x: animate ? phase * geo.size.width : -geo.size.width * 0.4)
                    }
                    .mask(Text(text).font(font))
                    .allowsHitTesting(false)   // decorative shimmer must never swallow clicks
                }
            )
            .foregroundStyle(.clear)
            .shadow(color: BLTheme.gold.opacity(0.22), radius: 10)
    }
}

// MARK: - Drifting HUD grid background — fx-holo-grid

/// A faint ~48px grid that slowly drifts behind hero areas. Very low opacity.
struct HUDGrid: View {
    var spacing: CGFloat = 48
    var opacity: Double = 0.05
    @Environment(\.blMotion) private var blMotion

    private var animate: Bool { blMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animate)) { tl in
            let drift = animate ? spacing * FXClock.loop(tl.date, 26) : 0
            Canvas { ctx, size in
                var path = Path()
                let dx = drift, dy = drift * 0.7
                var x = -spacing + dx.truncatingRemainder(dividingBy: spacing)
                while x < size.width { path.move(to: .init(x: x, y: 0)); path.addLine(to: .init(x: x, y: size.height)); x += spacing }
                var y = -spacing + dy.truncatingRemainder(dividingBy: spacing)
                while y < size.height { path.move(to: .init(x: 0, y: y)); path.addLine(to: .init(x: size.width, y: y)); y += spacing }
                ctx.stroke(path, with: .color(BLTheme.gold.opacity(opacity)), lineWidth: 0.6)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Premium glass card — fx-holo-card + border-pulse + sheen sweep

/// Dark glass card with a 1px gold border that pulses (0.16↔0.32, ~9s),
/// a periodic light sheen-sweep, and a soft gold glow. Hover lifts + brightens.
struct GlassCard<Content: View>: View {
    var radius: CGFloat = 16
    var sweep: Bool = true
    @ViewBuilder var content: () -> Content

    @Environment(\.blMotion) private var blMotion
    @State private var hover = false

    private var animate: Bool { blMotion }

    var body: some View {
        content()
            .background(
                ZStack {
                    // Glass fill — rgba(8,12,18,0.62) tinted material.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(.sRGB, red: 8/255, green: 12/255, blue: 18/255, opacity: 0.62))
                        .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                    // Sheen sweep — a soft gold/white band traveling left→right.
                    if sweep && animate {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { tl in
                            let sx = -1 + 2 * FXClock.easeInOut(FXClock.loop(tl.date, 7))
                            GeometryReader { geo in
                                LinearGradient(
                                    stops: [.init(color: .clear, location: 0),
                                            .init(color: Color.white.opacity(0.10), location: 0.45),
                                            .init(color: BLTheme.gold.opacity(0.18), location: 0.5),
                                            .init(color: Color.white.opacity(0.10), location: 0.55),
                                            .init(color: .clear, location: 1)],
                                    startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.6)
                                .offset(x: sx * geo.size.width * 1.6)
                                .blur(radius: 6)
                            }
                            .mask(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        }
                        .allowsHitTesting(false)
                    }
                }
            )
            .overlay(
                // Border pulse at 12fps — a 9s-each-way breathe needs no more.
                TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !animate || hover)) { tl in
                    let k = animate ? FXClock.easeInOut(FXClock.pingPong(tl.date, 9)) : 0
                    let borderOpacity = hover ? 0.46 : (animate ? 0.16 + 0.16 * k : 0.24)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(BLTheme.gold.opacity(borderOpacity), lineWidth: 1)
                }
            )
            .shadow(color: BLTheme.gold.opacity(hover ? 0.26 : 0.14), radius: hover ? 24 : 18, y: 8)
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            .offset(y: hover ? -2 : 0)
            .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hover = h } }
    }
}

// MARK: - Conic foil premium badge

/// Iridescent conic-gradient badge (gold→cyan→champagne→gold) for premium marks.
struct FoilBadge: View {
    let text: String
    var icon: String = "seal.fill"
    @Environment(\.blMotion) private var blMotion
    private var animate: Bool { blMotion }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
            Text(text.uppercased()).font(BLFonts.mono(9.5, weight: .bold)).tracking(1.0)
        }
        .foregroundColor(BLTheme.inkOnGold)
        .padding(.vertical, 4).padding(.horizontal, 9)
        .background(
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { tl in
                AngularGradient(colors: [BLTheme.gold, BLTheme.holoCyan, BLTheme.champagne, BLTheme.gold],
                                center: .center, angle: .degrees(animate ? 360 * FXClock.loop(tl.date, 12) : 0))
            }
        )
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.6))
        .shadow(color: BLTheme.gold.opacity(0.35), radius: 8, y: 2)
    }
}
#endif // circuit-convert
