// CircuitPortKit — SwiftUI's shape styles on SwiftCrossUI: ShapeStyle, AnyShapeStyle, gradients as
// fills, strokes and foregrounds, materials, .tint, Color.primary / .secondary / .accentColor, and
// SwiftUI's `.background(.red)` shorthand; Gradient(colors:) / Gradient(stops:), Font.custom.
//
// Approximated on Windows (listed per app in CONVERSION.md):
//   - A gradient used as a text or icon color, or as a stroke, draws in the gradient's middle color.
//     A gradient filling a rectangle, rounded rectangle, capsule or (square) circle is drawn exactly.
//   - Materials are a translucent tint of the window background, without the blur behind it.
//   - Font.custom uses the system font at the requested size (SwiftCrossUI draws the system font).
//   - .firstTextBaseline / .lastTextBaseline align rows by their centers.
#if canImport(SwiftCrossUI) && (!canImport(SwiftUI) || CIRCUIT_WINDOWS_SIM)
import Foundation
import SwiftCrossUI

// MARK: - Gradients (plain values, as in SwiftUI: usable in a `static let` outside any view)

/// SwiftUI's `Gradient`: colors at locations along it. A converted app's `Gradient` refers to this
/// type (a module-level alias Circuit generates), drawn by SwiftCrossUI's gradient views.
public struct CircuitGradient: Sendable, Hashable {
    public typealias Stop = SwiftCrossUI.Gradient.Stop
    public var stops: [Stop]

    public init(stops: [Stop]) { self.stops = stops }

    /// Evenly spaced colors.
    public init(colors: [SwiftCrossUI.Color]) {
        if colors.count == 1 {
            stops = [Stop(color: colors[0], location: 0), Stop(color: colors[0], location: 1)]
        } else {
            let last = Double(max(colors.count - 1, 1))
            stops = colors.enumerated().map { Stop(color: $0.element, location: Double($0.offset) / last) }
        }
    }
}

/// SwiftUI's `LinearGradient`.
public struct CircuitLinearGradient: Sendable {
    public var gradient: CircuitGradient
    public var startPoint: SwiftCrossUI.UnitPoint
    public var endPoint: SwiftCrossUI.UnitPoint

    public init(gradient: CircuitGradient, startPoint: SwiftCrossUI.UnitPoint, endPoint: SwiftCrossUI.UnitPoint) {
        self.gradient = gradient
        self.startPoint = startPoint
        self.endPoint = endPoint
    }
    public init(colors: [SwiftCrossUI.Color], startPoint: SwiftCrossUI.UnitPoint, endPoint: SwiftCrossUI.UnitPoint) {
        self.init(gradient: CircuitGradient(colors: colors), startPoint: startPoint, endPoint: endPoint)
    }
    public init(stops: [CircuitGradient.Stop], startPoint: SwiftCrossUI.UnitPoint, endPoint: SwiftCrossUI.UnitPoint) {
        self.init(gradient: CircuitGradient(stops: stops), startPoint: startPoint, endPoint: endPoint)
    }
}

extension CircuitLinearGradient: SwiftCrossUI.View {
    public var body: some SwiftCrossUI.View {
        SwiftCrossUI.LinearGradient(stops: gradient.stops, startPoint: startPoint, endPoint: endPoint)
    }
}

/// SwiftUI's `RadialGradient`.
public struct CircuitRadialGradient: Sendable {
    public var gradient: CircuitGradient
    public var center: SwiftCrossUI.UnitPoint
    public var startRadius: Double
    public var endRadius: Double

    public init(gradient: CircuitGradient, center: SwiftCrossUI.UnitPoint, startRadius: Double, endRadius: Double) {
        self.gradient = gradient
        self.center = center
        self.startRadius = startRadius
        self.endRadius = endRadius
    }
    public init(colors: [SwiftCrossUI.Color], center: SwiftCrossUI.UnitPoint, startRadius: Double, endRadius: Double) {
        self.init(gradient: CircuitGradient(colors: colors), center: center, startRadius: startRadius, endRadius: endRadius)
    }
    public init(stops: [CircuitGradient.Stop], center: SwiftCrossUI.UnitPoint, startRadius: Double, endRadius: Double) {
        self.init(gradient: CircuitGradient(stops: stops), center: center, startRadius: startRadius, endRadius: endRadius)
    }
}

