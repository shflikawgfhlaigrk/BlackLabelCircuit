#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — Black Label premium / holographic design language, translated from
// the live blacklabelbots.com CSS (PREMIUM-DESIGN-SPEC.md). Dark luxury / private-bank:
// near-black + gold + champagne + burgundy, restrained holo-cyan, serif display,
// glass cards, slow gold border-pulse + sheen sweep, shimmer headlines, drifting HUD grid.
// Motion is slow & expensive and honors Reduce Motion + the in-app Settings toggle.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreText) && !CIRCUIT_WINDOWS_SIM
import CoreText
#endif

// MARK: - Palette (exact hex from the storefront spec)
enum BLTheme {
    // Backgrounds
    static let bg     = Color(hex: 0x050505)   // base near-black
    static let bg2    = Color(hex: 0x0B0B0B)
    static let bg3    = Color(hex: 0x121212)
    static let panel  = Color(hex: 0x0F1216)   // glass-toned panel
    static let panelHi = Color(hex: 0x151A20)
    static let glass  = Color(red: 8/255, green: 12/255, blue: 18/255, opacity: 0.62)   // rgba(8,12,18,0.62)
    static let glassStrong = Color(red: 8/255, green: 12/255, blue: 18/255, opacity: 0.78)

    // Accents
    static let gold    = Color(hex: 0xC9A961)
    static let goldHi  = Color(hex: 0xF9E27D)
    static let goldDim = Color(hex: 0x8A7340)
    static let champagne = Color(hex: 0xD4C5A0)
    static let champagneHi = Color(hex: 0xFFF8E0)
    static let burgundy = Color(hex: 0x8B3A4A)
    static let burgundyDeep = Color(hex: 0x6B2D3E)
    static let holo    = Color(hex: 0x4FD7FF)   // holographic — used sparingly

    // Hairlines / strokes
    static let line   = Color(hex: 0x1F1F1F)
    static let stroke = Color(hex: 0x2A2A2A)

    // Text
    static let text   = Color(hex: 0xE8E6E1)   // primary
    static let sub    = Color(hex: 0x8A8680)   // dim
    static let mute   = Color(hex: 0x5A5650)   // mute
    static let ink    = Color(hex: 0x0A0A06)   // text on gold

    static let green  = Color(hex: 0x6FD08C)
    static let danger = Color(hex: 0xE0596B)

    // Gradients
    static var goldGrad: LinearGradient { LinearGradient(colors: [goldHi, gold, goldDim], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var panelGrad: LinearGradient { LinearGradient(colors: [panelHi.opacity(0.9), panel.opacity(0.85)], startPoint: .top, endPoint: .bottom) }
    static var hairline: LinearGradient { LinearGradient(colors: [gold.opacity(0.30), stroke.opacity(0.7)], startPoint: .top, endPoint: .bottom) }

    // Glows (spec: gold 0 0 34px rgba(201,169,97,0.24); cyan 0 0 28px rgba(79,215,255,0.14))
    static let goldGlow = gold.opacity(0.24)
    static let holoGlow = holo.opacity(0.14)

    // Fonts (bundled OFL — Cormorant Garamond display, JetBrains Mono data; SF fallbacks)
    static func serif(_ size: CGFloat) -> Font {
        if Fonts.serifRegistered { return .custom("Cormorant Garamond", size: size) }
        return .system(size: size, weight: .light, design: .serif)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if Fonts.monoRegistered { return .custom("JetBrains Mono", size: size).weight(weight) }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static func icon() -> NSImage? { Bundle.main.resourcePath.flatMap { NSImage(contentsOfFile: $0 + "/AppIcon.icns") } ?? NSImage(named: "AppIcon") }
}

// MARK: - Font registration (bundled TTFs → usable via .custom)
enum Fonts {
    static private(set) var serifRegistered = false
    static private(set) var monoRegistered = false
    static func register() {
        serifRegistered = registerOne("CormorantGaramond", ext: "ttf")
        monoRegistered = registerOne("JetBrainsMono", ext: "ttf")
    }
    private static func registerOne(_ name: String, ext: String) -> Bool {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return false }
        var err: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
        // Already-registered counts as available.
        if !ok, let e = err?.takeRetainedValue() {
            let code = CFErrorGetCode(e)
            if code == CTFontManagerError.alreadyRegistered.rawValue { return true }
            return false
        }
        return true
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF)/255, green: Double((hex >> 8) & 0xFF)/255, blue: Double(hex & 0xFF)/255, opacity: 1)
    }
}

// MARK: - Motion environment (respects system Reduce Motion + in-app toggle)
private struct MotionEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var blMotionEnabled: Bool {
        get { self[MotionEnabledKey.self] }
        set { self[MotionEnabledKey.self] = newValue }
    }
}

