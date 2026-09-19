import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum SetupWalkthroughIntent: Equatable {
    /// The initial setup is unfinished. Ace may resume it after an interruption
    /// until every required live proof has passed.
    case automaticFirstRunResume

    /// Setup already succeeded, but a current dependency is now genuinely
    /// missing and the owner explicitly chose Repair Ace.
    case explicitRepair
}

struct AggregateAutomationRecoveryPlan: Equatable {
    let schedulesStep: Bool
    let retryIntervalSeconds: TimeInterval?
}

enum AssistantAvailabilityPolicy {
    static func ownedPermissionRepairIntent(
        hasCompletedOnboarding: Bool
    ) -> SetupWalkthroughIntent {
        hasCompletedOnboarding ? .explicitRepair : .automaticFirstRunResume
    }

    static func shouldCompleteSetupFromIntro(
        requiredProofsReady: Bool
    ) -> Bool {
        requiredProofsReady
    }

    static func shouldBeginLiveFirstRunProof(
        phase: AceFirstRunPhase
    ) -> Bool {
        phase == .liveCommandShiftProof
    }

    static func mayPersistFirstRunCompletion(
        phase: AceFirstRunPhase
    ) -> Bool {
        phase == .complete
    }

    /// Setup completion is a sticky lifecycle boundary. Current runtime health
    /// may offer a repair, but it must never turn a completed owner back into a
    /// first-run owner or reopen setup automatically.
    static func mayRunSetupWalkthrough(
        hasCompletedOnboarding: Bool,
        intent: SetupWalkthroughIntent,
        hasOutstandingSteps: Bool
    ) -> Bool {
        switch intent {
        case .automaticFirstRunResume:
            return !hasCompletedOnboarding
        case .explicitRepair:
            return hasCompletedOnboarding && hasOutstandingSteps
        }
    }

    static func shouldOfferSetupRepair(
        hasCompletedOnboarding: Bool,
        currentSetupProofsReady: Bool
    ) -> Bool {
        hasCompletedOnboarding && !currentSetupProofsReady
    }

    static func mayPresentReadyClaim(
        hasCompletedOnboarding: Bool,
        panelPermissionsReady: Bool
    ) -> Bool {
        hasCompletedOnboarding && panelPermissionsReady
    }

    static func shouldShowPersistentGem(
        hasCompletedOnboarding: Bool,
        cursorEnabled: Bool,
        stealthVisibilityBlocked: Bool,
        coreInteractionPermissionsReady: Bool,
        appAutomationReady: Bool
    ) -> Bool {
        hasCompletedOnboarding
            && cursorEnabled
            && !stealthVisibilityBlocked
    }

    static func nonCoreSetupStepIsSatisfied(
        hasCompletedOnboarding: Bool,
        hasCurrentProof: Bool
    ) -> Bool {
        hasCompletedOnboarding || hasCurrentProof
    }

    /// Walkthrough admission and current health use the same live proof. A
    /// sticky completed-setup bit may keep the normal panel available, but it
    /// must never erase the exact missing step after the owner chooses Repair.
    static func setupStepIsSatisfied(
        intent: SetupWalkthroughIntent,
        hasCurrentProof: Bool
    ) -> Bool {
        switch intent {
        case .automaticFirstRunResume, .explicitRepair:
            return hasCurrentProof
        }
    }

    /// Automation is an optional, just-in-time integration. Neither automatic
    /// first run nor the aggregate Repair walkthrough may schedule the legacy
    /// all-app prompt/retry loop; each target remains owner-requested in-panel.
    static func aggregateAutomationRecoveryPlan(
        intent _: SetupWalkthroughIntent,
        hasCurrentProof _: Bool?
    ) -> AggregateAutomationRecoveryPlan {
        AggregateAutomationRecoveryPlan(
            schedulesStep: false,
            retryIntervalSeconds: nil
        )
    }

    static func panelPermissionsAreReady(
        hasCompletedOnboarding _: Bool,
        coreInteractionPermissionsReady: Bool,
        appAutomationReady _: Bool
    ) -> Bool {
        coreInteractionPermissionsReady
    }

