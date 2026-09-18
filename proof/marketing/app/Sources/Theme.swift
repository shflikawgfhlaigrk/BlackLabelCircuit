#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — theme + reusable UI.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

enum BLTheme {
    static let bg     = Color(hex: 0x0B0B0D)
    static let bg2    = Color(hex: 0x08080A)
    static let panel  = Color(hex: 0x141416)
    static let panelHi = Color(hex: 0x1A1A1E)
    static let line   = Color(hex: 0x2A2616)
    static let stroke = Color(hex: 0x26262B)
    static let text   = Color(hex: 0xEDEDED)
    static let sub    = Color(hex: 0x8C8C8C)
    static let green  = Color(hex: 0x6FD08C)
    static let danger = Color(hex: 0xFF6B6B)
    static let red    = Color(hex: 0xE56B6B)   // Leads-suite alarm tone (ported CRM domain uses it)
    static let inkOnGold = Color(hex: 0x1A1305)

    // Accent is buyer-controllable (set from Prefs at launch + on change). The
    // default is the Black Label gold; the rest of the palette derives from it.
    static let goldDefault = Color(hex: 0xD9B65C)
    static var gold: Color = Color(hex: 0xD9B65C)
    static var goldDim: Color { gold.opacity(0.78) }
    static var goldLite: Color { gold.opacity(1.0).lighter() }

    /// Update the live accent from the buyer's preference. Called at launch and on change.
    static func setAccent(_ c: Color) { gold = c }

    static var goldGrad: LinearGradient { LinearGradient(colors: [goldLite, gold, goldDim], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var goldText: LinearGradient { LinearGradient(colors: [goldLite, gold], startPoint: .leading, endPoint: .trailing) }
    static var panelGrad: LinearGradient { LinearGradient(colors: [panelHi, panel], startPoint: .top, endPoint: .bottom) }
    static var hairline: LinearGradient { LinearGradient(colors: [gold.opacity(0.32), stroke, stroke], startPoint: .top, endPoint: .bottom) }
    static func icon() -> NSImage? { Bundle.main.resourcePath.flatMap { NSImage(contentsOfFile: $0 + "/AppIcon.icns") } ?? NSImage(named: "AppIcon") }
}

extension Color {
    /// Lighten a color toward white (used for the gold highlight stop).
    func lighter(by f: Double = 0.22) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return Color(.sRGB,
                     red: min(1, ns.redComponent + f),
                     green: min(1, ns.greenComponent + f),
                     blue: min(1, ns.blueComponent + f),
                     opacity: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF)/255, green: Double((hex >> 8) & 0xFF)/255, blue: Double(hex & 0xFF)/255, opacity: 1)
    }
}

struct Logo: View {
    var size: CGFloat = 64
    var body: some View {
        // The canonical Black Label hex mark (rendered from assets/blb-mark.svg — founder rule:
        // real mark only, never an AI badge or a letter tile).
        Image("BLBMark").resizable().interpolation(.high)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size*0.24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size*0.24, style: .continuous).stroke(BLTheme.gold.opacity(0.35), lineWidth: 1))
        .shadow(color: BLTheme.gold.opacity(0.32), radius: size*0.18, y: 3)
    }
}

struct Field: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    /// Fires when the user presses Return in the field. Defaults to no-op so existing
    /// call sites are unaffected; search fields pass their search action here.
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    private var accessibilityID: String {
        "field." + title.lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "-"
        }.joined()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
            TextField(prompt.isEmpty ? title : prompt, text: $text)
                .textFieldStyle(.plain).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .focused($focused)
                .onSubmit(onSubmit)
                .accessibilityLabel(title)
                .accessibilityIdentifier(accessibilityID)
                .padding(.vertical, 10).padding(.horizontal, 12)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(focused ? BLTheme.gold.opacity(0.7) : BLTheme.stroke, lineWidth: focused ? 1.4 : 1))
                .shadow(color: focused ? BLTheme.gold.opacity(0.18) : .clear, radius: 6)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

struct GoldButton: View {
    let label: String; var fill = false; var icon = ""; let action: () -> Void
    @State private var hover = false
    private var accessibilityID: String {
        "button." + label.lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "-"
        }.joined()
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !icon.isEmpty { Image(systemName: icon).font(.system(size: 12.5, weight: .bold)) }
                Text(label)
            }
            .font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.inkOnGold)
            .padding(.vertical, 11).padding(.horizontal, 18).frame(maxWidth: fill ? .infinity : nil)
            .background(BLTheme.goldGrad).clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(hover ? 0.35 : 0.18), lineWidth: 0.8))
            .shadow(color: BLTheme.gold.opacity(hover ? 0.55 : 0.28), radius: hover ? 16 : 9, y: 3)
            // No hover scaleEffect — it resampled the label's rasterized bitmap and softened it under
            // the cursor; the growing shadow + brighter border are the hover cue instead.
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(accessibilityID)
        .buttonStyle(.plain).onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
    }
}

