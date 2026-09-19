// Sovereign — OPERATOR (SV-22): the watch-and-approve cross-app action layer.
//
// THE HONEST CLAIM. The website promises an operator that can actually DO things across the
// buyer's apps — click, type, drive a workflow — not just talk about it. This is the real
// substrate for that: an Accessibility (AXUIElement) action layer that can read another app's
// window/element graph and perform genuine UI actions (press a button, set a text field) on the
// buyer's OWN machine, with the buyer's OWN Accessibility grant. There is no cloud, no bundled
// automation, and NOTHING happens silently: every action passes the SAME deterministic grant/
// posture engine the rest of the app uses (Guardrails / GuardrailPosture), the approval dial is
// on MANUAL by default (approve every step), and there is a HARD deny-list that never lets the
// operator auto-act on a payment, send, or delete surface — even in the most autonomous mode.
//
// Every performed (or blocked, or skipped) step writes ONE real proof-of-execution receipt into
// the ActivityLog — no narrated fake clicks. A receipt exists only because the operator truly
// decided/acted on a real element.
//
// The PURE core (element descriptor, deny-list classification, decision, dial↔posture mapping,
// receipt content, trace ordering) is static/value-typed so it is exhaustively unit-tested with
// NO Accessibility permission, NO live app, NO UI. The macOS AX driver does the real I/O and is
// wired into the engine so enforcement + execution are genuine, not advisory.
import Foundation
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

// MARK: - Action model (pure)

/// What the operator is about to do to a target UI element. `read` observes the graph and never
/// mutates anything; the rest are genuine side-effecting UI actions.
enum OperatorActionKind: String, Codable, Equatable, CaseIterable {
    case read       // read the element / window graph — no mutation, always allowed
    case press      // AXPress — click a button, menu item, checkbox
    case setValue   // AXValue setter — type into a text field / move a slider
    case focus      // raise + focus a window/element (reversible, but a state change)

    /// Whether performing this action changes anything on the buyer's machine. A read never does.
    var mutates: Bool { self != .read }

    /// Buyer-facing verb for the confirmation prompt / receipt.
    var verb: String {
        switch self {
        case .read:     return "read"
        case .press:    return "click"
        case .setValue: return "type into"
        case .focus:    return "focus"
        }
    }
}

/// A PURE snapshot of a UI element the operator is about to touch, built from the AX graph. Every
/// field is a plain string so the deny-list classification is deterministic and testable with no
/// live AXUIElement. `bestLabel` is what a human would call the control.
struct OperatorElement: Equatable, Codable, Hashable {
    var role: String              // AX role, e.g. "AXButton", "AXTextField"
    var title: String             // AXTitle (the control's visible label)
    var roleDescription: String   // AXRoleDescription, e.g. "button", "text field"
    var value: String             // current AXValue (for fields), stringified
    var identifier: String        // AXIdentifier when the app set one
    var appName: String           // owning app's display name
    var appBundleID: String       // owning app's bundle id
    var screenX: Double?          // optional exact target point from a fresh numbered observation
    var screenY: Double?

    init(role: String = "", title: String = "", roleDescription: String = "", value: String = "",
         identifier: String = "", appName: String = "", appBundleID: String = "",
         screenX: Double? = nil, screenY: Double? = nil) {
        self.role = role; self.title = title; self.roleDescription = roleDescription
        self.value = value; self.identifier = identifier; self.appName = appName
        self.appBundleID = appBundleID; self.screenX = screenX; self.screenY = screenY
    }

    /// The most human-meaningful label for this control (title → roleDescription → identifier → role).
    var bestLabel: String {
        for s in [title, roleDescription, identifier, role] {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return "(unlabeled control)"
    }

    /// The app the action targets, for the prompt.
    var appLabel: String {
        let a = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? (appBundleID.isEmpty ? "another app" : appBundleID) : a
    }

    /// All the text the deny-list scans, folded to lowercase.
    var scanText: String {
        [title, roleDescription, identifier, value].joined(separator: " ").lowercased()
    }

    var screenPoint: CGPoint? {
        guard let screenX, let screenY else { return nil }
        return CGPoint(x: screenX, y: screenY)
    }
}

/// The operator's decision for a proposed step. `reason` is shown to the buyer and written to the
/// receipt — always honest, never inflated.
enum OperatorDecision: Equatable {
    case allow(reason: String)     // run it (a read, or an allowlisted action under Auto)
    case confirm(reason: String)   // suspend and wait for the buyer's explicit OK
    case block(reason: String)     // never run it (deny-list under a strict dial, or Skip mode)

