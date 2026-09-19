#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
import Foundation

enum AceHQPendingDispatchRecoveryState: String, Codable, Equatable, Sendable {
    case reconciling
    case ownerSuspended = "owner_suspended"
}

struct AceHQPendingDispatchRecoveryRecord: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let state: AceHQPendingDispatchRecoveryState
    let pending: AceHQPendingDispatch
    let reconciliationAttempt: AceHQReconciliationAttempt?

    private enum CodingKeys: String, CodingKey {
        case version
        case state
        case pending
        case reconciliationAttempt = "reconciliation_attempt"
    }

    init(
        version: Int,
        state: AceHQPendingDispatchRecoveryState,
        pending: AceHQPendingDispatch,
        reconciliationAttempt: AceHQReconciliationAttempt? = nil
    ) {
        self.version = version
        self.state = state
        self.pending = pending
        self.reconciliationAttempt = reconciliationAttempt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        state = try container.decode(
            AceHQPendingDispatchRecoveryState.self,
            forKey: .state
        )
        pending = try container.decode(
            AceHQPendingDispatch.self,
            forKey: .pending
        )
        reconciliationAttempt = try container.decodeIfPresent(
            AceHQReconciliationAttempt.self,
            forKey: .reconciliationAttempt
        )
    }

    var isValid: Bool {
        let envelope = pending.envelope
        let supportedVersion = version == Self.currentVersion
            || (
                version == 1
                    && reconciliationAttempt == nil
                    && envelope.authority == .planOnly
            )
        let executionStateValid: Bool
        switch envelope.authority {
        case .planOnly:
            executionStateValid = pending.executionID == nil
                && pending.executionPhase == nil
        case .executeWhitelisted:
            switch (pending.executionID, pending.executionPhase) {
            case (nil, nil):
                executionStateValid = true
            case (.some(let executionID), .some(let phase)):
                executionStateValid = !executionID.isEmpty
                    && executionID.count <= 512
                    && phase != .terminal
            default:
                executionStateValid = false
            }
        }
        return supportedVersion
            && envelope.schemaVersion == 2
            && envelope.hasCoherentAuthority
            && executionStateValid
            && canonicalUUID(envelope.source.sessionID)
            && canonicalUUID(envelope.source.turnID)
            && canonicalUUID(envelope.source.correlationID)
            && canonicalUUID(envelope.work.correlationID)
            && (envelope.work.parentCorrelationID.map(canonicalUUID) ?? true)
            && envelope.intent == pending.intent
            && !pending.sessionID.isEmpty
            && pending.sessionID.count <= 512
            && !pending.acceptedEventID.isEmpty
            && pending.acceptedEventID.count <= 512
            && pending.nextEventSequence >= 0
            && (reconciliationAttempt?.isValid(
                for: pending.intent
            ) ?? true)
    }

    private func canonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

/// One owner-only durable accepted cursor. HQ permits one in-flight dispatch,
/// so a single exact record is enough and prevents ambiguous relaunch fan-out.
enum AceHQPendingDispatchStore {
    static let fileName = "ace-hq-pending-v1.json"
    // Do not share the Gold store's first-generation key path. Each store has
    // its own creator lock, so sharing a filename could let two concurrent
    // first saves replace each other's key and orphan one ciphertext.
    static let encryptionKeyFileName = "ace-hq-pending-v1.key"
    private static let maximumBytes = 1_000_000
    private static let encryptionPrefix =
        Data("ACE-HQ-PENDING-AESGCM-V1\n".utf8)
    private static let keyLock = NSLock()

    static func load(
        directory: URL? = nil,
        performUnlessRaised:
            (_ body: () -> Bool) -> Bool?
    ) -> AceHQPendingDispatchRecoveryRecord? {
        guard let directory = directory
                ?? AceTranscript.supportDirectory(),
              !AceTranscript.stealthBlocksWriting(
                  supportDirectory: directory
              ),
              performUnlessRaised({ true }) == true else {
            return nil
        }
        let fileURL = directory.appendingPathComponent(fileName)
        guard privateRegularFile(fileURL),
              let encrypted = try? Data(contentsOf: fileURL),
              encrypted.count <= maximumBytes,
              let data = decodedPersistedData(
                  encrypted,
                  directory: directory
              ),
              let record = try? JSONDecoder().decode(
                  AceHQPendingDispatchRecoveryRecord.self,
                  from: data
              ),
              record.isValid,
              !AceTranscript.stealthBlocksWriting(
                  supportDirectory: directory
              ),
              performUnlessRaised({ true }) == true else {
            return nil
        }
        return record
    }

