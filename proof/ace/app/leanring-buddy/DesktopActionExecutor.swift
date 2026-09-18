//
//  DesktopActionExecutor.swift
//  Ace
//
//  One provider-neutral receipt boundary for Red desktop effects. Providers
//  describe an exact action; Ace performs it and accepts only an observed
//  postcondition from its app-owned Accessibility backend.
//

import Foundation

nonisolated enum DesktopAction: Codable, Equatable, Sendable {
    case openApplication(exactName: String)
    case openApplicationAndType(exactName: String, exactText: String)
    case ensureEditableSurface
    case click(exactTarget: String)
    case typeText(exactText: String)
    case typeTextInApplication(exactName: String, exactText: String)
    case pressKey(exactKey: String)
}

nonisolated struct DesktopActionRequest: Codable, Equatable, Sendable {
    let action: DesktopAction
    let expectedFrontmostBundleIdentifier: String?
    let expectedFocusedElementToken: String?
}

nonisolated extension OwnerCapabilityStatus: Codable {}

nonisolated struct DesktopActionReceipt: Codable, Equatable, Sendable {
    let status: OwnerCapabilityStatus
    let observedApplication: String?
    let observedRole: String?
    let observedValueDigest: String?
    let reason: String
}

nonisolated enum DesktopOpenResult: Equatable, Sendable {
    case observed(
        requestedApplicationName: String,
        resolvedApplicationName: String,
        frontmostApplicationName: String,
        frontmostBundleIdentifier: String?,
        visibleWindowCount: Int
    )
    case unavailable(String)
}

/// Result of bringing ONE exact window of a named application forward for a
/// typing action. The window identifier is the window server's own; every
/// later focus check is compared against it.
nonisolated enum DesktopWindowOpenResult: Equatable, Sendable {
    case bound(
        requestedApplicationName: String,
        resolvedApplicationName: String,
        bundleIdentifier: String?,
        windowIdentifier: UInt32
    )
    case unavailable(String)
}

nonisolated enum DesktopClickResult: Equatable, Sendable {
    case verified(applicationName: String)
    case deliveredWithoutObservedChange
    case ambiguous
    case targetMoved
    case unavailable(String)
}

nonisolated enum DesktopTypingResult: Equatable, Sendable {
    case verified(
        applicationName: String,
        role: String,
        valueDigest: String,
        characterCount: Int
    )
    case deliveredWithoutObservedChange(applicationName: String)
    case secureField
    case noEditableFocus
    case focusChanged(applicationName: String)
    case blockedByStealth
    case unavailable(String)
}

nonisolated enum DesktopTextValueObservation: Equatable, Sendable {
    case pending
    case changed(String)
    case focusChanged
}

nonisolated enum DesktopTextValueObservationPolicy {
    static func expectedValue(
        beforeValue: String?,
        selectionRange: NSRange?,
        insertedText: String
    ) -> String? {
        guard let beforeValue else { return nil }
        // A missing selection is only unambiguous in a known-empty editor.
        // Guessing the end of a nonempty field can replace the owner's text
        // at a different caret than the one they selected.
        guard let selectionRange = selectionRange
                ?? (beforeValue.isEmpty ? NSRange(location: 0, length: 0) : nil),
              let range = Range(selectionRange, in: beforeValue) else {
            return nil
        }
        return beforeValue.replacingCharacters(in: range, with: insertedText)
    }

    static func decision(
        beforeValue: String?,
        afterValue: String?,
        beforeSelectionRange: NSRange? = nil,
        afterSelectionRange: NSRange? = nil,
        insertedText: String? = nil,
        sameBoundElement: Bool
    ) -> DesktopTextValueObservation {
        guard sameBoundElement else { return .focusChanged }
        guard let insertedText, !insertedText.isEmpty,
              let afterValue,
              let expected = expectedValue(
                beforeValue: beforeValue,
                selectionRange: beforeSelectionRange,
                insertedText: insertedText
              ),
              afterValue == expected else { return .pending }
        if afterValue == beforeValue {
            guard let beforeSelectionRange,
                  beforeSelectionRange.length > 0,
                  let afterSelectionRange,
                  afterSelectionRange.length == 0,
                  afterSelectionRange.location
                    == beforeSelectionRange.location
                        + insertedText.utf16.count else {
                return .pending
            }
        }
        return .changed(afterValue)
    }
}