    var isAllow: Bool   { if case .allow = self { return true }; return false }
    var isConfirm: Bool { if case .confirm = self { return true }; return false }
    var isBlock: Bool   { if case .block = self { return true }; return false }
    var reason: String {
        switch self { case .allow(let r), .confirm(let r), .block(let r): return r }
    }
}

// MARK: - Approval dial (SV-15) — the one top-level autonomy control

/// The buyer's top-level operator autonomy setting. It maps 1:1 onto the SAME grant engine the
/// rest of the app already uses (`GuardrailPosture`) so there is never a second, divergent policy —
/// the deterministic Guardrails gate stays the single source of truth. Defaults to `.manual`
/// (deny-by-default: nothing runs without the buyer's OK).
enum ApprovalDial: String, Codable, CaseIterable, Identifiable, Hashable {
    /// DEFAULT. Approve every operator action before it runs. (== .confirmSideEffects)
    case manual
    /// Hands-off: allowlisted operator actions run without asking — but the deny-list
    /// (payment / send / delete) STILL stops for your explicit OK. (== .autonomousAllowlist)
    case auto
    /// Watch-only: the operator proposes each step for your review but performs NOTHING that
    /// mutates. The strictest floor. (== .blockDestructive, plus operator side-effects are held.)
    case skip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .auto:   return "Auto"
        case .skip:   return "Skip"
        }
    }

    var blurb: String {
        switch self {
        case .manual: return "Approve every action. The operator waits for your OK before it clicks or types anything."
        case .auto:   return "Hands-off. Allowlisted actions run automatically — but payments, sends, and deletes always stop for your explicit approval."
        case .skip:   return "Watch only. The operator proposes each step for your review and performs nothing that changes your machine."
        }
    }

    var icon: String {
        switch self {
        case .manual: return "hand.raised.fill"
        case .auto:   return "bolt.fill"
        case .skip:   return "eye.fill"
        }
    }

    /// The grant-engine posture this dial maps to — how operator actions flow through the shared
    /// Guardrails policy. `.skip` maps to the strictest posture; the engine additionally HOLDS any
    /// mutating operator step in Skip so watch-only is genuinely non-acting.
    var posture: GuardrailPosture {
        switch self {
        case .manual: return .confirmSideEffects
        case .auto:   return .autonomousAllowlist
        case .skip:   return .blockDestructive
        }
    }

    /// Round-trip the shared posture back to a dial so the ONE stored value (guardrailPosture) can
    /// drive both the general grant UI and this operator dial without a second persisted key.
    init(posture: GuardrailPosture) {
        switch posture {
        case .confirmSideEffects:  self = .manual
        case .autonomousAllowlist: self = .auto
        case .blockDestructive:    self = .skip
        }
    }
}

// MARK: - The deterministic operator gate (pure + static → exhaustively unit-tested)

enum OperatorAX {
    /// Substrings on a control's label/description/identifier/value that mark it as an IRREVERSIBLE
    /// or FINANCIAL surface the operator must NEVER auto-act on. This is a HARD deny-list: a matched
    /// element always requires the buyer's explicit approval (never Auto), and is BLOCKED outright
    /// under the strict dial. Conservative-but-meaningful — the controls a buyer would never want
    /// clicked silently.
    static let denyPatterns: [String] = [
        // money / commerce
        "pay", "payment", "buy", "purchase", "checkout", "check out", "place order", "order now",
        "subscribe", "upgrade plan", "add card", "confirm charge", "charge", "withdraw", "deposit",
        "transfer", "wire", "send money", "venmo", "zelle", "refund", "billing",
        // irreversible / destructive
        "delete", "remove", "erase", "destroy", "wipe", "trash", "permanently",
        "deactivate", "close account", "cancel account", "reset", "format", "uninstall",
        // outbound sends / publishes (leave the buyer's control)
        "send", "publish", "post", "tweet", "broadcast", "reply all", "confirm & send"
    ]

