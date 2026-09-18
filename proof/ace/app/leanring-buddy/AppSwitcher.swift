#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  AppSwitcher.swift
//  Black Label Assistant — instant "go to <app>".
//
//  "go to black label academy", "switch to chrome", "open safari" — resolving
//  and activating an app takes ~50ms in-process, so these never ride the codex
//  round-trip. The fast path only claims an utterance when a real app RESOLVES;
//  everything else falls through to normal routing (walkthrough, red agent,
//  gold), which keeps broad verbs like "open" safe — "open the pricing page"
//  resolves no app and lands with the worker as before.
//

#if canImport(ApplicationServices) && !CIRCUIT_WINDOWS_SIM
import ApplicationServices
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
import Foundation

/// One synchronous effect-admission primitive shared by every fast app-switch
/// commit. The injected form keeps the race contract deterministic in the
/// offline harness: the visibility wall is checked both before and inside the
/// same latch which the X event raises.
nonisolated enum AppSwitcherEffectAdmission {
    static func commit(
        visibilityIsBlocked: @escaping () -> Bool,
        performUnlessRaised: (_ body: () -> Bool) -> Bool?,
        effect: @escaping () -> Bool
    ) -> Bool {
        guard !visibilityIsBlocked() else { return false }
        let admitted = performUnlessRaised {
            guard !visibilityIsBlocked() else { return false }
            return effect()
        }
        return admitted == true
    }
}

@MainActor
enum AppSwitcher {
    struct ActivationResult: Equatable {
        let spokenConfirmation: String
        let resolvedApplicationName: String
        let bundleIdentifier: String?
        let visibleWindowCount: Int
        let verifiedVisible: Bool
    }

    struct BrowserNavigationResult: Equatable {
        let spokenConfirmation: String
        let browserName: String?
        let verifiedVisibleTarget: Bool
    }

    struct PassiveRunningTarget: Equatable {
        let applicationName: String
        let processIdentifier: pid_t
        let windowNumber: UInt32
    }

    /// Read-only resolution used when a later, confirmed action needs an exact
    /// app identity. This API never unhides, activates, reopens, or launches.
    enum PassiveResolution: Equatable {
        case notAppSwitchRequest
        case notFound(candidate: String)
        case ambiguous(candidate: String)
        case running(PassiveRunningTarget)
        case runningWithoutWindowIdentity(applicationName: String)
        case installed(applicationName: String)
    }

    /// Resolve the app named by a navigation utterance without causing any
    /// workspace event. Display-qualified opens use this before staging the
    /// one confirmed window move; a non-running or ambiguous app cannot be
    /// silently opened as a side effect of preparing that plan.
    static func resolveWithoutActivation(_ utterance: String) -> PassiveResolution {
        guard let candidateName = NativeAppSwitchIntentPolicy.candidate(
            from: utterance
        ) else {
            return .notAppSwitchRequest
        }
        switch resolveApp(named: candidateName) {
        case .matched(.running(let app)):
            let applicationName = app.localizedName ?? candidateName
            guard let windowNumber =
                    frontWindowNumber(for: app.processIdentifier) else {
                return .runningWithoutWindowIdentity(
                    applicationName: applicationName
                )
            }
            return .running(
                PassiveRunningTarget(
                    applicationName: applicationName,
                    processIdentifier: app.processIdentifier,
                    windowNumber: windowNumber
                )
            )
        case .matched(.installed(_, let applicationName)):
            return .installed(applicationName: applicationName)
        case .notFound:
            return .notFound(candidate: candidateName)
        case .ambiguous:
            return .ambiguous(candidate: candidateName)
        }
    }

