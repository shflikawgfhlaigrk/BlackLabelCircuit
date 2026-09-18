#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — Holographic Premium FX kit. The canonical, reusable surface language for the
// whole Black Label suite (same API in every app): AuroraBackdrop, .holoCard(), .holoSheen(),
// FoilText, ParticleField, AnimatedCounter, IridescentBorder, GlowPulse, HoloShimmerSkeleton,
// ParallaxLayer. EVERY component reads the live `HoloTheme` from the environment — no hardcoded
// intensities — so the buyer's Theme Studio retunes the entire app instantly.
//
// Hard constraints honored here:
//   • 60fps / GPU-light: Canvas + TimelineView, particle counts capped via HoloTheme.particleCount,
//     drawingGroup() on the heavy layers, no huge blur over full-window content.
//   • Reduce Motion + the in-app Motion Level + the global motion toggle all fold into
//     `theme.animates`; static fallback keeps gradients/foil/shadows (still premium) and stops loops.
//   • Purely visual. No data, no fabricated values, no network. Nothing baked in.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Live theme in the environment (set once by RootView; read everywhere)
private struct HoloThemeKey: EnvironmentKey {
    static let defaultValue = HoloTheme()   // safe defaults until RootView injects the live one
}
extension EnvironmentValues {
    var holoTheme: HoloTheme {
        get { self[HoloThemeKey.self] }
        set { self[HoloThemeKey.self] = newValue }
    }
}
extension View {
    /// Inject the live theme the whole FX kit reads.
    func holoTheme(_ t: HoloTheme) -> some View { environment(\.holoTheme, t) }
}

// MARK: - AuroraBackdrop — living background (drifting blurred blobs + faint grain + vignette)
/// Replaces flat backgrounds app-wide. Style honors `theme.background`:
///   .aurora    → 4 slow-drifting iridescent blobs over the deep base
///   .starfield → a capped twinkling star canvas
///   .solid     → just the deep base + vignette (still premium, fully static)
struct AuroraBackdrop: View {
    @Environment(\.holoTheme) private var theme
    var body: some View {
        ZStack {
            BLTheme.bg
            switch theme.background {
            case .aurora:   auroraBlobs
            case .starfield: Starfield()
            case .solid:    EmptyView()
            }
            vignette
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var auroraBlobs: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0, paused: !theme.animates)) { tl in
            let t = theme.animates ? tl.date.timeIntervalSinceReferenceDate * 0.05 * theme.driftSpeed : 0
            Canvas { ctx, size in
                ctx.addFilter(.blur(radius: 90))
                let blobs: [(Color, Double, Double, Double)] = [
                    (theme.accent,            0.20, 0.18, 0.30),
                    (BLTheme.burgundy,        0.70, 0.30, 0.24),
                    (theme.secondary,         0.40, 0.78, 0.22),
                    (BLTheme.goldHi,          0.85, 0.70, 0.20)
                ]
                for (i, b) in blobs.enumerated() {
                    let ph = Double(i) * 1.7 + t
                    let cx = (b.1 + 0.10 * sin(ph)) * size.width
                    let cy = (b.2 + 0.10 * cos(ph * 0.8)) * size.height
                    let r  = min(size.width, size.height) * 0.42
                    let rect = CGRect(x: cx - r, y: cy - r, width: r*2, height: r*2)
                    let g = Gradient(colors: [b.0.opacity(b.3 * max(0.5, theme.fxScale)), .clear])
                    ctx.fill(Path(ellipseIn: rect),
                             with: .radialGradient(g, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r))
                }
            }
            .drawingGroup()
        }
    }

    private var vignette: some View {
        RadialGradient(colors: [.clear, .black.opacity(0.42)], center: .center, startRadius: 220, endRadius: 760)
    }
}