    /// True if this control looks like a payment / irreversible / outbound-send surface. A pure
    /// READ can never be denied (observing the graph is always safe). Pure → testable.
    static func isDenied(_ element: OperatorElement, kind: OperatorActionKind) -> Bool {
        guard kind.mutates else { return false }
        let hay = element.scanText
        return denyPatterns.contains { hay.contains($0) }
    }

    /// THE GATE. Given a proposed action on an element and the buyer's dial, decide allow / confirm
    /// / block. Pure → exhaustively unit-tested; the engine enforces the result before anything runs.
    ///
    ///  · A read is always allowed (no mutation).
    ///  · Skip blocks every mutating action (watch-only).
    ///  · A deny-list surface NEVER auto-runs: confirm under Manual/Auto, block under Skip.
    ///  · Otherwise: confirm under Manual, allow under Auto.
    static func decide(kind: OperatorActionKind, element: OperatorElement, dial: ApprovalDial) -> OperatorDecision {
        if !kind.mutates {
            return .allow(reason: "Reading the UI element graph of \(element.appLabel) — no action performed.")
        }
        let denied = isDenied(element, kind: kind)
        switch dial {
        case .skip:
            return .block(reason: "Watch-only (Skip): the operator does not perform actions. Proposed \(kind.verb) \u{201C}\(element.bestLabel)\u{201D} in \(element.appLabel) was recorded for your review, not run.")
        case .manual:
            if denied {
                return .confirm(reason: "\u{201C}\(element.bestLabel)\u{201D} looks like a payment/irreversible control in \(element.appLabel) — explicit approval required before the operator \(kind.verb)s it.")
            }
            return .confirm(reason: "The operator wants to \(kind.verb) \u{201C}\(element.bestLabel)\u{201D} in \(element.appLabel) — approve this step?")
        case .auto:
            if denied {
                return .confirm(reason: "Auto still stops for payment/irreversible controls: \u{201C}\(element.bestLabel)\u{201D} in \(element.appLabel) needs your explicit OK before the operator \(kind.verb)s it.")
            }
            return .allow(reason: "Auto: allowlisted operator action (\(kind.verb) \u{201C}\(element.bestLabel)\u{201D} in \(element.appLabel)) permitted and audited.")
        }
    }

    /// Build the proof-of-execution receipt content for a consequential operator decision. Returns
    /// the title/detail/isFailure a real ActivityLog step will carry. A `.block` is a failure (the
    /// action was prevented). Pure → the content is unit-testable; the engine records it.
    static func receipt(for decision: OperatorDecision, kind: OperatorActionKind, element: OperatorElement)
        -> (title: String, detail: String, isFailure: Bool) {
        let where_ = "\(element.appLabel) \u{00B7} \(element.bestLabel)"
        switch decision {
        case .block:
            return ("Operator \u{00B7} Semantic \u{00B7} skipped \(kind.verb) \u{00B7} \(where_)", decision.reason, true)
        case .confirm:
            return ("Operator \u{00B7} Semantic \u{00B7} awaiting approval \u{00B7} \(where_)", decision.reason, false)
        case .allow:
            return ("Operator \u{00B7} Semantic \u{00B7} \(kind.verb) \u{00B7} \(where_)", decision.reason, false)
        }
    }

    /// The honest, buyer-facing description of what the operator actually is — used in Settings so
    /// the claim is never inflated. There is no "AI that guarantees safety"; there is a real AX
    /// action layer behind a deterministic gate, a deny-list, and (by default) human approval.
    static let honestDescription =
        "The operator acts across your apps using macOS Accessibility, on your machine, with your grant. "
        + "Every action passes the same deterministic policy gate the rest of Sovereign uses: it is "
        + "allowed, held for your approval, or blocked. A hard deny-list never lets it auto-click a "
        + "payment, send, or delete control. Set the dial to Manual to approve every step, Auto to let "
        + "allowlisted actions run, or Skip to watch without acting. Every step is written to your activity log."
}

// MARK: - A single proposed/executed operator step (the live, ordered trace)

