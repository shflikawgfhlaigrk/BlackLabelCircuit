// Sovereign — screen observation and numbered control map.
//
// A capture combines one local ScreenCaptureKit frame with a deterministic index of interactive
// Accessibility rectangles. The index lets the agent refer to a current control by number while
// the control arbiter remains responsible for choosing semantic or pixel input.
//
// Screen Recording and Accessibility are independent grants. The result carries both permission
// states and an explicit reason so a denied frame or missing geometry is never presented as a
// successful blank observation. Ordering, selection, and size calculations remain pure.
import Foundation
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
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

// MARK: - Set-of-marks model (pure, testable)

/// One numbered mark over an interactive on-screen control. `rect` is in global screen points.
struct SoMMark: Equatable {
    var index: Int
    var role: String
    var label: String
    var rect: CGRect

    /// Center point the computer-use sidecar would click for this mark.
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

enum SetOfMarks {
    /// Interactive AX roles that deserve a numbered target.
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXLink", "AXCheckBox", "AXRadioButton",
        "AXMenuButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXTab", "AXMenuItem",
        "AXDisclosureTriangle", "AXStepper", "AXSegmentedControl"
    ]

    struct Candidate: Equatable { var role: String; var label: String; var rect: CGRect }

    /// Number the interactive candidates in a stable order (top-to-bottom, then left-to-right).
    /// Non-interactive or zero-area candidates are dropped — no marks for things you can't click.
    static func build(from candidates: [Candidate]) -> [SoMMark] {
        let usable = candidates.enumerated().filter {
            interactiveRoles.contains($0.element.role)
                && $0.element.rect.width > 1 && $0.element.rect.height > 1
        }
        let ordered = usable.sorted {
            let lhs = $0.element, rhs = $1.element
            if lhs.rect.minY != rhs.rect.minY { return lhs.rect.minY < rhs.rect.minY }
            if lhs.rect.minX != rhs.rect.minX { return lhs.rect.minX < rhs.rect.minX }
            return $0.offset < $1.offset
        }
        return ordered.enumerated().map { numbered in
            let candidate = numbered.element.element
            return SoMMark(index: numbered.offset + 1, role: candidate.role,
                           label: candidate.label, rect: candidate.rect)
        }
    }

    /// Resolve an exact numbered mark. Marks are one-based for human-facing prompts.
    static func select(index: Int, from marks: [SoMMark]) -> SoMMark? {
        marks.first { $0.index == index }
    }

    /// Resolve the smallest mark containing a coordinate. Nested controls choose the tightest target;
    /// ties use the stable mark number.
    static func select(containing point: CGPoint, from marks: [SoMMark]) -> SoMMark? {
        marks.filter { $0.rect.contains(point) }.min {
            let lhsArea = $0.rect.width * $0.rect.height
            let rhsArea = $1.rect.width * $1.rect.height
            return lhsArea == rhsArea ? $0.index < $1.index : lhsArea < rhsArea
        }
    }

    /// The model-facing text the marks turn into ("[7] Button “Send” @ (x,y)"), so a text/vision
    /// brain can reference marks by number.
    static func prompt(_ marks: [SoMMark]) -> String {
        marks.map { m in
            let kind = m.role.hasPrefix("AX") ? String(m.role.dropFirst(2)) : m.role
            let label = m.label.isEmpty ? "" : " “\(m.label)”"
            return "[\(m.index)] \(kind)\(label) @ (\(Int(m.center.x)),\(Int(m.center.y)))"
        }.joined(separator: "\n")
    }

    /// Keep a capture within the app's owned observation budget while preserving aspect ratio.
    static func clampedSize(width: Int, height: Int, maxDimension: Int = 1440) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard maxDimension > 0, longest > maxDimension, longest > 0 else { return (width, height) }
        let scale = Double(maxDimension) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
}

// MARK: - AX geometry for the marks (needs the Accessibility grant)

enum SoMGeometry {
    /// Collect interactive candidates (role, label, global rect) from the frontmost app's focused
    /// window. Returns [] with an honest reason when Accessibility isn't granted.
    static func candidates(maxDepth: Int = 9, maxNodes: Int = 360) -> (marks: [SetOfMarks.Candidate], granted: Bool) {
        #if canImport(ApplicationServices) && canImport(AppKit)
        guard AXIsProcessTrusted() else { return ([], false) }
        guard let front = NSWorkspace.shared.frontmostApplication else { return ([], true) }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        let root: AXUIElement = copyElement(app, kAXFocusedWindowAttribute) ?? app
        if SecretRedactor.isCredentialSurface(app: front.localizedName ?? "",
                                               windowTitle: str(root, kAXTitleAttribute), text: "") {
            return ([], true)
        }
        var out: [SetOfMarks.Candidate] = []
        walk(root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, into: &out)
        return (out, true)
        #else
        return ([], false)
        #endif
    }

