// CircuitPortKit — more of SwiftUI on SwiftCrossUI: Path with CGPoint, CGFloat measurements,
// clipShape(Capsule/Circle), Toggle(isOn:label:), sheet(item:), Slider(step:), Stepper,
// LazyVStack/LazyHStack, TimelineView, ViewModifier, confirmationDialog, Text(date, style:),
// Button(role:), StrokeStyle(lineWidth:lineCap:lineJoin:), ignoresSafeArea.
//
// Where Windows draws it differently, stated here and listed per app in CONVERSION.md
// ("approximated on Windows"):
//   - LazyVGrid / LazyHGrid lay their items out in one column / one row (SwiftCrossUI has no grid
//     layout yet); every item is there, the arrangement differs.
//   - confirmationDialog is presented as an alert; Button(role:) has no destructive tint.
//   - Text(date, style: .relative / .offset / .timer) shows the value when drawn, not a live count.
//   - StrokeStyle dash patterns are drawn as solid lines.
#if canImport(SwiftCrossUI) && (!canImport(SwiftUI) || CIRCUIT_WINDOWS_SIM)
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics // CGRect's geometry on the Mac (Foundation carries it everywhere else)
#endif
import SwiftCrossUI

/// Internal mutability for wrappers the view graph recreates with each body pass.
final class CircuitBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - Path, with SwiftUI's CGPoint / CGRect API and its build-in-place style

// SwiftUI fills a path with the nonzero (winding) rule; SwiftCrossUI's paths start even-odd, so a
// path built with SwiftUI's API switches to winding.
extension SwiftCrossUI.Path {
    /// SwiftUI's `Path { path in … }`.
    public init(_ build: (inout SwiftCrossUI.Path) -> Void) {
        self = SwiftCrossUI.Path().fillRule(.winding)
        build(&self)
    }

    static func point(_ p: CGPoint) -> SIMD2<Double> { SIMD2(Double(p.x), Double(p.y)) }

    public mutating func move(to point: CGPoint) {
        self = actions.isEmpty ? self.fillRule(.winding).move(to: Self.point(point)) : self.move(to: Self.point(point))
    }
    public mutating func addLine(to point: CGPoint) { self = self.addLine(to: Self.point(point)) }
    public mutating func addLines(_ points: [CGPoint]) {
        guard let first = points.first else { return }
        move(to: first)
        for p in points.dropFirst() { addLine(to: p) }
    }
    public mutating func addQuadCurve(to end: CGPoint, control: CGPoint) {
        self = self.addQuadCurve(control: Self.point(control), to: Self.point(end))
    }
    public mutating func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint) {
        self = self.addCubicCurve(control1: Self.point(control1), control2: Self.point(control2), to: Self.point(end))
    }
    public mutating func addRect(_ rect: CGRect) {
        if actions.isEmpty { self = self.fillRule(.winding) }
        self = self.addRectangle(SwiftCrossUI.Path.Rect(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height)))
    }
    /// An ellipse as four cubic Béziers (the standard 0.5523 control distance).
    public mutating func addEllipse(in rect: CGRect) {
        if actions.isEmpty { self = self.fillRule(.winding) }
        let k = 0.5522847498
        let cx = Double(rect.midX), cy = Double(rect.midY), rx = Double(rect.width) / 2, ry = Double(rect.height) / 2
        self = self.move(to: SIMD2(cx + rx, cy))
            .addCubicCurve(control1: SIMD2(cx + rx, cy + k * ry), control2: SIMD2(cx + k * rx, cy + ry), to: SIMD2(cx, cy + ry))
            .addCubicCurve(control1: SIMD2(cx - k * rx, cy + ry), control2: SIMD2(cx - rx, cy + k * ry), to: SIMD2(cx - rx, cy))
            .addCubicCurve(control1: SIMD2(cx - rx, cy - k * ry), control2: SIMD2(cx - k * rx, cy - ry), to: SIMD2(cx, cy - ry))
            .addCubicCurve(control1: SIMD2(cx + k * rx, cy - ry), control2: SIMD2(cx + rx, cy - k * ry), to: SIMD2(cx + rx, cy))
    }
    /// Back to where the current subpath started.
    public mutating func closeSubpath() {
        for action in actions.reversed() {
            if case .moveTo(let start) = action {
                self = self.addLine(to: start)
                return
            }
        }
    }
}