extension CircuitRadialGradient: SwiftCrossUI.View {
    public var body: some SwiftCrossUI.View {
        SwiftCrossUI.RadialGradient(stops: gradient.stops, center: center, startRadius: startRadius, endRadius: endRadius)
    }
}

/// SwiftUI's `AngularGradient`.
public struct CircuitAngularGradient: Sendable {
    public var gradient: CircuitGradient
    public var center: SwiftCrossUI.UnitPoint
    public var startAngle: SwiftCrossUI.Angle
    public var endAngle: SwiftCrossUI.Angle?

    public init(gradient: CircuitGradient, center: SwiftCrossUI.UnitPoint, angle: SwiftCrossUI.Angle = .zero) {
        self.gradient = gradient
        self.center = center
        startAngle = angle
        endAngle = nil
    }
    public init(gradient: CircuitGradient, center: SwiftCrossUI.UnitPoint, startAngle: SwiftCrossUI.Angle, endAngle: SwiftCrossUI.Angle) {
        self.gradient = gradient
        self.center = center
        self.startAngle = startAngle
        self.endAngle = endAngle
    }
    public init(colors: [SwiftCrossUI.Color], center: SwiftCrossUI.UnitPoint, angle: SwiftCrossUI.Angle = .zero) {
        self.init(gradient: CircuitGradient(colors: colors), center: center, angle: angle)
    }
    public init(colors: [SwiftCrossUI.Color], center: SwiftCrossUI.UnitPoint, startAngle: SwiftCrossUI.Angle, endAngle: SwiftCrossUI.Angle) {
        self.init(gradient: CircuitGradient(colors: colors), center: center, startAngle: startAngle, endAngle: endAngle)
    }
    public init(stops: [CircuitGradient.Stop], center: SwiftCrossUI.UnitPoint, angle: SwiftCrossUI.Angle = .zero) {
        self.init(gradient: CircuitGradient(stops: stops), center: center, angle: angle)
    }
}

extension CircuitAngularGradient: SwiftCrossUI.View {
    public var body: some SwiftCrossUI.View {
        if let endAngle {
            SwiftCrossUI.AngularGradient(stops: gradient.stops, center: center, startAngle: startAngle, endAngle: endAngle)
        } else {
            SwiftCrossUI.AngularGradient(stops: gradient.stops, center: center, angle: startAngle)
        }
    }
}

// MARK: - Paint

/// What a shape style paints with, resolved against the environment when drawn.
public enum CircuitPaint: Sendable {
    case color(SwiftCrossUI.Color)
    case linear(CircuitLinearGradient)
    case radial(CircuitRadialGradient)
    case angular(CircuitAngularGradient)
    /// The window background at an opacity (materials, `.background`).
    case windowBackground(opacity: Double)
    /// The foreground color at an opacity (`.foreground`, `ForegroundStyle()`).
    case foreground(opacity: Double)
    /// The tint set with `.tint(_:)`, else the accent color.
    case tint

    @MainActor
    func color(in environment: SwiftCrossUI.EnvironmentValues) -> SwiftCrossUI.Color {
        switch self {
        case .color(let color): return color
        case .linear(let gradient): return Self.middle(of: gradient.gradient, in: environment)
        case .radial(let gradient): return Self.middle(of: gradient.gradient, in: environment)
        case .angular(let gradient): return Self.middle(of: gradient.gradient, in: environment)
        case .windowBackground(let opacity): return SwiftCrossUI.Color.circuitWindowBackground.opacity(opacity)
        case .foreground(let opacity): return environment.suggestedForegroundColor.opacity(opacity)
        case .tint: return environment[CircuitTintKey.self] ?? .accentColor
        }
    }

    /// The gradient's color halfway along it, mixed from the two stops around the middle.
    @MainActor
    static func middle(of gradient: CircuitGradient, in environment: SwiftCrossUI.EnvironmentValues) -> SwiftCrossUI.Color {
        let stops = gradient.stops
        guard let first = stops.first else { return .clear }
        var lower = first, upper = stops.last ?? first
        for stop in stops {
            if stop.location <= 0.5 { lower = stop }
            if stop.location >= 0.5 { upper = stop; break }
        }
        let a = lower.color.resolve(in: environment), b = upper.color.resolve(in: environment)
        let span = upper.location - lower.location
        let t = Float(span > 0 ? (0.5 - lower.location) / span : 0)
        return SwiftCrossUI.Color(SwiftCrossUI.Color.Resolved(
            red: a.red + (b.red - a.red) * t,
            green: a.green + (b.green - a.green) * t,
            blue: a.blue + (b.blue - a.blue) * t,
            opacity: a.opacity + (b.opacity - a.opacity) * t
        ))
    }