    #if canImport(ApplicationServices)
    private static func walk(_ el: AXUIElement, depth: Int, maxDepth: Int, maxNodes: Int,
                             into out: inout [SetOfMarks.Candidate]) {
        guard depth <= maxDepth, out.count < maxNodes else { return }
        let role = str(el, kAXRoleAttribute)
        if SetOfMarks.interactiveRoles.contains(role), let rect = frame(el) {
            // Never put AXValue into a model-facing mark: for text fields that value may be a secret.
            let raw = firstNonEmpty(str(el, kAXTitleAttribute), str(el, kAXDescriptionAttribute),
                                    str(el, kAXPlaceholderValueAttribute),
                                    str(el, kAXRoleDescriptionAttribute))
            let label = SecretRedactor.redact(raw).text
            out.append(SetOfMarks.Candidate(role: role, label: label, rect: rect))
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            if out.count >= maxNodes { break }
            walk(child, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes, into: &out)
        }
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private static func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let r = ref else { return nil }
        return (r as! AXUIElement)
    }
    private static func str(_ el: AXUIElement, _ attr: String) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return "" }
        if let s = ref as? String { return s }
        if let n = ref as? NSNumber { return n.stringValue }
        return ""
    }
    #endif
    private static func firstNonEmpty(_ ss: String...) -> String {
        for s in ss { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { return t } }
        return ""
    }

    static func frontmostApp() -> (name: String, bundleID: String) {
        #if canImport(AppKit)
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName ?? "", app?.bundleIdentifier ?? "")
        #else
        return ("", "")
        #endif
    }

    static var isCredentialSurface: Bool {
        #if canImport(ApplicationServices) && canImport(AppKit)
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        var windowTitle = ""
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            let root: AXUIElement = copyElement(app, kAXFocusedWindowAttribute) ?? app
            windowTitle = str(root, kAXTitleAttribute)
        }
        return SecretRedactor.isCredentialSurface(app: front.localizedName ?? "",
                                                   windowTitle: windowTitle, text: "")
        #else
        return false
        #endif
    }
}

// MARK: - The capture engine

/// A single screen capture plus its set-of-marks index.
struct SoMCapture {
    var image: CGImage?
    var marks: [SoMMark]
    var screenGranted: Bool
    var axGranted: Bool
    var reason: String
    var appName: String = ""
    var appBundleID: String = ""
}

enum ScreenCapture {
    private static let log = Logger(subsystem: "com.blacklabel.sovereign", category: "screencapture")

    /// True when the buyer has granted Screen Recording to this (signed) process.
    static var screenGranted: Bool {
        #if os(macOS) && canImport(CoreGraphics)
        return CGPreflightScreenCaptureAccess()
        #else
        return false
        #endif
    }

    /// Capture the main display as a set-of-marks frame. Honest: nil image + logged denial when
    /// Screen Recording isn't granted; zero marks + reason when Accessibility isn't granted.
    static func captureSetOfMarks(maxDimension: Int = 1440) async -> SoMCapture {
        let (cands, axGranted) = SoMGeometry.candidates()
        let marks = SetOfMarks.build(from: cands)
        let app = SoMGeometry.frontmostApp()

        guard !SoMGeometry.isCredentialSurface else {
            let reason = "Credential surfaces are not captured or indexed."
            log.notice("set-of-marks capture refused — \(reason, privacy: .public)")
            return SoMCapture(image: nil, marks: [], screenGranted: screenGranted,
                              axGranted: axGranted, reason: reason,
                              appName: app.name, appBundleID: app.bundleID)
        }

        guard screenGranted else {
            let reason = "Screen Recording not granted — capture inert. Grant Sovereign in System Settings ▸ Privacy & Security ▸ Screen Recording."
            log.notice("set-of-marks capture refused — \(reason, privacy: .public)")
            return SoMCapture(image: nil, marks: marks, screenGranted: false, axGranted: axGranted,
                              reason: reason, appName: app.name, appBundleID: app.bundleID)
        }

        let image = await captureImage(maxDimension: maxDimension)
        let reason = image == nil ? "Screen Recording granted but the frame capture returned no image."
                                  : (axGranted ? "OK" : "Frame captured; 0 marks (Accessibility not granted for element geometry).")
        return SoMCapture(image: image, marks: marks, screenGranted: true, axGranted: axGranted,
                          reason: reason, appName: app.name, appBundleID: app.bundleID)
    }

    /// The real frame grab: ScreenCaptureKit on macOS 14+, CGWindowList fallback on 13.
    static func captureImage(maxDimension: Int = 1440) async -> CGImage? {
        #if canImport(ScreenCaptureKit)
        if #available(macOS 14.0, *) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { return cgFallback(maxDimension: maxDimension) }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                let clamped = SetOfMarks.clampedSize(width: display.width, height: display.height, maxDimension: maxDimension)
                cfg.width = clamped.width
                cfg.height = clamped.height
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            } catch {
                log.error("SCScreenshotManager failed: \(error.localizedDescription, privacy: .public)")
                return cgFallback(maxDimension: maxDimension)
            }
        }
        #endif
        return cgFallback(maxDimension: maxDimension)
    }

    /// Pre-macOS-14 fallback. ScreenCaptureKit's one-shot screenshot API is macOS 14+, and the old
    /// CGWindowListCreateImage path is removed from the current SDK, so on macOS 13 we return an
    /// HONEST nil (logged) rather than pretend — the set-of-marks geometry still works, the frame
    /// image is simply unavailable on that OS.
    private static func cgFallback(maxDimension: Int) -> CGImage? {
        log.notice("Screen frame capture needs macOS 14+ (ScreenCaptureKit one-shot); returning no image on this OS.")
        return nil
    }
}