/// SwiftUI's `Path` is itself a shape: drawn where its points are, filled or stroked like any other.
extension SwiftCrossUI.Path: @retroactive SwiftCrossUI.Shape {
    public nonisolated func path(in bounds: SwiftCrossUI.Path.Rect) -> SwiftCrossUI.Path { self }
}

// MARK: - Measurements given as CGFloat / Double (SwiftCrossUI takes whole points)

extension SwiftCrossUI.View {
    public func padding(_ length: Double) -> some SwiftCrossUI.View { padding(.all, Int(length.rounded())) }
    public func padding(_ edges: SwiftCrossUI.Edge.Set, _ length: Double) -> some SwiftCrossUI.View { padding(edges, Int(length.rounded())) }
    public func cornerRadius(_ radius: Double) -> some SwiftCrossUI.View { cornerRadius(Int(radius.rounded())) }

    /// SwiftUI's `clipShape(Capsule())`: rounded ends. The backends clamp a corner radius to half
    /// the view's shorter side (WinUI and AppKit both do), which is exactly a capsule.
    public func clipShape(_ shape: SwiftCrossUI.Capsule) -> some SwiftCrossUI.View { cornerRadius(10_000) }
    /// SwiftUI's `clipShape(Circle())`: a circle on a square view (the common avatar case); on a
    /// non-square view, rounded ends.
    public func clipShape(_ shape: SwiftCrossUI.Circle) -> some SwiftCrossUI.View { cornerRadius(10_000) }

    /// A desktop window has no safe area to ignore.
    public func ignoresSafeArea(_ regions: CircuitSafeAreaRegions = .all, edges: SwiftCrossUI.Edge.Set = .all) -> some SwiftCrossUI.View { self }
}

public struct CircuitSafeAreaRegions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let container = CircuitSafeAreaRegions(rawValue: 1)
    public static let keyboard = CircuitSafeAreaRegions(rawValue: 2)
    public static let all: CircuitSafeAreaRegions = [.container, .keyboard]
}

extension SwiftCrossUI.VStack {
    public init(alignment: SwiftCrossUI.HorizontalAlignment = .center, spacing: Double?, @SwiftCrossUI.ViewBuilder content: () -> Content) {
        self.init(alignment: alignment, spacing: spacing.map { Int($0.rounded()) }, content: content)
    }
}

extension SwiftCrossUI.HStack {
    public init(alignment: SwiftCrossUI.VerticalAlignment = .center, spacing: Double?, @SwiftCrossUI.ViewBuilder content: () -> Content) {
        self.init(alignment: alignment, spacing: spacing.map { Int($0.rounded()) }, content)
    }
}

// MARK: - Controls

extension SwiftCrossUI.Toggle {
    /// SwiftUI's `Toggle(isOn:) { Text(…) }`.
    public init(isOn: SwiftCrossUI.Binding<Bool>, label: () -> SwiftCrossUI.Text) {
        self.init(label().string, isOn: isOn)
    }
}

extension SwiftCrossUI.Slider {
    /// SwiftUI's `Slider(value:in:step:)`: the value snaps to the step.
    public init<T: BinaryFloatingPoint>(value: SwiftCrossUI.Binding<T>, in range: ClosedRange<T>, step: T) {
        let snapped = SwiftCrossUI.Binding<T>(
            get: { value.wrappedValue },
            set: { new in value.wrappedValue = step > 0 ? min(range.upperBound, max(range.lowerBound, (new / step).rounded() * step)) : new }
        )
        self.init(value: snapped, in: range)
    }
}

/// SwiftUI's `Stepper`: a value with − and + buttons, kept within its range when it has one.
public struct Stepper<LabelContent: SwiftCrossUI.View>: SwiftCrossUI.View {
    let label: LabelContent
    let decrement: @MainActor @Sendable () -> Void
    let increment: @MainActor @Sendable () -> Void

    init(labelView: LabelContent, onIncrement: (@MainActor @Sendable () -> Void)?, onDecrement: (@MainActor @Sendable () -> Void)?) {
        label = labelView
        increment = onIncrement ?? {}
        decrement = onDecrement ?? {}
    }

