// Sovereign — pixel input driver.
//
// This file owns the low-level CoreGraphics event boundary for UI surfaces that do not expose a
// usable Accessibility action. Policy lives above this driver: callers must select an engine and
// pass the action through the shared approval dial before `perform` is reached.
//
// Synthetic input requires Accessibility permission for Sovereign's signed process identity. A
// missing grant is a terminal denial for the requested action; the driver never posts an event and
// never reports success. Permission checking is injectable so the denial path is deterministic in
// headless tests.
import Foundation
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(os) && !CIRCUIT_WINDOWS_SIM
import os
#else
import CircuitPortKit
#endif

// MARK: - Action model (pure, testable)

/// A pixel-level computer-use action. Coordinates are in global screen points (top-left origin,
/// matching CGEvent's coordinate space).
enum CUAction: Equatable {
    case move(x: Double, y: Double)
    case click(x: Double, y: Double)
    case doubleClick(x: Double, y: Double)
    case rightClick(x: Double, y: Double)
    case scroll(x: Double, y: Double, dy: Int, dx: Int)
    case type(String)
    case key(keyCode: CGKeyCode, flags: CGEventFlags)

    /// Every posted event changes interactive state, including moving the buyer's pointer.
    var mutates: Bool { true }

    var verb: String {
        switch self {
        case .move:        return "move pointer"
        case .click:       return "click"
        case .doubleClick: return "double-click"
        case .rightClick:  return "right-click"
        case .scroll:      return "scroll"
        case .type:        return "type"
        case .key:         return "press key"
        }
    }
}

/// The result of attempting an action. CoreGraphics confirms event construction and submission but
/// provides no delivery acknowledgement, so success is named `.posted`, not "performed".
enum CUOutcome: Equatable {
    case posted(String)      // real event(s) submitted to the HID event tap; human detail
    case denied(String)      // TCC not granted — inert; human detail
    case failed(String)      // granted but the post failed; honest error

    var didAct: Bool { if case .posted = self { return true }; return false }
    var detail: String {
        switch self { case .posted(let d), .denied(let d), .failed(let d): return d }
    }
}

// MARK: - Agent cursor motion (pure)

/// A small arced path used by a future visible cursor overlay. The curve is Black Label-owned and
/// intentionally simple: smoothstep timing plus a bounded perpendicular arc. It has no I/O and is
/// deterministic for tests.
struct AgentCursorMotion: Equatable {
    var arcRatio: Double = 0.10
    var enabled: Bool = true

    /// Sample the path from `from` to `to`. Endpoints are exact and a disabled motion returns the
    /// destination directly, allowing callers to honor reduced-motion settings without branching.
    func path(from: CGPoint, to: CGPoint, steps: Int = 20) -> [CGPoint] {
        guard enabled else { return [to] }
        guard steps > 1 else { return [to] }
        let dx = to.x - from.x, dy = to.y - from.y
        let dist = (dx*dx + dy*dy).squareRoot()
        let px = dist == 0 ? 0 : -dy / dist
        let py = dist == 0 ? 0 :  dx / dist
        let bump = dist * min(max(arcRatio, 0), 0.20)
        var pts: [CGPoint] = []
        for i in 0..<steps {
            let t = Double(i) / Double(steps - 1)
            let ease = smooth(t)
            let arc = sin(t * Double.pi) * bump
            let x = from.x + dx * ease + px * arc
            let y = from.y + dy * ease + py * arc
            pts.append(CGPoint(x: x, y: y))
        }
        return pts
    }

    private func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}

// MARK: - The sidecar

/// The single seam the agent loop calls to drive pixel-level input. Inert (returns `.denied`)
/// until the buyer grants Accessibility to Sovereign's signed identity.
final class ComputerUseSidecar {
    static let shared = ComputerUseSidecar()
    private let log = Logger(subsystem: "com.blacklabel.sovereign", category: "computeruse")
    private let permissionCheck: () -> Bool
    var motion = AgentCursorMotion()

    init(permissionCheck: @escaping () -> Bool = ComputerUseSidecar.systemPermission) {
        self.permissionCheck = permissionCheck
    }

