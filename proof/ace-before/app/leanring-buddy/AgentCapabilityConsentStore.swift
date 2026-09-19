#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

enum AgentCapabilityConsentStoreError: Error, Equatable {
    case unsafeDirectory
    case unsafeReceipt
    case malformedReceipt
    case atomicReplaceFailed
}

final class AgentCapabilityConsentStore: @unchecked Sendable {
    static let shared = AgentCapabilityConsentStore()

    private let directoryURL: URL
    private let receiptURL: URL
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
        receiptURL = resolvedDirectory.appendingPathComponent(
            "agent-capability-consent.v1.json",
            isDirectory: false
        )
        self.fileManager = fileManager
    }

    func load() throws -> AgentCapabilityConsentReceipt? {
        try lock.withLock {
            guard fileManager.fileExists(atPath: receiptURL.path) else {
                return nil
            }
            guard isPrivateDirectory(directoryURL, expectedMode: 0o700) else {
                throw AgentCapabilityConsentStoreError.unsafeDirectory
            }
            guard isPrivateRegularFile(receiptURL, expectedMode: 0o600) else {
                throw AgentCapabilityConsentStoreError.unsafeReceipt
            }
            let data = try Data(contentsOf: receiptURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let receipt = try? decoder.decode(
                AgentCapabilityConsentReceipt.self,
                from: data
            ), receipt.schemaVersion
                == AgentCapabilityConsentReceipt.currentSchemaVersion else {
                throw AgentCapabilityConsentStoreError.malformedReceipt
            }
            return receipt
        }
    }

    func save(_ receipt: AgentCapabilityConsentReceipt) throws {
        try lock.withLock {
            guard receipt.schemaVersion
                == AgentCapabilityConsentReceipt.currentSchemaVersion else {
                throw AgentCapabilityConsentStoreError.malformedReceipt
            }
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
            guard isPrivateDirectory(directoryURL, expectedMode: 0o700) else {
                throw AgentCapabilityConsentStoreError.unsafeDirectory
            }

            let temporaryURL = directoryURL.appendingPathComponent(
                ".agent-capability-consent.\(UUID().uuidString).tmp"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(receipt)
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw AgentCapabilityConsentStoreError.atomicReplaceFailed
            }
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: temporaryURL.path
                )
                guard rename(temporaryURL.path, receiptURL.path) == 0 else {
                    throw AgentCapabilityConsentStoreError.atomicReplaceFailed
                }
                guard isPrivateRegularFile(
                    receiptURL,
                    expectedMode: 0o600
                ) else {
                    throw AgentCapabilityConsentStoreError.unsafeReceipt
                }
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        }
    }

    private func isPrivateDirectory(
        _ url: URL,
        expectedMode: mode_t
    ) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            return false
        }
        return status.st_mode & 0o777 == expectedMode
    }

    private func isPrivateRegularFile(
        _ url: URL,
        expectedMode: mode_t
    ) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            return false
        }
        return status.st_mode & 0o777 == expectedMode
    }
}