    /// The gradient view, when the paint is a gradient.
    @MainActor
    var gradientView: SwiftCrossUI.AnyView? {
        switch self {
        case .linear(let gradient): return SwiftCrossUI.AnyView(gradient)
        case .radial(let gradient): return SwiftCrossUI.AnyView(gradient)
        case .angular(let gradient): return SwiftCrossUI.AnyView(gradient)
        default: return nil
        }
    }
}

/// SwiftUI's `ShapeStyle`: a color, gradient or material to fill, stroke or color content with.
public protocol ShapeStyle {
    var circuitPaint: CircuitPaint { get }
}

extension SwiftCrossUI.Color: ShapeStyle {
    public var circuitPaint: CircuitPaint { .color(self) }
}
extension CircuitLinearGradient: ShapeStyle {
    public var circuitPaint: CircuitPaint { .linear(self) }
}
extension CircuitRadialGradient: ShapeStyle {
    public var circuitPaint: CircuitPaint { .radial(self) }
}
extension CircuitAngularGradient: ShapeStyle {
    public var circuitPaint: CircuitPaint { .angular(self) }
}

// The styles below are plain values (usable anywhere) that are also views, filling their frame,
// as a style is in SwiftUI's `.background(_:)`; the view conformance is kept in an extension so
// their initializers stay usable outside the main actor.

/// SwiftUI's type-erased shape style.
public struct AnyShapeStyle: ShapeStyle, Sendable {
    public let circuitPaint: CircuitPaint
    public init<S: ShapeStyle>(_ style: S) { circuitPaint = style.circuitPaint }
}

/// SwiftUI's materials. Windows draws them as a translucent tint of the window background.
public struct Material: ShapeStyle, Sendable {
    let opacity: Double
    public var circuitPaint: CircuitPaint { .windowBackground(opacity: opacity) }

    public static let ultraThin = Material(opacity: 0.35)
    public static let thin = Material(opacity: 0.5)
    public static let regular = Material(opacity: 0.65)
    public static let thick = Material(opacity: 0.8)
    public static let ultraThick = Material(opacity: 0.9)
    public static let bar = Material(opacity: 0.8)
}

/// SwiftUI's `.tint` style: the color set with `.tint(_:)`, else the accent color.
public struct TintShapeStyle: ShapeStyle, Sendable {
    public init() {}
    public var circuitPaint: CircuitPaint { .tint }
}

/// SwiftUI's `ForegroundStyle()` / `.foreground`.
public struct ForegroundStyle: ShapeStyle, Sendable {
    public init() {}
    public var circuitPaint: CircuitPaint { .foreground(opacity: 1) }
}

/// SwiftUI's `BackgroundStyle()` / `.background`: the window background.
public struct BackgroundStyle: ShapeStyle, Sendable {
    public init() {}
    public var circuitPaint: CircuitPaint { .windowBackground(opacity: 1) }
}

extension AnyShapeStyle: SwiftCrossUI.View {
    public var body: some SwiftCrossUI.View { CircuitPaintView(paint: circuitPaint) }
}
extension Material: SwiftCrossUI.View {
    public var body: some SwiftCrossUI.View { CircuitPaintView(paint: circuitPaint) }
}
extension TintShapeStyle: SwiftCrossUI.View {
    public var body: some SwiftCrossUI.View { CircuitPaintView(paint: circuitPaint) }
}
extension ForegroundStyle: SwiftCrossUI.View {
    public var body: some SwiftCrossUI.View { CircuitPaintView(paint: circuitPaint) }
}
extension BackgroundStyle: SwiftCrossUI.View {
    public var body: some SwiftCrossUI.View { CircuitPaintView(paint: circuitPaint) }
}

/// A paint filling its frame (gradients as themselves, the rest as their resolved color).
struct CircuitPaintView: SwiftCrossUI.View {
    let paint: CircuitPaint
    @SwiftCrossUI.Environment(\.self) var environment

    var body: some SwiftCrossUI.View {
        if let gradient = paint.gradientView {
            gradient
        } else {
            paint.color(in: environment)
        }
    }
}

