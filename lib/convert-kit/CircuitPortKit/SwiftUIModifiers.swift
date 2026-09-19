// CircuitPortKit — SwiftUI modifiers and property wrappers SwiftCrossUI does not have yet.
//
// Kept exactly: onChange(of:) with the new value, or the old and new values; @FocusState as state
// the view reads and writes; .textSelection; alert and confirmationDialog messages (shown under the
// title); the system's reduce-motion and reduce-transparency settings.
// Presented differently: .toolbar content is a row above the view; popover and fullScreenCover
// are sheets.
// Not drawn on Windows (the view and its behavior are otherwise the same; listed per app in
// CONVERSION.md): letter spacing (.tracking, .kerning), shadows, blur, masks, clipping, offsets,
// scale and rotation effects, z-order, color effects, transitions, control / text field / menu
// styles and sizes, hidden labels, focus rings, context menus, keyboard shortcuts, accessibility
// labels, hit-testing changes (an overlay marked allowsHitTesting(false) still takes clicks), and
// @FocusState moving the keyboard focus.
#if canImport(SwiftCrossUI) && (!canImport(SwiftUI) || CIRCUIT_WINDOWS_SIM)
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if os(Windows)
import WinSDK
#endif
import SwiftCrossUI

// MARK: - State kept across a view's body passes

/// A reference a view keeps for its whole life, handed from one view instance to the next.
@propertyWrapper
public struct CircuitPersistent<Value: AnyObject>: SwiftCrossUI.DynamicProperty {
    private let storage: CircuitBox<Value>
    public init(wrappedValue: @autoclosure () -> Value) { storage = CircuitBox(wrappedValue()) }
    public var wrappedValue: Value { storage.value }
    public func update(with environment: SwiftCrossUI.EnvironmentValues, previousValue: CircuitPersistent<Value>?) {
        if let previousValue { storage.value = previousValue.storage.value }
    }
}

/// SwiftUI's `@FocusState`. On Windows it is state the view reads and writes; setting it does not
/// move the keyboard focus, and clicking into a field does not set it.
@propertyWrapper
public struct FocusState<Value: Hashable>: SwiftCrossUI.ObservableProperty {
    final class Storage {
        var value: Value
        let didChange = SwiftCrossUI.Publisher()
        init(_ value: Value) { self.value = value }
    }

    private let storage: CircuitBox<Storage>

    public init() where Value == Bool { storage = CircuitBox(Storage(false)) }
    public init<T: Hashable>() where Value == T? { storage = CircuitBox(Storage(nil)) }

    public var wrappedValue: Value {
        get { storage.value.value }
        nonmutating set {
            guard storage.value.value != newValue else { return }
            storage.value.value = newValue
            storage.value.didChange.send()
        }
    }

    public var projectedValue: Binding { Binding(storage: storage) }
    public var didChange: SwiftCrossUI.Publisher { storage.value.didChange }

    public func update(with environment: SwiftCrossUI.EnvironmentValues, previousValue: FocusState<Value>?) {
        if let previousValue { storage.value = previousValue.storage.value }
    }

    /// SwiftUI's `FocusState.Binding` (`$focused`).
    @propertyWrapper
    public struct Binding {
        fileprivate let storage: CircuitBox<Storage>
        public var wrappedValue: Value {
            get { storage.value.value }
            nonmutating set {
                guard storage.value.value != newValue else { return }
                storage.value.value = newValue
                storage.value.didChange.send()
            }
        }
        public var projectedValue: Binding { self }
    }
}

extension SwiftCrossUI.View {
    /// SwiftUI's `focused(_:)`. The binding keeps its value; Windows' keyboard focus is not moved.
    public func focused(_ condition: FocusState<Bool>.Binding) -> some SwiftCrossUI.View { self }
    /// SwiftUI's `focused(_:equals:)`.
    public func focused<Value: Hashable>(_ binding: FocusState<Value>.Binding, equals value: Value) -> some SwiftCrossUI.View { self }
}