/// One entry in the operator's live trace: what it proposed, how the gate decided, and (once the
/// buyer answers / it runs) the real outcome. Insertion order is preserved by the engine so the
/// trace reads top-to-bottom in the order steps actually happened.
struct OperatorStep: Identifiable, Equatable {
    let id = UUID()
    var kind: OperatorActionKind
    var element: OperatorElement
    var value: String?               // for setValue steps: what would be typed
    var decision: OperatorDecision
    var performed: Bool = false      // true once the AX driver actually ran it
    var result: String = ""          // the real outcome text (or the block/skip reason)
    var at = Date()

    static func == (a: OperatorStep, b: OperatorStep) -> Bool { a.id == b.id }
}

// MARK: - macOS Accessibility driver — the REAL AXUIElement I/O

#if os(macOS)
/// The genuine action layer. Reads a target app's element graph and performs real UI actions via
/// AXUIElement. Requires the buyer to grant Accessibility (System Settings ▸ Privacy). Nothing here
/// runs in the headless test binary (no permission, no live app) — it exists so the shipped app can
/// actually operate, and so the binary provably carries the AXUIElement symbols.
@MainActor
enum OperatorAXDriver {
    /// Is Sovereign trusted for Accessibility? Read live from the system — never faked.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompt the buyer to grant Accessibility (opens the system pane). Honest: we can only ask.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Read a bounded snapshot of a running app's element graph. Bounded in depth + node count so a
    /// deep UI can't hang the walk. Returns honest empty when access is missing.
    static func snapshot(pid: pid_t, appName: String, bundleID: String,
                         maxDepth: Int = 4, maxNodes: Int = 200) -> [OperatorElement] {
        guard isTrusted else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var out: [OperatorElement] = []
        walk(app, appName: appName, bundleID: bundleID, depth: 0,
             maxDepth: maxDepth, maxNodes: maxNodes, into: &out)
        return out
    }

