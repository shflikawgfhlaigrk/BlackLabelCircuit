#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  DesktopActionSystemBackend.swift
//  Ace
//
//  Live macOS implementation for the provider-neutral desktop boundary.
//

#if canImport(ApplicationServices) && !CIRCUIT_WINDOWS_SIM
import ApplicationServices
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
import Foundation

@MainActor
final class DesktopActionSystemBackend: DesktopActionBackend {
    typealias VisualPointResolver = @MainActor (String) async -> CGPoint?

    private struct FocusSnapshot {
        let element: AXUIElement
        let token: String
        let processIdentifier: pid_t
        /// Exact window-server identifier of the window that contains the
        /// focused element. It is part of `token`, so every existing
        /// same-token check also proves the text is still going into the
        /// same window, not merely the same application.
        let windowIdentifier: UInt32?
        let applicationName: String
        let bundleIdentifier: String?
        let role: String
        let subrole: String
        let value: String?
        let selectedTextRange: NSRange?
    }

    private struct ClickTargetSnapshot: Equatable {
        let processIdentifier: pid_t
        let windowNumber: UInt32?
        let role: String?
        let subrole: String?
        let identifier: String?
        let title: String?
        let value: String?
        let selected: Bool?
        let enabled: Bool?
    }

    private struct ClickObservation: Equatable {
        let frontmostProcessIdentifier: pid_t?
        let focusedWindowNumber: UInt32?
        let focusedWindowTitle: String?
        let focusedElementIdentity: CFHashCode?
        let target: ClickTargetSnapshot?
    }

    private enum TextPostingResult {
        case completed
        case completedExact(String)
        /// Characters were delivered as key events; some may have landed
        /// before a later focus check failed.
        case unobserved
        case focusChanged
        case blockedByStealth
    }

    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    // AX hashes can collide. Retain a small set of real element identities so
    // a token cannot transfer to a different tab's field with the same hash.
    private static var focusedElementIdentities:
        [(element: AXUIElement, token: String)] = []

    private static func token(for element: AXUIElement) -> String {
        if let retained = focusedElementIdentities.first(where: {
            CFEqual($0.element, element)
        }) {
            return retained.token
        }
        let token = UUID().uuidString
        focusedElementIdentities.append((element, token))
        if focusedElementIdentities.count > 64 {
            focusedElementIdentities.removeFirst()
        }
        return token
    }

    private let visualPointResolver: VisualPointResolver?
    private let isAllowed: @MainActor () -> Bool
    var textDeliveryDiagnostic: @MainActor (String) -> Void = { _ in }

    init(
        visualPointResolver: VisualPointResolver? = nil,
        isAllowed: @escaping @MainActor () -> Bool = { true }
    ) {
        self.visualPointResolver = visualPointResolver
        self.isAllowed = isAllowed
    }

    func currentFrontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func currentFocusedEditableElementToken() -> String? {
        guard let snapshot = Self.focusSnapshot(),
              !Self.isSecure(snapshot),
              Self.isEditable(snapshot),
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == snapshot.processIdentifier else {
            return nil
        }
        return snapshot.token
    }

