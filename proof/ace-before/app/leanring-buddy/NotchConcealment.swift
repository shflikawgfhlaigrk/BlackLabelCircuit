//
//  NotchConcealment.swift
//
//  The last silent first-run failure: on a notched MacBook with a crowded
//  menu bar, macOS pushes our status item under (or past) the camera housing
//  and the owner sees no icon at all. Combined with LSUIElement (no dock
//  icon), "Ace is running fine" and "Ace never opened" look identical —
//  the same shape as every other failure FirstRunFailureReporter exists for.
//
//  This is detection + honest instruction, not a fix: no API lets us move or
//  un-hide a status item the system chose to conceal. The verdict is pure
//  geometry against the screen's published safe areas, so a Mac without a
//  notch (safeAreaInsets.top == 0) can never false-positive.
//

#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
import Foundation

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
enum NotchConcealment {

    /// Reported once per launch at most; the reporter dedupes on this id.
    static let failureIdentifier = "menu-bar-icon-concealed-by-notch"

    /// Pure geometry so the verdict is testable without a real notch:
    /// concealed means the status item's window overlaps the horizontal gap
    /// between the two auxiliary (usable) top areas — the gap IS the notch.
    /// Screens without a notch report no auxiliary areas and never conceal.
    static func statusItemIsConcealed(
        statusItemWindowFrame: CGRect,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) -> Bool {
        guard let auxiliaryTopLeftArea, let auxiliaryTopRightArea else { return false }
        let notchGapMinX = auxiliaryTopLeftArea.maxX
        let notchGapMaxX = auxiliaryTopRightArea.minX
        guard notchGapMaxX > notchGapMinX else { return false }
        return statusItemWindowFrame.minX < notchGapMaxX
            && statusItemWindowFrame.maxX > notchGapMinX
    }

    /// Evaluates the live status item and reports through the first-run
    /// channel when it is hidden behind the notch. Called well after launch so
    /// the status bar has settled; quietly does nothing when the item is
    /// missing, on another screen, or genuinely visible.
    static func checkAndReport(menuBarPanelManager: MenuBarPanelManager?) {
        guard let statusItemPlacement = menuBarPanelManager?.statusItemWindowFrameAndScreen() else { return }
        let hostingScreen = statusItemPlacement.screen
        guard statusItemIsConcealed(
            statusItemWindowFrame: statusItemPlacement.frame,
            auxiliaryTopLeftArea: hostingScreen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: hostingScreen.auxiliaryTopRightArea
        ) else { return }

        LifecycleLog.append("NOTCH status item concealed at \(statusItemPlacement.frame)")
        FirstRunFailureReporter.shared.report(
            FirstRunFailure(
                id: failureIdentifier,
                summary: "Ace is running, but its menu-bar icon is hidden behind this Mac's notch.",
                remedy: "The icon works — it's just covered by the camera housing. Hold Command and "
                    + "drag another menu-bar icon off the bar to make room, or quit an app you don't "
                    + "need up there. Ace itself is fine: hold Command-Shift and talk any time, and "
                    + "opening Ace from Applications again brings its window back.",
                repairButtonTitle: nil
            ),
            interrupt: !AceIntroWindowController.shared.isVisible
        )
    }
}
#endif // circuit-convert