    private static func walk(_ el: AXUIElement, appName: String, bundleID: String, depth: Int,
                             maxDepth: Int, maxNodes: Int, into out: inout [OperatorElement]) {
        guard depth <= maxDepth, out.count < maxNodes else { return }
        out.append(describe(el, appName: appName, bundleID: bundleID))
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            if out.count >= maxNodes { break }
            walk(child, appName: appName, bundleID: bundleID, depth: depth + 1,
                 maxDepth: maxDepth, maxNodes: maxNodes, into: &out)
        }
    }

    /// Build the pure descriptor the deny-list scans, from a live element.
    static func describe(_ el: AXUIElement, appName: String, bundleID: String) -> OperatorElement {
        OperatorElement(
            role: str(el, kAXRoleAttribute),
            title: str(el, kAXTitleAttribute),
            roleDescription: str(el, kAXRoleDescriptionAttribute),
            value: str(el, kAXValueAttribute),
            identifier: str(el, kAXIdentifierAttribute),
            appName: appName, appBundleID: bundleID)
    }

    /// Perform a real UI action on a live element. Returns (success, human-readable result). The
    /// CALLER is responsible for having passed the gate first — the driver never gates itself.
    static func perform(_ kind: OperatorActionKind, on el: AXUIElement, value: String?) -> (Bool, String) {
        guard isTrusted else { return (false, "Accessibility access isn't granted. Grant it in System Settings ▸ Privacy & Security ▸ Accessibility.") }
        switch kind {
        case .read:
            return (true, "Read element.")
        case .press:
            let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
            return err == .success ? (true, "Pressed the control.")
                                   : (false, "Press failed (\(axErr(err))).")
        case .focus:
            let err = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return err == .success ? (true, "Focused the element.")
                                   : (false, "Focus failed (\(axErr(err))).")
        case .setValue:
            let v = (value ?? "") as CFString
            let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, v)
            return err == .success ? (true, "Set the value.")
                                   : (false, "Set value failed (\(axErr(err))).")
        }
    }

    /// Perform an action on the buyer's CURRENTLY FOCUSED UI element (frontmost app). The honest
    /// live-execution path for the OperatorEngine's performer: it resolves the real focused element
    /// through the system-wide AX handle, then performs the genuine action.
    static func performOnFocused(_ kind: OperatorActionKind, value: String?) -> (Bool, String) {
        guard isTrusted else { return (false, "Accessibility access isn't granted. Grant it in System Settings ▸ Privacy & Security ▸ Accessibility.") }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused else { return (false, "No focused UI element to act on right now.") }
        // A successful AXFocusedUIElement copy always yields an AXUIElement.
        return perform(kind, on: ref as! AXUIElement, value: value)
    }

    /// Perform against an exact point from a fresh numbered observation when present. A failed
    /// point resolution is terminal: it never falls through to whichever unrelated control happens
    /// to be focused. Untargeted semantic requests retain the focused-element path.
    static func performTargeted(_ kind: OperatorActionKind, element: OperatorElement,
                                value: String?) -> (Bool, String) {
        guard let point = element.screenPoint else { return performOnFocused(kind, value: value) }
        guard isTrusted else {
            return (false, "Accessibility access isn't granted. Grant it in System Settings ▸ Privacy & Security ▸ Accessibility.")
        }
        let system = AXUIElementCreateSystemWide()
        var target: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &target)
        guard err == .success, let target else {
            return (false, "The observed control is no longer available at that screen position. Inspect again before acting.")
        }
        guard let actionTarget = actionTarget(startingAt: target, kind: kind,
                                              preferredRole: element.role) else {
            return (false, "The observed point no longer resolves to a control that supports \(kind.verb). Inspect again before acting.")
        }
        return perform(kind, on: actionTarget, value: value)
    }

    /// Describe the buyer's CURRENTLY FOCUSED UI element — the very element `performOnFocused`
    /// would act on — so the deny-list can cross-check the REAL on-screen control against the
    /// label the model asserted. Returns nil when Accessibility isn't granted or nothing is
    /// focused (honest: the engine then judges the model's descriptor, never inventing a control).
    static func focusedElementDescriptor() -> OperatorElement? {
        guard isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused else { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        return describe(ref as! AXUIElement,
                        appName: front?.localizedName ?? "",
                        bundleID: front?.bundleIdentifier ?? "")
    }

    /// Describe the live element at an observed point for a final consequence check immediately
    /// before execution. Returns nil rather than substituting a focused control.
    static func targetedElementDescriptor(_ proposed: OperatorElement) -> OperatorElement? {
        guard let point = proposed.screenPoint, isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var target: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &target) == .success,
              let target else { return nil }
        let chain = elementChain(startingAt: target)
        let resolved = chain.first { !proposed.role.isEmpty && str($0, kAXRoleAttribute) == proposed.role }
            ?? chain.first(where: supportsAnyMutation)
            ?? target
        let front = NSWorkspace.shared.frontmostApplication
        var descriptor = describe(resolved,
                                  appName: front?.localizedName ?? proposed.appName,
                                  bundleID: front?.bundleIdentifier ?? proposed.appBundleID)
        descriptor.screenX = point.x; descriptor.screenY = point.y
        return descriptor
    }

    /// Hit-testing can return a label or layout descendant inside the numbered control. Resolve the
    /// closest ancestor that actually supports the selected semantic action; never jump to a
    /// focused or unrelated element.
    private static func actionTarget(startingAt element: AXUIElement, kind: OperatorActionKind,
                                     preferredRole: String) -> AXUIElement? {
        let chain = elementChain(startingAt: element)
        if !preferredRole.isEmpty,
           let exact = chain.first(where: {
               str($0, kAXRoleAttribute) == preferredRole && supports(kind, on: $0)
           }) {
            return exact
        }
        return chain.first { supports(kind, on: $0) }
    }

    private static func elementChain(startingAt element: AXUIElement) -> [AXUIElement] {
        var chain: [AXUIElement] = []
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let value = current else { break }
            chain.append(value)
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(value, kAXParentAttribute as CFString,
                                                &parentRef) == .success,
                  let parentRef else { break }
            current = (parentRef as! AXUIElement)
        }
        return chain
    }

    private static func supports(_ kind: OperatorActionKind, on element: AXUIElement) -> Bool {
        switch kind {
        case .read:
            return true
        case .press:
            var names: CFArray?
            guard AXUIElementCopyActionNames(element, &names) == .success,
                  let actions = names as? [String] else { return false }
            return actions.contains(kAXPressAction)
        case .focus:
            return attributeIsSettable(kAXFocusedAttribute, on: element)
        case .setValue:
            return attributeIsSettable(kAXValueAttribute, on: element)
        }
    }

    private static func supportsAnyMutation(_ element: AXUIElement) -> Bool {
        supports(.press, on: element) || supports(.setValue, on: element)
            || supports(.focus, on: element)
    }

    private static func attributeIsSettable(_ attribute: String,
                                            on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func str(_ el: AXUIElement, _ attr: String) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return "" }
        if let s = ref as? String { return s }
        if let n = ref as? NSNumber { return n.stringValue }
        return ""
    }

    private static func axErr(_ e: AXError) -> String {
        switch e {
        case .success: return "success"
        case .actionUnsupported: return "action unsupported"
        case .attributeUnsupported: return "attribute unsupported"
        case .apiDisabled: return "accessibility API disabled"
        case .notImplemented: return "not implemented"
        case .cannotComplete: return "cannot complete"
        case .noValue: return "no value"
        default: return "error \(e.rawValue)"
        }
    }
}
#endif