/// Browser key events may accept only one Unicode scalar and may drop a burst.
/// Advance only after the exact insertion and caret are visible in the same field.
nonisolated enum DesktopUnicodeTextDelivery {
    struct Observation: Equatable {
        let token: String
        let value: String
        let selection: NSRange
    }

    enum Result: Equatable {
        case verified(String)
        case unverified
        case targetChanged
        case cancelled
    }

    @MainActor
    static func deliver(
        _ text: String,
        initial: Observation,
        isAllowed: () -> Bool,
        observe: () -> Observation?,
        postScalar: (String) -> Bool,
        waitForObservation: () async -> Void
    ) async -> Result {
        var before = initial
        for scalar in text.unicodeScalars {
            guard !Task.isCancelled, isAllowed() else { return .cancelled }
            guard observe() == before else { return .targetChanged }
            let insertion = String(scalar)
            guard let expectedValue = DesktopTextValueObservationPolicy.expectedValue(
                beforeValue: before.value,
                selectionRange: before.selection,
                insertedText: insertion
            ) else { return .unverified }
            let expected = Observation(
                token: before.token,
                value: expectedValue,
                selection: NSRange(
                    location: before.selection.location + insertion.utf16.count,
                    length: 0
                )
            )
            // A sent event is never retried. A missing or partial observation
            // stops the operation before any later character can be sent.
            guard postScalar(insertion) else { return .unverified }
            var verified = false
            for _ in 0..<40 {
                guard !Task.isCancelled, isAllowed() else { return .cancelled }
                guard let current = observe(), current.token == before.token else {
                    return .targetChanged
                }
                if current == expected { verified = true; break }
                guard current.value == before.value || current.value == expected.value else {
                    return .unverified
                }
                await waitForObservation()
            }
            guard verified else { return .unverified }
            before = expected
        }
        guard !Task.isCancelled, isAllowed() else { return .cancelled }
        guard observe() == before else { return .targetChanged }
        return .verified(before.value)
    }
}

nonisolated enum DesktopTextDeliveryRoute: Equatable, Sendable {
    /// Whole-value write of (existing text with the selection replaced).
    case accessibilityValue
    /// Whole-value write of exactly the requested text. Admitted only while
    /// the editor is empty: on a non-empty editor it would erase the owner's
    /// existing content.
    case accessibilityExactValue
    /// Replace only the current selection (insert at the caret). This is what
    /// dictation does, and it cannot touch text outside the selection.
    case accessibilitySelectionInsertion
    /// Unicode key events delivered to the bound process: real typing, for
    /// editors that accept neither of the Accessibility writes safely.
    case unicodeKeyEvents
}

nonisolated enum DesktopTextDeliveryPolicy {
    private static let unicodeOnlyBundleIdentifiers: Set<String> = [
        "com.anthropic.claudefordesktop",
    ]

    /// The defaults reproduce the route an EMPTY editor has always received.
    /// The extra inputs exist for one reason: an exact whole-value write into
    /// a web or Electron editor replaced everything the owner had already
    /// written there, and a merged whole-value write into a rich text area
    /// flattened its formatting. A non-empty editor is therefore only ever
    /// inserted into.
    static func route(
        bundleIdentifier: String?,
        hasWebContentAncestor: Bool,
        role: String = "",
        existingValueIsEmpty: Bool = true,
        existingValueIsAvailable: Bool = true,
        selectionRangeIsAvailable: Bool = true,
        selectedTextIsSettable: Bool = false
    ) -> DesktopTextDeliveryRoute {
        if !existingValueIsAvailable
            || (!existingValueIsEmpty && !selectionRangeIsAvailable) {
            return selectedTextIsSettable
                ? .accessibilitySelectionInsertion : .unicodeKeyEvents
        }
        let requiresExactValueFamily = hasWebContentAncestor
            || bundleIdentifier.map {
                unicodeOnlyBundleIdentifiers.contains($0.lowercased())
            } ?? false
        if requiresExactValueFamily {
            if existingValueIsEmpty { return .accessibilityExactValue }
            return selectedTextIsSettable
                ? .accessibilitySelectionInsertion
                : .unicodeKeyEvents
        }
        if !existingValueIsEmpty, role == "AXTextArea" {
            return selectedTextIsSettable
                ? .accessibilitySelectionInsertion : .unicodeKeyEvents
        }
        return .accessibilityValue
    }
}

