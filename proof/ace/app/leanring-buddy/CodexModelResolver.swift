#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
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

/// Retains a digest only while the opened file and its path still identify the
/// same unchanged inode. Capability checks remain cheap between app updates.
nonisolated final class CodexExecutableDigestCache: @unchecked Sendable {
    static let shared = CodexExecutableDigestCache()

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        let mode: mode_t

        init?(_ status: stat) {
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                return nil
            }
            device = status.st_dev
            inode = status.st_ino
            size = status.st_size
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = status.st_mtimespec.tv_nsec
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = status.st_ctimespec.tv_nsec
            mode = status.st_mode
        }
    }

    private struct Entry {
        let identity: Identity
        let digest: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func digest(at path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        // A replaced path could be a FIFO. Open without waiting for a writer,
        // then require a regular file before reading any bytes.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            entries.removeValue(forKey: path)
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var openedStatus = stat()
        guard fstat(handle.fileDescriptor, &openedStatus) == 0,
              let identity = Identity(openedStatus) else {
            entries.removeValue(forKey: path)
            return nil
        }
        if let cached = entries[path], cached.identity == identity,
           pathIdentity(path) == identity {
            return cached.digest
        }
        entries.removeValue(forKey: path)

        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1024 * 1024),
                  !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        var finalStatus = stat()
        guard fstat(handle.fileDescriptor, &finalStatus) == 0,
              Identity(finalStatus) == identity,
              pathIdentity(path) == identity else { return nil }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if entries.count >= 16 { entries.removeAll(keepingCapacity: true) }
        entries[path] = Entry(identity: identity, digest: digest)
        return digest
    }

    private func pathIdentity(_ path: String) -> Identity? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return Identity(status)
    }
}

nonisolated enum CodexModelResolution: Equatable, Sendable {
    case supported(
        model: String,
        executableHash: String,
        accountProof: String
    )
    case authenticationRequired
    case temporarilyUnavailable(reason: String)
    case unsupported(candidatesTried: [String])
}

nonisolated struct CodexModelProbeObservation: Equatable, Sendable {
    let model: String
    let exitCode: Int32
    let answerText: String
    let diagnostic: String
    let timedOut: Bool
}

nonisolated enum CodexModelProbeClassification: Equatable, Sendable {
    case supported
    case unsupportedModel
    case authenticationRequired
    case temporarilyUnavailable(String)
}

nonisolated struct CodexModelCapabilityKey: Equatable, Hashable, Sendable {
    let executableHash: String
    let accountProof: String
}

nonisolated enum CodexCapabilityInvalidationReason: Sendable {
    case cancellation
    case providerSwitch
    case reconnect
    case executableChange
    case stopWork
    case privateMode

    var clearsProvenCapability: Bool {
        switch self {
        case .providerSwitch, .reconnect, .executableChange:
            return true
        case .cancellation, .stopWork, .privateMode:
            return false
        }
    }
}

nonisolated enum CodexModelCapabilityError: Error, Equatable, LocalizedError {
    case authenticationRequired
    case temporarilyUnavailable(String)
    case unsupported([String])

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Codex authentication is required. Reconnect ChatGPT in Ace."
        case let .temporarilyUnavailable(reason):
            return reason
        case let .unsupported(candidates):
            return "This ChatGPT account supports none of the packaged Codex models tried: "
                + candidates.joined(separator: ", ")
        }
    }
}