    /// AX returns an app's windows front-to-back. Bind the first window's
    /// exact window-server identifier without focusing it. Missing
    /// Accessibility access or a windowless process fails closed. (The
    /// "AXWindowNumber" attribute this used to read is vended by no ordinary
    /// app, so every display-qualified move was refused as unbound.)
    private static func frontWindowNumber(
        for processIdentifier: pid_t
    ) -> UInt32? {
        let applicationElement =
            AXUIElementCreateApplication(processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let windows = windowsValue as? [AXUIElement],
        let frontWindow = windows.first else {
            return nil
        }
        return AccessibilityWindowIdentity.windowIdentifier(of: frontWindow)
    }

    /// Executes one candidate already frozen by owner-turn admission. This
    /// effect API intentionally accepts no utterance and performs no grammar
    /// parsing, so downstream text cannot replace the admitted app target.
    static func handleFrozenCandidate(
        _ candidateName: String
    ) async -> ActivationResult? {
        let candidateName = candidateName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !candidateName.isEmpty else { return nil }
        guard case .matched(let resolution) = resolveApp(named: candidateName)
        else {
            return nil
        }
        switch resolution {
        case .running(let runningApp):
            let applicationName = runningApp.localizedName ?? candidateName
            // `NSRunningApplication.activate()` may return false even when the
            // app is healthy, which used to short-circuit the reliable
            // workspace-open path. One activating workspace request works for
            // both running and windowless apps and is verified below.
            guard reopenSoAWindowExists(runningApp) else {
                return nil
            }
            guard let visibleWindowCount =
                    await verifiedFrontmostWindowCount(
                processIdentifier: runningApp.processIdentifier,
                application: runningApp
            ) else {
                appendSwitchLog(
                    "SWITCH activation FAILED \(applicationName)"
                )
                return ActivationResult(
                    spokenConfirmation:
                    "i found \(applicationName), but macos did not bring it forward. click it once, then try again.",
                    resolvedApplicationName: applicationName,
                    bundleIdentifier: runningApp.bundleIdentifier,
                    visibleWindowCount: 0,
                    verifiedVisible: false
                )
            }
            appendSwitchLog("SWITCH activated \(applicationName)")
            return ActivationResult(
                spokenConfirmation:
                    "\(applicationName) is open, frontmost, and visible.",
                resolvedApplicationName: applicationName,
                bundleIdentifier: runningApp.bundleIdentifier,
                visibleWindowCount: visibleWindowCount,
                verifiedVisible: true
            )
        case .installed(let applicationURL, let applicationName):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            guard commitVisibleEffect({
                let request: Void = NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: configuration
                )
                _ = request
                return true
            }) else {
                return nil
            }
            guard let launched = await runningApplication(at: applicationURL),
                  let visibleWindowCount =
                    await verifiedFrontmostWindowCount(
                        processIdentifier: launched.processIdentifier,
                        application: launched
                    ) else {
                appendSwitchLog(
                    "SWITCH launch visibility FAILED \(applicationName)"
                )
                return ActivationResult(
                    spokenConfirmation:
                        "macos accepted the \(applicationName) launch, but no frontmost visible window appeared.",
                    resolvedApplicationName: applicationName,
                    bundleIdentifier: nil,
                    visibleWindowCount: 0,
                    verifiedVisible: false
                )
            }
            appendSwitchLog("SWITCH launched \(applicationName)")
            return ActivationResult(
                spokenConfirmation:
                    "\(applicationName) is open, frontmost, and visible.",
                resolvedApplicationName: applicationName,
                bundleIdentifier: launched.bundleIdentifier,
                visibleWindowCount: visibleWindowCount,
                verifiedVisible: true
            )
        }
    }

    struct WindowBoundActivationResult: Equatable {
        let resolvedApplicationName: String
        let bundleIdentifier: String?
        let processIdentifier: pid_t
        let windowIdentifier: UInt32
    }

    enum WindowBoundActivation: Equatable {
        case bound(WindowBoundActivationResult)
        /// Owner-facing reason. Nothing was typed; at most the named app was
        /// brought forward.
        case unavailable(String)
    }

    private struct WindowInventory {
        let descriptors: [DesktopWindowDescriptor]
        let elements: [AXUIElement]
        /// Open document windows the window server knows about that
        /// Accessibility does not list: they live on another Space.
        let openWindowCountOnOtherSpaces: Int
    }

