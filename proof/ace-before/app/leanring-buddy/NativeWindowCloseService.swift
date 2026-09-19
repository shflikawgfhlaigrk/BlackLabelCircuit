#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(ApplicationServices) && !CIRCUIT_WINDOWS_SIM
import ApplicationServices
#endif
import Foundation

nonisolated struct NativeCloseTarget: Hashable {
    let id: UUID
    let processID: pid_t
}
nonisolated enum NativeCloseState { case open, closed, needsSave, unknown }
nonisolated struct NativeCloseDiscovery {
    let targets: [NativeCloseTarget]
    let unreadableApps: Int
}
nonisolated struct NativeCloseResult {
    let complete: Bool
    let closed: Int
    let total: Int
    let reason: String
}
@MainActor protocol NativeWindowCloseBackend {
    func discover(deadline: Date) -> NativeCloseDiscovery
    func state(of target: NativeCloseTarget) -> NativeCloseState
    func requestClose(_ target: NativeCloseTarget) -> Bool
}

/// A single bounded pass over native Close controls. No app activation,
/// keyboard/mouse event, process termination, or save-dialog dismissal.
@MainActor enum NativeWindowCloseService {
    static func closeAll(
        backend: any NativeWindowCloseBackend,
        isAllowed: () -> Bool,
        now: () -> Date = Date.init,
        budget: TimeInterval = 8
    ) async -> NativeCloseResult {
        let deadline = now().addingTimeInterval(budget)
        guard isAllowed() else {
            return NativeCloseResult(complete: false, closed: 0, total: 0, reason: "Window closing was stopped before it began.")
        }
        let discovery = backend.discover(deadline: deadline)
        var stoppedApps = Set<pid_t>()
        var closed = Set<UUID>()
        for target in discovery.targets {
            guard isAllowed(), now() < deadline else { break }
            if stoppedApps.contains(target.processID) { continue }
            switch backend.state(of: target) {
            case .closed: closed.insert(target.id); continue
            case .needsSave: stoppedApps.insert(target.processID); continue
            case .unknown: continue
            case .open: break
            }
            guard isAllowed(), backend.requestClose(target) else { continue }
            let targetDeadline = min(deadline, now().addingTimeInterval(1))
            repeat {
                switch backend.state(of: target) {
                case .closed: closed.insert(target.id)
                case .needsSave: stoppedApps.insert(target.processID)
                case .open, .unknown: break
                }
                if closed.contains(target.id) || stoppedApps.contains(target.processID) { break }
                guard isAllowed(), now() < targetDeadline else { break }
                try? await Task.sleep(for: .milliseconds(50))
            } while true
        }
        let remaining = discovery.targets.count - closed.count
        let complete = remaining == 0 && discovery.unreadableApps == 0 && isAllowed()
        var reason = discovery.targets.isEmpty && complete
            ? "No external application windows were open."
            : "Verified \(closed.count) of \(discovery.targets.count) original windows closed."
        if remaining > 0 { reason += " \(remaining) remain open or unverified." }
        if !stoppedApps.isEmpty { reason += " Save dialogs were left for you to handle." }
        if discovery.unreadableApps > 0 { reason += " Some application windows could not be inspected." }
        if !isAllowed() { reason += " The remaining close requests were stopped." }
        return NativeCloseResult(complete: complete, closed: closed.count, total: discovery.targets.count, reason: reason)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor final class SystemWindowCloseBackend: NativeWindowCloseBackend {
    private struct BoundWindow {
        let app: AXUIElement
        let window: AXUIElement
    }
    private var windows: [UUID: BoundWindow] = [:]
    private var deadline = Date.distantPast

    func discover(deadline: Date) -> NativeCloseDiscovery {
        self.deadline = deadline
        guard AXIsProcessTrusted() else { return NativeCloseDiscovery(targets: [], unreadableApps: 1) }
        var targets: [NativeCloseTarget] = []
        var unreadable = 0
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            guard Date() < deadline, targets.count < 200 else { unreadable += 1; break }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.2)
            guard let current = windowList(element) else { unreadable += 1; continue }
            for window in current {
                guard Date() < deadline, targets.count < 200 else { unreadable += 1; break }
                AXUIElementSetMessagingTimeout(window, 0.2)
                let id = UUID()
                windows[id] = BoundWindow(app: element, window: window)
                targets.append(NativeCloseTarget(id: id, processID: app.processIdentifier))
            }
        }
        return NativeCloseDiscovery(targets: targets, unreadableApps: unreadable)
    }

    func state(of target: NativeCloseTarget) -> NativeCloseState {
        guard Date() < deadline else { return .unknown }
        guard let bound = windows[target.id] else { return .unknown }
        guard let running = NSRunningApplication(processIdentifier: target.processID), !running.isTerminated else { return .closed }
        guard let current = windowList(bound.app) else { return .unknown }
        guard current.contains(where: { CFEqual($0, bound.window) }) else { return .closed }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(bound.window, kAXChildrenAttribute as CFString, &children) == .success,
           let children = children as? [AXUIElement] {
            for child in children.prefix(100) {
                guard Date() < deadline else { return .unknown }
                AXUIElementSetMessagingTimeout(child, 0.1)
                var role: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success,
                   role as? String == kAXSheetRole as String { return .needsSave }
            }
        }
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(bound.window, kAXSubroleAttribute as CFString, &subrole) == .success,
           subrole as? String == kAXDialogSubrole as String { return .needsSave }
        return .open
    }

    func requestClose(_ target: NativeCloseTarget) -> Bool {
        guard state(of: target) == .open, let bound = windows[target.id] else { return false }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bound.window, kAXCloseButtonAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let button = unsafeBitCast(raw, to: AXUIElement.self)
        var enabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &enabled) == .success,
              enabled as? Bool == true, Date() < deadline else { return false }
        return StealthEntryLatch.shared.performUnlessRaised {
            AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        } == true
    }

    private func windowList(_ app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }
}
#endif // circuit-convert
