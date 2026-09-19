//
//  AccessibilityWindowIdentity.swift
//  Ace
//
//  One exact window-identity primitive shared by Private Mode capture binding,
//  named-window typing, click observation, and display-qualified window moves.
//
//  Why this exists: every one of those paths used to read an "AXWindowNumber"
//  Accessibility attribute. A September 17 host probe found that attribute on
//  0 of 16 windows across 11 ordinary apps (Safari, Chrome, Finder, Mail,
//  Slack, Terminal, ...), so identity silently fell through to "exactly one
//  window of this process has this frame". That fallback returns nothing the
//  moment an app owns two same-frame windows (two zoomed browser windows is
//  enough), which is how a customer's Private Mode read reported "the exact
//  foreground window could not be verified" and why display-qualified window
//  moves could never bind a target. The window server already knows the exact
//  CGWindowID behind an AX window element; ask it directly.
//

#if canImport(ApplicationServices) && !CIRCUIT_WINDOWS_SIM
import ApplicationServices
#endif
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Pure resolution order, separated from the live lookups so the offline
/// battery can prove that a missing or failing source never fabricates an
/// identifier and that a zero identifier is never accepted.
nonisolated enum AccessibilityWindowIdentityPolicy {
    static func resolvedWindowIdentifier(
        windowServerLookup: () -> UInt32?,
        accessibilityAttributeLookup: () -> UInt32?
    ) -> UInt32? {
        if let windowServerIdentifier = windowServerLookup(),
           windowServerIdentifier > 0 {
            return windowServerIdentifier
        }
        if let attributeIdentifier = accessibilityAttributeLookup(),
           attributeIdentifier > 0 {
            return attributeIdentifier
        }
        return nil
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated enum AccessibilityWindowIdentity {
    private typealias WindowServerLookupFunction = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    /// Resolved once through `dlsym` rather than a link-time import. The
    /// HIServices entry point is not in the public headers, so a future macOS
    /// that removes it must degrade to the attribute/frame fallbacks instead
    /// of preventing Ace from launching.
    private static let windowServerLookupFunction:
        WindowServerLookupFunction? = {
        // RTLD_DEFAULT: search every image already loaded into this process.
        let defaultSearchHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(
            defaultSearchHandle,
            "_AXUIElementGetWindow"
        ) else {
            return nil
        }
        return unsafeBitCast(symbol, to: WindowServerLookupFunction.self)
    }()

    /// Content-free diagnostic for receipts: tells a support log whether this
    /// macOS still offers the exact lookup at all.
    static var windowServerLookupIsAvailable: Bool {
        windowServerLookupFunction != nil
    }

    /// Exact CGWindowID for one Accessibility window element, or nil. Callers
    /// keep their own stricter fallbacks; this function never guesses.
    static func windowIdentifier(
        of windowElement: AXUIElement
    ) -> CGWindowID? {
        AccessibilityWindowIdentityPolicy.resolvedWindowIdentifier(
            windowServerLookup: {
                guard let windowServerLookupFunction else { return nil }
                var windowIdentifier: CGWindowID = 0
                guard windowServerLookupFunction(
                    windowElement,
                    &windowIdentifier
                ) == .success else {
                    return nil
                }
                return windowIdentifier
            },
            accessibilityAttributeLookup: {
                // Retained for any application that does vend the attribute.
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    windowElement,
                    "AXWindowNumber" as CFString,
                    &value
                ) == .success,
                let number = value as? NSNumber else {
                    return nil
                }
                let rawValue = number.uint64Value
                guard rawValue > 0, rawValue <= UInt64(UInt32.max) else {
                    return nil
                }
                return UInt32(rawValue)
            }
        )
    }
}
#endif // circuit-convert
