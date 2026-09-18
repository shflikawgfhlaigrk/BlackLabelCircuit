#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app. It stays visible across work in other apps until the owner
//  explicitly closes or toggles it, onboarding takes over, or Stealth begins.
//

import Foundation
import CircuitPortKit
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
@preconcurrency import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

extension Notification.Name {
    static let blacklabelDismissPanel = Notification.Name("blacklabelDismissPanel")

    /// Development-Mac only: drives the setup window's connect step end-to-end
    /// without a human clicking (see the RUN_CONNECT flag file).
    static let aceRunConnectTest = Notification.Name("aceRunConnectTest")

    /// Development-Mac only: exercises the Terminal sign-in hand-off.
    static let aceRunSignInTest = Notification.Name("aceRunSignInTest")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?

    /// Ace is `LSUIElement`, so the menu-bar icon is the ONLY way in: no Dock
    /// tile, no app menu, no window. Build 64 created the item exactly once
    /// from `init`, behind the stealth latch and the visibility wall, and never
    /// retried — so losing that race for a single instant at construction left
    /// the owner with a running process, nothing on screen, and no way to reach
    /// it. That is the "I installed it, I opened it, and nothing appeared"
    /// report. Creation is now observable and self-healing.
    private var statusItemRecoveryTask: Task<Void, Never>?
    private static let statusItemRecoveryInterval = Duration.seconds(1)
    private static let statusItemRecoveryAttemptLimit = 120

    /// The live panel manager, so the first-run tour can fly the gem to the real
    /// menu-bar icon instead of guessing at the top-right corner (which is wrong
    /// on any Mac with a notch, a second display, or other menu-bar items).
    private(set) static weak var shared: MenuBarPanelManager?

    /// Center of the menu-bar icon in AppKit screen coordinates, or nil when the
    /// icon is hidden (stealth) or not yet installed.
    func statusItemCenterInAppKitCoordinates() -> CGPoint? {
        guard let buttonWindowFrame = statusItem?.button?.window?.frame,
              statusItem?.isVisible == true else { return nil }
        return CGPoint(x: buttonWindowFrame.midX, y: buttonWindowFrame.midY)
    }

    /// The status item's window frame plus the screen hosting it, or nil when
    /// the icon is hidden (stealth) or not yet installed. NotchConcealment
    /// needs the full frame and the screen's safe areas, not just the center.
    func statusItemWindowFrameAndScreen() -> (frame: CGRect, screen: NSScreen)? {
        guard let buttonWindow = statusItem?.button?.window,
              let hostingScreen = buttonWindow.screen,
              statusItem?.isVisible == true else { return nil }
        return (buttonWindow.frame, hostingScreen)
    }
    private var panel: NSPanel?
    private var dismissPanelObserver: NSObjectProtocol?
    private var emailSettingsObserver: NSObjectProtocol?
    private var foregroundApplicationObserver: NSObjectProtocol?
    private var activationPermissionObserver: NSObjectProtocol?
    private var wakePermissionObserver: NSObjectProtocol?
    private var externalApplicationBeforePanel: NSRunningApplication?

    private func retainExternalApplication(_ application: NSRunningApplication?) {
        guard !companionManager.stealthActive,
              let application, !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.activationPolicy == .regular else { return }
        externalApplicationBeforePanel = application
    }

