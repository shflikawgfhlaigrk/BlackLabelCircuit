// CircuitPortKit — SwiftUI's names that SwiftCrossUI spells differently, built on SwiftCrossUI.
//
// A converted app's screens import SwiftCrossUI in place of SwiftUI (WinUI 3 on Windows). Its
// models stay Combine models (OpenCombine off Apple platforms), and its views hold them the SwiftUI
// way: @StateObject, @ObservedObject, @EnvironmentObject and .environmentObject(_:). SwiftCrossUI
// observes its own ObservableObject instead, so these wrappers relay each model's objectWillChange
// into the publisher SwiftCrossUI watches (an ObservableProperty). SwiftCrossUI applies the update
// on the main thread after the current mutation, so the view reads the new value, as in SwiftUI.
//
// Compiled wherever SwiftCrossUI stands in for SwiftUI (and on a Mac simulating Windows).
#if canImport(SwiftCrossUI) && canImport(OpenCombine) && (!canImport(SwiftUI) || CIRCUIT_WINDOWS_SIM)
import Foundation
import SwiftCrossUI
import OpenCombine

/// Forwards a Combine model's objectWillChange to the publisher SwiftCrossUI observes. The same
/// relay (and so the same publisher) is handed from one view instance to the next, because
/// SwiftCrossUI subscribes once, when the view's node is created.
final class CombineRelay<ObjectType: OpenCombine.ObservableObject> {
    let didChange = SwiftCrossUI.Publisher()
    private weak var watched: ObjectType?
    private var subscription: OpenCombine.AnyCancellable?

    func watch(_ object: ObjectType) {
        if let watched, watched === object { return }
        watched = object
        let didChange = self.didChange
        subscription = object.objectWillChange.sink { _ in didChange.send() }
    }
}

/// SwiftUI's `@ObservedObject`: a model owned elsewhere; the view updates when it changes.
@propertyWrapper
public struct ObservedObject<ObjectType: OpenCombine.ObservableObject>: SwiftCrossUI.ObservableProperty {
    private let relay: CircuitBox<CombineRelay<ObjectType>>
    public var wrappedValue: ObjectType

    public init(wrappedValue: ObjectType) {
        self.wrappedValue = wrappedValue
        relay = CircuitBox(CombineRelay())
        relay.value.watch(wrappedValue)
    }

    public init(initialValue: ObjectType) {
        self.init(wrappedValue: initialValue)
    }

    public var didChange: SwiftCrossUI.Publisher { relay.value.didChange }

    public var projectedValue: Wrapper { Wrapper(object: wrappedValue) }

    public func update(with environment: SwiftCrossUI.EnvironmentValues, previousValue: ObservedObject<ObjectType>?) {
        if let previousValue { relay.value = previousValue.relay.value }
        relay.value.watch(wrappedValue)
    }

    /// `$model.name` gives a binding to the model's property, as in SwiftUI.
    @dynamicMemberLookup
    public struct Wrapper {
        let object: ObjectType

        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> SwiftCrossUI.Binding<Subject> {
            let object = self.object
            return SwiftCrossUI.Binding(get: { object[keyPath: keyPath] }, set: { object[keyPath: keyPath] = $0 })
        }
    }
}

/// SwiftUI's `@StateObject`: a model the view owns. Created once, on first use, and kept for the
/// life of the view however often the view struct is recreated.
@propertyWrapper
public struct StateObject<ObjectType: OpenCombine.ObservableObject>: SwiftCrossUI.ObservableProperty {
    final class Storage {
        private let make: () -> ObjectType
        private var made: ObjectType?
        let relay = CombineRelay<ObjectType>()

        init(_ make: @escaping () -> ObjectType) { self.make = make }

        var object: ObjectType {
            if let made { return made }
            let object = make()
            made = object
            relay.watch(object)
            return object
        }
    }

    private let storage: CircuitBox<Storage>

    public init(wrappedValue thunk: @autoclosure @escaping () -> ObjectType) {
        storage = CircuitBox(Storage(thunk))
    }

    public var wrappedValue: ObjectType { storage.value.object }

