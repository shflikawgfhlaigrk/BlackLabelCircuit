#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  WindowTiler.swift
//  leanring-buddy
//
//  Arranges application windows on the RIGHT display into an equal 2×2 grid, and
//  provides the shared "which app windows are on the right display" inventory that
//  BOTH the tiling route (Feature A) and the "explain the apps on my right screen"
//  route (Feature B) read from live Accessibility data — never a screenshot guess.
//
//  The right display is the NSScreen with the greatest frame.origin.x — the same
//  rule the bundled `window-move` tool uses for "right" (on this rig the built-in
//  is at x = -1728 and the ultrawide is the main display at x = 0, so the greatest
//  origin.x is the ultrawide). Window geometry is read and written through the
//  Accessibility API, modeled on WindowPositionManager.shrinkOverlappingFocusedWindow
//  and the verified AX↔AppKit Y-flip in CompanionManager.pointAtRunningApp:
//  appKitY = primaryDisplayHeight − coreGraphicsY.
//

import Foundation
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(ApplicationServices) && !CIRCUIT_WINDOWS_SIM
import ApplicationServices
#endif

@MainActor
enum WindowTiler {
    static func placementScreen(named query: String) -> NSScreen? {
        let screens = NSScreen.screens
        let name = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["main", "primary"].contains(name) {
            return screens.first { $0.frame.origin == .zero }
        }
        if ["left", "right"].contains(name) {
            let edge = name == "left" ? screens.map(\.frame.midX).min() : screens.map(\.frame.midX).max()
            let matches = screens.filter { $0.frame.midX == edge }
            return matches.count == 1 ? matches[0] : nil
        }
        if ["built in", "built-in", "macbook", "laptop"].contains(name) {
            return screens.first {
                guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayIsBuiltin(id.uint32Value) != 0
            }
        }
        let matches = screens.filter { NativeAppSwitchIntentPolicy.displayName($0.localizedName, matches: query) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Opens no additional window: move the exact focused standard window and
    /// read the same AX handle back before publishing a successful placement.
    static func placeFrontmostWindow(
        on screen: NSScreen,
        expectedApplication: String,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> CGRect? {
        let displayFrame = screen.frame
        let visible = screen.visibleFrame
        let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        func displayIsCurrent() -> Bool {
            guard let displayNumber else { return false }
            return NSScreen.screens.contains {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == displayNumber
                    && $0.frame == displayFrame && $0.visibleFrame == visible
            }
        }
        guard isCurrent(), let application = NSWorkspace.shared.frontmostApplication,
              application.localizedName == expectedApplication,
              WindowPositionManager.hasAccessibilityPermission() else { return nil }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.25)
        guard isStandardNonMinimizedWindow(window),
              copyBoolAttribute(window, "AXFullScreen") != true,
              let original = readWindowGeometry(of: window) else { return nil }
        let size = CGSize(width: min(original.size.width, visible.width),
                          height: min(original.size.height, visible.height))
        guard size.width > 0, size.height > 0 else { return nil }
        let destination = CGRect(x: visible.midX - size.width / 2,
                                 y: visible.midY - size.height / 2,
                                 width: size.width, height: size.height)
        let primaryHeight = primaryDisplayHeightInPoints()
        let position = coreGraphicsTopLeft(ofAppKitRect: destination, primaryDisplayHeightInPoints: primaryHeight)
        let moved = StealthEntryLatch.shared.performUnlessRaised {
            guard isCurrent(), !StealthVisibilityGate.shared.isActive,
                  displayIsCurrent(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return false }
            applyWindowFrame(to: window, positionTopLeftInCoreGraphics: position, sizeInPoints: size)
            return true
        } ?? false
        guard moved else { return nil }
        for _ in 0..<12 {
            guard !Task.isCancelled, isCurrent(),
                  displayIsCurrent(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return nil }
            if let current = readWindowGeometry(of: window) {
                let frame = CGRect(x: current.positionTopLeft.x,
                    y: primaryHeight - current.positionTopLeft.y - current.size.height,
                    width: current.size.width, height: current.size.height)
                if abs(frame.minX - destination.minX) <= 3,
                   abs(frame.minY - destination.minY) <= 3,
                   abs(frame.width - destination.width) <= 3,
                   abs(frame.height - destination.height) <= 3,
                   visible.insetBy(dx: -3, dy: -3).contains(frame) { return frame }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }


    /// One application window that currently sits on the right display, with the
    /// Accessibility handle and geometry needed to move/resize it plus the
    /// human-facing names the explain route speaks.
    struct RightDisplayApplicationWindow {
        let owningApplicationName: String
        let windowTitle: String?
        let accessibilityWindowElement: AXUIElement
        let windowPositionTopLeftInCoreGraphicsCoordinates: CGPoint
        let windowSizeInPoints: CGSize
        var windowAreaInSquarePoints: CGFloat { windowSizeInPoints.width * windowSizeInPoints.height }
    }

    /// One window that the tiler placed into a quadrant, carrying everything the
    /// caller needs to prove the move landed: the AX handle to re-read, the
    /// quadrant it was asked to fill (AppKit coords), and that quadrant already
    /// converted to the top-left CoreGraphics position/size the AX API was set to.
    struct ArrangedWindow {
        let applicationName: String
        let accessibilityWindowElement: AXUIElement
        let expectedQuadrantInAppKitCoordinates: CGRect
        let expectedPositionTopLeftInCoreGraphicsCoordinates: CGPoint
        let expectedSizeInPoints: CGSize
    }

    /// The outcome of a tiling pass, so the caller can speak an honest confirmation
    /// and write a receipt that includes the real right-display visibleFrame and
    /// the per-window landed-vs-expected geometry.
    struct TilingOutcome {
        let rightDisplayVisibleFrameInAppKitCoordinates: CGRect
        let arrangedWindows: [ArrangedWindow]
    }

    // MARK: - Right display resolution

    /// The right-most display: the NSScreen whose frame origin has the greatest x.
    /// Nil only when there are no screens at all.
    static func rightDisplayScreen() -> NSScreen? {
        NSScreen.screens.max(by: { leftScreen, rightScreen in
            leftScreen.frame.origin.x < rightScreen.frame.origin.x
        })
    }

    // MARK: - Shared inventory (used by BOTH the tile route and the explain route)

    /// Every standard application window whose CENTER lies on the right display,
    /// read from live Accessibility data. Excludes Ace itself, non-regular
    /// (menu-bar-only / accessory) apps, the Finder desktop and other non-standard
    /// windows, and minimized or zero-size windows. Returns nil when Accessibility
    /// permission is missing or there is no display to inspect.
    static func rightDisplayInventory() -> (rightDisplayScreen: NSScreen, windowsOnRightDisplay: [RightDisplayApplicationWindow])? {
        guard WindowPositionManager.hasAccessibilityPermission() else { return nil }
        guard let rightDisplayScreen = rightDisplayScreen() else { return nil }

        let primaryDisplayHeight = primaryDisplayHeightInPoints()
        let aceProcessIdentifier = ProcessInfo.processInfo.processIdentifier

        let regularApplicationsExcludingAce = NSWorkspace.shared.runningApplications.filter { application in
            application.activationPolicy == .regular
                && application.processIdentifier != aceProcessIdentifier
        }

        var windowsOnRightDisplay: [RightDisplayApplicationWindow] = []
        for runningApplication in regularApplicationsExcludingAce {
            let owningApplicationName = runningApplication.localizedName ?? "an app"
            let applicationAccessibilityElement = AXUIElementCreateApplication(runningApplication.processIdentifier)

            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                applicationAccessibilityElement, kAXWindowsAttribute as CFString, &windowsValue
            ) == .success, let applicationWindows = windowsValue as? [AXUIElement] else { continue }

            for windowElement in applicationWindows {
                guard isStandardNonMinimizedWindow(windowElement) else { continue }
                guard let windowGeometry = readWindowGeometry(of: windowElement),
                      windowGeometry.size.width > 1, windowGeometry.size.height > 1 else { continue }

                // AX gives a top-left position in global CoreGraphics coords; flip
                // the window CENTER into AppKit coords to test which NSScreen owns it.
                let windowCenterInCoreGraphics = CGPoint(
                    x: windowGeometry.positionTopLeft.x + windowGeometry.size.width / 2.0,
                    y: windowGeometry.positionTopLeft.y + windowGeometry.size.height / 2.0
                )
                let windowCenterInAppKit = CGPoint(
                    x: windowCenterInCoreGraphics.x,
                    y: primaryDisplayHeight - windowCenterInCoreGraphics.y
                )
                guard rightDisplayScreen.frame.contains(windowCenterInAppKit) else { continue }

                let windowTitle = copyStringAttribute(windowElement, kAXTitleAttribute as String)
                windowsOnRightDisplay.append(
                    RightDisplayApplicationWindow(
                        owningApplicationName: owningApplicationName,
                        windowTitle: (windowTitle?.isEmpty == false) ? windowTitle : nil,
                        accessibilityWindowElement: windowElement,
                        windowPositionTopLeftInCoreGraphicsCoordinates: windowGeometry.positionTopLeft,
                        windowSizeInPoints: windowGeometry.size
                    )
                )
            }
        }
        return (rightDisplayScreen, windowsOnRightDisplay)
    }

    /// Distinct application names with a window on the right display, largest
    /// window first, for the spoken explanation (Feature B). Empty when nothing
    /// qualifies or Accessibility permission is missing.
    static func rightDisplayApplicationNames() -> [String] {
        guard let inventory = rightDisplayInventory() else { return [] }
        var seenApplicationNames = Set<String>()
        var orderedApplicationNames: [String] = []
        let windowsLargestFirst = inventory.windowsOnRightDisplay
            .sorted(by: { $0.windowAreaInSquarePoints > $1.windowAreaInSquarePoints })
        for window in windowsLargestFirst where seenApplicationNames.insert(window.owningApplicationName).inserted {
            orderedApplicationNames.append(window.owningApplicationName)
        }
        return orderedApplicationNames
    }

    /// True for the founder's PRODUCT apps — the windows "the four apps on my
    /// right screen" actually means (Marketing, Academy, Sovereign, Real Estate,
    /// Trading, …). The v1 largest-window heuristic tiled Chrome/Claude/HQ and
    /// buried these (observed 2026-07-17 22:21Z), so product windows now take the
    /// quadrants whenever they're present. Name-prefix match keeps the rule
    /// durable as products are added; the Assistant (Ace itself) and the HQ
    /// dashboard are deliberately not products.
    static func isPreferredProductApplication(named applicationName: String) -> Bool {
        applicationName.hasPrefix("Black Label ")
            && applicationName != "Black Label Assistant"
            && applicationName != "Black Label HQ"
    }

    /// The largest window per distinct application — tiling and explaining think
    /// in APPS the way the founder does, so two Chrome windows can never take
    /// two quadrants while a product app gets none.
    static func largestWindowPerApplication(
        in windowsOnRightDisplay: [RightDisplayApplicationWindow]
    ) -> [RightDisplayApplicationWindow] {
        var largestWindowByApplicationName: [String: RightDisplayApplicationWindow] = [:]
        for window in windowsOnRightDisplay {
            if let existingLargest = largestWindowByApplicationName[window.owningApplicationName],
               existingLargest.windowAreaInSquarePoints >= window.windowAreaInSquarePoints {
                continue
            }
            largestWindowByApplicationName[window.owningApplicationName] = window
        }
        return Array(largestWindowByApplicationName.values)
    }

    /// A window's CENTER in AppKit (bottom-left origin) coordinates — used for
    /// screen ownership tests, nearest-quadrant assignment, and the explain
    /// route's gem flight target.
    static func appKitCenter(
        of window: RightDisplayApplicationWindow, primaryDisplayHeightInPoints: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: window.windowPositionTopLeftInCoreGraphicsCoordinates.x + window.windowSizeInPoints.width / 2.0,
            y: primaryDisplayHeightInPoints
                - (window.windowPositionTopLeftInCoreGraphicsCoordinates.y + window.windowSizeInPoints.height / 2.0)
        )
    }

    // MARK: - Feature A: symmetrical 2×2 tiling of the right display

    /// Arranges up to four windows on the right display into an equal 2×2 grid
    /// filling the display's visibleFrame. More than four qualifying windows → the
    /// four largest by area are placed; fewer → the N present fill the first N
    /// row-major slots, each still an equal quadrant. Returns nil when there is no
    /// right display / no Accessibility permission; a TilingOutcome with zero
    /// arranged windows when the right display has no tileable windows.
    static func tileRightDisplayIntoTwoByTwoGrid() -> TilingOutcome? {
        guard let inventory = rightDisplayInventory() else { return nil }

        let rightDisplayVisibleFrame = inventory.rightDisplayScreen.visibleFrame

        // Selection: one (largest) window per app, PRODUCT apps first. When at
        // least two product apps have windows here, they own the grid outright —
        // Chrome/Claude/HQ never steal a quadrant from them. Only when products
        // are absent does the largest-window fallback pick the four.
        let largestWindowPerApp = largestWindowPerApplication(in: inventory.windowsOnRightDisplay)
        let productApplicationWindows = largestWindowPerApp
            .filter { isPreferredProductApplication(named: $0.owningApplicationName) }
        let selectionPool = productApplicationWindows.count >= 2
            ? productApplicationWindows
            : largestWindowPerApp
        let windowsToArrange = Array(
            selectionPool
                .sorted(by: { $0.windowAreaInSquarePoints > $1.windowAreaInSquarePoints })
                .prefix(4)
        )
        guard !windowsToArrange.isEmpty else {
            return TilingOutcome(
                rightDisplayVisibleFrameInAppKitCoordinates: rightDisplayVisibleFrame,
                arrangedWindows: []
            )
        }

        let quadrantsRowMajor = twoByTwoQuadrantsInAppKitCoordinates(filling: rightDisplayVisibleFrame)
        let primaryDisplayHeight = primaryDisplayHeightInPoints()

        // Assignment: each window goes to its NEAREST free quadrant (by current
        // center), greedily in ascending-distance order. "Make them symmetrical"
        // means equalize sizes where the windows already live — Marketing stays
        // top-left — never reshuffle a rough grid into a new order.
        var distanceOrderedPairs: [(distanceSquared: CGFloat, windowIndex: Int, quadrantIndex: Int)] = []
        for (windowIndex, window) in windowsToArrange.enumerated() {
            let windowCenterInAppKit = appKitCenter(of: window, primaryDisplayHeightInPoints: primaryDisplayHeight)
            for (quadrantIndex, quadrant) in quadrantsRowMajor.enumerated() {
                let deltaX = windowCenterInAppKit.x - quadrant.midX
                let deltaY = windowCenterInAppKit.y - quadrant.midY
                distanceOrderedPairs.append((deltaX * deltaX + deltaY * deltaY, windowIndex, quadrantIndex))
            }
        }
        var quadrantIndexByWindowIndex: [Int: Int] = [:]
        var takenQuadrantIndexes = Set<Int>()
        for pair in distanceOrderedPairs.sorted(by: { $0.distanceSquared < $1.distanceSquared }) {
            guard quadrantIndexByWindowIndex[pair.windowIndex] == nil,
                  !takenQuadrantIndexes.contains(pair.quadrantIndex) else { continue }
            quadrantIndexByWindowIndex[pair.windowIndex] = pair.quadrantIndex
            takenQuadrantIndexes.insert(pair.quadrantIndex)
        }

        var arrangedWindows: [ArrangedWindow] = []
        for (windowSlotIndex, window) in windowsToArrange.enumerated() {
            let quadrantInAppKit = quadrantsRowMajor[quadrantIndexByWindowIndex[windowSlotIndex] ?? windowSlotIndex]
            let targetPositionTopLeft = coreGraphicsTopLeft(
                ofAppKitRect: quadrantInAppKit, primaryDisplayHeightInPoints: primaryDisplayHeight)
            let targetSize = quadrantInAppKit.size
            applyWindowFrame(
                to: window.accessibilityWindowElement,
                positionTopLeftInCoreGraphics: targetPositionTopLeft,
                sizeInPoints: targetSize
            )
            arrangedWindows.append(
                ArrangedWindow(
                    applicationName: window.owningApplicationName,
                    accessibilityWindowElement: window.accessibilityWindowElement,
                    expectedQuadrantInAppKitCoordinates: quadrantInAppKit,
                    expectedPositionTopLeftInCoreGraphicsCoordinates: targetPositionTopLeft,
                    expectedSizeInPoints: targetSize
                )
            )
        }
        return TilingOutcome(
            rightDisplayVisibleFrameInAppKitCoordinates: rightDisplayVisibleFrame,
            arrangedWindows: arrangedWindows
        )
    }

    /// The four equal quadrants of `visibleFrame`, in AppKit (bottom-left origin)
    /// coordinates, returned ROW-MAJOR: top-left, top-right, bottom-left,
    /// bottom-right. "Top" is the higher-y half in AppKit.
    static func twoByTwoQuadrantsInAppKitCoordinates(filling visibleFrame: CGRect) -> [CGRect] {
        let halfWidth = visibleFrame.width / 2.0
        let halfHeight = visibleFrame.height / 2.0
        let leftColumnX = visibleFrame.minX
        let rightColumnX = visibleFrame.minX + halfWidth
        let bottomRowY = visibleFrame.minY
        let topRowY = visibleFrame.minY + halfHeight
        return [
            CGRect(x: leftColumnX, y: topRowY, width: halfWidth, height: halfHeight),     // slot 0 — top-left
            CGRect(x: rightColumnX, y: topRowY, width: halfWidth, height: halfHeight),    // slot 1 — top-right
            CGRect(x: leftColumnX, y: bottomRowY, width: halfWidth, height: halfHeight),  // slot 2 — bottom-left
            CGRect(x: rightColumnX, y: bottomRowY, width: halfWidth, height: halfHeight), // slot 3 — bottom-right
        ]
    }

    // MARK: - Accessibility geometry helpers

    /// The height of the primary display (the NSScreen anchored at origin .zero).
    /// Global CoreGraphics/AX coordinates (top-left origin, y down) and AppKit
    /// coordinates (bottom-left origin, y up) differ only by this flip:
    /// appKitY = primaryDisplayHeight − coreGraphicsY.
    static func primaryDisplayHeightInPoints() -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
    }

    /// Converts an AppKit rect (bottom-left origin) to the top-left position the
    /// AX API expects (global CoreGraphics coords). The rect's AppKit top edge
    /// (maxY) becomes the CoreGraphics top: coreGraphicsY = primaryHeight − maxY.
    static func coreGraphicsTopLeft(ofAppKitRect appKitRect: CGRect, primaryDisplayHeightInPoints: CGFloat) -> CGPoint {
        CGPoint(x: appKitRect.minX, y: primaryDisplayHeightInPoints - appKitRect.maxY)
    }

    /// Re-reads a window's current top-left position (global CoreGraphics coords)
    /// and size — used to PROVE a tiling move actually landed, rather than trust
    /// that the AX set "ran".
    static func currentGeometry(of windowElement: AXUIElement) -> (positionTopLeftInCoreGraphics: CGPoint, sizeInPoints: CGSize)? {
        guard let windowGeometry = readWindowGeometry(of: windowElement) else { return nil }
        return (windowGeometry.positionTopLeft, windowGeometry.size)
    }

    /// True only for a normal, on-screen application window: subrole
    /// AXStandardWindow (which excludes the Finder desktop, panels, sheets, and
    /// popovers) and not minimized.
    private static func isStandardNonMinimizedWindow(_ windowElement: AXUIElement) -> Bool {
        guard let subrole = copyStringAttribute(windowElement, kAXSubroleAttribute as String),
              subrole == (kAXStandardWindowSubrole as String) else { return false }
        if let isMinimized = copyBoolAttribute(windowElement, kAXMinimizedAttribute as String), isMinimized {
            return false
        }
        return true
    }

    /// Reads a window's top-left position (global CoreGraphics coords) and size.
    private static func readWindowGeometry(of windowElement: AXUIElement) -> (positionTopLeft: CGPoint, size: CGSize)? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else {
            return nil
        }
        var positionTopLeft = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &positionTopLeft),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return (positionTopLeft, size)
    }

    /// Moves and resizes a window to the given top-left CoreGraphics position and
    /// size. Position is set, then size, then position again — some apps clamp the
    /// first position against their OLD size, so the second pass lands the corner
    /// once the new size is in effect.
    private static func applyWindowFrame(
        to windowElement: AXUIElement,
        positionTopLeftInCoreGraphics: CGPoint,
        sizeInPoints: CGSize
    ) {
        var targetPosition = positionTopLeftInCoreGraphics
        var targetSize = sizeInPoints
        if let positionValue = AXValueCreate(.cgPoint, &targetPosition) {
            AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, positionValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &targetSize) {
            AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)
        }
        if let positionValue = AXValueCreate(.cgPoint, &targetPosition) {
            AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, positionValue)
        }
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copyBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return value as? Bool
    }
}
#endif // circuit-convert
