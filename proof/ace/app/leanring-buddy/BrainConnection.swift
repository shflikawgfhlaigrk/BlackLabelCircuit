//
//  BrainConnection.swift
//  Ace
//
//  First-run truth about Ace's brain. Buyer builds prove the licensed hosted
//  model with a live request; internal developer machines may instead prove a
//  local CLI. File existence alone never counts as connected.
//

#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import CircuitPortKit

nonisolated private final class BrainProcessDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ newData: Data) {
        lock.withLock {
            data = newData
        }
    }

    func snapshot() -> Data {
        lock.withLock { data }
    }
}

/// Minimal generation wall for non-process staged work. Claim and final commit
/// share the same latch Private Mode entry raises; the synchronous cutoff only invalidates
/// in-memory generations and therefore never waits for stalled staging I/O.
nonisolated private final class BrainConnectionGenerationAdmission:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let entryLatch: StealthEntryLatch
    private var nextGeneration: UInt64 = 0
    private var currentGenerations: Set<UInt64> = []
    private var cutoffIdentifier: UUID?

    init(entryLatch: StealthEntryLatch = .shared) {
        self.entryLatch = entryLatch
        cutoffIdentifier =
            entryLatch.registerSynchronousEntryCutoff { [weak self] in
                self?.invalidateAll()
            }
    }

    deinit {
        if let cutoffIdentifier {
            entryLatch.unregisterSynchronousEntryCutoff(cutoffIdentifier)
        }
    }

    func claimGeneration() -> UInt64? {
        entryLatch.performUnlessRaised {
            lock.withLock {
                nextGeneration &+= 1
                currentGenerations.insert(nextGeneration)
                return nextGeneration
            }
        }
    }

    func commitIfCurrent(
        generation: UInt64,
        _ body: () -> Void
    ) -> Bool {
        entryLatch.performUnlessRaised {
            lock.withLock {
                guard currentGenerations.contains(generation) else {
                    return false
                }
                body()
                return true
            }
        } == true
    }

    func isCurrent(generation: UInt64) -> Bool {
        entryLatch.performUnlessRaised {
            lock.withLock {
                currentGenerations.contains(generation)
            }
        } ?? false
    }

    func finish(generation: UInt64) {
        _ = lock.withLock {
            currentGenerations.remove(generation)
        }
    }

    private func invalidateAll() {
        lock.withLock {
            currentGenerations.removeAll(keepingCapacity: true)
        }
    }
}

/// Runs staging work without the event-tap latch, then admits only the final
/// bounded publication. A synchronous entry cutoff invalidates the generation
/// even when staging is stalled, so entry returns immediately and the public sink is
/// never reached.
nonisolated final class StealthStagedPublicationAdmission:
    @unchecked Sendable
{
    private let admission: BrainConnectionGenerationAdmission

    init(entryLatch: StealthEntryLatch = .shared) {
        admission = BrainConnectionGenerationAdmission(
            entryLatch: entryLatch
        )
    }

    func stageAndPublish<Artifact>(
        stage: () -> Artifact?,
        validate: (Artifact) -> Bool,
        publish: (Artifact) -> Bool,
        cleanup: (Artifact) -> Void
    ) -> Artifact? {
        guard let generation = admission.claimGeneration() else {
            return nil
        }
        defer { admission.finish(generation: generation) }

        guard let artifact = stage() else { return nil }
        guard admission.isCurrent(generation: generation),
              validate(artifact) else {
            cleanup(artifact)
            return nil
        }

        var didPublish = false
        let wasAdmitted = admission.commitIfCurrent(
            generation: generation
        ) {
            didPublish = publish(artifact)
        }
        guard wasAdmitted, didPublish else {
            cleanup(artifact)
            return nil
        }
        return artifact
    }
}

