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

struct AceCredentialDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var licenseToken: String?
    var hostedBrainToken: String?
    /// The local store provides durability only. Offline authority comes from
    /// the server's Ed25519 signature, which is revalidated on every launch.
    var signedLicenseLeaseKeyId: String?
    var signedLicenseLeasePayload: String?
    var signedLicenseLeaseSignature: String?
    var partnerProfileKeys: [String: String]
    /// Device-link transaction phases live INSIDE this sealed document — the
    /// pending session (with its poll secret) and the awaiting-server
    /// acknowledgement phase must never touch disk as plaintext. Stored as
    /// opaque encoded JSON so this file stays dependency-free; the
    /// transaction store owns the concrete session type. Optional with
    /// defaults so every existing v1 document keeps decoding unchanged.
    var deviceLinkSessionJSON: String? = nil
    var deviceLinkAcknowledgementPendingJSON: String? = nil
    /// Durable proof that the server acknowledged credential delivery for the
    /// direct device flow (epoch milliseconds). `.licensed`/linked publication
    /// is gated on this value existing.
    var deviceLinkDeliveryAttestedAtMs: Double? = nil

    var academicGPTZeroAPIKey: String? = nil
    var academicGPTZeroEnabled: Bool? = nil

    static let empty = AceCredentialDocument(
        schemaVersion: 1,
        licenseToken: nil,
        hostedBrainToken: nil,
        signedLicenseLeaseKeyId: nil,
        signedLicenseLeasePayload: nil,
        signedLicenseLeaseSignature: nil,
        partnerProfileKeys: [:]
    )
}

private struct AceEncryptedCredentialEnvelope: Codable {
    let schemaVersion: Int
    let encryption: String
    let sealedDocument: String
}

protocol AceCredentialStoring: Sendable {
    func load() throws -> AceCredentialDocument
    func update(
        _ transform: (inout AceCredentialDocument) throws -> Void
    ) throws
}

enum PromptFreeCredentialStoreError: Error, Equatable, LocalizedError {
    case unsafeCredentialDirectory
    case unsafeCredentialFile
    case unsafeCredentialKeyFile
    case missingCredentialKey
    case malformedCredentialKey
    case malformedDocument
    case unsupportedSchema
    case couldNotCreateTemporaryFile
    case atomicReplaceFailed
    case recoveryInterrupted
    case recoveryChanged
    case recoveryNotNeeded

    var errorDescription: String? {
        switch self {
        case .missingCredentialKey:
            return "Ace's saved credentials are present, but their encryption key is missing. Restore the original key from your backup, or review credential recovery."
        case .malformedCredentialKey, .malformedDocument:
            return "Ace's saved credentials could not be read. Restore the original credential files from your backup, or review credential recovery."
        case .unsupportedSchema:
            return "These credentials use an unsupported format. Open the Ace version that saved them; the files have been preserved."
        case .unsafeCredentialDirectory, .unsafeCredentialFile, .unsafeCredentialKeyFile:
            return "Ace's credential files must be private, owned by this macOS account, and free of symbolic or hard links. Restore their permissions, then try again."
        case .recoveryInterrupted:
            return "Credential recovery stopped before replacing the saved files. Check or recover again when Private Mode is off."
        case .recoveryChanged:
            return "The saved credentials changed after review. Check them again before recovering."
        case .recoveryNotNeeded:
            return "The saved credentials can now be read. Try again to verify them without resetting."
        case .couldNotCreateTemporaryFile, .atomicReplaceFailed:
            return "Ace could not save its private credentials. Check available disk space and access to Ace's Application Support folder, then try again."
        }
    }
}

/// No credential contents or keys are exposed to the review UI.
struct AceCredentialRecoveryReview: Equatable, Sendable {
    fileprivate let documentDigest: String
    fileprivate let keyDigest: String?
}