    public var projectedValue: ObservedObject<ObjectType>.Wrapper { ObservedObject<ObjectType>.Wrapper(object: wrappedValue) }

    public var didChange: SwiftCrossUI.Publisher { storage.value.relay.didChange }

    public func update(with environment: SwiftCrossUI.EnvironmentValues, previousValue: StateObject<ObjectType>?) {
        if let previousValue { storage.value = previousValue.storage.value }
        _ = storage.value.object
    }
}

/// Where `.environmentObject(_:)` keeps Combine models, by type, as SwiftUI does.
struct CircuitCombineObjectsKey: SwiftCrossUI.EnvironmentKey {
    static var defaultValue: [ObjectIdentifier: AnyObject] { [:] }
}

extension SwiftCrossUI.EnvironmentValues {
    public subscript(circuitCombineObject type: ObjectIdentifier) -> AnyObject? {
        get { self[CircuitCombineObjectsKey.self][type] }
        set { self[CircuitCombineObjectsKey.self][type] = newValue }
    }
}

extension SwiftCrossUI.View {
    /// SwiftUI's `.environmentObject(_:)`: makes the model available to `@EnvironmentObject`
    /// properties of this view's descendants.
    public func environmentObject<ObjectType: OpenCombine.ObservableObject>(_ object: ObjectType) -> some SwiftCrossUI.View {
        environment(\.[circuitCombineObject: ObjectIdentifier(ObjectType.self)], object)
    }
}

/// SwiftUI's `@EnvironmentObject`: a model an ancestor supplied with `.environmentObject(_:)`.
@propertyWrapper
public struct EnvironmentObject<ObjectType: OpenCombine.ObservableObject>: SwiftCrossUI.ObservableProperty {
    final class Storage {
        var object: ObjectType?
        let relay = CombineRelay<ObjectType>()
    }

    private let storage = CircuitBox(Storage())

    public init() {}

    public var wrappedValue: ObjectType {
        guard let object = storage.value.object else {
            // SwiftUI stops the app the same way when the ancestor forgot the object.
            fatalError("No ObservableObject of type \(ObjectType.self) found. A View.environmentObject(_:) for \(ObjectType.self) may be missing as an ancestor of this view.")
        }
        return object
    }

    public var projectedValue: ObservedObject<ObjectType>.Wrapper { ObservedObject<ObjectType>.Wrapper(object: wrappedValue) }

    public var didChange: SwiftCrossUI.Publisher { storage.value.relay.didChange }

    public func update(with environment: SwiftCrossUI.EnvironmentValues, previousValue: EnvironmentObject<ObjectType>?) {
        if let previousValue { storage.value = previousValue.storage.value }
        if let object = environment[circuitCombineObject: ObjectIdentifier(ObjectType.self)] as? ObjectType {
            storage.value.object = object
            storage.value.relay.watch(object)
        }
    }
}

/// A view's subscription to a publisher, kept while the view is shown.
final class CircuitReceiver<Output> {
    var subscription: OpenCombine.AnyCancellable?
    var action: ((Output) -> Void)?
}

struct CircuitOnReceive<Content: SwiftCrossUI.View, P: OpenCombine.Publisher>: SwiftCrossUI.View where P.Failure == Never {
    let content: Content
    let publisher: P
    let action: (P.Output) -> Void
    @CircuitPersistent var receiver = CircuitReceiver<P.Output>()

    var body: some SwiftCrossUI.View {
        let receiver = self.receiver, publisher = self.publisher
        receiver.action = action // the latest closure sees the latest view state
        return content
            .onAppear {
                guard receiver.subscription == nil else { return }
                receiver.subscription = publisher.sink { value in receiver.action?(value) }
            }
            .onDisappear {
                receiver.subscription = nil
            }
    }
}

extension SwiftCrossUI.View {
    /// SwiftUI's `onReceive(_:perform:)`: runs the action for each value the publisher sends while
    /// the view is shown.
    public func onReceive<P: OpenCombine.Publisher>(_ publisher: P, perform action: @escaping (P.Output) -> Void) -> some SwiftCrossUI.View where P.Failure == Never {
        CircuitOnReceive(content: self, publisher: publisher, action: action)
    }
}
#endif
