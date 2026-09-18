import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Adaptive layout
//
// This UI was drawn on a desktop canvas (820×640 panels, 28-pt gutters, 30-pt headline serif,
// 240-pt grid cells) and the same views ship on iPhone. On a 375×667 iPhone SE that canvas
// overflows: the sign-in card clips top and bottom, the demo banner truncates mid-sentence,
// and a single metric card eats a third of the screen.
//
// The fix is one continuous scale derived from the device's own shortest edge — NOT a table of
// per-device special cases, so a phone Apple ships next year fits automatically. Everything that
// carries a hardcoded point size routes through here: `BLFont`, `Font.blSystem`, screen gutters,
// grid minimums, and the shared card/badge components.
//
// macOS is pinned to factor 1.0 / non-compact, so the approved Mac App Store build renders
// byte-identically to before.
enum BLScale {
    /// The canvas these sizes were authored against (large-phone / desktop panel width).
    static let referenceWidth: CGFloat = 430

    /// Shortest edge of the current screen, in points. Orientation-stable (min of w/h).
    static var screenWidth: CGFloat {
        #if os(iOS)
        let b = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds ?? UIScreen.main.bounds
        return min(b.width, b.height)
        #else
        return referenceWidth
        #endif
    }

    /// Shortest edge → type/metric multiplier, clamped so text never collapses on a small phone
    /// and never inflates past the authored size on iPad.
    /// 375 (SE/mini) → 0.87 · 393 (16/17) → 0.91 · 430 (Pro Max) → 1.0 · iPad → 1.0
    static var factor: CGFloat {
        #if os(iOS)
        return min(1.0, max(0.82, screenWidth / referenceWidth))
        #else
        return 1
        #endif
    }

    /// True on phone-width screens, where desktop two-column rows must stack and gutters shrink.
    static var isCompact: Bool {
        #if os(iOS)
        return screenWidth < 500
        #else
        return false
        #endif
    }

    /// Scale a hardcoded point size. Rounded to a half point so text stays crisp.
    static func f(_ v: CGFloat) -> CGFloat { (v * factor * 2).rounded() / 2 }

    /// Screen gutter. Desktop 28-pt margins waste a phone's narrow width outright.
    static func gutter(_ desktop: CGFloat = 28) -> CGFloat {
        isCompact ? min(16, desktop) : desktop
    }

    /// Stack spacing — scaled, with a compact floor so rows don't collide.
    static func gap(_ v: CGFloat) -> CGFloat { max(8, f(v)) }

    /// Grid cell minimum. A 240-pt desktop cell yields ONE giant column on a phone; shrinking it
    /// gives two readable cards per row instead.
    /// Width of a fixed horizontal-scroll column (Kanban lane). Desktop keeps its authored width;
    /// a phone gets one near-full-width lane with the next lane peeking, so card text stops
    /// truncating and the swipe affordance stays obvious.
    static func columnWidth(_ desktop: CGFloat, peek: CGFloat = 30) -> CGFloat {
        guard isCompact else { return desktop }
        return max(desktop, screenWidth - gutter() * 2 - peek)
    }

    static func cardMin(_ desktop: CGFloat, spacing: CGFloat = 16) -> CGFloat {
        guard isCompact else { return desktop }
        // Two columns inside (screen − 2×gutter − inter-column spacing). The extra 4 pt of slack
        // matters: at exactly the fitting width LazyVGrid rounds DOWN to a single column.
        let twoUp = (screenWidth - gutter() * 2 - spacing - 4) / 2
        return max(132, min(desktop, twoUp))
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension Font {
    /// Drop-in for `.system(size:weight:design:)` that respects `BLScale`. Every explicit font size
    /// in the app goes through this so one device-derived factor governs all type.
    static func blSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: BLScale.f(size), weight: weight, design: design)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension View {
    /// Screen-level gutter: 28 on desktop/iPad, 16 on phones.
    func blScreenPadding(_ desktop: CGFloat = 28) -> some View {
        padding(BLScale.gutter(desktop))
    }
    /// Scaled uniform padding for cards and chrome.
    func blPadding(_ v: CGFloat) -> some View { padding(BLScale.f(v)) }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Screen header + its trailing actions. On a wide canvas they share one baseline-aligned row;
/// on a phone the actions move to their own line, because a 375-pt row forced the subtitle into a
/// four-line column and shoved the buttons off the edge.
struct HeaderRow<Trailing: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var trailing: Trailing
    var body: some View {
        if BLScale.isCompact {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: title, subtitle: subtitle)
                HStack(spacing: 8) { trailing; Spacer(minLength: 0) }
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: title, subtitle: subtitle)
                Spacer()
                trailing
            }
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Side-by-side on a wide canvas, stacked on a phone. Replaces desktop `HStack` pairs that
/// squeezed two full panels into 375 pt.
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat = 16
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var content: Content
    var body: some View {
        if BLScale.isCompact {
            VStack(alignment: alignment, spacing: BLScale.gap(spacing)) { content }
        } else {
            HStack(alignment: .top, spacing: spacing) { content }
        }
    }
}
#endif // circuit-convert