    static func panelFrameBelowStatusItem(
        statusItemFrame: CGRect,
        screenVisibleFrame: CGRect,
        panelSize: CGSize,
        gapBelowMenuBar: CGFloat
    ) -> CGRect {
        let maximumPanelOriginX = max(
            screenVisibleFrame.minX,
            screenVisibleFrame.maxX - panelSize.width
        )
        let maximumPanelOriginY = max(
            screenVisibleFrame.minY,
            screenVisibleFrame.maxY - panelSize.height
        )
        let proposedPanelOriginX =
            statusItemFrame.midX - panelSize.width / 2
        let proposedPanelOriginY =
            statusItemFrame.minY
                - panelSize.height
                - gapBelowMenuBar
        let panelOriginX = min(
            max(proposedPanelOriginX, screenVisibleFrame.minX),
            maximumPanelOriginX
        )
        let panelOriginY = min(
            max(proposedPanelOriginY, screenVisibleFrame.minY),
            maximumPanelOriginY
        )
        return CGRect(
            origin: CGPoint(x: panelOriginX, y: panelOriginY),
            size: panelSize
        )
    }

    static func boundedPanelSize(
        desired: CGSize,
        screenVisibleFrame: CGRect,
        verticalSafetyMargin: CGFloat
    ) -> CGSize {
        CGSize(
            width: min(
                max(1, desired.width),
                max(1, screenVisibleFrame.width)
            ),
            height: min(
                max(1, desired.height),
                max(
                    1,
                    screenVisibleFrame.height
                        - max(0, verticalSafetyMargin)
                )
            )
        )
    }

    /// A status item AppKit has not laid out yet still answers with a button,
    /// a window, and a screen — but its window frame sits at the screen's
    /// origin instead of in the menu bar. Anchoring the dropdown to that frame
    /// put the launch-time panel at the bottom-left of the display (issue #20:
    /// the locked panel at x≈71 after a relaunch). A laid-out menu-bar item
    /// always occupies the top strip of its own screen, on every menu-bar
    /// height, notch, and multi-display arrangement.
    static func statusItemFrameIsLaidOutInMenuBar(
        statusItemFrame: CGRect,
        screenFrame: CGRect
    ) -> Bool {
        statusItemFrame.width > 0
            && statusItemFrame.height > 0
            && screenFrame.intersects(statusItemFrame)
            && statusItemFrame.minY >= screenFrame.midY
    }

    enum DeferredPanelPlacement: Equatable {
        /// The icon is laid out: drop the panel below it now.
        case belowStatusItem
        /// The icon is not laid out yet and the bound has not expired.
        case keepWaiting
        /// The bound expired. The panel is the owner's recovery surface and
        /// must still appear, so place it under the menu bar at the top-right.
        case belowMenuBarWithoutStatusItem
    }

    /// Launch-time and manual shows race status-item creation and its bounded
    /// recovery loop. The panel is never presented at a frame computed from an
    /// un-laid-out icon: it waits, bounded, then falls back to a sane on-screen
    /// anchor.
    static func deferredPanelPlacement(
        statusItemIsLaidOut: Bool,
        waitedSeconds: TimeInterval,
        maximumWaitSeconds: TimeInterval
    ) -> DeferredPanelPlacement {
        if statusItemIsLaidOut {
            return .belowStatusItem
        }
        return waitedSeconds < maximumWaitSeconds
            ? .keepWaiting
            : .belowMenuBarWithoutStatusItem
    }

    /// Top-right of the visible frame, directly under the menu bar — where the
    /// owner looks for a menu-bar app whose icon has not appeared.
    static func panelFrameWithoutStatusItem(
        screenVisibleFrame: CGRect,
        panelSize: CGSize,
        gapBelowMenuBar: CGFloat
    ) -> CGRect {
        let panelOriginX = max(
            screenVisibleFrame.minX,
            screenVisibleFrame.maxX - panelSize.width
        )
        let panelOriginY = max(
            screenVisibleFrame.minY,
            screenVisibleFrame.maxY - panelSize.height - gapBelowMenuBar
        )
        return CGRect(
            origin: CGPoint(x: panelOriginX, y: panelOriginY),
            size: panelSize
        )
    }
}
