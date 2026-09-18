// Sovereign — semantic-first UI control arbitration.
//
// Planning is read-only. Every plan selects one route: Accessibility semantics when the observed
// control exposes a supported action, otherwise the pixel driver. Execution never falls through to
// the other route after a denial, failure, stale observation, or attempted action. Both routes use
// the same Manual / Auto / Skip policy and consequence deny floor.
import Foundation
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif

#if !os(macOS)
// CGEvent keyboard types are macOS-only. The iOS target still compiles the shared
// parser and policy model, but it never posts desktop events; these value types
// preserve the shared command shape without claiming desktop-control support.
typealias CGKeyCode = UInt16
struct CGEventFlags: OptionSet, Equatable {
    let rawValue: UInt64
    static let maskCommand = Self(rawValue: 1 << 20)
    static let maskShift = Self(rawValue: 1 << 17)
    static let maskAlternate = Self(rawValue: 1 << 19)
    static let maskControl = Self(rawValue: 1 << 18)
}
#endif

enum ControlRoute: String, Equatable {
    case semantic
    case visual

    var label: String { self == .semantic ? "Semantic" : "Visual" }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum VisualControlCommand: Equatable {
    case inspect
    case move(mark: Int?, point: CGPoint?)
    case click(mark: Int?, point: CGPoint?)
    case doubleClick(mark: Int?, point: CGPoint?)
    case rightClick(mark: Int?, point: CGPoint?)
    case scroll(dy: Int, dx: Int, point: CGPoint?)
    case type(text: String, mark: Int?)
    case key(code: CGKeyCode, flags: CGEventFlags)

    var mutates: Bool { self != .inspect }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct VisualControlRequest: Equatable {
    var command: VisualControlCommand
    var observationID: UUID?
    var targetLabel: String
}
#endif // circuit-convert

enum VisualControlParseFailure: Error, Equatable, CustomStringConvertible {
    case unknownAction(String)
    case missing(String)
    case invalid(String)
    case ambiguousTarget

    var description: String {
        switch self {
        case .unknownAction(let value): return "Unknown visual action “\(value)”."
        case .missing(let field): return "Missing required field “\(field)”."
        case .invalid(let field): return "Invalid value for “\(field)”."
        case .ambiguousTarget: return "Use either a mark or an x/y point, not both."
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Pure conversion from a structured tool dictionary to a typed request. No permission, capture,
/// or event posting occurs here.
enum VisualControlParser {
    static func parse(_ input: [String: Any]) -> Result<VisualControlRequest, VisualControlParseFailure> {
        let raw = string(input["action"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return .failure(.missing("action")) }
        let target = string(input["target"]).trimmingCharacters(in: .whitespacesAndNewlines)

        if raw == "inspect" {
            return .success(VisualControlRequest(command: .inspect, observationID: nil,
                                                 targetLabel: target))
        }
        guard let observationID = UUID(uuidString: string(input["observation_id"])) else {
            return .failure(.invalid("observation_id"))
        }

        let markResult = optionalInt(input["mark"], field: "mark")
        let mark: Int?
        switch markResult {
        case .success(let value): mark = value
        case .failure(let error): return .failure(error)
        }
        if let mark, mark < 1 { return .failure(.invalid("mark")) }

        let pointResult = optionalPoint(x: input["x"], y: input["y"])
        let point: CGPoint?
        switch pointResult {
        case .success(let value): point = value
        case .failure(let error): return .failure(error)
        }
        if mark != nil && point != nil { return .failure(.ambiguousTarget) }

        let command: VisualControlCommand
        switch raw {
        case "move":
            guard mark != nil || point != nil else { return .failure(.missing("mark or x/y")) }
            command = .move(mark: mark, point: point)
        case "click":
            guard mark != nil || point != nil else { return .failure(.missing("mark or x/y")) }
            command = .click(mark: mark, point: point)
        case "double_click", "doubleclick":
            guard mark != nil || point != nil else { return .failure(.missing("mark or x/y")) }
            command = .doubleClick(mark: mark, point: point)
        case "right_click", "rightclick":
            guard mark != nil || point != nil else { return .failure(.missing("mark or x/y")) }
            command = .rightClick(mark: mark, point: point)
        case "scroll":
            guard let dy = int(input["dy"]) else { return .failure(.missing("dy")) }
            command = .scroll(dy: dy, dx: int(input["dx"]) ?? 0, point: point)
        case "type":
            let text = string(input["text"])
            guard !text.isEmpty else { return .failure(.missing("text")) }
            command = .type(text: text, mark: mark)
        case "key":
            let key = string(input["key"]).lowercased()
            guard let code = keyCodes[key] else { return .failure(.invalid("key")) }
            guard let flags = modifierFlags(input["modifiers"]) else {
                return .failure(.invalid("modifiers"))
            }
            command = .key(code: code, flags: flags)
        default:
            return .failure(.unknownAction(raw))
        }
        return .success(VisualControlRequest(command: command, observationID: observationID,
                                             targetLabel: target))
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
        "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126
    ]

    private static func modifierFlags(_ raw: Any?) -> CGEventFlags? {
        guard let raw else { return [] }
        let values: [String]
        if let array = raw as? [String] { values = array }
        else if let text = raw as? String {
            values = text.split(separator: ",").map { String($0) }
        } else { return nil }
        var flags: CGEventFlags = []
        for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) {
            switch value {
            case "command", "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "": continue
            default: return nil
            }
        }
        return flags
    }

    private static func optionalPoint(x: Any?, y: Any?)
        -> Result<CGPoint?, VisualControlParseFailure> {
        if x == nil && y == nil { return .success(nil) }
        guard let x = double(x), let y = double(y), x.isFinite, y.isFinite else {
            return .failure(.invalid("x/y"))
        }
        return .success(CGPoint(x: x, y: y))
    }

    private static func optionalInt(_ raw: Any?, field: String)
        -> Result<Int?, VisualControlParseFailure> {
        guard let raw else { return .success(nil) }
        guard let value = int(raw) else { return .failure(.invalid(field)) }
        return .success(value)
    }

    private static func string(_ raw: Any?) -> String { raw as? String ?? "" }
    private static func int(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }
    private static func double(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }
}
#endif // circuit-convert

struct ControlObservation {
    let id: UUID
    let capturedAt: Date
    let marks: [SoMMark]
    let screenGranted: Bool
    let axGranted: Bool
    let reason: String
    let appName: String
    let appBundleID: String

    var prompt: String {
        let header = "Observation \(id.uuidString) · \(appName.isEmpty ? "frontmost app" : appName) · \(reason)"
        let body = SetOfMarks.prompt(marks)
        return body.isEmpty ? "\(header)\nNo numbered controls were found." : "\(header)\n\(body)"
    }
}

enum ControlPlanPayload: Equatable {
    case observation
    case semantic(kind: OperatorActionKind, value: String?)
    case visual(CUAction)
}

struct ControlPlan: Equatable {
    let id: UUID
    let route: ControlRoute
    let payload: ControlPlanPayload
    let element: OperatorElement
    let observationID: UUID?
    let observedAt: Date?
    let observedBundleID: String
    let requiresExplicitApproval: Bool
    let display: String

    var isObservation: Bool { if case .observation = payload { return true }; return false }
    var policyKind: OperatorActionKind {
        switch payload {
        case .observation: return .read
        case .semantic(let kind, _): return kind
        case .visual(let action):
            switch action {
            case .click, .doubleClick, .rightClick: return .press
            case .type, .key: return .setValue
            case .move, .scroll: return .focus
            }
        }
    }
}

enum ControlPlanFailure: Error, Equatable, CustomStringConvertible {
    case observationMissing
    case observationExpired
    case markMissing(Int)
    case unsupported(String)

    var description: String {
        switch self {
        case .observationMissing: return "That observation is unavailable. Inspect the screen again."
        case .observationExpired: return "That observation is stale. Inspect the screen again before acting."
        case .markMissing(let mark): return "Mark [\(mark)] is not present in that observation."
        case .unsupported(let reason): return reason
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Pure selection logic. The model supplies an intent, never an engine. A supported semantic action
/// wins; the pixel action exists only in plans that semantics cannot perform.
enum ControlPlanner {
    private static let pressRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuButton",
        "AXPopUpButton", "AXMenuItem", "AXDisclosureTriangle", "AXStepper",
        "AXSegmentedControl", "AXTab"
    ]
    private static let focusRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSlider"
    ]

    static func semantic(kind: OperatorActionKind, element: OperatorElement,
                         value: String?) -> ControlPlan {
        ControlPlan(id: UUID(), route: .semantic, payload: .semantic(kind: kind, value: value),
                    element: element, observationID: nil, observedAt: nil, observedBundleID: "",
                    requiresExplicitApproval: false,
                    display: display(kind: kind, element: element, value: value))
    }

    static func plan(_ request: VisualControlRequest, observation: ControlObservation?)
        -> Result<ControlPlan, ControlPlanFailure> {
        if case .inspect = request.command {
            return .success(ControlPlan(
                id: UUID(), route: .visual, payload: .observation,
                element: OperatorElement(appName: observation?.appName ?? "",
                                         appBundleID: observation?.appBundleID ?? ""),
                observationID: observation?.id, observedAt: observation?.capturedAt,
                observedBundleID: observation?.appBundleID ?? "", requiresExplicitApproval: false,
                display: "inspect the frontmost app"))
        }
        guard let observation else { return .failure(.observationMissing) }

        func mark(_ index: Int?) -> Result<SoMMark?, ControlPlanFailure> {
            guard let index else { return .success(nil) }
            guard let selected = SetOfMarks.select(index: index, from: observation.marks) else {
                return .failure(.markMissing(index))
            }
            return .success(selected)
        }
        func element(_ selected: SoMMark?, point: CGPoint?) -> OperatorElement {
            let targetPoint = selected?.center ?? point
            let label = selected?.label.isEmpty == false ? selected!.label : request.targetLabel
            return OperatorElement(role: selected?.role ?? "", title: label,
                                   appName: observation.appName,
                                   appBundleID: observation.appBundleID,
                                   screenX: targetPoint.map { Double($0.x) },
                                   screenY: targetPoint.map { Double($0.y) })
        }
        func makeVisual(_ action: CUAction, element: OperatorElement, display: String,
                        corroborated: Bool) -> ControlPlan {
            ControlPlan(id: UUID(), route: .visual, payload: .visual(action), element: element,
                        observationID: observation.id, observedAt: observation.capturedAt,
                        observedBundleID: observation.appBundleID,
                        requiresExplicitApproval: action.mutates && !corroborated,
                        display: display)
        }

        switch request.command {
        case .inspect:
            fatalError("handled above")
        case .click(let index, let rawPoint):
            let selected: SoMMark?
            switch mark(index) { case .success(let m): selected = m; case .failure(let e): return .failure(e) }
            guard let point = selected?.center ?? rawPoint else {
                return .failure(.unsupported("A click needs a current mark or screen point."))
            }
            let hit = selected ?? SetOfMarks.select(containing: point, from: observation.marks)
            let target = element(hit, point: point)
            if let hit, let kind = semanticActivation(for: hit.role) {
                return .success(ControlPlan(
                    id: UUID(), route: .semantic, payload: .semantic(kind: kind, value: nil),
                    element: target, observationID: observation.id, observedAt: observation.capturedAt,
                    observedBundleID: observation.appBundleID, requiresExplicitApproval: false,
                    display: display(kind: kind, element: target, value: nil)))
            }
            return .success(makeVisual(.click(x: point.x, y: point.y), element: target,
                                       display: "click \(target.bestLabel)", corroborated: hit != nil))
        case .move(let index, let rawPoint):
            let selected: SoMMark?
            switch mark(index) { case .success(let m): selected = m; case .failure(let e): return .failure(e) }
            guard let point = selected?.center ?? rawPoint else {
                return .failure(.unsupported("Pointer movement needs a current mark or screen point."))
            }
            let target = element(selected, point: point)
            return .success(makeVisual(.move(x: point.x, y: point.y), element: target,
                                       display: "move pointer to \(target.bestLabel)",
                                       corroborated: selected != nil))
        case .doubleClick(let index, let rawPoint), .rightClick(let index, let rawPoint):
            let selected: SoMMark?
            switch mark(index) { case .success(let m): selected = m; case .failure(let e): return .failure(e) }
            guard let point = selected?.center ?? rawPoint else {
                return .failure(.unsupported("This pointer action needs a current mark or screen point."))
            }
            let target = element(selected, point: point)
            let action: CUAction
            let verb: String
            if case .doubleClick = request.command {
                action = .doubleClick(x: point.x, y: point.y); verb = "double-click"
            } else {
                action = .rightClick(x: point.x, y: point.y); verb = "right-click"
            }
            return .success(makeVisual(action, element: target,
                                       display: "\(verb) \(target.bestLabel)",
                                       corroborated: selected != nil))
        case .scroll(let dy, let dx, let point):
            let p = point ?? .zero
            let hit = point.flatMap { SetOfMarks.select(containing: $0, from: observation.marks) }
            let target = element(hit, point: point)
            return .success(makeVisual(.scroll(x: p.x, y: p.y, dy: dy, dx: dx), element: target,
                                       display: "scroll dy=\(dy) dx=\(dx)",
                                       corroborated: hit != nil))
        case .type(let text, let index):
            let selected: SoMMark?
            switch mark(index) { case .success(let m): selected = m; case .failure(let e): return .failure(e) }
            let target = element(selected, point: selected?.center)
            if let selected, focusRoles.contains(selected.role) {
                return .success(ControlPlan(
                    id: UUID(), route: .semantic, payload: .semantic(kind: .setValue, value: text),
                    element: target, observationID: observation.id, observedAt: observation.capturedAt,
                    observedBundleID: observation.appBundleID, requiresExplicitApproval: false,
                    display: display(kind: .setValue, element: target, value: text)))
            }
            return .success(makeVisual(.type(text), element: target,
                                       display: "type \(text.count) characters",
                                       corroborated: selected != nil))
        case .key(let code, let flags):
            let target = element(nil, point: nil)
            return .success(makeVisual(.key(keyCode: code, flags: flags), element: target,
                                       display: "press key \(code)",
                                       corroborated: false))
        }
    }

    private static func semanticActivation(for role: String) -> OperatorActionKind? {
        if pressRoles.contains(role) { return .press }
        if focusRoles.contains(role) { return .focus }
        return nil
    }

    private static func display(kind: OperatorActionKind, element: OperatorElement,
                                value: String?) -> String {
        var result = "\(kind.verb) “\(element.bestLabel)”"
        if !element.appName.isEmpty { result += " in \(element.appName)" }
        if kind == .setValue, let value { result += " = “\(value)”" }
        return result
    }
}
#endif // circuit-convert

struct ControlStep: Identifiable, Equatable {
    let id: UUID
    let plan: ControlPlan
    var decision: OperatorDecision
    var performed: Bool
    var result: String
    var operatorStepID: UUID?

    var route: ControlRoute { plan.route }
    static func == (lhs: ControlStep, rhs: ControlStep) -> Bool { lhs.id == rhs.id }
}

enum ControlReceipt {
    static func content(plan: ControlPlan, decision: OperatorDecision, performed: Bool,
                        result: String) -> (title: String, detail: String, failure: Bool) {
        let title: String
        switch decision {
        case .block: title = "Operator · \(plan.route.label) · blocked · \(plan.element.bestLabel)"
        case .confirm: title = "Operator · \(plan.route.label) · awaiting approval · \(plan.element.bestLabel)"
        case .allow: title = "Operator · \(plan.route.label) · \(plan.policyKind.verb) · \(plan.element.bestLabel)"
        }
        let detail = result.isEmpty ? decision.reason : "\(decision.reason)\n\n\(result)"
        return (title, detail, decision.isBlock || (decision.isAllow && !performed))
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class ControlArbiter {
    let operatorEngine: OperatorEngine
    let runID = UUID()
    private weak var activity: ActivityLog?
    private var observations: [UUID: ControlObservation] = [:]
    private var pending: [UUID: ControlStep] = [:]
    private(set) var activeStepID: UUID?
    private(set) var trace: [ControlStep] = []

    /// Owned runtime defaults: observations are short-lived and only the four newest are retained.
    var observationLifetime: TimeInterval = 12
    var now: () -> Date = Date.init
    var currentApp: () -> (name: String, bundleID: String) = SoMGeometry.frontmostApp
    var captureProvider: () async -> SoMCapture = { await ScreenCapture.captureSetOfMarks() }
    var visualPerformer: (CUAction) -> CUOutcome = { ComputerUseSidecar.shared.perform($0) }

    init(operatorEngine: OperatorEngine) { self.operatorEngine = operatorEngine }

    func attach(activity: ActivityLog) { self.activity = activity }

    func captureObservation() async -> ControlObservation {
        let capture = await captureProvider()
        let observation = ControlObservation(id: UUID(), capturedAt: now(), marks: capture.marks,
                                             screenGranted: capture.screenGranted,
                                             axGranted: capture.axGranted, reason: capture.reason,
                                             appName: capture.appName,
                                             appBundleID: capture.appBundleID)
        remember(observation)
        return observation
    }

    func remember(_ observation: ControlObservation) {
        observations[observation.id] = observation
        if observations.count > 4 {
            for stale in observations.values.sorted(by: { $0.capturedAt < $1.capturedAt })
                .prefix(observations.count - 4) {
                observations.removeValue(forKey: stale.id)
            }
        }
    }

    func plan(_ request: VisualControlRequest) -> Result<ControlPlan, ControlPlanFailure> {
        if case .inspect = request.command { return ControlPlanner.plan(request, observation: nil) }
        guard let id = request.observationID, let observation = observations[id] else {
            return .failure(.observationMissing)
        }
        guard now().timeIntervalSince(observation.capturedAt) <= observationLifetime else {
            observations.removeValue(forKey: id)
            return .failure(.observationExpired)
        }
        return ControlPlanner.plan(request, observation: observation)
    }

    /// Enforce the policy and execute exactly one route. A semantic failure is terminal; the visual
    /// performer is never called as an after-the-fact fallback.
    @discardableResult
    func propose(_ plan: ControlPlan, dial: ApprovalDial) -> ControlStep {
        if let activeStepID {
            let decision = OperatorDecision.block(
                reason: "Control step \(activeStepID.uuidString) is still awaiting resolution; simultaneous input is blocked.")
            let step = ControlStep(id: plan.id, plan: plan, decision: decision, performed: false,
                                   result: decision.reason, operatorStepID: nil)
            trace.append(step); record(step)
            return step
        }
        if plan.isObservation {
            let decision = OperatorDecision.allow(reason: "Reading the current control map; no input is posted.")
            let step = ControlStep(id: plan.id, plan: plan, decision: decision, performed: false,
                                   result: decision.reason, operatorStepID: nil)
            trace.append(step)
            return step
        }
        if let reason = validationFailure(for: plan) {
            let decision = OperatorDecision.block(reason: reason)
            let step = ControlStep(id: plan.id, plan: plan, decision: decision, performed: false,
                                   result: reason, operatorStepID: nil)
            trace.append(step); record(step)
            return step
        }

        activeStepID = plan.id
        operatorEngine.dial = dial
        switch plan.payload {
        case .semantic(let kind, let value):
            let op = operatorEngine.propose(kind: kind, element: plan.element, value: value)
            let step = ControlStep(id: plan.id, plan: plan, decision: op.decision,
                                   performed: op.performed, result: op.result,
                                   operatorStepID: op.id)
            trace.append(step)
            if op.decision.isConfirm { pending[step.id] = step } else { activeStepID = nil }
            return step
        case .visual(let action):
            var decision = OperatorAX.decide(kind: plan.policyKind, element: plan.element, dial: dial)
            if plan.requiresExplicitApproval, decision.isAllow {
                decision = .confirm(reason: "This pixel target is not corroborated by an accessible control. Explicit approval is required before input is posted.")
            }
            if operatorEngine.isPaused, decision.isAllow {
                decision = .confirm(reason: "The operator is paused. Resume it, then approve this visual step before it can run.")
            }
            var step = ControlStep(id: plan.id, plan: plan, decision: decision,
                                   performed: false, result: "", operatorStepID: nil)
            switch decision {
            case .block:
                step.result = decision.reason; activeStepID = nil; record(step)
            case .confirm:
                step.result = decision.reason.lowercased().contains("paused")
                    ? "Paused — resume, then approve this visual step."
                    : "Awaiting your approval."
                pending[step.id] = step
            case .allow:
                applyVisual(action, to: &step); activeStepID = nil; record(step)
            }
            trace.append(step)
            return step
        case .observation:
            preconditionFailure("observation handled above")
        }
    }

    func resolve(_ id: UUID, approved: Bool) {
        guard var step = pending.removeValue(forKey: id), activeStepID == id else { return }
        defer { activeStepID = nil }

        if !approved || operatorEngine.isPaused {
            step.performed = false
            step.result = approved ? "Approved but paused — not performed." : "Declined — not performed."
            step.decision = .block(reason: step.result)
            if let opID = step.operatorStepID { operatorEngine.resolve(opID, approved: false) }
            replaceTrace(step); if step.route == .visual { record(step) }
            return
        }
        if let reason = validationFailure(for: step.plan) {
            step.performed = false; step.result = reason; step.decision = .block(reason: reason)
            if let opID = step.operatorStepID { operatorEngine.resolve(opID, approved: false) }
            replaceTrace(step); if step.route == .visual { record(step) }
            return
        }

        switch step.plan.payload {
        case .semantic:
            guard let opID = step.operatorStepID else { return }
            operatorEngine.resolve(opID, approved: true)
            if let resolved = operatorEngine.trace.first(where: { $0.id == opID }) {
                step.performed = resolved.performed; step.result = resolved.result
                step.decision = resolved.performed
                    ? .allow(reason: "Approved by you.")
                    : .block(reason: resolved.result)
            }
        case .visual(let action):
            step.decision = .allow(reason: "Approved by you.")
            applyVisual(action, to: &step); record(step)
        case .observation:
            break
        }
        replaceTrace(step)
    }

    func cancelPending() {
        guard let id = activeStepID else { return }
        resolve(id, approved: false)
    }

    private func validationFailure(for plan: ControlPlan) -> String? {
        guard let id = plan.observationID else { return nil }
        guard let observation = observations[id] else {
            return "The observation is unavailable. Inspect again before acting."
        }
        guard now().timeIntervalSince(observation.capturedAt) <= observationLifetime else {
            return "The observation expired. Inspect again before acting."
        }
        let current = currentApp()
        if !plan.observedBundleID.isEmpty, current.bundleID != plan.observedBundleID {
            return "The frontmost app changed after the observation. Inspect again; no input was posted."
        }
        return nil
    }

    private func applyVisual(_ action: CUAction, to step: inout ControlStep) {
        let outcome = visualPerformer(action)
        step.performed = outcome.didAct
        step.result = outcome.detail
        if !outcome.didAct { step.decision = .block(reason: outcome.detail) }
    }

    private func replaceTrace(_ step: ControlStep) {
        if let index = trace.firstIndex(where: { $0.id == step.id }) { trace[index] = step }
    }

    private func record(_ step: ControlStep) {
        let receipt = ControlReceipt.content(plan: step.plan, decision: step.decision,
                                             performed: step.performed, result: step.result)
        activity?.recordStep(parentID: runID, title: receipt.title, detail: receipt.detail,
                             outcome: receipt.failure ? .failure : .success)
    }
}
#endif // circuit-convert
