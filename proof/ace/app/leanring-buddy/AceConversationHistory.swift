//
//  AceConversationHistory.swift
//  Ace
//
//  Ace remembers the conversation across relaunches again.
//
//  HISTORY: added 2026-07-17 as `history.json`, whose commit message named the
//  exact problem it fixed — "Ace previously claimed persistent memory while
//  holding a RAM array." Deleted 2026-08-04 in commit 4ec70d12, entangled with
//  four removed cloud brain backends, inside a 255-file change. The array stayed;
//  only the load and save went. So Ace went straight back to claiming memory
//  while holding a RAM array, and the docs were edited to call that the design.
//
//  ON-DISK FORMAT IS DELIBERATELY THE ORIGINAL: `[[user, assistant], ...]`.
//  Buyers whose Macs still hold a history.json from July get their conversation
//  back on upgrade instead of a silent reset.
//
//  Two rules, both learned the hard way:
//  1. Stealth wins — same boundary the transcript and effect-guard.sh use.
//  2. One malformed entry costs ONE entry. Decoding whole-file-or-nothing is
//     how a single truncated write erases everything above it.
//

#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

typealias AceConversationExchange = (userTranscript: String, assistantResponse: String)

struct AceGoldContextRelaunchLoadResult {
    let bundle: AceGoldContextBundle
    let pendingRecovery: AceGoldContextBundle?
}

enum AceConversationHistory {
    static let fileName = "history.json"
    static let bundleFileName = "gold-context-v1.json"
    static let migrationTombstoneFileName =
        "gold-context-v1.migrated"
    static let previousBundleFileName =
        "gold-context-v1.previous.json"
    static let bundleEncryptionKeyFileName =
        "gold-context-v1.key"
    private static let maximumBundleBytes = 2_000_000
    private static let bundleEncryptionPrefix =
        Data("ACE-GOLD-CONTEXT-AESGCM-V1\n".utf8)
    private static let bundleEncryptionOverheadAllowance = 128
    private static let bundleEncryptionKeyLock = NSLock()
    /// Matches the in-memory cap in CompanionManager: the prompt carries the
    /// last ten exchanges. This governs the PROMPT only — never the file.
    static let maxExchanges = 10

    /// What DISK keeps, which is deliberately far more than the prompt window.
    ///
    /// The file previously held `maxExchanges` too, and `save` writes whatever
    /// CompanionManager currently holds — which is exactly those ten. So every
    /// save rewrote the file with the sliding window and permanently destroyed
    /// everything above it: turn 11 erased turn 1 from disk, and no amount of
    /// later recall could recover it because the bytes were gone. That is the
    /// whole of "Ace doesn't remember". Retention is bounded by
    /// `maximumBundleBytes` on the bundle path and by this count here.
    static let maxRetainedExchanges = 500

    enum ReadIssue: Equatable {
        case unreadable, recoveredPrevious, missingSavedHistory

        var ownerMessage: String {
            switch self {
            case .unreadable:
                return "Ace could not read its saved conversation and work history. The existing files are preserved; new history cannot be saved until recovery. Restore the history files and matching encryption key from your backup, then check again."
            case .recoveredPrevious:
                return "Ace recovered an earlier saved history because the latest copy could not be read. Recent exchanges or work results may be missing."
            case .missingSavedHistory:
                return "Ace's previously saved conversation and work history is missing. Earlier follow-ups and work receipts are unavailable. Restore your saved history and its matching encryption key from backup to recover them."
            }
        }
    }

    static let readIssueDidChangeNotification = Notification.Name(
        "com.blacklabel.ace.saved-context-read-issue-changed"
    )
    private static let readIssueLock = NSLock()
    private static var readIssues: [String: ReadIssue] = [:]

    nonisolated static func lastReadIssue(directory: URL? = nil) -> ReadIssue? {
        guard let directory = directory ?? AceTranscript.supportDirectory() else { return nil }
        return readIssueLock.withLock { readIssues[directory.standardizedFileURL.path] }
    }

