//
//  ScreenCaptureImageProvider.swift
//  leanring-buddy
//
//  One-frame ScreenCaptureKit compatibility boundary. macOS 14 and newer use
//  SCScreenshotManager; macOS 13 uses an SCStream and returns its first frame.
//

#if canImport(CoreImage) && !CIRCUIT_WINDOWS_SIM
import CoreImage
#endif
#if canImport(CoreMedia) && !CIRCUIT_WINDOWS_SIM
import CoreMedia
#endif
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(ImageIO) && !CIRCUIT_WINDOWS_SIM
import ImageIO
#endif
#if canImport(ScreenCaptureKit) && !CIRCUIT_WINDOWS_SIM
@preconcurrency import ScreenCaptureKit
#endif

/// ScreenCaptureKit has no cancellation handle for its one-shot discovery and
/// screenshot callbacks.  A lost ReplayKit reply must still release the Ace
/// task and its visible control instead of leaving "Checking" up forever.
nonisolated enum ScreenCaptureOperationBoundary {
    static let timeoutSeconds: TimeInterval = 12

    static func deadlineUptime(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        now + timeoutSeconds
    }

    static func remainingSeconds(
        untilUptime deadlineUptime: TimeInterval,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval {
        max(0.001, deadlineUptime - now)
    }

    static func isTimeout(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == "ScreenCaptureOperation"
            && error.code == -1001
    }

    static func timeoutError(stage: String) -> NSError {
        NSError(
            domain: "ScreenCaptureOperation",
            code: -1001,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Screen capture \(stage) did not respond within "
                    + "\(Int(timeoutSeconds)) seconds. Try again."
            ]
        )
    }
}

nonisolated enum ScreenCaptureRoutePolicy {
    static func usesDirectRectangleCapture(
        isPrivateMode: Bool,
        excludesSensitiveApplications: Bool
    ) -> Bool {
        !isPrivateMode && !excludesSensitiveApplications
    }
}