    /// Brings ONE exact window of a frozen, already-running application
    /// forward for a typing action and returns its verified identity.
    ///
    /// The window is chosen from state captured before any activation, so
    /// switching cannot change the answer. A minimized document is restored
    /// only when it is the application's sole document. An application that is
    /// not running is never launched here: a fresh window has no field the
    /// owner prepared, and typing into its address bar is not what was asked.
    static func activateFrozenCandidateWindow(
        _ candidateName: String
    ) async -> WindowBoundActivation? {
        let candidateName = candidateName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !candidateName.isEmpty else { return nil }
        guard case .matched(let resolution) = resolveApp(named: candidateName)
        else {
            return nil
        }
        guard case .running(let runningApp) = resolution else {
            if case .installed(_, let applicationName) = resolution {
                appendSwitchLog(
                    "SWITCH window-bind refused nonrunning=\(applicationName)"
                )
                return .unavailable(
                    "\(applicationName) is not open, so there is no field to type into. open it, click where the text should go, then ask again."
                )
            }
            return nil
        }
        let applicationName = runningApp.localizedName ?? candidateName
        let processIdentifier = runningApp.processIdentifier

        guard AXIsProcessTrusted() else {
            appendSwitchLog("SWITCH window-bind refused accessibility=off")
            return .unavailable(
                "Ace's Accessibility permission is off, so i could not bind one exact \(applicationName) window. turn Ace on in System Settings, Privacy & Security, Accessibility, then ask again."
            )
        }
        guard let inventory = windowInventory(for: processIdentifier) else {
            appendSwitchLog(
                "SWITCH window-bind refused inventory=unreadable pid=\(processIdentifier)"
            )
            return .unavailable(
                "\(applicationName) did not answer when i asked for its windows, so i did not type anything. wait until it responds, then ask again."
            )
        }

        let selection = DesktopWindowBindingPolicy.selection(
            from: inventory.descriptors
        )
        // An open window the owner left on another Space is invisible to
        // Accessibility until macOS switches to it. Restoring a Dock document
        // instead would substitute a different window, so in that one case
        // plain activation goes first and identity is bound after the switch.
        let ownerWindowIsOnAnotherSpace =
            inventory.openWindowCountOnOtherSpaces > 0

        func refusal() -> WindowBoundActivation {
            appendSwitchLog(
                "SWITCH window-bind refused selection=\(selection) pid=\(processIdentifier)"
            )
            return .unavailable(
                DesktopWindowBindingPolicy.refusalReason(
                    for: selection,
                    applicationName: applicationName
                ) ?? "i could not bind one exact \(applicationName) window."
            )
        }

        let boundWindowIdentifier: UInt32?
        switch selection {
        case .existing(let descriptor):
            boundWindowIdentifier = descriptor.windowIdentifier
            guard raise(
                inventory.elements[descriptor.accessibilityOrder],
                restoringFromDock: false
            ) else { return nil }

        case .restoreOnlyMinimized(let descriptor):
            if ownerWindowIsOnAnotherSpace {
                boundWindowIdentifier = nil
            } else {
                boundWindowIdentifier = descriptor.windowIdentifier
                guard raise(
                    inventory.elements[descriptor.accessibilityOrder],
                    restoringFromDock: true
                ) else { return nil }
                appendSwitchLog(
                    "SWITCH restored only minimized document pid=\(processIdentifier)"
                )
            }

        case .ambiguousMinimized, .noStandardWindow:
            guard ownerWindowIsOnAnotherSpace else { return refusal() }
            boundWindowIdentifier = nil

        case .ambiguousOpen, .identityUnavailable:
            return refusal()
        }

        guard let verifiedWindowIdentifier = await verifiedFocusedWindow(
            application: runningApp,
            expectedWindowIdentifier: boundWindowIdentifier
        ) else {
            appendSwitchLog(
                "SWITCH window-bind FAILED verification pid=\(processIdentifier) expected-window=\(boundWindowIdentifier ?? 0)"
            )
            return .unavailable(
                "macos did not bring the \(applicationName) window i bound forward, so i did not type anything. click that window once, then ask again."
            )
        }
        appendSwitchLog(
            "SWITCH window-bound \(applicationName) pid=\(processIdentifier) window=\(verifiedWindowIdentifier)"
        )
        return .bound(
            WindowBoundActivationResult(
                resolvedApplicationName: applicationName,
                bundleIdentifier: runningApp.bundleIdentifier,
                processIdentifier: processIdentifier,
                windowIdentifier: verifiedWindowIdentifier
            )
        )
    }