final class PromptFreeCredentialStore:
    AceCredentialStoring,
    @unchecked Sendable
{
    static let shared = PromptFreeCredentialStore()

    private let directoryURL: URL
    private let credentialURL: URL
    private let credentialKeyURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let resolvedDirectory = directoryURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/BlackLabel/Ace",
                    isDirectory: true
                )
        self.directoryURL = resolvedDirectory
        credentialURL = resolvedDirectory.appendingPathComponent(
            "credentials.v1.json",
            isDirectory: false
        )
        credentialKeyURL = resolvedDirectory.appendingPathComponent(
            "credentials.v1.key",
            isDirectory: false
        )
        self.fileManager = fileManager
    }

    func load() throws -> AceCredentialDocument {
        try lock.withLock {
            try loadUnlocked()
        }
    }

    /// Seals the empty credential document on the first normal-runtime launch.
    /// `load()` deliberately remains read-only so probes and tests cannot invent
    /// persistent state. The runtime singleton must be owned before this is
    /// called, which keeps first-launch key creation to one Ace process.
    func initializeEmptyDocumentIfNeeded() throws {
        try lock.withLock {
            if entryExists(credentialURL) {
                _ = try loadUnlocked()
                return
            }
            try writeUnlocked(.empty)
        }
    }

    func update(
        _ transform: (inout AceCredentialDocument) throws -> Void
    ) throws {
        try lock.withLock {
            var document = try loadUnlocked()
            try transform(&document)
            document.schemaVersion = 1
            try writeUnlocked(document)
        }
    }

    /// Preparation can read/encrypt/sync outside the privacy lock. Only a
    /// final atomic rename enters the supplied synchronous admission closure.
    func verifyForRecovery(
        commitIfAllowed: (_ commit: () -> Bool) -> Bool
    ) throws {
        try lock.withLock {
            guard commitIfAllowed({ true }) else {
                throw PromptFreeCredentialStoreError.recoveryInterrupted
            }
            if entryExists(credentialURL) {
                _ = try loadUnlocked(commitIfAllowed: commitIfAllowed)
            } else {
                try writeUnlocked(.empty, commitIfAllowed: commitIfAllowed)
            }
            _ = try loadUnlocked()
        }
    }

    /// A read-only review never authorizes recovery of permissions problems or
    /// a future schema. Only the exact unreadable pair may later be replaced.
    func reviewUnreadableCredentials() throws -> AceCredentialRecoveryReview {
        try lock.withLock { try recoveryReviewUnlocked() }
    }

    private func recoveryReviewUnlocked() throws -> AceCredentialRecoveryReview {
        do {
            _ = try loadUnlocked()
        } catch let error as PromptFreeCredentialStoreError {
            switch error {
            case .missingCredentialKey, .malformedCredentialKey, .malformedDocument:
                let bytes = try recoveryBytesUnlocked()
                return AceCredentialRecoveryReview(
                    documentDigest: SHA256.hash(data: bytes.document).description,
                    keyDigest: bytes.key.map { SHA256.hash(data: $0).description }
                )
            default: throw error
            }
        }
        throw PromptFreeCredentialStoreError.recoveryNotNeeded
    }

    private func recoveryBytesUnlocked() throws -> (document: Data, key: Data?) {
        guard isOwnedUnlinkedDirectory(directoryURL) else {
            throw PromptFreeCredentialStoreError.unsafeCredentialDirectory
        }
        let document = try readPrivateRegularFile(
            at: credentialURL, unsafeError: .unsafeCredentialFile
        )
        let key = entryExists(credentialKeyURL)
            ? try readPrivateRegularFile(at: credentialKeyURL, unsafeError: .unsafeCredentialKeyFile)
            : nil
        return (document, key)
    }

    /// Called only after the owner reviews the consequences. The original
    /// encrypted document and key are durably copied together before any live
    /// replacement. A crash between the two renames remains recoverable from
    /// this private archive. No history, provider login, or user file is erased.
    @discardableResult
    func recoverUnreadableCredentials(
        reviewed: AceCredentialRecoveryReview,
        commitIfAllowed: (_ commit: () -> Bool) -> Bool = { $0() }
    ) throws -> URL {
        try lock.withLock {
            guard commitIfAllowed({ true }) else {
                throw PromptFreeCredentialStoreError.recoveryInterrupted
            }
            guard try recoveryReviewUnlocked() == reviewed else {
                throw PromptFreeCredentialStoreError.recoveryChanged
            }
            let original = try recoveryBytesUnlocked()
            let archiveURL = directoryURL.appendingPathComponent(
                "credential-recovery-\(UUID().uuidString.lowercased())", isDirectory: true
            )
            guard mkdir(archiveURL.path, 0o700) == 0 else {
                throw PromptFreeCredentialStoreError.couldNotCreateTemporaryFile
            }
            let archiveDocument = archiveURL.appendingPathComponent(credentialURL.lastPathComponent)
            let archiveKey = archiveURL.appendingPathComponent(credentialKeyURL.lastPathComponent)
            try writeRecoveryFile(original.document, at: archiveDocument)
            if let key = original.key { try writeRecoveryFile(key, at: archiveKey) }
            try synchronizeRecoveryDirectory(archiveURL)
            try synchronizeRecoveryDirectory(directoryURL)

            let stagingURL = archiveURL.appendingPathComponent("replacement", isDirectory: true)
            let replacement = PromptFreeCredentialStore(directoryURL: stagingURL, fileManager: fileManager)
            try replacement.initializeEmptyDocumentIfNeeded()
            guard try replacement.load() == .empty else {
                throw PromptFreeCredentialStoreError.malformedDocument
            }
            guard try recoveryReviewUnlocked() == reviewed else {
                throw PromptFreeCredentialStoreError.recoveryChanged
            }
            // Pre-stage rollback too: no encryption, fsync, readback or
            // cleanup may run while the global privacy admission is held.
            let rollbackKey = stagingURL.appendingPathComponent("rollback.key")
            if let key = original.key { try writeRecoveryFile(key, at: rollbackKey) }
            try synchronizeRecoveryDirectory(stagingURL)
            var commitAttempted = false
            let committed = commitIfAllowed {
                commitAttempted = true
                guard rename(replacement.credentialKeyURL.path, credentialKeyURL.path) == 0 else { return false }
                guard rename(replacement.credentialURL.path, credentialURL.path) == 0 else {
                    if original.key != nil {
                        _ = rename(rollbackKey.path, credentialKeyURL.path)
                    } else {
                        _ = unlink(credentialKeyURL.path)
                    }
                    return false
                }
                return true
            }
            guard committed else {
                throw commitAttempted ? PromptFreeCredentialStoreError.atomicReplaceFailed
                    : PromptFreeCredentialStoreError.recoveryInterrupted
            }
            try synchronizeRecoveryDirectory(directoryURL)
            guard try loadUnlocked() == .empty else {
                throw PromptFreeCredentialStoreError.malformedDocument
            }
            try? fileManager.removeItem(at: stagingURL)
            return archiveURL
        }
    }

    private func writeRecoveryFile(_ data: Data, at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw PromptFreeCredentialStoreError.couldNotCreateTemporaryFile
        }
        defer { _ = close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func synchronizeRecoveryDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PromptFreeCredentialStoreError.atomicReplaceFailed }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw PromptFreeCredentialStoreError.atomicReplaceFailed }
    }

    private func loadUnlocked(
        commitIfAllowed: (_ commit: () -> Bool) -> Bool = { $0() }
    ) throws -> AceCredentialDocument {
        if entryExists(directoryURL),
           !isOwnedUnlinkedDirectory(directoryURL) {
            throw PromptFreeCredentialStoreError
                .unsafeCredentialDirectory
        }
        guard entryExists(credentialURL) else {
            return .empty
        }
        let data = try readPrivateRegularFile(
            at: credentialURL,
            unsafeError: .unsafeCredentialFile
        )
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(
            AceEncryptedCredentialEnvelope.self,
            from: data
        ) {
            return try decryptDocument(
                envelope,
                decoder: decoder
            )
        }

        let legacyDocument: AceCredentialDocument
        do {
            legacyDocument = try decoder.decode(
                AceCredentialDocument.self,
                from: data
            )
        } catch {
            throw PromptFreeCredentialStoreError.malformedDocument
        }
        guard legacyDocument.schemaVersion == 1 else {
            throw PromptFreeCredentialStoreError.unsupportedSchema
        }
        try writeUnlocked(legacyDocument, commitIfAllowed: commitIfAllowed)
        return legacyDocument
    }

    private func writeUnlocked(
        _ document: AceCredentialDocument,
        commitIfAllowed: (_ commit: () -> Bool) -> Bool = { $0() }
    ) throws {
        try prepareDirectory()
        if entryExists(credentialURL),
           !isOwnedUnlinkedRegularFile(credentialURL) {
            throw PromptFreeCredentialStoreError.unsafeCredentialFile
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let documentData = try encoder.encode(document)
        let credentialKey = try loadOrCreateCredentialKey()
        let sealedBox = try AES.GCM.seal(
            documentData,
            using: credentialKey
        )
        guard let combinedSealedBox = sealedBox.combined else {
            throw PromptFreeCredentialStoreError.malformedDocument
        }
        let envelope = AceEncryptedCredentialEnvelope(
            schemaVersion: 1,
            encryption: "AES.GCM.256",
            sealedDocument: combinedSealedBox.base64EncodedString()
        )
        let data = try encoder.encode(envelope)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".credentials.\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw PromptFreeCredentialStoreError
                .couldNotCreateTemporaryFile
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            var commitAttempted = false
            guard commitIfAllowed({
                commitAttempted = true
                return rename(temporaryURL.path, credentialURL.path) == 0
            }) else {
                throw commitAttempted ? PromptFreeCredentialStoreError.atomicReplaceFailed
                    : PromptFreeCredentialStoreError.recoveryInterrupted
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: credentialURL.path
            )
            guard isOwnedUnlinkedRegularFile(credentialURL) else {
                throw PromptFreeCredentialStoreError
                    .unsafeCredentialFile
            }
            synchronizeDirectory()
        } catch {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard isOwnedUnlinkedDirectory(directoryURL) else {
            throw PromptFreeCredentialStoreError
                .unsafeCredentialDirectory
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        guard isOwnedUnlinkedDirectory(directoryURL) else {
            throw PromptFreeCredentialStoreError
                .unsafeCredentialDirectory
        }
    }

    private func decryptDocument(
        _ envelope: AceEncryptedCredentialEnvelope,
        decoder: JSONDecoder
    ) throws -> AceCredentialDocument {
        guard envelope.schemaVersion == 1 else {
            throw PromptFreeCredentialStoreError.unsupportedSchema
        }
        guard envelope.encryption == "AES.GCM.256",
              let sealedDocument = Data(
                base64Encoded: envelope.sealedDocument
              ) else {
            throw PromptFreeCredentialStoreError.malformedDocument
        }
        let credentialKey = try loadExistingCredentialKey()
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(
                combined: sealedDocument
            )
        } catch {
            throw PromptFreeCredentialStoreError.malformedDocument
        }
        let documentData: Data
        do {
            documentData = try AES.GCM.open(
                sealedBox,
                using: credentialKey
            )
        } catch {
            throw PromptFreeCredentialStoreError.malformedDocument
        }
        let document: AceCredentialDocument
        do {
            document = try decoder.decode(
                AceCredentialDocument.self,
                from: documentData
            )
        } catch {
            throw PromptFreeCredentialStoreError.malformedDocument
        }
        guard document.schemaVersion == 1 else {
            throw PromptFreeCredentialStoreError.unsupportedSchema
        }
        return document
    }

    private func loadOrCreateCredentialKey() throws -> SymmetricKey {
        if entryExists(credentialKeyURL) {
            return try loadExistingCredentialKey()
        }

        let generatedKey = SymmetricKey(size: .bits256)
        let generatedKeyData = generatedKey.withUnsafeBytes {
            Data($0)
        }
        let temporaryKeyURL = directoryURL.appendingPathComponent(
            ".credentials-key.\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporaryKeyURL.path,
            contents: generatedKeyData,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw PromptFreeCredentialStoreError
                .couldNotCreateTemporaryFile
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryKeyURL)
            try handle.synchronize()
            try handle.close()
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryKeyURL.path
            )
            let exclusiveLinkResult = link(
                temporaryKeyURL.path,
                credentialKeyURL.path
            )
            if exclusiveLinkResult != 0, errno != EEXIST {
                throw PromptFreeCredentialStoreError.atomicReplaceFailed
            }
            guard unlink(temporaryKeyURL.path) == 0 else {
                throw PromptFreeCredentialStoreError.atomicReplaceFailed
            }
            synchronizeDirectory()
        } catch {
            if fileManager.fileExists(atPath: temporaryKeyURL.path) {
                try? fileManager.removeItem(at: temporaryKeyURL)
            }
            throw error
        }
        return try loadExistingCredentialKey()
    }

    private func loadExistingCredentialKey() throws -> SymmetricKey {
        if !entryExists(credentialKeyURL) {
            throw PromptFreeCredentialStoreError.missingCredentialKey
        }
        let keyData = try readPrivateRegularFile(
            at: credentialKeyURL,
            unsafeError: .unsafeCredentialKeyFile
        )
        guard keyData.count == 32 else {
            throw PromptFreeCredentialStoreError.malformedCredentialKey
        }
        return SymmetricKey(data: keyData)
    }

    private func isOwnedUnlinkedDirectory(_ url: URL) -> Bool {
        guard let metadata = fileMetadataWithoutFollowingLinks(url) else {
            return false
        }
        return (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && metadata.st_uid == getuid()
            && (metadata.st_mode & mode_t(0o777)) == mode_t(0o700)
    }

    private func isOwnedUnlinkedRegularFile(_ url: URL) -> Bool {
        // A path lstat can catch a competing writer mid-protocol: a
        // concurrent rename-replace can surface the outgoing inode with
        // st_nlink == 0, and the key-creation link()+unlink() protocol
        // leaves st_nlink == 2 for a moment. A genuine hardlink attack
        // PERSISTS, so retry the observation briefly and reject anything
        // that does not settle into exactly one private regular file.
        let maximumAdmissionAttempts = 10
        for admissionAttempt in 1...maximumAdmissionAttempts {
            guard let metadata = fileMetadataWithoutFollowingLinks(url) else {
                return false
            }
            if isPrivateRegularFile(metadata) {
                return true
            }
            let linkCountIsWriterTransient =
                metadata.st_nlink == 0 || metadata.st_nlink == 2
            guard linkCountIsWriterTransient,
                  isPrivateExceptLinkCount(metadata),
                  admissionAttempt < maximumAdmissionAttempts else {
                return false
            }
            usleep(2_000)
        }
        return false
    }

    private func isPrivateExceptLinkCount(_ metadata: stat) -> Bool {
        (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && metadata.st_uid == getuid()
            && (metadata.st_mode & mode_t(0o777)) == mode_t(0o600)
    }

    private func entryExists(_ url: URL) -> Bool {
        fileMetadataWithoutFollowingLinks(url) != nil
    }

    private func fileMetadataWithoutFollowingLinks(
        _ url: URL
    ) -> stat? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            return nil
        }
        return metadata
    }

    private func isPrivateRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
            && (metadata.st_mode & mode_t(0o777)) == mode_t(0o600)
    }

    private func readPrivateRegularFile(
        at url: URL,
        unsafeError: PromptFreeCredentialStoreError
    ) throws -> Data {
        // Two legitimate writer protocols make the link count transiently
        // wrong on a healthy private file, so a single observation cannot
        // distinguish an attack from a concurrent writer:
        //   - st_nlink == 0: a competing process rename-replaced the file
        //     between our open() and fstat(), so the inode we opened was
        //     just unlinked (a hardlink attack can never produce zero).
        //   - st_nlink == 2: the key-creation protocol link()s its private
        //     temporary onto the final name and unlinks the temporary a
        //     moment later.
        // A real hardlink attack PERSISTS, so retry the whole open+fstat
        // admission briefly and fail closed if the state does not settle.
        let maximumAdmissionAttempts = 10
        for admissionAttempt in 1...maximumAdmissionAttempts {
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw unsafeError
            }

            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                _ = close(descriptor)
                throw unsafeError
            }
            if isPrivateRegularFile(metadata) {
                defer {
                    _ = close(descriptor)
                }
                let handle = FileHandle(
                    fileDescriptor: descriptor,
                    closeOnDealloc: false
                )
                return try handle.readToEnd() ?? Data()
            }
            _ = close(descriptor)

            let linkCountIsWriterTransient =
                metadata.st_nlink == 0 || metadata.st_nlink == 2
            guard linkCountIsWriterTransient,
                  isPrivateExceptLinkCount(metadata),
                  admissionAttempt < maximumAdmissionAttempts else {
                throw unsafeError
            }
            usleep(2_000)
        }
        throw unsafeError
    }

    private func synchronizeDirectory() {
        let descriptor = open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            return
        }
        _ = fsync(descriptor)
        _ = close(descriptor)
    }
}
