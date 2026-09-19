#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  PrivateModePolicy.swift
//  leanring-buddy
//
//  Fail-closed policy for user-invoked Private Mode screen reads. The policy
//  protects credentials and security surfaces while leaving the app fully
//  visible to macOS, TCC, administrators, and endpoint-security software.
//

#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(ApplicationServices) && !CIRCUIT_WINDOWS_SIM
import ApplicationServices
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
import Foundation

struct PrivateModeDisplaySnapshot: Equatable, Sendable {
    let displayIdentifier: CGDirectDisplayID
    /// Quartz/ScreenCaptureKit coordinates (top-left origin). Synthetic mouse
    /// events and `SCWindow.frame` use this coordinate space.
    let coreGraphicsFrame: CGRect
    /// AppKit coordinates (bottom-left origin), retained so a topology change
    /// cannot hide behind an unchanged Quartz frame.
    let appKitFrame: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

struct PrivateModeWindowCandidate: Equatable, Sendable {
    let windowIdentifier: CGWindowID
    let processIdentifier: pid_t
    let title: String?
    let frame: CGRect
    let layer: Int
    let isOnScreen: Bool
}

struct PrivateModeContext: Equatable, Sendable {
    let bundleIdentifier: String?
    let applicationName: String?
    let processIdentifier: pid_t?
    let focusedRole: String?
    let focusedSubrole: String?
    let focusedWindowIdentifier: CGWindowID?
    let focusedWindowTitle: String?
    let focusedWindowFrame: CGRect?
    /// Why the focused window could not be bound, when it could not. It is
    /// diagnostic only: `contextsExactlyMatch` never reads it, so it cannot
    /// widen or narrow what a capture or click is allowed to target.
    var windowVerificationFailure: PrivateModeWindowVerificationFailure? = nil
}

/// Content-free reason the exact foreground window could not be bound. One
/// generic sentence used to cover a revoked permission, a windowless app, a
/// hung app, and two indistinguishable windows alike, which left a customer
/// with nothing to act on and a support log that could not tell them apart.
/// No case carries a title, a frame, or any other on-screen content.
nonisolated enum PrivateModeWindowVerificationFailure: String, Sendable {
    case accessibilityNotTrusted = "accessibility-not-trusted"
    case noFrontmostApplication = "no-frontmost-application"
    case applicationNotResponding = "application-not-responding"
    case focusedWindowUnavailable = "focused-window-unavailable"
    case windowFrameUnavailable = "window-frame-unavailable"
    case windowIdentityAmbiguous = "window-identity-ambiguous"
    case windowIdentityUnavailable = "window-identity-unavailable"

    var userFacingReason: String {
        switch self {
        case .accessibilityNotTrusted:
            return "Capture blocked because Ace's Accessibility permission is off. Turn Ace on in System Settings, Privacy & Security, Accessibility, then try again."
        case .noFrontmostApplication:
            return "Capture blocked because no app was in front. Click the question window, then try again."
        case .applicationNotResponding:
            return "Capture blocked because the app in front did not answer in time. Wait until it responds, then try again."
        case .focusedWindowUnavailable:
            return "Capture blocked because the app in front has no focused window. Click inside the question window, then try again."
        case .windowFrameUnavailable:
            return "Capture blocked because the question window's position could not be read. Click inside the question window, then try again."
        case .windowIdentityAmbiguous:
            return "Capture blocked because two windows of that app sit in exactly the same place, so the question window could not be told apart. Move or resize one of them, then try again."
        case .windowIdentityUnavailable:
            return "Capture blocked because the exact foreground window could not be verified. Click inside the question window, then try again."
        }
    }
}

struct PrivateModeContextDecision: Equatable, Sendable {
    let isAllowed: Bool
    let userFacingReason: String
}

/// Content-free capture diagnostics. Never expose a framework error's text:
/// it may contain a window title or other private capture metadata.
nonisolated enum PrivateModeCaptureFailure: String, Error, Sendable {
    case modeEnded = "mode-ended"
    case displayChanged = "display-changed"
    case windowChanged = "window-changed"
    case windowSpansDisplays = "window-spans-displays"
    case windowUnavailable = "window-unavailable"
    case displayUnavailable = "display-unavailable"
    case invalidCrop = "invalid-crop"
    case missingImage = "missing-image"
    case invalidBinding = "invalid-binding"
    case captureService = "capture-service"

    static func classified(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        let systemError = error as NSError
        guard systemError.domain == "CompanionScreenCapture" else {
            return .captureService
        }
        switch systemError.code {
        case -1, -4: return .displayUnavailable
        case -3: return .windowUnavailable
        case -6: return .missingImage
        case -7: return .invalidCrop
        default: return .captureService
        }
    }

    var userFacingReason: String {
        let reason: String
        switch self {
        case .modeEnded: reason = "Private Mode ended during capture."
        case .displayChanged: reason = "The display layout changed during capture."
        case .windowChanged: reason = "The focused window changed during capture."
        case .windowSpansDisplays:
            reason = "Move the whole question window onto one display before trying again."
        case .windowUnavailable:
            reason = "The focused window was unavailable to screen capture."
        case .displayUnavailable: reason = "The question's display was unavailable."
        case .invalidCrop: reason = "The question window had no valid visible capture area."
        case .missingImage: reason = "Screen capture returned no image."
        case .invalidBinding: reason = "The captured image did not match this request."
        case .captureService: reason = "macOS screen capture failed."
        }
        return reason + " Nothing was clicked."
    }
}

/// The only authority that lets ScreenCaptureKit run while Stealth's visibility
/// wall is raised. It is deliberately tied to one Private Mode session and one
/// already-verified foreground process/window; a bare Boolean cannot bypass the
/// capture wall.
struct PrivateModeCaptureCapability: Equatable, Sendable {
    let sessionIdentifier: UUID
    let expectedContext: PrivateModeContext
    let includesAllDisplays: Bool

    fileprivate init(
        sessionIdentifier: UUID,
        expectedContext: PrivateModeContext,
        includesAllDisplays: Bool = false
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.expectedContext = expectedContext
        self.includesAllDisplays = includesAllDisplays
    }
}

/// Exact geometry/identity returned with the one-window capture. This is the
/// immutable authority carried across the model round trip and all later aim /
/// click boundaries.
struct PrivateModeCaptureBinding: Equatable, Sendable {
    let sessionIdentifier: UUID
    let expectedContext: PrivateModeContext
    let windowIdentifier: CGWindowID
    let windowFrame: CGRect
    /// Exact global Quartz frame represented by the JPEG. This is normally the
    /// focused window, clipped to its one verified display when an edge is
    /// off-screen. It must never silently expand back to the whole display.
    let captureFrame: CGRect
    let display: PrivateModeDisplaySnapshot
    let displayTopology: [PrivateModeDisplaySnapshot]
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    var includesAllDisplays: Bool = false
}

/// Pure, testable plan for the exact-window ScreenCaptureKit crop. The source
/// rectangle is display-local (as required by `SCStreamConfiguration`), while
/// `captureFrame` remains global Quartz geometry for later click binding.
struct PrivateModeCaptureGeometry: Equatable, Sendable {
    let captureFrame: CGRect
    let sourceRect: CGRect
    let outputWidthInPixels: Int
    let outputHeightInPixels: Int
}

/// Mouse movement counters make a move-away-then-back observable. Comparing
/// only the final coordinate would incorrectly authorize that sequence.
struct PrivateModePointerSnapshot: Equatable, Sendable {
    let location: CGPoint
    let mouseMovedCount: UInt32
    let leftDraggedCount: UInt32
    let rightDraggedCount: UInt32
    let otherDraggedCount: UInt32
}

/// Sensitive Accessibility strings never live in a pending click. They are
/// reduced to a per-candidate salted digest in memory, which still lets the
/// exact semantic state be compared without retaining or logging the text.
struct PrivateModeSensitiveAttributeDigest: Equatable, Sendable {
    fileprivate let bytes: [UInt8]
}

/// Value-only identity/state for the exact Accessibility element beneath the
/// model's proposed point. Every field is compared at the aim and mouse-down
/// boundaries; same-window dynamic content therefore cannot inherit an older
/// candidate merely by occupying the same coordinate.
struct PrivateModeTargetElementSnapshot: Equatable, Sendable {
    let processIdentifier: pid_t
    let windowIdentifier: CGWindowID
    let role: String
    let subrole: String?
    let identifierDigest: PrivateModeSensitiveAttributeDigest?
    let frame: CGRect
    let titleDigest: PrivateModeSensitiveAttributeDigest?
    let valueDigest: PrivateModeSensitiveAttributeDigest?
    let descriptionDigest: PrivateModeSensitiveAttributeDigest?
    let enabled: Bool?
    let selected: Bool?
}

/// The live AX object is retained only for the initial hit-test. Chromium and
/// other browser engines may vend a fresh AX proxy for the same unchanged DOM
/// control on consecutive hit-tests, so authorization is bound to the exact
/// process/window/geometry and salted semantic snapshot instead of proxy
/// object identity.
struct PrivateModeTargetElementBinding {
    let hitPoint: CGPoint
    let snapshot: PrivateModeTargetElementSnapshot