    /// Exact identifier of the application's focused standard window, or nil.
    static func focusedStandardWindowIdentifier(
        for processIdentifier: pid_t
    ) -> UInt32? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success,
        let focusedWindowValue,
        CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedWindow = unsafeBitCast(
            focusedWindowValue,
            to: AXUIElement.self
        )
        var subroleValue: CFTypeRef?
        var minimizedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedWindow, kAXSubroleAttribute as CFString, &subroleValue
        ) == .success,
        subroleValue as? String == kAXStandardWindowSubrole,
        AXUIElementCopyAttributeValue(
            focusedWindow, kAXMinimizedAttribute as CFString, &minimizedValue
        ) == .success,
        (minimizedValue as? NSNumber)?.boolValue == false else {
            return nil
        }
        return AccessibilityWindowIdentity.windowIdentifier(of: focusedWindow)
    }

    private static func windowInventory(
        for processIdentifier: pid_t
    ) -> WindowInventory? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
        let windows = windowsValue as? [AXUIElement] else {
            return nil
        }
        var focusedWindowValue: CFTypeRef?
        let focusedWindow: AXUIElement? = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success
            && focusedWindowValue.map(CFGetTypeID) == AXUIElementGetTypeID()
            ? unsafeBitCast(focusedWindowValue, to: AXUIElement.self)
            : nil

        let windowServerRecords = (CGWindowListCopyWindowInfo(
            .optionAll, kCGNullWindowID
        ) as? [[CFString: Any]]) ?? []
        var onScreenIdentifiers = Set<UInt32>()
        var documentSizedIdentifiers = Set<UInt32>()
        for record in windowServerRecords {
            guard (record[kCGWindowOwnerPID] as? NSNumber)?.int32Value
                    == processIdentifier,
                  (record[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  let identifier =
                    (record[kCGWindowNumber] as? NSNumber)?.uint32Value,
                  identifier > 0,
                  ((record[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 0) > 0,
                  let bounds = record[kCGWindowBounds] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber,
                  width.doubleValue >= 200, height.doubleValue >= 200 else {
                continue
            }
            documentSizedIdentifiers.insert(identifier)
            if (record[kCGWindowIsOnscreen] as? NSNumber)?.boolValue == true {
                onScreenIdentifiers.insert(identifier)
            }
        }

        var descriptors: [DesktopWindowDescriptor] = []
        var listedIdentifiers = Set<UInt32>()
        for (accessibilityOrder, window) in windows.enumerated() {
            AXUIElementSetMessagingTimeout(window, 0.5)
            var subroleValue: CFTypeRef?
            var minimizedValue: CFTypeRef?
            var mainValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                window, kAXSubroleAttribute as CFString, &subroleValue
            )
            _ = AXUIElementCopyAttributeValue(
                window, kAXMinimizedAttribute as CFString, &minimizedValue
            )
            _ = AXUIElementCopyAttributeValue(
                window, kAXMainAttribute as CFString, &mainValue
            )
            let windowIdentifier =
                AccessibilityWindowIdentity.windowIdentifier(of: window)
            if let windowIdentifier {
                listedIdentifiers.insert(windowIdentifier)
            }
            descriptors.append(
                DesktopWindowDescriptor(
                    accessibilityOrder: accessibilityOrder,
                    windowIdentifier: windowIdentifier,
                    isStandardWindow:
                        subroleValue as? String == kAXStandardWindowSubrole,
                    isMinimized:
                        (minimizedValue as? NSNumber)?.boolValue ?? false,
                    isMainWindow: (mainValue as? NSNumber)?.boolValue ?? false,
                    isFocusedWindow: focusedWindow.map {
                        CFEqual($0, window)
                    } ?? false,
                    isOnScreen: windowIdentifier.map {
                        onScreenIdentifiers.contains($0)
                    } ?? false
                )
            )
        }
        // Accessibility lists only the current Space plus the Dock. A
        // document-sized window the window server knows about but AX does not
        // list is open on another Space.
        let openWindowCountOnOtherSpaces = documentSizedIdentifiers
            .subtracting(listedIdentifiers)
            .subtracting(onScreenIdentifiers)
            .count
        return WindowInventory(
            descriptors: descriptors,
            elements: windows,
            openWindowCountOnOtherSpaces: openWindowCountOnOtherSpaces
        )
    }

    private static func raise(
        _ window: AXUIElement,
        restoringFromDock: Bool
    ) -> Bool {
        commitVisibleEffect {
            if restoringFromDock,
               AXUIElementSetAttributeValue(
                   window,
                   kAXMinimizedAttribute as CFString,
                   kCFBooleanFalse
               ) != .success {
                return false
            }
            _ = AXUIElementSetAttributeValue(
                window,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            return AXUIElementPerformAction(
                window,
                kAXRaiseAction as CFString
            ) == .success
        }
    }

    /// Activates exactly one process (never "all windows": that reorders the
    /// application's other documents) and accepts success only once that
    /// process is frontmost AND its focused standard window is the bound one.
    /// With no expected identifier the focused window after the Space switch
    /// becomes the binding.
    private static func verifiedFocusedWindow(
        application: NSRunningApplication,
        expectedWindowIdentifier: UInt32?
    ) async -> UInt32? {
        let processIdentifier = application.processIdentifier
        let deadline = Date().addingTimeInterval(6)
        var nextActivationAttempt = Date.distantPast
        repeat {
            guard !StealthEntryLatch.shared.isRaised,
                  !StealthVisibilityGate.shared.isActive,
                  !application.isTerminated else {
                return nil
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processIdentifier,
               let focusedWindowIdentifier =
                focusedStandardWindowIdentifier(for: processIdentifier),
               expectedWindowIdentifier.map({
                   $0 == focusedWindowIdentifier
               }) ?? true {
                return focusedWindowIdentifier
            }
            if Date() >= nextActivationAttempt {
                guard commitVisibleEffect({
                    _ = application.unhide()
                    _ = application.activate(options: [])
                    return true
                }) else {
                    return nil
                }
                nextActivationAttempt = Date().addingTimeInterval(0.35)
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return nil
    }

    /// Opens one URL already frozen at admission, then accepts success only
    /// after a supported browser is frontmost with an on-screen window whose
    /// accessibility tree contains the requested host. LaunchServices alone
    /// is never reported as a completed navigation.
    static func openFrozenWebsite(
        _ urlString: String,
        browserBundleIdentifier: String? = nil
    ) async -> BrowserNavigationResult? {
        guard let url = URL(string: urlString),
              let expectedHost = url.host?.lowercased(),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        if let browserBundleIdentifier {
            guard supportedBrowserBundleIdentifiers.contains(browserBundleIdentifier),
                  let applicationURL = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: browserBundleIdentifier
                  ) else { return nil }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            guard commitVisibleEffect({
                NSWorkspace.shared.open(
                    [url], withApplicationAt: applicationURL,
                    configuration: configuration,
                    completionHandler: { _, _ in }
                )
                return true
            }) else { return nil }
        } else {
            guard commitVisibleEffect({ NSWorkspace.shared.open(url) }) else { return nil }
        }

        let deadline = Date().addingTimeInterval(6)
        var observedBrowserName: String?
        repeat {
            guard !StealthEntryLatch.shared.isRaised,
                  !StealthVisibilityGate.shared.isActive else {
                return nil
            }
            if let browser = NSWorkspace.shared.frontmostApplication,
               isSupportedBrowser(browser),
               browserBundleIdentifier == nil || browser.bundleIdentifier == browserBundleIdentifier,
               hasOnScreenWindow(processIdentifier: browser.processIdentifier) {
                observedBrowserName = browser.localizedName
                if accessibilityTree(
                    for: browser.processIdentifier,
                    containsHost: expectedHost
                ) {
                    let browserName = browser.localizedName ?? "the browser"
                    appendSwitchLog(
                        "WEB-NAV verified browser=\(browserName) host=\(expectedHost)"
                    )
                    return BrowserNavigationResult(
                        spokenConfirmation:
                            "\(expectedHost) is open in \(browserName), frontmost, and visible.",
                        browserName: browser.localizedName,
                        verifiedVisibleTarget: true
                    )
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline

        appendSwitchLog(
            "WEB-NAV verification FAILED host=\(expectedHost)"
        )
        return BrowserNavigationResult(
            spokenConfirmation:
                "macos accepted the website request, but i could not verify \(expectedHost) in a frontmost visible browser window.",
            browserName: observedBrowserName,
            verifiedVisibleTarget: false
        )
    }

    private static let supportedBrowserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.brave.Browser",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
    ]

    private static func isSupportedBrowser(
        _ application: NSRunningApplication
    ) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else {
            return false
        }
        return supportedBrowserBundleIdentifiers.contains(bundleIdentifier)
    }

    private static func runningApplication(
        at applicationURL: URL
    ) async -> NSRunningApplication? {
        let wantedPath = applicationURL.standardizedFileURL
            .resolvingSymlinksInPath().path
        let deadline = Date().addingTimeInterval(6)
        repeat {
            if let application = NSWorkspace.shared.runningApplications
                .first(where: {
                    $0.bundleURL?.standardizedFileURL
                        .resolvingSymlinksInPath().path == wantedPath
                }) {
                return application
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return nil
    }

    private static func verifiedFrontmostWindowCount(
        processIdentifier: pid_t,
        application: NSRunningApplication? = nil
    ) async -> Int? {
        let deadline = Date().addingTimeInterval(6)
        var nextActivationAttempt = Date.distantPast
        repeat {
            guard !StealthEntryLatch.shared.isRaised,
                  !StealthVisibilityGate.shared.isActive else {
                return nil
            }
            if let count = frontmostVisibleWindowCount(
                processIdentifier: processIdentifier
            ) {
                return count
            }
            // LaunchServices may accept an activation while a capture app
            // immediately takes keyboard ownership back. Reassert activation
            // at a bounded cadence until the same process owns the frontmost
            // visible layer; every retry remains ordered with Private Mode.
            if let application,
               !application.isTerminated,
               Date() >= nextActivationAttempt {
                guard commitVisibleEffect({
                    _ = application.activate(options: [.activateAllWindows])
                    return true
                }) else {
                    return nil
                }
                nextActivationAttempt = Date().addingTimeInterval(0.35)
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return nil
    }

    /// CGWindow records are z-ordered and process-external. They remain exact
    /// when the desktop action helper and the resident menu-bar app share
    /// Ace's bundle identity, a case where NSWorkspace can report the resident
    /// Ace process instead of the visibly frontmost target.
    private static func frontmostVisibleWindowCount(
        processIdentifier: pid_t
    ) -> Int? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return nil
        }
        let visibleWindows = windows.filter { window in
            guard let layer = window[kCGWindowLayer] as? NSNumber,
                  layer.intValue == 0,
                  let bounds = window[kCGWindowBounds] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber else {
                return false
            }
            return width.doubleValue >= 120 && height.doubleValue >= 80
        }
        guard let frontmostOwner = visibleWindows.first?[kCGWindowOwnerPID]
                as? NSNumber,
              frontmostOwner.int32Value == processIdentifier else {
            return nil
        }
        return visibleWindows.reduce(into: 0) { count, window in
            if (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value
                == processIdentifier {
                count += 1
            }
        }
    }

    private static func hasOnScreenWindow(
        processIdentifier: pid_t
    ) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return false
        }
        return windows.contains { window in
            guard let owner = window[kCGWindowOwnerPID] as? NSNumber,
                  owner.int32Value == processIdentifier,
                  let layer = window[kCGWindowLayer] as? NSNumber,
                  layer.intValue == 0,
                  let bounds = window[kCGWindowBounds] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber else {
                return false
            }
            return width.doubleValue >= 120 && height.doubleValue >= 80
        }
    }

    private static func accessibilityTree(
        for processIdentifier: pid_t,
        containsHost expectedHost: String
    ) -> Bool {
        let normalizedHost = expectedHost
            .replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
        let application = AXUIElementCreateApplication(processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let window = windowValue as! AXUIElement? else {
            return false
        }
        var remainingNodes = 1_500
        return accessibilityElement(
            window,
            containsHost: normalizedHost,
            depth: 0,
            remainingNodes: &remainingNodes
        )
    }

    private static func accessibilityElement(
        _ element: AXUIElement,
        containsHost expectedHost: String,
        depth: Int,
        remainingNodes: inout Int
    ) -> Bool {
        guard depth <= 12, remainingNodes > 0 else { return false }
        remainingNodes -= 1
        for attribute in [
            kAXValueAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
        ] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            ) == .success,
            let string = value as? String {
                let normalized = string.lowercased()
                    .replacingOccurrences(
                        of: #"www\."#,
                        with: "",
                        options: .regularExpression
                    )
                if normalized.contains(expectedHost) {
                    return true
                }
            }
        }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement] else {
            return false
        }
        for child in children where accessibilityElement(
            child,
            containsHost: expectedHost,
            depth: depth + 1,
            remainingNodes: &remainingNodes
        ) {
            return true
        }
        return false
    }

    /// A running-but-windowless app activates into… nothing visible ("open
    /// notes" claimed success while no window appeared). Firing the reopen
    /// event — the same thing clicking its Dock icon does — makes such an app
    /// materialize its default window; apps that already have windows are
    /// unaffected.
    private static func reopenSoAWindowExists(
        _ runningApp: NSRunningApplication
    ) -> Bool {
        let existingDocument = prepareExistingDocumentWindow(runningApp)
        if existingDocument || hasOnScreenWindow(
            processIdentifier: runningApp.processIdentifier
        ) {
            // A bundle-URL reopen can asynchronously activate a different
            // running Chrome instance after the selected document was raised.
            // Existing documents need only exact-process activation.
            return commitVisibleEffect {
                _ = runningApp.unhide()
                _ = runningApp.activate(options: [.activateAllWindows])
                return true
            }
        }
        guard let bundleURL = runningApp.bundleURL else { return true }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return commitVisibleEffect {
            let request: Void = NSWorkspace.shared.openApplication(
                at: bundleURL,
                configuration: configuration
            )
            _ = request
            // Some always-on-top capture applications accept the workspace
            // reopen while retaining keyboard ownership. Explicit activation
            // makes the requested app the actual frontmost input target; its
            // verified window check below remains the postcondition.
            _ = runningApp.activate(options: [.activateAllWindows])
            return true
        }
    }

    private static func prepareExistingDocumentWindow(
        _ runningApp: NSRunningApplication
    ) -> Bool {
        guard !hasOnScreenWindow(
            processIdentifier: runningApp.processIdentifier
        ) else { return false }
        let application = AXUIElementCreateApplication(
            runningApp.processIdentifier
        )
        AXUIElementSetMessagingTimeout(application, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXWindowsAttribute as CFString, &value
        ) == .success,
              let windows = value as? [AXUIElement] else { return false }
        // Activation alone leaves a minimized Chrome document in the Dock.
        // Restore one standard window belonging to the selected process;
        // never raise another profile or expand every minimized window.
        for window in windows.prefix(4) {
            AXUIElementSetMessagingTimeout(window, 0.1)
            var subrole: CFTypeRef?
            var minimized: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window, kAXSubroleAttribute as CFString, &subrole
            ) == .success,
                  subrole as? String == kAXStandardWindowSubrole,
                  AXUIElementCopyAttributeValue(
                    window, kAXMinimizedAttribute as CFString, &minimized
                  ) == .success,
                  let wasMinimized = (minimized as? NSNumber)?.boolValue else {
                continue
            }
            if wasMinimized {
                guard commitVisibleEffect({
                    AXUIElementSetAttributeValue(
                        window, kAXMinimizedAttribute as CFString, kCFBooleanFalse
                    ) == .success
                }) else { return false }
            }
            _ = commitVisibleEffect {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    == .success
            }
            if wasMinimized {
                appendSwitchLog(
                    "SWITCH restored minimized document pid=\(runningApp.processIdentifier)"
                )
            }
            return true
        }
        return false
    }

    /// The Private Mode event tap raises the same latch. Each AppKit/Workspace commit is
    /// therefore totally ordered with entry: either the complete request wins
    /// first, or no request reaches macOS after X has won.
    private static func commitVisibleEffect(
        _ effect: @escaping () -> Bool
    ) -> Bool {
        AppSwitcherEffectAdmission.commit(
            visibilityIsBlocked: {
                Task.isCancelled || StealthVisibilityGate.shared.isActive
            },
            performUnlessRaised: { body in
                StealthEntryLatch.shared.performUnlessRaised(body)
            },
            effect: effect
        )
    }

    /// Resolve WITHOUT activating — for "find but don't open": names the app
    /// if it's running or installed, launches nothing.
    static func installedAppName(matching rawName: String) -> String? {
        let wanted = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wanted.count >= 2,
              case .matched(let resolution) =
                resolveApp(named: wanted.lowercased()) else {
            return nil
        }
        switch resolution {
        case .running(let app): return app.localizedName
        case .installed(_, let name): return name
        }
    }

    /// Same durable receipt channel as the worker — proves by log, not self-report.
    private static func appendSwitchLog(_ message: String) {
        _ = commitVisibleEffect {
            guard let directory = FileManager.default
                .urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first?
                .appendingPathComponent(
                    "BlackLabel",
                    isDirectory: true
                ) else {
                return false
            }
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let safeMessage = message
                .components(separatedBy: .newlines)
                .joined(separator: "\\n")
                .unicodeScalars
                .map {
                    CharacterSet.controlCharacters.contains($0)
                        ? " "
                        : String($0)
                }
                .joined()
            let line =
                "\(ISO8601DateFormatter().string(from: Date())) \(safeMessage)\n"
            let fileURL = directory.appendingPathComponent("agent.log")
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(
                    to: fileURL,
                    options: .atomic
                )
            }
            return true
        }
    }

    private enum Resolution {
        case running(NSRunningApplication)
        case installed(URL, String)
    }

    private enum ResolutionOutcome {
        case matched(Resolution)
        case notFound
        case ambiguous
    }

    private enum MatchOutcome<Value> {
        case matched(String, Value)
        case notFound
        case ambiguous
    }

    /// Includes ordinary nested installs such as Utilities and Chrome Apps,
    /// without descending into app bundles, hidden backups, or arbitrary disks.
    static func installedApplications(in roots: [URL]) -> [(String, URL)] {
        let fileManager = FileManager.default
        var applications: [(String, URL)] = []
        var seen = Set<String>()
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "app" {
                    enumerator.skipDescendants()
                    let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                    guard seen.insert(canonical.path).inserted,
                          let bundle = Bundle(url: canonical),
                          bundle.bundleIdentifier != nil else { continue }
                    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    guard !name.isEmpty else { continue }
                    applications.append((name, canonical))
                } else if enumerator.level >= 3 {
                    enumerator.skipDescendants()
                }
            }
        }
        return applications
    }

    private static func resolveApp(named rawName: String) -> ResolutionOutcome {
        let wantedName = rawName.lowercased()
        // Score running and installed apps together. Searching running apps
        // first let a fuzzy Gmail match beat an exact installed Mail match.
        let regularRunningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        let runningGroups = Dictionary(grouping: regularRunningApps) { app in
            app.bundleURL?.standardizedFileURL
                .resolvingSymlinksInPath().path
                ?? app.bundleIdentifier
                ?? "pid:\(app.processIdentifier)"
        }
        let windowInfo = (CGWindowListCopyWindowInfo(
            .optionAll, kCGNullWindowID
        ) as? [[String: Any]]) ?? []
        let runningCandidates: [(String, Resolution)] =
            runningGroups.values.compactMap { instances in
                // Multiple Chrome profiles and automation sessions can share
                // one bundle URL. The oldest PID is often a windowless helper
                // instance. Prefer the active/visible document-owning instance.
                let ranked = instances.map { application in
                    let windows = windowInfo.filter {
                        ($0[kCGWindowOwnerPID as String] as? Int32)
                            == application.processIdentifier
                            && ($0[kCGWindowLayer as String] as? Int) == 0
                    }
                    var largestArea = 0.0
                    var largestVisibleArea = 0.0
                    for window in windows {
                        guard let bounds = window[kCGWindowBounds as String]
                                as? [String: Any],
                              let width = bounds["Width"] as? Double,
                              let height = bounds["Height"] as? Double,
                              width >= 200, height >= 200 else { continue }
                        largestArea = max(largestArea, width * height)
                        if window[kCGWindowIsOnscreen as String] as? Bool == true {
                            largestVisibleArea = max(largestVisibleArea, width * height)
                        }
                    }
                    return AppSwitcherRunningInstance(
                        processIdentifier: application.processIdentifier,
                        isActive: application.isActive,
                        visibleWindowArea: largestVisibleArea,
                        documentWindowArea: largestArea
                    )
                }
                guard let identifier = AppSwitcherRunningInstance.preferred(in: ranked),
                      let app = instances.first(where: { $0.processIdentifier == identifier }),
                      let name = app.localizedName else { return nil }
                return (name, .running(app))
            }
        // Installed apps include the Desktop, where Black Label Studio may live
        // on development machines.
        let installedCandidates = installedApplications(in: [
            "/Applications", "/System/Applications",
            NSHomeDirectory() + "/Applications", NSHomeDirectory() + "/Desktop",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) })

        // An app that is currently running also appears in an Applications
        // directory. Collapse only that same on-disk bundle. Two distinct
        // bundles or two running instances with the same normalized identity
        // remain separate candidates and therefore fail as ambiguous.
        let runningBundlePaths: Set<String> = Set(
            regularRunningApps.compactMap { app in
                app.bundleURL?.standardizedFileURL
                    .resolvingSymlinksInPath().path
            }
        )
        var candidates: [(String, Resolution)] = installedCandidates.compactMap {
            name, url in
            let canonicalURL =
                url.standardizedFileURL.resolvingSymlinksInPath()
            guard !runningBundlePaths.contains(canonicalURL.path) else {
                return nil
            }
            return (name, .installed(url, name))
        }
        candidates.append(contentsOf: runningCandidates)

        switch match(candidates, wanted: wantedName) {
        case .matched(_, let resolution):
            return .matched(resolution)
        case .notFound:
            return .notFound
        case .ambiguous:
            return .ambiguous
        }
    }

    /// STT delivers number WORDS while app names carry digits — "agent zero"
    /// must match "Agent 0". Both sides of every comparison go through this.
    private static func normalizedForMatching(_ name: String) -> String {
        var normalized = name.lowercased()
        let numberWordsByDigit = [
            ("zero", "0"), ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"),
            ("five", "5"), ("six", "6"), ("seven", "7"), ("eight", "8"), ("nine", "9"), ("ten", "10"),
        ]
        for (word, digit) in numberWordsByDigit {
            normalized = normalized.replacingOccurrences(
                of: #"\b\#(word)\b"#, with: digit, options: .regularExpression)
        }
        return normalized
    }

    /// exact > prefix > contains (either direction). Equal-scoring different
    /// names are ambiguous and fail closed instead of silently picking one.
    static func bestMatch<Value>(
        _ candidates: [(String, Value)], wanted rawWantedName: String
    ) -> (String, Value)? {
        guard case .matched(let name, let value) =
                match(candidates, wanted: rawWantedName) else {
            return nil
        }
        return (name, value)
    }

    private static func match<Value>(
        _ candidates: [(String, Value)], wanted rawWantedName: String
    ) -> MatchOutcome<Value> {
        let wantedName = normalizedForMatching(rawWantedName)
        var matches: [(score: Int, name: String, value: Value)] = []
        for (candidateName, value) in candidates {
            let lowercasedName = normalizedForMatching(candidateName)
            let score: Int
            if lowercasedName == wantedName {
                score = 3
            } else if lowercasedName.hasPrefix(wantedName) || wantedName.hasPrefix(lowercasedName) {
                score = 2
            } else if lowercasedName.contains(wantedName) {
                score = 1
            } else if wantedName.contains(lowercasedName),
                      lowercasedName.count >= 5,
                      wantedName.split(separator: " ").count <= 3 {
                // Reverse containment only for substantial names in short asks,
                // so "what apps are open" can never resolve to Apps.app.
                score = 1
            } else {
                continue
            }
            matches.append((score, candidateName, value))
        }

        let exactMatches = matches.filter { $0.score == 3 }
        if exactMatches.count == 1, let exactMatch = exactMatches.first {
            return .matched(exactMatch.name, exactMatch.value)
        }
        if exactMatches.count > 1 {
            return .ambiguous
        }
        guard !matches.isEmpty else { return .notFound }
        guard matches.count == 1, let onlyMatch = matches.first else {
            return .ambiguous
        }
        return .matched(onlyMatch.name, onlyMatch.value)
    }
}

