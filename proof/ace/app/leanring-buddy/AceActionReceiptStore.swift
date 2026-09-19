#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

struct AceActionReceipt: Codable, Equatable, Sendable {
    let actionID: String
    let startedAt: Date
    let finishedAt: Date
    let outcome: String
    let failureCode: String?
}

protocol AceActionReceiptWriting: Sendable {
    func append(_ receipt: AceActionReceipt) async throws
}

enum AceActionReceiptStoreError: Error, Equatable {
    case unsafeDiagnosticsDirectory
    case unsafeReceiptFile
    case couldNotCreateReceiptFile
}

actor AceActionReceiptStore: AceActionReceiptWriting {
    private let diagnosticsDirectoryURL: URL
    private let receiptURL: URL
    private let fileManager: FileManager

    init(
        diagnosticsDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let directory = diagnosticsDirectoryURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/BlackLabel/Ace/Diagnostics",
                    isDirectory: true
                )
        self.diagnosticsDirectoryURL = directory
        receiptURL = directory.appendingPathComponent(
            "action-receipts.jsonl",
            isDirectory: false
        )
        self.fileManager = fileManager
    }

    func append(_ receipt: AceActionReceipt) async throws {
        try prepareDestination()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var payload = try encoder.encode(receipt)
        payload.append(0x0A)

        let handle = try FileHandle(forWritingTo: receiptURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
        try handle.synchronize()
    }

    private func prepareDestination() throws {
        try fileManager.createDirectory(
            at: diagnosticsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard isOwnedUnlinkedDirectory(diagnosticsDirectoryURL) else {
            throw AceActionReceiptStoreError.unsafeDiagnosticsDirectory
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: diagnosticsDirectoryURL.path
        )

        if fileManager.fileExists(atPath: receiptURL.path) {
            guard isOwnedUnlinkedRegularFile(receiptURL) else {
                throw AceActionReceiptStoreError.unsafeReceiptFile
            }
        } else {
            guard fileManager.createFile(
                atPath: receiptURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw AceActionReceiptStoreError.couldNotCreateReceiptFile
            }
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: receiptURL.path
        )
        guard isOwnedUnlinkedRegularFile(receiptURL) else {
            throw AceActionReceiptStoreError.unsafeReceiptFile
        }
    }

    private func isOwnedUnlinkedDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true else {
            return false
        }
        return isOwnedByCurrentUser(url)
    }

    private func isOwnedUnlinkedRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true else {
            return false
        }
        return isOwnedByCurrentUser(url)
    }

    private func isOwnedByCurrentUser(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ),
        let owner = attributes[.ownerAccountID] as? NSNumber else {
            return false
        }
        return owner.uint32Value == getuid()
    }
}