// MARK: - Change handlers

/// Remembers the value last seen, for onChange's old value.
final class CircuitLastValue<Value> {
    var value: Value?
    init() {}
}

struct CircuitOnChange<Content: SwiftCrossUI.View, Value: Equatable>: SwiftCrossUI.View {
    let content: Content
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void
    @CircuitPersistent var last = CircuitLastValue<Value>()

    var body: some SwiftCrossUI.View {
        let last = self.last
        if last.value == nil { last.value = value }
        let value = self.value, action = self.action
        return content.onChange(of: value, initial: initial) {
            let old = last.value ?? value
            last.value = value
            action(old, value)
        }
    }
}

extension SwiftCrossUI.View {
    /// SwiftUI's `onChange(of:perform:)`: the action receives the new value.
    public func onChange<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some SwiftCrossUI.View {
        onChange(of: value, initial: false, perform: { action(value) })
    }

    /// SwiftUI's `onChange(of:initial:_:)` with the old and the new value.
    public func onChange<Value: Equatable>(of value: Value, initial: Bool = false, _ action: @escaping (Value, Value) -> Void) -> some SwiftCrossUI.View {
        CircuitOnChange(content: self, value: value, initial: initial, action: action)
    }
}

// MARK: - Alerts, dialogs, popovers, toolbars

/// The text of a message view built from `Text` (SwiftCrossUI wraps a single view in TupleView1).
@MainActor
func circuitMessageText<M: SwiftCrossUI.View>(_ message: M) -> String? {
    if let text = message as? SwiftCrossUI.Text { return text.string }
    if let single = message as? SwiftCrossUI.TupleView1<SwiftCrossUI.Text> { return single.view0.string }
    return nil
}

extension SwiftCrossUI.View {
    /// SwiftUI's `alert(_:isPresented:actions:message:)`: the message is shown under the title.
    public func alert<Message: SwiftCrossUI.View>(
        _ title: String,
        isPresented: SwiftCrossUI.Binding<Bool>,
        @SwiftCrossUI.AlertActionsBuilder actions: () -> [SwiftCrossUI.AlertAction],
        @SwiftCrossUI.ViewBuilder message: () -> Message
    ) -> some SwiftCrossUI.View {
        let text = circuitMessageText(message()).map { title + "\n\n" + $0 } ?? title
        return alert(text, isPresented: isPresented, actions: actions)
    }

    /// SwiftUI's `confirmationDialog(_:isPresented:titleVisibility:actions:message:)`, as an alert.
    public func confirmationDialog<Message: SwiftCrossUI.View>(
        _ title: String,
        isPresented: SwiftCrossUI.Binding<Bool>,
        titleVisibility: SwiftCrossUI.Visibility = .automatic,
        @SwiftCrossUI.AlertActionsBuilder actions: () -> [SwiftCrossUI.AlertAction],
        @SwiftCrossUI.ViewBuilder message: () -> Message
    ) -> some SwiftCrossUI.View {
        let text = circuitMessageText(message()).map { title + "\n\n" + $0 } ?? title
        return alert(text, isPresented: isPresented, actions: actions)
    }

    /// SwiftUI's `popover(isPresented:)`, presented as a sheet.
    public func popover<Content: SwiftCrossUI.View>(
        isPresented: SwiftCrossUI.Binding<Bool>,
        attachmentAnchor: CircuitPopoverAttachmentAnchor = .rect(.bounds),
        arrowEdge: SwiftCrossUI.Edge = .top,
        @SwiftCrossUI.ViewBuilder content: @escaping () -> Content
    ) -> some SwiftCrossUI.View {
        sheet(isPresented: isPresented, content: content)
    }