@MainActor
protocol DesktopActionBackend: AnyObject {
    func currentFrontmostBundleIdentifier() -> String?
    func currentFocusedEditableElementToken() -> String?
    func openApplication(named exactName: String) async -> DesktopOpenResult
    /// Brings forward the ONE window the owner was already using in the named,
    /// already-running application and returns its exact identity.
    func openApplicationWindowForTyping(
        named exactName: String
    ) async -> DesktopWindowOpenResult
    /// Token of the focused editable element, only when that element lives in
    /// the given exact window and that window is still the focused one.
    func currentFocusedEditableElementToken(
        inWindow windowIdentifier: UInt32
    ) -> String?
    func ensureEditableSurface() async -> DesktopTypingResult
    func click(targetedBy exactDescription: String) async -> DesktopClickResult
    func typeText(
        _ exactText: String,
        expectedFocusedElementToken: String?
    ) async -> DesktopTypingResult
    func pressKey(
        _ exactKey: String,
        expectedFocusedElementToken: String?
    ) -> DesktopTypingResult
}

@MainActor
final class DesktopActionExecutor {
    private static let supportedKeys: Set<String> = [
        "enter", "return", "tab", "escape", "space",
    ]

    private let backend: any DesktopActionBackend
    private let isAllowed: @MainActor () -> Bool

    init(
        backend: any DesktopActionBackend,
        isAllowed: @escaping @MainActor () -> Bool = { true }
    ) {
        self.backend = backend
        self.isAllowed = isAllowed
    }

    func execute(_ request: DesktopActionRequest) async -> DesktopActionReceipt {
        guard isAllowed() else {
            return failed("the desktop action is no longer allowed")
        }
        if case .openApplication = request.action {
            // The open action verifies the requested app after launch.
        } else if case .openApplicationAndType = request.action {
            // The open action verifies the requested app after launch.
        } else if case .typeTextInApplication = request.action {
            // Named typing binds to the opened app, never the previous foreground app.
        } else if let expected = request.expectedFrontmostBundleIdentifier,
                  backend.currentFrontmostBundleIdentifier() != expected {
            return failed(
                "the frozen frontmost application changed before the effect"
            )
        }

        switch request.action {
        case .typeTextInApplication(let exactName, let exactText):
            guard exactValue(exactName), !exactText.isEmpty else {
                return failed("the application name and text must be exact and nonempty")
            }
            // Naming an application is not enough to type safely: the text
            // must land in the window the owner was already using, in the
            // field that window already focused. The backend binds that one
            // exact window before activation; the token below then carries
            // the window identity into every later focus check.
            let opened = await backend.openApplicationWindowForTyping(
                named: exactName
            )
            guard isAllowed() else {
                return failed("the desktop action is no longer allowed")
            }
            switch opened {
            case .bound(
                let requested,
                let resolved,
                let bundle,
                let windowIdentifier
            ):
                guard requested == exactName,
                      let bundle,
                      windowIdentifier > 0,
                      backend.currentFrontmostBundleIdentifier() == bundle else {
                    return failed("the requested typing application did not remain frontmost and visible")
                }
                guard let token = backend.currentFocusedEditableElementToken(
                    inWindow: windowIdentifier
                ) else {
                    return failed(
                        "the \(resolved) window Ace bound has no focused editable field. click where the text should go, then ask again"
                    )
                }
                return await execute(.init(
                    action: .typeText(exactText: exactText),
                    expectedFrontmostBundleIdentifier: bundle,
                    expectedFocusedElementToken: token
                ))
            case .unavailable(let reason):
                return failed(reason)
            }

        case .openApplicationAndType(let exactName, let exactText):
            guard exactValue(exactName), !exactText.isEmpty else {
                return failed(
                    "the application name and text must be exact and nonempty"
                )
            }
            let openReceipt = await execute(
                DesktopActionRequest(
                    action: .openApplication(exactName: exactName),
                    expectedFrontmostBundleIdentifier: nil,
                    expectedFocusedElementToken: nil
                )
            )
            guard openReceipt.status == .verified,
                  let openedApplication = openReceipt.observedApplication,
                  let openedBundleIdentifier =
                    backend.currentFrontmostBundleIdentifier() else {
                return openReceipt
            }
            let surfaceReceipt = await execute(
                DesktopActionRequest(
                    action: .ensureEditableSurface,
                    expectedFrontmostBundleIdentifier:
                        openedBundleIdentifier,
                    expectedFocusedElementToken: nil
                )
            )
            guard surfaceReceipt.status == .verified else {
                return surfaceReceipt
            }
            guard let focusedElementToken =
                    backend.currentFocusedEditableElementToken() else {
                return failed(
                    "the opened application exposed no bound editable focus"
                )
            }
            let typingReceipt = await execute(
                DesktopActionRequest(
                    action: .typeText(exactText: exactText),
                    expectedFrontmostBundleIdentifier:
                        openedBundleIdentifier,
                    expectedFocusedElementToken: focusedElementToken
                )
            )
            guard typingReceipt.status == .verified else {
                return typingReceipt
            }
            return verified(
                "opened \(openedApplication), focused its bound editor, and "
                    + "\(typingReceipt.reason)",
                application: typingReceipt.observedApplication,
                role: typingReceipt.observedRole,
                valueDigest: typingReceipt.observedValueDigest
            )

        case .openApplication(let exactName):
            guard exactValue(exactName) else {
                return failed("the application name must be exact and nonempty")
            }
            switch await backend.openApplication(named: exactName) {
            case .observed(
                let requestedApplicationName,
                let resolvedApplicationName,
                let frontmostApplicationName,
                let frontmostBundleIdentifier,
                let visibleWindowCount
            ):
                guard requestedApplicationName == exactName,
                      resolvedApplicationName == frontmostApplicationName,
                      request.expectedFrontmostBundleIdentifier.map({
                          $0 == frontmostBundleIdentifier
                      }) ?? true,
                      visibleWindowCount > 0 else {
                    return failed(
                        "the requested application did not become exact, frontmost, and visible"
                    )
                }
                return verified(
                    "\(resolvedApplicationName) is frontmost with \(visibleWindowCount) visible window(s)",
                    application: resolvedApplicationName
                )
            case .unavailable(let reason):
                return failed(reason)
            }

        case .ensureEditableSurface:
            return typingReceipt(
                await backend.ensureEditableSurface()
            )

        case .click(let exactTarget):
            guard exactValue(exactTarget) else {
                return failed("the click target must be exact and nonempty")
            }
            switch await backend.click(targetedBy: exactTarget) {
            case .verified(let applicationName):
                return verified(
                    "clicked the unique target in \(applicationName) and observed a change",
                    application: applicationName
                )
            case .deliveredWithoutObservedChange:
                return failed("the click was delivered but no interface change was observed")
            case .ambiguous:
                return failed("more than one visible control matched the target")
            case .targetMoved:
                return failed("the target changed before the click could be delivered")
            case .unavailable(let reason):
                return failed(reason)
            }

        case .typeText(let exactText):
            guard !exactText.isEmpty else {
                return failed("the text must be nonempty")
            }
            return typingReceipt(
                await backend.typeText(
                    exactText,
                    expectedFocusedElementToken:
                        request.expectedFocusedElementToken
                )
            )

        case .pressKey(let exactKey):
            guard exactValue(exactKey) else {
                return failed("the key must be exact and nonempty")
            }
            let key = exactKey.lowercased()
            guard Self.supportedKeys.contains(key) else {
                return failed("the requested key is outside Ace's reviewed key set")
            }
            return typingReceipt(
                backend.pressKey(
                    key,
                    expectedFocusedElementToken:
                        request.expectedFocusedElementToken
                )
            )
        }
    }