    private nonisolated static func recordReadIssue(_ issue: ReadIssue?, directory: URL) {
        let changed = readIssueLock.withLock {
            let path = directory.standardizedFileURL.path
            guard readIssues[path] != issue else { return false }
            readIssues[path] = issue
            return true
        }
        // Content-free presentation signal, sent after releasing the lock.
        if changed {
            NotificationCenter.default.post(name: readIssueDidChangeNotification, object: nil)
        }
    }

    // MARK: - Pure

    /// Per-entry recovery. A pair that is malformed, short, or empty is skipped;
    /// everything readable around it survives.
    nonisolated static func decode(_ data: Data) -> [AceConversationExchange] {
        guard let pairs = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
        return pairs.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            let user = pair[0]
            let assistant = pair[1]
            guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (userTranscript: user, assistantResponse: assistant)
        }
    }

    nonisolated static func encode(_ history: [AceConversationExchange]) -> Data? {
        let pairs = history
            .suffix(maxRetainedExchanges)
            .map { [$0.userTranscript, $0.assistantResponse] }
        return try? JSONEncoder().encode(Array(pairs))
    }

    /// Folds the caller's sliding window onto what the file already holds.
    ///
    /// The caller passes the last `maxExchanges` exchanges, so a plain write
    /// would truncate. Splicing on the longest suffix-of-existing that is also
    /// a prefix-of-incoming appends only genuinely new turns, which makes a
    /// repeated save idempotent and keeps a full replay from turn 1 from
    /// duplicating the archive. Pure, so it is verifiable without the app:
    /// 40 turns through a sliding 10-window lose nothing.
    nonisolated static func merging(
        existing: [AceConversationExchange],
        incoming: [AceConversationExchange]
    ) -> [AceConversationExchange] {
        guard !incoming.isEmpty else { return existing }
        guard !existing.isEmpty else {
            return Array(incoming.suffix(maxRetainedExchanges))
        }
        let sameExchange: (AceConversationExchange, AceConversationExchange) -> Bool = {
            $0.userTranscript == $1.userTranscript
                && $0.assistantResponse == $1.assistantResponse
        }
        var overlap = 0
        var candidate = min(existing.count, incoming.count)
        while candidate > 0 {
            if zip(existing.suffix(candidate), incoming.prefix(candidate))
                .allSatisfy(sameExchange) {
                overlap = candidate
                break
            }
            candidate -= 1
        }
        return Array(
            (existing + incoming.dropFirst(overlap))
                .suffix(maxRetainedExchanges)
        )
    }

    // MARK: - Disk

    nonisolated static func load(directory: URL? = nil) -> [AceConversationExchange] {
        guard let directory = directory ?? AceTranscript.supportDirectory() else { return [] }
        // A relaunch while Private Mode is intended starts a minimal hidden
        // runtime; it must not rehydrate the owner's conversation either.
        guard !AceTranscript.stealthBlocksWriting(supportDirectory: directory) else { return [] }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else {
            return []
        }
        return Array(decode(data).suffix(maxExchanges))
    }

    nonisolated static func save(
        _ history: [AceConversationExchange],
        directory: URL? = nil
    ) {
        guard let directory = directory ?? AceTranscript.supportDirectory() else { return }
        guard (try? PrivateSupportDirectory.ensure(at: directory)) != nil else { return }
        guard !AceTranscript.stealthBlocksWriting(supportDirectory: directory) else { return }
        let fileURL = directory.appendingPathComponent(fileName)
        // Fold onto the archive instead of overwriting it. `history` is the
        // caller's ten-exchange prompt window; writing it straight out is what
        // erased every older turn from disk.
        let existing = (try? Data(contentsOf: fileURL)).map(decode) ?? []
        guard let data = encode(merging(existing: existing, incoming: history)) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    // MARK: - Correlated Gold context bundle

    /// Loads the whole durable Gold projection. Once a v1 bundle exists it is
    /// authoritative: malformed or oversized bytes return empty rather than
    /// falling back to an older history.json with stale context. The legacy
    /// file is consulted only for a one-way, identity-free migration when no
    /// bundle has ever been written.
    nonisolated static func loadBundle(
        directory: URL? = nil,
        performUnlessRaised: (_ body: () -> Bool) -> Bool?
    ) -> AceGoldContextBundle {
        guard let directory = directory ?? AceTranscript.supportDirectory(),
              !AceTranscript.stealthBlocksWriting(supportDirectory: directory),
              performUnlessRaised({ true }) == true else { return .empty }

        // Publish health only after the final privacy admission. A denied read
        // is neither empty history nor a new corruption report.
        func finish(_ bundle: AceGoldContextBundle, issue: ReadIssue?) -> AceGoldContextBundle {
            guard !AceTranscript.stealthBlocksWriting(supportDirectory: directory),
                  performUnlessRaised({ true }) == true else { return .empty }
            recordReadIssue(issue, directory: directory)
            return bundle
        }
        let current = directory.appendingPathComponent(bundleFileName)
        let previous = directory.appendingPathComponent(previousBundleFileName)
        if let bundle = validatedBundle(at: current, directory: directory) {
            return finish(bundle, issue: nil)
        }
        if let recovered = validatedBundle(at: previous, directory: directory) {
            return finish(recovered, issue: .recoveredPrevious)
        }
        if fixedObjectExists(current) || fixedObjectExists(previous) {
            return finish(.empty, issue: .unreadable)
        }
        if fixedObjectExists(directory.appendingPathComponent(migrationTombstoneFileName)) {
            return finish(.empty, issue: .missingSavedHistory)
        }
        return finish(AceGoldContextBundle.migratingLegacy(load(directory: directory)), issue: nil)
    }

    /// Relaunch-only admission. A vanished process cannot leave work marked
    /// running: convert it to an app-observed interrupted receipt and persist
    /// that correction before the next owner continuation is resolved.
    nonisolated static func loadBundleRecoveringInterruptedWork(
        directory: URL? = nil,
        preservingRunningWorkCorrelationIdentifiers:
            Set<UUID> = [],
        performUnlessRaised:
            (_ body: () -> Bool) -> Bool?,
        saveRecoveredBundle: ((AceGoldContextBundle) -> Bool)? = nil
    ) -> AceGoldContextBundle {
        loadBundleForRelaunch(
            directory: directory,
            preservingRunningWorkCorrelationIdentifiers:
                preservingRunningWorkCorrelationIdentifiers,
            performUnlessRaised: performUnlessRaised,
            saveRecoveredBundle: saveRecoveredBundle
        ).bundle
    }

    nonisolated static func loadBundleForRelaunch(
        directory: URL? = nil,
        interruptionCause: AceGoldInterruptionCause = .relaunch,
        preservingRunningWorkCorrelationIdentifiers:
            Set<UUID> = [],
        performUnlessRaised:
            (_ body: () -> Bool) -> Bool?,
        saveRecoveredBundle: ((AceGoldContextBundle) -> Bool)? = nil
    ) -> AceGoldContextRelaunchLoadResult {
        let loaded = loadBundle(
            directory: directory,
            performUnlessRaised: performUnlessRaised
        )
        var bundle = loaded
        guard bundle.recoverInterruptedWork(
            cause: interruptionCause,
            preservingRunningWorkCorrelationIdentifiers:
                preservingRunningWorkCorrelationIdentifiers
        ) > 0 else {
            return AceGoldContextRelaunchLoadResult(
                bundle: bundle,
                pendingRecovery: nil
            )
        }
        let persisted = saveRecoveredBundle?(bundle) ?? saveBundle(
                bundle,
                directory: directory,
                performUnlessRaised: performUnlessRaised
            )
        // Recovery is an authoritative state transition, not a RAM-only hint.
        // If X or disk failure rejects it, keep the original running projection
        // so the next turn/relaunch can retry instead of losing an invented
        // in-memory terminal at its first atomic reload.
        return AceGoldContextRelaunchLoadResult(
            bundle: persisted ? bundle : loaded,
            pendingRecovery: persisted ? nil : bundle
        )
    }

    /// Atomic, owner-only bundle commit. The Boolean is an observability
    /// contract for CompanionManager; a failed or Stealth-blocked write never
    /// becomes a claimed relaunch receipt.
    @discardableResult
    nonisolated static func saveBundle(
        _ bundle: AceGoldContextBundle,
        directory: URL? = nil,
        performUnlessRaised:
            (_ body: () -> Bool) -> Bool?,
        stageWriter: ((Data, String, URL) -> URL?)? = nil,
        continueBeforeCommitStep: ((Int) -> Bool)? = nil,
        continueAfterCommitStep: ((Int) -> Bool)? = nil
    ) -> Bool {
        guard let directory = directory
                ?? AceTranscript.supportDirectory() else {
            return false
        }
        // The first admission is intentionally in-memory only. Directory
        // creation, encoding, staging, chmod, validation and cleanup all stay
        // outside the event-tap latch so X is never queued behind disk I/O.
        guard !AceTranscript.stealthBlocksWriting(
            supportDirectory: directory
        ), performUnlessRaised({ true }) == true,
        (try? PrivateSupportDirectory.ensure(at: directory)) != nil,
        !AceTranscript.stealthBlocksWriting(
            supportDirectory: directory
        ) else {
            return false
        }
        let fileURL = directory.appendingPathComponent(
            bundleFileName
        )
        if FileManager.default.fileExists(atPath: fileURL.path),
           let values = try? fileURL.resourceValues(
               forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
           ),
           values.isRegularFile != true
                || values.isSymbolicLink == true {
            return false
        }
        let tombstoneURL = directory.appendingPathComponent(
            migrationTombstoneFileName
        )
        let previousURL = directory.appendingPathComponent(
            previousBundleFileName
        )
        let encryptionKeyURL = directory.appendingPathComponent(
            bundleEncryptionKeyFileName
        )
        guard canonicalTargetIsSafe(fileURL),
            canonicalTargetIsSafe(tombstoneURL),
            canonicalTargetIsSafe(previousURL),
            canonicalTargetIsSafe(encryptionKeyURL) else {
            return false
        }
        // Never replace irrecoverable generations or mint a replacement key
        // over them. Restoring the owner's original key must still recover the
        // original bytes. A verified prior generation can repair a bad current.
        let validCurrent = validatedBundleData(at: fileURL, directory: directory)
        let validPrevious = validatedBundleData(at: previousURL, directory: directory)
        guard !(fixedObjectExists(fileURL) || fixedObjectExists(previousURL))
                || validCurrent != nil || validPrevious != nil else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let normalized = bundle.normalizedForPersistence(
            maximumBytes:
                maximumBundleBytes
                    - bundleEncryptionOverheadAllowance
        ),
        let plaintextData = try? encoder.encode(normalized),
        let data = encryptedBundleData(
            plaintextData,
            directory: directory,
            createKeyIfMissing: true
        ),
        data.count <= maximumBundleBytes else {
            return false
        }
        let writeStage = stageWriter ?? { data, finalName, directory in
            writePrivateStage(
                data,
                finalName: finalName,
                directory: directory
            )
        }
        guard let currentStageURL = writeStage(
            data,
            bundleFileName,
            directory
        ) else {
            return false
        }
        var stagedURLs = [currentStageURL]
        defer {
            for stagedURL in stagedURLs {
                try? FileManager.default.removeItem(at: stagedURL)
            }
        }

        // Only a validated current generation may become the next backup. A
        // malformed current is replaced without touching an already-valid
        // previous generation.
        var previousStageURL: URL?
        let validPriorGenerationData: Data?
        if let validCurrent {
            validPriorGenerationData = validCurrent
        } else if let recoveredPrevious = validPrevious {
            // Missing *or corrupt* current may leave a legacy plaintext
            // previous generation as the last known good state. Preserve that
            // state, but always rotate it through encryption so recovery never
            // leaves owner text at rest indefinitely.
            validPriorGenerationData = recoveredPrevious
        } else {
            validPriorGenerationData = nil
        }
        if let validPriorGenerationData,
           let protectedCurrentData = encryptedBundleDataIfNeeded(
            validPriorGenerationData,
            directory: directory
        ) {
            guard let stagedPrevious = writeStage(
                protectedCurrentData,
                previousBundleFileName,
                directory
            ) else {
                return false
            }
            previousStageURL = stagedPrevious
            stagedURLs.append(stagedPrevious)
        }
        guard let tombstoneStageURL = writeStage(
            Data("v1\n".utf8),
            migrationTombstoneFileName,
            directory
        ) else {
            return false
        }
        stagedURLs.append(tombstoneStageURL)

        // Filesystem work, including each rename, remains outside the entry latch.
        // A latch admission is only an in-memory epoch check immediately before
        // and after a rename. X therefore never waits behind disk I/O. A rename
        // that was already admitted may finish after X wins, but it can move
        // only AES-GCM ciphertext; the post-check reports the save as uncommitted
        // and generation ordering keeps either the old or new current loadable.
        func stealthAllowsCommitStep() -> Bool {
            guard !AceTranscript.stealthBlocksWriting(
                supportDirectory: directory
            ) else {
                return false
            }
            return performUnlessRaised({ true }) == true
        }

        guard stealthAllowsCommitStep() else { return false }
        var commitStep = 0
        func commit(
            _ staged: URL,
            replacing target: URL
        ) -> Bool {
            let nextStep = commitStep + 1
            guard continueBeforeCommitStep?(nextStep) ?? true,
                  stealthAllowsCommitStep(),
                  atomicRename(staged, replacing: target) else {
                return false
            }
            commitStep = nextStep
            guard continueAfterCommitStep?(commitStep) ?? true else {
                return false
            }
            return stealthAllowsCommitStep()
        }

        // A backup commits first, while the old current remains valid.
        if let previousStageURL,
           !commit(previousStageURL, replacing: previousURL) {
            return false
        }
        // The new current is always durable before legacy retirement.
        guard commit(currentStageURL, replacing: fileURL) else {
            return false
        }
        guard commit(
            tombstoneStageURL,
            replacing: tombstoneURL
        ) else {
            return false
        }
        return true
    }

    private nonisolated static func writePrivateStage(
        _ data: Data,
        finalName: String,
        directory: URL
    ) -> URL? {
        let stageURL = directory.appendingPathComponent(
            ".\(finalName).stage-\(UUID().uuidString)"
        )
        do {
            try data.write(to: stageURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stageURL.path
            )
            return stageURL
        } catch {
            try? FileManager.default.removeItem(at: stageURL)
            return nil
        }
    }

    private nonisolated static func validatedBundle(
        at url: URL,
        directory: URL
    ) -> AceGoldContextBundle? {
        guard let data = validatedBundleData(
            at: url,
            directory: directory
        ) else {
            return nil
        }
        return decodedPersistedBundle(
            data,
            directory: directory
        )
    }

    private nonisolated static func validatedBundleData(
        at url: URL,
        directory: URL
    ) -> Data? {
        guard let values = try? url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        (values.fileSize ?? Int.max) <= maximumBundleBytes,
        !AceTranscript.stealthBlocksWriting(
            supportDirectory: directory
        ),
        let data = try? Data(contentsOf: url),
        decodedPersistedBundle(
            data,
            directory: directory
        ) != nil else {
            return nil
        }
        return data
    }

    /// Context generations are encrypted before any filesystem staging. A
    /// slow write may finish after the owner's X event without delaying that
    /// event, but the bytes that can outlive the cutoff never contain owner
    /// plaintext. The final publication remains a bounded rename admitted by
    /// the Stealth latch.
    private nonisolated static func encryptedBundleData(
        _ plaintext: Data,
        directory: URL,
        createKeyIfMissing: Bool
    ) -> Data? {
        guard let key = bundleEncryptionKey(
            directory: directory,
            createIfMissing: createKeyIfMissing
        ), let sealed = try? AES.GCM.seal(
            plaintext,
            using: key
        ), let combined = sealed.combined else {
            return nil
        }
        var persisted = bundleEncryptionPrefix
        persisted.append(combined)
        return persisted
    }

    private nonisolated static func encryptedBundleDataIfNeeded(
        _ data: Data,
        directory: URL
    ) -> Data? {
        if data.starts(with: bundleEncryptionPrefix) {
            return data
        }
        return encryptedBundleData(
            data,
            directory: directory,
            createKeyIfMissing: true
        )
    }

    private nonisolated static func decodedPersistedBundle(
        _ data: Data,
        directory: URL
    ) -> AceGoldContextBundle? {
        guard data.starts(with: bundleEncryptionPrefix) else {
            // One-way compatibility for pre-encryption v1 generations. The
            // next successful save rotates only encrypted bytes.
            return AceGoldContextBundle.decodeValidated(data)
        }
        let combined = Data(
            data.dropFirst(bundleEncryptionPrefix.count)
        )
        guard let key = bundleEncryptionKey(
            directory: directory,
            createIfMissing: false
        ), let sealed = try? AES.GCM.SealedBox(combined: combined),
        let plaintext = try? AES.GCM.open(sealed, using: key),
        plaintext.count
            <= maximumBundleBytes
                - bundleEncryptionOverheadAllowance else {
            return nil
        }
        return AceGoldContextBundle.decodeValidated(plaintext)
    }

    private nonisolated static func bundleEncryptionKey(
        directory: URL,
        createIfMissing: Bool
    ) -> SymmetricKey? {
        bundleEncryptionKeyLock.withLock {
            let keyURL = directory.appendingPathComponent(
                bundleEncryptionKeyFileName
            )
            if fixedObjectExists(keyURL) {
                guard let values = try? keyURL.resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .fileSizeKey,
                    ]
                ), values.isRegularFile == true,
                values.isSymbolicLink != true,
                values.fileSize == 32,
                let keyData = try? Data(contentsOf: keyURL),
                keyData.count == 32 else {
                    return nil
                }
                return SymmetricKey(data: keyData)
            }
            guard createIfMissing else { return nil }
            let key = SymmetricKey(size: .bits256)
            let keyData = key.withUnsafeBytes { Data($0) }
            guard let staged = writePrivateStage(
                keyData,
                finalName: bundleEncryptionKeyFileName,
                directory: directory
            ) else {
                return nil
            }
            defer { try? FileManager.default.removeItem(at: staged) }
            guard atomicRename(staged, replacing: keyURL),
            (try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keyURL.path
            )) != nil else {
                return nil
            }
            return key
        }
    }

    private nonisolated static func fixedObjectExists(
        _ url: URL
    ) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.attributesOfItem(
                atPath: url.path
            )) != nil
    }

    private nonisolated static func canonicalTargetIsSafe(
        _ url: URL
    ) -> Bool {
        guard fixedObjectExists(url) else { return true }
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
    }

    private nonisolated static func atomicRename(
        _ staged: URL,
        replacing target: URL
    ) -> Bool {
        staged.path.withCString { sourcePath in
            target.path.withCString { targetPath in
                Darwin.rename(sourcePath, targetPath) == 0
            }
        }
    }
}