// MARK: - OperatorEngine — orchestrates decide → (approve) → perform → RECEIPT, with a pausable trace

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Ties the pure gate to the real driver and the proof-of-execution ledger. Holds the buyer's dial,
/// a live pausable trace (SV-15), and records ONE real receipt per consequential step. In Skip mode,
/// or while paused, mutating steps are HELD (never performed) — watch-and-approve, for real.
@MainActor
final class OperatorEngine: ObservableObject {
    /// The live, ordered trace shown in the UI. Newest appended at the end (insertion order == the
    /// order steps happened). SV-15's "live action/reasoning trace view".
    @Published private(set) var trace: [OperatorStep] = []
    /// Pause the operator: proposals are still decided + recorded, but nothing that mutates is
    /// performed until the buyer resumes. A genuine hold, not a cosmetic flag.
    @Published var isPaused = false
    /// The active autonomy dial. Mirrors AppSettings.approvalDial; the app keeps them in sync.
    @Published var dial: ApprovalDial = .manual

    private weak var activity: ActivityLog?
    /// One run id so every operator step links under a single terminal receipt in the ledger.
    let runID = UUID()

    /// Injected real performer. The app wires this to OperatorAXDriver.perform on a live element;
    /// tests inject a deterministic stub so the orchestration is proven with NO Accessibility grant.
    var performer: (OperatorActionKind, OperatorElement, String?) -> (Bool, String) =
        { _, _, _ in (false, "No operator driver attached.") }

    /// Optional LIVE safety cross-check. On macOS with the buyer's Accessibility grant, this returns
    /// the REAL element the performer is about to touch (the focused control), so the deny-list can
    /// judge the ACTUAL on-screen surface — not merely the label the model asserted. nil when
    /// unavailable (no grant, nothing focused, tests). Purely additive: it can only make a step
    /// STRICTER (a benign-LABELLED action over a real Send/Pay/Delete control is caught), never
    /// looser — so a model that omits or mis-names the target can never slip a consequential
    /// control past Auto.
    var liveInspector: (() -> OperatorElement?)? = nil
    /// Target-aware inspector used for numbered observations. It must resolve only the proposed
    /// point and return nil if that target is stale; it may never substitute the focused element.
    var targetInspector: ((OperatorElement) -> OperatorElement?)? = nil

    func attach(activity: ActivityLog) { self.activity = activity }