// MARK: - FXClock  (wall-clock phases for TimelineView-driven FX loops)
// Every continuous FX loop is driven by a pausable TimelineView computing its phase from the
// wall clock — NEVER by `withAnimation(.repeatForever)` on @State. A running repeatForever
// cannot be cancelled: re-assigning the value (plainly or via a zero-duration withAnimation)
// leaves the animation attached, and the layer keeps re-rasterizing every frame even when the
// rendered output is frozen (proven with a minimal repro + `sample`, 2026-07-03, Marketing b17).
// A TimelineView with `paused: true` provably stops ticking (0.0% CPU). Wall-clock phases also
// mean no per-view start bookkeeping — loops stay in step for free.
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

// MARK: - Brand logo with soft gold glow
struct Logo: View {
    var size: CGFloat = 64
    var body: some View {
        Image("BLBMark")
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size*0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size*0.24, style: .continuous).stroke(BLTheme.gold.opacity(0.35), lineWidth: 1))
            .shadow(color: BLTheme.gold.opacity(0.35), radius: size*0.2, y: 4)
    }
}

// MARK: - Drifting HUD grid (faint, slow, behind hero areas)
struct HUDGrid: View {
    @Environment(\.blMotionEnabled) private var motion
    var spacing: CGFloat = 46
    var opacity: Double = 0.05
    var body: some View {
        // Slow drift is only perceptible at low fps anyway — 10fps keeps the paused-TimelineView
        // contract (0.0% when stilled) and near-zero cost when live.
        TimelineView(.animation(minimumInterval: 1.0/10.0, paused: !motion)) { tl in
            let off = motion ? spacing * FXClock.loop(tl.date, 60) : 0
            Canvas { ctx, size in
                var path = Path()
                var x = -spacing + off.truncatingRemainder(dividingBy: spacing)
                while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
                var y = -spacing + off.truncatingRemainder(dividingBy: spacing)
                while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
                ctx.stroke(path, with: .color(BLTheme.gold.opacity(opacity)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Slow animated gold orb (decorative ambient glow)
struct GoldOrb: View {
    @Environment(\.blMotionEnabled) private var motion
    var diameter: CGFloat = 340
    var opacity: Double = 0.16
    var tint: Color = BLTheme.gold
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/15.0, paused: !motion)) { tl in
            let p = motion ? FXClock.easeInOut(FXClock.pingPong(tl.date, 7)) : 0
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(opacity), .clear], center: .center, startRadius: 0, endRadius: diameter/2))
                .frame(width: diameter, height: diameter)
                .blur(radius: 60)
                .scaleEffect(0.9 + 0.22 * p)
                .opacity(0.7 + 0.3 * p)
        }
        .allowsHitTesting(false)   // purely-decorative glow halo: can NEVER eat clicks, regardless of placement
    }
}

// MARK: - Sheen sweep overlay (soft gold/white band sweeps L→R, peak ~0.6)
struct SheenSweep: View {
    @Environment(\.blMotionEnabled) private var motion
    var cornerRadius: CGFloat = 18
    var period: Double = 9
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            TimelineView(.animation(minimumInterval: 1.0/30.0, paused: !motion)) { tl in
                // stilled: parked off-screen left (matches the old pre-animation resting state)
                let x: CGFloat = motion ? -1.2 + 2.6 * FXClock.easeInOut(FXClock.loop(tl.date, period)) : -1.2
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: BLTheme.champagneHi.opacity(0.5), location: 0.45),
                    .init(color: BLTheme.goldHi.opacity(0.6), location: 0.5),
                    .init(color: BLTheme.champagneHi.opacity(0.5), location: 0.55),
                    .init(color: .clear, location: 1.0)
                ], startPoint: .leading, endPoint: .trailing)
                .frame(width: w * 0.55)
                .offset(x: x * w)
                .blendMode(.screen)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }
}

// MARK: - Holographic glass card — now powered by the live-HoloTheme FX kit (Holographic.swift).
// Kept as a view (not just the modifier) so every existing call site upgrades for free: iridescent
// animated border, layered shadow + accent glow, pointer 3D tilt + hover lift.
struct HoloCard<Content: View>: View {
    var cornerRadius: CGFloat = 18
    var sweep: Bool = true
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().holoCard(cornerRadius: cornerRadius, padding: padding, sheen: sweep)
    }
}

// MARK: - Holographic shimmer headline — now FoilText under the hood (theme-driven hues + glow).
struct ShimmerText: View {
    let text: String
    var size: CGFloat = 30
    var serif: Bool = true
    var body: some View { FoilText(text: text, size: size, serif: serif) }
}