/// Capped twinkling starfield (used by the .starfield background). GPU-light Canvas, deterministic seed.
struct Starfield: View {
    @Environment(\.holoTheme) private var theme
    private let stars: [(CGPoint, Double, Double)] = (0..<120).map { i in
        var s = UInt64(i &* 2654435761 &+ 12345)
        func rnd() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 33) / Double(UInt64(1) << 31) }
        return (CGPoint(x: rnd(), y: rnd()), rnd() * 1.6 + 0.4, rnd())
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/20.0, paused: !theme.animates)) { tl in
            let t = theme.animates ? tl.date.timeIntervalSinceReferenceDate * theme.driftSpeed : 0
            Canvas { ctx, size in
                for (p, r, seed) in stars {
                    let tw = 0.5 + 0.5 * sin(t * 1.3 + seed * 6.28)
                    let alpha = (0.25 + 0.6 * tw) * max(0.4, theme.fxScale)
                    let c = seed > 0.7 ? theme.secondary : theme.accent
                    let rect = CGRect(x: p.x * size.width, y: p.y * size.height, width: r, height: r)
                    ctx.fill(Path(ellipseIn: rect), with: .color(c.opacity(alpha)))
                }
            }.drawingGroup()
        }
        .allowsHitTesting(false)   // purely-decorative star canvas: can NEVER eat clicks, regardless of placement
    }
}

// MARK: - ParticleField — drifting motes behind content (Canvas, capped, pointer parallax)
struct ParticleField: View {
    @Environment(\.holoTheme) private var theme
    var tint: Color? = nil
    @State private var pointer: CGPoint = .zero

    private struct Mote { var x: Double; var y: Double; var vx: Double; var vy: Double; var r: Double; var seed: Double }
    @State private var motes: [Mote] = []

    var body: some View {
        GeometryReader { geo in
            let count = theme.particleCount
            TimelineView(.animation(minimumInterval: 1.0/30.0, paused: !theme.animates)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    let c = tint ?? theme.accent
                    for m in motes.prefix(count) {
                        // parallax: motes nudge toward/away from the pointer subtly
                        let px = (pointer.x / max(size.width, 1) - 0.5) * 16 * m.seed
                        let py = (pointer.y / max(size.height, 1) - 0.5) * 16 * m.seed
                        let drift = theme.animates ? t * 8 * theme.driftSpeed : 0
                        let x = (m.x * size.width + m.vx * drift).truncatingRemainder(dividingBy: size.width)
                        let y = (m.y * size.height + m.vy * drift).truncatingRemainder(dividingBy: size.height)
                        let xx = x < 0 ? x + size.width : x
                        let yy = y < 0 ? y + size.height : y
                        let tw = 0.55 + 0.45 * sin(t * 0.9 * theme.driftSpeed + m.seed * 6.28)
                        let rect = CGRect(x: xx + px, y: yy + py, width: m.r, height: m.r)
                        ctx.fill(Path(ellipseIn: rect), with: .color(c.opacity(0.05 + 0.28 * tw * theme.fxScale)))
                    }
                }
                .drawingGroup()
            }
            .onAppear { regen(count) }
            .onChange(of: count) { regen($0) }
            .onContinuousHover { phase in if case let .active(p) = phase { pointer = p } }
        }
        .allowsHitTesting(false)
    }

    private func regen(_ count: Int) {
        guard count > 0 else { motes = []; return }
        motes = (0..<count).map { i in
            var s = UInt64(i &* 0x9E3779B1 &+ 7)
            func rnd() -> Double { s = s &* 6364136223846793005 &+ 1; return Double(s >> 33) / Double(UInt64(1) << 31) }
            return Mote(x: rnd(), y: rnd(), vx: rnd() * 2 - 1, vy: -(rnd() * 1.2 + 0.3), r: rnd() * 2.4 + 0.8, seed: rnd())
        }
    }
}

// MARK: - IridescentBorder — animated rim (AngularGradient accent↔secondary↔magenta↔accent)
struct IridescentBorder: View {
    @Environment(\.holoTheme) private var theme
    var cornerRadius: CGFloat = 18
    var lineWidth: CGFloat = 1.2
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/24.0, paused: !theme.animates)) { tl in
            let angle = theme.animates ? tl.date.timeIntervalSinceReferenceDate * 28 * theme.driftSpeed : 0
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            theme.accent.opacity(0.20 + 0.55 * theme.fxScale),
                            theme.secondary.opacity(0.35 + 0.5 * theme.fxScale),
                            Color(hex: 0xFF4FD8).opacity(0.18 + 0.4 * theme.fxScale),
                            theme.accent.opacity(0.20 + 0.55 * theme.fxScale)
                        ]),
                        center: .center, angle: .degrees(angle)),
                    lineWidth: lineWidth)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - GlowPulse — soft breathing rim-light for primary CTAs / selected states
