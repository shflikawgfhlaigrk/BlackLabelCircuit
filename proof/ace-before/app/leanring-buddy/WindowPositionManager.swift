#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  WindowPositionManager.swift
//  leanring-buddy
//
//  Manages positioning the app window on the right edge of the screen
//  and shrinking overlapping windows from other apps via the Accessibility API.
//

import Foundation
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(ApplicationServices) && !CIRCUIT_WINDOWS_SIM
import ApplicationServices
#endif
#if canImport(ScreenCaptureKit) && !CIRCUIT_WINDOWS_SIM
import ScreenCaptureKit
#endif

/// One total-order boundary for the bounded AppKit, Workspace, and AX commits
/// in the setup panel. The event-tap entry latch and each effect share this
/// lock: entry first means the effect never reaches macOS; an already-admitted
/// effect finishes its one synchronous commit before entry raises the wall.
nonisolated enum StealthVisibleEffectAdmission {
    static func commit(
        visibilityIsBlocked: @escaping () -> Bool,
        performUnlessRaised: (_ body: () -> Bool) -> Bool?,
        // Not escaping: `effect` is called only inside the closure handed to
        // `performUnlessRaised`, which is itself non-escaping. Declaring it
        // @escaping was over-strict and broke every wrapper that forwards its
        // own non-escaping parameter through here.
        effect: () -> Bool
    ) -> Bool {
        guard !visibilityIsBlocked() else { return false }
        // The revalidating closure cannot capture a non-escaping parameter, but
        // it also never outlives this call: `performUnlessRaised` runs it
        // synchronously under the latch and returns. `withoutActuallyEscaping`
        // states exactly that, instead of forcing every caller to promise an
        // escape that never happens.
        return withoutActuallyEscaping(effect) { escapableEffect in
            performUnlessRaised {
                guard !visibilityIsBlocked() else { return false }
                return escapableEffect()
            } == true
        }
    }
}

@MainActor
class WindowPositionManager {
    static let accessibilityPermissionRepairCoordinator =
        PermissionRepairCoordinator()
    static let screenRecordingPermissionRepairCoordinator =
        PermissionRepairCoordinator()
    private static let promptAttemptStore =
        UserDefaultsPermissionPromptAttemptStore()

    // Attempted-prompt state must survive relaunches: macOS shows the TCC
    // consent dialog at most ONCE per app ever, so after a denial a fresh
    // launch's in-memory-only flag re-armed the "system prompt" branch, and
    // the first Grant click of every launch was an invisible no-op (Build 61).
    // Persisting the attempt routes previously-denied users straight to
    // System Settings, which always works.
    private static var hasEverAttemptedAccessibilitySystemPrompt: Bool {
        promptAttemptStore.hasAttempted(.accessibility)
    }
    private static var hasEverAttemptedScreenRecordingSystemPrompt: Bool {
        promptAttemptStore.hasAttempted(.screenRecording)
    }
    private static let hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey = "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"

    /// Returns true when the Mac currently has more than one connected display.
    /// Uses AppKit's screen list, which is available without ScreenCaptureKit's
    /// shareable-content permission prompt.
    static func currentMacHasMultipleDisplays() -> Bool {
        NSScreen.screens.count > 1
    }

    // MARK: - Accessibility Permission

    /// Returns true if the app has Accessibility permission.
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func beginAccessibilityPermissionRepair() -> Bool {
        let destination = permissionRequestPresentationDestination(
            hasPermissionNow: hasAccessibilityPermission(),
            hasAttemptedSystemPrompt:
                hasEverAttemptedAccessibilitySystemPrompt
        )
        if destination == .systemPrompt {
            return accessibilityPermissionRepairCoordinator
                .startPromptResolution(
                    permission: .accessibility,
                    requestPrompt: {
                        PermissionPromptAdmission.invoke(
                            store: promptAttemptStore,
                            permission: .accessibility,
                            commit: commitVisibleEffect,
                            prompt: {
                            let options =
                                ["AXTrustedCheckOptionPrompt": true]
                                    as CFDictionary
                            _ = AXIsProcessTrustedWithOptions(options)
                            }
                        )
                    },
                    readback: { hasAccessibilityPermission() }
                )
        }
        return accessibilityPermissionRepairCoordinator.start {
            if destination == .alreadyGranted,
               hasAccessibilityPermission() {
                return .succeeded(
                    .permissionReadback(permission: .accessibility)
                )
            }
            return await openSettingsAndWaitForReadback(
                .accessibility,
                permission: .accessibility,
                readback: { hasAccessibilityPermission() }
            )
        }
    }