    /// Propose one operator step. Decides via the shared gate, records a real receipt, and — only
    /// when the decision allows AND the engine isn't paused — performs the real action. A `confirm`
    /// decision is HELD (the caller drives the UI approval, then calls `resolve`). Returns the step.
    @discardableResult
    func propose(kind: OperatorActionKind, element: OperatorElement, value: String? = nil) -> OperatorStep {
        var element = element
        var decision = OperatorAX.decide(kind: kind, element: element, dial: dial)
        // LIVE CROSS-CHECK (SV-22 honesty): when the gate would otherwise ALLOW a mutating step
        // (i.e. Auto + a benign-looking label), read the REAL element the operator is about to
        // touch and re-judge on THAT. If the true on-screen control is a payment/send/delete
        // surface the model's label didn't name, we adopt the live descriptor and re-decide — so
        // the receipt names the real control and the deny-list holds it for approval. This can
        // only make a step STRICTER; it never loosens one (a read never mutates and is skipped).
        let inspected = inspectLiveTarget(for: element)
        if kind.mutates, decision.isAllow, let live = inspected,
           OperatorAX.isDenied(live, kind: kind) {
            element = live
            decision = OperatorAX.decide(kind: kind, element: live, dial: dial)
        }
        if kind.mutates, isPaused, decision.isAllow {
            decision = .confirm(reason: "The operator is paused. Resume it, then approve this step before it can run.")
        }
        var step = OperatorStep(kind: kind, element: element, value: value, decision: decision)

        switch decision {
        case .block:
            step.result = decision.reason
            recordReceipt(decision, kind: kind, element: element)
        case .confirm:
            step.result = decision.reason.lowercased().contains("paused")
                ? "Paused — resume, then approve this step."
                : "Awaiting your approval."
            // no receipt yet — the terminal outcome (approved/declined) is recorded on resolve
        case .allow:
            if isPaused {
                step.result = "Paused — held until you resume."
            } else {
                perform(&step)
                recordReceipt(decision, kind: kind, element: element, extra: step.result,
                              performed: step.performed)
            }
        }
        trace.append(step)
        return step
    }

    /// Resolve a confirm-gated step after the buyer answered. Approved + not paused → perform it;
    /// otherwise it is recorded as declined/held. Always writes ONE real receipt.
    func resolve(_ id: UUID, approved: Bool) {
        guard let idx = trace.firstIndex(where: { $0.id == id }) else { return }
        var step = trace[idx]
        guard step.decision.isConfirm else { return }
        if approved && !isPaused {
            // Re-check immediately before acting. If a benign proposal now resolves to a consequence
            // surface, the old approval does not transfer to the changed target.
            if step.kind.mutates,
               let live = inspectLiveTarget(for: step.element),
               !OperatorAX.isDenied(step.element, kind: step.kind),
               OperatorAX.isDenied(live, kind: step.kind) {
                step.element = live
                step.performed = false
                step.result = "The live target changed to a payment, send, or irreversible control. Inspect and approve the new target before acting."
                let d = OperatorDecision.block(reason: step.result)
                recordReceipt(d, kind: step.kind, element: step.element)
                trace[idx] = step
                return
            }
            perform(&step)
            let d = OperatorDecision.allow(reason: "Approved by you.")
            recordReceipt(d, kind: step.kind, element: step.element, extra: step.result,
                          performed: step.performed)
        } else {
            step.performed = false
            step.result = approved ? "Approved but paused — held until you resume." : "Declined — not performed."
            let d = OperatorDecision.block(reason: step.result)
            recordReceipt(d, kind: step.kind, element: step.element)
        }
        trace[idx] = step
    }

    /// Run the real (or injected) performer and fold the outcome into the step.
    private func perform(_ step: inout OperatorStep) {
        let (ok, msg) = performer(step.kind, step.element, step.value)
        step.performed = ok
        step.result = msg
    }

    /// A numbered target must be inspected at its observed point or not at all. Falling back to the
    /// focused control would mix two different UI elements in one decision. Untargeted operate_ui
    /// steps retain the focused-element cross-check.
    private func inspectLiveTarget(for element: OperatorElement) -> OperatorElement? {
        if element.screenPoint != nil { return targetInspector?(element) }
        return liveInspector?()
    }

    private func recordReceipt(_ decision: OperatorDecision, kind: OperatorActionKind,
                               element: OperatorElement, extra: String? = nil,
                               performed: Bool? = nil) {
        let r = OperatorAX.receipt(for: decision, kind: kind, element: element)
        var detail = r.detail
        if let e = extra, !e.isEmpty, e != r.detail { detail += "\n\n" + e }
        activity?.recordStep(parentID: runID, title: r.title, detail: detail,
                             outcome: (r.isFailure || performed == false) ? .failure : .success)
    }

    /// Clear the live trace (does not touch the persisted ledger — those receipts are permanent).
    func clearTrace() { trace.removeAll() }
}
#endif // circuit-convert