struct GlowPulse: View {
    @Environment(\.holoTheme) private var theme
    var cornerRadius: CGFloat = 14
    var tint: Color? = nil
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/24.0, paused: !theme.animates)) { tl in
            let p = theme.animates ? 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 1.6) : 0.6
            let c = tint ?? theme.accent
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(c.opacity((0.25 + 0.45 * p) * max(0.4, theme.fxScale)), lineWidth: 1.2)
                .shadow(color: c.opacity((0.18 + 0.32 * p) * theme.glow), radius: 10 + 8 * p)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - HoloSheen — moving diagonal iridescent light sweep across any surface/text
struct HoloSheen: View {
    @Environment(\.holoTheme) private var theme
    var cornerRadius: CGFloat = 18
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            TimelineView(.animation(minimumInterval: 1.0/30.0, paused: !theme.animates)) { tl in
                let period = 9.0 / max(0.2, theme.driftSpeed == 0 ? 1 : theme.driftSpeed)
                let phase = theme.animates ? (tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)) / period : 0.5
                let x = CGFloat(-1.2 + phase * 2.6)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: BLTheme.champagneHi.opacity(0.45 * theme.fxScale), location: 0.45),
                    .init(color: theme.secondary.opacity(0.5 * theme.fxScale), location: 0.5),
                    .init(color: BLTheme.champagneHi.opacity(0.45 * theme.fxScale), location: 0.55),
                    .init(color: .clear, location: 1.0)
                ], startPoint: .leading, endPoint: .trailing)
                .frame(width: w * 0.5)
                .offset(x: x * w)
                .blendMode(.screen)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }
}
extension View {
    /// Moving iridescent light sweep overlay. Use on hero panels, primary buttons, logos.
    func holoSheen(cornerRadius: CGFloat = 18) -> some View { overlay(HoloSheen(cornerRadius: cornerRadius)) }
}

// MARK: - .holoCard() — THE signature surface
// material + tint, iridescent animated border, layered shadow + accent glow, inner top highlight,
// hover lift. The pointer 3D tilt (rotation3DEffect) is DEFAULT OFF — it perspective-rasterizes and
// softens the card's text as the cursor moves; gated on the Theme Studio "Card 3D tilt" toggle
// (theme.tilt). When tilt is off, NO rotation3DEffect is applied at all (the modifier is absent, not
// a 0° rotation) so there is zero perspective softening of content. No cursor-following specular
// highlight either (removed earlier — it read as blur over card content).
private struct HoloCardModifier: ViewModifier {
    @Environment(\.holoTheme) private var theme
    var cornerRadius: CGFloat
    var sheen: Bool
    @State private var hover = false
    @State private var local: CGPoint = .zero
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        // Shared surface: material, sheen, iridescent border, shadows, accent glow, hover lift.
        // Identical whether or not tilt is on — only the rotation3DEffect differs.
        let base = content
            .background(
                ZStack {
                    // LEGIBILITY: an OPAQUE high-contrast base so the moving aurora NEVER shows through
                    // behind reading text. The frosted material + iridescent border still read as glass,
                    // but content sits on a solid dark panel (WCAG-AA contrast against BLTheme.text).
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(BLTheme.panel)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(BLTheme.glassStrong)
                    // inner top highlight
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center))
                }
            )
            .overlay { if sheen { HoloSheen(cornerRadius: cornerRadius) } }
            .overlay { IridescentBorder(cornerRadius: cornerRadius, lineWidth: 1.0) }
            .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { size = $0 } })
            .shadow(color: theme.accent.opacity(0.22 * theme.glow), radius: 28 + 14 * theme.glow, y: 0)
            .shadow(color: .black.opacity(0.40), radius: hover ? 22 : 16, y: hover ? 14 : 10)

        // Branch on tilt so OFF = no rotation3DEffect at all (no perspective rasterization of text).
        return Group {
            if theme.tilt > 0 {
                let maxTilt = 6.0 * theme.tilt
                let nx = size.width  > 0 ? (local.x / size.width  - 0.5) : 0
                let ny = size.height > 0 ? (local.y / size.height - 0.5) : 0
                base
                    .rotation3DEffect(.degrees(hover ? ny * maxTilt : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                    .rotation3DEffect(.degrees(hover ? -nx * maxTilt : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hover)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): if !hover { hover = true }; local = p
                        case .ended: hover = false
                        }
                    }
            } else {
                // Tilt OFF: keep the hover lift (shadow already keys off `hover`) — but never a rotation3DEffect.
                base
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hover)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: if !hover { hover = true }
                        case .ended: hover = false
                        }
                    }
            }
        }
    }
}
extension View {
    /// The signature holographic card surface. Reads the live HoloTheme for all intensities.
    func holoCard(cornerRadius: CGFloat = 18, padding: CGFloat = 20, sheen: Bool = true) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(HoloCardModifier(cornerRadius: cornerRadius, sheen: sheen))
    }
    /// Variant that wraps content WITHOUT adding padding/frame (for cards that own their layout).
    func holoSurface(cornerRadius: CGFloat = 18, sheen: Bool = false) -> some View {
        modifier(HoloCardModifier(cornerRadius: cornerRadius, sheen: sheen))
    }
}