    private static func systemPermission() -> Bool {
        #if os(macOS) && canImport(ApplicationServices)
        return AXIsProcessTrusted()
        #else
        return false
        #endif
    }

    /// True only when the process is a TRUSTED Accessibility client. Synthetic CGEvent input from
    /// an untrusted process is dropped by the WindowServer, so we gate on this and never pretend.
    var isGranted: Bool { permissionCheck() }

    /// Perform one action. Honest states: `.posted` only after a real event post; `.denied`
    /// (inert) when TCC is missing; `.failed` when granted but the OS refused the event.
    @discardableResult
    func perform(_ action: CUAction) -> CUOutcome {
        guard isGranted else {
            let msg = "Accessibility permission is required to synthesize input. Grant Sovereign in System Settings ▸ Privacy & Security ▸ Accessibility."
            log.notice("computer-use \(action.verb, privacy: .public) refused — \(msg, privacy: .public)")
            return .denied(msg)
        }
        #if os(macOS) && canImport(CoreGraphics)
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed("Could not create a CGEventSource.")
        }
        switch action {
        case .move(let x, let y):
            return post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left),
                        "Moved pointer to (\(Int(x)), \(Int(y))).")
        case .click(let x, let y):
            return mouseClick(source, x: x, y: y, button: .left, down: .leftMouseDown, up: .leftMouseUp, clicks: 1, verb: "Clicked")
        case .doubleClick(let x, let y):
            return mouseClick(source, x: x, y: y, button: .left, down: .leftMouseDown, up: .leftMouseUp, clicks: 2, verb: "Double-clicked")
        case .rightClick(let x, let y):
            return mouseClick(source, x: x, y: y, button: .right, down: .rightMouseDown, up: .rightMouseUp, clicks: 1, verb: "Right-clicked")
        case .scroll(_, _, let dy, let dx):
            let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
            return post(e, "Scrolled (dy=\(dy), dx=\(dx)).")
        case .type(let text):
            return typeText(source, text)
        case .key(let keyCode, let flags):
            return keyStroke(source, keyCode: keyCode, flags: flags)
        }
        #else
        return .denied("Desktop computer control is available only in Sovereign for macOS.")
        #endif
    }

    #if os(macOS) && canImport(CoreGraphics)
    private func mouseClick(_ src: CGEventSource, x: Double, y: Double,
                            button: CGMouseButton, down: CGEventType, up: CGEventType,
                            clicks: Int, verb: String) -> CUOutcome {
        let p = CGPoint(x: x, y: y)
        for n in 1...clicks {
            guard let d = CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: p, mouseButton: button),
                  let u = CGEvent(mouseEventSource: src, mouseType: up, mouseCursorPosition: p, mouseButton: button)
            else { return .failed("Could not build mouse events.") }
            d.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            u.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            d.post(tap: .cghidEventTap)
            u.post(tap: .cghidEventTap)
        }
        return .posted("Posted \(verb.lowercased()) at (\(Int(x)), \(Int(y))).")
    }

    private func typeText(_ src: CGEventSource, _ text: String) -> CUOutcome {
        for scalar in text.unicodeScalars {
            var utf16 = Array(String(scalar).utf16)
            guard let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { return .failed("Could not build keyboard events.") }
            d.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            u.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            d.post(tap: .cghidEventTap)
            u.post(tap: .cghidEventTap)
        }
        return .posted("Posted \(text.count) typed character\(text.count == 1 ? "" : "s").")
    }

    private func keyStroke(_ src: CGEventSource, keyCode: CGKeyCode, flags: CGEventFlags) -> CUOutcome {
        guard let d = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let u = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return .failed("Could not build key events.") }
        d.flags = flags; u.flags = flags
        d.post(tap: .cghidEventTap)
        u.post(tap: .cghidEventTap)
        return .posted("Posted key \(keyCode).")
    }

    private func post(_ event: CGEvent?, _ detail: String) -> CUOutcome {
        guard let event else { return .failed("Could not build event.") }
        event.post(tap: .cghidEventTap)
        return .posted("Posted event. \(detail)")
    }
    #endif
}