    @discardableResult
    static func save(
        _ pending: AceHQPendingDispatch,
        state: AceHQPendingDispatchRecoveryState = .reconciling,
        reconciliationAttempt: AceHQReconciliationAttempt? = nil,
        directory: URL? = nil,
        performUnlessRaised:
            (_ body: () -> Bool) -> Bool?,
        stageWriter: ((Data, URL) -> URL?)? = nil,
        continueBeforeCommit: (() -> Bool)? = nil,
        continueAfterCommit: (() -> Bool)? = nil
    ) -> Bool {
        guard let directory = directory
                ?? AceTranscript.supportDirectory(),
              !AceTranscript.stealthBlocksWriting(
                  supportDirectory: directory
              ),
              performUnlessRaised({ true }) == true,
              (try? PrivateSupportDirectory.ensure(at: directory)) != nil,
              !AceTranscript.stealthBlocksWriting(
                  supportDirectory: directory
              ) else {
            return false
        }
        let record = AceHQPendingDispatchRecoveryRecord(
            version: AceHQPendingDispatchRecoveryRecord.currentVersion,
            state: state,
            pending: pending,
            reconciliationAttempt: reconciliationAttempt
        )
        guard record.isValid,
              let plaintext = try? JSONEncoder.sorted.encode(record),
              let data = encrypt(
                  plaintext,
                  directory: directory,
                  createKeyIfMissing: true
              ),
              data.count <= maximumBytes else {
            return false
        }
        let fileURL = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: fileURL.path),
           !privateRegularFile(fileURL) {
            return false
        }
        let writeStage = stageWriter ?? { bytes, targetDirectory in
            writePrivateStage(bytes, directory: targetDirectory)
        }
        guard let stagedURL = writeStage(data, directory) else {
            return false
        }
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        func stealthAllowsCommit() -> Bool {
            !AceTranscript.stealthBlocksWriting(
                supportDirectory: directory
            ) && performUnlessRaised({ true }) == true
        }
        guard privateRegularFile(stagedURL),
              (continueBeforeCommit?() ?? true),
              stealthAllowsCommit(),
              atomicRename(stagedURL, replacing: fileURL),
              (continueAfterCommit?() ?? true),
              stealthAllowsCommit(),
              !AceTranscript.stealthBlocksWriting(
                  supportDirectory: directory
              ),
              privateRegularFile(fileURL) else {
            return false
        }
        return true
    }

    @discardableResult
    static func suspendCurrent(
        directory: URL? = nil,
        performUnlessRaised:
            (_ body: () -> Bool) -> Bool?
    ) -> Bool {
        guard let record = load(
            directory: directory,
            performUnlessRaised: performUnlessRaised
        ) else { return true }
        return save(
            record.pending,
            state: .ownerSuspended,
            reconciliationAttempt: record.reconciliationAttempt,
            directory: directory,
            performUnlessRaised: performUnlessRaised
        )
    }

    @discardableResult
    static func clear(
        expectedWorkCorrelationID: String,
        directory: URL? = nil,
        performUnlessRaised:
            (_ body: () -> Bool) -> Bool?,
        continueBeforeRemove: (() -> Bool)? = nil,
        continueAfterRemove: (() -> Bool)? = nil
    ) -> Bool {
        guard let directory = directory
                ?? AceTranscript.supportDirectory(),
              !AceTranscript.stealthBlocksWriting(
                  supportDirectory: directory
              ),
              performUnlessRaised({ true }) == true else {
            return false
        }
        let fileURL = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return true
        }
        guard let record = load(
            directory: directory,
            performUnlessRaised: performUnlessRaised
        ), record.pending.envelope.work.correlationID
            == expectedWorkCorrelationID,
              !AceTranscript.stealthBlocksWriting(
                  supportDirectory: directory
              ),
              performUnlessRaised({ true }) == true,
              (continueBeforeRemove?() ?? true),
              !AceTranscript.stealthBlocksWriting(
                  supportDirectory: directory
              ),
              performUnlessRaised({ true }) == true else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return (continueAfterRemove?() ?? true)
                && !AceTranscript.stealthBlocksWriting(
                    supportDirectory: directory
                )
                && performUnlessRaised({ true }) == true
                && !FileManager.default.fileExists(atPath: fileURL.path)
        } catch {
            return false
        }
    }

    private static func writePrivateStage(
        _ data: Data,
        directory: URL
    ) -> URL? {
        let stagedURL = directory.appendingPathComponent(
            ".\(fileName).stage-\(UUID().uuidString)"
        )
        do {
            try data.write(
                to: stagedURL,
                options: .withoutOverwriting
            )
            guard chmod(stagedURL.path, mode_t(0o600)) == 0,
                  privateRegularFile(stagedURL) else {
                try? FileManager.default.removeItem(at: stagedURL)
                return nil
            }
            return stagedURL
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            return nil
        }
    }

    private static func atomicRename(
        _ staged: URL,
        replacing target: URL
    ) -> Bool {
        staged.path.withCString { sourcePath in
            target.path.withCString { targetPath in
                Darwin.rename(sourcePath, targetPath) == 0
            }
        }
    }

    private static func encrypt(
        _ plaintext: Data,
        directory: URL,
        createKeyIfMissing: Bool
    ) -> Data? {
        guard let key = encryptionKey(
            directory: directory,
            createIfMissing: createKeyIfMissing
        ), let sealed = try? AES.GCM.seal(
            plaintext,
            using: key
        ), let combined = sealed.combined else {
            return nil
        }
        var persisted = encryptionPrefix
        persisted.append(combined)
        return persisted
    }

    private static func decrypt(
        _ persisted: Data,
        directory: URL
    ) -> Data? {
        guard persisted.starts(with: encryptionPrefix),
              let key = encryptionKey(
                  directory: directory,
                  createIfMissing: false
              ), let box = try? AES.GCM.SealedBox(
                  combined: Data(
                      persisted.dropFirst(encryptionPrefix.count)
                  )
              ) else {
            return nil
        }
        return try? AES.GCM.open(box, using: key)
    }

    /// One-way upgrade compatibility for accepted cursors written by the
    /// original schema-v1 store. A valid legacy plaintext record remains
    /// recoverable after upgrade; the next save always rotates it to AES-GCM.
    private static func decodedPersistedData(
        _ persisted: Data,
        directory: URL
    ) -> Data? {
        if persisted.starts(with: encryptionPrefix) {
            return decrypt(persisted, directory: directory)
        }
        return persisted
    }

    private static func encryptionKey(
        directory: URL,
        createIfMissing: Bool
    ) -> SymmetricKey? {
        keyLock.withLock {
            let keyURL = directory.appendingPathComponent(
                encryptionKeyFileName
            )
            if FileManager.default.fileExists(atPath: keyURL.path) {
                guard privateRegularFile(keyURL),
                      let data = try? Data(contentsOf: keyURL),
                      data.count == 32 else {
                    return nil
                }
                return SymmetricKey(data: data)
            }
            guard createIfMissing else { return nil }
            let key = SymmetricKey(size: .bits256)
            let keyData = key.withUnsafeBytes { Data($0) }
            let stage = directory.appendingPathComponent(
                ".\(encryptionKeyFileName).stage-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: stage) }
            guard (try? keyData.write(
                to: stage,
                options: .withoutOverwriting
            )) != nil,
            chmod(stage.path, mode_t(0o600)) == 0,
            privateRegularFile(stage),
            atomicRename(stage, replacing: keyURL),
            privateRegularFile(keyURL) else {
                return nil
            }
            return key
        }
    }

    private static func privateRegularFile(_ fileURL: URL) -> Bool {
        guard let values = try? fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ), values.isRegularFile == true,
              values.isSymbolicLink != true,
              let attributes = try? FileManager.default.attributesOfItem(
                  atPath: fileURL.path
              ), let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.intValue & 0o077 == 0
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
