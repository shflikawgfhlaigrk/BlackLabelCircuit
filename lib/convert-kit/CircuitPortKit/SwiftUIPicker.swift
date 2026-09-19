// CircuitPortKit — SwiftUI's Picker on SwiftCrossUI: `Picker("Title", selection: $value) { … }`
// with options written as views carrying `.tag(_:)` (Text, Label, ForEach over a collection,
// if/else), drawn by SwiftCrossUI's native picker (menu, segmented, radio group, inline).
//
// A converted app's `Picker` refers to CircuitPicker (a module-level alias Circuit generates).
// Each option shows the text of its view (an icon-only option shows its tag). The options are read
// from the content the way SwiftUI reads them: the tagged views, including every element of a
// ForEach. SwiftCrossUI keeps a ForEach's elements private; the kit reads them by reflection,
// against the SwiftCrossUI version Circuit pins (0.9.x), and the kit self-test checks it.
#if canImport(SwiftCrossUI) && (!canImport(SwiftUI) || CIRCUIT_WINDOWS_SIM)
import Foundation
import SwiftCrossUI

// MARK: - Tags

/// A view with SwiftUI's `.tag(_:)`: the value a Picker selects when this option is picked.
public struct CircuitTagged<Content: SwiftCrossUI.View>: SwiftCrossUI.View {
    let content: Content
    /// The tag as options compare it, and as the app wrote it (what the selection is set to).
    let tag: AnyHashable
    let value: Any
    public var body: some SwiftCrossUI.View { content }
}

extension SwiftCrossUI.View {
    /// SwiftUI's `tag(_:)`.
    public func tag<Value: Hashable>(_ tag: Value) -> CircuitTagged<Self> {
        CircuitTagged(content: self, tag: circuitComparable(tag), value: tag)
    }
    /// SwiftUI's `tag(_:includeOptional:)`: a tag matches an optional selection either way here.
    public func tag<Value: Hashable>(_ tag: Value, includeOptional: Bool) -> CircuitTagged<Self> {
        CircuitTagged(content: self, tag: circuitComparable(tag), value: tag)
    }
}

/// A value as a Picker compares it: `Optional(x)` and `x` are the same option, `nil` is none.
func circuitComparable<Value: Hashable>(_ value: Value) -> AnyHashable {
    circuitUnwrapped(value) ?? AnyHashable(CircuitNoSelection())
}

func circuitUnwrapped(_ value: Any) -> AnyHashable? {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        guard let payload = mirror.children.first?.value else { return nil }
        return circuitUnwrapped(payload)
    }
    return value as? AnyHashable
}

struct CircuitNoSelection: Hashable {}

// MARK: - Reading the options out of the content

/// One option of a picker: its tag, and the text SwiftCrossUI's picker shows for it.
struct CircuitPickerOption: Equatable, CustomStringConvertible {
    let tag: AnyHashable
    let value: Any
    let label: String
    var description: String { label }
    static func == (lhs: CircuitPickerOption, rhs: CircuitPickerOption) -> Bool { lhs.tag == rhs.tag }
}

/// Views that know their options directly (a tagged view, a ForEach).
protocol CircuitOptionSource {
    @MainActor func circuitOptions(depth: Int) -> [CircuitPickerOption]
}

extension CircuitTagged: CircuitOptionSource {
    func circuitOptions(depth: Int) -> [CircuitPickerOption] {
        [CircuitPickerOption(tag: tag, value: value, label: circuitText(of: content, depth: 0) ?? "\(tag.base)")]
    }
}

extension SwiftCrossUI.ForEach: CircuitOptionSource where Child: SwiftCrossUI.View {
    func circuitOptions(depth: Int) -> [CircuitPickerOption] {
        let mirror = Mirror(reflecting: self)
        guard let elements = mirror.descendant("elements") as? Items,
              let child = mirror.descendant("child") as? (Items.Element) -> Child else {
            CircuitPickerLog.unreadable()
            return []
        }
        return elements.flatMap { circuitCollectOptions(child($0), depth: depth + 1) }
    }
}