    fileprivate let element: AXUIElement
    fileprivate let semanticSalt: Data
    fileprivate let expectedWindowFrame: CGRect
}

struct PrivateModePointTargetCandidate<Element> {
    let element: Element
    let frame: CGRect
    let depth: Int
    let treePath: [Int]?

    init(
        element: Element,
        frame: CGRect,
        depth: Int = 0,
        treePath: [Int]? = nil
    ) {
        self.element = element
        self.frame = frame
        self.depth = depth
        self.treePath = treePath
    }
}

struct PrivateModeTargetSemanticFields {
    let role: String?
    let subrole: String?
    let identifier: String?
    let title: String?
    let value: String?
    let semanticDescription: String?
    let enabled: Bool?
    let selected: Bool?
    let frame: CGRect?
}

enum PrivateModePressableFrameRead {
    case notPressable
    case pressable(CGRect)
    case failure
}

enum PrivateModePressabilityRead {
    case notPressable
    case pressable
    case failure
}

enum PrivateModeAncestorRead<Element> {
    case parent(Element)
    case root
    case failure
}

enum PrivateModePressableAncestorSearch<Element> {
    case found(Element)
    case none
    case failure
}

private struct PrivateModeAXElementIdentity: Hashable {
    let element: AXUIElement

    static func == (
        lhs: PrivateModeAXElementIdentity,
        rhs: PrivateModeAXElementIdentity
    ) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

enum PrivateModePolicy {
    /// Private Mode needs enough text detail to answer reliably in both a
    /// window and a full-screen browser. Ordinary conversational screenshots
    /// retain their separate 1280-pixel bandwidth cap.
    static let privateModeMaximumCaptureDimensionInPixels = 2_560

    /// Security and credential managers are never eligible for capture or
    /// synthetic input in Private Mode.
    private static let blockedBundleIdentifierPrefixes = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "com.apple.SystemSettings",
        "com.apple.loginwindow",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.1password.",
        "com.agilebits.onepassword",
        "com.bitwarden.",
        "com.dashlane.",
        "com.lastpass.",
    ]

    static func isAlwaysExcluded(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return blockedBundleIdentifierPrefixes.contains { prefix in
            bundleIdentifier.caseInsensitiveCompare(prefix) == .orderedSame
                || bundleIdentifier.lowercased().hasPrefix(prefix.lowercased())
        }
    }

    static func decision(
        for context: PrivateModeContext,
        requireFocusedWindow: Bool = true
    ) -> PrivateModeContextDecision {
        guard let bundleIdentifier = context.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return PrivateModeContextDecision(
                isAllowed: false,
                userFacingReason: "Capture blocked because the foreground app could not be verified."
            )
        }

        if isAlwaysExcluded(bundleIdentifier: bundleIdentifier) {
            return PrivateModeContextDecision(
                isAllowed: false,
                userFacingReason: "Capture and clicking are blocked in credential and security apps."
            )
        }

        if requireFocusedWindow {
            guard context.processIdentifier != nil,
                  context.focusedWindowIdentifier != nil,
                  let windowFrame = context.focusedWindowFrame,
                  isFiniteNonEmpty(rect: windowFrame) else {
                return PrivateModeContextDecision(
                    isAllowed: false,
                    userFacingReason: (
                        context.windowVerificationFailure
                            ?? .windowIdentityUnavailable
                    ).userFacingReason
                )
            }
        }

        let secureRole = context.focusedRole == (kAXSecureTextFieldSubrole as String)
        let secureSubrole = context.focusedSubrole == (kAXSecureTextFieldSubrole as String)
        if secureRole || secureSubrole {
            return PrivateModeContextDecision(
                isAllowed: false,
                userFacingReason: "Capture and clicking are blocked while a password field is focused."
            )
        }

        return PrivateModeContextDecision(
            isAllowed: true,
            userFacingReason: "Foreground app and focused field passed the privacy checks."
        )
    }

    static func makeCaptureCapability(
        sessionIdentifier: UUID,
        context: PrivateModeContext
    ) -> PrivateModeCaptureCapability? {
        guard context.processIdentifier != nil,
              context.focusedWindowIdentifier != nil,
              let frame = context.focusedWindowFrame,
              isFiniteNonEmpty(rect: frame) else {
            return nil
        }
        return PrivateModeCaptureCapability(
            sessionIdentifier: sessionIdentifier,
            expectedContext: context
        )
    }

    static func makeVisibleDisplaysCapability(
        sessionIdentifier: UUID,
        context: PrivateModeContext
    ) -> PrivateModeCaptureCapability? {
        guard decision(for: context, requireFocusedWindow: false).isAllowed else { return nil }
        return PrivateModeCaptureCapability(sessionIdentifier: sessionIdentifier,
            expectedContext: context, includesAllDisplays: true)
    }

    static func contextsExactlyMatch(
        _ current: PrivateModeContext,
        _ expected: PrivateModeContext
    ) -> Bool {
        guard current.focusedWindowIdentifier != nil,
              expected.focusedWindowIdentifier != nil else {
            return false
        }
        return current.bundleIdentifier == expected.bundleIdentifier
            && current.processIdentifier == expected.processIdentifier
            && current.focusedWindowIdentifier == expected.focusedWindowIdentifier
            && current.focusedWindowTitle == expected.focusedWindowTitle
            && current.focusedWindowFrame == expected.focusedWindowFrame
    }

    static func captureCapabilityIsCurrent(
        _ capability: PrivateModeCaptureCapability,
        context: PrivateModeContext,
        displayTopology: [PrivateModeDisplaySnapshot]
    ) -> Bool {
        captureCapabilityFailure(
            capability, context: context, displayTopology: displayTopology
        ) == nil
    }

    static func captureCapabilityFailure(
        _ capability: PrivateModeCaptureCapability,
        context: PrivateModeContext,
        displayTopology: [PrivateModeDisplaySnapshot]
    ) -> PrivateModeCaptureFailure? {
        if capability.includesAllDisplays {
            return displayTopology.isEmpty ? .displayUnavailable : nil
        }
        guard contextsExactlyMatch(context, capability.expectedContext) else {
            return .windowChanged
        }
        guard let windowFrame = capability.expectedContext.focusedWindowFrame,
              displayTopology.contains(where: {
                  $0.coreGraphicsFrame.intersects(windowFrame)
              }) else {
            return .displayUnavailable
        }
        guard displayContaining(
            capability.expectedContext.focusedWindowFrame,
            in: displayTopology
        ) != nil else {
            return .windowSpansDisplays
        }
        return nil
    }

