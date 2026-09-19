#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

enum StableInstallResumeStoreError: Error, Equatable {
    case invalidStage
    case unsafeDirectory
    case unsafeResumeFile
    case couldNotCreateTemporaryFile
    case atomicReplaceFailed
}

struct StableInstallResumeDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let nonce: UUID
    let stage: String
    let createdAt: Date
}

struct StableInstallResumeStore {
    private let directoryURL: URL
    private let resumeURL: URL
    private let fileManager: FileManager
    private let now: () -> Date
    private let maximumAge: TimeInterval = 600

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        let resolvedDirectory = directoryURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/BlackLabel/Ace",
                    isDirectory: true
                )
        self.directoryURL = resolvedDirectory
        resumeURL = resolvedDirectory.appendingPathComponent(
            "stable-install-resume.json",
            isDirectory: false
        )
        self.fileManager = fileManager
        self.now = now
    }

    func write(stage: String) throws {
        let normalizedStage = stage.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedStage.isEmpty, normalizedStage.count <= 80 else {
            throw StableInstallResumeStoreError.invalidStage
        }

        try prepareDirectory()
        if fileManager.fileExists(atPath: resumeURL.path),
           !isOwnedUnlinkedRegularFile(resumeURL) {
            throw StableInstallResumeStoreError.unsafeResumeFile
        }

        let document = StableInstallResumeDocument(
            schemaVersion: 1,
            nonce: UUID(),
            stage: normalizedStage,
            createdAt: now()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".stable-install-resume.\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw StableInstallResumeStoreError
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
            guard rename(temporaryURL.path, resumeURL.path) == 0 else {
                throw StableInstallResumeStoreError.atomicReplaceFailed
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: resumeURL.path
            )
            guard isOwnedUnlinkedRegularFile(resumeURL) else {
                throw StableInstallResumeStoreError.unsafeResumeFile
            }
        } catch {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    func consume() throws -> String? {
        guard fileManager.fileExists(atPath: resumeURL.path) else {
            return nil
        }
        guard isOwnedUnlinkedRegularFile(resumeURL) else {
            throw StableInstallResumeStoreError.unsafeResumeFile
        }

        let data = try Data(contentsOf: resumeURL)
        try fileManager.removeItem(at: resumeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            StableInstallResumeDocument.self,
            from: data
        )
        guard document.schemaVersion == 1 else {
            return nil
        }
        let age = now().timeIntervalSince(document.createdAt)
        guard age >= 0, age <= maximumAge else {
            return nil
        }
        let normalizedStage = document.stage.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedStage.isEmpty, normalizedStage.count <= 80 else {
            return nil
        }
        return normalizedStage
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard isOwnedUnlinkedDirectory(directoryURL) else {
            throw StableInstallResumeStoreError.unsafeDirectory
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
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
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
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
