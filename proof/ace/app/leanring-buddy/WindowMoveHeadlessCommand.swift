#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  WindowMoveHeadlessCommand.swift
//  Ace
//
//  Final, identity-bound mutation for the bundled `window-move` tool.
//
//  Why this is native: the wrapper used to finish in AppleScript, selecting
//  the window whose "AXWindowNumber" attribute equalled the confirmed number.
//  No ordinary application vends that attribute, so the selection matched
//  nothing and every confirmed display move failed as "no longer uniquely
//  available". System Events cannot read the window server's identifier; the
//  signed Ace binary can, so the wrapper hands it the one bound mutation. The
//  wrapper still owns validation, the effect guard, the one-use approval, and
//  the display geometry.
//

#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(ApplicationServices) && !CIRCUIT_WINDOWS_SIM
import ApplicationServices
#endif
import Foundation

nonisolated enum WindowMoveHeadlessCommand {
    static let launchFlag = "--ace-window-move"

    struct Request: Equatable {
        let applicationName: String
        let processIdentifier: pid_t
        let windowIdentifier: UInt32
        let origin: CGPoint
        let size: CGSize
        let shouldFill: Bool
        let stealthEntryRequestPath: String
        let stealthIntentPath: String
        let stealthMarkerPath: String
    }

    /// Strict positional decoder shared with the offline battery. The order is
    /// the wrapper's: name, PID, window, x, y, width, height, fill flag, then
    /// the three Private Mode receipt paths the effect guard resolved.
    static func decodedRequest(from arguments: [String]) -> Request? {
        guard arguments.count == 11,
              !arguments[0].isEmpty,
              let processIdentifier = Int32(arguments[1]),
              processIdentifier > 0,
              let windowIdentifier = UInt32(arguments[2]),
              windowIdentifier > 0,
              let originX = Int(arguments[3]),
              let originY = Int(arguments[4]),
              let width = Int(arguments[5]),
              let height = Int(arguments[6]),
              width > 0, height > 0,
              ["0", "1"].contains(arguments[7]),
              arguments[8...10].allSatisfy({ $0.hasPrefix("/") }) else {
            return nil
        }
        return Request(
            applicationName: arguments[0],
            processIdentifier: processIdentifier,
            windowIdentifier: windowIdentifier,
            origin: CGPoint(x: originX, y: originY),
            size: CGSize(width: width, height: height),
            shouldFill: arguments[7] == "1",
            stealthEntryRequestPath: arguments[8],
            stealthIntentPath: arguments[9],
            stealthMarkerPath: arguments[10]
        )
    }

    /// Mirrors `ace_effect_guard_stealth_is_active`: any object at the entry
    /// request or durable intent name (including a broken symlink) is active,
    /// and a live PID in the marker is active. `lstat` never follows a link.
    static func privateModeIsActive(_ request: Request) -> Bool {
        for receiptPath in [
            request.stealthEntryRequestPath,
            request.stealthIntentPath,
        ] {
            var status = stat()
            if lstat(receiptPath, &status) == 0 { return true }
        }
        guard let markerContents = try? String(
            contentsOfFile: request.stealthMarkerPath,
            encoding: .utf8
        ),
        let markerProcessIdentifier = Int32(
            markerContents.split(
                whereSeparator: \.isNewline
            ).first.map(String.init) ?? ""
        ),
        markerProcessIdentifier > 0 else {
            return false
        }
        return kill(markerProcessIdentifier, 0) == 0 || errno == EPERM
    }

    static func runForever() -> Never {
        guard ProcessInfo.processInfo
            .environment["ACE_BACKGROUND_EXECUTION_MODE"] != "backend" else {
            finish("background work cannot move the owner's windows", status: 6)
        }
        let commandArguments = Array(
            CommandLine.arguments.drop(while: { $0 != launchFlag }).dropFirst()
        )
        guard let request = decodedRequest(from: commandArguments) else {
            finish("the window move request is invalid", status: 2)
        }
        Task { @MainActor in
            let failure = perform(request)
            finish(failure, status: failure == nil ? 0 : 1)
        }
        dispatchMain()
    }

    /// Returns nil on a verified move, otherwise the owner-facing failure.
    @MainActor
    private static func perform(_ request: Request) -> String? {
        guard AXIsProcessTrusted() else {
            return "Ace's Accessibility permission is off, so the window was not moved"
        }
        guard let runningApplication = NSRunningApplication(
            processIdentifier: request.processIdentifier
        ), !runningApplication.isTerminated else {
            return "the confirmed app process is no longer running"
        }
        // Case-sensitive, exact: a recycled PID owned by another app fails.
        guard runningApplication.localizedName == request.applicationName
        else {
            return "the confirmed app identity changed"
        }

        let applicationElement = AXUIElementCreateApplication(
            request.processIdentifier
        )
        AXUIElementSetMessagingTimeout(applicationElement, 1.0)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let windows = windowsValue as? [AXUIElement] else {
            return "the confirmed app did not list its windows"
        }
        let matchingWindows = windows.filter {
            AccessibilityWindowIdentity.windowIdentifier(of: $0)
                == request.windowIdentifier
        }
        guard matchingWindows.count == 1,
              let targetWindow = matchingWindows.first else {
            return "the confirmed app window is no longer uniquely available"
        }

        // Identity resolution above is read-only. Recheck immediately before
        // EACH mutation so Private Mode entry between focus, move, and resize
        // stops the remaining changes.
        guard !privateModeIsActive(request) else { return "Private Mode is active." }
        _ = runningApplication.activate(options: [])
        _ = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)

        guard !privateModeIsActive(request) else { return "Private Mode is active." }
        var requestedOrigin = request.origin
        guard let originValue = AXValueCreate(.cgPoint, &requestedOrigin),
              AXUIElementSetAttributeValue(
                targetWindow,
                kAXPositionAttribute as CFString,
                originValue
              ) == .success else {
            return "\(request.applicationName) did not accept the requested window position"
        }

        if request.shouldFill {
            guard !privateModeIsActive(request) else { return "Private Mode is active." }
            var requestedSize = request.size
            guard let sizeValue = AXValueCreate(.cgSize, &requestedSize),
                  AXUIElementSetAttributeValue(
                    targetWindow,
                    kAXSizeAttribute as CFString,
                    sizeValue
                  ) == .success else {
                return "\(request.applicationName) did not accept the requested window size"
            }
        }

        // Read back from the SAME bound element after the window server has
        // had a moment to settle; an accepted call is not a landed frame.
        usleep(100_000)
        guard let landedOrigin = pointAttribute(
            kAXPositionAttribute,
            of: targetWindow
        ),
        Int(landedOrigin.x.rounded()) == Int(request.origin.x),
        Int(landedOrigin.y.rounded()) == Int(request.origin.y) else {
            return "\(request.applicationName) did not accept the requested window position"
        }
        if request.shouldFill {
            guard let landedSize = sizeAttribute(
                kAXSizeAttribute,
                of: targetWindow
            ),
            Int(landedSize.width.rounded()) == Int(request.size.width),
            Int(landedSize.height.rounded()) == Int(request.size.height) else {
                return "\(request.applicationName) did not accept the requested window size"
            }
        }
        return nil
    }

    private static func pointAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let accessibilityValue = unsafeBitCast(value, to: AXValue.self)
        var point = CGPoint.zero
        return AXValueGetValue(accessibilityValue, .cgPoint, &point)
            ? point
            : nil
    }

    private static func sizeAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let accessibilityValue = unsafeBitCast(value, to: AXValue.self)
        var size = CGSize.zero
        return AXValueGetValue(accessibilityValue, .cgSize, &size)
            ? size
            : nil
    }

    private static func finish(_ failure: String?, status: Int32) -> Never {
        if let failure {
            FileHandle.standardError.write(Data((failure + "\n").utf8))
        }
        exit(status)
    }
}
#endif // circuit-convert
