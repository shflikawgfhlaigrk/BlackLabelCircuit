#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import Foundation
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(ScreenCaptureKit) && !CIRCUIT_WINDOWS_SIM
@preconcurrency import ScreenCaptureKit
#endif

/// One ordinary screenshot operation's synchronous X boundary. Registration
/// happens before any ScreenCaptureKit permission/discovery/capture call. The
/// event-tap callback only flips this small in-memory gate; the one-shot native
/// callback is allowed to finish, but its image is rejected after X.
nonisolated final class CompanionScreenCaptureStealthBoundary:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let entryLatch: StealthEntryLatch
    private var acceptsCapture: Bool
    private var stealthEntryCutoffRegistration: UUID?

    init(entryLatch: StealthEntryLatch = .shared) {
        self.entryLatch = entryLatch
        acceptsCapture = !entryLatch.isRaised
        stealthEntryCutoffRegistration = nil
        stealthEntryCutoffRegistration =
            entryLatch.registerSynchronousEntryCutoff { [weak self] in
                self?.cutOffSynchronously()
            }
    }

    deinit {
        if let stealthEntryCutoffRegistration {
            entryLatch.unregisterSynchronousEntryCutoff(
                stealthEntryCutoffRegistration
            )
        }
    }

    var isCurrent: Bool {
        lock.withLock {
            acceptsCapture && !entryLatch.isRaised
        }
    }

    /// The body must only initiate one callback-form native operation and
    /// return; it must never wait. X either wins first and the body is skipped,
    /// or this invocation returns first and X immediately generation-cuts it.
    func invokeIfCurrent<T>(
        _ body: () throws -> T
    ) rethrows -> T? {
        guard lock.withLock({ acceptsCapture }) else { return nil }
        return try entryLatch.performUnlessRaised(body)
    }

    func cutOffSynchronously() {
        lock.withLock {
            acceptsCapture = false
        }
    }
}