    /// SwiftUI's `fullScreenCover(isPresented:)`, presented as a sheet.
    public func fullScreenCover<Content: SwiftCrossUI.View>(
        isPresented: SwiftCrossUI.Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @SwiftCrossUI.ViewBuilder content: @escaping () -> Content
    ) -> some SwiftCrossUI.View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    /// SwiftUI's `toolbar { … }`: the items in a row above the view.
    public func toolbar<Items: SwiftCrossUI.View>(@SwiftCrossUI.ViewBuilder content: () -> Items) -> some SwiftCrossUI.View {
        let items = content()
        return SwiftCrossUI.VStack(spacing: 0) {
            SwiftCrossUI.HStack(spacing: 8) {
                SwiftCrossUI.Spacer()
                items
            }
            .padding(8)
            self
        }
    }

    /// The window title comes from the scene on Windows.
    public func navigationTitle(_ title: String) -> some SwiftCrossUI.View { self }
}

public enum CircuitPopoverAttachmentAnchor: Sendable {
    public enum Anchor: Sendable { case bounds }
    case rect(Anchor)
    case point(SwiftCrossUI.UnitPoint)
}

/// SwiftUI's `ToolbarItem`: its content, wherever it is placed.
public struct ToolbarItem<Content: SwiftCrossUI.View>: SwiftCrossUI.View {
    let content: Content
    public init(placement: ToolbarItemPlacement = .automatic, @SwiftCrossUI.ViewBuilder content: () -> Content) { self.content = content() }
    public init(id: String, placement: ToolbarItemPlacement = .automatic, @SwiftCrossUI.ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some SwiftCrossUI.View { content }
}

/// SwiftUI's `ToolbarItemGroup`.
public struct ToolbarItemGroup<Content: SwiftCrossUI.View>: SwiftCrossUI.View {
    let content: Content
    public init(placement: ToolbarItemPlacement = .automatic, @SwiftCrossUI.ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some SwiftCrossUI.View { SwiftCrossUI.HStack(spacing: 8) { content } }
}

public enum ToolbarItemPlacement: Sendable {
    case automatic, principal, navigation, primaryAction, secondaryAction, status, confirmationAction, cancellationAction, destructiveAction, keyboard
}

// MARK: - Environment the system provides

extension SwiftCrossUI.EnvironmentValues {
    /// Whether the system asks apps to reduce motion (Windows: "Animation effects" turned off).
    public var accessibilityReduceMotion: Bool { CircuitSystemSettings.reduceMotion }
    /// Whether the system asks apps to reduce transparency (not read on Windows yet: false).
    public var accessibilityReduceTransparency: Bool { CircuitSystemSettings.reduceTransparency }
    /// Desktop windows are the regular size class.
    public var horizontalSizeClass: UserInterfaceSizeClass? { .regular }
    public var verticalSizeClass: UserInterfaceSizeClass? { .regular }
}

public enum UserInterfaceSizeClass: Sendable { case compact, regular }

enum CircuitSystemSettings {
    static var reduceMotion: Bool {
        #if os(Windows)
        var animations: WindowsBool = true
        guard SystemParametersInfoW(UINT(SPI_GETCLIENTAREAANIMATION), 0, &animations, 0).boolValue else { return false }
        return !animations.boolValue
        #else
        return false
        #endif
    }

