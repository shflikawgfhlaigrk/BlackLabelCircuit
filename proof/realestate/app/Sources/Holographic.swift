// Black Label Real Estate — HOLOGRAPHIC PREMIUM FX KIT  (canonical reference implementation)
// ───────────────────────────────────────────────────────────────────────────────
// This is THE canonical FX kit; the other four Black Label apps mirror it and tune only their
// per-app accent. It reads this app's `BL.*` / `BLFont.*` (owned by Premium.swift) and `\.blMotion`.
//
// Everything here is PURELY VISUAL — no data, no Utah, no fabricated values. Every component
// reads a live `HoloTheme` (never a hardcoded intensity), so the buyer's Theme / Appearance
// Studio choices re-skin the entire app instantly. All continuous motion is gated behind
// `\.blMotion` (the in-app Motion toggle AND system Reduce Motion) and additionally scaled by
// the theme's Motion Level — Reduce Motion always hard-overrides to a gorgeous static fallback.
//
// CURSOR SPECULAR: REMOVED (explicit owner feedback — the old cursor-following white/radial
// sheen caused blur over card content). There is NO cursor specular anywhere in this kit and no
// Theme Studio control for one. CURSOR 3D TILT: DEFAULTS OFF (same reason — its perspective
// transform softened card text). Default hover feel = iridescent border + glow + lift only. Tilt
// is opt-in via the Theme Studio "Card 3D tilt" toggle; when off, NO rotation3DEffect is inserted.
//
// Perf contract: 60fps, GPU-light. Canvas/TimelineView for living layers, `.drawingGroup()`
// on particle/aurora canvases, particle counts capped, no full-window heavy blur loops.
//
// Components:
//   AuroraBackdrop            living animated background (drifting blobs / starfield / solid)
//   .holoCard()               signature surface: iridescent border + glow + pointer 3D tilt (NO specular)
//   .holoSheen()              moving diagonal iridescent light sweep over any surface
//   FoilText                  metallic/holographic headline text (gradient + sheen + glow)
//   ParticleField             drifting gold motes (Canvas, capped, parallax)
//   AnimatedCounter           numbers roll/transition on change (.numericText)
//   IridescentBorder          animated rim-light for CTAs / selected states
//   GlowPulse                 soft pulsing glow on the primary action
//   HoloShimmerSkeleton       holographic loading shimmer (never a spinner)
//   ParallaxLayer             depth: layers move at different rates on pointer
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// NOTE (Real Estate): the canonical palette/font/motion API this kit reads — `BL.*`, `BLFont.*`,
// and the `\.blMotion` environment value — is owned by this app's Premium.swift. The kit does NOT
// redeclare them here. (A cross-app kit sync once dropped Marketing's shim copies of enum BL /
// enum BLFont / BLMotionKey into this file; they collided with Premium.swift's definitions and broke
// the build. Those live in Premium.swift ONLY — this file just uses them.)

// MARK: - HoloTheme  (the single live model every FX component reads)
// Pure value type. Persisted in this app's settings store (Prefs). Drives intensity/motion/
// particles/background. NO specular field — the cursor specular is removed from this app.

/// Holographic intensity — scales border iridescence, sheen and glow strength.
enum HoloIntensity: String, Codable, CaseIterable, Identifiable {
    case off, subtle, balanced, full
    var id: String { rawValue }
    var label: String { self == .off ? "Off" : rawValue.capitalized }
    /// 0 → no FX (flat premium), 1 → full holographic. Used as a master multiplier.
    var scale: Double { switch self { case .off: return 0; case .subtle: return 0.45; case .balanced: return 0.75; case .full: return 1.0 } }
}

/// Motion level — scales drift speed / breathing / particle motion. Reduce Motion still hard-overrides.
enum HoloMotion: String, Codable, CaseIterable, Identifiable {
    case off, calm, lively
    var id: String { rawValue }
    var label: String { self == .off ? "Off" : rawValue.capitalized }
    /// Speed multiplier (higher = faster). 0 disables continuous loops.
    var speed: Double { switch self { case .off: return 0; case .calm: return 0.7; case .lively: return 1.35 } }
}

/// Living background style.
enum HoloBackground: String, Codable, CaseIterable, Identifiable {
    case aurora, starfield, solid
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// The persisted holographic look. Every FX component reads this — no hardcoded intensities.
struct HoloTheme: Codable, Hashable {
    // Accent — a stored hex so a custom color picker works (presets set these too).
    var accentHex: UInt32 = 0xC9A961      // gold (spec default — matches BLAccent.goldTriple)
    var accentHiHex: UInt32 = 0xF9E27D    // glint highlight
    var accentDimHex: UInt32 = 0x8A7340   // dim
    /// Secondary iridescent hue used in borders/sheens (cyan by default for the holo shimmer).
    var iridescentHex: UInt32 = 0x4FD7FF