struct CompanionScreenCapture {
    let imageData: Data
    let identity: ScreenCaptureIdentity
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let displayIdentifier: CGDirectDisplayID
    let coreGraphicsDisplayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let privateModeBinding: PrivateModeCaptureBinding?
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures connected displays as JPEG data, labeling each with whether
    /// the user's cursor is on that screen. `onlyCursorScreen` skips the other
    /// monitors entirely — half the capture work and half the vision payload
    /// for the common single-screen question; callers pass false when the
    /// utterance names another monitor.
    /// `excludingSensitiveApplications` excludes password managers, keychain and
    /// security surfaces at ScreenCaptureKit's own content-filter boundary — so
    /// those windows never enter this process's memory, let alone the JPEG
    /// encoder. Used by the Private Mode read, where the whole point is that a
    /// credential window cannot be captured even by accident.
    static func captureAllScreensAsJPEG(
        onlyCursorScreen: Bool = false,
        excludingSensitiveApplications: Bool = false,
        privateModeCapability: PrivateModeCaptureCapability? = nil
    ) async throws -> [CompanionScreenCapture] {
        // Discovery and every requested image share one user-action budget.
        // Separate per-stage timers let one click appear frozen for multiples
        // of the advertised timeout, especially with more than one display.
        let captureDeadlineUptime =
            ScreenCaptureOperationBoundary.deadlineUptime()
        let captureGeneration = UUID()
        let initialDisplayTopology = PrivateModePolicy.currentDisplayTopology()
        let includesAllDisplays = privateModeCapability?.includesAllDisplays == true
        let ordinaryCaptureBoundary =
            privateModeCapability == nil
                ? CompanionScreenCaptureStealthBoundary()
                : nil
        try requireCaptureBoundary(
            privateModeCapability,
            ordinaryCaptureBoundary: ordinaryCaptureBoundary,
            expectedDisplayTopology: initialDisplayTopology
        )
        if #available(macOS 26.0, *),
           ScreenCaptureRoutePolicy.usesDirectRectangleCapture(
               isPrivateMode: privateModeCapability != nil,
               excludesSensitiveApplications:
                   excludingSensitiveApplications
           ),
           let ordinaryCaptureBoundary {
            return try await captureOrdinaryScreensDirectly(
                topology: initialDisplayTopology,
                onlyCursorScreen: onlyCursorScreen,
                boundary: ordinaryCaptureBoundary,
                captureGeneration: captureGeneration,
                deadlineUptime: captureDeadlineUptime
            )
        }
        let content = try await shareableContent(
            ordinaryCaptureBoundary: ordinaryCaptureBoundary,
            deadlineUptime: captureDeadlineUptime
        )
        try requireCaptureBoundary(
            privateModeCapability,
            ordinaryCaptureBoundary: ordinaryCaptureBoundary,
            expectedDisplayTopology: initialDisplayTopology
        )

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }
        let applicationsExcludedFromPrivateCapture = content.applications.filter { application in
            application.bundleIdentifier == ownBundleIdentifier
                || PrivateModePolicy.isAlwaysExcluded(bundleIdentifier: application.bundleIdentifier)
        }
        let onlyWindow: SCWindow? = {
            guard let capability = privateModeCapability,
                  !capability.includesAllDisplays,
                  let expectedProcessIdentifier =
                    capability.expectedContext.processIdentifier,
                  let expectedWindowIdentifier =
                    capability.expectedContext.focusedWindowIdentifier,
                  let expectedFrame =
                    capability.expectedContext.focusedWindowFrame else {
                return nil
            }
            let matches = content.windows.filter { window in
                guard window.windowID == expectedWindowIdentifier,
                      window.owningApplication?.processID
                        == expectedProcessIdentifier,
                      framesApproximatelyMatch(window.frame, expectedFrame) else {
                    return false
                }
                // AX, CGWindow, and ScreenCaptureKit can decorate the same
                // browser title differently. The immutable window ID, owner
                // PID, and exact frame are the capture authority; the original
                // AX title remains bound and is revalidated before the click.
                return true
            }
            return matches.count == 1 ? matches[0] : nil
        }()
        if privateModeCapability != nil, !includesAllDisplays, onlyWindow == nil {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The verified foreground window was not present in ScreenCaptureKit."
                ]
            )
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        let privateModeDisplay: SCDisplay? = {
            guard let onlyWindow,
                  let snapshot = PrivateModePolicy.displayContaining(
                      onlyWindow.frame,
                      in: initialDisplayTopology
                  ) else {
                return nil
            }
            let matches = content.displays.filter {
                $0.displayID == snapshot.displayIdentifier
                    && $0.width == snapshot.pixelWidth
                    && $0.height == snapshot.pixelHeight
                    && framesApproximatelyMatch(
                        $0.frame,
                        snapshot.coreGraphicsFrame
                    )
            }
            return matches.count == 1 ? matches[0] : nil
        }()
        if privateModeCapability != nil, !includesAllDisplays, privateModeDisplay == nil {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The verified foreground window was not wholly contained by its original display."
                ]
            )
        }

        var sortedDisplays: [SCDisplay]
        if let privateModeDisplay {
            sortedDisplays = [privateModeDisplay]
        } else {
            sortedDisplays = content.displays.sorted { displayA, displayB in
                let frameA = nsScreenByDisplayID[displayA.displayID]?.frame
                    ?? displayA.frame
                let frameB = nsScreenByDisplayID[displayB.displayID]?.frame
                    ?? displayB.frame
                let aContainsCursor = frameA.contains(mouseLocation)
                let bContainsCursor = frameB.contains(mouseLocation)
                if aContainsCursor != bContainsCursor {
                    return aContainsCursor
                }
                return displayA.displayID < displayB.displayID
            }
        }
        if onlyCursorScreen, privateModeCapability == nil {
            // The exact-window display sorts first when present; otherwise the
            // cursor display does. Taking one also emits single-screen wording.
            sortedDisplays = Array(sortedDisplays.prefix(1))
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            try requireCaptureBoundary(
                privateModeCapability,
                ordinaryCaptureBoundary: ordinaryCaptureBoundary,
                expectedDisplayTopology: initialDisplayTopology
            )
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let privateModeGeometry: PrivateModeCaptureGeometry? = {
                guard let snapshot = initialDisplayTopology.first(where: {
                          $0.displayIdentifier == display.displayID
                      }) else {
                    return nil
                }
                guard let captureFrame = includesAllDisplays
                    ? snapshot.coreGraphicsFrame : onlyWindow?.frame else { return nil }
                return PrivateModePolicy.privateModeCaptureGeometry(
                    windowFrame: captureFrame,
                    display: snapshot
                )
            }()
            if privateModeCapability != nil, privateModeGeometry == nil {
                throw NSError(
                    domain: "CompanionScreenCapture",
                    code: -7,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The verified foreground window had no valid one-display capture crop."
                    ]
                )
            }

            let filter: SCContentFilter
            if let onlyWindow {
                // Let exactly one verified window through the filter. The
                // sourceRect below then crops the IOSurface to that window's
                // visible intersection, so text is not crushed into a mostly
                // empty whole-display image. Other windows from the same
                // browser process never enter the captured frame.
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: content.applications,
                    exceptingWindows: [onlyWindow]
                )
            } else if excludingSensitiveApplications {
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: applicationsExcludedFromPrivateCapture,
                    exceptingWindows: []
                )
            } else {
                filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)
            }

            let configuration = SCStreamConfiguration()
            if let privateModeGeometry {
                configuration.sourceRect = privateModeGeometry.sourceRect
                configuration.width =
                    privateModeGeometry.outputWidthInPixels
                configuration.height =
                    privateModeGeometry.outputHeightInPixels
            } else {
                let maxDimension = 1280
                let aspectRatio = CGFloat(display.width)
                    / CGFloat(display.height)
                if display.width >= display.height {
                    configuration.width = maxDimension
                    configuration.height = Int(
                        CGFloat(maxDimension) / aspectRatio
                    )
                } else {
                    configuration.height = maxDimension
                    configuration.width = Int(
                        CGFloat(maxDimension) * aspectRatio
                    )
                }
            }

            let cgImage = try await captureImage(
                contentFilter: filter,
                configuration: configuration,
                ordinaryCaptureBoundary: ordinaryCaptureBoundary,
                deadlineUptime: captureDeadlineUptime
            )
            try requireCaptureBoundary(
                privateModeCapability,
                ordinaryCaptureBoundary: ordinaryCaptureBoundary,
                expectedDisplayTopology: initialDisplayTopology
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }
            try requireCaptureBoundary(
                privateModeCapability,
                ordinaryCaptureBoundary: ordinaryCaptureBoundary,
                expectedDisplayTopology: initialDisplayTopology
            )

            let baseScreenLabel: String
            if sortedDisplays.count == 1 {
                baseScreenLabel = isCursorScreen
                    ? "user's screen (cursor is here)"
                    : "focused-window screen (cursor is on another display)"
            } else if isCursorScreen {
                baseScreenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                baseScreenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            let screenshotWidth = cgImage.width
            let screenshotHeight = cgImage.height
            let imageSHA256 = SHA256.hash(data: jpegData).map {
                String(format: "%02x", $0)
            }.joined()
            let identityFrame = privateModeGeometry?.captureFrame
                ?? displayFrame
            let scale = identityFrame.width > 0
                ? CGFloat(screenshotWidth) / identityFrame.width
                : 1
            let identity = ScreenCaptureIdentity(
                generation: captureGeneration,
                displayID: display.displayID,
                originXPoints: Double(identityFrame.origin.x),
                originYPoints: Double(identityFrame.origin.y),
                widthPoints: Double(identityFrame.width),
                heightPoints: Double(identityFrame.height),
                widthPixels: screenshotWidth,
                heightPixels: screenshotHeight,
                scale: Double(scale),
                imageSHA256: imageSHA256
            )
            let screenLabel = baseScreenLabel
                + " (\(identity.promptLabel))"
            let privateModeBinding: PrivateModeCaptureBinding? = {
                guard let capability = privateModeCapability,
                      let snapshot = initialDisplayTopology.first(where: {
                          $0.displayIdentifier == display.displayID
                      }) else {
                    return nil
                }
                return PrivateModeCaptureBinding(
                    sessionIdentifier: capability.sessionIdentifier,
                    expectedContext: capability.expectedContext,
                    windowIdentifier: onlyWindow?.windowID ?? 0,
                    windowFrame: onlyWindow?.frame ?? snapshot.coreGraphicsFrame,
                    captureFrame: privateModeGeometry?.captureFrame
                        ?? snapshot.coreGraphicsFrame,
                    display: snapshot,
                    displayTopology: initialDisplayTopology,
                    screenshotWidthInPixels: screenshotWidth,
                    screenshotHeightInPixels: screenshotHeight,
                    includesAllDisplays: capability.includesAllDisplays
                )
            }()
            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                identity: identity,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                displayIdentifier: display.displayID,
                coreGraphicsDisplayFrame: display.frame,
                screenshotWidthInPixels: screenshotWidth,
                screenshotHeightInPixels: screenshotHeight,
                privateModeBinding: privateModeBinding
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        try requireCaptureBoundary(
            privateModeCapability,
            ordinaryCaptureBoundary: ordinaryCaptureBoundary,
            expectedDisplayTopology: initialDisplayTopology
        )
        return capturedScreens
    }

    /// The macOS 26 rectangle API starts capture immediately and avoids the
    /// system-wide shareable-window enumeration that can take over a minute on
    /// a busy desktop. This path is only for ordinary screen questions. The
    /// filtered SCShareableContent path remains mandatory for Private Mode.
    @available(macOS 26.0, *)
    private static func captureOrdinaryScreensDirectly(
        topology: [PrivateModeDisplaySnapshot],
        onlyCursorScreen: Bool,
        boundary: CompanionScreenCaptureStealthBoundary,
        captureGeneration: UUID,
        deadlineUptime: TimeInterval
    ) async throws -> [CompanionScreenCapture] {
        guard !topology.isEmpty else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No display available for capture"
                ]
            )
        }

        let mouseLocation = NSEvent.mouseLocation
        var displays = topology.sorted { first, second in
            let firstContainsCursor = first.appKitFrame.contains(mouseLocation)
            let secondContainsCursor =
                second.appKitFrame.contains(mouseLocation)
            if firstContainsCursor != secondContainsCursor {
                return firstContainsCursor
            }
            return first.displayIdentifier < second.displayIdentifier
        }
        if onlyCursorScreen {
            displays = Array(displays.prefix(1))
        }

        var captures: [CompanionScreenCapture] = []
        for (displayIndex, display) in displays.enumerated() {
            try requireCaptureBoundary(
                nil,
                ordinaryCaptureBoundary: boundary,
                expectedDisplayTopology: topology
            )
            let isCursorScreen = display.appKitFrame.contains(mouseLocation)
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.pixelWidth)
                / CGFloat(max(display.pixelHeight, 1))
            let outputWidth: Int
            let outputHeight: Int
            if display.pixelWidth >= display.pixelHeight {
                outputWidth = maxDimension
                outputHeight = max(
                    1,
                    Int(CGFloat(maxDimension) / aspectRatio)
                )
            } else {
                outputHeight = maxDimension
                outputWidth = max(
                    1,
                    Int(CGFloat(maxDimension) * aspectRatio)
                )
            }

            let cgImage = try await captureDirectImage(
                displayID: display.displayIdentifier,
                rect: display.coreGraphicsFrame,
                width: outputWidth,
                height: outputHeight,
                boundary: boundary,
                deadlineUptime: deadlineUptime
            )
            try requireCaptureBoundary(
                nil,
                ordinaryCaptureBoundary: boundary,
                expectedDisplayTopology: topology
            )
            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(
                    using: .jpeg,
                    properties: [.compressionFactor: 0.8]
                ) else {
                continue
            }

            let baseScreenLabel: String
            if displays.count == 1 {
                baseScreenLabel = isCursorScreen
                    ? "user's screen (cursor is here)"
                    : "user's screen (cursor is on another display)"
            } else if isCursorScreen {
                baseScreenLabel =
                    "screen \(displayIndex + 1) of \(displays.count) "
                    + "— cursor is on this screen (primary focus)"
            } else {
                baseScreenLabel =
                    "screen \(displayIndex + 1) of \(displays.count) "
                    + "— secondary screen"
            }

            let imageSHA256 = SHA256.hash(data: jpegData).map {
                String(format: "%02x", $0)
            }.joined()
            let scale = display.appKitFrame.width > 0
                ? CGFloat(cgImage.width) / display.appKitFrame.width
                : 1
            let identity = ScreenCaptureIdentity(
                generation: captureGeneration,
                displayID: display.displayIdentifier,
                originXPoints: Double(display.appKitFrame.origin.x),
                originYPoints: Double(display.appKitFrame.origin.y),
                widthPoints: Double(display.appKitFrame.width),
                heightPoints: Double(display.appKitFrame.height),
                widthPixels: cgImage.width,
                heightPixels: cgImage.height,
                scale: Double(scale),
                imageSHA256: imageSHA256
            )
            captures.append(
                CompanionScreenCapture(
                    imageData: jpegData,
                    identity: identity,
                    label: baseScreenLabel + " (\(identity.promptLabel))",
                    isCursorScreen: isCursorScreen,
                    displayWidthInPoints: Int(display.appKitFrame.width),
                    displayHeightInPoints: Int(display.appKitFrame.height),
                    displayFrame: display.appKitFrame,
                    displayIdentifier: display.displayIdentifier,
                    coreGraphicsDisplayFrame: display.coreGraphicsFrame,
                    screenshotWidthInPixels: cgImage.width,
                    screenshotHeightInPixels: cgImage.height,
                    privateModeBinding: nil
                )
            )
        }

        guard !captures.isEmpty else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to capture any screen"
                ]
            )
        }
        try requireCaptureBoundary(
            nil,
            ordinaryCaptureBoundary: boundary,
            expectedDisplayTopology: topology
        )
        return captures
    }

    @available(macOS 26.0, *)
    private static func captureDirectImage(
        displayID: CGDirectDisplayID,
        rect: CGRect,
        width: Int,
        height: Int,
        boundary: CompanionScreenCaptureStealthBoundary,
        deadlineUptime: TimeInterval
    ) async throws -> CGImage {
        if let image = ScreenCaptureImageProvider
            .captureDisplayImageImmediately(
                displayID: displayID,
                width: width,
                height: height
            ) {
            return image
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CGImage, Error>) in
            let continuationBoundary =
                BoundedScreenCaptureContinuation(continuation)
            continuationBoundary.armTimeout(
                stage: "direct image",
                after: ScreenCaptureOperationBoundary.remainingSeconds(
                    untilUptime: deadlineUptime
                )
            )
            let didInvoke = boundary.invokeIfCurrent {
                ScreenCaptureImageProvider.captureSystemScreenshot(
                    rect: rect,
                    width: width,
                    height: height,
                    timeoutSeconds:
                        ScreenCaptureOperationBoundary.remainingSeconds(
                            untilUptime: deadlineUptime
                        )
                ) { image, error in
                    if let error {
                        continuationBoundary.resolve(.failure(error))
                    } else if let image {
                        continuationBoundary.resolve(.success(image))
                    } else {
                        continuationBoundary.resolve(
                            .failure(
                                NSError(
                                    domain: "CompanionScreenCapture",
                                    code: -6,
                                    userInfo: [
                                        NSLocalizedDescriptionKey:
                                            "ScreenCaptureKit returned no image."
                                    ]
                                )
                            )
                        )
                    }
                }
                return true
            }
            if didInvoke != true {
                continuationBoundary.resolve(.failure(CancellationError()))
            }
        }
    }

    private static func shareableContent(
        ordinaryCaptureBoundary:
            CompanionScreenCaptureStealthBoundary?,
        deadlineUptime: TimeInterval
    ) async throws -> SCShareableContent {
        guard let ordinaryCaptureBoundary else {
            return try await SCShareableContent
                .excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
        }

        return try await withCheckedThrowingContinuation { continuation in
            let boundary = BoundedScreenCaptureContinuation(continuation)
            boundary.armTimeout(
                stage: "display discovery",
                after: ScreenCaptureOperationBoundary.remainingSeconds(
                    untilUptime: deadlineUptime
                )
            )
            let didInvoke = ordinaryCaptureBoundary.invokeIfCurrent {
                SCShareableContent.getExcludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                ) { shareableContent, error in
                    if let error {
                        boundary.resolve(.failure(error))
                    } else if let shareableContent {
                        boundary.resolve(.success(shareableContent))
                    } else {
                        boundary.resolve(
                            .failure(NSError(
                                domain: "CompanionScreenCapture",
                                code: -5,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "ScreenCaptureKit returned no shareable content."
                                ]
                            ))
                        )
                    }
                }
                return true
            }
            if didInvoke != true {
                boundary.resolve(.failure(CancellationError()))
            }
        }
    }

    private static func captureImage(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration,
        ordinaryCaptureBoundary:
            CompanionScreenCaptureStealthBoundary?,
        deadlineUptime: TimeInterval
    ) async throws -> CGImage {
        guard let ordinaryCaptureBoundary else {
            return try await ScreenCaptureImageProvider.captureImage(
                contentFilter: contentFilter,
                configuration: configuration
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            let boundary = BoundedScreenCaptureContinuation(continuation)
            boundary.armTimeout(
                stage: "image",
                after: ScreenCaptureOperationBoundary.remainingSeconds(
                    untilUptime: deadlineUptime
                )
            )
            let didInvoke = ordinaryCaptureBoundary.invokeIfCurrent {
                ScreenCaptureImageProvider.captureImage(
                    contentFilter: contentFilter,
                    configuration: configuration
                ) { image, error in
                    if let error {
                        boundary.resolve(.failure(error))
                    } else if let image {
                        boundary.resolve(.success(image))
                    } else {
                        boundary.resolve(
                            .failure(NSError(
                                domain: "CompanionScreenCapture",
                                code: -6,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "ScreenCaptureKit returned no image."
                                ]
                            ))
                        )
                    }
                }
                return true
            }
            if didInvoke != true {
                boundary.resolve(.failure(CancellationError()))
            }
        }
    }

    private static func requireCaptureBoundary(
        _ privateModeCapability: PrivateModeCaptureCapability?,
        ordinaryCaptureBoundary:
            CompanionScreenCaptureStealthBoundary?,
        expectedDisplayTopology: [PrivateModeDisplaySnapshot]
    ) throws {
        guard !Task.isCancelled else { throw CancellationError() }
        guard let privateModeCapability else {
            guard ordinaryCaptureBoundary?.isCurrent == true,
                  !StealthEntryLatch.shared.isRaised,
                  !StealthVisibilityGate.shared.isActive else {
                throw CancellationError()
            }
            return
        }
        guard StealthVisibilityGate.shared.isActive else {
            throw PrivateModeCaptureFailure.modeEnded
        }
        guard PrivateModePolicy.currentDisplayTopology()
                == expectedDisplayTopology else {
            throw PrivateModeCaptureFailure.displayChanged
        }
        if let failure = PrivateModePolicy.captureCapabilityFailure(
            privateModeCapability,
            context: PrivateModePolicy.currentContext(),
            displayTopology: expectedDisplayTopology
        ) {
            throw failure
        }
    }

    private static func framesApproximatelyMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 3
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
#endif // circuit-convert