/// Whether reflection should look inside a stored value for views (structs, enums, optionals and
/// tuples hold a view's children; a class is a model, a collection is data).
func circuitHoldsViews(_ value: Any) -> Bool {
    switch Mirror(reflecting: value).displayStyle {
    case .struct?, .enum?, .optional?, .tuple?: return true
    default: return false
    }
}

@MainActor
func circuitCollectOptions(_ view: Any, depth: Int) -> [CircuitPickerOption] {
    guard depth < 24 else { return [] }
    if let source = view as? CircuitOptionSource { return source.circuitOptions(depth: depth) }
    if view is SwiftCrossUI.Text { return [] }
    var options: [CircuitPickerOption] = []
    for child in Mirror(reflecting: view).children where circuitHoldsViews(child.value) {
        options += circuitCollectOptions(child.value, depth: depth + 1)
    }
    return options
}

/// The text a view shows (its Text views, in order), for an option's title.
@MainActor
func circuitText(of view: Any, depth: Int) -> String? {
    if let text = view as? SwiftCrossUI.Text { return text.string }
    guard depth < 12 else { return nil }
    let texts = Mirror(reflecting: view).children.compactMap { child -> String? in
        circuitHoldsViews(child.value) ? circuitText(of: child.value, depth: depth + 1) : nil
    }
    return texts.isEmpty ? nil : texts.joined(separator: " ")
}

enum CircuitPickerLog {
    private static let once = CircuitSymbolSeen()
    static func unreadable() {
        guard once.insert("ForEach") else { return }
        FileHandle.standardError.write(Data("[CircuitPortKit] Picker could not read a ForEach's elements (SwiftCrossUI changed its layout); its options are missing\n".utf8))
    }
}

// MARK: - Picker

/// Where `.labelsHidden()` hides the kit's control labels.
struct CircuitLabelsHiddenKey: SwiftCrossUI.EnvironmentKey {
    static var defaultValue: Bool { false }
}

extension SwiftCrossUI.EnvironmentValues {
    public var circuitLabelsHidden: Bool {
        get { self[CircuitLabelsHiddenKey.self] }
        set { self[CircuitLabelsHiddenKey.self] = newValue }
    }
}

/// SwiftUI's `Picker`.
public struct CircuitPicker<SelectionValue: Hashable, Content: SwiftCrossUI.View>: SwiftCrossUI.View {
    let title: String?
    let selection: SwiftCrossUI.Binding<SelectionValue>
    let content: Content
    @SwiftCrossUI.Environment(\.circuitLabelsHidden) var labelsHidden

    public init(_ title: String, selection: SwiftCrossUI.Binding<SelectionValue>, @SwiftCrossUI.ViewBuilder content: () -> Content) {
        self.title = title
        self.selection = selection
        self.content = content()
    }

    public init<Label: SwiftCrossUI.View>(selection: SwiftCrossUI.Binding<SelectionValue>, @SwiftCrossUI.ViewBuilder content: () -> Content, @SwiftCrossUI.ViewBuilder label: () -> Label) {
        title = circuitText(of: label(), depth: 0)
        self.selection = selection
        self.content = content()
    }

    /// SwiftUI's older argument order, label first.
    public init<Label: SwiftCrossUI.View>(selection: SwiftCrossUI.Binding<SelectionValue>, @SwiftCrossUI.ViewBuilder label: () -> Label, @SwiftCrossUI.ViewBuilder content: () -> Content) {
        title = circuitText(of: label(), depth: 0)
        self.selection = selection
        self.content = content()
    }

    public var body: some SwiftCrossUI.View {
        let options = circuitCollectOptions(content, depth: 0)
        let selection = self.selection
        let chosen = SwiftCrossUI.Binding<CircuitPickerOption?>(
            get: {
                let current = circuitComparable(selection.wrappedValue)
                return options.first { $0.tag == current }
            },
            set: { option in
                guard let option, let value = option.value as? SelectionValue else { return }
                selection.wrappedValue = value
            }
        )
        return SwiftCrossUI.HStack(spacing: 8) {
            if let title, !title.isEmpty, !labelsHidden {
                SwiftCrossUI.Text(title)
            }
            SwiftCrossUI.Picker(of: options, selection: chosen)
        }
    }
}
#endif