    var intensity: HoloIntensity = .balanced
    var motion: HoloMotion = .calm
    var background: HoloBackground = .aurora

    var particleDensity: Double = 0.5     // 0 → off, 1 → max (capped to PARTICLE_CAP)
    // Cursor 3D tilt DEFAULTS OFF. Owner feedback: the pointer-tracked rotation3DEffect
    // perspective transform softened/blurred card text as the mouse moved. Off here means the
    // HoloCard body inserts NO rotation3DEffect modifier at all (not .degrees(0)) → zero text
    // softening. Hover lift/shadows/border still react. Opt-in via the Theme Studio "Card tilt".
    var tiltEnabled: Bool = false
    var tiltStrength: Double = 0.6        // 0 → flat, 1 → strong 3D (only when tiltEnabled)
    var glowStrength: Double = 0.6        // 0 → none, 1 → strong gold glow

    // Forgiving Codable: a saved settings snapshot from before a field existed must still load — each key
    // falls back to the struct's default rather than failing the whole decode. (An older save may
    // carry a now-removed `specularStrength` key from another app; an unknown key is simply
    // ignored on decode, so cross-app presets remain loadable.)
    private enum CodingKeys: String, CodingKey {
        case accentHex, accentHiHex, accentDimHex, iridescentHex, intensity, motion, background
        case particleDensity, tiltEnabled, tiltStrength, glowStrength
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var t = HoloTheme()   // start from defaults, override only what's present
        t.accentHex        = try c.decodeIfPresent(UInt32.self, forKey: .accentHex)        ?? t.accentHex
        t.accentHiHex      = try c.decodeIfPresent(UInt32.self, forKey: .accentHiHex)      ?? t.accentHiHex
        t.accentDimHex     = try c.decodeIfPresent(UInt32.self, forKey: .accentDimHex)     ?? t.accentDimHex
        t.iridescentHex    = try c.decodeIfPresent(UInt32.self, forKey: .iridescentHex)    ?? t.iridescentHex
        t.intensity        = try c.decodeIfPresent(HoloIntensity.self, forKey: .intensity) ?? t.intensity
        t.motion           = try c.decodeIfPresent(HoloMotion.self, forKey: .motion)       ?? t.motion
        t.background       = try c.decodeIfPresent(HoloBackground.self, forKey: .background) ?? t.background
        t.particleDensity  = try c.decodeIfPresent(Double.self, forKey: .particleDensity)  ?? t.particleDensity
        t.tiltEnabled      = try c.decodeIfPresent(Bool.self, forKey: .tiltEnabled)        ?? t.tiltEnabled
        t.tiltStrength     = try c.decodeIfPresent(Double.self, forKey: .tiltStrength)     ?? t.tiltStrength
        t.glowStrength     = try c.decodeIfPresent(Double.self, forKey: .glowStrength)     ?? t.glowStrength
        self = t
    }
    /// Memberwise-style init kept available since a custom init() suppresses the synthesized one.
    init(accentHex: UInt32 = 0xC9A961, accentHiHex: UInt32 = 0xF9E27D, accentDimHex: UInt32 = 0x8A7340,
         iridescentHex: UInt32 = 0x4FD7FF, intensity: HoloIntensity = .balanced, motion: HoloMotion = .calm,
         background: HoloBackground = .aurora, particleDensity: Double = 0.5, tiltEnabled: Bool = false,
         tiltStrength: Double = 0.6, glowStrength: Double = 0.6) {
        self.accentHex = accentHex; self.accentHiHex = accentHiHex; self.accentDimHex = accentDimHex
        self.iridescentHex = iridescentHex; self.intensity = intensity; self.motion = motion
        self.background = background; self.particleDensity = particleDensity; self.tiltEnabled = tiltEnabled
        self.tiltStrength = tiltStrength; self.glowStrength = glowStrength
    }

    // Convenience computed colors.
    var accent: Color { Color(hex: accentHex) }
    var accentHi: Color { Color(hex: accentHiHex) }
    var accentDim: Color { Color(hex: accentDimHex) }
    var iridescent: Color { Color(hex: iridescentHex) }

    /// The iridescent sweep stops used by borders/foil: accent → highlight → iridescent → accent.
    var spectrum: [Color] { [accent, accentHi, iridescent, accentHi, accent] }