    init<V: Strideable>(labelView: LabelContent, value: SwiftCrossUI.Binding<V>, in range: ClosedRange<V>?, step: V.Stride) {
        let box = CircuitBox((value, range, step))
        self.init(
            labelView: labelView,
            onIncrement: {
                let (value, range, step) = box.value
                let next = value.wrappedValue.advanced(by: step)
                value.wrappedValue = range.map { min($0.upperBound, next) } ?? next
            },
            onDecrement: {
                let (value, range, step) = box.value
                let next = value.wrappedValue.advanced(by: -step)
                value.wrappedValue = range.map { max($0.lowerBound, next) } ?? next
            }
        )
    }

    public init<V: Strideable>(value: SwiftCrossUI.Binding<V>, in range: ClosedRange<V>, step: V.Stride = 1, @SwiftCrossUI.ViewBuilder label: () -> LabelContent) {
        self.init(labelView: label(), value: value, in: range, step: step)
    }

    public init<V: Strideable>(value: SwiftCrossUI.Binding<V>, step: V.Stride = 1, @SwiftCrossUI.ViewBuilder label: () -> LabelContent) {
        self.init(labelView: label(), value: value, in: nil, step: step)
    }

    public init(@SwiftCrossUI.ViewBuilder label: () -> LabelContent, onIncrement: (@MainActor @Sendable () -> Void)?, onDecrement: (@MainActor @Sendable () -> Void)?) {
        self.init(labelView: label(), onIncrement: onIncrement, onDecrement: onDecrement)
    }

    public var body: some SwiftCrossUI.View {
        SwiftCrossUI.HStack(spacing: 8) {
            label
            SwiftCrossUI.Button("−", action: decrement)
            SwiftCrossUI.Button("+", action: increment)
        }
    }
}

extension Stepper where LabelContent == SwiftCrossUI.Text {
    public init<V: Strideable>(_ title: String, value: SwiftCrossUI.Binding<V>, in range: ClosedRange<V>, step: V.Stride = 1) {
        self.init(labelView: SwiftCrossUI.Text(title), value: value, in: range, step: step)
    }

    public init<V: Strideable>(_ title: String, value: SwiftCrossUI.Binding<V>, step: V.Stride = 1) {
        self.init(labelView: SwiftCrossUI.Text(title), value: value, in: nil, step: step)
    }

    public init(_ title: String, onIncrement: (@MainActor @Sendable () -> Void)?, onDecrement: (@MainActor @Sendable () -> Void)?) {
        self.init(labelView: SwiftCrossUI.Text(title), onIncrement: onIncrement, onDecrement: onDecrement)
    }
}

/// SwiftUI's button roles. Windows draws every role the same (no destructive tint).
public enum ButtonRole: Sendable { case cancel, destructive }

extension SwiftCrossUI.Button where Label == SwiftCrossUI.TupleView1<SwiftCrossUI.Text> {
    public init(_ label: String, role: ButtonRole?, action: @escaping @MainActor @Sendable () -> Void) {
        self.init(label, action: action)
    }
}

// MARK: - Presentation