// MARK: - Static members (SwiftUI's `.secondary`, `.ultraThinMaterial`, `.tint`, `.linearGradient(…)`)

extension ShapeStyle where Self == Material {
    public static var ultraThinMaterial: Material { .ultraThin }
    public static var thinMaterial: Material { .thin }
    public static var regularMaterial: Material { .regular }
    public static var thickMaterial: Material { .thick }
    public static var ultraThickMaterial: Material { .ultraThick }
    public static var bar: Material { Material.bar }
}

extension ShapeStyle where Self == TintShapeStyle {
    public static var tint: TintShapeStyle { TintShapeStyle() }
}

extension ShapeStyle where Self == ForegroundStyle {
    public static var foreground: ForegroundStyle { ForegroundStyle() }
}

extension ShapeStyle where Self == BackgroundStyle {
    public static var background: BackgroundStyle { BackgroundStyle() }
}

extension ShapeStyle where Self == CircuitLinearGradient {
    public static func linearGradient(colors: [SwiftCrossUI.Color], startPoint: SwiftCrossUI.UnitPoint, endPoint: SwiftCrossUI.UnitPoint) -> CircuitLinearGradient {
        CircuitLinearGradient(colors: colors, startPoint: startPoint, endPoint: endPoint)
    }
    public static func linearGradient(stops: [CircuitGradient.Stop], startPoint: SwiftCrossUI.UnitPoint, endPoint: SwiftCrossUI.UnitPoint) -> CircuitLinearGradient {
        CircuitLinearGradient(stops: stops, startPoint: startPoint, endPoint: endPoint)
    }
    public static func linearGradient(_ gradient: CircuitGradient, startPoint: SwiftCrossUI.UnitPoint, endPoint: SwiftCrossUI.UnitPoint) -> CircuitLinearGradient {
        CircuitLinearGradient(gradient: gradient, startPoint: startPoint, endPoint: endPoint)
    }
}

extension ShapeStyle where Self == CircuitRadialGradient {
    public static func radialGradient(colors: [SwiftCrossUI.Color], center: SwiftCrossUI.UnitPoint, startRadius: Double, endRadius: Double) -> CircuitRadialGradient {
        CircuitRadialGradient(colors: colors, center: center, startRadius: startRadius, endRadius: endRadius)
    }
    public static func radialGradient(_ gradient: CircuitGradient, center: SwiftCrossUI.UnitPoint, startRadius: Double, endRadius: Double) -> CircuitRadialGradient {
        CircuitRadialGradient(gradient: gradient, center: center, startRadius: startRadius, endRadius: endRadius)
    }
}

/// Colors by name where any style is accepted (`AnyShapeStyle(.secondary)`, `.fill(.quaternary)`).
extension ShapeStyle where Self == SwiftCrossUI.Color {
    public static var black: SwiftCrossUI.Color { SwiftCrossUI.Color.black }
    public static var white: SwiftCrossUI.Color { SwiftCrossUI.Color.white }
    public static var clear: SwiftCrossUI.Color { SwiftCrossUI.Color.clear }
    public static var gray: SwiftCrossUI.Color { SwiftCrossUI.Color.gray }
    public static var red: SwiftCrossUI.Color { SwiftCrossUI.Color.red }
    public static var orange: SwiftCrossUI.Color { SwiftCrossUI.Color.orange }
    public static var yellow: SwiftCrossUI.Color { SwiftCrossUI.Color.yellow }
    public static var green: SwiftCrossUI.Color { SwiftCrossUI.Color.green }
    public static var mint: SwiftCrossUI.Color { SwiftCrossUI.Color.mint }
    public static var teal: SwiftCrossUI.Color { SwiftCrossUI.Color.teal }
    public static var cyan: SwiftCrossUI.Color { SwiftCrossUI.Color.cyan }
    public static var blue: SwiftCrossUI.Color { SwiftCrossUI.Color.blue }
    public static var indigo: SwiftCrossUI.Color { SwiftCrossUI.Color.indigo }
    public static var purple: SwiftCrossUI.Color { SwiftCrossUI.Color.purple }
    public static var pink: SwiftCrossUI.Color { SwiftCrossUI.Color.pink }
    public static var brown: SwiftCrossUI.Color { SwiftCrossUI.Color.brown }
    public static var primary: SwiftCrossUI.Color { SwiftCrossUI.Color.primary }
    public static var secondary: SwiftCrossUI.Color { SwiftCrossUI.Color.secondary }
    public static var tertiary: SwiftCrossUI.Color { SwiftCrossUI.Color.tertiary }
    public static var quaternary: SwiftCrossUI.Color { SwiftCrossUI.Color.quaternary }
    public static var quinary: SwiftCrossUI.Color { SwiftCrossUI.Color.quinary }
    public static var accentColor: SwiftCrossUI.Color { SwiftCrossUI.Color.accentColor }
}