    /// Max particles this theme requests (capped). Off when intensity is off or density 0.
    var particleCount: Int {
        guard intensity != .off, particleDensity > 0 else { return 0 }
        return Int((particleDensity * Double(HoloTheme.PARTICLE_CAP)).rounded())
    }
    /// Effective FX strength after intensity scaling (0…1). 0 = flat fallback.
    var fxScale: Double { intensity.scale }
    /// Effective continuous-motion speed (0 = no loops). Caller still gates on \.blMotion.
    func motionSpeed(reduceMotion: Bool, toggleOn: Bool) -> Double {
        (reduceMotion || !toggleOn) ? 0 : motion.speed
    }

    static let PARTICLE_CAP = 56          // hard ceiling for ParticleField

    // MARK: Presets — one-click named looks.
    // NOTE: every preset ships with tiltEnabled:false — the cursor 3D tilt is opt-in only
    // (it softened card text). tiltStrength is preserved per-preset so opting in still feels right.
    static let goldVault = HoloTheme(accentHex: 0xC9A961, accentHiHex: 0xF9E27D, accentDimHex: 0x8A7340,
                                     iridescentHex: 0x4FD7FF, intensity: .balanced, motion: .calm,
                                     background: .aurora, particleDensity: 0.5, tiltEnabled: false,
                                     tiltStrength: 0.6, glowStrength: 0.6)
    static let platinum = HoloTheme(accentHex: 0xD8DBE0, accentHiHex: 0xFFFFFF, accentDimHex: 0x9AA0A8,
                                    iridescentHex: 0xBFD4FF, intensity: .subtle, motion: .calm,
                                    background: .aurora, particleDensity: 0.35, tiltEnabled: false,
                                    tiltStrength: 0.45, glowStrength: 0.4)
    static let aurora = HoloTheme(accentHex: 0x7DE2C3, accentHiHex: 0xBFF7E6, accentDimHex: 0x3E9C86,
                                  iridescentHex: 0x9C7DFF, intensity: .full, motion: .lively,
                                  background: .aurora, particleDensity: 0.7, tiltEnabled: false,
                                  tiltStrength: 0.7, glowStrength: 0.75)
    static let cyberNeon = HoloTheme(accentHex: 0x4FD7FF, accentHiHex: 0xA6F0FF, accentDimHex: 0x2E9BBF,
                                     iridescentHex: 0xFF5FE1, intensity: .full, motion: .lively,
                                     background: .starfield, particleDensity: 0.85, tiltEnabled: false,
                                     tiltStrength: 0.85, glowStrength: 0.9)
    static let midnight = HoloTheme(accentHex: 0x6F86FF, accentHiHex: 0xAFC0FF, accentDimHex: 0x44529E,
                                    iridescentHex: 0x9C7DFF, intensity: .subtle, motion: .calm,
                                    background: .solid, particleDensity: 0.2, tiltEnabled: false,
                                    tiltStrength: 0.4, glowStrength: 0.35)

    /// Named presets exposed in the Theme Studio (display name → theme).
    static let presets: [(name: String, theme: HoloTheme)] = [
        ("Gold Vault", .goldVault), ("Platinum", .platinum), ("Aurora", .aurora),
        ("Cyber Neon", .cyberNeon), ("Midnight", .midnight),
    ]

