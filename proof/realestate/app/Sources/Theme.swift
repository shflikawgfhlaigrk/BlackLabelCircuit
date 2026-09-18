// Black Label Real Estate — theme + reusable UI.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// DATABASE-FIRST NAV ORDER: the sections that read the live 28M+ public-records
// index (Property Index, Map, List Builder, Lot-Flip) lead; the buyer's own CRM
// follows. The front door is discovery on OUR data — never a paste/import prompt.
enum Section: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", propertyIndex = "Property Index", map = "Property Map", lists = "List Builder",
         lotflip = "Lot-Flip Scout", leads = "My Leads", workqueue = "Work Queue",
         pipeline = "Pipeline", deals = "Deals", analyzer = "Deal Analyzer",
         offers = "Offers & LOI", dispositions = "Dispositions", directmail = "Direct Mail",
         dialer = "Dialer & SMS", route = "Route", calculators = "Calculators",
         accounting = "Deal Accounting", analytics = "Analytics", compliance = "Compliance",
         help = "Help & Guides", settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "chart.pie.fill"; case .leads: return "rectangle.stack.badge.plus"
        case .propertyIndex: return "building.columns.fill"
        case .lists: return "line.3.horizontal.decrease.circle.fill"; case .workqueue: return "flame.fill"
        case .pipeline: return "rectangle.split.3x1.fill"; case .lotflip: return "hammer.fill"
        case .deals: return "house.fill"
        case .analyzer: return "function"; case .offers: return "doc.text.fill"
        case .dispositions: return "person.2.wave.2.fill"; case .directmail: return "envelope.open.fill"
        case .dialer: return "phone.bubble.fill"; case .map: return "mappin.and.ellipse"; case .route: return "map.fill"
        case .calculators: return "percent"; case .accounting: return "dollarsign.square.fill"
        case .analytics: return "chart.bar.xaxis"
        case .compliance: return "checkmark.shield.fill"
        case .help: return "questionmark.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var group: String {
        switch self {
        case .dashboard: return ""
        case .propertyIndex, .map, .lists, .lotflip: return "PROPERTY DATABASE"
        case .leads, .workqueue, .pipeline: return "CRM & PIPELINE"
        case .deals, .analyzer, .offers, .dispositions: return "DEALS"
        case .directmail, .dialer, .route: return "OUTREACH"
        case .calculators, .accounting, .analytics: return "TOOLS"
        case .compliance, .help, .settings: return "WORKSPACE"
        }
    }

    /// The 4 primary sections that get their own bottom tab on iPhone compact width.
    static let primaryTabs: [Section] = [.dashboard, .pipeline, .workqueue, .route]

    static var visibleSections: [Section] { allCases }
}

/// Pure compact-navigation decision used by the iPhone shell. A non-primary destination needs both
/// the More tab and a pushed path; selecting only tab 4 strands dashboard/search deep links at the
/// More menu. Keeping the rule outside `main.swift` makes every acquisition-critical jump testable.
struct CompactNavigationRoute: Equatable {
    var tab: Int
    var morePath: [Section]
}

enum CompactNavigation {
    static func route(to section: Section) -> CompactNavigationRoute {
        if let tab = Section.primaryTabs.firstIndex(of: section) {
            return CompactNavigationRoute(tab: tab, morePath: [])
        }
        return CompactNavigationRoute(tab: 4, morePath: [section])
    }
}

/// The single source of truth for the compact iPhone shell.
///
/// `TabView` owns the selected bottom tab while `NavigationStack` owns the More history, so both
/// pieces must move together for a cross-screen action to be visible. Keeping the current section
/// alongside those real UI bindings also prevents child screens from "navigating" by changing an
/// unrelated desktop-only selection.
struct CompactNavigationState: Equatable {
    var tab: Int = 0
    var morePath: [Section] = []
    var currentSection: Section? = .dashboard

    /// Replace the current compact destination. Used by global entry points such as Search and
    /// Dashboard, where the requested screen should become the root of the More history.
    mutating func navigate(to section: Section) {
        let route = CompactNavigation.route(to: section)
        tab = route.tab
        morePath = route.morePath
        currentSection = section
    }

    /// Navigate from a screen already presented under More. Non-primary destinations are pushed so
    /// the system back button returns to the originating screen; primary destinations switch tabs
    /// and clear the now-hidden More history.
    mutating func pushFromMore(to section: Section) {
        if let primaryTab = Section.primaryTabs.firstIndex(of: section) {
            tab = primaryTab
            morePath.removeAll()
        } else {
            tab = 4
            if morePath.last != section { morePath.append(section) }
        }
        currentSection = section
    }

