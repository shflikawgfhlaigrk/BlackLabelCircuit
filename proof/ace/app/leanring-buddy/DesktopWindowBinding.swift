//
//  DesktopWindowBinding.swift
//  Ace
//
//  Pure selection of the ONE window a named-application action may target.
//
//  Why this exists: "type this out in Chrome" used to bind only the
//  application. Activation then let macOS (or Ace's own minimized-document
//  restore) decide which window came forward, and the text went into whatever
//  field that window happened to focus. On September 17 that put 115
//  characters into a restored, unrelated Chrome window. The owner names an
//  app; the window they mean is the one they were already using in it. That
//  choice is made here, from values captured BEFORE any activation, so the
//  act of switching can never change the answer. Anything that would require
//  a guess fails closed with a reason the owner can act on.
//

import Foundation

/// Value-only description of one Accessibility window. No title or content is
/// retained: selection needs identity and state, not what the window shows.
nonisolated struct DesktopWindowDescriptor: Equatable, Sendable {
    /// Index in the application's AXWindows array (front-to-back).
    let accessibilityOrder: Int
    /// Exact window-server identifier, when it could be resolved.
    let windowIdentifier: UInt32?
    let isStandardWindow: Bool
    let isMinimized: Bool
    let isMainWindow: Bool
    let isFocusedWindow: Bool
    /// True when the window server lists this identifier on the current Space.
    let isOnScreen: Bool
}

nonisolated enum DesktopWindowSelection: Equatable, Sendable {
    /// The window the owner was already using. Raise exactly this one.
    case existing(DesktopWindowDescriptor)
    /// Every document is in the Dock and there is exactly one: restoring it
    /// is what clicking the Dock icon does, and it is not a guess.
    case restoreOnlyMinimized(DesktopWindowDescriptor)
    /// Several open windows and the application names none as its main one.
    case ambiguousOpen(count: Int)
    /// Several minimized documents and nothing on screen.
    case ambiguousMinimized(count: Int)
    case noStandardWindow
    /// A window was chosen but has no exact identifier to re-verify against.
    case identityUnavailable
}

nonisolated enum DesktopWindowBindingPolicy {
    static func selection(
        from descriptors: [DesktopWindowDescriptor]
    ) -> DesktopWindowSelection {
        let standardWindows = descriptors.filter(\.isStandardWindow)
        guard !standardWindows.isEmpty else { return .noStandardWindow }

        let openWindows = standardWindows.filter { !$0.isMinimized }
        guard !openWindows.isEmpty else {
            guard standardWindows.count == 1,
                  let onlyMinimizedWindow = standardWindows.first else {
                return .ambiguousMinimized(count: standardWindows.count)
            }
            guard onlyMinimizedWindow.windowIdentifier != nil else {
                return .identityUnavailable
            }
            return .restoreOnlyMinimized(onlyMinimizedWindow)
        }

        // A window the owner can currently see always outranks one parked on
        // another Space; a minimized window is never chosen while any window
        // is open. This is the exact rule the September 17 failure broke.
        let windowsOnCurrentSpace = openWindows.filter(\.isOnScreen)
        let candidateWindows = windowsOnCurrentSpace.isEmpty
            ? openWindows
            : windowsOnCurrentSpace

        let chosenWindow: DesktopWindowDescriptor
        if let focusedWindow = uniqueWindow(
            in: candidateWindows,
            where: \.isFocusedWindow
        ) {
            chosenWindow = focusedWindow
        } else if let mainWindow = uniqueWindow(
            in: candidateWindows,
            where: \.isMainWindow
        ) {
            chosenWindow = mainWindow
        } else if candidateWindows.count == 1,
                  let onlyWindow = candidateWindows.first {
            chosenWindow = onlyWindow
        } else {
            return .ambiguousOpen(count: candidateWindows.count)
        }

        guard chosenWindow.windowIdentifier != nil else {
            return .identityUnavailable
        }
        return .existing(chosenWindow)
    }

    private static func uniqueWindow(
        in windows: [DesktopWindowDescriptor],
        where predicate: (DesktopWindowDescriptor) -> Bool
    ) -> DesktopWindowDescriptor? {
        let matches = windows.filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }

    /// Owner-facing text for every refusal. Each names what the owner can do;
    /// none claims a permission problem that was not observed.
    static func refusalReason(
        for selection: DesktopWindowSelection,
        applicationName: String
    ) -> String? {
        switch selection {
        case .existing, .restoreOnlyMinimized:
            return nil
        case .ambiguousOpen(let count):
            return "\(applicationName) has \(count) open windows and none is marked as the one in use, so i did not pick one. click the window you want, then ask again."
        case .ambiguousMinimized(let count):
            return "\(applicationName) has \(count) minimized windows and none open, so i did not pick one. bring the window you want forward, then ask again."
        case .noStandardWindow:
            return "\(applicationName) has no open document window to type into. open the window you want, click where the text should go, then ask again."
        case .identityUnavailable:
            return "i could not bind one exact \(applicationName) window, so i did not type anything. click the window you want, then ask again."
        }
    }
}
