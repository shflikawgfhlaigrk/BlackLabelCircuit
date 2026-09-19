// CircuitPortKit — SwiftUI views and call shapes that SwiftCrossUI has under another name or
// shape, built on SwiftCrossUI so they draw with its Windows backend (WinUI 3):
//   Label, Link; background(_:in:), background(_:alignment:), overlay(_:alignment:),
//   stroke(_:lineWidth:), strokeBorder(_:lineWidth:), RoundedRectangle(cornerRadius:style:),
//   clipShape(RoundedRectangle), foregroundStyle(Color), State(initialValue:),
//   Color(.sRGB, red:green:blue:opacity:), Font.Design .rounded / .serif.
//
// Stated once, the places Windows cannot match the Mac exactly:
//   - withAnimation / .animation / .transition: SwiftCrossUI has no animation system yet, so the
//     change happens at once. The state and the layout end the same; only the motion is missing.
//   - Font.Design .rounded and .serif: SwiftCrossUI only offers the system font, so text uses it.
// Nothing here pretends to do something it does not: what cannot be expressed is left out, and
// the compiler keeps the views that use it for the Mac.
#if canImport(SwiftCrossUI) && (!canImport(SwiftUI) || CIRCUIT_WINDOWS_SIM)
import Foundation
import SwiftCrossUI

// MARK: - Label, Link

/// SwiftUI's `Label`: an icon beside a title.
public struct Label<Title: SwiftCrossUI.View, Icon: SwiftCrossUI.View>: SwiftCrossUI.View {
    let title: Title
    let icon: Icon

    public init(@SwiftCrossUI.ViewBuilder title: () -> Title, @SwiftCrossUI.ViewBuilder icon: () -> Icon) {
        self.title = title()
        self.icon = icon()
    }

    init(titleView: Title, iconView: Icon) {
        title = titleView
        icon = iconView
    }

    public var body: some SwiftCrossUI.View {
        SwiftCrossUI.HStack(spacing: 6) {
            icon
            title
        }
    }
}

extension Label where Title == SwiftCrossUI.Text, Icon == CircuitImage {
    public init(_ title: String, systemImage: String) {
        self.init(titleView: SwiftCrossUI.Text(title), iconView: CircuitImage(systemName: systemImage))
    }
}

/// SwiftUI's `Link`: opens its destination in the default browser (SwiftCrossUI's openURL).
public struct Link<LabelContent: SwiftCrossUI.View>: SwiftCrossUI.View {
    let destination: URL
    let label: LabelContent
    @SwiftCrossUI.Environment(\.openURL) var openURL

    public init(destination: URL, @SwiftCrossUI.ViewBuilder label: () -> LabelContent) {
        self.destination = destination
        self.label = label()
    }

    init(destination: URL, labelView: LabelContent) {
        self.destination = destination
        label = labelView
    }

    public var body: some SwiftCrossUI.View {
        let openURL = self.openURL
        let destination = self.destination
        return label
            .foregroundColor(.blue)
            .onTapGesture { openURL(destination) }
    }
}

extension Link where LabelContent == SwiftCrossUI.Text {
    public init(_ title: String, destination: URL) {
        self.init(destination: destination, labelView: SwiftCrossUI.Text(title))
    }
}

// MARK: - Shapes

/// SwiftUI's corner style. SwiftCrossUI's rounded rectangle already draws the smooth
/// (superellipse-like) corners SwiftUI calls `.continuous`.
public enum RoundedCornerStyle: Sendable {
    case circular, continuous
}

extension SwiftCrossUI.RoundedRectangle {
    public init(cornerRadius: Double, style: RoundedCornerStyle) {
        self.init(cornerRadius: cornerRadius)
    }
}

extension SwiftCrossUI.Shape {
    /// SwiftUI's `stroke(_:lineWidth:)`.
    public func stroke(_ color: SwiftCrossUI.Color, lineWidth: Double) -> some SwiftCrossUI.StyledShape {
        stroke(color, style: SwiftCrossUI.StrokeStyle(width: lineWidth))
    }