    /// Not read from the system yet: materials are drawn without blur on Windows either way.
    static var reduceTransparency: Bool { false }
}

// MARK: - Text

public enum CircuitTruncationMode: Sendable { case head, tail, middle }
public struct CircuitTextSelectability: Sendable {
    let enabled: Bool
    public static let enabled = CircuitTextSelectability(enabled: true)
    public static let disabled = CircuitTextSelectability(enabled: false)
}

extension SwiftCrossUI.View {
    /// SwiftUI's `textSelection(_:)`.
    public func textSelection(_ selectability: CircuitTextSelectability) -> some SwiftCrossUI.View {
        textSelectionEnabled(selectability.enabled)
    }
    /// Letter spacing is not applied on Windows.
    public func tracking(_ tracking: Double) -> some SwiftCrossUI.View { self }
    public func kerning(_ kerning: Double) -> some SwiftCrossUI.View { self }
    public func baselineOffset(_ offset: Double) -> some SwiftCrossUI.View { self }
    /// Long text is cut at its end on Windows, whatever the mode.
    public func truncationMode(_ mode: CircuitTruncationMode) -> some SwiftCrossUI.View { self }
    public func minimumScaleFactor(_ factor: Double) -> some SwiftCrossUI.View { self }
    public func allowsTightening(_ flag: Bool) -> some SwiftCrossUI.View { self }
    public func monospacedDigit() -> some SwiftCrossUI.View { self }
    public func privacySensitive(_ sensitive: Bool = true) -> some SwiftCrossUI.View { self }
}

extension SwiftCrossUI.Text {
    public func tracking(_ tracking: Double) -> SwiftCrossUI.Text { self }
    public func kerning(_ kerning: Double) -> SwiftCrossUI.Text { self }
    public func monospacedDigit() -> SwiftCrossUI.Text { self }
}

// MARK: - Effects not drawn on Windows

/// SwiftUI's transitions (views appear and disappear without motion on Windows).
public struct AnyTransition: Sendable {
    public static let opacity = AnyTransition()
    public static let scale = AnyTransition()
    public static let slide = AnyTransition()
    public static let identity = AnyTransition()
    public static func scale(scale: Double, anchor: SwiftCrossUI.UnitPoint = .center) -> AnyTransition { AnyTransition() }
    public static func move(edge: SwiftCrossUI.Edge) -> AnyTransition { AnyTransition() }
    public static func push(from edge: SwiftCrossUI.Edge) -> AnyTransition { AnyTransition() }
    public static func offset(x: Double = 0, y: Double = 0) -> AnyTransition { AnyTransition() }
    public static func asymmetric(insertion: AnyTransition, removal: AnyTransition) -> AnyTransition { AnyTransition() }
    public func combined(with other: AnyTransition) -> AnyTransition { self }
    public func animation(_ animation: Animation?) -> AnyTransition { self }
}

public enum BlendMode: Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight
    case difference, exclusion, hue, saturation, color, luminosity, sourceAtop, destinationOver, destinationOut, plusDarker, plusLighter
}

extension SwiftCrossUI.View {
    public func shadow(color: SwiftCrossUI.Color = SwiftCrossUI.Color(white: 0, opacity: 0.33), radius: Double, x: Double = 0, y: Double = 0) -> some SwiftCrossUI.View { self }
    public func blur(radius: Double, opaque: Bool = false) -> some SwiftCrossUI.View { self }
    public func offset(x: Double = 0, y: Double = 0) -> some SwiftCrossUI.View { self }
    public func offset(_ offset: CGSize) -> some SwiftCrossUI.View { self }
    public func scaleEffect(_ scale: Double, anchor: SwiftCrossUI.UnitPoint = .center) -> some SwiftCrossUI.View { self }
    public func scaleEffect(x: Double = 1, y: Double = 1, anchor: SwiftCrossUI.UnitPoint = .center) -> some SwiftCrossUI.View { self }
    public func scaleEffect(_ scale: CGSize, anchor: SwiftCrossUI.UnitPoint = .center) -> some SwiftCrossUI.View { self }
    public func rotationEffect(_ angle: SwiftCrossUI.Angle, anchor: SwiftCrossUI.UnitPoint = .center) -> some SwiftCrossUI.View { self }
    public func zIndex(_ value: Double) -> some SwiftCrossUI.View { self }
    public func transition(_ transition: AnyTransition) -> some SwiftCrossUI.View { self }
    public func compositingGroup() -> some SwiftCrossUI.View { self }
    public func drawingGroup(opaque: Bool = false) -> some SwiftCrossUI.View { self }
    public func saturation(_ amount: Double) -> some SwiftCrossUI.View { self }
    public func brightness(_ amount: Double) -> some SwiftCrossUI.View { self }
    public func contrast(_ amount: Double) -> some SwiftCrossUI.View { self }
    public func grayscale(_ amount: Double) -> some SwiftCrossUI.View { self }
    public func hueRotation(_ angle: SwiftCrossUI.Angle) -> some SwiftCrossUI.View { self }
    public func colorMultiply(_ color: SwiftCrossUI.Color) -> some SwiftCrossUI.View { self }
    public func blendMode(_ mode: BlendMode) -> some SwiftCrossUI.View { self }
    public func mask<Mask: SwiftCrossUI.View>(_ mask: Mask) -> some SwiftCrossUI.View { self }
    public func mask<Mask: SwiftCrossUI.View>(alignment: SwiftCrossUI.Alignment = .center, @SwiftCrossUI.ViewBuilder _ mask: () -> Mask) -> some SwiftCrossUI.View { self }
    public func clipped(antialiased: Bool = false) -> some SwiftCrossUI.View { self }
    public func allowsHitTesting(_ enabled: Bool) -> some SwiftCrossUI.View { self }
    public func contentShape<S: SwiftCrossUI.Shape>(_ shape: S, eoFill: Bool = false) -> some SwiftCrossUI.View { self }
    public func contextMenu<MenuItems: SwiftCrossUI.View>(@SwiftCrossUI.ViewBuilder menuItems: () -> MenuItems) -> some SwiftCrossUI.View { self }
}

// MARK: - Keyboard shortcuts (not bound on Windows)

public struct KeyEquivalent: Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
    public let character: Character
    public init(_ character: Character) { self.character = character }
    public init(extendedGraphemeClusterLiteral value: Character) { character = value }
    public static let `return` = KeyEquivalent("\r")
    public static let escape = KeyEquivalent("\u{1B}")
    public static let delete = KeyEquivalent("\u{8}")
    public static let deleteForward = KeyEquivalent("\u{7F}")
    public static let space = KeyEquivalent(" ")
    public static let tab = KeyEquivalent("\t")
    public static let upArrow = KeyEquivalent("\u{F700}")
    public static let downArrow = KeyEquivalent("\u{F701}")
    public static let leftArrow = KeyEquivalent("\u{F702}")
    public static let rightArrow = KeyEquivalent("\u{F703}")
    public static let home = KeyEquivalent("\u{F729}")
    public static let end = KeyEquivalent("\u{F72B}")
    public static let pageUp = KeyEquivalent("\u{F72C}")
    public static let pageDown = KeyEquivalent("\u{F72D}")
}

