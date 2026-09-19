#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

enum PrivateSupportDirectoryError: Error {
    case unsafeExistingPath
}

enum PrivateSupportDirectory {
    nonisolated static func ensure(
        at directoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard directoryIsOwnedAndNotLinked(
            directoryURL,
            fileManager: fileManager
        ) else {
            throw PrivateSupportDirectoryError.unsafeExistingPath
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        guard directoryIsOwnedAndNotLinked(
            directoryURL,
            fileManager: fileManager
        ) else {
            throw PrivateSupportDirectoryError.unsafeExistingPath
        }
    }

    private nonisolated static func directoryIsOwnedAndNotLinked(
        _ directoryURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let values = try? directoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        let attributes = try? fileManager.attributesOfItem(
            atPath: directoryURL.path
        ),
        let ownerIdentifier = attributes[.ownerAccountID] as? NSNumber else {
            return false
        }
        return ownerIdentifier.uint32Value == getuid()
    }
}