extension SwiftCrossUI.Color {
    /// SwiftUI's `Color.primary`: the text color (black in light mode, white in dark).
    public static var primary: SwiftCrossUI.Color { .adaptive(light: SwiftCrossUI.Color(white: 0, opacity: 0.85), dark: SwiftCrossUI.Color(white: 1, opacity: 0.85)) }
    /// SwiftUI's `Color.secondary` (and `.tertiary` / `.quaternary` / `.quinary` below): the
    /// secondary label colors of macOS, as translucent black or white.
    public static var secondary: SwiftCrossUI.Color { .adaptive(light: SwiftCrossUI.Color(white: 0, opacity: 0.5), dark: SwiftCrossUI.Color(white: 1, opacity: 0.55)) }
    public static var tertiary: SwiftCrossUI.Color { .adaptive(light: SwiftCrossUI.Color(white: 0, opacity: 0.26), dark: SwiftCrossUI.Color(white: 1, opacity: 0.25)) }
    public static var quaternary: SwiftCrossUI.Color { .adaptive(light: SwiftCrossUI.Color(white: 0, opacity: 0.1), dark: SwiftCrossUI.Color(white: 1, opacity: 0.1)) }
    public static var quinary: SwiftCrossUI.Color { .adaptive(light: SwiftCrossUI.Color(white: 0, opacity: 0.05), dark: SwiftCrossUI.Color(white: 1, opacity: 0.05)) }
    /// SwiftUI's `Color.accentColor`: the system accent blue.
    public static var accentColor: SwiftCrossUI.Color { .blue }
    /// The window background color.
    static var circuitWindowBackground: SwiftCrossUI.Color { .adaptive(light: SwiftCrossUI.Color(white: 0.96), dark: SwiftCrossUI.Color(white: 0.16)) }
}

/// SwiftUI's `.background(.red)` / `.overlay(.blue)` shorthand: a color, material or style as the view.
extension SwiftCrossUI.View where Self == SwiftCrossUI.Color {
    public static var black: SwiftCrossUI.Color { SwiftCrossUI.Color.black }
    public static var white: SwiftCrossUI.Color { SwiftCrossUI.Color.white }
    public static var clear: SwiftCrossUI.Color { SwiftCrossUI.Color.clear }
    public static var gray: SwiftCrossUI.Color { SwiftCrossUI.Color.gray }
    public static var red: SwiftCrossUI.Color { SwiftCrossUI.Color.red }
    public static var orange: SwiftCrossUI.Color { SwiftCrossUI.Color.orange }
    public static var yellow: SwiftCrossUI.Color { SwiftCrossUI.Color.yellow }
    public static var green: SwiftCrossUI.Color { SwiftCrossUI.Color.green }
    public static var mint: SwiftCrossUI.Color { SwiftCrossUI.Color.mint }
    public static var teal: SwiftCrossUI.Color { SwiftCrossUI.Color.teal }
    public static var cyan: SwiftCrossUI.Color { SwiftCrossUI.Color.cyan }
    public static var blue: SwiftCrossUI.Color { SwiftCrossUI.Color.blue }
    public static var indigo: SwiftCrossUI.Color { SwiftCrossUI.Color.indigo }
    public static var purple: SwiftCrossUI.Color { SwiftCrossUI.Color.purple }
    public static var pink: SwiftCrossUI.Color { SwiftCrossUI.Color.pink }
    public static var brown: SwiftCrossUI.Color { SwiftCrossUI.Color.brown }
    public static var primary: SwiftCrossUI.Color { SwiftCrossUI.Color.primary }
    public static var secondary: SwiftCrossUI.Color { SwiftCrossUI.Color.secondary }
    public static var tertiary: SwiftCrossUI.Color { SwiftCrossUI.Color.tertiary }
    public static var quaternary: SwiftCrossUI.Color { SwiftCrossUI.Color.quaternary }
    public static var accentColor: SwiftCrossUI.Color { SwiftCrossUI.Color.accentColor }
}