    func openApplicationWindowForTyping(
        named exactName: String
    ) async -> DesktopWindowOpenResult {
        guard let activation =
                await AppSwitcher.activateFrozenCandidateWindow(exactName)
        else {
            return .unavailable(
                "the installed application identity changed before opening. say the exact application name and i will continue the same request."
            )
        }
        switch activation {
        case .bound(let result):
            return .bound(
                requestedApplicationName: exactName,
                resolvedApplicationName: result.resolvedApplicationName,
                bundleIdentifier: result.bundleIdentifier,
                windowIdentifier: result.windowIdentifier
            )
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    func currentFocusedEditableElementToken(
        inWindow windowIdentifier: UInt32
    ) -> String? {
        guard windowIdentifier > 0,
              let snapshot = Self.focusSnapshot(),
              !Self.isSecure(snapshot),
              Self.isEditable(snapshot),
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == snapshot.processIdentifier,
              // The focused element must live in the bound window...
              snapshot.windowIdentifier == windowIdentifier,
              // ...and that window must still be the one the application
              // itself reports as focused, so a sheet or a second document
              // that took key status cannot inherit the binding.
              AppSwitcher.focusedStandardWindowIdentifier(
                for: snapshot.processIdentifier
              ) == windowIdentifier else {
            return nil
        }
        return snapshot.token
    }

    func openApplication(named exactName: String) async -> DesktopOpenResult {
        guard let result = await AppSwitcher.handleFrozenCandidate(exactName)
        else {
            return .unavailable(
                "the installed application identity changed before opening. say the exact application name and i will continue the same request."
            )
        }
        guard result.verifiedVisible,
              result.visibleWindowCount > 0 else {
            return .unavailable(result.spokenConfirmation)
        }
        return .observed(
            requestedApplicationName: exactName,
            resolvedApplicationName: result.resolvedApplicationName,
            frontmostApplicationName: result.resolvedApplicationName,
            frontmostBundleIdentifier: result.bundleIdentifier,
            visibleWindowCount: result.visibleWindowCount
        )
    }

    /// Makes the current, already-bound app ready for an exact typing action.
    /// Some document apps reopen into an Open panel instead of an editor. A
    /// modal-cancel followed by Command-N is the universal keyboard path back
    /// to a fresh editable surface; every commit is ordered with Private Mode
    /// entry and success requires a same-app editable-focus observation.
    func ensureEditableSurface() async -> DesktopTypingResult {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier > 0 else {
            return .unavailable("there is no exact frontmost application")
        }
        let processIdentifier = application.processIdentifier
        let applicationName = application.localizedName ?? "the focused app"

        if let current = Self.focusSnapshot(),
           current.processIdentifier == processIdentifier,
           !Self.isSecure(current),
           Self.isEditable(current) {
            return Self.verifiedEditableSurface(
                current,
                applicationName: applicationName
            )
        }

        if let focused = await Self.focusBestEditableCandidate(
            in: processIdentifier
        ) {
            return Self.verifiedEditableSurface(
                focused,
                applicationName: applicationName
            )
        }

        guard Self.postShortcut(
            keyCode: 53,
            flags: [],
            processIdentifier: processIdentifier
        ) else {
            return StealthEntryLatch.shared.isRaised
                ? .blockedByStealth
                : .focusChanged(applicationName: applicationName)
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processIdentifier else {
            return .focusChanged(applicationName: applicationName)
        }

        if let current = Self.focusSnapshot(),
           current.processIdentifier == processIdentifier,
           !Self.isSecure(current),
           Self.isEditable(current) {
            return Self.verifiedEditableSurface(
                current,
                applicationName: applicationName
            )
        }

        if let focused = await Self.focusBestEditableCandidate(
            in: processIdentifier
        ) {
            return Self.verifiedEditableSurface(
                focused,
                applicationName: applicationName
            )
        }

        guard Self.postShortcut(
            keyCode: 45,
            flags: .maskCommand,
            processIdentifier: processIdentifier
        ) else {
            return StealthEntryLatch.shared.isRaised
                ? .blockedByStealth
                : .focusChanged(applicationName: applicationName)
        }

        let deadline = Date().addingTimeInterval(2.5)
        repeat {
            guard !StealthEntryLatch.shared.isRaised else {
                return .blockedByStealth
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == processIdentifier else {
                return .focusChanged(applicationName: applicationName)
            }
            if let current = Self.focusSnapshot(),
               current.processIdentifier == processIdentifier,
               !Self.isSecure(current),
               Self.isEditable(current) {
                return Self.verifiedEditableSurface(
                    current,
                    applicationName: applicationName
                )
            }
            if let focused = await Self.focusBestEditableCandidate(
                in: processIdentifier
            ) {
                return Self.verifiedEditableSurface(
                    focused,
                    applicationName: applicationName
                )
            }
            try? await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        return .noEditableFocus
    }

    func click(
        targetedBy exactDescription: String
    ) async -> DesktopClickResult {
        let point: CGPoint
        switch AccessibilityVisualTargetResolver.resolution(
            for: exactDescription
        ) {
        case .unique(let accessibilityPoint):
            point = accessibilityPoint
        case .ambiguous:
            return .ambiguous
        case .missing:
            guard let visualPointResolver,
                  let visualPoint = await visualPointResolver(
                    exactDescription
                  ) else {
                return .unavailable(
                    "no unique enabled control matched the exact target"
                )
            }
            point = visualPoint
        }

        return await executeBoundClick(at: point)
    }

    func typeText(
        _ exactText: String,
        expectedFocusedElementToken: String?
    ) async -> DesktopTypingResult {
        guard let before = Self.focusSnapshot() else {
            return .noEditableFocus
        }
        guard !Self.isSecure(before) else { return .secureField }
        guard Self.isEditable(before) else { return .noEditableFocus }
        guard expectedFocusedElementToken.map({ $0 == before.token }) ?? true
        else {
            return .focusChanged(applicationName: before.applicationName)
        }

        switch await Self.postText(
            exactText, into: before, isAllowed: isAllowed,
            diagnostic: textDeliveryDiagnostic
        ) {
        case .completedExact(let exactValue):
            return .verified(
                applicationName: before.applicationName,
                role: before.role,
                valueDigest: Self.digest(exactValue),
                characterCount: exactText.count
            )
        case .completed:
            // Native editors can commit their selection-aware AX replacement
            // asynchronously. Preserve the exact PID and focused-element token
            // while allowing that same bound editor a short observation window.
            let deadline = Date().addingTimeInterval(1.75)
            repeat {
                guard !StealthEntryLatch.shared.isRaised else {
                    return .blockedByStealth
                }
                guard let after = Self.focusSnapshot() else {
                    return .focusChanged(
                        applicationName: before.applicationName
                    )
                }
                switch DesktopTextValueObservationPolicy.decision(
                    beforeValue: before.value,
                    afterValue: after.value,
                    beforeSelectionRange: before.selectedTextRange,
                    afterSelectionRange: after.selectedTextRange,
                    insertedText: exactText,
                    sameBoundElement:
                        after.token == before.token
                            && after.processIdentifier
                                == before.processIdentifier
                ) {
                case .focusChanged:
                    return .focusChanged(
                        applicationName: before.applicationName
                    )
                case .changed(let afterValue):
                    return .verified(
                        applicationName: before.applicationName,
                        role: after.role,
                        valueDigest: Self.digest(afterValue),
                        characterCount: exactText.count
                    )
                case .pending:
                    break
                }
                usleep(25_000)
            } while Date() < deadline
            return .deliveredWithoutObservedChange(
                applicationName: before.applicationName
            )
        case .focusChanged:
            return .focusChanged(applicationName: before.applicationName)
        case .unobserved:
            return .deliveredWithoutObservedChange(
                applicationName: before.applicationName
            )
        case .blockedByStealth:
            return .blockedByStealth
        }
    }

    func pressKey(
        _ exactKey: String,
        expectedFocusedElementToken: String?
    ) -> DesktopTypingResult {
        guard let before = Self.focusSnapshot() else {
            return .noEditableFocus
        }
        guard !Self.isSecure(before) else { return .secureField }
        guard Self.isEditable(before) else { return .noEditableFocus }
        guard expectedFocusedElementToken.map({ $0 == before.token }) ?? true
        else {
            return .focusChanged(applicationName: before.applicationName)
        }
        switch Self.postKey(exactKey, into: before) {
        case .blockedByStealth:
            return .blockedByStealth
        case .focusChanged:
            return .focusChanged(applicationName: before.applicationName)
        case .completed:
            break
        case .completedExact, .unobserved:
            return .deliveredWithoutObservedChange(
                applicationName: before.applicationName
            )
        }
        guard let after = Self.focusSnapshot() else {
            return .deliveredWithoutObservedChange(
                applicationName: before.applicationName
            )
        }
        let changed = after.token != before.token || after.value != before.value
        guard changed else {
            return .deliveredWithoutObservedChange(
                applicationName: before.applicationName
            )
        }
        return .verified(
            applicationName: before.applicationName,
            role: after.role,
            valueDigest: Self.digest(after.value ?? after.token),
            characterCount: 1
        )
    }

    private static func focusSnapshot() -> FocusSnapshot? {
        let element: AXUIElement
        var value: CFTypeRef?
        if let frontmostProcessIdentifier = NSWorkspace.shared
            .frontmostApplication?.processIdentifier,
           frontmostProcessIdentifier > 0,
           AXUIElementCopyAttributeValue(
               AXUIElementCreateApplication(frontmostProcessIdentifier),
               kAXFocusedUIElementAttribute as CFString,
               &value
           ) == .success,
           let value,
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            element = unsafeBitCast(value, to: AXUIElement.self)
        } else {
            value = nil
            guard AXUIElementCopyAttributeValue(
                AXUIElementCreateSystemWide(),
                kAXFocusedUIElementAttribute as CFString,
                &value
            ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            element = unsafeBitCast(value, to: AXUIElement.self)
        }
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier > 0 else {
            return nil
        }
        let role = stringAttribute(kAXRoleAttribute, of: element) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute, of: element) ?? ""
        let identifier = stringAttribute(
            kAXIdentifierAttribute,
            of: element
        ) ?? ""
        let runningApplication = NSRunningApplication(
            processIdentifier: processIdentifier
        )
        let windowIdentifier = containingWindowIdentifier(of: element)
        return FocusSnapshot(
            element: element,
            token:
                "\(processIdentifier):w\(windowIdentifier ?? 0):\(token(for: element)):\(role):\(identifier)",
            processIdentifier: processIdentifier,
            windowIdentifier: windowIdentifier,
            applicationName: runningApplication?.localizedName
                ?? "the focused app",
            bundleIdentifier: runningApplication?.bundleIdentifier,
            role: role,
            subrole: subrole,
            value: semanticAttribute(kAXValueAttribute, of: element),
            selectedTextRange: selectedTextRange(of: element)
        )
    }

    /// Focus one high-confidence editable descendant of the focused window.
    /// A tied best score is rejected instead of guessing between editors.
    private static func focusBestEditableCandidate(
        in processIdentifier: pid_t
    ) async -> FocusSnapshot? {
        guard !StealthEntryLatch.shared.isRaised,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processIdentifier else {
            return nil
        }
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let focusedWindow = elementAttribute(
            kAXFocusedWindowAttribute,
            of: application
        ) else {
            return nil
        }

        var queue: [AXUIElement] = [focusedWindow]
        var cursor = 0
        var visited = 0
        var candidates: [(score: Int, element: AXUIElement)] = []
        while cursor < queue.count, visited < 2_500 {
            let element = queue[cursor]
            cursor += 1
            visited += 1
            let role = stringAttribute(kAXRoleAttribute, of: element) ?? ""
            let subrole = stringAttribute(
                kAXSubroleAttribute,
                of: element
            ) ?? ""
            if role != "AXSecureTextField",
               subrole != "AXSecureTextField",
               boolAttribute(kAXEnabledAttribute, of: element) != false,
               boolAttribute(kAXHiddenAttribute, of: element) != true {
                var valueSettable = DarwinBoolean(false)
                let isValueSettable =
                    AXUIElementIsAttributeSettable(
                        element,
                        kAXValueAttribute as CFString,
                        &valueSettable
                    ) == .success && valueSettable.boolValue
                if editableRoles.contains(role) || isValueSettable {
                    let score: Int
                    switch role {
                    case "AXTextArea": score = 400
                    case "AXTextField": score = 300
                    case "AXComboBox": score = 200
                    case "AXSearchField": score = 100
                    default: score = 50
                    }
                    candidates.append((score, element))
                }
            }
            queue.append(contentsOf: elementArrayAttribute(
                kAXChildrenAttribute,
                of: element
            ))
        }

        guard let bestScore = candidates.map(\.score).max() else {
            return nil
        }
        let best = candidates.filter { $0.score == bestScore }
        guard best.count == 1 else { return nil }
        let target = best[0].element
        guard requestEditableFocus(
            target,
            processIdentifier: processIdentifier
        ) else {
            return nil
        }

        let deadline = Date().addingTimeInterval(1.25)
        repeat {
            guard !StealthEntryLatch.shared.isRaised,
                  NSWorkspace.shared.frontmostApplication?
                    .processIdentifier == processIdentifier else {
                return nil
            }
            if let focused = focusSnapshot(),
               focused.processIdentifier == processIdentifier,
               !isSecure(focused),
               isEditable(focused),
               CFEqual(focused.element, target) {
                return focused
            }
            try? await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        return nil
    }

    private static func requestEditableFocus(
        _ target: AXUIElement,
        processIdentifier: pid_t
    ) -> Bool {
        var focusSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            target,
            kAXFocusedAttribute as CFString,
            &focusSettable
        ) == .success,
        focusSettable.boolValue,
        StealthEntryLatch.shared.performUnlessRaised({
            guard NSWorkspace.shared.frontmostApplication?
                    .processIdentifier == processIdentifier else {
                return false
            }
            return AXUIElementSetAttributeValue(
                target,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            ) == .success
        }) == true,
        let focused = focusSnapshot(),
        focused.processIdentifier == processIdentifier,
        CFEqual(focused.element, target) {
            return true
        }

        var actions: CFArray?
        if AXUIElementCopyActionNames(target, &actions) == .success,
           (actions as? [String])?.contains(
                kAXPressAction as String
           ) == true,
           StealthEntryLatch.shared.performUnlessRaised({
                guard NSWorkspace.shared.frontmostApplication?
                        .processIdentifier == processIdentifier else {
                    return false
                }
                return AXUIElementPerformAction(
                    target,
                    kAXPressAction as CFString
                ) == .success
           }) == true,
           let focused = focusSnapshot(),
           focused.processIdentifier == processIdentifier,
           CFEqual(focused.element, target) {
            return true
        }

        // A failed Accessibility focus request must never borrow the owner's
        // pointer. Physical pointer actions belong to the bound Private Mode path.
        return false
    }

    private func executeBoundClick(at point: CGPoint) async -> DesktopClickResult {
        guard point.x.isFinite, point.y.isFinite,
              let hitElement = Self.element(at: point),
              let hitSnapshot = Self.clickSnapshot(of: hitElement) else {
            return .unavailable("the target was no longer available")
        }
        let pressElement = Self.pressableElement(startingAt: hitElement)
        let actionElement = pressElement ?? hitElement
        guard let actionSnapshot = Self.clickSnapshot(of: actionElement),
              actionSnapshot.processIdentifier
                == hitSnapshot.processIdentifier else {
            return .unavailable("the target was no longer available")
        }
        let initialObservation = Self.clickObservation(
            target: actionElement,
            processIdentifier: actionSnapshot.processIdentifier
        )

        func targetIsCurrent() -> Bool {
            guard let currentHit = Self.element(at: point) else { return false }
            let currentAction = pressElement == nil
                ? currentHit
                : Self.pressableElement(startingAt: currentHit)
            guard let currentAction,
                  CFEqual(currentAction, actionElement),
                  let currentSnapshot = Self.clickSnapshot(
                    of: currentAction
                  ) else {
                return false
            }
            return currentSnapshot == actionSnapshot
        }

        guard targetIsCurrent() else { return .targetMoved }
        let delivered: Bool
        if pressElement != nil {
            delivered = AXUIElementPerformAction(
                actionElement,
                kAXPressAction as CFString
            ) == .success
        } else {
            return .unavailable("the control has no Accessibility press action; the pointer was left untouched")
        }

        guard delivered else {
            return .unavailable("macOS rejected the bound click")
        }

        let deadline = Date().addingTimeInterval(1.75)
        repeat {
            if Self.clickObservation(
                target: actionElement,
                processIdentifier: actionSnapshot.processIdentifier
            ) != initialObservation {
                return .verified(
                    applicationName:
                        NSRunningApplication(
                            processIdentifier:
                                actionSnapshot.processIdentifier
                        )?.localizedName ?? "the frontmost app"
                )
            }
            try? await Task.sleep(for: .milliseconds(75))
        } while Date() < deadline
        return .deliveredWithoutObservedChange
    }

    private static func postText(
        _ text: String,
        into target: FocusSnapshot,
        isAllowed: @MainActor () -> Bool,
        diagnostic: @MainActor (String) -> Void
    ) async -> TextPostingResult {
        guard !StealthEntryLatch.shared.isRaised else {
            return .blockedByStealth
        }
        // Claude and DOM-backed editors can retain stale hidden AX values after
        // a visible clear, so an EMPTY one still receives the exact requested
        // value. A NON-EMPTY editor is only ever inserted into: the exact
        // write erased whatever the owner had already written there. Exactly
        // one route is chosen up front and never chained, because a second
        // attempt after an unobserved first one could type the text twice.
        var selectedTextSettable = DarwinBoolean(false)
        let selectedTextIsSettable = AXUIElementIsAttributeSettable(
            target.element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        ) == .success && selectedTextSettable.boolValue
        let deliveryRoute = DesktopTextDeliveryPolicy.route(
            bundleIdentifier: target.bundleIdentifier,
            hasWebContentAncestor: hasWebContentAncestor(target.element),
            role: target.role,
            existingValueIsEmpty: target.value?.isEmpty == true,
            existingValueIsAvailable: target.value != nil,
            selectionRangeIsAvailable: target.selectedTextRange != nil,
            selectedTextIsSettable: selectedTextIsSettable
        )
        diagnostic(
            "route=\(deliveryRoute) pid=\(target.processIdentifier) "
                + "window=\(target.windowIdentifier ?? 0) "
                + "selected-text-settable=\(selectedTextIsSettable)"
        )
        switch deliveryRoute {
        case .accessibilityExactValue:
            return postExactTextThroughAccessibility(text, into: target)
        case .accessibilitySelectionInsertion:
            return postSelectionInsertionThroughAccessibility(
                text,
                into: target
            )
        case .unicodeKeyEvents:
            return await postTextThroughUnicodeKeyEvents(text, into: target, isAllowed: isAllowed)
        case .accessibilityValue:
            return postTextThroughAccessibility(text, into: target)
                ?? .unobserved
        }
    }

    /// Replaces only the current selection, exactly as dictation does. The
    /// caller observes the same bound element afterwards; nothing here reads
    /// or rewrites text outside the selection.
    private static func postSelectionInsertionThroughAccessibility(
        _ text: String,
        into target: FocusSnapshot
    ) -> TextPostingResult {
        guard StealthEntryLatch.shared.performUnlessRaised({
            guard focusStillMatches(target) else { return false }
            return AXUIElementSetAttributeValue(
                target.element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            ) == .success
        }) == true else {
            return StealthEntryLatch.shared.isRaised
                ? .blockedByStealth
                : .focusChanged
        }
        return .completed
    }

    private static func postTextThroughUnicodeKeyEvents(
        _ text: String,
        into target: FocusSnapshot,
        isAllowed: @MainActor () -> Bool
    ) async -> TextPostingResult {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let value = target.value,
              let selection = target.selectedTextRange else { return .unobserved }
        let result = await DesktopUnicodeTextDelivery.deliver(
            text,
            initial: .init(token: target.token, value: value, selection: selection),
            isAllowed: { isAllowed() && !StealthEntryLatch.shared.isRaised },
            observe: {
                guard focusStillMatches(target), let current = focusSnapshot(),
                      let value = current.value,
                      let selection = current.selectedTextRange else { return nil }
                return .init(token: current.token, value: value, selection: selection)
            },
            postScalar: { scalar in
                let units = Array(scalar.utf16)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    return false
                }
                down.flags = []
                up.flags = []
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                guard isAllowed() else { return false }
                return StealthEntryLatch.shared.performUnlessRaised {
                    guard focusStillMatches(target) else { return false }
                    down.postToPid(target.processIdentifier)
                    up.postToPid(target.processIdentifier)
                    return true
                } == true
            },
            waitForObservation: { try? await Task.sleep(for: .milliseconds(25)) }
        )
        switch result {
        case .verified(let value): return .completedExact(value)
        case .targetChanged: return .focusChanged
        case .unverified: return .unobserved
        case .cancelled:
            return StealthEntryLatch.shared.isRaised ? .blockedByStealth : .unobserved
        }
    }

    private static func postExactTextThroughAccessibility(
        _ text: String,
        into target: FocusSnapshot
    ) -> TextPostingResult {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            target.element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success,
        settable.boolValue else {
            return .unobserved
        }
        guard StealthEntryLatch.shared.performUnlessRaised({
            guard focusStillMatches(target) else { return false }
            return AXUIElementSetAttributeValue(
                target.element,
                kAXValueAttribute as CFString,
                text as CFString
            ) == .success
        }) == true else {
            return StealthEntryLatch.shared.isRaised
                ? .blockedByStealth
                : .focusChanged
        }

        let deadline = Date().addingTimeInterval(1.75)
        repeat {
            guard !StealthEntryLatch.shared.isRaised else {
                return .blockedByStealth
            }
            guard let current = focusSnapshot(),
                  current.token == target.token,
                  current.processIdentifier == target.processIdentifier else {
                return .focusChanged
            }
            if current.value == text {
                return .completedExact(text)
            }
            usleep(25_000)
        } while Date() < deadline
        return .unobserved
    }

    private static func postTextThroughAccessibility(
        _ text: String,
        into target: FocusSnapshot
    ) -> TextPostingResult? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            target.element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success,
        settable.boolValue else {
            return nil
        }

        guard let expected = DesktopTextValueObservationPolicy.expectedValue(
            beforeValue: target.value,
            selectionRange: target.selectedTextRange,
            insertedText: text
        ) else {
            return nil
        }
        guard StealthEntryLatch.shared.performUnlessRaised({
            guard focusStillMatches(target) else { return false }
            return AXUIElementSetAttributeValue(
                target.element,
                kAXValueAttribute as CFString,
                expected as CFString
            ) == .success
        }) == true else {
            return StealthEntryLatch.shared.isRaised
                ? .blockedByStealth
                : .focusChanged
        }

        let deadline = Date().addingTimeInterval(1.75)
        repeat {
            guard !StealthEntryLatch.shared.isRaised else {
                return .blockedByStealth
            }
            guard let current = focusSnapshot(),
                  current.token == target.token,
                  current.processIdentifier == target.processIdentifier else {
                return .focusChanged
            }
            if current.value == expected { return .completedExact(expected) }
            usleep(25_000)
        } while Date() < deadline
        return .unobserved
    }

    private static func postKey(
        _ key: String,
        into target: FocusSnapshot
    ) -> TextPostingResult {
        guard !StealthEntryLatch.shared.isRaised else {
            return .blockedByStealth
        }
        let codes: [String: CGKeyCode] = [
            "enter": 36, "return": 36, "tab": 48,
            "escape": 53, "space": 49,
        ]
        guard let code = codes[key], focusStillMatches(target),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: code,
                keyDown: true
              ), let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: code,
                keyDown: false
              ) else {
            return .focusChanged
        }
        guard StealthEntryLatch.shared.performUnlessRaised({
            guard focusStillMatches(target) else { return false }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }) == true else {
            return StealthEntryLatch.shared.isRaised
                ? .blockedByStealth
                : .focusChanged
        }
        return .completed
    }