/// Resolves account capability from bounded, packaged candidates. A different
/// error never triggers a second paid/network process under the fiction that a
/// model name can repair authentication, rate limits, transport, or output.
nonisolated enum CodexModelResolver {
    /// Terra answered through the installed Codex 0.146.0 and Ace-owned account
    /// on 2026-09-12 after both older candidates became unsupported.
    static let packagedCandidates = ["gpt-5.6-sol", "gpt-5.4-mini", "gpt-5.6-terra"]

    static func candidateOrder(cachedModel: String?) -> [String] {
        guard let cachedModel,
              packagedCandidates.contains(cachedModel) else {
            return packagedCandidates
        }
        return [cachedModel]
            + packagedCandidates.filter { $0 != cachedModel }
    }

    static func nextCandidate(
        after observations: [CodexModelProbeObservation],
        cachedModel: String?
    ) -> String? {
        let order = candidateOrder(cachedModel: cachedModel)
        guard let last = observations.last else { return order.first }
        guard classify(last) == .unsupportedModel else { return nil }
        let tried = Set(observations.map(\.model))
        return order.first { !tried.contains($0) }
    }

    static func resolve(
        executableHash: String,
        accountProof: String,
        observations: [CodexModelProbeObservation]
    ) -> CodexModelResolution {
        if let supported = observations.last(where: {
            classify($0) == .supported
        }) {
            return .supported(
                model: supported.model,
                executableHash: executableHash,
                accountProof: accountProof
            )
        }
        guard let last = observations.last else {
            return .temporarilyUnavailable(
                reason: "no Codex capability observation was recorded"
            )
        }
        switch classify(last) {
        case .supported:
            preconditionFailure("supported observations return above")
        case .authenticationRequired:
            return .authenticationRequired
        case let .temporarilyUnavailable(reason):
            return .temporarilyUnavailable(reason: reason)
        case .unsupportedModel:
            let tried = observations.map(\.model)
            if nextCandidate(after: observations, cachedModel: nil) == nil {
                return .unsupported(candidatesTried: tried)
            }
            return .temporarilyUnavailable(
                reason: "another verified Codex model candidate is available"
            )
        }
    }

    static func classify(
        _ observation: CodexModelProbeObservation
    ) -> CodexModelProbeClassification {
        let answer = observation.answerText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if observation.exitCode == 0,
           !observation.timedOut,
           answer.lowercased() == "ready" {
            return .supported
        }
        if observation.timedOut {
            return .temporarilyUnavailable(
                "Codex capability probe timed out"
            )
        }

        let diagnostic = observation.diagnostic.lowercased()
        if let detail = usageLimitDetail(from: observation.diagnostic) {
            return .temporarilyUnavailable(detail)
        }
        if exactUnsupportedModelDiagnostic(diagnostic) {
            return .unsupportedModel
        }
        let authenticationMarkers = [
            "not authenticated", "unauthenticated", "unauthorized",
            "run codex login", "log in", "sign in", "signed out",
            "session expired", "oauth", "auth.json", "http 401",
            " 401", "http 403", " 403",
        ]
        if authenticationMarkers.contains(where: diagnostic.contains) {
            return .authenticationRequired
        }
        if observation.exitCode == 0 {
            return .temporarilyUnavailable(
                "Codex returned an invalid verification response"
            )
        }
        let transientMarkers = [
            "rate limit", "429", "network", "connection", "temporarily",
            "unavailable", "timeout", "timed out", "dns", "tls",
        ]
        if let marker = transientMarkers.first(where: diagnostic.contains) {
            return .temporarilyUnavailable(
                "Codex is temporarily unavailable (\(marker))"
            )
        }
        return .temporarilyUnavailable(
            "Codex process exited \(observation.exitCode)"
        )
    }

    static func usageLimitDetail(from diagnostic: String) -> String? {
        let lowercased = diagnostic.lowercased()
        guard ["usage limit", "usage_limit", "insufficient_quota", "quota exceeded"]
            .contains(where: lowercased.contains) else { return nil }
        var detail = "Codex account usage limit reached."
        if let range = diagnostic.range(
            of: #"try again at [0-9]{1,2}:[0-9]{2}\s*(?:AM|PM)"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let retry = String(diagnostic[range])
            detail += " " + retry.prefix(1).uppercased() + retry.dropFirst() + "."
        } else {
            detail += " Retry after your provider resets the limit."
        }
        return detail
    }

    static func arguments(
        for model: String,
        command: [String]
    ) -> [String] {
        guard packagedCandidates.contains(model),
              let execIndex = command.firstIndex(of: "exec") else {
            return command
        }
        var result = command
        var index = result.index(after: execIndex)
        while index < result.endIndex {
            if result[index] == "--model" || result[index] == "-m" {
                let valueIndex = result.index(after: index)
                guard valueIndex < result.endIndex else {
                    result.remove(at: index)
                    break
                }
                result.removeSubrange(index...valueIndex)
                continue
            }
            index = result.index(after: index)
        }
        result.insert(contentsOf: ["--model", model], at: result.index(after: execIndex))
        return result
    }

    static func executableHash(at path: String) -> String? {
        CodexExecutableDigestCache.shared.digest(at: path)
    }

    /// Hashes credential-file metadata, never credential contents. Reconnect
    /// replaces this proof naturally, while no secret becomes a cache key.
    static func accountCapabilityProof(authFilePath: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: authFilePath
        ), let size = attributes[.size] as? NSNumber,
           let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        let inode = attributes[.systemFileNumber] as? NSNumber
        let device = attributes[.systemNumber] as? NSNumber
        let metadata = [
            device?.stringValue ?? "device-unknown",
            inode?.stringValue ?? "inode-unknown",
            size.stringValue,
            String(modified.timeIntervalSince1970),
        ].joined(separator: ":")
        let digest = SHA256.hash(data: Data(metadata.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func capabilityKey(
        executablePath: String,
        authFilePath: String
    ) -> CodexModelCapabilityKey? {
        guard let executableHash = executableHash(at: executablePath),
              let accountProof = accountCapabilityProof(
                authFilePath: authFilePath
              ) else {
            return nil
        }
        return CodexModelCapabilityKey(
            executableHash: executableHash,
            accountProof: accountProof
        )
    }

    private static func exactUnsupportedModelDiagnostic(
        _ diagnostic: String
    ) -> Bool {
        diagnostic.contains("model is not supported when using codex with a chatgpt account")
            || (diagnostic.contains("the '")
                && diagnostic.contains("' model is not supported")
                && diagnostic.contains("chatgpt account"))
    }
}

nonisolated final class CodexModelCapabilityCache: @unchecked Sendable {
    static let shared = CodexModelCapabilityCache()

    private let lock = NSLock()
    private var supportedResolution: CodexModelResolution?
    private var epoch: UInt64 = 0

    fileprivate struct Snapshot: Sendable {
        let model: String?
        let epoch: UInt64
    }

    func store(_ resolution: CodexModelResolution) {
        guard case .supported = resolution else { return }
        lock.withLock {
            supportedResolution = resolution
        }
    }

    func model(
        executableHash: String,
        accountProof: String
    ) -> String? {
        lock.withLock {
            guard case let .supported(
                model,
                storedExecutableHash,
                storedAccountProof
            ) = supportedResolution,
            storedExecutableHash == executableHash,
            storedAccountProof == accountProof else {
                return nil
            }
            return model
        }
    }

    func modelForCurrentCapability(
        executablePath: String,
        authFilePath: String
    ) -> String? {
        guard let key = CodexModelResolver.capabilityKey(
            executablePath: executablePath,
            authFilePath: authFilePath
        ) else {
            return nil
        }
        return model(
            executableHash: key.executableHash,
            accountProof: key.accountProof
        )
    }

    fileprivate func snapshot(
        for key: CodexModelCapabilityKey
    ) -> Snapshot {
        lock.withLock {
            let model: String?
            if case let .supported(
                storedModel,
                storedExecutableHash,
                storedAccountProof
            ) = supportedResolution,
            storedExecutableHash == key.executableHash,
            storedAccountProof == key.accountProof {
                model = storedModel
            } else {
                model = nil
            }
            return Snapshot(model: model, epoch: epoch)
        }
    }

    fileprivate func currentEpoch() -> UInt64 {
        lock.withLock { epoch }
    }

    @discardableResult
    fileprivate func store(
        _ resolution: CodexModelResolution,
        expectedEpoch: UInt64
    ) -> Bool {
        guard case .supported = resolution else { return false }
        return lock.withLock {
            guard epoch == expectedEpoch else { return false }
            supportedResolution = resolution
            return true
        }
    }

    @discardableResult
    func invalidate() -> UInt64 {
        advanceEpoch(clearingSupportedResolution: true)
    }

    /// Cancels results from the old request generation without necessarily
    /// throwing away a capability already proven for the unchanged executable
    /// and account. Ordinary answer cancellation must remain a fast local
    /// operation; provider/account/executable transitions still clear it.
    @discardableResult
    fileprivate func advanceEpoch(
        clearingSupportedResolution: Bool
    ) -> UInt64 {
        lock.withLock {
            if clearingSupportedResolution {
                supportedResolution = nil
            }
            epoch &+= 1
            return epoch
        }
    }
}

/// One live capability decision for the exact packaged executable and current
/// private `auth.json` metadata. The flight is deliberately process-local: a
/// relaunch proves the returning buyer again instead of trusting persisted
/// model availability or an upstream provider default.
actor CodexModelCapabilityPreflight {
    static let shared = CodexModelCapabilityPreflight(
        cache: .shared
    )

    typealias Probe = @Sendable (String) async -> CodexModelProbeObservation

    private struct FlightIdentity: Equatable, Sendable {
        let key: CodexModelCapabilityKey
        let cacheEpoch: UInt64
    }

    private enum FlightOutcome: Sendable {
        case resolved(CodexModelResolution)
        case cancelled
    }

    private struct Flight {
        let identifier: UUID
        let identity: FlightIdentity
        let task: Task<Void, Never>
        let currentKey: @Sendable () -> CodexModelCapabilityKey?
        var waiters: [
            UUID: CheckedContinuation<CodexModelResolution, any Error>
        ]
    }

    nonisolated private let cache: CodexModelCapabilityCache
    private var flight: Flight?
    private var cancelledWaiters: Set<UUID> = []

    init(cache: CodexModelCapabilityCache) {
        self.cache = cache
    }

    /// Returns a cached exact-key capability or joins/starts the one bounded
    /// live probe. Caller cancellation retires only that waiter; if no waiter
    /// remains, the underlying provider process is cancelled too.
    nonisolated func resolve(
        executablePath: String,
        authFilePath: String,
        probe: @escaping Probe
    ) async throws -> CodexModelResolution {
        try Task.checkCancellation()
        let startingEpoch = cache.currentEpoch()
        guard let executableHash = CodexModelResolver.executableHash(
            at: executablePath
        ) else {
            return .temporarilyUnavailable(
                reason: "The packaged Codex executable could not be verified"
            )
        }
        guard let accountProof = CodexModelResolver.accountCapabilityProof(
            authFilePath: authFilePath
        ) else {
            return .authenticationRequired
        }
        let key = CodexModelCapabilityKey(
            executableHash: executableHash,
            accountProof: accountProof
        )
        let cacheSnapshot = cache.snapshot(for: key)
        guard cacheSnapshot.epoch == startingEpoch else {
            throw CancellationError()
        }
        if let model = cacheSnapshot.model {
            guard CodexModelResolver.capabilityKey(
                executablePath: executablePath,
                authFilePath: authFilePath
            ) == key else {
                cache.invalidate()
                return .temporarilyUnavailable(
                    reason: "Codex capability metadata changed before execution"
                )
            }
            let finalSnapshot = cache.snapshot(for: key)
            guard finalSnapshot.epoch == cacheSnapshot.epoch,
                  finalSnapshot.model == model else {
                throw CancellationError()
            }
            return .supported(
                model: model,
                executableHash: key.executableHash,
                accountProof: key.accountProof
            )
        }

        let waiterIdentifier = UUID()
        let currentKey: @Sendable () -> CodexModelCapabilityKey? = {
            CodexModelResolver.capabilityKey(
                executablePath: executablePath,
                authFilePath: authFilePath
            )
        }
        return try await withTaskCancellationHandler {
            defer {
                Task {
                    await self.retireCancellationMarker(waiterIdentifier)
                }
            }
            try Task.checkCancellation()
            let resolution = try await waitForResolution(
                identity: FlightIdentity(
                    key: key,
                    cacheEpoch: cacheSnapshot.epoch
                ),
                waiterIdentifier: waiterIdentifier,
                currentKey: currentKey,
                probe: probe
            )
            try Task.checkCancellation()
            return resolution
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterIdentifier)
            }
        }
    }

    /// Synchronously advances the cache epoch before scheduling actor teardown.
    /// Even if an old process exits at the same instant, its stale result can no
    /// longer satisfy the guarded store.
    @discardableResult
    nonisolated func invalidate(
        reason: CodexCapabilityInvalidationReason
    ) -> UInt64 {
        let invalidationEpoch = cache.advanceEpoch(
            clearingSupportedResolution: reason.clearsProvenCapability
        )
        Task {
            await self.cancelFlights(olderThan: invalidationEpoch)
        }
        return invalidationEpoch
    }

    func cancelFlights(olderThan invalidationEpoch: UInt64) {
        guard let activeFlight = flight,
              activeFlight.identity.cacheEpoch < invalidationEpoch else {
            return
        }
        flight = nil
        activeFlight.task.cancel()
        resume(
            activeFlight.waiters,
            with: .failure(CancellationError())
        )
    }

    private func waitForResolution(
        identity: FlightIdentity,
        waiterIdentifier: UUID,
        currentKey: @escaping @Sendable () -> CodexModelCapabilityKey?,
        probe: @escaping Probe
    ) async throws -> CodexModelResolution {
        try await withCheckedThrowingContinuation { continuation in
            if cancelledWaiters.remove(waiterIdentifier) != nil {
                continuation.resume(throwing: CancellationError())
                return
            }

            let latestSnapshot = cache.snapshot(for: identity.key)
            guard latestSnapshot.epoch == identity.cacheEpoch else {
                continuation.resume(throwing: CancellationError())
                return
            }
            if let model = latestSnapshot.model {
                continuation.resume(returning: .supported(
                    model: model,
                    executableHash: identity.key.executableHash,
                    accountProof: identity.key.accountProof
                ))
                return
            }

            if var activeFlight = flight,
               activeFlight.identity == identity {
                activeFlight.waiters[waiterIdentifier] = continuation
                flight = activeFlight
                return
            }

            cancelActiveFlight()
            let flightIdentifier = UUID()
            let task = Task { [weak self] in
                let outcome = await Self.runFlight(
                    identity: identity,
                    currentKey: currentKey,
                    probe: probe
                )
                await self?.finishFlight(
                    identifier: flightIdentifier,
                    outcome: outcome
                )
            }
            flight = Flight(
                identifier: flightIdentifier,
                identity: identity,
                task: task,
                currentKey: currentKey,
                waiters: [waiterIdentifier: continuation]
            )
        }
    }

    private nonisolated static func runFlight(
        identity: FlightIdentity,
        currentKey: @escaping @Sendable () -> CodexModelCapabilityKey?,
        probe: @escaping Probe
    ) async -> FlightOutcome {
        var observations: [CodexModelProbeObservation] = []
        while let model = CodexModelResolver.nextCandidate(
            after: observations,
            cachedModel: nil
        ) {
            guard !Task.isCancelled,
                  currentKey() == identity.key else {
                return .cancelled
            }
            let observation = await probe(model)
            guard !Task.isCancelled,
                  currentKey() == identity.key else {
                return .cancelled
            }
            observations.append(observation)
            switch CodexModelResolver.classify(observation) {
            case .supported:
                return .resolved(CodexModelResolver.resolve(
                    executableHash: identity.key.executableHash,
                    accountProof: identity.key.accountProof,
                    observations: observations
                ))
            case .unsupportedModel:
                if CodexModelResolver.nextCandidate(
                    after: observations,
                    cachedModel: nil
                ) != nil {
                    continue
                }
                return .resolved(CodexModelResolver.resolve(
                    executableHash: identity.key.executableHash,
                    accountProof: identity.key.accountProof,
                    observations: observations
                ))
            case .authenticationRequired, .temporarilyUnavailable:
                return .resolved(CodexModelResolver.resolve(
                    executableHash: identity.key.executableHash,
                    accountProof: identity.key.accountProof,
                    observations: observations
                ))
            }
        }
        return .resolved(.unsupported(candidatesTried: []))
    }

    private func finishFlight(
        identifier: UUID,
        outcome: FlightOutcome
    ) {
        guard let activeFlight = flight,
              activeFlight.identifier == identifier else {
            return
        }
        flight = nil

        let result: Result<CodexModelResolution, any Error>
        switch outcome {
        case .cancelled:
            result = .failure(CancellationError())
        case let .resolved(resolution):
            guard cache.currentEpoch() == activeFlight.identity.cacheEpoch,
                  activeFlight.currentKey() == activeFlight.identity.key else {
                cache.invalidate()
                resume(
                    activeFlight.waiters,
                    with: .failure(CancellationError())
                )
                return
            }
            if case .supported = resolution,
               !cache.store(
                    resolution,
                    expectedEpoch: activeFlight.identity.cacheEpoch
               ) {
                result = .failure(CancellationError())
            } else {
                result = .success(resolution)
            }
        }
        resume(activeFlight.waiters, with: result)
    }

    private func cancelWaiter(_ waiterIdentifier: UUID) {
        guard var activeFlight = flight,
              let continuation = activeFlight.waiters.removeValue(
                forKey: waiterIdentifier
              ) else {
            cancelledWaiters.insert(waiterIdentifier)
            return
        }
        continuation.resume(throwing: CancellationError())
        if activeFlight.waiters.isEmpty {
            flight = nil
            activeFlight.task.cancel()
        } else {
            flight = activeFlight
        }
    }

    private func cancelActiveFlight() {
        guard let activeFlight = flight else { return }
        flight = nil
        activeFlight.task.cancel()
        resume(
            activeFlight.waiters,
            with: .failure(CancellationError())
        )
    }

    private func retireCancellationMarker(_ waiterIdentifier: UUID) {
        cancelledWaiters.remove(waiterIdentifier)
    }

    private func resume(
        _ waiters: [
            UUID: CheckedContinuation<CodexModelResolution, any Error>
        ],
        with result: Result<CodexModelResolution, any Error>
    ) {
        for continuation in waiters.values {
            continuation.resume(with: result)
        }
    }
}