/// Subtle secondary (ghost) button matching the brand.
struct GhostButton: View {
    let label: String; var icon = ""; var tint: Color = BLTheme.text; let action: () -> Void
    @State private var hover = false
    private var accessibilityID: String {
        "button." + label.lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "-"
        }.joined()
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !icon.isEmpty { Image(systemName: icon).font(.system(size: 12, weight: .bold)) }
                Text(label)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(tint)
            .padding(.vertical, 9).padding(.horizontal, 16)
            .background(hover ? BLTheme.panelHi : BLTheme.bg2).clipShape(Capsule())
            .overlay(Capsule().stroke(hover ? tint.opacity(0.5) : BLTheme.stroke, lineWidth: 1))
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(accessibilityID)
        .buttonStyle(.plain).onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

// Always-visible close affordance for modal sheets. Prepends a top bar with a clear "✕ Close" pill
// (Esc-bound) so a presented editor/detail NEVER looks like a dead-end — the Save/Cancel pair sits at
// the BOTTOM of long scrolling forms, which reads as "no back button". A prepended bar (not an overlay)
// never collides with top-right header content.
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
        .keyboardDoneBar()   // every sheet form gets the keyboard escape hatch on iOS
    }
}
extension View {
    /// Adds an always-visible top-right "Close" button (Esc-bound) above a sheet's content.
    func sheetCloseBar() -> some View { modifier(SheetCloseBar()) }
}

// Keyboard escape hatch (iOS). TextEditors have no Return-to-dismiss and the decimal/default
// pads keep the keyboard over a form's bottom Save/Cancel controls, so every text surface needs
// a Done accessory plus drag-to-dismiss scrolling. macOS: identity — no on-screen keyboard.
#if os(iOS)
struct KeyboardDoneBar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    }
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                }
            }
    }
}
extension View {
    /// Keyboard Done accessory + interactive scroll-to-dismiss (iOS); no-op on macOS.
    func keyboardDoneBar() -> some View { modifier(KeyboardDoneBar()) }
}
#else
extension View {
    /// Keyboard Done accessory + interactive scroll-to-dismiss (iOS); no-op on macOS.
    func keyboardDoneBar() -> some View { self }
}
#endif

/// A trash control that asks before destroying — one misclick must never erase buyer data.
/// Wraps IconButton with a local confirmation alert (same idiom as the account-delete flow).
struct ConfirmDeleteButton: View {
    let title: String
    let message: String
    var system: String = "trash"
    var tint: Color = BLTheme.danger
    let action: () -> Void
    @State private var confirming = false
    var body: some View {
        IconButton(system: system, tint: tint, accessibilityText: "Delete") { confirming = true }
            .alert(title, isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { action() }
            } message: { Text(message) }
    }
}

/// Small icon-only action button with hover feedback.
struct IconButton: View {
    let system: String
    var tint: Color = BLTheme.gold
    var accessibilityText: String? = nil
    var targetSize: CGFloat = 28
    let action: () -> Void
    @State private var hover = false
    private var inferredAccessibilityText: String {
        if let accessibilityText { return accessibilityText }
        switch system {
        case "trash": return "Delete"
        case "doc.on.doc": return "Copy"
        case "eye": return "Preview"
        case "pencil", "square.and.pencil": return "Edit"
        case "xmark", "xmark.circle": return "Close"
        case "chevron.left": return "Previous"
        case "chevron.right": return "Next"
        case "arrow.clockwise": return "Refresh"
        case "paperplane.fill": return "Publish"
        case "envelope", "envelope.badge": return "Email"
        case "arrow.up.right", "arrow.up.right.square": return "Open link"
        case "plus.circle.fill": return "Add"
        default: return system.replacingOccurrences(of: ".", with: " ")
        }
    }
    var body: some View {
        Button(action: action) {
            ZStack {
                Color.clear
                Image(systemName: system)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(tint)
            }
            .frame(width: targetSize, height: targetSize)
            .contentShape(Rectangle())
            .background(hover ? tint.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(width: targetSize, height: targetSize)
        .contentShape(Rectangle())
        .buttonStyle(.plain).onHover { h in withAnimation(.easeOut(duration: 0.13)) { hover = h } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(inferredAccessibilityText)
        .accessibilityAddTraits(.isButton)
    }
}

struct Panel<Content: View>: View {
    let title: String; var icon = "square.grid.2x2"; @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                    .frame(width: 28, height: 28).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: BLTheme.gold.opacity(0.35), radius: 6, y: 2)
                Text(title).font(BLFonts.display(20, weight: .medium)).foregroundColor(BLTheme.text)
            }
            content()
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassBackground(radius: 18))
    }
}