extension SwiftCrossUI.View where Self == Material {
    public static var ultraThinMaterial: Material { .ultraThin }
    public static var thinMaterial: Material { .thin }
    public static var regularMaterial: Material { .regular }
    public static var thickMaterial: Material { .thick }
    public static var ultraThickMaterial: Material { .ultraThick }
    public static var bar: Material { Material.bar }
}

extension SwiftCrossUI.View where Self == TintShapeStyle {
    public static var tint: TintShapeStyle { TintShapeStyle() }
}

extension SwiftCrossUI.View where Self == BackgroundStyle {
    public static var background: BackgroundStyle { BackgroundStyle() }
}

// MARK: - Styles applied: foreground, fill, stroke, background

/// The tint `.tint(_:)` sets for `.tint` styles below it.
struct CircuitTintKey: SwiftCrossUI.EnvironmentKey {
    static var defaultValue: SwiftCrossUI.Color? { nil }
}

/// Content colored with a style resolved in the current environment.
struct CircuitForegroundStyled<Content: SwiftCrossUI.View>: SwiftCrossUI.View {
    let content: Content
    let paint: CircuitPaint
    @SwiftCrossUI.Environment(\.self) var environment
    var body: some SwiftCrossUI.View { content.foregroundColor(paint.color(in: environment)) }
}

extension SwiftCrossUI.View {
    /// SwiftUI's `foregroundStyle(_:)` with any style. Gradients color text and icons with their
    /// middle color on Windows.
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> some SwiftCrossUI.View {
        CircuitForegroundStyled(content: self, paint: style.circuitPaint)
    }
    /// SwiftUI's hierarchical `foregroundStyle(_:_:)`: the primary style colors the content.
    public func foregroundStyle<S1: ShapeStyle, S2: ShapeStyle>(_ primary: S1, _ secondary: S2) -> some SwiftCrossUI.View {
        foregroundStyle(primary)
    }
    public func foregroundStyle<S1: ShapeStyle, S2: ShapeStyle, S3: ShapeStyle>(_ primary: S1, _ secondary: S2, _ tertiary: S3) -> some SwiftCrossUI.View {
        foregroundStyle(primary)
    }

    /// SwiftUI's `tint(_:)`: the color `.tint` styles below draw with. (Windows' own controls keep
    /// the system accent color.)
    public func tint(_ tint: SwiftCrossUI.Color?) -> some SwiftCrossUI.View {
        environment(\.circuitTint, tint)
    }

    /// SwiftUI's `background(_:in:)` with any style.
    public func background<St: ShapeStyle, Sh: SwiftCrossUI.Shape>(_ style: St, in shape: Sh) -> some SwiftCrossUI.View {
        background(shape.fill(style))
    }
}

extension SwiftCrossUI.EnvironmentValues {
    public var circuitTint: SwiftCrossUI.Color? {
        get { self[CircuitTintKey.self] }
        set { self[CircuitTintKey.self] = newValue }
    }
}

/// The corner radius that clips a rectangle into this shape, for the shapes that are rounded
/// rectangles (a circle only when its frame is square).
func circuitClipRadius<S: SwiftCrossUI.Shape>(_ shape: S) -> Int? {
    if shape is SwiftCrossUI.Rectangle { return 0 }
    if let rounded = shape as? SwiftCrossUI.RoundedRectangle { return Int(rounded.cornerRadius.rounded()) }
    if shape is SwiftCrossUI.Capsule || shape is SwiftCrossUI.Circle { return 10_000 }
    return nil
}

/// A shape filled with a style: a gradient exactly where the shape is a rounded rectangle, the
/// style's color otherwise.
struct CircuitShapeFill<S: SwiftCrossUI.Shape>: SwiftCrossUI.View {
    let shape: S
    let paint: CircuitPaint
    @SwiftCrossUI.Environment(\.self) var environment

    var body: some SwiftCrossUI.View {
        if let gradient = paint.gradientView, let radius = circuitClipRadius(shape) {
            gradient.cornerRadius(radius)
        } else {
            shape.fill(paint.color(in: environment))
        }
    }
}