    static func captureBindingIsCurrent(
        _ binding: PrivateModeCaptureBinding,
        context: PrivateModeContext,
        displayTopology: [PrivateModeDisplaySnapshot]
    ) -> Bool {
        if binding.includesAllDisplays {
            return displayTopology == binding.displayTopology
                && displayTopology.contains(binding.display)
                && binding.captureFrame == binding.display.coreGraphicsFrame
                && binding.windowFrame == binding.captureFrame
                && binding.screenshotWidthInPixels > 0
                && binding.screenshotHeightInPixels > 0
        }
        guard contextsExactlyMatch(context, binding.expectedContext),
              context.focusedWindowIdentifier == binding.windowIdentifier,
              displayTopology == binding.displayTopology,
              let currentDisplay = displayTopology.first(where: {
                  $0.displayIdentifier == binding.display.displayIdentifier
              }),
              currentDisplay == binding.display,
              displayContaining(binding.windowFrame, in: displayTopology)
                == currentDisplay,
              let currentWindowFrame = context.focusedWindowFrame,
              framesApproximatelyMatch(currentWindowFrame, binding.windowFrame),
              let currentGeometry = privateModeCaptureGeometry(
                  windowFrame: currentWindowFrame,
                  display: currentDisplay
              ),
              framesApproximatelyMatch(
                  currentGeometry.captureFrame,
                  binding.captureFrame
              ) else {
            return false
        }
        return true
    }

    /// Produces a readable, non-upscaled exact-window crop. A window touching
    /// one display edge is clipped to its visible intersection; a window that
    /// spans displays has already failed `displayContaining` and is never
    /// given a geometry plan.
    static func privateModeCaptureGeometry(
        windowFrame: CGRect,
        display: PrivateModeDisplaySnapshot
    ) -> PrivateModeCaptureGeometry? {
        guard isFiniteNonEmpty(rect: windowFrame),
              isFiniteNonEmpty(rect: display.coreGraphicsFrame),
              display.pixelWidth > 0,
              display.pixelHeight > 0 else {
            return nil
        }

        let captureFrame = windowFrame.intersection(
            display.coreGraphicsFrame
        )
        guard isFiniteNonEmpty(rect: captureFrame) else { return nil }

        let sourceRect = CGRect(
            x: captureFrame.minX - display.coreGraphicsFrame.minX,
            y: captureFrame.minY - display.coreGraphicsFrame.minY,
            width: captureFrame.width,
            height: captureFrame.height
        )
        guard isFiniteNonEmpty(rect: sourceRect) else { return nil }

        let nativeWidth = captureFrame.width
            * CGFloat(display.pixelWidth)
            / display.coreGraphicsFrame.width
        let nativeHeight = captureFrame.height
            * CGFloat(display.pixelHeight)
            / display.coreGraphicsFrame.height
        guard nativeWidth.isFinite,
              nativeHeight.isFinite,
              nativeWidth > 0,
              nativeHeight > 0 else {
            return nil
        }

        let longestNativeEdge = max(nativeWidth, nativeHeight)
        let downsampleScale = min(
            1,
            CGFloat(privateModeMaximumCaptureDimensionInPixels)
                / longestNativeEdge
        )
        let outputWidth = max(
            1,
            Int((nativeWidth * downsampleScale).rounded())
        )
        let outputHeight = max(
            1,
            Int((nativeHeight * downsampleScale).rounded())
        )
        return PrivateModeCaptureGeometry(
            captureFrame: captureFrame,
            sourceRect: sourceRect,
            outputWidthInPixels: outputWidth,
            outputHeightInPixels: outputHeight
        )
    }