/// Keeps staging off MainActor while propagating cancellation into the detached
/// worker. A queued Stealth visibility turn can therefore run even if the
/// staging seam is deliberately stalled.
nonisolated enum BrainConnectionStagingWorker {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        let worker = Task.detached(
            priority: .userInitiated,
            operation: operation
        )
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

/// Stages bounded log bytes without holding the event-tap latch, then publishes
/// the complete next file with one admitted same-directory rename. X invalidates
/// the generation synchronously, so staging that loses the race is only removed
/// and can never replace the public log.
nonisolated private final class BrainConnectionLogWriter:
    @unchecked Sendable
{
    static let shared = BrainConnectionLogWriter()

    private static let maximumLogBytes = 256 * 1024
    private let writerLock = NSLock()
    private let publicationAdmission =
        BrainConnectionGenerationAdmission()

    func append(_ lineData: Data, in supportDirectory: URL) {
        guard let generation =
                publicationAdmission.claimGeneration() else {
            return
        }
        defer {
            publicationAdmission.finish(generation: generation)
        }

        writerLock.lock()
        defer { writerLock.unlock() }
        guard publicationAdmission.isCurrent(generation: generation),
              Self.isExistingDirectory(supportDirectory) else {
            return
        }

        let logFileURL =
            supportDirectory.appendingPathComponent("connect.log")
        let stagedFileURL = supportDirectory.appendingPathComponent(
            ".connect-log-\(UUID().uuidString).staging"
        )
        let boundedLine = Data(
            lineData.suffix(Self.maximumLogBytes)
        )
        let existingLimit =
            Self.maximumLogBytes - boundedLine.count
        let existingTail = Self.readTail(
            of: logFileURL,
            maximumBytes: existingLimit
        )
        var nextLogData = Data(existingTail.suffix(existingLimit))
        nextLogData.append(boundedLine)

        guard publicationAdmission.isCurrent(generation: generation) else {
            return
        }
        do {
            try nextLogData.write(
                to: stagedFileURL,
                options: .withoutOverwriting
            )
        } catch {
            return
        }

        var didPublish = false
        let wasAdmitted = publicationAdmission.commitIfCurrent(
            generation: generation
        ) {
            didPublish =
                Darwin.rename(
                    stagedFileURL.path,
                    logFileURL.path
                ) == 0
        }
        if !wasAdmitted || !didPublish {
            try? FileManager.default.removeItem(at: stagedFileURL)
        }
    }

    private static func isExistingDirectory(_ directoryURL: URL) -> Bool {
        var fileStatus = stat()
        return Darwin.lstat(directoryURL.path, &fileStatus) == 0
            && (fileStatus.st_mode & S_IFMT) == S_IFDIR
    }

    private static func readTail(
        of fileURL: URL,
        maximumBytes: Int
    ) -> Data {
        guard maximumBytes > 0 else { return Data() }
        var fileStatus = stat()
        guard Darwin.lstat(fileURL.path, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return Data()
        }
        defer { try? handle.close() }
        do {
            let endOffset = try handle.seekToEnd()
            let bytesToRead = min(UInt64(maximumBytes), endOffset)
            try handle.seek(toOffset: endOffset - bytesToRead)
            return try handle.read(upToCount: Int(bytesToRead)) ?? Data()
        } catch {
            return Data()
        }
    }
}

/// Registers the synchronous entry cutoff before a runner queues any work. Standard
/// input is first staged into an unlinked private file without holding the X
/// latch; only process launch and PID publication use the bounded latch commit.
nonisolated private final class BrainConnectionProcessBoundary:
    @unchecked Sendable
{
    private let admission: StealthModelProcessAdmission
    private let generation: UInt64?

    init(entryLatch: StealthEntryLatch = .shared) {
        let admission = StealthModelProcessAdmission(entryLatch: entryLatch)
        self.admission = admission
        generation = admission.claimGeneration()
    }

    func launchAndPublish(_ process: Process) throws -> Bool {
        guard let generation else { return false }
        return try admission.launchAndPublishIfCurrent(
            generation: generation,
            launch: {
                try process.run()
                return process.processIdentifier
            },
            publish: { _ in }
        )
    }

    func stageStandardInput(_ standardInput: String) throws
        -> FileHandle?
    {
        guard let generation else { return nil }
        return try PrivateModelStandardInput.stage(
            standardInput: standardInput,
            generation: generation,
            admission: admission
        )
    }

    func cancel() {
        guard let generation else { return }
        admission.cancel(generation: generation)
    }

    func clear() {
        guard let generation else { return }
        admission.finish(generation: generation)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Customer-owned model runtimes supported by Ace. All three runtimes ship in
/// the app; Qwen also ships with its sealed GGUF weights and needs no account.
/// Every provider must return a real answer before setup can select it.
nonisolated extension BrainCLI {
    /// Arguments Ace runs directly. Both CLIs own their browser OAuth flow, so
    /// setup never has to launch Terminal or manufacture a shell script.
    var nativeSignInArguments: [String] {
        switch self {
        case .codex:
            return BrainBackend.privacyArguments(
                for: .codex,
                ["login"]
            )
        case .claude:
            return BrainBackend.privacyArguments(
                for: .claude,
                ["auth", "login"]
            )
        case .qwen: return []
        }
    }

    /// Reconnect replaces only the provider session stored inside Ace's
    /// private support directory. It does not touch the buyer's browser,
    /// system-wide CLI configuration, or any other app's account.
    var nativeSignOutArguments: [String] {
        switch self {
        case .codex:
            return BrainBackend.privacyArguments(
                for: .codex,
                ["logout"]
            )
        case .claude:
            return BrainBackend.privacyArguments(
                for: .claude,
                ["auth", "logout"]
            )
        case .qwen:
            return []
        }
    }

    /// Even a presence check is a provider process. It receives the same
    /// privacy boundary as sign-in and real answer calls.
    var versionArguments: [String] {
        BrainBackend.privacyArguments(for: self, ["--version"])
    }

    /// Resolves the executable inside this exact app bundle. Machine-global
    /// installations are deliberately outside the customer trust boundary.
    func resolveExecutablePath() -> String? {
        switch self {
        case .codex:
            return BrainBackend.resolveCodexExecutable()
        case .claude:
            return BrainBackend.resolveClaudeExecutable()
        case .qwen: return AceLocalBrain.resolveBundledExecutable()
        }
    }
}
#endif // circuit-convert

/// What Ace can prove about one CLI right now.
enum BrainConnectionState: Equatable {
    /// Nothing at any known install path.
    case notInstalled
    /// The binary is there and runs, but the CLI reported an auth problem.
    case signedOut
    /// The CLI answered a real prompt. This is the only state that claims a
    /// working brain, and it is never inferred from a file on disk.
    case connected
    /// Present, but the probe failed for a reason that isn't auth. `detail`
    /// carries the CLI's own last words — a buyer support thread starts here.
    case failed
    /// Not probed yet this session.
    case unknown
}

struct BrainConnectionStatus: Equatable {
    var state: BrainConnectionState = .unknown
    /// Version string when known ("2.1.215"), else the CLI's error tail.
    var detail: String = ""
    var executablePath: String?
    var isChecking: Bool = false
    /// Set only by `BrainConnectionProbe.probe` after a subprocess completed a
    /// real answer call. A simulated `.connected` state deliberately leaves
    /// this false, so QA display overrides can never satisfy onboarding.
    var answeredRealProbe: Bool = false

    var isConnected: Bool { state == .connected }
    var isVerifiedConnected: Bool { isConnected && answeredRealProbe }
    var isUsageLimited: Bool {
        state == .failed && detail.lowercased().contains("usage limit")
    }
}

/// The filesystem object that a resolver path names right now.
///
/// The resolver path and symlink-resolved path are both intentional. A new
/// higher-priority install path must not inherit proof from the old path, and a
/// symlink retarget must not inherit proof merely because the locator stayed
/// the same. Device/inode plus size, mode, mtime, and ctime also reject an
/// executable replaced in place at the same resolved path.
nonisolated struct BrainExecutableIdentity: Codable, Equatable {
    let resolverPath: String
    let resolvedExecutablePath: String
    let fileSystemDeviceNumber: UInt64
    let fileSystemFileNumber: UInt64
    let fileSize: UInt64
    let fileMode: UInt32
    let modificationTimeSeconds: Int64
    let modificationTimeNanoseconds: Int64
    let changeTimeSeconds: Int64
    let changeTimeNanoseconds: Int64

    static func capture(resolverPath: String) -> BrainExecutableIdentity? {
        let standardizedResolverPath = URL(fileURLWithPath: resolverPath)
            .standardizedFileURL
            .path
        let resolvedExecutablePath = URL(fileURLWithPath: standardizedResolverPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        guard FileManager.default.isExecutableFile(atPath: resolvedExecutablePath) else {
            return nil
        }

        var fileStatus = stat()
        guard Darwin.lstat(resolvedExecutablePath, &fileStatus) == 0,
              fileStatus.st_size >= 0 else {
            return nil
        }

        return BrainExecutableIdentity(
            resolverPath: standardizedResolverPath,
            resolvedExecutablePath: resolvedExecutablePath,
            fileSystemDeviceNumber: UInt64(fileStatus.st_dev),
            fileSystemFileNumber: UInt64(fileStatus.st_ino),
            fileSize: UInt64(fileStatus.st_size),
            fileMode: UInt32(fileStatus.st_mode),
            modificationTimeSeconds: Int64(fileStatus.st_mtimespec.tv_sec),
            modificationTimeNanoseconds: Int64(fileStatus.st_mtimespec.tv_nsec),
            changeTimeSeconds: Int64(fileStatus.st_ctimespec.tv_sec),
            changeTimeNanoseconds: Int64(fileStatus.st_ctimespec.tv_nsec)
        )
    }
}

/// Persisted proof data is deliberately a value type so receipt acceptance can
/// be tested without touching defaults, the filesystem, or a model provider.
nonisolated struct BrainConnectionReceipt: Codable, Equatable {
    let schemaVersion: Int
    let cliIdentifier: String
    let proofKind: String
    let executableIdentity: BrainExecutableIdentity
    let answeredAt: Date
    let versionDetail: String
}

nonisolated enum BrainConnectionReceiptPolicy {
    static let currentSchemaVersion = 2
    static let isolatedZeroToolAnswerProofKind = "isolated-zero-tool-answer"
    /// Covers the intentional Accessibility relaunch and short first-run tour,
    /// while forcing a new live answer if setup sits unattended.
    static let maximumReceiptAge: TimeInterval = 15 * 60

    static func receiptUnlocksSetup(
        _ receipt: BrainConnectionReceipt,
        expectedCLIIdentifier: String,
        currentExecutableIdentity: BrainExecutableIdentity,
        now: Date,
        maximumReceiptAge: TimeInterval = maximumReceiptAge
    ) -> Bool {
        guard receipt.schemaVersion == currentSchemaVersion,
              receipt.cliIdentifier == expectedCLIIdentifier,
              receipt.proofKind == isolatedZeroToolAnswerProofKind,
              receipt.executableIdentity == currentExecutableIdentity,
              maximumReceiptAge > 0 else {
            return false
        }

        let receiptAge = now.timeIntervalSince(receipt.answeredAt)
        return receiptAge.isFinite
            && receiptAge >= 0
            && receiptAge <= maximumReceiptAge
    }

    /// Setup proof is intentionally short-lived, but an already-connected
    /// provider remains a valid runtime choice after that setup window closes.
    /// Reuse still binds the receipt to the exact bundled executable so an app
    /// update or replaced runtime must be verified again before it can be used.
    static func receiptAllowsRuntimeSelection(
        _ receipt: BrainConnectionReceipt,
        expectedCLIIdentifier: String,
        currentExecutableIdentity: BrainExecutableIdentity
    ) -> Bool {
        receipt.schemaVersion == currentSchemaVersion
            && receipt.cliIdentifier == expectedCLIIdentifier
            && receipt.proofKind == isolatedZeroToolAnswerProofKind
            && receipt.executableIdentity == currentExecutableIdentity
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Durable evidence that Claude answered Ace's real, isolated zero-tool probe.
///
/// `SetupWalkthrough` needs a synchronous predicate while the intro window owns
/// the asynchronous subprocess. Executable presence and `--version` are not
/// that predicate: an installed, signed-out CLI passes both file checks. A
/// receipt is written only after the answer call succeeds and is usable only
/// for a bounded time while the exact resolver path, resolved target, and
/// executable filesystem identity still match.
nonisolated enum BrainConnectionProof {
    private static let keyPrefix = "BrainConnectionProof.v2"
    private static let obsoleteKeyPrefixes = ["BrainConnectionProof.v1"]

    /// The reliable setup predicate. A clean Mac is false, finding a binary is
    /// still false, and only a fresh successful real answer probe can make it
    /// true.
    @MainActor
    static var hasAnsweredRealProbe: Bool {
        if AceBrainRoute.current == .founderHosted {
            return HostedBrainConnectionProof.hasAnsweredRealProbe(
                credentials: AceLicense.shared.hostedBrainCredentials
            )
        }
        return hasAnsweredRealProbe(for: BrainBackend.selectedCLI)
    }

    /// A completed owner keeps the proven runtime after the short setup timer;
    /// actual invocation failures and changed executables still revoke it.
    @MainActor
    static var hasReusableRuntimeProof: Bool {
        if AceBrainRoute.current == .founderHosted {
            return HostedBrainConnectionProof.hasAnsweredRealProbe(
                credentials: AceLicense.shared.hostedBrainCredentials
            )
        }
        return hasReusableRuntimeProof(for: BrainBackend.selectedCLI)
    }

    static func hasReusableRuntimeProof(for cli: BrainCLI, now: Date = Date()) -> Bool {
        guard let receipt = informationalReceipt(for: cli),
              receipt.answeredAt <= now,
              let resolverPath = cli.resolveExecutablePath(),
              let identity = BrainExecutableIdentity.capture(resolverPath: resolverPath) else {
            return false
        }
        return BrainConnectionReceiptPolicy.receiptAllowsRuntimeSelection(
            receipt, expectedCLIIdentifier: cli.rawValue,
            currentExecutableIdentity: identity
        )
    }

    static func hasAnsweredRealProbe(for cli: BrainCLI, now: Date = Date()) -> Bool {
        removeObsoleteReceipts(for: cli)
        guard let receipt = receipt(for: cli),
              let resolverPath = cli.resolveExecutablePath(),
              let currentExecutableIdentity = BrainExecutableIdentity.capture(
                resolverPath: resolverPath
              ) else {
            invalidateCurrentReceipt(cli)
            return false
        }
        guard AceProviderInvocationReceiptStore.runtimeFailure(for: cli)?
            .supersedesProbe(answeredAt: receipt.answeredAt) != true else {
            invalidateCurrentReceipt(cli)
            return false
        }
        guard BrainConnectionReceiptPolicy.receiptAllowsRuntimeSelection(
            receipt,
            expectedCLIIdentifier: cli.rawValue,
            currentExecutableIdentity: currentExecutableIdentity
        ) else {
            invalidateCurrentReceipt(cli)
            return false
        }
        // Expiry closes only the setup gate. Preserve the exact-runtime receipt
        // so the permanent panel can still switch among connected providers.
        return BrainConnectionReceiptPolicy.receiptUnlocksSetup(
            receipt,
            expectedCLIIdentifier: cli.rawValue,
            currentExecutableIdentity: currentExecutableIdentity,
            now: now
        )
    }

    /// Reads a prior successful receipt for informational setup copy only.
    /// Unlike the setup-unlock predicate, this never resolves or executes a
    /// provider and never deletes an expired or identity-mismatched receipt.
    static func informationalReceipt(
        for cli: BrainCLI
    ) -> BrainConnectionReceipt? {
        guard let receipt = receipt(for: cli),
              AceProviderInvocationReceiptStore.runtimeFailure(for: cli)?
                .supersedesProbe(answeredAt: receipt.answeredAt) != true,
              receipt.schemaVersion
                == BrainConnectionReceiptPolicy.currentSchemaVersion,
              receipt.cliIdentifier == cli.rawValue,
              receipt.proofKind
                == BrainConnectionReceiptPolicy
                    .isolatedZeroToolAnswerProofKind else {
            return nil
        }
        return receipt
    }

    @discardableResult
    fileprivate static func recordSuccessfulProbe(
        for cli: BrainCLI,
        executableIdentity: BrainExecutableIdentity,
        versionDetail: String,
        answeredAt: Date = Date()
    ) -> Bool {
        removeObsoleteReceipts(for: cli)
        let receipt = BrainConnectionReceipt(
            schemaVersion: BrainConnectionReceiptPolicy.currentSchemaVersion,
            cliIdentifier: cli.rawValue,
            proofKind: BrainConnectionReceiptPolicy.isolatedZeroToolAnswerProofKind,
            executableIdentity: executableIdentity,
            answeredAt: answeredAt,
            versionDetail: versionDetail
        )
        guard let encoded = try? JSONEncoder().encode(receipt) else {
            invalidateCurrentReceipt(cli)
            return false
        }
        return StealthEntryLatch.shared.performUnlessRaised {
            UserDefaults.standard.set(encoded, forKey: key(for: cli))
            return true
        } == true
    }

    fileprivate static func invalidate(_ cli: BrainCLI) {
        if cli == .codex {
            CodexModelCapabilityPreflight.shared.invalidate(
                reason: .reconnect
            )
        }
        invalidateCurrentReceipt(cli)
        removeObsoleteReceipts(for: cli)
    }

    private static func invalidateCurrentReceipt(_ cli: BrainCLI) {
        let receiptKey = key(for: cli)
        guard UserDefaults.standard.object(forKey: receiptKey) != nil else { return }
        UserDefaults.standard.removeObject(forKey: receiptKey)
    }

    private static func removeObsoleteReceipts(for cli: BrainCLI) {
        for obsoleteKeyPrefix in obsoleteKeyPrefixes {
            let receiptKey = "\(obsoleteKeyPrefix).\(cli.rawValue)"
            // Panel status reads share defaults with @AppStorage. Even removing
            // an absent key emits a change and can restart the SwiftUI render.
            guard UserDefaults.standard.object(forKey: receiptKey) != nil else { continue }
            UserDefaults.standard.removeObject(forKey: receiptKey)
        }
    }

    private static func receipt(for cli: BrainCLI) -> BrainConnectionReceipt? {
        guard let encoded = UserDefaults.standard.data(forKey: key(for: cli)) else {
            return nil
        }
        return try? JSONDecoder().decode(BrainConnectionReceipt.self, from: encoded)
    }

    private static func key(for cli: BrainCLI) -> String {
        "\(keyPrefix).\(cli.rawValue)"
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Probes the shipped provider CLIs and publishes what it found. Setup and the
/// permanent panel each own a short-lived model, while provider subprocesses
/// remain generation-bound so one surface cannot publish another's result.
@MainActor
final class BrainConnectionModel: ObservableObject {
    @Published private(set) var statuses: [BrainCLI: BrainConnectionStatus] = [
        .codex: BrainConnectionStatus(),
        .claude: BrainConnectionStatus(),
        .qwen: BrainConnectionStatus(),
    ]
    @Published private var hostedProbeStatus = BrainConnectionStatus()
    private(set) var hostedStatus: BrainConnectionStatus {
        get {
            let credentials = AceLicense.shared.hostedBrainCredentials
            guard !hostedProbeStatus.isChecking else { return hostedProbeStatus }
            let hasProof = HostedBrainConnectionProof.hasAnsweredRealProbe(credentials: credentials)
            if !hasProof,
               let failure = HostedBrainConnectionProof.runtimeFailure(credentials: credentials) {
                return BrainConnectionStatus(
                    state: failure.cause.contains("rejected the account connection") ? .signedOut : .failed,
                    detail: failure.cause + ". Check again to verify access.",
                    executablePath: nil, isChecking: false, answeredRealProbe: false
                )
            }
            if hostedProbeStatus.isVerifiedConnected, !hasProof {
                return BrainConnectionStatus(
                    state: .unknown,
                    detail: "Access changed or the last check expired. Check again to verify access.",
                    executablePath: nil, isChecking: false, answeredRealProbe: false
                )
            }
            return hostedProbeStatus
        }
        set { hostedProbeStatus = newValue }
    }
    @Published private(set) var providerOnboardingStates:
        [BrainCLI: BrainConnectionProviderOnboardingState] = [
            .codex: .readyToConnect,
            .claude: .readyToConnect,
            .qwen: .readyToConnect,
        ]

    /// The transport proven by the intro screen.
    @Published var selectedBrain: BrainCLI
    private var runtimeFailureObservation: AnyCancellable?

    init() {
        selectedBrain = BrainBackend.selectedCLI
        // Persist only the proof-backed selection chosen by the runtime policy.
        // This repairs stale defaults without discarding a proven Claude setup.
        UserDefaults.standard.set(
            selectedBrain.rawValue,
            forKey: "SelectedBrainCLI"
        )
        UserDefaults.standard.removeObject(forKey: "BrainBackend")
        loadCachedStatuses()
        runtimeFailureObservation = NotificationCenter.default.circuitCombine.publisher(
            for: .aceProviderInvocationReceiptDidChange
        ).receive(on: RunLoop.main.circuitScheduler).sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Automatic lifecycle requests are display-only. A real provider process
    /// may start only through an explicit Check/Connect action.
    func handleProbeRequest(_ source: BrainConnectionProbeRequestSource) {
        switch BrainConnectionStartupPolicy.action(for: source) {
        case .cachedOnly:
            loadCachedStatuses()
        case .runRealProbe:
            refreshAll()
        }
    }

    func userRequestedRefreshAll() {
        // The founder-hosted card has its own explicit activation action. A
        // customer-owned provider may be launched only by connectProvider.
        guard AceBrainRoute.current == .founderHosted else {
            return
        }
        handleProbeRequest(.explicitRefresh)
    }

    /// Publishes executable and prior-receipt facts without executing a CLI.
    /// Cached receipts are deliberately never rendered as a live connection.
    private func loadCachedStatuses() {
        guard AceBrainRoute.current == .customerOwned else {
            hostedStatus = BrainConnectionStatus(
                state: .unknown,
                detail:
                    "Not checked this session. Press Check again to verify your access.",
                executablePath: nil,
                isChecking: false,
                answeredRealProbe: false
            )
            return
        }

        for cli in BrainCLI.customerChoices {
            let resolverPath = cli.resolveExecutablePath()
            let executableIdentity = resolverPath.flatMap {
                BrainExecutableIdentity.capture(resolverPath: $0)
            }
            let receipt = BrainConnectionProof.informationalReceipt(for: cli)
            let summary = BrainConnectionStartupPolicy.cachedStatus(
                runtimeAvailable: executableIdentity != nil,
                hasStoredReceipt: receipt != nil,
                receiptMatchesRuntime:
                    receipt?.executableIdentity == executableIdentity,
                versionDetail: receipt?.versionDetail ?? ""
            )
            statuses[cli] = BrainConnectionStatus(
                state: summary.kind == .runtimeMissing
                    ? .notInstalled : .unknown,
                detail: summary.detail,
                executablePath:
                    executableIdentity?.resolvedExecutablePath ?? resolverPath,
                isChecking: false,
                answeredRealProbe: false
            )
        }
    }

    /// True while any probe is in flight (drives the button spinner).
    var isChecking: Bool {
        AceBrainRoute.current == .customerOwned
            ? BrainCLI.customerChoices.contains { status(for: $0).isChecking }
            : hostedStatus.isChecking
    }

    /// True when at least one CLI answered during this model's live probe. The
    /// intro gates navigation on current-session evidence; the walkthrough uses
    /// the same fresh, identity-bound receipt as its durable predicate.
    var hasAnsweredRealProbeThisSession: Bool {
        if AceBrainRoute.current == .founderHosted {
            return hostedStatus.isVerifiedConnected
                && HostedBrainConnectionProof.hasAnsweredRealProbe(
                    credentials: AceLicense.shared.hostedBrainCredentials
                )
        }
        return BrainCLI.customerChoices.contains { cli in
            status(for: cli).isVerifiedConnected
                && BrainConnectionProof.hasAnsweredRealProbe(for: cli)
        }
    }

    func status(for cli: BrainCLI) -> BrainConnectionStatus {
        let status = statuses[cli] ?? BrainConnectionStatus()
        guard !status.isChecking,
              let failure = AceProviderInvocationReceiptStore.runtimeFailure(for: cli),
              BrainConnectionProof.informationalReceipt(for: cli) == nil else {
            return status
        }
        return BrainConnectionStatus(
            state: failure.cause.contains("rejected the account connection") ? .signedOut : .failed,
            detail: failure.cause + ". Check account to verify it again.",
            executablePath: status.executablePath,
            isChecking: false,
            answeredRealProbe: false
        )
    }

    func providerOnboardingState(
        for cli: BrainCLI
    ) -> BrainConnectionProviderOnboardingState {
        providerOnboardingStates[cli]
            ?? BrainConnectionProviderOnboardingPolicy.initialState
    }

    /// A provider receipt is deliberately invalidated when the bundled runtime
    /// changes, but the buyer's Ace-owned login survives an upgrade. Detect
    /// only the presence of known private credential files — never their
    /// contents — so the permanent control still says Reconnect and replaces
    /// that account instead of silently reusing it as a new Connect.
    func hasPrivateAuthenticationState(for cli: BrainCLI) -> Bool {
        let supportRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/BlackLabel",
                isDirectory: true
            )
        let providerDirectory: URL
        let credentialFileNames: [String]
        switch cli {
        case .codex:
            providerDirectory = supportRoot.appendingPathComponent(
                "Codex",
                isDirectory: true
            )
            credentialFileNames = ["auth.json"]
        case .claude:
            providerDirectory = supportRoot.appendingPathComponent(
                "Claude",
                isDirectory: true
            )
            credentialFileNames = [
                ".credentials.json",
                "credentials.json",
                ".claude.json",
            ]
        case .qwen:
            return false
        }
        return credentialFileNames.contains { fileName in
            FileManager.default.fileExists(
                atPath: providerDirectory
                    .appendingPathComponent(fileName, isDirectory: false)
                    .path
            )
        }
    }

    func canVerifyExistingAuthentication(for cli: BrainCLI) -> Bool {
        BrainConnectionAuthenticationPolicy.shouldVerifyExistingSession(
            hasPrivateState: hasPrivateAuthenticationState(for: cli),
            lastAttemptRejectedAuthentication:
                providerOnboardingState(for: cli) == .retryConnection
                    && status(for: cli).state == .signedOut
        )
    }

    private var visibleEffectsAreAllowed: Bool {
        !StealthEntryLatch.shared.isRaised
            && !StealthVisibilityGate.shared.isActive
    }

    private var providerEffectsAreAllowed: Bool {
        visibleEffectsAreAllowed
            && AceLicense.shared.admits(.providerConnection)
    }

    @discardableResult
    private func commitVisibleEffect(
        _ effect: () -> Bool
    ) -> Bool {
        StealthVisibleEffectAdmission.commit(
            visibilityIsBlocked: {
                StealthVisibilityGate.shared.isActive
            },
            performUnlessRaised: { body in
                StealthEntryLatch.shared.performUnlessRaised(body)
            },
            effect: effect
        )
    }

    /// A real answer remains reusable after the 15-minute setup gate expires.
    /// Cloud providers must also retain their Ace-owned credential file; Qwen
    /// is local and needs only its exact verified runtime identity.
    func canSelectConnectedProvider(_ cli: BrainCLI) -> Bool {
        guard BrainCLI.customerChoices.contains(cli) else { return false }
        let current = status(for: cli)
        guard current.state != .failed, current.state != .signedOut,
              current.state != .notInstalled else { return false }
        if current.isVerifiedConnected {
            return true
        }
        guard let receipt = BrainConnectionProof.informationalReceipt(for: cli),
              let resolverPath = cli.resolveExecutablePath(),
              let executableIdentity = BrainExecutableIdentity.capture(
                resolverPath: resolverPath
              ),
              BrainConnectionReceiptPolicy.receiptAllowsRuntimeSelection(
                receipt,
                expectedCLIIdentifier: cli.rawValue,
                currentExecutableIdentity: executableIdentity
              ) else {
            return false
        }
        return cli == .qwen || hasPrivateAuthenticationState(for: cli)
    }

    /// Persists the choice into the same key every new brain process reads.
    /// An in-flight speech turn is cancelled before the lane changes.
    @discardableResult
    func selectBrain(_ cli: BrainCLI) -> Bool {
        guard BrainCLI.customerChoices.contains(cli),
              canSelectConnectedProvider(cli),
              providerEffectsAreAllowed else {
            return false
        }
        let didSelect = commitVisibleEffect {
            if cli != self.selectedBrain {
                SpeechProviderSwitchBoundary.cancelActiveSpeechTurn()
            }
            if cli == .codex || self.selectedBrain == .codex {
                CodexModelCapabilityPreflight.shared.invalidate(
                    reason: .providerSwitch
                )
            }
            self.selectedBrain = cli
            UserDefaults.standard.set(
                cli.rawValue,
                forKey: "SelectedBrainCLI"
            )
            UserDefaults.standard.removeObject(forKey: "BrainBackend")
            return true
        }
        if didSelect {
            BrainConnectionProbe.appendConnectLog(
                "SELECT provider=\(cli.rawValue) source=connected-provider"
            )
        }
        return didSelect
    }

    static func fallbackSelection(
        currentSelection: BrainCLI,
        statuses: [BrainCLI: BrainConnectionStatus],
        allProbesFinished: Bool
    ) -> BrainCLI? {
        guard allProbesFinished,
              statuses[currentSelection]?.isVerifiedConnected != true else {
            return nil
        }
        return BrainCLI.allCases.first {
            statuses[$0]?.isVerifiedConnected == true
        }
    }

    private var probeTasks: [BrainCLI: Task<Void, Never>] = [:]
    private var hostedProbeTask: Task<Void, Never>?
    private var workGeneration = UUID()

    /// The CLI whose sign-in we're waiting on, if any. Drives the "finish in
    /// your browser" state so the user is never looking at a screen that has
    /// stopped telling them what happens next.
    @Published private(set) var awaitingSignInFor: BrainCLI?
    /// Distinguishes a non-destructive real-answer check from a browser OAuth
    /// flight so the permanent panel never claims it opened or is waiting on a
    /// browser when it is only verifying the existing private session.
    @Published private(set) var verifyingExistingAuthenticationFor: BrainCLI?
    /// Bounded auto-retry while waiting: each retry is a real CLI call against
    /// the user's own plan, so it is capped rather than looped forever.
    private var signInPollAttemptsRemaining = 0
    private var signInPollTimer: Timer?
    private var signInPreparationTask: Task<Void, Never>?
    private var signInFlight:
        BrainConnectionProviderFlightCoordinator.Flight?
    private var providerFlightCoordinator =
        BrainConnectionProviderFlightCoordinator()

    var hasActiveProviderFlight: Bool {
        providerFlightCoordinator.activeFlight != nil
    }

    /// The only primary buyer-facing entry for a customer-owned provider. An
    /// existing Ace-owned session is verified in place; OAuth is launched only
    /// when no private provider session exists. It scopes probing, any required
    /// OAuth, and eventual brain selection to the tapped card.
    @discardableResult
    func connectProvider(_ cli: BrainCLI) -> Bool {
        beginProviderConnection(
            cli,
            replacingExistingAuthentication: false
        )
    }

    /// Deliberately replaces the account in Ace's private provider directory.
    /// This is distinct from Connect: reconnect first executes the provider's
    /// native logout, invalidates the old proof, then starts browser login and
    /// requires a new real answer before the replacement is accepted.
    @discardableResult
    func reconnectProvider(_ cli: BrainCLI) -> Bool {
        beginProviderConnection(
            cli,
            replacingExistingAuthentication: true
        )
    }

    func cancelProviderConnection(_ cli: BrainCLI) {
        guard let flight = providerFlightCoordinator.activeFlight,
              flight.providerIdentifier == cli.rawValue else { return }
        finishWaitingWithRetry(for: cli, flight: flight)
    }

    @discardableResult
    private func beginProviderConnection(
        _ cli: BrainCLI,
        replacingExistingAuthentication: Bool
    ) -> Bool {
        guard BrainCLI.customerChoices.contains(cli),
              AceBrainRoute.current == .customerOwned,
              providerEffectsAreAllowed else {
            return false
        }
        let state = providerOnboardingState(for: cli)
        let verifyExistingAuthentication =
            canVerifyExistingAuthentication(for: cli)
        let nextState = BrainConnectionProviderOnboardingPolicy.transition(
            from: state,
            event: .connectTapped
        )
        guard nextState != state || state == .readyToConnect
            || state == .retryConnection else {
            return false
        }
        guard cli.resolveExecutablePath() != nil else {
            loadCachedStatuses()
            return false
        }
        // Switching providers must not be wedged by the flight that belongs to
        // the OTHER one. This used to `return false` for ANY active flight, so
        // once a Codex flight existed the Claude card did nothing at all — no
        // retire, no message, no receipt — until the seven-minute timeout fired.
        // `retireActiveProviderFlightForReplacement()` is written for exactly
        // this ("a second card click cancels and visibly resets the old provider
        // before the new browser OAuth process can launch") and had zero callers
        // tree-wide, so the documented escape hatch did not exist.
        //
        // A flight for the SAME provider is left alone: native sign-in may
        // legitimately run for 300 seconds, and that control is deliberately
        // single-flight until it publishes its own terminal.
        if let activeFlight = providerFlightCoordinator.activeFlight {
            guard activeFlight.providerIdentifier != cli.rawValue else {
                return false
            }
            retireActiveProviderFlightForReplacement()
        }
        guard let flight = providerFlightCoordinator.beginIfIdle(
            providerIdentifier: cli.rawValue
        ) else { return false }
        if cli == .codex || selectedBrain == .codex {
            CodexModelCapabilityPreflight.shared.invalidate(
                reason: replacingExistingAuthentication
                    ? .reconnect : .providerSwitch
            )
        }
        providerOnboardingStates[cli] =
            providerFlightCoordinator.onboardingState(for: cli.rawValue)
        guard startSignIn(
            for: cli,
            flight: flight,
            replacingExistingAuthentication:
                replacingExistingAuthentication,
            verifyExistingAuthentication: verifyExistingAuthentication
        ) else {
            finishWaitingWithRetry(for: cli, flight: flight)
            return false
        }
        return true
    }

    /// A provider repair owns the full OAuth/poll flight. The native sign-in
    /// process may legitimately run for 300 seconds, so the control remains
    /// single-flight until the model publishes that exact flight's terminal.
    func waitForProviderRepairTerminal(
        _ cli: BrainCLI
    ) async -> PermissionRepairResult {
        guard let ownedFlight = providerFlightCoordinator.activeFlight,
              ownedFlight.providerIdentifier == cli.rawValue else {
            return .failed(
                PermissionRepairFailure(
                    code: "provider.flight_not_owned",
                    message: "This control does not own the active provider flight."
                )
            )
        }
        for _ in 0..<4_200 {
            if Task.isCancelled {
                if providerFlightCoordinator.admits(ownedFlight) {
                    finishWaitingWithRetry(for: cli, flight: ownedFlight)
                }
                return .failed(
                    PermissionRepairFailure(
                        code: "provider.retry_cancelled",
                        message: "The provider repair was cancelled."
                    )
                )
            }
            let onboarding = providerOnboardingState(for: cli)
            let current = status(for: cli)
            if onboarding == .connected,
               current.isVerifiedConnected {
                return .succeeded(
                    .verifiedOperation("provider_real_answer")
                )
            }
            if onboarding == .retryConnection {
                return .failed(
                    PermissionRepairFailure(
                        code: "provider.answer_not_verified",
                        message: current.detail.isEmpty
                            ? "The provider did not return a verified answer."
                            : current.detail
                    )
                )
            }
            if !providerFlightCoordinator.admits(ownedFlight) {
                return .failed(PermissionRepairFailure(
                    code: "provider.connection_cancelled",
                    message: "Connection cancelled. You can try again."
                ))
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if providerFlightCoordinator.admits(ownedFlight) {
            finishWaitingWithRetry(for: cli, flight: ownedFlight)
        }
        return .failed(
            PermissionRepairFailure(
                code: "provider.flight_timeout",
                message: "Ace did not verify a reply in time. Check your account again, or finish signing in through your browser and retry."
            )
        )
    }

    /// The customer route has exactly one explicit provider connection flight.
    /// A second card click cancels and visibly resets the old provider before
    /// the new browser OAuth process can launch.
    private func retireActiveProviderFlightForReplacement() {
        guard let activeFlight = providerFlightCoordinator.activeFlight else {
            return
        }
        _ = providerFlightCoordinator.cancelActive()
        signInPreparationTask?.cancel()
        signInPreparationTask = nil
        signInFlight = nil
        signInPollTimer?.invalidate()
        signInPollTimer = nil
        signInPollAttemptsRemaining = 0
        awaitingSignInFor = nil
        verifyingExistingAuthenticationFor = nil
        guard let cli = BrainCLI(
            rawValue: activeFlight.providerIdentifier
        ) else { return }
        probeTasks[cli]?.cancel()
        probeTasks[cli] = nil
        statuses[cli]?.isChecking = false
        providerOnboardingStates[cli] =
            providerFlightCoordinator.onboardingState(for: cli.rawValue)
    }

    /// Begins waiting for a sign-in to complete, re-probing periodically so the
    /// card usually flips on its own without the user having to press anything.
    private func startWaitingForSignIn(
        _ cli: BrainCLI,
        flight: BrainConnectionProviderFlightCoordinator.Flight
    ) {
        guard providerEffectsAreAllowed,
              providerFlightCoordinator.admits(flight),
              providerFlightCoordinator.markOAuthLaunched(flight) else {
            return
        }
        awaitingSignInFor = cli
        providerOnboardingStates[cli] =
            providerFlightCoordinator.onboardingState(for: cli.rawValue)
        signInPollAttemptsRemaining = 6
        signInPollTimer?.invalidate()
        // 20s: long enough for a browser round-trip, and 6 attempts caps the
        // cost of watching at two minutes of polling.
        signInPollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.providerEffectsAreAllowed,
                      self.providerFlightCoordinator.admits(flight),
                      self.awaitingSignInFor == cli,
                      !(self.statuses[cli]?.isVerifiedConnected ?? false) else {
                    return
                }
                guard BrainConnectionProviderPollPolicy.shouldConsumeAttempt(
                    probeIsChecking: self.statuses[cli]?.isChecking ?? false
                ) else {
                    return
                }
                guard self.signInPollAttemptsRemaining > 0 else {
                    self.finishWaitingWithRetry(
                        for: cli,
                        flight: flight
                    )
                    return
                }
                self.signInPollAttemptsRemaining -= 1
                self.refresh(cli, flight: flight)
            }
        }
    }

    private func clearWaitingPresentation() {
        signInPollTimer?.invalidate()
        signInPollTimer = nil
        signInPollAttemptsRemaining = 0
        awaitingSignInFor = nil
        verifyingExistingAuthenticationFor = nil
    }

    private func finishWaitingWithRetry(
        for cli: BrainCLI,
        flight: BrainConnectionProviderFlightCoordinator.Flight
    ) {
        guard providerFlightCoordinator.admits(flight),
              awaitingSignInFor == cli else { return }
        probeTasks[cli]?.cancel()
        probeTasks[cli] = nil
        statuses[cli]?.isChecking = false
        if signInFlight == flight {
            signInPreparationTask?.cancel()
            signInPreparationTask = nil
            signInFlight = nil
        }
        _ = providerFlightCoordinator.finishForRetry(flight)
        providerOnboardingStates[cli] =
            providerFlightCoordinator.onboardingState(for: cli.rawValue)
        clearWaitingPresentation()
    }

    private func finishVerifiedProviderFlight(
        for cli: BrainCLI,
        flight: BrainConnectionProviderFlightCoordinator.Flight
    ) {
        guard providerFlightCoordinator.admits(flight),
              awaitingSignInFor == cli else { return }
        if signInFlight == flight {
            signInPreparationTask?.cancel()
            signInPreparationTask = nil
            signInFlight = nil
        }
        _ = providerFlightCoordinator.finishConnected(flight)
        providerOnboardingStates[cli] =
            providerFlightCoordinator.onboardingState(for: cli.rawValue)
        clearWaitingPresentation()
        selectBrain(cli)
    }

    /// Starts the provider's browser sign-in flow as a direct child process.
    /// Ace owns the process and its timeout; Terminal is never opened.
    private func startSignIn(
        for cli: BrainCLI,
        flight: BrainConnectionProviderFlightCoordinator.Flight,
        replacingExistingAuthentication: Bool,
        verifyExistingAuthentication: Bool
    ) -> Bool {
        if cli == .qwen {
            guard providerEffectsAreAllowed,
                  providerFlightCoordinator.admits(flight),
                  cli.resolveExecutablePath() != nil else {
                return false
            }
            startWaitingForSignIn(cli, flight: flight)
            BrainConnectionProbe.appendConnectLog(
                "ACTIVATE local qwen verification"
            )
            refresh(cli, flight: flight)
            return true
        }
        if !replacingExistingAuthentication,
           verifyExistingAuthentication {
            guard providerEffectsAreAllowed,
                  providerFlightCoordinator.admits(flight),
                  cli.resolveExecutablePath() != nil else {
                return false
            }
            verifyingExistingAuthenticationFor = cli
            startWaitingForSignIn(cli, flight: flight)
            BrainConnectionProbe.appendConnectLog(
                "VERIFY existing customer \(cli.rawValue) session"
            )
            refresh(cli, flight: flight)
            return true
        }
        if BrainCLI.customerChoices.contains(cli),
           AceBrainRoute.current == .customerOwned {
            guard providerEffectsAreAllowed,
                  providerFlightCoordinator.admits(flight),
                  let executablePath = cli.resolveExecutablePath() else {
                return false
            }
            let generation = workGeneration
            signInFlight = flight
            startWaitingForSignIn(cli, flight: flight)
            BrainConnectionProbe.appendConnectLog(
                "SIGNIN launched native customer \(cli.rawValue) browser flow"
            )
            signInPreparationTask = Task { [weak self] in
                guard let self,
                      self.providerEffectsAreAllowed,
                      self.providerFlightCoordinator.admits(flight),
                      self.signInFlight == flight else {
                    return
                }
                if replacingExistingAuthentication {
                    let signOutResult = await BrainConnectionProbe.runProcess(
                        executablePath: executablePath,
                        arguments: cli.nativeSignOutArguments,
                        standardInput: nil,
                        environment: BrainBackend.processEnvironment(
                            claudeExecutablePath: executablePath
                        ),
                        timeout: 30
                    )
                    guard !Task.isCancelled,
                          self.workGeneration == generation,
                          self.providerFlightCoordinator.admits(flight),
                          self.signInFlight == flight,
                          self.awaitingSignInFor == cli,
                          self.providerEffectsAreAllowed else {
                        return
                    }
                    BrainConnectionProbe.appendConnectLog(
                        "SIGNOUT native customer \(cli.rawValue) exit=\(signOutResult.exitCode)"
                    )
                    guard signOutResult.exitCode == 0 else {
                        self.statuses[cli] = BrainConnectionStatus(
                            state: .failed,
                            detail:
                                "Ace could not sign out its private "
                                + "\(cli.displayName) session. Retry reconnect.",
                            executablePath: executablePath,
                            isChecking: false,
                            answeredRealProbe: false
                        )
                        self.finishWaitingWithRetry(
                            for: cli,
                            flight: flight
                        )
                        return
                    }
                    BrainConnectionProof.invalidate(cli)
                    self.statuses[cli] = BrainConnectionStatus(
                        state: .signedOut,
                        detail:
                            "Ace signed out its private provider session. "
                            + "Finish the new browser sign-in.",
                        executablePath: executablePath,
                        isChecking: false,
                        answeredRealProbe: false
                    )
                }
                let result = await BrainConnectionProbe.runProcess(
                    executablePath: executablePath,
                    arguments: cli.nativeSignInArguments,
                    standardInput: nil,
                    environment: BrainBackend.processEnvironment(
                        claudeExecutablePath: executablePath
                    ),
                    timeout: 300
                )
                guard !Task.isCancelled,
                      self.workGeneration == generation,
                      self.providerFlightCoordinator.admits(flight),
                      self.signInFlight == flight,
                      self.awaitingSignInFor == cli,
                      self.providerEffectsAreAllowed else {
                    return
                }
                self.signInPreparationTask = nil
                self.signInFlight = nil
                BrainConnectionProbe.appendConnectLog(
                    "SIGNIN native customer \(cli.rawValue) exit=\(result.exitCode)"
                )
                self.refresh(cli, flight: flight)
            }
            return true
        }

        return false
    }

    /// Ends every process and timer owned by this first-run model. Swift task
    /// cancellation alone is not enough for `Process`; the runners below bind
    /// cancellation to process-tree termination so CLI helpers cannot outlive
    /// the setup window.
    func cancelAllWork() {
        workGeneration = UUID()
        providerFlightCoordinator.cancelAll()
        signInPreparationTask?.cancel()
        signInPreparationTask = nil
        signInFlight = nil
        hostedProbeTask?.cancel()
        hostedProbeTask = nil
        for task in probeTasks.values {
            task.cancel()
        }
        probeTasks.removeAll()
        clearWaitingPresentation()
        for cli in BrainCLI.customerChoices {
            providerOnboardingStates[cli] =
                providerFlightCoordinator.onboardingState(for: cli.rawValue)
        }
        hostedStatus.isChecking = false
        for cli in BrainCLI.allCases where statuses[cli]?.isChecking == true {
            statuses[cli]?.isChecking = false
        }
    }

    /// True when a development Mac has CLI-state simulation turned on.
    static var isSimulatingBrainStates: Bool {
        guard DeveloperMachine.isDeveloperMachine else { return false }
        let simulationSetting = UserDefaults.standard.string(forKey: "SimulateBrainState") ?? ""
        return !simulationSetting.isEmpty
    }

    /// Parses `SimulateBrainState` — for example, "claude:notInstalled".
    /// Returns nil (real probe) on a buyer Mac no matter what the key says.
    private static func simulatedState(for cli: BrainCLI) -> BrainConnectionState? {
        guard DeveloperMachine.isDeveloperMachine,
              let simulationSetting = UserDefaults.standard.string(forKey: "SimulateBrainState"),
              !simulationSetting.isEmpty else { return nil }

        for pair in simulationSetting.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard parts.count == 2, parts[0] == cli.rawValue else { continue }
            switch parts[1] {
            case "notinstalled": return .notInstalled
            case "signedout": return .signedOut
            case "connected": return .connected
            case "failed": return .failed
            default: return nil
            }
        }
        return nil
    }

    /// Re-probes Claude. The cheap file check resolves instantly; the live
    /// answer probe runs off the main actor so the intro keeps animating.
    private func refreshAll() {
        guard visibleEffectsAreAllowed else { return }
        guard AceBrainRoute.current == .founderHosted else { return }
        refreshHosted()
    }

    private func refreshHosted() {
        guard providerEffectsAreAllowed,
              !hostedStatus.isChecking else {
            return
        }
        let generation = workGeneration
        guard let credentials = AceLicense.shared.hostedBrainCredentials else {
            HostedBrainConnectionProof.invalidate()
            hostedStatus = BrainConnectionStatus(
                state: .signedOut,
                detail: "Activate Ace with your activation key.",
                executablePath: nil,
                isChecking: false
            )
            return
        }
        HostedBrainConnectionProof.invalidate()
        hostedStatus = BrainConnectionStatus(
            state: .unknown,
            detail: "Checking Ace's Codex CLI…",
            executablePath: nil,
            isChecking: true
        )
        hostedProbeTask?.cancel()
        hostedProbeTask = Task { [weak self] in
            guard let self, self.providerEffectsAreAllowed else { return }
            let result: BrainConnectionStatus
            do {
                let answer = try await HostedBrainClient.complete(
                    kind: .probe,
                    prompt: "Reply with exactly one lowercase word: ready",
                    expectedCredentials: credentials
                )
                guard !Task.isCancelled,
                      self.workGeneration == generation,
                      self.providerEffectsAreAllowed,
                      AceLicense.shared.hostedBrainCredentials == credentials else { return }
                guard answer == "ready",
                      HostedBrainConnectionProof.recordSuccessfulProbe(
                        credentials: credentials
                      ) else {
                    throw HostedBrainError.invalidResponse
                }
                result = BrainConnectionStatus(
                    state: .connected,
                    detail: "Ace Codex CLI · live answer verified",
                    executablePath: nil,
                    isChecking: false,
                    answeredRealProbe: true
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.workGeneration == generation,
                      self.providerEffectsAreAllowed,
                      AceLicense.shared.hostedBrainCredentials == credentials else { return }
                HostedBrainConnectionProof.invalidate()
                result = BrainConnectionStatus(
                    state: .failed,
                    detail: error.localizedDescription,
                    executablePath: nil,
                    isChecking: false
                )
            }
            guard !Task.isCancelled,
                  self.workGeneration == generation,
                  self.providerEffectsAreAllowed else {
                return
            }
            self.hostedStatus = result
            self.hostedProbeTask = nil
        }
    }

    private func refresh(
        _ cli: BrainCLI,
        flight: BrainConnectionProviderFlightCoordinator.Flight
    ) {
        guard providerEffectsAreAllowed,
              providerFlightCoordinator.admits(flight),
              awaitingSignInFor == cli,
              !(statuses[cli]?.isChecking ?? false) else {
            return
        }
        let generation = workGeneration

        // QA affordance, development Macs only (same gate as RUN_DEMO/RUN_SAY):
        // the machine that BUILDS Ace always has a working CLI, so the states a
        // buyer actually sees on a fresh Mac — nothing installed, installed but
        // signed out — can otherwise never be looked at before shipping.
        //   defaults write com.blacklabel.assistant SimulateBrainState "claude:notInstalled"
        //   defaults delete com.blacklabel.assistant SimulateBrainState
        if let simulatedState = Self.simulatedState(for: cli) {
            // Simulation is display-only. It must never coexist with durable
            // setup authority from an earlier real run on the developer Mac.
            BrainConnectionProof.invalidate(cli)
            _ = commitVisibleEffect {
                self.statuses[cli] = BrainConnectionStatus(
                    state: simulatedState,
                    detail:
                        simulatedState == .connected ? "simulated" : "",
                    executablePath:
                        simulatedState == .notInstalled
                            ? nil : cli.resolveExecutablePath(),
                    isChecking: false
                )
                return true
            }
            finishWaitingWithRetry(for: cli, flight: flight)
            return
        }

        guard let resolverPath = cli.resolveExecutablePath() else {
            BrainConnectionProbe.appendConnectLog("PROBE \(cli.rawValue) → notInstalled (no binary at any known path)")
            BrainConnectionProof.invalidate(cli)
            _ = commitVisibleEffect {
                self.statuses[cli] = BrainConnectionStatus(
                    state: .notInstalled,
                    detail: "",
                    executablePath: nil,
                    isChecking: false
                )
                return true
            }
            finishWaitingWithRetry(for: cli, flight: flight)
            return
        }

        guard let executableIdentityBeforeProbe = BrainExecutableIdentity.capture(
            resolverPath: resolverPath
        ) else {
            BrainConnectionProbe.appendConnectLog(
                "PROBE \(cli.rawValue) → failed (resolved executable identity unavailable)"
            )
            BrainConnectionProof.invalidate(cli)
            _ = commitVisibleEffect {
                self.statuses[cli] = BrainConnectionStatus(
                    state: .failed,
                    detail:
                        "Claude's executable changed or could not be "
                        + "inspected. Retry connection.",
                    executablePath: resolverPath,
                    isChecking: false
                )
                return true
            }
            finishWaitingWithRetry(for: cli, flight: flight)
            return
        }

        // A refresh is a new authority decision. Remove the older receipt before
        // launching so setup cannot race ahead on stale proof while this exact
        // executable is still being authenticated.
        BrainConnectionProof.invalidate(cli)

        var probingStatus = statuses[cli] ?? BrainConnectionStatus()
        probingStatus.isChecking = true
        probingStatus.executablePath = executableIdentityBeforeProbe.resolvedExecutablePath
        probingStatus.answeredRealProbe = false
        guard commitVisibleEffect({
            self.statuses[cli] = probingStatus
            return true
        }) else {
            return
        }
        guard providerFlightCoordinator.markProbeStarted(flight) else {
            statuses[cli]?.isChecking = false
            return
        }

        probeTasks[cli] = Task { [weak self] in
            guard let self,
                  self.providerEffectsAreAllowed,
                  self.providerFlightCoordinator.admits(flight) else {
                return
            }
            var result = await BrainConnectionProbe.probe(
                cli: cli,
                executablePath: executableIdentityBeforeProbe.resolvedExecutablePath
            )
            guard !Task.isCancelled,
                  self.workGeneration == generation,
                  self.providerFlightCoordinator.admits(flight),
                  self.awaitingSignInFor == cli,
                  self.providerEffectsAreAllowed else { return }

            let executableIdentityAfterProbe = cli.resolveExecutablePath()
                .flatMap { BrainExecutableIdentity.capture(resolverPath: $0) }
            if result.isVerifiedConnected,
               executableIdentityAfterProbe != executableIdentityBeforeProbe {
                result = BrainConnectionStatus(
                    state: .failed,
                    detail: "Claude's executable changed while its connection was being checked. Check again.",
                    executablePath: executableIdentityAfterProbe?.resolvedExecutablePath,
                    isChecking: false
                )
            }

            if result.isVerifiedConnected,
               let executableIdentityAfterProbe {
                if !BrainConnectionProof.recordSuccessfulProbe(
                    for: cli,
                    executableIdentity: executableIdentityAfterProbe,
                    versionDetail: result.detail
                ) {
                    BrainConnectionProof.invalidate(cli)
                    result = BrainConnectionStatus(
                        state: .failed,
                        detail:
                            "Ace could not securely record the verified "
                            + "connection. Retry connection.",
                        executablePath:
                            executableIdentityAfterProbe
                                .resolvedExecutablePath,
                        isChecking: false
                    )
                }
            } else {
                BrainConnectionProof.invalidate(cli)
            }
            guard self.providerFlightCoordinator
                .markProbeFinished(flight) else { return }
            let didPublishResult = self.commitVisibleEffect {
                self.statuses[cli] = result
                self.probeTasks[cli] = nil
                return true
            }
            guard didPublishResult else { return }
            switch BrainConnectionProviderPollPolicy.disposition(
                answeredRealProbe: result.isVerifiedConnected,
                attemptsRemaining: self.signInPollAttemptsRemaining,
                providerUsageLimited: result.isUsageLimited,
                checkingSavedAccount: self.verifyingExistingAuthenticationFor == cli
            ) {
            case .connected:
                self.finishVerifiedProviderFlight(
                    for: cli,
                    flight: flight
                )
            case .keepWaiting:
                break
            case .retryConnection:
                if self.awaitingSignInFor == cli {
                    self.finishWaitingWithRetry(
                        for: cli,
                        flight: flight
                    )
                }
            }
            BrainConnectionProbe.appendConnectLog(
                "PROBE \(cli.rawValue) → \(result.state) "
                    + "detail=\"\(result.detail)\" "
                    + "resolver="
                    + "\(executableIdentityBeforeProbe.resolverPath) "
                    + "resolved="
                    + executableIdentityBeforeProbe
                        .resolvedExecutablePath
            )
            // Keep the selected transport synchronized with the one verified
            // by the same real answer probe the runtime uses.
            let allProbesFinished = BrainCLI.allCases.allSatisfy {
                self.probeTasks[$0] == nil
                    && self.statuses[$0]?.isChecking != true
            }
            if let workingBrain = Self.fallbackSelection(
                currentSelection: self.selectedBrain,
                statuses: self.statuses,
                allProbesFinished: allProbesFinished
            ) {
                self.selectBrain(workingBrain)
            }
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// The actual subprocess work. Nonisolated so it never touches the main thread.
enum BrainConnectionProbe {

    /// Durable receipts for the connection lane, so "did the installer actually
    /// run" and "what did the probe decide" are answerable from a file instead
    /// of from a screenshot taken at the right second.
    nonisolated static func appendConnectLog(_ message: String) {
        guard !StealthEntryLatch.shared.isRaised else { return }
        guard let supportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true) else { return }
        let safeMessage = message
            .components(separatedBy: .newlines)
            .joined(separator: "\\n")
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
        let line =
            "\(ISO8601DateFormatter().string(from: Date())) "
            + "\(safeMessage.prefix(4_096))\n"
        guard let lineData = line.data(using: .utf8) else { return }
        DispatchQueue.global(qos: .utility).async {
            BrainConnectionLogWriter.shared.append(
                lineData,
                in: supportDirectory
            )
        }
    }

    /// Two questions, in order: does the binary run at all (`--version`, fast),
    /// and does it ANSWER (a real one-word prompt, slow). The second is what
    /// separates "installed" from "signed in" — an unauthenticated CLI passes
    /// `--version` happily and fails the moment it needs credentials.
    static func probe(cli: BrainCLI, executablePath: String) async -> BrainConnectionStatus {
        if cli == .qwen {
            switch await AceLocalBrain.probe() {
            case .success(let detail):
                return BrainConnectionStatus(
                    state: .connected,
                    detail: detail,
                    executablePath: executablePath,
                    isChecking: false,
                    answeredRealProbe: true
                )
            case .failure(let error):
                return BrainConnectionStatus(
                    state: .failed,
                    detail: error.localizedDescription,
                    executablePath: executablePath,
                    isChecking: false
                )
            }
        }
        let versionRun = await runProcess(
            executablePath: executablePath,
            arguments: cli.versionArguments,
            standardInput: nil,
            environment: environment(for: cli, executablePath: executablePath),
            timeout: 20
        )

        guard versionRun.exitCode == 0 else {
            return BrainConnectionStatus(
                state: .failed,
                detail: diagnosticLine(versionRun.combinedOutput, fallback: "`--version` exited \(versionRun.exitCode)."),
                executablePath: executablePath,
                isChecking: false
            )
        }

        let versionText = firstLine(versionRun.standardOutput, fallback: "installed")

        let answerRun = await answerProbe(cli: cli, executablePath: executablePath)
        if BrainConnectionLiveProbePolicy.provesLiveAuthenticatedAnswer(
            invocationKind: answerRun.invocationKind,
            exitCode: answerRun.exitCode,
            answerText: answerRun.answerText,
            timedOut: answerRun.timedOut
        ) {
            return BrainConnectionStatus(
                state: .connected,
                detail: answerRun.resolvedCodexModel.map {
                    "\(versionText) · Last account check: \($0)"
                } ?? versionText,
                executablePath: executablePath,
                isChecking: false,
                answeredRealProbe: true
            )
        }

        let failureText = answerRun.combinedOutput
        let state: BrainConnectionState = looksLikeAuthFailure(failureText) ? .signedOut : .failed
        let detail: String
        if state == .signedOut {
            detail = versionText
        } else if answerRun.timedOut {
            detail = "\(versionText) — but it didn't answer within \(Int(answerTimeout))s."
        } else if answerRun.exitCode == 0 {
            detail =
                "\(versionText) — but its verification answer was not exactly \"ready\"."
        } else {
            detail = diagnosticLine(failureText, fallback: "\(versionText) — but it returned no answer.")
        }
        return BrainConnectionStatus(
            state: state,
            detail: detail,
            executablePath: executablePath,
            isChecking: false
        )
    }

    // MARK: - Answer probe

    /// Long enough for a cold CLI start plus one short generation, short enough
    /// that a hung CLI doesn't strand someone on the setup screen.
    private static let answerTimeout: TimeInterval = 75

    private static let probePrompt = "Reply with exactly one word: ready"

    private struct AnswerRun {
        var exitCode: Int32
        var answerText: String
        var combinedOutput: String
        var timedOut: Bool
        var invocationKind: BrainConnectionProbeInvocationKind
        var resolvedCodexModel: String?
    }

    /// Runs the same shape of call the real brain makes — same isolation flags,
    /// same read-only posture, same environment — so a probe that passes is
    /// evidence about the path Ace will actually use, not about some simpler
    /// invocation that happens to work.
    private static func answerProbe(
        cli: BrainCLI,
        executablePath: String
    ) async -> AnswerRun {
        switch cli {
        case .claude:
            let arguments = BrainBackend.isolatedZeroToolClaudeArguments(
                model: .sonnet
            ) + ["--max-turns", "1"]
            return await runAnswerProbe(
                cli: cli,
                executablePath: executablePath,
                arguments: arguments,
                resolvedCodexModel: nil
            )
        case .codex:
            return await resolveAndRunCodexAnswerProbe(
                executablePath: executablePath
            )
        case .qwen:
            return await runAnswerProbe(
                cli: cli,
                executablePath: executablePath,
                arguments: AceLocalBrain.cliAnswerArguments(),
                resolvedCodexModel: nil
            )
        }
    }

    private static func resolveAndRunCodexAnswerProbe(
        executablePath: String
    ) async -> AnswerRun {
        do {
            let model = try await resolveCodexCapabilityForSetup(
                executablePath: executablePath
            )
            return AnswerRun(
                exitCode: 0,
                answerText: "ready",
                combinedOutput: "",
                timedOut: false,
                invocationKind: .isolatedZeroToolAnswer,
                resolvedCodexModel: model
            )
        } catch is CancellationError {
            return invalidAnswerRun("The Codex capability check was cancelled.")
        } catch {
            return AnswerRun(
                exitCode: -1,
                answerText: "",
                combinedOutput: error.localizedDescription,
                timedOut: false,
                invocationKind: .isolatedZeroToolAnswer,
                resolvedCodexModel: nil
            )
        }
    }

    static func resolveCodexCapabilityForSetup(
        executablePath: String,
        resolveCodexModel:
            @escaping @Sendable (String) async throws -> String = {
                try await BrainBackend.resolveCodexModel(
                    executablePath: $0
                )
            }
    ) async throws -> String {
        try await resolveCodexModel(executablePath)
    }

    /// One concrete live attempt used by the shared preflight for setup and all
    /// returning customer-owned execution lanes.
    static func codexCapabilityObservation(
        executablePath: String,
        model: String,
        entryLatch: StealthEntryLatch = .shared
    ) async -> CodexModelProbeObservation {
        let run = await runAnswerProbe(
            cli: .codex,
            executablePath: executablePath,
            arguments: BrainConnectionCodexProbePolicy.arguments(
                answerFilePath: "__ACE_PROBE_OWNS_PATH__",
                model: model
            ),
            resolvedCodexModel: model,
            entryLatch: entryLatch
        )
        return CodexModelProbeObservation(
            model: model,
            exitCode: run.exitCode,
            answerText: run.answerText,
            diagnostic: run.combinedOutput,
            timedOut: run.timedOut
        )
    }

    private static func runAnswerProbe(
        cli: BrainCLI,
        executablePath: String,
        arguments rawArguments: [String],
        resolvedCodexModel: String?,
        entryLatch: StealthEntryLatch = .shared
    ) async -> AnswerRun {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let answerFileURL = temporaryDirectory.appendingPathComponent(
            "ace-brain-probe-\(UUID().uuidString).txt"
        )
        defer { try? FileManager.default.removeItem(at: answerFileURL) }
        let arguments = rawArguments.map {
            $0 == "__ACE_PROBE_OWNS_PATH__" ? answerFileURL.path : $0
        }
        guard BrainConnectionLiveProbePolicy
            .argumentsDescribeIsolatedZeroToolInvocation(arguments) else {
            return AnswerRun(
                exitCode: -1,
                answerText: "",
                combinedOutput: "The brain probe's isolation arguments were invalid.",
                timedOut: false,
                invocationKind: .invalidConfiguration,
                resolvedCodexModel: resolvedCodexModel
            )
        }
        let run = await runProcess(
            executablePath: executablePath,
            arguments: arguments,
            standardInput: probePrompt,
            workingDirectory: temporaryDirectory,
            environment: environment(for: cli, executablePath: executablePath),
            timeout: answerTimeout,
            entryLatch: entryLatch
        )
        let answerText =
            BrainBackend.screenshotAnswerCapturesStandardOutput(for: cli)
            ? run.standardOutput
            : (try? String(contentsOf: answerFileURL, encoding: .utf8)) ?? ""
        return AnswerRun(
            exitCode: run.exitCode,
            answerText: answerText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            combinedOutput: run.combinedOutput,
            timedOut: run.timedOut,
            invocationKind: .isolatedZeroToolAnswer,
            resolvedCodexModel: resolvedCodexModel
        )
    }

    private static func invalidAnswerRun(_ message: String) -> AnswerRun {
        AnswerRun(
            exitCode: -1,
            answerText: "",
            combinedOutput: message,
            timedOut: false,
            invocationKind: .invalidConfiguration,
            resolvedCodexModel: nil
        )
    }

    private static func environment(for cli: BrainCLI, executablePath: String) -> [String: String] {
        BrainBackend.processEnvironment(claudeExecutablePath: executablePath)
    }

    // MARK: - Classification

    /// Distinguishes "you're not signed in" (a step the user can take) from any
    /// other failure (which we show verbatim rather than guessing about).
    /// Deliberately generous because CLI versions word this differently, and a
    /// mislabelled auth error still lands the user on the right fix.
    static func looksLikeAuthFailure(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        let authMarkers = [
            "login", "log in", "sign in", "signed out", "not authenticated",
            "unauthenticated", "unauthorized", "authenticate", "authentication",
            "oauth", "session expired", "credential", "api key", "apikey",
            "auth.json", "401", "403", "/login",
        ]
        return authMarkers.contains { lowercased.contains($0) }
    }

    /// First non-empty line — right for `--version`, whose whole output is the
    /// answer.
    private static func firstLine(_ text: String, fallback: String) -> String {
        let line = nonEmptyLines(text).first
        guard let line else { return fallback }
        return truncated(line)
    }

    /// The line that explains a FAILURE. Not the first one: the CLI opens with
    /// startup banners ("Reading prompt from stdin...", skills warnings, hook
    /// notices), and showing those told the user nothing while the real cause —
    /// "ERROR: You've hit your usage limit" — sat four lines below, unread.
    /// Prefer an explicit error line; failing that, the CLI's last word, which
    /// is where a failing run ends up.
    private static func diagnosticLine(_ text: String, fallback: String) -> String {
        let bannerPrefixes = ["reading prompt from stdin", "hook:", "warning:", "[", "note:"]
        let candidateLines = nonEmptyLines(text).filter { line in
            let lowercased = line.lowercased()
            return !bannerPrefixes.contains { lowercased.hasPrefix($0) }
        }
        let chosenLine = candidateLines.last(where: { $0.lowercased().contains("error") })
            ?? candidateLines.last
            ?? nonEmptyLines(text).last
        guard let chosenLine else { return fallback }
        return truncated(chosenLine)
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func truncated(_ line: String) -> String {
        line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    // MARK: - Process runner

    struct ProcessRun {
        var exitCode: Int32
        var standardOutput: String
        var standardError: String
        var timedOut: Bool

        var combinedOutput: String {
            [standardError, standardOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    /// Runs a CLI to completion off the main thread with a hard timeout, both
    /// streams drained separately so neither pipe can fill and deadlock.
    static func runProcess(
        executablePath: String,
        arguments: [String],
        standardInput: String?,
        workingDirectory: URL? = nil,
        environment: [String: String],
        timeout: TimeInterval,
        entryLatch: StealthEntryLatch = .shared
    ) async -> ProcessRun {
        let processBoundary = BrainConnectionProcessBoundary(
            entryLatch: entryLatch
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProcessRun, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.environment = environment
                if let workingDirectory {
                    process.currentDirectoryURL = workingDirectory
                }

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                var privateInputHandle: FileHandle?
                do {
                    if let standardInput {
                        guard let stagedInput =
                                try processBoundary.stageStandardInput(
                                    standardInput
                                ) else {
                            processBoundary.clear()
                            continuation.resume(returning: ProcessRun(
                                exitCode: -1,
                                standardOutput: "",
                                standardError:
                                    "Blocked by Private Mode.",
                                timedOut: false
                            ))
                            return
                        }
                        privateInputHandle = stagedInput
                        process.standardInput = stagedInput
                    } else {
                        process.standardInput = FileHandle.nullDevice
                    }
                    guard try processBoundary.launchAndPublish(process) else {
                        try? privateInputHandle?.close()
                        processBoundary.clear()
                        continuation.resume(returning: ProcessRun(
                            exitCode: -1,
                            standardOutput: "",
                            standardError: "Blocked by Private Mode.",
                            timedOut: false
                        ))
                        return
                    }
                } catch {
                    try? privateInputHandle?.close()
                    processBoundary.clear()
                    continuation.resume(returning: ProcessRun(
                        exitCode: -1,
                        standardOutput: "",
                        standardError: error.localizedDescription,
                        timedOut: false
                    ))
                    return
                }
                try? privateInputHandle?.close()

                // Drain both pipes on their own threads: a CLI that writes more
                // than a pipe buffer while we block on waitUntilExit would hang
                // forever, and the timeout below would report a stall that is
                // really our own deadlock.
                let outputData = BrainProcessDataBox()
                let errorData = BrainProcessDataBox()
                let drainGroup = DispatchGroup()
                for (pipe, isStandardOutput) in [(outputPipe, true), (errorPipe, false)] {
                    drainGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        if isStandardOutput {
                            outputData.store(data)
                        } else {
                            errorData.store(data)
                        }
                        drainGroup.leave()
                    }
                }

                let watchdog = DispatchWorkItem {
                    processBoundary.cancel()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

                process.waitUntilExit()
                let didTimeOut = !watchdog.isCancelled && process.terminationReason == .uncaughtSignal
                watchdog.cancel()
                _ = drainGroup.wait(timeout: .now() + 5)

                let capturedOutput =
                    String(data: outputData.snapshot(), encoding: .utf8) ?? ""
                let capturedError =
                    String(data: errorData.snapshot(), encoding: .utf8) ?? ""
                processBoundary.clear()

                continuation.resume(returning: ProcessRun(
                    exitCode: process.terminationStatus,
                    standardOutput: capturedOutput,
                    standardError: capturedError,
                    timedOut: didTimeOut
                ))
            }
            }
        } onCancel: {
            processBoundary.cancel()
        }
    }
}
#endif // circuit-convert