// MARK: - Conic foil premium badge (iridescent gold→cyan→champagne, only on premium chips)
struct FoilBadge: View {
    @Environment(\.blMotionEnabled) private var motion
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(BLTheme.mono(9.5, weight: .bold)).tracking(1.0)
            .foregroundColor(BLTheme.ink)
            .padding(.vertical, 4).padding(.horizontal, 10)
            .background(
                // Only the conic fill is timeline-driven — the text/capsule content above never
                // re-renders per tick. Conic gradients are the single hottest FX cost (sample:
                // argb32_shade_conic), so this one earns the 24fps cap.
                TimelineView(.animation(minimumInterval: 1.0/24.0, paused: !motion)) { tl in
                    let angle = motion ? 360 * FXClock.loop(tl.date, 8) : 0
                    AngularGradient(colors: [BLTheme.goldHi, BLTheme.holo, BLTheme.champagneHi, BLTheme.gold, BLTheme.goldHi],
                                    center: .center, angle: .degrees(angle))
                }
            )
            .clipShape(Capsule())
            .overlay(Capsule().stroke(BLTheme.goldHi.opacity(0.6), lineWidth: 0.75))
            .shadow(color: BLTheme.goldGlow, radius: 8)
    }
}

// MARK: - Labeled text field
struct Field: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var secure = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            Group {
                if secure { SecureField(prompt.isEmpty ? title : prompt, text: $text) }
                else { TextField(prompt.isEmpty ? title : prompt, text: $text) }
            }
            .textFieldStyle(.plain).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            .focused($focused)
            .padding(.vertical, 11).padding(.horizontal, 13)
            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(focused ? BLTheme.gold.opacity(0.7) : BLTheme.stroke, lineWidth: focused ? 1.5 : 1))
            .shadow(color: focused ? BLTheme.goldGlow : .clear, radius: 8)
            .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

// MARK: - Primary gold button with hover scale + glow
struct GoldButton: View {
    let label: String; var fill = false; var icon = ""; let action: () -> Void
    @State private var hover = false
    @State private var press = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if !icon.isEmpty { Image(systemName: icon).font(.system(size: 12.5, weight: .bold)) }
                Text(label)
            }
            .font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.ink)
            .padding(.vertical, 11).padding(.horizontal, 20).frame(maxWidth: fill ? .infinity : nil)
            .background(BLTheme.goldGrad).clipShape(Capsule())
            .overlay(Capsule().stroke(BLTheme.goldHi.opacity(hover ? 0.7 : 0.2), lineWidth: 1))
            .shadow(color: BLTheme.gold.opacity(hover ? 0.5 : 0.28), radius: hover ? 18 : 10, y: 4)
            .scaleEffect(press ? 0.97 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
        .pressAction(onPress: { press = true }, onRelease: { press = false })
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Sheet close affordance
// Always-visible close for modal sheets. Prepends a top bar with a clear "✕ Close" pill (Esc-bound)
// so a presented editor/runner/detail NEVER looks like a dead-end — the Save/Cancel pair often sits
// at the BOTTOM of long scrolling forms, which reads as "no back button". A prepended bar (not an
// overlay) never collides with top-right header content.
struct SheetCloseBar: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        Text("Close").font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(BLTheme.text)
                    .padding(.vertical, 6).padding(.horizontal, 11)
                    .background(BLTheme.bg2, in: Capsule())
                    .overlay(Capsule().stroke(BLTheme.gold.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain).help("Close (Esc)").keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 2)
            content
        }
        .background(BLTheme.bg)
    }
}
extension View {
    /// Adds an always-visible top-right "Close" button (Esc-bound) above a sheet's content.
    func sheetCloseBar() -> some View { modifier(SheetCloseBar()) }

    /// Sheet/editor sizing. macOS sheets want a fixed, comfortable width. On iPhone a fixed 520-600pt
    /// width clips off-screen (the phone is ~390pt wide), so the sheet must fill the available width
    /// (capped on iPad). Replaces bare `.frame(width: N)` on modal editor content so the same call
    /// renders correctly on both platforms.
    @ViewBuilder func sheetWidth(_ width: CGFloat) -> some View {
        #if os(macOS)
        self.frame(width: width)
        #else
        self.frame(maxWidth: width)
        #endif
    }

    /// Inline segmented control width: fixed on macOS, full-width-up-to-cap on iPhone (so a 360-380pt
    /// control never overflows a 390pt screen and reads natively).
    @ViewBuilder func segmentedWidth(_ width: CGFloat) -> some View {
        #if os(macOS)
        self.frame(width: width)
        #else
        self.frame(maxWidth: width)
        #endif
    }

