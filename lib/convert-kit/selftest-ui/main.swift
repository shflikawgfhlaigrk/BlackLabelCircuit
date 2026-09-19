// CircuitPortKit UI self-test: runs the SwiftUI adapters (on SwiftCrossUI) and checks what they do.
// Built by `circuit --kit-selftest-ui`: natively on Windows, in the simulated Windows configuration on a Mac.
import Foundation
import SwiftCrossUI
@testable import CircuitPortKit

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS  \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

enum Mode: String, CaseIterable, Hashable { case light, dark, auto }
struct Person: Identifiable, Hashable { let id: Int; let name: String }

MainActor.assumeIsolated {
    // Picker options: tagged Text, ForEach over values, ForEach over Identifiable, if/else, Label.
    let sizePicker = CircuitPicker("Size", selection: SwiftCrossUI.Binding<Int>.constant(2)) {
        SwiftCrossUI.Text("Small").tag(1)
        SwiftCrossUI.Text("Medium").tag(2)
        SwiftCrossUI.Text("Large").tag(3)
    }
    let plain = circuitCollectOptions(sizePicker.content, depth: 0)
    check(plain.map(\.label) == ["Small", "Medium", "Large"], "tagged Text options: \(plain.map(\.label))")

    let modePicker = CircuitPicker("Mode", selection: SwiftCrossUI.Binding<Mode>.constant(.dark)) {
        SwiftCrossUI.ForEach(Mode.allCases, id: \.self) { mode in
            SwiftCrossUI.Text(mode.rawValue.capitalized).tag(mode)
        }
    }
    let modes = circuitCollectOptions(modePicker.content, depth: 0)
    check(modes.map(\.label) == ["Light", "Dark", "Auto"], "ForEach options: \(modes.map(\.label))")

    let people = [Person(id: 7, name: "Ada"), Person(id: 9, name: "Grace")]
    let chosen: Int? = 9
    let ownerPicker = CircuitPicker("Owner", selection: SwiftCrossUI.Binding<Int?>.constant(chosen)) {
        SwiftCrossUI.Text("Nobody").tag(Int?.none)
        SwiftCrossUI.ForEach(people) { person in
            Label(person.name, systemImage: "person").tag(Optional(person.id))
        }
    }
    let persons = circuitCollectOptions(ownerPicker.content, depth: 0)
    check(persons.map(\.label) == ["Nobody", "Ada", "Grace"], "optional tags, Label titles: \(persons.map(\.label))")
    check(persons.first { $0.tag == circuitComparable(chosen) }?.label == "Grace", "Optional(9) selection matches tag 9")
    check((persons[0].value as? Int?) == .some(nil), "the nil tag sets an optional selection to nil")

    let flag = true
    let branchPicker = CircuitPicker("Branch", selection: SwiftCrossUI.Binding<String>.constant("a")) {
        if flag { SwiftCrossUI.Text("A").tag("a") } else { SwiftCrossUI.Text("B").tag("b") }
        SwiftCrossUI.Text("C").tag("c")
    }
    let branches = circuitCollectOptions(branchPicker.content, depth: 0)
    check(branches.map(\.label) == ["A", "C"], "if/else options: \(branches.map(\.label))")

    // Picking writes the app's value back through the binding.
    var picked = Mode.light
    let binding = SwiftCrossUI.Binding(get: { picked }, set: { picked = $0 })
    let option = modes[2]
    if let value = option.value as? Mode { binding.wrappedValue = value }
    check(picked == .auto, "picking an option sets the selection")

    // Path with SwiftUI's CGPoint API.
    let path = SwiftCrossUI.Path { p in
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 10, y: 0))
        p.addLine(to: CGPoint(x: 10, y: 10))
        p.closeSubpath()
    }
    check(path.actions == [.moveTo(SIMD2(0, 0)), .lineTo(SIMD2(10, 0)), .lineTo(SIMD2(10, 10)), .lineTo(SIMD2(0, 0))], "Path { move, addLine, closeSubpath }")
    check(path.fillRule == .winding, "SwiftUI-built paths fill with the winding rule")

    // Stepper stays in range; Slider snaps to its step.
    var level = 9
    let stepper = Stepper("Level", value: SwiftCrossUI.Binding(get: { level }, set: { level = $0 }), in: 1...10)
    stepper.increment(); stepper.increment()
    check(level == 10, "Stepper stops at the top of its range (\(level))")
    stepper.decrement()
    check(level == 9, "Stepper steps down (\(level))")

    // Text(date, style:).
    check(SwiftCrossUI.Text.circuitSpan(3 * 3600 + 5 * 60 + 7) == "3 hours, 5 minutes", "relative span: \(SwiftCrossUI.Text.circuitSpan(3 * 3600 + 5 * 60 + 7))")
    check(SwiftCrossUI.Text.circuitSpan(1) == "1 second", "relative span singular")
    check(SwiftCrossUI.Text(Date().addingTimeInterval(125), style: .timer).string == "2:05" || SwiftCrossUI.Text(Date().addingTimeInterval(125), style: .timer).string == "2:04", "timer style")

    // Gradients are plain values: built outside the main actor too.
    let grad = CircuitLinearGradient(colors: [.red, .blue], startPoint: .top, endPoint: .bottom)
    check(grad.gradient.stops.map(\.location) == [0, 1], "Gradient(colors:) spaces its stops evenly")
    check(CircuitGradient(colors: [.red, .green, .blue]).stops.map(\.location) == [0, 0.5, 1], "three colors at 0, 0.5, 1")
}

let detached = Thread { _ = CircuitLinearGradient(colors: [.red], startPoint: .top, endPoint: .bottom) }
detached.start()
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