// MARK: - FoilText — metallic/holographic text (gradient fill + sheen sweep + soft glow)
struct FoilText: View {
    @Environment(\.holoTheme) private var theme
    let text: String
    var size: CGFloat = 32
    var serif: Bool = true
    private func font() -> Font { serif ? BLTheme.serif(size) : .system(size: size, weight: .heavy, design: .rounded) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0, paused: !theme.animates)) { tl in
            let p = theme.animates ? CGFloat(-0.6 + 1.2 * (0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 0.5 * max(0.4, theme.driftSpeed)))) : 0.0
            let grad = LinearGradient(stops: [
                .init(color: BLTheme.goldDim, location: 0.0),
                .init(color: theme.accent, location: 0.22),
                .init(color: BLTheme.goldHi, location: 0.42),
                .init(color: BLTheme.champagneHi, location: 0.5),
                .init(color: theme.secondary.opacity(0.9), location: 0.62),
                .init(color: BLTheme.goldHi, location: 0.8),
                .init(color: BLTheme.goldDim, location: 1.0)
            ], startPoint: UnitPoint(x: p, y: 0.5), endPoint: UnitPoint(x: p + 1.6, y: 0.5))
            Text(text)
                .font(font())
                .foregroundStyle(grad)
                // LEGIBILITY: keep the foil gradient + sheen, but a MINIMAL/crisp glow so the edges
                // of large display headings stay sharp (no soft halo that fuzzes the type).
                .shadow(color: theme.accent.opacity(0.18 * max(0.3, theme.glow)), radius: 3, y: 0)
        }
        .accessibilityLabel(text)
    }
}

// MARK: - AnimatedCounter — numbers roll/transition on change (numericText + spring)
struct AnimatedCounter: View {
    @Environment(\.holoTheme) private var theme
    let value: Int
    var font: Font = BLTheme.mono(28, weight: .bold)
    var color: Color = BLTheme.text
    var body: some View {
        Text("\(value)")
            .font(font).foregroundColor(color)
            .contentTransition(.numericText())
            .animation(theme.animates ? .spring(response: 0.5, dampingFraction: 0.8) : nil, value: value)
            .accessibilityLabel("\(value)")
    }
}
/// String variant (for "12 of 30", "72°F" etc.) — still gets the numeric content transition.
struct AnimatedText: View {
    @Environment(\.holoTheme) private var theme
    let text: String
    var font: Font = BLTheme.mono(28, weight: .bold)
    var color: Color = BLTheme.text
    var body: some View {
        Text(text).font(font).foregroundColor(color)
            .contentTransition(.numericText())
            .animation(theme.animates ? .spring(response: 0.5, dampingFraction: 0.8) : nil, value: text)
    }
}