    /// Opens System Settings to the Accessibility pane.
    static func openAccessibilitySettings() {
        let url = PermissionSystemSettingsPane.accessibility.deepLink
        _ = commitVisibleEffect {
            return NSWorkspace.shared.open(url)
        }
    }

    /// Reveals the running app bundle in Finder so the user can drag it into
    /// the Accessibility list if it doesn't appear automatically.
    static func revealAppInFinderForRepair() async
        -> PermissionRepairResult {
        guard let appURL = Bundle.main.bundleURL as URL? else {
            return .failed(
                PermissionRepairFailure(
                    code: "finder.bundle_url_missing",
                    message: "Ace could not resolve its running app bundle for Finder."
                )
            )
        }
        let didReveal = commitVisibleEffect {
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
            return true
        }
        guard didReveal else {
            return .failed(
                PermissionRepairFailure(
                    code: "finder.reveal_not_admitted",
                    message: "Ace did not admit the Finder selection while Private Mode was active."
                )
            )
        }
        for _ in 0..<30 {
            if NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.finder"
            ).contains(where: { $0.isActive }) {
                // Finder came forward for the selection we requested. This used
                // to return .failed because macOS exposes no prompt-free receipt
                // for WHICH row is highlighted — so every working press of
                // "Find App" reported failure, and the function had no
                // .succeeded path at all: all four exits were failures.
                //
                // Refusing to claim more than was observed is right; calling an
                // observed success a failure is not. The proof says exactly what
                // was verified — Finder was activated for this bundle — and
                // claims nothing about the selected row.
                return .succeeded(
                    .verifiedOperation("finder_activated_for_app_selection")
                )
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .failed(
            PermissionRepairFailure(
                code: "finder.application_not_observed",
                message: "Finder did not become observable after Ace requested the app selection."
            )
        )
    }

    // MARK: - Screen Recording Permission

    /// Returns true if Screen Recording permission is granted.
    static func hasScreenRecordingPermission() -> Bool {
        let hasScreenRecordingPermissionNow = CGPreflightScreenCaptureAccess()
        if hasScreenRecordingPermissionNow {
            _ = commitVisibleEffect {
                UserDefaults.standard.set(
                    true,
                    forKey:
                        hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey
                )
                return true
            }
        }
        return hasScreenRecordingPermissionNow
    }

    /// Returns true when the app should proceed with session launch without showing
    /// the permission gate again. This intentionally falls back to the last known
    /// granted state because CGPreflightScreenCaptureAccess() can sometimes return a
    /// false negative even though the user has already approved the app.
    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch() -> Bool {
        shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: hasScreenRecordingPermission(),
            hasPreviouslyConfirmedScreenRecordingPermission: UserDefaults.standard.bool(forKey: hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey)
        )
    }

    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
        hasScreenRecordingPermissionNow: Bool,
        hasPreviouslyConfirmedScreenRecordingPermission: Bool
    ) -> Bool {
        hasScreenRecordingPermissionNow || hasPreviouslyConfirmedScreenRecordingPermission
    }

    static func clearPreviouslyConfirmedScreenRecordingPermission() {
        _ = commitVisibleEffect {
            UserDefaults.standard.removeObject(
                forKey:
                    hasPreviouslyConfirmedScreenRecordingPermissionUserDefaultsKey
            )
            return true
        }
    }

    @discardableResult
    static func beginScreenRecordingPermissionRepair() -> Bool {
        let destination = permissionRequestPresentationDestination(
            hasPermissionNow: hasScreenRecordingPermission(),
            hasAttemptedSystemPrompt:
                hasEverAttemptedScreenRecordingSystemPrompt
        )
        if destination == .systemPrompt {
            return screenRecordingPermissionRepairCoordinator
                .startPromptResolution(
                    permission: .screenRecording,
                    requestPrompt: {
                        PermissionPromptAdmission.invoke(
                            store: promptAttemptStore,
                            permission: .screenRecording,
                            commit: commitVisibleEffect,
                            prompt: { _ = CGRequestScreenCaptureAccess() }
                        )
                    },
                    readback: { hasScreenRecordingPermission() }
                )
        }
        return screenRecordingPermissionRepairCoordinator.start {
            if destination == .alreadyGranted,
               hasScreenRecordingPermission() {
                return .succeeded(
                    .permissionReadback(permission: .screenRecording)
                )
            }
            return await openSettingsAndWaitForReadback(
                .screenRecording,
                permission: .screenRecording,
                readback: { hasScreenRecordingPermission() }
            )
        }
    }

    /// Opens System Settings to the Screen Recording pane.
    static func openScreenRecordingSettings() {
        let url = PermissionSystemSettingsPane.screenRecording.deepLink
        _ = commitVisibleEffect {
            return NSWorkspace.shared.open(url)
        }
    }

    static func permissionRequestPresentationDestination(
        hasPermissionNow: Bool,
        hasAttemptedSystemPrompt: Bool
    ) -> PermissionRequestPresentationDestination {
        PermissionPromptFallbackPolicy.destination(
            hasPermissionNow: hasPermissionNow,
            hasAttemptedSystemPrompt: hasAttemptedSystemPrompt,
            settingsPane: .accessibility
        )
    }

    static func openAndObserveSystemSettingsPane(
        _ settingsPane: PermissionSystemSettingsPane
    ) async -> PermissionRepairResult {
        let didOpen = commitVisibleEffect {
            return NSWorkspace.shared.open(settingsPane.deepLink)
        }
        guard didOpen else {
            return .failed(
                PermissionRepairFailure(
                    code: "settings.open_rejected",
                    message:
                        "macOS did not open the requested System Settings pane."
                )
            )
        }

        return await PermissionSettingsPaneObserver(
            maximumPollCount: 50,
            pollDelayNanoseconds: 100_000_000,
            snapshot: {
                systemSettingsSelectionSnapshot(for: settingsPane)
            },
            unavailableFailureCode: "settings.selection_unverifiable"
        ).observe(settingsPane)
    }

    /// Opens the exact pane, then keeps the accepted control running while the
    /// owner changes macOS state. Pane observation is navigation evidence only;
    /// green requires the supplied permission or functional readback.
    static func openSettingsAndWaitForReadback(
        _ settingsPane: PermissionSystemSettingsPane,
        permission: PermissionKind,
        maximumPollCount: Int = 600,
        readback: @MainActor @escaping () -> Bool
    ) async -> PermissionRepairResult {
        let navigation = await openAndObserveSystemSettingsPane(settingsPane)
        let readbackResult = await PermissionRepairReadbackObserver(
            maximumPollCount: maximumPollCount,
            pollDelayNanoseconds: 100_000_000,
            readback: { readback() }
        ).observe(
            permission: permission,
            timeoutMessage: "macOS did not confirm \(settingsPane.ownerFacingName) during this repair attempt. Finish the change and retry."
        )
        if case .succeeded = readbackResult { return readbackResult }
        if case let .failed(navigationFailure) = navigation,
           !navigationFailure.code.hasPrefix("settings.awaiting_owner") {
            return .failed(navigationFailure)
        }
        return readbackResult
    }

    private static func systemSettingsSelectionSnapshot(
        for pane: PermissionSystemSettingsPane
    ) -> PermissionSettingsPaneSnapshot? {
        let bundleIdentifier = "com.apple.systempreferences"
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first,
              application.isActive else { return nil }
        let target = NSAppleEventDescriptor(
            processIdentifier: application.processIdentifier
        )
        guard let address = target.aeDesc,
              AEDeterminePermissionToAutomateTarget(
                  address,
                  typeWildCard,
                  typeWildCard,
                  false
              ) == noErr else {
            // A deep link was dispatched, but without an independently readable
            // selection Ace must report unverified instead of claiming success.
            return PermissionSettingsPaneSnapshot(
                applicationBundleIdentifier: bundleIdentifier,
                selectedPaneIdentifier: nil
            )
        }
        let script = NSAppleScript(
            source:
                "tell application id \"\(bundleIdentifier)\"\n"
                + "set revealedAnchor to reveal anchor \"\(pane.stableSelectionIdentifier)\" of pane id \"\(pane.paneIdentifier)\"\n"
                + "return name of revealedAnchor\n"
                + "end tell"
        )
        var error: NSDictionary?
        let reply = script?.executeAndReturnError(&error)
        guard error == nil,
              reply?.stringValue == pane.stableSelectionIdentifier else {
            return PermissionSettingsPaneSnapshot(
                applicationBundleIdentifier: bundleIdentifier,
                selectedPaneIdentifier: nil
            )
        }
        return PermissionSettingsPaneSnapshot(
            applicationBundleIdentifier: bundleIdentifier,
            selectedPaneIdentifier: pane.stableSelectionIdentifier
        )
    }

    // MARK: - Window Positioning

    /// Positions the app's main window pinned to the right edge of the screen
    /// that contains the given display ID, vertically centered.
    static func pinMainWindowToRight(onDisplayID displayID: CGDirectDisplayID?) {
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }

        // Find the NSScreen matching the selected display, or fall back to the screen
        // the window is currently on, or finally the main screen.
        let targetScreen: NSScreen
        if let displayID,
           let matchingScreen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            targetScreen = matchingScreen
        } else if let currentScreen = mainWindow.screen {
            targetScreen = currentScreen
        } else if let mainScreen = NSScreen.main {
            targetScreen = mainScreen
        } else {
            return
        }

        let visibleFrame = targetScreen.visibleFrame
        let windowSize = mainWindow.frame.size

        let x = visibleFrame.maxX - windowSize.width
        let y = visibleFrame.minY + (visibleFrame.height - windowSize.height) / 2.0

        _ = commitVisibleEffect {
            mainWindow.setFrameOrigin(NSPoint(x: x, y: y))
            return true
        }
    }

    // MARK: - Shrink Overlapping Windows

    /// Checks if the frontmost (non-self) app's focused window overlaps our app window
    /// on the same monitor and, if so, shrinks it so it no longer overlaps.
    /// Only operates if both windows are on the same screen as `targetDisplayID`.
    static func shrinkOverlappingFocusedWindow(targetDisplayID: CGDirectDisplayID?) {
        guard hasAccessibilityPermission() else { return }
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        guard let mainScreen = mainWindow.screen else { return }

        // Only operate if the main window is on the target display
        if let targetDisplayID, mainScreen.displayID != targetDisplayID {
            return
        }

        // Get the frontmost application that isn't us
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Get the focused window of the front app
        var focusedWindowValue: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue)
        guard focusedResult == .success, let focusedWindow = focusedWindowValue else { return }

        // Get position and size of the focused window
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return
        }

        var otherPosition = CGPoint.zero
        var otherSize = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &otherPosition),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &otherSize) else {
            return
        }

        // The other window's frame in screen coordinates (top-left origin from AX API).
        // Convert to check if it's on the same screen as our window.
        let otherRight = otherPosition.x + otherSize.width
        let ourLeft = mainWindow.frame.origin.x

        // Check that the other window is on the same screen by verifying its origin
        // falls within the target screen's bounds.
        let screenFrame = mainScreen.frame
        let otherCenterX = otherPosition.x + otherSize.width / 2
        // AX uses top-left origin, NSScreen uses bottom-left. Convert AX Y to NSScreen Y.
        let otherNSScreenY = screenFrame.maxY - otherPosition.y - otherSize.height
        let otherCenterY = otherNSScreenY + otherSize.height / 2
        let otherCenter = NSPoint(x: otherCenterX, y: otherCenterY)

        guard screenFrame.contains(otherCenter) else { return }

        // If the other window's right edge extends past our window's left edge, shrink it.
        if otherRight > ourLeft {
            let newWidth = ourLeft - otherPosition.x
            guard newWidth > 200 else { return } // Don't shrink too small

            var newSize = CGSize(width: newWidth, height: otherSize.height)
            guard let newSizeValue = AXValueCreate(.cgSize, &newSize) else { return }
            _ = commitVisibleEffect {
                AXUIElementSetAttributeValue(
                    focusedWindow as! AXUIElement,
                    kAXSizeAttribute as CFString,
                    newSizeValue
                ) == .success
            }
        }
    }

    @discardableResult
    private static func commitVisibleEffect(
        _ effect: () -> Bool
    ) -> Bool {
        StealthVisibleEffectAdmission.commit(
            visibilityIsBlocked: {
                StealthVisibilityGate.shared.isActive
            },
            performUnlessRaised: { body in
                StealthEntryLatch.shared.performUnlessRaised(body)
            },
            effect: effect
        )
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    /// The CGDirectDisplayID for this screen.
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }
}
#endif // circuit-convert