public struct EventModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let capsLock = EventModifiers(rawValue: 1)
    public static let shift = EventModifiers(rawValue: 2)
    public static let control = EventModifiers(rawValue: 4)
    public static let option = EventModifiers(rawValue: 8)
    public static let command = EventModifiers(rawValue: 16)
    public static let numericPad = EventModifiers(rawValue: 32)
    public static let all: EventModifiers = [.capsLock, .shift, .control, .option, .command, .numericPad]
}

public struct KeyboardShortcut: Sendable {
    public let key: KeyEquivalent
    public let modifiers: EventModifiers
    public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command) { self.key = key; self.modifiers = modifiers }
    public static let defaultAction = KeyboardShortcut(.return, modifiers: [])
    public static let cancelAction = KeyboardShortcut(.escape, modifiers: [])
}

extension SwiftCrossUI.View {
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some SwiftCrossUI.View { self }
    public func keyboardShortcut(_ shortcut: KeyboardShortcut?) -> some SwiftCrossUI.View { self }
}

// MARK: - Control styles (Windows draws its own controls)

public enum ControlSize: Sendable { case mini, small, regular, large, extraLarge }

public struct CircuitTextFieldStyle: Sendable {
    public static let automatic = CircuitTextFieldStyle()
    public static let plain = CircuitTextFieldStyle()
    public static let roundedBorder = CircuitTextFieldStyle()
    public static let squareBorder = CircuitTextFieldStyle()
}