    private func typingReceipt(
        _ result: DesktopTypingResult
    ) -> DesktopActionReceipt {
        switch result {
        case .verified(
            let applicationName,
            let role,
            let valueDigest,
            let characterCount
        ):
            return verified(
                "observed \(characterCount) character(s) entered in \(applicationName)",
                application: applicationName,
                role: role,
                valueDigest: valueDigest
            )
        case .deliveredWithoutObservedChange(let applicationName):
            return failed(
                "Typing in \(applicationName) did not match the requested text. Some text may have been inserted; inspect the field before trying again."
            )
        case .secureField:
            return failed("the focused element is a secure field")
        case .noEditableFocus:
            return failed("no editable element has exact focus")
        case .focusChanged(let applicationName):
            return failed("focus changed from \(applicationName) before completion")
        case .blockedByStealth:
            return failed("the desktop action was blocked by Private Mode")
        case .unavailable(let reason):
            return failed(reason)
        }
    }

    private func exactValue(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    private func verified(
        _ reason: String,
        application: String? = nil,
        role: String? = nil,
        valueDigest: String? = nil
    ) -> DesktopActionReceipt {
        DesktopActionReceipt(
            status: .verified,
            observedApplication: application,
            observedRole: role,
            observedValueDigest: valueDigest,
            reason: reason
        )
    }

    private func failed(_ reason: String) -> DesktopActionReceipt {
        DesktopActionReceipt(
            status: .failed,
            observedApplication: nil,
            observedRole: nil,
            observedValueDigest: nil,
            reason: reason
        )
    }
}