    private static func postShortcut(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        processIdentifier: pid_t
    ) -> Bool {
        guard !StealthEntryLatch.shared.isRaised,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processIdentifier,
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
              ) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        return StealthEntryLatch.shared.performUnlessRaised {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == processIdentifier else {
                return false
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        } == true
    }

    private static func verifiedEditableSurface(
        _ snapshot: FocusSnapshot,
        applicationName: String
    ) -> DesktopTypingResult {
        .verified(
            applicationName: applicationName,
            role: snapshot.role,
            valueDigest: digest(snapshot.value ?? snapshot.token),
            characterCount: 0
        )
    }

    private static func focusStillMatches(_ target: FocusSnapshot) -> Bool {
        guard let current = focusSnapshot(),
              current.token == target.token,
              current.processIdentifier == target.processIdentifier else {
            return false
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
            == target.processIdentifier
    }

    private static func element(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element
        ) == .success else {
            return nil
        }
        return element
    }

    private static func pressableElement(
        startingAt element: AXUIElement
    ) -> AXUIElement? {
        var candidate: AXUIElement? = element
        for _ in 0..<8 {
            guard let current = candidate else { return nil }
            var actions: CFArray?
            if AXUIElementCopyActionNames(current, &actions) == .success,
               (actions as? [String])?.contains(
                kAXPressAction as String
               ) == true {
                return current
            }
            candidate = elementAttribute(kAXParentAttribute, of: current)
        }
        return nil
    }