public struct CircuitMenuStyle: Sendable {
    public static let automatic = CircuitMenuStyle()
    public static let button = CircuitMenuStyle()
    public static let borderlessButton = CircuitMenuStyle()
}

public enum ScrollIndicatorVisibility: Sendable { case automatic, visible, hidden, never }

public struct CircuitButtonBorderShape: Sendable {
    public static let automatic = CircuitButtonBorderShape()
    public static let capsule = CircuitButtonBorderShape()
    public static let roundedRectangle = CircuitButtonBorderShape()
    public static func roundedRectangle(radius: Double) -> CircuitButtonBorderShape { CircuitButtonBorderShape() }
}

extension SwiftCrossUI.View {
    public func textFieldStyle(_ style: CircuitTextFieldStyle) -> some SwiftCrossUI.View { self }
    /// SwiftUI's `labelsHidden()`: hides the titles the kit's pickers show beside them.
    public func labelsHidden() -> some SwiftCrossUI.View { environment(\.circuitLabelsHidden, true) }
    public func controlSize(_ size: ControlSize) -> some SwiftCrossUI.View { self }
    public func menuStyle(_ style: CircuitMenuStyle) -> some SwiftCrossUI.View { self }
    public func menuIndicator(_ visibility: SwiftCrossUI.Visibility) -> some SwiftCrossUI.View { self }
    public func buttonBorderShape(_ shape: CircuitButtonBorderShape) -> some SwiftCrossUI.View { self }
    public func scrollContentBackground(_ visibility: SwiftCrossUI.Visibility) -> some SwiftCrossUI.View { self }
    public func scrollIndicators(_ visibility: ScrollIndicatorVisibility, axes: SwiftCrossUI.Axis.Set = [.vertical, .horizontal]) -> some SwiftCrossUI.View { self }
    public func focusable(_ isFocusable: Bool = true) -> some SwiftCrossUI.View { self }
    public func focusEffectDisabled(_ disabled: Bool = true) -> some SwiftCrossUI.View { self }
}

extension SwiftCrossUI.ButtonStyle {
    /// SwiftUI's prominent and link button styles: bordered and borderless on Windows.
    public static var borderedProminent: SwiftCrossUI.ButtonStyle { .bordered }
    public static var link: SwiftCrossUI.ButtonStyle { .borderless }
    public static var automatic: SwiftCrossUI.ButtonStyle { .bordered }
}

// MARK: - Accessibility (Windows reads the visible text)

public struct AccessibilityTraits: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let isButton = AccessibilityTraits(rawValue: 1)
    public static let isHeader = AccessibilityTraits(rawValue: 2)
    public static let isSelected = AccessibilityTraits(rawValue: 4)
    public static let isLink = AccessibilityTraits(rawValue: 8)
    public static let isImage = AccessibilityTraits(rawValue: 16)
    public static let isStaticText = AccessibilityTraits(rawValue: 32)
    public static let updatesFrequently = AccessibilityTraits(rawValue: 64)
}

public enum AccessibilityChildBehavior: Sendable { case ignore, contain, combine }

extension SwiftCrossUI.View {
    public func accessibilityLabel(_ label: String) -> some SwiftCrossUI.View { self }
    public func accessibilityLabel(_ label: SwiftCrossUI.Text) -> some SwiftCrossUI.View { self }
    public func accessibilityHint(_ hint: String) -> some SwiftCrossUI.View { self }
    public func accessibilityValue(_ value: String) -> some SwiftCrossUI.View { self }
    public func accessibilityIdentifier(_ identifier: String) -> some SwiftCrossUI.View { self }
    public func accessibilityHidden(_ hidden: Bool) -> some SwiftCrossUI.View { self }
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some SwiftCrossUI.View { self }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some SwiftCrossUI.View { self }
    public func accessibilityRemoveTraits(_ traits: AccessibilityTraits) -> some SwiftCrossUI.View { self }
    public func accessibilitySortPriority(_ priority: Double) -> some SwiftCrossUI.View { self }
}
#endif