extension SwiftCrossUI.View {
    /// SwiftUI's `sheet(item:)`: shown while the item is set, dismissed by clearing it.
    public func sheet<Item: Identifiable, SheetContent: SwiftCrossUI.View>(
        item: SwiftCrossUI.Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @SwiftCrossUI.ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some SwiftCrossUI.View {
        let isPresented = SwiftCrossUI.Binding<Bool>(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
        return sheet(isPresented: isPresented, onDismiss: onDismiss) {
            if let value = item.wrappedValue { content(value) }
        }
    }

    /// SwiftUI's `confirmationDialog`: presented as an alert with the same buttons.
    public func confirmationDialog(
        _ title: String,
        isPresented: SwiftCrossUI.Binding<Bool>,
        titleVisibility: SwiftCrossUI.Visibility = .automatic,
        @SwiftCrossUI.AlertActionsBuilder actions: () -> [SwiftCrossUI.AlertAction]
    ) -> some SwiftCrossUI.View {
        alert(title, isPresented: isPresented, actions: actions)
    }
}

// MARK: - Stacks and grids

public struct CircuitPinnedScrollableViews: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let sectionHeaders = CircuitPinnedScrollableViews(rawValue: 1)
    public static let sectionFooters = CircuitPinnedScrollableViews(rawValue: 2)
}

/// SwiftUI's `LazyVStack`: a `VStack` (every row is built; the layout is the same).
public struct LazyVStack<Content: SwiftCrossUI.View>: SwiftCrossUI.View {
    let alignment: SwiftCrossUI.HorizontalAlignment
    let spacing: Int?
    let content: Content
    public init(alignment: SwiftCrossUI.HorizontalAlignment = .center, spacing: Double? = nil, pinnedViews: CircuitPinnedScrollableViews = [], @SwiftCrossUI.ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing.map { Int($0.rounded()) }
        self.content = content()
    }
    public var body: some SwiftCrossUI.View { SwiftCrossUI.VStack(alignment: alignment, spacing: spacing) { content } }
}

/// SwiftUI's `LazyHStack`: an `HStack`.
public struct LazyHStack<Content: SwiftCrossUI.View>: SwiftCrossUI.View {
    let alignment: SwiftCrossUI.VerticalAlignment
    let spacing: Int?
    let content: Content
    public init(alignment: SwiftCrossUI.VerticalAlignment = .center, spacing: Double? = nil, pinnedViews: CircuitPinnedScrollableViews = [], @SwiftCrossUI.ViewBuilder content: () -> Content) {
        self.alignment = alignment
        self.spacing = spacing.map { Int($0.rounded()) }
        self.content = content()
    }
    public var body: some SwiftCrossUI.View { SwiftCrossUI.HStack(alignment: alignment, spacing: spacing) { content } }
}

/// SwiftUI's grid column description.
public struct GridItem: Sendable {
    public enum Size: Sendable {
        case fixed(Double)
        case flexible(minimum: Double = 10, maximum: Double = .infinity)
        case adaptive(minimum: Double, maximum: Double = .infinity)
    }
    public var size: Size
    public var spacing: Double?
    public var alignment: SwiftCrossUI.Alignment?
    public init(_ size: Size = .flexible(), spacing: Double? = nil, alignment: SwiftCrossUI.Alignment? = nil) {
        self.size = size
        self.spacing = spacing
        self.alignment = alignment
    }
}

/// SwiftUI's `LazyVGrid`, approximated: the items in one column (SwiftCrossUI has no grid layout).
public struct LazyVGrid<Content: SwiftCrossUI.View>: SwiftCrossUI.View {
    let spacing: Int?
    let content: Content
    public init(columns: [GridItem], alignment: SwiftCrossUI.HorizontalAlignment = .center, spacing: Double? = nil, pinnedViews: CircuitPinnedScrollableViews = [], @SwiftCrossUI.ViewBuilder content: () -> Content) {
        self.spacing = spacing.map { Int($0.rounded()) }
        self.content = content()
    }
    public var body: some SwiftCrossUI.View { SwiftCrossUI.VStack(spacing: spacing) { content } }
}

/// SwiftUI's `LazyHGrid`, approximated: the items in one row.
public struct LazyHGrid<Content: SwiftCrossUI.View>: SwiftCrossUI.View {
    let spacing: Int?
    let content: Content
    public init(rows: [GridItem], alignment: SwiftCrossUI.VerticalAlignment = .center, spacing: Double? = nil, pinnedViews: CircuitPinnedScrollableViews = [], @SwiftCrossUI.ViewBuilder content: () -> Content) {
        self.spacing = spacing.map { Int($0.rounded()) }
        self.content = content()
    }
    public var body: some SwiftCrossUI.View { SwiftCrossUI.HStack(spacing: spacing) { content } }
}

// MARK: - TimelineView

/// When a `TimelineView` redraws.
public struct CircuitTimelineSchedule: Sendable {
    let interval: Double
    public static func periodic(from start: Date, by interval: TimeInterval) -> CircuitTimelineSchedule { CircuitTimelineSchedule(interval: max(interval, 0.016)) }
    public static var everyMinute: CircuitTimelineSchedule { CircuitTimelineSchedule(interval: 60) }
    /// Display-rate updates, at 30 per second.
    public static var animation: CircuitTimelineSchedule { CircuitTimelineSchedule(interval: 1.0 / 30) }
    public static func animation(minimumInterval: Double? = nil, paused: Bool = false) -> CircuitTimelineSchedule {
        CircuitTimelineSchedule(interval: paused ? .infinity : max(minimumInterval ?? 1.0 / 30, 0.016))
    }
}

/// What a `TimelineView`'s content receives (SwiftUI's `TimelineViewDefaultContext`).
public struct TimelineViewDefaultContext {
    public enum Cadence: Sendable, Comparable { case live, seconds, minutes }
    public let date: Date
    public let cadence: Cadence
}

/// SwiftUI's `TimelineView`: content redrawn on a schedule, with the current date.
public struct TimelineView<Content: SwiftCrossUI.View>: SwiftCrossUI.View {
    public typealias Context = TimelineViewDefaultContext