    private static func hasWebContentAncestor(_ element: AXUIElement) -> Bool {
        var candidate: AXUIElement? = element
        for _ in 0..<24 {
            guard let current = candidate else { return false }
            let role = stringAttribute(kAXRoleAttribute, of: current) ?? ""
            if role == "AXWebArea" || role == "AXHTMLContent" {
                return true
            }
            candidate = elementAttribute(kAXParentAttribute, of: current)
        }
        return false
    }

    private static func clickSnapshot(
        of element: AXUIElement
    ) -> ClickTargetSnapshot? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier > 0 else {
            return nil
        }
        let window = elementAttribute(kAXWindowAttribute, of: element)
        return ClickTargetSnapshot(
            processIdentifier: processIdentifier,
            windowNumber: window.flatMap(windowNumber),
            role: stringAttribute(kAXRoleAttribute, of: element),
            subrole: stringAttribute(kAXSubroleAttribute, of: element),
            identifier: stringAttribute(kAXIdentifierAttribute, of: element),
            title: stringAttribute(kAXTitleAttribute, of: element),
            value: semanticAttribute(kAXValueAttribute, of: element),
            selected: boolAttribute(kAXSelectedAttribute, of: element),
            enabled: boolAttribute(kAXEnabledAttribute, of: element)
        )
    }

    private static func clickObservation(
        target: AXUIElement,
        processIdentifier: pid_t
    ) -> ClickObservation {
        let app = AXUIElementCreateApplication(processIdentifier)
        let focusedWindow = elementAttribute(
            kAXFocusedWindowAttribute,
            of: app
        )
        return ClickObservation(
            frontmostProcessIdentifier:
                NSWorkspace.shared.frontmostApplication?.processIdentifier,
            focusedWindowNumber: focusedWindow.flatMap(windowNumber),
            focusedWindowTitle: focusedWindow.flatMap {
                stringAttribute(kAXTitleAttribute, of: $0)
            },
            focusedElementIdentity: focusedElementIdentity(
                in: processIdentifier
            ),
            target: clickSnapshot(of: target)
        )
    }

    private static func focusedElementIdentity(
        in processIdentifier: pid_t
    ) -> CFHashCode? {
        guard let focused = elementAttribute(
            kAXFocusedUIElementAttribute,
            of: AXUIElementCreateApplication(processIdentifier)
        ) else { return nil }
        return CFHash(focused)
    }

    private static func elementAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func elementArrayAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let values = value as? [Any] else {
            return []
        }
        return values.compactMap { candidate in
            let reference = candidate as CFTypeRef
            guard CFGetTypeID(reference) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeBitCast(reference, to: AXUIElement.self)
        }
    }

    private static func windowNumber(of element: AXUIElement) -> UInt32? {
        AccessibilityWindowIdentity.windowIdentifier(of: element)
    }

    /// Exact identifier of the window containing `element`. Browser web
    /// controls can omit AXWindow while keeping their parent chain, so the
    /// chain is the fallback; a bounded walk keeps a malformed tree finite.
    private static func containingWindowIdentifier(
        of element: AXUIElement
    ) -> UInt32? {
        if let window = elementAttribute(kAXWindowAttribute, of: element) {
            return windowNumber(of: window)
        }
        var candidate: AXUIElement? = element
        for _ in 0..<32 {
            guard let current = candidate else { return nil }
            if stringAttribute(kAXRoleAttribute, of: current)
                == kAXWindowRole as String {
                return windowNumber(of: current)
            }
            candidate = elementAttribute(kAXParentAttribute, of: current)
        }
        return nil
    }

    private static func boolAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    private static func selectedTextRange(
        of element: AXUIElement
    ) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
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
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
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
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static func isSecure(_ snapshot: FocusSnapshot) -> Bool {
        snapshot.role == "AXSecureTextField"
            || snapshot.subrole == "AXSecureTextField"
    }

    private static func isEditable(_ snapshot: FocusSnapshot) -> Bool {
        if editableRoles.contains(snapshot.role) { return true }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            snapshot.element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }

    private static func stringAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private static func semanticAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value else {
            return nil
        }
        if let string = value as? String {
            return String(string.prefix(16_384))
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(String(describing: value).prefix(16_384))
    }

    private static func digest(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }
            .joined()
    }

    private static func visibleWindowCount(
        processIdentifier: pid_t
    ) -> Int {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return windows.filter { window in
            (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                == processIdentifier
                && (window[kCGWindowLayer as String] as? NSNumber)?.intValue
                    == 0
                && ((window[kCGWindowAlpha as String] as? NSNumber)?
                    .doubleValue ?? 0) > 0
        }.count
    }
}
#endif // circuit-convert