    /// Converts a model point from the captured JPEG into Quartz coordinates.
    /// No clamping is allowed: a point on the display edge, desktop, Dock, menu
    /// bar, or outside the exact captured window is rejected.
    static func resolvedCandidatePoint(
        imagePoint: CGPoint,
        binding: PrivateModeCaptureBinding
    ) -> CGPoint? {
        guard imagePoint.x.isFinite,
              imagePoint.y.isFinite,
              binding.screenshotWidthInPixels > 0,
              binding.screenshotHeightInPixels > 0 else {
            return nil
        }
        let screenshotWidth = CGFloat(binding.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(binding.screenshotHeightInPixels)
        guard imagePoint.x > 0,
              imagePoint.y > 0,
              imagePoint.x < screenshotWidth,
              imagePoint.y < screenshotHeight else {
            return nil
        }

        let captureFrame = binding.captureFrame
        let point = CGPoint(
            x: captureFrame.minX
                + imagePoint.x * (captureFrame.width / screenshotWidth),
            y: captureFrame.minY
                + imagePoint.y * (captureFrame.height / screenshotHeight)
        )
        guard strictlyContains(captureFrame, point: point),
              strictlyContains(
                  binding.display.coreGraphicsFrame,
                  point: point
              ),
              strictlyContains(binding.windowFrame, point: point) else {
            return nil
        }
        return point
    }

    static func captureBindingStrictlyContains(
        _ point: CGPoint,
        binding: PrivateModeCaptureBinding
    ) -> Bool {
        point.x.isFinite
            && point.y.isFinite
            && strictlyContains(binding.captureFrame, point: point)
            && strictlyContains(binding.display.coreGraphicsFrame, point: point)
            && strictlyContains(binding.windowFrame, point: point)
    }

    static func pointerStayedStill(
        from earlier: PrivateModePointerSnapshot,
        to later: PrivateModePointerSnapshot,
        expectedLocation: CGPoint,
        tolerance: CGFloat = 1
    ) -> Bool {
        guard tolerance >= 0,
              earlier.location.x.isFinite,
              earlier.location.y.isFinite,
              later.location.x.isFinite,
              later.location.y.isFinite,
              expectedLocation.x.isFinite,
              expectedLocation.y.isFinite else {
            return false
        }
        return earlier.mouseMovedCount == later.mouseMovedCount
            && earlier.leftDraggedCount == later.leftDraggedCount
            && earlier.rightDraggedCount == later.rightDraggedCount
            && earlier.otherDraggedCount == later.otherDraggedCount
            && hypot(
                later.location.x - expectedLocation.x,
                later.location.y - expectedLocation.y
            ) <= tolerance
    }

    /// Pure constructor shared by the AX adapter and tests. Raw semantic values
    /// exist only for this call; the returned value contains salted hashes.
    /// Geometry plus a role is not enough to close a dynamic-content gap, so at
    /// least one non-empty title/value/description is mandatory.
    static func makeTargetElementSnapshot(
        processIdentifier: pid_t,
        windowIdentifier: CGWindowID,
        role: String,
        subrole: String?,
        identifier: String?,
        frame: CGRect,
        title: String?,
        value: String?,
        semanticDescription: String?,
        enabled: Bool?,
        selected: Bool?,
        semanticSalt: Data
    ) -> PrivateModeTargetElementSnapshot? {
        let semanticValues = [title, value, semanticDescription]
        let sensitiveValues = [
            identifier,
            title,
            value,
            semanticDescription,
        ]
        guard processIdentifier > 0,
              windowIdentifier > 0,
              !role.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              role.utf8.count <= 256,
              (subrole?.utf8.count ?? 0) <= 256,
              role != (kAXSecureTextFieldSubrole as String),
              subrole != (kAXSecureTextFieldSubrole as String),
              isFiniteNonEmpty(rect: frame),
              semanticSalt.count >= 16,
              sensitiveValues.allSatisfy({
                  ($0?.utf8.count ?? 0) <= 8_192
              }),
              semanticValues.contains(where: {
                  guard let value = $0 else { return false }
                  return !value.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
              }) else {
            return nil
        }

        return PrivateModeTargetElementSnapshot(
            processIdentifier: processIdentifier,
            windowIdentifier: windowIdentifier,
            role: role,
            subrole: subrole,
            identifierDigest: identifier.map {
                sensitiveDigest(
                    attribute: kAXIdentifierAttribute as String,
                    value: $0,
                    salt: semanticSalt
                )
            },
            frame: frame,
            titleDigest: title.map {
                sensitiveDigest(
                    attribute: kAXTitleAttribute as String,
                    value: $0,
                    salt: semanticSalt
                )
            },
            valueDigest: value.map {
                sensitiveDigest(
                    attribute: kAXValueAttribute as String,
                    value: $0,
                    salt: semanticSalt
                )
            },
            descriptionDigest: semanticDescription.map {
                sensitiveDigest(
                    attribute: kAXDescriptionAttribute as String,
                    value: $0,
                    salt: semanticSalt
                )
            },
            enabled: enabled,
            selected: selected
        )
    }

    /// Keep the comparison centralized and exact. In particular, a changed
    /// role/subrole/identifier/frame/title/value/description/enabled/selected
    /// invalidates the old candidate.
    static func targetElementSnapshotsExactlyMatch(
        _ current: PrivateModeTargetElementSnapshot,
        _ expected: PrivateModeTargetElementSnapshot
    ) -> Bool {
        current == expected
    }

    static func targetSnapshotRemainsPresent<Element, Snapshot: Equatable>(
        _ expectedSnapshot: Snapshot,
        exactCandidates: [Element],
        windowCandidates: () -> [PrivateModePointTargetCandidate<Element>]?,
        snapshot: (Element) -> Snapshot?,
        snapshotFrame: (Snapshot) -> CGRect
    ) -> Bool {
        if exactCandidates.contains(where: {
            snapshot($0) == expectedSnapshot
        }) {
            return true
        }
        guard let windowCandidates = windowCandidates() else {
            return false
        }
        return windowCandidates.contains { candidate in
            candidate.frame == snapshotFrame(expectedSnapshot)
                && snapshot(candidate.element) == expectedSnapshot
        }
    }

    /// Prefer a pressable ancestor, then retain the exact hit element as the
    /// fallback. Some browser answer rows expose their visible semantic label
    /// at the click point without exposing AXPress on that label or an ancestor.
    /// The fallback remains exact-point and must pass the same semantic,
    /// process, window, geometry, and later revalidation gates below.
    static func targetElementCandidates<Element>(
        exactHitElement: Element,
        pressableAncestor: Element?
    ) -> [Element] {
        guard let pressableAncestor else {
            return [exactHitElement]
        }
        return [pressableAncestor, exactHitElement]
    }

    static func pressableAncestorSearch<Element>(
        startingAt element: Element,
        maximumVisitedElements: Int = 8,
        pressability: (Element) -> PrivateModePressabilityRead,
        parent: (Element) -> PrivateModeAncestorRead<Element>
    ) -> PrivateModePressableAncestorSearch<Element> {
        guard maximumVisitedElements > 0 else { return .none }
        var current = element
        for _ in 0..<maximumVisitedElements {
            switch pressability(current) {
            case .failure:
                return .failure
            case .pressable:
                return .found(current)
            case .notPressable:
                break
            }
            switch parent(current) {
            case .failure:
                return .failure
            case .root:
                return .none
            case .parent(let parentElement):
                current = parentElement
            }
        }
        return .none
    }

    static func containingWindowAncestor<Element>(
        startingAt element: Element,
        maximumVisitedElements: Int = 32,
        isWindow: (Element) -> Bool,
        parent: (Element) -> PrivateModeAncestorRead<Element>
    ) -> Element? {
        guard maximumVisitedElements > 0 else { return nil }
        var current = element
        for _ in 0..<maximumVisitedElements {
            if isWindow(current) { return current }
            switch parent(current) {
            case .parent(let next): current = next
            case .root, .failure: return nil
            }
        }
        return nil
    }

    static func uniqueSmallestPointTarget<Element>(
        at point: CGPoint,
        candidates: [PrivateModePointTargetCandidate<Element>]
    ) -> Element? {
        uniqueSmallestPointTargetCandidate(
            at: point,
            candidates: candidates
        )?.element
    }

    private static func uniqueSmallestPointTargetCandidate<Element>(
        at point: CGPoint,
        candidates: [PrivateModePointTargetCandidate<Element>]
    ) -> PrivateModePointTargetCandidate<Element>? {
        let containingCandidates = candidates.filter {
            isFiniteNonEmpty(rect: $0.frame)
                && strictlyContains($0.frame, point: point)
        }
        guard let smallestArea = containingCandidates.map({
            $0.frame.width * $0.frame.height
        }).min() else {
            return nil
        }
        let smallestCandidates = containingCandidates.filter {
            $0.frame.width * $0.frame.height == smallestArea
        }
        if smallestCandidates.count == 1 {
            return smallestCandidates[0]
        }
        guard let sharedFrame = smallestCandidates.first?.frame,
              smallestCandidates.allSatisfy({ $0.frame == sharedFrame }),
              smallestCandidates.allSatisfy({ $0.treePath != nil }),
              let deepestPathLength = smallestCandidates.compactMap({
                  $0.treePath?.count
              }).max() else {
            return nil
        }
        let deepestCandidates = smallestCandidates.filter {
            $0.treePath?.count == deepestPathLength
        }
        guard deepestCandidates.count == 1,
              let deepestCandidate = deepestCandidates.first,
              let deepestPath = deepestCandidate.treePath,
              smallestCandidates.allSatisfy({ candidate in
                  guard let candidatePath = candidate.treePath else {
                      return false
                  }
                  return candidatePath == deepestPath
                      || (candidatePath.count < deepestPath.count
                          && Array(
                              deepestPath.prefix(candidatePath.count)
                          ) == candidatePath)
              }) else {
            return nil
        }
        return deepestCandidate
    }

    static func resolvedPointTarget<Element, Snapshot>(
        at point: CGPoint,
        exactCandidates: [Element],
        windowCandidates: () -> [PrivateModePointTargetCandidate<Element>]?,
        snapshot: (Element) -> Snapshot?,
        snapshotFrame: (Snapshot) -> CGRect
    ) -> (element: Element, snapshot: Snapshot)? {
        for element in exactCandidates {
            if let candidateSnapshot = snapshot(element) {
                return (element, candidateSnapshot)
            }
        }

        guard let availableWindowCandidates = windowCandidates(),
              let candidate = uniqueSmallestPointTargetCandidate(
            at: point,
            candidates: availableWindowCandidates
        ),
        let candidateSnapshot = snapshot(candidate.element),
        snapshotFrame(candidateSnapshot) == candidate.frame else {
            return nil
        }
        return (candidate.element, candidateSnapshot)
    }

    static func pointTargetCandidatesInTree<Element, Identity: Hashable>(
        root: Element,
        at point: CGPoint,
        maximumVisitedElements: Int = 3_000,
        maximumDepth: Int = 24,
        identity: (Element) -> Identity,
        children: (Element) -> [Element]?,
        pressableFrame: (Element) -> PrivateModePressableFrameRead
    ) -> [PrivateModePointTargetCandidate<Element>]? {
        var queue: [(element: Element, depth: Int, path: [Int])] = [
            (root, 0, []),
        ]
        var nextIndex = 0
        var visited: Set<Identity> = []
        var candidates: [PrivateModePointTargetCandidate<Element>] = []

        while nextIndex < queue.count,
              visited.count < maximumVisitedElements {
            let current = queue[nextIndex]
            nextIndex += 1
            guard visited.insert(identity(current.element)).inserted else {
                continue
            }

            switch pressableFrame(current.element) {
            case .failure:
                return nil
            case .notPressable:
                break
            case .pressable(let frame):
                guard isFiniteNonEmpty(rect: frame) else { return nil }
                guard strictlyContains(frame, point: point) else { break }
                candidates.append(
                    PrivateModePointTargetCandidate(
                        element: current.element,
                        frame: frame,
                        depth: current.depth,
                        treePath: current.path
                    )
                )
            }

            guard let childElements = children(current.element) else {
                return nil
            }
            guard current.depth < maximumDepth else {
                guard childElements.isEmpty else { return nil }
                continue
            }
            queue.append(contentsOf: childElements.enumerated().map {
                childIndex, child in
                (child, current.depth + 1, current.path + [childIndex])
            })
        }
        guard nextIndex == queue.count else { return nil }
        return candidates
    }

    static func targetElementTreeSemanticFingerprint<
        Element,
        Identity: Hashable
    >(
        root: Element,
        maximumVisitedElements: Int = 3_000,
        maximumDepth: Int = 24,
        identity: (Element) -> Identity,
        children: (Element) -> [Element]?,
        fields: (Element) -> PrivateModeTargetSemanticFields?
    ) -> String? {
        var queue: [(element: Element, depth: Int)] = [(root, 0)]
        var nextIndex = 0
        var visited: Set<Identity> = []
        var hasher = SHA256()
        var hasSemanticValue = false

        func append(_ tag: String, _ value: String?) -> Bool {
            guard let value else {
                hasher.update(data: Data("\(tag):-\n".utf8))
                return true
            }
            guard value.utf8.count <= 8_192 else { return false }
            hasher.update(
                data: Data("\(tag):\(value.utf8.count):".utf8)
            )
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0x0A]))
            return true
        }

        while nextIndex < queue.count,
              visited.count < maximumVisitedElements {
            let current = queue[nextIndex]
            nextIndex += 1
            guard visited.insert(identity(current.element)).inserted else {
                continue
            }
            guard let node = fields(current.element) else { return nil }

            let semanticValues = [
                node.title,
                node.value,
                node.semanticDescription,
            ]
            hasSemanticValue = hasSemanticValue
                || semanticValues.contains(where: {
                    guard let value = $0 else { return false }
                    return !value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                })
            guard append("depth", String(current.depth)),
                  append("role", node.role),
                  append("subrole", node.subrole),
                  append("identifier", node.identifier),
                  append("title", node.title),
                  append("value", node.value),
                  append("description", node.semanticDescription),
                  append("enabled", node.enabled.map(String.init)),
                  append("selected", node.selected.map(String.init)),
                  append(
                    "frame",
                    node.frame.map {
                        [
                            Double($0.minX).bitPattern,
                            Double($0.minY).bitPattern,
                            Double($0.width).bitPattern,
                            Double($0.height).bitPattern,
                        ].map(String.init).joined(separator: ",")
                    }
                  ) else {
                return nil
            }

            guard let childElements = children(current.element) else {
                return nil
            }
            guard current.depth < maximumDepth else {
                guard childElements.isEmpty else { return nil }
                continue
            }
            queue.append(contentsOf: childElements.map {
                ($0, current.depth + 1)
            })
        }
        guard nextIndex == queue.count, hasSemanticValue else { return nil }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// Hit-test the exact model point and bind the first valid candidate in the
    /// already-bound process/window. Browser OCR points commonly land on an
    /// AXStaticText child inside a real AXButton; the pressable ancestor remains
    /// preferred while an exact semantic hit can safely cover custom web rows.
    @MainActor
    static func makeTargetElementBinding(
        at point: CGPoint,
        captureBinding: PrivateModeCaptureBinding
    ) -> PrivateModeTargetElementBinding? {
        guard captureBindingStrictlyContains(
            point,
            binding: captureBinding
        ),
        let expectedProcessIdentifier =
            captureBinding.expectedContext.processIdentifier,
        expectedProcessIdentifier > 0 else {
            return nil
        }

        let semanticSalt = makeSemanticSalt()
        guard let exactCandidates = exactTargetElementCandidates(at: point),
              let resolvedTarget = resolvedPointTarget(
            at: point,
            exactCandidates: exactCandidates,
            windowCandidates: {
                pressableWindowTargetCandidates(
                    at: point,
                    expectedProcessIdentifier: expectedProcessIdentifier,
                    expectedWindowIdentifier: captureBinding.windowIdentifier,
                    expectedWindowFrame: captureBinding.windowFrame
                )
            },
            snapshot: { element in
                targetElementSnapshot(
                    from: element,
                    at: point,
                    expectedProcessIdentifier: expectedProcessIdentifier,
                    expectedWindowIdentifier: captureBinding.windowIdentifier,
                    expectedWindowFrame: captureBinding.windowFrame,
                    semanticSalt: semanticSalt
                )
            },
            snapshotFrame: { $0.frame }
        ) else {
            return nil
        }

        return PrivateModeTargetElementBinding(
            hitPoint: point,
            snapshot: resolvedTarget.snapshot,
            element: resolvedTarget.element,
            semanticSalt: semanticSalt,
            expectedWindowFrame: captureBinding.windowFrame
        )
    }

    /// Re-hit-tests the same coordinate. Every bound process, window, geometry,
    /// role, identifier, text, and state field must still match. This is called
    /// before pointer aim and again immediately before mouse-down, never after
    /// mouse-down. AX proxy identity is intentionally excluded because browser
    /// engines may recreate a proxy while the DOM control remains unchanged.
    @MainActor
    static func targetElementBindingIsCurrent(
        _ binding: PrivateModeTargetElementBinding
    ) -> Bool {
        guard let exactCandidates = exactTargetElementCandidates(
            at: binding.hitPoint
        ) else {
            return false
        }
        return targetSnapshotRemainsPresent(
            binding.snapshot,
            exactCandidates: exactCandidates,
            windowCandidates: {
                pressableWindowTargetCandidates(
                    at: binding.hitPoint,
                    expectedProcessIdentifier:
                        binding.snapshot.processIdentifier,
                    expectedWindowIdentifier:
                        binding.snapshot.windowIdentifier,
                    expectedWindowFrame: binding.expectedWindowFrame
                )
            },
            snapshot: { element in
                targetElementSnapshot(
                    from: element,
                    at: binding.hitPoint,
                    expectedProcessIdentifier:
                        binding.snapshot.processIdentifier,
                    expectedWindowIdentifier:
                        binding.snapshot.windowIdentifier,
                    expectedWindowFrame: binding.expectedWindowFrame,
                    semanticSalt: binding.semanticSalt
                )
            },
            snapshotFrame: { $0.frame }
        )
    }

    static func displayContaining(
        _ windowFrame: CGRect?,
        in topology: [PrivateModeDisplaySnapshot]
    ) -> PrivateModeDisplaySnapshot? {
        guard let windowFrame, isFiniteNonEmpty(rect: windowFrame) else {
            return nil
        }
        let matches = topology.filter {
            let visibleIntersection = $0.coreGraphicsFrame
                .intersection(windowFrame)
            return !visibleIntersection.isNull
                && !visibleIntersection.isInfinite
                && visibleIntersection.width > 0
                && visibleIntersection.height > 0
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func selectExactWindowIdentifier(
        processIdentifier: pid_t,
        title: String?,
        frame: CGRect,
        candidates: [PrivateModeWindowCandidate]
    ) -> CGWindowID? {
        guard isFiniteNonEmpty(rect: frame) else { return nil }
        // AX and CGWindow do not promise the same title representation. Chrome,
        // for example, exposes "Document - Google Chrome - Profile" through AX
        // while CGWindow and ScreenCaptureKit expose only "Document". Window
        // identity therefore comes from the unique PID + layer + exact frame;
        // duplicate geometry remains fail-closed. The AX title is still bound
        // and revalidated across capture -> aim -> click in the context itself.
        _ = title
        let matches = exactFrameWindowMatches(
            processIdentifier: processIdentifier,
            frame: frame,
            candidates: candidates
        )
        return matches.count == 1 ? matches[0].windowIdentifier : nil
    }

    /// Shared by the fallback resolver and its diagnostics so the receipt can
    /// never disagree with the decision about how many windows matched.
    static func exactFrameWindowMatches(
        processIdentifier: pid_t,
        frame: CGRect,
        candidates: [PrivateModeWindowCandidate]
    ) -> [PrivateModeWindowCandidate] {
        guard isFiniteNonEmpty(rect: frame) else { return [] }
        return candidates.filter { candidate in
            candidate.processIdentifier == processIdentifier
                && candidate.layer == 0
                && candidate.isOnScreen
                && framesApproximatelyMatch(candidate.frame, frame)
        }
    }

    /// Pure classification of an unbound focused window. The order mirrors
    /// what the owner can fix first: a missing permission explains every
    /// later symptom, and a hung app explains a missing window.
    static func windowVerificationFailure(
        accessibilityIsTrusted: Bool,
        hasFrontmostApplication: Bool,
        focusedWindowReadError: AXError?,
        hasWindowFrame: Bool,
        hasWindowIdentifier: Bool,
        exactFrameMatchCount: Int
    ) -> PrivateModeWindowVerificationFailure? {
        guard accessibilityIsTrusted else { return .accessibilityNotTrusted }
        guard hasFrontmostApplication else { return .noFrontmostApplication }
        if let focusedWindowReadError {
            switch focusedWindowReadError {
            case .apiDisabled:
                return .accessibilityNotTrusted
            case .cannotComplete:
                return .applicationNotResponding
            default:
                return .focusedWindowUnavailable
            }
        }
        guard hasWindowFrame else { return .windowFrameUnavailable }
        guard !hasWindowIdentifier else { return nil }
        return exactFrameMatchCount > 1
            ? .windowIdentityAmbiguous
            : .windowIdentityUnavailable
    }

    @MainActor
    static func currentDisplayTopology() -> [PrivateModeDisplaySnapshot] {
        NSScreen.screens.compactMap { screen in
            guard let displayIdentifier = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else {
                return nil
            }
            let coreGraphicsFrame = CGDisplayBounds(displayIdentifier)
            let pixelWidth = CGDisplayPixelsWide(displayIdentifier)
            let pixelHeight = CGDisplayPixelsHigh(displayIdentifier)
            guard isFiniteNonEmpty(rect: coreGraphicsFrame),
                  pixelWidth > 0,
                  pixelHeight > 0 else {
                return nil
            }
            return PrivateModeDisplaySnapshot(
                displayIdentifier: displayIdentifier,
                coreGraphicsFrame: coreGraphicsFrame,
                appKitFrame: screen.frame,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }
        .sorted { $0.displayIdentifier < $1.displayIdentifier }
    }

    @MainActor
    static func currentContextDecision() -> PrivateModeContextDecision {
        decision(for: currentContext())
    }

    @MainActor
    static func currentContext() -> PrivateModeContext {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let focusedAttributes = focusedAccessibilityAttributes()
        let focusedWindow = frontmostApplication.map {
            focusedWindowAttributes(processIdentifier: $0.processIdentifier)
        }
        let hasWindowIdentifier = focusedWindow?.identifier != nil
        let hasWindowFrame = focusedWindow?.frame != nil
        return PrivateModeContext(
            bundleIdentifier: frontmostApplication?.bundleIdentifier,
            applicationName: frontmostApplication?.localizedName,
            processIdentifier: frontmostApplication?.processIdentifier,
            focusedRole: focusedAttributes.role,
            focusedSubrole: focusedAttributes.subrole,
            focusedWindowIdentifier: focusedWindow?.identifier,
            focusedWindowTitle: focusedWindow?.title,
            focusedWindowFrame: focusedWindow?.frame,
            windowVerificationFailure: hasWindowIdentifier && hasWindowFrame
                ? nil
                : windowVerificationFailure(
                    accessibilityIsTrusted: AXIsProcessTrusted(),
                    hasFrontmostApplication: frontmostApplication != nil,
                    focusedWindowReadError: focusedWindow?.readError,
                    hasWindowFrame: hasWindowFrame,
                    hasWindowIdentifier: hasWindowIdentifier,
                    exactFrameMatchCount:
                        focusedWindow?.exactFrameMatchCount ?? 0
                )
        )
    }

    private static func focusedWindowAttributes(
        processIdentifier: pid_t
    ) -> (
        identifier: CGWindowID?,
        title: String?,
        frame: CGRect?,
        readError: AXError?,
        exactFrameMatchCount: Int
    ) {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var focusedWindowValue: CFTypeRef?
        let focusedWindowReadResult = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )
        guard focusedWindowReadResult == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else {
            return (
                nil,
                nil,
                nil,
                focusedWindowReadResult == .success
                    ? .noValue
                    : focusedWindowReadResult,
                0
            )
        }

        let focusedWindow = unsafeBitCast(focusedWindowValue, to: AXUIElement.self)
        let title = copyStringAttribute(kAXTitleAttribute as CFString, from: focusedWindow)
        guard let position = copyPointAttribute(kAXPositionAttribute as CFString, from: focusedWindow),
              let size = copySizeAttribute(kAXSizeAttribute as CFString, from: focusedWindow) else {
            return (copyWindowIdentifier(from: focusedWindow), title, nil, nil, 0)
        }
        let frame = CGRect(origin: position, size: size)
        if let exactIdentifier = copyWindowIdentifier(from: focusedWindow) {
            return (exactIdentifier, title, frame, nil, 1)
        }
        // Reached only when the window server lookup is unavailable. The
        // match count stays in the result so an ambiguous pair of same-frame
        // windows is reported as exactly that.
        let exactFrameMatches = exactFrameWindowMatches(
            processIdentifier: processIdentifier,
            frame: frame,
            candidates: currentWindowCandidates()
        )
        return (
            exactFrameMatches.count == 1
                ? exactFrameMatches[0].windowIdentifier
                : nil,
            title,
            frame,
            nil,
            exactFrameMatches.count
        )
    }

    private static func copyWindowIdentifier(
        from element: AXUIElement
    ) -> CGWindowID? {
        // The window server's own identifier for this exact AX window. The
        // strict CGWindow-list resolver remains the fallback when it is absent.
        AccessibilityWindowIdentity.windowIdentifier(of: element)
    }

    private static func currentWindowCandidates() -> [PrivateModeWindowCandidate] {
        guard let rawWindowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return []
        }
        return rawWindowList.compactMap { info in
            guard let identifier = (info[kCGWindowNumber] as? NSNumber)?.uint32Value,
                  identifier != 0,
                  let processIdentifier = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer] as? NSNumber)?.intValue,
                  let rawBounds = info[kCGWindowBounds] else {
                return nil
            }
            let boundsValue = rawBounds as CFTypeRef
            guard CFGetTypeID(boundsValue) == CFDictionaryGetTypeID(),
                  let frame = CGRect(
                      dictionaryRepresentation: unsafeBitCast(
                          boundsValue,
                          to: CFDictionary.self
                      )
                  ),
                  isFiniteNonEmpty(rect: frame) else {
                return nil
            }
            return PrivateModeWindowCandidate(
                windowIdentifier: identifier,
                processIdentifier: processIdentifier,
                title: info[kCGWindowName] as? String,
                frame: frame,
                layer: layer,
                isOnScreen: (info[kCGWindowIsOnscreen] as? NSNumber)?.boolValue
                    ?? false
            )
        }
    }

    private static func focusedAccessibilityAttributes() -> (role: String?, subrole: String?) {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return (nil, nil)
        }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        return (
            copyStringAttribute(kAXRoleAttribute as CFString, from: focusedElement),
            copyStringAttribute(kAXSubroleAttribute as CFString, from: focusedElement)
        )
    }

    private static func copyStringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func copyPointAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func copySizeAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private enum OptionalAccessibilityAttribute<Value> {
        case unavailable
        case value(Value)
    }

    private static func accessibilityElement(
        at point: CGPoint
    ) -> AXUIElement? {
        guard point.x.isFinite,
              point.y.isFinite,
              abs(point.x) <= CGFloat(Float.greatestFiniteMagnitude),
              abs(point.y) <= CGFloat(Float.greatestFiniteMagnitude) else {
            return nil
        }
        let systemWideElement = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &element
        ) == .success else {
            return nil
        }
        return element
    }

    /// At most eight direct ancestors are considered, matching Ace's ordinary
    /// desktop-action click boundary. No tree search, label search, or nearest
    /// geometry fallback is allowed: the returned control must own AXPress and
    /// must contain the original model/OCR point when snapshotted below.
    private static func exactTargetElementCandidates(
        at point: CGPoint
    ) -> [AXUIElement]? {
        guard let exactHitElement = accessibilityElement(at: point) else {
            return []
        }
        switch pressableTargetElement(startingAt: exactHitElement) {
        case .failure:
            return nil
        case .none:
            return [exactHitElement]
        case .found(let pressableAncestor):
            return targetElementCandidates(
                exactHitElement: exactHitElement,
                pressableAncestor: pressableAncestor
            )
        }
    }

    private static func pressableTargetElement(
        startingAt element: AXUIElement
    ) -> PrivateModePressableAncestorSearch<AXUIElement> {
        pressableAncestorSearch(
            startingAt: element,
            pressability: { pressabilityRead(from: $0) },
            parent: { parentRead(from: $0) }
        )
    }

    private static func pressableWindowTargetCandidates(
        at point: CGPoint,
        expectedProcessIdentifier: pid_t,
        expectedWindowIdentifier: CGWindowID,
        expectedWindowFrame: CGRect
    ) -> [PrivateModePointTargetCandidate<AXUIElement>]? {
        guard expectedProcessIdentifier > 0 else { return nil }
        let application = AXUIElementCreateApplication(
            expectedProcessIdentifier
        )
        guard let focusedWindow = copyRequiredElementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: application
        ),
        resolvedWindowIdentifier(
            from: focusedWindow,
            processIdentifier: expectedProcessIdentifier
        ) == expectedWindowIdentifier,
        let focusedWindowPosition = copyPointAttribute(
            kAXPositionAttribute as CFString,
            from: focusedWindow
        ),
        let focusedWindowSize = copySizeAttribute(
            kAXSizeAttribute as CFString,
            from: focusedWindow
        ),
        framesApproximatelyMatch(
            CGRect(
                origin: focusedWindowPosition,
                size: focusedWindowSize
            ),
            expectedWindowFrame
        ) else {
            return nil
        }

        return pointTargetCandidatesInTree(
            root: focusedWindow,
            at: point,
            identity: { PrivateModeAXElementIdentity(element: $0) },
            children: {
                copyElementArrayAttribute(
                    kAXChildrenAttribute as CFString,
                    from: $0
                )
            },
            pressableFrame: { pressableFrameRead(from: $0) }
        )
    }

    private static func pressableFrameRead(
        from element: AXUIElement
    ) -> PrivateModePressableFrameRead {
        switch pressabilityRead(from: element) {
        case .failure:
            return .failure
        case .notPressable:
            return .notPressable
        case .pressable:
            break
        }
        guard let position = copyPointAttribute(
            kAXPositionAttribute as CFString,
            from: element
        ),
        let size = copySizeAttribute(
            kAXSizeAttribute as CFString,
            from: element
        ) else {
            return .failure
        }
        return .pressable(CGRect(origin: position, size: size))
    }

    private static func pressabilityRead(
        from element: AXUIElement
    ) -> PrivateModePressabilityRead {
        var actions: CFArray?
        let actionsError = AXUIElementCopyActionNames(element, &actions)
        return classifyPressability(
            actionsError: actionsError,
            actionNames: actions as? [String]
        )
    }

    static func classifyPressability(
        actionsError: AXError,
        actionNames: [String]?
    ) -> PrivateModePressabilityRead {
        if actionsError == .actionUnsupported
            || actionsError == .attributeUnsupported
            || actionsError == .noValue
            || actionsError == .notImplemented {
            return .notPressable
        }
        guard actionsError == .success,
              let actionNames else {
            return .failure
        }
        guard actionNames.contains(kAXPressAction as String) else {
            return .notPressable
        }
        return .pressable
    }

    private static func parentRead(
        from element: AXUIElement
    ) -> PrivateModeAncestorRead<AXUIElement> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &value
        )
        if error == .noValue || error == .attributeUnsupported {
            return .root
        }
        guard error == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .failure
        }
        return .parent(unsafeBitCast(value, to: AXUIElement.self))
    }

    private static func targetElementTreeSemanticFingerprint(
        startingAt element: AXUIElement
    ) -> String? {
        targetElementTreeSemanticFingerprint(
            root: element,
            identity: { PrivateModeAXElementIdentity(element: $0) },
            children: {
                copyElementArrayAttribute(
                    kAXChildrenAttribute as CFString,
                    from: $0
                )
            },
            fields: { candidate in
                guard let subrole = copyOptionalStringAttribute(
                    kAXSubroleAttribute as CFString,
                    from: candidate
                ),
                let identifier = copyOptionalStringAttribute(
                    kAXIdentifierAttribute as CFString,
                    from: candidate
                ),
                let title = copyOptionalSemanticAttribute(
                    kAXTitleAttribute as CFString,
                    from: candidate
                ),
                let value = copyOptionalSemanticAttribute(
                    kAXValueAttribute as CFString,
                    from: candidate
                ),
                let semanticDescription = copyOptionalSemanticAttribute(
                    kAXDescriptionAttribute as CFString,
                    from: candidate
                ),
                let enabled = copyOptionalBooleanAttribute(
                    kAXEnabledAttribute as CFString,
                    from: candidate
                ),
                let selected = copyOptionalBooleanAttribute(
                    kAXSelectedAttribute as CFString,
                    from: candidate
                ) else {
                    return nil
                }
                let frame: CGRect? = {
                    guard let position = copyPointAttribute(
                        kAXPositionAttribute as CFString,
                        from: candidate
                    ),
                    let size = copySizeAttribute(
                        kAXSizeAttribute as CFString,
                        from: candidate
                    ) else {
                        return nil
                    }
                    return CGRect(origin: position, size: size)
                }()
                return PrivateModeTargetSemanticFields(
                    role: copyStringAttribute(
                        kAXRoleAttribute as CFString,
                        from: candidate
                    ),
                    subrole: optionalValue(subrole),
                    identifier: optionalValue(identifier),
                    title: optionalValue(title),
                    value: optionalValue(value),
                    semanticDescription:
                        optionalValue(semanticDescription),
                    enabled: optionalValue(enabled),
                    selected: optionalValue(selected),
                    frame: frame
                )
            }
        )
    }

    private static func targetElementSnapshot(
        from element: AXUIElement,
        at point: CGPoint,
        expectedProcessIdentifier: pid_t,
        expectedWindowIdentifier: CGWindowID,
        expectedWindowFrame: CGRect,
        semanticSalt: Data
    ) -> PrivateModeTargetElementSnapshot? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(
            element,
            &processIdentifier
        ) == .success,
        processIdentifier == expectedProcessIdentifier,
        let role = copyStringAttribute(
            kAXRoleAttribute as CFString,
            from: element
        ),
        let subroleAttribute = copyOptionalStringAttribute(
            kAXSubroleAttribute as CFString,
            from: element
        ),
        let identifierAttribute = copyOptionalStringAttribute(
            kAXIdentifierAttribute as CFString,
            from: element
        ),
        let titleAttribute = copyOptionalSemanticAttribute(
            kAXTitleAttribute as CFString,
            from: element
        ),
        let valueAttribute = copyOptionalSemanticAttribute(
            kAXValueAttribute as CFString,
            from: element
        ),
        let descriptionAttribute = copyOptionalSemanticAttribute(
            kAXDescriptionAttribute as CFString,
            from: element
        ),
        let enabledAttribute = copyOptionalBooleanAttribute(
            kAXEnabledAttribute as CFString,
            from: element
        ),
        let selectedAttribute = copyOptionalBooleanAttribute(
            kAXSelectedAttribute as CFString,
            from: element
        ),
        let position = copyPointAttribute(
            kAXPositionAttribute as CFString,
            from: element
        ),
        let size = copySizeAttribute(
            kAXSizeAttribute as CFString,
            from: element
        ),
        let targetWindow = containingAccessibilityWindow(of: element) else {
            return nil
        }

        let title = optionalValue(titleAttribute)
        let value = optionalValue(valueAttribute)
        let ownSemanticDescription = optionalValue(descriptionAttribute)
        let hasOwnSemanticValue = [
            title,
            value,
            ownSemanticDescription,
        ].contains(where: {
            guard let value = $0 else { return false }
            return !value.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        })
        let semanticDescription = hasOwnSemanticValue
            ? ownSemanticDescription
            : targetElementTreeSemanticFingerprint(
                startingAt: element
            ).map { "tree-sha256:\($0)" }

        var windowProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(
            targetWindow,
            &windowProcessIdentifier
        ) == .success,
        windowProcessIdentifier == expectedProcessIdentifier,
        let windowIdentifier = resolvedWindowIdentifier(
            from: targetWindow,
            processIdentifier: expectedProcessIdentifier
        ),
        windowIdentifier == expectedWindowIdentifier,
        let windowPosition = copyPointAttribute(
            kAXPositionAttribute as CFString,
            from: targetWindow
        ),
        let windowSize = copySizeAttribute(
            kAXSizeAttribute as CFString,
            from: targetWindow
        ) else {
            return nil
        }

        let frame = CGRect(origin: position, size: size)
        let windowFrame = CGRect(
            origin: windowPosition,
            size: windowSize
        )
        guard framesApproximatelyMatch(
            windowFrame,
            expectedWindowFrame
        ),
        rect(expectedWindowFrame, contains: frame),
        strictlyContains(frame, point: point) else {
            return nil
        }

        return makeTargetElementSnapshot(
            processIdentifier: processIdentifier,
            windowIdentifier: windowIdentifier,
            role: role,
            subrole: optionalValue(subroleAttribute),
            identifier: optionalValue(identifierAttribute),
            frame: frame,
            title: title,
            value: value,
            semanticDescription: semanticDescription,
            enabled: optionalValue(enabledAttribute),
            selected: optionalValue(selectedAttribute),
            semanticSalt: semanticSalt
        )
    }

    private static func containingAccessibilityWindow(
        of element: AXUIElement
    ) -> AXUIElement? {
        if let window = copyRequiredElementAttribute(
            kAXWindowAttribute as CFString,
            from: element
        ) {
            return window
        }
        // Browser web controls can omit AXWindow while retaining their exact
        // parent chain. Resolve that chain; the caller still verifies the PID,
        // CGWindowID, window frame, target geometry, and semantic snapshot.
        return containingWindowAncestor(
            startingAt: element,
            isWindow: {
                copyStringAttribute(kAXRoleAttribute as CFString, from: $0)
                    == kAXWindowRole as String
            },
            parent: { parentRead(from: $0) }
        )
    }

    private static func resolvedWindowIdentifier(
        from window: AXUIElement,
        processIdentifier: pid_t
    ) -> CGWindowID? {
        if let identifier = copyWindowIdentifier(from: window) {
            return identifier
        }
        guard let position = copyPointAttribute(
            kAXPositionAttribute as CFString,
            from: window
        ),
        let size = copySizeAttribute(
            kAXSizeAttribute as CFString,
            from: window
        ) else {
            return nil
        }
        return selectExactWindowIdentifier(
            processIdentifier: processIdentifier,
            title: copyStringAttribute(
                kAXTitleAttribute as CFString,
                from: window
            ),
            frame: CGRect(origin: position, size: size),
            candidates: currentWindowCandidates()
        )
    }

    private static func copyOptionalRawAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> OptionalAccessibilityAttribute<CFTypeRef>? {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) {
        case .success:
            guard let value else { return nil }
            return .value(value)
        case .attributeUnsupported, .noValue, .notImplemented:
            return .unavailable
        default:
            return nil
        }
    }

    private static func copyOptionalStringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> OptionalAccessibilityAttribute<String>? {
        guard let rawAttribute = copyOptionalRawAttribute(
            attribute,
            from: element
        ) else {
            return nil
        }
        switch rawAttribute {
        case .unavailable:
            return .unavailable
        case .value(let value):
            guard let string = value as? String else { return nil }
            return .value(string)
        }
    }

    private static func copyOptionalSemanticAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> OptionalAccessibilityAttribute<String>? {
        guard let rawAttribute = copyOptionalRawAttribute(
            attribute,
            from: element
        ) else {
            return nil
        }
        switch rawAttribute {
        case .unavailable:
            return .unavailable
        case .value(let value):
            if let string = value as? String {
                return .value(string)
            }
            if let attributedString = value as? NSAttributedString {
                return .value(attributedString.string)
            }
            if let number = value as? NSNumber {
                return .value(
                    String(cString: number.objCType)
                        + ":" + number.stringValue
                )
            }
            return nil
        }
    }

    private static func copyOptionalBooleanAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> OptionalAccessibilityAttribute<Bool>? {
        guard let rawAttribute = copyOptionalRawAttribute(
            attribute,
            from: element
        ) else {
            return nil
        }
        switch rawAttribute {
        case .unavailable:
            return .unavailable
        case .value(let value):
            guard let number = value as? NSNumber else { return nil }
            return .value(number.boolValue)
        }
    }

    private static func copyRequiredElementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyElementArrayAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> [AXUIElement]? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        if error == .noValue || error == .attributeUnsupported {
            return []
        }
        guard error == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID(),
              let elements = value as? [AXUIElement] else {
            return nil
        }
        return elements
    }

    private static func optionalValue<Value>(
        _ attribute: OptionalAccessibilityAttribute<Value>
    ) -> Value? {
        switch attribute {
        case .unavailable:
            return nil
        case .value(let value):
            return value
        }
    }

    private static func makeSemanticSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }

    private static func sensitiveDigest(
        attribute: String,
        value: String,
        salt: Data
    ) -> PrivateModeSensitiveAttributeDigest {
        var input = Data("ACE-PRIVATE-TARGET-V1".utf8)
        input.append(0)
        input.append(salt)
        input.append(0)
        input.append(Data(attribute.utf8))
        input.append(0)
        input.append(Data(value.utf8))
        return PrivateModeSensitiveAttributeDigest(
            bytes: Array(SHA256.hash(data: input))
        )
    }

    private static func strictlyContains(_ rect: CGRect, point: CGPoint) -> Bool {
        point.x > rect.minX
            && point.x < rect.maxX
            && point.y > rect.minY
            && point.y < rect.maxY
    }

    private static func rect(_ outer: CGRect, contains inner: CGRect) -> Bool {
        outer.minX <= inner.minX
            && outer.minY <= inner.minY
            && outer.maxX >= inner.maxX
            && outer.maxY >= inner.maxY
    }

    private static func isFiniteNonEmpty(rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }

    private static func framesApproximatelyMatch(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> Bool {
        let tolerance: CGFloat = 1
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
#endif // circuit-convert