    let schedule: CircuitTimelineSchedule
    let content: (Context) -> Content
    @SwiftCrossUI.State private var now = Date()

    public init(_ schedule: CircuitTimelineSchedule, @SwiftCrossUI.ViewBuilder content: @escaping (Context) -> Content) {
        self.schedule = schedule
        self.content = content
    }

    public var body: some SwiftCrossUI.View {
        let interval = schedule.interval
        return content(Context(date: now, cadence: interval >= 60 ? .minutes : interval >= 1 ? .seconds : .live))
            .task {
                guard interval.isFinite else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    now = Date()
                }
            }
    }
}

// MARK: - ViewModifier

/// The content a `ViewModifier` receives.
public struct CircuitModifierContent: SwiftCrossUI.View {
    let view: SwiftCrossUI.AnyView
    public var body: some SwiftCrossUI.View { view }
}

/// SwiftUI's `ViewModifier`.
@MainActor
public protocol ViewModifier {
    associatedtype Body: SwiftCrossUI.View
    typealias Content = CircuitModifierContent
    @SwiftCrossUI.ViewBuilder func body(content: Content) -> Body
}

extension SwiftCrossUI.View {
    public func modifier<M: ViewModifier>(_ modifier: M) -> some SwiftCrossUI.View {
        modifier.body(content: CircuitModifierContent(view: SwiftCrossUI.AnyView(self)))
    }
}

// MARK: - Text with a date, strokes

extension SwiftCrossUI.Text {
    /// SwiftUI's date styles for `Text(_:style:)`.
    public struct DateStyle: Sendable {
        let kind: Int
        public static let date = DateStyle(kind: 0)
        public static let time = DateStyle(kind: 1)
        public static let relative = DateStyle(kind: 2)
        public static let offset = DateStyle(kind: 3)
        public static let timer = DateStyle(kind: 4)
    }

    public init(_ date: Date, style: DateStyle) {
        let seconds = Int(date.timeIntervalSinceNow.rounded())
        switch style.kind {
        case 0: self.init(DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .none))
        case 1: self.init(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))
        case 2: self.init(Self.circuitSpan(abs(seconds)))
        case 3: self.init((seconds < 0 ? "-" : "+") + Self.circuitSpan(abs(seconds)))
        default:
            let s = abs(seconds)
            self.init(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60))
        }
    }

    /// "2 hours, 3 minutes": SwiftUI's relative style, the two largest units.
    static func circuitSpan(_ seconds: Int) -> String {
        let units: [(Int, String)] = [(86_400, "day"), (3600, "hour"), (60, "minute"), (1, "second")]
        var rest = seconds, parts: [String] = []
        for (size, name) in units where parts.count < 2 {
            let n = rest / size
            rest %= size
            if n > 0 || (size == 1 && parts.isEmpty) { parts.append("\(n) \(name)\(n == 1 ? "" : "s")") }
        }
        return parts.joined(separator: ", ")
    }
}

extension SwiftCrossUI.StrokeStyle {
    /// SwiftUI's `StrokeStyle(lineWidth:lineCap:lineJoin:miterLimit:dash:dashPhase:)`. A dash
    /// pattern is drawn as a solid line on Windows (SwiftCrossUI strokes have no dashes yet).
    public init(lineWidth: Double = 1, lineCap: SwiftCrossUI.StrokeCap = .butt, lineJoin: CircuitLineJoin = .miter, miterLimit: Double = 10, dash: [Double] = [], dashPhase: Double = 0) {
        let join: SwiftCrossUI.StrokeJoin
        switch lineJoin {
        case .miter: join = .miter(limit: miterLimit)
        case .round: join = .round
        case .bevel: join = .bevel
        }
        self.init(width: lineWidth, cap: lineCap, join: join)
    }
}

public enum CircuitLineJoin: Sendable { case miter, round, bevel }
#endif