/// Premium hero stat card with gold value, icon badge, holographic surface, and a
/// rolling AnimatedCounter when the value is purely numeric (so dashboards feel live).
struct HeroStat: View {
    let label: String; let value: String; let icon: String
    /// Parse a clean integer value so AnimatedCounter can roll it; nil → render the raw string
    /// (e.g. "—" or "12.3%"), never fabricating a number.
    private var numeric: Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, Double(trimmed) != nil else { return nil }
        return Double(trimmed)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                    .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .glowPulse()
                Spacer()
            }
            Group {
                if let n = numeric {
                    AnimatedCounter(value: n, font: BLFonts.mono(40, weight: .heavy))
                        .foregroundStyle(BLTheme.goldText)
                } else {
                    Text(value).font(BLFonts.mono(40, weight: .heavy)).foregroundStyle(BLTheme.goldText)
                }
            }
            // Keep big values on ONE line and shrink-to-fit on a narrow phone card (no "59 / 2" wrap).
            .lineLimit(1).minimumScaleFactor(0.5)
            // LEGIBILITY: the big gold value had a wide soft glow (radius 10) that fuzzed the
            // digits. Pull it to a tight rim so the number reads razor-sharp; the gold fill +
            // opaque holoCard behind it carry the premium feel without softening the edges.
            .shadow(color: BLTheme.gold.opacity(0.22), radius: 3, y: 1)
            Text(label.uppercased()).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.8)
                .lineLimit(1).minimumScaleFactor(0.7)   // never char-wrap a one-word label on a narrow card
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .holoCard(radius: 18)
    }
}

/// Shared card surface used by HeroStat/Panel and many call sites. Now delegates to the
/// holographic FX kit (`.holoCard`) so the whole app shares ONE signature surface that reads
/// the buyer's live HoloTheme (iridescent border + glow + pointer 3D tilt — NO cursor specular).
/// Kept as a thin modifier so existing `.modifier(GlassBackground(radius:sweep:))` call sites
/// are unchanged.
struct GlassBackground: ViewModifier {
    var radius: CGFloat = 18
    var sweep: Bool = true
    func body(content: Content) -> some View {
        content.holoCard(radius: radius, sweep: sweep)
    }
}

struct Stat: View {
    let label: String; let value: String; var big = false; var tint: Color = BLTheme.text
    var body: some View {
        HStack { Text(label).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            Spacer()
            Text(value).font(big ? BLFonts.mono(18, weight: .heavy) : .system(size: 14, weight: .bold, design: .rounded)).foregroundColor(big ? BLTheme.gold : tint) }
    }
}

struct StatusPill: View {
    let text: String; let tint: Color
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(tint)
            .padding(.vertical, 3).padding(.horizontal, 9)
            .background(tint.opacity(0.15)).clipShape(Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
    }
}

/// Responsive grid columns. On a wide desktop canvas these behave like the original fixed N-column
/// grids; on a narrow iPhone (compact width) the adaptive sizing automatically reflows to 2 columns
/// (or 1 for very wide cards) so cards never get crushed into unreadable slivers — the fix for the
/// "59 / 2" digit-wrap and "CONVERSI ONS" label-wrap seen on a 390pt phone.
/// `minItemWidth` is the smallest a card may shrink to before the grid drops a column.
func blGridColumns(minItemWidth: CGFloat = 150, spacing: CGFloat = 16, macColumns: Int = 3) -> [GridItem] {
    #if os(iOS)
    return [GridItem(.adaptive(minimum: minItemWidth), spacing: spacing)]
    #else
    // Mac keeps the dense fixed-column look it was designed for.
    return Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(1, macColumns))
    #endif
}

// Width for one pane inside an `HSplitView`. On a wide canvas it pins the macOS/iPad min/ideal width;
// on an iPhone (compact) it instead fills the available width (the panes are stacked vertically there,
// so a hard `minWidth: 380` would force horizontal overflow on a 375pt phone). Lives here (not Compat)
// so it's available on BOTH platforms.
// `max` belongs HERE rather than in a second, stacked `.frame(maxWidth:)` on the call site: two
// chained frames make the pane answer one width proposal with another, and inside an HSplitView
// that re-proposal can re-enter the window's constraints-update pass (see the NSHostingController
// note in main.swift). One frame = one answer.
extension View {
    @ViewBuilder
    func splitPaneWidth(min: CGFloat, ideal: CGFloat? = nil, max maxW: CGFloat? = nil) -> some View {
        #if os(iOS)
        BLSplitPaneWidth(content: self, minW: min, idealW: ideal, maxW: maxW)
        #else
        self.frame(minWidth: min, idealWidth: ideal, maxWidth: maxW)
        #endif
    }
}

#if os(iOS)
private struct BLSplitPaneWidth<C: View>: View {
    let content: C; let minW: CGFloat; let idealW: CGFloat?; let maxW: CGFloat?
    @Environment(\.horizontalSizeClass) private var hSize
    var body: some View {
        if hSize == .compact {
            content.frame(maxWidth: .infinity)          // phone: fill, never force a desktop min width
        } else {
            content.frame(minWidth: minW, idealWidth: idealW, maxWidth: maxW)
        }
    }
}
#endif

/// Intentional empty-state: icon in a soft halo + title + hint.
struct EmptyState: View {
    let icon: String; let title: String; let hint: String
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(BLTheme.gold.opacity(0.10)).frame(width: 78, height: 78).blur(radius: 2)
                Image(systemName: icon).font(.system(size: 30, weight: .semibold)).foregroundStyle(BLTheme.goldText)
            }
            Text(title).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text(hint).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320)
        .padding(.vertical, 28)
    }
}
#endif // circuit-convert