    /// The built-in preset name this theme exactly matches, if any (for highlighting in the UI).
    var matchingPresetName: String? { HoloTheme.presets.first { $0.theme == self }?.name }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// A user-saved custom holographic look (lives alongside the built-in presets).
struct HoloPreset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = "My Look"
    var theme: HoloTheme = .goldVault
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Live environment
// The FX kit reads the theme from the environment so any view can render with the buyer's look.
struct HoloThemeKey: EnvironmentKey { static let defaultValue = HoloTheme.goldVault }
#endif // circuit-convert
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension EnvironmentValues {
    var holoTheme: HoloTheme {
        get { self[HoloThemeKey.self] }
        set { self[HoloThemeKey.self] = newValue }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Color hex helpers (read a UInt32 back out for the picker round-trip).
extension Color {
    /// Best-effort sRGB hex of this color (for persisting a custom-picked accent).
    var holoHex: UInt32 {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.gray
        let r = UInt32((ns.redComponent * 255).rounded())
        let g = UInt32((ns.greenComponent * 255).rounded())
        let b = UInt32((ns.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - 1. AuroraBackdrop  (living animated background)
// Drifting blurred color blobs (Aurora), a parallax star Canvas (Starfield), or a calm solid.
// Driven by TimelineView(.animation) so it drifts forever, eased. Replaces flat backgrounds.
struct AuroraBackdrop: View {
    @Environment(\.holoTheme) private var theme
    @Environment(\.blMotion) private var motion
    var body: some View {
        ZStack {
            BL.base.ignoresSafeArea()
            switch theme.background {
            case .aurora:    auroraBlobs
            case .starfield: Starfield().ignoresSafeArea()
            case .solid:     solidWash
            }
            // Faint vignette for depth on every style.
            RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 320, endRadius: 900)
                .ignoresSafeArea().allowsHitTesting(false)
        }
        // FOOLPROOF CLICK-THROUGH: the ENTIRE backdrop (incl. the opaque BL.base Color and the
        // solidWash gradients, which are otherwise hit-testable) is click-transparent. Baked in
        // here at the root so this background can NEVER intercept a button click regardless of
        // where it is placed (it was eating clicks app-wide because the root ZStack was opaque to
        // hit testing while content sat in the same ZStack). Visuals are unchanged — purely visual.
        .allowsHitTesting(false)
    }
    private var speed: Double { theme.motion.speed == 0 || !motion ? 0 : theme.motion.speed }
    private var solidWash: some View {
        ZStack {
            RadialGradient(colors: [theme.accent.opacity(0.07 * theme.fxScale), .clear], center: .topTrailing, startRadius: 0, endRadius: 760).ignoresSafeArea()
            RadialGradient(colors: [theme.iridescent.opacity(0.05 * theme.fxScale), .clear], center: .bottomLeading, startRadius: 0, endRadius: 640).ignoresSafeArea()
        }
    }
    private var auroraBlobs: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: speed == 0 ? nil : 1.0/30.0, paused: speed == 0)) { tl in
                let t = speed == 0 ? 0 : tl.date.timeIntervalSinceReferenceDate * 0.05 * speed
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    blob(theme.accent,      0.22, base: CGPoint(x: 0.18, y: 0.20), t: t, p: 0.0, w: w, h: h, r: 320)
                    blob(theme.accentDim,   0.18, base: CGPoint(x: 0.82, y: 0.78), t: t, p: 1.7, w: w, h: h, r: 300)
                    blob(theme.iridescent,  0.14, base: CGPoint(x: 0.70, y: 0.22), t: t, p: 3.1, w: w, h: h, r: 260)
                    blob(theme.accentHi,    0.10, base: CGPoint(x: 0.30, y: 0.80), t: t, p: 4.6, w: w, h: h, r: 240)
                }
                .blur(radius: 90)
                .opacity(0.5 + 0.5 * theme.fxScale)
                .drawingGroup()              // GPU-composite the blurred layer
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
    @ViewBuilder private func blob(_ c: Color, _ op: Double, base: CGPoint, t: Double, p: Double, w: CGFloat, h: CGFloat, r: CGFloat) -> some View {
        let dx = CGFloat(cos(t + p)) * w * 0.06
        let dy = CGFloat(sin(t * 0.8 + p)) * h * 0.06
        Circle().fill(c.opacity(op * (0.6 + 0.4 * theme.fxScale)))
            .frame(width: r, height: r)
            .position(x: base.x * w + dx, y: base.y * h + dy)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Parallax star Canvas — capped points, drifts slowly, twinkles. GPU-light.
struct Starfield: View {
    @Environment(\.holoTheme) private var theme
    @Environment(\.blMotion) private var motion
    private let stars: [(CGPoint, CGFloat, Double)] = (0..<90).map { i in
        var g = SeededRNG(seed: UInt64(i) &* 2654435761)
        return (CGPoint(x: g.next01(), y: g.next01()), CGFloat(0.5 + g.next01() * 1.6), g.next01())
    }
    var body: some View {
        let speed = theme.motion.speed == 0 || !motion ? 0.0 : theme.motion.speed
        TimelineView(.animation(paused: speed == 0)) { tl in
            let t = speed == 0 ? 0 : tl.date.timeIntervalSinceReferenceDate * 0.04 * speed
            Canvas { ctx, size in
                for (p, rad, phase) in stars {
                    let y = (p.y + CGFloat(t * 0.02)).truncatingRemainder(dividingBy: 1.0)
                    let tw = 0.4 + 0.6 * abs(sin(t * 1.2 + phase * 6.28))
                    let rect = CGRect(x: p.x * size.width, y: y * size.height, width: rad, height: rad)
                    ctx.fill(Path(ellipseIn: rect), with: .color(theme.accentHi.opacity(0.5 * tw)))
                }
            }
            .drawingGroup()
        }
        .background(BL.base)
        .allowsHitTesting(false)
    }
}
#endif // circuit-convert

// Tiny deterministic RNG so the starfield/particles are stable across frames.
struct SeededRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    mutating func next01() -> CGFloat { CGFloat(Double(next() >> 11) / Double(1 << 53)) }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - 2. HoloCard  (the signature surface)
// .ultraThinMaterial + panel tint, iridescent animated border, layered shadow + gold glow,
// inner top highlight, and an OPT-IN pointer 3D tilt. Falls back to a gorgeous static card when
// motion is off. Reads HoloTheme for ALL intensities. Call-site API: `.holoCard(radius:sweep:)`.
//
// NO CURSOR SPECULAR. Owner feedback removed the cursor-following white/radial sheen because it
// blurred card content. CURSOR 3D TILT DEFAULTS OFF for the same reason (its perspective transform
// softened card text); when `theme.tiltEnabled` is false the body inserts NO rotation3DEffect at
// all. Default hover = iridescent border brightening + glow lift only.
struct HoloCard: ViewModifier {
    var radius: CGFloat
    var sweep: Bool
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    @State private var hover = false
    @State private var local: CGPoint = CGPoint(x: 0.5, y: 0.5)   // cursor position within the card (0…1) — TILT ONLY
    @State private var size: CGSize = .zero

    private var fx: Double { theme.fxScale }
    private var glow: Double { theme.glowStrength }
    private var tiltAmt: Double { theme.tiltEnabled ? theme.tiltStrength : 0 }

    func body(content: Content) -> some View {
        let live = motion && theme.motion.speed > 0
        // Everything through the hover scale/shadows — the card's static + hover-reactive surface.
        // The pointer 3D tilt is applied AFTER this, and ONLY when tiltEnabled (see `tilted`).
        let base = content
            .background(
                ZStack {
                    BL.glassFill
                    LinearGradient(colors: [Color.white.opacity(0.03), .clear], startPoint: .top, endPoint: .bottom)
                }.background(.ultraThinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            // Diagonal sheen sweep (pausable TimelineView — wall-clock phase, no repeatForever).
            .overlay {
                if sweep && fx > 0 {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { tl in
                        let sx = live ? -1.0 + 3.0 * FXClock.easeInOut(FXClock.loop(tl.date, 7 / max(0.3, theme.motion.speed))) : 2.0
                        GeometryReader { geo in
                            LinearGradient(colors: [.clear, theme.accentHi.opacity(0.0), theme.accentHi.opacity(0.5 * fx), Color.white.opacity(0.3 * fx), theme.accentHi.opacity(0.0), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.5)
                                .offset(x: sx * geo.size.width * 1.5)
                                .blendMode(.screen).allowsHitTesting(false)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    }
                    .allowsHitTesting(false)
                }
            }
            // Iridescent animated border (rotating AngularGradient) — or static gold when motion off.
            .overlay(
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live || fx <= 0)) { tl in
                    let a = live && fx > 0 ? 360 * FXClock.loop(tl.date, 18 / max(0.3, theme.motion.speed)) : 90
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(borderStyle(angle: .degrees(a)), lineWidth: 1)
                }
                .allowsHitTesting(false)
            )
            // Inner top highlight (subtle glass edge).
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                    .blendMode(.overlay).allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.5), radius: hover ? 28 : 22, x: 0, y: hover ? 16 : 12)
            .shadow(color: theme.accent.opacity((hover ? 0.22 : 0.12) * glow), radius: hover ? 34 : 28, x: 0, y: 0)
        // Gate the pointer 3D tilt: when OFF, NO rotation3DEffect is inserted at all (not .degrees(0)),
        // so SwiftUI adds no perspective transform layer → card text stays crisp under the cursor.
        // Hover lift/shadows/border above still react. KEEP everything else; tilt is opt-in.
        tilted(base)
            .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChangeCompat(of: g.size) { size = $0 } })
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    withAnimation(.easeOut(duration: 0.12)) { hover = true }
                    if size.width > 0, size.height > 0 { local = CGPoint(x: pt.x / size.width, y: pt.y / size.height) }
                case .ended:
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { hover = false; local = CGPoint(x: 0.5, y: 0.5) }
                }
            }
    }

    /// Apply the pointer-tracking 3D tilt ONLY when the theme opts in. When `tiltEnabled` is false
    /// the two `rotation3DEffect` modifiers are entirely ABSENT (not `.degrees(0)`), so SwiftUI
    /// inserts no perspective transform layer and card text is never softened by the cursor.
    @ViewBuilder private func tilted<V: View>(_ base: V) -> some View {
        if theme.tiltEnabled {
            base
                .rotation3DEffect(.degrees(hover ? (Double(local.y) - 0.5) * -7 * tiltAmt : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                .rotation3DEffect(.degrees(hover ? (Double(local.x) - 0.5) *  7 * tiltAmt : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        } else {
            base   // no rotation3DEffect at all → no perspective layer → crisp text
        }
    }

    private func borderStyle(angle: Angle) -> AnyShapeStyle {
        if fx <= 0 { return AnyShapeStyle(LinearGradient(colors: [theme.accent.opacity(0.28), BL.hair2.opacity(0.7)], startPoint: .top, endPoint: .bottom)) }
        let a = angle
        return AnyShapeStyle(AngularGradient(
            colors: [theme.accent.opacity(0.5 * fx), theme.iridescent.opacity(0.45 * fx), theme.accentHi.opacity(0.55 * fx),
                     theme.accentDim.opacity(0.35 * fx), theme.accent.opacity(0.5 * fx)],
            center: .center, angle: a))
    }
}
#endif // circuit-convert
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension View {
    /// Apply the signature holographic card surface. API is stable across the suite.
    func holoCard(radius: CGFloat = 16, sweep: Bool = true) -> some View {
        modifier(HoloCard(radius: radius, sweep: sweep))
    }
}
#endif // circuit-convert

// MARK: - FXClock  (wall-clock phases for TimelineView-driven FX loops)
// Every continuous FX loop is driven by a pausable TimelineView computing its phase from the
// wall clock — NEVER by `withAnimation(.repeatForever)` on @State. A running repeatForever
// cannot be cancelled: re-assigning the value (plainly or via a zero-duration withAnimation)
// leaves the animation attached, and the layer keeps re-rasterizing every frame even when the
// rendered output is frozen (measured 2026-07-03: ~40% CPU while DEACTIVATED, conic border
// stroke hot in the sample). A TimelineView with `paused: true` provably stops ticking (0.0%).
// Wall-clock phases also mean no per-view start bookkeeping — loops stay in step for free.
enum FXClock {
    /// 0→1 sawtooth with the given period (seconds).
    static func loop(_ date: Date, _ period: Double) -> Double {
        let per = max(0.001, period)
        let p = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: per) / per
        return p < 0 ? p + 1 : p
    }
    /// 0→1→0 triangle, `period` seconds each way (the old autoreverse loops).
    static func pingPong(_ date: Date, _ period: Double) -> Double {
        let p = loop(date, period * 2)
        return p < 0.5 ? p * 2 : 2 - p * 2
    }
    /// Standard easeInOut, matching the feel of the old .easeInOut sweep loops.
    static func easeInOut(_ p: Double) -> Double { p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2 }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - 3. HoloSheen  (moving diagonal iridescent light sweep over any surface/text)
struct HoloSheen: ViewModifier {
    var angle: Double
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    func body(content: Content) -> some View {
        let fx = theme.fxScale
        let live = motion && theme.motion.speed > 0
        content.overlay {
            if fx > 0 {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { tl in
                    let x = live ? -1.2 + 3.2 * FXClock.easeInOut(FXClock.loop(tl.date, 4.5 / max(0.4, theme.motion.speed))) : 2.0
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Color.white.opacity(0.0), theme.accentHi.opacity(0.55 * fx), Color.white.opacity(0.35 * fx), theme.iridescent.opacity(0.0), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: x * geo.size.width * 1.6)
                            .rotationEffect(.degrees(angle))
                            .blendMode(.screen).allowsHitTesting(false)
                    }
                    .mask(content)
                }
                .allowsHitTesting(false)
            }
        }
    }
}
#endif // circuit-convert
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension View {
    /// Moving iridescent light sweep across this view. Use on hero panels, primary buttons, logos.
    func holoSheen(angle: Double = 18) -> some View { modifier(HoloSheen(angle: angle)) }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - 4. FoilText  (metallic / holographic headline text)
struct FoilText: View {
    let text: String
    var size: CGFloat = 30
    var weight: Font.Weight = .semibold
    var serif: Bool = true
    init(_ text: String, size: CGFloat = 30, weight: Font.Weight = .semibold, serif: Bool = true) {
        self.text = text; self.size = size; self.weight = weight; self.serif = serif
    }
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    private var font: Font { serif ? BLFont.display(size, weight) : BLFont.body(size, weight) }
    var body: some View {
        let fx = theme.fxScale
        let live = motion && theme.motion.speed > 0 && fx > 0
        let stops = [theme.accentHi, theme.accent, theme.iridescent, theme.accentHi, theme.accent]
        Text(text)
            .font(font)
            .foregroundStyle(LinearGradient(colors: [theme.accentHi, theme.accent, theme.accentDim], startPoint: .top, endPoint: .bottom))
            .overlay(
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { tl in
                    let phase = live ? -1 + 2 * FXClock.pingPong(tl.date, 16 / max(0.4, theme.motion.speed)) : 0
                    GeometryReader { geo in
                        LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 2.2)
                            .offset(x: phase * geo.size.width * 1.2)
                            .opacity(fx)
                    }
                    .mask(Text(text).font(font))
                }
                .blendMode(.screen)
                .allowsHitTesting(false)   // decorative foil sweep must never swallow clicks on a heading
            )
            // LEGIBILITY: keep the foil glow MINIMAL and CRISP so heading edges stay sharp.
            // FoilText is for LARGE display headings only; a soft wide glow fuzzed edges, so the
            // radius/opacity are pulled down to a tight rim rather than a halo.
            .shadow(color: theme.accent.opacity(0.16 * theme.glowStrength), radius: 4, y: 1)
            .accessibilityLabel(text)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - 5. ParticleField  (drifting gold motes, Canvas, capped, parallax to pointer)
struct ParticleField: View {
    @Environment(\.holoTheme) private var theme
    @Environment(\.blMotion) private var motion
    @State private var px: CGFloat = 0.5            // pointer parallax (0…1)
    @State private var py: CGFloat = 0.5
    private struct Mote { var x, y, r, vx, vy, phase: CGFloat }
    private var motes: [Mote] {
        let n = theme.particleCount
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            var g = SeededRNG(seed: UInt64(i) &* 0x100000001B3)
            return Mote(x: g.next01(), y: g.next01(), r: 0.6 + g.next01() * 2.2,
                        vx: (g.next01() - 0.5) * 0.6, vy: -0.2 - g.next01() * 0.5, phase: g.next01())
        }
    }
    var body: some View {
        let speed = theme.motion.speed == 0 || !motion ? 0.0 : theme.motion.speed
        let list = motes
        // FOOLPROOF CLICK-THROUGH: the whole field (both the empty `Color.clear` branch AND the
        // animated Canvas branch with its parallax .onContinuousHover) is click-transparent. Baked
        // in at the root so this drifting-motes layer can NEVER intercept a button click no matter
        // where it is placed. The `.onContinuousHover` is a passive observer (no opaque hit-target)
        // and the root `.allowsHitTesting(false)` makes the entire layer ignore pointer events.
        Group {
            if list.isEmpty {
                Color.clear
            } else {
                TimelineView(.animation(paused: speed == 0)) { tl in
                    let t = speed == 0 ? 0 : tl.date.timeIntervalSinceReferenceDate * speed
                    Canvas { ctx, size in
                        for m in list {
                            let driftY = (m.y - CGFloat(t * 0.02) * abs(m.vy)).truncatingRemainder(dividingBy: 1.0)
                            let y = driftY < 0 ? driftY + 1 : driftY
                            let x = (m.x + CGFloat(sin(t * 0.3 + m.phase * 6.28)) * 0.01 * m.vx + (px - 0.5) * 0.03)
                            let tw = 0.35 + 0.65 * abs(sin(t * 0.8 + m.phase * 6.28))
                            let rect = CGRect(x: x * size.width, y: y * size.height, width: m.r * 2, height: m.r * 2)
                            ctx.fill(Path(ellipseIn: rect), with: .color(theme.accentHi.opacity(0.5 * tw * theme.fxScale)))
                        }
                    }
                    .drawingGroup()
                }
                .onContinuousHover { phase in
                    if case .active(let pt) = phase {
                        // Light parallax only — cheap.
                        withAnimation(.easeOut(duration: 0.4)) { px = max(0, min(1, pt.x / 1000)); py = max(0, min(1, pt.y / 1000)) }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - 6. AnimatedCounter  (numbers roll/transition on change)
struct AnimatedCounter: View {
    let value: Double
    var format: (Double) -> String = { String(Int($0)) }
    var font: Font = .blSystem(size: 28, weight: .heavy, design: .rounded)
    @Environment(\.blMotion) private var motion
    var body: some View {
        let base = Text(format(value)).font(font).monospacedDigit()
        Group {
            if #available(macOS 14.0, *) {
                base.contentTransition(.numericText(value: value))
            } else {
                base.contentTransition(.numericText())   // macOS 13: rolls on any change
            }
        }
        .animation(motion ? .spring(response: 0.5, dampingFraction: 0.85) : nil, value: value)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - 7. IridescentBorder / GlowPulse  (CTA + selected-state rim-light)
struct IridescentBorder: ViewModifier {
    var radius: CGFloat = 12
    var lineWidth: CGFloat = 1.4
    var active: Bool = true
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    func body(content: Content) -> some View {
        let fx = theme.fxScale
        let live = motion && theme.motion.speed > 0 && active && fx > 0
        content.overlay(
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { tl in
                let phase = live ? FXClock.loop(tl.date, 6 / max(0.4, theme.motion.speed)) : 0
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(active && fx > 0
                        ? AnyShapeStyle(AngularGradient(colors: theme.spectrum, center: .center, angle: .degrees(phase * 360)))
                        : AnyShapeStyle(theme.accent.opacity(active ? 0.5 : 0.0)), lineWidth: lineWidth)
            }
            .allowsHitTesting(false)   // decorative rim — must never block the CTA it decorates
        )
    }
}
#endif // circuit-convert
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension View { func iridescentBorder(radius: CGFloat = 12, lineWidth: CGFloat = 1.4, active: Bool = true) -> some View { modifier(IridescentBorder(radius: radius, lineWidth: lineWidth, active: active)) } }
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct GlowPulse: ViewModifier {
    var color: Color? = nil
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    func body(content: Content) -> some View {
        let c = color ?? theme.accent
        let live = motion && theme.motion.speed > 0
        // Glow breathes at 12fps — the shadow wraps the content, so the timeline is capped low
        // to keep the per-tick re-render cheap; a 2.4s soft pulse is smooth well below 30fps.
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !live)) { tl in
            let k = live ? FXClock.easeInOut(FXClock.pingPong(tl.date, 2.4 / max(0.4, theme.motion.speed))) : 0
            content.shadow(color: c.opacity((0.25 + 0.30 * k) * theme.glowStrength), radius: 10 + 8 * k)
        }
    }
}
#endif // circuit-convert
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension View { func glowPulse(_ color: Color? = nil) -> some View { modifier(GlowPulse(color: color)) } }
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - 8. HoloShimmerSkeleton  (loading state = moving holographic gradient)
struct HoloShimmerSkeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var radius: CGFloat = 7
    @Environment(\.blMotion) private var motion
    @Environment(\.holoTheme) private var theme
    var body: some View {
        let live = motion && theme.motion.speed > 0
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(BL.bg2v)
            .frame(width: width, height: height)
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { tl in
                    let x = live ? -1 + 3 * FXClock.loop(tl.date, 1.4 / max(0.4, theme.motion.speed)) : 0.2
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, theme.accent.opacity(0.28), theme.accentHi.opacity(0.4), theme.accent.opacity(0.28), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: x * geo.size.width * 1.6)
                            .blendMode(.screen)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// A multi-line shimmering skeleton block — drop-in "loading" centerpiece for any screen.
struct HoloSkeletonBlock: View {
    var lines: Int = 4
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HoloShimmerSkeleton(width: 180, height: 20, radius: 8)
            ForEach(0..<max(1, lines), id: \.self) { i in
                HoloShimmerSkeleton(width: i == lines - 1 ? 160 : nil, height: 13)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - 9. ParallaxLayer  (depth: layers move at different rates on pointer)
struct ParallaxLayer<Content: View>: View {
    var depth: CGFloat = 12      // px of travel at the edges
    @ViewBuilder var content: () -> Content
    @Environment(\.blMotion) private var motion
    @State private var off: CGSize = .zero
    var body: some View {
        content()
            .offset(off)
            .onContinuousHover { phase in
                guard motion else { return }
                if case .active(let pt) = phase {
                    withAnimation(.easeOut(duration: 0.35)) {
                        off = CGSize(width: (pt.x.truncatingRemainder(dividingBy: 600)/600 - 0.5) * depth,
                                     height: (pt.y.truncatingRemainder(dividingBy: 600)/600 - 0.5) * depth)
                    }
                } else { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { off = .zero } }
            }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Premium asymmetric screen transition (slide + crossfade) used app-wide.
// Content never blurs: slide (.move) + crossfade (.opacity) only.
extension AnyTransition {
    static var holoScreen: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity))
    }
}
#endif // circuit-convert