// MARK: - HoloShimmerSkeleton — loading state = shimmering holographic skeleton (never a spinner)
struct HoloShimmerSkeleton: View {
    @Environment(\.holoTheme) private var theme
    var rows: Int = 3
    var cornerRadius: CGFloat = 8
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<rows, id: \.self) { i in
                bar(width: i == rows - 1 ? 0.6 : (i == 0 ? 0.85 : 1.0))
            }
        }
    }
    private func bar(width: CGFloat) -> some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0/30.0, paused: !theme.animates)) { tl in
                let phase = theme.animates ? CGFloat((tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)) / 1.6) : 0.5
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(BLTheme.bg3)
                    .overlay(
                        LinearGradient(stops: [
                            .init(color: .clear, location: max(0, phase - 0.25)),
                            .init(color: theme.accent.opacity(0.28 * max(0.4, theme.fxScale)), location: phase),
                            .init(color: .clear, location: min(1, phase + 0.25))
                        ], startPoint: .leading, endPoint: .trailing)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    )
                    .frame(width: geo.size.width * width)
            }
        }
        .frame(height: 14)
    }
}

// MARK: - Color <-> hex string (for the Theme Studio's custom color pickers)
extension Color {
    /// "RRGGBB" uppercased. Resolves through NSColor sRGB so SwiftUI/ColorPicker colors round-trip.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}

// MARK: - ThemeStudioPreview — a self-contained live sample of the current theme
/// Re-injects the buyer's CURRENT theme so the preview updates instantly as Studio knobs move
/// (the ambient environment theme only refreshes when RootView re-renders). Pure visual sample.
struct ThemeStudioPreview: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var theme: HoloTheme { settings.holoTheme(motionAllowed: settings.motionEnabled && !reduceMotion) }
    var body: some View {
        ZStack {
            AuroraBackdrop()
            ParticleField()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    FoilText(text: "Aa", size: 34)
                    AnimatedCounter(value: 1280, font: BLTheme.mono(22, weight: .bold))
                    Text("LIVE PREVIEW").font(BLTheme.mono(8.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(1)
                }
                .holoCard(cornerRadius: 16, padding: 16)
                VStack(spacing: 8) {
                    Text("Hover me").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Image(systemName: "sparkles").font(.system(size: 20, weight: .bold)).foregroundColor(theme.accent)
                }
                .holoCard(cornerRadius: 16, padding: 18)
                .frame(width: 120)
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        .holoTheme(theme)   // the preview samples the live, in-progress theme
    }
}

// MARK: - StaggerReveal — section/grid items spring in (opacity + offset + scale), staggered by index
// No content blur: items fade/rise/scale only — text and cards stay razor-sharp the whole reveal.
private struct StaggerReveal: ViewModifier {
    @Environment(\.holoTheme) private var theme
    let index: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .scaleEffect(shown ? 1 : 0.985)
            .onAppear {
                guard theme.animates else { shown = true; return }
                let delay = min(Double(index) * 0.045, 0.5)
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(delay)) { shown = true }
            }
    }
}
extension View {
    /// Staggered spring-in reveal (use on grid/section items with their position index).
    func staggerReveal(_ index: Int) -> some View { modifier(StaggerReveal(index: index)) }
}

// MARK: - ParallaxLayer — background/mid/foreground move at different rates on pointer
/// Wrap any decorative layer; `depth` 0 (far, barely moves) … 1 (near, moves most).
struct ParallaxLayer<Content: View>: View {
    @Environment(\.holoTheme) private var theme
    var depth: CGFloat = 0.5
    @ViewBuilder var content: () -> Content
    @State private var offset: CGSize = .zero
    var body: some View {
        content()
            .offset(offset)
            .background(
                GeometryReader { geo in
                    Color.clear.onContinuousHover { phase in
                        guard theme.tilt > 0 else { offset = .zero; return }
                        if case let .active(p) = phase {
                            let dx = (p.x / max(geo.size.width, 1) - 0.5) * 26 * depth
                            let dy = (p.y / max(geo.size.height, 1) - 0.5) * 26 * depth
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { offset = CGSize(width: dx, height: dy) }
                        } else {
                            withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { offset = .zero }
                        }
                    }
                }
            )
            .allowsHitTesting(false)
    }
}
#endif // circuit-convert