    /// SwiftUI's `strokeBorder(_:lineWidth:)`: the stroke drawn inside the shape's frame — the
    /// same stroke, inset by half its width.
    @MainActor
    public func strokeBorder(_ color: SwiftCrossUI.Color, lineWidth: Double = 1) -> some SwiftCrossUI.View {
        stroke(color, style: SwiftCrossUI.StrokeStyle(width: lineWidth))
            .padding(Int((lineWidth / 2).rounded(.up)))
    }
}

// MARK: - Backgrounds, overlays, clipping, colors

extension SwiftCrossUI.View {
    /// SwiftUI's `background(_:in:)`: a color filling a shape behind the view.
    public func background<S: SwiftCrossUI.Shape>(_ color: SwiftCrossUI.Color, in shape: S) -> some SwiftCrossUI.View {
        background(shape.fill(color))
    }

    /// SwiftUI's `background(_:alignment:)`.
    public func background<V: SwiftCrossUI.View>(_ background: V, alignment: SwiftCrossUI.Alignment) -> some SwiftCrossUI.View {
        self.background(alignment: alignment) { background }
    }

    /// SwiftUI's `overlay(_:alignment:)`.
    public func overlay<V: SwiftCrossUI.View>(_ overlay: V, alignment: SwiftCrossUI.Alignment = .center) -> some SwiftCrossUI.View {
        self.overlay(alignment: alignment) { overlay }
    }

    /// SwiftUI's `clipShape(_:)` for a rounded rectangle: the corner radius clip.
    public func clipShape(_ shape: SwiftCrossUI.RoundedRectangle) -> some SwiftCrossUI.View {
        cornerRadius(Int(shape.cornerRadius.rounded()))
    }

    /// SwiftUI's `foregroundStyle(_:)` with a color.
    public func foregroundStyle(_ color: SwiftCrossUI.Color) -> some SwiftCrossUI.View {
        foregroundColor(color)
    }
}

extension SwiftCrossUI.Color {
    /// SwiftUI's color spaces. Windows composes in sRGB; Display P3 values are taken as sRGB.
    public enum RGBColorSpace: Sendable { case sRGB, sRGBLinear, displayP3 }

    public init(_ colorSpace: RGBColorSpace, red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.init(red: red, green: green, blue: blue, opacity: opacity)
    }

    public init(_ colorSpace: RGBColorSpace, white: Double, opacity: Double = 1) {
        self.init(white: white, opacity: opacity)
    }
}

extension SwiftCrossUI.Font.Design {
    /// No rounded system font on Windows: the system font.
    public static var rounded: SwiftCrossUI.Font.Design { .default }
    /// No serif design in SwiftCrossUI's system font: the system font.
    public static var serif: SwiftCrossUI.Font.Design { .default }
}

// MARK: - State

extension SwiftCrossUI.State {
    /// SwiftUI's older spelling of `State(wrappedValue:)`.
    public init(initialValue: Value) {
        self.init(wrappedValue: initialValue)
    }
}

// MARK: - Animation (no motion on Windows yet; the change itself always happens)

public struct Animation: Sendable, Equatable {
    public static let `default` = Animation()
    public static let linear = Animation()
    public static let easeIn = Animation()
    public static let easeOut = Animation()
    public static let easeInOut = Animation()
    public static let spring = Animation()
    public static let bouncy = Animation()
    public static let smooth = Animation()
    public static let snappy = Animation()
    public static func linear(duration: Double) -> Animation { Animation() }
    public static func easeIn(duration: Double) -> Animation { Animation() }
    public static func easeOut(duration: Double) -> Animation { Animation() }
    public static func easeInOut(duration: Double) -> Animation { Animation() }
    public static func spring(response: Double = 0.5, dampingFraction: Double = 0.825, blendDuration: Double = 0) -> Animation { Animation() }
    public static func spring(duration: Double, bounce: Double = 0, blendDuration: Double = 0) -> Animation { Animation() }
    public func delay(_ delay: Double) -> Animation { self }
    public func speed(_ speed: Double) -> Animation { self }
    public func repeatForever(autoreverses: Bool = true) -> Animation { self }
}

/// SwiftUI's `withAnimation`: applies the change (without motion on Windows).
@discardableResult
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try body()
}

extension SwiftCrossUI.View {
    /// SwiftUI's `animation(_:value:)`: the view still updates when `value` changes, without motion.
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some SwiftCrossUI.View { self }
}
#endif
