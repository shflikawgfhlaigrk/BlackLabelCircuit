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

enum ArtifactReceiptStoreError: Error, Equatable {
    case unsafeDirectory
    case unsafeStore
    case malformedStore
    case invalidReceipt
    case artifactUnavailable
    case artifactChanged
    case atomicReplaceFailed
}

final class ArtifactReceiptStore: @unchecked Sendable {
    static let shared = ArtifactReceiptStore()

    private static let maximumReceiptCount = 2_000
    private let directoryURL: URL
    private let storeURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let directory = directoryURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/BlackLabel/Ace",
                    isDirectory: true
                )
        self.directoryURL = directory
        storeURL = directory.appendingPathComponent(
            "artifact-receipts.v1.json"
        )
        self.fileManager = fileManager
    }

    func recordStarted(
        operationID: UUID,
        artifactPath: String,
        at date: Date = Date()
    ) throws -> ArtifactReceipt {
        try append(
            operationID: operationID,
            artifactPath: artifactPath,
            sha256: nil,
            state: .started,
            at: date
        )
    }

    func recordStep(
        operationID: UUID,
        artifactPath: String,
        current: Int,
        total: Int,
        title: String,
        at date: Date = Date()
    ) throws -> ArtifactReceipt {
        guard current > 0,
              total >= current,
              !title.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            throw ArtifactReceiptStoreError.invalidReceipt
        }
        return try append(
            operationID: operationID,
            artifactPath: artifactPath,
            sha256: nil,
            state: .step(
                current: current,
                total: total,
                title: title
            ),
            at: date
        )
    }

    func recordDone(
        operationID: UUID,
        artifactURL: URL,
        at date: Date = Date()
    ) throws -> ArtifactReceipt {
        let path = artifactURL.standardizedFileURL.path
        let digest = try Self.sha256(ofRegularFileAt: artifactURL)
        return try append(
            operationID: operationID,
            artifactPath: path,
            sha256: digest,
            state: .done,
            at: date
        )
    }

    func recordFailed(
        operationID: UUID,
        artifactPath: String,
        reason: String,
        at date: Date = Date()
    ) throws -> ArtifactReceipt {
        let boundedReason = reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !boundedReason.isEmpty,
              boundedReason.count <= 500 else {
            throw ArtifactReceiptStoreError.invalidReceipt
        }
        return try append(
            operationID: operationID,
            artifactPath: artifactPath,
            sha256: nil,
            state: .failed(reason: boundedReason),
            at: date
        )
    }

    func receipts(operationID: UUID) throws -> [ArtifactReceipt] {
        try lock.withLock {
            try loadUnlocked().filter {
                $0.operationID == operationID
            }
        }
    }

    func latestVerifiedDone() throws -> ArtifactReceipt? {
        try lock.withLock {
            guard let receipt = try loadUnlocked().last(where: {
                $0.state == .done
            }) else {
                return nil
            }
            guard receipt.schemaVersion
                    == ArtifactReceipt.currentSchemaVersion,
                  let expectedDigest = receipt.sha256,
                  expectedDigest.count == 64 else {
                throw ArtifactReceiptStoreError.invalidReceipt
            }
            let actualDigest = try Self.sha256(
                ofRegularFileAt: URL(
                    fileURLWithPath: receipt.artifactPath
                )
            )
            guard actualDigest == expectedDigest else {
                throw ArtifactReceiptStoreError.artifactChanged
            }
            return receipt
        }
    }

    func verifiedDone(
        operationID: UUID
    ) throws -> ArtifactReceipt? {
        try lock.withLock {
            guard let receipt = try loadUnlocked().last(where: {
                $0.operationID == operationID
                    && $0.state == .done
            }) else {
                return nil
            }
            guard receipt.schemaVersion
                    == ArtifactReceipt.currentSchemaVersion,
                  let expectedDigest = receipt.sha256,
                  expectedDigest.count == 64 else {
                throw ArtifactReceiptStoreError.invalidReceipt
            }
            let actualDigest = try Self.sha256(
                ofRegularFileAt: URL(
                    fileURLWithPath: receipt.artifactPath
                )
            )
            guard actualDigest == expectedDigest else {
                throw ArtifactReceiptStoreError.artifactChanged
            }
            return receipt
        }
    }

    private func append(
        operationID: UUID,
        artifactPath: String,
        sha256: String?,
        state: ArtifactReceiptState,
        at date: Date
    ) throws -> ArtifactReceipt {
        try lock.withLock {
            try ensurePrivateDirectoryUnlocked()
            var values = try loadUnlocked()
            let nextSequence =
                (values.last(where: {
                    $0.operationID == operationID
                })?.sequence ?? 0) + 1
            let receipt = ArtifactReceipt(
                operationID: operationID,
                sequence: nextSequence,
                timestamp: date,
                artifactPath: artifactPath,
                sha256: sha256,
                state: state
            )
            values.append(receipt)
            if values.count > Self.maximumReceiptCount {
                values.removeFirst(
                    values.count - Self.maximumReceiptCount
                )
            }
            try saveUnlocked(values)
            return receipt
        }
    }

    private func ensurePrivateDirectoryUnlocked() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        guard isPrivateDirectory(directoryURL) else {
            throw ArtifactReceiptStoreError.unsafeDirectory
        }
    }

    private func loadUnlocked() throws -> [ArtifactReceipt] {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return []
        }
        guard isPrivateDirectory(directoryURL) else {
            throw ArtifactReceiptStoreError.unsafeDirectory
        }
        guard isPrivateRegularFile(storeURL) else {
            throw ArtifactReceiptStoreError.unsafeStore
        }
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let values = try? decoder.decode(
            [ArtifactReceipt].self,
            from: data
        ), values.count <= Self.maximumReceiptCount,
            values.allSatisfy({
                $0.schemaVersion
                    == ArtifactReceipt.currentSchemaVersion
                    && $0.sequence > 0
                    && !$0.artifactPath.isEmpty
            }) else {
            throw ArtifactReceiptStoreError.malformedStore
        }
        return values
    }

    private func saveUnlocked(_ receipts: [ArtifactReceipt]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipts)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".artifact-receipts.\(UUID().uuidString).tmp"
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ArtifactReceiptStoreError.atomicReplaceFailed
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            guard rename(temporaryURL.path, storeURL.path) == 0 else {
                throw ArtifactReceiptStoreError.atomicReplaceFailed
            }
            guard isPrivateRegularFile(storeURL) else {
                throw ArtifactReceiptStoreError.unsafeStore
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func isPrivateDirectory(_ url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & S_IFMT == S_IFDIR else {
            return false
        }
        return status.st_mode & 0o777 == 0o700
    }

    private func isPrivateRegularFile(_ url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1 else {
            return false
        }
        return status.st_mode & 0o777 == 0o600
    }

    private static func sha256(
        ofRegularFileAt url: URL
    ) throws -> String {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1 else {
            throw ArtifactReceiptStoreError.artifactUnavailable
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1_024),
              !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }
}