    /// Mirror a user-driven NavigationStack push/pop into the semantic current destination.
    mutating func syncMorePath(_ path: [Section]) {
        morePath = path
        if let destination = path.last {
            currentSection = destination
        } else if tab == 4 {
            currentSection = nil // the More menu itself is visible, not a product section
        }
    }

    /// Mirror a user-driven bottom-tab selection. Switching to a primary tab invalidates hidden
    /// More history; selecting More restores the top of its current path (or the menu when empty).
    mutating func syncTab(_ selectedTab: Int) {
        guard (0...4).contains(selectedTab) else { return }
        tab = selectedTab
        if Section.primaryTabs.indices.contains(selectedTab) {
            morePath.removeAll()
            currentSection = Section.primaryTabs[selectedTab]
        } else {
            currentSection = morePath.last
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// BLTheme aliases the exact premium palette (`BL`) so existing call-sites keep working while
// the whole app adopts the spec's near-black + gold + champagne language.
enum BLTheme {
    static let bg     = BL.base          // #050505 near-black
    static let bg2    = BL.bg2v          // #121212 inset surfaces
    static let panel  = BL.bg1           // #0B0B0B
    static let panelHi = Color(hex: 0x16161A)
    static var gold   : Color { BL.gold }   // live accent (spec default #C9A961) — re-themes via Settings
    static var goldHi : Color { BL.goldHi }
    static var goldDim: Color { BL.goldDim }
    static let line   = BL.hair1
    static let stroke = BL.hair2
    static let text   = BL.text          // #E8E6E1
    static let sub    = BL.dim           // #8A8680
    static let green  = BL.ok
    static let ink    = BL.ink

    static var goldGrad: LinearGradient { BL.goldGrad }
    static var panelGrad: LinearGradient { LinearGradient(colors: [panelHi, panel], startPoint: .top, endPoint: .bottom) }
    static var appBackground: some View { PremiumBackdrop(grid: false) }
    static func icon() -> NSImage? { Bundle.main.resourcePath.flatMap { NSImage(contentsOfFile: $0 + "/AppIcon.icns") } ?? NSImage(named: "AppIcon") }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF)/255, green: Double((hex >> 8) & 0xFF)/255, blue: Double(hex & 0xFF)/255, opacity: 1)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Reusable premium panel surface: subtle gradient fill + gold-tinted hairline + soft depth shadow.
struct PanelSurface: ViewModifier {
    var radius: CGFloat = 18
    var glow: Bool = false
    func body(content: Content) -> some View {
        content
            .background(BLTheme.panelGrad)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(LinearGradient(colors: [BLTheme.gold.opacity(glow ? 0.45 : 0.22), BLTheme.stroke.opacity(0.8)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
            .shadow(color: glow ? BLTheme.gold.opacity(0.10) : .clear, radius: 22, x: 0, y: 0)
    }
}
#endif // circuit-convert
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension View { func panelSurface(radius: CGFloat = 18, glow: Bool = false) -> some View { modifier(PanelSurface(radius: radius, glow: glow)) } }
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct Logo: View {
    var rawSize: CGFloat = 64
    init(size: CGFloat = 64) { self.rawSize = size }
    private var size: CGFloat { BLScale.f(rawSize) }
    var body: some View {
        // The canonical Black Label hex mark (rendered from assets/blb-mark.svg — founder rule:
        // real mark only, never an AI badge or a letter tile).
        Image("BLBMark").resizable().interpolation(.high)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size*0.22, style: .continuous))
        .shadow(color: BLTheme.gold.opacity(0.35), radius: size*0.2, y: 4)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Gold icon chip used in section headers + sidebar.
struct IconBadge: View {
    let system: String
    var rawSize: CGFloat = 26
    var active: Bool = true
    init(system: String, size: CGFloat = 26, active: Bool = true) {
        self.system = system; self.rawSize = size; self.active = active
    }
    private var size: CGFloat { BLScale.f(rawSize) }
    var body: some View {
        Image(systemName: system)
            .font(.system(size: size*0.46, weight: .bold))
            .foregroundColor(active ? BLTheme.ink : BLTheme.gold)
            .frame(width: size, height: size)
            .background(active ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.gold.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: size*0.31, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size*0.31, style: .continuous).stroke(BLTheme.gold.opacity(active ? 0 : 0.3), lineWidth: 1))
            .shadow(color: BLTheme.gold.opacity(active ? 0.3 : 0), radius: 6, y: 2)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct Field: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    /// Masked entry (SecureField) — for passwords. Secrets elsewhere already use SecureField
    /// directly; this flag brings the styled Field to parity so the sign-in password is never
    /// shown in the clear.
    var secure = false
    @State private var focused = false
    @FocusState private var isFocused: Bool
    private var accessibilityID: String {
        "field." + title.lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "-"
        }.joined()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
            Group {
                if secure {
                    SecureField(prompt.isEmpty ? title : prompt, text: $text)
                } else {
                    TextField(prompt.isEmpty ? title : prompt, text: $text)
                }
            }
                .textFieldStyle(.plain).font(.blSystem(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .focused($isFocused)
                .accessibilityLabel(title)
                .accessibilityIdentifier(accessibilityID)
                .padding(.vertical, 11).padding(.horizontal, 13)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isFocused ? BLTheme.gold.opacity(0.7) : BLTheme.stroke, lineWidth: isFocused ? 1.5 : 1))
                .shadow(color: isFocused ? BLTheme.gold.opacity(0.18) : .clear, radius: 8)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct GoldButton: View {
    let label: String; var fill = false; var icon = ""; let action: () -> Void
    @State private var hover = false
    @State private var press = false
    private var accessibilityID: String {
        "button." + label.lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "-"
        }.joined()
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if !icon.isEmpty { Image(systemName: icon).font(.blSystem(size: 12, weight: .bold)) }
                Text(label)
            }
            .font(.blSystem(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.ink)
            .padding(.vertical, 11).padding(.horizontal, 20).frame(maxWidth: fill ? .infinity : nil)
            .background(BLTheme.goldGrad).clipShape(Capsule())
            .overlay(Capsule().stroke(BLTheme.goldHi.opacity(hover ? 0.6 : 0.0), lineWidth: 1))
            .shadow(color: BLTheme.gold.opacity(hover ? 0.55 : 0.28), radius: hover ? 16 : 9, y: 4)
            // Momentary press dip only — NO persistent hover scale (a fractional hover scale resamples
            // the button label's rasterized bitmap and softens it while the cursor rests on it).
            .scaleEffect(press ? 0.97 : 1.0)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(accessibilityID)
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
        .pressAction(onPress: { withAnimation(.easeOut(duration: 0.1)) { press = true } },
                     onRelease: { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { press = false } })
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// GoldButton's look with NO Button inside — for `Menu { } label:` slots. A real Button as a Menu
/// label can swallow the click on macOS and the menu never opens (the "New sequence" dead control).
struct GoldLabel: View {
    let label: String; var icon = ""
    var body: some View {
        HStack(spacing: 7) {
            if !icon.isEmpty { Image(systemName: icon).font(.blSystem(size: 12, weight: .bold)) }
            Text(label)
        }
        .font(.blSystem(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.ink)
        .padding(.vertical, 11).padding(.horizontal, 20)
        .background(BLTheme.goldGrad).clipShape(Capsule())
        .shadow(color: BLTheme.gold.opacity(0.28), radius: 9, y: 4)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Secondary / ghost button with hover lift.
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
            HStack(spacing: 6) { if !icon.isEmpty { Image(systemName: icon).font(.blSystem(size: 12, weight: .bold)) }; Text(label) }
                .font(.blSystem(size: 13, weight: .semibold, design: .rounded)).foregroundColor(tint)
                .padding(.vertical, 9).padding(.horizontal, 16)
                .background(hover ? tint.opacity(0.14) : BLTheme.bg2).clipShape(Capsule())
                .overlay(Capsule().stroke(hover ? tint.opacity(0.45) : BLTheme.stroke, lineWidth: 1))
                // No hover scaleEffect — it softened the label under the cursor; bg + border are the hover cue.
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(accessibilityID)
        .buttonStyle(.plain).onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Always-visible close affordance for modal sheets. Prepends a thin top bar with a top-right
// close (X) button bound to Esc, so a presented editor/detail NEVER looks like a dead-end — the
// Save/Cancel pair lives at the BOTTOM of long scrolling forms, which read as "no back button".
// A prepended bar (not an overlay) can't collide with top-right header content like a status picker.
struct SheetCloseBar: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    // Editors publish unsaved-edit state up through SheetDirtyPreferenceKey; a dirty sheet
    // confirms before Close/Esc discards, instead of silently dropping the typed edits.
    @State private var dirty = false
    @State private var confirmDiscard = false
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                Button { if dirty { confirmDiscard = true } else { dismiss() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark").font(.blSystem(size: 11, weight: .bold))
                        Text("Close").font(.blSystem(size: 12, weight: .bold, design: .rounded))
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
        .background(BLTheme.appBackground)
        .onPreferenceChange(SheetDirtyPreferenceKey.self) { dirty = $0 }
        .interactiveDismissDisabled(dirty)
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: { Text("This sheet has edits that were not saved.") }
        #if os(iOS)
        // Touch keyboard escape hatch, shared by every sheet: a TextEditor's Return inserts a
        // newline and a decimal pad has no Return at all, so without these a raised keyboard can
        // only be escaped by killing the whole sheet (and its typed text).
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { blDismissKeyboard() }
            }
        }
        #endif
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Child → SheetCloseBar channel: true while the sheet's editor holds unsaved edits.
struct SheetDirtyPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
#endif // circuit-convert
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension View {
    /// Adds an always-visible top-right close button (Esc-bound) above a sheet's content.
    func sheetCloseBar() -> some View { modifier(SheetCloseBar()) }

    /// Marks the enclosing sheet's content dirty: the SheetCloseBar confirms before a Close/Esc
    /// (or an iOS swipe-down) can discard the unsaved edits.
    func sheetEditsPending(_ dirty: Bool) -> some View {
        preference(key: SheetDirtyPreferenceKey.self, value: dirty)
    }

    /// Sizes a sheet/editor: a fixed desktop frame on macOS, but on iOS lets the sheet fill the
    /// (narrow) phone presentation so a 560pt-wide desktop editor doesn't clip off-screen. The
    /// background fill is applied on both. Pass height = nil for forms that scroll their content.
    @ViewBuilder
    func sheetFrame(_ width: CGFloat, _ height: CGFloat? = nil) -> some View {
        #if os(iOS)
        self.frame(maxWidth: .infinity, maxHeight: .infinity).background(BLTheme.appBackground)
        #else
        if let h = height { self.frame(width: width, height: h).background(BLTheme.appBackground) }
        else { self.frame(width: width).background(BLTheme.appBackground) }
        #endif
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Premium glass panel — the holo card treatment (glass + pulsing gold border + sheen sweep).
struct Panel<Content: View>: View {
    let title: String; var icon = "square.grid.2x2"; var glow = false; var sweep = true; @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconBadge(system: icon)
                Text(title).font(BLFont.display(19, .semibold)).foregroundColor(BLTheme.text)
            }
            content()
        }
        .blPadding(20).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(HoloCard(radius: 16, sweep: sweep && glow))
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Big shimmer headline + dim subtitle — the luxury page header used by every screen.
struct SectionHeader: View {
    let title: String; var subtitle: String = ""; var size: CGFloat = 30
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ShimmerText(text: title, size: size, weight: .semibold)
                .foregroundColor(BLTheme.text)
            if !subtitle.isEmpty {
                Text(subtitle).font(BLFont.body(13, .medium)).foregroundColor(BLTheme.sub)
            }
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct Stat: View {
    let label: String; let value: String; var big = false; var tint: Color = BLTheme.text
    var body: some View {
        HStack { Text(label).font(.blSystem(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            Spacer()
            Text(value).font(.blSystem(size: big ? 20 : 14, weight: big ? .heavy : .bold, design: .rounded))
                .foregroundStyle(big ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(tint)) }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct StatusPill: View {
    let text: String; let tint: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6).shadow(color: tint.opacity(0.8), radius: 3)
            Text(text).font(.blSystem(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(tint)
        }
        .padding(.vertical, 4).padding(.horizontal, 10)
        .background(tint.opacity(0.14)).clipShape(Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Intentional empty-state: glowing icon + title + hint.
struct EmptyState: View {
    let icon: String; let title: String; let hint: String
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(BLTheme.gold.opacity(0.10)).frame(width: 92, height: 92).blur(radius: 4)
                Image(systemName: icon).font(.blSystem(size: 38, weight: .light)).foregroundStyle(BLTheme.goldGrad)
            }
            Text(title).font(.blSystem(size: 17, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text(hint).font(.blSystem(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Press gesture helper (used for button spring feedback).
struct PressActions: ViewModifier {
    var onPress: () -> Void; var onRelease: () -> Void
    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onPress() }
                .onEnded { _ in onRelease() }
        )
    }
}
#endif // circuit-convert
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension View {
    func pressAction(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) -> some View {
        modifier(PressActions(onPress: onPress, onRelease: onRelease))
    }
}
#endif // circuit-convert