    /// Floating panel/card width (command palette, onboarding card, auth card). Fixed on macOS;
    /// on iPhone capped to `width` but allowed to shrink to the available width, so it never runs
    /// off-screen on a 390pt phone. (No internal padding so stacked calls don't compound margins.)
    @ViewBuilder func responsiveWidth(_ width: CGFloat) -> some View {
        #if os(macOS)
        self.frame(width: width)
        #else
        self.frame(maxWidth: width)
        #endif
    }

    /// iOS keyboard escape for editor surfaces. Multi-line iOS keyboards have no Return-to-dismiss,
    /// so a TextEditor otherwise traps the keyboard over the bottom of its sheet (covering the
    /// Save/Cancel row) with no way down. One modifier at the editor's root gives the standard pair:
    /// a keyboard-toolbar Done that resigns focus, and interactive drag-to-dismiss on the enclosed
    /// scroll views. No-op on macOS (hardware keyboards don't cover content).
    @ViewBuilder func keyboardDismissable() -> some View {
        #if os(iOS)
        self
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    }
                }
            }
        #else
        self
        #endif
    }
}

// MARK: - Secondary / ghost button
struct GhostButton: View {
    let label: String; var icon = ""; var tint: Color = BLTheme.text; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !icon.isEmpty { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(label)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(tint)
            .padding(.vertical, 9).padding(.horizontal, 16)
            .background(hover ? tint.opacity(0.12) : BLTheme.bg2).clipShape(Capsule())
            .overlay(Capsule().stroke(hover ? tint.opacity(0.5) : BLTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Glassy panel with section header badge (holo card under the hood)
struct Panel<Content: View>: View {
    let title: String; var icon = "square.grid.2x2"; var accent: Color = BLTheme.gold
    @ViewBuilder var content: () -> Content
    var body: some View {
        HoloCard(cornerRadius: 20, sweep: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 12.5, weight: .bold)).foregroundColor(BLTheme.ink)
                        .frame(width: 28, height: 28).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .shadow(color: BLTheme.goldGlow, radius: 6, y: 2)
                    Text(title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                }
                content()
            }
        }
    }
}

// MARK: - Hero metric card (mono data type + accent glow)
struct MetricCard: View {
    let label: String; let value: String; let icon: String; var tint: Color = BLTheme.gold
    @State private var hover = false
    var body: some View {
        HoloCard(cornerRadius: 18, sweep: false, padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 16, weight: .bold)).foregroundColor(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(tint.opacity(0.3), lineWidth: 1))
                AnimatedText(text: value, font: BLTheme.mono(28, weight: .bold), color: BLTheme.text)
                Text(label.uppercased()).font(BLTheme.mono(9.5, weight: .medium)).foregroundColor(BLTheme.sub).tracking(0.8)
            }
        }
        .shadow(color: hover ? tint.opacity(0.22) : .clear, radius: hover ? 20 : 0, y: 6)
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { hover = h } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

struct Stat: View {
    let label: String; let value: String; var big = false; var tint: Color = BLTheme.text
    var body: some View {
        HStack { Text(label).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            Spacer()
            Text(value).font(big ? BLTheme.mono(18, weight: .bold) : BLTheme.mono(13, weight: .medium)).foregroundColor(big ? BLTheme.gold : tint) }
    }
}

struct StatusPill: View {
    let text: String; let tint: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6).shadow(color: tint.opacity(0.8), radius: 3)
            Text(text).font(BLTheme.mono(9.5, weight: .bold)).foregroundColor(tint).tracking(0.4)
        }
        .padding(.vertical, 4).padding(.horizontal, 10)
        .background(tint.opacity(0.14)).clipShape(Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(text)")
    }
}

// MARK: - Intentional empty-state
struct EmptyState: View {
    let icon: String; let title: String; let hint: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34, weight: .regular)).foregroundColor(BLTheme.ink)
                .frame(width: 72, height: 72).background(BLTheme.goldGrad.opacity(0.9)).clipShape(Circle())
                .shadow(color: BLTheme.goldGlow, radius: 14, y: 4)
            Text(title).font(BLTheme.serif(24)).foregroundColor(BLTheme.text)
            Text(hint).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.sub)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Screen title header (shimmer serif display)
struct ScreenTitle: View {
    let title: String; var subtitle: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ShimmerText(text: title, size: 32)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            }
        }
    }
}

// MARK: - Press gesture helper
extension View {
    func pressAction(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(.easeOut(duration: 0.1)) { onPress() } }
                .onEnded { _ in withAnimation(.easeOut(duration: 0.12)) { onRelease() } }
        )
    }
}
#endif // circuit-convert