/// Value-only ranking used by the real app resolver and its regression test.
nonisolated struct AppSwitcherRunningInstance {
    let processIdentifier: Int32
    let isActive: Bool
    let visibleWindowArea: Double
    let documentWindowArea: Double

    static func preferred(in candidates: [Self]) -> Int32? {
        candidates.max { lhs, rhs in
            // WindowServer ownership is authoritative when LaunchServices
            // labels a windowless duplicate as the active bundle instance.
            let lhsHasVisibleDocument = lhs.visibleWindowArea > 0
            let rhsHasVisibleDocument = rhs.visibleWindowArea > 0
            if lhsHasVisibleDocument != rhsHasVisibleDocument {
                return !lhsHasVisibleDocument
            }
            if !lhsHasVisibleDocument,
               lhs.documentWindowArea != rhs.documentWindowArea {
                return lhs.documentWindowArea < rhs.documentWindowArea
            }
            if lhs.isActive != rhs.isActive { return !lhs.isActive }
            if lhs.visibleWindowArea != rhs.visibleWindowArea {
                return lhs.visibleWindowArea < rhs.visibleWindowArea
            }
            if lhs.documentWindowArea != rhs.documentWindowArea {
                return lhs.documentWindowArea < rhs.documentWindowArea
            }
            return lhs.processIdentifier > rhs.processIdentifier
        }?.processIdentifier
    }
}
#endif // circuit-convert