/// A shape stroked with a style's color (a gradient's middle color).
struct CircuitShapeStroke<S: SwiftCrossUI.Shape>: SwiftCrossUI.View {
    let shape: S
    let paint: CircuitPaint?
    let style: SwiftCrossUI.StrokeStyle
    let inside: Bool
    @SwiftCrossUI.Environment(\.self) var environment

    var body: some SwiftCrossUI.View {
        let color = paint?.color(in: environment) ?? environment.suggestedForegroundColor
        let inset = inside ? Int((style.width / 2).rounded(.up)) : 0
        return shape.stroke(color, style: style).padding(inset)
    }
}

extension SwiftCrossUI.Shape {
    /// SwiftUI's `fill(_:)` with any style.
    @MainActor public func fill<St: ShapeStyle>(_ style: St) -> some SwiftCrossUI.View {
        CircuitShapeFill(shape: self, paint: style.circuitPaint)
    }
    /// SwiftUI's `stroke(_:lineWidth:)` with any style.
    @MainActor public func stroke<St: ShapeStyle>(_ style: St, lineWidth: Double = 1) -> some SwiftCrossUI.View {
        CircuitShapeStroke(shape: self, paint: style.circuitPaint, style: SwiftCrossUI.StrokeStyle(width: lineWidth), inside: false)
    }
    /// SwiftUI's `stroke(_:style:)` with any style.
    @MainActor public func stroke<St: ShapeStyle>(_ style: St, style strokeStyle: SwiftCrossUI.StrokeStyle) -> some SwiftCrossUI.View {
        CircuitShapeStroke(shape: self, paint: style.circuitPaint, style: strokeStyle, inside: false)
    }
    /// SwiftUI's `stroke(lineWidth:)`: stroked in the foreground color.
    @MainActor public func stroke(lineWidth: Double) -> some SwiftCrossUI.View {
        CircuitShapeStroke(shape: self, paint: nil, style: SwiftCrossUI.StrokeStyle(width: lineWidth), inside: false)
    }
    /// SwiftUI's `stroke(style:)`: stroked in the foreground color.
    @MainActor public func stroke(style strokeStyle: SwiftCrossUI.StrokeStyle) -> some SwiftCrossUI.View {
        CircuitShapeStroke(shape: self, paint: nil, style: strokeStyle, inside: false)
    }
    /// SwiftUI's `strokeBorder(_:lineWidth:)` with any style: the stroke inside the frame.
    @MainActor public func strokeBorder<St: ShapeStyle>(_ style: St, lineWidth: Double = 1) -> some SwiftCrossUI.View {
        CircuitShapeStroke(shape: self, paint: style.circuitPaint, style: SwiftCrossUI.StrokeStyle(width: lineWidth), inside: true)
    }
    @MainActor public func strokeBorder<St: ShapeStyle>(_ style: St, style strokeStyle: SwiftCrossUI.StrokeStyle) -> some SwiftCrossUI.View {
        CircuitShapeStroke(shape: self, paint: style.circuitPaint, style: strokeStyle, inside: true)
    }
    /// SwiftUI's `strokeBorder(lineWidth:)`: in the foreground color.
    @MainActor public func strokeBorder(lineWidth: Double) -> some SwiftCrossUI.View {
        CircuitShapeStroke(shape: self, paint: nil, style: SwiftCrossUI.StrokeStyle(width: lineWidth), inside: true)
    }
}

// MARK: - Fonts and alignment

extension SwiftCrossUI.Font {
    /// SwiftUI's `Font.custom(_:size:)`: the system font at that size on Windows.
    public static func custom(_ name: String, size: Double) -> SwiftCrossUI.Font { .system(size: size) }
    public static func custom(_ name: String, size: Double, relativeTo textStyle: SwiftCrossUI.Font.TextStyle) -> SwiftCrossUI.Font { .system(size: size) }
    public static func custom(_ name: String, fixedSize: Double) -> SwiftCrossUI.Font { .system(size: fixedSize) }
    /// SwiftUI's `Font.bold()`.
    public func bold() -> SwiftCrossUI.Font { weight(.bold) }
}

extension SwiftCrossUI.VerticalAlignment {
    /// Rows aligned by their text baselines in SwiftUI; by their centers on Windows.
    public static var firstTextBaseline: SwiftCrossUI.VerticalAlignment { .center }
    public static var lastTextBaseline: SwiftCrossUI.VerticalAlignment { .center }
}
#endif