/// Exactly-one resolver shared by ScreenCaptureKit callback bridges.  The
/// native callback may arrive after the timeout; that late result is ignored
/// rather than resuming a checked continuation twice.
nonisolated final class BoundedScreenCaptureContinuation<Value: Sendable>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutWorkItem: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func armTimeout(
        stage: String,
        after timeoutSeconds: TimeInterval =
            ScreenCaptureOperationBoundary.timeoutSeconds
    ) {
        let workItem = DispatchWorkItem { [self] in
            resolve(
                .failure(
                    ScreenCaptureOperationBoundary.timeoutError(
                        stage: stage
                    )
                )
            )
        }
        lock.withLock {
            timeoutWorkItem = workItem
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + timeoutSeconds,
            execute: workItem
        )
    }

    func resolve(_ result: Result<Value, Error>) {
        let (pending, timeout) = lock.withLock {
            let pending = continuation
            continuation = nil
            let timeout = timeoutWorkItem
            timeoutWorkItem = nil
            return (pending, timeout)
        }
        timeout?.cancel()
        pending?.resume(with: result)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Runs Apple's system screenshot tool off the main actor and owns its complete
/// lifetime. macOS 27 can leave both ScreenCaptureKit screenshot callbacks
/// queued indefinitely even though the app's Screen Recording preflight is
/// granted. The system tool is a separate capture implementation, so ordinary
/// screen questions retain a bounded, image-backed route on that OS.
///
/// The caller supplies a single-display rectangle. The output lives at a
/// random temporary path, is decoded exactly once, and is removed before the
/// completion handler is invoked. A timeout terminates only this child.
nonisolated private final class SystemScreenshotCaptureOperation:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let process = Process()
    private let outputURL: URL
    private let outputWidth: Int
    private let outputHeight: Int
    private let timeoutSeconds: TimeInterval
    private let completionHandler:
        @Sendable (CGImage?, (any Error)?) -> Void
    private var timeoutWorkItem: DispatchWorkItem?
    private var hasFinished = false
    private var lifetimeAnchor: SystemScreenshotCaptureOperation?

    init(
        rect: CGRect,
        outputWidth: Int,
        outputHeight: Int,
        timeoutSeconds: TimeInterval,
        completionHandler:
            @escaping @Sendable (CGImage?, (any Error)?) -> Void
    ) {
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.timeoutSeconds = timeoutSeconds
        self.completionHandler = completionHandler
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ace-screen-\(UUID().uuidString).png",
                isDirectory: false
            )
        let captureRect = [
            Int(rect.origin.x.rounded(.towardZero)),
            Int(rect.origin.y.rounded(.towardZero)),
            max(1, Int(rect.width.rounded(.up))),
            max(1, Int(rect.height.rounded(.up)))
        ].map(String.init).joined(separator: ",")
        process.executableURL = URL(
            fileURLWithPath: "/usr/sbin/screencapture",
            isDirectory: false
        )
        process.arguments = [
            "-x",
            "-t", "png",
            "-R\(captureRect)",
            outputURL.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func start() {
        lifetimeAnchor = self
        process.terminationHandler = { [weak self] process in
            self?.finishAfterProcessExit(status: process.terminationStatus)
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishWithTimeout()
        }
        lock.withLock {
            timeoutWorkItem = timeout
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + timeoutSeconds,
            execute: timeout
        )
        do {
            try process.run()
        } catch {
            finish(image: nil, error: error)
        }
    }

    private func finishAfterProcessExit(status: Int32) {
        guard status == 0 else {
            finish(
                image: nil,
                error: NSError(
                    domain: "SystemScreenshotCapture",
                    code: Int(status),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The macOS screenshot service did not return an image."
                    ]
                )
            )
            return
        }
        guard let source = CGImageSourceCreateWithURL(
                    outputURL as CFURL,
                    nil
              ),
              let decoded = CGImageSourceCreateImageAtIndex(
                    source,
                    0,
                    nil
              ),
              decoded.width > 0,
              decoded.height > 0 else {
            finish(
                image: nil,
                error: NSError(
                    domain: "SystemScreenshotCapture",
                    code: -2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The macOS screenshot service returned no decodable image."
                    ]
                )
            )
            return
        }
        finish(
            image: ScreenCaptureImageProvider.scaledImage(
                decoded,
                width: outputWidth,
                height: outputHeight
            ),
            error: nil
        )
    }

    private func finishWithTimeout() {
        let shouldTerminate = lock.withLock {
            !hasFinished
        }
        guard shouldTerminate else { return }
        if process.isRunning {
            process.terminate()
        }
        finish(
            image: nil,
            error: ScreenCaptureOperationBoundary.timeoutError(
                stage: "system screenshot"
            )
        )
    }

    private func finish(
        image: CGImage?,
        error: (any Error)?
    ) {
        let (claimed, timeout): (Bool, DispatchWorkItem?) = lock.withLock {
            guard !hasFinished else { return (false, nil) }
            hasFinished = true
            let timeout = timeoutWorkItem
            timeoutWorkItem = nil
            return (true, timeout)
        }
        guard claimed else { return }
        timeout?.cancel()
        process.terminationHandler = nil
        try? FileManager.default.removeItem(at: outputURL)
        lifetimeAnchor = nil
        completionHandler(image, error)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum ScreenCaptureImageProvider {
    /// CoreGraphics' former public display capture entry point remains the
    /// only prompt-returning capture path on macOS 27 systems where both
    /// SCScreenshotManager variants can leave their callback queued for over a
    /// minute. Resolve the system symbol dynamically because the SDK marks the
    /// source declaration unavailable; fail closed to the supported SCK path
    /// if a future system removes it.
    static func captureDisplayImageImmediately(
        displayID: CGDirectDisplayID,
        width: Int,
        height: Int
    ) -> CGImage? {
        typealias CreateDisplayImage = @convention(c) (
            CGDirectDisplayID
        ) -> Unmanaged<CGImage>?

        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "CGDisplayCreateImage"
        ) else {
            return nil
        }
        let createImage = unsafeBitCast(
            symbol,
            to: CreateDisplayImage.self
        )
        guard let fullSizeImage =
            createImage(displayID)?.takeRetainedValue() else {
            return nil
        }
        guard width > 0,
              height > 0,
              fullSizeImage.width > 0,
              fullSizeImage.height > 0 else {
            return fullSizeImage
        }
        return scaledImage(fullSizeImage, width: width, height: height)
    }

    fileprivate static func scaledImage(
        _ image: CGImage,
        width: Int,
        height: Int
    ) -> CGImage? {
        guard width > 0,
              height > 0,
              image.width > 0,
              image.height > 0 else {
            return image
        }
        let scaleX = CGFloat(width) / CGFloat(image.width)
        let scaleY = CGFloat(height) / CGFloat(image.height)
        let scaledImage = CIImage(cgImage: image).transformed(
            by: CGAffineTransform(scaleX: scaleX, y: scaleY)
        )
        return CIContext().createCGImage(
            scaledImage,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }

    /// Bounded ordinary-display capture for macOS versions whose
    /// ScreenCaptureKit one-shot APIs never call their completion handlers.
    /// Private Mode never calls this method; it stays on its filtered SCK path.
    static func captureSystemScreenshot(
        rect: CGRect,
        width: Int,
        height: Int,
        timeoutSeconds: TimeInterval,
        completionHandler:
            @escaping @Sendable (CGImage?, (any Error)?) -> Void
    ) {
        let operation = SystemScreenshotCaptureOperation(
            rect: rect,
            outputWidth: width,
            outputHeight: height,
            timeoutSeconds: max(0.001, timeoutSeconds),
            completionHandler: completionHandler
        )
        operation.start()
    }

    /// macOS 26 added a rectangle screenshot API that does not require the
    /// expensive SCShareableContent window/display enumeration. Use it for
    /// ordinary whole-display captures; Private Mode still goes through the
    /// filtered content path below so excluded windows never enter memory.
    @available(macOS 26.0, *)
    static func captureImage(
        rect: CGRect,
        width: Int,
        height: Int,
        showsCursor: Bool,
        completionHandler:
            @escaping @Sendable (CGImage?, (any Error)?) -> Void
    ) {
        let screenshotConfiguration = SCScreenshotConfiguration()
        screenshotConfiguration.width = width
        screenshotConfiguration.height = height
        screenshotConfiguration.showsCursor = showsCursor
        screenshotConfiguration.dynamicRange = .sdr
        SCScreenshotManager.captureScreenshot(
            rect: rect,
            configuration: screenshotConfiguration
        ) { output, error in
            completionHandler(output?.sdrImage, error)
        }
    }

    static func captureImage(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let boundary = BoundedScreenCaptureContinuation(continuation)
            boundary.armTimeout(stage: "image")
            captureImage(
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
                            domain: "ScreenCaptureImageProvider",
                            code: -1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "ScreenCaptureKit returned no image."
                            ]
                        ))
                    )
                }
            }
        }
    }

    static func captureImage(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration,
        completionHandler:
            @escaping @Sendable (CGImage?, (any Error)?) -> Void
    ) {
        if #available(macOS 26.0, *) {
            let screenshotConfiguration = SCScreenshotConfiguration()
            screenshotConfiguration.width = configuration.width
            screenshotConfiguration.height = configuration.height
            screenshotConfiguration.sourceRect = configuration.sourceRect
            screenshotConfiguration.showsCursor = configuration.showsCursor
            screenshotConfiguration.dynamicRange = .sdr
            SCScreenshotManager.captureScreenshot(
                contentFilter: contentFilter,
                configuration: screenshotConfiguration
            ) { output, error in
                completionHandler(output?.sdrImage, error)
            }
            return
        } else if #available(macOS 14.0, *) {
            SCScreenshotManager.captureImage(
                contentFilter: contentFilter,
                configuration: configuration,
                completionHandler: completionHandler
            )
            return
        }

        let receiver = ScreenCaptureFrameReceiver(
            contentFilter: contentFilter,
            configuration: configuration,
            completionHandler: completionHandler
        )
        receiver.start()
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
private final class ScreenCaptureFrameReceiver:
    NSObject,
    SCStreamDelegate,
    SCStreamOutput,
    @unchecked Sendable
{
    private let contentFilter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let completionHandler:
        @Sendable (CGImage?, (any Error)?) -> Void
    private let sampleQueue = DispatchQueue(
        label: "com.blacklabel.assistant.screenshot-frame"
    )
    private let lock = NSLock()
    private let imageContext = CIContext()

    private var stream: SCStream?
    private var lifetimeAnchor: ScreenCaptureFrameReceiver?
    private var hasFinished = false

    init(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration,
        completionHandler:
            @escaping @Sendable (CGImage?, (any Error)?) -> Void
    ) {
        self.contentFilter = contentFilter
        self.configuration = configuration
        self.completionHandler = completionHandler
    }

    func start() {
        let stream = SCStream(
            filter: contentFilter,
            configuration: configuration,
            delegate: self
        )
        do {
            try stream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: sampleQueue
            )
        } catch {
            finish(image: nil, error: error)
            return
        }

        lock.withLock {
            self.stream = stream
            lifetimeAnchor = self
        }
        stream.startCapture { [weak self] error in
            if let error {
                self?.finish(image: nil, error: error)
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer =
                CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(
            image,
            from: image.extent
        ) else {
            return
        }
        finish(image: cgImage, error: nil)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        finish(image: nil, error: error)
    }

    private func finish(image: CGImage?, error: (any Error)?) {
        let completion: (@Sendable (CGImage?, (any Error)?) -> Void)? =
            lock.withLock {
                guard !hasFinished else { return nil }
                hasFinished = true
                return completionHandler
            }
        guard let completion else { return }

        completion(image, error)
        stream?.stopCapture { _ in }
        lock.withLock {
            stream = nil
            lifetimeAnchor = nil
        }
    }
}
#endif // circuit-convert