    /// Composer focus belongs to Ace, but a point at the underlying page
    /// still belongs to the app the owner was using before that focus change.
    func applicationForPointing() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let identifier = PointingApplicationSelectionPolicy.processIdentifier(
            frontmost: frontmost?.processIdentifier,
            own: ProcessInfo.processInfo.processIdentifier,
            panelIsVisible: panelIsVisible,
            externalBeforePanel: externalApplicationBeforePanel?.processIdentifier
        ), let application = NSRunningApplication(processIdentifier: identifier),
              !application.isTerminated, !application.isHidden else { return nil }
        return application
    }
    private var stealthModeCancellable: AnyCancellable?
    private var displayChangeObserver: NSObjectProtocol?

    /// A show that arrived before AppKit laid the menu-bar icon out. Launch
    /// (`showPanelOnLaunch`) and the locked-install path (`showPanelForManualOpen`
    /// straight after construction) both race status-item creation and its
    /// recovery loop. Build 62 anchored the panel to the not-yet-laid-out
    /// icon's window frame and dropped it at the bottom-left of the screen
    /// (issue #20). The show now waits — bounded — for a laid-out icon, then
    /// falls back to the top-right under the menu bar so the recovery surface
    /// still appears if the icon never lays out.
    private var deferredPanelShowTask: Task<Void, Never>?
    private var deferredPanelShowGeneration: UInt64 = 0
    private static let deferredPanelShowPollInterval = Duration.milliseconds(100)
    private static let deferredPanelShowMaximumWaitSeconds: TimeInterval = 10
    /// True while the visible panel sits at the fallback anchor; the next
    /// status-item install re-anchors it under the icon.
    private var panelIsAtFallbackAnchor = false

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        Self.shared = self
        retainExternalApplication(NSWorkspace.shared.frontmostApplication)
        foregroundApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.retainExternalApplication(
                    notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication
                )
                if self?.panelIsVisible == true {
                    self?.refreshPermissionsForVisibleRuntime()
                }
            }
        }
        activationPermissionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissionsForVisibleRuntime() }
        }
        wakePermissionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissionsForVisibleRuntime() }
        }
        displayChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanchorVisiblePanelAfterDisplayChange() }
        }
        createStatusItem()
        emailSettingsObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AceShowEmailSettings"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPanel() }
        }

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .blacklabelDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hidePanel()
            }
        }

        // CompanionManager publishes on the main actor, so keep this sink
        // synchronous: even one queued main-loop turn would leave the status
        // item visible after the rest of the stealth wall was already active.
        // The isolated local exit-only PTT route can restore it on demand.
        stealthModeCancellable = companionManager.$stealthActive
            .sink { [weak self] stealthIsActive in
                self?.setStealthModeActive(stealthIsActive)
            }
    }

    deinit {
        if let observer = displayChangeObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = activationPermissionObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = wakePermissionObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = emailSettingsObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = foregroundApplicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Hide (stealth on) or restore (stealth off) the menu-bar icon. On enter we
    /// also dismiss the dropdown panel so nothing Ace-shaped stays on screen.
    private func setStealthModeActive(_ stealthIsActive: Bool) {
        if stealthIsActive {
            externalApplicationBeforePanel = nil
            hidePanel()
            statusItem?.isVisible = false
            return
        }
        if statusItem == nil {
            createStatusItem()
        }
        _ = StealthEntryLatch.shared.performUnlessRaised {
            guard !StealthVisibilityGate.shared.isActive else {
                return false
            }
            statusItem?.isVisible = true
            return true
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        guard statusItem == nil else { return }
        let icon = makeBlackLabelMenuBarIcon()
        let admitted = StealthEntryLatch.shared.performUnlessRaised {
            guard !companionManager.stealthActive,
                  !StealthVisibilityGate.shared.isActive else {
                return false
            }
            return installStatusItem(icon: icon)
        }
        if admitted == true, let createdStatusItem = statusItem {
            // A created item is NOT a visible item. The icon can be created
            // with a live button and still never reach the bar (no room, a
            // blank image, a hidden item). Record what actually landed so an
            // invisible Ace is diagnosable from the owner's log instead of
            // requiring the source.
            let buttonFrame = createdStatusItem.button?.window?.frame
            LifecycleLog.append(
                "MENUBAR status item created visible="
                + "\(createdStatusItem.isVisible)"
                + " length=\(createdStatusItem.length)"
                + " frame=\(buttonFrame.map { "\($0)" } ?? "none")"
                + " hasImage=\(createdStatusItem.button?.image != nil)"
                + " imageSize="
                + "\(createdStatusItem.button?.image?.size.debugDescription ?? "none")"
            )
            scheduleStatusItemVisibilityAudit()
            return
        }
        // Never leave an LSUIElement app with no way in. Say so, then keep
        // trying: a raised latch or an active wall is transient, and the
        // owner must not have to relaunch to get their menu bar back.
        LifecycleLog.append(
            "MENUBAR status item not created at launch — recovering"
        )
        scheduleStatusItemRecovery()
    }

    /// Proves the icon is actually on screen a moment after creation. A status
    /// item whose button never acquires a window is present in the process and
    /// absent from the owner's Mac — the failure that reads as "I opened Ace
    /// and nothing appeared" while every launch receipt looks healthy.
    private func scheduleStatusItemVisibilityAudit() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self,
                  !StealthEntryLatch.shared.isRaised,
                  !self.companionManager.stealthActive,
                  let auditedStatusItem = self.statusItem else {
                return
            }
            let buttonWindow = auditedStatusItem.button?.window
            let isOnScreen = buttonWindow?.isVisible == true
                && (buttonWindow?.frame.width ?? 0) > 0
            guard !isOnScreen || !auditedStatusItem.isVisible else {
                LifecycleLog.append("MENUBAR status item ON SCREEN")
                return
            }
            LifecycleLog.append(
                "MENUBAR status item CREATED BUT NOT ON SCREEN"
                + " visible=\(auditedStatusItem.isVisible)"
                + " window=\(buttonWindow.map { "\($0.frame)" } ?? "none")"
                + " — forcing visible and rebuilding"
            )
            auditedStatusItem.isVisible = true
            guard buttonWindow == nil
                || buttonWindow?.isVisible != true else { return }
            // Rebuild from scratch: an item that never acquired a window will
            // not acquire one by waiting.
            NSStatusBar.system.removeStatusItem(auditedStatusItem)
            self.statusItem = nil
            if self.installStatusItem(
                icon: self.makeBlackLabelMenuBarIcon()
            ) {
                LifecycleLog.append("MENUBAR status item rebuilt")
            } else {
                self.scheduleStatusItemRecovery()
            }
        }
    }

    /// Installs the item and proves it landed. `statusItem(withLength:)` can
    /// hand back an item whose button never materializes when the menu bar is
    /// saturated; treating that as success is what makes an icon-less launch
    /// look identical to a healthy one.
    private func installStatusItem(icon: NSImage) -> Bool {
        let newStatusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        guard let button = newStatusItem.button else {
            NSStatusBar.system.removeStatusItem(newStatusItem)
            return false
        }
        button.toolTip = "Ace"
        button.setAccessibilityLabel("Ace")
        button.image = icon
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
        statusItem = newStatusItem
        reanchorPanelIfPlacedWithoutStatusItem()
        return true
    }

    /// Retries creation until the icon is actually in the bar. Bounded so a
    /// permanently refused item reports a real terminal instead of spinning.
    private func scheduleStatusItemRecovery() {
        guard statusItemRecoveryTask == nil else { return }
        statusItemRecoveryTask = Task { @MainActor [weak self] in
            for _ in 0 ..< Self.statusItemRecoveryAttemptLimit {
                try? await Task.sleep(for: Self.statusItemRecoveryInterval)
                guard let self, !Task.isCancelled else { return }
                guard self.statusItem == nil else {
                    self.statusItemRecoveryTask = nil
                    return
                }
                // Stealth deliberately hides the icon; that is not a failure to
                // recover from. Only retry once the owner is out of it.
                guard !self.companionManager.stealthActive,
                      !StealthVisibilityGate.shared.isActive,
                      !StealthEntryLatch.shared.isRaised else { continue }
                if self.installStatusItem(
                    icon: self.makeBlackLabelMenuBarIcon()
                ) {
                    LifecycleLog.append("MENUBAR status item recovered")
                    self.statusItemRecoveryTask = nil
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            LifecycleLog.append(
                "MENUBAR status item UNRECOVERABLE — Ace has no way in"
            )
            self.statusItemRecoveryTask = nil
        }
    }

    /// The Ace mark for the menu bar: a genuine ace-of-spades spade, matching the
    /// app's ace-of-spades logo. Restored from utah-Ace — the plain rotated
    /// triangle that shipped in clicky was a regression from the real spade.
    private func makeBlackLabelMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        // Small inset so the glyph doesn't touch the icon edges.
        let glyphRect = NSRect(x: iconSize * 0.11, y: iconSize * 0.11,
                               width: iconSize * 0.78, height: iconSize * 0.78)
        func point(_ fractionX: CGFloat, _ fractionY: CGFloat) -> CGPoint {
            CGPoint(x: glyphRect.minX + fractionX * glyphRect.width,
                    y: glyphRect.minY + fractionY * glyphRect.height)
        }

        let spade = NSBezierPath()
        spade.move(to: point(0.50, 0.96))
        spade.curve(to: point(0.94, 0.42), controlPoint1: point(0.66, 0.80), controlPoint2: point(0.94, 0.66))
        spade.curve(to: point(0.56, 0.20), controlPoint1: point(0.94, 0.26), controlPoint2: point(0.72, 0.20))
        spade.curve(to: point(0.70, 0.06), controlPoint1: point(0.58, 0.15), controlPoint2: point(0.64, 0.10))
        spade.line(to: point(0.30, 0.06))
        spade.curve(to: point(0.44, 0.20), controlPoint1: point(0.36, 0.10), controlPoint2: point(0.42, 0.15))
        spade.curve(to: point(0.06, 0.42), controlPoint1: point(0.28, 0.20), controlPoint2: point(0.06, 0.26))
        spade.curve(to: point(0.50, 0.96), controlPoint1: point(0.06, 0.66), controlPoint2: point(0.34, 0.80))
        spade.close()

        NSColor.black.setFill()
        spade.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar.
        // The delay is a courtesy, not the guarantee: `showPanel` itself waits
        // for a laid-out icon before it anchors anything (issue #20).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    /// A manual Finder/Dock reopen is an explicit request to see Ace.
    func showPanelForManualOpen() {
        showPanel()
    }

    /// Ace has no document window. Its own panel, on the active Space, is the
    /// visible postcondition for an explicit owner request to open Ace.
    func openPanelForOwnerRequest(
        on requestedScreen: NSScreen? = nil,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard isCurrent() else { return false }
        showPanel()
        for _ in 0...110 {
            guard !Task.isCancelled, isCurrent(),
                  !StealthEntryLatch.shared.isRaised,
                  !StealthVisibilityGate.shared.isActive else { return false }
            if let panel, panel.isVisible, panel.isOnActiveSpace,
               panel.alphaValue > 0,
               NSScreen.screens.contains(where: {
                   $0.visibleFrame.intersects(panel.frame)
               }) {
                if let requestedScreen {
                    guard let screenNumber = requestedScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let liveScreen = NSScreen.screens.first(where: {
                              ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenNumber
                          }) else { return false }
                    let available = liveScreen.visibleFrame
                    let size = CGSize(width: min(panel.frame.width, available.width),
                                      height: min(panel.frame.height, available.height))
                    panel.setFrame(CGRect(x: available.midX - size.width / 2,
                                          y: available.maxY - size.height,
                                          width: size.width, height: size.height), display: true)
                    return available.insetBy(dx: -1, dy: -1).contains(panel.frame)
                }
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Command+, is an alternate entry point to the same menu-bar panel. It
    /// must not construct a SwiftUI Settings window with a second close owner.
    func showPanelForSettingsCommand() {
        showPanel()
    }

    func showPanelForVoiceInputFailure() {
        showPanel()
    }

    /// Consequential app work always gets an on-screen immutable review card.
    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func reanchorVisiblePanelAfterDisplayChange() {
        guard panel?.isVisible == true,
              !companionManager.stealthActive,
              !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else { return }
        if !positionPanelBelowStatusItem() {
            positionPanelBelowMenuBarWithoutStatusItem()
        }
    }

    private func refreshPermissionsForVisibleRuntime() {
        guard !companionManager.stealthActive,
              !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else { return }
        companionManager.refreshAllPermissions()
    }

    private func showPanel(makeKey: Bool = true) {
        retainExternalApplication(NSWorkspace.shared.frontmostApplication)
        guard !companionManager.stealthActive,
              !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else { return }
        refreshPermissionsForVisibleRuntime()
        // Refresh may restore the event tap and observe a concurrent entry chord.
        guard !companionManager.stealthActive,
              !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else { return }
        if panel == nil {
            createPanel()
        }

        // Never present a frame computed from an icon AppKit has not laid out
        // yet — that is the bottom-left panel of issue #20. Wait for the icon
        // (bounded), then present.
        guard positionPanelBelowStatusItem() else {
            deferPanelShowUntilStatusItemIsLaidOut(makeKey: makeKey)
            return
        }
        cancelDeferredPanelShow()
        presentPositionedPanel(makeKey: makeKey)
    }

    /// Orders an already-positioned panel on screen behind the Stealth latch.
    private func presentPositionedPanel(makeKey: Bool) {
        let wasVisible = panel?.isVisible == true
        let didShow =
            StealthEntryLatch.shared.performUnlessRaised {
                guard !companionManager.stealthActive,
                      !StealthVisibilityGate.shared.isActive else {
                    return false
                }
                if makeKey {
                    NSApp.activate(ignoringOtherApps: true)
                    panel?.makeKeyAndOrderFront(nil)
                }
                panel?.orderFrontRegardless()
                return true
            } ?? false
        if !didShow {
            hidePanel()
        } else {
            if !wasVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               let layer = panel?.contentView?.layer {
                let entrance = CASpringAnimation(keyPath: "transform.scale")
                entrance.fromValue = 0.965
                entrance.toValue = 1
                entrance.mass = 0.7
                entrance.stiffness = 280
                entrance.damping = 25
                entrance.duration = 0.3
                layer.add(entrance, forKey: "ace.panel.entrance")
            }
            InstallReadinessCoordinator.shared.set(
                .visiblePanel,
                active: true
            )
        }
    }

    /// A show that arrived before the menu-bar icon was laid out. Polls for a
    /// laid-out icon and anchors below it; once the bound expires the panel —
    /// the owner's recovery surface — still appears, under the menu bar at the
    /// top-right of the menu-bar screen. Stealth or a user close in the
    /// meantime retires the pending show.
    private func deferPanelShowUntilStatusItemIsLaidOut(makeKey: Bool) {
        guard deferredPanelShowTask == nil else { return }
        LifecycleLog.append(
            "MENUBAR panel show deferred — status item not laid out yet"
        )
        deferredPanelShowGeneration &+= 1
        let generation = deferredPanelShowGeneration
        let clock = ContinuousClock()
        let deferredAt = clock.now
        deferredPanelShowTask = Task { @MainActor [weak self] in
            defer {
                if let self,
                   self.deferredPanelShowGeneration == generation {
                    self.deferredPanelShowTask = nil
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: Self.deferredPanelShowPollInterval
                )
                guard let self, !Task.isCancelled else { return }
                guard !self.companionManager.stealthActive,
                      !StealthVisibilityGate.shared.isActive,
                      !StealthEntryLatch.shared.isRaised else { return }
                let waitedSeconds = Self.seconds(in: clock.now - deferredAt)
                switch AssistantAvailabilityPolicy.deferredPanelPlacement(
                    statusItemIsLaidOut: self.statusItemAnchor() != nil,
                    waitedSeconds: waitedSeconds,
                    maximumWaitSeconds:
                        Self.deferredPanelShowMaximumWaitSeconds
                ) {
                case .keepWaiting:
                    continue
                case .belowStatusItem:
                    guard self.positionPanelBelowStatusItem() else {
                        continue
                    }
                    LifecycleLog.append(
                        "MENUBAR panel anchored below status item after "
                            + "\(Int(waitedSeconds * 1_000))ms"
                    )
                    self.presentPositionedPanel(makeKey: makeKey)
                    return
                case .belowMenuBarWithoutStatusItem:
                    self.positionPanelBelowMenuBarWithoutStatusItem()
                    LifecycleLog.append(
                        "MENUBAR status item not laid out after "
                            + "\(Int(waitedSeconds))s — panel shown at the "
                            + "top-right fallback"
                    )
                    self.presentPositionedPanel(makeKey: makeKey)
                    return
                }
            }
        }
    }

    private func cancelDeferredPanelShow() {
        deferredPanelShowTask?.cancel()
        deferredPanelShowTask = nil
    }

    /// A panel that was shown at the fallback anchor moves under the icon as
    /// soon as a (re)installed icon is laid out — the same bounded wait.
    private func reanchorPanelIfPlacedWithoutStatusItem() {
        guard panelIsAtFallbackAnchor, panel?.isVisible == true else { return }
        deferPanelShowUntilStatusItemIsLaidOut(makeKey: false)
    }

    private static func seconds(in duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }

    private func hidePanel() {
        cancelDeferredPanelShow()
        panelIsAtFallbackAnchor = false
        companionManager.dismissVisibleAppActionReview()
        panel?.contentView?.layer?.removeAnimation(forKey: "ace.panel.entrance")
        panel?.orderOut(nil)
        InstallReadinessCoordinator.shared.set(
            .visiblePanel,
            active: false
        )
    }

    /// The panel's own Close control calls this directly instead of relying
    /// only on the dismiss notification — a user-visible control may not
    /// depend on observer wiring to have its one effect.
    func hidePanelForUserClose() {
        hidePanel()
    }

    /// True while the dropdown panel is on screen. The failure reporter uses
    /// this to skip the interrupting license alert when the locked panel —
    /// which carries the same recovery controls — is already visible.
    var panelIsVisible: Bool {
        panel?.isVisible == true
    }

    /// A nonactivating menu-bar panel may remain visible while another app is
    /// active. Promote it on the first composer click so SwiftUI text editors
    /// receive keyboard events immediately instead of looking enabled while
    /// silently discarding input.
    func activatePanelForTextInput() {
        guard let panel, panel.isVisible else { return }
        retainExternalApplication(NSWorkspace.shared.frontmostApplication)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = AceHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.becomesKeyOnlyIfNeeded = false
        menuBarPanel.level = .floating
        // Build 61's dead buttons: the launch-time license-failure alert runs
        // an app-modal session, and AppKit discards every mouse event aimed at
        // a non-modal window unless it works when modal. Without this line,
        // Quit/Close/Link this Mac in this panel silently ate every click for
        // as long as any alert (license, update, key entry) was on screen.
        menuBarPanel.worksWhenModal = true
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private static let gapBelowMenuBar: CGFloat = 4

    /// The icon's frame in screen coordinates plus its screen — only once
    /// AppKit has laid the icon out in a menu bar. Before layout the button
    /// already has a window and a screen, but that window still sits at the
    /// screen's origin; anchoring to it is what dropped the launch panel at
    /// the bottom-left (issue #20, the locked panel at x≈71 after relaunch).
    private func statusItemAnchor() -> (frame: CGRect, screen: NSScreen)? {
        guard let statusItemButton = statusItem?.button,
              let buttonWindow = statusItemButton.window,
              let hostingScreen = buttonWindow.screen else { return nil }
        let statusItemFrameInWindow = statusItemButton.convert(
            statusItemButton.bounds,
            to: nil
        )
        let statusItemFrame = buttonWindow.convertToScreen(
            statusItemFrameInWindow
        )
        guard AssistantAvailabilityPolicy.statusItemFrameIsLaidOutInMenuBar(
            statusItemFrame: statusItemFrame,
            screenFrame: hostingScreen.frame
        ) else { return nil }
        return (statusItemFrame, hostingScreen)
    }

    /// Anchors the panel below the icon. False when the icon is not laid out
    /// yet; the panel's frame is then left untouched so no caller can present
    /// a frame computed from nothing.
    @discardableResult
    private func positionPanelBelowStatusItem() -> Bool {
        guard let panel, let anchor = statusItemAnchor() else { return false }
        let boundedPanelSize = boundedPanelSize(
            for: panel,
            on: anchor.screen
        )
        let panelFrame =
            AssistantAvailabilityPolicy.panelFrameBelowStatusItem(
                statusItemFrame: anchor.frame,
                screenVisibleFrame: anchor.screen.visibleFrame,
                panelSize: boundedPanelSize,
                gapBelowMenuBar: Self.gapBelowMenuBar
            )

        panel.contentView?.frame.size = boundedPanelSize
        panel.setFrame(
            panelFrame,
            display: true
        )
        panelIsAtFallbackAnchor = false
        return true
    }

    /// The bounded fallback: under the menu bar at the top-right of the
    /// menu-bar screen. Used only after the icon failed to lay out in time.
    private func positionPanelBelowMenuBarWithoutStatusItem() {
        guard let panel,
              let menuBarScreen = NSScreen.screens.first ?? NSScreen.main else {
            return
        }
        let boundedPanelSize = boundedPanelSize(
            for: panel,
            on: menuBarScreen
        )
        let panelFrame =
            AssistantAvailabilityPolicy.panelFrameWithoutStatusItem(
                screenVisibleFrame: menuBarScreen.visibleFrame,
                panelSize: boundedPanelSize,
                gapBelowMenuBar: Self.gapBelowMenuBar
            )

        panel.contentView?.frame.size = boundedPanelSize
        panel.setFrame(
            panelFrame,
            display: true
        )
        panelIsAtFallbackAnchor = true
    }

    private func boundedPanelSize(
        for panel: NSPanel,
        on screen: NSScreen
    ) -> CGSize {
        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize
            ?? CGSize(width: panelWidth, height: panelHeight)
        return AssistantAvailabilityPolicy.boundedPanelSize(
            desired: CGSize(
                width: panelWidth,
                height: fittingSize.height
            ),
            screenVisibleFrame: screen.visibleFrame,
            verticalSafetyMargin: 12
        )
    }

}
#endif // circuit-convert
