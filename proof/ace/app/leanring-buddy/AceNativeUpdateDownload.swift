import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

nonisolated enum AceNativeUpdateError: LocalizedError {
    case rejected(String)
    var errorDescription: String? {
        switch self { case .rejected(let reason): return reason }
    }
}

/// A private, disk-streamed download. Credentials remain in the request body;
/// cookies, redirects, caches and resume data are deliberately never retained.
/// A retry starts a new entitlement check against a fresh manifest.
nonisolated final class AceNativeUpdateDownload: NSObject,
    URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let release: AceValidatedPublicRelease
    private let destination: URL
    private let entryLatch: StealthEntryLatch
    private let progress: @Sendable (Int64, Int64) -> Void
    private var session: URLSession?
    private var download: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var registration: UUID?
    private var finished = false
    private var cancelled = false
    private var lastProgress: TimeInterval = 0
    private let configuration: URLSessionConfiguration

    init(release: AceValidatedPublicRelease, destination: URL,
         entryLatch: StealthEntryLatch = .shared,
         configuration: URLSessionConfiguration = .ephemeral,
         progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.release = release
        self.destination = destination
        self.entryLatch = entryLatch
        self.progress = progress
        self.configuration = configuration
    }

    func perform(_ request: URLRequest) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = self.configuration
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 60 * 30
                let session = URLSession(configuration: configuration,
                                         delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                let refused = lock.withLock {
                    guard !cancelled, !finished else { return true }
                    self.session = session
                    self.download = task
                    self.continuation = continuation
                    return false
                }
                guard !refused else {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let token = entryLatch.registerSynchronousEntryCutoff { [weak self] in
                    self?.cancel()
                }
                let alreadyFinished = lock.withLock {
                    guard !finished else { return true }
                    registration = token
                    return false
                }
                if alreadyFinished {
                    entryLatch.unregisterSynchronousEntryCutoff(token)
                    return
                }
                let admitted = entryLatch.performUnlessRaised {
                    lock.withLock {
                        guard !finished, !cancelled else { return false }
                        task.resume()
                        return true
                    }
                } ?? false
                if !admitted { cancel() }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        finish(.failure(CancellationError()))
    }

    static func validateResponse(_ response: URLResponse?,
                                 release: AceValidatedPublicRelease) throws {
        guard let response = response as? HTTPURLResponse,
              response.url?.absoluteString == "https://ace-bl.tech/api/ace/update" else {
            throw AceNativeUpdateError.rejected("The update service returned an unexpected response.")
        }
        switch response.statusCode {
        case 200: break
        case 403:
            throw AceNativeUpdateError.rejected("Your licence could not authorize this update. Use Buyer Recovery to check the licence from your original purchase.")
        case 409:
            throw AceNativeUpdateError.rejected("A newer release was published during this download. Try Update & Restart again.")
        default:
            throw AceNativeUpdateError.rejected("The update service is unavailable (HTTP \(response.statusCode)). Try again later.")
        }
        guard response.expectedContentLength == Int64(release.dmgBytes),
              response.value(forHTTPHeaderField: "x-ace-source-sha256") == release.sourceSha256,
              response.value(forHTTPHeaderField: "x-ace-dmg-sha256") == release.dmgSha256 else {
            throw AceNativeUpdateError.rejected("The download does not match the selected release. Check for updates again.")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(AceNativeUpdateError.rejected("The update service tried to redirect the licensed download.")))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        do {
            try Self.validateResponse(downloadTask.response, release: release)
            guard totalBytesWritten <= Int64(release.dmgBytes) else {
                throw AceNativeUpdateError.rejected("The download exceeded the release's verified size.")
            }
            let shouldPublish = lock.withLock {
                let now = Date.timeIntervalSinceReferenceDate
                guard !finished, now - lastProgress >= 0.2
                        || totalBytesWritten == Int64(release.dmgBytes) else { return false }
                lastProgress = now
                return true
            }
            if shouldPublish {
                progress(totalBytesWritten, Int64(release.dmgBytes))
            }
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try Self.validateResponse(downloadTask.response, release: release)
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == release.dmgBytes else {
                throw AceNativeUpdateError.rejected("The update download was interrupted. Try again.")
            }
            let moved = try lock.withLock {
                guard !finished, !cancelled else { return false }
                try FileManager.default.moveItem(at: location, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: destination.path)
                return true
            }
            if moved { finish(.success(destination)) }
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<URL, Error>?, UUID?, URLSession?) in
            guard !finished else { return (nil, nil, nil) }
            finished = true
            let state = (continuation, registration, session)
            continuation = nil
            registration = nil
            session = nil
            download = nil
            return state
        }
        if let token = state.1 { entryLatch.unregisterSynchronousEntryCutoff(token) }
        state.2?.invalidateAndCancel()
        state.0?.resume(with: result)
    }
}
